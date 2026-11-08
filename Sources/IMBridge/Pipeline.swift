import Foundation
import IMCore
import IMForeground
import IMPolicy
import IMSend
import IMStore
import IMUI

/// How a mutation uses the action queue.
enum QueueUse {
    /// The pipeline takes the queue before the action and releases it after `final`.
    case pipeline
    /// `ForegroundMachine` takes the queue and hands its ticket back in the outcome.
    case foreground
    /// Policy changes don't touch Messages, so they never queue.
    case none
}

/// What the acting module gets for one run.
struct ActionContext {
    let entryID: String
    let approved: Bool
    /// Monotonic deadline for the queue wait, set when the request enters the queue.
    let queueDeadline: TimeInterval
    let recorder: InvocationRecorder
    let events: (BridgeEvent) -> Void
    /// Set for an approved threaded reply whose dialog didn't name a rate limit. `runForeground` runs it once the
    /// machine holds the queue.
    var recheck: RateRecheck?
}

/// The rate recheck under the queue for an approved threaded reply (section 2, Rate limits). `ForegroundMachine`
/// takes the queue itself, so the check runs first in its window step, before anything touches Messages. A breach
/// stops the run with `pending <id>` and keeps the prompt, and the pipeline asks again with the breach named.
final class RateRecheck {
    private let check: () -> ApprovalPrompt?
    /// The dialog the breach needs, once the check found one.
    private(set) var prompt: ApprovalPrompt?

    init(check: @escaping () -> ApprovalPrompt?) { self.check = check }

    /// The machine's window step with the check in front of it.
    func guarding(_ base: HiddenWindowPreparing) -> HiddenWindowPreparing { Guarded(rate: self, base: base) }

    private final class Guarded: HiddenWindowPreparing {
        let rate: RateRecheck
        let base: HiddenWindowPreparing

        init(rate: RateRecheck, base: HiddenWindowPreparing) {
            self.rate = rate
            self.base = base
        }

        func prepare(queueDeadline: TimeInterval) -> WindowPreparation {
            if let found = rate.check() {
                rate.prompt = found
                return WindowPreparation(early: ActionResult(.pending(id: found.id)), notes: [])
            }
            return base.prepare(queueDeadline: queueDeadline)
        }

        /// The rate check runs once, in `prepare`, so this is the base's window recheck alone.
        func recheck() -> ActionResult? { base.recheck() }
    }
}

/// What the acting module returns.
struct ActionOutcome {
    var result: ActionResult
    var payload: ResponsePayload
    var sentGUIDs: [String] = []
    /// The foreground machine's queue ticket, released after `final`.
    var ticket: QueueTicket?
}

/// The result of starting a foreground action.
enum ForegroundStart {
    case ran(ForegroundOutcome)
    /// Nothing ran.
    case refused(ActionResult)
}

/// One mutation after its target is resolved and its binding is built (steps 3 to 8 of `MutationPipeline`).
struct MutationJob {
    var key: IdempotencyKey
    var again: Bool
    var request: MutationRequest
    var approvalWait: TimeInterval
    /// `clock.uptime` when the request reached the pipeline. A dialog raised after a queue wait gets only the part of
    /// `approvalWait` that is left, so `pending <id>` still comes within the CLI's approval wait.
    var startedAt: TimeInterval
    var queue: QueueUse
    /// The Undo Send or edit window. Checked after approval and again by the runner.
    var windowOpen: (() -> Bool)?
    /// The open dialog named a rate limit, so its approval stands whatever the recheck under the queue finds.
    var rateLimitNamed = false
    /// The payload for a result reached before the action ran. The flag says whether a dialog approved it.
    var early: (ActionResult, Bool) -> ResponsePayload
    /// The payload for a key the journal already holds.
    var found: (KeyLookup) -> ResponsePayload
    var act: (ActionContext) -> ActionOutcome
    /// Runs once when the request is done, after `final` or when nothing was journaled. Discards a frozen upload.
    var cleanup: () -> Void = {}
}

extension MutationPipeline {
    static let foregroundUnavailable = ActionResult(.error(.message("foreground actions aren't available")),
                                                    fix: "run imessage doctor")
    static let imageUnsupported = ActionResult(.unsupported, fix: "imessage caps shows what this macOS supports")
    static let policySaveFailed = ActionResult(.error(.message("can't save the allowlist")), fix: "run imessage doctor")
    static let policyCheckFailed = ActionResult(.error(.message("policy check failed")), fix: "run imessage doctor")

    /// `nil` when the capability may run, otherwise the result to answer with.
    static func gate(_ status: CapStatus) -> ActionResult? {
        switch status {
        case .supported: return nil
        case .untested: return ActionResult(.untested, fix: "imessage caps shows what this macOS supports")
        case .unsupported: return ActionResult(.unsupported, fix: "imessage caps shows what this macOS supports")
        }
    }

    /// File parts with a correlated row get the attachment chat.db recorded for it, so the result prints
    /// `[photo a9901 2.2MB]` (section 5, Output). A part with no row, or a row chat.db can't read, keeps none.
    static func withAttachments(_ parts: [SendPartOutcome], reads: ReadService?) -> [SendPartOutcome] {
        parts.map { part in
            guard part.part == .file, part.attachment == nil, let rowid = part.rowid, let reads,
                  let detail = try? reads.message(MessageArgs(rowid: rowid)) else { return part }
            var filled = part
            filled.attachment = detail.message.attachments.first
            return filled
        }
    }

    /// The CLI's approval wait, kept between 0 and the approval expiry.
    static func clampWait(_ seconds: TimeInterval) -> TimeInterval {
        guard seconds.isFinite else { return Limits.approvalWait }
        return min(max(0, seconds), Limits.approvalExpiry)
    }

    /// Section 4: v1 targets 1:1 chats and single-part text (`p:0`) only, as `UIResults.unsupportedTarget` checks.
    /// Unsend and edit need the user's own message. Unsending a message that is already unsent is `already`. The
    /// runners check the same rules again; checking here keeps a dialog from asking about an action that can't run.
    static func targetRefusal(_ kind: UIActionKind, target: MessageTargetInfo, chat: ResolvedChat,
                              editState: EditStateProbe?) -> ActionResult? {
        let group = target.isGroupChat || target.canonical.isGroup || chat.isGroup
        if kind == .unsend {
            if group || !target.fromMe { return ActionResult(.unsupportedTarget) }
            if target.isUnsent { return ActionResult(.already) }
            if let state = editState, state.dateEditedNs != 0, TextNorm.matchKey(state.body).isEmpty {
                return ActionResult(.already)
            }
        }
        if kind == .edit, !target.fromMe { return ActionResult(.unsupportedTarget) }
        if chat.isGroup { return ActionResult(.unsupportedTarget) }
        return UIResults.unsupportedTarget(target)
    }

    /// The answer for a key the journal already holds. `repeated` builds an early payload marked as a repeat;
    /// `replay` marks a stored payload as a repeat.
    static func answer(_ lookup: KeyLookup, repeated: (ActionResult) -> ResponsePayload,
                       replay: (ResponsePayload) -> ResponsePayload) -> ResponsePayload {
        switch lookup {
        case .replay(let payload):
            if case .failure(let error) = payload, error.candidates.isEmpty { return repeated(error.result) }
            return replay(payload)
        case .pending(let id):
            return repeated(ActionResult(.pending(id: id)))
        case .rereadReaction(let entry):
            return replay(entry.response ?? .failure(WireError(result: entry.result ?? ActionResult(.ok))))
        case .mayHaveCompleted, .fresh:
            // `.fresh` never comes back as `.found`. If it did, running nothing is the safe answer.
            return repeated(ActionResult(.mayHaveCompleted))
        }
    }

    /// Marks the entry as foreground and runs the machine with this request's progress events. The machine takes the
    /// queue itself.
    static func runForeground(_ c: BridgeContainer, _ ctx: ActionContext, chat: ResolvedChat,
                              action: ForegroundAction) -> ForegroundStart {
        guard let machine = c.foreground else { return .refused(foregroundUnavailable) }
        // The user may have turned foreground mode off while the dialog was up.
        guard c.policy.isForegroundModeOn else { return .refused(.foregroundModeOff) }
        do {
            try c.journal.markForeground(ctx.entryID, true)
        } catch {
            return .refused(.journalWriteFailed)
        }
        var env = machine.env
        env.progress = ctx.events
        if let recheck = ctx.recheck { env.windowRules = recheck.guarding(env.windowRules) }
        let run = ForegroundRun(chat: chat, action: action, queueDeadline: ctx.queueDeadline)
        return .ran(ForegroundMachine(env: env).run(run, recorder: ctx.recorder))
    }

    static func refusal(_ start: ForegroundStart) -> ActionResult {
        switch start {
        case .refused(let result): return result
        case .ran(let outcome): return outcome.result
        }
    }

    // MARK: - Steps 3 to 8

    func run(_ job: MutationJob, events: @escaping (BridgeEvent) -> Void) -> ResponsePayload {
        let c = container
        let binding = job.request.binding
        // A journal that still holds unrecovered entries can't say whether this key already ran.
        guard BridgeMain.recoverIfNeeded(c) else {
            job.cleanup()
            return job.early(.journalWriteFailed, false)
        }
        let claim: KeyClaim
        do {
            claim = try c.journal.claim(key: job.key, again: job.again, action: binding.action, chat: binding.chat,
                                        binding: binding)
        } catch {
            job.cleanup()
            return job.early(.journalWriteFailed, false)
        }
        let entryID: String
        switch claim {
        case .found(let lookup):
            job.cleanup()
            return job.found(lookup)
        case .run(let entry):
            entryID = entry.id
        }
        switch evaluate(job.request) {
        case .refused(let result):
            return finish(job, entryID, result: result, payload: job.early(result, false))
        case .allowed:
            return proceed(job, entryID: entryID, approvalID: nil, events: events)
        case .needsApproval(let prompt):
            return ask(job, entryID: entryID, prompt: prompt, events: events)
        }
    }

    /// Fails closed: an engine that throws refuses the request.
    private func evaluate(_ request: MutationRequest) -> PolicyDecision {
        do {
            return try container.engine.evaluate(request)
        } catch {
            return .refused(MutationPipeline.policyCheckFailed)
        }
    }

    /// The part of the CLI's approval wait that is left since the request started.
    func approvalWaitLeft(_ job: MutationJob) -> TimeInterval {
        max(0, job.approvalWait - max(0, container.clock.uptime - job.startedAt))
    }

    /// Opens the dialog and waits for what is left of the CLI's approval wait. Past that, answers `pending <id>` and
    /// waits for the decision on a background thread that keeps the bridge resident.
    func ask(_ job: MutationJob, entryID: String, prompt: ApprovalPrompt,
             events: @escaping (BridgeEvent) -> Void) -> ResponsePayload {
        let c = container
        var job = job
        job.rateLimitNamed = prompt.namesRateLimit
        // Recorded before the dialog shows, so a repeated key gets `pending <id>` and never a second dialog.
        do {
            try c.journal.attachApproval(entryID, approvalID: prompt.id)
        } catch {
            return finish(job, entryID, result: .journalWriteFailed, payload: job.early(.journalWriteFailed, false))
        }
        let id = c.approvals.open(prompt)
        if id != prompt.id { try? c.journal.attachApproval(entryID, approvalID: id) }
        c.inFlight.alias(id, to: entryID)
        let pendingPayload = job.early(ActionResult(.pending(id: id)), false)
        c.inFlight.setPending(entryID, pendingPayload)
        events(.approvalShown(id: id))

        let status = c.approvals.wait(id: id, seconds: approvalWaitLeft(job))
        if status != .pending {
            return decided(job, entryID: entryID, approvalID: id, status: status, events: events)
        }
        let residency = c.residency
        residency.enter()
        let thread = Thread { [self] in
            let later = c.approvals.wait(id: id, seconds: Limits.approvalExpiry + 1)
            // The CLI has its answer and has hung up, so progress events go nowhere.
            _ = decided(job, entryID: entryID, approvalID: id, status: later, events: { _ in })
            residency.leave()
        }
        thread.name = "\(AppIdentity.bundleID).approval"
        thread.start()
        return pendingPayload
    }

    /// Deny holds the key. An allow runs only if the book consumes it, which fails once it expired or was used.
    func decided(_ job: MutationJob, entryID: String, approvalID id: String, status: ApprovalStatus,
                 events: @escaping (BridgeEvent) -> Void) -> ResponsePayload {
        let c = container
        let expired = ActionResult(.denied(.approvalExpired))
        switch status {
        case .decided(.deny):
            let denied = ActionResult(.denied(.user))
            return finish(job, entryID, result: denied, payload: job.early(denied, false))
        case .decided(let decision):
            guard c.approvals.consume(id: id, binding: job.request.binding) else {
                return finish(job, entryID, result: expired, payload: job.early(expired, false))
            }
            if decision == .alwaysAllow {
                do {
                    try c.engine.applyAlwaysAllow(job.request)
                } catch {
                    BridgeLog.write("always allow wasn't saved: \(error)")
                }
            }
            return proceed(job, entryID: entryID, approvalID: id, events: events)
        case .pending, .expired, .consumed, .unknown:
            return finish(job, entryID, result: expired, payload: job.early(expired, false))
        }
    }

    /// Steps 5 to 7: journal `approved`, check the action window, take the queue, recheck rate limits, act.
    func proceed(_ job: MutationJob, entryID: String, approvalID: String?,
                 events: @escaping (BridgeEvent) -> Void) -> ResponsePayload {
        let c = container
        let approved = approvalID != nil
        if let approvalID {
            do {
                // A second dialog after the recheck finds the entry `approved` already.
                if c.journal.entry(entryID)?.state != .approved {
                    try c.journal.advance(entryID, to: .approved, approvalID: approvalID)
                }
            } catch {
                return finish(job, entryID, result: .journalWriteFailed, payload: job.early(.journalWriteFailed, true))
            }
        }
        if let open = job.windowOpen, !open() {
            let expired = ActionResult(.expired)
            return finish(job, entryID, result: expired, payload: job.early(expired, approved))
        }

        let queueDeadline = c.clock.uptime + Limits.queueWait
        var ticket: QueueTicket?
        if job.queue == .pipeline {
            if c.queue.isHeld { events(.queued) }
            guard let held = c.queue.acquire(timeout: Limits.queueWait) else {
                let busy = ActionResult(.busy(.queue))
                return finish(job, entryID, result: busy, payload: job.early(busy, approved))
            }
            ticket = held
        }

        // Two sends to one chat can both pass the first check. Holding the queue, only one runs at a time.
        if !approved, job.request.binding.action.isRateLimited {
            switch evaluate(job.request) {
            case .allowed:
                break
            case .refused(let result):
                return finish(job, entryID, result: result, payload: job.early(result, false), tickets: [ticket])
            case .needsApproval(let prompt):
                if let ticket { c.queue.release(ticket) }
                return ask(job, entryID: entryID, prompt: prompt, events: events)
            }
        }

        // A threaded reply always asks, and a send can follow while its dialog is up, so the recheck covers it too.
        // The machine holds the queue when the check runs.
        var context = ActionContext(entryID: entryID, approved: approved, queueDeadline: queueDeadline,
                                    recorder: c.journal.recorder(for: entryID), events: events)
        if approved, job.queue == .foreground, job.request.binding.action.isRateLimited, !job.rateLimitNamed {
            let engine = c.engine
            let request = job.request
            context.recheck = RateRecheck { engine.rateLimitPrompt(request) }
        }
        let outcome = job.act(context)
        if let prompt = context.recheck?.prompt {
            if let held = outcome.ticket { c.queue.release(held) }
            do {
                try c.journal.markForeground(entryID, false)
            } catch {
                return finish(job, entryID, result: .journalWriteFailed, payload: job.early(.journalWriteFailed, true))
            }
            return ask(job, entryID: entryID, prompt: prompt, events: events)
        }
        return finish(job, entryID, result: outcome.result, payload: outcome.payload, sentGUIDs: outcome.sentGUIDs,
                      tickets: [ticket, outcome.ticket])
    }

    /// Step 8. GUIDs first so a `wait` running now never reports the bridge's own message, then the journal, the
    /// rate limiter and the queue.
    @discardableResult
    func finish(_ job: MutationJob, _ entryID: String, result: ActionResult, payload: ResponsePayload,
                sentGUIDs: [String] = [], tickets: [QueueTicket?] = []) -> ResponsePayload {
        let c = container
        if !sentGUIDs.isEmpty { c.db?.addAgentSentGUIDs(sentGUIDs) }
        c.inFlight.finish(entryID, payload, at: c.clock.now)
        do {
            try c.journal.finish(entryID, result: result, response: payload)
        } catch {
            BridgeLog.write("journal final for \(entryID) failed: \(error)")
        }
        if let event = c.journal.sendEvent(for: entryID) { c.engine.limiter.record(event) }
        var released = Set<QueueTicket>()
        for case let held? in tickets where released.insert(held).inserted { c.queue.release(held) }
        job.cleanup()
        return payload
    }
}

/// Request-level answers when chat.db isn't open.
enum StoreAccess {
    static let notOpen = WireError.message("can't open chat.db", fix: "run imessage doctor")
    static let readFailed = ActionResult(.error(.message("can't read chat.db")), fix: "run imessage doctor")

    /// Opens chat.db if it isn't open yet. `nil` once it is open.
    static func openFailure(_ c: BridgeContainer) -> WireError? {
        switch c.openStoreIfNeeded() {
        case .ok: return nil
        case .notPermitted: return WireErrors.noFullDiskAccess
        case .missing: return .message("chat.db not found", fix: "sign in to iMessage in Messages, then run imessage doctor")
        case .failed(let why): return .message("can't open chat.db: \(TextNorm.oneLine(why))", fix: "run imessage doctor")
        }
    }
}

/// One-line `error: … fix: …` answers for every error the read and send paths throw.
enum WireErrors {
    static let noFullDiskAccess = WireError.message("no Full Disk Access", fix: "imessage setup")

    static func map(_ error: Error, op: Op) -> WireError {
        if let wire = error as? WireError { return wire }
        if let store = error as? StoreError { return map(store, op: op) }
        if let attachment = error as? AttachmentError {
            switch attachment {
            case .unsafeCache(let path):
                return .message("unsafe attachment cache \(TextNorm.oneLine(path))", fix: "remove that folder and retry")
            case .io(let why):
                return .message("can't copy the attachment: \(TextNorm.oneLine(why))", fix: "free disk space and retry")
            case .conversion(let why):
                return .message("can't convert the image: \(TextNorm.oneLine(why))", fix: "retry, the original is unchanged")
            }
        }
        if let upload = error as? UploadError { return self.upload(upload) }
        return .message("unexpected error: \(TextNorm.oneLine(String(describing: error)))", fix: "run imessage doctor")
    }

    static func map(_ error: StoreError, op: Op) -> WireError {
        switch error {
        case .notPermitted:
            return noFullDiskAccess
        case .notFound(let what):
            return .message("no \(TextNorm.oneLine(what))", fix: "check the id and retry")
        case .severalMatches(let candidates):
            return WireError(result: ActionResult(.error(.severalMatches), fix: "pass a chat id or handle from the list"),
                             candidates: candidates)
        case .noMatch(let who):
            let quoted = "\"\(TextNorm.oneLine(who))\""
            if op == .contacts { return .message("no contact matches \(quoted)", fix: "imessage chats") }
            // The fix depends on the form: a chat number, an email, a phone number or a name (section 5).
            return .message("no chat or contact matches \(quoted)", fix: StoreError.noMatchFix(for: who))
        case .timeout:
            return .message("chat.db read timed out", fix: timeoutFix(op))
        case .rowCapExceeded:
            return .message("too many rows", fix: "ask for fewer rows with -n")
        case .sqlite(let code, let message):
            return .message("chat.db error \(code): \(TextNorm.oneLine(message))", fix: "run imessage doctor")
        case .decode(let what):
            return .message("can't decode \(TextNorm.oneLine(what))", fix: "run imessage doctor")
        }
    }

    /// Each fix names only flags its verb takes. `unread` can point at `read`, which looks at one chat. `changes` with
    /// no `--since` returns the current cursor and no rows, so an agent whose old cursor keeps timing out can start
    /// again from now.
    static func timeoutFix(_ op: Op) -> String {
        switch op {
        case .search: return "retry, or narrow the search with --in or --since"
        case .unread: return "retry, or read one chat with imessage read <chat>"
        case .changes: return "retry, or run imessage changes with no --since for a fresh cursor"
        default: return "retry"
        }
    }

    static func upload(_ error: Error) -> WireError {
        switch error as? UploadError {
        case .tooLarge?:
            return .message("file too large", fix: "send a file under 100 MB")
        case .shortRead?:
            return .message("the upload ended early", fix: "retry the send")
        case .badName?:
            return WireError(result: .badRequest)
        case .io(let why)?:
            return .message("can't save the upload: \(TextNorm.oneLine(why))", fix: "free disk space and retry")
        case nil:
            return .message("can't read the upload", fix: "retry the send")
        }
    }
}

/// Lines for the bridge's stderr, which launchd sends to the system log.
enum BridgeLog {
    static func write(_ line: String) {
        FileHandle.standardError.write(Data(("imessage-agent: " + TextNorm.oneLine(line) + "\n").utf8))
    }
}
