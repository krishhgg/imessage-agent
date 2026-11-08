import XCTest
import IMCore
import IMStore
@testable import IMUI
import IMTestSupport

/// Window rules after `prepare`: the user may show Messages while the bridge opens the chat, and the bridge must then
/// press nothing more (section 4, Window rules).
final class HiddenActionFlowTests: XCTestCase {
    let bubble = Make.bubble(51, text: "on my way", minute: "12:29 AM",
                             actions: UINames.classicTapbacks + [UINames.undoSend])
    let shown = Make.state(hidden: false, ax: 1, onScreen: 1)

    // MARK: - The predicate

    func testOnlyTheProceedStateAllowsAHiddenAction() {
        XCTAssertTrue(WindowRules.allowsHiddenAction(Make.readyState))
        let others: [MessagesAppState] = [
            .notRunning, Make.state(hidden: false, ax: 1), Make.state(frontmost: true), Make.state(onScreen: 1),
            Make.state(onScreen: -1), Make.state(ax: 0), Make.state(ax: -1), Make.state(ax: 2),
            Make.state(hidden: false, ax: 0),
        ]
        for state in others {
            XCTAssertFalse(WindowRules.allowsHiddenAction(state), "\(state)")
            XCTAssertNotEqual(WindowRules.decide(state), .proceed, "\(state)")
        }
    }

    func testRecheckReadsOnlyAndReturnsTheBusyResult() {
        let rig = Rig()
        XCTAssertNil(rig.windows.recheck())
        rig.app.current = shown
        XCTAssertEqual(rig.windows.recheck(), .messagesOpen)
        XCTAssertEqual(rig.windows.recheck()?.rendered, "busy: Messages is open fix: hide Messages (⌘H) and retry")
        rig.app.current = Make.state(ax: 2)
        XCTAssertEqual(rig.windows.recheck(), ActionResult(.busy(.messagesOpen)))
        rig.app.current = Make.state(frontmost: true)
        XCTAssertEqual(rig.windows.recheck()?.code, .busy(.messagesOpen))
        rig.app.current = .notRunning
        XCTAssertEqual(rig.windows.recheck(), ActionResult(.noHiddenWindow))
        XCTAssertTrue(rig.app.calls.isEmpty, "recheck never launches, quits or hides")
        XCTAssertTrue(rig.clock.sleeps.isEmpty)
    }

    func testRecheckFillsAnUnknownWindowCountFromAX() {
        let rig = Rig(state: Make.state(ax: -1))
        XCTAssertNil(rig.windows.recheck(), "AX counts one window")
        rig.ax.windows = 2
        XCTAssertEqual(rig.windows.recheck(), ActionResult(.busy(.messagesOpen)))
    }

    /// What Messages shows by the end of the fallback AX read, after a state that was hidden with no AX count and no
    /// window on screen, and the result the window rules then give.
    static let changesDuringTheFallbackRead: [(String, MessagesAppState, ActionResult)] = [
        ("unhidden, AX still unknown", Make.state(hidden: false, ax: -1, onScreen: 1), .messagesOpen),
        ("unhidden, AX counts again", Make.state(hidden: false, ax: 1, onScreen: 1), .messagesOpen),
        ("two AX windows", Make.state(hidden: true, ax: 2, anySpace: -1), ActionResult(.busy(.messagesOpen))),
        ("quit", .notRunning, ActionResult(.noHiddenWindow)),
    ]

    func testRecheckSamplesTheStateAgainAfterTheFallbackWindowCount() {
        for (name, during, expected) in Self.changesDuringTheFallbackRead {
            let rig = Rig(state: Make.state(hidden: true, ax: -1, onScreen: 0))
            rig.ax.windows = 1
            rig.ax.onWindowCount = { rig.app.current = during }
            XCTAssertEqual(rig.windows.recheck(), expected, name)
            XCTAssertTrue(rig.app.calls.isEmpty, name)
        }
    }

    func testBubbleActionPressesNothingWhenMessagesIsShownDuringTheRechecksFallbackRead() {
        let rig = Rig(state: Make.state(hidden: true, ax: -1, onScreen: 0))
        let (_, tapbacks, _) = runners(rig)
        let unhidden = Make.state(hidden: false, ax: -1, onScreen: 1)
        // Armed inside the press, so the fallback read that the final check's recheck makes is the one the user
        // unhides Messages during.
        rig.ax.beforePerformRevalidation = { rig.ax.onWindowCount = { rig.app.current = unhidden } }
        let request = TapbackRequest(target: Make.target(), chat: Make.chat(), kind: .heart, remove: false)
        let result = tapbacks.run(request, queueDeadline: rig.clock.uptime + 30, recorder: rig.recorder)
        XCTAssertEqual(result.result.code, .busy(.messagesOpen))
        XCTAssertEqual(result.result.fix, "hide Messages (⌘H) and retry")
        XCTAssertTrue(rig.ax.performed.isEmpty)
        XCTAssertFalse(rig.log.contains("ax.perform"))
        XCTAssertFalse(rig.app.calls.contains(.hide), "the user's window is never hidden")
    }

    // MARK: - Before the named action

    func runners(_ rig: Rig) -> (FakeTargeting, TapbackRunner, UnsendRunner) {
        let targeting = FakeTargeting(log: rig.log, bubble: bubble)
        let tapbacks = TapbackRunner(ax: rig.ax, windows: rig.windows, targeting: targeting, source: rig.source,
                                     clock: rig.clock)
        let unsend = UnsendRunner(ax: rig.ax, windows: rig.windows, targeting: targeting, source: rig.source,
                                  clock: rig.clock)
        return (targeting, tapbacks, unsend)
    }

    func testTapbackStopsWhenTheUserShowsMessagesAfterPrepare() {
        let rig = Rig()
        let (targeting, tapbacks, _) = runners(rig)
        let shown = self.shown
        targeting.onSelect = { rig.app.current = shown }
        let request = TapbackRequest(target: Make.target(), chat: Make.chat(), kind: .heart, remove: false)
        let result = tapbacks.run(request, queueDeadline: rig.clock.uptime + 30, recorder: rig.recorder)
        XCTAssertEqual(result.result.code, .busy(.messagesOpen))
        XCTAssertEqual(result.result.fix, "hide Messages (⌘H) and retry")
        XCTAssertTrue(result.result.notes.contains(.mayHaveMarkedRead), "the chat row was pressed")
        XCTAssertFalse(result.result.holdsIdempotencyKey)
        XCTAssertTrue(result.pressed)
        XCTAssertTrue(rig.ax.performed.isEmpty)
        XCTAssertFalse(rig.log.contains("ax.perform"))
        XCTAssertFalse(rig.log.contains("db.reactionRows"), "nothing ran, so nothing to verify")
        XCTAssertEqual(rig.recorder.facts.count, 1, "the entry reached invoking")
        XCTAssertEqual(rig.recorder.didInvokeCount, 0, "nothing was pressed, so the entry never reaches invoked")
        XCTAssertFalse(rig.app.calls.contains(.hide), "the user's window is never hidden")
    }

    func testUnsendStopsWhenTheUserShowsMessagesAfterPrepare() {
        let rig = Rig()
        let (targeting, _, unsend) = runners(rig)
        let shown = self.shown
        targeting.onSelect = { rig.app.current = shown }
        let result = unsend.run(target: Make.target(), chat: Make.chat(), queueDeadline: rig.clock.uptime + 30,
                                recorder: rig.recorder)
        XCTAssertEqual(result.result.code, .busy(.messagesOpen))
        XCTAssertTrue(result.pressed)
        XCTAssertTrue(rig.ax.performed.isEmpty)
        XCTAssertFalse(rig.log.contains("ax.perform"))
        XCTAssertEqual(rig.recorder.facts.count, 1, "the entry reached invoking")
        XCTAssertEqual(rig.recorder.didInvokeCount, 0, "nothing was pressed, so the entry never reaches invoked")
        XCTAssertFalse(result.result.holdsIdempotencyKey)
        XCTAssertFalse(rig.app.calls.contains(.hide))
    }

    func testStillHiddenAtTheRecheckPresses() {
        let rig = Rig()
        let (_, tapbacks, _) = runners(rig)
        let request = TapbackRequest(target: Make.target(), chat: Make.chat(), kind: .heart, remove: false)
        _ = tapbacks.run(request, queueDeadline: rig.clock.uptime + 30, recorder: rig.recorder)
        XCTAssertEqual(rig.ax.performed.map(\.action), ["Heart"])
    }

    func testRealTargeterThenUserShowsMessagesBeforeTheAction() {
        let rig = Rig()
        rig.source.summaries = [Make.summary()]
        rig.ax.rows = [Make.row(2, "Jordan, see you, 12:20 AM")]
        let transcript = [Make.bubble(51, fromMe: true, text: "on my way", minute: "12:29 AM", actions: ["Heart"]),
                          Make.bubble(52, fromMe: false, text: "see you", minute: "12:20 AM")]
        rig.ax.bubbles = { [unowned ax = rig.ax] in ax.pressedRows.isEmpty ? [] : transcript }
        let shown = self.shown
        rig.app.onState = { state in
            if rig.log.contains("ax.pressRow") { state = shown }
        }
        let runner = TapbackRunner(ax: rig.ax, windows: rig.windows, targeting: rig.targeter(), source: rig.source,
                                   clock: rig.clock)
        let target = Make.target(body: "on my way", dateNs: Make.nanos(2026, 11, 6, 0, 29))
        let request = TapbackRequest(target: target, chat: Make.chat(), kind: .heart, remove: false)
        let result = runner.run(request, queueDeadline: rig.clock.uptime + 30, recorder: rig.recorder)
        XCTAssertEqual(result.result.code, .busy(.messagesOpen))
        XCTAssertEqual(rig.log.count(of: "ax.pressRow"), 1)
        XCTAssertFalse(rig.log.contains("ax.perform"))
    }

    // MARK: - Before the row press

    func testRowPressRefusedForAShownMessagesIsBusyWithNoMarkReadNote() {
        let rig = Rig()
        rig.source.summaries = [Make.summary()]
        rig.ax.rows = [Make.row(2, "Jordan, see you, 12:20 AM")]
        rig.ax.pressError = .messagesVisible(shown)
        XCTAssertEqual(rig.targeter().selectChat(Make.chat()), .refused(.messagesOpen))

        let runner = TapbackRunner(ax: rig.ax, windows: rig.windows, targeting: rig.targeter(), source: rig.source,
                                   clock: rig.clock)
        let request = TapbackRequest(target: Make.target(), chat: Make.chat(), kind: .heart, remove: false)
        let result = runner.run(request, queueDeadline: rig.clock.uptime + 30, recorder: rig.recorder)
        XCTAssertEqual(result.result, .messagesOpen)
        XCTAssertFalse(result.pressed)
        XCTAssertTrue(rig.ax.pressedRows.isEmpty, "the driver refused the row press")
        XCTAssertFalse(rig.log.contains("ax.perform"))
        XCTAssertTrue(rig.recorder.facts.isEmpty)
    }

    func testRowPressSamplesTheStateAgainAfterTheFallbackWindowCount() {
        for (name, during, expected) in Self.changesDuringTheFallbackRead {
            let rig = Rig(state: Make.state(hidden: true, ax: -1, onScreen: 0))
            rig.source.summaries = [Make.summary()]
            rig.ax.rows = [Make.row(2, "Jordan, see you, 12:20 AM")]
            // The live driver's window rules before the press, over the fakes. Its AX read is `windowCount`, and the
            // user changes Messages during that read.
            rig.ax.beforeRowPress = { [unowned app = rig.app, unowned ax = rig.ax] in
                ax.onWindowCount = { app.current = during }
                try LiveMessagesAX.requireHiddenWindow(HiddenWindowManager.state(of: app, countWindows: {
                    try ax.windowCount()
                }))
            }
            XCTAssertEqual(rig.targeter().selectChat(Make.chat()), .refused(expected), name)
            XCTAssertTrue(rig.ax.pressedRows.isEmpty, "\(name): the driver refused the row press")
        }
    }
}
