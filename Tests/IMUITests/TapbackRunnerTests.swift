import XCTest
import IMCore
import IMStore
@testable import IMUI
import IMTestSupport

/// Checklist items 5, 11, 13 and 14 for tapbacks, plus the journal contract.
final class TapbackRunnerTests: XCTestCase {
    let bubble = Make.bubble(51, text: "on my way", minute: "12:29 AM",
                             actions: UINames.classicTapbacks + ["😭", "🙏🏾", "Add Emoji as Tapback", "Reply…",
                                                                 "Delete…", "Copy"])

    func setup(_ configure: (Rig, FakeTargeting) -> Void = { _, _ in }) -> (Rig, FakeTargeting, TapbackRunner) {
        let rig = Rig()
        let targeting = FakeTargeting(log: rig.log, bubble: bubble)
        configure(rig, targeting)
        let runner = TapbackRunner(ax: rig.ax, windows: rig.windows, targeting: targeting, source: rig.source,
                                   clock: rig.clock)
        return (rig, targeting, runner)
    }

    func request(_ kind: TapbackKind = .heart, remove: Bool = false,
                 target: MessageTargetInfo = Make.target()) -> TapbackRequest {
        TapbackRequest(target: target, chat: Make.chat(), kind: kind, remove: remove)
    }

    /// The verifying row shows up `delay` seconds after the press.
    func verifyingRow(_ rig: Rig, type: Int, emoji: String? = nil, after delay: TimeInterval = 1) {
        let clock = rig.clock
        var pressedAt: TimeInterval?
        rig.ax.onPerform = { _, _ in pressedAt = clock.uptime }
        rig.source.reactionRowsProvider = { above in
            guard let pressedAt, clock.uptime - pressedAt >= delay else { return [] }
            return [Make.reaction(rowid: above + 1, type: type, emoji: emoji)]
        }
    }

    // MARK: - Happy path and journal order

    func testHeartAddPressesOnceAndVerifies() {
        let (rig, _, runner) = setup()
        verifyingRow(rig, type: 2000)
        rig.source.reactionAfter = { .heart }
        let result = runner.run(request(), queueDeadline: rig.clock.uptime + 30, recorder: rig.recorder)
        XCTAssertEqual(result.result, ActionResult(.ok, notes: [.mayHaveMarkedRead]))
        XCTAssertEqual(result.result.rendered, "ok, chat opened, may be marked read")
        XCTAssertEqual(result.currentReaction, .heart)
        XCTAssertTrue(result.pressed)
        XCTAssertEqual(rig.ax.performed.map(\.action), ["Heart"])
        XCTAssertEqual(rig.ax.performed.map(\.ref), [AXRef(id: 51)])
    }

    func testJournalFactsAreWrittenBeforeThePressAndClosedAfter() {
        let (rig, _, runner) = setup()
        rig.source.maxRowID = 812
        verifyingRow(rig, type: 2000)
        let target = Make.target(rowid: 101, guid: "GUID-101")
        _ = runner.run(request(target: target), queueDeadline: rig.clock.uptime + 30, recorder: rig.recorder)
        XCTAssertEqual(rig.recorder.facts, [InvocationFacts(snapshotRowID: 812, targetGUID: "GUID-101", targetPart: 0,
                                                            targetRowID: 101)])
        let will = rig.log.index(of: "journal.willInvoke")!
        let press = rig.log.index(of: "ax.perform")!
        let did = rig.log.index(of: "journal.didInvoke")!
        let snapshot = rig.log.index(of: "db.maxRowID")!
        XCTAssertLessThan(snapshot, will)
        XCTAssertLessThan(will, press)
        XCTAssertLessThan(press, did)
        XCTAssertEqual(rig.recorder.didInvokeCount, 1)
    }

    func testJournalWriteFailurePressesNothing() {
        let (rig, _, runner) = setup()
        rig.recorder.failWillInvoke = true
        let result = runner.run(request(), queueDeadline: rig.clock.uptime + 30, recorder: rig.recorder)
        XCTAssertEqual(result.result.code, .error(.message("journal write failed")))
        XCTAssertEqual(result.result.rendered,
                       "error: journal write failed, chat opened, may be marked read fix: free disk space and retry")
        XCTAssertFalse(result.result.holdsIdempotencyKey)
        XCTAssertFalse(rig.log.contains("ax.perform"))
        XCTAssertFalse(rig.log.contains("journal.didInvoke"))
    }

    func testSnapshotReadFailurePressesNothing() {
        let (rig, _, runner) = setup()
        rig.source.failing = [.maxRowID]
        let result = runner.run(request(), queueDeadline: rig.clock.uptime + 30, recorder: rig.recorder)
        XCTAssertEqual(result.result.code, UIResults.readFailed.code)
        XCTAssertFalse(rig.log.contains("journal.willInvoke"))
        XCTAssertFalse(rig.log.contains("ax.perform"))
    }

    // MARK: - Set-state semantics (item 11)

    func testAlreadySetIsAlreadyWithNoWindowWorkOrPress() {
        let (rig, _, runner) = setup { rig, _ in rig.source.reaction = .heart }
        rig.app.current = .notRunning
        let result = runner.run(request(.heart), queueDeadline: rig.clock.uptime + 30, recorder: rig.recorder)
        XCTAssertEqual(result, UIActionResult(result: ActionResult(.already), currentReaction: .heart, pressed: false))
        XCTAssertTrue(rig.app.calls.isEmpty, "Messages was launched for a no-op")
        XCTAssertFalse(rig.log.contains("target.select"))
        XCTAssertNoPress(rig.log)
        XCTAssertTrue(rig.recorder.facts.isEmpty)
    }

    func testRemovingAReactionThatIsNotSetIsAlready() {
        for current: TapbackKind? in [nil, .like, .emoji("😭")] {
            let (rig, _, runner) = setup { rig, _ in rig.source.reaction = current }
            let result = runner.run(request(.heart, remove: true), queueDeadline: rig.clock.uptime + 30,
                                    recorder: rig.recorder)
            XCTAssertEqual(result.result, ActionResult(.already), "\(String(describing: current))")
            XCTAssertEqual(result.currentReaction, current)
            XCTAssertNoPress(rig.log)
        }
    }

    func testReactionSetElsewhereDuringTheWindowWorkIsAlreadyWithNoPress() {
        // A Heart from another device lands while the chat is being opened.
        let (rig, targeting, runner) = setup()
        targeting.onSelect = { rig.source.reaction = .heart }
        let result = runner.run(request(.heart), queueDeadline: rig.clock.uptime + 30, recorder: rig.recorder)
        XCTAssertEqual(result, UIActionResult(result: ActionResult(.already, notes: [.mayHaveMarkedRead]),
                                              currentReaction: .heart, pressed: true))
        XCTAssertEqual(result.result.rendered, "already, chat opened, may be marked read")
        XCTAssertTrue(rig.ax.performed.isEmpty, "the Heart would have been toggled off")
        XCTAssertFalse(rig.log.contains("ax.perform"))
        XCTAssertTrue(rig.recorder.facts.isEmpty)
        XCTAssertEqual(rig.log.count(of: "db.currentReaction"), 2)
        XCTAssertLessThan(rig.log.index(of: "target.find")!,
                          rig.log.events.lastIndex { $0.hasPrefix("db.currentReaction") }!,
                          "the second read comes after the window work and the bubble lookup")
    }

    func testReactionRemovedElsewhereBeforeARemoveIsAlready() {
        let (rig, targeting, runner) = setup { rig, _ in rig.source.reaction = .laugh }
        targeting.onSelect = { rig.source.reaction = nil }
        let result = runner.run(request(.laugh, remove: true), queueDeadline: rig.clock.uptime + 30,
                                recorder: rig.recorder)
        XCTAssertEqual(result.result, ActionResult(.already, notes: [.mayHaveMarkedRead]))
        XCTAssertNil(result.currentReaction)
        XCTAssertNoPress(rig.log)
    }

    func testReactionReadFailingAfterTheWindowWorkPressesNothing() {
        let (rig, targeting, runner) = setup()
        targeting.onSelect = { rig.source.failing = [.currentReaction] }
        let result = runner.run(request(), queueDeadline: rig.clock.uptime + 30, recorder: rig.recorder)
        XCTAssertEqual(result.result, UIResults.readFailed.adding([.mayHaveMarkedRead]))
        XCTAssertTrue(result.pressed)
        XCTAssertFalse(rig.log.contains("ax.perform"))
        XCTAssertFalse(rig.log.contains("journal.willInvoke"))
    }

    func testReactionChangedToAnotherKindElsewhereStillPresses() {
        let (rig, targeting, runner) = setup()
        targeting.onSelect = { rig.source.reaction = .like }
        verifyingRow(rig, type: 2000)
        let result = runner.run(request(.heart), queueDeadline: rig.clock.uptime + 30, recorder: rig.recorder)
        XCTAssertEqual(result.result.code, .ok)
        XCTAssertEqual(rig.ax.performed.map(\.action), ["Heart"])
    }

    func testReplacingAnotherKindPresses() {
        let (rig, _, runner) = setup { rig, _ in rig.source.reaction = .like }
        verifyingRow(rig, type: 2000)
        let result = runner.run(request(.heart), queueDeadline: rig.clock.uptime + 30, recorder: rig.recorder)
        XCTAssertEqual(result.result.code, .ok)
        XCTAssertEqual(rig.ax.performed.map(\.action), ["Heart"])
    }

    func testRemoveVerifiesWithTheRemoveType() {
        let (rig, _, runner) = setup { rig, _ in rig.source.reaction = .laugh }
        verifyingRow(rig, type: 3003)
        rig.source.reactionAfter = { nil }
        let result = runner.run(request(.laugh, remove: true), queueDeadline: rig.clock.uptime + 30,
                                recorder: rig.recorder)
        XCTAssertEqual(result.result.code, .ok)
        XCTAssertNil(result.currentReaction)
        XCTAssertEqual(rig.ax.performed.map(\.action), ["Ha ha!"])
    }

    func testAddTypeDoesNotVerifyARemove() {
        let (rig, _, runner) = setup { rig, _ in rig.source.reaction = .laugh }
        verifyingRow(rig, type: 2003)
        let result = runner.run(request(.laugh, remove: true), queueDeadline: rig.clock.uptime + 30,
                                recorder: rig.recorder)
        XCTAssertEqual(result.result.code, .mayHaveCompleted)
    }

    func testVerifyWaitBoundaryAtTenSeconds() {
        func run(rowAfter delay: TimeInterval) -> UIActionResult {
            let (rig, _, runner) = setup()
            runner.pollInterval = 0.25
            verifyingRow(rig, type: 2000, after: delay)
            return runner.run(request(), queueDeadline: rig.clock.uptime + 30, recorder: rig.recorder)
        }
        XCTAssertEqual(run(rowAfter: 9.75).result.code, .ok)
        XCTAssertEqual(run(rowAfter: 10.0).result.code, .ok)
        let late = run(rowAfter: 10.01)
        XCTAssertEqual(late.result, ActionResult(.mayHaveCompleted, notes: [.mayHaveMarkedRead]))
        XCTAssertEqual(late.result.rendered, "may_have_completed, chat opened, may be marked read")
        XCTAssertTrue(late.pressed)
    }

    func testRowsThatDoNotVerify() {
        // Not from me, at or below the snapshot, or the wrong kind: none of them count.
        let (rig, _, runner) = setup()
        rig.source.maxRowID = 500
        rig.source.reactionRowsProvider = { _ in
            [Make.reaction(rowid: 501, type: 2000, fromMe: false), Make.reaction(rowid: 500, type: 2000),
             Make.reaction(rowid: 502, type: 2001), Make.reaction(rowid: 503, guid: "OTHER", type: 2000)]
        }
        let result = runner.run(request(), queueDeadline: rig.clock.uptime + 30, recorder: rig.recorder)
        XCTAssertEqual(result.result.code, .mayHaveCompleted)
    }

    func testEmojiAddNeedsTheSameEmojiAndRemoveAcceptsNone() {
        XCTAssertTrue(try TapbackRunner.verifyingRowExists(in: source([Make.reaction(rowid: 9, type: 2006, emoji: "😭")]),
                                                           targetGUID: "GUID-101", part: 0, aboveRowID: 1,
                                                           kind: .emoji("😭"), remove: false))
        XCTAssertFalse(try TapbackRunner.verifyingRowExists(in: source([Make.reaction(rowid: 9, type: 2006, emoji: "🥲")]),
                                                            targetGUID: "GUID-101", part: 0, aboveRowID: 1,
                                                            kind: .emoji("😭"), remove: false))
        XCTAssertFalse(try TapbackRunner.verifyingRowExists(in: source([Make.reaction(rowid: 9, type: 2006)]),
                                                            targetGUID: "GUID-101", part: 0, aboveRowID: 1,
                                                            kind: .emoji("😭"), remove: false))
        XCTAssertTrue(try TapbackRunner.verifyingRowExists(in: source([Make.reaction(rowid: 9, type: 3006)]),
                                                           targetGUID: "GUID-101", part: 0, aboveRowID: 1,
                                                           kind: .emoji("😭"), remove: true))
        XCTAssertFalse(try TapbackRunner.verifyingRowExists(in: source([Make.reaction(rowid: 9, type: 3006, emoji: "🥲")]),
                                                            targetGUID: "GUID-101", part: 0, aboveRowID: 1,
                                                            kind: .emoji("😭"), remove: true))
    }

    func testEveryClassicKindUsesItsTypes() {
        let kinds: [TapbackKind] = [.heart, .like, .dislike, .laugh, .emphasize, .question]
        for (offset, kind) in kinds.enumerated() {
            XCTAssertTrue(try TapbackRunner.verifyingRowExists(in: source([Make.reaction(rowid: 9, type: 2000 + offset)]),
                                                               targetGUID: "GUID-101", part: 0, aboveRowID: 1,
                                                               kind: kind, remove: false))
            XCTAssertTrue(try TapbackRunner.verifyingRowExists(in: source([Make.reaction(rowid: 9, type: 3000 + offset)]),
                                                               targetGUID: "GUID-101", part: 0, aboveRowID: 1,
                                                               kind: kind, remove: true))
        }
    }

    func source(_ rows: [ReactionRowProbe]) -> FakeUISource {
        let source = FakeUISource(log: EventLog())
        source.reactionRowsProvider = { _ in rows }
        return source
    }

    func testCurrentReactionReadFailurePressesNothing() {
        let (rig, _, runner) = setup { rig, _ in rig.source.failing = [.currentReaction] }
        let result = runner.run(request(), queueDeadline: rig.clock.uptime + 30, recorder: rig.recorder)
        XCTAssertEqual(result.result, UIResults.readFailed)
        XCTAssertFalse(result.pressed)
        XCTAssertNoPress(rig.log)
        XCTAssertTrue(rig.app.calls.isEmpty)
    }

    // MARK: - Refusals before the press

    func testGroupAndMultipartTargetsAreUnsupportedTargetWithNoReads() {
        for target in [Make.target(group: true), Make.target(parts: 2), Make.target(singlePartText: false)] {
            let (rig, _, runner) = setup()
            let result = runner.run(request(target: target), queueDeadline: rig.clock.uptime + 30,
                                    recorder: rig.recorder)
            XCTAssertEqual(result.result, ActionResult(.unsupportedTarget))
            XCTAssertFalse(result.pressed)
            XCTAssertTrue(rig.log.events.isEmpty, "\(rig.log.events)")
        }
    }

    func testEmojiKindThatIsNotOneEmojiIsUnsupported() {
        // TapbackKind(wireName:) accepts any non-ASCII text as an emoji, so "Delete…" must never reach a press.
        for text in ["Delete…", "Reply…", "…", "😭😭", "Add Emoji as Tapback"] {
            let (rig, _, runner) = setup()
            let result = runner.run(request(.emoji(text)), queueDeadline: rig.clock.uptime + 30,
                                    recorder: rig.recorder)
            XCTAssertEqual(result.result, ActionResult(.unsupported), text)
            XCTAssertTrue(rig.log.events.isEmpty, "\(text): \(rig.log.events)")
        }
    }

    func testBusyWindowStopsBeforeSelection() {
        let (rig, _, runner) = setup()
        rig.app.current = Make.state(hidden: false, ax: 1)
        let result = runner.run(request(), queueDeadline: rig.clock.uptime + 30, recorder: rig.recorder)
        XCTAssertEqual(result.result, .messagesOpen)
        XCTAssertFalse(result.pressed)
        XCTAssertFalse(rig.log.contains("target.select"))
        XCTAssertNoPress(rig.log)
    }

    func testRefusedSelectionWithNoPressHasNoMarkReadNote() {
        let (rig, targeting, runner) = setup()
        targeting.selection = .refused(ActionResult(.ambiguous(.target)))
        let result = runner.run(request(), queueDeadline: rig.clock.uptime + 30, recorder: rig.recorder)
        XCTAssertEqual(result.result, ActionResult(.ambiguous(.target)))
        XCTAssertFalse(result.pressed)
        XCTAssertFalse(rig.log.contains("target.find"))
        XCTAssertTrue(rig.recorder.facts.isEmpty)
    }

    func testWrongChatAfterThePressCountsAsPressed() {
        let (rig, targeting, runner) = setup()
        targeting.selection = .refused(ActionResult(.error(.wrongChat), notes: [.mayHaveMarkedRead]))
        let start = rig.clock.uptime
        let result = runner.run(request(), queueDeadline: start + 30, recorder: rig.recorder)
        XCTAssertEqual(result.result, ActionResult(.error(.wrongChat), notes: [.mayHaveMarkedRead]))
        XCTAssertTrue(result.pressed)
        XCTAssertEqual(rig.clock.uptime - start, Limits.visibilityPoll, accuracy: 0.0001, "visibility poll ran")
        XCTAssertFalse(rig.log.contains("ax.perform"))
    }

    func testBubbleNotLoadedAfterTheChatPressCarriesTheNote() {
        let (rig, targeting, runner) = setup()
        targeting.lookup = .refused(ActionResult(.notLoaded))
        let result = runner.run(request(), queueDeadline: rig.clock.uptime + 30, recorder: rig.recorder)
        XCTAssertEqual(result.result, ActionResult(.notLoaded, notes: [.mayHaveMarkedRead]))
        XCTAssertTrue(result.pressed)
        XCTAssertFalse(rig.log.contains("ax.perform"))
    }

    // MARK: - Missing action names (item 13)

    func testMissingActionNameIsUnsupportedWithNoPress() {
        let noHeart = Make.bubble(51, text: "on my way", minute: "12:29 AM", actions: ["Thumbs up", "Reply…"])
        let (rig, targeting, runner) = setup()
        targeting.lookup = .found(noHeart)
        let result = runner.run(request(.heart), queueDeadline: rig.clock.uptime + 30, recorder: rig.recorder)
        XCTAssertEqual(result.result, ActionResult(.unsupported, notes: [.mayHaveMarkedRead]))
        XCTAssertFalse(rig.log.contains("ax.perform"))
        XCTAssertFalse(rig.log.contains("journal.willInvoke"))
    }

    func testRecentEmojiIsPressedByItsOwnName() {
        let (rig, _, runner) = setup()
        verifyingRow(rig, type: 2006, emoji: "🙏🏾")
        let result = runner.run(request(.emoji("🙏🏾")), queueDeadline: rig.clock.uptime + 30, recorder: rig.recorder)
        XCTAssertEqual(result.result.code, .ok)
        XCTAssertEqual(rig.ax.performed.map(\.action), ["🙏🏾"])
    }

    func testEmojiNotInTheRecentsIsUnsupported() {
        let (rig, _, runner) = setup()
        let result = runner.run(request(.emoji("🎉")), queueDeadline: rig.clock.uptime + 30, recorder: rig.recorder)
        XCTAssertEqual(result.result.code, .unsupported)
        XCTAssertFalse(rig.log.contains("ax.perform"))
    }

    func testActionVanishingAtThePressIsUnsupported() {
        let (rig, _, runner) = setup()
        rig.ax.performError = .actionMissing("Heart")
        let result = runner.run(request(), queueDeadline: rig.clock.uptime + 30, recorder: rig.recorder)
        XCTAssertEqual(result.result, ActionResult(.unsupported, notes: [.mayHaveMarkedRead]))
        XCTAssertFalse(rig.log.contains("db.reactionRows"), "nothing was performed, so nothing to verify")
        XCTAssertEqual(rig.recorder.didInvokeCount, 1, "the journal entry is closed")
    }

    func testAXErrorsThatProveNoPressMapToTheirOwnResults() {
        let cases: [(AXDriveError, ActionResult)] = [
            (.notTrusted, UIResults.accessibilityMissing),
            (.notRunning, ActionResult(.noHiddenWindow)),
            (.staleReference, ActionResult(.notLoaded)),
        ]
        for (error, expected) in cases {
            let (rig, _, runner) = setup()
            rig.ax.performError = error
            let result = runner.run(request(), queueDeadline: rig.clock.uptime + 30, recorder: rig.recorder)
            XCTAssertEqual(result.result, expected.adding([.mayHaveMarkedRead]), "\(error)")
            XCTAssertFalse(result.result.holdsIdempotencyKey, "\(error)")
            XCTAssertFalse(rig.log.contains("db.reactionRows"), "\(error): nothing ran, so nothing to verify")
            XCTAssertEqual(rig.recorder.didInvokeCount, 1, "\(error): the journal entry is closed")
        }
        XCTAssertEqual(UIResults.accessibilityMissing.rendered,
                       "error: Accessibility not granted fix: run imessage doctor --ui")
    }

    func testAXErrorAtThePressStillVerifies() {
        let (rig, _, runner) = setup()
        rig.ax.performError = .axError(-25204)
        rig.source.reactionRowsProvider = { above in [Make.reaction(rowid: above + 1, type: 2000)] }
        let result = runner.run(request(), queueDeadline: rig.clock.uptime + 30, recorder: rig.recorder)
        XCTAssertEqual(result.result.code, .ok)
    }

    // MARK: - Visibility and mark-read notes (items 4 and 14)

    func testWindowShowingAfterThePressAddsTheNote() {
        let (rig, _, runner) = setup()
        verifyingRow(rig, type: 2000)
        rig.app.onState = { state in
            if rig.log.contains("ax.perform") { state = Make.state(hidden: false, ax: 1, onScreen: 1) }
        }
        let result = runner.run(request(), queueDeadline: rig.clock.uptime + 30, recorder: rig.recorder)
        XCTAssertEqual(result.result, ActionResult(.ok, notes: [.messagesBecameVisible, .mayHaveMarkedRead]))
        XCTAssertEqual(result.result.rendered, "ok, error: Messages became visible, chat opened, may be marked read")
    }

    func testWindowFlashingRightAfterThePressIsCaught() {
        // The window shows for 0.3 s after the press and hides again while the verifying row is still on its way.
        let (rig, _, runner) = setup()
        verifyingRow(rig, type: 2000, after: 2)
        let clock = rig.clock
        var pressedAt: TimeInterval?
        let verify = rig.ax.onPerform
        rig.ax.onPerform = { action, ref in
            pressedAt = clock.uptime
            verify?(action, ref)
        }
        rig.app.onState = { state in
            if let pressedAt, clock.uptime - pressedAt < 0.3 { state = Make.state(hidden: false, ax: 1, onScreen: 1) }
        }
        let result = runner.run(request(), queueDeadline: clock.uptime + 30, recorder: rig.recorder)
        XCTAssertEqual(result.result, ActionResult(.ok, notes: [.messagesBecameVisible, .mayHaveMarkedRead]))
    }

    func testVerifyDeadlineCountsFromThePressAndThePollRunsOnce() {
        let (rig, _, runner) = setup()
        let clock = rig.clock
        var pressedAt: TimeInterval?
        rig.ax.onPerform = { _, _ in pressedAt = clock.uptime }
        let result = runner.run(request(), queueDeadline: clock.uptime + 30, recorder: rig.recorder)
        XCTAssertEqual(result.result, ActionResult(.mayHaveCompleted, notes: [.mayHaveMarkedRead]))
        XCTAssertEqual(clock.uptime - pressedAt!, Limits.uiVerifyTimeout, accuracy: 0.0001,
                       "the 1 s poll is inside the 10 s, and finish doesn't poll again")
    }

    func testZeroPollIntervalsStillReachTheDeadlines() {
        let (rig, _, runner) = setup()
        runner.pollInterval = 0
        rig.windows.pollInterval = -1
        let start = rig.clock.uptime
        let result = runner.run(request(), queueDeadline: start + 30, recorder: rig.recorder)
        XCTAssertEqual(result.result.code, .mayHaveCompleted)
        XCTAssertEqual(rig.clock.uptime - start, Limits.uiVerifyTimeout, accuracy: 0.0001)
        XCTAssertFalse(rig.clock.sleeps.contains { $0 <= 0 })
    }

    func testColdLaunchNoteIsCarriedIntoTheResult() {
        let (rig, _, runner) = setup()
        rig.app.current = .notRunning
        let clock = rig.clock
        let start = clock.uptime
        rig.app.onState = { state in
            guard rig.app.calls.contains(.launchHidden) else { return }
            state = clock.uptime - start < 0.5 ? Make.state(hidden: false, ax: 1, onScreen: 1) : Make.readyState
        }
        verifyingRow(rig, type: 2000)
        let result = runner.run(request(), queueDeadline: start + 30, recorder: rig.recorder)
        XCTAssertEqual(result.result, ActionResult(.ok, notes: [.messagesBecameVisible, .mayHaveMarkedRead]))
    }

    // MARK: - End to end over the real targeter

    func testEndToEndWithTheRealTargeter() {
        let rig = Rig()
        rig.source.summaries = [Make.summary()]
        rig.ax.rows = [Make.row(2, "Jordan, see you, 12:20 AM")]
        let transcript = [Make.bubble(51, fromMe: true, text: "on my way", minute: "12:29 AM", actions: ["Heart"]),
                          Make.bubble(52, fromMe: false, text: "see you", minute: "12:20 AM")]
        rig.ax.bubbles = { [unowned ax = rig.ax] in ax.pressedRows.isEmpty ? [] : transcript }
        verifyingRow(rig, type: 2000)
        let runner = TapbackRunner(ax: rig.ax, windows: rig.windows, targeting: rig.targeter(), source: rig.source,
                                   clock: rig.clock)
        let target = Make.target(body: "on my way", dateNs: Make.nanos(2026, 11, 6, 0, 29))
        let result = runner.run(request(target: target), queueDeadline: rig.clock.uptime + 30,
                                recorder: rig.recorder)
        XCTAssertEqual(result.result, ActionResult(.ok, notes: [.mayHaveMarkedRead]))
        XCTAssertEqual(rig.log.count(of: "ax.pressRow"), 1)
        XCTAssertEqual(rig.ax.performed.map(\.action), ["Heart"])
    }

    // MARK: - Reconciliation

    func testVerifyOnlyReadsOnceAndNeverTouchesMessages() {
        let (rig, _, runner) = setup()
        rig.source.reactionRowsProvider = { above in [Make.reaction(rowid: above + 1, type: 2000)] }
        XCTAssertEqual(runner.verifyOnly(targetGUID: "GUID-101", part: 0, aboveRowID: 500, kind: .heart,
                                         remove: false), ActionResult(.ok))
        XCTAssertEqual(runner.verifyOnly(targetGUID: "GUID-101", part: 0, aboveRowID: 500, kind: .heart,
                                         remove: true), ActionResult(.mayHaveCompleted))
        rig.source.failing = [.reactionRows]
        XCTAssertEqual(runner.verifyOnly(targetGUID: "GUID-101", part: 0, aboveRowID: 500, kind: .heart,
                                         remove: false), ActionResult(.mayHaveCompleted))
        XCTAssertEqual(rig.log.count(of: "db.reactionRows"), 3)
        XCTAssertFalse(rig.log.contains("ax."))
        XCTAssertTrue(rig.app.calls.isEmpty)
        XCTAssertTrue(rig.clock.sleeps.isEmpty)
    }

    func testVerifyOnlyIsSafeFromSeveralConnections() {
        let (rig, _, runner) = setup()
        rig.source.reactionRowsProvider = { above in above == 1 ? [Make.reaction(rowid: 2, type: 2000)] : [] }
        let lock = NSLock()
        var codes: [Int: ResultCode] = [:]
        DispatchQueue.concurrentPerform(iterations: 200) { i in
            let code = runner.verifyOnly(targetGUID: "GUID-101", part: 0, aboveRowID: Int64(i % 2 == 0 ? 1 : 5),
                                         kind: .heart, remove: false).code
            lock.lock()
            codes[i] = code
            lock.unlock()
        }
        XCTAssertEqual(codes.count, 200)
        for (i, code) in codes { XCTAssertEqual(code, i % 2 == 0 ? .ok : .mayHaveCompleted) }
    }
}
