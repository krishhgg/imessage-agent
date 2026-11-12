import Foundation
import IMCore

/// Bundle id of a URL preview balloon. Bound as a parameter, never written into SQL.
let urlBalloonBundleID = "com.apple.messages.URLBalloonProvider"
/// Bundle id of a poll balloon (research/macos.md). Compared in Swift, never written into SQL.
let pollBalloonBundleID = "com.apple.messages.Polls"
/// A URL balloon row this close after a text row with the same URL merges into that row (bench/reader.py).
let linkMergeWindowNs: Int64 = 5_000_000_000
let nanosPerDay: Int64 = 86_400_000_000_000

// MARK: - Chats and conversations

/// One chat.db chat.
struct ChatInfo {
    let rowid: Int64
    let guid: String
    let identifier: String
    let service: String
    let displayName: String
    let isGroup: Bool
    /// Raw member handles in handle ROWID order, duplicates kept.
    var members: [String] = []
    /// Newest `chat_message_join.message_date`, 0 for an empty chat.
    var lastDate: Int64 = 0
}

/// A conversation as the user sees it: one group chat, or every 1:1 chat with the same normalized handle.
final class Conversation {
    let canonical: CanonicalChatID
    let isGroup: Bool
    /// Newest first. Empty for a new direct target.
    var chats: [ChatInfo]
    var label = ""
    /// Raw member handles, one per normalized handle, the user's own left out.
    var memberHandles: [String] = []
    var memberNames: [String] = []
    /// Normalized participant handles, the user's own left out.
    var handles: [String] = []
    /// `primary` when there are no chats: ROWID 0, and the handle the send addresses as the identifier.
    private let standIn: ChatInfo

    init(canonical: CanonicalChatID, isGroup: Bool, chats: [ChatInfo]) {
        self.canonical = canonical
        self.isGroup = isGroup
        self.chats = chats
        standIn = ChatInfo(rowid: 0, guid: "", identifier: "", service: "", displayName: "", isGroup: isGroup)
    }

    /// A 1:1 conversation chat.db has no chat for yet (section 5: a phone, email or contact handle the user has
    /// never messaged). It has no chats, so reads find no rows, and it sends to `handle` on `service`
    /// (`Session.newDirectService`).
    init(newDirect handle: String, service: String, contacts: ContactBook) {
        canonical = .direct(handle: handle)
        isGroup = false
        chats = []
        standIn = ChatInfo(rowid: 0, guid: "", identifier: handle, service: service, displayName: "", isGroup: false)
        ConversationIndex.describe(self, contacts: contacts)
    }

    var primary: ChatInfo { chats.first ?? standIn }
    var chatRowIDs: [Int64] { chats.map(\.rowid) }
    var ref: ChatRef { ChatRef(rowid: primary.rowid, label: label, isGroup: isGroup) }

    var resolved: ResolvedChat {
        ResolvedChat(canonical: canonical, chatRowIDs: chatRowIDs, chatGUIDs: chats.map(\.guid),
                     primaryChatRowID: primary.rowid, label: label, isGroup: isGroup, handles: handles,
                     sendHandle: isGroup ? nil : primary.identifier, service: primary.service)
    }
}

/// Every chat grouped into conversations, rebuilt for each call so it never goes stale.
struct ConversationIndex {
    var chats: [Int64: ChatInfo] = [:]
    /// Newest first: by the newest row of the primary chat, then chat ROWID.
    var conversations: [Conversation] = []
    var byChat: [Int64: Conversation] = [:]
    var byCanonical: [CanonicalChatID: Conversation] = [:]
    /// 1:1 chats whose handle is the user's own.
    var selfChats: Set<Int64> = []

    static func load(_ s: Session) throws -> ConversationIndex {
        let q = SQLText.shared
        let contacts = s.db.contacts
        var index = ConversationIndex()
        var order: [Int64] = []
        try s.eachAll(q.chatList, [], cap: s.indexCap) { r in
            let info = ChatInfo(rowid: r.int(0), guid: r.text(1) ?? "", identifier: r.text(3) ?? "",
                                service: r.text(4) ?? "", displayName: r.text(5) ?? "", isGroup: r.int(2) == 43)
            if index.chats[info.rowid] == nil { order.append(info.rowid) }
            index.chats[info.rowid] = info
        }
        try s.eachAll(q.chatMembers, [], cap: s.indexCap) { r in
            if let h = r.text(1), !h.isEmpty { index.chats[r.int(0)]?.members.append(h) }
        }
        for id in order {
            try s.each(q.chatLastDate, [.int(id)], limit: 1) { r in index.chats[id]?.lastDate = r.int(0) }
        }

        var grouped: [CanonicalChatID: Conversation] = [:]
        var convOrder: [CanonicalChatID] = []
        for id in order {
            guard let info = index.chats[id] else { continue }
            let canonical = ConversationIndex.canonical(of: info)
            if let key = canonical.directHandle, contacts.isOwner(key) { index.selfChats.insert(id) }
            if let conv = grouped[canonical] {
                conv.chats.append(info)
            } else {
                grouped[canonical] = Conversation(canonical: canonical, isGroup: info.isGroup, chats: [info])
                convOrder.append(canonical)
            }
        }
        var conversations: [Conversation] = []
        for canonical in convOrder {
            guard let conv = grouped[canonical] else { continue }
            conv.chats.sort { ($0.lastDate, -$0.rowid) > ($1.lastDate, -$1.rowid) }
            describe(conv, contacts: contacts)
            conversations.append(conv)
            for chat in conv.chats { index.byChat[chat.rowid] = conv }
            index.byCanonical[canonical] = conv
        }
        conversations.sort { ($0.primary.lastDate, -$0.primary.rowid) > ($1.primary.lastDate, -$1.primary.rowid) }
        index.conversations = conversations
        return index
    }

    /// The identity a chat belongs to: a group by its identifier (its guid when that is empty), a 1:1 chat by its
    /// normalized handle, and a 1:1 chat with no usable handle on its own, by its guid.
    static func canonical(of info: ChatInfo) -> CanonicalChatID {
        if info.isGroup { return .group(identifier: info.identifier.isEmpty ? info.guid : info.identifier) }
        let key = HandleNormalizer.normalize(info.identifier)
        return key.isEmpty ? .group(identifier: info.guid) : .direct(handle: key)
    }

    /// Members, handles, names and the label (`chat_label` in ours.py).
    static func describe(_ conv: Conversation, contacts: ContactBook) {
        var seen: Set<String> = []
        var members: [String] = []
        for chat in conv.chats {
            for h in chat.members {
                let key = HandleNormalizer.normalize(h)
                guard !key.isEmpty, !contacts.isOwner(key), seen.insert(key).inserted else { continue }
                members.append(h)
            }
        }
        let primary = conv.primary
        if !conv.isGroup, members.isEmpty, !primary.identifier.isEmpty, !contacts.isOwner(primary.identifier) {
            members = [primary.identifier]
        }
        conv.memberHandles = members
        conv.handles = members.map(HandleNormalizer.normalize)
        conv.memberNames = members.map { contacts.shortName(for: $0, among: members) }

        if !primary.displayName.isEmpty {
            conv.label = primary.displayName
        } else if conv.isGroup {
            conv.label = conv.memberNames.joined(separator: ", ")
        } else if contacts.isOwner(primary.identifier) {
            conv.label = "You (notes)"
        } else if let card = contacts.card(for: primary.identifier) {
            conv.label = card.nickname ?? contacts.fullName(for: primary.identifier)
                ?? contacts.shortName(for: primary.identifier)
        } else {
            conv.label = contacts.shortName(for: primary.identifier)
        }
    }
}

// MARK: - Message rows

/// One row of `SQLText.rowColumns`: a message with its previous and next row in the same chat.
final class MessageRow {
    let rowid: Int64
    let guid: String
    let textColumn: String?
    let body: Data?
    let handleID: Int64
    let handle: String?
    let otherHandle: String?
    let service: String?
    let date: Int64
    let fromMe: Bool
    let itemType: Int
    let groupActionType: Int
    let groupTitle: String?
    let associatedType: Int
    let associatedGUID: String?
    let associatedEmoji: String?
    let threadGUID: String?
    let summaryData: Data?
    let dateEdited: Int64
    let dateRetracted: Int64
    let isRead: Bool
    let dateRead: Int64
    let isDelivered: Bool
    let dateDelivered: Int64
    let isSent: Bool
    let error: Int
    let balloon: String?
    let payload: Data?
    let isAudio: Bool
    let partCountColumn: Int
    let chatID: Int64
    let joinDate: Int64

    let prevRowID: Int64?
    let prevFromMe: Bool
    let prevHandleID: Int64
    let prevDate: Int64
    private let prevTextColumn: String?
    private let prevBody: Data?

    let nextRowID: Int64?
    let nextFromMe: Bool
    let nextHandleID: Int64
    let nextDate: Int64
    let nextBalloon: String?
    private let nextPayload: Data?

    /// Event time for `changes`, from the extra column of `changedRows`.
    var eventTime: Int64 = 0

    init(_ r: SQLiteRow) {
        rowid = r.int(0)
        guid = r.text(1) ?? ""
        textColumn = r.text(2)
        body = r.blob(3)
        handleID = r.int(4)
        handle = r.text(5)
        otherHandle = r.text(6)
        service = r.text(7)
        date = r.int(8)
        fromMe = r.int(9) != 0
        itemType = Int(clamping: r.int(10))
        groupActionType = Int(clamping: r.int(11))
        groupTitle = r.text(12)
        associatedType = Int(clamping: r.int(13))
        associatedGUID = r.text(14)
        associatedEmoji = r.text(15)
        threadGUID = r.text(16)
        summaryData = r.blob(17)
        dateEdited = r.int(18)
        dateRetracted = r.int(19)
        isRead = r.int(20) != 0
        dateRead = r.int(21)
        isDelivered = r.int(22) != 0
        dateDelivered = r.int(23)
        isSent = r.int(24) != 0
        error = Int(clamping: r.int(25))
        balloon = r.text(26)
        payload = r.blob(27)
        isAudio = r.int(28) != 0
        partCountColumn = Int(clamping: r.int(29))
        chatID = r.int(30)
        prevRowID = r.optionalInt(31)
        prevFromMe = r.int(32) != 0
        prevHandleID = r.int(33)
        prevDate = r.int(34)
        prevTextColumn = r.text(35)
        prevBody = r.blob(36)
        nextRowID = r.optionalInt(37)
        nextFromMe = r.int(38) != 0
        nextHandleID = r.int(39)
        nextDate = r.int(40)
        nextBalloon = r.text(41)
        nextPayload = r.blob(42)
        joinDate = r.int(43)
    }

    // MARK: Body

    private lazy var decoded: (text: String?, runs: [AttributeRun]) =
        MessageRow.decode(text: textColumn, body: body)

    /// Decoded body with U+FFFC placeholders, nil when the row has neither attributedBody nor text.
    var text: String? { decoded.text }
    var runs: [AttributeRun] { decoded.runs }
    /// What records carry: the body without U+FFFC.
    var displayText: String { (text ?? "").replacingOccurrences(of: "\u{FFFC}", with: "") }

    /// attributedBody when it decodes, else the text column (bench/reader.py `_load`).
    static func decode(text: String?, body: Data?) -> (text: String?, runs: [AttributeRun]) {
        if let body, !body.isEmpty, let d = try? TypedStreamDecoder.decodeAttributedString(body) {
            return (d.text, d.runs)
        }
        return (text, [])
    }

    private lazy var prevText: String? = MessageRow.decode(text: prevTextColumn, body: prevBody).text

    // MARK: Kinds

    var isTapback: Bool { (2000...3999).contains(associatedType) }
    var isPlacedSticker: Bool { associatedType == 1000 }
    /// A poll vote (research/macos.md). Like a tapback it is an associated row and never prints; the poll itself does.
    var isPollVote: Bool { associatedType == 4000 }
    var isEvent: Bool { itemType != 0 }

    // MARK: Edits

    private lazy var summary: SummaryInfo? = {
        guard let summaryData, !summaryData.isEmpty else { return nil }
        return try? SummaryInfo.decode(summaryData)
    }()

    var unsentParts: [Int] { summary?.unsentParts ?? [] }
    var edited: Bool { !(summary?.editVersions.isEmpty ?? true) && dateEdited != 0 }
    var unsent: Bool { dateRetracted != 0 || (!unsentParts.isEmpty && (text ?? "").isEmpty && dateEdited != 0) }
    var partUnsent: Bool { !unsent && !unsentParts.isEmpty }

    /// Parts: the column, the highest part in the runs plus one, and at least 1.
    var partCount: Int {
        var highest = -1
        for run in runs {
            if let p = run.attributes["__kIMMessagePartAttributeName"]?.integerValue, p >= 0, p < 1_000 {
                highest = max(highest, Int(p))
            }
        }
        return max(partCountColumn, highest + 1, 1)
    }

    // MARK: Links and visibility

    private lazy var ownLink: LinkRecord? = MessageRow.link(balloon: balloon, payload: payload)
    private lazy var nextLink: LinkRecord? = MessageRow.link(balloon: nextBalloon, payload: nextPayload)

    static func link(balloon: String?, payload: Data?) -> LinkRecord? {
        guard balloon == urlBalloonBundleID, let payload, !payload.isEmpty else { return nil }
        return LinkMetadataDecoder.decode(payload)
    }

    /// `later - earlier <= 5 s`, without overflow.
    static func withinMergeWindow(later: Int64, earlier: Int64) -> Bool {
        let (diff, overflow) = later.subtractingReportingOverflow(earlier)
        if overflow { return later < earlier }
        return diff <= linkMergeWindowNs
    }

    /// A URL balloon row that repeats the previous row's URL (bench `_mark_echoes_and_link_duplicates`).
    var isDuplicateLink: Bool {
        guard prevRowID != nil, let url = ownLink?.url, !url.isEmpty, prevHandleID == handleID, prevFromMe == fromMe,
              let pt = prevText, !pt.isEmpty, pt.contains(url) else { return false }
        return MessageRow.withinMergeWindow(later: date, earlier: prevDate)
    }

    /// The link this row shows: the next row's, when that row is a duplicate of this one, else its own.
    var shownLink: LinkRecord? {
        if nextRowID != nil, let link = nextLink, let url = link.url, !url.isEmpty, nextHandleID == handleID,
           nextFromMe == fromMe, let t = text, !t.isEmpty, t.contains(url),
           MessageRow.withinMergeWindow(later: nextDate, earlier: date) {
            return link
        }
        return ownLink
    }

    /// The incoming copy a self chat gets of each outgoing row: not from me, right after a from-me row, same text.
    func isEcho(inSelfChat selfChat: Bool) -> Bool {
        selfChat && !fromMe && prevRowID != nil && prevFromMe && prevText == text
    }
}

// MARK: - Session

/// One call's view of chat.db: a connection, its budget, the conversation index and record building.
/// A session lives inside `SQLiteConnection.withBudget`, so it holds the connection lock for the whole call.
final class Session {
    let db: ChatDatabase
    let conn: SQLiteConnection
    let cap: Int
    /// Row cap of the conversation index loads (`StoreConfiguration.indexRowCap`).
    let indexCap: Int
    let timeout: TimeInterval
    let agentSent: Set<String>
    private var loadedIndex: ConversationIndex?

    /// Most rows fetched per query when a scan walks a chat.
    static let batch = 200
    /// Extra rows a counted scan asks for on its first fetch, so a few hidden rows don't cost a second query.
    static let slack = 8

    init(db: ChatDatabase, conn: SQLiteConnection, timeout: TimeInterval) {
        self.db = db
        self.conn = conn
        self.cap = max(1, db.configuration.rowCap)
        self.indexCap = max(1, db.configuration.indexRowCap)
        self.timeout = timeout
        self.agentSent = db.agentSentGUIDs
    }

    func index() throws -> ConversationIndex {
        if let loadedIndex { return loadedIndex }
        let index = try ConversationIndex.load(self)
        loadedIndex = index
        return index
    }

    /// Runs fixed SQL. `limit` binds the trailing `LIMIT ?` and never goes above the row cap, which the connection
    /// enforces as well.
    func each(_ sql: String, _ params: [SQLiteValue], limit: Int, _ body: (SQLiteRow) throws -> Void) throws {
        let n = Int64(max(0, min(limit, cap)))
        try conn.withBudget(seconds: timeout, rowCap: cap) {
            try conn.query(sql, params + [.int(n)], row: body)
        }
    }

    /// Runs fixed SQL whose every row the caller needs. It binds `cap + 1` into the trailing `LIMIT ?` and throws
    /// `rowCapExceeded` when that extra row comes back, so nothing is built from a list that was cut short.
    func eachAll(_ sql: String, _ params: [SQLiteValue], cap: Int, _ body: (SQLiteRow) throws -> Void) throws {
        let limit = max(0, cap)
        var seen = 0
        try conn.withBudget(seconds: timeout, rowCap: limit + 1) {
            try conn.query(sql, params + [.int(Int64(limit) + 1)]) { r in
                seen += 1
                if seen > limit { throw StoreError.rowCapExceeded }
                try body(r)
            }
        }
    }

    func rows(_ sql: String, _ params: [SQLiteValue], limit: Int) throws -> [MessageRow] {
        var out: [MessageRow] = []
        try each(sql, params, limit: limit) { out.append(MessageRow($0)) }
        return out
    }

    func conversation(forChat id: Int64) throws -> Conversation? { try index().byChat[id] }

    // MARK: Visibility

    /// `includeTapbacks` keeps tapback rows, which the conversation list shows as a row's newest message.
    func isVisible(_ row: MessageRow, includeTapbacks: Bool = false) throws -> Bool {
        if row.isPlacedSticker || row.isPollVote || (row.isTapback && !includeTapbacks) { return false }
        if row.isEcho(inSelfChat: try index().selfChats.contains(row.chatID)) { return false }
        return !row.isDuplicateLink
    }

    /// An incoming self-chat row whose body matches one of the 20 previous outgoing rows the bridge sent.
    func isAgentEcho(_ row: MessageRow) throws -> Bool {
        guard !agentSent.isEmpty, !row.fromMe, try index().selfChats.contains(row.chatID) else { return false }
        let key = TextNorm.matchKey(row.displayText)
        var hit = false
        try each(SQLText.shared.fromMeBefore, [.int(row.chatID), .int(row.rowid)], limit: 20) { r in
            guard !hit, let guid = r.text(0), agentSent.contains(guid) else { return }
            let text = MessageRow.decode(text: r.text(1), body: r.blob(2)).text ?? ""
            if TextNorm.matchKey(text.replacingOccurrences(of: "\u{FFFC}", with: "")) == key { hit = true }
        }
        return hit
    }

    /// Rows the bridge sent, and their echoes. `wait` skips them, and `changes` never reports them as new.
    func isAgentRow(_ row: MessageRow) throws -> Bool {
        if agentSent.contains(row.guid) { return true }
        return try isAgentEcho(row)
    }

    // MARK: Scans

    /// Merges per-chat scans by key. `fetch(chat, cursor, n)` returns up to `n` rows strictly past `cursor` in
    /// scan order; nil chat means every chat. A message joined to two chats is visited once. `visit` returns false
    /// to stop. Each chat's first fetch asks for `batch` rows (at most `Session.batch`), and each later fetch for
    /// twice as many, up to `Session.batch`. A fetch that returns fewer rows than it asked for ends that chat.
    func merged(chats: [Int64?], descending: Bool, start: (Int64, Int64)?, key: (MessageRow) -> (Int64, Int64),
                batch: Int = Session.batch, fetch: (Int64?, (Int64, Int64)?, Int) throws -> [MessageRow],
                visit: (MessageRow) throws -> Bool) throws {
        var buffers = Array(repeating: [MessageRow](), count: chats.count)
        var heads = Array(repeating: 0, count: chats.count)
        var cursors = Array(repeating: start, count: chats.count)
        var finished = Array(repeating: false, count: chats.count)
        var sizes = Array(repeating: max(1, min(batch, Session.batch)), count: chats.count)
        var seen: Set<Int64> = []
        while true {
            for i in chats.indices where !finished[i] && heads[i] >= buffers[i].count {
                let rows = try fetch(chats[i], cursors[i], sizes[i])
                buffers[i] = rows
                heads[i] = 0
                if rows.count < sizes[i] { finished[i] = true }
                if let last = rows.last { cursors[i] = key(last) }
                sizes[i] = min(Session.batch, sizes[i] * 2)
            }
            var best: Int?
            for i in chats.indices where heads[i] < buffers[i].count {
                guard let b = best else {
                    best = i
                    continue
                }
                let k = key(buffers[i][heads[i]])
                let kb = key(buffers[b][heads[b]])
                if descending ? k > kb : k < kb { best = i }
            }
            guard let b = best else { return }
            let row = buffers[b][heads[b]]
            heads[b] += 1
            guard seen.insert(row.rowid).inserted else { continue }
            if try !visit(row) { return }
        }
    }

    /// Visible rows of a conversation below `before`, newest first, until `count` pass `keep`. The first fetch
    /// per chat asks for `count` plus `Session.slack` rows, so a short read never pulls a whole batch.
    func visibleRows(in conv: Conversation, before: Int64, count: Int, includeTapbacks: Bool = false,
                     keep: (MessageRow) throws -> Bool = { _ in true }) throws -> [MessageRow] {
        var out: [MessageRow] = []
        guard count > 0 else { return out }
        try merged(chats: conv.chatRowIDs, descending: true, start: (before, 0), key: { ($0.rowid, 0) },
                   batch: count.addingReportingOverflow(Session.slack).partialValue,
                   fetch: { chat, cursor, n in
                       try self.rows(SQLText.shared.rowsBefore, [.int(chat ?? 0), .int(cursor?.0 ?? before)], limit: n)
                   }, visit: { row in
                       if try self.isVisible(row, includeTapbacks: includeTapbacks), try keep(row) { out.append(row) }
                       return out.count < count
                   })
        return out
    }

    /// Visible rows of a conversation above `after`, oldest first, until `count` pass `keep`.
    func visibleRows(in conv: Conversation, after: Int64, count: Int,
                     keep: (MessageRow) throws -> Bool = { _ in true }) throws -> [MessageRow] {
        var out: [MessageRow] = []
        guard count > 0 else { return out }
        try merged(chats: conv.chatRowIDs, descending: false, start: (after, 0), key: { ($0.rowid, 0) },
                   batch: count.addingReportingOverflow(Session.slack).partialValue,
                   fetch: { chat, cursor, n in
                       try self.rows(SQLText.shared.rowsAfter, [.int(chat ?? 0), .int(cursor?.0 ?? after)], limit: n)
                   }, visit: { row in
                       if try self.isVisible(row), try keep(row) { out.append(row) }
                       return out.count < count
                   })
        return out
    }

    func row(id: Int64) throws -> MessageRow? {
        try rows(SQLText.shared.rowByID, [.int(id)], limit: 1).first
    }

    // MARK: Records

    func senderName(handle: String?, fromMe: Bool, in conv: Conversation?) -> String {
        if fromMe { return "You" }
        if let conv, conv.isGroup { return db.contacts.shortName(for: handle, among: conv.memberHandles) }
        return db.contacts.shortName(for: handle)
    }

    func record(_ row: MessageRow) throws -> MessageRecord {
        let conv = try conversation(forChat: row.chatID)
        let (reactions, stickers) = try reactionsAndStickers(guid: row.guid, partCount: row.partCount, in: conv)
        let sender = senderName(handle: row.handle, fromMe: row.fromMe, in: conv)
        return MessageRecord(
            rowid: row.rowid, guid: row.guid, chatRowID: row.chatID, dateNs: row.date, fromMe: row.fromMe,
            senderName: sender, senderHandle: row.fromMe ? nil : row.handle, service: row.service,
            text: row.displayText, replyTo: try reply(for: row, in: conv), attachments: try attachments(for: row),
            edited: row.edited, unsent: row.unsent, partUnsent: row.partUnsent, errorCode: row.error,
            reactions: reactions, stickers: stickers, event: event(for: row, sender: sender, in: conv),
            link: row.shownLink, isRead: row.isRead, dateDeliveredNs: row.dateDelivered, dateReadNs: row.dateRead,
            dateEditedNs: row.dateEdited, partCount: row.partCount, agentSent: agentSent.contains(row.guid))
    }

    /// Group events, location shares (item_type 4) and poll balloons, which print as short events (DESIGN 5).
    /// Poll payloads are not decoded, so a poll has no title. Vote rows (type 4000) are not polls.
    func event(for row: MessageRow, sender: String, in conv: Conversation?) -> EventRecord? {
        guard row.isEvent else {
            guard row.balloon == pollBalloonBundleID, row.associatedType == 0 else { return nil }
            return EventRecord(kind: .poll, actorName: sender, itemType: row.itemType,
                               groupActionType: row.groupActionType)
        }
        let kind: GroupEventKind
        switch (row.itemType, row.groupActionType) {
        case (2, _): kind = .renamed
        case (1, 0): kind = .added
        case (1, 1): kind = .removed
        case (3, _): kind = .left
        case (4, _): kind = .location
        default: kind = .other
        }
        let other = row.otherHandle.map { senderName(handle: $0, fromMe: false, in: conv) }
        return EventRecord(kind: kind, actorName: sender, otherName: other,
                           title: kind == .renamed ? (row.groupTitle ?? "") : row.groupTitle,
                           itemType: row.itemType, groupActionType: row.groupActionType)
    }

    func reply(for row: MessageRow, in conv: Conversation?) throws -> ReplyRef? {
        guard let guid = row.threadGUID, !guid.isEmpty else { return nil }
        var out: ReplyRef?
        try each(SQLText.shared.parentByGUID, [.text(guid)], limit: 1) { r in
            let text = MessageRow.decode(text: r.text(3), body: r.blob(4)).text ?? ""
            let parentConv = r.optionalInt(5).flatMap { try? self.conversation(forChat: $0) } ?? conv
            out = ReplyRef(rowid: r.int(0),
                           senderName: senderName(handle: r.text(2), fromMe: r.int(1) != 0, in: parentConv),
                           text: TextNorm.oneLine(text.replacingOccurrences(of: "\u{FFFC}", with: "")))
        }
        return out
    }

    /// Tapback and sticker rows aimed at `p:0/`…`p:<n-1>/` and `bp:` of a message, in ROWID order.
    func reactionRows(guid: String, partCount: Int) throws -> [TapbackFolder.Row] {
        var targets = (0..<max(1, partCount)).map { "p:\($0)/\(guid)" }
        targets.append("bp:\(guid)")
        var rows: [TapbackFolder.Row] = []
        for target in targets {
            try each(SQLText.shared.reactionsFor, [.text(target)], limit: cap) { r in
                rows.append(TapbackFolder.Row(rowid: r.int(0), associatedGUID: r.text(1) ?? "",
                                              associatedType: Int(clamping: r.int(2)), emoji: r.text(3),
                                              fromMe: r.int(4) != 0, actorHandle: r.text(5)))
            }
        }
        return rows.sorted { $0.rowid < $1.rowid }
    }

    func reactionsAndStickers(guid: String, partCount: Int,
                              in conv: Conversation?) throws -> ([ReactionRecord], [StickerRecord]) {
        let rows = try reactionRows(guid: guid, partCount: partCount)
        guard !rows.isEmpty else { return ([], []) }
        let name: (String?) -> String = { self.senderName(handle: $0, fromMe: false, in: conv) }
        let reactions = TapbackFolder.fold(rows, name: name)[guid] ?? []
        let stickers = rows.filter { $0.associatedType == 1000 }.map { r in
            StickerRecord(actorName: r.fromMe ? "You" : name(r.actorHandle), fromMe: r.fromMe,
                          part: TapbackFolder.parseTarget(r.associatedGUID).part, rowid: r.rowid)
        }
        return (reactions, stickers)
    }

    func attachments(for row: MessageRow) throws -> [AttachmentRecord] {
        var out: [AttachmentRecord] = []
        try each(SQLText.shared.attachmentsFor, [.int(row.rowid)], limit: cap) { r in
            out.append(AttachmentRow(r).record(runs: row.runs, isAudioMessage: row.isAudio,
                                               root: db.configuration.attachmentsRoot))
        }
        return out
    }
}

// MARK: - Attachment rows

/// Columns 0 to 9 of `attachmentsFor` and `attachmentByID`.
struct AttachmentRow {
    let rowid: Int64
    let guid: String
    let filename: String?
    let uti: String?
    let mimeType: String?
    let transferName: String?
    let totalBytes: Int64?
    let isSticker: Bool
    let transferState: Int
    let userInfo: Data?
    /// Column 10: the message that carries it.
    let messageRowID: Int64?

    init(_ r: SQLiteRow) {
        rowid = r.int(0)
        guid = r.text(1) ?? ""
        filename = r.text(2)
        uti = r.text(3)
        mimeType = r.text(4)
        transferName = r.text(5)
        totalBytes = r.optionalInt(6)
        isSticker = r.int(7) != 0
        transferState = Int(clamping: r.int(8))
        userInfo = r.blob(9)
        messageRowID = r.optionalInt(10)
    }

    /// `Attachment.kind` in bench/reader.py.
    func kind(isAudioMessage: Bool) -> AttachmentKind {
        let mime = mimeType ?? ""
        if isSticker { return .sticker }
        if mime.hasPrefix("image/") { return .photo }
        if mime.hasPrefix("video/") { return .video }
        if mime.hasPrefix("audio/") || isAudioMessage { return .voice }
        return .file
    }

    var transcript: String? {
        guard let userInfo, !userInfo.isEmpty,
              let plist = try? PropertyListSerialization.propertyList(from: userInfo, options: [], format: nil),
              let dict = plist as? [String: Any], let t = dict["audio-transcription"] as? String, !t.isEmpty else {
            return nil
        }
        return t
    }

    func record(runs: [AttributeRun], isAudioMessage: Bool, root: URL) -> AttachmentRecord {
        var width: Int?
        var height: Int?
        for run in runs where run.attributes["__kIMFileTransferGUIDAttributeName"] == .string(guid) {
            if let w = run.attributes["__kIMInlineMediaWidthAttributeName"]?.integerValue, w > 0 {
                width = Int(clamping: w)
            }
            if let h = run.attributes["__kIMInlineMediaHeightAttributeName"]?.integerValue, h > 0 {
                height = Int(clamping: h)
            }
        }
        let name = transferName ?? filename.map { ($0 as NSString).lastPathComponent } ?? ""
        let onDisk = filename.flatMap { AttachmentPaths.mapped($0, root: root) }
            .map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        return AttachmentRecord(rowid: rowid, guid: guid, kind: kind(isAudioMessage: isAudioMessage),
                                transferName: name, mimeType: mimeType, uti: uti, totalBytes: totalBytes,
                                width: width, height: height, transcript: transcript, onDisk: onDisk,
                                transferState: transferState)
    }
}

/// Maps `attachment.filename` onto the Attachments root.
enum AttachmentPaths {
    static let messagesPrefix = "~/Library/Messages/Attachments/"

    /// The file under `root` that `filename` names, or nil when it names anything outside `root`. This check is
    /// lexical; `AttachmentService` repeats it with realpath before it opens anything.
    static func mapped(_ filename: String, root: URL) -> URL? {
        let rootPath = root.standardizedFileURL.path
        let candidate: String
        if filename.hasPrefix(messagesPrefix) {
            candidate = rootPath + "/" + filename.dropFirst(messagesPrefix.count)
        } else if filename.hasPrefix("/") {
            candidate = filename
        } else {
            return nil
        }
        guard !filename.contains("\u{0}") else { return nil }
        let standardized = URL(fileURLWithPath: candidate).standardizedFileURL.path
        guard AttachmentService.contains(standardized, in: rootPath) else { return nil }
        return URL(fileURLWithPath: standardized)
    }
}
