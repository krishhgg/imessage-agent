import Foundation
import XCTest
import IMCore
import IMStore
@testable import IMUI
import IMTestSupport

/// One ordered log shared by the fakes, so tests can check that a journal write came before the press.
final class EventLog {
    private let lock = NSLock()
    private var storage: [String] = []

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func add(_ event: String) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }

    func index(of prefix: String) -> Int? { events.firstIndex { $0.hasPrefix(prefix) } }
    func count(of prefix: String) -> Int { events.filter { $0.hasPrefix(prefix) }.count }
    func contains(_ prefix: String) -> Bool { index(of: prefix) != nil }
}

struct TestError: Error {}

/// Scripted AX driver. Every call goes into the log; nothing touches Messages.
final class ScriptedAX: MessagesAXDriving {
    let log: EventLog
    var windows = 1
    var windowCountError: AXDriveError?
    /// Runs inside `windowCount`, where the live read can block for up to 2 s.
    var onWindowCount: (() -> Void)?
    var rows: [ConversationRowInfo] = []
    var rowsError: AXDriveError?
    /// Answers `conversationListState`, called once per read. Loaded by default. Tests can switch on a clock to
    /// script a list that loads late, or throw to script a failed read.
    var listState: () throws -> ConversationListState = { .loaded }
    /// Returns the loaded bubbles. Tests can switch on a clock to script a transcript that settles late.
    var bubbles: () -> [BubbleInfo] = { [] }
    var bubblesError: AXDriveError?
    var pressError: AXDriveError?
    var performError: AXDriveError?
    var onPerform: ((String, AXRef) -> Void)?
    /// Runs inside `perform`, where the live driver rereads the bubble's description and action names, before the
    /// final check.
    var beforePerformRevalidation: (() -> Void)?
    private(set) var pressedRows: [AXRef] = []
    private(set) var performed: [(action: String, ref: AXRef)] = []

    init(log: EventLog) { self.log = log }

    func windowCount() throws -> Int {
        log.add("ax.windowCount")
        onWindowCount?()
        if let windowCountError { throw windowCountError }
        return windows
    }

    func conversationRows() throws -> [ConversationRowInfo] {
        log.add("ax.rows")
        if let rowsError { throw rowsError }
        return rows
    }

    func conversationListState() throws -> ConversationListState {
        log.add("ax.listState")
        return try listState()
    }

    func press(row: AXRef, finalCheck: AXFinalCheck) throws {
        log.add("ax.pressRow:\(row.id)")
        if let pressError { throw pressError }
        try finalCheck()
        pressedRows.append(row)
    }

    func loadedBubbles() throws -> [BubbleInfo] {
        log.add("ax.bubbles")
        if let bubblesError { throw bubblesError }
        return bubbles()
    }

    func perform(action: String, on bubble: AXRef, finalCheck: AXFinalCheck) throws {
        beforePerformRevalidation?()
        try finalCheck()
        log.add("ax.perform:\(action):\(bubble.id)")
        if let performError { throw performError }
        performed.append((action, bubble))
        onPerform?(action, bubble)
    }

    func composer() throws -> FieldInfo? { log.add("ax.composer"); return nil }
    func editField() throws -> FieldInfo? { log.add("ax.editField"); return nil }
    func focusedField() throws -> FieldInfo? { log.add("ax.focusedField"); return nil }
    func threadView() throws -> ThreadViewInfo? { log.add("ax.threadView"); return nil }
    func showsMainTranscript() throws -> Bool { log.add("ax.showsMainTranscript"); return true }
    func menuItem(titled title: String) throws -> MenuItemInfo? { log.add("ax.menuItem:\(title)"); return nil }
    func press(menuItem: AXRef, finalCheck: AXFinalCheck) throws {
        try finalCheck()
        log.add("ax.pressMenuItem:\(menuItem.id)")
    }
    func setValue(_ value: String, of field: AXRef, finalCheck: AXFinalCheck) throws {
        try finalCheck()
        log.add("ax.setValue:\(field.id)")
    }
    func readValue(of field: AXRef) throws -> String { log.add("ax.readValue:\(field.id)"); return "" }
}

/// Scripted chat.db reads. Thread safe, so the concurrency tests can share one.
final class FakeUISource: UITargetSource {
    enum Op: Hashable {
        case conversations, conversation, messageTarget, sameBody, currentReaction, reactionRows, editState,
             newestIncoming, maxRowID
    }

    let log: EventLog
    private let lock = NSLock()
    var summaries: [ConversationSummary] = []
    var targets: [Int64: MessageTargetInfo] = [:]
    var sameBodyCount = 0
    var reaction: TapbackKind?
    /// Reaction after a press, if the test wants the re-read to differ.
    var reactionAfter: (() -> TapbackKind?)?
    var reactionRowsProvider: (Int64) -> [ReactionRowProbe] = { _ in [] }
    var editStateProvider: (Int64) -> EditStateProbe? = { _ in nil }
    var maxRowID: Int64 = 500
    var failing: Set<Op> = []

    init(log: EventLog) { self.log = log }

    private func read(_ op: Op) throws {
        log.add("db.\(op)")
        lock.lock()
        let fails = failing.contains(op)
        lock.unlock()
        if fails { throw TestError() }
    }

    func conversations() throws -> [ConversationSummary] {
        try read(.conversations)
        return summaries
    }

    func conversation(for chat: ResolvedChat) throws -> ConversationSummary? {
        try read(.conversation)
        return summaries.first { $0.canonical == chat.canonical }
    }

    func messageTarget(rowid: Int64) throws -> MessageTargetInfo? {
        try read(.messageTarget)
        return targets[rowid]
    }

    func sameBodyAndMinuteCount(for target: MessageTargetInfo) throws -> Int {
        try read(.sameBody)
        return sameBodyCount
    }

    func currentUserReaction(messageGUID: String, part: Int) throws -> TapbackKind? {
        try read(.currentReaction)
        if let reactionAfter, log.contains("ax.perform") { return reactionAfter() }
        return reaction
    }

    func reactionRows(aboveRowID rowid: Int64, targetGUID: String, part: Int) throws -> [ReactionRowProbe] {
        try read(.reactionRows)
        return reactionRowsProvider(rowid).filter { $0.associatedGUID == "p:\(part)/\(targetGUID)" }
    }

    func editState(rowid: Int64) throws -> EditStateProbe? {
        try read(.editState)
        return editStateProvider(rowid)
    }

    func newestIncoming(for chat: ResolvedChat) throws -> MessageTargetInfo? {
        try read(.newestIncoming)
        return nil
    }

    func maxMessageRowID() throws -> Int64 {
        try read(.maxRowID)
        return maxRowID
    }
}

/// Journal hooks that write into the shared log.
final class LoggingRecorder: InvocationRecorder {
    let log: EventLog
    var failWillInvoke = false
    /// Runs inside each `willInvoke` after the write, for a flush that takes time on a `FakeClock`.
    var onWillInvoke: (() -> Void)?
    private(set) var facts: [InvocationFacts] = []
    private(set) var didInvokeCount = 0

    init(log: EventLog) { self.log = log }

    func willInvoke(_ facts: InvocationFacts) throws {
        log.add("journal.willInvoke")
        if failWillInvoke { throw TestError() }
        self.facts.append(facts)
        onWillInvoke?()
    }

    func didInvoke() throws {
        log.add("journal.didInvoke")
        didInvokeCount += 1
    }
}

/// Scripted chat selection and bubble lookup for the runner tests.
final class FakeTargeting: ChatTargeting {
    let log: EventLog
    var selection: ChatSelection = .selected
    var lookup: BubbleLookup
    var onSelect: (() -> Void)?

    init(log: EventLog, bubble: BubbleInfo) {
        self.log = log
        self.lookup = .found(bubble)
    }

    func selectChat(_ chat: ResolvedChat) -> ChatSelection {
        log.add("target.select")
        onSelect?()
        return selection
    }

    func verifySelected(_ chat: ResolvedChat, excluding rowid: Int64?) -> Bool {
        log.add("target.verify")
        return true
    }

    func selectionExpectation(_ chat: ResolvedChat, excluding rowid: Int64?) -> SelectionExpectation? {
        log.add("target.expectation")
        return SelectionExpectation(chat: chat, signature: [], bound: nil)
    }

    func verifySelected(_ expected: SelectionExpectation) -> Bool {
        log.add("target.verify")
        return true
    }

    func findLoadedBubble(_ target: MessageTargetInfo) -> BubbleLookup {
        log.add("target.find")
        return lookup
    }

    func findBubble(_ target: MessageTargetInfo) -> BubbleLookup {
        log.add("target.find")
        return lookup
    }
}

/// Pending staged files until `clearAt` on the clock's uptime.
final class TimedTransfers: PendingTransferChecking {
    let clock: FakeClock
    var clearAt: TimeInterval
    private(set) var checks = 0

    init(clock: FakeClock, clearAt: TimeInterval) {
        self.clock = clock
        self.clearAt = clearAt
    }

    func hasPendingTransfers() -> Bool {
        checks += 1
        return clock.uptime < clearAt
    }
}

/// `FakeMessagesApp` whose `launchHidden` fails.
final class LaunchFailingApp: MessagesAppControl {
    let inner = FakeMessagesApp()
    var launches = 0

    func state() -> MessagesAppState { inner.state() }
    func launchHidden() -> Bool { launches += 1; return false }
    func quit() -> Bool { inner.quit() }
    func waitForExit(timeout: TimeInterval) -> Bool { inner.waitForExit(timeout: timeout) }
    func activateForeground() -> Bool { inner.activateForeground() }
    func hide() { inner.hide() }
    func frontmostApp() -> FrontApp? { inner.frontmostApp() }
    func reopen(bundleID: String) -> Bool { inner.reopen(bundleID: bundleID) }
}

// MARK: - Builders

enum Make {
    static let pid: Int32 = 4242

    /// `anySpace` is the real-window count on every Space. It defaults to the AX count, because AX lists the windows
    /// on the current Space and each of those is also in the window server's full list. A test that puts a window on
    /// another Space, or shows only the menu bar strips, passes it. `onSpace` is how many of those the window server
    /// puts on a Space, and defaults to `anySpace`; a test with the 500 x 500 window Messages never shows passes it.
    /// `locked` is the screen lock, read whether or not Messages runs.
    static func state(running: Bool = true, frontmost: Bool = false, hidden: Bool = true, ax: Int = 1,
                      onScreen: Int = 0, anySpace: Int? = nil, onSpace: Int? = nil,
                      locked: Bool = false) -> MessagesAppState {
        guard running else {
            var state = MessagesAppState.notRunning
            state.isScreenLocked = locked
            return state
        }
        return MessagesAppState(isRunning: true, pid: pid, isFrontmost: frontmost, isHidden: hidden,
                                axWindowCount: ax, onScreenWindowCount: onScreen,
                                allSpacesWindowCount: anySpace ?? ax, spaceWindowCount: onSpace,
                                isScreenLocked: locked)
    }

    static let readyState = state()

    static func chat(_ handle: String = "+15550001111", group: Bool = false) -> ResolvedChat {
        let canonical: CanonicalChatID = group ? .group(identifier: handle) : .direct(handle: handle)
        return ResolvedChat(canonical: canonical, chatRowIDs: [1], chatGUIDs: ["iMessage;-;\(handle)"],
                            primaryChatRowID: 1, label: handle, isGroup: group, handles: [handle],
                            sendHandle: group ? nil : handle, service: "iMessage")
    }

    static func summary(_ handle: String = "+15550001111", name: String = "Jordan", preview: String = "see you",
                        dateNs: AppleNanos = Fixture.nowNs - 600 * 1_000_000_000, group: Bool = false,
                        signature: [SignatureRow]? = nil) -> ConversationSummary {
        let canonical: CanonicalChatID = group ? .group(identifier: handle) : .direct(handle: handle)
        return ConversationSummary(canonical: canonical, chatRowIDs: [1], isGroup: group, displayName: name,
                                   newestPreview: preview, newestDateNs: dateNs,
                                   signature: signature ?? [SignatureRow(fromMe: false, body: preview),
                                                            SignatureRow(fromMe: true, body: "on my way")])
    }

    static func target(rowid: Int64 = 101, guid: String = "GUID-101", handle: String = "+15550001111",
                       fromMe: Bool = true, body: String = "on my way",
                       dateNs: AppleNanos = Fixture.nowNs - 30 * 1_000_000_000, parts: Int = 1,
                       singlePartText: Bool = true, group: Bool = false, unsent: Bool = false) -> MessageTargetInfo {
        let canonical: CanonicalChatID = group ? .group(identifier: handle) : .direct(handle: handle)
        return MessageTargetInfo(rowid: rowid, guid: guid, chatRowID: 1, canonical: canonical, isGroupChat: group,
                                 fromMe: fromMe, body: body, dateNs: dateNs, partCount: parts,
                                 isSinglePartText: singlePartText, dateEditedNs: 0, isUnsent: unsent,
                                 senderName: fromMe ? "" : "Jordan")
    }

    static func bubble(_ id: UInt64, fromMe: Bool = true, text: String = "on my way", minute: String = "",
                       hasText: Bool = true, actions: [String] = UINames.classicTapbacks,
                       description: String = "", bare: Bool = false) -> BubbleInfo {
        BubbleInfo(ref: AXRef(id: id), fromMe: fromMe, text: text, minuteLabel: minute, hasTextBubble: hasText,
                   actionNames: actions, axDescription: description, isBareGroup: bare)
    }

    /// A text bubble Messages shows as a bare group, because it detected a date or time in it (live, 2026-11-11).
    static func dateBubble(_ id: UInt64, fromMe: Bool = true, text: String, minute: String,
                           sender: String = "Jordan") -> BubbleInfo {
        bubble(id, fromMe: fromMe, text: "", minute: minute, hasText: false,
               description: "\(fromMe ? "Your iMessage" : sender), \(text), \(minute)", bare: true)
    }

    /// A file attachment as S2 recorded it: an `AXButton` with no text view, so not bare.
    static func fileBubble(_ id: UInt64, fromMe: Bool = true, name: String, minute: String) -> BubbleInfo {
        bubble(id, fromMe: fromMe, text: "", minute: minute, hasText: false,
               description: "\(fromMe ? "Your iMessage" : "Jordan"), \(name), Text Document · 23 bytes, \(minute)")
    }

    static func row(_ id: UInt64, _ description: String, selected: Bool? = false) -> ConversationRowInfo {
        ConversationRowInfo(ref: AXRef(id: id), description: description, isSelected: selected)
    }

    static func reaction(rowid: Int64, guid: String = "GUID-101", type: Int, emoji: String? = nil,
                         fromMe: Bool = true) -> ReactionRowProbe {
        ReactionRowProbe(rowid: rowid, associatedType: type, associatedGUID: "p:0/\(guid)", emoji: emoji,
                         fromMe: fromMe)
    }

    static func builder(now: Date = Fixture.now) -> RowDescriptionBuilder {
        RowDescriptionBuilder(timeZone: Fixture.timeZone, now: now)
    }

    /// Apple nanoseconds for a local wall-clock time in the fixture's time zone.
    static func nanos(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0)
        -> AppleNanos {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Fixture.timeZone
        let date = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute,
                                                      second: second))!
        return AppleTime.nanos(from: date)
    }
}

/// A full set of hidden-action parts over fakes, ready in the one-hidden-window state.
final class Rig {
    let log = EventLog()
    let clock = FakeClock()
    let app: FakeMessagesApp
    let ax: ScriptedAX
    let source: FakeUISource
    let transfers = FakePendingTransfers()
    let recorder: LoggingRecorder
    let windows: HiddenWindowManager

    init(state: MessagesAppState = Make.readyState) {
        app = FakeMessagesApp(current: state)
        ax = ScriptedAX(log: log)
        source = FakeUISource(log: log)
        recorder = LoggingRecorder(log: log)
        windows = HiddenWindowManager(app: app, ax: ax, transfers: transfers, clock: clock)
    }

    /// Wired to `windows` for the last launch, as the bridge wires it.
    func targeter() -> ChatTargeter {
        let clock = self.clock
        let windows = self.windows
        return ChatTargeter(ax: ax, source: source, builder: { Make.builder(now: clock.now) }, clock: clock,
                            lastLaunch: { windows.lastLaunchUptime })
    }
}

func XCTAssertNoPress(_ log: EventLog, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertFalse(log.contains("ax.pressRow"), "a row was pressed: \(log.events)", file: file, line: line)
    XCTAssertFalse(log.contains("ax.perform"), "an action was performed: \(log.events)", file: file, line: line)
}
