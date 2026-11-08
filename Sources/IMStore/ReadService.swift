import Foundation
import IMCore

/// The read ops of DESIGN.md section 1 (`chats`, `messages`, `message`, `search`, `contacts`, `changes`) plus
/// `unread` and `wait` for section 5. Fixed SQL, bound parameters, row caps, 2 s interactive budget. Owner: IMStore.
///
/// Visibility rules (bench/reader.py and bench/renderers/ours.py `visible`):
/// - Tapback rows (2000 to 3999) and placed stickers (1000) fold into their target and never print.
/// - Self-chat echo copies (from_me 0, same text, right after a from_me 1 row) are dropped.
/// - A URL balloon row within 5 s of a text row with the same URL merges into that row.
/// - Recently Deleted rows (no chat_message_join row) are skipped.
/// - Unsent rows print `(unsent)`; partly unsent print `(part unsent)`.
public final class ReadService {
    public let db: ChatDatabase

    public init(db: ChatDatabase) { self.db = db }

    /// Recent chats, newest first, with unread counts and the newest visible message.
    /// A contact's iMessage and SMS chats merge into one row.
    public func chats(_ args: ChatsArgs) throws -> ChatsPage {
        let limit = max(1, min(args.limit, Limits.outputMaxLines))
        return try db.interactive { s in
            let unread = try s.unreadCounts()
            var eligible = try s.index().conversations
            if args.unreadOnly { eligible = eligible.filter { (unread[$0.canonical] ?? 0) > 0 } }
            let records = try eligible.prefix(limit).map {
                try s.chatRecord($0, unreadCount: unread[$0.canonical] ?? 0)
            }
            return ChatsPage(chats: records, hasMore: eligible.count > limit, limit: limit)
        }
    }

    /// Unread incoming messages (`is_read` 0, not from me, not tapbacks or events), grouped by chat, newest chat
    /// first, with up to `args.context` earlier visible lines before each run.
    ///
    /// Every group keeps its chat and unread count, so the header totals cover every unread message. Message
    /// records are built only for what the 200-line text page can show: groups that may fit get all their
    /// entries, the first group that can't fit gets the oldest entries up to the lines left, and later groups get
    /// none. Format.unread prints the same page either way.
    public func unread(_ args: UnreadArgs) throws -> UnreadPage {
        try unreadPage(args, lineBudget: Limits.outputMaxLines)
    }

    /// `unread` for a page of at most `lineBudget` lines. Tests pass `Int.max` to build every entry.
    func unreadPage(_ args: UnreadArgs, lineBudget: Int) throws -> UnreadPage {
        let context = max(0, min(args.context, Limits.outputMaxLines))
        return try db.interactive { s in
            var byConversation: [CanonicalChatID: [MessageRow]] = [:]
            for row in try s.unreadRows() {
                if let key = s.conversationKey(row) { byConversation[key, default: []].append(row) }
            }
            let unreadConversations = try s.index().conversations.filter { byConversation[$0.canonical] != nil }
            // Lines left after the page header. A block with n entries takes at least 3 + n lines: the chat
            // header, a day separator, an unread marker and one line per entry. A block that is not last also
            // needs room for the `more:` line that points at the next chat.
            var remaining = max(0, lineBudget - 1)
            var cut = false
            var groups: [UnreadGroup] = []
            for (gi, conv) in unreadConversations.enumerated() {
                let rows = byConversation[conv.canonical] ?? []
                var entries: [UnreadEntry] = []
                if !cut {
                    let built = try s.unreadEntries(conv, rows: rows, context: context, limit: remaining)
                    entries = built.entries
                    let next = gi + 1 < unreadConversations.count ? 1 : 0
                    if !built.complete || 3 + entries.count + next > remaining {
                        cut = true
                    } else {
                        remaining -= 3 + entries.count
                    }
                }
                groups.append(UnreadGroup(chat: try s.chatRecord(conv, unreadCount: rows.count),
                                          entries: entries, unreadCount: rows.count))
            }
            return UnreadPage(groups: groups, totalUnread: groups.reduce(0) { $0 + $1.unreadCount })
        }
    }

    /// `read`: the window of visible messages, oldest first.
    public func messages(_ args: MessagesArgs) throws -> MessagesPage {
        let n = max(1, min(args.limit, Limits.outputMaxLines))
        return try db.interactive { s in
            let conv = try s.resolve(args.who)
            var window: [MessageRow]
            if let before = args.before {
                window = try s.visibleRows(in: conv, before: before, count: n).reversed()
            } else if let after = args.after {
                window = try s.visibleRows(in: conv, after: after, count: n)
            } else if let around = args.around {
                let atOrAfter = try s.visibleRows(in: conv, after: around == Int64.min ? around : around - 1, count: n)
                if let anchor = atOrAfter.first {
                    let older: [MessageRow] = try s.visibleRows(in: conv, before: anchor.rowid, count: n / 2).reversed()
                    window = older + atOrAfter.prefix(n - older.count)
                } else {
                    window = try s.visibleRows(in: conv, before: Int64.max, count: n / 2 + 1).reversed()
                }
            } else {
                window = try s.visibleRows(in: conv, before: Int64.max, count: n).reversed()
            }
            if let since = args.sinceNs { window = window.filter { $0.date >= since } }
            let records = try window.map(s.record)
            let older = try window.first.map { try !s.visibleRows(in: conv, before: $0.rowid, count: 1).isEmpty }
            // Only --after and --around can stop short of the newest message.
            let newer = args.after == nil && args.around == nil ? nil
                : try window.last.map { try !s.visibleRows(in: conv, after: $0.rowid, count: 1).isEmpty }
            let unread = try s.unreadCounts()[conv.canonical] ?? 0
            return MessagesPage(chat: try s.chatRecord(conv, unreadCount: unread), messages: records,
                                totalVisible: try s.totalVisible(conv), olderExists: older ?? false,
                                newerExists: newer ?? false)
        }
    }

    /// `show`: one message with its whole body in `message.text`, as `MessageDetail` asks. Format prints at most
    /// `Limits.showCapBytes` from `fromByte` on and writes the `--from` footer. `fromByte` is `args.fromByte`
    /// clamped to the body, and `totalBytes` is `message.text.utf8.count`.
    public func message(_ args: MessageArgs) throws -> MessageDetail {
        try db.interactive { s in
            guard let row = try s.row(id: args.rowid) else { throw StoreError.notFound("message \(args.rowid)") }
            let record = try s.record(row)
            let total = record.text.utf8.count
            let ref = try s.conversation(forChat: row.chatID)?.ref
                ?? ChatRef(rowid: row.chatID, label: "", isGroup: false)
            return MessageDetail(message: record, chat: ref, fromByte: max(0, min(args.fromByte, total)),
                                 totalBytes: total)
        }
    }

    /// `search` (section 1, Search): `text LIKE ?` or `ci_contains(attributedBody, ?)` prefilter, decode only
    /// candidates, confirm on the decoded body, newest first inside the date window, cursor continuation,
    /// separate search budget. No persistent index.
    ///
    /// The scan walks date slices newest first and spends at most 80% of the budget; the rest builds the records.
    /// The first slice of a call is 1 hour and each completed slice doubles the next, up to 7 days
    /// (`searchSliceSpan`), so a call that runs out of budget has usually finished a slice and moved the cursor.
    /// The cursor is `<date ns>:<rowid>:<window start ns>`, the text form of IMCore's `SearchCursor`. Everything
    /// newer than (date, rowid) has been checked, and a continued search keeps the cursor's window start.
    public func search(_ args: SearchArgs) throws -> SearchPage {
        guard !TextNorm.matchKey(args.text).isEmpty else { throw StoreError.decode("search text is empty") }
        guard args.text.unicodeScalars.count <= Limits.searchQueryMaxChars else {
            throw WireError.message("search text is over \(Limits.searchQueryMaxChars) characters",
                                    fix: "search a shorter phrase")
        }
        let limit = max(1, min(args.limit, Limits.outputMaxLines))
        var position: (Int64, Int64) = (Int64.max, Int64.max)
        var resumedWindow: Int64?
        if let cursor = args.cursor {
            guard let c = SearchCursor(text: cursor) else { throw StoreError.decode("bad search cursor") }
            position = (c.dateNs, c.rowid)
            resumedWindow = c.windowStartNs
        }
        let configuration = db.configuration
        return try db.searching { s in
            let started = DispatchTime.now().uptimeNanoseconds
            let nowNs = AppleTime.nanos(from: db.clock.now)
            let span = Int64(max(1, configuration.searchWindowDays)).multipliedReportingOverflow(by: nanosPerDay)
            let windowNs = span.overflow ? Int64.max : span.partialValue
            let windowStart = resumedWindow ?? args.sinceNs ?? Nanos.subtract(nowNs, windowNs)
            let conv = try args.inWho.map { try s.resolve($0) }
            let scopes: [Int64?] = conv.map { $0.chatRowIDs.map { Optional($0) } } ?? [nil]
            let query = SearchQuery(args.text)
            let scanNanos = UInt64(max(0, configuration.searchBudget) * 0.8 * 1e9)
            let startPosition = position

            var hits: [MessageRow] = []
            var windowDone = false
            var exhausted = false
            var completedSlices = 0
            do {
                try s.conn.withBudget(seconds: configuration.searchBudget * 0.8, rowCap: Int.max) {
                    while hits.count < limit {
                        if position.0 < windowStart || (position.0 == windowStart && position.1 == Int64.min) {
                            windowDone = true
                            break
                        }
                        let top = min(position.0, nowNs)
                        let lo = max(windowStart,
                                     Nanos.subtract(top, ReadService.searchSliceSpan(completed: completedSlices)))
                        var full = false
                        try s.merged(chats: scopes, descending: true, start: position, key: { ($0.joinDate, $0.rowid) },
                                     fetch: { chat, cursor, n in
                                         let p = cursor ?? position
                                         var params: [SQLiteValue] = [.int(lo), .int(p.0), .int(p.0), .int(p.1)]
                                         params += query.parameters
                                         if let chat {
                                             return try s.rows(SQLText.shared.searchInChat, [.int(chat)] + params,
                                                               limit: n)
                                         }
                                         return try s.rows(SQLText.shared.searchGlobal, params, limit: n)
                                     }, visit: { row in
                                         if DispatchTime.now().uptimeNanoseconds &- started > scanNanos {
                                             throw StoreError.timeout
                                         }
                                         // The visibility check can load the conversation index and run out of
                                         // budget, so the cursor passes a row only once the row is checked.
                                         if !row.isEvent, query.confirms(row.displayText), try s.isVisible(row) {
                                             hits.append(row)
                                         }
                                         position = (row.joinDate, row.rowid)
                                         full = hits.count >= limit
                                         return !full
                                     })
                        if full { break }
                        position = (lo, Int64.min)
                        completedSlices += 1
                    }
                }
            } catch StoreError.timeout {
                exhausted = true
            }

            var built: [SearchHit] = []
            do {
                for row in hits {
                    let ref = try s.conversation(forChat: row.chatID)?.ref
                        ?? ChatRef(rowid: row.chatID, label: "", isGroup: false)
                    built.append(SearchHit(chat: ref, message: try s.record(row), cursorNs: row.joinDate))
                }
            } catch StoreError.timeout {
                exhausted = true
                windowDone = false
                position = built.last.map { hit in
                    hits.first { $0.rowid == hit.message.rowid }.map { ($0.joinDate, $0.rowid) } ?? startPosition
                } ?? startPosition
            }
            let scanned = windowDone ? windowStart : max(windowStart, min(position.0, nowNs))
            let next = windowDone ? nil
                : SearchCursor(dateNs: position.0, rowid: position.1, windowStartNs: windowStart).text
            return SearchPage(query: args.text, inChat: conv?.ref, hits: built, scannedBackToNs: scanned,
                              windowStartNs: windowStart, nextCursor: next, budgetExhausted: exhausted)
        }
    }

    /// `who`: matching cards with their handles, services and chats. Outside a +1 region, a number saved without a
    /// `+` that chat.db's handle table doesn't list is shown as saved, never as the +1 number `HandleNormalizer`
    /// makes of it, so `who` never offers a number that resolving the card refuses.
    public func contacts(_ args: ContactsArgs) throws -> ContactsPage {
        let cards = db.contacts.cards(named: args.name)
        guard !cards.isEmpty else { throw StoreError.noMatch(args.name) }
        return try db.interactive { s in
            var services: [String: Set<String>] = [:]
            try s.each(SQLText.shared.handleServices, [], limit: s.cap) { r in
                guard let id = r.text(0), let service = r.text(1), !service.isEmpty else { return }
                services[HandleNormalizer.normalize(id), default: []].insert(service)
            }
            let conversations = try s.index().conversations.sorted { $0.primary.rowid < $1.primary.rowid }
            let northAmerican = s.northAmericanPlan
            let records = cards.map { card -> ContactRecord in
                let keys = Set(card.handles.map(HandleNormalizer.normalize))
                let handles = card.handles.map { h -> HandleRecord in
                    let key = HandleNormalizer.normalize(h)
                    let saved = h.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !northAmerican, services[key] == nil, Session.looksLikePhone(saved), !saved.hasPrefix("+") {
                        return HandleRecord(id: saved, services: [])
                    }
                    return HandleRecord(id: key, services: (services[key] ?? []).sorted())
                }
                let chats = conversations.filter { !keys.isDisjoint(with: $0.handles) }.map(\.ref)
                return ContactRecord(shortName: ContactBook.baseName(card) ?? (card.handles.first ?? ""),
                                     firstName: card.firstName, lastName: card.lastName, handles: handles, chats: chats)
            }
            return ContactsPage(query: args.name, contacts: records)
        }
    }

    /// `changes`: new rows above the cursor ROWID, plus rows whose date_edited, date_read or date_delivered is
    /// after the cursor time. No `since` returns the current cursor and no rows. No state is kept.
    ///
    /// Each call fixes `T`, the clock, and `R`, the highest ROWID. Changes come first, ordered by time and then
    /// ROWID: rows at or below the cursor ROWID whose retracted, edited, read or delivered time is in
    /// (cursor time, T], of any age, and bridge sends anywhere up to `R` with such a time. A cursor with a tie
    /// ROWID also takes the rows above that ROWID at exactly the cursor time. Then new rows in (cursor ROWID, R].
    /// Tapbacks and hidden rows are left out. Rows the bridge sent never appear as new, and their self-chat echoes
    /// never appear at all, but a later delivery, read, edit or unsend of a bridge send is reported (DESIGN 3.5:
    /// "`changes` reports later deliveries"), whether the send is below or above the cursor ROWID.
    ///
    /// Past 200 records the page is truncated, and the cursor never skips a change it didn't return. Changes past
    /// the page keep the cursor ROWID and move the time to the last one returned (ties stay on the page). New rows
    /// past the page come after every change, so the cursor moves the time to `T` and the ROWID to the last new
    /// row returned. A changes query that fills the row cap may stop inside its last time, so that time comes back
    /// on the next call. When every row it fetched has one time, the cursor takes a tie ROWID instead, and the next
    /// call resumes inside that time from the last ROWID fetched (`ChangeCursor.tieRowID`).
    ///
    /// Messages writes a message row before its chat_message_join row. A row above the cursor that is newer than
    /// `changesJoinLagNs` and has no join row yet pins the cursor just below it: new rows above the pin wait for
    /// a later call, which reports them once they are joined. An older unjoined row (Recently Deleted) never pins.
    public func changes(_ args: ChangesArgs) throws -> ChangesPage {
        try db.interactive { s in
            let now = AppleTime.nanos(from: db.clock.now)
            let maxRow = try s.maxRowID()
            guard let sinceText = args.since else {
                return ChangesPage(cursor: ChangeCursor(rowid: maxRow, timeNs: now).text, changes: [], truncated: false)
            }
            guard let since = ChangeCursor(text: sinceText) else { throw StoreError.decode("bad changes cursor") }
            let cap = Limits.outputMaxLines
            let t = since.timeNs
            let window: [SQLiteValue] = [.int(t), .int(t), .int(since.tieRowID ?? .max), .int(now)]
            let params = window + window + window + window + window + window + window
                + [.int(maxRow), .int(Int64(s.cap))]
            var fetched: [MessageRow] = []
            try s.each(SQLText.shared.changedRows, params, limit: s.cap) { r in
                let row = MessageRow(r)
                row.eventTime = r.int(44)
                fetched.append(row)
            }
            // A fetch that filled the row cap may have stopped inside its last time. Rows at that time wait for the
            // next call. When every fetched row has that one time, rows from the last fetched ROWID on wait instead,
            // so the next call resumes inside the time. `resume` is where the next call starts; rows after it wait.
            var resume: ChangeCursor?
            if fetched.count >= s.cap, let first = fetched.first, let last = fetched.last {
                resume = first.eventTime != last.eventTime
                    ? ChangeCursor(rowid: since.rowid, timeNs: last.eventTime - 1)
                    : ChangeCursor(rowid: since.rowid, timeNs: last.eventTime,
                                   tieRowID: first.rowid != last.rowid ? last.rowid - 1 : last.rowid)
            }
            var changed: [(ChangeKind, MessageRow)] = []
            for row in fetched {
                if let resume, resume.isBefore(time: row.eventTime, rowid: row.rowid) { break }
                // Other rows above the cursor ROWID are new rows, reported below.
                guard row.rowid <= since.rowid || s.agentSent.contains(row.guid) else { continue }
                guard try s.isVisible(row), try !s.isAgentEcho(row) else { continue }
                let inWindow: (Int64) -> Bool = { since.isBefore(time: $0, rowid: row.rowid) && $0 <= now }
                changed.append((ReadService.changeKind(row, inWindow: inWindow) ?? .delivered, row))
            }

            var pin: Int64 = 0
            try s.each(SQLText.shared.firstUnjoinedAbove,
                       [.int(since.rowid), .int(maxRow), .int(Nanos.subtract(now, ReadService.changesJoinLagNs))],
                       limit: 1) { pin = $0.int(0) }
            let top = pin > 0 ? pin - 1 : maxRow
            var cursor = ChangeCursor(rowid: top, timeNs: now)
            var truncated = false
            var picked: [(ChangeKind, MessageRow)]
            if changed.count > cap {
                let lastTime = changed[cap - 1].1.eventTime
                var end = cap
                while end < changed.count, changed[end].1.eventTime == lastTime { end += 1 }
                picked = Array(changed.prefix(end))
                truncated = true
                cursor = ChangeCursor(rowid: since.rowid, timeNs: lastTime)
                // A fetch that stopped inside lastTime left rows at it for the next call.
                if let resume, resume.timeNs == lastTime { cursor = resume }
            } else if let resume {
                picked = changed
                truncated = true
                cursor = resume
            } else {
                picked = changed
                let room = cap - changed.count
                var fresh: [(ChangeKind, MessageRow)] = []
                var low = since.rowid
                var previous: Int64?
                // New rows up to `top`. Bridge sends are never new; their changes are in `changed`.
                scan: while low < top {
                    let batch = try s.rows(SQLText.shared.rowsInRange, [.int(low), .int(top)], limit: Session.batch)
                    for row in batch {
                        if previous == row.rowid { continue }
                        previous = row.rowid
                        guard !s.agentSent.contains(row.guid), try s.isVisible(row), try !s.isAgentEcho(row) else {
                            continue
                        }
                        fresh.append((.new, row))
                        if fresh.count > room { break scan }
                    }
                    guard batch.count == Session.batch, let last = batch.last else { break }
                    low = last.rowid
                }
                if fresh.count > room {
                    fresh = Array(fresh.prefix(room))
                    truncated = true
                    cursor = ChangeCursor(rowid: fresh.last?.1.rowid ?? since.rowid, timeNs: now)
                }
                picked += fresh
            }
            let records = try picked.map { kind, row -> ChangeRecord in
                let ref = try s.conversation(forChat: row.chatID)?.ref
                    ?? ChatRef(rowid: row.chatID, label: "", isGroup: false)
                return ChangeRecord(kind: kind, chat: ref, message: try s.record(row),
                                    eventNs: kind == .new ? 0 : row.eventTime)
            }
            return ChangesPage(cursor: cursor.text, changes: records, truncated: truncated)
        }
    }

    /// Length of a search slice after `completed` finished slices in the same call: 1 hour, doubling each time,
    /// at most 7 days.
    static func searchSliceSpan(completed: Int) -> Int64 {
        let hour: Int64 = 3_600_000_000_000
        let most = 7 * nanosPerDay
        guard completed > 0 else { return hour }
        guard completed < 62 else { return most }
        let span = hour.multipliedReportingOverflow(by: Int64(1) << Int64(completed))
        return span.overflow ? most : min(span.partialValue, most)
    }

    /// How long `changes` waits for a new row's chat_message_join row before it stops holding the cursor.
    static let changesJoinLagNs: Int64 = 10_000_000_000

    /// The change a row's event times show inside the window, first match of unsent, edited, read, delivered.
    static func changeKind(_ row: MessageRow, inWindow: (Int64) -> Bool) -> ChangeKind? {
        if (inWindow(row.dateRetracted) || inWindow(row.dateEdited)) && row.unsent { return .unsent }
        if inWindow(row.dateEdited) { return .edited }
        if inWindow(row.dateRead) { return .read }
        if inWindow(row.dateDelivered) { return .delivered }
        return nil
    }

    /// One poll step for `wait`: the first inbound visible row above `afterRowID`, optionally from one chat.
    /// Rows in `db.agentSentGUIDs`, and echoes of them, never count. IMBridge loops this until the timeout.
    public func nextInbound(afterRowID: Int64, in chat: ResolvedChat?) throws -> (ChatRef, MessageRecord)? {
        try db.interactive { s in
            let accept: (MessageRow) throws -> Bool = { row in
                try !row.fromMe && !row.isEvent && !s.isAgentRow(row)
            }
            var found: MessageRow?
            if let chat {
                guard let conv = try s.conversation(for: chat) else { return nil }
                found = try s.visibleRows(in: conv, after: afterRowID, count: 1, keep: accept).first
            } else {
                try s.merged(chats: [nil], descending: false, start: (afterRowID, 0), key: { ($0.rowid, 0) },
                             fetch: { _, cursor, n in
                                 let from = cursor?.0 ?? afterRowID
                                 return try s.rows(SQLText.shared.rowsInRange, [.int(from), .int(Int64.max)], limit: n)
                             }, visit: { row in
                                 if try s.isVisible(row), try accept(row) {
                                     found = row
                                     return false
                                 }
                                 return true
                             })
            }
            guard let row = found else { return nil }
            let ref = try s.conversation(forChat: row.chatID)?.ref
                ?? ChatRef(rowid: row.chatID, label: "", isGroup: false)
            return (ref, try s.record(row))
        }
    }

    /// Highest message ROWID, the starting point for `wait` and `changes`.
    public func maxMessageRowID() throws -> Int64 { try db.interactive { try $0.maxRowID() } }
}

// MARK: - Session helpers for the read ops

extension Session {
    func maxRowID() throws -> Int64 {
        var value: Int64 = 0
        try each(SQLText.shared.maxMessageRowID, [], limit: 1) { value = $0.int(0) }
        return value
    }

    /// Visible unread incoming rows, oldest first. Past the row cap the newest ones are kept.
    func unreadRows() throws -> [MessageRow] {
        var seen: Set<Int64> = []
        return try rows(SQLText.shared.unreadRows, [], limit: cap).reversed().filter { row in
            try isVisible(row) && seen.insert(row.rowid).inserted
        }
    }

    func unreadCounts() throws -> [CanonicalChatID: Int] {
        var counts: [CanonicalChatID: Int] = [:]
        for row in try unreadRows() {
            if let key = conversationKey(row) { counts[key, default: 0] += 1 }
        }
        return counts
    }

    /// The entries of one unread group: the unread rows, oldest first, each run with up to `context` earlier
    /// visible rows. It stops once `limit` entries are settled and returns the oldest `limit` with `complete`
    /// false. After an unread row is handled, no later row adds an entry below it, so that prefix is final.
    func unreadEntries(_ conv: Conversation, rows: [MessageRow], context: Int,
                       limit: Int) throws -> (entries: [UnreadEntry], complete: Bool) {
        let unreadIDs = Set(rows.map(\.rowid))
        var shown: [Int64: MessageRow] = [:]
        var predecessor: [Int64: Int64] = [:]
        var complete = true
        for u in rows {
            if shown.count >= limit {
                complete = false
                break
            }
            shown[u.rowid] = u
            let before = try visibleRows(in: conv, before: u.rowid, count: context + 1)
            if let p = before.first { predecessor[u.rowid] = p.rowid }
            if let p = before.first, unreadIDs.contains(p.rowid) { continue }
            for (k, c) in before.prefix(context).enumerated() {
                shown[c.rowid] = c
                if k + 1 < before.count { predecessor[c.rowid] = before[k + 1].rowid }
            }
        }
        let order = Array(shown.keys.sorted().prefix(max(0, limit)))
        if order.count < shown.count { complete = false }
        var entries: [UnreadEntry] = []
        for (i, id) in order.enumerated() {
            guard let row = shown[id] else { continue }
            let gap = i > 0 && predecessor[id] != order[i - 1]
            entries.append(UnreadEntry(message: try record(row), isUnread: unreadIDs.contains(id), gapBefore: gap))
        }
        return (entries, complete)
    }

    func chatRecord(_ conv: Conversation, unreadCount: Int) throws -> ChatRecord {
        let primary = conv.primary
        let last = try visibleRows(in: conv, before: Int64.max, count: 1).first.map(record)
        return ChatRecord(rowid: primary.rowid, guid: primary.guid, identifier: primary.identifier,
                          canonical: conv.canonical, displayName: primary.displayName, label: conv.label,
                          isGroup: conv.isGroup, memberNames: conv.memberNames, service: primary.service,
                          unreadCount: unreadCount, last: last, mergedChatRowIDs: conv.chatRowIDs)
    }

    /// Visible rows of a conversation: rows that are not tapbacks or stickers, less echoes and duplicate links.
    func totalVisible(_ conv: Conversation) throws -> Int {
        let q = SQLText.shared
        var total = 0
        for chat in conv.chats {
            var count = 0
            try each(q.nonReactionCount, [.int(chat.rowid)], limit: 1) { count = Int(clamping: $0.int(0)) }
            var hidden: Set<Int64> = []
            if try index().selfChats.contains(chat.rowid) {
                try each(q.echoCandidates, [.int(chat.rowid)], limit: cap) { r in
                    let text = MessageRow.decode(text: r.text(1), body: r.blob(2)).text
                    let prev = MessageRow.decode(text: r.text(3), body: r.blob(4)).text
                    if text == prev { hidden.insert(r.int(0)) }
                }
            }
            try each(q.linkCandidates, [.int(chat.rowid), .text(urlBalloonBundleID), .int(linkMergeWindowNs)],
                     limit: cap) { r in
                guard let url = MessageRow.link(balloon: urlBalloonBundleID, payload: r.blob(1))?.url, !url.isEmpty,
                      let prev = MessageRow.decode(text: r.text(2), body: r.blob(3)).text, !prev.isEmpty,
                      prev.contains(url) else { return }
                hidden.insert(r.int(0))
            }
            total += max(0, count - hidden.count)
        }
        return total
    }
}

enum Nanos {
    /// `a - b`, clamped instead of overflowing.
    static func subtract(_ a: Int64, _ b: Int64) -> Int64 {
        let (v, overflow) = a.subtractingReportingOverflow(b)
        return overflow ? (b > 0 ? Int64.min : Int64.max) : v
    }
}

/// One search needle: the SQL prefilter parameters and the confirm step on decoded text.
struct SearchQuery {
    let needle: String
    let forms: NeedleForms
    let parameters: [SQLiteValue]

    init(_ needle: String) {
        self.needle = needle
        forms = NeedleForms(needle)
        let nfc = needle.precomposedStringWithCanonicalMapping
        let nfd = needle.decomposedStringWithCanonicalMapping
        parameters = [.text("%" + SearchQuery.escapeLike(nfc) + "%"), .text("\\"),
                      .text("%" + SearchQuery.escapeLike(nfd) + "%"), .text("\\"), .text(needle)]
    }

    /// `\`, `%` and `_` escaped with a backslash for `LIKE ? ESCAPE ?`.
    static func escapeLike(_ s: String) -> String {
        var out = ""
        for ch in s {
            if ch == "\\" || ch == "%" || ch == "_" { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    /// The match on the decoded body: NFC, ASCII case folded.
    func confirms(_ text: String) -> Bool {
        let hay = Array(text.precomposedStringWithCanonicalMapping.utf8)
        return hay.withUnsafeBytes { forms.matches($0) }
    }
}

/// Folds tapback and sticker rows into their targets (bench/reader.py `_fold_tapbacks`). Owner: IMStore.
/// Replays adds and removes in ROWID order; each actor keeps at most one reaction per message part.
/// Targets are `p:<part>/<guid>` or `bp:<guid>`. Must reproduce manifest.json `tapback_net_state`.
public enum TapbackFolder {
    public struct Row: Hashable, Sendable {
        public var rowid: Int64
        public var associatedGUID: String
        public var associatedType: Int
        public var emoji: String?
        public var fromMe: Bool
        public var actorHandle: String?

        public init(rowid: Int64, associatedGUID: String, associatedType: Int, emoji: String?, fromMe: Bool,
                    actorHandle: String?) {
            self.rowid = rowid
            self.associatedGUID = associatedGUID
            self.associatedType = associatedType
            self.emoji = emoji
            self.fromMe = fromMe
            self.actorHandle = actorHandle
        }
    }

    /// Parses `p:1/<guid>` to (1, guid) and `bp:<guid>` to (0, guid).
    public static func parseTarget(_ associatedGUID: String) -> (part: Int, guid: String) {
        let g = associatedGUID
        if g.hasPrefix("p:"), let slash = g.firstIndex(of: "/") {
            let digits = g[g.index(g.startIndex, offsetBy: 2)..<slash]
            if !digits.isEmpty, digits.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }), let part = Int(digits) {
                return (part, String(g[g.index(after: slash)...]))
            }
        }
        if g.hasPrefix("bp:") { return (0, String(g.dropFirst(3))) }
        return (0, g)
    }

    /// Net reactions per target GUID, in first-reaction order. `name` turns an actor handle into a short name.
    /// Rows outside 2000 to 3999, and adds or removes with an unknown kind, are skipped. A remove takes away the
    /// actor's reaction of that kind (and, for emoji tapbacks, that emoji) on that part.
    public static func fold(_ rows: [Row], name: (String?) -> String) -> [String: [ReactionRecord]] {
        struct Entry {
            var actor: String
            var record: ReactionRecord
        }
        var state: [String: [Int: [Entry]]] = [:]
        for row in rows.sorted(by: { $0.rowid < $1.rowid }) where (2000...3999).contains(row.associatedType) {
            let (part, guid) = parseTarget(row.associatedGUID)
            let actor = row.fromMe ? "me" : HandleNormalizer.normalize(row.actorHandle ?? "")
            var list = state[guid]?[part] ?? []
            if row.associatedType < 3000 {
                guard let kind = TapbackKind(associatedType: row.associatedType, emoji: row.emoji) else { continue }
                if let i = list.firstIndex(where: { $0.actor == actor }) { list.remove(at: i) }
                let record = ReactionRecord(kind: kind, actorName: row.fromMe ? "You" : name(row.actorHandle),
                                            fromMe: row.fromMe, part: part, rowid: row.rowid)
                list.append(Entry(actor: actor, record: record))
            } else {
                let offset = row.associatedType % 1000
                guard (0...6).contains(offset) else { continue }
                if let i = list.firstIndex(where: { e in
                    e.actor == actor && e.record.kind.typeOffset == offset
                        && (offset != 6 || e.record.kind == .emoji(row.emoji ?? ""))
                }) {
                    list.remove(at: i)
                }
            }
            state[guid, default: [:]][part] = list
        }
        return state.mapValues { parts in
            parts.keys.sorted().flatMap { parts[$0]!.map(\.record) }
        }
    }
}

/// `ci_contains(blob, needle)`: ASCII case-folding byte search for the needle in NFC and in NFD (section 1).
/// A case difference outside ASCII can miss; the skill reference says so. Owner: IMStore.
public enum CaseInsensitiveContains {
    public static func matches(haystack: Data, needle: String) -> Bool {
        let forms = NeedleForms(needle)
        return haystack.withUnsafeBytes { forms.matches($0) }
    }
}
