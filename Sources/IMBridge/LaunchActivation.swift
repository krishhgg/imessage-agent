import Foundation
import IMCore

@_silgen_name("launch_activate_socket")
private func launch_activate_socket(_ name: UnsafePointer<CChar>,
                                    _ fds: UnsafeMutablePointer<UnsafeMutablePointer<Int32>?>,
                                    _ cnt: UnsafeMutablePointer<Int>) -> Int32

/// launchd socket adoption (DESIGN.md section 1, TCC contract). Taken from the S1 spike (spikes/s1/Bridge.swift).
/// Owner: IMBridge.
public enum LaunchActivation {
    /// The listening fds launchd holds for `Sockets/<name>`, or nil if this process wasn't launched by launchd.
    /// Must run before `NSApplicationMain`.
    public static func activateSocket(name: String = AppIdentity.launchdSocketName) -> [Int32]? {
        adopt(name: name, using: launch_activate_socket)
    }

    /// The `launch_activate_socket` call shape.
    typealias Activate = (UnsafePointer<CChar>, UnsafeMutablePointer<UnsafeMutablePointer<Int32>?>,
                          UnsafeMutablePointer<Int>) -> Int32

    /// Turns the activation result into the fd list and frees the array launchd allocated. A non-zero result
    /// (ESRCH when launchd didn't start this process) or an empty list is nil. Tests pass a fake `activate`, so they
    /// never reach launchd.
    static func adopt(name: String, using activate: Activate) -> [Int32]? {
        var fds: UnsafeMutablePointer<Int32>?
        var count = 0
        let rc = name.withCString { activate($0, &fds, &count) }
        defer { free(fds) }
        guard rc == 0, count > 0, let base = fds else { return nil }
        return Array(UnsafeBufferPointer(start: base, count: count))
    }

    /// A second instance started by Launch Services (Finder, `open`, "Quit & Reopen") kickstarts the launchd job and
    /// exits (S1 tested `open`).
    public static func kickstartAndExit() -> Never {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["kickstart", Paths.launchdServiceTarget(uid: getuid())]
        try? p.run()
        p.waitUntilExit()
        exit(0)
    }
}
