import Foundation
import XCTest
import IMCore
@testable import IMStore
import IMTestSupport

/// Contacts behind target resolution (checklist item 10): the AddressBook reader, the JSON fixture reader,
/// handle normalization and the name rules.
final class ContactsTests: XCTestCase {
    // MARK: AddressBook

    func testAddressBookReadsCardsAndTheMeCard() throws {
        let dir = TempDir.make()
        try AddressBookFixture.make(in: dir)
        let source = AddressBookContacts(sourcesDir: dir)
        let cards = try source.cards()
        XCTAssertEqual(cards, [
            ContactCard(firstName: "Meera", lastName: "Desai", nickname: "Mom", handles: ["(415) 555-0101"]),
            ContactCard(firstName: "Acme Plumbing", lastName: "", nickname: nil, handles: ["415.555.0177"]),
            ContactCard(firstName: "Jordan", lastName: "Kim", nickname: nil, handles: ["Jordan.Kim@Example.com"]),
        ])
        XCTAssertEqual(try source.ownerHandles(), ["+1 (415) 555-0100", "alex@example.com"])
    }

    func testOlderSchemaWithoutTheMeColumnStillReads() throws {
        let dir = TempDir.make()
        try AddressBookFixture.make(in: dir, withMeColumn: false)
        let source = AddressBookContacts(sourcesDir: dir)
        XCTAssertEqual(try source.cards().map(\.firstName), ["Alex", "Meera", "Acme Plumbing", "Jordan"])
        XCTAssertEqual(try source.ownerHandles(), [])
    }

    func testOrganizationFillsOnlyAnEmptyName() throws {
        let dir = TempDir.make()
        try AddressBookFixture.make(in: dir, records: [(1, nil, "Lee", nil, "Acme", false), (2, nil, nil, "Bo", "Acme", false),
                                                       (3, "", "", "", "Shop", false)],
                                    phones: [(1, "1"), (2, "2"), (3, "3")], emails: [])
        let cards = try AddressBookContacts(sourcesDir: dir).cards()
        XCTAssertEqual(cards.map(\.firstName), ["", "", "Shop"])
        XCTAssertEqual(cards.map(\.lastName), ["Lee", "", ""])
        XCTAssertEqual(cards.map(\.nickname), [nil, "Bo", nil])
    }

    func testSourcesMergeInNameOrderAndBrokenOnesAreSkipped() throws {
        let dir = TempDir.make()
        try AddressBookFixture.make(in: dir, source: "B", records: [(1, "Bea", nil, nil, nil, false)],
                                    phones: [(1, "+14155550111")], emails: [])
        try AddressBookFixture.make(in: dir, source: "A", records: [(1, "Ann", nil, nil, nil, false)],
                                    phones: [(1, "+14155550112")], emails: [])
        try AddressBookFixture.make(in: dir, source: ".hidden", records: [(1, "Hid", nil, nil, nil, false)],
                                    phones: [(1, "+14155550113")], emails: [])
        let broken = dir.appendingPathComponent("C", isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("not a database".utf8).write(to: broken.appendingPathComponent("AddressBook-v22.abcddb"))
        let other = dir.appendingPathComponent("D", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data().write(to: other.appendingPathComponent("AddressBook-v21.abcddb"))
        XCTAssertEqual(try AddressBookContacts(sourcesDir: dir).cards().map(\.firstName), ["Ann", "Bea"])
    }

    func testEverySourceFailingThrowsAndNoSourcesIsEmpty() throws {
        let dir = TempDir.make()
        let broken = dir.appendingPathComponent("A", isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("not a database".utf8).write(to: broken.appendingPathComponent("AddressBook-v22.abcddb"))
        XCTAssertThrowsError(try AddressBookContacts(sourcesDir: dir).cards())
        XCTAssertEqual(try AddressBookContacts(sourcesDir: TempDir.make()).cards(), [])
        XCTAssertEqual(try AddressBookContacts(sourcesDir: TempDir.make().appendingPathComponent("none")).cards(), [])
    }

    func testAddressBookIsReadWithoutWriting() throws {
        let dir = TempDir.make()
        let url = try AddressBookFixture.make(in: dir)
        let before = try Data(contentsOf: url)
        _ = try AddressBookContacts(sourcesDir: dir).cards()
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path),
                       ["AddressBook-v22.abcddb"])
    }

    func testCardsLoadOnceAndConcurrentReadsAgree() throws {
        let dir = TempDir.make()
        let url = try AddressBookFixture.make(in: dir)
        let source = AddressBookContacts(sourcesDir: dir)
        let mismatches = Counter()
        let first = try source.cards()
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            if (try? source.cards()) != first { mismatches.add() }
        }
        XCTAssertEqual(mismatches.value, 0)
        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(try source.cards(), first)
    }

    func testContactBookOverTheAddressBook() throws {
        let dir = TempDir.make()
        try AddressBookFixture.make(in: dir)
        let book = try ContactBook(source: AddressBookContacts(sourcesDir: dir))
        XCTAssertEqual(book.shortName(for: "+14155550101"), "Mom")
        XCTAssertEqual(book.shortName(for: "+14155550177"), "Acme Plumbing")
        XCTAssertEqual(book.shortName(for: "jordan.kim@example.com"), "Jordan")
        XCTAssertEqual(book.shortName(for: "+14155550100"), "You")
        XCTAssertTrue(book.isOwner("ALEX@example.com"))
        XCTAssertEqual(book.ownerHandles, ["+14155550100", "alex@example.com"])
        XCTAssertNil(book.card(for: "+14155550199"))
    }

    /// The same person in two AddressBook sources (iCloud and On My Mac) is one card: one chat for the name and
    /// one `who` entry with the handle once.
    func testSamePersonInTwoSourcesIsOneCard() throws {
        let dir = TempDir.make()
        try AddressBookFixture.make(in: dir, source: "A", records: [(1, "Priya", "Shah", nil, nil, false)],
                                    phones: [(1, "+1 (555) 123-4567")], emails: [])
        try AddressBookFixture.make(in: dir, source: "B", records: [(1, "Priya", "Shah", "Pri", nil, false)],
                                    phones: [(1, "5551234567")], emails: [(1, "priya@example.com")])
        let copy = try FixtureCopy()
        try copy.exec("INSERT INTO handle (ROWID, id, service) VALUES (60, '+15551234567', 'iMessage')")
        try copy.insertChat(rowid: 70, guid: "iMessage;-;+15551234567", identifier: "+15551234567",
                            service: "iMessage", handles: [60])
        try copy.insertMessage(rowid: 41600, guid: "PRIYA-1", chat: 70, handle: 60, text: "hi", fromMe: false,
                               date: Fixture.nowNs - 1_000_000_000)
        let book = try ContactBook(source: AddressBookContacts(sourcesDir: dir))
        XCTAssertEqual(book.cards(named: "Priya"), [ContactCard(firstName: "Priya", lastName: "Shah", nickname: "Pri",
                                                                handles: ["+1 (555) 123-4567", "priya@example.com"])])
        let db = try ChatDatabase(configuration: TestStore.configuration(db: copy.path), contacts: book,
                                  clock: FakeClock())
        XCTAssertEqual(try db.resolve("Priya").chatRowIDs, [70])
        XCTAssertEqual(try db.resolve("Priya Shah").chatRowIDs, [70])
        let who = try ReadService(db: db).contacts(ContactsArgs(name: "Priya"))
        XCTAssertEqual(who.contacts.count, 1)
        XCTAssertEqual(who.contacts.first?.handles.map(\.id), ["+15551234567", "priya@example.com"])
        XCTAssertEqual(who.contacts.first?.chats.map(\.rowid), [70])
    }

    func testCardsMergeOnlyWithTheSameNameAndASharedHandle() {
        let a = ContactCard(firstName: "Sam", lastName: "Lee", nickname: nil, handles: ["+14155550120"])
        let b = ContactCard(firstName: "sam", lastName: "LEE ", nickname: nil, handles: ["(415) 555-0121"])
        let c = ContactCard(firstName: "Sam", lastName: "Lee", nickname: "S", handles: ["415 555 0120", "4155550121"])
        let other = ContactCard(firstName: "Sam", lastName: "Park", nickname: nil, handles: ["+14155550120"])
        XCTAssertEqual(ContactBook.merged([a, other]), [a, other])
        XCTAssertEqual(ContactBook.merged([a, b]), [a, b])
        XCTAssertEqual(ContactBook.merged([a, b, c]),
                       [ContactCard(firstName: "Sam", lastName: "Lee", nickname: "S",
                                    handles: ["+14155550120", "(415) 555-0121"])])
    }

    // MARK: JSON fixture

    func testJSONContactsErrors() throws {
        let missing = TempDir.make().appendingPathComponent("none.json")
        XCTAssertThrowsError(try JSONContacts(url: missing).cards()) { error in
            XCTAssertEqual(error as? StoreError, .notFound(missing.path))
        }
        for body in ["not json", "{}", "{\"people\": [{\"first\": \"A\"}]}", "[]"] {
            let url = TempDir.make().appendingPathComponent("c.json")
            try Data(body.utf8).write(to: url)
            XCTAssertThrowsError(try JSONContacts(url: url).cards(), body) { error in
                guard case StoreError.decode = error else { return XCTFail("\(error)") }
            }
        }
        let url = TempDir.make().appendingPathComponent("c.json")
        try Data("{\"people\": [{\"first\": \"A\", \"nickname\": \"\", \"handles\": [\"1\"]}]}".utf8).write(to: url)
        XCTAssertEqual(try JSONContacts(url: url).cards(), [ContactCard(firstName: "A", lastName: "", nickname: nil,
                                                                         handles: ["1"])])
        XCTAssertEqual(try JSONContacts(url: url).ownerHandles(), [])
    }

    func testFirstNameVariantResolvesParents() throws {
        let book = try TestStore.contacts(Fixture.contactsFirstNameJSON)
        XCTAssertEqual(book.shortName(for: "+14155550101"), "Mom")
        XCTAssertEqual(book.shortName(for: "+14155550102"), "Dad")
        XCTAssertNil(book.fullName(for: "+14155550199"))
        XCTAssertEqual(book.fullName(for: "+14155550101"), "Mom")
        let db = try TestStore.database(contacts: Fixture.contactsFirstNameJSON)
        XCTAssertEqual(try db.resolve("Mom").primaryChatRowID, 7)
        XCTAssertEqual(try db.resolve("dad").primaryChatRowID, 9)
        XCTAssertEqual(try db.resolve("Mom").label, "Mom")
    }

    // MARK: Handles and names

    func testHandleNormalization() {
        XCTAssertEqual(HandleNormalizer.normalize(" Alex@Example.COM "), "alex@example.com")
        XCTAssertEqual(HandleNormalizer.normalize("(415) 555-0101"), "+14155550101")
        XCTAssertEqual(HandleNormalizer.normalize("4155550101"), "+14155550101")
        XCTAssertEqual(HandleNormalizer.normalize("+1 415.555.0101"), "+14155550101")
        XCTAssertEqual(HandleNormalizer.normalize("+44 20 7946 0958"), "+442079460958")
        XCTAssertEqual(HandleNormalizer.normalize("urn:biz:1234567890"), "urn:biz:1234567890")
        XCTAssertEqual(HandleNormalizer.normalize("12345"), "+12345")
        XCTAssertEqual(HandleNormalizer.normalize(""), "")
        XCTAssertEqual(HandleNormalizer.normalize("---"), "---")
        XCTAssertEqual(HandleNormalizer.normalize("\u{FF14}\u{FF11}\u{FF15}"), "\u{FF14}\u{FF11}\u{FF15}")
    }

    func testPhoneFormatting() {
        XCTAssertEqual(HandleNormalizer.formatPhone("+14155550101"), "+1 (415) 555-0101")
        XCTAssertEqual(HandleNormalizer.formatPhone("+442079460958"), "+442079460958")
        XCTAssertEqual(HandleNormalizer.formatPhone("24155550101"), "24155550101")
        XCTAssertEqual(HandleNormalizer.formatPhone("a1415555010@example.com"), "a1415555010@example.com")
        XCTAssertEqual(HandleNormalizer.formatForWho("+14155550101"), "+1 415-555-0101")
        XCTAssertEqual(HandleNormalizer.formatForWho("pat@example.com"), "pat@example.com")
    }

    func testShortNamesAndClashes() throws {
        let url = try contactsFile(people: [("Sam", "Lee", nil, ["+16505550142"]), ("Sam", "Ortiz", nil, ["+16505550143"]),
                                            ("Kai", "", "K", ["kai@example.com"]), ("", "Nguyen", nil, ["+16505550144"])])
        let book = try TestStore.contacts(url)
        XCTAssertEqual(book.shortName(for: nil), "Unknown")
        XCTAssertEqual(book.shortName(for: "+14155550100"), "You")
        XCTAssertEqual(book.shortName(for: "+16505550142"), "Sam")
        XCTAssertEqual(book.shortName(for: "+16505550142", among: ["+16505550142", "+16505550143"]), "Sam L")
        XCTAssertEqual(book.shortName(for: "+16505550143", among: ["+16505550142", "+16505550143"]), "Sam O")
        XCTAssertEqual(book.shortName(for: "+16505550142", among: ["+16505550142", "kai@example.com"]), "Sam")
        XCTAssertEqual(book.shortName(for: "KAI@example.com"), "K")
        XCTAssertEqual(book.shortName(for: "+16505550144"), "Nguyen")
        XCTAssertEqual(book.shortName(for: "+16505550199"), "+1 (650) 555-0199")
        XCTAssertEqual(book.shortName(for: "who@example.com"), "who@example.com")
        XCTAssertEqual(book.cards(named: " sam ").count, 2)
        XCTAssertEqual(book.cards(named: "SAM LEE").map(\.lastName), ["Lee"])
        XCTAssertEqual(book.cards(named: "k").map(\.firstName), ["Kai"])
        XCTAssertEqual(book.cards(named: ""), [])
    }

    func testNamesCompareInNFC() throws {
        let url = try contactsFile(people: [("Jos\u{E9}", "Ruiz", nil, ["+16505550150"])])
        let book = try TestStore.contacts(url)
        XCTAssertEqual(book.cards(named: "jose\u{301}").count, 1)
        XCTAssertEqual(book.cards(named: "JOS\u{C9} RUIZ").count, 1)
    }

    func testOwnerHandlesGrowSafelyUnderConcurrency() throws {
        let book = try TestStore.contacts()
        DispatchQueue.concurrentPerform(iterations: 100) { i in
            book.addOwnerHandles(["+1650555\(String(format: "%04d", i))", ""])
            _ = book.isOwner("+16505550000")
        }
        XCTAssertEqual(book.ownerHandles.count, 102)
        XCTAssertTrue(book.isOwner("(650) 555-0042"))
        XCTAssertFalse(book.ownerHandles.contains(""))
    }
}
