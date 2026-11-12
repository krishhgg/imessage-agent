import Foundation
import XCTest
@testable import IMForeground
import IMCore
import IMStore
import IMTestSupport
import IMUI

/// From `t_front` to Return: the journal hook, the press, the write, the 3 s deadline and step 4.
final class PressAndReturnTests: XCTestCase {
    // MARK: - Whole runs

    func testEditRunsEveryStepInOrder() {
        let h = Harness()
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result, ActionResult(.ok, notes: [.mayHaveMarkedRead]))
        XCTAssertEqual(h.actions, [
            .acquire(30), .ensureHidden, .selectChat, .findBubble, .activate, .findBubble, .willInvoke,
            .perform(UINames.edit), .setValue(Harness.newText), .verifySelected, .key(.returnKey), .didInvoke,
            .hide, .verify,
        ])
        XCTAssertEqual(h.keys.pids, [Harness.pid])
        XCTAssertEqual(outcome.lastPhase, .done)
        XCTAssertNotNil(outcome.ticket)
        XCTAssertFalse(outcome.turnedModeOff)
        XCTAssertNil(outcome.sentGUID)
    }

    func testReplyRunsEveryStepInOrder() {
        let h = Harness()
        let outcome = h.runReply()
        XCTAssertEqual(outcome.result, ActionResult(.submitted, notes: [.mayHaveMarkedRead]))
        XCTAssertEqual(h.actions, [
            .acquire(30), .ensureHidden, .selectChat, .activate, .willInvoke, .pressMenu,
            .setValue(Harness.replyText), .key(.returnKey), .didInvoke, .key(.escape), .hide, .verify,
        ])
        XCTAssertEqual(h.keys.pids, [Harness.pid, Harness.pid])
        XCTAssertEqual(outcome.sentGUID, "reply-row-guid")
    }

    // MARK: - The journal hook

    func testWillInvokeCarriesTheEditFactsBeforeThePress() {
        let h = Harness()
        h.runEdit()
        XCTAssertEqual(h.recorder.facts, [InvocationFacts(snapshotRowID: 500, targetGUID: "target-guid", targetPart: 0,
                                                          targetRowID: 410, dateEditedBeforeNs: 123)])
        XCTAssertLessThan(h.log.index(of: .willInvoke) ?? .max, h.log.index(of: .perform(UINames.edit)) ?? -1)
        XCTAssertGreaterThan(h.log.index(of: .willInvoke) ?? -1, h.log.index(of: .activate) ?? .max)
    }

    func testWillInvokeCarriesTheSnapshotBeforeTheMenuPress() {
        let h = Harness()
        h.runReply()
        XCTAssertEqual(h.recorder.facts, [InvocationFacts(snapshotRowID: 500)])
        XCTAssertLessThan(h.log.index(of: .willInvoke) ?? .max, h.log.index(of: .pressMenu) ?? -1)
    }

    func testWillInvokeFailurePressesNothingAndCleansUp() {
        let h = Harness()
        let recorder = FakeInvocationRecorder()
        recorder.failWillInvoke = true
        let run = ForegroundRun(chat: h.chat, action: .edit(target: h.target, newText: Harness.newText),
                                queueDeadline: 1030)
        let outcome = h.machine.run(run, recorder: recorder)
        XCTAssertEqual(outcome.result, ActionResult(.error(.message("journal write failed")),
                                                    notes: [.mayHaveMarkedRead], fix: "free disk space and retry"))
        XCTAssertFalse(outcome.result.holdsIdempotencyKey, "nothing was pressed, so a retry runs again")
        XCTAssertTrue(recorder.invoking.isEmpty)
        XCTAssertEqual(recorder.invokedCount, 0)
        XCTAssertEqual(h.log.count(.perform(UINames.edit)), 0)
        XCTAssertTrue(h.log.writes.isEmpty)
        XCTAssertTrue(h.log.keys.isEmpty)
        XCTAssertEqual(h.log.count(.hide), 1, "bridge-owned failure still runs step 6")
        XCTAssertEqual(h.log.count(.verify), 0)
    }

    func testDidInvokeFollowsReturn() {
        let h = Harness()
        h.runEdit()
        XCTAssertEqual(h.recorder.invokedCount, 1)
        XCTAssertEqual(h.log.index(of: .didInvoke), (h.log.index(of: .key(.returnKey)) ?? -2) + 1)
    }

    // MARK: - Press failures

    func testEditActionGoneAtPressTimeIsAbortedPress() {
        let h = Harness()
        var gone = h.bubble
        gone.actionNames = ["Heart"]
        h.targeting.lookups = [.found(h.bubble), .found(gone)]
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result.code, .aborted(.check("press")))
        XCTAssertTrue(h.recorder.facts.isEmpty)
        XCTAssertEqual(h.log.count(.perform(UINames.edit)), 0)
        XCTAssertEqual(h.log.count(.hide), 1)
    }

    func testEditPressErrorIsAbortedPress() {
        let h = Harness()
        h.ax.failPerform = true
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result.code, .aborted(.check("press")))
        XCTAssertEqual(h.recorder.facts.count, 1)
        XCTAssertTrue(h.log.writes.isEmpty)
        XCTAssertTrue(h.log.keys.isEmpty)
    }

    func testMenuPressErrorIsAbortedPress() {
        let h = Harness()
        h.ax.failPress = true
        let outcome = h.runReply()
        XCTAssertEqual(outcome.result.code, .aborted(.check("press")))
        XCTAssertTrue(h.log.writes.isEmpty)
    }

    func testFieldWriteErrorIsAbortedField() {
        let h = Harness()
        h.ax.failSet = true
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result.code, .aborted(.check("field")))
        XCTAssertFalse(h.log.keys.contains(.returnKey))
    }

    func testReturnThatCannotBePostedIsAbortedPress() {
        let h = Harness()
        h.keys.refused = [.returnKey]
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result.code, .aborted(.check("press")))
        XCTAssertEqual(h.recorder.invokedCount, 0)
        XCTAssertEqual(h.log.writes, [Harness.newText, Harness.oldText], "field restored")
        XCTAssertEqual(h.log.count(.verify), 0)
    }

    // MARK: - Return within 3 s of t_front

    func testReturnAtExactlyThreeSecondsIsPosted() {
        let h = Harness()
        h.ax.openDelay = 3
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result.code, .ok)
        XCTAssertEqual(h.log.keys, [.returnKey])
    }

    func testFieldLaterThanThreeSecondsIsAbortedDeadline() {
        let h = Harness()
        h.ax.openDelay = 3 + 1.0 / 64.0
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result.code, .aborted(.deadline))
        XCTAssertFalse(h.log.keys.contains(.returnKey))
        XCTAssertTrue(h.log.writes.isEmpty)
    }

    func testSlowWriteThatEndsAtTheDeadlineStillReturns() {
        let h = Harness()
        h.ax.writeDuration = 3
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result.code, .ok)
    }

    func testSlowWritePastTheDeadlineIsAbortedDeadlineAndRestoresTheField() {
        let h = Harness()
        h.ax.writeDuration = 3 + 1.0 / 64.0
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result, ActionResult(.aborted(.deadline), notes: [.mayHaveMarkedRead]))
        XCTAssertEqual(h.log.writes, [Harness.newText, Harness.oldText])
        XCTAssertEqual(h.log.keys, [.escape])
    }

    func testMenuItemNeverEnabledIsAbortedDeadline() {
        let h = Harness()
        h.ax.menu?.enabled = false
        let outcome = h.runReply()
        XCTAssertEqual(outcome.result.code, .aborted(.deadline))
        XCTAssertEqual(h.clock.uptime, 1000.25 + 3 + 0.25, "3 s from t_front, then the 0.25 s hide")
        XCTAssertTrue(h.recorder.facts.isEmpty)
        XCTAssertEqual(h.log.count(.pressMenu), 0)
    }

    func testAMenuItemFirstSeenEnabledAfterTheDeadlineIsNeverPressed() {
        // The read that starts 2.9 s after `t_front` ends 0.2 s later, past the 3 s, with the item enabled.
        let h = Harness()
        h.ax.menu?.enabled = false
        h.ax.onMenuRead = { [unowned h] in
            guard h.log.count(.activate) == 1, h.clock.uptime >= 1000.25 + 2.9, h.ax.menu?.enabled == false else {
                return
            }
            h.clock.advance(0.2)
            h.ax.menu?.enabled = true
        }
        let outcome = h.runReply()
        XCTAssertEqual(outcome.result.code, .aborted(.deadline))
        XCTAssertEqual(h.log.count(.pressMenu), 0)
        XCTAssertTrue(h.recorder.facts.isEmpty)
        XCTAssertTrue(h.log.keys.isEmpty)
    }

    func testAReplyFieldFirstReadAfterTheDeadlineIsAbortedDeadline() {
        // The thread view shows 2.9 s after the press, and the focus read that finds its field ends past the 3 s.
        let h = Harness()
        h.ax.openDelay = 2.9
        var slowed = false
        h.ax.focusOverride = { [unowned h] in
            if !slowed {
                slowed = true
                h.clock.advance(0.2)
            }
            return ScriptedAX.threadComposerRef
        }
        let outcome = h.runReply()
        XCTAssertTrue(slowed)
        XCTAssertEqual(outcome.result.code, .aborted(.deadline))
        XCTAssertTrue(h.log.writes.isEmpty)
        XCTAssertFalse(h.log.keys.contains(.returnKey))
    }

    // MARK: - Step 4

    func testEditFieldOfAnotherBubbleIsAbortedView() {
        let h = Harness()
        h.ax.editOwner = AXRef(id: 99)
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result.code, .aborted(.check("view")))
        XCTAssertFalse(h.log.keys.contains(.returnKey))
    }

    func testOtherBubblesMustMatchTheSignatureWithTheTargetLeftOut() {
        let h = Harness()
        h.targeting.signatureMatches = false
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result.code, .aborted(.check("view")))
        XCTAssertEqual(h.targeting.verifyExcluding, [410])
        XCTAssertFalse(h.log.keys.contains(.returnKey))
    }

    func testFieldMustHoldExactlyTheIntendedText() {
        for change in [{ (s: String) in s + " " }, { (s: String) in s.uppercased() }, { _ in "" }] {
            let h = Harness()
            h.ax.transform = change
            let outcome = h.runEdit()
            XCTAssertEqual(outcome.result.code, .aborted(.check("field")))
            XCTAssertFalse(h.log.keys.contains(.returnKey))
        }
    }

    func testFieldReadErrorBeforeReturnIsAbortedField() {
        let h = Harness()
        h.log.onEvent = { [unowned h] event in if event == .verifySelected { h.ax.failRead = true } }
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result.code, .aborted(.check("field")))
        XCTAssertFalse(h.log.keys.contains(.returnKey))
    }

    func testEditWindowClosingAfterActivationIsExpiredBeforeReturn() {
        let h = Harness()
        // Reads: leaving the queue, before `open -b`, at `t_front`, right before the press, as the press's final
        // check, before Return.
        h.editWindowByCall = { $0 < 6 }
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result, ActionResult(.expired, notes: [.mayHaveMarkedRead]))
        XCTAssertEqual(h.editWindowArgs.count, 6)
        XCTAssertFalse(h.log.keys.contains(.returnKey))
        XCTAssertEqual(h.log.writes, [Harness.newText, Harness.oldText])
        XCTAssertEqual(h.log.count(.hide), 1)
    }

    func testEditWindowClosingDuringTheLastChecksIsExpiredWithNoReturn() {
        // The window closes while the view check reads AX, after the window check that opens step 4.
        let h = Harness()
        h.log.onEvent = { [unowned h] event in
            if event == .verifySelected {
                h.clock.advance(0.5)
                h.editWindowOpen = false
            }
        }
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result, ActionResult(.expired, notes: [.mayHaveMarkedRead]))
        XCTAssertFalse(h.log.keys.contains(.returnKey))
        XCTAssertEqual(h.recorder.invokedCount, 0)
        XCTAssertEqual(h.log.writes, [Harness.newText, Harness.oldText], "field restored")
        XCTAssertEqual(h.log.count(.hide), 1)
        XCTAssertEqual(h.log.count(.verify), 0)
    }

    func testEditWindowIsCheckedAfterTheFocusReadRightBeforeReturn() {
        // The focused-field read before Return can block. The window closes there, and the window check after it
        // catches that before the ownership check and the key post.
        let h = Harness()
        h.ax.focusOverride = { [unowned h] in
            h.editWindowOpen = false
            return ScriptedAX.editRef
        }
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result, ActionResult(.expired, notes: [.mayHaveMarkedRead]))
        XCTAssertFalse(h.log.keys.contains(.returnKey))
        XCTAssertEqual(h.log.writes, [Harness.newText, Harness.oldText], "field restored")
        XCTAssertEqual(h.log.count(.hide), 1)
    }

    func testEditWindowClosingBeforeThePressIsExpiredWithNoPress() {
        let h = Harness()
        h.editWindowByCall = { $0 < 3 }
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result.code, .expired)
        XCTAssertEqual(h.log.count(.activate), 1)
        XCTAssertTrue(h.recorder.facts.isEmpty)
        XCTAssertEqual(h.log.count(.perform(UINames.edit)), 0)
        XCTAssertEqual(h.log.count(.hide), 1)
    }

    func testEditWindowClosingWhileTheBubbleIsFoundAgainIsExpiredWithNoPress() {
        // The window is open at `t_front` and closes during the AX walk that finds the bubble again, before the
        // journal write and the ownership check. The check right before the press catches it.
        let h = Harness()
        var activated = false
        h.log.onEvent = { [unowned h] event in
            if event == .activate { activated = true }
            if activated, event == .findBubble {
                h.clock.advance(0.5)
                h.editWindowOpen = false
            }
        }
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result, ActionResult(.expired, notes: [.mayHaveMarkedRead]))
        XCTAssertEqual(h.log.count(.perform(UINames.edit)), 0)
        XCTAssertTrue(h.log.writes.isEmpty)
        XCTAssertTrue(h.log.keys.isEmpty)
        XCTAssertEqual(h.recorder.invokedCount, 0)
        XCTAssertEqual(h.log.count(.hide), 1)
        XCTAssertEqual(h.log.count(.verify), 0)
    }

    func testThreadViewParentMustMatchDirectionBodyAndMinute() {
        // Step 4's check: a parent bubble that doesn't match is `aborted: parent changed` (section 4 step 5), and a
        // thread view with no parent bubble is `aborted: view`.
        let base = Harness()
        var flipped = Harness.parentBubble(for: base.parent)
        flipped.fromMe = true
        var otherBody = Harness.parentBubble(for: base.parent)
        otherBody.text = "Are you close?!"
        var otherMinute = Harness.parentBubble(for: base.parent)
        otherMinute.minuteLabel = Harness.minuteLabel(base.parent.dateNs + 60_000_000_000)
        var noMinute = Harness.parentBubble(for: base.parent)
        noMinute.minuteLabel = "Yesterday"
        let cases: [(String, BubbleInfo?, ResultCode)] = [
            ("direction", flipped, .aborted(.parentChanged)), ("body", otherBody, .aborted(.parentChanged)),
            ("minute", otherMinute, .aborted(.parentChanged)), ("no minute", noMinute, .aborted(.parentChanged)),
            ("no parent", nil, .aborted(.check("view"))),
        ]
        for (name, shown, code) in cases {
            let h = Harness()
            h.ax.threadParent = shown
            let outcome = h.runReply()
            XCTAssertEqual(outcome.result.code, code, name)
            XCTAssertFalse(h.log.keys.contains(.returnKey), name)
            XCTAssertEqual(h.log.count(.verify), 0, name)
            XCTAssertEqual(h.log.writes, [Harness.replyText, ""], "\(name): reply field restored")
        }
    }

    func testThreadViewReadFailingOrGoneAtTheStep4CheckIsAbortedView() {
        for name in ["failed read", "no thread view"] {
            let h = Harness()
            var readsAfterWrite = 0
            h.ax.onThreadRead = { [unowned h] in
                guard h.log.writes.contains(Harness.replyText) else { return }
                readsAfterWrite += 1
                guard readsAfterWrite == 1 else { h.ax.failThread = false; return }
                if name == "failed read" { h.ax.failThread = true } else { h.ax.threadOpen = false }
            }
            let outcome = h.runReply()
            XCTAssertGreaterThanOrEqual(readsAfterWrite, 1, name)
            XCTAssertEqual(outcome.result.code, .aborted(.check("view")), name)
            XCTAssertFalse(h.log.keys.contains(.returnKey), name)
            XCTAssertEqual(h.recorder.invokedCount, 0, name)
        }
    }

    func testThreadViewParentBodyComparesAfterNFC() {
        let h = Harness()
        var decomposed = Harness.parentBubble(for: h.parent)
        decomposed.text = "Cafe\u{301}?"
        h.ax.threadParent = decomposed
        var parent = h.parent
        parent.body = "Caf\u{E9}?"
        h.source.newest = { parent }
        let run = ForegroundRun(chat: h.chat, action: .threadedReply(parent: parent, text: Harness.replyText),
                                queueDeadline: 1030)
        let outcome = h.machine.run(run, recorder: h.recorder)
        XCTAssertEqual(outcome.result.code, .submitted)
    }

    func testThreadViewParentMatchesAChatDBBodyWithATrailingNewline() {
        let h = Harness()
        var parent = h.parent
        parent.body = "Are you close?\n"
        h.source.newest = { parent }
        var shown = Harness.parentBubble(for: parent)
        shown.text = "Are you close?"
        h.ax.threadParent = shown
        let run = ForegroundRun(chat: h.chat, action: .threadedReply(parent: parent, text: Harness.replyText),
                                queueDeadline: 1030)
        let outcome = h.machine.run(run, recorder: h.recorder)
        XCTAssertEqual(outcome.result.code, .submitted)
        XCTAssertEqual(h.log.keys.first, .returnKey)
    }

    func testNewestIncomingChangedBeforeReturnIsParentChanged() {
        let h = Harness()
        var newer = h.parent
        newer.guid = "newer-guid"
        var reads = 0
        let parent = h.parent
        h.source.newest = {
            reads += 1
            return reads == 1 ? parent : newer
        }
        let outcome = h.runReply()
        XCTAssertEqual(outcome.result.code, .aborted(.parentChanged))
        XCTAssertEqual(reads, 2)
        XCTAssertFalse(h.log.keys.contains(.returnKey))
        XCTAssertEqual(h.log.writes, [Harness.replyText, ""], "reply field restored")
        XCTAssertEqual(h.log.count(.hide), 1)
    }

    func testNewestIncomingReadErrorBeforeReturnIsAbortedView() {
        let h = Harness()
        var reads = 0
        let parent = h.parent
        h.source.newest = {
            reads += 1
            if reads > 1 { throw FakeRows.Failure() }
            return parent
        }
        let outcome = h.runReply()
        XCTAssertEqual(outcome.result.code, .aborted(.check("view")))
        XCTAssertFalse(h.log.keys.contains(.returnKey))
    }
}
