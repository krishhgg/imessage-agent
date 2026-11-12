import ApplicationServices
import AppKit
func attr(_ e: AXUIElement, _ n: String) -> CFTypeRef? { var v: CFTypeRef?; return AXUIElementCopyAttributeValue(e, n as CFString, &v) == .success ? v : nil }
func str(_ e: AXUIElement, _ n: String) -> String { attr(e, n) as? String ?? "" }
var row: AXUIElement?
func walk(_ e: AXUIElement, _ d: Int) { if d > 40 || row != nil { return }; if str(e, kAXRoleAttribute) == "AXStaticText" && str(e, kAXDescriptionAttribute).hasPrefix(CommandLine.arguments[1] + ",") { row = e; return }; for c in (attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? []) { walk(c, d + 1) } }
let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MobileSMS").first!
for w in (attr(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute) as? [AXUIElement] ?? []) { walk(w, 0) }
if let r = row { print("press=\(AXUIElementPerformAction(r, kAXPressAction as CFString).rawValue)") } else { print("no row") }
