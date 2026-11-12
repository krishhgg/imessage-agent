import Foundation
import IMCore

/// Everything IMStore needs to open and read. Tests build one around the fixture (see IMTestSupport.Fixture).
public struct StoreConfiguration {
    /// chat.db path. Live: `Paths.chatDB` only (section 1). Tests: Tests/Fixtures/chat.db.
    public var chatDBPath: String
    /// Root that `~/Library/Messages/Attachments/` maps to. Live: `Paths.messagesAttachmentsDir`.
    /// Tests: Tests/Fixtures/Attachments.
    public var attachmentsRoot: URL
    /// 0700 cache for viewable copies (`Paths.attachmentCacheDir`).
    public var attachmentCacheDir: URL
    public var timeZone: TimeZone
    public var rowCap: Int
    public var interactiveTimeout: TimeInterval
    public var searchBudget: TimeInterval
    public var searchWindowDays: Int
    /// Cap on the chat list and member rows the conversation index loads. Past it every call fails with
    /// `rowCapExceeded` instead of working from an index with chats or members missing.
    public var indexRowCap: Int
    /// The Mac's region, like `US` or `MX`. A phone number typed or saved without a leading `+` becomes a new direct
    /// target only when this region uses the North American +1 plan (`HandleNormalizer.usesNorthAmericanPlan`).
    /// Nil counts as outside it.
    public var regionCode: String?

    /// The index cap: far above any real chat list, as `AddressBookContacts.rowCap` is for cards.
    public static let defaultIndexRowCap = 200_000

    /// The region of `Locale.current`, the default for `regionCode`.
    public static var currentRegionCode: String? { Locale.current.region?.identifier }

    public init(chatDBPath: String, attachmentsRoot: URL, attachmentCacheDir: URL, timeZone: TimeZone = .current,
                rowCap: Int = Limits.defaultRowCap, interactiveTimeout: TimeInterval = Limits.interactiveReadTimeout,
                searchBudget: TimeInterval = Limits.searchBudget, searchWindowDays: Int = Limits.searchWindowDays,
                indexRowCap: Int = StoreConfiguration.defaultIndexRowCap,
                regionCode: String? = StoreConfiguration.currentRegionCode) {
        self.chatDBPath = chatDBPath
        self.attachmentsRoot = attachmentsRoot
        self.attachmentCacheDir = attachmentCacheDir
        self.timeZone = timeZone
        self.rowCap = rowCap
        self.interactiveTimeout = interactiveTimeout
        self.searchBudget = searchBudget
        self.searchWindowDays = searchWindowDays
        self.indexRowCap = indexRowCap
        self.regionCode = regionCode
    }

    /// The bridge's configuration: hard-coded paths from `Paths`.
    public static func live(paths: Paths = Paths()) -> StoreConfiguration {
        StoreConfiguration(chatDBPath: paths.chatDB.path, attachmentsRoot: paths.messagesAttachmentsDir,
                           attachmentCacheDir: paths.attachmentCacheDir)
    }
}

/// The 1:1 or group conversation a target argument names (section 5: name, phone, email, chat id or number).
/// "The target chat" means every 1:1 chat.db chat with the same participant handle (section 4, Chat).
///
/// A new direct target is a phone number, email or contact handle chat.db has no chat for yet. It has no chats
/// (`chatRowIDs` and `chatGUIDs` empty, `primaryChatRowID` 0), its `sendHandle` is that handle and its service is
/// iMessage. Once Messages creates the chat, the same text resolves to it, with the same `canonical`.
public struct ResolvedChat: Hashable, Sendable {
    public var canonical: CanonicalChatID
    /// Every chat.db chat in this conversation, newest first. Empty for a new direct target.
    public var chatRowIDs: [Int64]
    public var chatGUIDs: [String]
    /// The chat `read` and `chats` show for this conversation. 0 for a new direct target.
    public var primaryChatRowID: Int64
    public var label: String
    public var isGroup: Bool
    /// Normalized participant handles, the user's own left out.
    public var handles: [String]
    /// Handle the AppleScript send addresses (1:1 only).
    public var sendHandle: String?
    /// The chat's service, `iMessage`, `SMS` or `RCS`. The send scripts use the SMS account for `SMS` and iMessage
    /// for any other (BUILD-PLAN 16).
    public var service: String

    public init(canonical: CanonicalChatID, chatRowIDs: [Int64], chatGUIDs: [String], primaryChatRowID: Int64,
                label: String, isGroup: Bool, handles: [String], sendHandle: String?, service: String) {
        self.canonical = canonical
        self.chatRowIDs = chatRowIDs
        self.chatGUIDs = chatGUIDs
        self.primaryChatRowID = primaryChatRowID
        self.label = label
        self.isGroup = isGroup
        self.handles = handles
        self.sendHandle = sendHandle
        self.service = service
    }

    public var ref: ChatRef { ChatRef(rowid: primaryChatRowID, label: label, isGroup: isGroup) }
}

/// The read side: one hardened chat.db connection plus contacts. Conforms to the consumer protocols in
/// ConsumerProtocols.swift so IMSend, IMUI and IMPolicy can run against fakes. Owner: IMStore.
///
/// Two hardened connections: interactive reads share one, and search runs on its own so a long search never holds
/// up `read` or `send`. Each call holds its connection for the whole call, and waiting for it counts toward the
/// call's deadline. `agentSentGUIDs` sits behind a lock, so the bridge can update it while reads run.
public final class ChatDatabase {
    public let configuration: StoreConfiguration
    public let contacts: ContactBook
    public let clock: Clock

    let connection: SQLiteConnection
    let searchConnection: SQLiteConnection
    private let agentLock = NSLock()
    private var agentSent: Set<String> = []

    public init(configuration: StoreConfiguration, contacts: ContactBook, clock: Clock) throws {
        self.configuration = configuration
        self.contacts = contacts
        self.clock = clock
        connection = try SQLiteConnection(readOnlyPath: configuration.chatDBPath)
        searchConnection = try SQLiteConnection(readOnlyPath: configuration.chatDBPath)
        for conn in [connection, searchConnection] {
            conn.defaultRowCap = max(1, configuration.rowCap)
            try conn.registerSearchFunctions()
        }
        connection.defaultTimeout = configuration.interactiveTimeout
        searchConnection.defaultTimeout = configuration.searchBudget
        contacts.addOwnerHandles(try interactive { try $0.accountHandles() })
    }

    /// Runs one interactive call: 2 s (configurable) for everything it reads, waiting for the connection included.
    func interactive<T>(_ body: (Session) throws -> T) throws -> T {
        try connection.withBudget(seconds: configuration.interactiveTimeout, rowCap: Int.max) {
            try body(Session(db: self, conn: connection, timeout: configuration.interactiveTimeout))
        }
    }

    /// Runs one search call on the search connection with the search budget.
    func searching<T>(_ body: (Session) throws -> T) throws -> T {
        try searchConnection.withBudget(seconds: configuration.searchBudget, rowCap: Int.max) {
            try body(Session(db: self, conn: searchConnection, timeout: configuration.searchBudget))
        }
    }

    /// Full Disk Access probe used by `status`, `setup` and `doctor`. Tries the open once so macOS lists the
    /// bridge in the FDA pane (section 1, TCC contract).
    public static func probe(path: String) -> DatabaseProbe {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        if fd < 0 {
            let code = errno
            switch code {
            case EPERM, EACCES: return .notPermitted
            case ENOENT, ENOTDIR: return .missing
            default: return .failed(String(cString: strerror(code)))
            }
        }
        close(fd)
        do {
            let conn = try SQLiteConnection(readOnlyPath: path)
            defer { conn.close() }
            var count: Int64 = 0
            try conn.query(SQLText.shared.messageCount, [.int(1)]) { count = $0.int(0) }
            return .ok(messageRows: count)
        } catch StoreError.notPermitted {
            return .notPermitted
        } catch StoreError.notFound {
            return .missing
        } catch {
            return .failed(String(describing: error))
        }
    }

    /// Resolves a target argument (section 5). Several matches throw `.severalMatches` with candidates and
    /// nothing runs. A contact's iMessage and SMS chats count as one conversation. A valid phone number or email
    /// with no chat, or a contact whose one handle has no chat, is a new direct target. A number without a leading
    /// `+` is valid only when `StoreConfiguration.regionCode` uses the +1 plan.
    public func resolve(_ who: String) throws -> ResolvedChat {
        try interactive { try $0.resolve(who).resolved }
    }

    /// Rebuilds the conversation a journal entry or approval binding names, for crash reconciliation (section 3
    /// item 2). Nil if chat.db no longer has a chat for it.
    public func resolve(canonical: CanonicalChatID) throws -> ResolvedChat? {
        try interactive { try $0.index().byCanonical[canonical]?.resolved }
    }

    /// The conversation a journal entry's send went to, for crash reconciliation: `resolve(canonical:)`, or for a
    /// 1:1 identity chat.db has no chat for yet, the new direct target that addresses its handle. A send to a new
    /// direct target can leave a row whose chat Messages hasn't written yet, so reconciling it must not need one.
    public func sendTarget(canonical: CanonicalChatID) throws -> ResolvedChat? {
        try interactive { s in
            if let conv = try s.index().byCanonical[canonical] { return conv.resolved }
            guard let key = canonical.directHandle, !key.isEmpty else { return nil }
            return Conversation(newDirect: key, service: try s.newDirectService(key), contacts: contacts).resolved
        }
    }

    /// The conversation a chat.db chat belongs to, for UI actions that name a message (`MessageTargetInfo.chatRowID`).
    /// A 1:1 chat resolves to every chat with the same participant handle (section 4, Chat).
    public func resolve(chatRowID: Int64) throws -> ResolvedChat? {
        try interactive { try $0.index().byChat[chatRowID]?.resolved }
    }

    /// Chat by chat.db ROWID. Identity fields are that chat's; label, members, unread count, newest message and
    /// merged chats are its conversation's.
    public func chat(rowid: Int64) throws -> ChatRecord {
        try interactive { s in
            guard let info = try s.index().chats[rowid], let conv = try s.index().byChat[rowid] else {
                throw StoreError.notFound("chat \(rowid)")
            }
            let unread = try s.unreadRows().filter { s.conversationKey($0) == conv.canonical }.count
            var record = try s.chatRecord(conv, unreadCount: unread)
            record.rowid = info.rowid
            record.guid = info.guid
            record.identifier = info.identifier
            record.displayName = info.displayName
            record.service = info.service
            return record
        }
    }

    /// Rows the bridge sent, so echoes and agent sends never count as inbound (sections 2 and 5).
    /// IMBridge keeps this current from the journal. Reads and writes are locked; prefer `addAgentSentGUIDs`
    /// for single inserts so two writers never drop each other's entries.
    public var agentSentGUIDs: Set<String> {
        get {
            agentLock.lock()
            defer { agentLock.unlock() }
            return agentSent
        }
        set {
            agentLock.lock()
            agentSent = newValue
            agentLock.unlock()
        }
    }

    /// Adds GUIDs atomically.
    public func addAgentSentGUIDs<S: Sequence>(_ guids: S) where S.Element == String {
        agentLock.lock()
        agentSent.formUnion(guids)
        agentLock.unlock()
    }
}

// MARK: - Resolution

extension Session {
    /// chat.db's view of the user's own handles: account logins without the `E:` or `P:` prefix, and the handle
    /// each chat was last addressed from.
    func accountHandles() throws -> [String] {
        var out: [String] = []
        try eachAll(SQLText.shared.chatList, [], cap: indexCap) { r in
            if var login = r.text(6), !login.isEmpty {
                if login.hasPrefix("E:") || login.hasPrefix("P:") { login.removeFirst(2) }
                if !login.isEmpty { out.append(login) }
            }
            if let last = r.text(7), !last.isEmpty { out.append(last) }
        }
        return out
    }

    func conversationKey(_ row: MessageRow) -> CanonicalChatID? {
        (try? conversation(forChat: row.chatID))?.canonical
    }

    static let phonePattern = try! NSRegularExpression(pattern: "^\\+?[0-9\\s().-]{7,}$")

    static func looksLikePhone(_ s: String) -> Bool {
        let range = NSRange(s.startIndex..., in: s)
        return phonePattern.firstMatch(in: s, range: range) != nil
    }

    /// Whether the Mac's region uses the +1 plan, so a number without a leading `+` can be a new direct target.
    var northAmericanPlan: Bool { HandleNormalizer.usesNorthAmericanPlan(region: db.configuration.regionCode) }

    /// A phone number or email a send can address before chat.db has a chat for it: an email with a name, one `@`,
    /// a dotted domain and no spaces, or a phone number with a leading `+` and 7 to 15 digits. With
    /// `northAmerican` (the Mac's region uses the +1 plan) a number with 10 digits, or 11 starting with 1, also
    /// counts, as `HandleNormalizer` reads those as +1 numbers. Elsewhere such a number may be a local one, and
    /// adding +1 would address a stranger.
    static func isSendableHandle(_ text: String, northAmerican: Bool) -> Bool {
        let h = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.contains("@") {
            let parts = h.split(separator: "@", omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty,
                  !h.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }) else {
                return false
            }
            let labels = parts[1].split(separator: ".", omittingEmptySubsequences: false)
            return labels.count >= 2 && labels.allSatisfy { !$0.isEmpty }
        }
        guard looksLikePhone(h) else { return false }
        let digits = h.unicodeScalars.filter { ("0"..."9").contains($0) }
        if h.hasPrefix("+") { return (7...15).contains(digits.count) && digits.first != "0" }
        return northAmerican && (digits.count == 10 || (digits.count == 11 && digits.first == "1"))
    }

    /// The service a new direct target sends on: `SMS` when chat.db knows the handle only from SMS (a member of an
    /// SMS group, say) and never from iMessage, otherwise `iMessage`. RCS counts as neither, so a handle known only
    /// from RCS sends on iMessage, as an RCS chat does (BUILD-PLAN item 16).
    func newDirectService(_ key: String) throws -> String {
        var services: Set<String> = []
        try each(SQLText.shared.servicesOfHandle, [.text(key)], limit: cap) { r in
            if let service = r.text(0) { services.insert(service) }
        }
        return services.contains("SMS") && !services.contains("iMessage") ? "SMS" : "iMessage"
    }

    static func isChatNumber(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 6 && s.unicodeScalars.allSatisfy { ("0"..."9").contains($0) }
    }

    /// Whether `needle` occurs in `text` at the start of a word: at the start of `text` or after a character that
    /// isn't a letter or digit. A needle that starts with such a character can match anywhere. So `Fam` and
    /// `of 2012` match `Family` and `Class of 2012`, but `dad` doesn't match `Grandad` and `12` doesn't match `2012`.
    static func startsWord(_ needle: String, in text: String) -> Bool {
        guard let head = needle.first else { return false }
        let isWordCharacter: (Character) -> Bool = { $0.isLetter || $0.isNumber }
        var from = text.startIndex
        while from < text.endIndex, let r = text.range(of: needle, range: from..<text.endIndex) {
            if r.lowerBound == text.startIndex || !isWordCharacter(head)
                || !isWordCharacter(text[text.index(before: r.lowerBound)]) {
                return true
            }
            from = text.index(after: r.lowerBound)
        }
        return false
    }

    /// What a target text matches. `targets` are distinct conversations, chat.db's newest first, then new direct
    /// targets. `cards` holds the contacts with the name when there are two or more, which are several matches
    /// on their own. `localNumbers` holds the phone numbers saved without a `+` on the one matching contact when,
    /// outside a +1 region, that contact has no chat and nothing to send to. `cards` then holds that contact, so
    /// it still counts as a match.
    struct TargetMatches {
        var targets: [Conversation] = []
        var cards: [ContactCard] = []
        var localNumbers: [String] = []
    }

    /// Every kind of match at once (section 5): chat number, chat guid or identifier, phone or email, contact name
    /// and group display name. A phone number or email with no chat, or a contact with no chat, gives a new direct
    /// target for each valid handle (`isSendableHandle` in the Mac's region). Text matches a display name where it
    /// starts a word (`startsWord`), and a chat number never matches one.
    func targetMatches(_ w: String, _ index: ConversationIndex) throws -> TargetMatches {
        var found: [Conversation] = []
        func add(_ conv: Conversation?) {
            guard let conv, !found.contains(where: { $0.canonical == conv.canonical }) else { return }
            found.append(conv)
        }
        let northAmerican = northAmericanPlan
        var localNumbers: [String] = []
        if Session.isChatNumber(w), let id = Int64(w) { add(index.byChat[id]) }
        for chat in index.chats.values where chat.guid == w || chat.identifier == w { add(index.byChat[chat.rowid]) }
        if w.contains("@") || Session.looksLikePhone(w) {
            let key = HandleNormalizer.normalize(w)
            if let conv = index.byCanonical[.direct(handle: key)] {
                add(conv)
            } else if Session.isSendableHandle(w, northAmerican: northAmerican) {
                add(Conversation(newDirect: key, service: try newDirectService(key), contacts: db.contacts))
            }
        }
        var cards = db.contacts.cards(named: w)
        if cards.count == 1 {
            var direct: [Conversation] = []
            var unknown: [String] = []
            var local: [String] = []
            for h in cards[0].handles {
                let key = HandleNormalizer.normalize(h)
                if let conv = index.byCanonical[.direct(handle: key)] {
                    direct.append(conv)
                } else if Session.isSendableHandle(h, northAmerican: northAmerican) {
                    if !unknown.contains(key) { unknown.append(key) }
                } else if !northAmerican {
                    let number = h.trimmingCharacters(in: .whitespacesAndNewlines)
                    if Session.looksLikePhone(number), !number.hasPrefix("+") { local.append(number) }
                }
            }
            if direct.isEmpty {
                for key in unknown {
                    add(Conversation(newDirect: key, service: try newDirectService(key), contacts: db.contacts))
                }
                if unknown.isEmpty { localNumbers = local }
            } else {
                direct.forEach(add)
            }
            if localNumbers.isEmpty { cards = [] }
        }
        // A chat number is compared with chat numbers and identifiers only, so a group named `Team 7` never
        // competes with chat 7.
        let needle = ContactBook.fold(w)
        if !Session.isChatNumber(w) {
            for conv in index.conversations where conv.isGroup && !conv.primary.displayName.isEmpty
                && Session.startsWord(needle, in: ContactBook.fold(conv.label)) {
                add(conv)
            }
        }
        var rank: [CanonicalChatID: Int] = [:]
        for (i, conv) in index.conversations.enumerated() { rank[conv.canonical] = i }
        let ordered = found.enumerated().sorted {
            (rank[$0.element.canonical] ?? Int.max, $0.offset) < (rank[$1.element.canonical] ?? Int.max, $1.offset)
        }
        return TargetMatches(targets: ordered.map(\.element), cards: cards, localNumbers: localNumbers)
    }

    /// How a match is listed under `error: several matches`. The argument is the chat number, or the chat guid
    /// when the number matches more than this conversation, or the handle of a new direct target.
    func candidate(_ conv: Conversation, _ index: ConversationIndex) throws -> Candidate {
        if conv.chats.isEmpty {
            let key = conv.primary.identifier
            return Candidate(label: "\(conv.label) \(HandleNormalizer.formatForWho(key))", argument: key)
        }
        let label = conv.isGroup ? conv.label
            : "\(conv.label) \(HandleNormalizer.formatForWho(conv.handles.first ?? conv.primary.identifier))"
        let number = String(conv.primary.rowid)
        let again = try targetMatches(number, index)
        let unique = again.cards.isEmpty && again.targets.count == 1 && again.targets[0].canonical == conv.canonical
        return Candidate(label: label, argument: unique ? number : conv.primary.guid)
    }

    /// The handle a contact is listed with under several matches: the first of the card's handles that has a
    /// chat or that `isSendableHandle` accepts in the Mac's region, normalized. A card with neither gives its first
    /// handle as saved, so a number without a `+` outside a +1 region resolves to the country-code fix and never
    /// to the +1 number `HandleNormalizer` makes of it (BUILD-PLAN entry 41).
    func cardArgument(_ card: ContactCard, _ index: ConversationIndex) -> String? {
        let northAmerican = northAmericanPlan
        for h in card.handles {
            let key = HandleNormalizer.normalize(h)
            if index.byCanonical[.direct(handle: key)] != nil
                || Session.isSendableHandle(h, northAmerican: northAmerican) {
                return key
            }
        }
        return card.handles.first?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Section 5 target resolution. Every kind of match is collected (`targetMatches`), and two or more distinct
    /// conversations, or two or more contacts with the name, throw `.severalMatches` with every candidate. One
    /// match is the target. With none, a group whose label (its members' names, as it has no display name)
    /// contains the text is the target; else `.noMatch`. A contact whose only numbers lack a country code
    /// outside a +1 region is a match too. Next to another match it is listed with `cardArgument`. Alone it
    /// throws `.noMatch` with the first of those numbers, so the fix asks for the number with its country code.
    func resolve(_ who: String) throws -> Conversation {
        let w = who.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty else { throw StoreError.noMatch(who) }
        let index = try index()
        let found = try targetMatches(w, index)
        if !found.cards.isEmpty, found.cards.count + found.targets.count > 1 {
            throw StoreError.severalMatches(found.cards.map { card in
                let label = db.contacts.fullName(for: card.handles.first ?? "") ?? ContactBook.baseName(card) ?? w
                return Candidate(label: label, argument: cardArgument(card, index) ?? w)
            } + (try found.targets.map { try candidate($0, index) }))
        }
        if let number = found.localNumbers.first { throw StoreError.noMatch(number) }
        if found.targets.count == 1 { return found.targets[0] }
        if found.targets.count > 1 { throw StoreError.severalMatches(try found.targets.map { try candidate($0, index) }) }

        let needle = ContactBook.fold(w)
        let groups = index.conversations.filter {
            $0.isGroup && $0.primary.displayName.isEmpty && ContactBook.fold($0.label).contains(needle)
        }
        if groups.count == 1 { return groups[0] }
        if groups.count > 1 { throw StoreError.severalMatches(try groups.map { try candidate($0, index) }) }
        throw StoreError.noMatch(w)
    }
}

extension StoreError {
    /// The fix for a target's `.noMatch` (section 5). A chat number points at `imessage chats`, an email or phone
    /// number that can't be addressed asks for the whole form, and anything else asks for a phone number, an
    /// email or a chat id.
    public static func noMatchFix(for who: String) -> String {
        let w = who.trimmingCharacters(in: .whitespacesAndNewlines)
        if Session.isChatNumber(w) { return "imessage chats" }
        if w.contains("@") { return "check the email address" }
        if Session.looksLikePhone(w) { return "pass the whole number with + and its country code" }
        return "pass a phone number, an email or a chat id from imessage chats"
    }
}
