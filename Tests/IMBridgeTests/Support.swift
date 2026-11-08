import Foundation
import SQLite3
import XCTest
@testable import IMBridge
import IMCore
import IMForeground
import IMPolicy
import IMSend
import IMStore
import IMTestSupport
import IMUI

// Test doubles for the bridge. Nothing here sends Apple Events, touches Messages, opens ~/Library/Messages, reads a
// keychain or posts events. Every store is a private copy of Tests/Fixtures/chat.db.

/// Virtual time shared by every thread. `sleep` moves time forward at once, runs the hooks, then pauses briefly in
/// real time so a thread polling in a loop lets the others run.
final class TestClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var currentNow: Date
    private var currentUptime: TimeInterval
    private var hooks: [(TestClock) -> Void] = []
    let realPause: TimeInterval

    init(now: Date = Fixture.now, uptime: TimeInterval = 1000, realPause: TimeInterval = 0.0002) {
        currentNow = now
        currentUptime = uptime
        self.realPause = realPause
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return currentNow
    }

    var uptime: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return currentUptime
    }

    func sleep(_ seconds: TimeInterval) {
        advance(seconds.isFinite ? max(0, seconds) : 0)
        lock.lock()
        let hooks = self.hooks
        lock.unlock()
        for hook in hooks { hook(self) }
        if realPause > 0 { Thread.sleep(forTimeInterval: realPause) }
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        currentNow = currentNow.addingTimeInterval(seconds)
        currentUptime += seconds
        lock.unlock()
    }

    func onSleep(_ hook: @escaping (TestClock) -> Void) {
        lock.lock()
        hooks.append(hook)
        lock.unlock()
    }
}

/// Answers each dialog by plan. A planned decision fires during the first clock sleep at or after its time, so it
/// lands inside `ApprovalBook.wait`. `.hold` keeps the callback for `decide(_:_:)`.
final class ScriptedPresenter: ApprovalPresenting {
    enum Plan {
        case decide(ApprovalDecision, after: TimeInterval)
        case hold
    }

    private struct Due {
        var id: String
        var at: TimeInterval
        var decision: ApprovalDecision
        var decided: (ApprovalDecision) -> Void
    }

    private let lock = NSLock()
    private let clock: TestClock
    private var plans: [Plan] = []
    private var due: [Due] = []
    private var held: [String: (ApprovalDecision) -> Void] = [:]
    private var shown: [ApprovalPrompt] = []
    private var gone: [String] = []
    var defaultPlan: Plan

    init(clock: TestClock, plan: Plan = .decide(.allowOnce, after: 1.5)) {
        self.clock = clock
        self.defaultPlan = plan
        clock.onSleep { [weak self] c in self?.fire(at: c.uptime) }
    }

    /// Plans for the next dialogs, in order. After they run out, `defaultPlan`.
    func queue(_ plans: Plan...) {
        lock.lock()
        self.plans += plans
        lock.unlock()
    }

    var prompts: [ApprovalPrompt] {
        lock.lock()
        defer { lock.unlock() }
        return shown
    }

    var withdrawn: [String] {
        lock.lock()
        defer { lock.unlock() }
        return gone
    }

    func present(_ prompt: ApprovalPrompt, decided: @escaping (ApprovalDecision) -> Void) {
        lock.lock()
        shown.append(prompt)
        let plan = plans.isEmpty ? defaultPlan : plans.removeFirst()
        switch plan {
        case .decide(let decision, let after):
            due.append(Due(id: prompt.id, at: clock.uptime + after, decision: decision, decided: decided))
        case .hold:
            held[prompt.id] = decided
        }
        lock.unlock()
    }

    func withdraw(id: String) {
        lock.lock()
        gone.append(id)
        lock.unlock()
    }

    /// Answers a held dialog now.
    func decide(_ id: String, _ decision: ApprovalDecision) {
        lock.lock()
        let callback = held.removeValue(forKey: id)
        lock.unlock()
        callback?(decision)
    }

    private func fire(at uptime: TimeInterval) {
        lock.lock()
        let ready = due.filter { $0.at <= uptime }
        due.removeAll { $0.at <= uptime }
        lock.unlock()
        for item in ready { item.decided(item.decision) }
    }
}

final class InMemoryKeychain: KeychainHashStoring {
    private let lock = NSLock()
    private var hash: Data?

    func readHash() throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return hash
    }

    func writeHash(_ hash: Data) throws {
        lock.lock()
        self.hash = hash
        lock.unlock()
    }

    func deleteHash() throws {
        lock.lock()
        hash = nil
        lock.unlock()
    }
}

/// Records every TCC call. Never raises a prompt or opens a pane.
final class RecordingPermissions: PermissionProbing {
    enum Call: Hashable {
        case fullDiskAccess
        case automation(ask: Bool)
        case silentAutomation
        case accessibility(prompt: Bool)
        case openPane
    }

    private let lock = NSLock()
    private var log: [Call] = []
    var fullDiskAccessState: PermissionState = .granted
    var automationState: PermissionState = .granted
    /// The silent check finds Messages closed (`procNotFound`), whatever `automationState` says.
    var messagesClosed = false
    var accessibilityState: PermissionState = .granted
    var paneURL: String? = "x-apple.systempreferences:test-pane"

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return log
    }

    private func record(_ call: Call) {
        lock.lock()
        log.append(call)
        lock.unlock()
    }

    func fullDiskAccess() -> PermissionState { record(.fullDiskAccess); return fullDiskAccessState }
    func automation(ask: Bool) -> PermissionState { record(.automation(ask: ask)); return automationState }
    func silentAutomation() -> SilentAutomation {
        record(.silentAutomation)
        return messagesClosed ? .messagesClosed : .answered(automationState)
    }
    func accessibility(prompt: Bool) -> PermissionState { record(.accessibility(prompt: prompt)); return accessibilityState }
    func openFullDiskAccessPane() -> String? { record(.openPane); return paneURL }
}

/// Messages running hidden with its one window, unless a test changes `state`. Thread safe.
final class SafeMessagesApp: MessagesAppControl {
    static let hiddenReady = MessagesAppState(isRunning: true, pid: 4242, isFrontmost: false, isHidden: true,
                                              axWindowCount: 1, onScreenWindowCount: 0, allSpacesWindowCount: 1)
    private let lock = NSLock()
    private var current: MessagesAppState
    private var log: [String] = []

    init(state: MessagesAppState = SafeMessagesApp.hiddenReady) { current = state }

    var state_: MessagesAppState {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set { lock.lock(); current = newValue; lock.unlock() }
    }

    var calls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return log
    }

    private func record(_ call: String) {
        lock.lock()
        log.append(call)
        lock.unlock()
    }

    func state() -> MessagesAppState { state_ }
    func launchHidden() -> Bool { record("launchHidden"); return false }
    func quit() -> Bool { record("quit"); return false }
    func waitForExit(timeout: TimeInterval) -> Bool { record("waitForExit"); return false }
    func activateForeground() -> Bool { record("activateForeground"); return false }
    func hide() { record("hide") }
    func frontmostApp() -> FrontApp? { nil }
    func reopen(bundleID: String) -> Bool { record("reopen"); return false }
}

/// An AX tree with the given bubbles. `onPerform` runs for each named action, after it is recorded.
/// `beforeFinalCheck` runs where the driver reads the bubble before the press's final check, and `performError` is
/// thrown after the press, as an error from `AXUIElementPerformAction`.
final class FakeAX: MessagesAXDriving {
    private let lock = NSLock()
    private var bubbleList: [BubbleInfo] = []
    private var actions: [String] = []
    var onPerform: ((String) -> Void)?
    var bubblesError: Error?
    var beforeFinalCheck: (() -> Void)?
    var performError: Error?

    var bubbles: [BubbleInfo] {
        get { lock.lock(); defer { lock.unlock() }; return bubbleList }
        set { lock.lock(); bubbleList = newValue; lock.unlock() }
    }

    var performed: [String] {
        lock.lock()
        defer { lock.unlock() }
        return actions
    }

    func windowCount() throws -> Int { 1 }
    func conversationRows() throws -> [ConversationRowInfo] { [] }
    func conversationListState() throws -> ConversationListState { .loaded }
    func press(row: AXRef, finalCheck: AXFinalCheck) throws {
        try finalCheck()
    }
    func loadedBubbles() throws -> [BubbleInfo] {
        if let bubblesError { throw bubblesError }
        return bubbles
    }
    func perform(action: String, on bubble: AXRef, finalCheck: AXFinalCheck) throws {
        beforeFinalCheck?()
        try finalCheck()
        lock.lock()
        actions.append(action)
        lock.unlock()
        onPerform?(action)
        if let performError { throw performError }
    }
    func composer() throws -> FieldInfo? { nil }
    func editField() throws -> FieldInfo? { nil }
    func focusedField() throws -> FieldInfo? { nil }
    func threadView() throws -> ThreadViewInfo? { nil }
    func showsMainTranscript() throws -> Bool { true }
    func menuItem(titled title: String) throws -> MenuItemInfo? { nil }
    func press(menuItem: AXRef, finalCheck: AXFinalCheck) throws {
        try finalCheck()
    }
    func setValue(_ value: String, of field: AXRef, finalCheck: AXFinalCheck) throws {
        try finalCheck()
    }
    func readValue(of field: AXRef) throws -> String { "" }
}

/// Selects every chat and finds one bubble that offers every allowed action, unless a test changes them.
final class FakeTargeting: ChatTargeting {
    static let fullBubble = BubbleInfo(ref: AXRef(id: 1), fromMe: false, text: "", minuteLabel: "", hasTextBubble: true,
                                       actionNames: UINames.classicTapbacks + [UINames.undoSend, UINames.edit])
    private let lock = NSLock()
    private var selections: [String] = []
    var selection: ChatSelection = .selected
    var bubble: BubbleLookup = .found(FakeTargeting.fullBubble)

    var selected: [String] {
        lock.lock()
        defer { lock.unlock() }
        return selections
    }

    func selectChat(_ chat: ResolvedChat) -> ChatSelection {
        lock.lock()
        selections.append(chat.label)
        lock.unlock()
        return selection
    }

    func verifySelected(_ chat: ResolvedChat, excluding rowid: Int64?) -> Bool { true }
    func selectionExpectation(_ chat: ResolvedChat, excluding rowid: Int64?) -> SelectionExpectation? {
        SelectionExpectation(chat: chat, signature: [], bound: nil)
    }
    func verifySelected(_ expected: SelectionExpectation) -> Bool { true }
    func findBubble(_ target: MessageTargetInfo) -> BubbleLookup { bubble }
    func findLoadedBubble(_ target: MessageTargetInfo) -> BubbleLookup { bubble }
}

/// Reports a fixed idle time and runs `onRead` before each reading.
final class FakeInput: InputMonitoring {
    var idle: TimeInterval
    var onRead: (() -> Void)?

    init(idle: TimeInterval = 100) { self.idle = idle }

    func secondsSinceLastInput() -> TimeInterval {
        onRead?()
        return idle
    }
}

final class FakeKeys: KeyPosting {
    private let lock = NSLock()
    private var log: [ForegroundKey] = []

    var posted: [ForegroundKey] {
        lock.lock()
        defer { lock.unlock() }
        return log
    }

    func post(_ key: ForegroundKey, toPID pid: Int32) -> Bool {
        lock.lock()
        log.append(key)
        lock.unlock()
        return true
    }
}

/// Counts callers waiting in `acquire`, so a test can release the queue once every request is waiting.
final class CountingQueue: ActionQueueing {
    let inner: ActionQueueing
    private let lock = NSLock()
    private var waiting = 0
    private var acquired = 0

    init(_ inner: ActionQueueing) { self.inner = inner }

    var waiters: Int {
        lock.lock()
        defer { lock.unlock() }
        return waiting
    }

    var acquisitions: Int {
        lock.lock()
        defer { lock.unlock() }
        return acquired
    }

    func acquire(timeout: TimeInterval) -> QueueTicket? {
        lock.lock()
        waiting += 1
        lock.unlock()
        let ticket = inner.acquire(timeout: timeout)
        lock.lock()
        waiting -= 1
        if ticket != nil { acquired += 1 }
        lock.unlock()
        return ticket
    }

    func release(_ ticket: QueueTicket) { inner.release(ticket) }
    var isHeld: Bool { inner.isHeld }
}

enum TempDir {
    static func make(_ prefix: String = "imbridge-tests") -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(prefix + "-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// A writable copy of the fixture database. Triggers are dropped because they call functions that exist only inside
/// Messages.
final class FixtureCopy {
    let dir: URL
    let path: String
    private let lock = NSLock()

    init() throws {
        dir = TempDir.make("imbridge-db")
        path = dir.appendingPathComponent("chat.db").path
        try FileManager.default.copyItem(atPath: Fixture.chatDB.path, toPath: path)
        let names = try strings("SELECT name FROM sqlite_master WHERE type = 'trigger'")
        for name in names { try exec("DROP TRIGGER \"\(name)\"") }
    }

    func exec(_ sql: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw StoreError.sqlite(code: 0, message: "open")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let message = err.map { String(cString: $0) } ?? "exec"
            sqlite3_free(err)
            throw StoreError.sqlite(code: 1, message: message)
        }
    }

    func strings(_ sql: String) throws -> [String] {
        lock.lock()
        defer { lock.unlock() }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw StoreError.sqlite(code: 0, message: "open")
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.sqlite(code: 2, message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "")
        }
        return out
    }

    func int(_ sql: String) throws -> Int64 {
        Int64(try strings(sql).first ?? "") ?? 0
    }

    static func quote(_ s: String?) -> String {
        s.map { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" } ?? "NULL"
    }

    /// A message joined to `chat`. Dates are Apple nanoseconds.
    func insertMessage(rowid: Int64, guid: String, chat: Int64 = 7, handle: Int64 = 3, text: String?, fromMe: Bool,
                       date: AppleNanos, delivered: Bool = true, associatedType: Int = 0,
                       associatedGUID: String? = nil, threadOriginator: String? = nil,
                       service: String = "iMessage") throws {
        let deliveredNs = fromMe && delivered ? date : 0
        try exec("""
            INSERT INTO message (ROWID, guid, text, handle_id, service, date, is_from_me, is_read, is_sent,
                is_delivered, date_delivered, item_type, associated_message_type, associated_message_guid,
                thread_originator_guid)
            VALUES (\(rowid), '\(guid)', \(FixtureCopy.quote(text)), \(handle), \(FixtureCopy.quote(service)), \(date),
                \(fromMe ? 1 : 0),
                1, \(fromMe ? 1 : 0), \(deliveredNs > 0 ? 1 : 0), \(deliveredNs), 0, \(associatedType),
                \(FixtureCopy.quote(associatedGUID)), \(FixtureCopy.quote(threadOriginator)));
            INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (\(chat), \(rowid), \(date));
            """)
    }

    /// The 1:1 chat Messages makes on the first send to a handle it has no chat for, with the handle's row on
    /// `service`. Running it again changes nothing.
    func insertDirectChat(rowid: Int64, handleRowID: Int64, handle: String, service: String) throws {
        try exec("""
            INSERT OR IGNORE INTO handle (ROWID, id, service) VALUES (\(handleRowID), \(FixtureCopy.quote(handle)),
                \(FixtureCopy.quote(service)));
            INSERT OR IGNORE INTO chat (ROWID, guid, style, chat_identifier, service_name, display_name, account_login,
                last_addressed_handle) VALUES (\(rowid), \(FixtureCopy.quote(service + ";-;" + handle)), 45,
                \(FixtureCopy.quote(handle)), \(FixtureCopy.quote(service)), '', 'P:+14155550100', '+14155550100');
            INSERT OR IGNORE INTO chat_handle_join (chat_id, handle_id) VALUES (\(rowid), \(handleRowID));
            """)
    }

    /// A from_me row with one attachment whose transfer name is `transferName`.
    func insertFileMessage(rowid: Int64, guid: String, chat: Int64 = 7, handle: Int64 = 3, transferName: String,
                           date: AppleNanos) throws {
        try insertMessage(rowid: rowid, guid: guid, chat: chat, handle: handle, text: nil, fromMe: true, date: date)
        let attachment = 90_000 + rowid
        try exec("""
            INSERT INTO attachment (ROWID, guid, original_guid, filename, transfer_name, transfer_state, is_outgoing,
                total_bytes) VALUES (\(attachment), 'AT-\(guid)', 'AT-\(guid)', '/tmp/\(transferName)',
                \(FixtureCopy.quote(transferName)), 5, 1, 4);
            INSERT INTO message_attachment_join (message_id, attachment_id) VALUES (\(rowid), \(attachment));
            """)
    }
}

/// Plays Messages for `send_text` and `send_file`: each call adds a delivered from_me row for Mom (handle 3, chat 7)
/// to the fixture copy, dated now. `send_chat_text` and `send_chat_file` to the Family group add one joined to chat 12.
/// A `send_text` to an address in `newChats` makes that address's chat first, as Messages does on a first send, and
/// its row joins that chat, on the service the call named (an SMS row is never delivered). Nothing is sent anywhere.
final class SendingScripts: AppleScriptRunning {
    let copy: FixtureCopy
    let clock: Clock
    private let lock = NSLock()
    private var log: [(ScriptHandler, [String])] = []
    private var next: Int64 = 50_000
    private var fresh: [String: (chat: Int64, handle: Int64)] = [:]
    private var hook: ((ScriptHandler) -> Void)?
    var writesRows = true

    /// Runs at the start of each call, before any row is written, so a test can hold a send at `invoking`.
    var onCall: ((ScriptHandler) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return hook }
        set { lock.lock(); hook = newValue; lock.unlock() }
    }

    /// Addresses with no chat yet: the chat ROWID and handle ROWID Messages gives each on its first send.
    var newChats: [String: (chat: Int64, handle: Int64)] {
        get { lock.lock(); defer { lock.unlock() }; return fresh }
        set { lock.lock(); fresh = newValue; lock.unlock() }
    }

    init(copy: FixtureCopy, clock: Clock) {
        self.copy = copy
        self.clock = clock
    }

    var calls: [(ScriptHandler, [String])] {
        lock.lock()
        defer { lock.unlock() }
        return log
    }

    var sentTexts: [String] { calls.filter { $0.0 == .sendText }.map { $0.1[1] } }

    /// The fixture's Family group (chat 12).
    static let familyGUID = "any;+;chat836828054889214904"

    func call(_ handler: ScriptHandler, arguments: [String]) -> AppleScriptOutcome {
        lock.lock()
        log.append((handler, arguments))
        let rowid = next
        next += 1
        let writes = writesRows
        let newChat = handler == .sendText ? fresh[arguments[0]] : nil
        let hook = self.hook
        lock.unlock()
        hook?(handler)
        guard writes else { return AppleScriptOutcome(ok: true) }
        let now = AppleTime.nanos(from: clock.now)
        switch handler {
        case .sendText:
            if let newChat {
                let service = arguments[2] == "SMS" ? "SMS" : "iMessage"
                try? copy.insertDirectChat(rowid: newChat.chat, handleRowID: newChat.handle, handle: arguments[0],
                                           service: service)
                try? copy.insertMessage(rowid: rowid, guid: "SENT-\(rowid)", chat: newChat.chat,
                                        handle: newChat.handle, text: arguments[1], fromMe: true, date: now,
                                        delivered: service != "SMS", service: service)
            } else {
                try? copy.insertMessage(rowid: rowid, guid: "SENT-\(rowid)", text: arguments[1], fromMe: true,
                                        date: now)
            }
        case .sendFile:
            let name = URL(fileURLWithPath: arguments[1]).lastPathComponent
            try? copy.insertFileMessage(rowid: rowid, guid: "SENT-\(rowid)", transferName: name, date: now)
        case .sendChatText where arguments[0] == SendingScripts.familyGUID:
            // A group's from_me row has handle 0, joined to the Family chat (12).
            try? copy.insertMessage(rowid: rowid, guid: "SENT-\(rowid)", chat: 12, handle: 0, text: arguments[1],
                                    fromMe: true, date: now)
        case .sendChatFile where arguments[0] == SendingScripts.familyGUID:
            let name = URL(fileURLWithPath: arguments[1]).lastPathComponent
            try? copy.insertFileMessage(rowid: rowid, guid: "SENT-\(rowid)", chat: 12, handle: 0, transferName: name,
                                        date: now)
        case .sendChatText, .sendChatFile, .quitMessages, .accountReady:
            break
        }
        return AppleScriptOutcome(ok: true)
    }
}

/// Release evidence for the running macOS, so the listed capabilities and their prerequisites are `supported`.
enum Evidence {
    static func write(_ capabilities: [Capability], to dir: URL) throws -> URL {
        let version = CapabilityRegistry.currentMajorMinor()
        var all: [Capability] = []
        for capability in capabilities {
            for needed in capability.prerequisites + [capability] where !all.contains(needed) { all.append(needed) }
        }
        let records = all.flatMap { capability in
            capability.releaseTests.map {
                EvidenceRecord(macOS: version, capability: capability.name, releaseTest: $0, passedAt: Fixture.now,
                               bridgeVersion: AppIdentity.version)
            }
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let url = dir.appendingPathComponent("release-evidence-\(UUID().uuidString).json")
        try encoder.encode(records).write(to: url)
        return url
    }
}

/// Upload bytes held in memory, read the way `ConnectionUpload` reads them.
final class DataUpload: UploadReading {
    let data: Data
    private(set) var offset = 0

    init(_ data: Data) { self.data = data }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        let n = min(buffer.count, data.count - offset)
        guard n > 0 else { return 0 }
        data.withUnsafeBytes { src in
            buffer.baseAddress!.copyMemory(from: src.baseAddress! + offset, byteCount: n)
        }
        offset += n
        return n
    }
}

/// Collects events from any thread.
final class EventLog {
    private let lock = NSLock()
    private var items: [BridgeEvent] = []

    var events: [BridgeEvent] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }

    func add(_ event: BridgeEvent) {
        lock.lock()
        items.append(event)
        lock.unlock()
    }
}

/// The fixture's people plus a second Sam, so "Sam" matches two contacts.
enum TwoSams {
    static func contactsFile() throws -> URL {
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: Fixture.contactsJSON)) as! [String: Any]
        var people = json["people"] as! [[String: Any]]
        people.append(["first": "Sam", "last": "Ortiz", "handles": ["+14155550104"]])
        json["people"] = people
        let url = TempDir.make("imbridge-contacts").appendingPathComponent("contacts.json")
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        return url
    }
}

/// Mom's chat in the fixture: chat 7, handle 3.
enum Mom {
    static let who = "Mom"
    static let chatRowID: Int64 = 7
    static let handleRowID: Int64 = 3
}

/// A container over a private fixture copy and fakes, built through the memberwise init. `Paths(home:)` points at a
/// temp folder, so the journal, policy file, uploads and staging never touch the real home folder.
final class Harness {
    struct Options {
        var capabilities: [Capability] = Capability.reported
        /// Open the database in the harness and inject the hidden-action runners. False leaves chat.db for
        /// `openStoreIfNeeded`.
        var injectStore = true
        /// Build a foreground machine over the fakes.
        var foreground = false
        /// The queue's clock. Nil uses the harness clock.
        var queueClock: Clock?
        var plan: ScriptedPresenter.Plan = .decide(.allowOnce, after: 1.5)
        var home: URL?
        var copy: FixtureCopy?
        var chatDBPath: String?
        var contacts: URL = Fixture.contactsJSON
        /// The Mac's region for target resolution. `US` unless a test sets it, so results never depend on the Mac
        /// running the tests.
        var regionCode: String? = "US"
    }

    let home: URL
    let copy: FixtureCopy
    let clock: TestClock
    let presenter: ScriptedPresenter
    let permissions = RecordingPermissions()
    let keychain: InMemoryKeychain
    let app = SafeMessagesApp()
    let ax = FakeAX()
    let targeting = FakeTargeting()
    let input = FakeInput()
    let keys = FakeKeys()
    let scripts: SendingScripts
    let queue: CountingQueue
    let policy: PolicyStore
    let journal: Journal
    let activity: DeferredActivitySource
    let container: BridgeContainer
    let dispatcher: OpDispatcher

    init(_ options: Options = Options(), clock: TestClock = TestClock(), keychain: InMemoryKeychain = InMemoryKeychain()) throws {
        self.clock = clock
        self.keychain = keychain
        home = options.home ?? TempDir.make("imbridge-home")
        copy = try options.copy ?? FixtureCopy()
        let paths = Paths(home: home)
        let store = StoreConfiguration(chatDBPath: options.chatDBPath ?? copy.path, attachmentsRoot: Fixture.attachmentsRoot,
                                       attachmentCacheDir: home.appendingPathComponent("cache", isDirectory: true),
                                       timeZone: Fixture.timeZone, regionCode: options.regionCode)
        presenter = ScriptedPresenter(clock: clock, plan: options.plan)
        scripts = SendingScripts(copy: copy, clock: clock)
        queue = CountingQueue(ActionQueue(clock: options.queueClock ?? clock))
        policy = PolicyStore(fileURL: paths.policyStoreURL, keychain: keychain)
        journal = try Journal(directory: paths.journalDir, clock: clock)
        activity = DeferredActivitySource()
        let limiter = RateLimiter(clock: clock, activity: activity, ownAddresses: activity.ownAddresses,
                                  history: journal.sendEvents())
        let engine = PolicyEngine(store: policy, limiter: limiter, clock: clock)
        let approvals = ApprovalBook(clock: clock, presenter: presenter)
        let capabilities = CapabilityRegistry(evidenceURL: try Evidence.write(options.capabilities, to: home),
                                              macOSVersion: CapabilityRegistry.currentMajorMinor(),
                                              uiLanguageEnglish: true, locale: Locale(identifier: "en_US"))

        var db: ChatDatabase?
        var tapbacks: TapbackRunner?
        var unsend: UnsendRunner?
        var foreground: ForegroundMachine?
        if options.injectStore {
            let database = try ChatDatabase(configuration: store, contacts: ContactBook(source: JSONContacts(url: options.contacts)),
                                            clock: clock)
            let windows = HiddenWindowManager(app: app, ax: ax, transfers: FakePendingTransfers(), clock: clock)
            tapbacks = TapbackRunner(ax: ax, windows: windows, targeting: targeting, source: database, clock: clock)
            unsend = UnsendRunner(ax: ax, windows: windows, targeting: targeting, source: database, clock: clock)
            if options.foreground {
                let verifier = LiveForegroundVerifier(source: database, correlator: SendCorrelator(rows: database, clock: clock),
                                                      clock: clock)
                let env = ForegroundEnvironment(clock: clock, input: input, app: app, ax: ax, keys: keys, verifier: verifier,
                                                queue: queue, targeting: targeting, windows: windows, source: database,
                                                rows: database, mode: policy, progress: { _ in })
                foreground = ForegroundMachine(env: env)
            }
            db = database
        }
        container = BridgeContainer(
            paths: paths, clock: clock, store: store, permissions: permissions, db: db,
            reads: db.map { ReadService(db: $0) }, attachments: db.map { AttachmentService(db: $0, clock: clock) },
            policy: policy, engine: engine, approvals: approvals, journal: journal, queue: queue, scripts: scripts,
            app: app, ax: ax, capabilities: capabilities, sender: nil, tapbacks: tapbacks, unsend: unsend,
            foreground: foreground)
        container.contactsSource = JSONContacts(url: options.contacts)
        activity.container = container
        dispatcher = OpDispatcher(container: container)
    }

    /// One request through the dispatcher, the way a connection thread calls it.
    @discardableResult
    func call(_ body: RequestBody, upload: Data? = nil, fileName: String = "note.txt", events: EventLog = EventLog(),
              id: String = UUID().uuidString) -> ResponsePayload {
        let header = upload.map { UploadHeader(byteCount: Int64($0.count), fileName: fileName) }
        let request = Request(id: id, body: body, upload: header)
        let response = dispatcher.handle(request, upload: upload.map { DataUpload($0) }, events: events.add)
        XCTAssertEqual(response.id, id)
        return response.payload
    }

    func send(_ text: String?, to who: String = Mom.who, again: Bool = false, thread: Bool = false,
              approvalWait: TimeInterval = 120, file: Data? = nil, fileName: String = "note.txt",
              events: EventLog = EventLog()) -> ResponsePayload {
        call(.send(SendArgs(who: who, text: text, again: again, thread: thread, approvalWait: approvalWait)),
             upload: file, fileName: fileName, events: events)
    }

    /// Mom on the allowlist, as after an earlier "Always allow".
    func allowMom(scope: AllowScope = .text) throws {
        let mom = try XCTUnwrap(container.db).resolve(Mom.who)
        try policy.allow(mom.canonical, label: mom.label, scope: scope)
    }

    func waitUntilIdle(timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) {
        let end = Date().addingTimeInterval(timeout)
        while container.residency.holds > 0, Date() < end { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertEqual(container.residency.holds, 0, "a background approval is still open", file: file, line: line)
    }

    var messageCount: Int64 { (try? copy.int("SELECT COUNT(*) FROM message")) ?? -1 }
}

/// The parts of a payload tests look at.
extension ResponsePayload {
    var sendOutcome: SendOutcome? { if case .send(let o) = self { return o } else { return nil } }
    var uiOutcome: UIOutcome? { if case .ui(let o) = self { return o } else { return nil } }
    var policyOutcome: PolicyOutcome? { if case .policy(let o) = self { return o } else { return nil } }
    var failure: WireError? { if case .failure(let e) = self { return e } else { return nil } }

    /// The result a CLI line starts with: the early result, else the first part's.
    var headline: ResultCode? {
        switch self {
        case .send(let o): return o.early?.code ?? o.parts.first?.result.code
        case .ui(let o): return o.result.code
        case .policy(let o): return o.result.code
        case .failure(let e): return e.result.code
        default: return nil
        }
    }
}

extension Harness {
    /// Mom as the pipeline resolves her.
    func mom() throws -> ResolvedChat { try XCTUnwrap(container.db).resolve(Mom.who) }

    /// The next clock sleep on any thread moves time forward by `seconds`, once. A test reaches an approval's expiry
    /// this way without polling through ten virtual minutes.
    func jumpOnNextSleep(_ seconds: TimeInterval) {
        let lock = NSLock()
        var done = false
        clock.onSleep { c in
            lock.lock()
            let go = !done
            done = true
            lock.unlock()
            if go { c.advance(seconds) }
        }
    }

    /// A from_me text row in Mom's chat, `age` seconds old.
    @discardableResult
    func insertOwnMessage(_ rowid: Int64, text: String, age: TimeInterval) throws -> Int64 {
        let date = AppleTime.nanos(from: clock.now.addingTimeInterval(-age))
        try copy.insertMessage(rowid: rowid, guid: "OWN-\(rowid)", text: text, fromMe: true, date: date)
        return rowid
    }

    /// Files left in the uploads folder.
    var uploadFiles: [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: container.uploads.directory.path)) ?? []
    }

    /// The single journal entry, failing the test if there isn't exactly one.
    func onlyEntry(file: StaticString = #filePath, line: UInt = #line) throws -> JournalEntry {
        let all = journal.allEntries()
        XCTAssertEqual(all.count, 1, file: file, line: line)
        return try XCTUnwrap(all.first, file: file, line: line)
    }
}

/// A fixture photo, for the image-send gate.
enum Photo {
    static var heic: URL {
        Fixture.attachmentsRoot.appendingPathComponent("49/08/4C65644D-297F-4373-9EB1-3DE53FF3C98D/IMG_2439.HEIC")
    }
}

/// Polls `condition` in real time. For lining up threads, never for virtual time.
func eventually(_ timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.002)
    }
    return condition()
}
