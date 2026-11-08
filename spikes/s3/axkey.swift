// axkey confirm | return: try AXConfirm on the composer, or post Return straight to Messages' pid (not the focused app).
import ApplicationServices
import AppKit
func attr(_ e: AXUIElement, _ n: String) -> CFTypeRef? { var v: CFTypeRef?; return AXUIElementCopyAttributeValue(e, n as CFString, &v) == .success ? v : nil }
func find(_ e: AXUIElement, _ id: String, _ d: Int = 0) -> AXUIElement? {
    if (attr(e, "AXIdentifier") as? String) == id { return e }
    if d > 30 { return nil }
    for c in (attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? []) { if let r = find(c, id, d + 1) { return r } }
    return nil
}
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MobileSMS").first else { exit(1) }
let pid = app.processIdentifier
let ax = AXUIElementCreateApplication(pid)
guard let win = (attr(ax, kAXWindowsAttribute) as? [AXUIElement])?.first, let field = find(win, "messageBodyField") else { print("no field"); exit(2) }
if CommandLine.arguments[1] == "confirm" {
    print("confirm=\(AXUIElementPerformAction(field, kAXConfirmAction as CFString).rawValue)")
} else {
    print("focus=\(AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue).rawValue)")
    let src = CGEventSource(stateID: .privateState)
    for down in [true, false] {
        let ev = CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: down)!
        ev.postToPid(pid)
    }
    print("posted return to pid \(pid)")
}
