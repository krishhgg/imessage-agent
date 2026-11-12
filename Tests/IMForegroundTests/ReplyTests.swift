import Foundation
import XCTest
@testable import IMForeground
import IMCore
import IMTestSupport
import IMUI

/// Which field the reply writes, and the focus check before Return for edit and reply.
final class ReplyTests: XCTestCase {
    // MARK: - The reply field

    func testReplyWritesTheThreadFieldAndLeavesTheMainComposerAlone() {
        let h = Harness()
        let outcome = h.runReply()
        XCTAssertEqual(outcome.result.code, .submitted)
        XCTAssertEqual(h.ax.writtenRefs, [ScriptedAX.threadComposerRef])
        XCTAssertEqual(h.ax.values[ScriptedAX.composerRef], "", "text in the main composer would go out unthreaded")
    }

    func testReplyWithNoFocusedFieldWritesNothing() {
        let h = Harness()
        h.ax.focusOverride = { [unowned h] in h.ax.threadOpen ? nil : ScriptedAX.composerRef }
        let outcome = h.runReply()
        XCTAssertEqual(outcome.result.code, .aborted(.check("field")))
        XCTAssertTrue(h.log.writes.isEmpty)
        XCTAssertTrue(h.ax.writtenRefs.isEmpty)
        XCTAssertFalse(h.log.keys.contains(.returnKey))
        XCTAssertEqual(h.log.count(.hide), 1)
    }

    func testReplyFocusedOnTheMainComposerIsNotWritten() {
        let h = Harness()
        h.ax.focusOverride = { ScriptedAX.composerRef }
        let outcome = h.runReply()
        XCTAssertEqual(outcome.result.code, .aborted(.check("field")))
        XCTAssertFalse(h.ax.writtenRefs.contains(ScriptedAX.composerRef))
        XCTAssertFalse(h.log.keys.contains(.returnKey))
    }

    func testReplyWithAThreadButNoFieldBeforeTheDeadlineIsAbortedField() {
        let h = Harness()
        h.ax.focusOverride = { nil }
        let outcome = h.runReply()
        XCTAssertEqual(outcome.result.code, .aborted(.check("field")))
        XCTAssertTrue(h.log.writes.isEmpty)
    }

    func testReplyWithNoThreadViewIsAbortedDeadline() {
        let h = Harness()
        h.ax.openDelay = 10
        let outcome = h.runReply()
        XCTAssertEqual(outcome.result.code, .aborted(.deadline))
        XCTAssertTrue(h.log.writes.isEmpty)
    }

    func testMainComposerThatChangedAfterTheWriteStopsTheReply() {
        let h = Harness()
        h.ax.onSet = { [unowned h] _ in h.ax.values[ScriptedAX.composerRef] = "typed meanwhile" }
        let outcome = h.runReply()
        XCTAssertEqual(outcome.result.code, .aborted(.check("field")))
        XCTAssertFalse(h.log.keys.contains(.returnKey))
    }

    func testMainComposerThatCannotBeReadStopsTheReply() {
        let h = Harness()
        h.ax.onSet = { [unowned h] _ in h.ax.failComposer = true }
        let outcome = h.runReply()
        XCTAssertEqual(outcome.result.code, .aborted(.check("field")))
        XCTAssertFalse(h.log.keys.contains(.returnKey))
    }

    func testAReplyFieldWhoseValueCannotBeReadIsNeverWritten() {
        let h = Harness()
        h.log.onEvent = { [unowned h] event in if event == .pressMenu { h.ax.failFocus = true } }
        let outcome = h.runReply()
        XCTAssertEqual(outcome.result.code, .aborted(.check("field")))
        XCTAssertTrue(h.log.writes.isEmpty, "\(h.log.writes)")
        XCTAssertFalse(h.log.keys.contains(.returnKey))
    }

    // MARK: - Focus before Return

    func testReplyStopsWhenFocusLeavesTheWrittenField() {
        let h = Harness()
        h.ax.onSet = { [unowned h] _ in h.ax.focusOverride = { ScriptedAX.composerRef } }
        let outcome = h.runReply()
        XCTAssertEqual(outcome.result.code, .aborted(.check("field")))
        XCTAssertEqual(h.ax.writtenRefs.first, ScriptedAX.threadComposerRef)
        XCTAssertFalse(h.log.keys.contains(.returnKey))
    }

    func testEditStopsWhenFocusLeavesTheWrittenField() {
        let h = Harness()
        h.ax.onSet = { [unowned h] _ in h.ax.focusOverride = { ScriptedAX.composerRef } }
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result.code, .aborted(.check("field")))
        XCTAssertEqual(h.ax.writtenRefs.first, ScriptedAX.editRef)
        XCTAssertFalse(h.log.keys.contains(.returnKey))
    }

    func testReplyFieldThatChangesAfterTheValueCheckGetsNoReturn() {
        let h = Harness()
        // Step 4's value read passes. Then, during the main composer walk and with no input, the reply field changes.
        var armed = true
        h.ax.onSet = { [unowned h] _ in
            guard armed else { return }
            armed = false
            h.ax.onComposerRead = { h.ax.values[ScriptedAX.threadComposerRef] = Harness.replyText + "." }
        }
        let outcome = h.runReply()
        XCTAssertEqual(outcome.result.code, .aborted(.check("field")))
        XCTAssertFalse(h.log.keys.contains(.returnKey))
        XCTAssertEqual(h.recorder.invokedCount, 0)
        XCTAssertEqual(h.log.writes, [Harness.replyText, ""], "the bridge-owned restore writes the earlier value")
    }

    func testEditFieldThatChangesAfterTheValueCheckGetsNoReturn() {
        let h = Harness()
        // Step 4's value read passes. Then, during the focused-field read and with no input, the edit field changes.
        h.ax.onFocusRead = { [unowned h] in h.ax.values[ScriptedAX.editRef] = Harness.newText + "!" }
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result.code, .aborted(.check("field")))
        XCTAssertEqual(h.ax.focusReads, 1)
        XCTAssertFalse(h.log.keys.contains(.returnKey))
        XCTAssertEqual(h.recorder.invokedCount, 0)
        XCTAssertEqual(h.log.writes, [Harness.newText, Harness.oldText], "the bridge-owned restore")
    }

    func testEditFieldWithoutFocusIsAbortedField() {
        let h = Harness()
        h.ax.focusOverride = { nil }
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result.code, .aborted(.check("field")))
        XCTAssertFalse(h.log.keys.contains(.returnKey))
    }

    func testFocusReadErrorBeforeReturnIsAbortedField() {
        let h = Harness()
        h.ax.onSet = { [unowned h] _ in h.ax.failFocus = true }
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result.code, .aborted(.check("field")))
        XCTAssertFalse(h.log.keys.contains(.returnKey))
    }

    func testFocusIsReadRightBeforeReturn() {
        let h = Harness()
        var readsAtReturn = -1
        h.log.onEvent = { [unowned h] event in
            if event == .key(.returnKey) { readsAtReturn = h.ax.focusReads }
        }
        h.runEdit()
        XCTAssertEqual(readsAtReturn, 1, "edit reads focus once, after the write and before Return")
    }
}
