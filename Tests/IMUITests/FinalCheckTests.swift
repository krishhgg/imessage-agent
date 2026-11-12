import XCTest
import IMCore
import IMStore
@testable import IMUI
import IMTestSupport

/// The hidden press's last checks run inside the driver, after its own reads of the bubble and right before
/// `AXUIElementPerformAction` (`AXFinalCheck`). The fake models those reads with `beforePerformRevalidation`.
final class FinalCheckTests: XCTestCase {
    func testExpiryDuringTheDriversPrePressReadsPreventsUndoSend() {
        let helper = UnsendRunnerTests()
        let (rig, _, runner) = helper.setup()
        // 119.5 s old, and the driver's description and action-name reads take 1 s.
        rig.ax.beforePerformRevalidation = { rig.clock.advance(1) }
        let result = helper.run(runner, rig, helper.target(age: 119.5))
        XCTAssertEqual(result.result, ActionResult(.expired, notes: [.mayHaveMarkedRead]))
        XCTAssertTrue(rig.ax.performed.isEmpty, "Undo Send pressed after expiry during the driver's reads")
        XCTAssertFalse(rig.log.contains("ax.perform"))
        // The same state as a window that closes during the journal flush: invoking, never invoked, no key held.
        XCTAssertEqual(rig.recorder.facts.count, 1)
        XCTAssertEqual(rig.recorder.didInvokeCount, 0)
        XCTAssertFalse(result.result.holdsIdempotencyKey)
    }

    func testMessagesShownDuringTheDriversPrePressReadsPreventsTheTapback() {
        let rig = Rig()
        let targeting = FakeTargeting(log: rig.log, bubble: Make.bubble(51, text: "on my way", minute: "12:29 AM",
                                                                       actions: UINames.classicTapbacks))
        let runner = TapbackRunner(ax: rig.ax, windows: rig.windows, targeting: targeting, source: rig.source,
                                   clock: rig.clock)
        rig.ax.beforePerformRevalidation = { rig.app.current = Make.state(hidden: false, ax: 1, onScreen: 1) }
        let request = TapbackRequest(target: Make.target(), chat: Make.chat(), kind: .heart, remove: false)
        let result = runner.run(request, queueDeadline: rig.clock.uptime + 30, recorder: rig.recorder)
        XCTAssertEqual(result.result.code, .busy(.messagesOpen))
        XCTAssertTrue(rig.ax.performed.isEmpty, "Heart pressed on a shown Messages")
        XCTAssertFalse(result.result.holdsIdempotencyKey)
        // Invoking, never invoked, no key held, as for the expired Undo Send above.
        XCTAssertEqual(rig.recorder.facts.count, 1)
        XCTAssertEqual(rig.recorder.didInvokeCount, 0)
        XCTAssertFalse(rig.app.calls.contains(.hide), "the user's window is never hidden")
    }

    func testMessagesShownDuringTheDriversPrePressReadsPreventsUndoSend() {
        let helper = UnsendRunnerTests()
        let (rig, _, runner) = helper.setup()
        rig.ax.beforePerformRevalidation = { rig.app.current = Make.state(hidden: false, ax: 1, onScreen: 1) }
        let result = helper.run(runner, rig, helper.target())
        XCTAssertEqual(result.result.code, .busy(.messagesOpen))
        XCTAssertTrue(rig.ax.performed.isEmpty, "Undo Send pressed on a shown Messages")
        XCTAssertFalse(rig.log.contains("ax.perform"))
        XCTAssertEqual(rig.recorder.facts.count, 1)
        XCTAssertEqual(rig.recorder.didInvokeCount, 0)
        XCTAssertFalse(result.result.holdsIdempotencyKey)
    }

    /// An AX error that comes back from the press itself may follow a press that ran, so the entry still reaches
    /// `invoked`, and with no verifying row the result is `may_have_completed`, which holds the key.
    func testAnErrorAfterTheTapbackPressStillRecordsInvoked() throws {
        let rig = Rig()
        let targeting = FakeTargeting(log: rig.log, bubble: Make.bubble(51, text: "on my way", minute: "12:29 AM",
                                                                       actions: UINames.classicTapbacks))
        let runner = TapbackRunner(ax: rig.ax, windows: rig.windows, targeting: targeting, source: rig.source,
                                   clock: rig.clock)
        rig.ax.performError = .axError(-25204)
        let request = TapbackRequest(target: Make.target(), chat: Make.chat(), kind: .heart, remove: false)
        let result = runner.run(request, queueDeadline: rig.clock.uptime + 30, recorder: rig.recorder)
        XCTAssertEqual(result.result, ActionResult(.mayHaveCompleted, notes: [.mayHaveMarkedRead]))
        XCTAssertTrue(result.result.holdsIdempotencyKey)
        XCTAssertEqual(rig.recorder.facts.count, 1)
        XCTAssertEqual(rig.recorder.didInvokeCount, 1)
        let press = try XCTUnwrap(rig.log.index(of: "ax.perform"))
        XCTAssertLessThan(press, try XCTUnwrap(rig.log.index(of: "journal.didInvoke")))
    }

    func testAnErrorAfterTheUndoSendPressStillRecordsInvoked() throws {
        let helper = UnsendRunnerTests()
        let (rig, _, runner) = helper.setup()
        rig.ax.performError = .axError(-25204)
        let result = helper.run(runner, rig, helper.target())
        XCTAssertEqual(result.result, ActionResult(.mayHaveCompleted, notes: [.mayHaveMarkedRead]))
        XCTAssertTrue(result.result.holdsIdempotencyKey)
        XCTAssertEqual(rig.recorder.facts.count, 1)
        XCTAssertEqual(rig.recorder.didInvokeCount, 1)
        let press = try XCTUnwrap(rig.log.index(of: "ax.perform"))
        XCTAssertLessThan(press, try XCTUnwrap(rig.log.index(of: "journal.didInvoke")))
    }

    func testTheWindowRulesRunBeforeTheCallersCheck() {
        // Both change during the driver's reads: Messages shows and the 2-minute window closes. The window rules
        // come first, so the result is busy, not expired.
        let helper = UnsendRunnerTests()
        let (rig, _, runner) = helper.setup()
        rig.ax.beforePerformRevalidation = {
            rig.app.current = Make.state(hidden: false, ax: 1, onScreen: 1)
            rig.clock.advance(1)
        }
        let result = helper.run(runner, rig, helper.target(age: 119.5))
        XCTAssertEqual(result.result.code, .busy(.messagesOpen))
        XCTAssertTrue(rig.ax.performed.isEmpty)
    }
}
