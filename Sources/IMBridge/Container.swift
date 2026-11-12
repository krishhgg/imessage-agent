import Foundation
import IMCore
import IMForeground
import IMPolicy
import IMSend
import IMStore
import IMUI

/// All live objects, built once at start. Tests build one from fakes with the memberwise init. Owner: IMBridge.
///
/// `db`, `reads` and `attachments` are optional because chat.db may not open yet (no Full Disk Access). The bridge
/// retries the open on each read request, so a grant reaches the running bridge without a restart (S1: within 2 s).
///
/// Side effects that leave the process go through injected objects only: `permissions` for TCC checks and the
/// Settings pane, `scripts` for Apple Events, `app` and `ax` for Messages. `openStoreIfNeeded` opens
/// `store.chatDBPath`, which tests point at the fixture.
///
/// The store-backed objects (`db` through `foreground`) are read and written under one lock, because connection
/// threads read them while another connection's read request may be opening the store. Set `contactsSource`, `input`
/// and `keys` before the first `openStoreIfNeeded`; the foreground machine is built only when both `input` and `keys`
/// are set.
public final class BridgeContainer {
    public let paths: Paths
    public let clock: Clock
    /// What `openStoreIfNeeded` opens. Live: `StoreConfiguration.live(paths:)`.
    public let store: StoreConfiguration
    public let permissions: PermissionProbing
    public var db: ChatDatabase? {
        get { locked { storedDB } }
        set { locked { storedDB = newValue } }
    }
    public var reads: ReadService? {
        get { locked { storedReads } }
        set { locked { storedReads = newValue } }
    }
    public var attachments: AttachmentService? {
        get { locked { storedAttachments } }
        set { locked { storedAttachments = newValue } }
    }
    public let policy: PolicyStore
    public let engine: PolicyEngine
    public let approvals: ApprovalBook
    public let journal: Journal
    public let queue: ActionQueueing
    public let scripts: AppleScriptRunning
    public let app: MessagesAppControl
    public let ax: MessagesAXDriving
    public let capabilities: CapabilityRegistry
    public var sender: MessageSender? {
        get { locked { storedSender } }
        set { locked { storedSender = newValue } }
    }
    public var tapbacks: TapbackRunner? {
        get { locked { storedTapbacks } }
        set { locked { storedTapbacks = newValue } }
    }
    public var unsend: UnsendRunner? {
        get { locked { storedUnsend } }
        set { locked { storedUnsend = newValue } }
    }
    public var foreground: ForegroundMachine? {
        get { locked { storedForeground } }
        set { locked { storedForeground = newValue } }
    }

    /// Where chat.db names come from. Nil means no contacts: handles show as phone numbers and emails. Live:
    /// `AddressBookContacts`.
    public var contactsSource: ContactsSource? {
        get { locked { storedContacts } }
        set { locked { storedContacts = newValue } }
    }
    /// The HID idle reading the foreground machine's idle gate and ownership check use. Live: `HIDInputMonitor`.
    public var input: InputMonitoring? {
        get { locked { storedInput } }
        set { locked { storedInput = newValue } }
    }
    /// Return and Escape posted to Messages in foreground mode. Live: `PidKeyPoster`.
    public var keys: KeyPosting? {
        get { locked { storedKeys } }
        set { locked { storedKeys = newValue } }
    }
    /// Set at start when crash recovery found a foreground action that didn't finish. `status` and `doctor` show it.
    public var crashNote: String? {
        get { locked { storedCrashNote } }
        set { locked { storedCrashNote = newValue } }
    }
    /// Counts open connections and background approvals, and keeps the process from being terminated while any is
    /// open (section 1: the bridge stays resident while an approval is open).
    public let residency: ResidencyGuard
    /// The staging area the sender stages files in, once the store is open. The timers sweep it.
    public var stagingArea: StagingArea? { sender?.staging }

    /// Frozen upload copies, before staging.
    let uploads: UploadFreezer
    /// Responses of requests that are still running or finished in this bridge run, for `pending <id>`.
    let inFlight = InFlightRegistry()
    /// True while crash recovery hasn't written a final record for every open entry. `BridgeMain.recoverIfNeeded`
    /// retries it, and mutations are refused until it succeeds (section 3 item 2).
    var journalNeedsRecovery: Bool {
        get { locked { storedNeedsRecovery } }
        set { locked { storedNeedsRecovery = newValue } }
    }
    /// Serializes crash recovery, so two requests never recover the journal at once.
    let recoveryLock = NSLock()

    private let lock = NSLock()
    /// Serializes `openStoreIfNeeded`, so two read requests never open chat.db twice.
    private let openLock = NSLock()
    private var storedDB: ChatDatabase?
    private var storedReads: ReadService?
    private var storedAttachments: AttachmentService?
    private var storedSender: MessageSender?
    private var storedTapbacks: TapbackRunner?
    private var storedUnsend: UnsendRunner?
    private var storedForeground: ForegroundMachine?
    private var storedContacts: ContactsSource?
    private var storedInput: InputMonitoring?
    private var storedKeys: KeyPosting?
    private var storedCrashNote: String?
    private var storedNeedsRecovery = false
    /// The message count from the probe that opened the store.
    private var openedRows: Int64 = 0

    public init(paths: Paths, clock: Clock, store: StoreConfiguration, permissions: PermissionProbing,
                db: ChatDatabase?, reads: ReadService?, attachments: AttachmentService?,
                policy: PolicyStore, engine: PolicyEngine, approvals: ApprovalBook, journal: Journal,
                queue: ActionQueueing, scripts: AppleScriptRunning, app: MessagesAppControl, ax: MessagesAXDriving,
                capabilities: CapabilityRegistry, sender: MessageSender?, tapbacks: TapbackRunner?,
                unsend: UnsendRunner?, foreground: ForegroundMachine?) {
        self.paths = paths
        self.clock = clock
        self.store = store
        self.permissions = permissions
        self.storedDB = db
        self.storedReads = reads
        self.storedAttachments = attachments
        self.policy = policy
        self.engine = engine
        self.approvals = approvals
        self.journal = journal
        self.queue = queue
        self.scripts = scripts
        self.app = app
        self.ax = ax
        self.capabilities = capabilities
        self.storedSender = sender
        self.storedTapbacks = tapbacks
        self.storedUnsend = unsend
        self.storedForeground = foreground
        self.residency = ResidencyGuard()
        self.uploads = UploadFreezer(directory: paths.uploadsDir)
    }

    /// Live wiring: `SystemClock`, `StoreConfiguration.live`, `LivePermissionProbe`, `LiveKeychainHashStore`,
    /// `NSAppleScriptRunner`, `LiveMessagesApp`, `LiveMessagesAX`, `ApprovalPanelController`, `HIDInputMonitor`,
    /// `PidKeyPoster`, `AddressBookContacts`.
    ///
    /// The rate limiter starts with the journal's send history. Its inbound reads go through
    /// `DeferredActivitySource`, which reaches chat.db once the store is open. Throws if the journal can't be read,
    /// since a lost `invoking` record could make a retry send twice.
    public static func live(paths: Paths = Paths()) throws -> BridgeContainer {
        let clock = SystemClock()
        let policy = PolicyStore(fileURL: paths.policyStoreURL, keychain: LiveKeychainHashStore())
        let journal = try Journal(directory: paths.journalDir, clock: clock)
        let activity = DeferredActivitySource()
        let limiter = RateLimiter(clock: clock, activity: activity, ownAddresses: activity.ownAddresses,
                                  history: journal.sendEvents())
        let engine = PolicyEngine(store: policy, limiter: limiter, clock: clock)
        let approvals = ApprovalBook(clock: clock, presenter: ApprovalPanelController())
        let scripts = NSAppleScriptRunner()
        let app = LiveMessagesApp(scripts: scripts)
        let ax = LiveMessagesAX(app: app)
        let evidence = Bundle.main.url(forResource: "release-evidence", withExtension: "json") ?? paths.evidenceURL
        let capabilities = CapabilityRegistry(evidenceURL: evidence, macOSVersion: CapabilityRegistry.currentMajorMinor(),
                                              uiLanguageEnglish: CapabilityRegistry.currentUIIsEnglish())
        let container = BridgeContainer(
            paths: paths, clock: clock, store: .live(paths: paths), permissions: LivePermissionProbe(paths: paths),
            db: nil, reads: nil, attachments: nil, policy: policy, engine: engine, approvals: approvals,
            journal: journal, queue: ActionQueue(clock: clock), scripts: scripts, app: app, ax: ax,
            capabilities: capabilities, sender: nil, tapbacks: nil, unsend: nil, foreground: nil)
        container.contactsSource = AddressBookContacts(sourcesDir: paths.addressBookSourcesDir)
        container.input = HIDInputMonitor()
        container.keys = PidKeyPoster()
        activity.container = container
        _ = container.openStoreIfNeeded()
        return container
    }

    /// Opens chat.db at `store.chatDBPath` if it isn't open yet and builds the store-backed objects.
    ///
    /// - Already open: `.ok` with the count from the open, and nothing is read.
    /// - Otherwise `ChatDatabase.probe` first. Anything but `.ok` is returned as is and the next read tries again.
    /// - On success the agent-sent GUIDs are seeded from the journal, then every store-backed object that is still
    ///   nil is built: reads, attachments, the sender with its staging area and correlator, the tapback and unsend
    ///   runners, and the foreground machine when `input` and `keys` are set. Objects a test injected are kept.
    public func openStoreIfNeeded() -> DatabaseProbe {
        openLock.lock()
        defer { openLock.unlock() }

        let database: ChatDatabase
        let probe: DatabaseProbe
        if let open = db {
            database = open
            probe = .ok(messageRows: locked { openedRows })
        } else {
            let found = ChatDatabase.probe(path: store.chatDBPath)
            guard case .ok(let rows) = found else { return found }
            let contacts: ContactBook
            do {
                contacts = try ContactBook(source: contactsSource ?? EmptyContacts())
            } catch {
                // An unreadable address book shouldn't block reads; names fall back to handles.
                guard let empty = try? ContactBook(source: EmptyContacts()) else {
                    return .failed("contacts: \(error)")
                }
                contacts = empty
            }
            do {
                database = try ChatDatabase(configuration: store, contacts: contacts, clock: clock)
            } catch StoreError.notPermitted {
                return .notPermitted
            } catch StoreError.notFound {
                return .missing
            } catch {
                return .failed(String(describing: error))
            }
            database.addAgentSentGUIDs(journal.agentSentGUIDs())
            probe = .ok(messageRows: rows)
            locked { openedRows = rows }
        }
        buildStoreObjects(database)
        return probe
    }

    /// Builds what is still missing around an open database.
    private func buildStoreObjects(_ database: ChatDatabase) {
        let clock = self.clock
        let timeZone = store.timeZone
        lock.lock()
        defer { lock.unlock() }
        if storedDB == nil { storedDB = database }
        if storedReads == nil { storedReads = ReadService(db: database) }
        if storedAttachments == nil { storedAttachments = AttachmentService(db: database, clock: clock) }

        let staging = storedSender?.staging
            ?? StagingArea(directory: paths.stagingDir, clock: clock, rows: database)
        let correlator = storedSender?.correlator ?? SendCorrelator(rows: database, clock: clock)
        if storedSender == nil {
            storedSender = MessageSender(scripts: scripts, coldStart: ColdStarter(app: app, scripts: scripts, clock: clock),
                                         staging: staging, correlator: correlator, rows: database, clock: clock)
        }
        guard storedTapbacks == nil || storedUnsend == nil || storedForeground == nil else { return }

        let windows = storedTapbacks?.windows ?? storedUnsend?.windows
            ?? HiddenWindowManager(app: app, ax: ax, transfers: staging, clock: clock)
        let targeting: ChatTargeting = storedTapbacks?.targeting ?? storedUnsend?.targeting
            ?? ChatTargeter(ax: ax, source: database,
                            builder: { RowDescriptionBuilder(timeZone: timeZone, now: clock.now) }, clock: clock)
        if storedTapbacks == nil {
            storedTapbacks = TapbackRunner(ax: ax, windows: windows, targeting: targeting, source: database, clock: clock)
        }
        if storedUnsend == nil {
            storedUnsend = UnsendRunner(ax: ax, windows: windows, targeting: targeting, source: database, clock: clock)
        }
        if storedForeground == nil, let input = storedInput, let keys = storedKeys {
            let verifier = LiveForegroundVerifier(source: database, correlator: correlator, clock: clock)
            let env = ForegroundEnvironment(clock: clock, input: input, app: app, ax: ax, keys: keys, verifier: verifier,
                                            queue: queue, targeting: targeting, windows: windows, source: database,
                                            rows: database, mode: policy, progress: { _ in })
            storedForeground = ForegroundMachine(env: env)
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

/// No contacts. Used when the container has no `contactsSource` and when the address book can't be read.
final class EmptyContacts: ContactsSource {
    func cards() throws -> [ContactCard] { [] }
    func ownerHandles() throws -> [String] { [] }
}

/// The rate limiter's inbound reads, built before chat.db opens. Reads go to `container.db`; until the store is open
/// they throw `StoreError.notPermitted`, so `PolicyEngine` asks instead of allowing (fail closed). Owner: IMBridge.
public final class DeferredActivitySource: ChatActivitySource {
    public weak var container: BridgeContainer?

    public init(container: BridgeContainer? = nil) { self.container = container }

    public func inboundRows(in chat: ResolvedChat, afterNs: AppleNanos, limit: Int) throws -> [InboundRow] {
        guard let db = container?.db else { throw StoreError.notPermitted }
        return try db.inboundRows(in: chat, afterNs: afterNs, limit: limit)
    }

    /// The user's own addresses for `RateLimiter.ownAddresses`: the open store's `ContactBook.ownerHandles`, which
    /// also decide chat.db's self-chats. Empty until chat.db opens, when `inboundRows` throws anyway.
    public func ownAddresses() -> Set<String> {
        container?.db?.contacts.ownerHandles ?? []
    }
}

/// Keeps the bridge resident while a connection or an approval is open (section 1). Owner: IMBridge.
///
/// A counter under a lock. The first `enter` turns off automatic and sudden termination; the matching last `leave`
/// turns them back on. `leave` without a matching `enter` does nothing, so the count never goes negative.
public final class ResidencyGuard {
    public static let reason = "an approval or a request is open"

    private let lock = NSLock()
    private var count = 0
    private let onFirstEnter: () -> Void
    private let onLastLeave: () -> Void

    public init(onFirstEnter: @escaping () -> Void = ResidencyGuard.holdProcess,
                onLastLeave: @escaping () -> Void = ResidencyGuard.releaseProcess) {
        self.onFirstEnter = onFirstEnter
        self.onLastLeave = onLastLeave
    }

    public func enter() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        if count == 1 { onFirstEnter() }
    }

    public func leave() {
        lock.lock()
        defer { lock.unlock() }
        guard count > 0 else { return }
        count -= 1
        if count == 0 { onLastLeave() }
    }

    /// Open holds right now.
    public var holds: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    public static func holdProcess() {
        ProcessInfo.processInfo.disableAutomaticTermination(reason)
        ProcessInfo.processInfo.disableSuddenTermination()
    }

    public static func releaseProcess() {
        ProcessInfo.processInfo.enableSuddenTermination()
        ProcessInfo.processInfo.enableAutomaticTermination(reason)
    }
}

/// What `pending <id>` answers for requests of this bridge run: the `pending <id>` payload while a request waits in
/// the background, then its full final payload. The journal keeps the final response too, with message text removed,
/// so a restart still answers. Entries are dropped `retention` after they finish. Thread safe.
final class InFlightRegistry {
    static let retention: TimeInterval = Limits.approvalExpiry + Limits.idempotencyWindow

    private struct Item {
        var pending: ResponsePayload?
        var final: ResponsePayload?
        var finishedAt: Date?
    }

    private let lock = NSLock()
    private var items: [String: Item] = [:]
    private var aliases: [String: String] = [:]

    /// Records that approval `approvalID` belongs to entry `entryID`. Covers the case where the approval book gave the
    /// dialog a new id and the journal couldn't record it.
    func alias(_ approvalID: String, to entryID: String) {
        lock.lock()
        defer { lock.unlock() }
        aliases[approvalID] = entryID
    }

    func entryID(forApproval approvalID: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return aliases[approvalID]
    }

    func setPending(_ entryID: String, _ payload: ResponsePayload) {
        lock.lock()
        defer { lock.unlock() }
        var item = items[entryID] ?? Item()
        guard item.final == nil else { return }
        item.pending = payload
        items[entryID] = item
    }

    func finish(_ entryID: String, _ payload: ResponsePayload, at now: Date) {
        lock.lock()
        defer { lock.unlock() }
        items[entryID] = Item(pending: nil, final: payload, finishedAt: now)
    }

    func pendingPayload(_ entryID: String) -> ResponsePayload? {
        lock.lock()
        defer { lock.unlock() }
        return items[entryID]?.pending
    }

    func finalPayload(_ entryID: String) -> ResponsePayload? {
        lock.lock()
        defer { lock.unlock() }
        return items[entryID]?.final
    }

    func prune(now: Date) {
        lock.lock()
        defer { lock.unlock() }
        items = items.filter { _, item in
            guard let at = item.finishedAt else { return true }
            return now.timeIntervalSince(at) < InFlightRegistry.retention
        }
        aliases = aliases.filter { items[$0.value] != nil }
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return items.count
    }
}

/// `JournalReconciling` over IMSend's correlator, IMUI's verify-only paths and IMForeground's verifier. Reads chat.db
/// only, never presses or sends. Owner: IMBridge.
///
/// Built from `entry.binding` and `entry.facts`, never from text. The chat comes from
/// `db.sendTarget(canonical: binding.chat)`, which also covers a send to a phone or email that had no chat yet; nil
/// gives `may_have_completed`. Each one-pass check repeats until `deadline`,
/// which is an absolute `clock.uptime` value (`Limits.reconcileTimeout` after recovery starts), not a duration.
/// - `send`: `SendCorrelator.matchOnce` with `SendSnapshot(maxRowID: facts.snapshotRowID, requestedAt:
///   entry.receivedAt)` and parts `.textDigest(binding.textDigest)` and `.file(transferName:)` per
///   `facts.transferNames`.
/// - `threadedReply`: `ForegroundVerifying.verifyReply` with that snapshot, `binding.textDigest` and
///   `binding.parentGUID`.
/// - `react`: `TapbackRunner.verifyOnly(targetGUID: facts.targetGUID, part: facts.targetPart,
///   aboveRowID: facts.snapshotRowID, kind: binding.tapback, remove: binding.remove)`.
/// - `unsend`: `UnsendRunner.verifyOnly(rowid: facts.targetRowID)`.
/// - `edit`: `ForegroundVerifying.verifyEdit(rowid: facts.targetRowID, dateEditedBeforeNs:
///   facts.dateEditedBeforeNs, newTextDigest: binding.textDigest)`.
/// - A missing fact or a policy change: `may_have_completed`.
///
/// `reconcileRows` also returns the GUIDs of the rows a send or threaded reply matched, for `agentSentGUIDs`.
public final class ReconcileAdapter: JournalReconciling {
    public let container: BridgeContainer

    /// Gap between chat.db passes while waiting for a row.
    static let pollInterval: TimeInterval = 0.25

    public init(container: BridgeContainer) { self.container = container }

    public func reconcile(_ entry: JournalEntry, deadline: TimeInterval) -> ActionResult {
        reconcileRows(entry, deadline: deadline).result
    }

    public func reconcileRows(_ entry: JournalEntry, deadline: TimeInterval) -> Reconciliation {
        let unknown = Reconciliation(result: ActionResult(.mayHaveCompleted))
        guard !entry.action.isPolicyChange, let facts = entry.facts, let canonical = entry.binding.chat else {
            return unknown
        }
        if container.db == nil { _ = container.openStoreIfNeeded() }
        guard let db = container.db, let chat = try? db.sendTarget(canonical: canonical) else {
            return unknown
        }
        guard let check = makeCheck(entry, facts: facts, chat: chat, db: db) else { return unknown }
        let clock = container.clock
        while true {
            let found = check(max(0, deadline - clock.uptime))
            if found.result.code != .mayHaveCompleted { return found }
            let left = deadline - clock.uptime
            if left <= 0 { return found }
            clock.sleep(min(ReconcileAdapter.pollInterval, left))
        }
    }

    /// One pass for the entry's action, taking the time left. Nil when a fact it needs is missing.
    private func makeCheck(_ entry: JournalEntry, facts: InvocationFacts, chat: ResolvedChat,
                           db: ChatDatabase) -> ((TimeInterval) -> Reconciliation)? {
        let binding = entry.binding
        let clock = container.clock
        switch entry.action {
        case .send:
            guard let snapshotRowID = facts.snapshotRowID else { return nil }
            var parts: [PartExpectation] = []
            if let digest = binding.textDigest { parts.append(.textDigest(digest)) }
            parts += facts.transferNames.map { PartExpectation.file(transferName: $0) }
            guard !parts.isEmpty else { return nil }
            let snapshot = SendSnapshot(maxRowID: snapshotRowID, requestedAt: entry.receivedAt)
            let correlator = container.sender?.correlator ?? SendCorrelator(rows: db, clock: clock)
            return { _ in
                let matched = correlator.matchOnce(snapshot: snapshot, chat: chat, parts: parts)
                var guids: [String] = []
                for guid in matched.compactMap({ $0.row?.guid }) where !guids.contains(guid) { guids.append(guid) }
                return Reconciliation(result: ReconcileAdapter.combine(matched.map(\.result)), sentGUIDs: guids)
            }
        case .threadedReply:
            guard let snapshotRowID = facts.snapshotRowID, let digest = binding.textDigest,
                  let parent = binding.parentGUID else { return nil }
            let snapshot = SendSnapshot(maxRowID: snapshotRowID, requestedAt: entry.receivedAt)
            let verifier = self.verifier(db: db)
            return { left in
                let reply = verifier.verifyReplyRow(snapshot: snapshot, chat: chat, textDigest: digest,
                                                    parentGUID: parent, timeout: left)
                return Reconciliation(result: reply.result, sentGUIDs: reply.rowGUID.map { [$0] } ?? [])
            }
        case .edit:
            guard let rowid = facts.targetRowID, let before = facts.dateEditedBeforeNs,
                  let digest = binding.textDigest else { return nil }
            let verifier = self.verifier(db: db)
            return { left in
                Reconciliation(result: verifier.verifyEdit(rowid: rowid, dateEditedBeforeNs: before,
                                                           newTextDigest: digest, timeout: left))
            }
        case .react:
            guard let guid = facts.targetGUID, let part = facts.targetPart, let above = facts.snapshotRowID,
                  let kind = binding.tapback, let runner = container.tapbacks else { return nil }
            return { _ in
                Reconciliation(result: runner.verifyOnly(targetGUID: guid, part: part, aboveRowID: above, kind: kind,
                                                         remove: binding.remove))
            }
        case .unsend:
            guard let rowid = facts.targetRowID, let runner = container.unsend else { return nil }
            return { _ in Reconciliation(result: runner.verifyOnly(rowid: rowid)) }
        case .allowChat, .revokeChat, .foregroundOn, .foregroundOff:
            return nil
        }
    }

    private func verifier(db: ChatDatabase) -> ForegroundVerifying {
        if let machine = container.foreground { return machine.env.verifier }
        let clock = container.clock
        return LiveForegroundVerifier(source: db, correlator: SendCorrelator(rows: db, clock: clock), clock: clock)
    }

    /// One result for a send's parts: any part still unknown makes the whole send unknown, then a failed part, then
    /// an ambiguous one, else the first part's result.
    static func combine(_ results: [ActionResult]) -> ActionResult {
        guard let first = results.first else { return ActionResult(.mayHaveCompleted) }
        if results.contains(where: { $0.code == .mayHaveCompleted }) { return ActionResult(.mayHaveCompleted) }
        if let failed = results.first(where: { if case .failed = $0.code { return true } else { return false } }) {
            return failed
        }
        if let ambiguous = results.first(where: { if case .ambiguous = $0.code { return true } else { return false } }) {
            return ambiguous
        }
        return first
    }
}
