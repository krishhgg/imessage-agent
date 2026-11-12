import Foundation
import IMCore

/// What the window rules say to do before a hidden UI action (DESIGN.md section 4, Window rules).
public enum WindowDecision: Hashable, Sendable {
    /// Messages is hidden with exactly one window. Go ahead.
    case proceed
    /// Not running: `open -g -j -b`, then require one hidden window.
    case launchHidden
    /// No window and not frontmost: quit, wait up to 10 s, relaunch hidden. Needs the queue and no pending transfer.
    /// Not hidden, it also needs no real window on any Space.
    case quitAndRelaunch
    /// Frontmost (with or without a window), visible window, or hidden with more than one window.
    case busyMessagesOpen
    /// The screen is locked. AX lists no Messages window, so nothing is launched, quit or pressed.
    case screenLocked
}

/// Pure decision from a `MessagesAppState`. Owner: IMUI.
///
/// - Screen locked: `screenLocked`, whatever else the state shows. AX lists no Messages window on a locked screen,
///   hidden or not, so the hidden-with-no-window case below would otherwise quit and relaunch Messages and still find
///   no window (docs/BUILD-PLAN.md entry 52).
/// - Frontmost: `busyMessagesOpen`.
/// - Not running: `launchHidden`.
/// - No AX window, not hidden, and a real window on some Space (or an unknown count): `busyMessagesOpen` with the
///   ⌘H fix. AX and the on-screen list both miss a window on another Space or full screen in its own Space.
/// - No window: `quitAndRelaunch`. Hidden with no AX window also counts as no window, since a hidden window on
///   another Space isn't in use.
/// - A window that isn't hidden (even minimized or on another Space): `busyMessagesOpen` with the ⌘H fix.
/// - Hidden with more than one window: `busyMessagesOpen`. The count is the larger of AX's and the real windows on
///   some Space (`spaceWindowCount`), since AX misses a window on another Space. The count leaves out the 500 x 500
///   window Messages never shows, which is on no Space; counted, it made every hidden action busy. An unknown count
///   (-1) doesn't raise it.
///
/// Only that test uses `spaceWindowCount`. The busy-or-quit test keeps `allSpacesWindowCount`, so a Space lookup
/// that misses a real window can't quit Messages while the user has it open on another Space.
/// - Hidden with one window: `proceed`.
///
/// Unknown counts fail closed. An AX window count of -1 (no Accessibility grant, or AX failed) or a nonzero
/// on-screen count is `busyMessagesOpen`, because a window the bridge can't count may be the user's, and quitting
/// Messages would close it.
public enum WindowRules {
    public static func decide(_ state: MessagesAppState) -> WindowDecision {
        if state.isScreenLocked { return .screenLocked }
        if state.isFrontmost { return .busyMessagesOpen }
        if !state.isRunning { return .launchHidden }
        if state.axWindowCount < 0 { return .busyMessagesOpen }
        if state.onScreenWindowCount != 0 { return .busyMessagesOpen }
        if state.axWindowCount == 0 {
            if !state.isHidden, state.allSpacesWindowCount != 0 { return .busyMessagesOpen }
            return .quitAndRelaunch
        }
        if !state.isHidden { return .busyMessagesOpen }
        if max(state.axWindowCount, state.spaceWindowCount) > 1 { return .busyMessagesOpen }
        return .proceed
    }

    /// True only when `decide` says `proceed`: Messages hidden, not frontmost, one AX window, none on screen and no
    /// more than one real window on any Space.
    /// Read-only. `HiddenWindowManager.recheck` runs it as the last check before a hidden named action, after
    /// `prepare` may have waited.
    public static func allowsHiddenAction(_ state: MessagesAppState) -> Bool {
        decide(state) == .proceed
    }

    /// The `busy: Messages is open` result for a busy state. It carries `fix: hide Messages (⌘H) and retry` only
    /// when a window is showing, that is Messages isn't hidden and has a window, on any Space or of an unknown
    /// count there. Hiding doesn't help when Messages is already hidden with two windows, or frontmost with none.
    /// A locked screen gives `busy: screen locked` instead.
    public static func busyResult(for state: MessagesAppState) -> ActionResult {
        if state.isScreenLocked { return .screenLocked }
        let windowShowing = state.isRunning && !state.isHidden
            && (state.axWindowCount > 0 || state.onScreenWindowCount > 0 || state.allSpacesWindowCount != 0)
        return windowShowing ? .messagesOpen : ActionResult(.busy(.messagesOpen))
    }

    /// True when a sample shows Messages on screen, by what the user can see: an on-screen window (or an unknown
    /// on-screen count), Messages frontmost, or Messages not hidden with an AX window. An unknown AX count alone isn't
    /// shown. The count on every Space decides only busy against quit (`decide` and `busyResult`), because a window on
    /// another Space isn't on screen, and `isHidden` can lag a launch. The visibility poll and the launch wait use it.
    public static func showsWindow(_ state: MessagesAppState) -> Bool {
        guard state.isRunning else { return false }
        if state.onScreenWindowCount != 0 || state.isFrontmost { return true }
        return !state.isHidden && state.axWindowCount > 0
    }
}

/// Result of the 1 s poll after a hidden action, cold launch or relaunch.
public struct VisibilityCheck: Hashable, Sendable {
    public var becameVisible: Bool

    public init(becameVisible: Bool) { self.becameVisible = becameVisible }

    /// Note to add when `becameVisible` is true.
    public var note: ResultNote? { becameVisible ? .messagesBecameVisible : nil }
}

/// What `HiddenWindowManager.prepare` found: an early result, or nil when the action may go ahead, plus the notes the
/// action must add to its own result (`error: Messages became visible` after a cold launch or relaunch). An early
/// result already carries its notes, and `notes` is then empty.
public struct WindowPreparation: Hashable, Sendable {
    public var early: ActionResult?
    public var notes: [ResultNote]

    public init(early: ActionResult?, notes: [ResultNote]) {
        self.early = early
        self.notes = notes
    }
}

/// Runs `WindowRules` and gets Messages into the one-hidden-window state. Owner: IMUI.
///
/// Returns `busy: Messages is open` (with the fix), `no_hidden_window` if Messages doesn't exit or there is no single
/// hidden window 10 s after the relaunch, or nil when the action may go ahead. Waits for `transfers` before a
/// relaunch, inside the caller's queue wait.
///
/// The caller holds the queue (section 3 item 3). The manager never presses anything in Messages, never uses
/// Window > Messages or `imessage://`, and never hides a window the user may be using.
public final class HiddenWindowManager {
    public let app: MessagesAppControl
    public let ax: MessagesAXDriving
    public let transfers: PendingTransferChecking
    public let clock: Clock
    /// Sampling interval for the launch wait, the transfer wait and the visibility poll.
    public var pollInterval: TimeInterval = 0.05

    private let lock = NSLock()
    private var launchedAt: TimeInterval?

    /// `clock.uptime` when this manager last ran `open -g -j -b` for a cold launch or relaunch, nil before its first
    /// launch. `ChatTargeter` reads it to tell a list that hasn't shown yet, or is still filling in its rows, after a
    /// launch from a window with no list or a list with placeholder tiles.
    public var lastLaunchUptime: TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        return launchedAt
    }

    public init(app: MessagesAppControl, ax: MessagesAXDriving, transfers: PendingTransferChecking, clock: Clock) {
        self.app = app
        self.ax = ax
        self.transfers = transfers
        self.clock = clock
    }

    /// Nil when ready. Otherwise the early result to return.
    ///
    /// The early result already carries `error: Messages became visible` when a launch showed a window. When the
    /// action goes ahead after a cold launch or relaunch that showed a window, only `prepare` returns that note, so
    /// callers that go on to act should call `prepare` instead.
    public func ensureHiddenWindow(queueDeadline: TimeInterval) -> ActionResult? {
        prepare(queueDeadline: queueDeadline).early
    }

    /// `ensureHiddenWindow` plus the notes the action adds to its own result.
    ///
    /// - No Accessibility grant (`AXDriveError.notTrusted`): `UIResults.accessibilityMissing`, nothing launched.
    /// - `proceed`: ready, nothing pressed or launched.
    /// - `busyMessagesOpen`: `WindowRules.busyResult`.
    /// - `screenLocked`: `busy: screen locked`, nothing launched or quit.
    /// - `launchHidden`: `open -g -j -b`, then one hidden window within `Limits.relaunchWindowWait`, then the 1 s
    ///   visibility poll.
    /// - `quitAndRelaunch`: waits until no staged file is pending, up to `queueDeadline` (`busy: queue`), reads the
    ///   state again, quits through Apple Events, waits `Limits.quitWait` for the exit, then launches as above.
    ///   The quit's return value is advisory; only the exit counts.
    public func prepare(queueDeadline: TimeInterval) -> WindowPreparation {
        // Untrusted, AX reads no windows, and the rules would take that for a Messages the user has open, or launch
        // it and wait for a window AX can't see. Nothing is launched or quit.
        do {
            _ = try ax.windowCount()
        } catch AXDriveError.notTrusted {
            return WindowPreparation(early: UIResults.accessibilityMissing, notes: [])
        } catch {}
        let state = currentState()
        switch WindowRules.decide(state) {
        case .proceed:
            return WindowPreparation(early: nil, notes: [])
        case .busyMessagesOpen:
            return WindowPreparation(early: WindowRules.busyResult(for: state), notes: [])
        case .screenLocked:
            return WindowPreparation(early: .screenLocked, notes: [])
        case .launchHidden:
            return launchAndWait()
        case .quitAndRelaunch:
            return quitAndRelaunch(queueDeadline: queueDeadline)
        }
    }

    /// The window rules again, launching and quitting nothing: nil while Messages is still hidden with one window,
    /// `busy: screen locked` on a locked screen, `no_hidden_window` if it quit, otherwise `WindowRules.busyResult`.
    /// Hidden actions call it right before the named action, because the user may have shown Messages since
    /// `prepare`. Foreground step 1 calls it after the chat check, which can wait seconds for the list to load, and
    /// after a `not_loaded` refusal from that check.
    public func recheck() -> ActionResult? {
        let state = currentState()
        if WindowRules.allowsHiddenAction(state) { return nil }
        if state.isScreenLocked { return .screenLocked }
        return state.isRunning ? WindowRules.busyResult(for: state) : ActionResult(.noHiddenWindow)
    }

    /// Polls `isHidden` and the on-screen window list for `Limits.visibilityPoll`.
    public func visibilityCheck() -> VisibilityCheck {
        let deadline = clock.uptime + Limits.visibilityPoll
        while true {
            if WindowRules.showsWindow(currentState()) { return VisibilityCheck(becameVisible: true) }
            let left = deadline - clock.uptime
            if left <= 0 { return VisibilityCheck(becameVisible: false) }
            sleepPollStep(clock, interval: pollInterval, left: left)
        }
    }

    // MARK: - Paths

    private func quitAndRelaunch(queueDeadline: TimeInterval) -> WindowPreparation {
        // Section 3 item 3: the relaunch waits until no staged file is waiting for transfer_state 5, and that wait
        // counts against the request's 30 s queue budget.
        while transfers.hasPendingTransfers() {
            let left = queueDeadline - clock.uptime
            if left <= 0 { return WindowPreparation(early: ActionResult(.busy(.queue)), notes: []) }
            sleepPollStep(clock, interval: pollInterval, left: left)
        }
        // Time passed while waiting, so the user may have opened Messages or locked the screen. Decide again before
        // quitting.
        let state = currentState()
        switch WindowRules.decide(state) {
        case .proceed:
            return WindowPreparation(early: nil, notes: [])
        case .busyMessagesOpen:
            return WindowPreparation(early: WindowRules.busyResult(for: state), notes: [])
        case .screenLocked:
            return WindowPreparation(early: .screenLocked, notes: [])
        case .launchHidden:
            return launchAndWait()
        case .quitAndRelaunch:
            break
        }
        _ = app.quit()
        guard app.waitForExit(timeout: Limits.quitWait) else {
            return WindowPreparation(early: ActionResult(.noHiddenWindow), notes: [])
        }
        // Even if the screen locked during the exit wait, launch hidden to restore the Messages the bridge quit.
        return launchAndWait()
    }

    private func launchAndWait() -> WindowPreparation {
        let deadline = clock.uptime + Limits.relaunchWindowWait
        var sawWindow = false
        var ready = false
        // A failed `open` may still have started Messages, so the visibility poll below runs either way, and the
        // launch time is kept either way.
        lock.lock()
        launchedAt = clock.uptime
        lock.unlock()
        if app.launchHidden() {
            while true {
                let state = currentState()
                if WindowRules.showsWindow(state) { sawWindow = true }
                let decision = WindowRules.decide(state)
                if decision == .proceed {
                    ready = true
                    break
                }
                // A screen that locks during the wait won't show a window to AX before the deadline.
                if decision == .screenLocked { break }
                let left = deadline - clock.uptime
                if left <= 0 { break }
                sleepPollStep(clock, interval: pollInterval, left: left)
            }
        }
        // The 1 s poll after every cold launch and relaunch. A window already seen is enough for the note.
        if !sawWindow, visibilityCheck().becameVisible { sawWindow = true }
        let notes: [ResultNote] = sawWindow ? [.messagesBecameVisible] : []
        let final = currentState()
        guard ready, WindowRules.decide(final) == .proceed else {
            let early = final.isScreenLocked
                ? ActionResult(.busy(.screenLocked), notes: notes, fix: ActionResult.screenLocked.fix)
                : ActionResult(.noHiddenWindow, notes: notes)
            return WindowPreparation(early: early, notes: [])
        }
        return WindowPreparation(early: nil, notes: notes)
    }

    /// `app.state()`, with the AX window count filled from `ax` when the app snapshot couldn't count windows.
    private func currentState() -> MessagesAppState {
        Self.state(of: app, countWindows: { try ax.windowCount() })
    }

    /// `app.state()`, with an unknown AX window count (-1) filled from `countWindows`, which can block for up to 2 s.
    /// After that read succeeds, `app.state()` runs again, so `isHidden` and frontmost are sampled after every read
    /// that can block. The filled count is used only if the new state's AX count is still unknown. A new state that
    /// shows Messages not running is returned as it is. `LiveMessagesAX.press(row:)`, which nothing calls now, uses it
    /// too.
    static func state(of app: MessagesAppControl, countWindows: () throws -> Int) -> MessagesAppState {
        let first = app.state()
        guard first.isRunning, first.axWindowCount < 0, let count = try? countWindows() else { return first }
        var state = app.state()
        if state.isRunning, state.axWindowCount < 0 { state.axWindowCount = count }
        return state
    }
}

/// Sleeps one poll step, never past `left`. A step of 0 or less counts as `minimumPollStep`, so a poll loop always
/// reaches its deadline, even on a clock that only moves when it sleeps.
func sleepPollStep(_ clock: Clock, interval: TimeInterval, left: TimeInterval) {
    clock.sleep(min(max(interval, minimumPollStep), left))
}

/// The shortest poll step any IMUI loop takes.
let minimumPollStep: TimeInterval = 0.01
