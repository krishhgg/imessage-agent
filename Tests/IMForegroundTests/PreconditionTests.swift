import Foundation
import XCTest
@testable import IMForeground
import IMCore
import IMStore
import IMUI
import IMTestSupport

/// Step 1, after the queue: every check that keeps Messages hidden and returns early.
final class PreconditionTests: XCTestCase {
    func testStep1RunsAfterTheQueueTake() {
        let h = Harness()
        h.runEdit()
        let acquire = h.actions.firstIndex { if case .acquire = $0 { return true } else { return false } }
        XCTAssertEqual(acquire, 0)
        XCTAssertEqual(Array(h.actions[1...3]), h.editStep1Events)
    }

    func testWindowRulesGetTheQueueDeadlineAndTheirEarlyResultStops() {
        let h = Harness()
        h.windowRules.result = .messagesOpen
        let outcome = h.runEdit(queueDeadline: 1017)
        XCTAssertEqual(outcome.result, .messagesOpen)
        XCTAssertEqual(h.windowRules.deadlines, [1017])
        XCTAssertNotNil(outcome.ticket, "the machine keeps the queue for IMBridge to release")
        XCTAssertEqual(h.log.count(.selectChat), 0)
        assertNothingActivated(h)
    }

    func testWindowRuleNotesAreAddedToTheFinalResult() {
        let h = Harness()
        h.windowRules.notes = [.messagesBecameVisible]
        let edit = h.runEdit()
        XCTAssertEqual(edit.result, ActionResult(.ok, notes: [.messagesBecameVisible, .mayHaveMarkedRead]))
        XCTAssertEqual(edit.result.rendered, "ok, error: Messages became visible, chat opened, may be marked read")

        let r = Harness()
        r.windowRules.notes = [.messagesBecameVisible]
        let reply = r.runReply()
        XCTAssertEqual(reply.result, ActionResult(.submitted, notes: [.messagesBecameVisible, .mayHaveMarkedRead]))
    }

    func testWindowRuleNotesAreAddedToALaterStep1Refusal() {
        let h = Harness()
        h.windowRules.notes = [.messagesBecameVisible]
        h.ax.values[ScriptedAX.composerRef] = "half a thought"
        let outcome = h.runReply()
        XCTAssertEqual(outcome.result, ActionResult(.busy(.draftInMessages), notes: [.messagesBecameVisible]),
                       "step 1 presses nothing, so no mark-read note")
        assertNothingActivated(h)
    }

    func testWindowRuleNotesAppearOnceAfterARetake() {
        let h = Harness()
        h.windowRules.notes = [.messagesBecameVisible]
        h.injectInput(on: .selectChat)
        let outcome = h.runEdit(queueDeadline: 1100)
        XCTAssertEqual(h.log.count(.ensureHidden), 2, "step 1 ran twice")
        XCTAssertEqual(outcome.result, ActionResult(.ok, notes: [.messagesBecameVisible, .mayHaveMarkedRead]))
    }

    func testMessagesNotHiddenOrFrontmostIsBusyMessagesOpen() {
        for (hidden, frontmost) in [(false, false), (true, true)] {
            let h = Harness()
            h.base.isHidden = hidden
            h.base.isFrontmost = frontmost
            let outcome = h.runReply()
            XCTAssertEqual(outcome.result, .messagesOpen)
            XCTAssertEqual(h.log.count(.selectChat), 0)
            assertNothingActivated(h)
        }
    }

    func testMessagesNotRunningIsNoHiddenWindow() {
        let h = Harness()
        h.base = .notRunning
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result.code, .noHiddenWindow)
        assertNothingActivated(h)
    }

    func testChatSelectionRefusalIsReturned() {
        let h = Harness()
        h.targeting.selection = .refused(ActionResult(.ambiguous(.target)))
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result, ActionResult(.ambiguous(.target)))
        XCTAssertEqual(h.log.count(.findBubble), 0)
        assertNothingActivated(h)
    }

    func testChatNotOpenIsBusyWithNothingPressedAndNoNote() {
        let busy = ActionResult(.busy(.chatNotOpen), fix: "open Sam in Messages, hide it (⌘H), then retry")
        for reply in [false, true] {
            let h = Harness()
            h.targeting.selection = .refused(busy)
            var composerReads = 0
            h.ax.onComposerRead = { composerReads += 1 }
            let outcome = reply ? h.runReply() : h.runEdit()
            XCTAssertEqual(outcome.result, busy, "reply: \(reply)")
            XCTAssertFalse(outcome.result.holdsIdempotencyKey)
            XCTAssertEqual(h.log.count(.selectChat), 1)
            XCTAssertEqual(h.log.count(.findBubble), 0)
            XCTAssertEqual(composerReads, 0, "no composer read")
            assertNothingActivated(h)
        }
    }

    func testChatNotOpenOnTheRetakeHasNoNote() {
        // Input at the activation check sends the run back to step 1, and by then another chat is selected.
        let busy = ActionResult(.busy(.chatNotOpen), fix: "open Sam in Messages, hide it (⌘H), then retry")
        let h = Harness()
        h.log.onEvent = { [unowned h] event in
            if event == .selectChat, h.log.count(.selectChat) == 1 { h.input.inject() }
            if event == .findBubble, h.log.count(.findBubble) == 1 { h.targeting.selection = .refused(busy) }
        }
        let outcome = h.runEdit(queueDeadline: 1100)
        XCTAssertEqual(h.log.count(.selectChat), 2, "step 1 ran twice")
        XCTAssertEqual(outcome.result, busy, "no mark-read note")
        assertNothingActivated(h)
    }

    func testDraftInComposerIsBusyDraftInMessages() {
        let h = Harness()
        h.ax.values[ScriptedAX.composerRef] = "half a thought"
        let outcome = h.runReply()
        XCTAssertEqual(outcome.result.code, .busy(.draftInMessages))
        XCTAssertEqual(outcome.result.notes, [], "step 1 presses nothing, so no mark-read note")
        assertNothingActivated(h)
    }

    func testOpenEditFieldOrThreadViewIsBusyEditInProgress() {
        for thread in [false, true] {
            let h = Harness()
            if thread { h.ax.threadOpen = true } else { h.ax.editOpen = true }
            h.ax.values[ScriptedAX.threadComposerRef] = ""
            let outcome = h.runEdit()
            XCTAssertEqual(outcome.result.code, .busy(.editInProgress), "thread \(thread)")
            assertNothingActivated(h)
        }
    }

    func testTwoEditFieldsShowingIsBusyEditInProgress() {
        for reply in [false, true] {
            let h = Harness()
            h.ax.editFieldError = AXDriveError.severalEditFields
            let outcome = reply ? h.runReply() : h.runEdit()
            XCTAssertEqual(outcome.result.code, .busy(.editInProgress), "reply \(reply)")
            assertNothingActivated(h)
        }
    }

    func testUnreadableOrMissingComposerFailsClosed() {
        let cases: [(ScriptedAX) -> Void] = [
            { $0.failComposer = true },
            { $0.hasComposer = false },
            { $0.failEditField = true },
            { $0.editFieldError = AXDriveError.walkLimit },
            { $0.failThread = true },
        ]
        for (i, setUp) in cases.enumerated() {
            let h = Harness()
            setUp(h.ax)
            let outcome = h.runEdit()
            XCTAssertEqual(outcome.result.code, .aborted(.check("AX read")), "case \(i)")
            assertNothingActivated(h)
        }
    }

    func testReplyParentChangedBeforeActivation() {
        for movedOn in [true, false] {
            let h = Harness()
            var newer = h.parent
            newer.guid = "newer-guid"
            let newest: MessageTargetInfo? = movedOn ? newer : nil
            h.source.newest = { newest }
            let outcome = h.runReply()
            XCTAssertEqual(outcome.result.code, .aborted(.parentChanged))
            assertNothingActivated(h)
        }
    }

    func testReplyNewestIncomingReadErrorFailsClosed() {
        let h = Harness()
        h.source.newest = { throw FakeRows.Failure() }
        let outcome = h.runReply()
        XCTAssertEqual(outcome.result.code, .aborted(.check("chat.db read")))
        assertNothingActivated(h)
    }

    func testReplyMenuItemMissingIsUnsupported() {
        let h = Harness()
        h.ax.menu = nil
        let outcome = h.runReply()
        XCTAssertEqual(outcome.result.code, .unsupported)
        assertNothingActivated(h)
    }

    func testReplyMenuItemReadErrorFailsClosed() {
        let h = Harness()
        h.ax.failMenu = true
        let outcome = h.runReply()
        XCTAssertEqual(outcome.result.code, .aborted(.check("AX read")))
        assertNothingActivated(h)
    }

    func testReplyMenuItemDisabledWhileHiddenStillPassesStep1() {
        let h = Harness()
        h.ax.menu?.enabled = false
        h.log.onEvent = { [unowned h] event in if event == .activate { h.ax.menu?.enabled = true } }
        let outcome = h.runReply()
        XCTAssertEqual(outcome.result.code, .submitted)
    }

    func testHiddenReplyToMessageTitlePassesStep1AndTheExactTitleIsPressed() {
        let h = Harness()
        h.ax.menu = MenuItemInfo(ref: ScriptedAX.menuRef, title: UINames.replyToMessage, enabled: false)
        h.log.onEvent = { [unowned h] event in
            if event == .activate {
                h.ax.menu = MenuItemInfo(ref: ScriptedAX.menuRef, title: UINames.replyToLastMessage, enabled: true)
            }
        }
        let outcome = h.runReply()
        XCTAssertEqual(outcome.result.code, .submitted)
        XCTAssertEqual(h.log.count(.pressMenu), 1)
    }

    func testReplyToMessageTitleIsNeverPressedAfterFront() {
        let h = Harness()
        h.ax.menu = MenuItemInfo(ref: ScriptedAX.menuRef, title: UINames.replyToMessage, enabled: true)
        let outcome = h.runReply()
        XCTAssertEqual(outcome.result.code, .aborted(.deadline))
        XCTAssertEqual(h.log.count(.pressMenu), 0)
        XCTAssertTrue(h.log.writes.isEmpty)
        XCTAssertFalse(h.log.keys.contains(.returnKey))
        XCTAssertEqual(h.log.count(.hide), 1, "bridge-owned failure still runs step 6")
    }

    func testEditBubbleWithoutEditActionIsUnsupported() {
        let h = Harness()
        var bubble = h.bubble
        bubble.actionNames = ["Heart", "Undo Send"]
        h.targeting.lookup = .found(bubble)
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result.code, .unsupported)
        assertNothingActivated(h)
    }

    func testEditActionMissingAfterTheWindowClosedIsExpired() {
        let h = Harness()
        var bubble = h.bubble
        bubble.actionNames = ["Heart"]
        h.targeting.lookup = .found(bubble)
        // Open when the action leaves the queue, closed by the time the bubble shows no Edit action.
        h.editWindowByCall = { $0 == 1 }
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result.code, .expired)
        assertNothingActivated(h)
    }

    func testEditBubbleLookupRefusalIsReturned() {
        let h = Harness()
        h.targeting.lookup = .refused(ActionResult(.notLoaded))
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result.code, .notLoaded)
        assertNothingActivated(h)
    }

    func testEditStateMissingOrUnreadableFailsClosed() {
        let cases: [(Int64) throws -> EditStateProbe?] = [{ _ in nil }, { _ in throw FakeRows.Failure() }]
        for (i, edit) in cases.enumerated() {
            let h = Harness()
            h.source.edit = edit
            let outcome = h.runEdit()
            XCTAssertEqual(outcome.result.code, .aborted(.check("chat.db read")), "case \(i)")
            assertNothingActivated(h)
        }
    }

    func testSnapshotReadErrorFailsClosed() {
        let h = Harness()
        h.rows.maxRowID = { throw FakeRows.Failure() }
        let outcome = h.runReply()
        XCTAssertEqual(outcome.result.code, .aborted(.check("chat.db read")))
        assertNothingActivated(h)
    }

    // MARK: - Edit window before activation (section 2)

    func testEditWindowClosedWhenLeavingTheQueueIsExpiredBeforeStep1() {
        let h = Harness()
        h.editWindowOpen = false
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result, ActionResult(.expired))
        XCTAssertNotNil(outcome.ticket)
        XCTAssertEqual(h.log.count(.ensureHidden), 0)
        assertNothingActivated(h)
    }

    func testEditWindowClosedRightBeforeOpenIsExpiredWithoutActivation() {
        let h = Harness()
        // Open when the action leaves the queue (read 1), closed right before `open -b` (read 2).
        h.editWindowByCall = { $0 < 2 }
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result.code, .expired)
        XCTAssertEqual(h.log.count(.findBubble), 1, "step 1 ran")
        XCTAssertEqual(h.editWindowArgs.count, 2)
        assertNothingActivated(h)
    }

    func testEditWindowIsReadFromTheRowDateAndTheWallClock() {
        let h = Harness()
        h.runEdit()
        XCTAssertFalse(h.editWindowArgs.isEmpty)
        for read in h.editWindowArgs {
            XCTAssertEqual(read.dateNs, h.target.dateNs)
            XCTAssertEqual(read.now, read.clockNow)
        }
    }

    func testReplyNeverReadsTheEditWindow() {
        let h = Harness()
        h.editWindowOpen = false
        let outcome = h.runReply()
        XCTAssertEqual(outcome.result.code, .submitted)
        XCTAssertTrue(h.editWindowArgs.isEmpty)
    }
}
