import Foundation
import IMCore
import IMStore

/// One agent send the limiter remembers. Persisted with the journal so limits survive a bridge restart.
public struct SendEvent: Hashable, Codable, Sendable {
    public var chat: CanonicalChatID
    public var at: Date
    /// The row the send produced, if correlation found one. Lets the consecutive-send check skip that row.
    public var guid: String?
    /// `TextNorm.textDigest` of the sent text, nil for a file-only send. A self-chat echo row has its own GUID, so in
    /// a self-chat the consecutive-send check matches echoes on this against `InboundRow.bodyDigest`.
    public var textDigest: String?

    public init(chat: CanonicalChatID, at: Date, guid: String?, textDigest: String?) {
        self.chat = chat
        self.at = at
        self.guid = guid
        self.textDigest = textDigest
    }
}

public enum RateLimitBreach: Hashable, Sendable {
    /// 1 send per 20 s per chat.
    case perChatInterval
    /// 30 per chat per day.
    case perChatDaily
    /// 100 per day.
    case globalDaily
    /// 3 consecutive agent sends to a chat with no inbound message in between.
    case consecutive

    /// Shown in the approval dialog as the reason it asks.
    public var dialogReason: String {
        switch self {
        case .perChatInterval: return "more than 1 send in 20 seconds to this chat"
        case .perChatDaily: return "more than 30 sends to this chat today"
        case .globalDaily: return "more than 100 sends today"
        case .consecutive: return "3 sends in a row with no reply"
        }
    }
}

/// Rate limits from DESIGN.md section 2. Owner: IMPolicy.
///
/// - Counts sends (text and file parts of one request count once) and threaded replies. Tapbacks, unsend and edit
///   are not counted; DESIGN.md says "send" and this is the reading the build plan uses.
/// - A breach does not refuse the action. It turns an allowed action into one that needs approval.
/// - "Day" is a rolling 24 h window: a send exactly 24 h old no longer counts.
/// - A send exactly 20 s after the previous one to the same chat is allowed.
/// - Inbound rows come from `ChatActivitySource`, which already drops the self-chat echo copies `ReadService` drops.
///   On top of that, a row whose GUID equals an agent send's `guid` is an echo and never resets the consecutive
///   count. In a self-chat, a 1:1 chat whose handle is one of `ownAddresses`, a row whose `bodyDigest` equals the
///   `textDigest` of an agent send to that chat is an echo too. The row's date isn't compared with the send's,
///   because an incoming copy can carry a server time a little before the bridge's clock. Only a self-chat gets
///   copies of the user's own sends, so in any other chat a reply with the same text as an agent send is a real
///   reply and resets the count.
/// - The consecutive count looks at the chat's last 3 sends in the history, whatever their age. History keeps
///   `Limits.journalRetention` (7 days), the same span IMBridge seeds from the journal.
/// - If the inbound rows can't be read, `check` throws and `PolicyEngine` asks.
///
/// Thread safe. `check` reads chat.db without holding the lock.
public final class RateLimiter {
    public let clock: Clock
    public let activity: ChatActivitySource
    /// The user's own addresses (`ContactBook.ownerHandles`), read at each check. A 1:1 chat with one is a self-chat.
    public let ownAddresses: () -> Set<String>

    static let day: TimeInterval = 24 * 3600
    /// Inbound rows read per call while looking for a reply among echoes.
    static let inboundPageSize = 50
    /// After this many pages of nothing but echoes the check gives up and reports a breach, so it asks.
    static let maxInboundPages = 20

    private let lock = NSLock()
    /// Oldest first.
    private var events: [SendEvent]

    public init(clock: Clock, activity: ChatActivitySource, ownAddresses: @escaping () -> Set<String>,
                history: [SendEvent] = []) {
        self.clock = clock
        self.activity = activity
        self.ownAddresses = ownAddresses
        self.events = RateLimiter.retained(history.sorted { $0.at < $1.at }, now: clock.now)
    }

    /// The first limit this send would break, or nil. Order: per-chat interval, per-chat daily, global daily,
    /// consecutive.
    public func check(chat: ResolvedChat) throws -> RateLimitBreach? {
        let now = clock.now
        lock.lock()
        let all = events
        lock.unlock()
        let mine = all.filter { $0.chat == chat.canonical }
        let inDay: (SendEvent) -> Bool = { now.timeIntervalSince($0.at) < RateLimiter.day }

        if let last = mine.last, now.timeIntervalSince(last.at) < Limits.minSecondsBetweenSendsPerChat {
            return .perChatInterval
        }
        if mine.filter(inDay).count >= Limits.maxSendsPerChatPerDay { return .perChatDaily }
        if all.filter(inDay).count >= Limits.maxSendsPerDay { return .globalDaily }
        if try noInboundSince(mine: mine, all: all, chat: chat) { return .consecutive }
        return nil
    }

    /// Records a send once it reaches `invoking`, whatever its result.
    public func record(_ event: SendEvent) {
        lock.lock()
        defer { lock.unlock() }
        let i = events.firstIndex { $0.at > event.at } ?? events.endIndex
        events.insert(event, at: i)
        events = RateLimiter.retained(events, now: clock.now)
    }

    /// Snapshot to persist, oldest first.
    public var history: [SendEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    // MARK: - Internals

    private static func retained(_ events: [SendEvent], now: Date) -> [SendEvent] {
        events.filter { now.timeIntervalSince($0.at) < Limits.journalRetention }
    }

    /// A 1:1 chat whose handle is one of the user's own addresses.
    static func isSelfChat(_ chat: ResolvedChat, own: Set<String>) -> Bool {
        guard !chat.isGroup else { return false }
        return own.contains { CanonicalChatID.direct(handle: HandleNormalizer.normalize($0)) == chat.canonical }
    }

    /// True if the chat's last `maxConsecutiveAgentSends` sends have no real inbound message after the oldest of them.
    private func noInboundSince(mine: [SendEvent], all: [SendEvent], chat: ResolvedChat) throws -> Bool {
        let n = Limits.maxConsecutiveAgentSends
        guard mine.count >= n else { return false }
        let anchor = mine[mine.count - n]
        let sentGUIDs = Set(all.compactMap(\.guid))
        let digests = RateLimiter.isSelfChat(chat, own: ownAddresses()) ? Set(mine.compactMap(\.textDigest)) : []
        func isEcho(_ row: InboundRow) -> Bool {
            sentGUIDs.contains(row.guid) || digests.contains(row.bodyDigest)
        }

        var after = AppleTime.nanos(from: anchor.at)
        for _ in 0..<RateLimiter.maxInboundPages {
            let rows = try activity.inboundRows(in: chat, afterNs: after, limit: RateLimiter.inboundPageSize)
            if rows.contains(where: { !isEcho($0) }) { return false }
            guard rows.count >= RateLimiter.inboundPageSize, let last = rows.last, last.dateNs > after else {
                return true
            }
            after = last.dateNs
        }
        return true
    }
}
