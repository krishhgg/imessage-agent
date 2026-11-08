import Foundation
import XCTest
@testable import IMForeground
import IMCore
import IMPolicy
import IMSend
import IMStore
import IMUI
import IMTestSupport

// Fakes for every protocol the machine touches, all driven by one `FakeClock`, plus a `Harness` that wires them and
// keeps one ordered event log. None of them posts events, runs AX or touches Messages.

enum Event: Hashable {
    case input
    case progress(BridgeEvent)
    case acquire(TimeInterval)
    case release
    case ensureHidden
    case selectChat
    case findBubble
    case verifySelected
    case activate
    /// `ActivationEnding.endActivation`, on an app that has it.
    case endActivation
    case hide
    case reopen(String)
    case perform(String)
    case pressMenu
    case setValue(String)
    case readValue
    case readTranscript
    case key(ForegroundKey)
    case willInvoke
    case didInvoke
    case modeOff(String)
    case verify
    /// A release-test marker (`ForegroundEnvironment.marker`).
    case marker(String)
}

final class EventLog {
    private(set) var events: [Event] = []
    /// Runs after each event is recorded. Tests inject input here at a chosen point.
    var onEvent: ((Event) -> Void)?

    func add(_ event: Event) {
        events.append(event)
        onEvent?(event)
    }

    func count(_ event: Event) -> Int { events.filter { $0 == event }.count }

    func index(of event: Event) -> Int? { events.firstIndex(of: event) }

    /// Events after the first injected input.
    var afterInput: [Event] {
        guard let i = events.firstIndex(of: .input) else { return [] }
        return Array(events[(i + 1)...])
    }

    var keys: [ForegroundKey] {
        events.compactMap { if case .key(let key) = $0 { return key } else { return nil } }
    }

    var writes: [String] {
        events.compactMap { if case .setValue(let value) = $0 { return value } else { return nil } }
    }

    var acquireTimeouts: [TimeInterval] {
        events.compactMap { if case .acquire(let timeout) = $0 { return timeout } else { return nil } }
    }

    var markers: [String] {
        events.compactMap { if case .marker(let marker) = $0 { return marker } else { return nil } }
    }
}

/// Input as uptimes. `secondsSinceLastInput` is the time since the latest one at or before now.
final class FakeInput: InputMonitoring {
    let clock: FakeClock
    let log: EventLog
    var inputs: [TimeInterval]
    /// Overrides the computed reading, for NaN and negative values.
    var reading: TimeInterval?
    var onRead: (() -> Void)?

    init(clock: FakeClock, log: EventLog, idleFor seconds: TimeInterval = 100) {
        self.clock = clock
        self.log = log
        self.inputs = [clock.uptime - seconds]
    }

    func secondsSinceLastInput() -> TimeInterval {
        onRead?()
        if let reading { return reading }
        let last = inputs.filter { $0 <= clock.uptime }.max() ?? -.infinity
        return clock.uptime - last
    }

    /// User input right now.
    func inject() {
        inputs.append(clock.uptime)
        log.add(.input)
    }
}

final class RecordingKeys: KeyPosting {
    let log: EventLog
    /// Keys whose post fails.
    var refused: Set<ForegroundKey> = []
    private(set) var pids: [Int32] = []
    var onPost: ((ForegroundKey) -> Void)?

    init(log: EventLog) { self.log = log }

    func post(_ key: ForegroundKey, toPID pid: Int32) -> Bool {
        guard !refused.contains(key) else { return false }
        pids.append(pid)
        log.add(.key(key))
        onPost?(key)
        return true
    }
}

/// One Messages window as AX shows it: the main composer, one edit field, one thread view with its own field, and
/// the Reply to Last Message… menu item. `composer()` is always the main composer, as `LiveMessagesAX` finds it, and
/// the thread's field is reachable only as the focused field.
final class ScriptedAX: MessagesAXDriving {
    struct Failure: Error {}

    static let composerRef = AXRef(id: 1)
    static let editRef = AXRef(id: 2)
    static let threadComposerRef = AXRef(id: 3)
    static let threadRef = AXRef(id: 4)
    static let menuRef = AXRef(id: 5)

    let clock: FakeClock
    let log: EventLog

    var values: [AXRef: String] = [composerRef: ""]
    var hasComposer = true
    var editOpen = false
    var editOwner: AXRef? = Harness.bubbleRef
    /// What the edit field holds when the Edit action opens it.
    var editTextOnOpen = Harness.oldText
    /// The edit field or thread view shows this long after the press.
    var openDelay: TimeInterval = 0
    private var openedAt: TimeInterval?
    var threadOpen = false
    var threadParent: BubbleInfo?
    var menu: MenuItemInfo? = MenuItemInfo(ref: menuRef, title: UINames.replyToLastMessage, enabled: true)
    /// Nil: the main transcript shows when no edit field and no thread view shows.
    var transcriptOverride: Bool?
    /// Escapes needed to close an edit field or thread view.
    var escapesToClose = 1
    private(set) var escapes = 0
    /// How long one `setValue` takes.
    var writeDuration: TimeInterval = 0
    /// What the field ends up holding after a write, for a field that changes the text.
    var transform: ((String) -> String)?

    /// Replaces the focused field `focusedField()` reports: by default the thread's field while the thread view
    /// shows, else the edit field while it shows, else the main composer. Nil from the closure means no text field
    /// has focus.
    var focusOverride: (() -> AXRef?)?
    private(set) var focusReads = 0

    var failComposer = false
    var failFocus = false
    var failEditField = false
    /// Thrown by `editField()` in place of `Failure`, for the live driver's own errors.
    var editFieldError: Error?
    /// Runs at the start of each `menuItem(titled:)` read.
    var onMenuRead: (() -> Void)?
    var failThread = false
    var failMenu = false
    var failPerform = false
    var failPress = false
    var failSet = false
    var failRead = false
    var failTranscript = false
    /// Runs at the start of each `composer()` read.
    var onComposerRead: (() -> Void)?
    /// Runs at the start of each `focusedField()` read.
    var onFocusRead: (() -> Void)?
    /// Runs at the start of each `threadView()` read, where the live driver walks the thread view.
    var onThreadRead: (() -> Void)?
    /// Runs inside `perform`, where the live driver rereads the bubble's description and action names, before the
    /// final check.
    var beforePerformRevalidation: (() -> Void)?
    /// Runs inside `press(menuItem:)`, where the live driver rereads the item's title, before the final check.
    var beforeMenuPressRevalidation: (() -> Void)?

    init(clock: FakeClock, log: EventLog) {
        self.clock = clock
        self.log = log
    }

    private var shown: Bool {
        guard let openedAt else { return true }
        return clock.uptime >= openedAt + openDelay
    }

    func windowCount() throws -> Int { 1 }
    func conversationRows() throws -> [ConversationRowInfo] { [] }
    func conversationListState() throws -> ConversationListState { .loaded }
    func press(row: AXRef, finalCheck: AXFinalCheck) throws {
        try finalCheck()
    }
    func loadedBubbles() throws -> [BubbleInfo] { [] }

    func perform(action: String, on bubble: AXRef, finalCheck: AXFinalCheck) throws {
        beforePerformRevalidation?()
        if failPerform { throw Failure() }
        try finalCheck()
        log.add(.perform(action))
        if action == UINames.edit {
            editOpen = true
            openedAt = clock.uptime
            values[Self.editRef] = editTextOnOpen
        }
    }

    func composer() throws -> FieldInfo? {
        onComposerRead?()
        if failComposer { throw Failure() }
        guard hasComposer else { return nil }
        return FieldInfo(ref: Self.composerRef, value: values[Self.composerRef] ?? "", owningBubble: nil)
    }

    func focusedField() throws -> FieldInfo? {
        focusReads += 1
        onFocusRead?()
        if failFocus { throw Failure() }
        let ref: AXRef?
        if let focusOverride {
            ref = focusOverride()
        } else if threadOpen, shown {
            ref = Self.threadComposerRef
        } else if editOpen, shown {
            ref = Self.editRef
        } else {
            ref = hasComposer ? Self.composerRef : nil
        }
        guard let ref else { return nil }
        return FieldInfo(ref: ref, value: values[ref] ?? "", owningBubble: ref == Self.editRef ? editOwner : nil)
    }

    func editField() throws -> FieldInfo? {
        if failEditField { throw Failure() }
        if let editFieldError { throw editFieldError }
        guard editOpen, shown else { return nil }
        return FieldInfo(ref: Self.editRef, value: values[Self.editRef] ?? "", owningBubble: editOwner)
    }

    func threadView() throws -> ThreadViewInfo? {
        onThreadRead?()
        if failThread { throw Failure() }
        guard threadOpen, shown else { return nil }
        return ThreadViewInfo(ref: Self.threadRef, parent: threadParent)
    }

    func showsMainTranscript() throws -> Bool {
        log.add(.readTranscript)
        if failTranscript { throw Failure() }
        return transcriptOverride ?? (!editOpen && !threadOpen)
    }

    func menuItem(titled title: String) throws -> MenuItemInfo? {
        onMenuRead?()
        if failMenu { throw Failure() }
        guard let menu, menu.title == title else { return nil }
        return menu
    }

    func press(menuItem: AXRef, finalCheck: AXFinalCheck) throws {
        beforeMenuPressRevalidation?()
        if failPress { throw Failure() }
        try finalCheck()
        log.add(.pressMenu)
        threadOpen = true
        openedAt = clock.uptime
        values[Self.threadComposerRef] = ""
    }

    /// The field each `setValue` wrote, in order.
    private(set) var writtenRefs: [AXRef] = []
    /// Runs after each write lands.
    var onSet: ((AXRef) -> Void)?

    func setValue(_ value: String, of field: AXRef, finalCheck: AXFinalCheck) throws {
        if failSet { throw Failure() }
        try finalCheck()
        log.add(.setValue(value))
        clock.advance(writeDuration)
        values[field] = transform?(value) ?? value
        writtenRefs.append(field)
        onSet?(field)
    }

    func readValue(of field: AXRef) throws -> String {
        log.add(.readValue)
        if failRead { throw Failure() }
        if field == Self.editRef, !editOpen { throw Failure() }
        if field == Self.threadComposerRef, !threadOpen { throw Failure() }
        guard let value = values[field] else { throw Failure() }
        return value
    }

    func escape() {
        escapes += 1
        if escapes >= escapesToClose {
            editOpen = false
            threadOpen = false
        }
    }

    /// Return commits an edit and closes its field, or sends a thread reply and leaves the thread view open.
    func commitReturn() {
        if editOpen {
            editOpen = false
        } else if threadOpen {
            values[Self.threadComposerRef] = ""
        }
    }
}

final class FakeTargeting: ChatTargeting {
    let log: EventLog
    var selection: ChatSelection = .selected
    var lookup: BubbleLookup
    /// Used before `lookup`, one per call.
    var lookups: [BubbleLookup] = []
    var signatureMatches = true
    /// Nil from `selectionExpectation`, as for a failed chat.db read.
    var failExpectation = false
    private(set) var verifyExcluding: [Int64?] = []
    /// `log.events.count` at each call that reads chat.db in the live targeter.
    private(set) var chatDBReadsAt: [Int] = []

    init(log: EventLog, bubble: BubbleInfo) {
        self.log = log
        self.lookup = .found(bubble)
    }

    func selectChat(_ chat: ResolvedChat) -> ChatSelection {
        chatDBReadsAt.append(log.events.count)
        log.add(.selectChat)
        return selection
    }

    func verifySelected(_ chat: ResolvedChat, excluding rowid: Int64?) -> Bool {
        chatDBReadsAt.append(log.events.count)
        log.add(.verifySelected)
        verifyExcluding.append(rowid)
        return signatureMatches
    }

    func selectionExpectation(_ chat: ResolvedChat, excluding rowid: Int64?) -> SelectionExpectation? {
        chatDBReadsAt.append(log.events.count)
        verifyExcluding.append(rowid)
        return failExpectation ? nil : SelectionExpectation(chat: chat, signature: [], bound: nil)
    }

    func verifySelected(_ expected: SelectionExpectation) -> Bool {
        log.add(.verifySelected)
        return signatureMatches
    }

    func findBubble(_ target: MessageTargetInfo) -> BubbleLookup {
        chatDBReadsAt.append(log.events.count)
        return findLoadedBubble(target)
    }

    func findLoadedBubble(_ target: MessageTargetInfo) -> BubbleLookup {
        log.add(.findBubble)
        if !lookups.isEmpty { return lookups.removeFirst() }
        return lookup
    }
}

final class FakeWindowRules: HiddenWindowPreparing {
    let log: EventLog
    var result: ActionResult?
    /// Notes for the action's own result, returned on every call.
    var notes: [ResultNote] = []
    private(set) var deadlines: [TimeInterval] = []

    init(log: EventLog) { self.log = log }

    func prepare(queueDeadline: TimeInterval) -> WindowPreparation {
        log.add(.ensureHidden)
        deadlines.append(queueDeadline)
        return WindowPreparation(early: result, notes: notes)
    }
}

final class FakeSource: UITargetSource {
    var newest: () throws -> MessageTargetInfo?
    var edit: (Int64) throws -> EditStateProbe?
    var maxRowID: () throws -> Int64 = { 500 }
    /// Set by the harness: each call records `log.events.count` in `readsAt`.
    var log: EventLog?
    private(set) var readsAt: [Int] = []

    init(newest: MessageTargetInfo?, edit: EditStateProbe?) {
        self.newest = { newest }
        self.edit = { _ in edit }
    }

    private func read() { readsAt.append(log?.events.count ?? -1) }

    func conversations() throws -> [ConversationSummary] { read(); return [] }
    func conversation(for chat: ResolvedChat) throws -> ConversationSummary? { read(); return nil }
    func messageTarget(rowid: Int64) throws -> MessageTargetInfo? { read(); return nil }
    func sameBodyAndMinuteCount(for target: MessageTargetInfo) throws -> Int { read(); return 1 }
    func currentUserReaction(messageGUID: String, part: Int) throws -> TapbackKind? { read(); return nil }
    func reactionRows(aboveRowID rowid: Int64, targetGUID: String, part: Int) throws -> [ReactionRowProbe] {
        read()
        return []
    }
    func editState(rowid: Int64) throws -> EditStateProbe? { read(); return try edit(rowid) }
    func newestIncoming(for chat: ResolvedChat) throws -> MessageTargetInfo? { read(); return try newest() }
    func maxMessageRowID() throws -> Int64 { read(); return try maxRowID() }
}

final class FakeRows: SendRowSource {
    struct Failure: Error {}
    var maxRowID: () throws -> Int64 = { 500 }

    func maxMessageRowID() throws -> Int64 { try maxRowID() }
    func fromMeRows(aboveRowID rowid: Int64, limit: Int) throws -> [SentRowProbe] { [] }
    func sentRow(rowid: Int64) throws -> SentRowProbe? { nil }
    func transferStates(transferNames: [String]) throws -> [String: Int] { [:] }
    func canonicalChatID(chatRowID: Int64) throws -> CanonicalChatID? { nil }
}

/// Only reads and turns off: `ForegroundModeSwitching` has no way to turn the mode on.
final class FakeMode: ForegroundModeSwitching {
    let log: EventLog
    var isForegroundModeOn = true
    private(set) var reasons: [String] = []

    init(log: EventLog) { self.log = log }

    func turnForegroundOff(reason: String) {
        isForegroundModeOn = false
        reasons.append(reason)
        log.add(.modeOff(reason))
    }
}

/// One queue. `otherHolderUntil` is when another request gives it back; a wait advances the clock.
final class FakeQueue: ActionQueueing {
    let clock: FakeClock
    let log: EventLog
    var otherHolderUntil: TimeInterval?
    private(set) var holder: QueueTicket?
    private(set) var released: [QueueTicket] = []
    private(set) var acquiredAt: [TimeInterval] = []
    private(set) var doubleAcquire = false
    private var serial: UInt64 = 0

    init(clock: FakeClock, log: EventLog) {
        self.clock = clock
        self.log = log
    }

    var isHeld: Bool {
        if holder != nil { return true }
        if let until = otherHolderUntil, clock.uptime < until { return true }
        return false
    }

    func acquire(timeout: TimeInterval) -> QueueTicket? {
        log.add(.acquire(timeout))
        // A run that retakes the queue forever without the clock moving would hang the test.
        guard acquiredAt.count < 200 else {
            XCTFail("the queue was taken 200 times")
            return nil
        }
        if holder != nil { doubleAcquire = true }
        if let until = otherHolderUntil, clock.uptime < until {
            let wait = until - clock.uptime
            if wait > timeout {
                clock.advance(timeout)
                return nil
            }
            clock.advance(wait)
        }
        serial += 1
        let ticket = QueueTicket(serial: serial)
        holder = ticket
        acquiredAt.append(clock.uptime)
        return ticket
    }

    func release(_ ticket: QueueTicket) {
        log.add(.release)
        released.append(ticket)
        if holder == ticket { holder = nil }
    }
}

final class FakeVerifier: ForegroundVerifying {
    struct EditCall: Equatable {
        var rowid: Int64
        var before: AppleNanos
        var digest: String
        var timeout: TimeInterval
    }

    struct ReplyCall: Equatable {
        var snapshot: SendSnapshot
        var chat: ResolvedChat
        var digest: String
        var parentGUID: String
        var timeout: TimeInterval
    }

    let log: EventLog
    var editResult = ActionResult(.ok)
    var reply = ReplyVerification(result: ActionResult(.submitted), rowGUID: "reply-row-guid")
    private(set) var editCalls: [EditCall] = []
    private(set) var replyCalls: [ReplyCall] = []

    init(log: EventLog) { self.log = log }

    func verifyEdit(rowid: Int64, dateEditedBeforeNs: AppleNanos, newTextDigest: String,
                    timeout: TimeInterval) -> ActionResult {
        log.add(.verify)
        editCalls.append(EditCall(rowid: rowid, before: dateEditedBeforeNs, digest: newTextDigest, timeout: timeout))
        return editResult
    }

    func verifyReply(snapshot: SendSnapshot, chat: ResolvedChat, textDigest: String, parentGUID: String,
                     timeout: TimeInterval) -> ActionResult {
        verifyReplyRow(snapshot: snapshot, chat: chat, textDigest: textDigest, parentGUID: parentGUID,
                       timeout: timeout).result
    }

    func verifyReplyRow(snapshot: SendSnapshot, chat: ResolvedChat, textDigest: String, parentGUID: String,
                        timeout: TimeInterval) -> ReplyVerification {
        log.add(.verify)
        replyCalls.append(ReplyCall(snapshot: snapshot, chat: chat, digest: textDigest, parentGUID: parentGUID,
                                    timeout: timeout))
        return reply
    }
}

final class LoggingRecorder: InvocationRecorder {
    struct Failure: Error {}
    let log: EventLog
    var failWillInvoke = false
    private(set) var facts: [InvocationFacts] = []
    private(set) var invokedCount = 0

    init(log: EventLog) { self.log = log }

    func willInvoke(_ facts: InvocationFacts) throws {
        if failWillInvoke { throw Failure() }
        self.facts.append(facts)
        log.add(.willInvoke)
    }

    func didInvoke() throws {
        invokedCount += 1
        log.add(.didInvoke)
    }
}

/// Wires every fake to one clock and one log, and scripts Messages through `FakeMessagesApp`'s hooks.
final class Harness {
    static let pid: Int32 = 4242
    static let bubbleRef = AXRef(id: 10)
    static let threadParentRef = AXRef(id: 20)
    static let oldText = "see you at 5"
    static let newText = "see you at 6"
    static let replyText = "on my way"
    static let safari = FrontApp(bundleID: "com.apple.Safari", name: "Safari", pid: 500, hasWindows: true)
    static let finder = FrontApp(bundleID: "com.apple.finder", name: "Finder", pid: 300, hasWindows: true)
    static let messages = FrontApp(bundleID: "com.apple.MobileSMS", name: "Messages", pid: pid, hasWindows: true)

    let clock = FakeClock()
    let log = EventLog()
    let app = FakeMessagesApp()
    let input: FakeInput
    let ax: ScriptedAX
    let keys: RecordingKeys
    let verifier: FakeVerifier
    let queue: FakeQueue
    let targeting: FakeTargeting
    let windowRules: FakeWindowRules
    let source: FakeSource
    let rows = FakeRows()
    let mode: FakeMode
    let recorder: LoggingRecorder

    let chat: ResolvedChat
    let target: MessageTargetInfo
    let parent: MessageTargetInfo
    let bubble: BubbleInfo

    var editWindowOpen = true
    /// Overrides `editWindowOpen`; the argument counts calls from 1.
    var editWindowByCall: ((Int) -> Bool)?
    /// Each edit-window read: the row date and time passed in, and the fake clock's wall time then.
    private(set) var editWindowArgs: [(dateNs: AppleNanos, now: Date, clockNow: Date)] = []

    // Messages script, as delays after the call that starts each change.
    var base = MessagesAppState(isRunning: true, pid: pid, isFrontmost: false, isHidden: true, axWindowCount: 1,
                                onScreenWindowCount: 0, allSpacesWindowCount: 1)
    /// Frontmost this long after `open -b`. Nil: never.
    var activationDelay: TimeInterval? = 0.25
    /// Visible behind the front app this long after `open -b`, when it never comes to the front.
    var visibleBehindDelay: TimeInterval?
    /// Hidden this long after `hide`. Nil: never.
    var hideDelay: TimeInterval? = 0.25
    /// Messages stops being frontmost at this uptime.
    var loseFrontmostAt: TimeInterval?
    /// The front app before activation.
    var earlier: FrontApp? = Harness.safari
    /// The front app once Messages hides.
    var frontAfterHide: FrontApp? = Harness.safari
    /// The earlier app comes to the front this long after the reopen. Nil: never.
    var reopenDelay: TimeInterval? = 0.25
    /// The front app still reads Messages this long after `isHidden` turns true, as NSWorkspace can lag the hide.
    var frontLagAfterHide: TimeInterval = 0
    /// Runs on every front-app read.
    var onFrontRead: (() -> Void)?
    /// Replaces `app` as the machine's `env.app`, for a wrapper around it.
    var appControl: MessagesAppControl?
    private var activatedAt: TimeInterval?
    private var hiddenAt: TimeInterval?
    private var reopenedAt: TimeInterval?

    private(set) lazy var machine = ForegroundMachine(env: makeEnv())

    init() {
        input = FakeInput(clock: clock, log: log)
        ax = ScriptedAX(clock: clock, log: log)
        keys = RecordingKeys(log: log)
        verifier = FakeVerifier(log: log)
        queue = FakeQueue(clock: clock, log: log)
        windowRules = FakeWindowRules(log: log)
        mode = FakeMode(log: log)
        recorder = LoggingRecorder(log: log)

        let canonical = CanonicalChatID.direct(handle: "+14155550111")
        chat = ResolvedChat(canonical: canonical, chatRowIDs: [7], chatGUIDs: ["iMessage;-;+14155550111"],
                            primaryChatRowID: 7, label: "Sam", isGroup: false, handles: ["+14155550111"],
                            sendHandle: "+14155550111", service: "iMessage")
        let sentNs = Fixture.nowNs - 120_000_000_000
        target = MessageTargetInfo(rowid: 410, guid: "target-guid", chatRowID: 7, canonical: canonical,
                                   isGroupChat: false, fromMe: true, body: Harness.oldText, dateNs: sentNs,
                                   partCount: 1, isSinglePartText: true, dateEditedNs: 0, isUnsent: false,
                                   senderName: "Me")
        parent = MessageTargetInfo(rowid: 420, guid: "parent-guid", chatRowID: 7, canonical: canonical,
                                   isGroupChat: false, fromMe: false, body: "Are you close?", dateNs: sentNs,
                                   partCount: 1, isSinglePartText: true, dateEditedNs: 0, isUnsent: false,
                                   senderName: "Sam")
        bubble = BubbleInfo(ref: Harness.bubbleRef, fromMe: true, text: Harness.oldText,
                            minuteLabel: Harness.minuteLabel(sentNs), hasTextBubble: true,
                            actionNames: ["Heart", UINames.edit])
        targeting = FakeTargeting(log: log, bubble: bubble)
        source = FakeSource(newest: parent,
                            edit: EditStateProbe(rowid: 410, dateEditedNs: 123, dateRetractedNs: 0,
                                                 body: Harness.oldText))
        source.log = log
        ax.threadParent = Harness.parentBubble(for: parent)

        app.onCall = { [unowned self] call, _ in
            switch call {
            case .activateForeground:
                activatedAt = clock.uptime
                log.add(.activate)
            case .hide:
                hiddenAt = clock.uptime
                log.add(.hide)
            case .reopen(let bundleID):
                reopenedAt = clock.uptime
                log.add(.reopen(bundleID))
            default:
                break
            }
        }
        app.onState = { [unowned self] state in state = currentState() }
        app.onFrontmost = { [unowned self] front in front = currentFront() }
        keys.onPost = { [unowned self] key in
            switch key {
            case .escape: ax.escape()
            case .returnKey: ax.commitReturn()
            }
        }
    }

    static func minuteLabel(_ dateNs: AppleNanos, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute], from: AppleTime.date(fromNanos: dateNs))
        let hour = parts.hour ?? 0
        let shown = hour % 12 == 0 ? 12 : hour % 12
        return String(format: "%d:%02d\u{202F}%@", shown, parts.minute ?? 0, hour < 12 ? "AM" : "PM")
    }

    static func parentBubble(for parent: MessageTargetInfo) -> BubbleInfo {
        BubbleInfo(ref: threadParentRef, fromMe: parent.fromMe, text: parent.body,
                   minuteLabel: minuteLabel(parent.dateNs), hasTextBubble: true, actionNames: [])
    }

    func makeEnv() -> ForegroundEnvironment {
        let windows = HiddenWindowManager(app: app, ax: ax, transfers: FakePendingTransfers(), clock: clock)
        var env = ForegroundEnvironment(clock: clock, input: input, app: appControl ?? app, ax: ax, keys: keys,
                                        verifier: verifier, queue: queue, targeting: targeting, windows: windows,
                                        source: source, rows: rows, mode: mode) { [unowned self] event in
            log.add(.progress(event))
        }
        env.windowRules = windowRules
        env.marker = { [unowned self] marker in log.add(.marker(marker)) }
        env.editWindowOpen = { [unowned self] dateNs, now in
            editWindowArgs.append((dateNs, now, clock.now))
            if let byCall = editWindowByCall { return byCall(editWindowArgs.count) }
            return editWindowOpen
        }
        return env
    }

    func currentState() -> MessagesAppState {
        let now = clock.uptime
        var state = base
        if let hiddenAt, let hideDelay, now >= hiddenAt + hideDelay {
            state.isHidden = true
            state.isFrontmost = false
        } else if let activatedAt, let delay = activationDelay, now >= activatedAt + delay {
            state.isHidden = false
            state.isFrontmost = !(loseFrontmostAt.map { now >= $0 } ?? false)
        } else if let activatedAt, let delay = visibleBehindDelay, now >= activatedAt + delay {
            state.isHidden = false
            state.isFrontmost = false
        }
        state.onScreenWindowCount = state.isHidden ? 0 : 1
        return state
    }

    func currentFront() -> FrontApp? {
        onFrontRead?()
        let now = clock.uptime
        if currentState().isFrontmost { return Harness.messages }
        if let reopenedAt, let reopenDelay, now >= reopenedAt + reopenDelay { return earlier }
        if let hiddenAt, currentState().isHidden {
            if let hideDelay, now < hiddenAt + hideDelay + frontLagAfterHide { return Harness.messages }
            return frontAfterHide
        }
        return earlier
    }

    var queueDeadline: TimeInterval { clock.uptime + Limits.queueWait }

    @discardableResult
    func runEdit(_ text: String = Harness.newText, queueDeadline: TimeInterval? = nil) -> ForegroundOutcome {
        let run = ForegroundRun(chat: chat, action: .edit(target: target, newText: text),
                                queueDeadline: queueDeadline ?? self.queueDeadline)
        return machine.run(run, recorder: recorder)
    }

    @discardableResult
    func runReply(_ text: String = Harness.replyText, queueDeadline: TimeInterval? = nil) -> ForegroundOutcome {
        let run = ForegroundRun(chat: chat, action: .threadedReply(parent: parent, text: text),
                                queueDeadline: queueDeadline ?? self.queueDeadline)
        return machine.run(run, recorder: recorder)
    }

    /// The log without reads and markers, for order checks.
    var actions: [Event] {
        log.events.filter { event in
            if case .marker = event { return false }
            return event != .readValue && event != .readTranscript
        }
    }

    /// The log without reads, markers included.
    var actionsAndMarkers: [Event] {
        log.events.filter { $0 != .readValue && $0 != .readTranscript }
    }

    /// Injects input the first time `event` is logged.
    func injectInput(on event: Event, when condition: @escaping () -> Bool = { true }) {
        var done = false
        log.onEvent = { [unowned self] logged in
            guard !done, logged == event, condition() else { return }
            done = true
            input.inject()
        }
    }

    /// The step 1 checks one take of the queue makes, in order, for an edit.
    var editStep1Events: [Event] { [.ensureHidden, .selectChat, .findBubble] }
}

/// Fails the test if a run touched Messages' foreground in any way.
func assertNothingActivated(_ h: Harness, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(h.log.count(.activate), 0, "activated", file: file, line: line)
    XCTAssertTrue(h.log.keys.isEmpty, "posted keys", file: file, line: line)
    XCTAssertTrue(h.log.writes.isEmpty, "wrote a field", file: file, line: line)
    XCTAssertEqual(h.log.count(.hide), 0, "hid Messages", file: file, line: line)
    XCTAssertEqual(h.recorder.facts.count, 0, "called willInvoke", file: file, line: line)
}

/// Fails the test if anything after the first input is a key, a hide, a reopen or a press.
func assertNoActionAfterInput(_ h: Harness, allowingWrites writes: Int = 0, file: StaticString = #filePath,
                              line: UInt = #line) {
    let after = h.log.afterInput
    XCTAssertTrue(h.log.events.contains(.input), "no input was injected", file: file, line: line)
    for event in after {
        switch event {
        case .key, .hide, .reopen, .perform, .pressMenu, .activate:
            XCTFail("\(event) after input", file: file, line: line)
        default:
            break
        }
    }
    let afterWrites = after.filter { if case .setValue = $0 { return true } else { return false } }.count
    XCTAssertLessThanOrEqual(afterWrites, writes, "AX writes after input", file: file, line: line)
}
