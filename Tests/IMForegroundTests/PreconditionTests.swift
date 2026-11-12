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

    func testMessagesShownDuringTheChatCheckIsBusyMessagesOpen() {
        // The chat check can wait seconds for a conversation list that is still loading. A user who shows Messages
        // early in that wait and then stays still for 2 s would pass the idle check before `open -b`. The result is
        // the window rules' own busy line: with the fix for a window showing, without it for a hidden Messages.
        let cases: [(hidden: Bool, frontmost: Bool, result: ActionResult)] = [
            (false, false, .messagesOpen), (true, true, ActionResult(.busy(.messagesOpen))),
        ]
        for (hidden, frontmost, result) in cases {
            let h = Harness()
            h.log.onEvent = { [unowned h] event in
                guard event == .selectChat else { return }
                h.input.inject()
                h.base.isHidden = hidden
                h.base.isFrontmost = frontmost
                h.clock.advance(6)
            }
            let edit = h.runEdit()
            XCTAssertEqual(edit.result, result, "\(hidden) \(frontmost)")
            XCTAssertEqual(h.log.count(.selectChat), 1)
            XCTAssertEqual(h.windowRules.rechecks, 1)
            XCTAssertEqual(h.log.count(.findBubble), 0, "step 1 stops at the recheck after the chat check")
            assertNothingActivated(h)
        }
    }

    func testScreenLockedDuringTheChatCheckIsBusyScreenLocked() {
        // AX lists no window on a locked screen, so without the recheck the next AX read would fail as
        // `aborted: AX read`.
        for reply in [false, true] {
            let h = Harness()
            var composerReads = 0
            h.ax.onComposerRead = { composerReads += 1 }
            h.log.onEvent = { [unowned h] event in
                guard event == .selectChat else { return }
                h.base.isScreenLocked = true
                h.clock.advance(6)
            }
            let outcome = reply ? h.runReply() : h.runEdit()
            XCTAssertEqual(outcome.result, .screenLocked, "reply: \(reply)")
            XCTAssertEqual(outcome.result.rendered, "busy: screen locked fix: unlock the Mac and retry")
            XCTAssertEqual(h.windowRules.rechecks, 1)
            XCTAssertEqual(h.log.count(.findBubble), 0, "no bubble lookup")
            XCTAssertEqual(composerReads, 0, "no composer read")
            XCTAssertEqual(h.source.readsAt.count, 0, "no chat.db read for the step 1 checks")
            assertNothingActivated(h)
        }
    }

    func testASecondWindowDuringTheChatCheckIsBusyMessagesOpen() {
        // Hidden with two windows, as AX counts them or as the window server counts them on some Space. Hiding
        // again doesn't help, so the busy line has no fix.
        for (ax, space) in [(2, 1), (1, 2)] {
            for reply in [false, true] {
                let h = Harness()
                var composerReads = 0
                h.ax.onComposerRead = { composerReads += 1 }
                h.log.onEvent = { [unowned h] event in
                    guard event == .selectChat else { return }
                    h.base.axWindowCount = ax
                    h.base.allSpacesWindowCount = space
                    h.base.spaceWindowCount = space
                    h.clock.advance(6)
                }
                let outcome = reply ? h.runReply() : h.runEdit()
                let label = "ax \(ax), space \(space), reply: \(reply)"
                XCTAssertEqual(outcome.result, ActionResult(.busy(.messagesOpen)), label)
                XCTAssertEqual(outcome.result.rendered, "busy: Messages is open", label)
                XCTAssertEqual(h.windowRules.rechecks, 1, label)
                XCTAssertEqual(h.log.count(.findBubble), 0, label)
                XCTAssertEqual(composerReads, 0, label)
                assertNothingActivated(h)
            }
        }
    }

    func testTheWindowRecheckComesAfterTheChatCheckAndBeforeTheOtherStep1Reads() {
        // Once per take of the queue, after the chat check and before the bubble lookup and the composer read.
        let h = Harness()
        var rechecksAtFindBubble: [Int] = []
        var rechecksAtComposer: [Int] = []
        h.ax.onComposerRead = { [unowned h] in rechecksAtComposer.append(h.windowRules.rechecks) }
        h.log.onEvent = { [unowned h] event in
            if event == .selectChat { XCTAssertEqual(h.windowRules.rechecks, 0) }
            if event == .findBubble { rechecksAtFindBubble.append(h.windowRules.rechecks) }
        }
        XCTAssertEqual(h.runEdit().result.code, .ok)
        XCTAssertEqual(h.windowRules.rechecks, 1)
        XCTAssertEqual(rechecksAtFindBubble.first, 1)
        XCTAssertEqual(rechecksAtComposer.first, 1)

        // A `not_loaded` refusal runs the recheck once. Messages is still hidden with one window here, so the
        // refusal is returned. The other refusals return before the recheck.
        let r = Harness()
        r.targeting.selection = .refused(ActionResult(.notLoaded))
        XCTAssertEqual(r.runReply().result, ActionResult(.notLoaded))
        XCTAssertEqual(r.windowRules.rechecks, 1, "a not_loaded refusal runs the recheck")
        XCTAssertEqual(r.log.count(.findBubble), 0)
        assertNothingActivated(r)

        let busy = ActionResult(.busy(.chatNotOpen), fix: "open Sam in Messages, hide it (⌘H), then retry")
        for refusal in [ActionResult(.ambiguous(.target)), ActionResult(.unsupportedTarget), busy] {
            let o = Harness()
            o.targeting.selection = .refused(refusal)
            o.log.onEvent = { [unowned o] event in
                if event == .selectChat { o.base.isScreenLocked = true }
            }
            XCTAssertEqual(o.runReply().result, refusal)
            XCTAssertEqual(o.windowRules.rechecks, 0, "\(refusal.rendered) returns before the recheck")
        }
    }

    func testANotLoadedChatCheckAfterALockOrASecondWindowIsTheBusyLine() {
        // The live targeter reads no window on a locked screen or after Messages quits, and fails its AX reads when
        // AX counts two windows. Each ends as `not_loaded`. The recheck after that refusal names the real cause, and
        // nothing is pressed.
        let cases: [(label: String, change: (inout MessagesAppState) -> Void, result: ActionResult)] = [
            ("locked", { $0.isScreenLocked = true }, .screenLocked),
            ("two AX windows", { $0.axWindowCount = 2 }, ActionResult(.busy(.messagesOpen))),
            ("quit", { $0 = .notRunning }, ActionResult(.noHiddenWindow)),
        ]
        for (label, change, result) in cases {
            for reply in [false, true] {
                let h = Harness()
                h.targeting.selection = .refused(ActionResult(.notLoaded))
                var composerReads = 0
                h.ax.onComposerRead = { composerReads += 1 }
                h.log.onEvent = { [unowned h] event in
                    guard event == .selectChat else { return }
                    change(&h.base)
                    h.clock.advance(6)
                }
                let outcome = reply ? h.runReply() : h.runEdit()
                let name = "\(label), reply: \(reply)"
                XCTAssertEqual(outcome.result, result, name)
                XCTAssertEqual(h.windowRules.rechecks, 1, name)
                XCTAssertEqual(h.log.count(.selectChat), 1, name)
                XCTAssertEqual(h.log.count(.findBubble), 0, name)
                XCTAssertEqual(composerReads, 0, name)
                XCTAssertEqual(outcome.result.notes, [], "\(name): nothing pressed, so no mark-read note")
                assertNothingActivated(h)
            }
        }
    }

    func testARelaunchDuringTheWindowRecheckIsNoHiddenWindow() {
        // Messages quits and comes back hidden with one window while the recheck reads it, so the recheck passes.
        // The pid read comes after it and catches the new pid.
        for reply in [false, true] {
            let h = Harness()
            var composerReads = 0
            h.ax.onComposerRead = { composerReads += 1 }
            _ = h.machine // builds the env, which installs the real recheck
            let recheck = h.windowRules.rechecker
            h.windowRules.rechecker = { [unowned h] in
                h.base.pid = Harness.pid + 1
                return recheck()
            }
            let outcome = reply ? h.runReply() : h.runEdit()
            XCTAssertEqual(outcome.result.code, .noHiddenWindow, "reply: \(reply)")
            XCTAssertEqual(h.windowRules.rechecks, 1)
            XCTAssertEqual(h.log.count(.findBubble), 0)
            XCTAssertEqual(composerReads, 0)
            assertNothingActivated(h)
        }
    }

    func testMessagesQuitOrRelaunchedDuringTheChatCheckIsNoHiddenWindow() {
        var relaunched = Harness().base
        relaunched.pid = Harness.pid + 1
        for state in [MessagesAppState.notRunning, relaunched] {
            let h = Harness()
            h.log.onEvent = { [unowned h] event in
                if event == .selectChat { h.base = state }
            }
            let reply = h.runReply()
            XCTAssertEqual(reply.result.code, .noHiddenWindow, "\(state)")
            XCTAssertEqual(h.log.count(.selectChat), 1)
            assertNothingActivated(h)
        }
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
