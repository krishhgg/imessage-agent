import Foundation

// The full result vocabulary of DESIGN.md sections 2, 3, 4 and 5. Every string a result line can start with
// is produced here and nowhere else. The bridge sends `ActionResult` values; the CLI renders `rendered`.

/// Why a send or action failed after it may have reached Messages, or why it never ran.
public enum FailureReason: Hashable, Sendable {
    /// `failed <error>`: the row's `error` column is nonzero (section 3 item 6).
    case rowError(Int)
    /// `failed transfer_state 6`: the attachment transfer failed with `error` 0 (section 3 item 6).
    case transferFailed
    /// `failed: Messages not ready`: the cold start passed 60 s (section 3 item 4).
    case messagesNotReady
    /// `failed: bridge restarted`: a `received` or `approved` request found after a crash (section 3 item 2).
    case bridgeRestarted
    /// `failed: sent with wrong parent <guid or none>` (section 4 step 7).
    case sentWithWrongParent(String?)
}

/// `ambiguous` variants.
public enum AmbiguityReason: Hashable, Sendable {
    /// `ambiguous: two rows matched`: correlation found two candidates (section 3 item 5).
    case twoRowsMatched
    /// `ambiguous`: chat or bubble targeting matched more than one thing (section 4, Targeting).
    case target
}

/// `denied` variants (section 2).
public enum DenialReason: Hashable, Sendable {
    /// `denied`: the user pressed Deny. Holds the idempotency key.
    case user
    /// `denied: approval expired`: nobody answered for 10 minutes. Does not hold the key.
    case approvalExpired
}

/// `busy` variants. None of them sent or pressed anything.
public enum BusyReason: Hashable, Sendable {
    /// `busy: queue`: 30 s passed waiting for the queue (section 3 item 3).
    case queue
    /// `busy: Messages is open`: the user has Messages (section 4, Window rules). Comes with a fix.
    case messagesOpen
    /// `busy: draft in Messages`: the composer isn't empty (section 4 step 1).
    case draftInMessages
    /// `busy: edit in progress`: AX shows an edit field or a thread view (section 4 step 1).
    case editInProgress
    /// `busy: user active`: the idle gate ran out (section 4 steps 2 and 3).
    case userActive
    /// `busy: screen locked`: the Mac's screen is locked, so AX reaches no Messages window. Nothing was launched or
    /// quit (docs/BUILD-PLAN.md entry 52). Comes with a fix.
    case screenLocked
}

/// `aborted` variants (section 4 steps 3 and 5).
public enum AbortReason: Hashable, Sendable {
    case userTookOver
    case parentChanged
    case lateActivation
    case activation
    case deadline
    /// `aborted: <check>` for any other failed check before Return.
    case check(String)
}

/// `error` variants. One line, `error: … fix: …` (section 5, Output).
public enum ErrorReason: Hashable, Sendable {
    /// `error: wrong chat`: the transcript didn't match the signature after the press (section 4).
    case wrongChat
    /// `error: several matches`: a target argument matched more than one contact or conversation (section 5).
    case severalMatches
    /// Any other one-line error, for example `error: no chat or contact matches "x"`.
    case message(String)
}

/// The leading code of a result line.
public enum ResultCode: Hashable, Sendable {
    case submitted
    case delivered
    case failed(FailureReason)
    case ghost
    case ambiguous(AmbiguityReason)
    case mayHaveCompleted
    case ok
    case already
    case expired
    case denied(DenialReason)
    case pending(id: String)
    case busy(BusyReason)
    case notLoaded
    case notDownloaded
    case unsupported
    case unsupportedTarget
    case untested
    case noHiddenWindow
    case aborted(AbortReason)
    case timeout
    case error(ErrorReason)
}

/// Clauses a result can add after its code (sections 3 item 5 and 4).
public enum ResultNote: Hashable, Sendable {
    /// `chat unconfirmed`: the join row hadn't appeared when correlation returned.
    case chatUnconfirmed
    /// `error: Messages became visible`: a window showed during a hidden action.
    case messagesBecameVisible
    /// `Messages left in edit mode`.
    case messagesLeftInEditMode
    /// `Messages left open`.
    case messagesLeftOpen
    /// `<app> in front`: focus ended somewhere other than the user's earlier app.
    case frontApp(String)
    /// `user took over`: a takeover after Return.
    case userTookOver
    /// `agent text may still be in the field`.
    case agentTextMayRemain
    /// The edit-field or thread-view state AX shows after a takeover.
    case axState(String)
    /// `chat opened, may be marked read`: opening a chat may mark it read and send a read receipt.
    case mayHaveMarkedRead
}

/// One result: a code, its notes and an optional fix.
public struct ActionResult: Hashable, Sendable {
    public var code: ResultCode
    public var notes: [ResultNote]
    public var fix: String?

    public init(_ code: ResultCode, notes: [ResultNote] = [], fix: String? = nil) {
        self.code = code
        self.notes = notes
        self.fix = fix
    }

    /// `busy: Messages is open` with its fixed fix text (section 4, Window rules).
    public static let messagesOpen = ActionResult(.busy(.messagesOpen), fix: "hide Messages (⌘H) and retry")
    /// `busy: screen locked` with its fix text (docs/BUILD-PLAN.md entry 52).
    public static let screenLocked = ActionResult(.busy(.screenLocked), fix: "unlock the Mac and retry")

    // Error lines docs/BUILD-PLAN.md adds ("Items DESIGN.md doesn't settle", item 8).

    /// `error: journal write failed`: `willInvoke` threw, so nothing was performed. IMSend, IMUI and IMForeground
    /// return this value too.
    public static let journalWriteFailed = ActionResult(.error(.message("journal write failed")),
                                                        fix: "free disk space and retry")
    /// `error: foreground mode is off`: `edit` and `send --thread` need foreground mode.
    public static let foregroundModeOff = ActionResult(.error(.message("foreground mode is off")),
                                                       fix: "imessage allow --foreground")
    /// `error: --thread can't be combined with --file` (section 5, `send`).
    public static let threadWithFile = ActionResult(.error(.message("--thread can't be combined with --file")),
                                                    fix: "send the file and the reply separately")
    /// `error: bad request`: a frame over the cap, bad JSON or a protocol version other than 1. IMPolicy also
    /// refuses a request whose chat is missing or differs from its binding with this value.
    public static let badRequest = ActionResult(.error(.message("bad request")),
                                                fix: "retry, and run imessage doctor if it happens again")

    /// Section 3 item 1: a result holds the idempotency key only if the action may have taken effect, plus `denied`.
    public var holdsIdempotencyKey: Bool {
        if notes.contains(.agentTextMayRemain) { return true }
        switch code {
        case .submitted, .delivered, .ghost, .mayHaveCompleted, .ok:
            return true
        case .failed(.rowError), .failed(.transferFailed), .failed(.sentWithWrongParent):
            return true
        case .ambiguous(.twoRowsMatched):
            return true
        case .denied(.user):
            return true
        default:
            return false
        }
    }

    /// The single line the CLI prints: `<code>[, <note>]…[ fix: <fix>]`. Line breaks inside a message, note or fix
    /// fold to ` / ` (`TextNorm.singleLine`), so it is always one line.
    public var rendered: String { rendered(tail: "") }

    /// `rendered` with `tail` (such as ` (repeat)`) after the notes and before ` fix:`, so the fix stays last.
    func rendered(tail: String) -> String {
        var s = code.wire
        for n in notes { s += ", " + n.wire }
        s += tail
        if let fix { s += " fix: " + fix }
        return TextNorm.singleLine(s)
    }
}

// MARK: - Wire strings

extension ResultCode {
    /// The exact string DESIGN.md uses for this code.
    public var wire: String {
        switch self {
        case .submitted: return "submitted"
        case .delivered: return "delivered"
        case .failed(let r):
            switch r {
            case .rowError(let e): return "failed \(e)"
            case .transferFailed: return "failed transfer_state 6"
            case .messagesNotReady: return "failed: Messages not ready"
            case .bridgeRestarted: return "failed: bridge restarted"
            case .sentWithWrongParent(let g): return "failed: sent with wrong parent \(g ?? "none")"
            }
        case .ghost: return "ghost"
        case .ambiguous(.twoRowsMatched): return "ambiguous: two rows matched"
        case .ambiguous(.target): return "ambiguous"
        case .mayHaveCompleted: return "may_have_completed"
        case .ok: return "ok"
        case .already: return "already"
        case .expired: return "expired"
        case .denied(.user): return "denied"
        case .denied(.approvalExpired): return "denied: approval expired"
        case .pending(let id): return "pending \(id)"
        case .busy(let r):
            switch r {
            case .queue: return "busy: queue"
            case .messagesOpen: return "busy: Messages is open"
            case .draftInMessages: return "busy: draft in Messages"
            case .editInProgress: return "busy: edit in progress"
            case .userActive: return "busy: user active"
            case .screenLocked: return "busy: screen locked"
            }
        case .notLoaded: return "not_loaded"
        case .notDownloaded: return "not_downloaded"
        case .unsupported: return "unsupported"
        case .unsupportedTarget: return "unsupported_target"
        case .untested: return "untested"
        case .noHiddenWindow: return "no_hidden_window"
        case .aborted(let r):
            switch r {
            case .userTookOver: return "aborted: user took over"
            case .parentChanged: return "aborted: parent changed"
            case .lateActivation: return "aborted: late activation"
            case .activation: return "aborted: activation"
            case .deadline: return "aborted: deadline"
            case .check(let c): return "aborted: \(c)"
            }
        case .timeout: return "timeout"
        case .error(.wrongChat): return "error: wrong chat"
        case .error(.severalMatches): return "error: several matches"
        case .error(.message(let m)): return "error: \(m)"
        }
    }

    /// Parses a string produced by `wire`. Returns nil for anything else.
    public init?(wire s: String) {
        let fixed: [String: ResultCode] = [
            "submitted": .submitted, "delivered": .delivered, "ghost": .ghost,
            "failed transfer_state 6": .failed(.transferFailed),
            "failed: Messages not ready": .failed(.messagesNotReady),
            "failed: bridge restarted": .failed(.bridgeRestarted),
            "ambiguous: two rows matched": .ambiguous(.twoRowsMatched), "ambiguous": .ambiguous(.target),
            "may_have_completed": .mayHaveCompleted, "ok": .ok, "already": .already, "expired": .expired,
            "denied": .denied(.user), "denied: approval expired": .denied(.approvalExpired),
            "busy: queue": .busy(.queue), "busy: Messages is open": .busy(.messagesOpen),
            "busy: draft in Messages": .busy(.draftInMessages), "busy: edit in progress": .busy(.editInProgress),
            "busy: user active": .busy(.userActive), "busy: screen locked": .busy(.screenLocked),
            "not_loaded": .notLoaded, "not_downloaded": .notDownloaded, "unsupported": .unsupported,
            "unsupported_target": .unsupportedTarget, "untested": .untested, "no_hidden_window": .noHiddenWindow,
            "aborted: user took over": .aborted(.userTookOver), "aborted: parent changed": .aborted(.parentChanged),
            "aborted: late activation": .aborted(.lateActivation), "aborted: activation": .aborted(.activation),
            "aborted: deadline": .aborted(.deadline),
            "timeout": .timeout, "error: wrong chat": .error(.wrongChat), "error: several matches": .error(.severalMatches),
        ]
        if let c = fixed[s] { self = c; return }
        if s.hasPrefix("failed: sent with wrong parent ") {
            let g = String(s.dropFirst("failed: sent with wrong parent ".count))
            self = .failed(.sentWithWrongParent(g == "none" ? nil : g)); return
        }
        if s.hasPrefix("failed "), let e = Int(s.dropFirst("failed ".count)) { self = .failed(.rowError(e)); return }
        if s.hasPrefix("pending "), s.count > "pending ".count { self = .pending(id: String(s.dropFirst("pending ".count))); return }
        if s.hasPrefix("aborted: ") { self = .aborted(.check(String(s.dropFirst("aborted: ".count)))); return }
        if s.hasPrefix("error: ") { self = .error(.message(String(s.dropFirst("error: ".count)))); return }
        return nil
    }
}

extension ResultNote {
    public var wire: String {
        switch self {
        case .chatUnconfirmed: return "chat unconfirmed"
        case .messagesBecameVisible: return "error: Messages became visible"
        case .messagesLeftInEditMode: return "Messages left in edit mode"
        case .messagesLeftOpen: return "Messages left open"
        case .frontApp(let name): return "\(name) in front"
        case .userTookOver: return "user took over"
        case .agentTextMayRemain: return "agent text may still be in the field"
        case .axState(let s): return "AX shows \(s)"
        case .mayHaveMarkedRead: return "chat opened, may be marked read"
        }
    }

    public init?(wire s: String) {
        switch s {
        case "chat unconfirmed": self = .chatUnconfirmed
        case "error: Messages became visible": self = .messagesBecameVisible
        case "Messages left in edit mode": self = .messagesLeftInEditMode
        case "Messages left open": self = .messagesLeftOpen
        case "user took over": self = .userTookOver
        case "agent text may still be in the field": self = .agentTextMayRemain
        case "chat opened, may be marked read": self = .mayHaveMarkedRead
        default:
            if s.hasPrefix("AX shows ") { self = .axState(String(s.dropFirst("AX shows ".count))); return }
            if s.hasSuffix(" in front") { self = .frontApp(String(s.dropLast(" in front".count))); return }
            return nil
        }
    }
}

// MARK: - Codable as strings, so NDJSON output stays readable

extension ResultCode: Codable {
    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let c = ResultCode(wire: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown result \(s)"))
        }
        self = c
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(wire)
    }
}

extension ResultNote: Codable {
    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let n = ResultNote(wire: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown note \(s)"))
        }
        self = n
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(wire)
    }
}

extension ActionResult: Codable {}
