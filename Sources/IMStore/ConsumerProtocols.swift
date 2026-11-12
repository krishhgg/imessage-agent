import Foundation
import IMCore

// Read interfaces that the modules above IMStore depend on. ChatDatabase is the live conformer; each consumer's
// tests use their own fakes. Owner of these declarations: IMStore. Changing one needs the consumer owner's agreement.

// MARK: - IMSend: correlation (section 3 item 5) and staging cleanup (section 3 item 7)

/// A from_me row above the send snapshot, with what correlation compares.
public struct SentRowProbe: Hashable, Sendable {
    public var rowid: Int64
    public var guid: String
    public var handle: String?
    public var service: String?
    public var dateNs: AppleNanos
    /// Decoded body, `TextNorm.matchKey` applied. Empty for file-only rows.
    public var body: String
    public var hasBody: Bool
    public var transferNames: [String]
    /// transfer_state per transfer name.
    public var transferStates: [String: Int]
    public var error: Int
    public var isSent: Bool
    public var isDelivered: Bool
    public var dateDeliveredNs: AppleNanos
    /// Chat from chat_message_join, nil while the join row lags (about 1 s in S2).
    public var joinedChatRowID: Int64?
    public var threadOriginatorGUID: String?
    public var itemType: Int

    public init(rowid: Int64, guid: String, handle: String?, service: String?, dateNs: AppleNanos, body: String,
                hasBody: Bool, transferNames: [String], transferStates: [String: Int], error: Int, isSent: Bool,
                isDelivered: Bool, dateDeliveredNs: AppleNanos, joinedChatRowID: Int64?,
                threadOriginatorGUID: String?, itemType: Int) {
        self.rowid = rowid
        self.guid = guid
        self.handle = handle
        self.service = service
        self.dateNs = dateNs
        self.body = body
        self.hasBody = hasBody
        self.transferNames = transferNames
        self.transferStates = transferStates
        self.error = error
        self.isSent = isSent
        self.isDelivered = isDelivered
        self.dateDeliveredNs = dateDeliveredNs
        self.joinedChatRowID = joinedChatRowID
        self.threadOriginatorGUID = threadOriginatorGUID
        self.itemType = itemType
    }
}

public protocol SendRowSource: AnyObject {
    func maxMessageRowID() throws -> Int64
    /// Every from_me row above `rowid`, oldest first, at most `limit`. Includes empty, unjoined SMS rows (ghost).
    func fromMeRows(aboveRowID rowid: Int64, limit: Int) throws -> [SentRowProbe]
    func sentRow(rowid: Int64) throws -> SentRowProbe?
    /// transfer_state for attachments with these transfer names. Missing names are absent from the result.
    func transferStates(transferNames: [String]) throws -> [String: Int]
    /// The canonical identity of a chat.db chat, nil if there is no such chat. Correlation uses it for a target that
    /// had no chat when it was resolved, to tell its new chat from another conversation's.
    func canonicalChatID(chatRowID: Int64) throws -> CanonicalChatID?
}

// MARK: - IMUI: targeting (section 4, Targeting) and verification (Tapback semantics, Unsend)

/// One text row of a signature: direction and NFC body.
public struct SignatureRow: Hashable, Sendable {
    public var fromMe: Bool
    public var body: String

    public init(fromMe: Bool, body: String) {
        self.fromMe = fromMe
        self.body = body
    }
}

/// One conversation as Messages lists it: each group chat on its own, 1:1 chats grouped by handle.
public struct ConversationSummary: Hashable, Sendable {
    public var canonical: CanonicalChatID
    public var chatRowIDs: [Int64]
    public var isGroup: Bool
    /// The name Messages shows in the row.
    public var displayName: String
    /// Newest row's preview as Messages renders it, before time formatting.
    public var newestPreview: String
    public var newestDateNs: AppleNanos
    /// Newest text rows by direction and body, newest first, up to `Limits.signatureRows`.
    /// Tapbacks, unsent messages and rows without a text bubble are skipped.
    public var signature: [SignatureRow]

    public init(canonical: CanonicalChatID, chatRowIDs: [Int64], isGroup: Bool, displayName: String,
                newestPreview: String, newestDateNs: AppleNanos, signature: [SignatureRow]) {
        self.canonical = canonical
        self.chatRowIDs = chatRowIDs
        self.isGroup = isGroup
        self.displayName = displayName
        self.newestPreview = newestPreview
        self.newestDateNs = newestDateNs
        self.signature = signature
    }
}

/// The message a UI action targets.
public struct MessageTargetInfo: Hashable, Sendable {
    public var rowid: Int64
    public var guid: String
    public var chatRowID: Int64
    public var canonical: CanonicalChatID
    public var isGroupChat: Bool
    public var fromMe: Bool
    /// Decoded body, NFC.
    public var body: String
    public var dateNs: AppleNanos
    public var partCount: Int
    /// v1 targets only single-part text messages (`p:0`). Others return `unsupported_target`.
    public var isSinglePartText: Bool
    public var dateEditedNs: AppleNanos
    public var isUnsent: Bool
    public var senderName: String

    public init(rowid: Int64, guid: String, chatRowID: Int64, canonical: CanonicalChatID, isGroupChat: Bool,
                fromMe: Bool, body: String, dateNs: AppleNanos, partCount: Int, isSinglePartText: Bool,
                dateEditedNs: AppleNanos, isUnsent: Bool, senderName: String) {
        self.rowid = rowid
        self.guid = guid
        self.chatRowID = chatRowID
        self.canonical = canonical
        self.isGroupChat = isGroupChat
        self.fromMe = fromMe
        self.body = body
        self.dateNs = dateNs
        self.partCount = partCount
        self.isSinglePartText = isSinglePartText
        self.dateEditedNs = dateEditedNs
        self.isUnsent = isUnsent
        self.senderName = senderName
    }
}

/// A tapback row seen while verifying (types 2000 to 2006 add, 3000 to 3006 remove, on `p:0/<guid>`).
public struct ReactionRowProbe: Hashable, Sendable {
    public var rowid: Int64
    public var associatedType: Int
    public var associatedGUID: String
    public var emoji: String?
    public var fromMe: Bool

    public init(rowid: Int64, associatedType: Int, associatedGUID: String, emoji: String?, fromMe: Bool) {
        self.rowid = rowid
        self.associatedType = associatedType
        self.associatedGUID = associatedGUID
        self.emoji = emoji
        self.fromMe = fromMe
    }
}

/// Edit and unsend state of a row (section 4: Unsend, step 7 edit verification).
public struct EditStateProbe: Hashable, Sendable {
    public var rowid: Int64
    public var dateEditedNs: AppleNanos
    public var dateRetractedNs: AppleNanos
    /// Decoded body, NFC, trimmed. Empty after an unsend.
    public var body: String

    public init(rowid: Int64, dateEditedNs: AppleNanos, dateRetractedNs: AppleNanos, body: String) {
        self.rowid = rowid
        self.dateEditedNs = dateEditedNs
        self.dateRetractedNs = dateRetractedNs
        self.body = body
    }
}

public protocol UITargetSource: AnyObject {
    /// Every conversation, for the duplicate-description and duplicate-signature checks.
    func conversations() throws -> [ConversationSummary]
    func conversation(for chat: ResolvedChat) throws -> ConversationSummary?
    func messageTarget(rowid: Int64) throws -> MessageTargetInfo?
    /// Other messages in the target chat with the same direction, body and minute on any day.
    func sameBodyAndMinuteCount(for target: MessageTargetInfo) throws -> Int
    /// The user's current reaction on that message part, from the folded state.
    func currentUserReaction(messageGUID: String, part: Int) throws -> TapbackKind?
    /// from_me tapback rows above `rowid` that target `p:<part>/<guid>`.
    func reactionRows(aboveRowID rowid: Int64, targetGUID: String, part: Int) throws -> [ReactionRowProbe]
    func editState(rowid: Int64) throws -> EditStateProbe?
    /// The chat's newest incoming message, the parent "Reply to Last Message…" targets (section 4). IMBridge binds its
    /// GUID and shows its body in the approval dialog (section 2). IMForeground compares its GUID in steps 1 and 4,
    /// and its direction, body and minute with the thread view's parent bubble in step 4.
    func newestIncoming(for chat: ResolvedChat) throws -> MessageTargetInfo?
    func maxMessageRowID() throws -> Int64
}

// MARK: - IMPolicy: rate limits (section 2)

/// An inbound row, for "at most 3 consecutive agent sends with no inbound message in between".
public struct InboundRow: Hashable, Sendable {
    public var rowid: Int64
    public var guid: String
    public var dateNs: AppleNanos
    /// `TextNorm.textDigest` of the decoded body. `RateLimiter` compares it with `SendEvent.textDigest` to skip
    /// echoes of its own sends, which carry their own GUID.
    public var bodyDigest: String

    public init(rowid: Int64, guid: String, dateNs: AppleNanos, bodyDigest: String) {
        self.rowid = rowid
        self.guid = guid
        self.dateNs = dateNs
        self.bodyDigest = bodyDigest
    }
}

public protocol ChatActivitySource: AnyObject {
    /// Inbound visible rows in the conversation after `afterNs`, oldest first, at most `limit`. Visible means
    /// `ReadService`'s rules, so the self-chat echo copies it drops never appear here either.
    func inboundRows(in chat: ResolvedChat, afterNs: AppleNanos, limit: Int) throws -> [InboundRow]
}

// MARK: - Live conformance

extension ChatDatabase: SendRowSource {
    public func maxMessageRowID() throws -> Int64 { try interactive { try $0.maxRowID() } }

    public func fromMeRows(aboveRowID rowid: Int64, limit: Int) throws -> [SentRowProbe] {
        guard limit > 0 else { return [] }
        return try interactive { s in
            var out: [SentRowProbe] = []
            try s.each(SQLText.shared.fromMeAbove, [.int(rowid)], limit: limit) { out.append(s.sentProbe($0)) }
            return try out.map(s.withTransfers)
        }
    }

    public func sentRow(rowid: Int64) throws -> SentRowProbe? {
        try interactive { s in
            var out: SentRowProbe?
            try s.each(SQLText.shared.fromMeByID, [.int(rowid)], limit: 1) { out = s.sentProbe($0) }
            return try out.map(s.withTransfers)
        }
    }

    public func transferStates(transferNames: [String]) throws -> [String: Int] {
        try interactive { s in
            var out: [String: Int] = [:]
            for name in Set(transferNames) {
                try s.each(SQLText.shared.transferStateByName, [.text(name)], limit: 1) { r in
                    out[name] = Int(clamping: r.int(0))
                }
            }
            return out
        }
    }

    public func canonicalChatID(chatRowID: Int64) throws -> CanonicalChatID? {
        try interactive { s in
            var out: CanonicalChatID?
            try s.each(SQLText.shared.chatByRowID, [.int(chatRowID)], limit: 1) { r in
                let info = ChatInfo(rowid: r.int(0), guid: r.text(1) ?? "", identifier: r.text(3) ?? "", service: "",
                                    displayName: "", isGroup: r.int(2) == 43)
                out = ConversationIndex.canonical(of: info)
            }
            return out
        }
    }
}

extension ChatDatabase: UITargetSource {
    public func conversations() throws -> [ConversationSummary] {
        try interactive { s in try s.index().conversations.map(s.summary) }
    }

    public func conversation(for chat: ResolvedChat) throws -> ConversationSummary? {
        try interactive { s in try s.conversation(for: chat).map(s.summary) }
    }

    public func messageTarget(rowid: Int64) throws -> MessageTargetInfo? {
        try interactive { s in try s.row(id: rowid).flatMap(s.targetInfo) }
    }

    /// Counts rows in the target's conversation, the target left out, with the same direction, the same body after
    /// `TextNorm.matchKey`, and the same hour and minute in `configuration.timeZone`.
    public func sameBodyAndMinuteCount(for target: MessageTargetInfo) throws -> Int {
        let key = TextNorm.matchKey(target.body)
        guard !key.isEmpty else { return 0 }
        let minute = clockMinute(target.dateNs)
        return try interactive { s in
            let chats = try s.conversation(forChat: target.chatRowID)?.chatRowIDs ?? [target.chatRowID]
            var seen: Set<Int64> = [target.rowid]
            var count = 0
            for chat in chats {
                let params: [SQLiteValue] = [.int(chat), .int(target.fromMe ? 1 : 0), .int(target.rowid),
                                             .text(key), .text(key)]
                for row in try s.rows(SQLText.shared.sameBodyCandidates, params, limit: s.cap)
                where seen.insert(row.rowid).inserted {
                    guard !row.isEvent, try s.isVisible(row), TextNorm.matchKey(row.displayText) == key,
                          clockMinute(row.date) == minute else { continue }
                    count += 1
                }
            }
            return count
        }
    }

    /// The user's own reaction on one part, folded from every outgoing tapback row on it, joined or not. A row
    /// Messages has written but not joined yet still counts, as it does for `reactionRows(aboveRowID:)`.
    public func currentUserReaction(messageGUID: String, part: Int) throws -> TapbackKind? {
        guard part >= 0 else { return nil }
        return try interactive { s in
            let rows = try s.fromMeReactionRows(aboveRowID: Int64.min, targetGUID: messageGUID, part: part).map {
                TapbackFolder.Row(rowid: $0.rowid, associatedGUID: $0.associatedGUID, associatedType: $0.associatedType,
                                  emoji: $0.emoji, fromMe: true, actorHandle: nil)
            }
            let folded = TapbackFolder.fold(rows, name: { _ in "" })[messageGUID] ?? []
            return folded.last { $0.fromMe && $0.part == part }?.kind
        }
    }

    /// Outgoing tapback rows above `rowid` on `p:<part>/<guid>`, joined or not, oldest first. For part 0 the
    /// `bp:<guid>` form counts too, as it does when folding.
    public func reactionRows(aboveRowID rowid: Int64, targetGUID: String, part: Int) throws -> [ReactionRowProbe] {
        guard part >= 0 else { return [] }
        return try interactive { s in try s.fromMeReactionRows(aboveRowID: rowid, targetGUID: targetGUID, part: part) }
    }

    public func editState(rowid: Int64) throws -> EditStateProbe? {
        try interactive { s in
            var out: EditStateProbe?
            try s.each(SQLText.shared.editState, [.int(rowid)], limit: 1) { r in
                let retracted = r.int(2)
                let text = MessageRow.decode(text: r.text(3), body: r.blob(4)).text ?? ""
                let body = retracted != 0 ? "" : TextNorm.matchKey(text.replacingOccurrences(of: "\u{FFFC}", with: ""))
                out = EditStateProbe(rowid: r.int(0), dateEditedNs: r.int(1), dateRetractedNs: retracted, body: body)
            }
            return out
        }
    }

    public func newestIncoming(for chat: ResolvedChat) throws -> MessageTargetInfo? {
        try interactive { s in
            guard let conv = try s.conversation(for: chat) else { return nil }
            let rows = try s.visibleRows(in: conv, before: Int64.max, count: 1) { !$0.fromMe && !$0.isEvent }
            return try rows.first.flatMap(s.targetInfo)
        }
    }

    /// Hour and minute of an Apple time in the configured time zone.
    func clockMinute(_ ns: AppleNanos) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = configuration.timeZone
        let parts = calendar.dateComponents([.hour, .minute], from: AppleTime.date(fromNanos: ns))
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }
}

extension ChatDatabase: ChatActivitySource {
    public func inboundRows(in chat: ResolvedChat, afterNs: AppleNanos, limit: Int) throws -> [InboundRow] {
        guard limit > 0 else { return [] }
        return try interactive { s in
            guard let conv = try s.conversation(for: chat) else { return [] }
            let n = min(limit, s.cap)
            var out: [InboundRow] = []
            try s.merged(chats: conv.chatRowIDs, descending: false, start: (afterNs, Int64.max),
                         key: { ($0.joinDate, $0.rowid) },
                         fetch: { chat, cursor, batch in
                             let c = cursor ?? (afterNs, Int64.max)
                             return try s.rows(SQLText.shared.inboundAfterDate,
                                               [.int(chat ?? 0), .int(c.0), .int(c.0), .int(c.1)], limit: batch)
                         }, visit: { row in
                             if !row.isEvent, try s.isVisible(row) {
                                 out.append(InboundRow(rowid: row.rowid, guid: row.guid, dateNs: row.date,
                                                       bodyDigest: TextNorm.textDigest(row.displayText)))
                             }
                             return out.count < n
                         })
            return out
        }
    }
}

// MARK: - Session helpers for the consumer protocols

extension Session {
    func conversation(for chat: ResolvedChat) throws -> Conversation? {
        let index = try index()
        return index.byCanonical[chat.canonical] ?? chat.chatRowIDs.lazy.compactMap { index.byChat[$0] }.first
    }

    /// Columns of `SQLText.sentColumns`.
    func sentProbe(_ r: SQLiteRow) -> SentRowProbe {
        let text = MessageRow.decode(text: r.text(5), body: r.blob(6)).text ?? ""
        let body = TextNorm.matchKey(text.replacingOccurrences(of: "\u{FFFC}", with: ""))
        return SentRowProbe(rowid: r.int(0), guid: r.text(1) ?? "", handle: r.text(2).map(HandleNormalizer.normalize),
                            service: r.text(3), dateNs: r.int(4), body: body, hasBody: !body.isEmpty,
                            transferNames: [], transferStates: [:], error: Int(clamping: r.int(7)),
                            isSent: r.int(8) != 0, isDelivered: r.int(9) != 0, dateDeliveredNs: r.int(10),
                            joinedChatRowID: r.optionalInt(11), threadOriginatorGUID: r.text(12),
                            itemType: Int(clamping: r.int(13)))
    }

    func withTransfers(_ probe: SentRowProbe) throws -> SentRowProbe {
        var p = probe
        try each(SQLText.shared.transfersFor, [.int(probe.rowid)], limit: cap) { r in
            guard let name = r.text(0) else { return }
            p.transferNames.append(name)
            p.transferStates[name] = Int(clamping: r.int(1))
        }
        return p
    }

    /// Outgoing tapback rows above `rowid` on `p:<part>/<guid>`, plus `bp:<guid>` for part 0, joined or not,
    /// oldest first.
    func fromMeReactionRows(aboveRowID rowid: Int64, targetGUID: String, part: Int) throws -> [ReactionRowProbe] {
        var targets = ["p:\(part)/\(targetGUID)"]
        if part == 0 { targets.append("bp:\(targetGUID)") }
        var out: [ReactionRowProbe] = []
        for target in targets {
            try each(SQLText.shared.fromMeReactionsAbove, [.int(rowid), .text(target)], limit: cap) { r in
                out.append(ReactionRowProbe(rowid: r.int(0), associatedType: Int(clamping: r.int(1)),
                                            associatedGUID: r.text(2) ?? "", emoji: r.text(3), fromMe: r.int(4) != 0))
            }
        }
        return out.sorted { $0.rowid < $1.rowid }
    }

    /// The conversation as its Messages list row shows it. The preview and time come from the newest row the
    /// list counts, tapbacks and attachment-only rows included; echoes and merged link rows stay out.
    func summary(_ conv: Conversation) throws -> ConversationSummary {
        let newest = try visibleRows(in: conv, before: Int64.max, count: 1, includeTapbacks: true).first
        let signature = try visibleRows(in: conv, before: Int64.max, count: Limits.signatureRows) { row in
            !row.isEvent && !row.unsent && (row.balloon ?? "").isEmpty && !TextNorm.matchKey(row.displayText).isEmpty
        }.map { SignatureRow(fromMe: $0.fromMe, body: TextNorm.matchKey($0.displayText)) }
        let preview = try newest.map { try listPreview($0, in: conv) } ?? ""
        return ConversationSummary(canonical: conv.canonical, chatRowIDs: conv.chatRowIDs, isGroup: conv.isGroup,
                                   displayName: listName(conv), newestPreview: preview,
                                   newestDateNs: newest?.date ?? 0, signature: signature)
    }

    /// The name of a conversation's list row. The self-chat shows its handle there (an email as is, a phone
    /// through `formatPhone`), never the Me card's name; `conv.label` keeps `You (notes)` for the CLI.
    func listName(_ conv: Conversation) -> String {
        let primary = conv.primary
        if !conv.isGroup, primary.displayName.isEmpty, !primary.identifier.isEmpty,
           db.contacts.isOwner(primary.identifier) {
            return ContactBook.handleLabel(primary.identifier)
        }
        return conv.label
    }

    /// The preview line of a list row whose newest row is `row`.
    func listPreview(_ row: MessageRow, in conv: Conversation) throws -> String {
        if row.isTapback, let preview = try tapbackPreview(row, in: conv) { return preview }
        let text = TextNorm.oneLine(row.displayText)
        guard text.isEmpty else { return text }
        var kinds: [AttachmentKind] = []
        try each(SQLText.shared.attachmentsFor, [.int(row.rowid)], limit: cap) { r in
            kinds.append(AttachmentRow(r).kind(isAudioMessage: row.isAudio))
        }
        return RowPreview.attachments(kinds) ?? text
    }

    /// `You removed a heart from “<target>”` and the other `RowPreview.tapbacks` lines. Nil when the kind is not
    /// in the table or the target row is gone; the caller then uses the row's own text.
    func tapbackPreview(_ row: MessageRow, in conv: Conversation) throws -> String? {
        let key = RowPreview.Key(fromMe: row.fromMe, add: row.associatedType < 3000, offset: row.associatedType % 1000)
        guard let template = RowPreview.tapbacks[key] else { return nil }
        let guid = TapbackFolder.parseTarget(row.associatedGUID ?? "").guid
        var body: String?
        try each(SQLText.shared.parentByGUID, [.text(guid)], limit: 1) { r in
            body = MessageRow.decode(text: r.text(3), body: r.blob(4)).text ?? ""
        }
        guard let body else { return nil }
        let target = "\u{201C}" + TextNorm.oneLine(body.replacingOccurrences(of: "\u{FFFC}", with: "")) + "\u{201D}"
        return RowPreview.fill(template, ["name": senderName(handle: row.handle, fromMe: row.fromMe, in: conv),
                                          "emoji": row.associatedEmoji ?? "", "target": target])
    }

    func targetInfo(_ row: MessageRow) throws -> MessageTargetInfo? {
        guard let conv = try conversation(forChat: row.chatID) else { return nil }
        var hasAttachment = false
        try each(SQLText.shared.transfersFor, [.int(row.rowid)], limit: 1) { _ in hasAttachment = true }
        let body = row.displayText.precomposedStringWithCanonicalMapping
        let singlePart = try isVisible(row) && !row.isEvent && !row.isTapback && !hasAttachment
            && row.partCount == 1 && !TextNorm.matchKey(body).isEmpty && (row.balloon ?? "").isEmpty
        return MessageTargetInfo(rowid: row.rowid, guid: row.guid, chatRowID: row.chatID, canonical: conv.canonical,
                                 isGroupChat: conv.isGroup, fromMe: row.fromMe, body: body, dateNs: row.date,
                                 partCount: row.partCount, isSinglePartText: singlePart,
                                 dateEditedNs: row.dateEdited, isUnsent: row.unsent,
                                 senderName: senderName(handle: row.handle, fromMe: row.fromMe, in: conv))
    }
}

/// Text of a conversation list row's preview for rows that have no text of their own.
enum RowPreview {
    struct Key: Hashable {
        var fromMe: Bool
        var add: Bool
        /// Tapback type offset, 0 to 6 (`TapbackKind.typeOffset`).
        var offset: Int
    }

    // Only `You removed a heart from {target}` is recorded (the S3 dumps). Every other entry here, and the
    // attachment-only preview in `attachments(_:)`, is unconfirmed and left for release tests 1 to 3 to correct.
    // A wrong line makes the list row match fail, so the action stops as not_loaded instead of picking a row.
    static let tapbacks: [Key: String] = [
        Key(fromMe: true, add: true, offset: 0): "You loved {target}",
        Key(fromMe: true, add: true, offset: 1): "You liked {target}",
        Key(fromMe: true, add: true, offset: 2): "You disliked {target}",
        Key(fromMe: true, add: true, offset: 3): "You laughed at {target}",
        Key(fromMe: true, add: true, offset: 4): "You emphasized {target}",
        Key(fromMe: true, add: true, offset: 5): "You questioned {target}",
        Key(fromMe: true, add: true, offset: 6): "You reacted {emoji} to {target}",
        Key(fromMe: true, add: false, offset: 0): "You removed a heart from {target}",
        Key(fromMe: true, add: false, offset: 1): "You removed a like from {target}",
        Key(fromMe: true, add: false, offset: 2): "You removed a dislike from {target}",
        Key(fromMe: true, add: false, offset: 3): "You removed a laugh from {target}",
        Key(fromMe: true, add: false, offset: 4): "You removed an exclamation from {target}",
        Key(fromMe: true, add: false, offset: 5): "You removed a question mark from {target}",
        Key(fromMe: true, add: false, offset: 6): "You removed {emoji} from {target}",
        Key(fromMe: false, add: true, offset: 0): "{name} loved {target}",
        Key(fromMe: false, add: true, offset: 1): "{name} liked {target}",
        Key(fromMe: false, add: true, offset: 2): "{name} disliked {target}",
        Key(fromMe: false, add: true, offset: 3): "{name} laughed at {target}",
        Key(fromMe: false, add: true, offset: 4): "{name} emphasized {target}",
        Key(fromMe: false, add: true, offset: 5): "{name} questioned {target}",
        Key(fromMe: false, add: true, offset: 6): "{name} reacted {emoji} to {target}",
        Key(fromMe: false, add: false, offset: 0): "{name} removed a heart from {target}",
        Key(fromMe: false, add: false, offset: 1): "{name} removed a like from {target}",
        Key(fromMe: false, add: false, offset: 2): "{name} removed a dislike from {target}",
        Key(fromMe: false, add: false, offset: 3): "{name} removed a laugh from {target}",
        Key(fromMe: false, add: false, offset: 4): "{name} removed an exclamation from {target}",
        Key(fromMe: false, add: false, offset: 5): "{name} removed a question mark from {target}",
        Key(fromMe: false, add: false, offset: 6): "{name} removed {emoji} from {target}",
    ]

    /// `Attachment: 1 Image`, `Attachment: 2 Images`. Nil for no attachments.
    static func attachments(_ kinds: [AttachmentKind]) -> String? {
        guard let first = kinds.first else { return nil }
        let noun: String
        switch kinds.allSatisfy({ $0 == first }) ? first : .file {
        case .photo: noun = "Image"
        case .video: noun = "Video"
        case .voice: noun = "Audio Message"
        case .sticker: noun = "Sticker"
        case .file: noun = "File"
        }
        return "Attachment: \(kinds.count) \(noun)\(kinds.count == 1 ? "" : "s")"
    }

    /// Replaces each `{key}` in one pass, so a value that contains braces is never read as a placeholder.
    static func fill(_ template: String, _ values: [String: String]) -> String {
        var out = ""
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            out += rest[..<open]
            let key = String(rest[rest.index(after: open)..<close])
            out += values[key] ?? String(rest[open...close])
            rest = rest[rest.index(after: close)...]
        }
        return out + rest
    }
}
