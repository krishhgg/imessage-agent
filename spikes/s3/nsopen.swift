import AppKit
let cfg = NSWorkspace.OpenConfiguration(); cfg.activates = false; cfg.addsToRecentItems = false
let sem = DispatchSemaphore(value: 0)
NSWorkspace.shared.open(URL(string: CommandLine.arguments[1])!, configuration: cfg) { _, e in print("err=\(String(describing: e))"); sem.signal() }
sem.wait()
