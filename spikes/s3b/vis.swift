// vis <ms> -- <command...>: runs the command and samples every 10 ms for <ms>, recording any
// on-screen Messages window (owner pid + bounds only, no titles or content) and frontmost-app changes.
import AppKit
import ApplicationServices
let a = CommandLine.arguments
let ms = Int(a[1]) ?? 1500
let cmd = Array(a.dropFirst(3))
func msgs() -> NSRunningApplication? { NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MobileSMS").first }
func onscreen(_ pid: pid_t) -> Int {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
        && (($0[kCGWindowBounds as String] as? [String: Any])?["Height"] as? Double ?? 0) > 100 }.count
}
func axWindows(_ pid: pid_t) -> Int { var v: CFTypeRef?; AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &v); return (v as? [AXUIElement])?.count ?? -1 }
let front0 = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
let t0 = Date()
if !cmd.isEmpty { let p = Process(); p.executableURL = URL(fileURLWithPath: cmd[0]); p.arguments = Array(cmd.dropFirst()); try? p.run() }
var maxOn = 0, firstOn = -1, visMs = 0, fronts: [String] = [], lastFront = front0
while Int(Date().timeIntervalSince(t0) * 1000) < ms {
    if let m = msgs() {
        let n = onscreen(m.processIdentifier)
        if n > 0 { visMs += 10; if firstOn < 0 { firstOn = Int(Date().timeIntervalSince(t0) * 1000) } }
        maxOn = max(maxOn, n)
    }
    let f = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
    if f != lastFront { fronts.append("\(Int(Date().timeIntervalSince(t0) * 1000))ms:\(f)"); lastFront = f }
    usleep(10_000)
    RunLoop.current.run(until: Date())
}
let m = msgs()
print("running=\(m != nil) hidden=\(m?.isHidden ?? false) active=\(m?.isActive ?? false) ax_windows=\(m.map { axWindows($0.processIdentifier) } ?? -1) onscreen_max=\(maxOn) first_on_ms=\(firstOn) visible_ms~\(visMs) front_before=\(front0) front_changes=\(fronts.isEmpty ? "none" : fronts.joined(separator: ","))")
