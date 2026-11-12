import Foundation
import IMCore
import IMStore

/// A mutation as the policy sees it, before approval (DESIGN.md section 2).
public struct MutationRequest: Hashable, Sendable {
    public var binding: ApprovalBinding
    public var chat: ResolvedChat?
    /// Scope the action needs: `files` for any attachment, `text` otherwise.
    public var requiredScope: AllowScope
    /// Shown in the dialog only.
    public var text: String?
    public var parentText: String?
    public var attachmentName: String?
    public var attachmentBytes: Int64?

    public init(binding: ApprovalBinding, chat: ResolvedChat?, requiredScope: AllowScope, text: String? = nil,
                parentText: String? = nil, attachmentName: String? = nil, attachmentBytes: Int64? = nil) {
        self.binding = binding
        self.chat = chat
        self.requiredScope = requiredScope
        self.text = text
        self.parentText = parentText
        self.attachmentName = attachmentName
        self.attachmentBytes = attachmentBytes
    }
}

public enum PolicyDecision: Hashable, Sendable {
    /// Allowed chat, within scope and rate limits, and not an always-ask action.
    case allowed
    /// Needs the native dialog. The prompt is ready to present.
    case needsApproval(ApprovalPrompt)
    /// Refused before any dialog, for example foreground mode off or a group chat send while group sends are off.
    case refused(ActionResult)
}

public enum PolicyEngineError: Error, Hashable, Sendable {
    /// Unsend, edit, threaded reply and policy changes have no "Always allow" (section 2).
    case alwaysAllowNotOffered(MutationKind)
    /// The request names no chat, or its binding names a different one.
    case chatMismatch
}

/// Decides whether a mutation runs, asks, or is refused. Owner: IMPolicy.
///
/// Checklist (section 2), in the order `evaluate` applies it:
/// - Foreground actions with foreground mode off: refused with `error: foreground mode is off` and a fix naming
///   `imessage allow --foreground`. An untrusted store reads as foreground mode off.
/// - A chat action whose request has no chat, or whose binding names another chat: refused with `error: bad request`.
/// - Policy changes (`allow`, `revoke`, `--foreground`) always go through the dialog, without "Always allow".
/// - Untrusted store: every mutation asks, and "Always allow" re-approves the chat.
/// - Unsend, edit, threaded reply: always ask, no "Always allow". A threaded reply counts under the send rate limits,
///   so a breach is its dialog's reason in place of "threaded replies always ask".
/// - Not allowed, or scope `text` with an attachment: asks, and "Always allow" grants the action's scope.
/// - Rate limit breach on a send: asks, with the breach as the reason and no "Always allow", which wouldn't lift the
///   limit. A rate check that throws also asks (`rateLimitPrompt`).
/// - Otherwise allowed.
///
/// The scope an action needs is `files` if the request says so or its binding has an attachment digest, else `text`.
/// Every decision reads the store once, so the allowlist and foreground mode come from the same verified file.
public final class PolicyEngine {
    public let store: PolicyStore
    public let limiter: RateLimiter
    public let clock: Clock

    public init(store: PolicyStore, limiter: RateLimiter, clock: Clock) {
        self.store = store
        self.limiter = limiter
        self.clock = clock
    }

    /// IMCore's `ActionResult.foregroundModeOff`, so every module prints the same line.
    public static let foregroundModeOff = ActionResult.foregroundModeOff
    /// The bridge built a request whose chat is missing or differs from its binding. Nothing runs.
    public static let badRequest = ActionResult.badRequest

    public func evaluate(_ request: MutationRequest) throws -> PolicyDecision {
        let binding = request.binding
        let action = binding.action
        let snapshot = store.snapshot()

        if action.isForegroundAction && !snapshot.foregroundOn { return .refused(PolicyEngine.foregroundModeOff) }
        if PolicyEngine.needsChat(action) {
            guard let chat = request.chat, binding.chat == chat.canonical else {
                return .refused(PolicyEngine.badRequest)
            }
        }
        if action.isPolicyChange {
            return .needsApproval(prompt(request, reason: PolicyEngine.alwaysAskReason(action), alwaysAllow: false))
        }
        if case .untrusted = snapshot.load {
            let reason = "the allowed chats failed their tamper check, so every chat asks again"
            return .needsApproval(prompt(request, reason: reason, alwaysAllow: !action.alwaysAsks))
        }
        if action.alwaysAsks {
            if let limited = rateLimitPrompt(request) { return .needsApproval(limited) }
            return .needsApproval(prompt(request, reason: PolicyEngine.alwaysAskReason(action), alwaysAllow: false))
        }
        guard let chat = request.chat else { return .refused(PolicyEngine.badRequest) }
        guard let entry = snapshot.state.entries.first(where: { $0.chat == chat.canonical }) else {
            return .needsApproval(prompt(request, reason: "this chat isn't allowed yet", alwaysAllow: true))
        }
        if entry.scope < PolicyEngine.requiredScope(request) {
            return .needsApproval(prompt(request, reason: "this chat is allowed for text and tapbacks only",
                                         alwaysAllow: true))
        }
        if let limited = rateLimitPrompt(request) { return .needsApproval(limited) }
        return .allowed
    }

    /// The dialog for a send or threaded reply whose chat is over a rate limit, or nil when it is within them or the
    /// action isn't rate limited. The breach is the reason, a check that throws asks too, and there is no
    /// "Always allow", which wouldn't lift the limit. The bridge also calls this holding the queue.
    public func rateLimitPrompt(_ request: MutationRequest) -> ApprovalPrompt? {
        guard request.binding.action.isRateLimited, let chat = request.chat else { return nil }
        let reason: String
        do {
            guard let breach = try limiter.check(chat: chat) else { return nil }
            reason = breach.dialogReason
        } catch {
            reason = "the rate limits couldn't be checked"
        }
        var limited = prompt(request, reason: reason, alwaysAllow: false)
        limited.namesRateLimit = true
        return limited
    }

    /// Applies an "Always allow this chat" decision after the dialog returns: adds the chat, or widens it to the
    /// scope the approved action needs. On an untrusted store this starts a fresh, trusted allowlist.
    public func applyAlwaysAllow(_ request: MutationRequest) throws {
        let action = request.binding.action
        guard !action.alwaysAsks else { throw PolicyEngineError.alwaysAllowNotOffered(action) }
        guard let chat = request.chat, request.binding.chat == chat.canonical else {
            throw PolicyEngineError.chatMismatch
        }
        try store.allow(chat.canonical, label: chat.label, scope: PolicyEngine.requiredScope(request))
    }

    // MARK: - Internals

    static func requiredScope(_ request: MutationRequest) -> AllowScope {
        request.binding.attachmentDigest != nil ? .files : request.requiredScope
    }

    static func needsChat(_ action: MutationKind) -> Bool {
        switch action {
        case .send, .threadedReply, .react, .unsend, .edit, .allowChat, .revokeChat: return true
        case .foregroundOn, .foregroundOff: return false
        }
    }

    static func alwaysAskReason(_ action: MutationKind) -> String {
        switch action {
        case .unsend: return "unsend always asks"
        case .edit: return "edit always asks"
        case .threadedReply: return "threaded replies always ask"
        case .allowChat, .revokeChat: return "changes to the allowed chats always ask"
        case .foregroundOn, .foregroundOff: return "foreground mode changes always ask"
        case .send, .react: return "this action asks"
        }
    }

    private func prompt(_ request: MutationRequest, reason: String, alwaysAllow: Bool) -> ApprovalPrompt {
        let binding = request.binding
        let label = request.chat?.label ?? binding.chat?.rawValue ?? "this chat"
        let direct = request.chat.flatMap { $0.isGroup || $0.canonical.isGroup ? nil : $0 }
        return ApprovalPrompt(id: ShortID.make(), binding: binding, title: PolicyEngine.title(binding, label: label),
                              chatLabel: request.chat?.label, text: request.text, parentText: request.parentText,
                              attachmentName: request.attachmentName, attachmentBytes: request.attachmentBytes,
                              offersAlwaysAllow: alwaysAllow, reason: reason, sendHandle: direct?.sendHandle,
                              service: direct.map { PolicyEngine.sendService($0.service) })
    }

    /// The account `send_text` and `send_file` use for a chat's service: SMS for `SMS` and iMessage for any other,
    /// RCS included (BUILD-PLAN 16). The script's `is` ignores case, so this does too.
    static func sendService(_ service: String) -> String {
        service.caseInsensitiveCompare("SMS") == .orderedSame ? "SMS" : "iMessage"
    }

    static func title(_ binding: ApprovalBinding, label: String) -> String {
        switch binding.action {
        case .send:
            return binding.textDigest == nil && binding.attachmentDigest != nil
                ? "Send a file to \(label)" : "Send to \(label)"
        case .threadedReply: return "Reply in \(label)"
        case .react:
            let glyph = binding.tapback?.displayEmoji ?? "a tapback"
            return binding.remove ? "Remove \(glyph) in \(label)" : "React \(glyph) in \(label)"
        case .unsend: return "Unsend your message in \(label)"
        case .edit: return "Edit your message in \(label)"
        case .allowChat: return binding.scope == .files ? "Allow \(label), with files" : "Allow \(label)"
        case .revokeChat: return "Revoke \(label)"
        case .foregroundOn: return "Turn on foreground mode"
        case .foregroundOff: return "Turn off foreground mode"
        }
    }
}
