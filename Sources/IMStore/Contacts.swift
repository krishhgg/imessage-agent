import Foundation
import IMCore

/// One Contacts card, reduced to what names and target resolution need.
public struct ContactCard: Hashable, Sendable {
    public var firstName: String
    public var lastName: String
    public var nickname: String?
    /// Raw handles as stored on the card. Normalize with `HandleNormalizer` before comparing.
    public var handles: [String]

    public init(firstName: String, lastName: String, nickname: String?, handles: [String]) {
        self.firstName = firstName
        self.lastName = lastName
        self.nickname = nickname
        self.handles = handles
    }
}

/// Where contacts come from. Live: `AddressBookContacts`. Tests: `JSONContacts` on Tests/Fixtures/contacts.json.
public protocol ContactsSource: AnyObject {
    func cards() throws -> [ContactCard]
    /// The user's own handles (the "Me" card, or the fixture's `owner`). chat.db account columns add to these.
    func ownerHandles() throws -> [String]
}

/// Reads `~/Library/Application Support/AddressBook/Sources/*/AddressBook-v22.abcddb` read-only with the same
/// hardening as chat.db (section 1). Tables: ZABCDRECORD, ZABCDPHONENUMBER, ZABCDEMAILADDRESS. Owner: IMStore.
///
/// A card with no first, last or nickname but an organization uses the organization as its first name. Cards with
/// no phone or email are left out. The Me card (`ZCONTAINERWHERECONTACTISME` set) gives the owner handles and is
/// not listed as a card. A source that fails to open or read is skipped; if every source fails, the first error is
/// thrown.
public final class AddressBookContacts: ContactsSource {
    public let sourcesDir: URL

    static let databaseName = "AddressBook-v22.abcddb"
    static let rowCap = 200_000

    private let lock = NSLock()
    private var loaded: (cards: [ContactCard], owner: [String])?

    public init(sourcesDir: URL) { self.sourcesDir = sourcesDir }

    public func cards() throws -> [ContactCard] { try load().cards }
    public func ownerHandles() throws -> [String] { try load().owner }

    private func load() throws -> (cards: [ContactCard], owner: [String]) {
        lock.lock()
        defer { lock.unlock() }
        if let loaded { return loaded }
        var cards: [ContactCard] = []
        var owner: [String] = []
        var firstError: Error?
        var anyRead = false
        for path in databasePaths() {
            do {
                let source = try AddressBookContacts.read(path: path)
                cards += source.cards
                owner += source.owner
                anyRead = true
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if !anyRead, let firstError { throw firstError }
        let result = (cards: cards, owner: owner)
        loaded = result
        return result
    }

    /// Source databases in name order. Only the fixed file name inside each direct subfolder is considered.
    func databasePaths() -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: sourcesDir.path) else { return [] }
        return names.sorted().compactMap { name in
            guard !name.hasPrefix(".") else { return nil }
            let path = sourcesDir.appendingPathComponent(name, isDirectory: true)
                .appendingPathComponent(AddressBookContacts.databaseName).path
            return fm.fileExists(atPath: path) ? path : nil
        }
    }

    static func read(path: String) throws -> (cards: [ContactCard], owner: [String]) {
        let conn = try SQLiteConnection(readOnlyPath: path)
        defer { conn.close() }
        conn.defaultRowCap = rowCap
        let cap = SQLiteValue.int(Int64(rowCap))

        struct Draft {
            var first = "", last = "", nickname: String?, organization = ""
            var handles: [String] = []
        }
        var order: [Int64] = []
        var drafts: [Int64: Draft] = [:]
        try conn.query(SQLText.shared.addressBookRecords, [cap]) { r in
            let pk = r.int(0)
            if drafts[pk] == nil { order.append(pk) }
            drafts[pk] = Draft(first: r.text(1) ?? "", last: r.text(2) ?? "", nickname: r.text(3),
                               organization: r.text(4) ?? "")
        }
        try conn.query(SQLText.shared.addressBookPhones, [cap]) { r in
            let pk = r.int(0)
            if let v = r.text(1), !v.isEmpty { drafts[pk]?.handles.append(v) }
        }
        try conn.query(SQLText.shared.addressBookEmails, [cap]) { r in
            let pk = r.int(0)
            if let v = r.text(1), !v.isEmpty { drafts[pk]?.handles.append(v) }
        }
        var me: Set<Int64> = []
        do {
            try conn.query(SQLText.shared.addressBookMe, [cap]) { r in me.insert(r.int(0)) }
        } catch StoreError.sqlite {
            // Older schemas have no ZCONTAINERWHERECONTACTISME column; there is then no Me card.
        }
        var cards: [ContactCard] = []
        var owner: [String] = []
        for pk in order {
            guard let d = drafts[pk], !d.handles.isEmpty else { continue }
            if me.contains(pk) {
                owner += d.handles
                continue
            }
            let nickname = d.nickname.flatMap { $0.isEmpty ? nil : $0 }
            var first = d.first
            if first.isEmpty, d.last.isEmpty, nickname == nil { first = d.organization }
            cards.append(ContactCard(firstName: first, lastName: d.last, nickname: nickname, handles: d.handles))
        }
        return (cards, owner)
    }
}

/// Fixture contacts: `{"owner": {"first", "handles"}, "people": [{"first", "last", "nickname", "handles"}]}`.
public final class JSONContacts: ContactsSource {
    public let url: URL

    public init(url: URL) { self.url = url }

    private struct File: Decodable {
        struct Owner: Decodable {
            var first: String?
            var handles: [String]
        }
        struct Person: Decodable {
            var first: String?
            var last: String?
            var nickname: String?
            var handles: [String]
        }
        var owner: Owner?
        var people: [Person]
    }

    private func load() throws -> File {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw StoreError.notFound(url.path)
        }
        do {
            return try JSONDecoder().decode(File.self, from: data)
        } catch {
            throw StoreError.decode("contacts file \(url.lastPathComponent) is not valid")
        }
    }

    public func cards() throws -> [ContactCard] {
        try load().people.map {
            ContactCard(firstName: $0.first ?? "", lastName: $0.last ?? "",
                        nickname: $0.nickname.flatMap { $0.isEmpty ? nil : $0 }, handles: $0.handles)
        }
    }

    public func ownerHandles() throws -> [String] { try load().owner?.handles ?? [] }
}

/// Handle normalization (bench/reader.py `normalize_handle`): emails lowercased, phones to `+<digits>` with a
/// leading 1 added to 10-digit numbers written without a `+`.
///
/// A number with a `+` before its first digit already has its country code, so `+45 32 12 34 56` stays
/// `+4532123456` and never becomes the +1 number `+14532123456`.
///
/// One difference from the bench: a handle with letters and no `@` (a business chat id such as `urn:biz:…`) is
/// kept as it is, so its digits can never turn it into somebody's phone number.
public enum HandleNormalizer {
    public static func normalize(_ handle: String) -> String {
        let h = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.contains("@") { return h.lowercased() }
        if h.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) { return h }
        var digits = String(h.unicodeScalars.filter { $0.isASCII && CharacterSet.decimalDigits.contains($0) })
        if digits.isEmpty { return h }
        let hasCountryCode = h.unicodeScalars.first { $0 == "+" || ("0"..."9").contains($0) } == "+"
        if digits.count == 10, !hasCountryCode { digits = "1" + digits }
        return "+" + digits
    }

    /// ISO 3166 regions in the North American Numbering Plan, country code +1.
    public static let northAmericanRegions: Set<String> = [
        "AG", "AI", "AS", "BB", "BM", "BS", "CA", "DM", "DO", "GD", "GU", "JM", "KN",
        "KY", "LC", "MP", "MS", "PR", "SX", "TC", "TT", "UM", "US", "VC", "VG", "VI",
    ]

    /// Whether a number dialed there without a country code is a +1 number. Nil, or a region code that isn't a
    /// country (`419`), counts as no.
    public static func usesNorthAmericanPlan(region: String?) -> Bool {
        guard let region else { return false }
        return northAmericanRegions.contains(region.uppercased())
    }

    /// `+1 (415) 555-0101` for 11-digit NANP numbers, else the handle (`format_phone`).
    public static func formatPhone(_ handle: String) -> String {
        guard let d = nanpDigits(handle) else { return handle }
        return "+1 (\(d[1..<4])) \(d[4..<7])-\(d[7..<11])"
    }

    /// `+1 415-555-0101` as `who` prints it (`reader_format` in ours.py).
    public static func formatForWho(_ handle: String) -> String {
        guard let d = nanpDigits(handle) else { return handle }
        return "+1 \(d[1..<4])-\(d[4..<7])-\(d[7..<11])"
    }

    /// The 11 digits of a NANP number with a leading 1, or nil.
    private static func nanpDigits(_ handle: String) -> DigitSlice? {
        guard !handle.contains("@") else { return nil }
        let digits = handle.unicodeScalars.filter { $0.isASCII && CharacterSet.decimalDigits.contains($0) }
        guard digits.count == 11, digits.first == "1" else { return nil }
        return DigitSlice(chars: digits.map { Character($0) })
    }

    private struct DigitSlice {
        let chars: [Character]
        subscript(_ r: Range<Int>) -> String { String(chars[r]) }
    }
}

/// Name lookups over a `ContactsSource` (research/tokens.md section 5, field rule 3). Owner: IMStore.
///
/// Cards are loaded once. Owner handles can grow (`addOwnerHandles`, from chat.db account columns) and are guarded
/// by a lock, so several connections can read names at once.
public final class ContactBook {
    private let allCards: [ContactCard]
    private let byHandle: [String: ContactCard]
    private let lock = NSLock()
    private var owners: Set<String>

    public init(source: ContactsSource) throws {
        let cards = ContactBook.merged(try source.cards())
        var map: [String: ContactCard] = [:]
        for card in cards {
            for h in card.handles {
                let key = HandleNormalizer.normalize(h)
                if !key.isEmpty { map[key] = card }
            }
        }
        allCards = cards
        byHandle = map
        owners = Set(try source.ownerHandles().map(HandleNormalizer.normalize).filter { !$0.isEmpty })
    }

    /// Adds handles chat.db shows as the user's own (account login, last addressed handle).
    public func addOwnerHandles(_ handles: [String]) {
        let normalized = handles.map(HandleNormalizer.normalize).filter { !$0.isEmpty }
        lock.lock()
        owners.formUnion(normalized)
        lock.unlock()
    }

    /// Every owner handle, normalized.
    public var ownerHandles: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return owners
    }

    /// `You` for owner handles; nickname or first name; else a formatted phone or the email.
    /// Adds the last initial when two members of one chat share a first name.
    public func shortName(for handle: String?) -> String {
        guard let handle else { return "Unknown" }
        if isOwner(handle) { return "You" }
        if let card = card(for: handle), let name = ContactBook.baseName(card) { return name }
        return ContactBook.handleLabel(handle)
    }

    /// A handle as text: an email as is, a phone through `HandleNormalizer.formatPhone`.
    public static func handleLabel(_ handle: String) -> String {
        handle.contains("@") ? handle : HandleNormalizer.formatPhone(handle)
    }

    /// `shortName(for:)` inside a chat whose members are `members`. When another member's card gives the same
    /// short name, the last initial is added (`Sam L`), as research/tokens.md asks.
    public func shortName(for handle: String?, among members: [String]) -> String {
        let name = shortName(for: handle)
        guard let handle, !isOwner(handle), let card = card(for: handle), let initial = card.lastName.first else {
            return name
        }
        let key = HandleNormalizer.normalize(handle)
        let clash = members.contains { other in
            let otherKey = HandleNormalizer.normalize(other)
            guard otherKey != key, !isOwner(other), let otherCard = self.card(for: other), otherCard != card else {
                return false
            }
            return ContactBook.baseName(otherCard) == name
        }
        return clash ? "\(name) \(initial)" : name
    }

    /// First and last name, the way Contacts shows a card. No nickname.
    public func fullName(for handle: String) -> String? {
        guard let card = card(for: handle) else { return nil }
        let name = [card.firstName, card.lastName].filter { !$0.isEmpty }.joined(separator: " ")
        return name.isEmpty ? nil : name
    }

    public func card(for handle: String) -> ContactCard? {
        byHandle[HandleNormalizer.normalize(handle)]
    }

    /// Cards whose nickname, first name or "first last" equals `name`, case-insensitively.
    public func cards(named name: String) -> [ContactCard] {
        let q = ContactBook.fold(name)
        guard !q.isEmpty else { return [] }
        var out: [ContactCard] = []
        for card in allCards {
            let names = [card.nickname ?? "", card.firstName, "\(card.firstName) \(card.lastName)"]
                .map(ContactBook.fold).filter { !$0.isEmpty }
            if names.contains(q), !out.contains(card) { out.append(card) }
        }
        return out
    }

    public func isOwner(_ handle: String) -> Bool {
        let key = HandleNormalizer.normalize(handle)
        lock.lock()
        defer { lock.unlock() }
        return owners.contains(key)
    }

    /// Merges cards with the same folded first and last name that share a normalized handle, as when two
    /// AddressBook sources hold the same person. The merged card keeps the first card's names, the first nickname
    /// and every handle once (by normalized form, first spelling kept), so the name resolves to one chat and
    /// `who` lists the person once. A card that links two earlier cards merges all three.
    static func merged(_ cards: [ContactCard]) -> [ContactCard] {
        var out: [ContactCard] = []
        var names: [String] = []
        var keys: [Set<String>] = []
        for card in cards {
            let name = fold("\(card.firstName) \(card.lastName)")
            let cardKeys = Set(card.handles.map(HandleNormalizer.normalize).filter { !$0.isEmpty })
            let matches = out.indices.filter { names[$0] == name && !keys[$0].isDisjoint(with: cardKeys) }
            guard let first = matches.first else {
                out.append(card)
                names.append(name)
                keys.append(cardKeys)
                continue
            }
            var merged = out[first]
            var seen = Set<String>()
            var handles: [String] = []
            for other in matches.dropFirst().map({ out[$0] }) + [card] {
                if merged.nickname == nil { merged.nickname = other.nickname }
                merged.handles += other.handles
            }
            for h in merged.handles {
                let key = HandleNormalizer.normalize(h)
                if key.isEmpty || seen.insert(key).inserted { handles.append(h) }
            }
            merged.handles = handles
            out[first] = merged
            keys[first] = matches.reduce(cardKeys) { $0.union(keys[$1]) }
            for i in matches.dropFirst().reversed() {
                out.remove(at: i)
                names.remove(at: i)
                keys.remove(at: i)
            }
        }
        return out
    }

    /// Nickname, else first name, else last name. Nil for a card with no names.
    static func baseName(_ card: ContactCard) -> String? {
        if let n = card.nickname, !n.isEmpty { return n }
        if !card.firstName.isEmpty { return card.firstName }
        if !card.lastName.isEmpty { return card.lastName }
        return nil
    }

    /// NFC, lowercased, trimmed: how names are compared.
    static func fold(_ s: String) -> String {
        s.precomposedStringWithCanonicalMapping.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
