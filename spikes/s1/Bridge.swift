// S1 spike bridge. Answers one command per connection on a launchd-owned
// Unix socket so we can see which process macOS charges for TCC access.
// Ops never return message content, only counts and status codes.
import AppKit
import ApplicationServices
import Foundation
import SQLite3

let buildTag = "S1-BUILD-1"
let label = "local.imessageagent.spike"

@_silgen_name("launch_activate_socket")
func launch_activate_socket(_ name: UnsafePointer<CChar>,
                            _ fds: UnsafeMutablePointer<UnsafeMutablePointer<Int32>?>,
                            _ cnt: UnsafeMutablePointer<Int>) -> Int32

typealias RespFn = @convention(c) (pid_t) -> pid_t

func responsiblePid(_ pid: pid_t) -> pid_t {
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return -1 }
    return unsafeBitCast(sym, to: RespFn.self)(pid)
}

func pathFor(pid: pid_t) -> String {
    var buf = [CChar](repeating: 0, count: 4096)
    let n = proc_pidpath(pid, &buf, UInt32(buf.count))
    return n > 0 ? String(cString: buf) : "?"
}

func designatedRequirement() -> String {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let c = code else { return "?" }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(c, [], &staticCode) == errSecSuccess, let s = staticCode else { return "?" }
    var req: SecRequirement?
    guard SecCodeCopyDesignatedRequirement(s, [], &req) == errSecSuccess, let r = req else { return "?" }
    var str: CFString?
    SecRequirementCopyString(r, [], &str)
    return (str as String?) ?? "?"
}

let chatDB = NSHomeDirectory() + "/Library/Messages/chat.db"

func opWhoami() -> String {
    let me = getpid()
    let rp = responsiblePid(me)
    return "build=\(buildTag) pid=\(me) ppid=\(getppid()) responsible=\(rp) responsible_path=\(pathFor(pid: rp)) bundle=\(Bundle.main.bundleIdentifier ?? "?") dr=\(designatedRequirement())"
}

func opStatus() -> String {
    var parts: [String] = []
    let fd = open(chatDB, O_RDONLY)
    if fd >= 0 { parts.append("open=ok"); close(fd) } else { parts.append("open=errno\(errno)") }
    var db: OpaquePointer?
    let uri = "file:\(chatDB)?mode=ro"
    let rc = sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
    if rc != SQLITE_OK {
        parts.append("sqlite_open=\(rc)")
        sqlite3_close(db)
        return parts.joined(separator: " ")
    }
    sqlite3_limit(db, SQLITE_LIMIT_ATTACHED, 0)
    var stmt: OpaquePointer?
    if sqlite3_prepare_v2(db, "SELECT count(*) FROM message", -1, &stmt, nil) == SQLITE_OK,
       sqlite3_step(stmt) == SQLITE_ROW {
        parts.append("message_rows=\(sqlite3_column_int64(stmt, 0))")
    } else {
        parts.append("query_err=\(String(cString: sqlite3_errmsg(db)))")
    }
    sqlite3_finalize(stmt)
    sqlite3_close(db)
    return parts.joined(separator: " ")
}

func ensureMessagesRunning() -> Bool {
    if !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MobileSMS").isEmpty { return true }
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.MobileSMS") else { return false }
    let cfg = NSWorkspace.OpenConfiguration()
    cfg.activates = false
    let sem = DispatchSemaphore(value: 0)
    NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in sem.signal() }
    _ = sem.wait(timeout: .now() + 15)
    Thread.sleep(forTimeInterval: 2)
    return !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MobileSMS").isEmpty
}

// Asks TCC (and the user, if undecided) whether we may send Apple Events to Messages.
func opAE() -> String {
    guard ensureMessagesRunning() else { return "ae=messages_not_running" }
    let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.MobileSMS")
    let st = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, true)
    return "ae_permission=\(st)"
}

// Runs a harmless read-only script: number of accounts.
func opAEScript() -> String {
    var out = ""
    DispatchQueue.main.sync {
        var err: NSDictionary?
        let s = NSAppleScript(source: "tell application id \"com.apple.MobileSMS\" to count accounts")
        let r = s?.executeAndReturnError(&err)
        if let e = err { out = "script_err=\(e[NSAppleScript.errorNumber] ?? "?")" } else { out = "accounts=\(r?.int32Value ?? -1)" }
    }
    return out
}

func opAX(prompt: Bool) -> String {
    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
    return "ax_trusted=\(AXIsProcessTrustedWithOptions(opts))"
}

// S3 confirmation: perform a named AX action on the one bubble whose description holds a
// test token. Only tokens starting with "s3-" are accepted, so it can't touch other messages.
func axAttr(_ e: AXUIElement, _ a: String) -> CFTypeRef? { var v: CFTypeRef?; return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil }
func axStr(_ e: AXUIElement, _ a: String) -> String { axAttr(e, a) as? String ?? "" }

func opReact(token: String, action: String) -> String {
    guard token.hasPrefix("s3-") else { return "err token_not_test" }
    guard AXIsProcessTrusted() else { return "err ax_not_trusted" }
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MobileSMS").first else { return "err messages_not_running" }
    var hits: [AXUIElement] = []
    func walk(_ e: AXUIElement, _ d: Int) {
        if d > 40 { return }
        if axStr(e, "AXIdentifier") == "Sticker" && axStr(e, kAXDescriptionAttribute).contains(token) { hits.append(e) }
        for c in (axAttr(e, kAXChildrenAttribute) as? [AXUIElement] ?? []) { walk(c, d + 1) }
    }
    let ax = AXUIElementCreateApplication(app.processIdentifier)
    for w in (axAttr(ax, kAXWindowsAttribute) as? [AXUIElement] ?? []) { walk(w, 0) }
    guard hits.count == 1, let el = hits.first else { return "err matches=\(hits.count)" }
    var names: CFArray?; AXUIElementCopyActionNames(el, &names)
    guard let full = (names as? [String] ?? []).first(where: { $0 == "Name:\(action)" || $0.hasPrefix("Name:\(action)\n") }) else { return "err no_action" }
    let rc = AXUIElementPerformAction(el, full as CFString)
    return "perform=\(rc.rawValue) hidden=\(app.isHidden) frontmost=\(app.isActive)"
}

final class PanelController: NSObject {
    var result = "timeout"
    var panel: NSPanel?
    let done = DispatchSemaphore(value: 0)

    func show() {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 150),
                        styleMask: [.titled, .nonactivatingPanel, .utilityWindow],
                        backing: .buffered, defer: false)
        p.title = "iMessage Agent Spike"
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        let label = NSTextField(wrappingLabelWithString: "Test approval panel. Is this visible over your current app? Click a button.")
        label.frame = NSRect(x: 20, y: 60, width: 340, height: 60)
        let deny = NSButton(title: "Deny", target: self, action: #selector(denyClicked))
        deny.frame = NSRect(x: 180, y: 15, width: 80, height: 32)
        deny.keyEquivalent = "\u{1b}"
        let allow = NSButton(title: "Allow once", target: self, action: #selector(allowClicked))
        allow.frame = NSRect(x: 270, y: 15, width: 95, height: 32)
        allow.isEnabled = false
        p.contentView?.addSubview(label)
        p.contentView?.addSubview(deny)
        p.contentView?.addSubview(allow)
        p.center()
        p.orderFrontRegardless()
        panel = p
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { allow.isEnabled = true }
    }

    @objc func denyClicked() { finish("deny") }
    @objc func allowClicked() { finish("allow") }

    func finish(_ r: String) {
        result = r
        panel?.orderOut(nil)
        done.signal()
    }
}

func opPanel() -> String {
    let pc = PanelController()
    DispatchQueue.main.async { pc.show() }
    if pc.done.wait(timeout: .now() + 90) == .timedOut {
        DispatchQueue.main.sync { pc.panel?.orderOut(nil) }
    }
    return "panel=\(pc.result)"
}

// ---- S2 ops: self-chat sends and row-shape inspection ----

func withDB<T>(_ body: (OpaquePointer) -> T) -> T? {
    var db: OpaquePointer?
    guard sqlite3_open_v2("file:\(chatDB)?mode=ro", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let d = db else {
        sqlite3_close(db); return nil
    }
    sqlite3_limit(d, SQLITE_LIMIT_ATTACHED, 0)
    sqlite3_busy_timeout(d, 2000)
    defer { sqlite3_close(d) }
    return body(d)
}

func scalar(_ db: OpaquePointer, _ sql: String) -> Int64 {
    var st: OpaquePointer?
    defer { sqlite3_finalize(st) }
    guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, sqlite3_step(st) == SQLITE_ROW else { return -1 }
    return sqlite3_column_int64(st, 0)
}

func opSnap() -> String {
    withDB { db in "max_rowid=\(scalar(db, "SELECT ifnull(max(ROWID),0) FROM message")) max_att=\(scalar(db, "SELECT ifnull(max(ROWID),0) FROM attachment"))" } ?? "err db"
}

// Metadata for rows newer than snap. Rows outside the self chat print only their rowid.
func opRows(snap: Int64, handle: String, token: String) -> String {
    withDB { db in
        let sql = """
        SELECT m.ROWID, substr(m.guid,1,8), m.is_from_me, m.is_sent, m.is_delivered, m.is_finished, m.is_read,
               m.error, ifnull(m.service,''), m.item_type, m.associated_message_type, m.text IS NULL,
               ifnull(length(m.attributedBody),0), ifnull(instr(m.attributedBody, ?2),0) > 0 OR ifnull(instr(m.text, ?2),0) > 0,
               m.date_delivered > 0, m.cache_has_attachments, ifnull(h.id,''), ifnull(c.chat_identifier,''),
               ifnull(m.destination_caller_id,'') = ?1, m.date, m.date_delivered, ifnull(m.thread_originator_guid,'') <> ''
        FROM message m
        LEFT JOIN handle h ON h.ROWID = m.handle_id
        LEFT JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        LEFT JOIN chat c ON c.ROWID = cmj.chat_id
        WHERE m.ROWID > ?3 ORDER BY m.ROWID
        """
        var st: OpaquePointer?
        defer { sqlite3_finalize(st) }
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return "err \(String(cString: sqlite3_errmsg(db)))" }
        let T = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(st, 1, handle, -1, T)
        sqlite3_bind_blob(st, 2, token, Int32(token.utf8.count), T)
        sqlite3_bind_int64(st, 3, snap)
        var lines: [String] = []
        while sqlite3_step(st) == SQLITE_ROW {
            let i = { (c: Int32) in sqlite3_column_int64(st, c) }
            let s = { (c: Int32) in String(cString: sqlite3_column_text(st, c)) }
            let chatID = s(17).lowercased(), hid = s(16).lowercased()
            if chatID != handle.lowercased() && hid != handle.lowercased() { lines.append("rowid=\(i(0)) other"); continue }
            let dd = i(20) > 0 ? String(format: "%.1f", Double(i(20) - i(19)) / 1e9) : "-"
            lines.append("rowid=\(i(0)) guid=\(s(1)) from_me=\(i(2)) sent=\(i(3)) delivered=\(i(4)) finished=\(i(5)) read=\(i(6)) err=\(i(7)) svc=\(s(8)) item=\(i(9)) assoc=\(i(10)) text_null=\(i(11)) ab=\(i(12)) match=\(i(13)) has_att=\(i(15)) handle_is_self=\(hid == handle.lowercased()) chat=\(chatID == handle.lowercased() ? "self" : "?") dest_is_self=\(i(18)) deliver_s=\(dd) reply=\(i(21))")
        }
        return lines.isEmpty ? "rows=none" : lines.joined(separator: " | ")
    } ?? "err db"
}

func opAtts(snap: Int64) -> String {
    withDB { db in
        var st: OpaquePointer?
        defer { sqlite3_finalize(st) }
        let sql = "SELECT a.ROWID, a.transfer_state, ifnull(a.mime_type,''), a.total_bytes, ifnull(a.transfer_name,''), a.is_outgoing, ifnull(maj.message_id,0), ifnull(a.filename,'') FROM attachment a LEFT JOIN message_attachment_join maj ON maj.attachment_id = a.ROWID WHERE a.ROWID > ?1"
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return "err" }
        sqlite3_bind_int64(st, 1, snap)
        var out: [String] = []
        while sqlite3_step(st) == SQLITE_ROW {
            let name = String(cString: sqlite3_column_text(st, 4))
            let fn = String(cString: sqlite3_column_text(st, 7))
            guard name.hasPrefix("s2-") else { out.append("att=\(sqlite3_column_int64(st, 0)) other"); continue }
            out.append("att=\(sqlite3_column_int64(st, 0)) state=\(sqlite3_column_int64(st, 1)) mime=\(String(cString: sqlite3_column_text(st, 2))) bytes=\(sqlite3_column_int64(st, 3)) name=\(name) out=\(sqlite3_column_int64(st, 5)) msg=\(sqlite3_column_int64(st, 6)) stored=\(fn.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")
        }
        return out.isEmpty ? "atts=none" : out.joined(separator: " | ")
    } ?? "err db"
}

func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }

// Calls an AppleScript handler with string arguments passed as descriptors (no source interpolation).
func callHandler(_ source: String, _ name: String, _ args: [String]) -> String {
    var out = ""
    DispatchQueue.main.sync {
        var err: NSDictionary?
        guard let script = NSAppleScript(source: source), script.compileAndReturnError(&err) else { out = "compile_err"; return }
        let params = NSAppleEventDescriptor.list()
        for (i, a) in args.enumerated() { params.insert(NSAppleEventDescriptor(string: a), at: i + 1) }
        let ev = NSAppleEventDescriptor.appleEvent(withEventClass: fourCC("ascr"), eventID: fourCC("psbr"),
                                                   targetDescriptor: NSAppleEventDescriptor(processIdentifier: getpid()),
                                                   returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        ev.setDescriptor(NSAppleEventDescriptor(string: name.lowercased()), forKeyword: fourCC("snam"))
        ev.setDescriptor(params, forKeyword: fourCC("----"))
        let t0 = Date()
        let r = script.executeAppleEvent(ev, error: &err)
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        if let e = err { out = "as_err=\(e[NSAppleScript.errorNumber] ?? "?") msg=\((e[NSAppleScript.errorMessage] as? String ?? "").prefix(120)) ms=\(ms)" }
        else { out = "as_ok result=\(r.stringValue ?? "-") ms=\(ms)" }
    }
    return out
}

let sendScript = """
on send_text(h, t)
  tell application id "com.apple.MobileSMS"
    set s to 1st account whose service type = iMessage
    send t to participant h of s
  end tell
  return "sent"
end send_text

on send_file(h, p)
  set f to POSIX file p as alias
  tell application id "com.apple.MobileSMS"
    set s to 1st account whose service type = iMessage
    send f to participant h of s
  end tell
  return "sent"
end send_file

on quit_messages()
  tell application id "com.apple.MobileSMS" to quit
  return "quit"
end quit_messages
"""

func stagingDir(_ kind: String) -> String? {
    switch kind {
    case "tmp": return "/private/var/tmp/com.apple.messages/iMessageAgentSpike"
    case "pictures": return NSHomeDirectory() + "/Pictures/iMessageAgentSpike"
    case "attachments": return NSHomeDirectory() + "/Library/Messages/Attachments/iMessageAgentSpike"
    case "downloads": return NSHomeDirectory() + "/Downloads/iMessageAgentSpike"
    default: return nil
    }
}

func opSendFile(handle: String, kind: String, token: String) -> String {
    guard let dir = stagingDir(kind) else { return "err kind" }
    do { try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }
    catch { return "mkdir_err=\((error as NSError).code)" }
    let path = dir + "/\(token).txt"
    guard FileManager.default.createFile(atPath: path, contents: "spike file \(token)\n".data(using: .utf8)) else { return "write_err" }
    return "staged=\(kind) " + callHandler(sendScript, "send_file", [handle, path])
}

func handle(_ cmd: String) -> String {
    let f = cmd.components(separatedBy: "\t")
    switch f[0] {
    case "snap": return opSnap()
    case "send" where f.count == 3: return callHandler(sendScript, "send_text", [f[1], f[2]])
    case "sendfile" where f.count == 4: return opSendFile(handle: f[1], kind: f[2], token: f[3])
    case "rows" where f.count == 4: return opRows(snap: Int64(f[1]) ?? 0, handle: f[2], token: f[3])
    case "atts" where f.count == 2: return opAtts(snap: Int64(f[1]) ?? 0)
    case "quit-messages": return callHandler(sendScript, "quit_messages", [])
    case "react" where f.count == 3: return opReact(token: f[1], action: f[2])
    case "messages-running": return "running=\(!NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MobileSMS").isEmpty)"
    default: break
    }
    switch cmd {
    case "ping": return "pong \(buildTag)"
    case "whoami": return opWhoami()
    case "status": return opStatus()
    case "ae": return opAE()
    case "ae-script": return opAEScript()
    case "ax": return opAX(prompt: false)
    case "ax-prompt": return opAX(prompt: true)
    case "panel": return opPanel()
    case "quit":
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exit(0) }
        return "bye"
    default: return "err unknown_op"
    }
}

func readLine(fd: Int32) -> String {
    var data = [UInt8]()
    var byte: UInt8 = 0
    while data.count < 4096 {
        let n = read(fd, &byte, 1)
        if n <= 0 || byte == 10 { break }
        data.append(byte)
    }
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespaces)
}

func serve(listenFD: Int32) {
    let q = DispatchQueue(label: "accept")
    let src = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: q)
    src.setEventHandler {
        let c = accept(listenFD, nil, nil)
        guard c >= 0 else { return }
        var uid: uid_t = 0, gid: gid_t = 0
        if getpeereid(c, &uid, &gid) != 0 || uid != getuid() { close(c); return }
        DispatchQueue.global().async {
            let reply = handle(readLine(fd: c)) + "\n"
            _ = reply.withCString { write(c, $0, strlen($0)) }
            close(c)
        }
    }
    src.resume()
    listenSource = src
}

var listenSource: DispatchSourceRead?

var fdsPtr: UnsafeMutablePointer<Int32>?
var cnt = 0
let rc = launch_activate_socket("Listener", &fdsPtr, &cnt)
if rc != 0 || cnt == 0 {
    // Launched outside launchd (Finder, open). Hand off: kick the launchd job and exit.
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = ["kickstart", "gui/\(getuid())/\(label)"]
    try? p.run()
    p.waitUntilExit()
    FileHandle.standardError.write("not launched by launchd (rc=\(rc)); kicked job and exiting\n".data(using: .utf8)!)
    exit(0)
}
let listenFD = fdsPtr![0]
free(fdsPtr)
serve(listenFD: listenFD)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.run()
