// Lists Messages menu bar items (UI labels only) and their enabled state.
import ApplicationServices
import AppKit
func attr(_ e: AXUIElement, _ n: String) -> CFTypeRef? { var v: CFTypeRef?; return AXUIElementCopyAttributeValue(e, n as CFString, &v) == .success ? v : nil }
func walk(_ e: AXUIElement, _ d: Int) {
    if d > 8 { return }
    let t = attr(e, kAXTitleAttribute) as? String ?? ""
    let en = (attr(e, kAXEnabledAttribute) as? Bool).map { $0 ? "" : " (disabled)" } ?? ""
    if !t.isEmpty { print(String(repeating: "  ", count: d) + t + en) }
    for c in (attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? []) { walk(c, d + 1) }
}
let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MobileSMS").first!
let ax = AXUIElementCreateApplication(app.processIdentifier)
if let mb = attr(ax, kAXMenuBarAttribute) { walk(mb as! AXUIElement, 0) }
