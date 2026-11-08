import Foundation
import IMCore

public enum ColdStartResult: Hashable, Sendable {
    /// `launched` is true if this call started Messages. `becameVisible` is the 1 s visibility poll after the launch.
    case ready(launched: Bool, becameVisible: Bool)
    /// `failed: Messages not ready` after `Limits.coldStartTimeout`.
    case notReady
}

/// Cold start (DESIGN.md section 3 item 4). Owner: IMSend.
///
/// If Messages isn't running, launch it hidden through `MessagesAppControl.launchHidden()` (section 4 window rules),
/// then poll `account_ready(service)` until it returns "1", for up to 60 s.
/// After a launch it polls `app.state()` (`isHidden` and the on-screen window count) for `Limits.visibilityPoll`, and
/// the sender adds `error: Messages became visible` to each part's result if a window showed (section 4).
///
/// Order after a launch:
/// 1. Sample the window state every `visibilitySampleInterval` for `Limits.visibilityPoll`. No Apple Event runs in
///    this second, so a slow first event can't leave a gap in the samples.
/// 2. Call `account_ready` every `readyPollInterval`, sampling the window state again before each call, until it
///    returns "1" or the timeout, counted from the start of `ensureReady`, runs out. The last call runs at the
///    deadline. A poll that finds Messages not running sends no Apple Event, since that would launch it unhidden.
///
/// A Messages that is already running gets no Apple Event and no wait: section 3 item 4 ties the readiness wait to
/// the launch. A failed `open` returns `notReady` at once.
public final class ColdStarter {
    public let app: MessagesAppControl
    public let scripts: AppleScriptRunning
    public let clock: Clock

    /// Window-state samples during the 1 s visibility poll.
    public static let visibilitySampleInterval: TimeInterval = 0.05
    /// Gap between `account_ready` calls.
    public static let readyPollInterval: TimeInterval = 0.25

    public init(app: MessagesAppControl, scripts: AppleScriptRunning, clock: Clock) {
        self.app = app
        self.scripts = scripts
        self.clock = clock
    }

    public func ensureReady(service: String, timeout: TimeInterval = Limits.coldStartTimeout) -> ColdStartResult {
        let report = start(service: service, timeout: timeout)
        return report.ready ? .ready(launched: report.launched, becameVisible: report.becameVisible) : .notReady
    }

    /// What a cold start found. `ColdStartResult.notReady` has no visibility flag, so the sender uses this to report a
    /// window that showed on a launch that then timed out. Section 4 puts the note on the action's own result.
    struct Report: Hashable {
        var ready: Bool
        var launched: Bool
        var becameVisible: Bool
    }

    func start(service: String, timeout: TimeInterval = Limits.coldStartTimeout) -> Report {
        if app.state().isRunning { return Report(ready: true, launched: false, becameVisible: false) }

        let deadline = clock.uptime + timeout
        guard app.launchHidden() else { return Report(ready: false, launched: false, becameVisible: false) }

        var becameVisible = false
        let pollEnd = clock.uptime + Limits.visibilityPoll
        while true {
            if ColdStarter.windowShowed(app.state()) { becameVisible = true }
            let left = pollEnd - clock.uptime
            if left <= 0 { break }
            clock.sleep(min(ColdStarter.visibilitySampleInterval, left))
        }

        while true {
            let state = app.state()
            if ColdStarter.windowShowed(state) { becameVisible = true }
            // An Apple Event to a Messages that isn't running would launch it the normal way, not hidden. Until the
            // hidden launch shows up as running, or after Messages exits, the poll only waits.
            if state.isRunning, accountReady(service: service) {
                return Report(ready: true, launched: true, becameVisible: becameVisible)
            }
            let left = deadline - clock.uptime
            if left <= 0 { return Report(ready: false, launched: true, becameVisible: becameVisible) }
            clock.sleep(min(ColdStarter.readyPollInterval, left))
        }
    }

    /// Only a "1" from the handler counts. An error, "0" or any other value means not ready yet.
    private func accountReady(service: String) -> Bool {
        let outcome = scripts.call(.accountReady, arguments: [service])
        return outcome.ok && outcome.value == "1"
    }

    /// A Messages window showed, by what the user can see, the same rule as `WindowRules.showsWindow`: anything in
    /// the on-screen window list, at any layer and size, or an unknown on-screen count (-1), Messages frontmost, or an
    /// AX window while the app isn't hidden. An unknown AX count alone isn't shown, because without the Accessibility
    /// grant, which a send-only install doesn't have, it is always -1, and `isHidden` can lag the hidden launch. The
    /// count on every Space isn't used: a window on another Space isn't on screen.
    static func windowShowed(_ state: MessagesAppState) -> Bool {
        guard state.isRunning else { return false }
        if state.onScreenWindowCount != 0 || state.isFrontmost { return true }
        return !state.isHidden && state.axWindowCount > 0
    }
}
