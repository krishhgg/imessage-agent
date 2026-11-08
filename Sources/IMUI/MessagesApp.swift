import AppKit
import ApplicationServices
import Foundation
import IMCore

/// Live `MessagesAppControl` over NSRunningApplication, NSWorkspace, `/usr/bin/open` and
/// `CGWindowListCopyWindowInfo`. Owner: IMUI.
///
/// - `launchHidden`: `/usr/bin/open -g -j -b com.apple.MobileSMS` (S3b).
/// - `quit`: the `quit_messages` handler through `AppleScriptRunning`.
/// - `activateForeground`: `/usr/bin/open -b com.apple.MobileSMS`, the one activation that worked in S3. It returns
///   once `open` has started, without waiting for it to exit, so IMForeground polls the front app while `open` runs
///   and records `t_front` from that poll (section 4 step 3).
/// - `endActivation`: terminates that `open` if it still runs. IMForeground calls it once Messages is seen
///   frontmost, or when the late-activation watch ends, rather than leaving it to `openTimeout`.
/// - `state().onScreenWindowCount` counts every on-screen window owned by the Messages pid, at any layer and size.
/// - `state().allSpacesWindowCount` counts the pid's real windows on every Space (`realWindowCount`), and
///   `state().spaceWindowCount` the ones of those the window server puts on a Space (`spaceWindowCount`).
/// - `isFrontmost` reads only NSWorkspace and the running app's pid, with no AX read and no window list.
/// - Never uses Window > Messages or `imessage://` (both showed a window in S3 and S3b).
public final class LiveMessagesApp: MessagesAppControl, ActivationEnding {
    public let scripts: AppleScriptRunning
    public let bundleID: String

    public init(scripts: AppleScriptRunning, bundleID: String = AppIdentity.messagesBundleID) {
        self.scripts = scripts
        self.bundleID = bundleID
    }

    /// How often `waitForExit` checks whether Messages is still running.
    public var exitPollInterval: TimeInterval = 0.1

    /// The `open -b` the last `activateForeground` started.
    private let activation = StartedProcess()

    public func state() -> MessagesAppState {
        let screenLocked = ScreenLock.isLocked()
        guard let running = runningApp() else {
            var state = MessagesAppState.notRunning
            state.isScreenLocked = screenLocked
            return state
        }
        let pid = running.processIdentifier
        // The AX count (2 s timeout) and both window lists first, and `isHidden` and frontmost last, so a hidden
        // action's final check sees an unhide or activation that happened during those reads.
        let axWindowCount = Self.axWindowCount(pid: pid)
        let onScreenWindowCount = Self.onScreenWindowCount(pid: pid)
        let allWindows = Self.allWindows()
        let allSpacesWindowCount = Self.realWindowCount(pid: pid, in: allWindows)
        let spaceWindowCount = Self.spaceWindowCount(pid: pid, in: allWindows, spaces: WindowSpaces.count(of:))
        // A screen that locks during those reads hides every Messages window from AX, so read the lock again and count
        // either read. A lock that ended during them gives busy, and the caller retries.
        let lockedAfterReads = ScreenLock.isLocked()
        let isHidden = running.isHidden
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        return MessagesAppState(isRunning: true, pid: pid, isFrontmost: frontmost, isHidden: isHidden,
                                axWindowCount: axWindowCount, onScreenWindowCount: onScreenWindowCount,
                                allSpacesWindowCount: allSpacesWindowCount, spaceWindowCount: spaceWindowCount,
                                isScreenLocked: screenLocked || lockedAfterReads)
    }

    /// The front app's pid against the running Messages' pid. No AX read and no window list, so it can't block on
    /// Messages the way `state()` can.
    public func isFrontmost() -> Bool {
        guard let pid = runningApp()?.processIdentifier else { return false }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    public func launchHidden() -> Bool {
        Self.runOpen(["-g", "-j", "-b", bundleID])
    }

    /// The `quit_messages` handler. Its result is advisory; `HiddenWindowManager` waits for the exit. The handler
    /// answers `not_running` without sending Messages anything when it has already exited, which is `ok`, so that
    /// counts as quit, and `waitForExit` then returns at once.
    public func quit() -> Bool {
        scripts.call(.quitMessages, arguments: []).ok
    }

    public func waitForExit(timeout: TimeInterval) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        while runningApp() != nil {
            let left = deadline - ProcessInfo.processInfo.systemUptime
            if left <= 0 { return false }
            Thread.sleep(forTimeInterval: min(exitPollInterval, left))
        }
        return true
    }

    public func activateForeground() -> Bool {
        activation.start(Self.openURL, ["-b", bundleID]) != nil
    }

    public func endActivation() {
        activation.end()
    }

    public func hide() {
        _ = runningApp()?.hide()
    }

    public func frontmostApp() -> FrontApp? {
        guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = front.processIdentifier
        return FrontApp(bundleID: front.bundleIdentifier, name: front.localizedName ?? "", pid: pid,
                        hasWindows: Self.hasNormalWindow(pid: pid))
    }

    /// `/usr/bin/open -b <bundleID>`. Refuses an id that isn't a plain bundle identifier.
    public func reopen(bundleID: String) -> Bool {
        guard isPlainBundleID(bundleID) else { return false }
        return Self.runOpen(["-b", bundleID])
    }

    // MARK: - Helpers

    /// The pid of the running Messages, if any. `LiveMessagesAX` uses it to skip the window counts.
    func runningPID() -> pid_t? { runningApp()?.processIdentifier }

    private func runningApp() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first { !$0.isTerminated }
    }

    /// How long `open` gets to exit before it is terminated and the call counts as failed. The caller holds the
    /// queue, so a stuck `open` must not hold it forever.
    static let openTimeout: TimeInterval = 10

    static let openURL = URL(fileURLWithPath: "/usr/bin/open")

    /// `executable` with no shell and null standard streams.
    private static func makeProcess(_ executable: URL, _ arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
    }

    /// Runs `/usr/bin/open` and waits up to `openTimeout` for it to exit.
    private static func runOpen(_ arguments: [String]) -> Bool {
        let process = makeProcess(openURL, arguments)
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return false }
        guard exited.wait(timeout: .now() + openTimeout) == .success else {
            process.terminate()
            return false
        }
        return process.terminationReason == .exit && process.terminationStatus == 0
    }

    /// Starts `executable` and returns the running process without waiting for it to exit, or nil if it didn't
    /// start. One still running after `timeout` is terminated.
    static func startProcess(_ executable: URL, _ arguments: [String],
                             timeout: TimeInterval = openTimeout) -> Process? {
        let process = makeProcess(executable, arguments)
        do { try process.run() } catch { return nil }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if process.isRunning { process.terminate() }
        }
        return process
    }

    /// AX windows of `pid`, or -1 without the Accessibility grant or on an AX error.
    private static func axWindowCount(pid: pid_t) -> Int {
        guard AXIsProcessTrusted() else { return -1 }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, LiveMessagesAX.messagingTimeout)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, "AXWindows" as CFString, &value)
        if error == .noValue { return 0 }
        guard error == .success, let windows = value as? [AnyObject] else { return -1 }
        return windows.count
    }

    /// On-screen windows owned by `pid` at any layer and size, or -1 if the window server gives no list.
    private static func onScreenWindowCount(pid: pid_t) -> Int {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return -1
        }
        return list.filter { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid }.count
    }

    /// True if `pid` owns a real window on any Space (`realWindowCount`), on screen or not. False if the window server
    /// gives no list. Without the size floor every app with a menu bar would count.
    private static func hasNormalWindow(pid: pid_t) -> Bool {
        realWindowCount(pid: pid, in: allWindows()) > 0
    }

    /// Every window the window server lists, on every Space, or nil if it gives no list.
    private static func allWindows() -> [[String: Any]]? {
        CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]
    }

    /// The shortest side, in points, a window needs to count as real. On macOS 26 every app with windows owns four
    /// layer 0 menu bar strips, 1512 x 33 on a 1512-point screen, in the full window list
    /// (research/live-tests/2026-11-07-windows.md).
    static let realWindowMinimumSide: CGFloat = 100

    /// Windows in `list` owned by `pid` at layer 0 whose width and height are both at least `realWindowMinimumSide`.
    /// -1 when there is no list. A window with no readable bounds doesn't count.
    static func realWindowCount(pid: pid_t, in list: [[String: Any]]?) -> Int {
        guard let list else { return -1 }
        return list.filter { isRealWindow($0, pid: pid) }.count
    }

    /// The real windows in `list` (`realWindowCount`) that `spaces` puts on at least one Space. `spaces` gives the
    /// number of Spaces a window id is on, or nil when it can't say, and a window it can't place still counts, as
    /// does one with no readable id. -1 when there is no list.
    ///
    /// Messages owns a 500 x 500 layer 0 window that is never on screen, at the screen's bottom-left corner, on no
    /// Space and absent from AX. Its chat window is on a Space when open, minimized or hidden
    /// (research/live-tests/2026-11-07-sends.md, test 2).
    static func spaceWindowCount(pid: pid_t, in list: [[String: Any]]?, spaces: (Int) -> Int?) -> Int {
        guard let list else { return -1 }
        return list.filter { info in
            guard isRealWindow(info, pid: pid) else { return false }
            guard let id = (info[kCGWindowNumber as String] as? NSNumber)?.intValue, let count = spaces(id) else {
                return true
            }
            return count > 0
        }.count
    }

    /// Owned by `pid`, layer 0, and both sides at least `realWindowMinimumSide`. A window with no readable bounds
    /// isn't real.
    private static func isRealWindow(_ info: [String: Any], pid: pid_t) -> Bool {
        guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
              (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
              let bounds = info[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
        return rect.width >= realWindowMinimumSide && rect.height >= realWindowMinimumSide
    }
}

/// Which Spaces the window server puts a window on, through `CGSCopySpacesForWindows`. That function is private, so
/// it is looked up at run time, and every answer is nil when it is missing. Owner: IMUI.
enum WindowSpaces {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias CopySpaces = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

    /// Current, other and full-screen Spaces.
    static let allSpacesMask: Int32 = 0x7

    private static let functions: (main: MainConnection, copy: CopySpaces)? = {
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY),
              let main = dlsym(handle, "CGSMainConnectionID"),
              let copy = dlsym(handle, "CGSCopySpacesForWindows") else { return nil }
        return (unsafeBitCast(main, to: MainConnection.self), unsafeBitCast(copy, to: CopySpaces.self))
    }()

    /// The number of Spaces window `id` is on, or nil if the lookup is missing or gives no list.
    static func count(of id: Int) -> Int? {
        guard let functions,
              let spaces = functions.copy(functions.main(), allSpacesMask, [id] as CFArray)?.takeRetainedValue()
        else { return nil }
        return CFArrayGetCount(spaces)
    }
}

/// A `MessagesAppControl` whose `activateForeground` returns while `open` still runs. IMForeground calls
/// `endActivation` once `t_front` is recorded, before any hide, and when the late-activation watch ends (section 4
/// step 3), because an `open` that brought Messages forward after the hide, or after the result, would show it again.
public protocol ActivationEnding: AnyObject {
    /// Terminates the `open` the last `activateForeground` started, if it still runs.
    func endActivation()
}

/// One started process, kept so it can be terminated before `LiveMessagesApp.openTimeout`. Thread safe.
final class StartedProcess {
    private let lock = NSLock()
    private var process: Process?

    /// `LiveMessagesApp.startProcess`, keeping the process in place of the one before.
    @discardableResult
    func start(_ executable: URL, _ arguments: [String]) -> Process? {
        let started = LiveMessagesApp.startProcess(executable, arguments)
        lock.lock()
        process = started
        lock.unlock()
        return started
    }

    /// Terminates the kept process if it still runs, and forgets it.
    func end() {
        lock.lock()
        let kept = process
        process = nil
        lock.unlock()
        if let kept, kept.isRunning { kept.terminate() }
    }
}

/// A bundle identifier `reopen` may pass to `open -b`: ASCII letters, digits, dots and hyphens, not starting with a
/// hyphen or a dot, at most 255 bytes.
func isPlainBundleID(_ id: String) -> Bool {
    guard !id.isEmpty, id.utf8.count <= 255, !id.hasPrefix("-"), !id.hasPrefix(".") else { return false }
    return id.unicodeScalars.allSatisfy {
        ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "." || $0 == "-"
    }
}

/// Whether the login session's screen is locked, from `CGSessionCopyCurrentDictionary`. Owner: IMUI.
///
/// Measured on macOS 26.2 (research/live-tests/2026-11-07-sends.md, Screen locked): `CGSSessionScreenIsLocked` is 1
/// while the lock screen shows, and AX lists no Messages window then. A session that isn't on the console
/// (`kCGSSessionOnConsoleKey` false, another user switched in) counts as locked too, since the bridge's user can't
/// see or reach Messages then either. That case is assumed, not measured. The front app being loginwindow counts as
/// locked too: it was the front app the whole time the screen was locked, and once in that time the lock key read
/// missing. loginwindow also owns the Force Quit window, so that window reads as a lock and gives busy, which fails
/// closed. A missing key with any other front app, or no session dictionary at all, reads as unlocked, so the window
/// rules decide as before.
public enum ScreenLock {
    static let loginWindowBundleID = "com.apple.loginwindow"

    public static func isLocked() -> Bool {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return front == loginWindowBundleID
        }
        return isLocked(session, frontBundleID: front)
    }

    static func isLocked(_ session: [String: Any], frontBundleID: String? = nil) -> Bool {
        if flag(session["CGSSessionScreenIsLocked"]) == true { return true }
        if flag(session[kCGSessionOnConsoleKey as String]) == false { return true }
        return frontBundleID == loginWindowBundleID
    }

    /// A Bool, or a number read as nonzero. Nil for a missing key or any other type.
    private static func flag(_ value: Any?) -> Bool? {
        switch value {
        case let flag as Bool: return flag
        case let number as NSNumber: return number.intValue != 0
        default: return nil
        }
    }
}
