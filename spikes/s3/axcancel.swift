import ApplicationServices
import AppKit
func attr(_ e: AXUIElement, _ n: String) -> CFTypeRef? { var v: CFTypeRef?; return AXUIElementCopyAttributeValue(e, n as CFString, &v) == .success ? v : nil }
func str(_ e: AXUIElement, _ n: String) -> String { attr(e, n) as? String ?? "" }
var f: AXUIElement?
func walk(_ e: AXUIElement, _ d: Int) { if d > 40 || f != nil { return }; if str(e, kAXRoleAttribute) == "AXTextField" && str(e, kAXValueAttribute).contains("s3-e1") { f = e; return }; for c in (attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? []) { walk(c, d + 1) } }
let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MobileSMS").first!
for w in (attr(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute) as? [AXUIElement] ?? []) { walk(w, 0) }
if let x = f { print("cancel=\(AXUIElementPerformAction(x, kAXCancelAction as CFString).rawValue)") } else { print("no edit field open") }
