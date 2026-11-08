import Foundation
import IMCore
import IMStore

/// Mutations the policy sees (sections 2 to 5).
public enum MutationKind: String, Hashable, Codable, Sendable {
    case send
    case threadedReply
    case react
    case unsend
    case edit
    case allowChat
    case revokeChat
    case foregroundOn
    case foregroundOff

    /// Unsend, edit and threaded reply always need approval and their dialog has no "Always allow" (section 2).
    public var alwaysAsks: Bool {
        switch self {
        case .unsend, .edit, .threadedReply, .allowChat, .revokeChat, .foregroundOn, .foregroundOff: return true
        case .send, .react: return false
        }
    }

    /// `allow`, `revoke`, `allow --foreground` and `revoke --foreground` always go through the dialog (section 2).
    public var isPolicyChange: Bool {
        switch self {
        case .allowChat, .revokeChat, .foregroundOn, .foregroundOff: return true
        case .send, .threadedReply, .react, .unsend, .edit: return false
        }
    }

    /// Edit and threaded reply run only in foreground mode (section 4).
    public var isForegroundAction: Bool { self == .edit || self == .threadedReply }

    /// Sends and threaded replies count toward the rate limits (build plan item 2).
    public var isRateLimited: Bool { self == .send || self == .threadedReply }
}

/// What an approval is bound to (section 2, Everything else). An approval matches a request only if every field
/// is equal.
public struct ApprovalBinding: Hashable, Codable, Sendable {
    public var chat: CanonicalChatID?
    public var action: MutationKind
    /// `TextNorm.textDigest` of the text: the send text, the new text for an edit, or the reply text.
    public var textDigest: String?
    /// SHA-256 of the frozen attachment copy.
    public var attachmentDigest: String?
    /// Target message GUID and part for tapbacks, unsend and edit.
    public var targetGUID: String?
    public var targetPart: Int?
    /// Parent GUID for a threaded reply.
    public var parentGUID: String?
    public var tapback: TapbackKind?
    public var remove: Bool
    /// Scope requested by `allow`.
    public var scope: AllowScope?

    public init(chat: CanonicalChatID?, action: MutationKind, textDigest: String? = nil,
                attachmentDigest: String? = nil, targetGUID: String? = nil, targetPart: Int? = nil,
                parentGUID: String? = nil, tapback: TapbackKind? = nil, remove: Bool = false,
                scope: AllowScope? = nil) {
        self.chat = chat
        self.action = action
        self.textDigest = textDigest
        self.attachmentDigest = attachmentDigest
        self.targetGUID = targetGUID
        self.targetPart = targetPart
        self.parentGUID = parentGUID
        self.tapback = tapback
        self.remove = remove
        self.scope = scope
    }
}

/// What the dialog shows. Text is shown in the dialog but never written to the journal.
public struct ApprovalPrompt: Hashable, Sendable {
    public var id: String
    public var binding: ApprovalBinding
    /// For example `Send to Mom`, `Unsend your message in Dad`, `Turn on foreground mode`.
    public var title: String
    public var chatLabel: String?
    /// For a 1:1 chat, the handle the send addresses (`ResolvedChat.sendHandle`) and the account the send scripts use,
    /// `SMS` for an SMS chat and `iMessage` for any other, RCS included. Both come from the request's chat, the same
    /// value the action uses after approval. A threaded reply goes through the Messages UI, which picks the service,
    /// so its dialog doesn't show this one. Nil for a group and for a request with no chat.
    public var sendHandle: String?
    public var service: String?
    public var text: String?
    /// A threaded-reply approval shows the parent's text (section 2).
    public var parentText: String?
    public var attachmentName: String?
    public var attachmentBytes: Int64?
    /// False for unsend, edit, threaded reply, policy changes and rate-limit breaches on an allowed chat.
    public var offersAlwaysAllow: Bool
    /// The reason it asks: not allowed, scope too narrow, rate limit, always asks, store untrusted.
    public var reason: String
    /// True when `reason` is a rate-limit breach or a rate check that failed, so an approval of this dialog was
    /// given knowing the limit.
    public var namesRateLimit: Bool

    public init(id: String, binding: ApprovalBinding, title: String, chatLabel: String?, text: String?,
                parentText: String?, attachmentName: String?, attachmentBytes: Int64?, offersAlwaysAllow: Bool,
                reason: String, namesRateLimit: Bool = false, sendHandle: String? = nil, service: String? = nil) {
        self.id = id
        self.binding = binding
        self.title = title
        self.chatLabel = chatLabel
        self.sendHandle = sendHandle
        self.service = service
        self.text = text
        self.parentText = parentText
        self.attachmentName = attachmentName
        self.attachmentBytes = attachmentBytes
        self.offersAlwaysAllow = offersAlwaysAllow
        self.reason = reason
        self.namesRateLimit = namesRateLimit
    }
}

/// Buttons: Deny (default), Allow once, Always allow this chat (section 2).
public enum ApprovalDecision: String, Hashable, Codable, Sendable {
    case deny
    case allowOnce
    case alwaysAllow
}

/// Shows the native dialog. Live: `IMBridge.ApprovalPanelController` (AppKit NSPanel). Tests: a fake that answers.
///
/// What the live panel must do (section 2): Deny is the default button. The allow buttons have no key equivalent and
/// stay disabled for `Limits.approvalButtonDelay`. "Always allow this chat" is shown only when
/// `ApprovalPrompt.offersAlwaysAllow` is true. `ApprovalBook` enforces the last two again on the decision it gets.
public protocol ApprovalPresenting: AnyObject {
    /// Shows the panel. Calls `decided` once, on any thread. Never blocks the caller.
    func present(_ prompt: ApprovalPrompt, decided: @escaping (ApprovalDecision) -> Void)
    /// Closes the panel without a decision (expiry).
    func withdraw(id: String)
}

public enum ApprovalStatus: Hashable, Sendable {
    case pending
    case decided(ApprovalDecision)
    case expired
    case consumed
    case unknown
}

/// Pending and decided approvals. Single use, 10-minute expiry (section 2). Owner: IMPolicy.
///
/// - `open` presents the dialog and returns its id.
/// - `wait` blocks up to `seconds` (the CLI's 120 s) and returns the status then.
/// - `consume` succeeds once, only for an allow decision, only for an equal binding, only before expiry.
/// - An approval unanswered for 10 minutes becomes `.expired`, and its request resolves to `denied: approval expired`.
///
/// Rules on the decision the presenter reports:
/// - The first decision counts. Later ones, and any that arrive after expiry, are ignored.
/// - An allow that arrives sooner than `Limits.approvalButtonDelay` after the panel was shown can't have come from
///   an enabled button, so it is recorded as deny.
/// - "Always allow" on a prompt that didn't offer it is recorded as "Allow once".
///
/// An approval is valid while `clock.now` is before `createdAt + Limits.approvalExpiry`; at exactly 10 minutes it
/// has expired. A decided allow that nobody consumed expires too. Deny stays deny.
///
/// Waits poll through the injected clock every `pollInterval`, so tests on `FakeClock` run a 120 s wait at once.
/// Thread safe: the presenter may decide on the main thread while connection threads wait and consume.
public final class ApprovalBook {
    public let clock: Clock
    public let presenter: ApprovalPresenting

    static let pollInterval: TimeInterval = 0.05

    private struct Record {
        var prompt: ApprovalPrompt
        var createdAt: Date
        var expiresAt: Date
        /// `clock.uptime` when the panel was presented, for the 1 s button delay.
        var presentedUptime: TimeInterval
        var decision: ApprovalDecision?
        var consumed = false
        var withdrawn = false
    }

    private let lock = NSLock()
    private var records: [String: Record] = [:]

    public init(clock: Clock, presenter: ApprovalPresenting) {
        self.clock = clock
        self.presenter = presenter
    }

    /// Registers the prompt and presents it. Keeps `prompt.id` unless it is empty or already in use, in which case
    /// it picks a fresh one. Returns the id the approval goes by.
    public func open(_ prompt: ApprovalPrompt) -> String {
        var prompt = prompt
        lock.lock()
        if prompt.id.isEmpty || records[prompt.id] != nil {
            repeat { prompt.id = ShortID.make() } while records[prompt.id] != nil
        }
        let now = clock.now
        records[prompt.id] = Record(prompt: prompt, createdAt: now, expiresAt: now.addingTimeInterval(Limits.approvalExpiry),
                                    presentedUptime: clock.uptime)
        lock.unlock()
        let id = prompt.id
        presenter.present(prompt) { [weak self] decision in self?.decide(id, decision) }
        return id
    }

    public func wait(id: String, seconds: TimeInterval) -> ApprovalStatus {
        let deadline = clock.uptime + max(0, seconds)
        while true {
            let current = status(id: id)
            if current != .pending { return current }
            let remaining = deadline - clock.uptime
            if remaining <= 0 { return .pending }
            clock.sleep(min(ApprovalBook.pollInterval, remaining))
        }
    }

    public func status(id: String) -> ApprovalStatus {
        lock.lock()
        let (status, withdraw) = statusLocked(id)
        lock.unlock()
        if withdraw { presenter.withdraw(id: id) }
        return status
    }

    public func consume(id: String, binding: ApprovalBinding) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard var record = records[id], !record.consumed, let decision = record.decision, decision != .deny,
              clock.now < record.expiresAt, record.prompt.binding == binding else { return false }
        record.consumed = true
        records[id] = record
        return true
    }

    /// Open approvals, oldest first, for `imessage pending`.
    public func pendingItems() -> [PendingItem] {
        lock.lock()
        defer { lock.unlock() }
        let now = clock.now
        return records.values
            .filter { $0.decision == nil && !$0.consumed && now < $0.expiresAt }
            .sorted { ($0.createdAt, $0.prompt.id) < ($1.createdAt, $1.prompt.id) }
            .map { PendingItem(id: $0.prompt.id, summary: ApprovalBook.summary($0.prompt), createdAt: $0.createdAt,
                               expiresAt: $0.expiresAt) }
    }

    /// Withdraws panels past expiry. The bridge calls it on a timer. Records more than 10 minutes past their expiry
    /// are forgotten; by then the journal holds the request's result.
    public func expireOld() {
        lock.lock()
        let now = clock.now
        var toWithdraw: [String] = []
        for (id, record) in records {
            if now >= record.expiresAt.addingTimeInterval(Limits.approvalExpiry) {
                if record.decision == nil && !record.withdrawn { toWithdraw.append(id) }
                records[id] = nil
                continue
            }
            if case (_, true) = statusLocked(id) { toWithdraw.append(id) }
        }
        lock.unlock()
        for id in toWithdraw.sorted() { presenter.withdraw(id: id) }
    }

    /// True while any dialog is open; the bridge stays resident then (section 1).
    public var hasOpenApprovals: Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = clock.now
        return records.values.contains { $0.decision == nil && !$0.consumed && now < $0.expiresAt }
    }

    // MARK: - Internals

    private func decide(_ id: String, _ reported: ApprovalDecision) {
        lock.lock()
        defer { lock.unlock() }
        guard var record = records[id], record.decision == nil, !record.consumed, !record.withdrawn,
              clock.now < record.expiresAt else { return }
        var decision = reported
        if decision != .deny, clock.uptime - record.presentedUptime < Limits.approvalButtonDelay {
            decision = .deny
        }
        if decision == .alwaysAllow, !record.prompt.offersAlwaysAllow {
            decision = .allowOnce
        }
        record.decision = decision
        records[id] = record
    }

    /// The status, and whether the panel needs withdrawing because this call found it expired.
    private func statusLocked(_ id: String) -> (ApprovalStatus, Bool) {
        guard var record = records[id] else { return (.unknown, false) }
        if record.consumed { return (.consumed, false) }
        let expired = clock.now >= record.expiresAt
        if let decision = record.decision {
            if decision == .deny { return (.decided(.deny), false) }
            return (expired ? .expired : .decided(decision), false)
        }
        guard expired else { return (.pending, false) }
        if record.withdrawn { return (.expired, false) }
        record.withdrawn = true
        records[id] = record
        return (.expired, true)
    }

    /// `send to Mom "On my way"`.
    static func summary(_ prompt: ApprovalPrompt) -> String {
        var s = prompt.title
        if let first = s.first { s = first.lowercased() + s.dropFirst() }
        if let text = prompt.text.map(TextNorm.oneLine), !text.isEmpty {
            let cut = text.count > Limits.quoteChars ? String(text.prefix(Limits.quoteChars)) + "…" : text
            s += " \"\(cut)\""
        } else if let name = prompt.attachmentName {
            s += " \(name)"
        }
        return s
    }
}
