import Foundation
import XCTest
@testable import IMForeground
import IMCore
import IMPolicy
import IMSend
import IMStore
import IMTestSupport
import IMUI

/// Several connections calling `run` on one machine at once, on the real clock with lock-protected fakes. Every
/// condition the machine waits for holds at once, so no run sleeps.
final class ConcurrencyTests: XCTestCase {
    func testConcurrentRunsKeepTheirOwnStateAndMeetOnlyAtTheQueue() {
        let world = World()
        let clock = SystemClock()
        let app = WorldApp(world)
        let ax = WorldAX(world)
        let windows = HiddenWindowManager(app: app, ax: ax, transfers: FakePendingTransfers(), clock: clock)
        var env = ForegroundEnvironment(clock: clock, input: AlwaysIdle(), app: app, ax: ax, keys: WorldKeys(world),
                                        verifier: WorldVerifier(world), queue: world.queue,
                                        targeting: WorldTargeting(world), windows: windows,
                                        source: WorldSource(world), rows: WorldRows(world), mode: AlwaysOn(),
                                        progress: { _ in })
        env.windowRules = NoWindowRules()
        env.editWindowOpen = { _, _ in true }
        let machine = ForegroundMachine(env: env)

        let runs = 8
        let base = Harness()
        let lock = NSLock()
        var outcomes: [Int: ForegroundOutcome] = [:]
        var facts: [Int: [InvocationFacts]] = [:]
        var reading = true
        func stillReading() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return reading
        }
        let readerDone = DispatchSemaphore(value: 0)
        let reader = Thread {
            while stillReading() { _ = machine.phase }
            readerDone.signal()
        }
        reader.start()

        DispatchQueue.concurrentPerform(iterations: runs) { i in
            let chat = World.chat(i)
            let recorder = FakeInvocationRecorder()
            let run: ForegroundRun
            if i.isMultiple(of: 2) {
                var target = base.target
                target.rowid = Int64(1000 + i)
                target.guid = "target-\(i)"
                target.canonical = chat.canonical
                run = ForegroundRun(chat: chat, action: .edit(target: target, newText: "edit \(i)"),
                                    queueDeadline: clock.uptime + 30)
            } else {
                run = ForegroundRun(chat: chat, action: .threadedReply(parent: World.parent(i), text: "reply \(i)"),
                                    queueDeadline: clock.uptime + 30)
            }
            let outcome = machine.run(run, recorder: recorder)
            // IMBridge releases the queue once the journal records `final`.
            if let ticket = outcome.ticket { world.queue.release(ticket) }
            lock.lock()
            outcomes[i] = outcome
            facts[i] = recorder.invoking
            lock.unlock()
        }
        lock.lock()
        reading = false
        lock.unlock()
        XCTAssertEqual(readerDone.wait(timeout: .now() + 5), .success)

        XCTAssertEqual(outcomes.count, runs)
        XCTAssertEqual(world.queue.mostHolders, 1, "two runs held the queue at once")
        var tickets = Set<UInt64>()
        for i in 0..<runs {
            guard let outcome = outcomes[i], let invoking = facts[i] else { return XCTFail("run \(i) missing") }
            XCTAssertNotNil(outcome.ticket, "run \(i)")
            if let serial = outcome.ticket?.serial { tickets.insert(serial) }
            XCTAssertEqual(invoking.count, 1, "run \(i)")
            if i.isMultiple(of: 2) {
                XCTAssertEqual(outcome.result.code, .ok, "run \(i)")
                XCTAssertEqual(invoking.first?.targetGUID, "target-\(i)")
                XCTAssertNil(outcome.sentGUID)
            } else {
                XCTAssertEqual(outcome.result.code, .submitted, "run \(i)")
                XCTAssertEqual(outcome.sentGUID, "row-" + TextNorm.textDigest("reply \(i)"), "run \(i)")
                XCTAssertNil(invoking.first?.targetGUID)
            }
            XCTAssertEqual(world.typed(i), i.isMultiple(of: 2) ? "edit \(i)" : "reply \(i)", "run \(i)")
        }
        XCTAssertEqual(tickets.count, runs)
        let snapshots = world.with { world.snapshots }
        XCTAssertEqual(Set(snapshots.values).count, runs, "each run kept its own snapshot")
        for i in 0..<runs {
            XCTAssertEqual(facts[i]?.first?.snapshotRowID, snapshots[i], "run \(i) journaled its own snapshot")
            if !i.isMultiple(of: 2) {
                XCTAssertEqual(world.verifiedSnapshot(i), snapshots[i], "run \(i) verified its own snapshot")
            }
        }
    }
}

// MARK: - Lock-protected fakes over one shared Messages

/// The one Messages every fake shares. Every access holds the lock.
final class World {
    let lock = NSLock()
    let queue = BlockingQueue()
    var frontmost = false
    var hidden = true
    var selected: Int?
    var editOpenFor: Int?
    var threadOpenFor: Int?
    var values: [AXRef: String] = [:]
    var typedByRun: [Int: String] = [:]
    var maxRowID: Int64 = 0
    var snapshots: [Int: Int64] = [:]
    var verified: [Int: Int64] = [:]

    static func chat(_ i: Int) -> ResolvedChat {
        let canonical = CanonicalChatID.direct(handle: "+1415555\(1000 + i)")
        return ResolvedChat(canonical: canonical, chatRowIDs: [Int64(i)], chatGUIDs: ["chat-\(i)"],
                            primaryChatRowID: Int64(i), label: "Chat \(i)", isGroup: false,
                            handles: ["+1415555\(1000 + i)"], sendHandle: "+1415555\(1000 + i)", service: "iMessage")
    }

    static func parent(_ i: Int) -> MessageTargetInfo {
        MessageTargetInfo(rowid: Int64(2000 + i), guid: "parent-\(i)", chatRowID: Int64(i), canonical: chat(i).canonical,
                          isGroupChat: false, fromMe: false, body: "question \(i)", dateNs: Fixture.nowNs,
                          partCount: 1, isSinglePartText: true, dateEditedNs: 0, isUnsent: false, senderName: "S")
    }

    static func run(of chat: ResolvedChat) -> Int { Int(chat.primaryChatRowID) }

    func with<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func typed(_ i: Int) -> String? { with { typedByRun[i] } }
    func verifiedSnapshot(_ i: Int) -> Int64? { with { verified[i] } }
}

final class BlockingQueue: ActionQueueing {
    private let condition = NSCondition()
    private var holder: QueueTicket?
    private var serial: UInt64 = 0
    private var holders = 0
    private(set) var mostHolders = 0

    var isHeld: Bool {
        condition.lock()
        defer { condition.unlock() }
        return holder != nil
    }

    func acquire(timeout: TimeInterval) -> QueueTicket? {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while holder != nil {
            if !condition.wait(until: deadline) { return nil }
        }
        serial += 1
        let ticket = QueueTicket(serial: serial)
        holder = ticket
        holders += 1
        mostHolders = max(mostHolders, holders)
        return ticket
    }

    func release(_ ticket: QueueTicket) {
        condition.lock()
        defer { condition.unlock() }
        guard holder == ticket else { return }
        holder = nil
        holders -= 1
        condition.broadcast()
    }
}

final class AlwaysIdle: InputMonitoring {
    func secondsSinceLastInput() -> TimeInterval { 100 }
}

final class AlwaysOn: ForegroundModeSwitching {
    var isForegroundModeOn: Bool { true }
    func turnForegroundOff(reason: String) { XCTFail("turned off: \(reason)") }
}

final class NoWindowRules: HiddenWindowPreparing {
    func prepare(queueDeadline: TimeInterval) -> WindowPreparation { WindowPreparation(early: nil, notes: []) }
}

final class WorldApp: MessagesAppControl {
    let world: World
    init(_ world: World) { self.world = world }

    func state() -> MessagesAppState {
        world.with {
            MessagesAppState(isRunning: true, pid: 4242, isFrontmost: world.frontmost, isHidden: world.hidden,
                             axWindowCount: 1, onScreenWindowCount: world.hidden ? 0 : 1, allSpacesWindowCount: 1)
        }
    }

    func launchHidden() -> Bool { true }
    func quit() -> Bool { true }
    func waitForExit(timeout: TimeInterval) -> Bool { true }

    func activateForeground() -> Bool {
        world.with {
            world.hidden = false
            world.frontmost = true
        }
        return true
    }

    func hide() {
        world.with {
            world.hidden = true
            world.frontmost = false
        }
    }

    func frontmostApp() -> FrontApp? {
        world.with { world.frontmost ? Harness.messages : Harness.safari }
    }

    func reopen(bundleID: String) -> Bool { true }
}

final class WorldAX: MessagesAXDriving {
    static let composer = AXRef(id: 1)
    static let edit = AXRef(id: 2)
    static let threadComposer = AXRef(id: 3)
    let world: World
    init(_ world: World) { self.world = world }

    static func bubbleRef(_ i: Int) -> AXRef { AXRef(id: UInt64(100 + i)) }

    func windowCount() throws -> Int { 1 }
    func conversationRows() throws -> [ConversationRowInfo] { [] }
    func press(row: AXRef, finalCheck: AXFinalCheck) throws {
        try finalCheck()
    }
    func loadedBubbles() throws -> [BubbleInfo] { [] }

    func perform(action: String, on bubble: AXRef, finalCheck: AXFinalCheck) throws {
        try finalCheck()
        world.with {
            world.editOpenFor = world.selected
            world.values[Self.edit] = "old"
        }
    }

    /// The main composer, also while a thread view shows. The thread has its own field, which takes focus.
    func composer() throws -> FieldInfo? {
        world.with { FieldInfo(ref: Self.composer, value: world.values[Self.composer] ?? "", owningBubble: nil) }
    }

    func editField() throws -> FieldInfo? {
        world.with {
            guard let run = world.editOpenFor else { return nil }
            return FieldInfo(ref: Self.edit, value: world.values[Self.edit] ?? "", owningBubble: Self.bubbleRef(run))
        }
    }

    func focusedField() throws -> FieldInfo? {
        world.with {
            if world.threadOpenFor != nil {
                return FieldInfo(ref: Self.threadComposer, value: world.values[Self.threadComposer] ?? "",
                                 owningBubble: nil)
            }
            if let run = world.editOpenFor {
                return FieldInfo(ref: Self.edit, value: world.values[Self.edit] ?? "", owningBubble: Self.bubbleRef(run))
            }
            return FieldInfo(ref: Self.composer, value: world.values[Self.composer] ?? "", owningBubble: nil)
        }
    }

    func threadView() throws -> ThreadViewInfo? {
        world.with {
            guard let run = world.threadOpenFor else { return nil }
            let parent = World.parent(run)
            return ThreadViewInfo(ref: AXRef(id: 4), parent: Harness.parentBubble(for: parent))
        }
    }

    func showsMainTranscript() throws -> Bool { world.with { world.editOpenFor == nil && world.threadOpenFor == nil } }

    func menuItem(titled title: String) throws -> MenuItemInfo? {
        MenuItemInfo(ref: AXRef(id: 5), title: title, enabled: true)
    }

    func press(menuItem: AXRef, finalCheck: AXFinalCheck) throws {
        try finalCheck()
        world.with {
            world.threadOpenFor = world.selected
            world.values[Self.threadComposer] = ""
        }
    }

    func setValue(_ value: String, of field: AXRef, finalCheck: AXFinalCheck) throws {
        try finalCheck()
        world.with {
            world.values[field] = value
            if let run = world.selected { world.typedByRun[run] = value }
        }
    }

    func readValue(of field: AXRef) throws -> String {
        try world.with { () -> Result<String, Error> in
            guard let value = world.values[field] else { return .failure(ScriptedAX.Failure()) }
            return .success(value)
        }.get()
    }
}

final class WorldKeys: KeyPosting {
    let world: World
    init(_ world: World) { self.world = world }

    func post(_ key: ForegroundKey, toPID pid: Int32) -> Bool {
        world.with {
            switch key {
            case .returnKey:
                if world.editOpenFor != nil { world.editOpenFor = nil } else { world.values[WorldAX.threadComposer] = "" }
            case .escape:
                world.editOpenFor = nil
                world.threadOpenFor = nil
            }
        }
        return true
    }
}

final class WorldTargeting: ChatTargeting {
    let world: World
    init(_ world: World) { self.world = world }

    func selectChat(_ chat: ResolvedChat) -> ChatSelection {
        world.with { world.selected = World.run(of: chat) }
        return .selected
    }

    func verifySelected(_ chat: ResolvedChat, excluding rowid: Int64?) -> Bool {
        world.with { world.selected == World.run(of: chat) }
    }

    func selectionExpectation(_ chat: ResolvedChat, excluding rowid: Int64?) -> SelectionExpectation? {
        SelectionExpectation(chat: chat, signature: [], bound: nil)
    }

    func verifySelected(_ expected: SelectionExpectation) -> Bool {
        verifySelected(expected.chat, excluding: nil)
    }

    func findLoadedBubble(_ target: MessageTargetInfo) -> BubbleLookup { findBubble(target) }

    func findBubble(_ target: MessageTargetInfo) -> BubbleLookup {
        let run = Int(target.rowid - 1000)
        return .found(BubbleInfo(ref: WorldAX.bubbleRef(run), fromMe: true, text: target.body, minuteLabel: "",
                                 hasTextBubble: true, actionNames: [UINames.edit]))
    }
}

final class WorldSource: UITargetSource {
    let world: World
    init(_ world: World) { self.world = world }

    func conversations() throws -> [ConversationSummary] { [] }
    func conversation(for chat: ResolvedChat) throws -> ConversationSummary? { nil }
    func messageTarget(rowid: Int64) throws -> MessageTargetInfo? { nil }
    func sameBodyAndMinuteCount(for target: MessageTargetInfo) throws -> Int { 1 }
    func currentUserReaction(messageGUID: String, part: Int) throws -> TapbackKind? { nil }
    func reactionRows(aboveRowID rowid: Int64, targetGUID: String, part: Int) throws -> [ReactionRowProbe] { [] }
    func editState(rowid: Int64) throws -> EditStateProbe? {
        EditStateProbe(rowid: rowid, dateEditedNs: rowid, dateRetractedNs: 0, body: "old")
    }
    func newestIncoming(for chat: ResolvedChat) throws -> MessageTargetInfo? { World.parent(World.run(of: chat)) }
    func maxMessageRowID() throws -> Int64 { 0 }
}

/// Each read returns a new ROWID, recorded against the selected chat's run.
final class WorldRows: SendRowSource {
    let world: World
    init(_ world: World) { self.world = world }

    func maxMessageRowID() throws -> Int64 {
        world.with {
            world.maxRowID += 1
            if let run = world.selected { world.snapshots[run] = world.maxRowID }
            return world.maxRowID
        }
    }

    func fromMeRows(aboveRowID rowid: Int64, limit: Int) throws -> [SentRowProbe] { [] }
    func sentRow(rowid: Int64) throws -> SentRowProbe? { nil }
    func transferStates(transferNames: [String]) throws -> [String: Int] { [:] }
    func canonicalChatID(chatRowID: Int64) throws -> CanonicalChatID? { nil }
}

/// Edit: ok only for the run's own date_edited. Reply: records the snapshot it got against the chat's run.
final class WorldVerifier: ForegroundVerifying {
    let world: World
    init(_ world: World) { self.world = world }

    func verifyEdit(rowid: Int64, dateEditedBeforeNs: AppleNanos, newTextDigest: String,
                    timeout: TimeInterval) -> ActionResult {
        rowid == dateEditedBeforeNs ? ActionResult(.ok) : ActionResult(.mayHaveCompleted)
    }

    func verifyReply(snapshot: SendSnapshot, chat: ResolvedChat, textDigest: String, parentGUID: String,
                     timeout: TimeInterval) -> ActionResult {
        verifyReplyRow(snapshot: snapshot, chat: chat, textDigest: textDigest, parentGUID: parentGUID,
                       timeout: timeout).result
    }

    func verifyReplyRow(snapshot: SendSnapshot, chat: ResolvedChat, textDigest: String, parentGUID: String,
                        timeout: TimeInterval) -> ReplyVerification {
        world.with { world.verified[World.run(of: chat)] = snapshot.maxRowID }
        guard parentGUID == World.parent(World.run(of: chat)).guid else {
            return ReplyVerification(result: ActionResult(.mayHaveCompleted), rowGUID: nil)
        }
        return ReplyVerification(result: ActionResult(.submitted), rowGUID: "row-" + textDigest)
    }
}
