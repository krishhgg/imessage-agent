import Foundation
import SQLite3
import XCTest
import IMCore
@testable import IMStore
import IMTestSupport

/// Builds stores around the fixture or a private copy of it. Nothing here opens ~/Library/Messages.
enum TestStore {
    static func contacts(_ url: URL = Fixture.contactsJSON) throws -> ContactBook {
        try ContactBook(source: JSONContacts(url: url))
    }

    /// The region is `US` unless a test sets it, so results never depend on the Mac running the tests.
    static func configuration(db: String = Fixture.chatDB.path, root: URL = Fixture.attachmentsRoot,
                              cache: URL? = nil, rowCap: Int = Limits.defaultRowCap,
                              timeout: TimeInterval = Limits.interactiveReadTimeout,
                              searchBudget: TimeInterval = Limits.searchBudget,
                              windowDays: Int = Limits.searchWindowDays, region: String? = "US") -> StoreConfiguration {
        StoreConfiguration(chatDBPath: db, attachmentsRoot: root,
                           attachmentCacheDir: cache ?? TempDir.make().appendingPathComponent("cache"),
                           timeZone: Fixture.timeZone, rowCap: rowCap, interactiveTimeout: timeout,
                           searchBudget: searchBudget, searchWindowDays: windowDays, regionCode: region)
    }

    static func database(_ configuration: StoreConfiguration = configuration(), contacts url: URL = Fixture.contactsJSON,
                         clock: FakeClock = FakeClock()) throws -> ChatDatabase {
        try ChatDatabase(configuration: configuration, contacts: contacts(url), clock: clock)
    }

    static func reader(_ db: ChatDatabase? = nil) throws -> ReadService {
        try ReadService(db: db ?? database())
    }
}

enum TempDir {
    static func make() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("imstore-tests-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// A writable copy of the fixture database for tests that need extra rows. Triggers are dropped first because
/// they call functions that only exist inside Messages.
final class FixtureCopy {
    let dir: URL
    let path: String

    init() throws {
        dir = TempDir.make()
        path = dir.appendingPathComponent("chat.db").path
        try FileManager.default.copyItem(atPath: Fixture.chatDB.path, toPath: path)
        var names: [String] = []
        try query("SELECT name FROM sqlite_master WHERE type = 'trigger'") { names.append($0) }
        for name in names { try exec("DROP TRIGGER \"\(name)\"") }
    }

    func exec(_ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw StoreError.sqlite(code: 0, message: "open")
        }
        defer { sqlite3_close(db) }
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let message = err.map { String(cString: $0) } ?? "exec"
            sqlite3_free(err)
            throw StoreError.sqlite(code: 1, message: message)
        }
    }

    func query(_ sql: String, _ row: (String) -> Void) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw StoreError.sqlite(code: 0, message: "open")
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.sqlite(code: 2, message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            row(sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "")
        }
    }

    func database(contacts url: URL = Fixture.contactsJSON, clock: FakeClock = FakeClock(),
                  rowCap: Int = Limits.defaultRowCap, timeout: TimeInterval = Limits.interactiveReadTimeout,
                  searchBudget: TimeInterval = Limits.searchBudget, region: String? = "US") throws -> ChatDatabase {
        try TestStore.database(TestStore.configuration(db: path, rowCap: rowCap, timeout: timeout,
                                                       searchBudget: searchBudget, region: region),
                               contacts: url, clock: clock)
    }
}

/// manifest.json, read as loose JSON.
enum Manifest {
    static let json: [String: Any] = {
        let data = try! Data(contentsOf: Fixture.manifest)
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }()

    static func edge(_ name: String) -> [Int64] {
        let cases = json["edge_cases"] as! [String: Any]
        return (cases[name] as! [NSNumber]).map(\.int64Value)
    }

    static func first(_ name: String) -> Int64 { edge(name)[0] }
}

/// Finds a message record in a `read` page by ROWID.
extension MessagesPage {
    func message(_ rowid: Int64) -> MessageRecord? { messages.first { $0.rowid == rowid } }
}

/// A synthetic AddressBook source database with the three tables `AddressBookContacts` reads.
enum AddressBookFixture {
    /// Writes `<dir>/<source>/AddressBook-v22.abcddb` and returns its URL. `dir` stands in for the Sources folder.
    @discardableResult
    static func make(in dir: URL, source: String = "A1", withMeColumn: Bool = true,
                     records: [(pk: Int, first: String?, last: String?, nickname: String?, org: String?, me: Bool)]
                         = defaultRecords,
                     phones: [(owner: Int, number: String)] = defaultPhones,
                     emails: [(owner: Int, address: String)] = defaultEmails) throws -> URL {
        let folder = dir.appendingPathComponent(source, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("AddressBook-v22.abcddb")
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw StoreError.sqlite(code: 0, message: "open") }
        defer { sqlite3_close(db) }
        func exec(_ sql: String, _ values: [String?] = []) throws {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw StoreError.sqlite(code: 1, message: String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (i, v) in values.enumerated() {
                if let v { sqlite3_bind_text(stmt, Int32(i + 1), v, -1, transient) } else { sqlite3_bind_null(stmt, Int32(i + 1)) }
            }
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw StoreError.sqlite(code: 2, message: String(cString: sqlite3_errmsg(db)))
            }
        }
        let meColumn = withMeColumn ? ", ZCONTAINERWHERECONTACTISME INTEGER" : ""
        try exec("CREATE TABLE ZABCDRECORD (Z_PK INTEGER PRIMARY KEY, ZFIRSTNAME VARCHAR, ZLASTNAME VARCHAR, "
                 + "ZNICKNAME VARCHAR, ZORGANIZATION VARCHAR\(meColumn))")
        try exec("CREATE TABLE ZABCDPHONENUMBER (Z_PK INTEGER PRIMARY KEY, ZOWNER INTEGER, ZFULLNUMBER VARCHAR)")
        try exec("CREATE TABLE ZABCDEMAILADDRESS (Z_PK INTEGER PRIMARY KEY, ZOWNER INTEGER, ZADDRESS VARCHAR)")
        for r in records {
            if withMeColumn {
                try exec("INSERT INTO ZABCDRECORD VALUES (?, ?, ?, ?, ?, ?)",
                         [String(r.pk), r.first, r.last, r.nickname, r.org, r.me ? "1" : nil])
            } else {
                try exec("INSERT INTO ZABCDRECORD VALUES (?, ?, ?, ?, ?)", [String(r.pk), r.first, r.last, r.nickname, r.org])
            }
        }
        for p in phones { try exec("INSERT INTO ZABCDPHONENUMBER (ZOWNER, ZFULLNUMBER) VALUES (?, ?)", [String(p.owner), p.number]) }
        for e in emails { try exec("INSERT INTO ZABCDEMAILADDRESS (ZOWNER, ZADDRESS) VALUES (?, ?)", [String(e.owner), e.address]) }
        return url
    }

    static let defaultRecords: [(pk: Int, first: String?, last: String?, nickname: String?, org: String?, me: Bool)] = [
        (1, "Alex", "Rivera", nil, nil, true),
        (2, "Meera", "Desai", "Mom", nil, false),
        (3, nil, nil, nil, "Acme Plumbing", false),
        (4, "Nobody", "Handles", nil, nil, false),
        (5, "Jordan", "Kim", nil, nil, false),
    ]
    static let defaultPhones: [(owner: Int, number: String)] = [
        (1, "+1 (415) 555-0100"), (2, "(415) 555-0101"), (3, "415.555.0177"),
    ]
    static let defaultEmails: [(owner: Int, address: String)] = [(1, "alex@example.com"), (5, "Jordan.Kim@Example.com")]
}

extension FixtureCopy {
    /// Adds a message joined to `chat`. Dates are Apple nanoseconds.
    func insertMessage(rowid: Int64, guid: String, chat: Int64, handle: Int64, text: String?, fromMe: Bool,
                       date: Int64, isRead: Bool = true, service: String = "iMessage", associatedType: Int = 0,
                       associatedGUID: String? = nil, emoji: String? = nil) throws {
        let t = text.map { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" } ?? "NULL"
        let ag = associatedGUID.map { "'\($0)'" } ?? "NULL"
        let em = emoji.map { "'\($0)'" } ?? "NULL"
        try exec("""
            INSERT INTO message (ROWID, guid, text, handle_id, service, date, is_from_me, is_read, item_type,
                associated_message_type, associated_message_guid, associated_message_emoji)
            VALUES (\(rowid), '\(guid)', \(t), \(handle), '\(service)', \(date), \(fromMe ? 1 : 0), \(isRead ? 1 : 0), 0,
                \(associatedType), \(ag), \(em));
            INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (\(chat), \(rowid), \(date));
            """)
    }

    func insertChat(rowid: Int64, guid: String, identifier: String, service: String, style: Int = 45,
                    displayName: String = "", handles: [Int64]) throws {
        try exec("""
            INSERT INTO chat (ROWID, guid, style, chat_identifier, service_name, display_name, account_login,
                last_addressed_handle) VALUES (\(rowid), '\(guid)', \(style), '\(identifier)', '\(service)',
                '\(displayName)', 'P:+14155550100', '+14155550100');
            """)
        for h in handles { try exec("INSERT INTO chat_handle_join (chat_id, handle_id) VALUES (\(rowid), \(h))") }
    }
}

extension ReadService {
    /// Every visible row of a conversation, oldest first, by paging `read` backwards.
    func allVisible(_ who: String) throws -> [MessageRecord] {
        var out: [MessageRecord] = []
        var page = try messages(MessagesArgs(who: who, limit: 200))
        out = page.messages
        while page.olderExists, let first = page.messages.first {
            page = try messages(MessagesArgs(who: who, limit: 200, before: first.rowid))
            out = page.messages + out
        }
        return out
    }
}

/// Writes contacts JSON in the fixture format and returns its URL.
func contactsFile(owner: [String] = Fixture.ownerHandles,
                  people: [(first: String, last: String, nickname: String?, handles: [String])]) throws -> URL {
    let list: [[String: Any]] = people.map { p in
        var d: [String: Any] = ["first": p.first, "last": p.last, "handles": p.handles]
        if let n = p.nickname { d["nickname"] = n }
        return d
    }
    let json: [String: Any] = ["owner": ["first": "Alex", "handles": owner], "people": list]
    let url = TempDir.make().appendingPathComponent("contacts.json")
    try JSONSerialization.data(withJSONObject: json).write(to: url)
    return url
}

/// ROWIDs of chat.db rows matching fixed SQL on the fixture.
func fixtureRowIDs(_ sql: String) throws -> [Int64] {
    let conn = try SQLiteConnection(readOnlyPath: Fixture.chatDB.path)
    defer { conn.close() }
    var out: [Int64] = []
    try conn.query(sql, [.int(100_000)]) { out.append($0.int(0)) }
    return out
}
