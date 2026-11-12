// Synthetic input for release test 5, the foreground abort path (DESIGN.md "Release tests" item 5).
//
// Usage:
//   hid-inject <event> <trigger> [--delay-ms N] [--timeout-ms N] [--out FILE]
//
// Events, posted at the HID event tap so they reach the HID system state the bridge reads:
//   modifier    Shift down and up
//   letter      the x key down and up
//   click       left button down and up at the pointer's current position
//   app-switch  Command-Tab
//
// Triggers (exactly one):
//   --when-front BUNDLE              BUNDLE becomes the front app
//   --when-left BUNDLE               BUNDLE was in front and no longer is
//   --when-log FILE --pattern REGEX  a line matching REGEX is appended to FILE after the start
//
// After the trigger it waits --delay-ms (default 0), posts the event and prints one JSON line with wall_ms (Unix
// time in ms) of the trigger and of the first posted event. --timeout-ms (default 120000) gives up when the
// trigger never comes. The process that runs it needs Accessibility to post events.
// Exit status: 0 posted, 2 usage or no permission to post, 3 trigger not seen.
import AppKit
import CoreGraphics
import Foundation

func usageExit(_ message: String) -> Never {
    FileHandle.standardError.write(Data("""
    error: \(message)
    usage: hid-inject modifier|letter|click|app-switch (--when-front BUNDLE | --when-left BUNDLE | --when-log FILE --pattern REGEX) [--delay-ms N] [--timeout-ms N] [--out FILE]

    """.utf8))
    exit(2)
}

enum Trigger {
    case front(String)
    case left(String)
    case log(path: String, pattern: NSRegularExpression)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let event = args.first, ["modifier", "letter", "click", "app-switch"].contains(event) else {
    usageExit("the first argument is modifier, letter, click or app-switch")
}
args.removeFirst()

var trigger: Trigger?
var logPath: String?
var pattern: String?
var delayMs = 0
var timeoutMs = 120_000
var outPath: String?
func value(_ flag: String) -> String {
    guard !args.isEmpty else { usageExit("\(flag) needs a value") }
    return args.removeFirst()
}
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--when-front": trigger = .front(value(a))
    case "--when-left": trigger = .left(value(a))
    case "--when-log": logPath = value(a)
    case "--pattern": pattern = value(a)
    case "--delay-ms":
        guard let n = Int(value(a)), n >= 0 else { usageExit("--delay-ms needs a number") }
        delayMs = n
    case "--timeout-ms":
        guard let n = Int(value(a)), n > 0 else { usageExit("--timeout-ms needs a positive number") }
        timeoutMs = n
    case "--out": outPath = value(a)
    default: usageExit("unknown argument \(a)")
    }
}
if let logPath {
    guard trigger == nil, let pattern, !pattern.isEmpty else { usageExit("--when-log needs --pattern and no other trigger") }
    guard let regex = try? NSRegularExpression(pattern: pattern) else { usageExit("--pattern isn't a valid regular expression") }
    trigger = .log(path: logPath, pattern: regex)
} else if pattern != nil {
    usageExit("--pattern needs --when-log")
}
guard let trigger else { usageExit("give one trigger") }

guard CGPreflightPostEventAccess() else {
    usageExit("this process can't post events fix: give the terminal app Accessibility in System Settings, Privacy & Security")
}

func nowMs() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }
func frontBundle() -> String {
    RunLoop.current.run(until: Date())
    return NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
}

/// Polls every 2 ms until the trigger fires. Returns its wall time, or nil on timeout.
func waitForTrigger() -> Int64? {
    let start = nowMs()
    var seenFront = false
    var handle: FileHandle?
    var buffer = Data()
    if case .log(let path, _) = trigger {
        guard let h = FileHandle(forReadingAtPath: path) else { usageExit("can't read \(path)") }
        h.seekToEndOfFile()
        handle = h
    }
    while nowMs() - start < Int64(timeoutMs) {
        switch trigger {
        case .front(let b):
            if frontBundle() == b { return nowMs() }
        case .left(let b):
            let f = frontBundle()
            if f == b { seenFront = true } else if seenFront { return nowMs() }
        case .log(_, let p):
            if let h = handle {
                buffer.append(h.readDataToEndOfFile())
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
                    buffer.removeSubrange(buffer.startIndex...nl)
                    if p.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil { return nowMs() }
                }
            }
        }
        usleep(2_000)
    }
    return nil
}

let source = CGEventSource(stateID: .hidSystemState)

func key(_ code: CGKeyCode, down: Bool, flags: CGEventFlags = [], type: CGEventType? = nil) {
    guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
    e.flags = flags
    if let type { e.type = type }
    e.post(tap: .cghidEventTap)
}

func post(_ name: String) {
    let shift: CGKeyCode = 56, x: CGKeyCode = 7, command: CGKeyCode = 55, tab: CGKeyCode = 48
    switch name {
    case "modifier":
        key(shift, down: true, flags: .maskShift, type: .flagsChanged)
        usleep(30_000)
        key(shift, down: false, flags: [], type: .flagsChanged)
    case "letter":
        key(x, down: true)
        usleep(30_000)
        key(x, down: false)
    case "click":
        let at = CGEvent(source: nil)?.location ?? .zero
        CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: at, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        usleep(30_000)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: at, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    default:
        key(command, down: true, flags: .maskCommand, type: .flagsChanged)
        usleep(30_000)
        key(tab, down: true, flags: .maskCommand)
        usleep(30_000)
        key(tab, down: false, flags: .maskCommand)
        usleep(30_000)
        key(command, down: false, flags: [], type: .flagsChanged)
    }
}

func describe(_ t: Trigger) -> String {
    switch t {
    case .front(let b): return "front \(b)"
    case .left(let b): return "left \(b)"
    case .log(_, let p): return "log \(p.pattern)"
    }
}

func write(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
    let line = String(decoding: data, as: UTF8.self) + "\n"
    print(line, terminator: "")
    if let outPath {
        if !FileManager.default.fileExists(atPath: outPath) { FileManager.default.createFile(atPath: outPath, contents: nil) }
        if let h = FileHandle(forWritingAtPath: outPath) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        }
    }
}

guard let fired = waitForTrigger() else {
    write(["type": "inject", "event": event, "trigger": describe(trigger), "result": "trigger not seen"])
    exit(3)
}
if delayMs > 0 { usleep(useconds_t(delayMs) * 1000) }
let postedAt = nowMs()
post(event)
write(["type": "inject", "event": event, "trigger": describe(trigger), "trigger_ms": fired, "wall_ms": postedAt,
       "result": "posted"])
exit(0)
