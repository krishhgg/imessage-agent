import Foundation
import XCTest
@testable import IMForeground
import IMCore
import IMTestSupport
@testable import IMUI

/// `Harness.app` with `ActivationEnding`. `activateForeground` also starts a real `/bin/sleep 30` through IMUI's
/// `StartedProcess`, which `LiveMessagesApp` uses for `open -b`, so the sleep stands in for an `open` that hasn't
/// exited.
final class SlowOpenApp: MessagesAppControl, ActivationEnding {
    let inner: FakeMessagesApp
    let clock: FakeClock
    let log: EventLog
    private let activation = StartedProcess()
    private(set) var started: Process?
    /// The uptime of each `endActivation` call.
    private(set) var endedAt: [TimeInterval] = []

    init(_ h: Harness) {
        inner = h.app
        clock = h.clock
        log = h.log
    }

    deinit { if let started, started.isRunning { started.terminate() } }

    func state() -> MessagesAppState { inner.state() }
    func launchHidden() -> Bool { inner.launchHidden() }
    func quit() -> Bool { inner.quit() }
    func waitForExit(timeout: TimeInterval) -> Bool { inner.waitForExit(timeout: timeout) }
    func activateForeground() -> Bool {
        started = activation.start(URL(fileURLWithPath: "/bin/sleep"), ["30"])
        return started != nil && inner.activateForeground()
    }
    func hide() { inner.hide() }
    func frontmostApp() -> FrontApp? { inner.frontmostApp() }
    func reopen(bundleID: String) -> Bool { inner.reopen(bundleID: bundleID) }

    func endActivation() {
        endedAt.append(clock.uptime)
        log.add(.endActivation)
        activation.end()
    }
}

/// Step 3 from `open -b`: `t_front` within 1 s, else the 5 s late-activation watch.
final class ActivationTests: XCTestCase {
    func testOpenRunsOnlyAfterTheActivationCheck() {
        let h = Harness()
        h.runEdit()
        XCTAssertEqual(h.log.count(.activate), 1)
        XCTAssertEqual(h.app.calls.first, .activateForeground)
    }

    func testFrontmostAtExactlyOneSecondRecordsTFront() {
        let h = Harness()
        h.activationDelay = 1.0
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result.code, .ok)
        XCTAssertEqual(h.log.keys.first, .returnKey)
    }

    func testTFrontIsWhenMessagesCameForwardNotWhenOpenRan() {
        // Frontmost 0.75 s after `open -b`; the edit field shows exactly 3 s after that.
        let h = Harness()
        h.activationDelay = 0.75
        h.ax.openDelay = 3
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result.code, .ok)
        XCTAssertEqual(h.log.keys.first, .returnKey)
    }

    func testOpenThatBlocksPastOneSecondIsLateActivationAndPostsNothing() {
        // `open` holds the call for 4 s while Messages comes forward 0.25 s in. The first read after it can't
        // become `t_front`, so no Return goes out 4 s after activation.
        for reply in [false, true] {
            let h = Harness()
            let original = h.app.onCall
            h.app.onCall = { [unowned h] call, state in
                original?(call, &state)
                if call == .activateForeground { h.clock.advance(4) }
            }
            let outcome = reply ? h.runReply() : h.runEdit()
            XCTAssertEqual(outcome.result, ActionResult(.aborted(.lateActivation), notes: [.mayHaveMarkedRead]),
                           "reply \(reply)")
            XCTAssertTrue(h.log.keys.isEmpty, "reply \(reply)")
            XCTAssertTrue(h.log.writes.isEmpty, "reply \(reply)")
            XCTAssertTrue(h.recorder.facts.isEmpty, "reply \(reply)")
            XCTAssertEqual(h.log.count(.perform(UINames.edit)) + h.log.count(.pressMenu), 0, "reply \(reply)")
            XCTAssertEqual(h.log.count(.hide), 1, "reply \(reply)")
        }
    }

    func testAFrontmostReadThatEndsAfterOneSecondDoesNotCount() {
        // The read that starts 0.875 s after `open -b` takes 0.25 s and shows Messages frontmost (since 0.9 s).
        let h = Harness()
        h.activationDelay = 0.9
        var tOpen: TimeInterval?
        let onCall = h.app.onCall
        h.app.onCall = { [unowned h] call, state in
            if call == .activateForeground { tOpen = h.clock.uptime }
            onCall?(call, &state)
        }
        var slowed = false
        let onState = h.app.onState
        h.app.onState = { [unowned h] state in
            if let tOpen, !slowed, h.clock.uptime >= tOpen + 0.875 {
                slowed = true
                h.clock.advance(0.25)
            }
            onState?(&state)
        }
        let outcome = h.runEdit()
        XCTAssertTrue(slowed)
        XCTAssertEqual(outcome.result.code, .aborted(.lateActivation))
        XCTAssertTrue(h.log.keys.isEmpty)
        XCTAssertTrue(h.recorder.facts.isEmpty)
        XCTAssertEqual(h.log.count(.perform(UINames.edit)), 0)
    }

    func testTFrontIsWhenTheFrontmostReadStartedNotWhenItEnded() {
        // Messages is frontmost 0.25 s after `open -b`. The read that starts then sees it and takes 0.7 s more, the
        // case of any slow frontmost read. With the field showing 2.9 s after the press, 3.6 s after that read
        // started, Return would miss the 3 s. At 2.25 s it makes it.
        for (openDelay, inTime) in [(2.9, false), (2.25, true)] {
            for reply in [false, true] {
                let h = Harness()
                h.ax.openDelay = openDelay
                var slowed = false
                let onState = h.app.onState
                h.app.onState = { [unowned h] state in
                    onState?(&state)
                    if state.isFrontmost, !slowed {
                        slowed = true
                        h.clock.advance(0.7)
                    }
                }
                let outcome = reply ? h.runReply() : h.runEdit()
                let label = "open delay \(openDelay), reply \(reply)"
                XCTAssertTrue(slowed, label)
                XCTAssertEqual(outcome.result.code,
                               inTime ? (reply ? ResultCode.submitted : .ok) : .aborted(.deadline), label)
                XCTAssertEqual(h.log.keys.contains(.returnKey), inTime, label)
            }
        }
    }

    func testNotFrontmostWithinOneSecondPostsNothingAndHidesWhenItComesForward() {
        let h = Harness()
        h.activationDelay = 1.0 + 1.0 / 64.0
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result, ActionResult(.aborted(.lateActivation), notes: [.mayHaveMarkedRead]))
        XCTAssertTrue(h.log.keys.isEmpty)
        XCTAssertTrue(h.log.writes.isEmpty)
        XCTAssertTrue(h.recorder.facts.isEmpty, "willInvoke before t_front")
        XCTAssertEqual(h.log.count(.perform(UINames.edit)), 0)
        XCTAssertEqual(h.log.count(.hide), 1)
        XCTAssertEqual(h.log.count(.verify), 0)
        XCTAssertNotNil(outcome.ticket, "the queue stays held through the watch")
        XCTAssertEqual(outcome.lastPhase, .lateActivationWatch)
    }

    func testComingForwardAtTheEndOfTheFiveSecondWatchIsLateActivation() {
        let h = Harness()
        h.activationDelay = 6.0
        let outcome = h.runReply()
        XCTAssertEqual(outcome.result.code, .aborted(.lateActivation))
        XCTAssertEqual(h.log.count(.hide), 1)
        XCTAssertTrue(h.log.keys.isEmpty)
    }

    func testNeverComingForwardIsAbortedActivationWithoutAHide() {
        for delay in [nil, 6.0 + 1.0 / 64.0] as [TimeInterval?] {
            let h = Harness()
            h.activationDelay = delay
            let outcome = h.runEdit()
            XCTAssertEqual(outcome.result, ActionResult(.aborted(.activation), notes: [.mayHaveMarkedRead]))
            XCTAssertEqual(h.clock.uptime, 1006, "watch ends 1 s + 5 s after open")
            XCTAssertEqual(h.log.count(.hide), 0)
            XCTAssertTrue(h.log.keys.isEmpty)
            XCTAssertTrue(h.recorder.facts.isEmpty)
        }
    }

    func testAnOpenStillRunningWhenTheWatchEndsIsTerminatedBeforeAbortedActivation() throws {
        // `open` would otherwise run to its 10 s timeout and could bring Messages forward after the result, with the
        // queue released. Messages either never shows or shows behind the front app and gets hidden.
        for visibleBehind in [nil, 0.5] as [TimeInterval?] {
            let h = Harness()
            h.activationDelay = nil
            h.visibleBehindDelay = visibleBehind
            let app = SlowOpenApp(h)
            h.appControl = app
            let outcome = h.runEdit()
            let label = "visible behind \(String(describing: visibleBehind))"
            XCTAssertEqual(outcome.result, ActionResult(.aborted(.activation), notes: [.mayHaveMarkedRead]), label)
            XCTAssertEqual(app.endedAt, [1006], "ended once, when the watch ended 1 s + 5 s after open; \(label)")
            if visibleBehind != nil {
                let ended = try XCTUnwrap(h.log.index(of: .endActivation), label)
                let hidden = try XCTUnwrap(h.log.index(of: .hide), label)
                XCTAssertLessThan(ended, hidden, label)
            }
            let process = try XCTUnwrap(app.started, label)
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            XCTAssertFalse(process.isRunning, label)
            if !process.isRunning { XCTAssertEqual(process.terminationReason, .uncaughtSignal, label) }
        }
    }

    func testOpenIsEndedOnceMessagesIsFrontmostBeforeTheHide() throws {
        // On the success path `open` can still be running at `t_front`. Left running, it could bring Messages forward
        // again after the hide.
        let h = Harness()
        let app = SlowOpenApp(h)
        h.appControl = app
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result.code, .ok)
        XCTAssertEqual(app.endedAt, [1000.25], "ended once, at t_front 0.25 s after open")
        let ended = try XCTUnwrap(h.log.index(of: .endActivation))
        XCTAssertLessThan(try XCTUnwrap(h.log.index(of: .activate)), ended)
        XCTAssertLessThan(ended, try XCTUnwrap(h.log.index(of: .perform(UINames.edit))), "before the first press")
        XCTAssertLessThan(ended, try XCTUnwrap(h.log.index(of: .hide)))
        let process = try XCTUnwrap(app.started)
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertFalse(process.isRunning)
        if !process.isRunning { XCTAssertEqual(process.terminationReason, .uncaughtSignal) }
    }

    func testVisibleBehindTheFrontAppIsHiddenAndAbortedActivation() {
        let h = Harness()
        h.activationDelay = nil
        h.visibleBehindDelay = 0.5
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result.code, .aborted(.activation))
        XCTAssertEqual(h.log.count(.hide), 1)
        XCTAssertTrue(h.log.keys.isEmpty)
    }

    func testInputDuringTheWatchIsATakeoverWithNoHide() {
        let h = Harness()
        h.activationDelay = nil
        h.visibleBehindDelay = 0.5
        h.input.inputs.append(1003)
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result, ActionResult(.aborted(.userTookOver),
                                                    notes: [.axState("no edit field or thread view"),
                                                            .mayHaveMarkedRead]))
        XCTAssertEqual(h.clock.uptime, 1003)
        XCTAssertEqual(h.log.count(.hide), 0)
        XCTAssertEqual(h.app.calls.filter { if case .reopen = $0 { return true } else { return false } }.count, 0)
        XCTAssertTrue(h.log.keys.isEmpty)
        XCTAssertEqual(outcome.lastPhase, .takeover)
    }

    func testInputBeforeTheActivationCheckDoesNotCountAgainstOwnership() {
        let h = Harness()
        h.input.inputs = [998]
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result.code, .ok)
        XCTAssertFalse(outcome.result.notes.contains(.userTookOver))
    }
}
