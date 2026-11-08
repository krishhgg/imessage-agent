// axedit <token> [newtext] [button-desc]: find the inline edit field holding <token>, list its sibling
// buttons, optionally set new text and press a button. Our own test messages only.
import ApplicationServices
import AppKit
let a = CommandLine.arguments
func attr(_ e: AXUIElement, _ n: String) -> CFTypeRef? { var v: CFTypeRef?; return AXUIElementCopyAttributeValue(e, n as CFString, &v) == .success ? v : nil }
func str(_ e: AXUIElement, _ n: String) -> String { attr(e, n) as? String ?? "" }
var field: AXUIElement?
func walk(_ e: AXUIElement, _ d: Int) {
    if d > 40 || field != nil { return }
    if str(e, kAXRoleAttribute) == "AXTextField" && str(e, kAXValueAttribute).contains(a[1]) { field = e; return }
    for c in (attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? []) { walk(c, d + 1) }
}
let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MobileSMS").first!
let ax = AXUIElementCreateApplication(app.processIdentifier)
for w in (attr(ax, kAXWindowsAttribute) as? [AXUIElement] ?? []) { walk(w, 0) }
guard let f = field else { print("no edit field"); exit(2) }
var parent: CFTypeRef?; AXUIElementCopyAttributeValue(f, kAXParentAttribute as CFString, &parent)
var grand: CFTypeRef?; AXUIElementCopyAttributeValue(parent as! AXUIElement, kAXParentAttribute as CFString, &grand)
let sibs = attr(grand as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement] ?? []
for s in sibs where str(s, kAXRoleAttribute) == "AXButton" { print("button desc=\(str(s, kAXDescriptionAttribute)) help=\(str(s, kAXHelpAttribute))") }
if a.count > 2 { print("set=\(AXUIElementSetAttributeValue(f, kAXValueAttribute as CFString, a[2] as CFString).rawValue)") }
if a.count > 3, let b = sibs.first(where: { str($0, kAXDescriptionAttribute) == a[3] }) { print("press=\(AXUIElementPerformAction(b, kAXPressAction as CFString).rawValue)") }
