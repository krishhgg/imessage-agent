import Foundation
import XCTest
@testable import IMForeground
import IMCore
import IMTestSupport
import IMUI

/// Step 5's takeover and bridge-owned paths, and step 6's finish.
final class CleanupTests: XCTestCase {
    // MARK: - Takeover

    func testTakeoverResetsAFieldThatStillHoldsTheBridgeText() {
        let h = Harness()
        h.injectInput(on: .setValue(Harness.newText))
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result, ActionResult(.aborted(.userTookOver),
                                                    notes: [.axState("an edit field"), .mayHaveMarkedRead]))
        XCTAssertEqual(h.log.writes, [Harness.newText, Harness.oldText])
        XCTAssertEqual(h.ax.values[ScriptedAX.editRef], Harness.oldText)
        assertNoActionAfterInput(h, allowingWrites: 1)
        XCTAssertEqual(h.app.calls, [.activateForeground], "no hide and no focus change")
    }

    func testTakeoverLeavesAChangedFieldAloneAndSaysTheTextMayRemain() {
        let h = Harness()
        h.injectInput(on: .setValue(Harness.newText)) { [unowned h] in
            h.ax.transform = { $0 + "!" }
            return true
        }
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result, ActionResult(.aborted(.userTookOver),
                                                    notes: [.agentTextMayRemain, .axState("an edit field"),
                                                            .mayHaveMarkedRead]))
        XCTAssertEqual(h.log.writes, [Harness.newText])
        assertNoActionAfterInput(h)
    }

    func testTakeoverWithTheFieldBackAtItsEarlierValueWritesNothing() {
        let h = Harness()
        h.injectInput(on: .setValue(Harness.newText)) { [unowned h] in
            h.ax.transform = { _ in Harness.oldText }
            return true
        }
        let outcome = h.runEdit()
        XCTAssertFalse(outcome.result.notes.contains(.agentTextMayRemain))
        XCTAssertEqual(h.log.writes, [Harness.newText])
    }

    func testTakeoverResetThatDoesNotStickSaysTheTextMayRemain() {
        let h = Harness()
        h.log.onEvent = { [unowned h] event in
            guard event == .setValue(Harness.newText) else { return }
            h.input.inject()
            // The bridge text lands; the reset write that follows is ignored.
            h.ax.transform = { $0 == Harness.oldText ? Harness.newText : $0 }
        }
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result.notes.first, .agentTextMayRemain)
        XCTAssertEqual(h.log.writes, [Harness.newText, Harness.oldText], "still only one write")
    }

    func testTakeoverWithAnUnreadableFieldSaysTheTextMayRemainAndWritesNothing() {
        let h = Harness()
        h.injectInput(on: .setValue(Harness.newText)) { [unowned h] in
            h.ax.failRead = true
            return true
        }
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result.code, .aborted(.userTookOver))
        XCTAssertEqual(outcome.result.notes.first, .agentTextMayRemain)
        XCTAssertEqual(h.log.writes, [Harness.newText])
    }

    func testTakeoverReportsWhatAXShows() {
        let cases: [(String, (Harness) -> Void)] = [
            ("an edit field and a thread view", { $0.ax.threadOpen = true }),
            ("no edit field or thread view", { $0.ax.editOpen = false }),
            ("no readable state", { $0.ax.failEditField = true }),
            ("more than one edit field", { $0.ax.editFieldError = AXDriveError.severalEditFields }),
            ("more than one edit field and a thread view", {
                $0.ax.editFieldError = AXDriveError.severalEditFields
                $0.ax.threadOpen = true
            }),
        ]
        for (expected, change) in cases {
            let h = Harness()
            h.injectInput(on: .setValue(Harness.newText)) { [unowned h] in
                change(h)
                return true
            }
            let outcome = h.runEdit()
            XCTAssertEqual(outcome.result.code, .aborted(.userTookOver), expected)
            XCTAssertTrue(outcome.result.notes.contains(.axState(expected)), expected)
        }
    }

    func testReplyTakeoverResetsTheThreadComposer() {
        let h = Harness()
        h.injectInput(on: .setValue(Harness.replyText))
        let outcome = h.runReply()
        XCTAssertEqual(outcome.result, ActionResult(.aborted(.userTookOver),
                                                    notes: [.axState("a thread view"), .mayHaveMarkedRead]))
        XCTAssertEqual(h.log.writes, [Harness.replyText, ""])
        XCTAssertTrue(h.log.keys.isEmpty)
    }

    // MARK: - Bridge-owned failure

    func testBridgeOwnedFailureRestoresTheFieldEscapesAndRunsStep6() {
        let h = Harness()
        h.targeting.signatureMatches = false
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result, ActionResult(.aborted(.check("view")), notes: [.mayHaveMarkedRead]))
        let afterWrite = h.actions.drop { $0 != .setValue(Harness.newText) }.dropFirst()
        XCTAssertEqual(Array(afterWrite), [.verifySelected, .setValue(Harness.oldText), .key(.escape), .hide])
        XCTAssertEqual(h.log.count(.verify), 0, "step 7 is skipped")
        XCTAssertEqual(h.recorder.invokedCount, 0)
        XCTAssertTrue(h.mode.isForegroundModeOn)
        XCTAssertFalse(outcome.turnedModeOff)
    }

    func testBridgeOwnedRestoreThatDoesNotStickSaysTheTextMayRemain() {
        let h = Harness()
        h.targeting.signatureMatches = false
        h.log.onEvent = { [unowned h] event in
            if event == .verifySelected { h.ax.transform = { _ in "garbled" } }
        }
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result.code, .aborted(.check("view")))
        XCTAssertEqual(outcome.result.notes, [.agentTextMayRemain, .mayHaveMarkedRead])
    }

    func testBridgeOwnedFailureWithTheFieldAlreadyAtItsEarlierValueWritesNothing() {
        let h = Harness()
        h.ax.failSet = true
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result, ActionResult(.aborted(.check("field")), notes: [.mayHaveMarkedRead]))
        XCTAssertTrue(h.log.writes.isEmpty)
        XCTAssertEqual(h.log.keys, [.escape])
    }

    func testBridgeOwnedFailurePressesEscapeAtMostThreeTimes() {
        let h = Harness()
        h.targeting.signatureMatches = false
        h.ax.escapesToClose = 99
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result, ActionResult(.aborted(.check("view")),
                                                    notes: [.messagesLeftInEditMode, .mayHaveMarkedRead]))
        XCTAssertEqual(h.log.keys, [.escape, .escape, .escape])
        XCTAssertEqual(h.log.count(.hide), 0)
        XCTAssertEqual(h.mode.reasons, ["Messages left in edit mode"])
        XCTAssertTrue(outcome.turnedModeOff)
        XCTAssertEqual(h.log.count(.verify), 0)
    }

    func testThirdEscapeClosingTheFieldIsEnough() {
        let h = Harness()
        h.targeting.signatureMatches = false
        h.ax.escapesToClose = 3
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result, ActionResult(.aborted(.check("view")), notes: [.mayHaveMarkedRead]))
        XCTAssertEqual(h.log.keys, [.escape, .escape, .escape])
        XCTAssertEqual(h.log.count(.hide), 1)
        XCTAssertTrue(h.mode.isForegroundModeOn)
    }

    func testUnreadableEditStateDuringCleanupCountsAsStillShowing() {
        let h = Harness()
        h.targeting.signatureMatches = false
        h.log.onEvent = { [unowned h] event in
            if event == .setValue(Harness.oldText) { h.ax.failEditField = true }
        }
        let outcome = h.runEdit()
        XCTAssertTrue(outcome.result.notes.contains(.messagesLeftInEditMode))
        XCTAssertEqual(h.log.keys.count, 3)
        XCTAssertEqual(h.log.count(.hide), 0)
        XCTAssertFalse(h.mode.isForegroundModeOn)
    }

    func testReplyBridgeOwnedFailureEscapesTheThreadView() {
        let h = Harness()
        h.ax.threadParent = nil
        h.ax.escapesToClose = 2
        let outcome = h.runReply()
        XCTAssertEqual(outcome.result.code, .aborted(.check("view")))
        XCTAssertEqual(h.log.writes, [Harness.replyText, ""])
        XCTAssertEqual(h.log.keys, [.escape, .escape])
        XCTAssertEqual(h.log.count(.hide), 1)
    }

    func testExpiredAfterActivationWithInputDuringCleanupIsUserTookOver() {
        let h = Harness()
        h.editWindowByCall = { $0 < 6 }
        h.injectInput(on: .key(.escape))
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result.code, .aborted(.userTookOver))
        XCTAssertEqual(h.log.count(.hide), 0)
    }

    // MARK: - Step 6

    func testFinishEscapesUntilTheMainTranscriptShows() {
        let h = Harness()
        h.ax.escapesToClose = 2
        let outcome = h.runReply()
        XCTAssertEqual(outcome.result, ActionResult(.submitted, notes: [.mayHaveMarkedRead]))
        XCTAssertEqual(h.log.keys, [.returnKey, .escape, .escape])
        XCTAssertEqual(h.log.count(.hide), 1)
    }

    func testFinishStopsAfterThreeEscapesTurnsModeOffAndStillVerifies() {
        let h = Harness()
        h.log.onEvent = { [unowned h] event in
            if event == .key(.returnKey) { h.ax.transcriptOverride = false }
        }
        let outcome = h.runReply()
        XCTAssertEqual(outcome.result, ActionResult(.submitted, notes: [.messagesLeftOpen, .mayHaveMarkedRead]))
        XCTAssertEqual(h.log.keys, [.returnKey, .escape, .escape, .escape])
        XCTAssertEqual(h.log.count(.hide), 0)
        XCTAssertEqual(h.mode.reasons, ["Messages left open"])
        XCTAssertTrue(outcome.turnedModeOff)
        XCTAssertEqual(h.log.count(.verify), 1)
    }

    func testUnreadableTranscriptCountsAsNotShowing() {
        let h = Harness()
        h.log.onEvent = { [unowned h] event in
            if event == .key(.returnKey) { h.ax.failTranscript = true }
        }
        let outcome = h.runEdit()
        XCTAssertTrue(outcome.result.notes.contains(.messagesLeftOpen))
        XCTAssertEqual(h.log.keys, [.returnKey, .escape, .escape, .escape])
        XCTAssertEqual(h.log.count(.hide), 0)
    }

    func testHiddenAtExactlyOneSecondRestoresFocus() {
        let h = Harness()
        h.hideDelay = 1
        h.frontAfterHide = Harness.finder
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result, ActionResult(.ok, notes: [.mayHaveMarkedRead]))
        XCTAssertEqual(h.log.count(.reopen("com.apple.Safari")), 1)
    }

    func testASlowReadThatShowsMessagesHiddenCountsAndRestoresFocus() {
        // The first `isHidden` read after the hide takes 1.1 s and shows Messages hidden. Messages is hidden, so
        // the focus restore runs and nothing says Messages was left open.
        for late in [false, true] {
            let h = Harness()
            h.activationDelay = late ? 2 : 0.25
            h.frontAfterHide = Harness.finder
            var hid = false
            h.log.onEvent = { event in if event == .hide { hid = true } }
            var slowed = false
            let onState = h.app.onState
            h.app.onState = { [unowned h] state in
                if hid, !slowed {
                    slowed = true
                    h.clock.advance(1.1)
                }
                onState?(&state)
            }
            let outcome = h.runEdit()
            XCTAssertTrue(slowed, "late activation \(late)")
            XCTAssertEqual(outcome.result, ActionResult(late ? .aborted(.lateActivation) : .ok,
                                                        notes: [.mayHaveMarkedRead]), "late activation \(late)")
            XCTAssertEqual(h.app.calls, [.activateForeground, .hide, .reopen("com.apple.Safari")],
                           "late activation \(late)")
        }
    }

    func testNotHiddenAfterOneSecondIsMessagesLeftOpenWithNoFocusRestore() {
        let h = Harness()
        h.hideDelay = 1 + 1.0 / 64.0
        h.frontAfterHide = Harness.finder
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result, ActionResult(.ok, notes: [.messagesLeftOpen, .mayHaveMarkedRead]))
        XCTAssertEqual(h.log.count(.reopen("com.apple.Safari")), 0)
        XCTAssertTrue(h.mode.isForegroundModeOn)
    }

    func testEarlierAppInFrontAfterTheHideNeedsNoReopen() {
        let h = Harness()
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result.notes, [.mayHaveMarkedRead])
        XCTAssertEqual(h.app.calls, [.activateForeground, .hide])
    }

    func testReopenedEarlierAppAtExactlyTwoSecondsIsDone() {
        let h = Harness()
        h.frontAfterHide = Harness.finder
        h.reopenDelay = 2
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result.notes, [.mayHaveMarkedRead])
        XCTAssertEqual(h.app.calls, [.activateForeground, .hide, .reopen("com.apple.Safari")])
    }

    func testOtherAppInFrontAfterTwoSecondsIsNamed() {
        let h = Harness()
        h.frontAfterHide = Harness.finder
        h.reopenDelay = 2 + 1.0 / 64.0
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result.notes, [.frontApp("Finder"), .mayHaveMarkedRead])
    }

    func testEarlierAppWithoutWindowsIsNotReopened() {
        let h = Harness()
        h.earlier = FrontApp(bundleID: "com.apple.Safari", name: "Safari", pid: 500, hasWindows: false)
        h.frontAfterHide = Harness.finder
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result.notes, [.frontApp("Finder"), .mayHaveMarkedRead])
        XCTAssertEqual(h.app.calls, [.activateForeground, .hide])
    }

    func testNoEarlierAppMeansNothingToRestore() {
        let h = Harness()
        h.earlier = nil
        h.frontAfterHide = Harness.finder
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result.notes, [.mayHaveMarkedRead])
        XCTAssertEqual(h.app.calls, [.activateForeground, .hide])
    }
}
