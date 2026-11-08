import Foundation
import XCTest
import IMCore
@testable import IMSend
import IMTestSupport

final class ColdStartTests: XCTestCase {
    private let hiddenRunning = MessagesAppState(isRunning: true, pid: 4242, isFrontmost: false, isHidden: true,
                                                 axWindowCount: 1, onScreenWindowCount: 0,
                                                 allSpacesWindowCount: 1)

    /// Messages that starts hidden on `launchHidden`. `window` says when, in seconds after the launch, a window is on
    /// screen.
    private func launchingApp(clock: FakeClock, window: @escaping (TimeInterval) -> Bool = { _ in false })
        -> (FakeMessagesApp, () -> TimeInterval?) {
        let app = FakeMessagesApp()
        var launchedAt: TimeInterval?
        let hidden = hiddenRunning
        app.onCall = { call, state in
            if call == .launchHidden {
                launchedAt = clock.uptime
                state = hidden
            }
        }
        app.onState = { state in
            guard let at = launchedAt else { return }
            state.onScreenWindowCount = window(clock.uptime - at) ? 1 : 0
        }
        return (app, { launchedAt })
    }

    /// account_ready answers "1" from `readyAt` seconds after the runner was made, and records when it was asked.
    private func readiness(clock: FakeClock, readyAt: TimeInterval) -> (ScriptedRunner, () -> [TimeInterval]) {
        let start = clock.uptime
        var asked: [TimeInterval] = []
        let runner = ScriptedRunner { handler, _ in
            XCTAssertEqual(handler, .accountReady)
            asked.append(clock.uptime - start)
            return AppleScriptOutcome(ok: true, value: clock.uptime - start >= readyAt - 1e-9 ? "1" : "0")
        }
        return (runner, { asked })
    }

    // MARK: Launch

    func testRunningMessagesGetsNoLaunchAndNoAppleEvent() {
        let clock = FakeClock()
        let app = FakeMessagesApp(current: hiddenRunning)
        let runner = ScriptedRunner()
        let result = ColdStarter(app: app, scripts: runner, clock: clock).ensureReady(service: "iMessage")

        XCTAssertEqual(result, .ready(launched: false, becameVisible: false))
        XCTAssertTrue(app.calls.isEmpty)
        XCTAssertTrue(runner.calls.isEmpty)
        XCTAssertTrue(clock.sleeps.isEmpty)
    }

    func testNotRunningLaunchesHiddenThroughAppControlOnce() {
        let clock = FakeClock()
        let (app, _) = launchingApp(clock: clock)
        let (runner, _) = readiness(clock: clock, readyAt: 2)
        let result = ColdStarter(app: app, scripts: runner, clock: clock).ensureReady(service: "iMessage")

        XCTAssertEqual(result, .ready(launched: true, becameVisible: false))
        XCTAssertEqual(app.calls, [.launchHidden])
    }

    func testFailedLaunchIsNotReadyWithNoAppleEvent() {
        let clock = FakeClock()
        let app = UnlaunchableMessagesApp()
        let runner = ScriptedRunner()
        let result = ColdStarter(app: app, scripts: runner, clock: clock).ensureReady(service: "iMessage")

        XCTAssertEqual(result, .notReady)
        XCTAssertEqual(app.launches, 1)
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testNoAccountReadyEventWhileMessagesIsntRunning() {
        // `open` succeeded but Messages never shows up as running. An Apple Event would launch it unhidden.
        let clock = FakeClock()
        let start = clock.uptime
        let app = FakeMessagesApp()
        let runner = ScriptedRunner { _, _ in AppleScriptOutcome(ok: true, value: "1") }
        let result = ColdStarter(app: app, scripts: runner, clock: clock).ensureReady(service: "iMessage")

        XCTAssertEqual(result, .notReady)
        XCTAssertEqual(app.calls, [.launchHidden])
        XCTAssertTrue(runner.calls.isEmpty)
        XCTAssertEqual(clock.uptime - start, Limits.coldStartTimeout, accuracy: 1e-6)
    }

    func testReadinessPollWaitsUntilTheHiddenLaunchIsRunning() {
        let clock = FakeClock()
        let start = clock.uptime
        let app = FakeMessagesApp()
        let hidden = hiddenRunning
        app.onState = { state in if clock.uptime - start >= 3 { state = hidden } }
        let (runner, asked) = readiness(clock: clock, readyAt: 0)
        let result = ColdStarter(app: app, scripts: runner, clock: clock).ensureReady(service: "iMessage")

        XCTAssertEqual(result, .ready(launched: true, becameVisible: false))
        XCTAssertEqual(asked(), [3], "the first Apple Event goes to a running Messages")
    }

    func testMessagesThatExitsWhileWaitingGetsNoMoreAppleEvents() {
        let clock = FakeClock()
        let start = clock.uptime
        let (app, _) = launchingApp(clock: clock)
        let launched = app.onState
        app.onState = { state in
            launched?(&state)
            if clock.uptime - start >= 2 { state = .notRunning }
        }
        let (runner, asked) = readiness(clock: clock, readyAt: .infinity)
        let result = ColdStarter(app: app, scripts: runner, clock: clock).ensureReady(service: "iMessage")

        XCTAssertEqual(result, .notReady)
        XCTAssertFalse(asked().isEmpty)
        XCTAssertTrue(asked().allSatisfy { $0 < 2 }, "\(asked())")
    }

    func testAccountReadyAnsweringNotRunningIsNotReady() {
        // Messages quit between the running check and the call, so the handler's own check answered without an Apple
        // Event to Messages. That isn't ready, and the poll goes on until "1" or the timeout.
        let clock = FakeClock()
        let start = clock.uptime
        let (app, _) = launchingApp(clock: clock)
        let runner = ScriptedRunner { _, _ in
            AppleScriptOutcome(ok: true, value: clock.uptime - start >= 2 ? "1" : SendScripts.notRunning)
        }
        XCTAssertEqual(ColdStarter(app: app, scripts: runner, clock: clock).ensureReady(service: "iMessage"),
                       .ready(launched: true, becameVisible: false))
        XCTAssertEqual(clock.uptime - start, 2, accuracy: 1e-6)

        let never = ScriptedRunner { _, _ in AppleScriptOutcome(ok: true, value: SendScripts.notRunning) }
        let (stays, _) = launchingApp(clock: clock)
        XCTAssertEqual(ColdStarter(app: stays, scripts: never, clock: clock).ensureReady(service: "iMessage"), .notReady)
    }

    // MARK: Readiness wait

    func testWaitsForAccountReadyWithTheChatsService() {
        let clock = FakeClock()
        let start = clock.uptime
        let (app, _) = launchingApp(clock: clock)
        let (runner, asked) = readiness(clock: clock, readyAt: 3)
        let result = ColdStarter(app: app, scripts: runner, clock: clock).ensureReady(service: "SMS")

        XCTAssertEqual(result, .ready(launched: true, becameVisible: false))
        XCTAssertEqual(clock.uptime - start, 3, accuracy: 1e-6)
        XCTAssertTrue(runner.calls.allSatisfy { $0.0 == .accountReady && $0.1 == ["SMS"] })
        XCTAssertEqual(asked().last ?? -1, 3, accuracy: 1e-6)
    }

    func testReadyAtExactlySixtySecondsCounts() {
        let clock = FakeClock()
        let start = clock.uptime
        let (app, _) = launchingApp(clock: clock)
        let (runner, _) = readiness(clock: clock, readyAt: Limits.coldStartTimeout)
        let result = ColdStarter(app: app, scripts: runner, clock: clock).ensureReady(service: "iMessage")

        XCTAssertEqual(result, .ready(launched: true, becameVisible: false))
        XCTAssertEqual(clock.uptime - start, 60, accuracy: 1e-6)
    }

    func testNotReadyAfterSixtySeconds() {
        let clock = FakeClock()
        let start = clock.uptime
        let (app, _) = launchingApp(clock: clock)
        let (runner, asked) = readiness(clock: clock, readyAt: Limits.coldStartTimeout + 0.01)
        let result = ColdStarter(app: app, scripts: runner, clock: clock).ensureReady(service: "iMessage")

        XCTAssertEqual(result, .notReady)
        XCTAssertEqual(clock.uptime - start, 60, accuracy: 1e-6, "gives up at 60 s, not later")
        XCTAssertEqual(asked().last ?? -1, 60, accuracy: 1e-6, "the last check runs at the deadline")
    }

    func testOnlyAOneFromTheHandlerMeansReady() {
        let clock = FakeClock()
        let (app, _) = launchingApp(clock: clock)
        var answers = [AppleScriptOutcome(ok: true, value: "0"),
                       AppleScriptOutcome(ok: false, value: "1", errorNumber: -600),
                       AppleScriptOutcome(ok: true, value: "true"),
                       AppleScriptOutcome(ok: false, errorNumber: -1728),
                       AppleScriptOutcome(ok: true, value: "1")]
        let runner = ScriptedRunner { _, _ in answers.removeFirst() }
        let result = ColdStarter(app: app, scripts: runner, clock: clock).ensureReady(service: "iMessage")

        XCTAssertEqual(result, .ready(launched: true, becameVisible: false))
        XCTAssertEqual(runner.calls.count, 5)
    }

    func testNoAppleEventDuringTheVisibilitySecond() {
        let clock = FakeClock()
        let (app, launchedAt) = launchingApp(clock: clock)
        let start = clock.uptime
        let (runner, asked) = readiness(clock: clock, readyAt: 0)
        let result = ColdStarter(app: app, scripts: runner, clock: clock).ensureReady(service: "iMessage")

        XCTAssertEqual(result, .ready(launched: true, becameVisible: false))
        let launch = (launchedAt() ?? .nan) - start
        XCTAssertEqual(asked().first ?? -1, launch + Limits.visibilityPoll, accuracy: 1e-6)
    }

    // MARK: Visibility poll

    func testWindowDuringTheFirstSecondIsReported() {
        let clock = FakeClock()
        let (app, _) = launchingApp(clock: clock, window: { $0 >= 0.9 && $0 < 0.95 })
        let (runner, _) = readiness(clock: clock, readyAt: 0)
        let result = ColdStarter(app: app, scripts: runner, clock: clock).ensureReady(service: "iMessage")
        XCTAssertEqual(result, .ready(launched: true, becameVisible: true))
    }

    func testPollLastsAFullSecondEvenWhenTheAccountIsReadyAtOnce() {
        let clock = FakeClock()
        let start = clock.uptime
        let (app, _) = launchingApp(clock: clock, window: { $0 >= 0.98 })
        let (runner, _) = readiness(clock: clock, readyAt: 0)
        let result = ColdStarter(app: app, scripts: runner, clock: clock).ensureReady(service: "iMessage")

        XCTAssertEqual(result, .ready(launched: true, becameVisible: true))
        XCTAssertGreaterThanOrEqual(clock.uptime - start, Limits.visibilityPoll - 1e-9)
    }

    func testWindowWhileWaitingForTheAccountIsReported() {
        let clock = FakeClock()
        let (app, _) = launchingApp(clock: clock, window: { $0 >= 2 && $0 < 2.3 })
        let (runner, _) = readiness(clock: clock, readyAt: 4)
        let result = ColdStarter(app: app, scripts: runner, clock: clock).ensureReady(service: "iMessage")
        XCTAssertEqual(result, .ready(launched: true, becameVisible: true))
    }

    func testWindowOnALaunchThatTimesOutIsStillReported() {
        let clock = FakeClock()
        let (app, _) = launchingApp(clock: clock, window: { $0 < 0.1 })
        let (runner, _) = readiness(clock: clock, readyAt: .infinity)
        let starter = ColdStarter(app: app, scripts: runner, clock: clock)

        XCTAssertEqual(starter.start(service: "iMessage"), ColdStarter.Report(ready: false, launched: true,
                                                                              becameVisible: true))
    }

    func testHiddenLaunchWithItsOneAXWindowIsNotVisible() {
        let clock = FakeClock()
        let (app, _) = launchingApp(clock: clock)
        let (runner, _) = readiness(clock: clock, readyAt: 1.5)
        let result = ColdStarter(app: app, scripts: runner, clock: clock).ensureReady(service: "iMessage")
        XCTAssertEqual(result, .ready(launched: true, becameVisible: false))
    }

    func testWindowStateRules() {
        var state = hiddenRunning
        XCTAssertFalse(ColdStarter.windowShowed(state), "hidden, AX window only")
        state.onScreenWindowCount = 1
        XCTAssertTrue(ColdStarter.windowShowed(state), "any on-screen window, at any layer and size")
        state = hiddenRunning
        state.isHidden = false
        XCTAssertTrue(ColdStarter.windowShowed(state), "unhidden with an AX window, even off screen")
        state.axWindowCount = 0
        XCTAssertFalse(ColdStarter.windowShowed(state), "an unhidden window on another Space isn't on screen")
        state.allSpacesWindowCount = 0
        XCTAssertFalse(ColdStarter.windowShowed(state), "unhidden with no window shows nothing")
        state.isFrontmost = true
        XCTAssertTrue(ColdStarter.windowShowed(state), "frontmost")
        state = hiddenRunning
        state.axWindowCount = -1
        XCTAssertFalse(ColdStarter.windowShowed(state), "hidden, no AX grant and nothing on screen")
        state.axWindowCount = 0
        state.allSpacesWindowCount = 1
        XCTAssertFalse(ColdStarter.windowShowed(state), "a hidden window on another Space shows nothing")
        XCTAssertFalse(ColdStarter.windowShowed(.notRunning))
    }

    func testOnlyWhatTheUserCanSeeCountsAsShown() {
        // As `WindowRules.showsWindow`. A send-only install has no Accessibility grant, so AX counts -1 on every
        // sample, and `isHidden` can lag the hidden launch. A window on another Space isn't on screen.
        var state = hiddenRunning
        state.isHidden = false
        state.axWindowCount = -1
        state.onScreenWindowCount = 0
        state.allSpacesWindowCount = 1
        XCTAssertFalse(ColdStarter.windowShowed(state), "no AX grant, nothing on screen, a window on another Space")
        state.allSpacesWindowCount = -1
        XCTAssertFalse(ColdStarter.windowShowed(state), "no AX grant and no full window list")
        state.onScreenWindowCount = -1
        XCTAssertTrue(ColdStarter.windowShowed(state), "no on-screen list")
        state.isHidden = true
        XCTAssertTrue(ColdStarter.windowShowed(state), "no on-screen list, even while hidden")
        state.isHidden = false
        state.onScreenWindowCount = 0
        state.axWindowCount = 1
        XCTAssertTrue(ColdStarter.windowShowed(state), "not hidden with an AX window")
    }

    func testSendOnlyLaunchWhileIsHiddenLagsIsNotVisible() {
        // No Accessibility grant, and `isHidden` turns true 0.3 s after `open -g -j`, with no window on screen.
        let clock = FakeClock()
        let (app, launchedAt) = launchingApp(clock: clock)
        app.onState = { state in
            guard let at = launchedAt() else { return }
            state.axWindowCount = -1
            state.isHidden = clock.uptime - at >= 0.3
        }
        let (runner, _) = readiness(clock: clock, readyAt: 1.5)
        let result = ColdStarter(app: app, scripts: runner, clock: clock).ensureReady(service: "iMessage")
        XCTAssertEqual(result, .ready(launched: true, becameVisible: false))
    }

    func testLaunchWithNoOnScreenListIsReportedVisible() {
        let clock = FakeClock()
        let (app, _) = launchingApp(clock: clock)
        app.onState = { state in if state.isRunning { state.onScreenWindowCount = -1 } }
        let (runner, _) = readiness(clock: clock, readyAt: 1.5)
        let result = ColdStarter(app: app, scripts: runner, clock: clock).ensureReady(service: "iMessage")
        XCTAssertEqual(result, .ready(launched: true, becameVisible: true))
    }
}
