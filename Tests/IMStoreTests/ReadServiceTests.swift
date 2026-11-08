import Foundation
import XCTest
import IMCore
@testable import IMStore
import IMTestSupport

/// Checklist items 9 to 11 and the read verbs: visibility, target resolution, chats, unread, read and show.
final class ReadServiceTests: XCTestCase {
    private var reader: ReadService!

    override func setUpWithError() throws {
        reader = try TestStore.reader()
    }

    // MARK: Item 9, visibility

    func testTapbackAndPlacedStickerRowsNeverAppear() throws {
        let hidden = try fixtureRowIDs("SELECT ROWID FROM message WHERE associated_message_type BETWEEN 2000 AND 3999 "
                                       + "OR associated_message_type = 1000 LIMIT ?")
        XCTAssertEqual(hidden.count, 90)
        for who in ["7", "9", "12", "19", "23", "31", "56", "2"] {
            let shown = Set(try reader.allVisible(who).map(\.rowid))
            XCTAssertTrue(shown.isDisjoint(with: hidden), "chat \(who)")
        }
    }

    func testPlacedStickerFoldsOntoItsTarget() throws {
        let target = try reader.message(MessageArgs(rowid: 41417)).message
        XCTAssertEqual(target.stickers.map(\.rowid), [Manifest.first("placed_sticker")])
        XCTAssertEqual(target.stickers.first?.actorName, "Arjun")
        XCTAssertEqual(target.stickers.first?.part, 0)
        XCTAssertTrue(target.reactions.isEmpty)
    }

    func testStickerMessageStaysVisible() throws {
        let all = try reader.allVisible("12")
        let sticker = try XCTUnwrap(all.first { $0.rowid == Manifest.first("sticker") })
        XCTAssertEqual(sticker.attachments.first?.kind, .sticker)
    }

    func testSelfChatEchoesAreDroppedAndOriginalsKept() throws {
        let shown = Set(try reader.allVisible("2").map(\.rowid))
        let echoes = Manifest.edge("self_echo_assumed")
        XCTAssertEqual(echoes.count, 17)
        XCTAssertTrue(shown.isDisjoint(with: echoes))
        XCTAssertTrue(Set(Manifest.edge("self_echo_original")).isSubset(of: shown))
    }

    func testEchoRuleOnlyAppliesToTheSelfChat() throws {
        let copy = try FixtureCopy()
        let t = Fixture.nowNs - 120_000_000_000
        try copy.insertMessage(rowid: 41600, guid: "ECHO-OUT", chat: 7, handle: 3, text: "same words", fromMe: true, date: t)
        try copy.insertMessage(rowid: 41601, guid: "ECHO-IN", chat: 7, handle: 3, text: "same words", fromMe: false,
                               date: t + 1_000_000_000)
        try copy.insertMessage(rowid: 41602, guid: "SELF-OUT", chat: 2, handle: 1, text: "note words", fromMe: true, date: t)
        try copy.insertMessage(rowid: 41603, guid: "SELF-IN", chat: 2, handle: 1, text: "note words", fromMe: false,
                               date: t + 1_000_000_000)
        let r = ReadService(db: try copy.database())
        XCTAssertEqual(try r.messages(MessagesArgs(who: "Mom", limit: 2)).messages.map(\.rowid), [41600, 41601])
        XCTAssertEqual(try r.messages(MessagesArgs(who: "2", limit: 1)).messages.map(\.rowid), [41602])
    }

    func testURLBalloonDuplicateMergesIntoTheTextRow() throws {
        let rows = Manifest.edge("link_preview_two_rows")
        let all = try reader.allVisible("19")
        let text = try XCTUnwrap(all.first { $0.rowid == rows[0] })
        XCTAssertNil(all.first { $0.rowid == rows[1] })
        XCTAssertEqual(text.link?.url, "https://blog.example.org/posts/cabin-checklist")
        XCTAssertEqual(text.link?.title, "The Cabin Checklist: 31 Things to Pack")
        let single = try XCTUnwrap(try reader.allVisible("12").first { $0.rowid == Manifest.first("link_preview_single_row") })
        XCTAssertEqual(single.link?.title, "A Guide to Diwali Sweets, From Barfi to Jalebi")
        let bare = try reader.message(MessageArgs(rowid: Manifest.first("link_without_preview"))).message
        XCTAssertNil(bare.link)
    }

    func testURLBalloonMergeWindowIsFiveSeconds() throws {
        let rows = Manifest.edge("link_preview_two_rows")
        let first: Int64 = 796_962_000_507_281_000
        for (offset, merged) in [(Int64(5_000_000_000), true), (Int64(5_000_000_001), false)] {
            let copy = try FixtureCopy()
            try copy.exec("UPDATE message SET date = \(first + offset) WHERE ROWID = \(rows[1])")
            let all = try ReadService(db: try copy.database()).allVisible("19")
            XCTAssertEqual(all.first { $0.rowid == rows[1] } == nil, merged, "offset \(offset)")
            XCTAssertEqual(all.first { $0.rowid == rows[0] }?.link != nil, merged, "offset \(offset)")
        }
    }

    func testRecentlyDeletedRowIsSkipped() throws {
        let deleted = Manifest.first("recently_deleted")
        XCTAssertNil(try reader.allVisible("12").first { $0.rowid == deleted })
        XCTAssertThrowsError(try reader.message(MessageArgs(rowid: deleted))) {
            XCTAssertEqual($0 as? StoreError, .notFound("message \(deleted)"))
        }
        let changes = try reader.changes(ChangesArgs(since: ChangeCursor(rowid: deleted - 1, timeNs: Fixture.nowNs).text))
        XCTAssertFalse(changes.changes.contains { $0.message.rowid == deleted })
    }

    func testTotalVisibleCountsWhatReadShows() throws {
        for who in ["7", "9", "12", "19", "23", "31", "56", "2"] {
            let page = try reader.messages(MessagesArgs(who: who, limit: 1))
            XCTAssertEqual(page.totalVisible, try reader.allVisible(who).count, "chat \(who)")
        }
    }

    // MARK: Item 10, target resolution

    func testEveryTargetFormResolves() throws {
        let db = try TestStore.database()
        let cases: [(String, Int64)] = [
            ("Mom", 7), ("mom", 7), ("Meera", 7), ("Meera Desai", 7), ("+14155550101", 7), ("+1 (415) 555-0101", 7),
            ("415-555-0101", 7), ("4155550101", 7), ("7", 7), ("any;-;+14155550101", 7),
            ("jordan.kim@example.com", 23), ("JORDAN.KIM@EXAMPLE.COM", 23), ("Jordan", 23),
            ("chat836828054889214904", 12), ("Fam", 12), ("family 🏡", 12), ("12", 12), ("Jordan, Taylor", 19),
            ("+15105550163", 56), ("Sam", 31), ("2", 2), ("+14155550100", 2),
        ]
        for (who, chat) in cases {
            XCTAssertEqual(try db.resolve(who).primaryChatRowID, chat, who)
        }
    }

    func testResolvedChatCarriesSendFields() throws {
        let db = try TestStore.database()
        let mom = try db.resolve("Mom")
        XCTAssertEqual(mom.canonical, .direct(handle: "+14155550101"))
        XCTAssertEqual(mom.sendHandle, "+14155550101")
        XCTAssertEqual(mom.service, "iMessage")
        XCTAssertEqual(mom.handles, ["+14155550101"])
        XCTAssertFalse(mom.isGroup)
        let group = try db.resolve("12")
        XCTAssertEqual(group.canonical, .group(identifier: "chat836828054889214904"))
        XCTAssertNil(group.sendHandle)
        XCTAssertTrue(group.isGroup)
        XCTAssertEqual(Set(group.handles), ["+14155550101", "+14155550102", "+14155550103", "+14155550104"])
    }

    func testIMessageAndSMSChatsAreOneConversation() throws {
        let copy = try FixtureCopy()
        try copy.insertChat(rowid: 90, guid: "SMS;-;+14155550101", identifier: "+14155550101", service: "SMS", handles: [8])
        try copy.insertMessage(rowid: 41600, guid: "MOM-SMS", chat: 90, handle: 8, text: "sms from mom", fromMe: false,
                               date: Fixture.nowNs - 60_000_000_000, isRead: false, service: "SMS")
        let db = try copy.database()
        let mom = try db.resolve("Mom")
        XCTAssertEqual(mom.chatRowIDs, [90, 7])
        XCTAssertEqual(mom.primaryChatRowID, 90)
        XCTAssertEqual(mom.service, "SMS")
        XCTAssertEqual(try db.resolve("+14155550101").canonical, mom.canonical)
        XCTAssertEqual(try db.resolve("7").canonical, mom.canonical)
        XCTAssertEqual(try db.resolve(chatRowID: 7)?.chatRowIDs, [90, 7])

        let r = ReadService(db: db)
        let chats = try r.chats(ChatsArgs(limit: 50))
        let moms = chats.chats.filter { $0.canonical == mom.canonical }
        XCTAssertEqual(moms.count, 1)
        XCTAssertEqual(moms.first?.mergedChatRowIDs, [90, 7])
        XCTAssertEqual(moms.first?.unreadCount, 3)
        XCTAssertEqual(chats.chats.first?.rowid, 90)
        XCTAssertEqual(try r.messages(MessagesArgs(who: "Mom", limit: 2)).messages.map(\.rowid), [41556, 41600])
        let unread = try r.unread(UnreadArgs(context: 0))
        XCTAssertEqual(unread.groups.first?.entries.map(\.message.rowid), [41555, 41556, 41600])
    }

    func testTwoMatchingContactsThrowSeveralMatches() throws {
        let url = try contactsFile(people: [("Sam", "Lee", nil, ["+16505550142"]), ("Sam", "Ortiz", nil, ["+14155550104"])])
        let db = try TestStore.database(contacts: url)
        XCTAssertThrowsError(try db.resolve("Sam")) { error in
            guard case StoreError.severalMatches(let candidates) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(candidates.map(\.label), ["Sam Lee", "Sam Ortiz"])
            XCTAssertEqual(candidates.map(\.argument), ["+16505550142", "+14155550104"])
        }
        XCTAssertThrowsError(try ReadService(db: db).messages(MessagesArgs(who: "Sam"))) { error in
            guard case StoreError.severalMatches = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try db.resolve("Sam Lee").primaryChatRowID, 31)
    }

    func testOneContactWithTwoConversationsThrowsSeveralMatches() throws {
        let url = try contactsFile(people: [("Pat", "Two", nil, ["+14155550102", "+16505550142"])])
        let db = try TestStore.database(contacts: url)
        XCTAssertThrowsError(try db.resolve("Pat")) { error in
            guard case StoreError.severalMatches(let candidates) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(candidates.map(\.argument), ["31", "9"])
        }
    }

    /// Section 5 merges a contact's iMessage and SMS chats on one handle. Chats on different handles of one card,
    /// here Jordan's email on iMessage and a phone on SMS, stay separate, so the name gives several matches with
    /// each chat and nothing runs. That is the safe reading.
    func testOneContactWithChatsOnDifferentHandlesThrowsSeveralMatches() throws {
        let url = try contactsFile(people: [("Jordan", "Kim", nil, ["jordan.kim@example.com", "+15105550163"])])
        let db = try TestStore.database(contacts: url)
        XCTAssertThrowsError(try db.resolve("Jordan")) { error in
            guard case StoreError.severalMatches(let candidates) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(Set(candidates.map(\.argument)), ["23", "56"])
        }
        XCTAssertEqual(try db.resolve("jordan.kim@example.com").service, "iMessage")
        XCTAssertEqual(try db.resolve("+15105550163").service, "SMS")
    }

    func testTwoMatchingGroupsThrowSeveralMatches() throws {
        let copy = try FixtureCopy()
        try copy.insertChat(rowid: 91, guid: "any;+;chat111", identifier: "chat111", service: "iMessage", style: 43,
                            displayName: "Family trip", handles: [3, 4])
        let db = try copy.database()
        XCTAssertThrowsError(try db.resolve("Family")) { error in
            guard case StoreError.severalMatches(let candidates) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(Set(candidates.map(\.argument)), ["12", "91"])
        }
        XCTAssertEqual(try db.resolve("Family trip").primaryChatRowID, 91)
    }

    func testUnknownTargetsThrowNoMatch() throws {
        let url = try contactsFile(people: [("Zed", "Blank", nil, [])])
        let db = try TestStore.database(contacts: url)
        for who in ["Nobody", "", "   ", "9999", "555-0199", "12345678", "+0123456789", "bob@home", "a@b@example.com",
                    "Zed"] {
            XCTAssertThrowsError(try db.resolve(who), who) { error in
                guard case StoreError.noMatch = error else { return XCTFail("\(who): \(error)") }
            }
        }
    }

    func testNoMatchFixNamesWhatToPass() {
        XCTAssertEqual(StoreError.noMatchFix(for: "9999"), "imessage chats")
        XCTAssertEqual(StoreError.noMatchFix(for: "bob@home"), "check the email address")
        XCTAssertEqual(StoreError.noMatchFix(for: "555-0199"),
                       "pass the whole number with + and its country code")
        XCTAssertEqual(StoreError.noMatchFix(for: "Nobody"), "pass a phone number, an email or a chat id from imessage chats")
    }

    func testChatNumberThatIsAlsoAnIdentifierThrowsSeveralMatches() throws {
        let copy = try FixtureCopy()
        try copy.insertChat(rowid: 12345, guid: "iMessage;-;+17075550131", identifier: "+17075550131",
                            service: "iMessage", handles: [22])
        try copy.insertChat(rowid: 93, guid: "SMS;-;12345", identifier: "12345", service: "SMS", handles: [])
        let db = try copy.database()
        XCTAssertThrowsError(try db.resolve("12345")) { error in
            guard case StoreError.severalMatches(let candidates) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(Set(candidates.map(\.argument)), ["iMessage;-;+17075550131", "93"])
        }
        XCTAssertEqual(try db.resolve("iMessage;-;+17075550131").primaryChatRowID, 12345)
        XCTAssertEqual(try db.resolve("93").primaryChatRowID, 93)
    }

    func testContactNameThatIsAlsoInAGroupNameThrowsSeveralMatches() throws {
        let copy = try FixtureCopy()
        try copy.insertChat(rowid: 92, guid: "any;+;chat222", identifier: "chat222", service: "iMessage", style: 43,
                            displayName: "Mom & Dad", handles: [3, 4])
        let db = try copy.database()
        XCTAssertThrowsError(try db.resolve("Mom")) { error in
            guard case StoreError.severalMatches(let candidates) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(Set(candidates.map(\.argument)), ["7", "92"])
            XCTAssertEqual(Set(candidates.map(\.label)), ["Mom +1 415-555-0101", "Mom & Dad"])
        }
        XCTAssertEqual(try db.resolve("Meera Desai").primaryChatRowID, 7)
        XCTAssertEqual(try db.resolve("Mom & Dad").primaryChatRowID, 92)
    }

    /// A group display name matches text that starts one of its words, and a chat number never matches a display
    /// name, so the numbers `imessage chats` prints and contact names inside a longer word keep working.
    func testGroupNamesMatchOnWordStartsAndNeverTakeAChatNumber() throws {
        let copy = try FixtureCopy()
        try copy.insertChat(rowid: 95, guid: "any;+;chat333", identifier: "chat333", service: "iMessage", style: 43,
                            displayName: "Class of 2012", handles: [3, 4])
        try copy.insertChat(rowid: 96, guid: "any;+;chat444", identifier: "chat444", service: "iMessage", style: 43,
                            displayName: "Grandad 80th", handles: [3, 4])
        try copy.insertChat(rowid: 97, guid: "any;+;chat555", identifier: "chat555", service: "iMessage", style: 43,
                            displayName: "Team 7", handles: [3, 4])
        let db = try copy.database()
        for (who, chat) in [("2", 2), ("12", 12), ("7", 7), ("Dad", 9), ("Class", 95), ("class of", 95), ("of 2012", 95),
                            ("Grand", 96), ("80th", 96), ("Team", 97), ("Fam", 12)] as [(String, Int64)] {
            XCTAssertEqual(try db.resolve(who).primaryChatRowID, chat, who)
        }
        XCTAssertEqual(try ReadService(db: db).messages(MessagesArgs(who: "12", limit: 1)).chat.rowid, 12)
        for who in ["2012", "80", "ad", "lass", "andad"] {
            XCTAssertThrowsError(try db.resolve(who), who) { error in
                guard case StoreError.noMatch = error else { return XCTFail("\(who): \(error)") }
            }
        }
    }

    // MARK: New direct targets (section 5)

    func testPhoneOrEmailWithNoChatIsANewDirectTarget() throws {
        let db = try TestStore.database()
        let phone = try db.resolve("+1 (999) 555-0000")
        XCTAssertEqual(phone.canonical, .direct(handle: "+19995550000"))
        XCTAssertEqual(phone.chatRowIDs, [])
        XCTAssertEqual(phone.chatGUIDs, [])
        XCTAssertEqual(phone.primaryChatRowID, 0)
        XCTAssertEqual(phone.sendHandle, "+19995550000")
        XCTAssertEqual(phone.service, "iMessage")
        XCTAssertEqual(phone.handles, ["+19995550000"])
        XCTAssertFalse(phone.isGroup)
        XCTAssertEqual(try db.resolve("9995550000").canonical, phone.canonical)
        let email = try db.resolve("Nobody@Example.com")
        XCTAssertEqual(email.canonical, .direct(handle: "nobody@example.com"))
        XCTAssertEqual(email.sendHandle, "nobody@example.com")
        XCTAssertEqual(email.chatRowIDs, [])
    }

    func testContactWithOneHandleAndNoChatIsANewDirectTarget() throws {
        let db = try TestStore.database()
        let priya = try db.resolve("Priya")
        XCTAssertEqual(priya.canonical, .direct(handle: "+14155550103"))
        XCTAssertEqual(priya.sendHandle, "+14155550103")
        XCTAssertEqual(priya.label, "Priya Desai")
        XCTAssertEqual(priya.chatRowIDs, [])
        XCTAssertEqual(try db.resolve("+14155550103").canonical, priya.canonical)
        let taylor = try db.resolve("Taylor")
        XCTAssertEqual(taylor.sendHandle, "+12125550188")
        XCTAssertEqual(taylor.chatRowIDs, [])

        XCTAssertNil(try db.conversation(for: priya))
        XCTAssertNil(try db.newestIncoming(for: priya))
        XCTAssertEqual(try db.inboundRows(in: priya, afterNs: 0, limit: 10), [])

        let page = try ReadService(db: db).messages(MessagesArgs(who: "Priya", limit: 5))
        XCTAssertEqual(page.messages, [])
        XCTAssertEqual(page.totalVisible, 0)
        XCTAssertFalse(page.olderExists)
        XCTAssertEqual(page.chat.rowid, 0)
        XCTAssertEqual(page.chat.canonical, priya.canonical)
    }

    func testContactWithSeveralHandlesAndNoChatThrowsSeveralMatches() throws {
        let url = try contactsFile(people: [("Kai", "Two", nil, ["+19995550001", "Kai@Example.com"])])
        let db = try TestStore.database(contacts: url)
        XCTAssertThrowsError(try db.resolve("Kai")) { error in
            guard case StoreError.severalMatches(let candidates) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(candidates.map(\.argument), ["+19995550001", "kai@example.com"])
        }
        XCTAssertEqual(try db.resolve("kai@example.com").sendHandle, "kai@example.com")
    }

    /// Juan is saved as 55 1234 5678 and his real chat is +525512345678. Outside a +1 region his card and the typed
    /// number give no new direct target, so nothing goes to the stranger at +15512345678, and the error names the
    /// number so its fix asks for the country code. Numbers still match existing chats as before.
    func testNumberWithoutACountryCodeIsANewDirectTargetOnlyInAPlusOneRegion() throws {
        let copy = try FixtureCopy()
        try copy.exec("INSERT INTO handle (ROWID, id, service) VALUES (40, '+525512345678', 'iMessage')")
        try copy.insertChat(rowid: 98, guid: "iMessage;-;+525512345678", identifier: "+525512345678",
                            service: "iMessage", handles: [40])
        try copy.insertMessage(rowid: 41600, guid: "JUAN-1", chat: 98, handle: 40, text: "hola", fromMe: false,
                               date: Fixture.nowNs - 60_000_000_000)
        let kai = try contactsFile(people: [("Kai", "Two", nil, ["5512340000", "Kai@Example.com"])])
        let ana = try contactsFile(people: [("Ana", "Lane", nil, ["07911 123456"])])

        for region in ["MX", "GB", nil] as [String?] {
            let db = try copy.database(contacts: Fixture.contactsLocalNumberJSON, region: region)
            for who in ["Juan", "Juan Perez"] {
                XCTAssertThrowsError(try db.resolve(who), "\(who) in \(region ?? "no region")") { error in
                    XCTAssertEqual(error as? StoreError, .noMatch("55 1234 5678"))
                }
            }
            for typed in ["55 1234 5678", "5512345678", "15512345678", "(999) 555-0000"] {
                XCTAssertThrowsError(try db.resolve(typed), typed) { error in
                    XCTAssertEqual(error as? StoreError, .noMatch(typed))
                }
                XCTAssertEqual(StoreError.noMatchFix(for: typed),
                               "pass the whole number with + and its country code")
            }
            XCTAssertEqual(try db.resolve("+52 55 1234 5678").primaryChatRowID, 98)
            XCTAssertEqual(try db.resolve("+52 55 8765 4321").sendHandle, "+525587654321")
            XCTAssertEqual(try db.resolve("(415) 555-0101").primaryChatRowID, 7, "matching a chat is unchanged")
            XCTAssertEqual(try db.resolve("4155550102").primaryChatRowID, 9)
            XCTAssertEqual(try db.resolve("Priya").sendHandle, "+14155550103", "a saved + number still works")
            XCTAssertEqual(try db.sendTarget(canonical: .direct(handle: "+15512345678"))?.sendHandle, "+15512345678",
                           "crash recovery rebuilds a journal entry's handle as before")
            let kaiDB = try copy.database(contacts: kai, region: region)
            XCTAssertEqual(try kaiDB.resolve("Kai").sendHandle, "kai@example.com")
            XCTAssertThrowsError(try copy.database(contacts: ana, region: region).resolve("Ana")) { error in
                XCTAssertEqual(error as? StoreError, .noMatch("07911 123456"))
            }
        }

        let us = try copy.database(contacts: Fixture.contactsLocalNumberJSON, region: "US")
        let juan = try us.resolve("Juan")
        XCTAssertEqual(juan.sendHandle, "+15512345678")
        XCTAssertEqual(juan.chatRowIDs, [])
        XCTAssertEqual(juan.label, "Juan Perez")
        XCTAssertEqual(try us.resolve("55 1234 5678").sendHandle, "+15512345678")
        XCTAssertEqual(try us.resolve("15512345678").sendHandle, "+15512345678")
        XCTAssertEqual(try us.resolve("+525512345678").primaryChatRowID, 98)
        XCTAssertEqual(try copy.database(contacts: Fixture.contactsLocalNumberJSON, region: "ca").resolve("Juan"), juan)
        XCTAssertThrowsError(try copy.database(contacts: kai, region: "US").resolve("Kai")) { error in
            guard case StoreError.severalMatches(let candidates) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(candidates.map(\.argument), ["+15512340000", "kai@example.com"])
        }
        XCTAssertThrowsError(try copy.database(contacts: ana, region: "US").resolve("Ana")) { error in
            XCTAssertEqual(error as? StoreError, .noMatch("Ana"), "a +1 region keeps the error as it was")
        }
    }

    /// Two Juans in Mexico: Perez saved as 55 1234 5678, Lopez as +525511112222. Under several matches Perez is
    /// listed with his number as saved, so passing it back asks for the country code instead of making a new
    /// direct target to the stranger at +15512345678 labeled Juan Perez. A card with a chat, a + number or an
    /// email is listed with that handle. A +1 region lists the +1 number as before.
    func testSeveralContactsNeverListANumberWithoutACountryCodeAsAPlusOneNumberOutsideAPlusOneRegion() throws {
        let copy = try FixtureCopy()
        try copy.exec("INSERT INTO handle (ROWID, id, service) VALUES (40, '+525512345678', 'iMessage')")
        try copy.insertChat(rowid: 98, guid: "iMessage;-;+525512345678", identifier: "+525512345678",
                            service: "iMessage", handles: [40])
        try copy.insertMessage(rowid: 41600, guid: "JUAN-1", chat: 98, handle: 40, text: "hola", fromMe: false,
                               date: Fixture.nowNs - 60_000_000_000)
        let juans = try contactsFile(people: [("Juan", "Perez", nil, ["55 1234 5678"]),
                                              ("Juan", "Lopez", nil, ["+525511112222"]),
                                              ("Juan", "Ruiz", nil, ["5512340000", "Ruiz@Example.com"]),
                                              ("Juan", "Soto", nil, ["55 8765 4321", "+52 55 1234 5678"])])
        for region in ["MX", "GB", nil] as [String?] {
            let db = try copy.database(contacts: juans, region: region)
            let label = region ?? "no region"
            XCTAssertThrowsError(try db.resolve("Juan"), label) { error in
                guard case StoreError.severalMatches(let candidates) = error else { return XCTFail("\(error)") }
                XCTAssertEqual(candidates.map(\.label), ["Juan Perez", "Juan Lopez", "Juan Ruiz", "Juan Soto"], label)
                XCTAssertEqual(candidates.map(\.argument),
                               ["55 1234 5678", "+525511112222", "ruiz@example.com", "+525512345678"], label)
            }
            XCTAssertThrowsError(try db.resolve("55 1234 5678"), label) { error in
                XCTAssertEqual(error as? StoreError, .noMatch("55 1234 5678"))
            }
            XCTAssertEqual(StoreError.noMatchFix(for: "55 1234 5678"), "pass the whole number with + and its country code")
            XCTAssertEqual(try db.resolve("+525511112222").sendHandle, "+525511112222", label)
            XCTAssertEqual(try db.resolve("ruiz@example.com").sendHandle, "ruiz@example.com", label)
            XCTAssertEqual(try db.resolve("+525512345678").primaryChatRowID, 98, label)
        }
        let us = try copy.database(contacts: juans, region: "US")
        XCTAssertThrowsError(try us.resolve("Juan")) { error in
            guard case StoreError.severalMatches(let candidates) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(candidates.map(\.argument),
                           ["+15512345678", "+525511112222", "+15512340000", "+15587654321"])
        }
    }

    /// Juan Perez, saved as 55 1234 5678, and the group Juan y amigos are several matches for `Juan` in every
    /// region, as a contact and a group's display name are anywhere else. Outside a +1 region Juan is listed with
    /// his number as saved, so passing it back asks for the country code. A +1 region lists the +1 number.
    func testContactWithOnlyANumberWithoutACountryCodeAndAGroupNameAreSeveralMatchesInEveryRegion() throws {
        let copy = try FixtureCopy()
        try copy.insertChat(rowid: 91, guid: "any;+;chat111", identifier: "chat111", service: "iMessage", style: 43,
                            displayName: "Juan y amigos", handles: [3, 4])
        for region in ["MX", "GB", nil] as [String?] {
            let db = try copy.database(contacts: Fixture.contactsLocalNumberJSON, region: region)
            let label = region ?? "no region"
            XCTAssertThrowsError(try db.resolve("Juan"), label) { error in
                guard case StoreError.severalMatches(let candidates) = error else { return XCTFail("\(label): \(error)") }
                XCTAssertEqual(candidates.map(\.label), ["Juan Perez", "Juan y amigos"], label)
                XCTAssertEqual(candidates.map(\.argument), ["55 1234 5678", "91"], label)
            }
            XCTAssertThrowsError(try db.resolve("55 1234 5678"), label) { error in
                XCTAssertEqual(error as? StoreError, .noMatch("55 1234 5678"), label)
            }
            XCTAssertEqual(StoreError.noMatchFix(for: "55 1234 5678"), "pass the whole number with + and its country code")
            XCTAssertThrowsError(try db.resolve("Juan Perez"), label) { error in
                XCTAssertEqual(error as? StoreError, .noMatch("55 1234 5678"), label)
            }
            XCTAssertEqual(try db.resolve("91").primaryChatRowID, 91, label)
            XCTAssertEqual(try db.resolve("Juan y amigos").primaryChatRowID, 91, label)
        }
        let us = try copy.database(contacts: Fixture.contactsLocalNumberJSON, region: "US")
        XCTAssertThrowsError(try us.resolve("Juan")) { error in
            guard case StoreError.severalMatches(let candidates) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(candidates.map(\.label), ["Juan y amigos", "Juan Perez +1 551-234-5678"])
            XCTAssertEqual(candidates.map(\.argument), ["91", "+15512345678"])
        }
        XCTAssertEqual(try us.resolve("55 1234 5678").sendHandle, "+15512345678")
        XCTAssertEqual(try us.resolve("Juan Perez").sendHandle, "+15512345678")
    }

    /// Outside a +1 region Juan Perez, saved as 55 1234 5678, still counts as a match, so the fallback on an unnamed
    /// group's member names (BUILD-PLAN entry 25) doesn't take his name, as it doesn't in a +1 region.
    func testContactWithOnlyANumberWithoutACountryCodeKeepsHisNameFromAnUnnamedGroup() throws {
        let copy = try FixtureCopy()
        try copy.exec("INSERT INTO handle (ROWID, id, service) VALUES (41, 'juan.amigo@example.com', 'iMessage')")
        try copy.insertChat(rowid: 92, guid: "any;+;chat222", identifier: "chat222", service: "iMessage", style: 43,
                            handles: [3, 41])
        for region in ["MX", "GB", nil] as [String?] {
            let db = try copy.database(contacts: Fixture.contactsLocalNumberJSON, region: region)
            let label = region ?? "no region"
            XCTAssertThrowsError(try db.resolve("Juan"), label) { error in
                XCTAssertEqual(error as? StoreError, .noMatch("55 1234 5678"), label)
            }
            XCTAssertEqual(try db.resolve("amigo").primaryChatRowID, 92, label)
        }
        let us = try copy.database(contacts: Fixture.contactsLocalNumberJSON, region: "US")
        XCTAssertEqual(try us.resolve("Juan").sendHandle, "+15512345678")
        XCTAssertEqual(try us.resolve("amigo").primaryChatRowID, 92)
    }

    /// Outside a +1 region, `who` shows a number saved without a `+` as saved when chat.db doesn't know it, so it
    /// never offers the +1 number that resolving the card refuses. A + number, an email, a number chat.db knows and
    /// every number in a +1 region print as before.
    func testWhoOutsideAPlusOneRegionShowsANumberWithoutACountryCodeAsSaved() throws {
        let copy = try FixtureCopy()
        let kai = try contactsFile(people: [("Kai", "Two", nil, ["(415) 555-0101", "5512340000", "+52 55 8765 4321",
                                                                 "Kai@Example.com"])])
        for region in ["MX", "GB", nil] as [String?] {
            let reader = ReadService(db: try copy.database(contacts: Fixture.contactsLocalNumberJSON, region: region))
            let juan = try XCTUnwrap(try reader.contacts(ContactsArgs(name: "Juan")).contacts.first)
            XCTAssertEqual(juan.handles, [HandleRecord(id: "55 1234 5678", services: [])], region ?? "no region")
            let record = try XCTUnwrap(try ReadService(db: try copy.database(contacts: kai, region: region))
                .contacts(ContactsArgs(name: "Kai")).contacts.first)
            XCTAssertEqual(record.handles.map(\.id), ["+14155550101", "5512340000", "+525587654321", "kai@example.com"],
                           "a number chat.db knows keeps its handle")
        }
        let us = ReadService(db: try copy.database(contacts: Fixture.contactsLocalNumberJSON, region: "US"))
        XCTAssertEqual(try us.contacts(ContactsArgs(name: "Juan")).contacts.first?.handles.map(\.id), ["+15512345678"])
    }

    func testRegionDefaultsToTheCurrentLocaleAndOnlyPlusOneRegionsCount() {
        let config = StoreConfiguration(chatDBPath: Fixture.chatDB.path, attachmentsRoot: Fixture.attachmentsRoot,
                                        attachmentCacheDir: TempDir.make())
        XCTAssertEqual(config.regionCode, Locale.current.region?.identifier)
        XCTAssertEqual(StoreConfiguration.live().regionCode, Locale.current.region?.identifier)
        for region in ["US", "CA", "PR", "JM", "us"] {
            XCTAssertTrue(HandleNormalizer.usesNorthAmericanPlan(region: region), region)
        }
        for region in ["MX", "GB", "IN", "BR", "419", ""] as [String?] + [nil] {
            XCTAssertFalse(HandleNormalizer.usesNorthAmericanPlan(region: region), region ?? "nil")
        }
    }

    func testNewDirectTargetSendsOnSMSOnlyWhenChatDBKnowsTheHandleOnlyFromSMS() throws {
        let copy = try FixtureCopy()
        try copy.exec("""
            INSERT INTO handle (ROWID, id, service) VALUES (30, '+14155550177', 'SMS');
            INSERT INTO handle (ROWID, id, service) VALUES (31, '+14155550178', 'SMS');
            INSERT INTO handle (ROWID, id, service) VALUES (32, '+14155550178', 'iMessage');
            INSERT INTO handle (ROWID, id, service) VALUES (33, '+14155550179', 'RCS');
            INSERT INTO handle (ROWID, id, service) VALUES (34, 'Pat.Two@Example.com', 'SMS');
            """)
        let db = try copy.database()
        let smsOnly = try db.resolve("(415) 555-0177")
        XCTAssertEqual(smsOnly.chatRowIDs, [])
        XCTAssertEqual(smsOnly.sendHandle, "+14155550177")
        XCTAssertEqual(smsOnly.service, "SMS")
        XCTAssertEqual(try db.resolve("+14155550178").service, "iMessage", "iMessage wins when chat.db lists both")
        XCTAssertEqual(try db.resolve("+14155550179").service, "iMessage", "RCS sends on iMessage")
        XCTAssertEqual(try db.resolve("pat.two@example.com").service, "SMS", "the handle compare folds case")
        XCTAssertEqual(try db.resolve("Taylor").service, "iMessage")
        XCTAssertEqual(try db.resolve("+19995550000").service, "iMessage", "a handle chat.db doesn't list")
        XCTAssertEqual(try db.sendTarget(canonical: .direct(handle: "+14155550177"))?.service, "SMS")
    }

    func testSendTargetCoversADirectIdentityWithNoChatYet() throws {
        let db = try TestStore.database()
        let fresh = try XCTUnwrap(try db.sendTarget(canonical: .direct(handle: "+19995550000")))
        XCTAssertEqual(fresh, try db.resolve("+19995550000"))
        XCTAssertEqual(fresh.chatRowIDs, [])
        XCTAssertEqual(fresh.sendHandle, "+19995550000")
        XCTAssertEqual(try db.sendTarget(canonical: .direct(handle: "+14155550101")),
                       try db.resolve(canonical: .direct(handle: "+14155550101")))
        XCTAssertEqual(try db.sendTarget(canonical: .group(identifier: "chat836828054889214904"))?.primaryChatRowID, 12)
        XCTAssertNil(try db.sendTarget(canonical: .group(identifier: "chat000")))
        XCTAssertNil(try db.sendTarget(canonical: CanonicalChatID(rawValue: "")))
        XCTAssertNil(try db.sendTarget(canonical: .direct(handle: "")))
    }

    func testNewDirectTargetBecomesTheChatOnceItExists() throws {
        let copy = try FixtureCopy()
        try copy.insertChat(rowid: 94, guid: "iMessage;-;+14155550103", identifier: "+14155550103",
                            service: "iMessage", handles: [5])
        try copy.insertMessage(rowid: 41600, guid: "PRIYA-1", chat: 94, handle: 5, text: "hi", fromMe: false,
                               date: Fixture.nowNs - 60_000_000_000)
        let db = try copy.database()
        let priya = try db.resolve("Priya")
        XCTAssertEqual(priya.chatRowIDs, [94])
        XCTAssertEqual(priya.canonical, .direct(handle: "+14155550103"))
        XCTAssertEqual(try db.resolve("+14155550103").primaryChatRowID, 94)
    }

    // MARK: Item 11, resolve(canonical:) and resolve(chatRowID:)

    func testResolveByCanonicalAndChatRowID() throws {
        let db = try TestStore.database()
        XCTAssertEqual(try db.resolve(canonical: .direct(handle: "+14155550101"))?.primaryChatRowID, 7)
        XCTAssertEqual(try db.resolve(canonical: .group(identifier: "chat836828054889214904"))?.primaryChatRowID, 12)
        XCTAssertEqual(try db.resolve(chatRowID: 19)?.canonical, .group(identifier: "chat564517051022821277"))
        XCTAssertNil(try db.resolve(canonical: .direct(handle: "+19995550000")))
        XCTAssertNil(try db.resolve(canonical: .group(identifier: "chat000")))
        XCTAssertNil(try db.resolve(canonical: CanonicalChatID(rawValue: "")))
        XCTAssertNil(try db.resolve(chatRowID: 9999))
        XCTAssertNil(try db.resolve(chatRowID: -1))
        XCTAssertThrowsError(try db.chat(rowid: 9999)) { XCTAssertEqual($0 as? StoreError, .notFound("chat 9999")) }
    }

    func testResolveReturnsNilOnceTheChatIsGone() throws {
        let copy = try FixtureCopy()
        let before = try copy.database()
        let canonical = try XCTUnwrap(try before.resolve(chatRowID: 9)).canonical
        try copy.exec("DELETE FROM chat_message_join WHERE chat_id = 9; DELETE FROM chat_handle_join WHERE chat_id = 9; "
                      + "DELETE FROM chat WHERE ROWID = 9")
        let after = try copy.database()
        XCTAssertNil(try after.resolve(canonical: canonical))
        XCTAssertNil(try after.resolve(chatRowID: 9))
    }

    // MARK: chats, unread, read and show

    func testChatsInRecencyOrderWithLabelsAndUnreadCounts() throws {
        let page = try reader.chats(ChatsArgs(limit: 50))
        XCTAssertEqual(page.chats.map(\.rowid), [23, 19, 7, 12, 31, 56, 9, 2])
        XCTAssertEqual(page.chats.map(\.label), ["Jordan Kim", "Jordan, Taylor", "Mom", "Family 🏡", "Sam Lee",
                                                 "+1 (510) 555-0163", "Dad", "You (notes)"])
        XCTAssertEqual(page.chats.map(\.unreadCount), [0, 1, 2, 3, 1, 1, 0, 0])
        XCTAssertEqual(page.chats.first?.last?.rowid, 41558)
        XCTAssertFalse(page.hasMore)
        let short = try reader.chats(ChatsArgs(limit: 3))
        XCTAssertEqual(short.chats.count, 3)
        XCTAssertTrue(short.hasMore)
        XCTAssertEqual(try reader.chats(ChatsArgs(limit: 0)).chats.count, 1)
        XCTAssertEqual(try reader.chats(ChatsArgs(limit: 8)).hasMore, false)
        XCTAssertEqual(try reader.chats(ChatsArgs(limit: 7)).hasMore, true)
    }

    func testUnreadOnlyFiltersBeforeTheLimit() throws {
        let page = try reader.chats(ChatsArgs(limit: 2, unreadOnly: true))
        XCTAssertEqual(page.chats.map(\.rowid), [19, 7])
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(try reader.chats(ChatsArgs(limit: 50, unreadOnly: true)).chats.map(\.rowid), [19, 7, 12, 31, 56])
    }

    func testUnreadMatchesTheManifest() throws {
        let page = try reader.unread(UnreadArgs(context: 2))
        let tasks = Manifest.json["tasks"] as! [String: Any]
        let summarize = tasks["summarize_unread"] as! [String: Any]
        let expected = summarize["unread_rowids_by_chat"] as! [String: [NSNumber]]
        XCTAssertEqual(page.totalUnread, 8)
        XCTAssertEqual(page.groups.map(\.chat.rowid), [19, 7, 12, 31, 56])
        for group in page.groups {
            let ids = group.entries.filter(\.isUnread).map(\.message.rowid)
            XCTAssertEqual(ids, expected[String(group.chat.rowid)]?.map(\.int64Value), "chat \(group.chat.rowid)")
            XCTAssertEqual(group.unreadCount, ids.count)
        }
        let mom = try XCTUnwrap(page.groups.first { $0.chat.rowid == 7 })
        XCTAssertEqual(mom.entries.map(\.message.rowid), [41540, 41541, 41555, 41556])
        XCTAssertFalse(mom.entries.contains(where: \.gapBefore))
    }

    func testUnreadContextIsClampedAndGapsAreMarked() throws {
        XCTAssertEqual(try reader.unread(UnreadArgs(context: -3)).groups.flatMap(\.entries).filter { !$0.isUnread }.count, 0)
        let copy = try FixtureCopy()
        try copy.exec("UPDATE message SET is_read = 0 WHERE ROWID = 41538")
        let r = ReadService(db: try copy.database())
        let mom = try XCTUnwrap(try r.unread(UnreadArgs(context: 1)).groups.first { $0.chat.rowid == 7 })
        XCTAssertEqual(mom.entries.map(\.message.rowid), [41537, 41538, 41541, 41555, 41556])
        XCTAssertEqual(mom.entries.map(\.isUnread), [false, true, false, true, true])
        XCTAssertEqual(mom.entries.map(\.gapBefore), [false, false, true, false, false])
    }

    /// Inserts `count` unread incoming rows into `chat`, one second apart from `start`.
    private func insertUnread(_ copy: FixtureCopy, count: Int, chat: Int64, handle: Int64, start: Int64) throws {
        try copy.exec("""
            WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < \(count))
            INSERT INTO message (ROWID, guid, text, handle_id, service, date, is_from_me, is_read, item_type)
            SELECT 50000 + i, 'UNREAD-' || i, 'unread row ' || i, \(handle), 'iMessage', \(start) + i * 1000000000, 0, 0, 0
            FROM n;
            INSERT INTO chat_message_join (chat_id, message_id, message_date)
            SELECT \(chat), ROWID, date FROM message WHERE ROWID > 50000 AND ROWID <= 50000 + \(count);
            """)
    }

    /// 4,000 unread rows cost what one 200-line page can show, not a context scan and a record per row. The
    /// fetched-row count comes from a row-cap budget around the call, so nothing here depends on timing.
    func testUnreadBuildsOnlyWhatThePageCanShow() throws {
        let copy = try FixtureCopy()
        try insertUnread(copy, count: 4_000, chat: 7, handle: 3, start: Fixture.nowNs - 4_001 * 1_000_000_000)
        let db = try copy.database(timeout: 120)
        let r = ReadService(db: db)
        let page = try db.connection.withBudget(seconds: 120, rowCap: 10_000) { try r.unread(UnreadArgs()) }
        XCTAssertEqual(page.totalUnread, 4_008)
        XCTAssertEqual(page.groups.map(\.chat.rowid), [7, 19, 12, 31, 56])
        XCTAssertEqual(page.groups.map(\.unreadCount), [4_002, 1, 3, 1, 1])
        XCTAssertEqual(page.groups.map { $0.chat.unreadCount }, [4_002, 1, 3, 1, 1])
        XCTAssertLessThanOrEqual(page.groups[0].entries.count, Limits.outputMaxLines)
        XCTAssertGreaterThan(page.groups[0].entries.count, 190)
        XCTAssertTrue(page.groups.dropFirst().allSatisfy { $0.entries.isEmpty })
        XCTAssertTrue(page.groups.allSatisfy { $0.chat.last != nil })

        let full = try r.unreadPage(UnreadArgs(), lineBudget: Int.max)
        XCTAssertEqual(full.groups[0].entries.count, 4_004)
        XCTAssertEqual(Array(full.groups[0].entries.prefix(page.groups[0].entries.count)), page.groups[0].entries)
        XCTAssertEqual(Format.unread(page, Golden.context), Format.unread(full, Golden.context))
        XCTAssertTrue(Format.unread(page, Golden.context).contains("more: imessage read 7 --after "))
    }

    /// When a later chat is the first that can't fit, every chat keeps its unread count for the header, the chats
    /// past it get no entries, and the text page is the one the full page prints.
    func testUnreadTotalsCoverChatsPastTheLineCap() throws {
        let copy = try FixtureCopy()
        try insertUnread(copy, count: 300, chat: 12, handle: 6, start: 815_000_000_000_000_000)
        let db = try copy.database(timeout: 120)
        let r = ReadService(db: db)
        let page = try r.unread(UnreadArgs())
        XCTAssertEqual(page.totalUnread, 308)
        XCTAssertEqual(page.groups.map(\.chat.rowid), [19, 7, 12, 31, 56])
        XCTAssertEqual(page.groups.map(\.unreadCount), [1, 2, 303, 1, 1])
        XCTAssertFalse(page.groups[0].entries.isEmpty)
        XCTAssertFalse(page.groups[1].entries.isEmpty)
        XCTAssertLessThanOrEqual(page.groups[2].entries.count, Limits.outputMaxLines)
        XCTAssertTrue(page.groups[3].entries.isEmpty && page.groups[4].entries.isEmpty)
        let full = try r.unreadPage(UnreadArgs(), lineBudget: Int.max)
        XCTAssertEqual(full.groups.map(\.unreadCount), page.groups.map(\.unreadCount))
        XCTAssertEqual(Array(full.groups.prefix(2)), Array(page.groups.prefix(2)))
        let text = Format.unread(page, Golden.context)
        XCTAssertEqual(text, Format.unread(full, Golden.context))
        XCTAssertTrue(text.hasPrefix("unread · 308 messages in 5 chats"))
        XCTAssertTrue(text.contains("more: imessage read 12"))
    }

    func testAfterAndAroundSayWhenNewerMessagesExist() throws {
        let all = try reader.allVisible("Mom").map(\.rowid)
        let after = try reader.messages(MessagesArgs(who: "Mom", limit: 5, after: all[100]))
        XCTAssertEqual(after.messages.map(\.rowid), Array(all[101..<106]))
        XCTAssertTrue(after.newerExists)
        XCTAssertTrue(after.olderExists)
        XCTAssertTrue(try reader.messages(MessagesArgs(who: "Mom", limit: 10, around: all[100])).newerExists)
        let last = try reader.messages(MessagesArgs(who: "Mom", limit: 5, after: all[all.count - 4]))
        XCTAssertEqual(last.messages.map(\.rowid), Array(all.suffix(3)))
        XCTAssertFalse(last.newerExists, "the newest message is on the page")
        XCTAssertFalse(try reader.messages(MessagesArgs(who: "Mom", limit: 10, around: 99_999)).newerExists)
        XCTAssertFalse(try reader.messages(MessagesArgs(who: "Mom", limit: 5, before: all[100])).newerExists,
                       "--before pages back, and its footer is --before")
        XCTAssertFalse(try reader.messages(MessagesArgs(who: "Mom", limit: 5)).newerExists)
    }

    func testReadWindows() throws {
        let all = try reader.allVisible("Mom").map(\.rowid)
        XCTAssertEqual(all.count, 303)
        let newest = try reader.messages(MessagesArgs(who: "Mom", limit: 10))
        XCTAssertEqual(newest.messages.map(\.rowid), Array(all.suffix(10)))
        XCTAssertTrue(newest.olderExists)
        let anchor = all[100]
        XCTAssertEqual(try reader.messages(MessagesArgs(who: "Mom", limit: 5, before: anchor)).messages.map(\.rowid),
                       Array(all[95..<100]))
        XCTAssertEqual(try reader.messages(MessagesArgs(who: "Mom", limit: 5, after: anchor)).messages.map(\.rowid),
                       Array(all[101..<106]))
        XCTAssertEqual(try reader.messages(MessagesArgs(who: "Mom", limit: 10, around: anchor)).messages.map(\.rowid),
                       Array(all[95..<105]))
        XCTAssertEqual(try reader.messages(MessagesArgs(who: "Mom", limit: 10, around: anchor - 1)).messages.first?.rowid,
                       all[95])
        XCTAssertEqual(try reader.messages(MessagesArgs(who: "Mom", limit: 10, around: all[2])).messages.map(\.rowid),
                       Array(all[0..<10]))
        XCTAssertEqual(try reader.messages(MessagesArgs(who: "Mom", limit: 10, around: 99_999)).messages.map(\.rowid),
                       Array(all.suffix(6)))
        let oldest = try reader.messages(MessagesArgs(who: "Mom", limit: 5, before: all[3]))
        XCTAssertEqual(oldest.messages.map(\.rowid), Array(all[0..<3]))
        XCTAssertFalse(oldest.olderExists)
        let none = try reader.messages(MessagesArgs(who: "Mom", limit: 5, before: all[0]))
        XCTAssertTrue(none.messages.isEmpty)
        XCTAssertFalse(none.olderExists)
    }

    func testReadLimitIsClampedTo200() throws {
        XCTAssertEqual(try reader.messages(MessagesArgs(who: "Mom", limit: 5_000)).messages.count, 200)
        XCTAssertEqual(try reader.messages(MessagesArgs(who: "Mom", limit: 0)).messages.count, 1)
    }

    func testSinceFiltersAfterWindowing() throws {
        let window = try reader.messages(MessagesArgs(who: "Mom", limit: 10)).messages
        let cut = window[6].dateNs
        let page = try reader.messages(MessagesArgs(who: "Mom", limit: 10, sinceNs: cut))
        XCTAssertEqual(page.messages.map(\.rowid), window.filter { $0.dateNs >= cut }.map(\.rowid))
        XCTAssertEqual(page.messages.count, 4)
    }

    /// DESIGN 5: polls and locations print as short events. Poll payloads are not decoded, so there is no title.
    func testLocationSharesAndPollsAreShortEvents() throws {
        let copy = try FixtureCopy()
        let t = Fixture.nowNs - 60 * 1_000_000_000
        try copy.insertMessage(rowid: 41600, guid: "LOC-1", chat: 7, handle: 3, text: nil, fromMe: false, date: t)
        try copy.insertMessage(rowid: 41601, guid: "POLL-1", chat: 7, handle: 3, text: "\u{FFFC}", fromMe: false,
                               date: t + 1)
        try copy.insertMessage(rowid: 41602, guid: "VOTE-1", chat: 7, handle: 3, text: nil, fromMe: false, date: t + 2,
                               associatedType: 4000, associatedGUID: "POLL-1")
        try copy.exec("""
            UPDATE message SET item_type = 4 WHERE ROWID = 41600;
            UPDATE message SET balloon_bundle_id = 'com.apple.messages.Polls' WHERE ROWID IN (41601, 41602);
            """)
        let r = ReadService(db: try copy.database())
        let location = try r.message(MessageArgs(rowid: 41600)).message
        XCTAssertEqual(location.event?.kind, .location)
        XCTAssertEqual(location.event.map(Format.eventText), "* Mom shared a location")
        let poll = try r.message(MessageArgs(rowid: 41601)).message
        XCTAssertEqual(poll.event?.kind, .poll)
        XCTAssertNil(poll.event?.title)
        XCTAssertEqual(poll.event.map(Format.eventText), "* Mom started a poll")
        XCTAssertNil(try r.message(MessageArgs(rowid: 41602)).message.event)
        XCTAssertNil(try reader.message(MessageArgs(rowid: 41558)).message.event)

        // A poll vote (associated type 4000) is never a row of its own: not in read, unread, chats or the
        // conversation list, even while it is unread.
        try copy.exec("UPDATE message SET is_read = 0 WHERE ROWID = 41602")
        let db = try copy.database()
        let votes = ReadService(db: db)
        let mom = try votes.allVisible("Mom").map(\.rowid)
        XCTAssertTrue(mom.contains(41601))
        XCTAssertFalse(mom.contains(41602))
        XCTAssertEqual(try votes.messages(MessagesArgs(who: "Mom", limit: 200)).totalVisible, mom.count)
        let unread = try votes.unread(UnreadArgs())
        XCTAssertFalse(unread.groups.flatMap(\.entries).contains { $0.message.rowid == 41602 })
        XCTAssertEqual(unread.totalUnread, try reader.unread(UnreadArgs()).totalUnread)
        XCTAssertEqual(try votes.chats(ChatsArgs(limit: 50)).chats.first { $0.rowid == 7 }?.last?.rowid, 41601)
        XCTAssertEqual(try db.conversations().first { $0.chatRowIDs == [7] }?.newestDateNs, t + 1)
    }

    func testRecordsCarrySenderAndEventFields() throws {
        let rename = try reader.message(MessageArgs(rowid: 40016)).message
        XCTAssertEqual(rename.event?.kind, .renamed)
        XCTAssertEqual(rename.event?.title, "Fam")
        XCTAssertEqual(rename.event?.actorName, "Mom")
        let add = try reader.message(MessageArgs(rowid: 40473)).message
        XCTAssertEqual(add.event?.kind, .added)
        XCTAssertEqual(add.event?.otherName, "+1 (707) 555-0131")
        let remove = try reader.message(MessageArgs(rowid: 40829)).message
        XCTAssertEqual(remove.event?.kind, .removed)
        XCTAssertEqual(remove.event?.actorName, "You")
        XCTAssertEqual(remove.event?.otherName, "Chris")
        XCTAssertEqual(try reader.message(MessageArgs(rowid: 41144)).message.event?.kind, .left)
        let fromMe = try reader.message(MessageArgs(rowid: 41558)).message
        XCTAssertTrue(fromMe.fromMe)
        XCTAssertNil(fromMe.senderHandle)
        XCTAssertEqual(fromMe.senderName, "You")
        let reply = try reader.message(MessageArgs(rowid: 40889)).message
        XCTAssertEqual(reply.replyTo?.rowid, 40888)
        XCTAssertEqual(reply.replyTo?.senderName, "Taylor")
        let voice = try reader.message(MessageArgs(rowid: 40580)).message
        XCTAssertEqual(voice.attachments.first?.kind, .voice)
        XCTAssertEqual(voice.attachments.first?.transcript?.hasPrefix("Hi beta"), true)
        XCTAssertEqual(try reader.message(MessageArgs(rowid: 40051)).message.attachments.first?.onDisk, false)
    }

    func testGroupSendersUseShortNamesAmongMembers() throws {
        let page = try reader.messages(MessagesArgs(who: "12", limit: 200))
        let names = Set(page.messages.filter { !$0.fromMe }.map(\.senderName))
        XCTAssertEqual(names, ["Mom", "Dad", "Priya", "Arjun"])
    }

    func testShowReturnsTheWholeBodyAndTheRequestedOffset() throws {
        let id = Manifest.first("long_body_over_8kb")
        let first = try reader.message(MessageArgs(rowid: id, fromByte: 0))
        XCTAssertEqual(first.totalBytes, 8_503)
        XCTAssertGreaterThan(first.totalBytes, Limits.showCapBytes)
        XCTAssertEqual(first.message.text.utf8.count, first.totalBytes)
        XCTAssertEqual(first.fromByte, 0)
        let second = try reader.message(MessageArgs(rowid: id, fromByte: 8_190))
        XCTAssertEqual(second.fromByte, 8_190)
        XCTAssertEqual(second.message.text, first.message.text)
        XCTAssertEqual(try reader.message(MessageArgs(rowid: id, fromByte: 1_000_000)).fromByte, 8_503)
        XCTAssertEqual(try reader.message(MessageArgs(rowid: id, fromByte: 8_503)).fromByte, 8_503)
        XCTAssertEqual(try reader.message(MessageArgs(rowid: id, fromByte: -5)).fromByte, 0)

        let emoji = try reader.message(MessageArgs(rowid: Manifest.first("emoji_zwj_flag"), fromByte: 2))
        XCTAssertEqual(emoji.fromByte, 2)
        XCTAssertEqual(emoji.message.text, "👨‍👩‍👧‍👦❤️🇮🇳")
        XCTAssertEqual(emoji.totalBytes, "👨‍👩‍👧‍👦❤️🇮🇳".utf8.count)
    }

    func testShowOfAnUnknownRowThrowsNotFound() {
        XCTAssertThrowsError(try reader.message(MessageArgs(rowid: 1))) {
            XCTAssertEqual($0 as? StoreError, .notFound("message 1"))
        }
    }

    func testContactsListsHandlesServicesAndChats() throws {
        let mom = try reader.contacts(ContactsArgs(name: "Mom"))
        XCTAssertEqual(mom.contacts.count, 1)
        let card = try XCTUnwrap(mom.contacts.first)
        XCTAssertEqual(card.firstName, "Meera")
        XCTAssertEqual(card.lastName, "Desai")
        XCTAssertEqual(card.handles.map(\.id), ["+14155550101"])
        XCTAssertEqual(card.handles.first?.services, ["SMS", "iMessage"])
        XCTAssertEqual(card.chats.map(\.rowid), [7, 12])
        XCTAssertEqual(try reader.contacts(ContactsArgs(name: "Jordan")).contacts.first?.chats.map(\.rowid), [19, 23])
        XCTAssertThrowsError(try reader.contacts(ContactsArgs(name: "Nobody"))) {
            XCTAssertEqual($0 as? StoreError, .noMatch("Nobody"))
        }
    }

    func testChatByRowIDKeepsThatChatsIdentity() throws {
        let db = try TestStore.database()
        let chat = try db.chat(rowid: 12)
        XCTAssertEqual(chat.guid, "any;+;chat836828054889214904")
        XCTAssertEqual(chat.label, "Family 🏡")
        XCTAssertEqual(chat.unreadCount, 3)
        XCTAssertEqual(chat.last?.rowid, 41554)
    }

    // MARK: Thread safety

    func testConcurrentReadsAgreeWithSerialReads() throws {
        let db = try TestStore.database()
        let r = ReadService(db: db)
        let expectedChats = try r.chats(ChatsArgs(limit: 50)).chats.map(\.rowid)
        let expectedMom = try r.messages(MessagesArgs(who: "Mom", limit: 50)).messages.map(\.rowid)
        let expectedHits = try r.search(SearchArgs(text: "dinner", limit: 50)).hits.map(\.message.rowid)
        let lock = NSLock()
        var failures: [String] = []
        DispatchQueue.concurrentPerform(iterations: 24) { i in
            do {
                switch i % 4 {
                case 0:
                    let got = try r.chats(ChatsArgs(limit: 50)).chats.map(\.rowid)
                    if got != expectedChats { throw StoreError.decode("chats") }
                case 1:
                    let got = try r.messages(MessagesArgs(who: "Mom", limit: 50)).messages.map(\.rowid)
                    if got != expectedMom { throw StoreError.decode("read") }
                case 2:
                    let got = try r.search(SearchArgs(text: "dinner", limit: 50)).hits.map(\.message.rowid)
                    if got != expectedHits { throw StoreError.decode("search") }
                default:
                    db.addAgentSentGUIDs(["G\(i)"])
                    _ = try r.unread(UnreadArgs())
                }
            } catch {
                lock.lock()
                failures.append("\(i): \(error)")
                lock.unlock()
            }
        }
        XCTAssertEqual(failures, [])
    }
}
