// nsopen2 app|url <arg>: NSWorkspace open with activates=false, hides=true (what the bridge would use).
import AppKit
let a = CommandLine.arguments
let c = NSWorkspace.OpenConfiguration(); c.activates = false; c.hides = true; c.addsToRecentItems = false
let s = DispatchSemaphore(value: 0); var res = "?"
if a[1] == "app" {
    NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Messages.app"), configuration: c) { app, err in res = err == nil ? "ok" : "err \((err! as NSError).code)"; s.signal() }
} else {
    NSWorkspace.shared.open([URL(string: a[2])!], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Messages.app"), configuration: c) { app, err in res = err == nil ? "ok" : "err \((err! as NSError).code)"; s.signal() }
}
while s.wait(timeout: .now()) == .timedOut { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
print("open=\(res)")
