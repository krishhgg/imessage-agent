// axrow <handle> [action]: list or perform a named action on the conversation-list row for <handle> (self-chat only).
import ApplicationServices
import AppKit
let a = CommandLine.arguments
func attr(_ e: AXUIElement, _ n: String) -> CFTypeRef? { var v: CFTypeRef?; return AXUIElementCopyAttributeValue(e, n as CFString, &v) == .success ? v : nil }
func str(_ e: AXUIElement, _ n: String) -> String { attr(e, n) as? String ?? "" }
var row: AXUIElement?
func walk(_ e: AXUIElement, _ d: Int) {
    if d > 40 || row != nil { return }
    if str(e, kAXRoleAttribute) == "AXStaticText" && str(e, kAXDescriptionAttribute).hasPrefix(a[1] + ",") { row = e; return }
    for c in (attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? []) { walk(c, d + 1) }
}
let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MobileSMS").first!
for w in (attr(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute) as? [AXUIElement] ?? []) { walk(w, 0) }
guard let r = row else { print("no row"); exit(2) }
var names: CFArray?; AXUIElementCopyActionNames(r, &names)
let all = names as? [String] ?? []
let short = all.map { $0.hasPrefix("Name:") ? String($0.split(separator: "\n")[0].dropFirst(5)) : $0 }
print(short.filter { !$0.hasPrefix("AX") }.joined(separator: ","))
if a.count > 2, let i = short.firstIndex(of: a[2]) { print("perform=\(AXUIElementPerformAction(r, all[i] as CFString).rawValue)") }
