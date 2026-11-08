import Foundation
import XCTest
@testable import IMForeground
import IMCore
import IMTestSupport
import IMUI

/// Step 6's focus restore when the front app still reads Messages for a moment after `isHidden` turns true, as
/// NSWorkspace updates it on a later run-loop turn.
final class FinishTests: XCTestCase {
    static let windowlessSafari = FrontApp(bundleID: "com.apple.Safari", name: "Safari", pid: 500, hasWindows: false)

    func testEarlierAppWithWindowsThatComesForwardLateIsNotReopened() {
        let h = Harness()
        h.frontLagAfterHide = 0.25
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result, ActionResult(.ok, notes: [.mayHaveMarkedRead]))
        XCTAssertEqual(h.app.calls, [.activateForeground, .hide])
        XCTAssertFalse(h.log.markers.contains { $0.hasPrefix("focus-restore") })
    }

    func testEarlierAppWithoutWindowsThatComesForwardLateGetsNoNote() {
        let h = Harness()
        h.earlier = Self.windowlessSafari
        h.frontAfterHide = Self.windowlessSafari
        h.frontLagAfterHide = 0.25
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result, ActionResult(.ok, notes: [.mayHaveMarkedRead]))
        XCTAssertEqual(h.app.calls, [.activateForeground, .hide])
    }

    func testOtherAppThatComesForwardLateIsNamedRatherThanMessages() {
        let h = Harness()
        h.earlier = Self.windowlessSafari
        h.frontAfterHide = Harness.finder
        h.frontLagAfterHide = 0.25
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result, ActionResult(.ok, notes: [.frontApp("Finder"), .mayHaveMarkedRead]))
        XCTAssertEqual(h.app.calls, [.activateForeground, .hide])
    }

    func testLateActivationRestoreAlsoWaitsForTheFrontApp() {
        let h = Harness()
        h.activationDelay = 2
        h.frontLagAfterHide = 0.25
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result, ActionResult(.aborted(.lateActivation), notes: [.mayHaveMarkedRead]))
        XCTAssertEqual(h.app.calls, [.activateForeground, .hide])
    }

    func testInputWhileWaitingForTheFrontAppIsATakeoverWithNoReopen() {
        let h = Harness()
        h.frontAfterHide = Harness.finder
        h.frontLagAfterHide = 0.5
        var hideAt: TimeInterval?
        var injectedWhileMessagesFront = false
        h.log.onEvent = { [unowned h] event in
            if event == .hide { hideAt = h.clock.uptime }
        }
        h.onFrontRead = { [unowned h] in
            // `isHidden` turns true 0.25 s after the hide, and the front app reads Messages until 0.75 s.
            guard !injectedWhileMessagesFront, let hideAt, h.clock.uptime >= hideAt + 0.375 else { return }
            injectedWhileMessagesFront = h.clock.uptime < hideAt + 0.75
            h.input.inject()
        }
        let outcome = h.runEdit()
        XCTAssertTrue(injectedWhileMessagesFront)
        XCTAssertEqual(outcome.result, ActionResult(.ok, notes: [.userTookOver, .mayHaveMarkedRead]))
        XCTAssertEqual(h.app.calls, [.activateForeground, .hide])
        XCTAssertEqual(markersAfterInput(h), ["phase verifying", "phase done"])
    }

    func testFrontAppStuckOnMessagesWaitsTheFocusWaitThenReopens() {
        let h = Harness()
        h.frontLagAfterHide = 60
        var hideAt: TimeInterval?
        var reopenAt: TimeInterval?
        h.log.onEvent = { [unowned h] event in
            if event == .hide { hideAt = h.clock.uptime }
            if case .reopen = event { reopenAt = h.clock.uptime }
        }
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result, ActionResult(.ok, notes: [.mayHaveMarkedRead]))
        XCTAssertEqual(h.app.calls, [.activateForeground, .hide, .reopen("com.apple.Safari")])
        guard let hideAt, let reopenAt else { return XCTFail("no hide or no reopen") }
        // Hidden 0.25 s after the hide, then at most `Limits.focusRestoreWait` for the front app to move.
        XCTAssertEqual(reopenAt - hideAt, 0.25 + Limits.focusRestoreWait, accuracy: 1e-9)
    }

    func testWindowlessEarlierAppWithMessagesStillInFrontNamesMessagesAfterTheWait() {
        let h = Harness()
        h.earlier = Self.windowlessSafari
        h.frontLagAfterHide = 60
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result, ActionResult(.ok, notes: [.frontApp("Messages"), .mayHaveMarkedRead]))
        XCTAssertEqual(h.app.calls, [.activateForeground, .hide])
    }
}
