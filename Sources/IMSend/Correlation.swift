import Foundation
import IMCore
import IMStore

/// Taken before the Apple Event (DESIGN.md section 3 item 5).
public struct SendSnapshot: Hashable, Codable, Sendable {
    public var maxRowID: Int64
    public var requestedAt: Date

    public init(maxRowID: Int64, requestedAt: Date) {
        self.maxRowID = maxRowID
        self.requestedAt = requestedAt
    }
}

/// What one part's row must look like.
public enum PartExpectation: Hashable, Sendable {
    /// Decoded body equals `matchKey` (`TextNorm.matchKey` of the sent text).
    case text(matchKey: String)
    /// `TextNorm.textDigest` of the decoded body equals this. Crash reconciliation and the foreground verifier use
    /// it, because the journal stores digests and never text.
    case textDigest(String)
    /// The attachment's transfer_name equals the staged unique name.
    case file(transferName: String)
}

public struct PartCorrelation: Hashable, Sendable {
    public var result: ActionResult
    public var row: SentRowProbe?

    public init(result: ActionResult, row: SentRowProbe?) {
        self.result = result
        self.row = row
    }
}

/// Matches sent rows to parts. Owner: IMSend. Used by `MessageSender`, by IMForeground's reply verification and by
/// IMBridge's crash reconciliation.
///
/// Rules (section 3 items 5 and 6):
/// - Only from_me rows above the snapshot, for the recipient's handle, dated at or after the request. A group's
///   from_me rows have no handle, so for a group the row counts once its join row names one of `chat.chatRowIDs`.
/// - A row whose join row names a chat outside `chat.chatRowIDs` is not this send's row, so it never matches. With
///   no other match the part ends as section 3 item 5 says for no match: `may_have_completed`.
/// - The join row can lag about 1 s; the chat is confirmed from it but 1:1 matching doesn't wait for it. A group
///   row waits for it inside the same 10 s.
/// - 10 s in all. No match: `may_have_completed`, or `ghost` if an empty unjoined from_me SMS row appeared.
/// - Two candidates: `ambiguous: two rows matched`.
/// - Matched row with error set or transfer_state 6: `failed`. With date_delivered set: `delivered`. Either way, wait
///   up to 1 s more for the join row inside the 10 s, then return.
/// - Otherwise `submitted` at 10 s. SMS never sets date_delivered, so it stays `submitted`.
/// - Join row still missing on return: add `chat unconfirmed`.
///
/// Details the rules leave open:
/// - The recipient's handles are `chat.handles` plus `chat.sendHandle`, compared after `HandleNormalizer.normalize`
///   (emails lowercased, phones as `+<digits>` with a leading 1 added to 10 digits written without a `+`, a handle
///   with a letter kept as it is). The rule is applied to both sides, so it gives the same answer whether or not
///   the row source already normalized them, and a letter handle such as `urn:biz:...` never matches the phone
///   number with its digits.
/// - The chat is confirmed when the join row names one of `chat.chatRowIDs`. A row first seen with no join row that
///   later joins another chat drops out, and the part keeps waiting for a match inside the 10 s.
/// - A chat with no chat.db chats yet (`chatRowIDs` empty, a new direct target) gets its chat from this send, so a
///   join row is compared by identity instead: the joined chat's `SendRowSource.canonicalChatID` must equal
///   `chat.canonical` to confirm the chat, and a row joined to a chat with another identity never matches. A joined
///   chat whose identity can't be read neither confirms nor rules out the row, so it matches on the handle and adds
///   `chat unconfirmed`.
/// - A nonzero `error` wins over transfer_state 6, so the result carries the error code.
/// - SMS means the row's service, or the chat's when the row has none. An iMessage send that Messages sent as SMS
///   therefore stays `submitted` too.
/// - A ghost row may carry the recipient's handle or none. It must have no body, no attachment, no join row and the
///   SMS service.
/// - A failed chat.db read counts as a pass that saw nothing new. If no read ever succeeds, every part is
///   `may_have_completed`.
/// - The correlator keeps no state between calls, so the bridge may call it from several threads.
public final class SendCorrelator {
    public let rows: SendRowSource
    public let clock: Clock

    /// Gap between chat.db reads while waiting.
    public static let pollInterval: TimeInterval = 0.25
    /// Rows asked for per read. A read pages until it has every row above the snapshot, up to `Limits.defaultRowCap`.
    static let pageSize = 500

    public init(rows: SendRowSource, clock: Clock) {
        self.rows = rows
        self.clock = clock
    }

    /// Polls until every part has a result or `timeout` passes. Results are in `parts` order.
    public func correlate(snapshot: SendSnapshot, chat: ResolvedChat, parts: [PartExpectation],
                          timeout: TimeInterval = Limits.correlationTimeout) -> [PartCorrelation] {
        let filter = RowFilter(snapshot: snapshot, chat: chat, rows: rows)
        let deadline = clock.uptime + timeout
        var finals = [PartCorrelation?](repeating: nil, count: parts.count)
        // The end of each part's wait for its join row, set when its row first shows delivered or failed. A wait that
        // runs past the deadline ends there, because the loop stops at the deadline.
        var joinBy = [TimeInterval?](repeating: nil, count: parts.count)
        var latest = Pass.empty

        while true {
            let now = clock.uptime
            if let pass = read(filter) { latest = pass }

            for index in parts.indices where finals[index] == nil {
                switch latest.match(parts[index]) {
                case .several:
                    finals[index] = PartCorrelation(result: ActionResult(.ambiguous(.twoRowsMatched)), row: nil)
                case .one(let row):
                    let state = SendCorrelator.rowState(row, part: parts[index], chat: chat)
                    guard state.isFinal else { break }
                    let end = joinBy[index] ?? now + Limits.joinRowGrace
                    joinBy[index] = end
                    if row.joinedChatRowID != nil || now >= end {
                        finals[index] = SendCorrelator.result(row: row, code: state.code, filter: filter)
                    }
                case .none:
                    break
                }
            }

            if finals.allSatisfy({ $0 != nil }) { return finals.map { $0! } }
            if now >= deadline { break }

            var wake = min(now + SendCorrelator.pollInterval, deadline)
            for index in parts.indices where finals[index] == nil {
                if let end = joinBy[index], end > now { wake = min(wake, end) }
            }
            clock.sleep(wake - now)
        }

        return parts.indices.map { finals[$0] ?? latest.settle(parts[$0], filter: filter, ghostAllowed: true) }
    }

    /// One pass with no waiting, for crash reconciliation (section 3 item 2). `ReconcileAdapter` builds `snapshot` from
    /// the entry's `facts.snapshotRowID` and `receivedAt`, and `parts` from `binding.textDigest` (`.textDigest`) and
    /// `facts.transferNames` (`.file`), then repeats this pass until its deadline.
    ///
    /// A matched row gives its current result (`submitted` if neither delivered nor failed yet), with
    /// `chat unconfirmed` while its join row is missing. Anything else is `may_have_completed`, never `ghost`:
    /// section 3 item 2 gives a reconciled request a matched row's result or `may_have_completed`, and after a crash
    /// an empty SMS row above an old snapshot says little about this send.
    public func matchOnce(snapshot: SendSnapshot, chat: ResolvedChat, parts: [PartExpectation]) -> [PartCorrelation] {
        let filter = RowFilter(snapshot: snapshot, chat: chat, rows: rows)
        let pass = read(filter) ?? .empty
        return parts.map { pass.settle($0, filter: filter, ghostAllowed: false) }
    }

    // MARK: - Reading

    /// Every from_me row above the snapshot, sorted into candidates and ghost rows. Nil if chat.db couldn't be read.
    private func read(_ filter: RowFilter) -> Pass? {
        var seen: [Int64: SentRowProbe] = [:]
        var cursor = filter.snapshot.maxRowID
        do {
            while seen.count < Limits.defaultRowCap {
                let page = try rows.fromMeRows(aboveRowID: cursor, limit: SendCorrelator.pageSize)
                for row in page { seen[row.rowid] = row }
                guard page.count >= SendCorrelator.pageSize, let last = page.map(\.rowid).max(), last > cursor
                else { break }
                cursor = last
            }
        } catch {
            return nil
        }
        let ordered = seen.values.sorted { $0.rowid < $1.rowid }
        return Pass(candidates: ordered.filter(filter.isCandidate), ghosts: ordered.filter(filter.isGhost))
    }

    // MARK: - Results

    private struct RowState {
        var code: ResultCode
        /// Delivered or failed: correlation stops waiting for this part once the join row appears.
        var isFinal: Bool
    }

    private static func rowState(_ row: SentRowProbe, part: PartExpectation, chat: ResolvedChat) -> RowState {
        if row.error != 0 { return RowState(code: .failed(.rowError(row.error)), isFinal: true) }
        if case .file(let name) = part, row.transferStates[name] == Limits.transferStateFailed {
            return RowState(code: .failed(.transferFailed), isFinal: true)
        }
        let isSMS = (row.service ?? chat.service) == "SMS"
        if !isSMS && row.dateDeliveredNs > 0 { return RowState(code: .delivered, isFinal: true) }
        return RowState(code: .submitted, isFinal: false)
    }

    private static func result(row: SentRowProbe, code: ResultCode, filter: RowFilter) -> PartCorrelation {
        PartCorrelation(result: ActionResult(code, notes: filter.confirms(row) ? [] : [.chatUnconfirmed]), row: row)
    }

    private struct Pass {
        var candidates: [SentRowProbe]
        var ghosts: [SentRowProbe]

        static let empty = Pass(candidates: [], ghosts: [])

        enum Match {
            case none
            case one(SentRowProbe)
            case several
        }

        func match(_ part: PartExpectation) -> Match {
            let matched = candidates.filter { RowFilter.matches($0, part) }
            switch matched.count {
            case 0: return .none
            case 1: return .one(matched[0])
            default: return .several
            }
        }

        /// The result when no more waiting happens: at the end of `correlate`, or for `matchOnce`, which passes
        /// `ghostAllowed: false`.
        func settle(_ part: PartExpectation, filter: RowFilter, ghostAllowed: Bool) -> PartCorrelation {
            switch match(part) {
            case .several:
                return PartCorrelation(result: ActionResult(.ambiguous(.twoRowsMatched)), row: nil)
            case .one(let row):
                let code = SendCorrelator.rowState(row, part: part, chat: filter.chat).code
                return SendCorrelator.result(row: row, code: code, filter: filter)
            case .none:
                if ghostAllowed, let ghost = ghosts.first {
                    return PartCorrelation(result: ActionResult(.ghost), row: ghost)
                }
                return PartCorrelation(result: ActionResult(.mayHaveCompleted), row: nil)
            }
        }
    }
}

/// The identities of the chats rows join, read once per chat during one correlation. A failed read isn't kept, so
/// the next pass asks again.
final class JoinedChats {
    private let rows: SendRowSource
    private var known: [Int64: CanonicalChatID?] = [:]

    init(rows: SendRowSource) { self.rows = rows }

    func canonical(_ chatRowID: Int64) -> CanonicalChatID? {
        if let found = known[chatRowID] { return found }
        guard let found = try? rows.canonicalChatID(chatRowID: chatRowID) else { return nil }
        known[chatRowID] = found
        return found
    }
}

/// Which rows count for one send.
struct RowFilter {
    let snapshot: SendSnapshot
    let chat: ResolvedChat
    let requestNs: AppleNanos
    let recipients: Set<String>
    /// For a group, the chats a candidate's join row must name.
    let groupChats: Set<Int64>?
    /// The conversation's chats. A 1:1 row joined to any other chat is another conversation's row.
    let chats: Set<Int64>
    /// For a 1:1 chat with no chats yet, the identities of the chats its rows join.
    let joined: JoinedChats?

    init(snapshot: SendSnapshot, chat: ResolvedChat, rows: SendRowSource) {
        self.snapshot = snapshot
        self.chat = chat
        self.requestNs = AppleTime.nanos(from: snapshot.requestedAt)
        self.groupChats = chat.isGroup ? Set(chat.chatRowIDs) : nil
        self.chats = Set(chat.chatRowIDs)
        self.joined = !chat.isGroup && chat.chatRowIDs.isEmpty ? JoinedChats(rows: rows) : nil
        let handles = chat.handles + (chat.sendHandle.map { [$0] } ?? [])
        self.recipients = Set(handles.map(HandleNormalizer.normalize).filter { !$0.isEmpty })
    }

    /// The join row confirms the chat: it names one of the conversation's chats, or, for a chat with no chats yet,
    /// a chat with the same identity.
    func confirms(_ row: SentRowProbe) -> Bool {
        guard let id = row.joinedChatRowID else { return false }
        if chats.contains(id) { return true }
        guard let joined, let identity = joined.canonical(id) else { return false }
        return identity == chat.canonical
    }

    /// The join row names a chat that belongs to another conversation.
    private func joinsAnotherChat(_ row: SentRowProbe) -> Bool {
        guard let id = row.joinedChatRowID else { return false }
        if !chats.isEmpty { return !chats.contains(id) }
        guard let joined, let identity = joined.canonical(id) else { return false }
        return identity != chat.canonical
    }

    /// Above the snapshot and dated at or after the request.
    private func isNew(_ row: SentRowProbe) -> Bool {
        row.rowid > snapshot.maxRowID && row.dateNs >= requestNs
    }

    private func handleKey(of row: SentRowProbe) -> String? {
        guard let handle = row.handle else { return nil }
        let key = HandleNormalizer.normalize(handle)
        return key.isEmpty ? nil : key
    }

    func isCandidate(_ row: SentRowProbe) -> Bool {
        guard isNew(row) else { return false }
        if let groupChats { return row.joinedChatRowID.map(groupChats.contains) ?? false }
        if joinsAnotherChat(row) { return false }
        guard let key = handleKey(of: row) else { return false }
        return recipients.contains(key)
    }

    /// An empty, unjoined from_me SMS row (section 3 item 6, `ghost`).
    func isGhost(_ row: SentRowProbe) -> Bool {
        guard isNew(row), row.service == "SMS", !row.hasBody, row.body.isEmpty, row.transferNames.isEmpty,
              row.joinedChatRowID == nil else { return false }
        guard let key = handleKey(of: row) else { return true }
        return recipients.contains(key)
    }

    static func matches(_ row: SentRowProbe, _ part: PartExpectation) -> Bool {
        switch part {
        case .text(let matchKey):
            let key = TextNorm.matchKey(matchKey)
            return row.hasBody && !key.isEmpty && TextNorm.matchKey(row.body) == key
        case .textDigest(let digest):
            return row.hasBody && TextNorm.textDigest(row.body) == digest
        case .file(let transferName):
            return row.transferNames.contains(transferName)
        }
    }
}
