import Foundation

/// Every SQL statement IMStore runs. Each one is fixed text: values are bound as parameters, never spliced in, and
/// each statement ends in `LIMIT ?`, which the caller binds to at most the row cap. The texts contain no quote
/// characters, so not even a constant string literal is written into SQL; string constants are bound too.
/// The properties are stored so tests can list every statement with `Mirror`.
struct SQLText {
    static let shared = SQLText()

    /// Columns of a message row, in `MessageRow` order. `p` is the previous and `n` the next row of the same chat.
    static let rowColumns = """
        SELECT m.ROWID, m.guid, m.text, m.attributedBody, m.handle_id, h.id, oh.id, m.service, m.date, m.is_from_me, \
        m.item_type, m.group_action_type, m.group_title, m.associated_message_type, m.associated_message_guid, \
        m.associated_message_emoji, m.thread_originator_guid, m.message_summary_info, m.date_edited, m.date_retracted, \
        m.is_read, m.date_read, m.is_delivered, m.date_delivered, m.is_sent, m.error, m.balloon_bundle_id, \
        m.payload_data, m.is_audio_message, m.part_count, j.chat_id, \
        p.ROWID, p.is_from_me, p.handle_id, p.date, p.text, p.attributedBody, \
        n.ROWID, n.is_from_me, n.handle_id, n.date, n.balloon_bundle_id, n.payload_data, j.message_date
        """

    static let neighborJoins = """
         LEFT JOIN handle h ON h.ROWID = m.handle_id \
        LEFT JOIN handle oh ON oh.ROWID = m.other_handle \
        LEFT JOIN message p ON p.ROWID = (SELECT max(jp.message_id) FROM chat_message_join jp \
        WHERE jp.chat_id = j.chat_id AND jp.message_id < j.message_id) \
        LEFT JOIN message n ON n.ROWID = (SELECT min(jn.message_id) FROM chat_message_join jn \
        WHERE jn.chat_id = j.chat_id AND jn.message_id > j.message_id)
        """

    /// Joined rows only: a Recently Deleted row has no chat_message_join row and never appears.
    static let rowsFromJoin = rowColumns + " FROM chat_message_join j JOIN message m ON m.ROWID = j.message_id"
        + neighborJoins + " "
    static let rowsFromDateIndex = rowColumns
        + " FROM chat_message_join j CROSS JOIN message m ON m.ROWID = j.message_id" + neighborJoins + " "

    /// Placed stickers (1000), tapbacks (2000 to 3999) and poll votes (4000) never print as rows.
    static let notReaction = "NOT (ifnull(m.associated_message_type, 0) = 1000 "
        + "OR ifnull(m.associated_message_type, 0) BETWEEN 2000 AND 3999 "
        + "OR ifnull(m.associated_message_type, 0) = 4000)"

    // MARK: Message rows

    /// chat id, below rowid, limit. Newest first.
    let rowsBefore = Self.rowsFromJoin + "WHERE j.chat_id = ? AND j.message_id < ? ORDER BY j.message_id DESC LIMIT ?"
    /// chat id, above rowid, limit. Oldest first.
    let rowsAfter = Self.rowsFromJoin + "WHERE j.chat_id = ? AND j.message_id > ? ORDER BY j.message_id ASC LIMIT ?"
    /// rowid, limit.
    let rowByID = Self.rowsFromJoin + "WHERE j.message_id = ? ORDER BY j.chat_id LIMIT ?"
    /// low rowid (exclusive), high rowid (inclusive), limit. Every chat, oldest first.
    let rowsInRange = Self.rowsFromJoin
        + "WHERE j.message_id > ? AND j.message_id <= ? ORDER BY j.message_id ASC, j.chat_id ASC LIMIT ?"
    /// limit. Unread incoming rows that are not events, tapbacks or poll votes, newest first so the row cap drops
    /// the oldest.
    let unreadRows = Self.rowsFromJoin + "WHERE m.is_read = 0 AND m.is_from_me = 0 AND ifnull(m.item_type, 0) = 0 "
        + "AND NOT (ifnull(m.associated_message_type, 0) BETWEEN 2000 AND 3999 "
        + "OR ifnull(m.associated_message_type, 0) = 4000) ORDER BY j.message_id DESC LIMIT ?"
    /// chat id, after date, same date, above rowid, limit. Incoming rows past (date, rowid), oldest first.
    let inboundAfterDate = Self.rowsFromJoin + "WHERE j.chat_id = ? AND m.is_from_me = 0 "
        + "AND (j.message_date > ? OR (j.message_date = ? AND j.message_id > ?)) "
        + "ORDER BY j.message_date ASC, j.message_id ASC LIMIT ?"
    /// chat id, from_me, rowid to leave out, needle, needle, limit. Rows whose body may equal the target's.
    let sameBodyCandidates = Self.rowsFromJoin + "WHERE j.chat_id = ? AND m.is_from_me = ? AND j.message_id != ? "
        + "AND (ci_contains(m.text, ?) OR ci_contains(m.attributedBody, ?)) AND " + Self.notReaction
        + " ORDER BY j.message_id ASC LIMIT ?"

    /// Event time of a changed row: the first of retracted, edited, read, delivered inside the window, which runs
    /// from the cursor's (time t, tie ROWID x) to T in (time, ROWID) order (`changedIn`). Parameters (t, t, x, T)
    /// three times, then the WHERE parameters: (t, t, x, T) four times, highest rowid, inner limit, limit. No
    /// message-age bound. No index covers the four times, so SQLite walks message by ROWID up to the highest rowid.
    /// The inner select keeps only (chat, ROWID, time) and its top-N sort holds at most the inner limit, so an old
    /// cursor that matches most of chat.db costs about what a new one does. Only the rows it keeps get their
    /// columns and neighbor rows (see `ReadService.changes`).
    let changedRows = Self.rowColumns
        + ", k.ev FROM (SELECT j.chat_id AS kc, m.ROWID AS km, CASE WHEN " + Self.changedIn("m.date_retracted")
        + " THEN m.date_retracted WHEN " + Self.changedIn("m.date_edited") + " THEN m.date_edited "
        + "WHEN " + Self.changedIn("m.date_read") + " THEN m.date_read ELSE m.date_delivered END AS ev "
        + "FROM message m JOIN chat_message_join j ON j.message_id = m.ROWID "
        + "WHERE (" + Self.changedIn("m.date_retracted") + " OR " + Self.changedIn("m.date_edited") + " OR "
        + Self.changedIn("m.date_read") + " OR " + Self.changedIn("m.date_delivered") + ") AND m.ROWID <= ? "
        + "ORDER BY ev ASC, m.ROWID ASC LIMIT ?) k "
        + "JOIN chat_message_join j ON j.chat_id = k.kc AND j.message_id = k.km JOIN message m ON m.ROWID = k.km"
        + Self.neighborJoins + " ORDER BY k.ev ASC, k.km ASC LIMIT ?"

    /// A change time inside the `changes` window: after (cursor time, tie ROWID) and at or before now. Parameters
    /// cursor time, cursor time, tie ROWID (the largest Int64 when the cursor has none), now. It reads message
    /// columns only, so SQLite tests it before it looks up the join row.
    static func changedIn(_ column: String) -> String {
        "((\(column) > ? OR (\(column) = ? AND m.ROWID > ?)) AND \(column) <= ?)"
    }

    // MARK: Search

    static let searchPrefilter = "(m.text LIKE ? ESCAPE ? OR m.text LIKE ? ESCAPE ? "
        + "OR ci_contains(m.attributedBody, ?))"
    static let searchBounds = "j.message_date >= ? "
        + "AND (j.message_date < ? OR (j.message_date = ? AND j.message_id < ?))"
    static let searchOrder = " ORDER BY j.message_date DESC, j.message_id DESC LIMIT ?"

    /// window low date, position date, position date, position rowid, NFC pattern, escape, NFD pattern, escape,
    /// needle, limit.
    let searchGlobal = Self.rowsFromDateIndex + "WHERE " + Self.searchBounds + " AND " + Self.searchPrefilter
        + Self.searchOrder
    /// chat id, then the `searchGlobal` parameters.
    let searchInChat = Self.rowsFromJoin + "WHERE j.chat_id = ? AND " + Self.searchBounds + " AND "
        + Self.searchPrefilter + Self.searchOrder

    // MARK: Counts for `read`

    /// chat id, limit. Rows that are not tapbacks or placed stickers.
    let nonReactionCount = "SELECT count(*) FROM chat_message_join j JOIN message m ON m.ROWID = j.message_id "
        + "WHERE j.chat_id = ? AND " + Self.notReaction + " LIMIT ?"
    /// chat id, limit. Incoming rows right after an outgoing row: echo candidates in a self chat.
    let echoCandidates = "SELECT m.ROWID, m.text, m.attributedBody, p.text, p.attributedBody "
        + "FROM chat_message_join j JOIN message m ON m.ROWID = j.message_id "
        + "JOIN message p ON p.ROWID = (SELECT max(jp.message_id) FROM chat_message_join jp "
        + "WHERE jp.chat_id = j.chat_id AND jp.message_id < j.message_id) "
        + "WHERE j.chat_id = ? AND m.is_from_me = 0 AND p.is_from_me = 1 AND " + Self.notReaction + " LIMIT ?"
    /// chat id, balloon bundle id, window ns, limit. URL balloon rows right after a row from the same sender.
    let linkCandidates = "SELECT m.ROWID, m.payload_data, p.text, p.attributedBody "
        + "FROM chat_message_join j JOIN message m ON m.ROWID = j.message_id "
        + "JOIN message p ON p.ROWID = (SELECT max(jp.message_id) FROM chat_message_join jp "
        + "WHERE jp.chat_id = j.chat_id AND jp.message_id < j.message_id) "
        + "WHERE j.chat_id = ? AND m.balloon_bundle_id = ? AND p.handle_id = m.handle_id "
        + "AND p.is_from_me = m.is_from_me AND m.date - p.date <= ? AND " + Self.notReaction + " LIMIT ?"

    // MARK: Pieces of a record

    /// associated guid, limit. Joined tapback and sticker rows aimed at one target string, ROWID order.
    let reactionsFor = "SELECT t.ROWID, t.associated_message_guid, t.associated_message_type, "
        + "t.associated_message_emoji, t.is_from_me, h.id FROM message t LEFT JOIN handle h ON h.ROWID = t.handle_id "
        + "WHERE t.associated_message_guid = ? "
        + "AND EXISTS (SELECT 1 FROM chat_message_join jt WHERE jt.message_id = t.ROWID) ORDER BY t.ROWID ASC LIMIT ?"
    /// message rowid, limit.
    let attachmentsFor = "SELECT a.ROWID, a.guid, a.filename, a.uti, a.mime_type, a.transfer_name, a.total_bytes, "
        + "a.is_sticker, a.transfer_state, a.user_info, maj.message_id FROM message_attachment_join maj "
        + "JOIN attachment a ON a.ROWID = maj.attachment_id WHERE maj.message_id = ? ORDER BY a.ROWID ASC LIMIT ?"
    /// attachment rowid, limit. The attachment and the first message that carries it.
    let attachmentByID = "SELECT a.ROWID, a.guid, a.filename, a.uti, a.mime_type, a.transfer_name, a.total_bytes, "
        + "a.is_sticker, a.transfer_state, a.user_info, "
        + "(SELECT min(maj.message_id) FROM message_attachment_join maj WHERE maj.attachment_id = a.ROWID) "
        + "FROM attachment a WHERE a.ROWID = ? LIMIT ?"
    /// guid, limit. A joined message by GUID, for reply quotes and tapback targets.
    let parentByGUID = "SELECT m.ROWID, m.is_from_me, h.id, m.text, m.attributedBody, "
        + "(SELECT min(jx.chat_id) FROM chat_message_join jx WHERE jx.message_id = m.ROWID) "
        + "FROM message m LEFT JOIN handle h ON h.ROWID = m.handle_id WHERE m.guid = ? "
        + "AND EXISTS (SELECT 1 FROM chat_message_join jx2 WHERE jx2.message_id = m.ROWID) LIMIT ?"
    /// chat id, below rowid, limit. Earlier outgoing rows of a chat, newest first.
    let fromMeBefore = "SELECT m.guid, m.text, m.attributedBody FROM chat_message_join j "
        + "JOIN message m ON m.ROWID = j.message_id WHERE j.chat_id = ? AND j.message_id < ? AND m.is_from_me = 1 "
        + "ORDER BY j.message_id DESC LIMIT ?"

    // MARK: IMSend and IMUI probes

    static let sentColumns = "SELECT m.ROWID, m.guid, h.id, m.service, m.date, m.text, m.attributedBody, m.error, "
        + "m.is_sent, m.is_delivered, m.date_delivered, "
        + "(SELECT min(jx.chat_id) FROM chat_message_join jx WHERE jx.message_id = m.ROWID), "
        + "m.thread_originator_guid, m.item_type FROM message m LEFT JOIN handle h ON h.ROWID = m.handle_id "
    /// above rowid, limit. Every outgoing row, joined or not.
    let fromMeAbove = Self.sentColumns + "WHERE m.ROWID > ? AND m.is_from_me = 1 ORDER BY m.ROWID ASC LIMIT ?"
    /// rowid, limit.
    let fromMeByID = Self.sentColumns + "WHERE m.ROWID = ? AND m.is_from_me = 1 LIMIT ?"
    /// message rowid, limit.
    let transfersFor = "SELECT a.transfer_name, a.transfer_state FROM message_attachment_join maj "
        + "JOIN attachment a ON a.ROWID = maj.attachment_id WHERE maj.message_id = ? ORDER BY a.ROWID ASC LIMIT ?"
    /// transfer name, limit. Newest attachment first.
    let transferStateByName = "SELECT a.transfer_state FROM attachment a WHERE a.transfer_name = ? "
        + "ORDER BY a.ROWID DESC LIMIT ?"
    /// above rowid, associated guid, limit. Outgoing tapback rows, joined or not.
    let fromMeReactionsAbove = "SELECT m.ROWID, m.associated_message_type, m.associated_message_guid, "
        + "m.associated_message_emoji, m.is_from_me FROM message m WHERE m.ROWID > ? AND m.associated_message_guid = ? "
        + "AND m.is_from_me = 1 AND m.associated_message_type BETWEEN 2000 AND 3999 ORDER BY m.ROWID ASC LIMIT ?"
    /// rowid, limit.
    let editState = "SELECT m.ROWID, m.date_edited, m.date_retracted, m.text, m.attributedBody, "
        + "m.message_summary_info FROM message m WHERE m.ROWID = ? LIMIT ?"

    // MARK: Totals

    /// limit.
    let maxMessageRowID = "SELECT ifnull(max(ROWID), 0) FROM message LIMIT ?"
    /// above rowid, up to rowid, newer than date, limit. The lowest recent row with no chat_message_join row yet:
    /// Messages writes the message row first and the join row after it.
    let firstUnjoinedAbove = "SELECT ifnull(min(m.ROWID), 0) FROM message m WHERE m.ROWID > ? AND m.ROWID <= ? "
        + "AND m.date > ? AND NOT EXISTS (SELECT 1 FROM chat_message_join j WHERE j.message_id = m.ROWID) LIMIT ?"
    /// limit.
    let messageCount = "SELECT count(*) FROM message LIMIT ?"
    /// limit.
    let schemaCheck = "SELECT count(*) FROM sqlite_master LIMIT ?"

    // MARK: Chats

    /// limit. Newest chats first so the row cap drops the oldest. Callers sort with a total order.
    let chatList = "SELECT c.ROWID, c.guid, c.style, c.chat_identifier, c.service_name, c.display_name, "
        + "c.account_login, c.last_addressed_handle FROM chat c ORDER BY c.ROWID DESC LIMIT ?"
    /// limit. Newest chats first, each chat's members in handle order.
    let chatMembers = "SELECT chj.chat_id, h.id FROM chat_handle_join chj JOIN handle h ON h.ROWID = chj.handle_id "
        + "ORDER BY chj.chat_id DESC, chj.handle_id ASC LIMIT ?"
    /// chat id, limit.
    let chatLastDate = "SELECT ifnull(max(j.message_date), 0) FROM chat_message_join j WHERE j.chat_id = ? LIMIT ?"
    /// limit.
    let handleServices = "SELECT h.id, h.service FROM handle h ORDER BY h.ROWID ASC LIMIT ?"
    /// normalized handle, limit. The services chat.db lists for one handle. Emails are stored in any case and the
    /// normalized form is lowercase, so the compare folds case.
    let servicesOfHandle = "SELECT h.service FROM handle h WHERE lower(h.id) = ? ORDER BY h.ROWID ASC LIMIT ?"
    /// chat id, limit. The columns `chatList` starts with, for one chat.
    let chatByRowID = "SELECT c.ROWID, c.guid, c.style, c.chat_identifier FROM chat c WHERE c.ROWID = ? LIMIT ?"

    // MARK: AddressBook

    let addressBookRecords = "SELECT Z_PK, ZFIRSTNAME, ZLASTNAME, ZNICKNAME, ZORGANIZATION FROM ZABCDRECORD "
        + "ORDER BY Z_PK ASC LIMIT ?"
    let addressBookPhones = "SELECT ZOWNER, ZFULLNUMBER FROM ZABCDPHONENUMBER ORDER BY Z_PK ASC LIMIT ?"
    let addressBookEmails = "SELECT ZOWNER, ZADDRESS FROM ZABCDEMAILADDRESS ORDER BY Z_PK ASC LIMIT ?"
    let addressBookMe = "SELECT Z_PK FROM ZABCDRECORD WHERE ZCONTAINERWHERECONTACTISME IS NOT NULL LIMIT ?"

    /// Every statement, for tests.
    var all: [(name: String, sql: String)] {
        Mirror(reflecting: self).children.compactMap { child in
            guard let name = child.label, let sql = child.value as? String else { return nil }
            return (name, sql)
        }
    }
}
