import XCTest
import IMCore
@testable import IMUI
import IMTestSupport

/// Checklist items 1 to 4: window rules, the launch and relaunch paths, and the visibility poll.
final class WindowRulesTests: XCTestCase {
    // MARK: - Decision table (item 1)

    func testHiddenWithOneWindowProceeds() {
        XCTAssertEqual(WindowRules.decide(Make.state()), .proceed)
    }

    func testNotRunningLaunchesHidden() {
        XCTAssertEqual(WindowRules.decide(.notRunning), .launchHidden)
    }

    func testFrontmostIsBusyWithOrWithoutWindow() {
        XCTAssertEqual(WindowRules.decide(Make.state(frontmost: true, hidden: false, ax: 1)), .busyMessagesOpen)
        XCTAssertEqual(WindowRules.decide(Make.state(frontmost: true, hidden: false, ax: 0)), .busyMessagesOpen)
    }

    func testVisibleWindowIsBusyEvenMinimizedOrOnAnotherSpace() {
        // Minimized or on another Space: AX still counts the window, the window server shows none on screen.
        XCTAssertEqual(WindowRules.decide(Make.state(hidden: false, ax: 1, onScreen: 0)), .busyMessagesOpen)
        XCTAssertEqual(WindowRules.decide(Make.state(hidden: false, ax: 1, onScreen: 1)), .busyMessagesOpen)
    }

    func testAWindowOnAnotherSpaceOrFullScreenIsBusyWithTheHideFix() {
        // AX lists only the current Space's windows and the on-screen list skips other Spaces, so a window on
        // Desktop 2, or Messages full screen in its own Space, shows only in the count on every Space.
        let elsewhere = Make.state(hidden: false, ax: 0, onScreen: 0, anySpace: 1)
        XCTAssertEqual(WindowRules.decide(elsewhere), .busyMessagesOpen)
        XCTAssertEqual(WindowRules.busyResult(for: elsewhere), .messagesOpen, "comes with the hide fix")
        XCTAssertFalse(WindowRules.allowsHiddenAction(elsewhere))
        XCTAssertEqual(WindowRules.decide(Make.state(hidden: false, ax: 0, onScreen: 0, anySpace: 2)), .busyMessagesOpen)
    }

    func testAnUnknownCountOnEverySpaceIsBusyWithTheHideFix() {
        let unknown = Make.state(hidden: false, ax: 0, onScreen: 0, anySpace: -1)
        XCTAssertEqual(WindowRules.decide(unknown), .busyMessagesOpen)
        XCTAssertEqual(WindowRules.busyResult(for: unknown), .messagesOpen)
    }

    func testHiddenWithAWindowOnlyOnAnotherSpaceQuitsAndRelaunches() {
        // A hidden window on another Space isn't in use, so the no-window path stands.
        XCTAssertEqual(WindowRules.decide(Make.state(hidden: true, ax: 0, onScreen: 0, anySpace: 1)), .quitAndRelaunch)
    }

    func testMenuBarStripsOnlyStillQuitAndRelaunch() {
        // The four 1512 x 33 strips fall under the size floor, so the count is 0 and nothing changes.
        XCTAssertEqual(WindowRules.decide(Make.state(hidden: false, ax: 0, onScreen: 0, anySpace: 0)), .quitAndRelaunch)
    }

    func testAWindowOnAnotherSpaceIsNeverQuit() {
        let rig = Rig(state: Make.state(hidden: false, ax: 0, onScreen: 0, anySpace: 1))
        rig.app.onCall = { call, state in
            if call == .quit { state = .notRunning }
            if call == .launchHidden { state = Make.readyState }
        }
        let prep = rig.windows.prepare(queueDeadline: rig.clock.uptime + 30)
        XCTAssertEqual(prep.early, .messagesOpen)
        XCTAssertTrue(rig.app.calls.isEmpty, "quit or launched: \(rig.app.calls)")
    }

    func testHiddenWithTwoWindowsIsBusy() {
        XCTAssertEqual(WindowRules.decide(Make.state(hidden: true, ax: 2)), .busyMessagesOpen)
    }

    func testHiddenWithASecondWindowOnAnotherSpaceIsBusy() {
        // AX lists the window on this Space, and the full window list shows a second one elsewhere.
        let state = Make.state(hidden: true, ax: 1, anySpace: 2)
        XCTAssertEqual(WindowRules.decide(state), .busyMessagesOpen)
        XCTAssertFalse(WindowRules.allowsHiddenAction(state))
        XCTAssertEqual(WindowRules.busyResult(for: state), ActionResult(.busy(.messagesOpen)), "hiding doesn't help")
        // An unknown count on every Space doesn't raise AX's one window.
        XCTAssertEqual(WindowRules.decide(Make.state(hidden: true, ax: 1, anySpace: -1)), .proceed)
        XCTAssertEqual(WindowRules.decide(Make.state(hidden: true, ax: 1, anySpace: 0)), .proceed)
        XCTAssertEqual(WindowRules.decide(Make.state(hidden: true, ax: 2, anySpace: -1)), .busyMessagesOpen)
    }

    func testNoWindowNotFrontmostQuitsAndRelaunches() {
        XCTAssertEqual(WindowRules.decide(Make.state(hidden: false, ax: 0)), .quitAndRelaunch)
        XCTAssertEqual(WindowRules.decide(Make.state(hidden: true, ax: 0)), .quitAndRelaunch)
    }

    func testUnknownCountsFailClosed() {
        XCTAssertEqual(WindowRules.decide(Make.state(hidden: true, ax: -1)), .busyMessagesOpen)
        XCTAssertEqual(WindowRules.decide(Make.state(hidden: true, ax: 1, onScreen: -1)), .busyMessagesOpen)
        XCTAssertEqual(WindowRules.decide(Make.state(hidden: true, ax: 0, onScreen: -1)), .busyMessagesOpen)
    }

    func testOnScreenWindowWhileHiddenIsBusy() {
        XCTAssertEqual(WindowRules.decide(Make.state(hidden: true, ax: 1, onScreen: 1)), .busyMessagesOpen)
        XCTAssertEqual(WindowRules.decide(Make.state(hidden: true, ax: 0, onScreen: 1)), .busyMessagesOpen)
    }

    func testBusyCarriesHideFixOnlyWhenAWindowIsShowing() {
        let showing = WindowRules.busyResult(for: Make.state(hidden: false, ax: 1))
        XCTAssertEqual(showing, .messagesOpen)
        XCTAssertEqual(showing.rendered, "busy: Messages is open fix: hide Messages (⌘H) and retry")

        let twoHidden = WindowRules.busyResult(for: Make.state(hidden: true, ax: 2))
        XCTAssertEqual(twoHidden, ActionResult(.busy(.messagesOpen)))
        XCTAssertNil(twoHidden.fix)

        let frontNoWindow = WindowRules.busyResult(for: Make.state(frontmost: true, hidden: false, ax: 0))
        XCTAssertNil(frontNoWindow.fix)
    }

    // MARK: - Manager paths

    func testReadyStateDoesNothing() {
        let rig = Rig()
        let prep = rig.windows.prepare(queueDeadline: rig.clock.uptime + 30)
        XCTAssertEqual(prep, WindowPreparation(early: nil, notes: []))
        XCTAssertTrue(rig.app.calls.isEmpty)
        XCTAssertNil(rig.windows.ensureHiddenWindow(queueDeadline: rig.clock.uptime + 30))
    }

    func testBusyStateNeverLaunchesQuitsOrHides() {
        for state in [Make.state(hidden: false, ax: 1), Make.state(frontmost: true, hidden: false, ax: 1),
                      Make.state(hidden: true, ax: 2), Make.state(hidden: true, ax: 1, onScreen: 1)] {
            let rig = Rig(state: state)
            let prep = rig.windows.prepare(queueDeadline: rig.clock.uptime + 30)
            XCTAssertEqual(prep.early?.code, .busy(.messagesOpen), "\(state)")
            XCTAssertTrue(rig.app.calls.isEmpty, "\(state): \(rig.app.calls)")
        }
    }

    func testUnknownAXCountIsFilledFromTheDriver() {
        let rig = Rig(state: Make.state(hidden: true, ax: -1))
        rig.ax.windows = 1
        XCTAssertNil(rig.windows.ensureHiddenWindow(queueDeadline: rig.clock.uptime + 30))

        let failing = Rig(state: Make.state(hidden: true, ax: -1))
        failing.ax.windowCountError = .axError(-25204)
        XCTAssertEqual(failing.windows.ensureHiddenWindow(queueDeadline: failing.clock.uptime + 30)?.code,
                       .busy(.messagesOpen))
        XCTAssertTrue(failing.app.calls.isEmpty)
    }

    func testNoAccessibilityGrantIsAccessibilityMissingAndLaunchesNothing() {
        let states: [(String, MessagesAppState)] = [("hidden", Make.state(hidden: true, ax: -1)),
                                                    ("quit", .notRunning), ("no window", Make.state(hidden: true, ax: 0))]
        for (name, state) in states {
            let rig = Rig(state: state)
            rig.ax.windowCountError = .notTrusted
            let start = rig.clock.uptime
            let prep = rig.windows.prepare(queueDeadline: start + 30)
            XCTAssertEqual(prep, WindowPreparation(early: UIResults.accessibilityMissing, notes: []), name)
            XCTAssertTrue(rig.app.calls.isEmpty, "\(name): no launch, quit or hide: \(rig.app.calls)")
            XCTAssertEqual(rig.clock.uptime - start, 0, accuracy: 0.001, "\(name): no wait")
        }
    }

    func testColdLaunchUsesLaunchHiddenAndWaitsForOneHiddenWindow() {
        let rig = Rig(state: .notRunning)
        rig.windows.pollInterval = 0.25
        var launchedAt: TimeInterval?
        let clock = rig.clock
        rig.app.onCall = { call, _ in if call == .launchHidden { launchedAt = clock.uptime } }
        rig.app.onState = { state in
            guard let launchedAt, clock.uptime >= launchedAt + 3 else { return }
            state = Make.readyState
        }
        let start = clock.uptime
        let prep = rig.windows.prepare(queueDeadline: start + 30)
        XCTAssertEqual(prep, WindowPreparation(early: nil, notes: []))
        XCTAssertEqual(rig.app.calls, [.launchHidden])
        // Ready at 3 s, then the 1 s visibility poll.
        XCTAssertEqual(clock.uptime - start, 4, accuracy: 0.001)
    }

    func testColdLaunchThatShowsAWindowAddsTheNote() {
        let rig = Rig(state: .notRunning)
        let clock = rig.clock
        let start = clock.uptime
        rig.app.onState = { state in
            guard rig.app.calls.contains(.launchHidden) else { return }
            let t = clock.uptime - start
            state = t < 1 ? Make.state(hidden: false, ax: 1, onScreen: 1) : Make.readyState
        }
        let prep = rig.windows.prepare(queueDeadline: start + 30)
        XCTAssertNil(prep.early)
        XCTAssertEqual(prep.notes, [.messagesBecameVisible])
    }

    func testVisibilityPollAfterLaunchCatchesALateWindow() {
        let rig = Rig(state: .notRunning)
        rig.windows.pollInterval = 0.25
        let clock = rig.clock
        let start = clock.uptime
        rig.app.onState = { state in
            guard rig.app.calls.contains(.launchHidden) else { return }
            // Ready at once, then a window shows 0.5 s into the 1 s poll and stays.
            state = clock.uptime - start >= 0.5 ? Make.state(hidden: false, ax: 1, onScreen: 1) : Make.readyState
        }
        let prep = rig.windows.prepare(queueDeadline: start + 30)
        XCTAssertEqual(prep.early, ActionResult(.noHiddenWindow, notes: [.messagesBecameVisible]))
        XCTAssertEqual(clock.uptime - start, 0.5, accuracy: 0.0001, "the poll stops at the first visible sample")
    }

    func testLaunchWaitBoundaryAtTenSeconds() {
        func run(readyAfter delay: TimeInterval) -> WindowPreparation {
            let rig = Rig(state: .notRunning)
            rig.windows.pollInterval = 0.25
            let clock = rig.clock
            let start = clock.uptime
            rig.app.onCall = { call, state in if call == .launchHidden { state = Make.state(hidden: true, ax: 0) } }
            rig.app.onState = { state in
                if rig.app.calls.contains(.launchHidden), clock.uptime - start >= delay { state = Make.readyState }
            }
            return rig.windows.prepare(queueDeadline: start + 30)
        }
        XCTAssertNil(run(readyAfter: 9.75).early)
        XCTAssertNil(run(readyAfter: 10.0).early)
        XCTAssertEqual(run(readyAfter: 10.01).early?.code, .noHiddenWindow)
        XCTAssertEqual(run(readyAfter: 10.25).early?.code, .noHiddenWindow)
    }

    func testLaunchThatEndsWithTwoWindowsIsNoHiddenWindow() {
        let rig = Rig(state: .notRunning)
        rig.app.onCall = { call, state in if call == .launchHidden { state = Make.state(hidden: true, ax: 2) } }
        XCTAssertEqual(rig.windows.prepare(queueDeadline: rig.clock.uptime + 30).early?.code, .noHiddenWindow)
    }

    func testFailedLaunchIsNoHiddenWindow() {
        let app = LaunchFailingApp()
        let log = EventLog()
        let manager = HiddenWindowManager(app: app, ax: ScriptedAX(log: log), transfers: FakePendingTransfers(),
                                          clock: FakeClock())
        XCTAssertEqual(manager.ensureHiddenWindow(queueDeadline: 2000), ActionResult(.noHiddenWindow))
        XCTAssertEqual(app.launches, 1)
    }

    func testFailedLaunchThatStillShowsAWindowCarriesTheNote() {
        // `open` reports failure, yet Messages came up with a window: the 1 s poll still runs.
        let app = LaunchFailingApp()
        let clock = FakeClock()
        app.inner.onState = { state in
            state = app.launches == 0 ? .notRunning : Make.state(hidden: false, ax: 1, onScreen: 1)
        }
        let manager = HiddenWindowManager(app: app, ax: ScriptedAX(log: EventLog()), transfers: FakePendingTransfers(),
                                          clock: clock)
        let prep = manager.prepare(queueDeadline: clock.uptime + 30)
        XCTAssertEqual(prep.early, ActionResult(.noHiddenWindow, notes: [.messagesBecameVisible]))
        XCTAssertEqual(app.launches, 1)
    }

    func testZeroPollIntervalStillEndsTheLaunchWaitAndThePoll() {
        let rig = Rig(state: .notRunning)
        rig.windows.pollInterval = 0
        let start = rig.clock.uptime
        XCTAssertEqual(rig.windows.prepare(queueDeadline: start + 30).early?.code, .noHiddenWindow)
        XCTAssertEqual(rig.clock.uptime - start, Limits.relaunchWindowWait + Limits.visibilityPoll, accuracy: 0.0001)
        XCTAssertFalse(rig.clock.sleeps.contains { $0 <= 0 })

        let ready = Rig()
        ready.windows.pollInterval = 0
        let from = ready.clock.uptime
        XCTAssertFalse(ready.windows.visibilityCheck().becameVisible)
        XCTAssertEqual(ready.clock.uptime - from, Limits.visibilityPoll, accuracy: 0.0001)
    }

    func testNoHiddenWindowAfterAVisibleLaunchCarriesTheNoteOnce() {
        let rig = Rig(state: .notRunning)
        rig.app.onCall = { call, state in
            if call == .launchHidden { state = Make.state(hidden: false, ax: 1, onScreen: 1) }
        }
        let prep = rig.windows.prepare(queueDeadline: rig.clock.uptime + 30)
        XCTAssertEqual(prep.early, ActionResult(.noHiddenWindow, notes: [.messagesBecameVisible]))
        XCTAssertEqual(prep.notes, [])
    }

    // MARK: - Quit and relaunch (item 2)

    func testNoWindowQuitsWaitsAndRelaunches() {
        let rig = Rig(state: Make.state(hidden: false, ax: 0))
        rig.app.onCall = { call, state in
            switch call {
            case .quit: state = .notRunning
            case .launchHidden: state = Make.readyState
            default: break
            }
        }
        let prep = rig.windows.prepare(queueDeadline: rig.clock.uptime + 30)
        XCTAssertEqual(prep, WindowPreparation(early: nil, notes: []))
        XCTAssertEqual(rig.app.calls, [.quit, .waitForExit, .launchHidden])
    }

    func testMessagesThatDoesNotExitIsNoHiddenWindowAndNotRelaunched() {
        let rig = Rig(state: Make.state(hidden: false, ax: 0))
        let prep = rig.windows.prepare(queueDeadline: rig.clock.uptime + 30)
        XCTAssertEqual(prep.early, ActionResult(.noHiddenWindow))
        XCTAssertEqual(rig.app.calls, [.quit, .waitForExit])
    }

    func testRelaunchWithoutOneHiddenWindowIsNoHiddenWindow() {
        let rig = Rig(state: Make.state(hidden: false, ax: 0))
        rig.app.onCall = { call, state in
            switch call {
            case .quit: state = .notRunning
            case .launchHidden: state = Make.state(hidden: true, ax: 0)
            default: break
            }
        }
        let start = rig.clock.uptime
        let prep = rig.windows.prepare(queueDeadline: start + 30)
        XCTAssertEqual(prep.early?.code, .noHiddenWindow)
        // 10 s launch wait, then the 1 s visibility poll.
        XCTAssertEqual(rig.clock.uptime - start, 11, accuracy: 0.001)
    }

    func testRelaunchWaitsForPendingTransfersInsideTheQueueBudget() {
        let rig = Rig(state: Make.state(hidden: false, ax: 0))
        let transfers = TimedTransfers(clock: rig.clock, clearAt: rig.clock.uptime + 2)
        let manager = HiddenWindowManager(app: rig.app, ax: rig.ax, transfers: transfers, clock: rig.clock)
        var quitAt: TimeInterval?
        let clock = rig.clock
        rig.app.onCall = { call, state in
            switch call {
            case .quit:
                quitAt = clock.uptime
                state = .notRunning
            case .launchHidden: state = Make.readyState
            default: break
            }
        }
        let start = clock.uptime
        XCTAssertNil(manager.ensureHiddenWindow(queueDeadline: start + 30))
        XCTAssertNotNil(quitAt)
        XCTAssertGreaterThanOrEqual(quitAt! - start, 2)
    }

    func testPendingTransfersPastTheQueueDeadlineAreBusyQueueWithNoQuit() {
        func run(clearAfter: TimeInterval) -> (ActionResult?, [FakeMessagesApp.Call]) {
            let rig = Rig(state: Make.state(hidden: false, ax: 0))
            let transfers = TimedTransfers(clock: rig.clock, clearAt: rig.clock.uptime + clearAfter)
            let manager = HiddenWindowManager(app: rig.app, ax: rig.ax, transfers: transfers, clock: rig.clock)
            manager.pollInterval = 0.25
            rig.app.onCall = { call, state in
                if call == .quit { state = .notRunning }
                if call == .launchHidden { state = Make.readyState }
            }
            let result = manager.ensureHiddenWindow(queueDeadline: rig.clock.uptime + 5)
            return (result, rig.app.calls)
        }
        let late = run(clearAfter: 5.25)
        XCTAssertEqual(late.0, ActionResult(.busy(.queue)))
        XCTAssertTrue(late.1.isEmpty)

        let atDeadline = run(clearAfter: 5)
        XCTAssertNil(atDeadline.0)
        XCTAssertEqual(atDeadline.1, [.quit, .waitForExit, .launchHidden])
    }

    func testStateIsReadAgainAfterTheTransferWait() {
        let rig = Rig(state: Make.state(hidden: false, ax: 0))
        let clock = rig.clock
        let transfers = TimedTransfers(clock: clock, clearAt: clock.uptime + 1)
        let manager = HiddenWindowManager(app: rig.app, ax: rig.ax, transfers: transfers, clock: clock)
        // The user opens Messages while the bridge waits for the transfer.
        rig.app.onState = { state in
            if transfers.checks > 0 { state = Make.state(frontmost: true, hidden: false, ax: 1, onScreen: 1) }
        }
        XCTAssertEqual(manager.ensureHiddenWindow(queueDeadline: clock.uptime + 30), .messagesOpen)
        XCTAssertTrue(rig.app.calls.isEmpty, "quit a window the user opened: \(rig.app.calls)")
    }

    func testQuitResultIsAdvisory() {
        // FakeMessagesApp.quit returns true; a quit that reports failure but still exits must still relaunch.
        final class QuitFails: MessagesAppControl {
            let inner: FakeMessagesApp
            init(_ inner: FakeMessagesApp) { self.inner = inner }
            func state() -> MessagesAppState { inner.state() }
            func launchHidden() -> Bool { inner.launchHidden() }
            func quit() -> Bool { _ = inner.quit(); return false }
            func waitForExit(timeout: TimeInterval) -> Bool {
                XCTAssertEqual(timeout, Limits.quitWait)
                return inner.waitForExit(timeout: timeout)
            }
            func activateForeground() -> Bool { inner.activateForeground() }
            func hide() { inner.hide() }
            func frontmostApp() -> FrontApp? { inner.frontmostApp() }
            func reopen(bundleID: String) -> Bool { inner.reopen(bundleID: bundleID) }
        }
        let rig = Rig(state: Make.state(hidden: false, ax: 0))
        rig.app.onCall = { call, state in
            if call == .quit { state = .notRunning }
            if call == .launchHidden { state = Make.readyState }
        }
        let manager = HiddenWindowManager(app: QuitFails(rig.app), ax: rig.ax, transfers: rig.transfers,
                                          clock: rig.clock)
        XCTAssertNil(manager.ensureHiddenWindow(queueDeadline: rig.clock.uptime + 30))
        XCTAssertEqual(rig.app.calls, [.quit, .waitForExit, .launchHidden])
    }

    func testQuitHandlerAnsweringNotRunningCountsAsQuit() {
        // Messages exited before the handler ran, so `quit_messages` sent it nothing and answered `not_running`.
        let scripts = FakeAppleScriptRunner()
        scripts.outcomes = [AppleScriptOutcome(ok: true, value: "not_running")]
        XCTAssertTrue(LiveMessagesApp(scripts: scripts).quit())
        XCTAssertEqual(scripts.calls.map(\.0), [.quitMessages])
    }

    // MARK: - Never touch the user's window (item 3)

    func testNoPathHidesActivatesOrReopens() {
        let states = [MessagesAppState.notRunning, Make.state(hidden: false, ax: 0), Make.state(hidden: false, ax: 1),
                      Make.state(frontmost: true, hidden: false, ax: 1), Make.state(hidden: true, ax: 2),
                      Make.state()]
        for state in states {
            let rig = Rig(state: state)
            rig.app.onCall = { call, s in
                if call == .quit { s = .notRunning }
                if call == .launchHidden { s = Make.readyState }
            }
            _ = rig.windows.prepare(queueDeadline: rig.clock.uptime + 30)
            _ = rig.windows.visibilityCheck()
            for call in rig.app.calls {
                switch call {
                case .hide, .activateForeground, .reopen: XCTFail("\(state): \(call)")
                default: break
                }
            }
            XCTAssertNoPress(rig.log)
        }
    }

    // MARK: - Visibility poll (item 4)

    func testVisibilityPollLastsOneSecondWhenNothingShows() {
        let rig = Rig()
        let start = rig.clock.uptime
        XCTAssertEqual(rig.windows.visibilityCheck(), VisibilityCheck(becameVisible: false))
        XCTAssertEqual(rig.clock.uptime - start, Limits.visibilityPoll, accuracy: 0.0001)
    }

    func testVisibilityPollCatchesUnhideAndOnScreenWindow() {
        let unhidden = Rig()
        let start = unhidden.clock.uptime
        let clock = unhidden.clock
        unhidden.app.onState = { s in if clock.uptime - start >= 0.5 { s = Make.state(hidden: false, ax: 1) } }
        let check = unhidden.windows.visibilityCheck()
        XCTAssertTrue(check.becameVisible)
        XCTAssertEqual(check.note, .messagesBecameVisible)

        let onScreen = Rig()
        onScreen.app.onState = { s in s = Make.state(hidden: true, ax: 1, onScreen: 1) }
        XCTAssertTrue(onScreen.windows.visibilityCheck().becameVisible)

        let unknown = Rig()
        unknown.app.onState = { s in s = Make.state(hidden: true, ax: 1, onScreen: -1) }
        XCTAssertTrue(unknown.windows.visibilityCheck().becameVisible, "an unknown on-screen count fails closed")
    }

    func testVisibilityPollBoundary() {
        func run(showAt: TimeInterval) -> Bool {
            let rig = Rig()
            rig.windows.pollInterval = 0.25
            let clock = rig.clock
            let start = clock.uptime
            rig.app.onState = { s in if clock.uptime - start >= showAt { s = Make.state(hidden: false, ax: 1) } }
            return rig.windows.visibilityCheck().becameVisible
        }
        XCTAssertTrue(run(showAt: 1.0))
        XCTAssertFalse(run(showAt: 1.01))
    }

    func testShowsWindow() {
        XCTAssertFalse(WindowRules.showsWindow(.notRunning))
        XCTAssertFalse(WindowRules.showsWindow(Make.state()))
        XCTAssertFalse(WindowRules.showsWindow(Make.state(hidden: false, ax: 0)))
        XCTAssertTrue(WindowRules.showsWindow(Make.state(hidden: false, ax: 1)))
        XCTAssertTrue(WindowRules.showsWindow(Make.state(frontmost: true, hidden: false, ax: 0)))
        XCTAssertTrue(WindowRules.showsWindow(Make.state(hidden: true, ax: 1, onScreen: 1)))
        XCTAssertFalse(WindowRules.showsWindow(Make.state(hidden: false, ax: 0, anySpace: 1)), "on another Space")
        XCTAssertFalse(WindowRules.showsWindow(Make.state(hidden: true, ax: 0, anySpace: 1)))
    }

    func testShowsWindowCountsOnlyWhatTheUserCanSee() {
        // No Accessibility grant or a failed AX read (-1), nothing on screen and a window on another Space: not shown.
        // The count on every Space decides only busy against quit, and `isHidden` can lag a launch.
        XCTAssertFalse(WindowRules.showsWindow(Make.state(hidden: false, ax: -1, onScreen: 0, anySpace: 1)))
        XCTAssertFalse(WindowRules.showsWindow(Make.state(hidden: false, ax: -1, onScreen: 0, anySpace: -1)))
        XCTAssertTrue(WindowRules.showsWindow(Make.state(hidden: false, ax: -1, onScreen: -1)), "no on-screen list")
        XCTAssertTrue(WindowRules.showsWindow(Make.state(hidden: true, ax: 1, onScreen: -1)), "no on-screen list")
        XCTAssertTrue(WindowRules.showsWindow(Make.state(hidden: false, ax: 1, onScreen: 0)), "not hidden, AX window")
    }

    func testBusyResultCountsAWindowOnAnySpace() {
        XCTAssertEqual(WindowRules.busyResult(for: Make.state(hidden: false, ax: 0, anySpace: 1)), .messagesOpen)
        XCTAssertNil(WindowRules.busyResult(for: Make.state(frontmost: true, hidden: false, ax: 0, anySpace: 0)).fix)
    }
}
