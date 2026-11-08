import Foundation
import XCTest
import IMCore
import IMStore
@testable import IMSend
import IMTestSupport

final class MessageSenderTests: XCTestCase {
    private let temp = TempFolders()
    private var clock: FakeClock!
    private var log: EventLog!
    private var rows: ScriptedRowSource!
    private var runner: ScriptedRunner!
    private var app: FakeMessagesApp!
    private var recorder: LoggingRecorder!
    private var stagingDir: URL!
    private var freezer: UploadFreezer!

    private let running = MessagesAppState(isRunning: true, pid: 4242, isFrontmost: false, isHidden: true,
                                           axWindowCount: 1, onScreenWindowCount: 0, allSpacesWindowCount: 1)

    override func setUp() {
        super.setUp()
        clock = FakeClock()
        log = EventLog()
        rows = ScriptedRowSource(clock: clock, maxRowID: 1000)
        rows.log = log
        runner = ScriptedRunner()
        runner.log = log
        app = FakeMessagesApp(current: running)
        recorder = LoggingRecorder()
        recorder.log = log
        let root = temp.make("sender")
        stagingDir = root.appendingPathComponent("Pictures/\(AppIdentity.appName)", isDirectory: true)
        freezer = UploadFreezer(directory: root.appendingPathComponent("uploads", isDirectory: true))
    }

    override func tearDown() {
        temp.removeAll()
        super.tearDown()
    }

    private func sender(staging directory: URL? = nil, scripts: AppleScriptRunning? = nil) -> MessageSender {
        let scripts = scripts ?? runner!
        return MessageSender(scripts: scripts, coldStart: ColdStarter(app: app, scripts: scripts, clock: clock),
                             staging: StagingArea(directory: directory ?? stagingDir, clock: clock, rows: rows),
                             correlator: SendCorrelator(rows: rows, clock: clock), rows: rows, clock: clock)
    }

    private func send(_ text: String?, file: FrozenFile? = nil, chat: ResolvedChat = momChat(),
                      staging directory: URL? = nil) -> SendResult {
        sender(staging: directory).send(SendRequest(chat: chat, text: text, file: file), recorder: recorder)
    }

    private func frozen(_ name: String = "Report.pdf") throws -> FrozenFile {
        try freeze(Data("file bytes".utf8), name: name, with: freezer)
    }

    /// Messages answering each send handler with a row in chat.db `after` seconds later, the way a real send does.
    /// Text rows carry the sent text, file rows the last path component of the staged file. A 1:1 row joins `joined`.
    private func messagesWritesRows(after delay: TimeInterval = 0.5, delivered: Bool = true, joined: Int64 = 7,
                                    outcome: AppleScriptOutcome = AppleScriptOutcome(ok: true, value: "sent")) {
        var next: Int64 = 1001
        runner.respond = { [unowned self] handler, args in
            let rowid = next
            next += 1
            let stamp = delivered ? deliveredStamp(clock.now) : 0
            switch handler {
            case .sendText:
                rows.addAfter(delay, row(rowid, after: clock.now, handle: args[0], service: args[2], body: args[1],
                                         deliveredNs: stamp, joined: joined))
            case .sendFile:
                let name = URL(fileURLWithPath: args[1]).lastPathComponent
                rows.addAfter(delay, row(rowid, after: clock.now, handle: args[0], service: args[2],
                                         transferNames: [name], transferStates: [name: 5], deliveredNs: stamp,
                                         joined: joined))
            case .sendChatText:
                // A group's from_me row has no handle. Only its join row ties it to the chat.
                rows.addAfter(delay, row(rowid, after: clock.now, handle: nil, body: args[1], deliveredNs: stamp,
                                         joined: 12))
            case .sendChatFile:
                let name = URL(fileURLWithPath: args[1]).lastPathComponent
                rows.addAfter(delay, row(rowid, after: clock.now, handle: nil, transferNames: [name],
                                         transferStates: [name: 5], deliveredNs: stamp, joined: 12))
            default:
                break
            }
            return outcome
        }
    }

    private func codes(_ result: SendResult) -> [ActionResult] { result.parts.map(\.result) }

    // MARK: Group sends

    func testGroupSendAddressesTheChatByItsGUID() throws {
        messagesWritesRows()
        let group = familyGroup()
        let result = send("hi all", file: try frozen(), chat: group)

        XCTAssertEqual(runner.handlers(), [.sendChatText, .sendChatFile])
        XCTAssertEqual(runner.calls[0].1, ["any;+;chat836828054889214904", "hi all"])
        let staged = try XCTUnwrap(filesIn(stagingDir).first)
        XCTAssertEqual(runner.calls[1].1, ["any;+;chat836828054889214904", stagingDir.appendingPathComponent(staged).path])
        XCTAssertFalse(runner.calls.contains { $0.0 == .sendText || $0.0 == .sendFile }, "no participant addressing")
        XCTAssertEqual(log.all, ["maxMessageRowID", "willInvoke", "call send_chat_text", "call send_chat_file",
                                 "didInvoke"])
        XCTAssertEqual(codes(result), [ActionResult(.delivered), ActionResult(.delivered)])
        XCTAssertEqual(result.parts.map(\.rowid), [1001, 1002])
    }

    func testGroupRowCountsOnlyOnceItsJoinRowNamesTheGroup() {
        runner.respond = { [unowned self] _, args in
            // The row lands unjoined, then its join row shows 2 s later.
            rows.addAfter(0.5, row(1001, after: clock.now, handle: nil, body: args[1],
                                   deliveredNs: deliveredStamp(clock.now), joined: nil))
            rows.addAfter(2.5, row(1001, after: clock.now, handle: nil, body: args[1],
                                   deliveredNs: deliveredStamp(clock.now), joined: 12))
            return AppleScriptOutcome(ok: true, value: "sent")
        }
        let result = send("hi all", chat: familyGroup())
        XCTAssertEqual(codes(result), [ActionResult(.delivered)], "no chat unconfirmed note once the join shows")
        XCTAssertEqual(result.parts.first?.rowid, 1001)
    }

    func testGroupRowJoinedToAnotherChatIsNotTheSend() {
        runner.respond = { [unowned self] _, args in
            rows.addAfter(0.5, row(1001, after: clock.now, handle: nil, body: args[1],
                                   deliveredNs: deliveredStamp(clock.now), joined: 7))
            return AppleScriptOutcome(ok: true, value: "sent")
        }
        let result = send("hi all", chat: familyGroup())
        XCTAssertEqual(codes(result), [ActionResult(.mayHaveCompleted)])
        XCTAssertNil(result.parts.first?.rowid)
    }

    func testGroupWithNoChatGUIDIsABadRequestAndSendsNothing() {
        var group = familyGroup()
        group.chatGUIDs = []
        let result = send("hi all", chat: group)
        XCTAssertEqual(codes(result), [MessageSender.badRequest])
        XCTAssertTrue(runner.calls.isEmpty)
        XCTAssertTrue(recorder.facts.isEmpty)
    }

    func testRefusedGroupEventWithNoRowIsAutomationNotAllowed() {
        runner.respond = { _, _ in AppleScriptOutcome(ok: false, errorNumber: -1743, errorMessage: "not allowed") }
        let result = send("hi all", chat: familyGroup())
        XCTAssertEqual(runner.handlers(), [.sendChatText])
        XCTAssertEqual(codes(result), [MessageSender.automationNotAllowed])
    }

    // MARK: Snapshot and journal before the Apple Event

    func testSnapshotThenJournalThenAppleEventsInOrder() throws {
        messagesWritesRows()
        let result = send("see you at 6", file: try frozen())

        XCTAssertEqual(log.all, ["maxMessageRowID", "willInvoke", "call send_text", "call send_file", "didInvoke"])
        XCTAssertEqual(recorder.facts.count, 1)
        XCTAssertEqual(recorder.facts[0].snapshotRowID, 1000)
        let staged = filesIn(stagingDir)
        XCTAssertEqual(staged.count, 1)
        XCTAssertEqual(recorder.facts[0].transferNames, staged)
        XCTAssertEqual(runner.calls[1].1[1], stagingDir.appendingPathComponent(staged[0]).path)
        XCTAssertEqual(codes(result), [ActionResult(.delivered), ActionResult(.delivered)])
    }

    func testSnapshotIsTakenBeforeTheAppleEvent() {
        messagesWritesRows(after: 0)
        let result = send("see you at 6")

        XCTAssertEqual(recorder.facts.first?.snapshotRowID, 1000, "the row the send wrote is above the snapshot")
        XCTAssertEqual(result.parts.first?.rowid, 1001)
        XCTAssertEqual(codes(result), [ActionResult(.delivered)])
    }

    func testJournalWriteFailureSendsNothingAndRemovesTheStagedCopy() throws {
        recorder.failWillInvoke = true
        messagesWritesRows()
        let result = send("see you at 6", file: try frozen())

        XCTAssertEqual(codes(result), [MessageSender.journalWriteFailed, MessageSender.journalWriteFailed])
        XCTAssertTrue(runner.calls.isEmpty)
        XCTAssertEqual(recorder.didInvokeCount, 0)
        XCTAssertEqual(rows.callLog, ["maxMessageRowID"])
        XCTAssertTrue(filesIn(stagingDir).isEmpty)
    }

    func testUnreadableChatDBSendsNothingAndRemovesTheStagedCopy() throws {
        rows.failMaxRowID = true
        messagesWritesRows()
        let result = send("see you at 6", file: try frozen())

        XCTAssertEqual(codes(result), [MessageSender.chatDBUnreadable, MessageSender.chatDBUnreadable])
        XCTAssertTrue(runner.calls.isEmpty)
        XCTAssertTrue(recorder.facts.isEmpty)
        XCTAssertTrue(filesIn(stagingDir).isEmpty)
    }

    func testStagingFailureSendsNothing() throws {
        let blocked = temp.make("blocked").appendingPathComponent("not-a-folder")
        try Data("x".utf8).write(to: blocked)
        messagesWritesRows()
        let result = send("see you at 6", file: try frozen(), staging: blocked)

        XCTAssertEqual(codes(result), [MessageSender.stagingFailed, MessageSender.stagingFailed])
        XCTAssertTrue(runner.calls.isEmpty)
        XCTAssertTrue(recorder.facts.isEmpty)
        XCTAssertTrue(rows.callLog.isEmpty)
    }

    func testMessagesTmpStagingFolderIsNeverUsed() throws {
        messagesWritesRows()
        let forbidden = URL(fileURLWithPath: "/private/var/tmp/com.apple.messages/iMessage Agent", isDirectory: true)
        let result = send(nil, file: try frozen(), staging: forbidden)

        XCTAssertEqual(codes(result), [MessageSender.stagingFailed])
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testDidInvokeFailureKeepsTheResult() {
        recorder.failDidInvoke = true
        messagesWritesRows()
        let result = send("see you at 6")

        XCTAssertEqual(recorder.didInvokeCount, 1)
        XCTAssertEqual(codes(result), [ActionResult(.delivered)])
    }

    // MARK: The AppleScript result is never the send result

    func testScriptSuccessWithNoRowIsMayHaveCompleted() {
        let start = clock.uptime
        let result = send("see you at 6")

        XCTAssertEqual(runner.handlers(), [.sendText])
        XCTAssertEqual(codes(result), [ActionResult(.mayHaveCompleted)])
        XCTAssertNil(result.parts[0].rowid)
        XCTAssertTrue(result.sentGUIDs.isEmpty)
        XCTAssertEqual(clock.uptime - start, Limits.correlationTimeout, accuracy: 1e-9)
    }

    func testScriptErrorWithADeliveredRowIsDelivered() {
        messagesWritesRows(outcome: AppleScriptOutcome(ok: false, errorNumber: -1712, errorMessage: "timed out"))
        let result = send("see you at 6")

        XCTAssertEqual(codes(result), [ActionResult(.delivered)])
        XCTAssertEqual(result.parts[0].guid, "GUID-1001")
    }

    func testScriptErrorsOtherThanAnAutomationRefusalWithNoRowStayMayHaveCompleted() {
        let others = [AppleScriptOutcome(ok: false, errorNumber: -1712, errorMessage: "timed out"),
                      AppleScriptOutcome(ok: false, errorNumber: -1728, errorMessage: "Can't get account"),
                      AppleScriptOutcome(ok: false, errorNumber: nil, errorMessage: "script not compiled")]
        for outcome in others {
            runner.respond = { _, _ in outcome }
            let result = send("see you at 6")
            XCTAssertEqual(codes(result), [ActionResult(.mayHaveCompleted)], "\(outcome)")
            XCTAssertTrue(result.parts[0].result.holdsIdempotencyKey)
        }
    }

    // MARK: Automation refused

    func testAutomationRefusalWithNoRowIsAnErrorThatHoldsNoKeyAndARetryRunsAgain() {
        let scripts = FakeAppleScriptRunner()
        let request = SendRequest(chat: momChat(), text: "see you at 6", file: nil)
        for errorNumber in [-1743, -1744] {
            scripts.outcomes = [AppleScriptOutcome(ok: false, errorNumber: errorNumber,
                                                   errorMessage: "Not authorized to send Apple events to Messages.")]
            let before = scripts.calls.count
            let result = sender(scripts: scripts).send(request, recorder: recorder)

            XCTAssertEqual(scripts.calls.count, before + 1, "the identical request ran again")
            XCTAssertEqual(scripts.calls.last?.0, .sendText)
            XCTAssertEqual(codes(result), [MessageSender.automationNotAllowed])
            XCTAssertEqual(result.parts[0].result.rendered,
                           "error: Messages automation not allowed fix: run imessage doctor")
            XCTAssertFalse(result.parts[0].result.holdsIdempotencyKey)
            XCTAssertNil(result.parts[0].rowid)
            XCTAssertTrue(result.sentGUIDs.isEmpty)
        }
        XCTAssertEqual(scripts.calls.count, 2)
        XCTAssertEqual(recorder.facts.count, 2)
    }

    func testAutomationRefusalIsDecidedPerPart() throws {
        let refused = AppleScriptOutcome(ok: false, errorNumber: -1743)
        messagesWritesRows()
        let writesRows = runner.respond
        runner.respond = { handler, args in
            handler == .sendText ? refused : writesRows(handler, args)
        }
        let result = send("see you at 6", file: try frozen())

        XCTAssertEqual(runner.handlers(), [.sendText, .sendFile])
        XCTAssertEqual(codes(result), [MessageSender.automationNotAllowed, ActionResult(.delivered)])
        XCTAssertEqual(result.parts.map(\.rowid), [nil, 1001])
        XCTAssertEqual(result.sentGUIDs, ["GUID-1001"])
    }

    func testAutomationRefusalWithAMatchedRowKeepsChatDBsResult() {
        messagesWritesRows(outcome: AppleScriptOutcome(ok: false, errorNumber: -1743))
        let result = send("see you at 6")
        XCTAssertEqual(codes(result), [ActionResult(.delivered)])
        XCTAssertEqual(result.sentGUIDs, ["GUID-1001"])

        setUp()
        runner.respond = { [unowned self] handler, _ in
            if handler == .sendText {
                for rowid: Int64 in [1001, 1002] {
                    rows.addAfter(0.5, row(rowid, after: clock.now, body: "see you at 6"))
                }
            }
            return AppleScriptOutcome(ok: false, errorNumber: -1744)
        }
        XCTAssertEqual(codes(send("see you at 6")), [ActionResult(.ambiguous(.twoRowsMatched))])
    }

    func testAutomationRefusalWithOnlyAGhostRowIsTheErrorAndReportsNoRow() {
        runner.respond = { [unowned self] _, _ in
            rows.addAfter(0.5, row(1001, after: clock.now, service: "SMS", joined: nil))
            return AppleScriptOutcome(ok: false, errorNumber: -1743)
        }
        let result = send("see you at 6", chat: momChat(service: "SMS"))
        XCTAssertEqual(codes(result), [MessageSender.automationNotAllowed])
        XCTAssertNil(result.parts[0].rowid)
        XCTAssertNil(result.parts[0].guid)
        XCTAssertTrue(result.sentGUIDs.isEmpty)

        setUp()
        runner.respond = { [unowned self] _, _ in
            rows.addAfter(0.5, row(1001, after: clock.now, service: "SMS", joined: nil))
            return AppleScriptOutcome(ok: true, value: "sent")
        }
        XCTAssertEqual(codes(send("see you at 6", chat: momChat(service: "SMS"))), [ActionResult(.ghost)])
    }

    func testAutomationRefusalWindowNoteStaysOnTheError() {
        app = FakeMessagesApp()
        var shown = running
        shown.onScreenWindowCount = 1
        app.onCall = { call, state in if call == .launchHidden { state = shown } }
        runner.respond = { handler, _ in
            handler == .accountReady ? AppleScriptOutcome(ok: true, value: "1")
                : AppleScriptOutcome(ok: false, errorNumber: -1743)
        }
        let result = send("see you at 6")
        XCTAssertEqual(codes(result), [ActionResult(.error(.message("Messages automation not allowed")),
                                                    notes: [.messagesBecameVisible], fix: "run imessage doctor")])
        XCTAssertFalse(result.parts[0].result.holdsIdempotencyKey)
    }

    // MARK: Arguments

    func testHandlerArgumentsAreTheHandleTextAndServiceVerbatim() {
        let text = "  he said \"hi\" & \\ \n bye "
        messagesWritesRows()
        _ = send(text)
        XCTAssertEqual(runner.calls.map(\.0), [.sendText])
        XCTAssertEqual(runner.calls[0].1, [Handles.mom, text, "iMessage"])
    }

    func testSMSChatUsesSMSForColdStartAndSend() {
        app = FakeMessagesApp()
        let hidden = running
        app.onCall = { call, state in if call == .launchHidden { state = hidden } }
        let base = runner.respond
        runner.respond = { handler, args in
            handler == .accountReady ? AppleScriptOutcome(ok: true, value: "1") : base(handler, args)
        }
        _ = send("see you at 6", chat: momChat(service: "SMS"))

        XCTAssertEqual(runner.calls.map(\.0), [.accountReady, .sendText])
        XCTAssertEqual(runner.calls[0].1, ["SMS"])
        XCTAssertEqual(runner.calls[1].1.last, "SMS")
    }

    func testSelfChatSendsToTheSendHandle() {
        messagesWritesRows(joined: 2)
        let result = send("note to self", chat: selfChat())
        XCTAssertEqual(runner.calls.first?.1.first, Handles.owner)
        XCTAssertEqual(codes(result), [ActionResult(.delivered)])
    }

    // MARK: Bad requests

    func testWhitespaceOnlyTextIsABadRequest() {
        let result = send(" \n\t ")
        XCTAssertEqual(result.parts.map(\.part), [.text])
        XCTAssertEqual(codes(result), [MessageSender.badRequest])
        XCTAssertTrue(runner.calls.isEmpty)
        XCTAssertTrue(rows.callLog.isEmpty)
        XCTAssertTrue(recorder.facts.isEmpty)
    }

    func testNoTextAndNoFileIsABadRequest() {
        XCTAssertEqual(codes(send(nil)), [MessageSender.badRequest])
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testWhitespaceTextWithAFileSendsOnlyTheFile() throws {
        messagesWritesRows()
        let result = send("   ", file: try frozen())
        XCTAssertEqual(result.parts.map(\.part), [.file])
        XCTAssertEqual(runner.handlers(), [.sendFile])
        XCTAssertEqual(codes(result), [ActionResult(.delivered)])
    }

    func testOneToOneChatWithNoSendHandleIsABadRequest() {
        for handle in [nil, ""] as [String?] {
            var chat = momChat()
            chat.sendHandle = handle
            XCTAssertEqual(codes(send("hi", chat: chat)), [MessageSender.badRequest])
        }
        XCTAssertTrue(runner.calls.isEmpty)
        XCTAssertTrue(app.calls.isEmpty)
    }

    func testEveryEarlyResultIsOneLineWithAFixAndHoldsNoKey() {
        let lines = [
            MessageSender.badRequest: "error: bad request fix: send text or --file to a phone number or email",
            MessageSender.journalWriteFailed: "error: journal write failed fix: free disk space and retry",
            MessageSender.chatDBUnreadable: "error: can't read chat.db fix: run imessage doctor",
            MessageSender.stagingFailed: "error: file staging failed fix: check that ~/Pictures/iMessage Agent is writable",
            MessageSender.groupUnsupported: "unsupported fix: send to each person on their own",
            MessageSender.automationNotAllowed: "error: Messages automation not allowed fix: run imessage doctor",
        ]
        for (result, line) in lines {
            XCTAssertEqual(result.rendered, line)
            XCTAssertFalse(result.rendered.contains("\n"))
            XCTAssertFalse(result.holdsIdempotencyKey, line)
        }
        XCTAssertFalse(ActionResult(.failed(.messagesNotReady), notes: [.messagesBecameVisible]).holdsIdempotencyKey)
    }

    // MARK: Cold start

    func testMessagesNotReadyFailsEveryPartAndSendsNothing() throws {
        app = FakeMessagesApp()
        let hidden = running
        app.onCall = { call, state in if call == .launchHidden { state = hidden } }
        runner.respond = { _, _ in AppleScriptOutcome(ok: true, value: "0") }
        let result = send("see you at 6", file: try frozen())

        XCTAssertEqual(app.calls, [.launchHidden])
        XCTAssertEqual(codes(result), [ActionResult(.failed(.messagesNotReady)),
                                       ActionResult(.failed(.messagesNotReady))])
        XCTAssertEqual(result.parts[0].result.rendered, "failed: Messages not ready")
        XCTAssertTrue(runner.handlers().allSatisfy { $0 == .accountReady })
        XCTAssertTrue(recorder.facts.isEmpty)
        XCTAssertTrue(rows.callLog.isEmpty)
        XCTAssertTrue(filesIn(stagingDir).isEmpty)
    }

    func testWindowOnColdStartIsNotedOnEveryPart() throws {
        app = FakeMessagesApp()
        var shown = running
        shown.onScreenWindowCount = 1
        app.onCall = { call, state in if call == .launchHidden { state = shown } }
        messagesWritesRows()
        let base = runner.respond
        runner.respond = { handler, args in
            handler == .accountReady ? AppleScriptOutcome(ok: true, value: "1") : base(handler, args)
        }
        let result = send("see you at 6", file: try frozen())

        XCTAssertEqual(codes(result), [ActionResult(.delivered, notes: [.messagesBecameVisible]),
                                       ActionResult(.delivered, notes: [.messagesBecameVisible])])
        XCTAssertEqual(result.parts[0].result.rendered, "delivered, error: Messages became visible")
    }

    func testWindowOnAColdStartThatTimesOutIsNoted() {
        app = FakeMessagesApp()
        var shown = running
        shown.onScreenWindowCount = 1
        app.onCall = { call, state in if call == .launchHidden { state = shown } }
        runner.respond = { _, _ in AppleScriptOutcome(ok: true, value: "0") }

        XCTAssertEqual(codes(send("see you at 6")),
                       [ActionResult(.failed(.messagesNotReady), notes: [.messagesBecameVisible])])
    }

    func testWarmMessagesGetsNoReadinessCall() {
        messagesWritesRows()
        _ = send("see you at 6")
        XCTAssertFalse(runner.handlers().contains(.accountReady))
        XCTAssertTrue(app.calls.isEmpty)
    }

    // MARK: Messages closed between the cold start and the send

    /// Running when the cold start looks, closed by the time the first handler runs, and running hidden once the
    /// sender launches it again. `shown` is the state the hidden launch leaves.
    private func messagesQuitsAfterTheColdStart(shown: MessagesAppState? = nil) {
        var reads = 0
        app.onState = { state in
            reads += 1
            if reads == 2 { state = .notRunning }
        }
        let launched = shown ?? running
        app.onCall = { call, state in if call == .launchHidden { state = launched } }
    }

    private let closed = AppleScriptOutcome(ok: true, value: SendScripts.notRunning)

    func testAHandlerThatFindsMessagesClosedGetsAHiddenColdStartAndOneRetry() {
        messagesQuitsAfterTheColdStart()
        let scripts = FakeAppleScriptRunner()
        scripts.outcomes = [closed, AppleScriptOutcome(ok: true, value: "1"), AppleScriptOutcome(ok: true, value: "sent")]
        let result = sender(scripts: scripts).send(SendRequest(chat: momChat(), text: "see you at 6", file: nil),
                                                   recorder: recorder)

        XCTAssertEqual(scripts.calls.map(\.0), [.sendText, .accountReady, .sendText])
        let args = [Handles.mom, "see you at 6", "iMessage"]
        XCTAssertEqual(scripts.calls.map(\.1), [args, ["iMessage"], args], "the retry is the same call")
        XCTAssertEqual(app.calls, [.launchHidden], "the hidden launch, never the send's own Apple Event")
        XCTAssertEqual(recorder.facts.count, 1, "invoking is journaled once, before the first call")
        XCTAssertEqual(recorder.didInvokeCount, 1)
        XCTAssertEqual(codes(result), [ActionResult(.mayHaveCompleted)], "this fake writes no row")
    }

    func testTheRetriedSendIsCorrelatedLikeAnyOther() {
        messagesQuitsAfterTheColdStart()
        messagesWritesRows()
        let base = runner.respond
        var first = true
        runner.respond = { [unowned self] handler, args in
            switch handler {
            case .accountReady: return AppleScriptOutcome(ok: true, value: "1")
            case .sendText where first:
                first = false
                return closed
            default: return base(handler, args)
            }
        }
        let result = send("see you at 6")

        XCTAssertEqual(log.all, ["maxMessageRowID", "willInvoke", "call send_text", "call account_ready",
                                 "call send_text", "didInvoke"])
        XCTAssertEqual(codes(result), [ActionResult(.delivered)])
        XCTAssertEqual(result.parts.first?.rowid, 1001)
        XCTAssertEqual(result.sentGUIDs, ["GUID-1001"])
    }

    func testAGroupHandlerThatFindsMessagesClosedIsRetriedToo() {
        messagesQuitsAfterTheColdStart()
        messagesWritesRows()
        let base = runner.respond
        var first = true
        runner.respond = { [unowned self] handler, args in
            switch handler {
            case .accountReady: return AppleScriptOutcome(ok: true, value: "1")
            case .sendChatText where first:
                first = false
                return closed
            default: return base(handler, args)
            }
        }
        let result = send("hi all", chat: familyGroup())

        XCTAssertEqual(runner.handlers(), [.sendChatText, .accountReady, .sendChatText])
        XCTAssertEqual(app.calls, [.launchHidden])
        XCTAssertEqual(codes(result), [ActionResult(.delivered)])
    }

    func testAFileHandlerThatFindsMessagesClosedIsRetriedAfterTheTextWent() throws {
        messagesWritesRows()
        let base = runner.respond
        var fileCalls = 0
        runner.respond = { [unowned self] handler, args in
            switch handler {
            case .accountReady: return AppleScriptOutcome(ok: true, value: "1")
            case .sendFile:
                fileCalls += 1
                if fileCalls == 1 {
                    app.current = .notRunning
                    return closed
                }
                return base(handler, args)
            default: return base(handler, args)
            }
        }
        let launched = running
        app.onCall = { call, state in if call == .launchHidden { state = launched } }
        let result = send("see you at 6", file: try frozen())

        XCTAssertEqual(runner.handlers(), [.sendText, .sendFile, .accountReady, .sendFile])
        XCTAssertEqual(app.calls, [.launchHidden])
        XCTAssertEqual(codes(result), [ActionResult(.delivered), ActionResult(.delivered)])
        XCTAssertEqual(result.parts.map(\.rowid), [1001, 1002])
    }

    func testAColdStartRetryThatTimesOutIsMessagesNotReadyAndSendsNothing() {
        messagesQuitsAfterTheColdStart()
        runner.respond = { [unowned self] handler, _ in
            handler == .accountReady ? AppleScriptOutcome(ok: true, value: "0") : closed
        }
        let result = send("see you at 6")

        XCTAssertEqual(runner.handlers().filter { $0 != .accountReady }, [.sendText], "no retry once it isn't ready")
        XCTAssertEqual(app.calls, [.launchHidden])
        XCTAssertEqual(codes(result), [ActionResult(.failed(.messagesNotReady))])
        XCTAssertFalse(result.parts[0].result.holdsIdempotencyKey, "nothing was sent, so a retry runs again")
        XCTAssertNil(result.parts[0].rowid)
        XCTAssertTrue(result.sentGUIDs.isEmpty)
    }

    func testThereIsOneRetryPerRequest() throws {
        messagesQuitsAfterTheColdStart()
        runner.respond = { [unowned self] handler, _ in
            if handler == .accountReady { return AppleScriptOutcome(ok: true, value: "1") }
            // Messages quits again each time it is asked to send.
            app.current = .notRunning
            return closed
        }
        let result = send("see you at 6", file: try frozen())

        XCTAssertEqual(runner.handlers(), [.sendText, .accountReady, .sendText, .sendFile])
        XCTAssertEqual(app.calls, [.launchHidden], "one hidden cold start, however often Messages quits")
        XCTAssertEqual(codes(result), [ActionResult(.failed(.messagesNotReady)),
                                       ActionResult(.failed(.messagesNotReady))])
    }

    func testAWindowOnTheRetryColdStartIsNotedOnEveryPart() throws {
        var shown = running
        shown.onScreenWindowCount = 1
        messagesQuitsAfterTheColdStart(shown: shown)
        messagesWritesRows()
        let base = runner.respond
        var first = true
        runner.respond = { [unowned self] handler, args in
            switch handler {
            case .accountReady: return AppleScriptOutcome(ok: true, value: "1")
            case .sendText where first:
                first = false
                return closed
            default: return base(handler, args)
            }
        }
        let result = send("see you at 6", file: try frozen())

        XCTAssertEqual(codes(result), [ActionResult(.delivered, notes: [.messagesBecameVisible]),
                                       ActionResult(.delivered, notes: [.messagesBecameVisible])])
    }

    func testOnlyTheNotRunningAnswerTriggersARetry() {
        messagesWritesRows()
        let base = runner.respond
        runner.respond = { handler, args in
            _ = base(handler, args)
            return AppleScriptOutcome(ok: true, value: "0")
        }
        _ = send("see you at 6")
        XCTAssertEqual(runner.handlers(), [.sendText])
        XCTAssertTrue(app.calls.isEmpty)
    }

    // MARK: Separate parts

    func testTextAndFileGetSeparateResultsAndRows() throws {
        var next: Int64 = 1001
        runner.respond = { [unowned self] handler, args in
            let rowid = next
            next += 1
            if handler == .sendText {
                rows.addAfter(0.5, row(rowid, after: clock.now, body: args[1], deliveredNs: deliveredStamp(clock.now)))
            } else if handler == .sendFile {
                let name = URL(fileURLWithPath: args[1]).lastPathComponent
                rows.addAfter(0.5, row(rowid, after: clock.now, transferNames: [name], transferStates: [name: 1]))
                rows.updateAfter(2, rowid: rowid) { $0.transferStates[name] = 6 }
            }
            return AppleScriptOutcome(ok: true)
        }
        let result = send("see you at 6", file: try frozen())

        XCTAssertEqual(result.parts.map(\.part), [.text, .file])
        XCTAssertEqual(codes(result), [ActionResult(.delivered), ActionResult(.failed(.transferFailed))])
        XCTAssertEqual(result.parts.map(\.rowid), [1001, 1002])
        XCTAssertEqual(result.parts.map(\.guid), ["GUID-1001", "GUID-1002"])
        XCTAssertNotNil(result.parts[0].dateDeliveredNs)
        XCTAssertNil(result.parts[1].dateDeliveredNs)
        XCTAssertEqual(result.sentGUIDs, ["GUID-1001", "GUID-1002"])
    }

    func testFileRowIsFoundByTheStagedTransferName() throws {
        messagesWritesRows()
        let result = send(nil, file: try frozen("Q3 report (final).pdf"))
        let path = try XCTUnwrap(runner.calls.first?.1[1])
        let name = URL(fileURLWithPath: path).lastPathComponent

        XCTAssertTrue(name.hasPrefix("Q3_report__final_-"), name)
        XCTAssertTrue(name.hasSuffix(".pdf"), name)
        XCTAssertEqual(recorder.facts.first?.transferNames, [name])
        XCTAssertEqual(codes(result), [ActionResult(.delivered)])
    }

    func testSMSSendStaysSubmitted() {
        messagesWritesRows(delivered: true)
        let result = send("see you at 6", chat: momChat(service: "SMS"))
        XCTAssertEqual(codes(result), [ActionResult(.submitted)])
        XCTAssertEqual(result.sentGUIDs, ["GUID-1001"])
    }
}
