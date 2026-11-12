// axact <token> <action> [--list]: perform a named AX action on the Messages bubble whose
// description contains <token> (our own test messages only). Prints the AXError code.
import ApplicationServices
import AppKit
let args = CommandLine.arguments
let token = args[1], action = args.count > 2 ? args[2] : "", listOnly = args.contains("--list")
func attr(_ e: AXUIElement, _ a: String) -> CFTypeRef? { var v: CFTypeRef?; return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil }
func str(_ e: AXUIElement, _ a: String) -> String { attr(e, a) as? String ?? "" }
var hits: [AXUIElement] = []
func walk(_ e: AXUIElement, _ d: Int) {
    if d > 40 { return }
    if str(e, "AXIdentifier") == "Sticker" && str(e, kAXDescriptionAttribute).contains(token) { hits.append(e) }
    for c in (attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? []) { walk(c, d + 1) }
}
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MobileSMS").first else { print("messages not running"); exit(1) }
let ax = AXUIElementCreateApplication(app.processIdentifier)
for w in (attr(ax, kAXWindowsAttribute) as? [AXUIElement] ?? []) { walk(w, 0) }
print("matches=\(hits.count)")
guard hits.count == 1, let el = hits.first else { exit(2) }
var names: CFArray?; AXUIElementCopyActionNames(el, &names)
let all = names as? [String] ?? []
if listOnly { print(all.map { $0.hasPrefix("Name:") ? String($0.split(separator: "\n")[0].dropFirst(5)) : $0 }.joined(separator: ",")); exit(0) }
guard let full = all.first(where: { $0 == action || $0.hasPrefix("Name:\(action)\n") || $0 == "Name:\(action)" }) else { print("no action \(action)"); exit(3) }
let t0 = Date()
let rc = AXUIElementPerformAction(el, full as CFString)
print("perform=\(rc.rawValue) ms=\(Int(Date().timeIntervalSince(t0) * 1000))")
