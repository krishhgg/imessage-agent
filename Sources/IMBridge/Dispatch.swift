import Foundation
import IMCore
import IMForeground
import IMPolicy
import IMSend
import IMStore
import IMUI

/// Routes each `RequestBody` case to its module. Owner: IMBridge.
///
/// - Reads (`chats`, `unread`, `messages`, `message`, `search`, `contacts`, `changes`, `attachment`) go to IMStore.
///   Every `StoreError` and `AttachmentError` case maps to a one-line `WireError` with a fix: `severalMatches`
///   becomes `error: several matches` with candidates. A file outside the Attachments root throws
///   `StoreError.notFound`. An offloaded or missing file isn't an error: the export's result is `not_downloaded`.
/// - `attachment` calls `AttachmentService.export(_:convertHEIC:)` with `convertHEIC` true only while
///   `capabilities.status(.attachmentConversion)` is `supported`.
/// - `wait` loops `ReadService.nextInbound` every second until the timeout, or until the client hangs up. Agent-sent
///   GUIDs never count.
/// - `send`, `ui`, `allow`, `revoke` go to `MutationPipeline`. `pending` goes to the pipeline's approval book.
/// - `caps`, `status`, `setup`, `doctor`, `ping` go to the services.
///
/// Every op that reads chat.db first calls `openStoreIfNeeded`, so a Full Disk Access grant reaches the running
/// bridge on the next request. Upload bytes are accepted only on `send`; any other op that announces an upload gets
/// `error: bad request`. One dispatcher serves every connection at once; it keeps no state of its own.
public final class OpDispatcher: RequestHandling {
    public let container: BridgeContainer
    let pipeline: MutationPipeline

    /// `wait` polls chat.db this often.
    static let waitPollInterval: TimeInterval = 1
    /// The longest `wait` the bridge serves, so a connection thread never blocks without end.
    static let maxWaitTimeout: TimeInterval = 3600

    public init(container: BridgeContainer) {
        self.container = container
        self.pipeline = MutationPipeline(container: container)
    }

    public func handle(_ request: Request, upload: UploadReading?, events: @escaping (BridgeEvent) -> Void,
                       peerGone: @escaping () -> Bool) -> Response {
        Response(id: request.id, payload: payload(for: request, upload: upload, events: events, peerGone: peerGone))
    }

    func payload(for request: Request, upload: UploadReading?, events: @escaping (BridgeEvent) -> Void,
                 peerGone: () -> Bool = { false }) -> ResponsePayload {
        guard request.v == Request.protocolVersion else { return .failure(WireError(result: .badRequest)) }
        if request.upload != nil, request.body.op != .send { return .failure(WireError(result: .badRequest)) }
        let c = container
        switch request.body {
        case .chats(let args): return read(.chats) { .chats(try $0.chats(args)) }
        case .unread(let args): return read(.unread) { .unread(try $0.unread(args)) }
        case .messages(let args): return read(.messages) { .messages(try $0.messages(args)) }
        case .message(let args): return read(.message) { .message(try $0.message(args)) }
        case .search(let args): return read(.search) { .search(try $0.search(args)) }
        case .contacts(let args): return read(.contacts) { .contacts(try $0.contacts(args)) }
        case .changes(let args): return read(.changes) { .changes(try $0.changes(args)) }
        case .attachment(let args): return attachment(args)
        case .wait(let args): return wait(args, peerGone: peerGone)
        case .send(let args): return pipeline.send(args, upload: upload, header: request.upload, events: events)
        case .ui(let args): return pipeline.ui(args, events: events)
        case .allow(let args): return pipeline.allow(args, events: events)
        case .revoke(let args): return pipeline.revoke(args, events: events)
        case .pending(let args): return pipeline.pending(args)
        case .caps:
            let trusted = c.permissions.accessibility(prompt: false) == .granted
            return .caps(c.capabilities.report(accessibilityTrusted: trusted, foregroundMode: c.policy.isForegroundModeOn))
        case .status: return .status(StatusService(container: c).status())
        case .setup(let args): return .setup(SetupService(container: c).run(args))
        case .doctor(let args): return .doctor(DoctorService(container: c).run(args))
        case .ping: return .pong(PongInfo(bridgeVersion: AppIdentity.version, pid: getpid()))
        }
    }

    // MARK: - Reads

    private func read(_ op: Op, _ body: (ReadService) throws -> ResponsePayload) -> ResponsePayload {
        if let failure = StoreAccess.openFailure(container) { return .failure(failure) }
        guard let reads = container.reads else { return .failure(StoreAccess.notOpen) }
        do {
            return try body(reads)
        } catch {
            return .failure(WireErrors.map(error, op: op))
        }
    }

    private func attachment(_ args: AttachmentArgs) -> ResponsePayload {
        if let failure = StoreAccess.openFailure(container) { return .failure(failure) }
        guard let attachments = container.attachments else { return .failure(StoreAccess.notOpen) }
        let convert = container.capabilities.status(.attachmentConversion) == .supported
        do {
            return .attachment(try attachments.export(args, convertHEIC: convert))
        } catch {
            return .failure(WireErrors.map(error, op: .attachment))
        }
    }

    /// The first inbound message above the newest row at the start, from `fromWho` if given, else `timeout`. Stops
    /// after the poll in which `peerGone` first says the client hung up, so a killed CLI doesn't keep a connection
    /// thread polling chat.db until the timeout.
    private func wait(_ args: WaitArgs, peerGone: () -> Bool) -> ResponsePayload {
        if let failure = StoreAccess.openFailure(container) { return .failure(failure) }
        guard let reads = container.reads, let db = container.db else { return .failure(StoreAccess.notOpen) }
        let clock = container.clock
        let timeout = min(max(0, args.timeout.isFinite ? args.timeout : 0), OpDispatcher.maxWaitTimeout)
        do {
            let chat = try args.fromWho.map { try db.resolve($0) }
            let start = try reads.maxMessageRowID()
            let deadline = clock.uptime + timeout
            while true {
                if let (ref, message) = try reads.nextInbound(afterRowID: start, in: chat) {
                    return .wait(WaitOutcome(chat: ref, message: message, timedOut: false))
                }
                let left = deadline - clock.uptime
                if left <= 0 { return .wait(WaitOutcome(chat: nil, message: nil, timedOut: true)) }
                clock.sleep(min(OpDispatcher.waitPollInterval, left))
                // Nobody reads this answer.
                if peerGone() { return .wait(WaitOutcome(chat: nil, message: nil, timedOut: true)) }
            }
        } catch {
            return .failure(WireErrors.map(error, op: .wait))
        }
    }
}

/// Every mutation's path through policy, approval, journal, queue and the acting module (DESIGN.md sections 2 to 4).
/// Owner: IMBridge.
///
/// Order for one request:
/// 1. Resolve the target (`error: several matches` runs nothing). A UI action resolves its message with
///    `messageTarget(rowid:)` and its chat with `ChatDatabase.resolve(chatRowID:)`. `send --thread` reads the parent
///    with `newestIncoming(for:)`: the binding gets its GUID and the dialog its body. Freeze the upload and hash it.
/// 2. Reject `send --thread --file` and foreground actions with foreground mode off. A UI action or threaded reply in
///    a group chat returns `unsupported_target`. An image file (ImageIO
///    recognizes the frozen bytes as an image) returns `unsupported` and sends nothing while
///    `capabilities.status(.imageSend)` isn't `supported`. A group send returns `unsupported` while `.groupSend`
///    isn't.
/// 3. Build the binding (digests with `TextNorm.textDigest`) and the idempotency key. If crash recovery hasn't
///    finished, retry it and answer `journal write failed` if it fails again. Then claim the key with
///    `journal.claim(key:again:action:chat:binding:)`. It looks the key up and journals `received` under one lock,
///    so two requests with the same key can't both run. `.found` answers with the lookup (replay, `pending <id>`,
///    `may_have_completed`, re-read reaction) and runs nothing.
/// 4. Evaluate policy. If it asks: open the dialog, record its id with `journal.attachApproval(id, approvalID:)`,
///    emit `approvalShown`, wait up to the CLI's approval wait. On timeout return `pending <id>` and keep going in
///    the background; `pending <id>` collects the result later. Deny: `denied` (holds the key). Expiry:
///    `denied: approval expired` (doesn't). After an "Always allow" decision is consumed, call
///    `engine.applyAlwaysAllow(request)`.
/// 5. Journal `approved`. Check Undo Send and edit windows (`expired`).
/// 6. Hidden actions and sends: take the queue (30 s, `busy: queue`). A send that policy allowed without a dialog
///    calls `RateLimiter.check` again while holding the queue, because two requests to one chat can both pass the
///    first check. On a breach it releases the queue and goes through the dialog. Foreground actions: the machine
///    takes the queue.
/// 7. Run IMSend, IMUI or IMForeground with `journal.recorder(for:)`. For a foreground action, call
///    `journal.markForeground(id, true)` right before `ForegroundMachine.run`.
/// 8. Journal `final` with the result (which clears `foreground`). For a send that reached `invoking`, call
///    `limiter.record` with `journal.sendEvent(for: id)`. Add sent GUIDs, release the queue.
///
/// Requests refused in steps 1 and 2 never reach the journal. Request-level errors answer with `.failure`; an
/// `unsupported`, `untested`, `expired` or `already` found before the claim answers with the action's own payload.
/// Thread safe: every connection calls the same pipeline, and its state lives in the container.
public final class MutationPipeline {
    public let container: BridgeContainer

    public init(container: BridgeContainer) { self.container = container }

    public func send(_ args: SendArgs, upload: UploadReading?, header: UploadHeader?,
                     events: @escaping (BridgeEvent) -> Void) -> ResponsePayload {
        let c = container
        let startedAt = c.clock.uptime
        if let failure = StoreAccess.openFailure(c) { return .failure(failure) }
        guard let db = c.db else { return .failure(StoreAccess.notOpen) }
        let chat: ResolvedChat
        do {
            chat = try db.resolve(args.who)
        } catch {
            return .failure(WireErrors.map(error, op: .send))
        }

        if args.thread {
            if header != nil { return .failure(WireError(result: .threadWithFile)) }
            guard c.policy.isForegroundModeOn else { return .failure(WireError(result: .foregroundModeOff)) }
            guard c.foreground != nil else { return .failure(WireError(result: MutationPipeline.foregroundUnavailable)) }
        }
        let text = args.text.flatMap { TextNorm.matchKey($0).isEmpty ? nil : $0 }
        guard text != nil || (header != nil && !args.thread) else {
            return .failure(WireError(result: MessageSender.badRequest))
        }

        var parent: MessageTargetInfo?
        if args.thread {
            do {
                parent = try db.newestIncoming(for: chat)
            } catch {
                return .failure(WireErrors.map(error, op: .send))
            }
            guard parent != nil else {
                return .failure(.message("no incoming message to reply to in \(chat.label)", fix: "send without --thread"))
            }
        }

        let outcome = { (early: ActionResult?, approved: Bool, parts: [SendPartOutcome], replayed: Bool) -> SendOutcome in
            SendOutcome(chat: chat.ref, approved: approved, early: early, text: text, threadParentRowID: parent?.rowid,
                        parts: parts, replayed: replayed)
        }

        // A threaded reply is a UI action, and v1 UI actions work on 1:1 chats only (section 4, Chat).
        if args.thread, chat.isGroup || chat.canonical.isGroup {
            return .send(outcome(ActionResult(.unsupportedTarget), false, [], false))
        }
        if args.thread, c.permissions.accessibility(prompt: false) != .granted {
            return .send(outcome(UIResults.accessibilityMissing, false, [], false))
        }
        if args.thread, let gated = MutationPipeline.gate(c.capabilities.status(.threadedReply)) {
            return .send(outcome(gated, false, [], false))
        }

        var file: FrozenFile?
        if let header {
            guard header.isValid, let upload else { return .failure(WireError(result: .badRequest)) }
            do {
                file = try c.uploads.freeze(header: header) { try upload.read(into: $0) }
            } catch {
                return .failure(WireErrors.upload(error))
            }
        }
        let uploads = c.uploads
        let frozen = file
        let discard = { if let frozen { uploads.discard(frozen) } }

        if let file, file.isImage, c.capabilities.status(.imageSend) != .supported {
            discard()
            return .send(outcome(MutationPipeline.imageUnsupported, false, [], false))
        }
        if chat.isGroup, c.capabilities.status(.groupSend) != .supported {
            discard()
            return .send(outcome(MessageSender.groupUnsupported, false, [], false))
        }

        let action: MutationKind = args.thread ? .threadedReply : .send
        let textDigest = text.map(TextNorm.textDigest)
        let binding = ApprovalBinding(chat: chat.canonical, action: action, textDigest: textDigest,
                                      attachmentDigest: file?.sha256, parentGUID: parent?.guid)
        let key = IdempotencyKey.send(chat: chat.canonical, threaded: args.thread, parentGUID: parent?.guid,
                                      textDigest: textDigest, attachmentDigest: file?.sha256)
        let request = MutationRequest(binding: binding, chat: chat, requiredScope: file == nil ? .text : .files,
                                      text: text, parentText: parent?.body, attachmentName: file?.originalName,
                                      attachmentBytes: file?.byteCount)
        let early = { (result: ActionResult, approved: Bool) in ResponsePayload.send(outcome(result, approved, [], false)) }
        let repeated = { (result: ActionResult) in ResponsePayload.send(outcome(result, false, [], true)) }

        let act: (ActionContext) -> ActionOutcome
        if args.thread, let parent, let text {
            act = { [c] ctx in
                let start = MutationPipeline.runForeground(c, ctx, chat: chat, action: .threadedReply(parent: parent, text: text))
                guard case .ran(let run) = start else {
                    let refusal = MutationPipeline.refusal(start)
                    return ActionOutcome(result: refusal, payload: early(refusal, ctx.approved))
                }
                let part = SendPartOutcome(part: .text, result: run.result, guid: run.sentGUID)
                return ActionOutcome(result: run.result, payload: .send(outcome(nil, ctx.approved, [part], false)),
                                     sentGUIDs: run.sentGUID.map { [$0] } ?? [], ticket: run.ticket)
            }
        } else {
            act = { [c] ctx in
                guard let sender = c.sender else {
                    return ActionOutcome(result: MessageSender.chatDBUnreadable,
                                         payload: early(MessageSender.chatDBUnreadable, ctx.approved))
                }
                let sent = sender.send(SendRequest(chat: chat, text: text, file: frozen), recorder: ctx.recorder)
                let overall = sent.parts.first { $0.result.holdsIdempotencyKey }?.result
                    ?? sent.parts.first?.result ?? ActionResult(.mayHaveCompleted)
                let parts = MutationPipeline.withAttachments(sent.parts, reads: c.reads)
                return ActionOutcome(result: overall, payload: .send(outcome(nil, ctx.approved, parts, false)),
                                     sentGUIDs: sent.sentGUIDs)
            }
        }

        let job = MutationJob(
            key: key, again: args.again, request: request, approvalWait: MutationPipeline.clampWait(args.approvalWait),
            startedAt: startedAt, queue: args.thread ? .foreground : .pipeline, windowOpen: nil, early: early,
            found: { lookup in
                MutationPipeline.answer(lookup, repeated: repeated) { payload in
                    guard case .send(var o) = payload else { return payload }
                    o.replayed = true
                    o.text = text
                    return .send(o)
                }
            },
            act: act, cleanup: discard)
        return run(job, events: events)
    }

    public func ui(_ args: UIArgs, events: @escaping (BridgeEvent) -> Void) -> ResponsePayload {
        let c = container
        let startedAt = c.clock.uptime
        if let failure = StoreAccess.openFailure(c) { return .failure(failure) }
        guard let db = c.db else { return .failure(StoreAccess.notOpen) }

        let rowid: Int64
        let kind: UIActionKind
        var tapback: TapbackKind?
        var remove = false
        var newText: String?
        switch args.action {
        case .react(let r, let k, let rm):
            (rowid, kind, tapback, remove) = (r, .react, k, rm)
        case .unsend(let r):
            (rowid, kind) = (r, .unsend)
        case .edit(let r, let t):
            (rowid, kind, newText) = (r, .edit, t)
        }

        let target: MessageTargetInfo
        let chat: ResolvedChat
        do {
            guard let found = try db.messageTarget(rowid: rowid) else {
                return .failure(.message("no message \(rowid)", fix: "imessage read <who> shows message ids"))
            }
            guard let resolved = try db.resolve(chatRowID: found.chatRowID) else {
                return .failure(.message("no chat for message \(rowid)", fix: "imessage chats"))
            }
            (target, chat) = (found, resolved)
        } catch {
            return .failure(WireErrors.map(error, op: .ui))
        }

        if kind == .edit {
            guard let t = newText, !TextNorm.matchKey(t).isEmpty else {
                return .failure(.message("edit needs the new text", fix: "imessage edit <msg> <text>"))
            }
            guard c.policy.isForegroundModeOn else { return .failure(WireError(result: .foregroundModeOff)) }
            guard c.foreground != nil else { return .failure(WireError(result: MutationPipeline.foregroundUnavailable)) }
        }

        let quote = ReplyRef(rowid: target.rowid, senderName: target.fromMe ? "You" : target.senderName, text: target.body)
        let outcome = { (result: ActionResult, approved: Bool, current: TapbackKind?, replayed: Bool) -> UIOutcome in
            UIOutcome(action: kind, targetRowID: rowid, chat: chat.ref, tapback: tapback, remove: remove,
                      approved: approved, result: result, currentReaction: current, replayed: replayed,
                      targetQuote: quote)
        }

        let editState = kind == .unsend ? (try? db.editState(rowid: target.rowid)) ?? nil : nil
        if let refusal = MutationPipeline.targetRefusal(kind, target: target, chat: chat, editState: editState) {
            return .ui(outcome(refusal, false, nil, false))
        }
        let capability: Capability
        switch kind {
        case .react: capability = .tapback(tapback ?? .heart, onOwnMessage: target.fromMe)
        case .unsend: capability = .unsend
        case .edit: capability = .edit
        }
        // Without the grant the action can't run, so no dialog opens and nothing is journaled.
        if c.permissions.accessibility(prompt: false) != .granted {
            return .ui(outcome(UIResults.accessibilityMissing, false, nil, false))
        }
        if let gated = MutationPipeline.gate(c.capabilities.status(capability)) {
            return .ui(outcome(gated, false, nil, false))
        }

        let clock = c.clock
        var windowOpen: (() -> Bool)?
        switch kind {
        case .unsend: windowOpen = { ActionWindows.undoSendOpen(rowDateNs: target.dateNs, now: clock.now) }
        case .edit: windowOpen = { ActionWindows.editOpen(rowDateNs: target.dateNs, now: clock.now) }
        case .react: windowOpen = nil
        }
        if let open = windowOpen, !open() { return .ui(outcome(ActionResult(.expired), false, nil, false)) }

        if kind == .react, let kindToSet = tapback {
            let current: TapbackKind?
            do {
                current = try db.currentUserReaction(messageGUID: target.guid, part: 0)
            } catch {
                return .failure(WireErrors.map(error, op: .ui))
            }
            let nothingToChange = remove ? current != kindToSet : current == kindToSet
            if nothingToChange { return .ui(outcome(ActionResult(.already), false, current, false)) }
        }

        let action: MutationKind = kind == .react ? .react : kind == .unsend ? .unsend : .edit
        let newDigest = newText.map(TextNorm.textDigest)
        let binding = ApprovalBinding(chat: chat.canonical, action: action, textDigest: newDigest, targetGUID: target.guid,
                                      targetPart: 0, tapback: tapback, remove: remove)
        let key = IdempotencyKey.ui(action: kind, targetGUID: target.guid, part: 0, remove: remove, tapback: tapback,
                                    newTextDigest: newDigest)
        let request = MutationRequest(binding: binding, chat: chat, requiredScope: .text,
                                      text: kind == .edit ? newText : target.body,
                                      parentText: kind == .edit ? target.body : nil)
        let early = { (result: ActionResult, approved: Bool) in ResponsePayload.ui(outcome(result, approved, nil, false)) }
        let repeated = { (result: ActionResult) in ResponsePayload.ui(outcome(result, false, nil, true)) }

        let act: (ActionContext) -> ActionOutcome
        switch args.action {
        case .react(_, let k, let rm):
            act = { [c] ctx in
                guard let runner = c.tapbacks else {
                    return ActionOutcome(result: StoreAccess.readFailed, payload: early(StoreAccess.readFailed, ctx.approved))
                }
                let done = runner.run(TapbackRequest(target: target, chat: chat, kind: k, remove: rm),
                                      queueDeadline: ctx.queueDeadline, recorder: ctx.recorder)
                return ActionOutcome(result: done.result,
                                     payload: .ui(outcome(done.result, ctx.approved, done.currentReaction, false)))
            }
        case .unsend:
            act = { [c] ctx in
                guard let runner = c.unsend else {
                    return ActionOutcome(result: StoreAccess.readFailed, payload: early(StoreAccess.readFailed, ctx.approved))
                }
                let done = runner.run(target: target, chat: chat, queueDeadline: ctx.queueDeadline, recorder: ctx.recorder)
                return ActionOutcome(result: done.result, payload: .ui(outcome(done.result, ctx.approved, nil, false)))
            }
        case .edit(_, let t):
            act = { [c] ctx in
                let start = MutationPipeline.runForeground(c, ctx, chat: chat, action: .edit(target: target, newText: t))
                guard case .ran(let run) = start else {
                    let refusal = MutationPipeline.refusal(start)
                    return ActionOutcome(result: refusal, payload: early(refusal, ctx.approved))
                }
                return ActionOutcome(result: run.result, payload: .ui(outcome(run.result, ctx.approved, nil, false)),
                                     ticket: run.ticket)
            }
        }

        let job = MutationJob(
            key: key, again: args.again, request: request, approvalWait: MutationPipeline.clampWait(args.approvalWait),
            startedAt: startedAt, queue: kind == .edit ? .foreground : .pipeline, windowOpen: windowOpen, early: early,
            found: { [c] lookup in
                if case .rereadReaction(let entry) = lookup {
                    let current = (try? c.db?.currentUserReaction(messageGUID: target.guid, part: 0)) ?? nil
                    guard case .ui(var o)? = entry.response else {
                        return .ui(outcome(entry.result ?? ActionResult(.ok), false, current, true))
                    }
                    o.replayed = true
                    o.currentReaction = current
                    o.targetQuote = quote
                    return .ui(o)
                }
                return MutationPipeline.answer(lookup, repeated: repeated) { payload in
                    guard case .ui(var o) = payload else { return payload }
                    o.replayed = true
                    o.targetQuote = quote
                    return .ui(o)
                }
            },
            act: act)
        return run(job, events: events)
    }

    public func allow(_ args: AllowArgs, events: @escaping (BridgeEvent) -> Void) -> ResponsePayload {
        policyChange(who: args.who, foreground: args.foreground, on: true, scope: args.files ? .files : .text,
                     approvalWait: args.approvalWait, events: events)
    }

    public func revoke(_ args: RevokeArgs, events: @escaping (BridgeEvent) -> Void) -> ResponsePayload {
        policyChange(who: args.who, foreground: args.foreground, on: false, scope: nil, approvalWait: args.approvalWait,
                     events: events)
    }

    /// `pending` lists open approvals; `pending <id>` finds the request with `journal.entry(pendingID:)` and returns
    /// its finished response or `pending <id>`.
    ///
    /// A request finished in this bridge run answers with its full response, message text included. One finished
    /// before a restart answers with the journal's copy, which has no message text.
    public func pending(_ args: PendingArgs) -> ResponsePayload {
        let c = container
        guard let id = args.id, !id.isEmpty else { return .pending(PendingList(items: c.approvals.pendingItems())) }
        let entry = c.journal.entry(pendingID: id) ?? c.inFlight.entryID(forApproval: id).flatMap { c.journal.entry($0) }
        guard let entry else {
            return .failure(.message("no request \(id)", fix: "imessage pending lists open approvals"))
        }
        if let finished = c.inFlight.finalPayload(entry.id) { return finished }
        if entry.state == .final {
            if let response = entry.response { return response }
            return .failure(WireError(result: entry.result ?? ActionResult(.mayHaveCompleted)))
        }
        if let waiting = c.inFlight.pendingPayload(entry.id) { return waiting }
        return .failure(WireError(result: ActionResult(.pending(id: entry.approvalID ?? entry.id))))
    }

    // MARK: - Policy changes

    private func policyChange(who: String?, foreground: Bool, on: Bool, scope: AllowScope?, approvalWait: TimeInterval,
                              events: @escaping (BridgeEvent) -> Void) -> ResponsePayload {
        let c = container
        let startedAt = c.clock.uptime
        let named = who.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
        guard named != foreground else { return .failure(WireError(result: .badRequest)) }

        let change: PolicyChange
        let action: MutationKind
        var chat: ResolvedChat?
        if foreground {
            (change, action) = on ? (.foregroundOn, .foregroundOn) : (.foregroundOff, .foregroundOff)
            if c.policy.isForegroundModeOn == on {
                return .policy(PolicyOutcome(change: change, chat: nil, scope: nil, result: ActionResult(.already)))
            }
        } else {
            (change, action) = on ? (.allowChat, .allowChat) : (.revokeChat, .revokeChat)
            if let failure = StoreAccess.openFailure(c) { return .failure(failure) }
            guard let db = c.db, let who else { return .failure(StoreAccess.notOpen) }
            do {
                chat = try db.resolve(who)
            } catch {
                return .failure(WireErrors.map(error, op: on ? .allow : .revoke))
            }
        }
        let resolved = chat
        let outcome = { (result: ActionResult) in
            ResponsePayload.policy(PolicyOutcome(change: change, chat: resolved?.ref, scope: scope, result: result))
        }
        if let chat {
            let entry = c.policy.entry(for: chat.canonical)
            if on, let entry, let scope, entry.scope >= scope { return outcome(ActionResult(.already)) }
            if !on, entry == nil { return outcome(ActionResult(.already)) }
        }

        let binding = ApprovalBinding(chat: chat?.canonical, action: action, scope: scope)
        let request = MutationRequest(binding: binding, chat: chat, requiredScope: scope ?? .text)
        let policy = c.policy
        let act: (ActionContext) -> ActionOutcome = { ctx in
            do {
                try ctx.recorder.willInvoke(InvocationFacts())
            } catch {
                return ActionOutcome(result: .journalWriteFailed, payload: outcome(.journalWriteFailed))
            }
            var result = ActionResult(.ok)
            do {
                switch change {
                case .allowChat:
                    if let chat { try policy.allow(chat.canonical, label: chat.label, scope: scope ?? .text) }
                case .revokeChat:
                    if let chat { try policy.revoke(chat.canonical) }
                case .foregroundOn:
                    try policy.setForegroundMode(true)
                case .foregroundOff:
                    try policy.setForegroundMode(false)
                }
            } catch {
                result = MutationPipeline.policySaveFailed
            }
            try? ctx.recorder.didInvoke()
            return ActionOutcome(result: result, payload: outcome(result))
        }
        // Policy changes have no `--again`, so each one gets a key of its own and always reaches the dialog.
        let job = MutationJob(
            key: IdempotencyKey(value: "policy-" + UUID().uuidString, targetSlot: nil), again: true, request: request,
            approvalWait: MutationPipeline.clampWait(approvalWait), startedAt: startedAt, queue: .none, windowOpen: nil,
            early: { result, _ in outcome(result) },
            found: { lookup in MutationPipeline.answer(lookup, repeated: outcome) { $0 } },
            act: act)
        return run(job, events: events)
    }
}
