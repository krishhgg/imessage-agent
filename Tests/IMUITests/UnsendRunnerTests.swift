import XCTest
import IMCore
import IMStore
@testable import IMUI
import IMTestSupport

/// Checklist items 12 and 13 for unsend, the 2-minute window and the journal contract.
final class UnsendRunnerTests: XCTestCase {
    let bubble = Make.bubble(51, text: "on my way", minute: "12:29 AM",
                             actions: UINames.classicTapbacks + [UINames.undoSend, UINames.edit, "Delete…"])

    func setup(_ configure: (Rig, FakeTargeting) -> Void = { _, _ in }) -> (Rig, FakeTargeting, UnsendRunner) {
        let rig = Rig()
        let targeting = FakeTargeting(log: rig.log, bubble: bubble)
        configure(rig, targeting)
        let runner = UnsendRunner(ax: rig.ax, windows: rig.windows, targeting: targeting, source: rig.source,
                                  clock: rig.clock)
        return (rig, targeting, runner)
    }

    /// A target sent `age` seconds before the fake clock's now.
    func target(age: TimeInterval = 30, rowid: Int64 = 101, fromMe: Bool = true) -> MessageTargetInfo {
        Make.target(rowid: rowid, fromMe: fromMe, dateNs: Fixture.nowNs - Int64(age * 1_000_000_000))
    }

    /// chat.db shows the row unsent `delay` seconds after the press.
    func unsentAfter(_ rig: Rig, _ delay: TimeInterval, body: String = "") {
        let clock = rig.clock
        var pressedAt: TimeInterval?
        rig.ax.onPerform = { _, _ in pressedAt = clock.uptime }
        rig.source.editStateProvider = { rowid in
            guard let pressedAt, clock.uptime - pressedAt >= delay else {
                return EditStateProbe(rowid: rowid, dateEditedNs: 0, dateRetractedNs: 0, body: "on my way")
            }
            return EditStateProbe(rowid: rowid, dateEditedNs: Fixture.nowNs, dateRetractedNs: 0, body: body)
        }
    }

    func run(_ runner: UnsendRunner, _ rig: Rig, _ target: MessageTargetInfo) -> UIActionResult {
        runner.run(target: target, chat: Make.chat(), queueDeadline: rig.clock.uptime + 30, recorder: rig.recorder)
    }

    // MARK: - Happy path

    func testUnsendPressesUndoSendAndVerifies() {
        let (rig, _, runner) = setup()
        unsentAfter(rig, 2)
        rig.source.maxRowID = 900
        let result = run(runner, rig, target())
        XCTAssertEqual(result, UIActionResult(result: ActionResult(.ok, notes: [.mayHaveMarkedRead]),
                                              currentReaction: nil, pressed: true))
        XCTAssertEqual(rig.ax.performed.map(\.action), ["Undo Send"])
        XCTAssertEqual(rig.recorder.facts, [InvocationFacts(snapshotRowID: 900, targetGUID: "GUID-101", targetPart: 0,
                                                            targetRowID: 101)])
        let will = rig.log.index(of: "journal.willInvoke")!
        let press = rig.log.index(of: "ax.perform")!
        let did = rig.log.index(of: "journal.didInvoke")!
        XCTAssertLessThan(will, press)
        XCTAssertLessThan(press, did)
    }

    func testVerifyWaitBoundaryAtTenSeconds() {
        func result(after delay: TimeInterval) -> ActionResult {
            let (rig, _, runner) = setup()
            runner.pollInterval = 0.25
            unsentAfter(rig, delay)
            return run(runner, rig, target()).result
        }
        XCTAssertEqual(result(after: 10.0).code, .ok)
        XCTAssertEqual(result(after: 10.01), ActionResult(.mayHaveCompleted, notes: [.mayHaveMarkedRead]))
    }

    func testEditedButNotEmptyIsNotAnUnsend() {
        let (rig, _, runner) = setup()
        unsentAfter(rig, 1, body: "on my way, edited")
        XCTAssertEqual(run(runner, rig, target()).result.code, .mayHaveCompleted)
    }

    func testJournalWriteFailurePressesNothing() {
        let (rig, _, runner) = setup()
        rig.recorder.failWillInvoke = true
        let result = run(runner, rig, target())
        XCTAssertEqual(result.result.code, .error(.message("journal write failed")))
        XCTAssertEqual(result.result.fix, "free disk space and retry")
        XCTAssertFalse(rig.log.contains("ax.perform"))
    }

    // MARK: - Refusals

    func testIncomingGroupAndMultipartAreUnsupportedTarget() {
        let cases = [target(fromMe: false), Make.target(group: true), Make.target(parts: 2),
                     Make.target(singlePartText: false)]
        for target in cases {
            let (rig, _, runner) = setup()
            XCTAssertEqual(run(runner, rig, target).result, ActionResult(.unsupportedTarget), "\(target)")
            XCTAssertNoPress(rig.log)
            XCTAssertTrue(rig.app.calls.isEmpty)
        }
    }

    func testAlreadyUnsentIsAlready() {
        let (rig, _, runner) = setup()
        XCTAssertEqual(run(runner, rig, Make.target(unsent: true)).result, ActionResult(.already))

        let (rig2, _, runner2) = setup()
        rig2.source.editStateProvider = { EditStateProbe(rowid: $0, dateEditedNs: 5, dateRetractedNs: 0, body: "") }
        XCTAssertEqual(run(runner2, rig2, target()).result, ActionResult(.already))
        XCTAssertNoPress(rig2.log)
    }

    // MARK: - The 2-minute window (item 12)

    func testWindowBoundaryOnLeavingTheQueue() {
        let (rig, _, runner) = setup()
        XCTAssertEqual(run(runner, rig, target(age: 120)).result, ActionResult(.expired))
        XCTAssertFalse(rig.log.contains("target.select"))
        XCTAssertTrue(rig.app.calls.isEmpty)

        let (rig2, _, runner2) = setup()
        unsentAfter(rig2, 0)
        XCTAssertEqual(run(runner2, rig2, target(age: 119.999)).result.code, .ok)
    }

    func testWindowClosingBeforeThePressIsExpiredWithNoPress() {
        let (rig, targeting, runner) = setup()
        // Selection takes 2 s and the message was 119 s old when the request left the queue.
        let clock = rig.clock
        targeting.onSelect = { clock.advance(2) }
        let result = run(runner, rig, target(age: 119))
        XCTAssertEqual(result.result, ActionResult(.expired))
        XCTAssertFalse(result.pressed)
        XCTAssertFalse(rig.log.contains("journal.willInvoke"))
        XCTAssertFalse(rig.log.contains("ax.perform"))
    }

    func testWindowClosingDuringTheJournalFlushIsExpiredWithNoPress() {
        // 119 s old when the request left the queue, and the `invoking` write takes 2 s to reach the disk.
        let (rig, _, runner) = setup()
        let clock = rig.clock
        rig.recorder.onWillInvoke = { clock.advance(2) }
        let result = run(runner, rig, target(age: 119))
        XCTAssertEqual(result.result, ActionResult(.expired))
        XCTAssertFalse(result.pressed)
        XCTAssertTrue(rig.ax.performed.isEmpty, "Undo Send pressed after the window closed")
        XCTAssertEqual(rig.recorder.facts.count, 1, "the entry reached invoking")
        XCTAssertEqual(rig.recorder.didInvokeCount, 0, "nothing was pressed, so the entry never reaches invoked")
        XCTAssertFalse(result.result.holdsIdempotencyKey)
    }

    func testWindowIsCheckedAfterTheWindowRecheckRightBeforeThePress() {
        // 119.5 s old, and the window rules' state read after `willInvoke` takes 1 s.
        let (rig, _, runner) = setup()
        let clock = rig.clock
        var invoked = false
        var slowed = false
        rig.recorder.onWillInvoke = { invoked = true }
        rig.app.onState = { _ in
            guard invoked, !slowed else { return }
            slowed = true
            clock.advance(1)
        }
        let result = run(runner, rig, target(age: 119.5))
        XCTAssertTrue(slowed)
        XCTAssertEqual(result.result, ActionResult(.expired))
        XCTAssertTrue(rig.ax.performed.isEmpty)
        XCTAssertEqual(rig.recorder.didInvokeCount, 0)
    }

    func testMissingUndoSendIsUnsupportedWhileOpenAndExpiredOnceClosed() {
        let noUndo = Make.bubble(51, text: "on my way", minute: "12:29 AM", actions: ["Heart", "Edit"])
        let (rig, targeting, runner) = setup()
        targeting.lookup = .found(noUndo)
        XCTAssertEqual(run(runner, rig, target(age: 30)).result, ActionResult(.unsupported))
        XCTAssertNoPressAfterSelect(rig)

        let (rig2, targeting2, runner2) = setup()
        targeting2.lookup = .found(noUndo)
        let clock = rig2.clock
        targeting2.onSelect = { clock.advance(5) }
        XCTAssertEqual(run(runner2, rig2, target(age: 118)).result, ActionResult(.expired))
        XCTAssertNoPressAfterSelect(rig2)
    }

    func testUndoSendVanishingAtThePress() {
        let (rig, _, runner) = setup()
        rig.ax.performError = .actionMissing("Undo Send")
        let result = run(runner, rig, target())
        XCTAssertEqual(result.result, ActionResult(.unsupported), "Undo Send didn't run, so no mark-read note")
        XCTAssertFalse(result.pressed)
        XCTAssertEqual(rig.log.count(of: "db.editState"), 1, "only the already check before the press reads the row")
    }

    func testUndoSendVanishingAsTheWindowClosesIsExpired() {
        // 119.5 s old at the press: the action is gone, and the window has closed by the time the result is built.
        let (rig, _, runner) = setup()
        rig.ax.performError = .actionMissing("Undo Send")
        XCTAssertEqual(run(runner, rig, target(age: 119.5)).result, ActionResult(.expired))
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
            XCTAssertEqual(run(runner, rig, target()).result, expected, "\(error): nothing ran, so no mark-read note")
            XCTAssertEqual(rig.log.count(of: "db.editState"), 1, "\(error): nothing ran, so nothing to verify")
        }
    }

    func testVerifyDeadlineCountsFromThePress() {
        let (rig, _, runner) = setup()
        let clock = rig.clock
        var pressedAt: TimeInterval?
        rig.ax.onPerform = { _, _ in pressedAt = clock.uptime }
        XCTAssertEqual(run(runner, rig, target()).result, ActionResult(.mayHaveCompleted, notes: [.mayHaveMarkedRead]))
        XCTAssertEqual(clock.uptime - pressedAt!, Limits.uiVerifyTimeout, accuracy: 0.0001)
    }

    func testWindowShowingAtThePressAddsTheNote() {
        let (rig, _, runner) = setup()
        unsentAfter(rig, 2)
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
        XCTAssertEqual(run(runner, rig, target()).result,
                       ActionResult(.ok, notes: [.messagesBecameVisible, .mayHaveMarkedRead]))
    }

    func testZeroPollIntervalStillReachesTheDeadline() {
        let (rig, _, runner) = setup()
        runner.pollInterval = 0
        rig.windows.pollInterval = 0
        XCTAssertEqual(run(runner, rig, target()).result.code, .mayHaveCompleted)
        XCTAssertFalse(rig.clock.sleeps.contains { $0 <= 0 })
    }

    func testBusyWindowStopsBeforeSelection() {
        let (rig, _, runner) = setup()
        rig.app.current = Make.state(hidden: true, ax: 2)
        XCTAssertEqual(run(runner, rig, target()).result, ActionResult(.busy(.messagesOpen)))
        XCTAssertFalse(rig.log.contains("target.select"))
    }

    func testChatNotOpenIsAnEarlyRefusalWithNothingPressed() {
        let busy = ActionResult(.busy(.chatNotOpen), fix: "open Jordan in Messages, hide it (⌘H), then retry")
        let (rig, _, runner) = setup { _, targeting in targeting.selection = .refused(busy) }
        let start = rig.clock.uptime
        let result = run(runner, rig, target())
        XCTAssertEqual(result, UIActionResult(result: busy, currentReaction: nil, pressed: false))
        XCTAssertFalse(result.result.holdsIdempotencyKey)
        XCTAssertEqual(rig.clock.uptime, start, "no visibility poll")
        XCTAssertFalse(rig.log.contains("target.find"))
        XCTAssertFalse(rig.log.contains("journal.willInvoke"))
        XCTAssertTrue(rig.recorder.facts.isEmpty)
        XCTAssertNoPress(rig.log)
    }

    func testChatNotOpenWithTheRealTargeterPressesNothing() {
        let rig = Rig()
        rig.source.summaries = [Make.summary()]
        rig.ax.rows = [Make.row(2, "Jordan, see you, 12:20 AM")]
        rig.ax.bubbles = { [self.bubble] }
        let runner = UnsendRunner(ax: rig.ax, windows: rig.windows, targeting: rig.targeter(), source: rig.source,
                                  clock: rig.clock)
        let result = run(runner, rig, target())
        XCTAssertEqual(result.result,
                       ActionResult(.busy(.chatNotOpen), fix: "open +15550001111 in Messages, hide it (⌘H), then retry"))
        XCTAssertFalse(result.pressed)
        XCTAssertNoPress(rig.log)
        XCTAssertTrue(rig.recorder.facts.isEmpty)
    }

    // MARK: - Reconciliation

    func testVerifyOnlyReadsTheRowOnce() {
        let (rig, _, runner) = setup()
        rig.source.editStateProvider = { EditStateProbe(rowid: $0, dateEditedNs: 7, dateRetractedNs: 0, body: "") }
        XCTAssertEqual(runner.verifyOnly(rowid: 101), ActionResult(.ok))
        rig.source.editStateProvider = { EditStateProbe(rowid: $0, dateEditedNs: 0, dateRetractedNs: 0, body: "") }
        XCTAssertEqual(runner.verifyOnly(rowid: 101), ActionResult(.mayHaveCompleted))
        rig.source.editStateProvider = { _ in nil }
        XCTAssertEqual(runner.verifyOnly(rowid: 101), ActionResult(.mayHaveCompleted))
        rig.source.failing = [.editState]
        XCTAssertEqual(runner.verifyOnly(rowid: 101), ActionResult(.mayHaveCompleted))
        XCTAssertEqual(rig.log.count(of: "db.editState"), 4)
        XCTAssertFalse(rig.log.contains("ax."))
        XCTAssertTrue(rig.app.calls.isEmpty)
    }

    func XCTAssertNoPressAfterSelect(_ rig: Rig, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(rig.log.contains("ax.perform"), file: file, line: line)
        XCTAssertFalse(rig.log.contains("journal.willInvoke"), file: file, line: line)
    }
}

/// The Undo Send and edit windows, at their exact boundaries.
final class ActionWindowsTests: XCTestCase {
    func ns(ago seconds: Double) -> AppleNanos { Fixture.nowNs - AppleNanos(seconds * 1_000_000_000) }

    func testUndoSendWindow() {
        XCTAssertTrue(ActionWindows.undoSendOpen(rowDateNs: ns(ago: 0), now: Fixture.now))
        XCTAssertTrue(ActionWindows.undoSendOpen(rowDateNs: ns(ago: 119.999), now: Fixture.now))
        XCTAssertTrue(ActionWindows.undoSendOpen(rowDateNs: Fixture.nowNs - 119_999_999_999, now: Fixture.now))
        XCTAssertFalse(ActionWindows.undoSendOpen(rowDateNs: Fixture.nowNs - 120_000_000_000, now: Fixture.now))
        XCTAssertFalse(ActionWindows.undoSendOpen(rowDateNs: ns(ago: 3600), now: Fixture.now))
    }

    func testEditWindow() {
        XCTAssertTrue(ActionWindows.editOpen(rowDateNs: ns(ago: 899.999), now: Fixture.now))
        XCTAssertFalse(ActionWindows.editOpen(rowDateNs: Fixture.nowNs - 900_000_000_000, now: Fixture.now))
    }
}
