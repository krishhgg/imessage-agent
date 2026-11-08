import Foundation
import IMCore

/// The bridge's one AppleScript (DESIGN.md section 3, S2). Compiled once, called with descriptor arguments.
/// `send_text`, `send_file` and `quit_messages` come from the S2 spike (spikes/s1/Bridge.swift) with a service
/// argument and a `with timeout` block added. `account_ready` is new and its readiness test needs confirming on 26.2
/// before cold start ships. `send_chat_text` and `send_chat_file` address a group by chat id (research/messages.sdef)
/// and stay unused until release test 8's group case turns group sends on.
/// Every `tell` to Messages sits inside its handler's own `with timeout` block, and each handler looks the account up
/// inline rather than through a shared handler, so the timeout covers every Apple Event the script sends.
/// The four send handlers, `account_ready` and `quit_messages` first check `application id "com.apple.MobileSMS" is
/// running`, which asks the system and doesn't launch Messages, and return `SendScripts.notRunning` when it isn't.
/// Without the check, a Messages that quit after the cold start would be launched the normal way, visible, by the
/// send's own Apple Event (section 3 item 4), or by `account_ready`'s if it quit between `ColdStarter`'s running check
/// and the call, or by the quit's own `quit` event if it exited after the window rules read its state.
/// `ColdStarter` counts only "1" as ready, so `not_running` from `account_ready` is not ready and the poll goes on.
/// `not_running` from `quit_messages` means Messages has already exited: `LiveMessagesApp.quit` returns true for it,
/// and the exit wait that follows finds no running Messages and returns at once.
/// `NSAppleScriptRunner` runs handlers on the main thread, so without a timeout a Messages that hangs would hold the
/// main thread, and every approval panel with it, for the 2 minute Apple Event default.
public enum SendScripts {
    public static let source = """
    on send_text(h, t, svc)
      if not (application id "com.apple.MobileSMS" is running) then return "not_running"
      with timeout of 10 seconds
        tell application id "com.apple.MobileSMS"
          if svc is "SMS" then
            set s to 1st account whose service type = SMS
          else
            set s to 1st account whose service type = iMessage
          end if
          send t to participant h of s
        end tell
      end timeout
      return "sent"
    end send_text

    on send_file(h, p, svc)
      if not (application id "com.apple.MobileSMS" is running) then return "not_running"
      set f to POSIX file p as alias
      with timeout of 10 seconds
        tell application id "com.apple.MobileSMS"
          if svc is "SMS" then
            set s to 1st account whose service type = SMS
          else
            set s to 1st account whose service type = iMessage
          end if
          send f to participant h of s
        end tell
      end timeout
      return "sent"
    end send_file

    on send_chat_text(g, t)
      if not (application id "com.apple.MobileSMS" is running) then return "not_running"
      with timeout of 10 seconds
        tell application id "com.apple.MobileSMS"
          send t to chat id g
        end tell
      end timeout
      return "sent"
    end send_chat_text

    on send_chat_file(g, p)
      if not (application id "com.apple.MobileSMS" is running) then return "not_running"
      set f to POSIX file p as alias
      with timeout of 10 seconds
        tell application id "com.apple.MobileSMS"
          send f to chat id g
        end tell
      end timeout
      return "sent"
    end send_chat_file

    on quit_messages()
      if not (application id "com.apple.MobileSMS" is running) then return "not_running"
      with timeout of 5 seconds
        tell application id "com.apple.MobileSMS" to quit
      end timeout
      return "quit"
    end quit_messages

    on account_ready(svc)
      if not (application id "com.apple.MobileSMS" is running) then return "not_running"
      with timeout of 5 seconds
        tell application id "com.apple.MobileSMS"
          if svc is "SMS" then
            set s to 1st account whose service type = SMS
          else
            set s to 1st account whose service type = iMessage
          end if
          if enabled of s and (connection status of s) is connected then return "1"
        end tell
      end timeout
      return "0"
    end account_ready
    """

    /// What a send handler returns when Messages isn't running. It sent nothing to Messages, so `MessageSender` runs
    /// the hidden cold start and calls the handler again.
    public static let notRunning = "not_running"

    /// Longest one send call (`send_text`, `send_file` or their chat forms) may wait for Messages to answer. A timed-out call is an error
    /// outcome, which stays advisory: correlation still decides the result from chat.db (section 3 item 5).
    /// A text plus file request makes two calls, so a stalled Messages holds the main thread for at most 20 s.
    static let sendEventTimeout: TimeInterval = Limits.sendEventTimeout

    /// Longest the `quit_messages` call may wait. The window rules' 10 s wait for Messages to exit
    /// (`Limits.quitWait`, section 4) starts only after this call returns, so this time adds to that wait.
    static let quitEventTimeout: TimeInterval = 5

    /// Longest one `account_ready` call may wait for Messages to answer. The default Apple Event timeout is 2 minutes,
    /// so a Messages that hangs while launching would hold one call far past the 60 s cold-start budget. A timed-out
    /// call is an error, which counts as not ready, and the next poll runs.
    static let accountReadyTimeout: TimeInterval = 5
}

/// Compiles and runs the script. The live engine wraps `NSAppleScript`. Tests put in an engine that records what it
/// is given and never compiles or runs AppleScript. `NSAppleScriptRunner` calls it on the main thread only.
protocol AppleScriptEngine: AnyObject {
    /// Compiles `source`. Nil on success, else the `NSAppleScript` error dictionary.
    func compile(_ source: String) -> NSDictionary?
    /// Runs one handler call against the compiled script. Returns the result descriptor or the error dictionary.
    func execute(_ event: NSAppleEventDescriptor) -> (result: NSAppleEventDescriptor?, error: NSDictionary?)
}

/// `NSAppleScript` engine. Holds the one compiled script.
final class NSAppleScriptEngine: AppleScriptEngine {
    private var script: NSAppleScript?

    func compile(_ source: String) -> NSDictionary? {
        guard let script = NSAppleScript(source: source) else {
            return [NSAppleScript.errorMessage: "could not create the script"]
        }
        var error: NSDictionary?
        guard script.compileAndReturnError(&error) else {
            return error ?? [NSAppleScript.errorMessage: "could not compile the script"]
        }
        self.script = script
        return nil
    }

    func execute(_ event: NSAppleEventDescriptor) -> (result: NSAppleEventDescriptor?, error: NSDictionary?) {
        guard let script else { return (nil, [NSAppleScript.errorMessage: "script not compiled"]) }
        var error: NSDictionary?
        let result = script.executeAppleEvent(event, error: &error)
        return error == nil ? (result, nil) : (nil, error)
    }
}

/// Live `AppleScriptRunning`: compiles `SendScripts.source` once and calls handlers through
/// `executeAppleEvent` (`ascr`/`psbr`) on the main thread. Owner: IMSend.
/// Never interpolates arguments into source. Each argument travels as its own string descriptor in the event's
/// direct parameter list, so a quote or `do shell script` in a message is only text.
///
/// The returned outcome is advisory. Every caller confirms a send in chat.db (section 3 item 5). `MessageSender` reads
/// only an Automation refusal from it, and only for a part that chat.db shows no row for.
public final class NSAppleScriptRunner: AppleScriptRunning {
    public let source: String

    /// Touched on the main thread only.
    private let engine: AppleScriptEngine
    private var compiled = false

    public convenience init(source: String = SendScripts.source) {
        self.init(source: source, engine: NSAppleScriptEngine())
    }

    init(source: String, engine: AppleScriptEngine) {
        self.source = source
        self.engine = engine
    }

    public func call(_ handler: ScriptHandler, arguments: [String]) -> AppleScriptOutcome {
        NSAppleScriptRunner.onMainThread { self.callOnMain(handler, arguments: arguments) }
    }

    private func callOnMain(_ handler: ScriptHandler, arguments: [String]) -> AppleScriptOutcome {
        dispatchPrecondition(condition: .onQueue(.main))
        let started = ProcessInfo.processInfo.systemUptime
        func elapsed() -> Int { Int(((ProcessInfo.processInfo.systemUptime - started) * 1000).rounded()) }

        if !compiled {
            // A failed compile is retried on the next call. Once it succeeds the script is never compiled again.
            if let error = engine.compile(source) {
                return NSAppleScriptRunner.failure(error, elapsedMs: elapsed())
            }
            compiled = true
        }
        let (result, error) = engine.execute(NSAppleScriptRunner.handlerEvent(handler, arguments: arguments))
        if let error { return NSAppleScriptRunner.failure(error, elapsedMs: elapsed()) }
        return AppleScriptOutcome(ok: true, value: result?.stringValue, elapsedMs: elapsed())
    }

    /// The `ascr`/`psbr` subroutine event for one handler call. `snam` names the handler and the direct parameter
    /// is a list of string descriptors, one per argument, in order.
    static func handlerEvent(_ handler: ScriptHandler, arguments: [String]) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: AppleEventCode.appleScriptSuite, eventID: AppleEventCode.subroutineEvent,
            targetDescriptor: .currentProcess(), returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID))
        event.setDescriptor(NSAppleEventDescriptor(string: handler.rawValue), forKeyword: AppleEventCode.subroutineName)
        let list = NSAppleEventDescriptor.list()
        for (index, argument) in arguments.enumerated() {
            list.insert(NSAppleEventDescriptor(string: argument), at: index + 1)
        }
        event.setDescriptor(list, forKeyword: AppleEventCode.directObject)
        return event
    }

    /// Runs `body` on the main thread: inline when already there, else with a synchronous hop. Calls from several
    /// connections therefore run one at a time, in the order they reach the main queue.
    static func onMainThread<T>(_ body: () -> T) -> T {
        if Thread.isMainThread { return body() }
        return DispatchQueue.main.sync(execute: body)
    }

    private static func failure(_ error: NSDictionary, elapsedMs: Int) -> AppleScriptOutcome {
        AppleScriptOutcome(ok: false, errorNumber: (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue,
                           errorMessage: error[NSAppleScript.errorMessage] as? String, elapsedMs: elapsedMs)
    }
}

/// Four-character codes for the AppleScript subroutine event (OpenScripting `ASRegistry.h`, `AppleEvents.h`).
enum AppleEventCode {
    static let appleScriptSuite = fourCC("ascr")
    static let subroutineEvent = fourCC("psbr")
    static let subroutineName = fourCC("snam")
    static let directObject = fourCC("----")

    static func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }
}
