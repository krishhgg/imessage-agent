// axinsert edit <token> <newtext> | reply <newtext>: replace text via AXSelectedText (typing-like insertion), then
// press "Send edit" (edit) or list composer buttons (reply). Our own test messages only.
import ApplicationServices
import AppKit
let a = CommandLine.arguments
func attr(_ e: AXUIElement, _ n: String) -> CFTypeRef? { var v: CFTypeRef?; return AXUIElementCopyAttributeValue(e, n as CFString, &v) == .success ? v : nil }
func str(_ e: AXUIElement, _ n: String) -> String { attr(e, n) as? String ?? "" }
func parent(_ e: AXUIElement) -> AXUIElement? { attr(e, kAXParentAttribute).map { $0 as! AXUIElement } }
var found: AXUIElement?
func walk(_ e: AXUIElement, _ d: Int, _ pred: (AXUIElement) -> Bool) {
    if d > 40 || found != nil { return }
    if pred(e) { found = e; return }
    for c in (attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? []) { walk(c, d + 1, pred) }
}
let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MobileSMS").first!
let win = (attr(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute) as! [AXUIElement])[0]
func replaceAll(_ f: AXUIElement, _ text: String) {
    let len = str(f, kAXValueAttribute).utf16.count
    var r = CFRange(location: 0, length: len)
    let rv = AXValueCreate(.cfRange, &r)!
    print("focus=\(AXUIElementSetAttributeValue(f, kAXFocusedAttribute as CFString, kCFBooleanTrue).rawValue) range=\(AXUIElementSetAttributeValue(f, kAXSelectedTextRangeAttribute as CFString, rv).rawValue) insert=\(AXUIElementSetAttributeValue(f, kAXSelectedTextAttribute as CFString, text as CFString).rawValue) now_len=\(str(f, kAXValueAttribute).count)")
}
if a[1] == "edit" {
    walk(win, 0) { str($0, kAXRoleAttribute) == "AXTextField" && str($0, kAXValueAttribute).contains(a[2]) }
    guard let f = found, let g = parent(f).flatMap(parent) else { print("no edit field"); exit(2) }
    replaceAll(f, a[3])
    let btns = (attr(g, kAXChildrenAttribute) as? [AXUIElement] ?? []).filter { str($0, kAXDescriptionAttribute) == (a.count > 4 ? a[4] : "Send edit") }
    if let b = btns.first { print("press=\(AXUIElementPerformAction(b, kAXPressAction as CFString).rawValue)") }
} else {
    walk(win, 0) { str($0, "AXIdentifier") == "messageBodyField" }
    guard let f = found, let entry = parent(f) else { print("no composer"); exit(2) }
    replaceAll(f, a[2])
    for k in (attr(entry, kAXChildrenAttribute) as? [AXUIElement] ?? []) { print("\(str(k, kAXRoleAttribute)) desc=\(str(k, kAXDescriptionAttribute))") }
}
