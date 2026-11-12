import Foundation
import IMCore

/// `imessage setup` (install flow step 4): sends `setup(fullDiskAccess)` and returns at once, so the bot can end its
/// turn and ask the user to say "done". Owner: imessage CLI.
enum SetupFlow {
    static func run(client: BridgeClient) throws -> ResponsePayload {
        let request = Request(body: .setup(SetupArgs(stage: .fullDiskAccess)))
        return try client.run(request, upload: nil, readTimeout: CLI.responseTimeout(for: request.body),
                              onEvent: { _ in }).payload
    }
}

/// `imessage doctor [--ui]` (install flow step 5). Owner: imessage CLI.
///
/// 1. `doctor`. If `needsKickstart`, call `kickstart` once, wait for the socket, then `doctor` with `afterKickstart`
///    true.
/// 2. `setup(automation)`, and `setup(accessibility)` if `--ui` was given.
///
/// `CLI.execute` passes `liveKickstart`. Tests pass a closure that records the call, so no test restarts an installed
/// bridge.
///
/// The result is one doctor report: a `restart` check when the kickstart ran, the bridge's own checks from the last
/// `doctor` answer, and one `<stage> prompt` check per prompt raised. The kickstart runs at most once per call, even if
/// the second answer still says `needsKickstart`. If the bridge doesn't answer within `reconnectAttempts` tries after
/// the kickstart, or one try runs out of time, the flow stops before raising prompts. A `failure` answer to the first
/// `doctor` is returned as is.
enum DoctorFlow {
    /// Tries to reach the bridge after the kickstart, `reconnectDelay` apart.
    static let reconnectAttempts = 20
    static let reconnectDelay: TimeInterval = 0.5

    static func run(client: BridgeClient, wantUIActions: Bool, kickstart: () -> Bool) throws -> ResponsePayload {
        try run(client: client, wantUIActions: wantUIActions, kickstart: kickstart,
                pause: { Thread.sleep(forTimeInterval: $0) })
    }

    /// `pause` waits between reconnect tries. Tests pass one that only records, and a short `doctorTimeout`.
    static func run(client: BridgeClient, wantUIActions: Bool, kickstart: () -> Bool,
                    pause: (TimeInterval) -> Void,
                    doctorTimeout: TimeInterval = CLI.responseTimeout(for: .doctor(DoctorArgs())))
        throws -> ResponsePayload {
        let first = try doctor(client, DoctorArgs(wantUIActions: wantUIActions, afterKickstart: false),
                               timeout: doctorTimeout)
        guard case .doctor(var report) = first else { return first }
        var restart: [DoctorCheck] = []
        if report.needsKickstart {
            let target = Paths.launchdServiceTarget()
            if kickstart() {
                guard let again = try doctorAfterRestart(client, wantUIActions: wantUIActions, pause: pause,
                                                         timeout: doctorTimeout) else {
                    restart.append(DoctorCheck(name: "restart", ok: false,
                                               detail: "the bridge didn't answer after launchctl kickstart -k \(target)",
                                               fix: "imessage doctor"))
                    return .doctor(merged(report, before: restart, after: []))
                }
                guard case .doctor(let r) = again else { return again }
                report = r
                restart.append(DoctorCheck(name: "restart", ok: true, detail: "ran launchctl kickstart -k \(target)"))
            } else {
                restart.append(DoctorCheck(name: "restart", ok: false, detail: "launchctl kickstart -k \(target) failed",
                                           fix: "launchctl kickstart -k \(target)"))
            }
        }
        var prompts: [DoctorCheck] = []
        for stage in wantUIActions ? [SetupStage.automation, .accessibility] : [.automation] {
            prompts.append(promptCheck(stage, client: client))
        }
        return .doctor(merged(report, before: restart, after: prompts))
    }

    static func merged(_ r: DoctorReport, before: [DoctorCheck], after: [DoctorCheck]) -> DoctorReport {
        DoctorReport(checks: before + r.checks + after, needsKickstart: r.needsKickstart,
                     releaseTestBuild: r.releaseTestBuild)
    }

    static func doctor(_ client: BridgeClient, _ args: DoctorArgs, timeout: TimeInterval) throws -> ResponsePayload {
        try client.run(Request(body: .doctor(args)), upload: nil, readTimeout: timeout, onEvent: { _ in }).payload
    }

    /// The restarted job may take a moment to accept; launchd holds the socket meanwhile. A refused connection or
    /// one the bridge closed is retried. A try that runs out of time ends the retries, so a hung bridge costs one
    /// `timeout`, not `reconnectAttempts` of them. Nil when the bridge never answers.
    static func doctorAfterRestart(_ client: BridgeClient, wantUIActions: Bool, pause: (TimeInterval) -> Void,
                                   timeout: TimeInterval) throws -> ResponsePayload? {
        for attempt in 0..<reconnectAttempts {
            if attempt > 0 { pause(reconnectDelay) }
            do {
                return try doctor(client, DoctorArgs(wantUIActions: wantUIActions, afterKickstart: true),
                                  timeout: timeout)
            } catch ClientError.noResponse(let why) where why == BridgeClient.noAnswerInTime {
                return nil
            } catch ClientError.bridgeNotRunning, ClientError.requestNotDelivered, ClientError.noResponse {
                continue
            }
        }
        return nil
    }

    static func stageName(_ s: SetupStage) -> String {
        switch s {
        case .fullDiskAccess: return "Full Disk Access"
        case .automation: return "Automation"
        case .accessibility: return "Accessibility"
        }
    }

    /// Raises one prompt with `setup(<stage>)` and reports it as a check. `denied` fails with the Settings fix; a
    /// prompt that is up or already granted passes. A failed request becomes a failing check, so the report the
    /// bridge already gave isn't lost.
    static func promptCheck(_ stage: SetupStage, client: BridgeClient) -> DoctorCheck {
        let name = "\(stageName(stage)) prompt"
        let payload: ResponsePayload
        do {
            let request = Request(body: .setup(SetupArgs(stage: stage)))
            payload = try client.run(request, upload: nil, readTimeout: CLI.responseTimeout(for: request.body),
                                     onEvent: { _ in }).payload
        } catch let e as ClientError {
            let line = Output.errorResult(e, paths: client.paths, mutating: false)
            return DoctorCheck(name: name, ok: false, detail: line.code.wire, fix: line.fix)
        } catch {
            return DoctorCheck(name: name, ok: false, detail: "\(error)", fix: "imessage doctor")
        }
        switch payload {
        case .setup(let r):
            let pane = r.openedPane.map { ", opened \($0)" } ?? ""
            switch r.state {
            case .granted:
                return DoctorCheck(name: name, ok: true, detail: "granted" + pane)
            case .denied:
                return DoctorCheck(name: name, ok: false, detail: "denied" + pane,
                                   fix: "turn on \(AppIdentity.appName) in System Settings > Privacy & Security > "
                                       + stageName(stage))
            case .notDetermined, .unknown:
                return DoctorCheck(name: name, ok: true, detail: "asked, answer the prompt on the Mac" + pane)
            }
        case .failure(let e):
            return DoctorCheck(name: name, ok: false, detail: e.result.code.wire, fix: e.result.fix)
        default:
            return DoctorCheck(name: name, ok: false, detail: "the bridge gave another kind of answer",
                               fix: "install the app and the CLI from the same release")
        }
    }

    /// `/bin/launchctl` and its arguments: `kickstart -k gui/<uid>/<AppIdentity.launchAgentLabel>`.
    static let launchctlPath = "/bin/launchctl"

    static func kickstartArguments(uid: uid_t = getuid()) -> [String] {
        ["kickstart", "-k", Paths.launchdServiceTarget(uid: uid)]
    }

    /// How long `liveKickstart` waits for launchctl before it gives up and stops it.
    static let kickstartTimeout: TimeInterval = 30

    /// Runs `/bin/launchctl kickstart -k gui/<uid>/<AppIdentity.launchAgentLabel>` and returns true on exit status 0.
    /// launchctl's own output goes to stderr, so stdout keeps only the doctor report.
    static func liveKickstart() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchctlPath)
        p.arguments = kickstartArguments()
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.standardError
        p.standardError = FileHandle.standardError
        return runToExit(p, timeout: kickstartTimeout)
    }

    /// Starts `process` and waits up to `timeout` for it to exit. True only for exit status 0. A process that
    /// can't start is false; one still running at the timeout is terminated and is false.
    static func runToExit(_ process: Process, timeout: TimeInterval) -> Bool {
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return false
        }
        guard exited.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            _ = exited.wait(timeout: .now() + 1)
            return false
        }
        return process.terminationReason == .exit && process.terminationStatus == 0
    }
}

/// Turns a response into stdout text with `Format`, or NDJSON with `--json`. Owner: imessage CLI.
/// Stdout carries only the result; events and `waiting for approval on the Mac` go to stderr.
///
/// Lines the CLI writes itself, usage and connection errors included, go to stderr. Stdout holds only what the
/// bridge answered, rendered by IMCore `Format`.
enum Output {
    static func render(_ payload: ResponsePayload, json: Bool, context: FormatContext) -> String {
        json ? Format.ndjson(payload) : Format.render(payload, context)
    }

    /// See `ExitCode` for the rule. `who` with no match prints an error line, so it exits 1. A `wait` that timed out,
    /// and every report and list, exit 0.
    static func exitCode(for payload: ResponsePayload) -> ExitCode {
        switch payload {
        case .failure:
            return .failure
        case .contacts(let p):
            return p.contacts.isEmpty ? .failure : .ok
        case .attachment(let e):
            return e.result == nil && !(e.path ?? "").isEmpty ? .ok : .failure
        case .send(let o):
            if let early = o.early { return tookEffect(early) ? .ok : .failure }
            guard !o.parts.isEmpty else { return .failure }
            return o.parts.allSatisfy { tookEffect($0.result) } ? .ok : .failure
        case .ui(let o):
            return tookEffect(o.result) ? .ok : .failure
        case .policy(let o):
            return tookEffect(o.result) ? .ok : .failure
        case .chats, .unread, .messages, .message, .search, .changes, .wait, .pending, .caps, .status, .setup,
             .doctor, .pong:
            return .ok
        }
    }

    /// `submitted`, `delivered`, `ok` and `already` took effect or already held; `pending <id>` is waiting for the
    /// user. Everything else is a failed action.
    static func tookEffect(_ r: ActionResult) -> Bool {
        switch r.code {
        case .submitted, .delivered, .ok, .already, .pending: return true
        default: return false
        }
    }

    static func eventLine(_ event: BridgeEvent) -> String? {
        switch event {
        case .approvalShown: return "waiting for approval on the Mac"
        case .queued: return "waiting for the queue"
        case .waitingForIdle: return "waiting until the Mac is idle"
        }
    }

    static func exitCode(for error: ClientError) -> ExitCode {
        error.beforeDelivery ? .bridgeUnavailable : .failure
    }

    /// The one-line error for a client failure. After a lost response to a mutation, the fix never suggests
    /// `--again`: a repeat without it returns the first result instead of acting twice.
    static func errorResult(_ error: ClientError, paths: Paths, mutating: Bool) -> ActionResult {
        let socket = (try? paths.resolvedSocketPath()) ?? paths.primarySocketPath
        func e(_ m: String, _ fix: String) -> ActionResult { ActionResult(.error(.message(m)), fix: fix) }
        switch error {
        case .bridgeNotRunning:
            return e("the bridge isn't running",
                     "launchctl bootstrap gui/\(getuid()) \(shellQuote(paths.launchAgentPlist.path)), "
                        + "or run install.sh again")
        case .wrongOwner:
            return e("the bridge socket \(socket) belongs to another user", "delete it, then run install.sh again")
        case .notSocket:
            return e("\(socket) isn't a socket", "delete it, then run install.sh again")
        case .protocolMismatch(let v):
            return e("the bridge speaks protocol \(v), this CLI speaks \(Request.protocolVersion)",
                     "install the app and the CLI from the same release")
        case .io(let d):
            return e("can't reach the bridge: \(d)", "imessage doctor")
        case .requestNotDelivered(let d):
            return e("the request didn't reach the bridge: \(d)", "retry, and run imessage doctor if it happens again")
        case .noResponse(let d):
            return e("no answer from the bridge: \(d)",
                     mutating ? "repeat the command without --again to get its result"
                              : "retry, and run imessage doctor if it happens again")
        case .uploadFailed(let d):
            return e("couldn't read the file: \(d)", "check the file and retry")
        }
    }

    /// The line for an error that is neither a usage error nor a `ClientError`. It still ends in a fix, like every
    /// error line (section 5, Output).
    static func unexpected(_ error: Error) -> ActionResult {
        ActionResult(.error(.message("\(error)")), fix: "retry, and run imessage doctor if it happens again")
    }

    /// Single-quotes a path for a shell when it holds anything outside a safe set.
    static func shellQuote(_ s: String) -> String {
        let safe = !s.isEmpty && s.unicodeScalars.allSatisfy { c in
            c.isASCII && (CharacterSet.alphanumerics.contains(c) || "_@%+=:,./-".unicodeScalars.contains(c))
        }
        return safe ? s : "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// What `CLI.execute` talks to. `live()` is the real process; tests build one with a fake bridge's paths, captured
/// output and a recording kickstart.
struct CLIEnvironment {
    var client: BridgeClient
    var now: Date
    var timeZone: TimeZone
    var stdout: (String) -> Void
    var stderr: (String) -> Void
    var kickstart: () -> Bool
    var pause: (TimeInterval) -> Void

    static func live() -> CLIEnvironment {
        CLIEnvironment(
            client: BridgeClient(), now: Date(), timeZone: .current,
            stdout: { try? FileHandle.standardOutput.write(contentsOf: Data($0.utf8)) },
            stderr: { try? FileHandle.standardError.write(contentsOf: Data($0.utf8)) },
            kickstart: DoctorFlow.liveKickstart,
            pause: { Thread.sleep(forTimeInterval: $0) })
    }
}

/// Top level: parse, build the request, call the bridge, print, return the exit code. Owner: imessage CLI.
enum CLI {
    static func run(arguments: [String]) -> Int32 {
        run(arguments: arguments, environment: .live())
    }

    static func run(arguments: [String], environment env: CLIEnvironment) -> Int32 {
        do {
            let invocation = try ArgumentParser.parse(arguments)
            return execute(invocation, environment: env).rawValue
        } catch let e as UsageError {
            env.stderr(e.line + "\n")
            return ExitCode.usage.rawValue
        } catch {
            env.stderr(Output.unexpected(error).rendered + "\n")
            return ExitCode.failure.rawValue
        }
    }

    static func execute(_ invocation: Invocation) -> ExitCode {
        execute(invocation, environment: .live())
    }

    /// Usage errors, an unreadable or oversized `--file` included, print before any connection is made.
    static func execute(_ invocation: Invocation, environment env: CLIEnvironment) -> ExitCode {
        let command = invocation.command
        do {
            let payload: ResponsePayload
            switch command {
            case .help(let topic):
                env.stdout(ArgumentParser.helpText(topic))
                return .ok
            case .setup:
                payload = try SetupFlow.run(client: env.client)
            case .doctor(let ui):
                payload = try DoctorFlow.run(client: env.client, wantUIActions: ui, kickstart: env.kickstart,
                                             pause: env.pause)
            default:
                var request = try request(for: command, now: env.now, timeZone: env.timeZone)
                var upload: UploadSource?
                if case .send(_, _, let file?, _, _) = command {
                    let source = try UploadSource(path: file)
                    request.upload = source.header
                    upload = source
                }
                let response = try env.client.run(request, upload: upload,
                                                  readTimeout: responseTimeout(for: request.body)) { event in
                    if let line = Output.eventLine(event) { env.stderr(line + "\n") }
                }
                payload = response.payload
            }
            env.stdout(Output.render(payload, json: invocation.json,
                                     context: FormatContext(now: env.now, timeZone: env.timeZone)))
            return Output.exitCode(for: payload)
        } catch let e as UsageError {
            env.stderr(e.line + "\n")
            return .usage
        } catch let e as ClientError {
            env.stderr(Output.errorResult(e, paths: env.client.paths, mutating: command.isMutation).rendered + "\n")
            return Output.exitCode(for: e)
        } catch {
            env.stderr(Output.unexpected(error).rendered + "\n")
            return .failure
        }
    }

    /// Maps a parsed command to a wire request. `help` and usage errors never reach the bridge.
    static func request(for command: Command, now: Date, timeZone: TimeZone) throws -> Request {
        func since(_ s: String?) throws -> AppleNanos? {
            guard let s else { return nil }
            guard let ns = TimeSpec.parseNanos(s, now: now, timeZone: timeZone) else {
                throw UsageError(message: "--since \(ArgumentParser.quoted(s)) isn't a time",
                                 fix: "use 30m, 12h, 7d, 2w, today, yesterday, 2026-10-01 or 2026-10-01T09:30")
            }
            return ns
        }
        let body: RequestBody
        switch command {
        case let .chats(limit, unreadOnly):
            body = .chats(ChatsArgs(limit: limit, unreadOnly: unreadOnly))
        case .unread(let context):
            body = .unread(UnreadArgs(context: context))
        case let .read(who, limit, before, after, around, s):
            body = .messages(MessagesArgs(who: who, limit: limit, before: before, after: after, around: around,
                                          sinceNs: try since(s)))
        case let .show(rowid, fromByte):
            body = .message(MessageArgs(rowid: rowid, fromByte: fromByte))
        case let .search(text, inWho, s, cursor, limit):
            body = .search(SearchArgs(text: text, inWho: inWho, sinceNs: try since(s), cursor: cursor, limit: limit))
        case .who(let name):
            body = .contacts(ContactsArgs(name: name))
        case .att(let id):
            body = .attachment(AttachmentArgs(id: id))
        case let .send(who, text, _, again, thread):
            body = .send(SendArgs(who: who, text: text, again: again, thread: thread))
        case let .react(rowid, kind, remove, again):
            body = .ui(UIArgs(action: .react(rowid: rowid, kind: kind, remove: remove), again: again))
        case let .unsend(rowid, again):
            body = .ui(UIArgs(action: .unsend(rowid: rowid), again: again))
        case let .edit(rowid, text, again):
            body = .ui(UIArgs(action: .edit(rowid: rowid, text: text), again: again))
        case let .allow(who, files, foreground):
            body = .allow(AllowArgs(who: who, files: files, foreground: foreground))
        case let .revoke(who, foreground):
            body = .revoke(RevokeArgs(who: who, foreground: foreground))
        case .pending(let id):
            body = .pending(PendingArgs(id: id))
        case let .wait(fromWho, timeout):
            body = .wait(WaitArgs(fromWho: fromWho, timeout: timeout))
        case .changes(let s):
            body = .changes(ChangesArgs(since: s))
        case .caps:
            body = .caps
        case .doctor(let ui):
            body = .doctor(DoctorArgs(wantUIActions: ui))
        case .setup:
            body = .setup(SetupArgs(stage: .fullDiskAccess))
        case .help:
            throw UsageError(message: "help doesn't go to the bridge", fix: "imessage help")
        }
        return Request(body: body)
    }

    /// Time the bridge needs beyond the waits it reports, for scheduling and IO.
    static let responseSlack: TimeInterval = 30

    /// The longest a plain send runs after the queue (section 3 items 4 and 5): the hidden cold start, the text call
    /// and the file call, then, when one of them finds Messages closed, a second cold start and that call again, then
    /// the correlation wait. Each of the three calls counts at its full `Limits.sendEventTimeout`.
    static let sendActionTime = 2 * Limits.coldStartTimeout + 3 * Limits.sendEventTimeout + Limits.correlationTimeout

    /// The longest a hidden UI action runs: cold start, the no-window relaunch, the visibility poll and the verify
    /// wait (section 4).
    static let hiddenActionTime = Limits.coldStartTimeout + Limits.quitWait + Limits.relaunchWindowWait
        + Limits.visibilityPoll + Limits.uiVerifyTimeout

    /// The longest a foreground action runs after approval: the idle gate, activation, the late-activation watch,
    /// the Return deadline, hiding, focus restore and the verify wait (section 4 steps 2 to 7). `edit` and
    /// `send --thread` are foreground actions.
    static let foregroundActionTime = Limits.idleGateTimeout + Limits.activationTimeout + Limits.lateActivationWatch
        + Limits.returnDeadline + Limits.hidePoll + Limits.focusRestoreWait + Limits.foregroundVerifyTimeout

    /// How long the client waits for the response, events included: the approval wait, the queue wait and the
    /// action's own timeouts from `Limits`, plus `responseSlack`.
    static func responseTimeout(for body: RequestBody) -> TimeInterval {
        let slack = responseSlack
        switch body {
        case .search:
            return Limits.searchBudget + slack
        case .wait(let a):
            return a.timeout + slack
        case .send(let a):
            let queued = a.approvalWait + Limits.queueWait + slack
            // A threaded reply makes no script call and takes no file, so it has no retry to cover.
            if a.thread { return queued + Limits.coldStartTimeout + Limits.correlationTimeout + foregroundActionTime }
            return queued + sendActionTime
        case .ui(let a):
            return a.approvalWait + Limits.queueWait + hiddenActionTime + foregroundActionTime + slack
        case .allow(let a):
            return a.approvalWait + slack
        case .revoke(let a):
            return a.approvalWait + slack
        case .doctor:
            return Limits.coldStartTimeout + slack
        default:
            return slack
        }
    }
}
