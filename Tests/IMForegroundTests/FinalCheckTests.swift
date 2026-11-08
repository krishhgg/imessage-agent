import Foundation
import XCTest
import IMCore
import IMUI
@testable import IMForeground
import IMTestSupport

/// The last checks before each foreground AX press, write and Return. The press and write checks run inside the
/// driver, after its own reads (`AXFinalCheck`); the fake models those reads with its revalidation hooks.
final class FinalCheckTests: XCTestCase {
    // MARK: - The Edit press

    func testInputDuringTheDriversPrePressReadsPreventsTheEditPress() {
        let h = Harness()
        h.ax.beforePerformRevalidation = { h.clock.advance(0.25); h.input.inject() }
        let result = h.runEdit()
        XCTAssertEqual(result.result.code, .aborted(.userTookOver))
        XCTAssertEqual(h.log.count(.perform(UINames.edit)), 0, "Edit pressed after input during the driver's reads")
        XCTAssertTrue(h.log.writes.isEmpty)
        assertNoActionAfterInput(h)
    }

    func testExpiryDuringTheDriversPrePressReadsPreventsTheEditPress() {
        let h = Harness()
        h.ax.beforePerformRevalidation = { h.clock.advance(0.5); h.editWindowOpen = false }
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result, ActionResult(.expired, notes: [.mayHaveMarkedRead]))
        XCTAssertEqual(h.log.count(.perform(UINames.edit)), 0)
        XCTAssertTrue(h.log.writes.isEmpty)
        XCTAssertTrue(h.log.keys.isEmpty)
        // As for a window that closes before the press: `invoking` written, never `invoked`, Messages hidden again.
        XCTAssertEqual(h.recorder.facts.count, 1)
        XCTAssertEqual(h.recorder.invokedCount, 0)
        XCTAssertEqual(h.log.count(.hide), 1)
    }

    func testInputDuringTheWindowCheckInsideTheEditPressFinalCheckPreventsThePress() {
        // Inside the Edit press's final check the window comes first and the ownership check last, so input that
        // arrives while the window is checked is seen before the press.
        let h = Harness()
        var pressing = false
        var injected = false
        h.ax.beforePerformRevalidation = { pressing = true }
        h.editWindowByCall = { [unowned h] _ in
            if pressing, !injected {
                injected = true
                h.input.inject()
            }
            return true
        }
        let outcome = h.runEdit()
        XCTAssertTrue(injected)
        XCTAssertEqual(outcome.result.code, .aborted(.userTookOver))
        XCTAssertEqual(h.log.count(.perform(UINames.edit)), 0, "Edit pressed after input during the window check")
        XCTAssertTrue(h.log.writes.isEmpty)
        assertNoActionAfterInput(h)
    }

    // MARK: - The Reply to Last Message press

    func testInputDuringTheDriversTitleReadPreventsTheReplyPress() {
        let h = Harness()
        h.ax.beforeMenuPressRevalidation = { h.clock.advance(0.25); h.input.inject() }
        let outcome = h.runReply()
        XCTAssertEqual(outcome.result.code, .aborted(.userTookOver))
        XCTAssertEqual(h.log.count(.pressMenu), 0, "menu item pressed after input during the driver's reads")
        XCTAssertTrue(h.log.writes.isEmpty)
        assertNoActionAfterInput(h)
    }

    // MARK: - Field writes

    func testInputRightAfterTheFieldSetMarkerPreventsTheWrite() {
        let h = Harness()
        h.injectInput(on: .marker("field-set"))
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result.code, .aborted(.userTookOver))
        XCTAssertTrue(h.log.writes.isEmpty, "the field was written after input")
        XCTAssertFalse(outcome.result.notes.contains(.agentTextMayRemain))
        XCTAssertEqual(markersAfterInput(h), ["phase takeover"])
        assertNoActionAfterInput(h)
    }

    func testATakeoverAfterAStoppedWriteDoesNotReadTheField() {
        // The write's final check stopped it, so the field holds nothing of the bridge's. The field can't be read
        // after the input here, which would add the agent-text note if the takeover read it.
        let h = Harness()
        h.log.onEvent = { [unowned h] event in
            guard event == .marker("field-set"), !h.log.events.contains(.input) else { return }
            h.input.inject()
            h.ax.failRead = true
        }
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result.code, .aborted(.userTookOver))
        XCTAssertTrue(h.log.writes.isEmpty)
        XCTAssertFalse(h.log.afterInput.contains(.readValue), "the takeover read the field")
        XCTAssertFalse(outcome.result.notes.contains(.agentTextMayRemain))
        assertNoActionAfterInput(h)
    }

    func testInputRightAfterTheFieldRestoreMarkerLeavesTheResetToTheTakeover() {
        // The edit window closes after the write, so a bridge-owned cleanup restores the field. Input after its
        // ownership check stops the restore write, and the takeover makes its one reset instead.
        let h = Harness()
        h.editWindowByCall = { $0 < 6 }
        h.injectInput(on: .marker("field-restore"))
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result.code, .aborted(.userTookOver))
        XCTAssertEqual(markersAfterInput(h), ["phase takeover", "field-reset"])
        XCTAssertEqual(h.log.writes, [Harness.newText, Harness.oldText])
        assertNoActionAfterInput(h, allowingWrites: 1)
    }

    // MARK: - Right before Return

    func testInputDuringTheEditWindowCheckBeforeReturnIsATakeoverWithNoReturn() {
        // The ownership check is the last check before Return, after the window check.
        let h = Harness()
        h.editWindowByCall = { [unowned h] _ in
            if h.ax.focusReads > 0 { h.input.inject() }
            return true
        }
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result.code, .aborted(.userTookOver))
        XCTAssertFalse(h.log.keys.contains(.returnKey))
        XCTAssertEqual(h.recorder.invokedCount, 0)
        assertNoActionAfterInput(h, allowingWrites: 1)
    }

    func testInboundMessageDuringTheComposerWalkIsParentChangedWithNoReturn() {
        let h = Harness()
        var newer = h.parent
        newer.guid = "newer-guid"
        h.ax.onComposerRead = { [unowned h] in
            if h.log.writes.contains(Harness.replyText) { h.source.newest = { newer } }
        }
        let outcome = h.runReply()
        XCTAssertEqual(outcome.result.code, .aborted(.parentChanged))
        XCTAssertFalse(h.log.keys.contains(.returnKey))
        XCTAssertEqual(h.recorder.invokedCount, 0)
        XCTAssertEqual(h.log.writes, [Harness.replyText, ""], "reply field restored")
        XCTAssertEqual(h.log.count(.hide), 1)
    }

    func testInboundMessageDuringTheFocusedFieldReadIsParentChangedWithNoReturn() {
        let h = Harness()
        var newer = h.parent
        newer.guid = "newer-guid"
        h.ax.onFocusRead = { [unowned h] in
            if h.log.writes.contains(Harness.replyText) { h.source.newest = { newer } }
        }
        let outcome = h.runReply()
        XCTAssertEqual(outcome.result.code, .aborted(.parentChanged))
        XCTAssertFalse(h.log.keys.contains(.returnKey))
        XCTAssertEqual(h.recorder.invokedCount, 0)
        XCTAssertEqual(h.log.writes, [Harness.replyText, ""], "reply field restored")
        XCTAssertEqual(h.log.count(.hide), 1)
    }

    func testInboundMessageDuringTheThreadViewRereadIsParentChangedWithNoReturn() {
        // Each AX read of the thread view walk right before Return can block, so the newest incoming GUID is read
        // after it.
        let h = Harness()
        var newer = h.parent
        newer.guid = "newer-guid"
        var readsAfterWrite = 0
        h.ax.onThreadRead = { [unowned h] in
            guard h.log.writes.contains(Harness.replyText) else { return }
            readsAfterWrite += 1
            // The first is step 4's check, the second the reread in postReturn.
            if readsAfterWrite == 2 { h.source.newest = { newer } }
        }
        let outcome = h.runReply()
        XCTAssertGreaterThanOrEqual(readsAfterWrite, 2)
        XCTAssertEqual(outcome.result.code, .aborted(.parentChanged))
        XCTAssertFalse(h.log.keys.contains(.returnKey))
        XCTAssertEqual(h.recorder.invokedCount, 0)
        XCTAssertEqual(h.log.writes, [Harness.replyText, ""], "reply field restored")
        XCTAssertEqual(h.log.count(.hide), 1)
    }

    func testThreadParentChangedDuringTheFocusedFieldReadIsParentChangedWithNoReturn() {
        let h = Harness()
        var other = Harness.parentBubble(for: h.parent)
        other.text = "Something else"
        h.ax.onFocusRead = { [unowned h] in
            if h.log.writes.contains(Harness.replyText) { h.ax.threadParent = other }
        }
        let outcome = h.runReply()
        XCTAssertEqual(outcome.result.code, .aborted(.parentChanged))
        XCTAssertFalse(h.log.keys.contains(.returnKey))
        XCTAssertEqual(h.log.writes, [Harness.replyText, ""], "reply field restored")
    }

    // MARK: - The activation check

    func testInputDuringTheEarlierAppReadCountsBeforeTheActivationCheck() {
        // The front app to restore is read before the activation check, so input during that read sends the run
        // back to the idle gate instead of counting against ownership after `open -b`.
        let h = Harness()
        var injected = false
        h.onFrontRead = { [unowned h] in
            guard !injected, h.log.count(.activate) == 0 else { return }
            injected = true
            h.input.inject()
        }
        let outcome = h.runEdit()
        XCTAssertTrue(injected)
        XCTAssertEqual(outcome.result, ActionResult(.ok, notes: [.mayHaveMarkedRead]))
        XCTAssertEqual(h.log.count(.activate), 1)
        XCTAssertEqual(h.log.markers.filter { $0 == "phase activationCheck" }.count, 2)
    }
}
