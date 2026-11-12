import Foundation
import XCTest
@testable import IMForeground
import IMCore
import IMTestSupport
import IMUI

/// `Harness.app` with its own `isFrontmost()`, so a test can tell the light frontmost read from `state()`, which also
/// reads the AX window count and the window list.
final class LightFrontmostApp: MessagesAppControl {
    let inner: FakeMessagesApp
    /// Runs inside each `isFrontmost()` call, before the read.
    var onFrontmostRead: (() -> Void)?
    /// Runs inside each `state()` call, before the read.
    var onStateRead: (() -> Void)?

    init(_ inner: FakeMessagesApp) { self.inner = inner }

    func state() -> MessagesAppState {
        onStateRead?()
        return inner.state()
    }
    func isFrontmost() -> Bool {
        onFrontmostRead?()
        return inner.state().isFrontmost
    }
    func launchHidden() -> Bool { inner.launchHidden() }
    func quit() -> Bool { inner.quit() }
    func waitForExit(timeout: TimeInterval) -> Bool { inner.waitForExit(timeout: timeout) }
    func activateForeground() -> Bool { inner.activateForeground() }
    func hide() { inner.hide() }
    func frontmostApp() -> FrontApp? { inner.frontmostApp() }
    func reopen(bundleID: String) -> Bool { inner.reopen(bundleID: bundleID) }
}

/// The ownership check, and release test 5's injection points as unit tests: before the field is set, during the
/// restore, between cleanup Escapes, before the hide and before the focus restore.
final class OwnershipTests: XCTestCase {
    // MARK: - OwnershipGuard

    private func makeGuard(frontmost: Bool = true) -> (OwnershipGuard, FakeClock, FakeInput, FakeMessagesApp) {
        let clock = FakeClock()
        let input = FakeInput(clock: clock, log: EventLog())
        let app = FakeMessagesApp(current: MessagesAppState(isRunning: true, pid: 1, isFrontmost: frontmost,
                                                            isHidden: !frontmost, axWindowCount: 1,
                                                            onScreenWindowCount: frontmost ? 1 : 0,
                                                            allSpacesWindowCount: 1))
        return (OwnershipGuard(input: input, app: app, clock: clock), clock, input, app)
    }

    func testGuardDoesNotOwnBeforeTheActivationCheck() {
        let (owner, _, _, _) = makeGuard()
        XCTAssertFalse(owner.owns())
        owner.markActivationCheck()
        XCTAssertFalse(owner.owns(), "the first failure sticks")
        XCTAssertTrue(owner.hasFailed)
    }

    func testInputBeforeTheCheckDoesNotCount() {
        let (owner, clock, input, _) = makeGuard()
        input.inputs = [clock.uptime - 0.5]
        owner.markActivationCheck()
        clock.advance(1)
        XCTAssertTrue(owner.owns())
    }

    func testInputAtOrAfterTheCheckCounts() {
        for delay in [0, 1.0 / 64.0, 2] as [TimeInterval] {
            let (owner, clock, input, _) = makeGuard()
            owner.markActivationCheck()
            clock.advance(delay)
            input.inject()
            clock.advance(0.5)
            XCTAssertFalse(owner.owns(), "\(delay)")
        }
    }

    func testNaNReadingCountsAsInput() {
        let (owner, _, input, _) = makeGuard()
        owner.markActivationCheck()
        input.reading = .nan
        XCTAssertFalse(owner.owns())
    }

    func testFrontmostIsRequiredOnlyBetweenTFrontAndTheHide() {
        let (owner, clock, _, app) = makeGuard(frontmost: false)
        owner.markActivationCheck()
        XCTAssertTrue(owner.owns(), "before t_front only input counts")
        XCTAssertNil(owner.tFront)
        clock.advance(0.25)
        app.current.isFrontmost = true
        owner.markFront()
        XCTAssertEqual(owner.tFront, 1000.25)
        XCTAssertTrue(owner.owns())
        owner.markHidden()
        app.current.isFrontmost = false
        XCTAssertTrue(owner.owns(), "after the hide only input counts")
    }

    func testLosingFrontmostFailsAndStaysFailed() {
        let (owner, _, _, app) = makeGuard()
        owner.markActivationCheck()
        owner.markFront()
        app.current.isFrontmost = false
        XCTAssertFalse(owner.owns())
        app.current.isFrontmost = true
        XCTAssertFalse(owner.owns())
        owner.markHidden()
        XCTAssertFalse(owner.owns())
    }

    func testInputDuringTheFrontmostReadIsCaught() {
        // The frontmost read can block, so input is sampled after it, as the last read before a key.
        let clock = FakeClock()
        let input = FakeInput(clock: clock, log: EventLog())
        let app = LightFrontmostApp(FakeMessagesApp(current: MessagesAppState(
            isRunning: true, pid: 1, isFrontmost: true, isHidden: false, axWindowCount: 1, onScreenWindowCount: 1,
            allSpacesWindowCount: 1)))
        let owner = OwnershipGuard(input: input, app: app, clock: clock)
        owner.markActivationCheck()
        clock.advance(0.5)
        owner.markFront()
        XCTAssertTrue(owner.owns())
        app.onFrontmostRead = {
            clock.advance(0.1)
            input.inject()
        }
        XCTAssertFalse(owner.owns())
    }

    func testInputDuringTheLastOwnershipAppReadPostsNoReturn() {
        // The app has no light read of its own, so the ownership check reads `state()`.
        let h = Harness()
        let baseRead = h.app.onState
        var injected = false
        h.app.onState = { [unowned h] state in
            baseRead?(&state)
            guard h.ax.focusReads >= 1, !injected else { return }
            injected = true
            h.clock.advance(0.1)
            h.input.inject()
        }
        let outcome = h.runEdit()
        XCTAssertTrue(injected)
        XCTAssertFalse(h.log.keys.contains(.returnKey), "Return after input during the last app read")
        XCTAssertEqual(outcome.result.code, .aborted(.userTookOver))
    }

    func testInputDuringTheLightFrontmostReadPostsNoReturn() {
        let h = Harness()
        let app = LightFrontmostApp(h.app)
        h.appControl = app
        var injected = false
        app.onFrontmostRead = { [unowned h] in
            guard h.ax.focusReads >= 1, !injected else { return }
            injected = true
            h.clock.advance(0.1)
            h.input.inject()
        }
        let outcome = h.runEdit()
        XCTAssertTrue(injected)
        XCTAssertFalse(h.log.keys.contains(.returnKey), "Return after input during the frontmost read")
        XCTAssertEqual(outcome.result.code, .aborted(.userTookOver))
    }

    func testFromOpenToTheHideOnlyTheLightFrontmostReadRuns() {
        // `state()` also reads the AX window count, which can block for 2 s. The activation poll, the late-activation
        // watch and the ownership check need only the frontmost bit.
        let runs: [(String, TimeInterval, ResultCode, (Harness) -> ForegroundOutcome)] = [
            ("edit", 0.25, .ok, { $0.runEdit() }),
            ("reply", 0.25, .submitted, { $0.runReply() }),
            ("late activation", 2, .aborted(.lateActivation), { $0.runEdit() }),
        ]
        for (label, delay, code, run) in runs {
            let h = Harness()
            h.activationDelay = delay
            let app = LightFrontmostApp(h.app)
            h.appControl = app
            var stateReads = 0
            var frontmostReads = 0
            app.onStateRead = { [unowned h] in
                if h.log.count(.activate) > 0, h.log.count(.hide) == 0 { stateReads += 1 }
            }
            app.onFrontmostRead = { frontmostReads += 1 }
            let outcome = run(h)
            XCTAssertEqual(outcome.result.code, code, label)
            XCTAssertEqual(h.log.count(.hide), 1, label)
            XCTAssertGreaterThan(frontmostReads, 0, label)
            XCTAssertEqual(stateReads, 0, "state() read between open and the hide; \(label)")
        }
    }

    // MARK: - Before the field is set

    func testInputBeforeTheEditFieldIsSetIsATakeoverWithNoWrite() {
        let h = Harness()
        h.injectInput(on: .perform(UINames.edit))
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result, ActionResult(.aborted(.userTookOver),
                                                    notes: [.axState("an edit field"), .mayHaveMarkedRead]))
        XCTAssertTrue(h.log.writes.isEmpty)
        assertNoActionAfterInput(h)
        XCTAssertEqual(outcome.lastPhase, .takeover)
        XCTAssertEqual(h.log.count(.verify), 0)
        XCTAssertNotNil(outcome.ticket)
    }

    func testInputBeforeTheReplyFieldIsSetIsATakeoverWithNoWrite() {
        let h = Harness()
        h.injectInput(on: .pressMenu)
        let outcome = h.runReply()
        XCTAssertEqual(outcome.result.code, .aborted(.userTookOver))
        XCTAssertEqual(outcome.result.notes.first, .axState("a thread view"))
        XCTAssertTrue(h.log.writes.isEmpty)
        assertNoActionAfterInput(h)
    }

    func testInputBeforeThePressIsATakeoverWithNoPress() {
        let h = Harness()
        h.injectInput(on: .willInvoke)
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result.code, .aborted(.userTookOver))
        XCTAssertEqual(h.log.count(.perform(UINames.edit)), 0)
        assertNoActionAfterInput(h)
    }

    func testInputRightBeforeReturnPostsNoReturn() {
        let h = Harness()
        // After step 4's own ownership check, before the one ahead of the key event.
        h.injectInput(on: .verifySelected)
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result.code, .aborted(.userTookOver))
        XCTAssertTrue(h.log.keys.isEmpty)
        XCTAssertEqual(h.log.writes, [Harness.newText, Harness.oldText], "the one reset write")
        assertNoActionAfterInput(h, allowingWrites: 1)
    }

    func testLosingFrontmostBeforeReturnIsATakeover() {
        let h = Harness()
        h.ax.writeDuration = 0.5
        h.loseFrontmostAt = 1000.5
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result.code, .aborted(.userTookOver))
        XCTAssertTrue(h.log.keys.isEmpty)
        XCTAssertEqual(h.log.count(.hide), 0)
        XCTAssertEqual(h.log.writes, [Harness.newText, Harness.oldText])
    }

    // MARK: - During the restore

    func testInputDuringTheRestoreLeavesOnlyTheTakeoverWrite() {
        let h = Harness()
        h.targeting.signatureMatches = false
        h.injectInput(on: .readValue) { [unowned h] in h.machine.phase == .bridgeOwnedCleanup }
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result, ActionResult(.aborted(.userTookOver),
                                                    notes: [.axState("an edit field"), .mayHaveMarkedRead]))
        XCTAssertEqual(h.log.writes, [Harness.newText, Harness.oldText])
        assertNoActionAfterInput(h, allowingWrites: 1)
        XCTAssertEqual(h.ax.values[ScriptedAX.editRef], Harness.oldText)
    }

    func testInputRightAfterTheRestoreWriteStopsBeforeAnyEscape() {
        let h = Harness()
        h.targeting.signatureMatches = false
        h.injectInput(on: .setValue(Harness.oldText))
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result.code, .aborted(.userTookOver))
        XCTAssertFalse(outcome.result.notes.contains(.agentTextMayRemain))
        XCTAssertEqual(h.log.writes, [Harness.newText, Harness.oldText])
        assertNoActionAfterInput(h)
    }

    func testUserTypingDuringTheRestoreIsLeftAlone() {
        let h = Harness()
        h.targeting.signatureMatches = false
        h.injectInput(on: .readValue) { [unowned h] in
            guard h.machine.phase == .bridgeOwnedCleanup else { return false }
            h.ax.values[ScriptedAX.editRef] = Harness.newText + " and more"
            return true
        }
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result.code, .aborted(.userTookOver))
        XCTAssertEqual(outcome.result.notes.first, .agentTextMayRemain)
        XCTAssertEqual(h.log.writes, [Harness.newText])
    }

    // MARK: - Between cleanup Escapes

    func testInputBetweenCleanupEscapesStopsEscaping() {
        let h = Harness()
        h.targeting.signatureMatches = false
        h.ax.escapesToClose = 2
        h.injectInput(on: .key(.escape))
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result, ActionResult(.aborted(.userTookOver),
                                                    notes: [.axState("an edit field"), .mayHaveMarkedRead]))
        XCTAssertEqual(h.log.keys, [.escape])
        assertNoActionAfterInput(h)
        XCTAssertTrue(h.mode.isForegroundModeOn)
    }

    func testInputBetweenFinishEscapesAfterReturnKeepsTheVerifyResult() {
        let h = Harness()
        h.ax.escapesToClose = 2
        h.injectInput(on: .key(.escape))
        let outcome = h.runReply()
        XCTAssertEqual(outcome.result, ActionResult(.submitted, notes: [.userTookOver, .mayHaveMarkedRead]))
        XCTAssertEqual(h.log.keys, [.returnKey, .escape])
        XCTAssertEqual(h.log.count(.hide), 0)
        XCTAssertEqual(h.log.count(.verify), 1)
        XCTAssertEqual(outcome.sentGUID, "reply-row-guid")
    }

    // MARK: - Before the hide

    func testInputBeforeTheHideAfterReturnSkipsTheHide() {
        let h = Harness()
        h.injectInput(on: .readTranscript)
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result, ActionResult(.ok, notes: [.userTookOver, .mayHaveMarkedRead]))
        XCTAssertEqual(h.log.count(.hide), 0)
        XCTAssertEqual(h.log.count(.verify), 1)
        assertNoActionAfterInput(h)
    }

    func testInputBeforeTheHideInBridgeOwnedCleanupIsATakeover() {
        let h = Harness()
        h.targeting.signatureMatches = false
        h.injectInput(on: .readTranscript)
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result, ActionResult(.aborted(.userTookOver),
                                                    notes: [.axState("no edit field or thread view"),
                                                            .mayHaveMarkedRead]))
        XCTAssertEqual(h.log.count(.hide), 0)
        assertNoActionAfterInput(h)
    }

    func testLosingFrontmostAfterReturnBeforeTheHideIsATakeover() {
        let h = Harness()
        h.log.onEvent = { [unowned h] event in
            if event == .key(.returnKey) { h.loseFrontmostAt = h.clock.uptime }
        }
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result, ActionResult(.ok, notes: [.userTookOver, .mayHaveMarkedRead]))
        XCTAssertEqual(h.log.count(.hide), 0)
    }

    // MARK: - Before the focus restore

    func testInputBeforeTheFocusRestoreSkipsTheReopen() {
        let h = Harness()
        h.frontAfterHide = Harness.finder
        h.injectInput(on: .hide)
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result, ActionResult(.ok, notes: [.userTookOver, .mayHaveMarkedRead]))
        XCTAssertFalse(h.app.calls.contains(.reopen("com.apple.Safari")))
        assertNoActionAfterInput(h)
    }

    func testInputBeforeTheFocusRestoreShowsEvenWhenNoReopenIsNeeded() {
        let h = Harness()
        h.injectInput(on: .hide)
        let outcome = h.runEdit()
        XCTAssertTrue(outcome.result.notes.contains(.userTookOver))
    }

    func testInputBetweenTheFrontAppReadAndTheReopenSkipsTheReopen() {
        let h = Harness()
        h.frontAfterHide = Harness.finder
        var injected = false
        h.onFrontRead = { [unowned h] in
            guard !injected, h.log.count(.hide) == 1 else { return }
            injected = true
            h.input.inject()
        }
        let outcome = h.runEdit()
        XCTAssertTrue(injected)
        XCTAssertTrue(outcome.result.notes.contains(.userTookOver))
        XCTAssertFalse(h.app.calls.contains(.reopen("com.apple.Safari")))
    }

    func testMessagesNotFrontmostAfterTheHideIsNotATakeover() {
        let h = Harness()
        // Messages leaves the front as soon as it is asked to hide, before `isHidden` turns true.
        h.log.onEvent = { [unowned h] event in
            if event == .hide { h.loseFrontmostAt = h.clock.uptime }
        }
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result, ActionResult(.ok, notes: [.mayHaveMarkedRead]))
    }
}
