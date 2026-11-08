import Foundation
import IMCore

/// Clock that only moves when told. `sleep` advances both clocks instead of blocking. Thread safe: one lock guards
/// `now`, `uptime` and `sleeps`, so tests can sleep and advance it from several threads.
public final class FakeClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var currentNow: Date
    private var currentUptime: TimeInterval
    private var recordedSleeps: [TimeInterval] = []

    public init(now: Date = Fixture.now, uptime: TimeInterval = 1000) {
        currentNow = now
        currentUptime = uptime
    }

    public var now: Date {
        get { locked { currentNow } }
        set { locked { currentNow = newValue } }
    }

    public var uptime: TimeInterval {
        get { locked { currentUptime } }
        set { locked { currentUptime = newValue } }
    }

    public var sleeps: [TimeInterval] { locked { recordedSleeps } }

    public func sleep(_ seconds: TimeInterval) {
        locked {
            recordedSleeps.append(seconds)
            advanceLocked(seconds)
        }
    }

    public func advance(_ seconds: TimeInterval) {
        locked { advanceLocked(seconds) }
    }

    private func advanceLocked(_ seconds: TimeInterval) {
        currentNow = currentNow.addingTimeInterval(seconds)
        currentUptime += seconds
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// Scripted Messages process. Tests set `current` and read `calls`.
///
/// Three hooks script the state:
/// - `onCall` runs after each control call (launch, quit, activate, hide, reopen).
/// - `onState` runs inside every `state()` call before it returns `current`, so a test can change the state as a
///   `FakeClock` advances, for example `isHidden` turning true 0.4 s into the 1 s hide poll, Messages becoming
///   frontmost within 1 s of `activateForeground`, or one hidden window appearing 3 s after a relaunch.
/// - `onFrontmost` runs inside every `frontmostApp()` call before it returns `front`, for the same kind of script
///   on the front app (the 5 s late-activation watch, the 2 s focus-restore wait).
public final class FakeMessagesApp: MessagesAppControl {
    public enum Call: Hashable {
        case launchHidden, quit, waitForExit, activateForeground, hide, reopen(String)
    }

    public var current: MessagesAppState
    public var front: FrontApp?
    public private(set) var calls: [Call] = []
    /// Applied to `current` after each call, so a test can script the next state.
    public var onCall: ((Call, inout MessagesAppState) -> Void)?
    /// Applied to `current` on each `state()` read. Capture a `FakeClock` and branch on its `uptime`.
    public var onState: ((inout MessagesAppState) -> Void)?
    /// Applied to `front` on each `frontmostApp()` read. Capture a `FakeClock` and branch on its `uptime`.
    public var onFrontmost: ((inout FrontApp?) -> Void)?

    public init(current: MessagesAppState = .notRunning, front: FrontApp? = nil) {
        self.current = current
        self.front = front
    }

    private func record(_ call: Call) {
        calls.append(call)
        onCall?(call, &current)
    }

    public func state() -> MessagesAppState {
        onState?(&current)
        return current
    }
    public func launchHidden() -> Bool { record(.launchHidden); return true }
    public func quit() -> Bool { record(.quit); return true }
    public func waitForExit(timeout: TimeInterval) -> Bool { record(.waitForExit); return !state().isRunning }
    public func activateForeground() -> Bool { record(.activateForeground); return true }
    public func hide() { record(.hide) }
    public func frontmostApp() -> FrontApp? {
        onFrontmost?(&front)
        return front
    }
    public func reopen(bundleID: String) -> Bool { record(.reopen(bundleID)); return true }
}

/// Records handler calls and returns queued outcomes (default: ok with no value).
public final class FakeAppleScriptRunner: AppleScriptRunning {
    public private(set) var calls: [(ScriptHandler, [String])] = []
    public var outcomes: [AppleScriptOutcome] = []

    public init() {}

    public func call(_ handler: ScriptHandler, arguments: [String]) -> AppleScriptOutcome {
        calls.append((handler, arguments))
        return outcomes.isEmpty ? AppleScriptOutcome(ok: true) : outcomes.removeFirst()
    }
}

/// Records journal hooks. Set `failWillInvoke` to check that the caller performs nothing.
public final class FakeInvocationRecorder: InvocationRecorder {
    public struct Failure: Error {}

    public private(set) var invoking: [InvocationFacts] = []
    public private(set) var invokedCount = 0
    public var failWillInvoke = false

    public init() {}

    public func willInvoke(_ facts: InvocationFacts) throws {
        if failWillInvoke { throw Failure() }
        invoking.append(facts)
    }

    public func didInvoke() throws { invokedCount += 1 }
}

public final class FakePendingTransfers: PendingTransferChecking {
    public var pending: Bool

    public init(pending: Bool = false) { self.pending = pending }

    public func hasPendingTransfers() -> Bool { pending }
}
