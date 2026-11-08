// Dumps the Messages AX tree: roles, identifiers and action names only.
// Text attributes print only when they contain the spike token, otherwise just their length.
import ApplicationServices
import AppKit
let token = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "S2 spike"
let maxDepth = 40
var count = 0
func attr(_ e: AXUIElement, _ a: String) -> CFTypeRef? { var v: CFTypeRef?; return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil }
func str(_ e: AXUIElement, _ a: String) -> String? { attr(e, a) as? String }
func safe(_ s: String?) -> String {
    guard let s = s, !s.isEmpty else { return "" }
    return s.contains(token) || s.contains("s2-") ? "\"\(s.prefix(160))\"" : "len\(s.count)"
}
func walk(_ e: AXUIElement, _ d: Int) {
    count += 1; if count > 4000 || d > maxDepth { return }
    var names: CFArray?; AXUIElementCopyActionNames(e, &names)
    let acts = (names as? [String] ?? []).map { $0.hasPrefix("Name:") ? String($0.split(separator: "\n").first ?? "").replacingOccurrences(of: "Name:", with: "") : $0 }
    let role = str(e, kAXRoleAttribute) ?? "?", sub = str(e, kAXSubroleAttribute) ?? "", ident = str(e, "AXIdentifier") ?? ""
    let parts = ["desc=\(safe(str(e, kAXDescriptionAttribute)))", "val=\(safe(str(e, kAXValueAttribute)))", "title=\(safe(str(e, kAXTitleAttribute)))"].filter { !$0.hasSuffix("=") }
    print(String(repeating: " ", count: d) + "\(role)\(sub.isEmpty ? "" : "/" + sub)\(ident.isEmpty ? "" : " id=" + ident) \(parts.joined(separator: " "))\(acts.isEmpty ? "" : " acts=" + acts.joined(separator: ","))")
    for c in (attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? []) { walk(c, d + 1) }
}
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MobileSMS").first else { print("messages not running"); exit(1) }
let ax = AXUIElementCreateApplication(app.processIdentifier)
for w in (attr(ax, kAXWindowsAttribute) as? [AXUIElement] ?? []) { print("== window"); walk(w, 0) }
print("nodes=\(count)")
