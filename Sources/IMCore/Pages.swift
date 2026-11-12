import Foundation

// Response payloads, one per bridge op (DESIGN.md sections 1 and 5). Format renders each one.

/// `chats [-n 20] [--unread]`.
public struct ChatsPage: Hashable, Codable, Sendable {
    public var chats: [ChatRecord]
    /// More chats exist past `limit`. Footer: `more: imessage chats -n <n + 20>`, with `--unread` when `unreadOnly`.
    public var hasMore: Bool
    public var limit: Int
    /// The page lists only chats with unread messages (`--unread`), so its footer asks for more of those.
    public var unreadOnly: Bool

    public init(chats: [ChatRecord], hasMore: Bool, limit: Int, unreadOnly: Bool = false) {
        self.chats = chats
        self.hasMore = hasMore
        self.limit = limit
        self.unreadOnly = unreadOnly
    }

    private enum CodingKeys: String, CodingKey { case chats, hasMore, limit, unreadOnly }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chats = try c.decode([ChatRecord].self, forKey: .chats)
        hasMore = try c.decode(Bool.self, forKey: .hasMore)
        limit = try c.decode(Int.self, forKey: .limit)
        unreadOnly = try c.decodeIfPresent(Bool.self, forKey: .unreadOnly) ?? false
    }

    /// The command the `more:` footer names: the same list, 20 chats longer.
    public var nextCommand: String {
        "imessage chats" + (unreadOnly ? " --unread" : "") + " -n \(limit + 20)"
    }
}

/// One line of an `unread` group.
public struct UnreadEntry: Hashable, Codable, Sendable {
    public var message: MessageRecord
    public var isUnread: Bool
    /// True if visible messages were skipped before this one. Format prints `…`.
    public var gapBefore: Bool

    public init(message: MessageRecord, isUnread: Bool, gapBefore: Bool) {
        self.message = message
        self.isUnread = isUnread
        self.gapBefore = gapBefore
    }
}

/// Unread messages of one chat with up to `-c` context lines before each run.
public struct UnreadGroup: Hashable, Codable, Sendable {
    public var chat: ChatRecord
    public var entries: [UnreadEntry]
    public var unreadCount: Int

    public init(chat: ChatRecord, entries: [UnreadEntry], unreadCount: Int) {
        self.chat = chat
        self.entries = entries
        self.unreadCount = unreadCount
    }
}

/// `unread [-c 2]`: every unread message across chats, newest chat first.
public struct UnreadPage: Hashable, Codable, Sendable {
    public var groups: [UnreadGroup]
    public var totalUnread: Int

    public init(groups: [UnreadGroup], totalUnread: Int) {
        self.groups = groups
        self.totalUnread = totalUnread
    }
}

/// `read <who> [-n 30] [--before/--after/--around ROWID] [--since T]`.
public struct MessagesPage: Hashable, Codable, Sendable {
    public var chat: ChatRecord
    /// Oldest first.
    public var messages: [MessageRecord]
    /// Visible messages in the chat, for `<shown> of <total>`.
    public var totalVisible: Int
    /// Older visible messages exist. Footer: `more: imessage read <chat> --before <oldest shown>`.
    public var olderExists: Bool
    /// Newer visible messages exist past the window, which only `--after` and `--around` leave. Footer:
    /// `more: imessage read <chat> --after <newest shown>`.
    public var newerExists: Bool

    public init(chat: ChatRecord, messages: [MessageRecord], totalVisible: Int, olderExists: Bool,
                newerExists: Bool = false) {
        self.chat = chat
        self.messages = messages
        self.totalVisible = totalVisible
        self.olderExists = olderExists
        self.newerExists = newerExists
    }

    private enum CodingKeys: String, CodingKey { case chat, messages, totalVisible, olderExists, newerExists }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chat = try c.decode(ChatRecord.self, forKey: .chat)
        messages = try c.decode([MessageRecord].self, forKey: .messages)
        totalVisible = try c.decode(Int.self, forKey: .totalVisible)
        olderExists = try c.decode(Bool.self, forKey: .olderExists)
        newerExists = try c.decodeIfPresent(Bool.self, forKey: .newerExists) ?? false
    }
}

/// `show <rowid> [--from N]`: one message in full, up to 8 KB per call.
///
/// `message.text` holds the whole body. Format prints the bytes from `fromByte` on, at most
/// `Limits.showCapBytes`, cut back to a character boundary, and ends with a `--from` footer when bytes remain.
public struct MessageDetail: Hashable, Codable, Sendable {
    public var message: MessageRecord
    public var chat: ChatRef
    /// UTF-8 byte offset this page starts at, `MessageArgs.fromByte`. Format moves an offset inside a character
    /// forward to the next character and treats one past the end as an empty page.
    public var fromByte: Int
    /// Total UTF-8 bytes of the body, `message.text.utf8.count`.
    public var totalBytes: Int

    public init(message: MessageRecord, chat: ChatRef, fromByte: Int, totalBytes: Int) {
        self.message = message
        self.chat = chat
        self.fromByte = fromByte
        self.totalBytes = totalBytes
    }
}

public struct SearchHit: Hashable, Codable, Sendable {
    public var chat: ChatRef
    public var message: MessageRecord
    /// The `chat_message_join.message_date` the store pages on, for a cursor that resumes right after this hit.
    /// Nil uses `message.dateNs`.
    public var cursorNs: AppleNanos?

    public init(chat: ChatRef, message: MessageRecord, cursorNs: AppleNanos? = nil) {
        self.chat = chat
        self.message = message
        self.cursorNs = cursorNs
    }
}

/// `search <text> [--in who] [--since T] [--cursor C] [-n 20]` (section 1, Search).
public struct SearchPage: Hashable, Codable, Sendable {
    public var query: String
    public var inChat: ChatRef?
    /// Newest first.
    public var hits: [SearchHit]
    /// How far back this page scanned (section 1: "Each result page reports how far back it scanned").
    public var scannedBackToNs: AppleNanos
    /// Start of the date window (default 1 year).
    public var windowStartNs: AppleNanos
    /// Cursor for the next page (`SearchCursor.text`), nil when the window is exhausted.
    public var nextCursor: String?
    /// The search budget ran out before the window was exhausted.
    public var budgetExhausted: Bool

    public init(query: String, inChat: ChatRef?, hits: [SearchHit], scannedBackToNs: AppleNanos,
                windowStartNs: AppleNanos, nextCursor: String?, budgetExhausted: Bool) {
        self.query = query
        self.inChat = inChat
        self.hits = hits
        self.scannedBackToNs = scannedBackToNs
        self.windowStartNs = windowStartNs
        self.nextCursor = nextCursor
        self.budgetExhausted = budgetExhausted
    }
}

/// The `search` cursor: the last hit a page showed and the start of its date window. The next page returns hits
/// strictly older than (`dateNs`, `rowid`) in newest-first order, down to `windowStartNs`.
/// Text form `<dateNs>:<rowid>:<windowStartNs>`. `SearchPage.nextCursor` uses it, and Format writes one when the
/// output cap cuts a page short.
public struct SearchCursor: Hashable, Codable, Sendable {
    public var dateNs: AppleNanos
    public var rowid: Int64
    public var windowStartNs: AppleNanos

    public init(dateNs: AppleNanos, rowid: Int64, windowStartNs: AppleNanos) {
        self.dateNs = dateNs
        self.rowid = rowid
        self.windowStartNs = windowStartNs
    }

    public var text: String { "\(dateNs):\(rowid):\(windowStartNs)" }

    public init?(text: String) {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, let d = AppleNanos(parts[0]), let r = Int64(parts[1]), let w = AppleNanos(parts[2])
        else { return nil }
        self.init(dateNs: d, rowid: r, windowStartNs: w)
    }
}

/// `who <name>`.
public struct ContactsPage: Hashable, Codable, Sendable {
    public var query: String
    public var contacts: [ContactRecord]

    public init(query: String, contacts: [ContactRecord]) {
        self.query = query
        self.contacts = contacts
    }
}

public enum ChangeKind: String, Codable, Sendable, Hashable {
    case new, edited, unsent, read, delivered
}

public struct ChangeRecord: Hashable, Codable, Sendable {
    public var kind: ChangeKind
    public var chat: ChatRef
    public var message: MessageRecord
    /// The time that put the row on the page: its retracted, edited, read or delivered time inside the window.
    /// 0 for `.new` and when unknown. A retract-only unsend has only this, since `MessageRecord` has no retracted time.
    public var eventNs: AppleNanos

    public init(kind: ChangeKind, chat: ChatRef, message: MessageRecord, eventNs: AppleNanos = 0) {
        self.kind = kind
        self.chat = chat
        self.message = message
        self.eventNs = eventNs
    }

    private enum CodingKeys: String, CodingKey { case kind, chat, message, eventNs }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(ChangeKind.self, forKey: .kind)
        chat = try c.decode(ChatRef.self, forKey: .chat)
        message = try c.decode(MessageRecord.self, forKey: .message)
        eventNs = try c.decodeIfPresent(AppleNanos.self, forKey: .eventNs) ?? 0
    }
}

/// `changes [--since CURSOR]`. With no `--since`, `changes` is empty and `cursor` is the current position.
public struct ChangesPage: Hashable, Codable, Sendable {
    /// Cursor for the next call. See `ChangeCursor`.
    public var cursor: String
    public var changes: [ChangeRecord]
    /// More changes exist past the output cap; call again with `cursor`.
    public var truncated: Bool

    public init(cursor: String, changes: [ChangeRecord], truncated: Bool) {
        self.cursor = cursor
        self.changes = changes
        self.truncated = truncated
    }
}

/// The `changes` cursor: (ROWID, time). Rows above the ROWID, or with date_edited, date_read or
/// date_delivered after the time (section 5). Text form `<rowid>:<apple ns>`.
///
/// A page that stops partway through the changes at one time adds a tie ROWID, `<rowid>:<apple ns>:<tie>`: the
/// changes at exactly that time on rows above the tie ROWID are still to come. Changes go in (time, ROWID) order,
/// so a bulk mark-read that gives hundreds of rows one date_read still pages forward.
public struct ChangeCursor: Hashable, Codable, Sendable {
    public var rowid: Int64
    public var timeNs: AppleNanos
    /// Changes at `timeNs` on rows above this ROWID are still to come. Nil when every change at `timeNs` is done.
    public var tieRowID: Int64?

    public init(rowid: Int64, timeNs: AppleNanos, tieRowID: Int64? = nil) {
        self.rowid = rowid
        self.timeNs = timeNs
        self.tieRowID = tieRowID
    }

    public var text: String { tieRowID.map { "\(rowid):\(timeNs):\($0)" } ?? "\(rowid):\(timeNs)" }

    public init?(text: String) {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3, let r = Int64(parts[0]), let t = AppleNanos(parts[1]) else {
            return nil
        }
        var tie: Int64?
        if parts.count == 3 {
            guard let x = Int64(parts[2]) else { return nil }
            tie = x
        }
        self.init(rowid: r, timeNs: t, tieRowID: tie)
    }

    /// The cursor's place in (time, ROWID) order. With no tie ROWID it comes after every row at its time.
    var position: (AppleNanos, Int64) { (timeNs, tieRowID ?? .max) }

    /// Whether a change at `time` on row `rowid` comes after the cursor, so it is still to be reported.
    public func isBefore(time: AppleNanos, rowid: Int64) -> Bool { position < (time, rowid) }
}

/// `wait [--from who] [--timeout 300]`: the first new inbound message, or `timeout`.
public struct WaitOutcome: Hashable, Codable, Sendable {
    public var chat: ChatRef?
    public var message: MessageRecord?
    public var timedOut: Bool

    public init(chat: ChatRef?, message: MessageRecord?, timedOut: Bool) {
        self.chat = chat
        self.message = message
        self.timedOut = timedOut
    }
}

/// `att <id>`: a viewable copy in the 0700 cache, or `not_downloaded`.
public struct AttachmentExport: Hashable, Codable, Sendable {
    public var attachment: AttachmentRecord
    /// Path of the cached copy. Nil when `result` is set.
    public var path: String?
    /// HEIC was converted to JPEG with the long side at most 1600 px.
    public var converted: Bool
    public var result: ActionResult?

    public init(attachment: AttachmentRecord, path: String?, converted: Bool, result: ActionResult?) {
        self.attachment = attachment
        self.path = path
        self.converted = converted
        self.result = result
    }
}

public enum SendPartKind: String, Codable, Sendable, Hashable {
    case text, file
}

/// One part of a send. Text and file parts get separate results (section 3 item 6).
public struct SendPartOutcome: Hashable, Codable, Sendable {
    public var part: SendPartKind
    public var result: ActionResult
    public var rowid: Int64?
    public var guid: String?
    public var dateDeliveredNs: AppleNanos?
    /// The file part's attachment as staged, for `[photo a9901 2.2MB]`.
    public var attachment: AttachmentRecord?

    public init(part: SendPartKind, result: ActionResult, rowid: Int64? = nil, guid: String? = nil,
                dateDeliveredNs: AppleNanos? = nil, attachment: AttachmentRecord? = nil) {
        self.part = part
        self.result = result
        self.rowid = rowid
        self.guid = guid
        self.dateDeliveredNs = dateDeliveredNs
        self.attachment = attachment
    }
}

/// `send <who> [<text>] [--file P] [--again] [--thread]`.
public struct SendOutcome: Hashable, Codable, Sendable {
    public var chat: ChatRef
    /// An approval dialog was answered with Allow for this request. Format prints `approved` first.
    public var approved: Bool
    /// Set when the request ended before any part ran (busy, denied, pending, error, may_have_completed replay).
    public var early: ActionResult?
    public var text: String?
    public var threadParentRowID: Int64?
    public var parts: [SendPartOutcome]
    /// The result came from the journal for a repeated idempotency key.
    public var replayed: Bool

    public init(chat: ChatRef, approved: Bool, early: ActionResult?, text: String?, threadParentRowID: Int64?,
                parts: [SendPartOutcome], replayed: Bool) {
        self.chat = chat
        self.approved = approved
        self.early = early
        self.text = text
        self.threadParentRowID = threadParentRowID
        self.parts = parts
        self.replayed = replayed
    }
}

public enum UIActionKind: String, Codable, Sendable, Hashable {
    case react, unsend, edit
}

/// `react`, `unsend`, `edit`.
public struct UIOutcome: Hashable, Codable, Sendable {
    public var action: UIActionKind
    public var targetRowID: Int64
    public var chat: ChatRef?
    public var tapback: TapbackKind?
    public var remove: Bool
    public var approved: Bool
    public var result: ActionResult
    /// For a repeated tapback key whose first result was `ok`: the reaction re-read from chat.db (section 4).
    public var currentReaction: TapbackKind?
    public var replayed: Bool
    /// Quote of the target for the result line: `reacted ❤️ to 41418 (Mom: …)`.
    public var targetQuote: ReplyRef?

    public init(action: UIActionKind, targetRowID: Int64, chat: ChatRef?, tapback: TapbackKind?, remove: Bool,
                approved: Bool, result: ActionResult, currentReaction: TapbackKind?, replayed: Bool,
                targetQuote: ReplyRef?) {
        self.action = action
        self.targetRowID = targetRowID
        self.chat = chat
        self.tapback = tapback
        self.remove = remove
        self.approved = approved
        self.result = result
        self.currentReaction = currentReaction
        self.replayed = replayed
        self.targetQuote = targetQuote
    }
}

public enum PolicyChange: String, Codable, Sendable, Hashable {
    case allowChat, revokeChat, foregroundOn, foregroundOff
}

/// `allow`, `revoke`, `allow --foreground`, `revoke --foreground`.
public struct PolicyOutcome: Hashable, Codable, Sendable {
    public var change: PolicyChange
    public var chat: ChatRef?
    public var scope: AllowScope?
    public var result: ActionResult

    public init(change: PolicyChange, chat: ChatRef?, scope: AllowScope?, result: ActionResult) {
        self.change = change
        self.chat = chat
        self.scope = scope
        self.result = result
    }
}

public struct PendingItem: Hashable, Codable, Sendable {
    public var id: String
    /// One-line summary such as `send to Mom "On my way"`.
    public var summary: String
    public var createdAt: Date
    public var expiresAt: Date

    public init(id: String, summary: String, createdAt: Date, expiresAt: Date) {
        self.id = id
        self.summary = summary
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }
}

/// `pending` with no id: open approvals.
public struct PendingList: Hashable, Codable, Sendable {
    public var items: [PendingItem]

    public init(items: [PendingItem]) { self.items = items }
}

public enum CapStatus: String, Codable, Sendable, Hashable {
    /// Passed its release test on this macOS major.minor.
    case supported
    /// No release-test record for this version: off (section 4).
    case untested
    /// Failed its release test, or an action name is missing, or the UI language isn't English.
    case unsupported
}

public struct CapEntry: Hashable, Codable, Sendable {
    public var name: String
    public var status: CapStatus
    public var note: String?

    public init(name: String, status: CapStatus, note: String? = nil) {
        self.name = name
        self.status = status
        self.note = note
    }
}

/// `caps` (section 4, Capabilities and evidence).
public struct CapsReport: Hashable, Codable, Sendable {
    /// `26.2`. Records are keyed on major.minor.
    public var macOSVersion: String
    public var uiLanguageEnglish: Bool
    public var accessibilityTrusted: Bool
    public var foregroundMode: Bool
    public var entries: [CapEntry]

    public init(macOSVersion: String, uiLanguageEnglish: Bool, accessibilityTrusted: Bool, foregroundMode: Bool,
                entries: [CapEntry]) {
        self.macOSVersion = macOSVersion
        self.uiLanguageEnglish = uiLanguageEnglish
        self.accessibilityTrusted = accessibilityTrusted
        self.foregroundMode = foregroundMode
        self.entries = entries
    }
}

public enum PermissionState: String, Codable, Sendable, Hashable {
    case granted, denied, notDetermined, unknown
}

/// `status` (section 1): silent permission checks.
public struct StatusReport: Hashable, Codable, Sendable {
    public var bridgeVersion: String
    public var pid: Int32
    public var fullDiskAccess: PermissionState
    public var automation: PermissionState
    public var accessibility: PermissionState
    public var messagesRunning: Bool
    public var foregroundMode: Bool
    public var foregroundOffReason: String?
    /// False if the allowlist file or its Keychain hash failed the tamper check (section 2, Storage).
    public var allowlistTrusted: Bool
    public var allowedChats: Int
    public var openApprovals: Int
    /// Set after a crash during a foreground action (section 3 item 2).
    public var crashNote: String?

    public init(bridgeVersion: String, pid: Int32, fullDiskAccess: PermissionState, automation: PermissionState,
                accessibility: PermissionState, messagesRunning: Bool, foregroundMode: Bool,
                foregroundOffReason: String?, allowlistTrusted: Bool, allowedChats: Int, openApprovals: Int,
                crashNote: String?) {
        self.bridgeVersion = bridgeVersion
        self.pid = pid
        self.fullDiskAccess = fullDiskAccess
        self.automation = automation
        self.accessibility = accessibility
        self.messagesRunning = messagesRunning
        self.foregroundMode = foregroundMode
        self.foregroundOffReason = foregroundOffReason
        self.allowlistTrusted = allowlistTrusted
        self.allowedChats = allowedChats
        self.openApprovals = openApprovals
        self.crashNote = crashNote
    }
}

public enum SetupStage: String, Codable, Sendable, Hashable, CaseIterable {
    /// Try chat.db once so macOS lists the bridge, then open the Full Disk Access pane (install flow step 4).
    case fullDiskAccess
    /// Raise the Automation prompt for Messages (install flow step 5).
    case automation
    /// Raise the Accessibility prompt, only if the user wants UI actions (install flow step 5).
    case accessibility
}

public struct SetupReport: Hashable, Codable, Sendable {
    public var stage: SetupStage
    public var state: PermissionState
    /// Settings pane the bridge opened, if any.
    public var openedPane: String?

    public init(stage: SetupStage, state: PermissionState, openedPane: String?) {
        self.stage = stage
        self.state = state
        self.openedPane = openedPane
    }
}

public struct DoctorCheck: Hashable, Codable, Sendable {
    public var name: String
    public var ok: Bool
    public var detail: String?
    public var fix: String?

    public init(name: String, ok: Bool, detail: String? = nil, fix: String? = nil) {
        self.name = name
        self.ok = ok
        self.detail = detail
        self.fix = fix
    }
}

/// `doctor` (install flow step 5, sections 3 item 2 and 4).
public struct DoctorReport: Hashable, Codable, Sendable {
    public var checks: [DoctorCheck]
    /// The bridge still can't open chat.db; the CLI runs `launchctl kickstart -k` once and asks again.
    public var needsKickstart: Bool
    /// The bridge was compiled with `IMESSAGE_RELEASE_TESTS`. The `doctor` header says so
    /// (docs/BUILD-PLAN.md, "Items DESIGN.md doesn't settle", item 10). Decodes as false when absent.
    public var releaseTestBuild: Bool

    public init(checks: [DoctorCheck], needsKickstart: Bool) {
        self.init(checks: checks, needsKickstart: needsKickstart, releaseTestBuild: false)
    }

    public init(checks: [DoctorCheck], needsKickstart: Bool, releaseTestBuild: Bool) {
        self.checks = checks
        self.needsKickstart = needsKickstart
        self.releaseTestBuild = releaseTestBuild
    }

    private enum CodingKeys: String, CodingKey { case checks, needsKickstart, releaseTestBuild }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        checks = try c.decode([DoctorCheck].self, forKey: .checks)
        needsKickstart = try c.decode(Bool.self, forKey: .needsKickstart)
        releaseTestBuild = try c.decodeIfPresent(Bool.self, forKey: .releaseTestBuild) ?? false
    }
}

public struct PongInfo: Hashable, Codable, Sendable {
    public var bridgeVersion: String
    public var pid: Int32

    public init(bridgeVersion: String, pid: Int32) {
        self.bridgeVersion = bridgeVersion
        self.pid = pid
    }
}

/// A request-level error: `error: <message> fix: <fix>` (section 5).
public struct WireError: Hashable, Codable, Sendable, Error {
    public var result: ActionResult
    /// Filled for `error: several matches`.
    public var candidates: [Candidate]

    public init(result: ActionResult, candidates: [Candidate] = []) {
        self.result = result
        self.candidates = candidates
    }

    public static func message(_ m: String, fix: String? = nil) -> WireError {
        WireError(result: ActionResult(.error(.message(m)), fix: fix))
    }
}
