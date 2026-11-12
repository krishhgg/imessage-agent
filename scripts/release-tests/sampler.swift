// Release-test sampler, adapted from spikes/s3b/vis.swift (DESIGN.md "Release tests", docs/BUILD-PLAN.md
// "Release-test harness").
//
// Usage:
//   sampler --out FILE [--mode hidden|foreground] [--duration-ms N] [--ready FILE] [--also BUNDLE]
//
// It runs as its own process next to the bridge and samples every 10 ms until SIGTERM, SIGINT or --duration-ms
// (default 180000). Each sample counts every on-screen window owned by Messages, at any layer and size, and records
// the front app by bundle id and the last HID input time (key, flags, mouse button and scroll events from
// hidSystemState). It writes JSON lines to --out with only pids, bounds, layers, bundle ids and times. It never
// reads window titles or content.
//
// Lines: start, messages_app, messages_windows, front, input, also, gap, and a final summary. Each has wall_ms
// (Unix time in ms). --ready FILE is created once the first sample is written, so a script can wait for it.
// --also BUNDLE also tracks that app's layer-0 window count, on screen and in total, every 100 ms.
//
// Verdicts, printed to stdout as `verdict <v> <reason>` and in the summary line:
//   hidden mode      pass when no Messages window was on screen and the front app never changed. Each violation
//                    with HID input in the 1 s before it is a rerun instead of a failure.
//   foreground mode  pass when, at the end, Messages has no on-screen window and is hidden, the front app is the one
//                    from the start, and no --also app gained a window. A miss with input after Messages first came
//                    to the front is a rerun.
//   invalid          a gap between samples over 100 ms, no front app at the start, Messages in front at the start,
//                    or a Messages window on screen at the start. The setup didn't hold, so the run says nothing.
// Exit status: 0 pass, 1 fail, 2 usage, 3 rerun, 4 invalid.
import AppKit
import CoreGraphics
import Foundation

let messagesBundle = "com.apple.MobileSMS"

struct Options {
    var out = ""
    var mode = "hidden"
    var durationMs = 180_000
    var ready: String?
    var also: [String] = []
}

func usageExit(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\nusage: sampler --out FILE [--mode hidden|foreground] [--duration-ms N] [--ready FILE] [--also BUNDLE]\n".utf8))
    exit(2)
}

func parseOptions() -> Options {
    var o = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    func value(_ flag: String) -> String {
        guard !args.isEmpty else { usageExit("\(flag) needs a value") }
        return args.removeFirst()
    }
    while !args.isEmpty {
        let a = args.removeFirst()
        switch a {
        case "--out": o.out = value(a)
        case "--mode":
            o.mode = value(a)
            guard o.mode == "hidden" || o.mode == "foreground" else { usageExit("--mode is hidden or foreground") }
        case "--duration-ms":
            guard let n = Int(value(a)), n > 0 else { usageExit("--duration-ms needs a positive number") }
            o.durationMs = n
        case "--ready": o.ready = value(a)
        case "--also": o.also.append(value(a))
        default: usageExit("unknown argument \(a)")
        }
    }
    if o.out.isEmpty { usageExit("--out is required") }
    return o
}

let options = parseOptions()

var stopRequested: sig_atomic_t = 0
signal(SIGTERM) { _ in stopRequested = 1 }
signal(SIGINT) { _ in stopRequested = 1 }

guard FileManager.default.createFile(atPath: options.out, contents: nil),
      let outHandle = FileHandle(forWritingAtPath: options.out) else {
    usageExit("can't write \(options.out)")
}

func emit(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
    outHandle.write(data)
    outHandle.write(Data("\n".utf8))
}

func nowMs() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }

func messagesApps() -> [NSRunningApplication] {
    NSRunningApplication.runningApplications(withBundleIdentifier: messagesBundle)
}

struct WindowInfo: Equatable {
    var pid: Int32
    var layer: Int
    var bounds: [Int]
}

func windowList(_ option: CGWindowListOption) -> [[String: Any]] {
    CGWindowListCopyWindowInfo(option, kCGNullWindowID) as? [[String: Any]] ?? []
}

func info(_ w: [String: Any]) -> WindowInfo? {
    guard let pid = w[kCGWindowOwnerPID as String] as? Int32 else { return nil }
    let layer = w[kCGWindowLayer as String] as? Int ?? 0
    var bounds = [0, 0, 0, 0]
    if let b = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b as CFDictionary) {
        bounds = [Int(r.origin.x), Int(r.origin.y), Int(r.width), Int(r.height)]
    }
    return WindowInfo(pid: pid, layer: layer, bounds: bounds)
}

/// Every on-screen window owned by one of the given pids, at any layer and size.
func onScreenWindows(of pids: Set<Int32>) -> [WindowInfo] {
    guard !pids.isEmpty else { return [] }
    return windowList([.optionOnScreenOnly]).compactMap(info).filter { pids.contains($0.pid) }
}

/// Layer-0 windows of an app by bundle id: (on screen, total).
func windowCounts(bundle: String) -> (onScreen: Int, total: Int) {
    let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundle).map(\.processIdentifier))
    guard !pids.isEmpty else { return (0, 0) }
    let all = windowList([.optionAll]).compactMap(info).filter { pids.contains($0.pid) && $0.layer == 0 }
    let on = onScreenWindows(of: pids).filter { $0.layer == 0 }
    return (on.count, all.count)
}

let inputTypes: [CGEventType] = [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]

/// Wall time in ms of the newest key, flags, mouse button or scroll event in the HID system state.
func lastInputMs(now: Int64) -> Int64 {
    let seconds = inputTypes.map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }.min() ?? 1e9
    return now - Int64((seconds * 1000).rounded())
}

func windowsJSON(_ ws: [WindowInfo]) -> [[String: Any]] {
    ws.map { ["pid": Int($0.pid), "layer": $0.layer, "bounds": $0.bounds] }
}

// Start.
RunLoop.current.run(until: Date())
let t0 = nowMs()
let startFront = NSWorkspace.shared.frontmostApplication
let startFrontBundle = startFront?.bundleIdentifier ?? ""
var lastMessagesPids = Set(messagesApps().map(\.processIdentifier))
var lastHidden = messagesApps().first?.isHidden ?? false
var alsoStart: [String: (onScreen: Int, total: Int)] = [:]
var alsoLast: [String: (onScreen: Int, total: Int)] = [:]
for b in options.also {
    let c = windowCounts(bundle: b)
    alsoStart[b] = c
    alsoLast[b] = c
}
var lastWindows: [WindowInfo] = onScreenWindows(of: lastMessagesPids)
let startWindowCount = lastWindows.count
emit([
    "type": "start", "wall_ms": t0, "mode": options.mode, "front": startFrontBundle, "messages_onscreen": startWindowCount,
    "front_pid": Int(startFront?.processIdentifier ?? 0), "messages_pids": lastMessagesPids.sorted().map(Int.init),
    "messages_hidden": lastHidden,
    "also": options.also.map { ["bundle": $0, "onscreen": alsoStart[$0]!.onScreen, "windows": alsoStart[$0]!.total] },
])

var samples = 0
var maxGap: Int64 = 0
var lastSample = t0
var windowOnMs: Int64 = 0
var firstWindowMs: Int64 = -1
var lastFront = startFrontBundle
var frontChanges: [(ms: Int64, bundle: String)] = []
var windowAppearances: [Int64] = []
var inputs: [Int64] = []
var lastInput = lastInputMs(now: t0)
var firstMessagesFrontMs: Int64 = -1
var lastAlsoCheck: Int64 = 0
if !lastWindows.isEmpty {
    firstWindowMs = 0
    emit(["type": "messages_windows", "wall_ms": t0, "windows": windowsJSON(lastWindows)])
}
if let ready = options.ready {
    FileManager.default.createFile(atPath: ready, contents: Data("\(t0)\n".utf8))
}

while stopRequested == 0 && nowMs() - t0 < Int64(options.durationMs) {
    usleep(10_000)
    RunLoop.current.run(until: Date())
    let now = nowMs()
    samples += 1
    let gap = now - lastSample
    if gap > maxGap { maxGap = gap }
    if gap > 100 { emit(["type": "gap", "wall_ms": now, "ms": gap]) }

    let apps = messagesApps()
    let pids = Set(apps.map(\.processIdentifier))
    let hidden = apps.first?.isHidden ?? false
    if pids != lastMessagesPids || hidden != lastHidden {
        emit(["type": "messages_app", "wall_ms": now, "pids": pids.sorted().map(Int.init), "hidden": hidden])
        lastMessagesPids = pids
        lastHidden = hidden
    }

    let ws = onScreenWindows(of: pids)
    if !ws.isEmpty {
        windowOnMs += gap
        if firstWindowMs < 0 { firstWindowMs = now - t0 }
    }
    if ws != lastWindows {
        if lastWindows.isEmpty && !ws.isEmpty { windowAppearances.append(now) }
        emit(["type": "messages_windows", "wall_ms": now, "windows": windowsJSON(ws)])
        lastWindows = ws
    }

    let front = NSWorkspace.shared.frontmostApplication
    let frontBundle = front?.bundleIdentifier ?? ""
    if frontBundle != lastFront {
        emit(["type": "front", "wall_ms": now, "bundle": frontBundle, "pid": Int(front?.processIdentifier ?? 0)])
        frontChanges.append((now, frontBundle))
        if frontBundle == messagesBundle && firstMessagesFrontMs < 0 { firstMessagesFrontMs = now }
        lastFront = frontBundle
    }

    let li = lastInputMs(now: now)
    if li > lastInput + 20 {
        emit(["type": "input", "wall_ms": li])
        inputs.append(li)
    }
    lastInput = max(lastInput, li)

    if !options.also.isEmpty && now - lastAlsoCheck >= 100 {
        lastAlsoCheck = now
        for b in options.also {
            let c = windowCounts(bundle: b)
            if let l = alsoLast[b], l.onScreen != c.onScreen || l.total != c.total {
                emit(["type": "also", "wall_ms": now, "bundle": b, "onscreen": c.onScreen, "windows": c.total])
            }
            alsoLast[b] = c
        }
    }
    lastSample = now
}

// Summary.
RunLoop.current.run(until: Date())
let tEnd = nowMs()
let endApps = messagesApps()
let endPids = Set(endApps.map(\.processIdentifier))
let endOnScreen = onScreenWindows(of: endPids).count
let endHidden = endApps.isEmpty || endApps.allSatisfy(\.isHidden)
let endFront = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
var alsoGained: [String] = []
for b in options.also {
    let c = windowCounts(bundle: b)
    if c.total > alsoStart[b]!.total { alsoGained.append(b) }
}

func inputWithin(_ ms: Int64, before t: Int64) -> Bool { inputs.contains { $0 <= t && $0 >= t - ms } }

var verdict = "pass"
var reason = "no Messages window on screen and no front-app change"
if startFrontBundle.isEmpty {
    verdict = "invalid"; reason = "no front app at the start"
} else if startFrontBundle == messagesBundle {
    verdict = "invalid"; reason = "Messages was in front at the start"
} else if startWindowCount > 0 {
    verdict = "invalid"; reason = "\(startWindowCount) Messages window(s) on screen at the start"
} else if maxGap > 100 {
    verdict = "invalid"; reason = "a \(maxGap) ms gap between samples"
} else if options.mode == "hidden" {
    let violations = windowAppearances + frontChanges.map(\.ms)
    if !violations.isEmpty {
        let unexplained = violations.filter { !inputWithin(1000, before: $0) }
        if unexplained.isEmpty {
            verdict = "rerun"
            reason = "\(violations.count) window or front-app change(s), each with user input in the 1 s before"
        } else {
            verdict = "fail"
            reason = "\(windowAppearances.count) Messages window appearance(s), \(frontChanges.count) front-app change(s), first at +\(unexplained.min()! - t0) ms"
        }
    }
} else {
    var misses: [String] = []
    if endOnScreen > 0 { misses.append("\(endOnScreen) Messages window(s) on screen at the end") }
    if !endHidden { misses.append("Messages not hidden at the end") }
    if endFront != startFrontBundle { misses.append("\(endFront.isEmpty ? "no app" : endFront) in front at the end, not \(startFrontBundle)") }
    if !alsoGained.isEmpty { misses.append("\(alsoGained.joined(separator: ",")) gained a window") }
    if misses.isEmpty {
        reason = "Messages hidden, \(startFrontBundle) back in front"
    } else if firstMessagesFrontMs >= 0 && inputs.contains(where: { $0 >= firstMessagesFrontMs }) {
        verdict = "rerun"; reason = misses.joined(separator: "; ") + ", with user input after Messages came forward"
    } else {
        verdict = "fail"; reason = misses.joined(separator: "; ")
    }
}

var awayMs: Int64 = -1
if let firstAway = frontChanges.first(where: { $0.bundle != startFrontBundle })?.ms,
   let back = frontChanges.last(where: { $0.bundle == startFrontBundle })?.ms, back > firstAway {
    awayMs = back - firstAway
}

emit([
    "type": "summary", "wall_ms": tEnd, "verdict": verdict, "reason": reason, "mode": options.mode,
    "samples": samples, "duration_ms": tEnd - t0, "max_gap_ms": maxGap, "messages_window_ms": windowOnMs,
    "first_window_ms": firstWindowMs, "window_appearances": windowAppearances.count,
    "front_changes": frontChanges.count, "inputs": inputs.count, "start_front": startFrontBundle,
    "end_front": endFront, "messages_hidden_end": endHidden, "messages_onscreen_end": endOnScreen,
    "messages_front_ms": firstMessagesFrontMs, "away_ms": awayMs, "also_gained": alsoGained,
])
try? outHandle.close()
print("verdict \(verdict) \(reason)")
switch verdict {
case "pass": exit(0)
case "fail": exit(1)
case "rerun": exit(3)
default: exit(4)
}
