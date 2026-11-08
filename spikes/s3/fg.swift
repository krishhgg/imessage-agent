// fg cancel-edit <token> | reply <token> <text> | edit <token> <text>
// Brings Messages forward only for the action, then hides it and restores the previous app.
// Refuses to run if the user typed or clicked in the last 2 s.
import ApplicationServices
import AppKit
let a = CommandLine.arguments
func attr(_ e: AXUIElement, _ n: String) -> CFTypeRef? { var v: CFTypeRef?; return AXUIElementCopyAttributeValue(e, n as CFString, &v) == .success ? v : nil }
func str(_ e: AXUIElement, _ n: String) -> String { attr(e, n) as? String ?? "" }
func parent(_ e: AXUIElement) -> AXUIElement? { attr(e, kAXParentAttribute).map { $0 as! AXUIElement } }
func first(_ e: AXUIElement, _ d: Int = 0, _ p: (AXUIElement) -> Bool) -> AXUIElement? {
    if p(e) { return e }; if d > 40 { return nil }
    for c in (attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? []) { if let r = first(c, d + 1, p) { return r } }
    return nil
}
func named(_ e: AXUIElement, _ action: String) -> Int32 {
    var names: CFArray?; AXUIElementCopyActionNames(e, &names)
    guard let full = (names as? [String] ?? []).first(where: { $0 == action || $0.hasPrefix("Name:\(action)\n") }) else { return -1 }
    return AXUIElementPerformAction(e, full as CFString).rawValue
}
let idle = min(CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown),
               CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDown))
if idle < 2 { print("abort: user active \(String(format: "%.1f", idle))s ago"); exit(5) }
let msgs = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MobileSMS").first!
let prev = NSWorkspace.shared.frontmostApplication
let pid = msgs.processIdentifier
let ax = AXUIElementCreateApplication(pid)
guard let win = (attr(ax, kAXWindowsAttribute) as? [AXUIElement])?.first else { print("no window"); exit(2) }
func key(_ code: CGKeyCode) {
    let src = CGEventSource(stateID: .privateState)
    for down in [true, false] { CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)!.postToPid(pid) }
}
let t0 = Date()
func lsActivate(_ app: NSRunningApplication) {
    guard let bid = app.bundleIdentifier else { return }
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/open"); p.arguments = ["-b", bid]
    try? p.run(); p.waitUntilExit()
}
lsActivate(msgs)
for _ in 0..<60 where NSWorkspace.shared.frontmostApplication?.processIdentifier != pid { usleep(25_000) }
usleep(150_000)
var out = "front_ok=\(NSWorkspace.shared.frontmostApplication?.processIdentifier == pid)"
switch a[1] {
case "cancel-edit":
    key(53) // Escape
    out += " escape_sent"
case "reply":
    guard let b = first(win, 0, { str($0, "AXIdentifier") == "Sticker" && str($0, kAXDescriptionAttribute).contains(a[2]) }) else { out += " no bubble"; break }
    out += " reply_action=\(named(b, "Reply…"))"
    usleep(300_000)
    if let f = first(win, 0, { str($0, "AXIdentifier") == "messageBodyField" }) {
        AXUIElementSetAttributeValue(f, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        out += " set=\(AXUIElementSetAttributeValue(f, kAXValueAttribute as CFString, a[3] as CFString).rawValue)"
        usleep(150_000); key(36)
        out += " return_sent"
    } else {
        // Reply may use its own field in a popover
        let fields = (attr(ax, kAXFocusedUIElementAttribute)).map { $0 as! AXUIElement }
        if let f = fields { out += " focused_role=\(str(f, kAXRoleAttribute)) set=\(AXUIElementSetAttributeValue(f, kAXValueAttribute as CFString, a[3] as CFString).rawValue)"; usleep(150_000); key(36); out += " return_sent" }
    }
case "probe-reply":
    guard let b = first(win, 0, { str($0, "AXIdentifier") == "Sticker" && str($0, kAXDescriptionAttribute).contains(a[2]) }) else { out += " no bubble"; break }
    out += " reply_action=\(named(b, "Reply…"))"
    usleep(600_000)
    if let f = attr(ax, kAXFocusedUIElementAttribute) { let e = f as! AXUIElement; out += " focused=\(str(e, kAXRoleAttribute)) id=\(str(e, "AXIdentifier")) desc=\(str(e, kAXDescriptionAttribute)) vlen=\(str(e, kAXValueAttribute).count)" }
    let wins = attr(ax, kAXWindowsAttribute) as? [AXUIElement] ?? []
    out += " windows=\(wins.count)"
    for w in wins { var n = 0; func cnt(_ e: AXUIElement, _ d: Int) { if d > 40 { return }; let r = str(e, kAXRoleAttribute); if r == "AXTextField" || r == "AXTextArea" && str(e, "AXIdentifier") != "CKBalloonTextView" { n += 1; out += " [field \(r) id=\(str(e, "AXIdentifier")) desc=\(str(e, kAXDescriptionAttribute))]" }; for c in (attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? []) { cnt(c, d + 1) } }; cnt(w, 0) }
    key(53)
case "reply-menu":
    guard let b = first(win, 0, { str($0, "AXIdentifier") == "Sticker" && str($0, kAXDescriptionAttribute).contains(a[2]) }) else { out += " no bubble"; break }
    let tv = first(b, 0, { str($0, "AXIdentifier") == "CKBalloonTextView" }) ?? b
    out += " select=\(AXUIElementPerformAction(tv, kAXPressAction as CFString).rawValue)"
    usleep(250_000)
    if let mb = attr(ax, kAXMenuBarAttribute).map({ $0 as! AXUIElement }),
       let item = first(mb, 0, { str($0, kAXTitleAttribute).hasPrefix("Reply to ") }) {
        let en = attr(item, kAXEnabledAttribute) as? Bool ?? false
        out += " menu=\(str(item, kAXTitleAttribute)) enabled=\(en)"
        if en { out += " menu_press=\(AXUIElementPerformAction(item, kAXPressAction as CFString).rawValue)" }
    } else { out += " no menu item" }
    usleep(900_000)
    if let f = attr(ax, kAXFocusedUIElementAttribute) { let e = f as! AXUIElement; out += " focused=\(str(e, kAXRoleAttribute)) id=\(str(e, "AXIdentifier")) desc=\(str(e, kAXDescriptionAttribute))"
        if str(e, kAXRoleAttribute) == "AXTextField" && str(e, kAXDescriptionAttribute) != "Search" {
            out += " set=\(AXUIElementSetAttributeValue(e, kAXValueAttribute as CFString, a[3] as CFString).rawValue)"; usleep(150_000); key(36); out += " return_sent"
        } else { key(53); out += " not_reply_mode escape" }
    }
case "edit":
    key(53); usleep(400_000)
    var found: AXUIElement?
    for _ in 0..<20 {
        let w = (attr(ax, kAXWindowsAttribute) as? [AXUIElement])?.first ?? win
        found = first(w, 0, { str($0, "AXIdentifier") == "Sticker" && str($0, kAXDescriptionAttribute).contains(a[2]) })
        if found != nil { break }; usleep(100_000)
    }
    guard let b = found else { out += " no bubble"; break }
    out += " edit_action=\(named(b, "Edit"))"
    usleep(300_000)
    if let f = first(win, 0, { str($0, kAXRoleAttribute) == "AXTextField" && str($0, kAXValueAttribute).contains(a[2]) && str($0, "AXIdentifier") != "messageBodyField" }) {
        AXUIElementSetAttributeValue(f, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        out += " set=\(AXUIElementSetAttributeValue(f, kAXValueAttribute as CFString, a[3] as CFString).rawValue)"
        usleep(150_000); key(36)
        out += " return_sent"
    } else { out += " no edit field" }
default: break
}
usleep(400_000)
msgs.hide()
if let p = prev { lsActivate(p) }
for _ in 0..<40 where NSWorkspace.shared.frontmostApplication?.processIdentifier != prev?.processIdentifier { usleep(25_000) }
print(out + " away_ms=\(Int(Date().timeIntervalSince(t0) * 1000)) restored=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
