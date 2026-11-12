// axcompose set <text> | buttons | press <desc>: drive the Messages composer through AX only (no keystrokes).
import ApplicationServices
import AppKit
let a = CommandLine.arguments
func attr(_ e: AXUIElement, _ n: String) -> CFTypeRef? { var v: CFTypeRef?; return AXUIElementCopyAttributeValue(e, n as CFString, &v) == .success ? v : nil }
func str(_ e: AXUIElement, _ n: String) -> String { attr(e, n) as? String ?? "" }
func find(_ e: AXUIElement, _ id: String, _ d: Int = 0) -> AXUIElement? {
    if str(e, "AXIdentifier") == id { return e }
    if d > 30 { return nil }
    for c in (attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? []) { if let r = find(c, id, d + 1) { return r } }
    return nil
}
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MobileSMS").first else { exit(1) }
let ax = AXUIElementCreateApplication(app.processIdentifier)
guard let win = (attr(ax, kAXWindowsAttribute) as? [AXUIElement])?.first, let entry = find(win, "MessageEntryView") else { print("no entry view"); exit(2) }
let kids = attr(entry, kAXChildrenAttribute) as? [AXUIElement] ?? []
switch a[1] {
case "set":
    guard let field = find(entry, "messageBodyField") else { print("no field"); exit(3) }
    print("before_len=\(str(field, kAXValueAttribute).count)")
    let rc = AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, a[2] as CFString)
    print("set=\(rc.rawValue) after_len=\(str(field, kAXValueAttribute).count)")
case "buttons":
    for k in kids { print("\(str(k, kAXRoleAttribute)) id=\(str(k, "AXIdentifier")) desc=\(str(k, kAXDescriptionAttribute)) help=\(str(k, kAXHelpAttribute))") }
case "press":
    guard let b = kids.first(where: { str($0, kAXDescriptionAttribute) == a[2] }) else { print("no button \(a[2])"); exit(4) }
    print("press=\(AXUIElementPerformAction(b, kAXPressAction as CFString).rawValue)")
default: break
}
