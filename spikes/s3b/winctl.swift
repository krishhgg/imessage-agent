// winctl close|menu-list|menu <title>|hide|state: window-level controls on Messages, for S3b.
import AppKit
import ApplicationServices
let a = CommandLine.arguments
guard let m = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MobileSMS").first else { print("not running"); exit(1) }
let ax = AXUIElementCreateApplication(m.processIdentifier)
func attr(_ e: AXUIElement, _ k: String) -> CFTypeRef? { var v: CFTypeRef?; return AXUIElementCopyAttributeValue(e, k as CFString, &v) == .success ? v : nil }
func kids(_ e: AXUIElement) -> [AXUIElement] { attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
let wins = attr(ax, kAXWindowsAttribute) as? [AXUIElement] ?? []
switch a[1] {
case "state": print("hidden=\(m.isHidden) active=\(m.isActive) ax_windows=\(wins.count)")
case "hide": print("hide=\(m.hide())")
case "unhide": print("unhide=\(m.unhide())")
case "tree":
    var ids: [String: Int] = [:]
    func walk(_ e: AXUIElement, _ d: Int) { if d > 30 { return }; if let i = attr(e, "AXIdentifier") as? String, !i.isEmpty { ids[i, default: 0] += 1 }; for c in kids(e) { walk(c, d + 1) } }
    for w in wins { walk(w, 0) }
    for k in ["TranscriptCollectionView", "Sticker", "MessageEntryView", "messageBodyField"] { print("\(k)=\(ids[k] ?? 0)") }
case "close":
    guard let w = wins.first, let b = attr(w, kAXCloseButtonAttribute) else { print("no window"); exit(2) }
    print("close=\(AXUIElementPerformAction(b as! AXUIElement, kAXPressAction as CFString).rawValue)")
case "menu-list", "menu":
    guard let bar = attr(ax, kAXMenuBarAttribute) else { print("no menubar"); exit(2) }
    for top in kids(bar as! AXUIElement) where (attr(top, kAXTitleAttribute) as? String) == "Window" {
        for menu in kids(top) { for it in kids(menu) {
            let t = attr(it, kAXTitleAttribute) as? String ?? "", en = attr(it, kAXEnabledAttribute) as? Bool ?? false
            if a[1] == "menu-list" { if !t.isEmpty { print("\(t) enabled=\(en)") } }
            else if t == a[2] { print("press=\(AXUIElementPerformAction(it, kAXPressAction as CFString).rawValue) enabled=\(en)") }
        } }
    }
default: print("usage")
}
