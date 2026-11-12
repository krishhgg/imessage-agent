import Foundation
import XCTest
import IMCore
@testable import IMStore
import IMTestSupport

/// Checklist item 17: ChatDatabase as SendRowSource, UITargetSource and ChatActivitySource.
final class ConsumerProtocolTests: XCTestCase {
    private var db: ChatDatabase!
    private var reader: ReadService!
    private let second: Int64 = 1_000_000_000

    override func setUpWithError() throws {
        db = try TestStore.database()
        reader = ReadService(db: db)
    }

    private func text(_ rowid: Int64) throws -> String { try reader.message(MessageArgs(rowid: rowid)).message.text }

    private func guid(_ rowid: Int64) throws -> String { try XCTUnwrap(try db.messageTarget(rowid: rowid)).guid }

    func testChatDatabaseConformsToEveryConsumerProtocol() {
        let send: SendRowSource = db
        let ui: UITargetSource = db
        let activity: ChatActivitySource = db
        XCTAssertTrue(send === ui && ui === activity)
    }

    // MARK: SendRowSource

    func testMaxMessageRowIDFollowsNewRows() throws {
        XCTAssertEqual(try db.maxMessageRowID(), 41558)
        let copy = try FixtureCopy()
        try copy.insertMessage(rowid: 41600, guid: "NEW", chat: 7, handle: 3, text: "hi", fromMe: true, date: Fixture.nowNs)
        XCTAssertEqual(try copy.database().maxMessageRowID(), 41600)
    }

    func testFromMeRowsAreOldestFirstAndLimited() throws {
        let all = try db.fromMeRows(aboveRowID: 41500, limit: 100).map(\.rowid)
        XCTAssertEqual(all, [41501, 41504, 41506, 41509, 41514, 41515, 41518, 41520, 41526, 41528, 41531, 41534,
                             41537, 41539, 41540, 41547, 41558])
        XCTAssertEqual(try db.fromMeRows(aboveRowID: 41500, limit: 3).map(\.rowid), [41501, 41504, 41506])
        XCTAssertEqual(try db.fromMeRows(aboveRowID: 41500, limit: 1).map(\.rowid), [41501])
        XCTAssertEqual(try db.fromMeRows(aboveRowID: 41500, limit: 0), [])
        XCTAssertEqual(try db.fromMeRows(aboveRowID: 41500, limit: -5), [])
        XCTAssertEqual(try db.fromMeRows(aboveRowID: 41558, limit: 10), [])
        XCTAssertEqual(try db.fromMeRows(aboveRowID: 41557, limit: 10).map(\.rowid), [41558])
    }

    func testCanonicalChatIDOfAChatMatchesItsConversation() throws {
        for rowid: Int64 in [2, 7, 9, 12, 19, 23, 31, 56] {
            XCTAssertEqual(try db.canonicalChatID(chatRowID: rowid), try db.resolve(chatRowID: rowid)?.canonical, "\(rowid)")
        }
        XCTAssertEqual(try db.canonicalChatID(chatRowID: 7), .direct(handle: "+14155550101"))
        XCTAssertEqual(try db.canonicalChatID(chatRowID: 12), .group(identifier: "chat836828054889214904"))
        XCTAssertNil(try db.canonicalChatID(chatRowID: 9999))
    }

    func testSentProbeCarriesWhatCorrelationCompares() throws {
        let probe = try XCTUnwrap(try db.sentRow(rowid: 41558))
        XCTAssertEqual(probe.guid, "9CA666AA-4233-4681-A68D-4365B2E1707B")
        XCTAssertEqual(probe.handle, "jordan.kim@example.com")
        XCTAssertEqual(probe.service, "iMessage")
        XCTAssertEqual(probe.joinedChatRowID, 23)
        XCTAssertTrue(probe.isSent)
        XCTAssertFalse(probe.isDelivered)
        XCTAssertEqual(probe.error, 0)
        XCTAssertEqual(probe.body, TextNorm.matchKey(try text(41558)))
        XCTAssertTrue(probe.hasBody)
        XCTAssertEqual(probe.transferNames, [])
        let failed = try XCTUnwrap(try db.sentRow(rowid: Manifest.first("failed_send")))
        XCTAssertEqual(failed.error, 4)
        XCTAssertFalse(failed.isSent)
        let delivered = try XCTUnwrap(try db.sentRow(rowid: 41163))
        XCTAssertTrue(delivered.isDelivered)
        XCTAssertEqual(delivered.dateDeliveredNs, 810_107_359_371_164_000)
        XCTAssertNil(try db.sentRow(rowid: 41557))
        XCTAssertNil(try db.sentRow(rowid: 999_999))
    }

    func testSentProbeNormalizesTheHandleAndBody() throws {
        let copy = try FixtureCopy()
        try copy.exec("INSERT INTO handle (ROWID, id, service) VALUES (90, ' Pat.Doe@Example.COM ', 'iMessage')")
        try copy.exec("INSERT INTO handle (ROWID, id, service) VALUES (91, '(415) 555-0177', 'SMS')")
        try copy.insertMessage(rowid: 41600, guid: "A", chat: 7, handle: 90, text: "  cafe\u{301} \n", fromMe: true,
                               date: Fixture.nowNs)
        try copy.insertMessage(rowid: 41601, guid: "B", chat: 7, handle: 91, text: "x", fromMe: true, date: Fixture.nowNs)
        let probes = try copy.database().fromMeRows(aboveRowID: 41558, limit: 10)
        XCTAssertEqual(probes.map(\.handle), ["pat.doe@example.com", "+14155550177"])
        XCTAssertEqual(probes.first?.body, "caf\u{E9}")
    }

    func testUnjoinedEmptyRowIsReported() throws {
        let copy = try FixtureCopy()
        try copy.exec("""
            INSERT INTO message (ROWID, guid, text, handle_id, service, date, is_from_me, is_sent, error)
            VALUES (41600, 'GHOST', NULL, 14, 'SMS', \(Fixture.nowNs), 1, 0, 0)
            """)
        let ghost = try XCTUnwrap(try copy.database().fromMeRows(aboveRowID: 41558, limit: 10).first)
        XCTAssertEqual(ghost.guid, "GHOST")
        XCTAssertNil(ghost.joinedChatRowID)
        XCTAssertEqual(ghost.body, "")
        XCTAssertFalse(ghost.hasBody)
        XCTAssertEqual(ghost.service, "SMS")
        XCTAssertEqual(ghost.handle, "+15105550163")
    }

    func testProbesListTheirTransfers() throws {
        let probe = try XCTUnwrap(try db.sentRow(rowid: 41540))
        XCTAssertEqual(probe.transferNames, ["IMG_9201.HEIC"])
        XCTAssertEqual(probe.transferStates, ["IMG_9201.HEIC": 5])
        XCTAssertEqual(try db.fromMeRows(aboveRowID: 41539, limit: 1).first?.transferNames, ["IMG_9201.HEIC"])
    }

    func testTransferStatesUseTheNewestAttachmentPerName() throws {
        XCTAssertEqual(try db.transferStates(transferNames: ["IMG_4420.HEIC", "IMG_2291.HEIC", "none.png", "IMG_4420.HEIC"]),
                       ["IMG_4420.HEIC": 5, "IMG_2291.HEIC": 0])
        XCTAssertEqual(try db.transferStates(transferNames: []), [:])
        let copy = try FixtureCopy()
        try copy.exec("""
            INSERT INTO attachment (ROWID, guid, original_guid, transfer_name, transfer_state)
            VALUES (9100, 'T', 'T', 'IMG_4420.HEIC', 3)
            """)
        XCTAssertEqual(try copy.database().transferStates(transferNames: ["IMG_4420.HEIC"]), ["IMG_4420.HEIC": 3])
    }

    // MARK: UITargetSource

    func testConversationsListEveryConversationOnce() throws {
        let all = try db.conversations()
        XCTAssertEqual(all.count, 8)
        XCTAssertEqual(Set(all.map(\.canonical)).count, 8)
        XCTAssertEqual(Set(all.flatMap(\.chatRowIDs)), [2, 7, 9, 12, 19, 23, 31, 56])
        let mom = try XCTUnwrap(all.first { $0.displayName == "Mom" })
        XCTAssertEqual(mom.chatRowIDs, [7])
        XCTAssertFalse(mom.isGroup)
        XCTAssertEqual(mom.canonical, .direct(handle: "+14155550101"))
        XCTAssertEqual(mom.newestDateNs, 815_632_922_051_314_000)
        XCTAssertEqual(mom.newestPreview, TextNorm.oneLine(try text(41556)))
        let family = try XCTUnwrap(all.first { $0.displayName == "Family 🏡" })
        XCTAssertTrue(family.isGroup)
        XCTAssertEqual(family.canonical, .group(identifier: "chat836828054889214904"))
        let jordan = try XCTUnwrap(all.first { $0.displayName == "Jordan Kim" })
        XCTAssertEqual(jordan.signature.first, SignatureRow(fromMe: true, body: TextNorm.matchKey(try text(41558))))
    }

    /// The self-chat's list row shows its handle: a phone through formatPhone, an email as is, never the Me card's
    /// name. `read` and `chats` keep `You (notes)`.
    func testSelfChatSummaryShowsItsHandle() throws {
        let notes = try XCTUnwrap(try db.conversations().first { $0.chatRowIDs == [2] })
        XCTAssertEqual(notes.displayName, "+1 (415) 555-0100")
        XCTAssertEqual(try db.conversation(for: try db.resolve("2"))?.displayName, "+1 (415) 555-0100")
        XCTAssertEqual(try db.resolve("2").label, "You (notes)")
        XCTAssertEqual(try reader.chats(ChatsArgs(limit: 50)).chats.first { $0.rowid == 2 }?.label, "You (notes)")
        let copy = try FixtureCopy()
        try copy.exec("UPDATE chat SET chat_identifier = 'alex@example.com' WHERE ROWID = 2")
        let email = try XCTUnwrap(try copy.database().conversations().first { $0.chatRowIDs == [2] })
        XCTAssertEqual(email.displayName, "alex@example.com")
        XCTAssertEqual(try copy.database().resolve("2").label, "You (notes)")
    }

    /// A tapback as the newest row gives the list row's preview and time. `You removed a heart from` is the line
    /// the S3 dumps recorded; the target goes through TextNorm.oneLine inside curly quotes.
    func testSummaryPreviewOfATapbackRow() throws {
        let copy = try FixtureCopy()
        let at = Fixture.nowNs - 30 * second
        try copy.insertMessage(rowid: 41600, guid: "UNHEART-1", chat: 7, handle: 3, text: "Removed a heart",
                               fromMe: true, date: at, associatedType: 3000, associatedGUID: "p:0/\(try guid(41556))")
        let before = try XCTUnwrap(try db.conversations().first { $0.chatRowIDs == [7] })
        let mom = try XCTUnwrap(try copy.database().conversations().first { $0.chatRowIDs == [7] })
        XCTAssertEqual(mom.newestPreview,
                       "You removed a heart from \u{201C}" + TextNorm.oneLine(try text(41556)) + "\u{201D}")
        XCTAssertEqual(mom.newestDateNs, at)
        XCTAssertEqual(mom.signature, before.signature)
        XCTAssertEqual(mom.displayName, "Mom")
    }

    /// A row with only an attachment gives the list row's preview and time.
    func testSummaryPreviewOfAnAttachmentRow() throws {
        let copy = try FixtureCopy()
        let at = Fixture.nowNs - 30 * second
        try copy.insertMessage(rowid: 41600, guid: "PHOTO-1", chat: 7, handle: 3, text: "\u{FFFC}", fromMe: false,
                               date: at)
        try copy.exec("""
            INSERT INTO attachment (ROWID, guid, original_guid, filename, mime_type, transfer_name, transfer_state)
            VALUES (9100, 'PHOTO-A', 'PHOTO-A', '~/Library/Messages/Attachments/aa/00/IMG_1.HEIC', 'image/heic',
                'IMG_1.HEIC', 5);
            INSERT INTO message_attachment_join (message_id, attachment_id) VALUES (41600, 9100);
            """)
        let mom = try XCTUnwrap(try copy.database().conversations().first { $0.chatRowIDs == [7] })
        XCTAssertEqual(mom.newestPreview, "Attachment: 1 Image")
        XCTAssertEqual(mom.newestDateNs, at)
    }

    func testRowPreviewTable() {
        XCTAssertEqual(RowPreview.tapbacks.count, 28)
        for fromMe in [true, false] {
            for add in [true, false] {
                for offset in 0...6 {
                    let line = RowPreview.tapbacks[RowPreview.Key(fromMe: fromMe, add: add, offset: offset)]
                    XCTAssertEqual(line?.hasPrefix(fromMe ? "You " : "{name} "), true, "\(fromMe) \(add) \(offset)")
                    XCTAssertEqual(line?.hasSuffix(" {target}"), true, "\(fromMe) \(add) \(offset)")
                }
            }
        }
        XCTAssertEqual(RowPreview.tapbacks[RowPreview.Key(fromMe: true, add: false, offset: 0)],
                       "You removed a heart from {target}")
        XCTAssertEqual(RowPreview.fill("{name} reacted {emoji} to {target}",
                                       ["name": "{target}", "emoji": "🎉", "target": "\u{201C}x\u{201D}"]),
                       "{target} reacted 🎉 to \u{201C}x\u{201D}")
        XCTAssertEqual(RowPreview.attachments([]), nil)
        XCTAssertEqual(RowPreview.attachments([.photo, .photo]), "Attachment: 2 Images")
        XCTAssertEqual(RowPreview.attachments([.voice]), "Attachment: 1 Audio Message")
        XCTAssertEqual(RowPreview.attachments([.photo, .video]), "Attachment: 2 Files")
    }

    /// A URL balloon row is not a text bubble, so the signature skips it even when it is the newest row.
    func testSignatureSkipsLinkPreviewRows() throws {
        XCTAssertEqual(Manifest.first("link_preview_single_row"), 41434)
        let body = TextNorm.matchKey(try text(41434))
        XCTAssertFalse(body.isEmpty)
        let newest = try FixtureCopy()
        try newest.exec("DELETE FROM chat_message_join WHERE chat_id = 12 AND message_id > 41434")
        let without = try FixtureCopy()
        try without.exec("DELETE FROM chat_message_join WHERE chat_id = 12 AND message_id >= 41434")
        let family = try XCTUnwrap(try newest.database().conversations().first { $0.chatRowIDs == [12] })
        let expected = try XCTUnwrap(try without.database().conversations().first { $0.chatRowIDs == [12] })
        XCTAssertEqual(family.newestDateNs, try reader.message(MessageArgs(rowid: 41434)).message.dateNs)
        XCTAssertEqual(family.signature.count, Limits.signatureRows)
        XCTAssertFalse(family.signature.contains { $0.body == body })
        XCTAssertEqual(family.signature, expected.signature)
    }

    func testSignatureSkipsTapbacksUnsentAndEmptyRows() throws {
        for summary in try db.conversations() {
            XCTAssertLessThanOrEqual(summary.signature.count, Limits.signatureRows)
            XCTAssertTrue(summary.signature.allSatisfy { !$0.body.isEmpty && $0.body == TextNorm.matchKey($0.body) })
        }
        let dad = try XCTUnwrap(try db.conversations().first { $0.displayName == "Dad" })
        XCTAssertEqual(dad.signature.count, Limits.signatureRows)
        let shown = try reader.allVisible("Dad").filter { $0.event == nil && !$0.unsent }
            .filter { !TextNorm.matchKey($0.text).isEmpty }
        let expected = shown.sorted { ($0.dateNs, $0.rowid) > ($1.dateNs, $1.rowid) }.prefix(Limits.signatureRows)
            .map { SignatureRow(fromMe: $0.fromMe, body: TextNorm.matchKey($0.text)) }
        XCTAssertEqual(dad.signature, Array(expected))
        XCTAssertFalse(dad.signature.contains { $0.body.hasPrefix("Liked") || $0.body.hasPrefix("Loved") })

        let copy = try FixtureCopy()
        try copy.exec("UPDATE message SET date_retracted = \(Fixture.nowNs) WHERE ROWID = 41558")
        let jordan = try XCTUnwrap(try copy.database().conversations().first { $0.displayName == "Jordan Kim" })
        XCTAssertNotEqual(jordan.signature.first?.body, TextNorm.matchKey(try text(41558)))
    }

    func testConversationForAResolvedChat() throws {
        let mom = try db.resolve("Mom")
        XCTAssertEqual(try db.conversation(for: mom)?.displayName, "Mom")
        var stale = mom
        stale.canonical = CanonicalChatID(rawValue: "handle:+19995550000")
        XCTAssertEqual(try db.conversation(for: stale)?.chatRowIDs, [7])
        stale.chatRowIDs = [999]
        XCTAssertNil(try db.conversation(for: stale))
    }

    func testMessageTargetForASinglePartText() throws {
        let target = try XCTUnwrap(try db.messageTarget(rowid: 41555))
        XCTAssertEqual(target.guid, "C64923B3-EF7C-4245-936C-73CFAA286869")
        XCTAssertEqual(target.chatRowID, 7)
        XCTAssertEqual(target.canonical, try db.resolve("Mom").canonical)
        XCTAssertFalse(target.isGroupChat)
        XCTAssertFalse(target.fromMe)
        XCTAssertEqual(target.partCount, 1)
        XCTAssertTrue(target.isSinglePartText)
        XCTAssertEqual(target.senderName, "Mom")
        XCTAssertEqual(target.body, try text(41555))
        XCTAssertEqual(target.dateNs, 815_632_877_261_570_000)
        let group = try XCTUnwrap(try db.messageTarget(rowid: 41418))
        XCTAssertTrue(group.isGroupChat)
        XCTAssertTrue(group.isSinglePartText)
        XCTAssertEqual(group.senderName, "Dad")
        XCTAssertNil(try db.messageTarget(rowid: 999_999))
    }

    func testOnlySinglePartTextIsATarget() throws {
        let edited = try XCTUnwrap(try db.messageTarget(rowid: 41427))
        XCTAssertEqual(edited.dateEditedNs, 814_238_585_873_347_000)
        XCTAssertTrue(edited.isSinglePartText)
        XCTAssertNil(try db.messageTarget(rowid: Manifest.first("recently_deleted")))
        for rowid: Int64 in [41428, 40945, 40785, 41434, 41548, 41483, 40016] {
            let target = try XCTUnwrap(try db.messageTarget(rowid: rowid), "\(rowid)")
            XCTAssertFalse(target.isSinglePartText, "\(rowid)")
        }
        XCTAssertTrue(try XCTUnwrap(try db.messageTarget(rowid: 41483)).isUnsent)
    }

    func testTargetBodyIsNFC() throws {
        let nfd = try XCTUnwrap(try db.messageTarget(rowid: Manifest.first("nfd_text")))
        XCTAssertEqual(nfd.body, nfd.body.precomposedStringWithCanonicalMapping)
        XCTAssertTrue(Array(nfd.body.unicodeScalars).contains("\u{E9}"))
    }

    func testSameBodyAndMinuteCountsOtherRowsOnly() throws {
        for (a, b) in [(Int64(41089), Int64(41090)), (41487, 41488)] {
            XCTAssertEqual(try db.sameBodyAndMinuteCount(for: XCTUnwrap(db.messageTarget(rowid: a))), 1, "\(a)")
            XCTAssertEqual(try db.sameBodyAndMinuteCount(for: XCTUnwrap(db.messageTarget(rowid: b))), 1, "\(b)")
        }
        XCTAssertEqual(try db.sameBodyAndMinuteCount(for: XCTUnwrap(db.messageTarget(rowid: 41555))), 0)
        var flipped = try XCTUnwrap(try db.messageTarget(rowid: 41089))
        flipped.fromMe = true
        XCTAssertEqual(try db.sameBodyAndMinuteCount(for: flipped), 0)
        var empty = flipped
        empty.body = "  "
        XCTAssertEqual(try db.sameBodyAndMinuteCount(for: empty), 0)
    }

    func testSameMinuteOnAnyDayCountsInTheConfiguredTimeZone() throws {
        let target = try XCTUnwrap(try db.messageTarget(rowid: 41089))
        let copy = try FixtureCopy()
        let day: Int64 = 86_400 * second
        let body = target.body
        try copy.insertMessage(rowid: 41600, guid: "D3", chat: 7, handle: 3, text: body, fromMe: false,
                               date: target.dateNs + 3 * day)
        try copy.insertMessage(rowid: 41601, guid: "D3B", chat: 7, handle: 3, text: " \(body) ", fromMe: false,
                               date: target.dateNs + 5 * day)
        try copy.insertMessage(rowid: 41602, guid: "LATE", chat: 7, handle: 3, text: body, fromMe: false,
                               date: target.dateNs + 4 * day + 60 * second)
        try copy.insertMessage(rowid: 41603, guid: "OTHER", chat: 9, handle: 4, text: body, fromMe: false,
                               date: target.dateNs + 2 * day)
        let local = try copy.database()
        XCTAssertEqual(try local.sameBodyAndMinuteCount(for: target), 3)
        let kolkata = try TestStore.database(StoreConfiguration(chatDBPath: copy.path,
                                                                attachmentsRoot: Fixture.attachmentsRoot,
                                                                attachmentCacheDir: TempDir.make(),
                                                                timeZone: TimeZone(identifier: "Asia/Kolkata")!))
        XCTAssertEqual(local.clockMinute(Fixture.nowNs), 30)
        XCTAssertEqual(kolkata.clockMinute(Fixture.nowNs), 14 * 60)
    }

    func testCurrentUserReactionIsTheFoldedState() throws {
        XCTAssertEqual(try db.currentUserReaction(messageGUID: guid(Manifest.first("tapback_target_a")), part: 0), .emphasize)
        XCTAssertEqual(try db.currentUserReaction(messageGUID: guid(Manifest.first("tapback_target_c")), part: 0), .emoji("🎉"))
        XCTAssertNil(try db.currentUserReaction(messageGUID: guid(Manifest.first("tapback_target_b")), part: 0))
        XCTAssertNil(try db.currentUserReaction(messageGUID: guid(Manifest.first("tapback_target_d")), part: 0))
        let multipart = try guid(Manifest.first("tapback_target_multipart"))
        XCTAssertNil(try db.currentUserReaction(messageGUID: multipart, part: 1))
        XCTAssertNil(try db.currentUserReaction(messageGUID: multipart, part: -1))
        XCTAssertNil(try db.currentUserReaction(messageGUID: "NO-SUCH-GUID", part: 0))
    }

    func testCurrentUserReactionFoldsBpAndRemovesInRowIDOrder() throws {
        let copy = try FixtureCopy()
        let target = try guid(41465)
        try copy.insertMessage(rowid: 41600, guid: "R1", chat: 12, handle: 0, text: nil, fromMe: true,
                               date: Fixture.nowNs, associatedType: 2003, associatedGUID: "bp:\(target)")
        XCTAssertEqual(try copy.database().currentUserReaction(messageGUID: target, part: 0), .laugh)
        try copy.insertMessage(rowid: 41601, guid: "R2", chat: 12, handle: 0, text: nil, fromMe: true,
                               date: Fixture.nowNs, associatedType: 2000, associatedGUID: "p:0/\(target)")
        XCTAssertEqual(try copy.database().currentUserReaction(messageGUID: target, part: 0), .heart)
        try copy.insertMessage(rowid: 41602, guid: "R3", chat: 12, handle: 0, text: nil, fromMe: true,
                               date: Fixture.nowNs, associatedType: 3000, associatedGUID: "p:0/\(target)")
        XCTAssertNil(try copy.database().currentUserReaction(messageGUID: target, part: 0))
        try copy.insertMessage(rowid: 41603, guid: "R4", chat: 12, handle: 6, text: nil, fromMe: false,
                               date: Fixture.nowNs, associatedType: 2001, associatedGUID: "p:0/\(target)")
        XCTAssertNil(try copy.database().currentUserReaction(messageGUID: target, part: 0))
    }

    /// Messages writes a tapback row before its chat_message_join row. That row already is the user's reaction.
    func testCurrentUserReactionCountsUnjoinedRows() throws {
        let copy = try FixtureCopy()
        let target = try guid(41465)
        XCTAssertNil(try copy.database().currentUserReaction(messageGUID: target, part: 0))
        func insertUnjoined(_ rowid: Int64, type: Int) throws {
            try copy.exec("""
                INSERT INTO message (ROWID, guid, text, handle_id, service, date, is_from_me, is_read, item_type,
                    associated_message_type, associated_message_guid)
                VALUES (\(rowid), 'UNJOINED-\(rowid)', NULL, 0, 'iMessage', \(Fixture.nowNs), 1, 1, 0, \(type),
                    'p:0/\(target)');
                """)
        }
        try insertUnjoined(41600, type: 2000)
        let added = try copy.database()
        XCTAssertEqual(try added.currentUserReaction(messageGUID: target, part: 0), .heart)
        XCTAssertEqual(try added.reactionRows(aboveRowID: 41599, targetGUID: target, part: 0).map(\.rowid), [41600])
        try insertUnjoined(41601, type: 3000)
        XCTAssertNil(try copy.database().currentUserReaction(messageGUID: target, part: 0))
    }

    func testReactionRowsAreOutgoingAndAboveTheSnapshot() throws {
        let a = try guid(41418)
        XCTAssertEqual(try db.reactionRows(aboveRowID: 41400, targetGUID: a, part: 0),
                       [ReactionRowProbe(rowid: 41426, associatedType: 2004, associatedGUID: "p:0/" + a, emoji: nil,
                                         fromMe: true)])
        XCTAssertEqual(try db.reactionRows(aboveRowID: 41426, targetGUID: a, part: 0), [])
        let d = try guid(41476)
        XCTAssertEqual(try db.reactionRows(aboveRowID: 0, targetGUID: d, part: 0).map(\.rowid), [41478, 41481])
        XCTAssertEqual(try db.reactionRows(aboveRowID: 0, targetGUID: d, part: 0).map(\.associatedType), [2003, 3003])
        XCTAssertEqual(try db.reactionRows(aboveRowID: 0, targetGUID: d, part: 1), [])
        XCTAssertEqual(try db.reactionRows(aboveRowID: 0, targetGUID: d, part: -1), [])
        let c = try guid(41471)
        XCTAssertEqual(try db.reactionRows(aboveRowID: 0, targetGUID: c, part: 0).map(\.emoji), ["🎉"])
    }

    func testEditStateTracksEditsAndUnsends() throws {
        let edited = try XCTUnwrap(try db.editState(rowid: 41427))
        XCTAssertEqual(edited.dateEditedNs, 814_238_585_873_347_000)
        XCTAssertEqual(edited.dateRetractedNs, 0)
        XCTAssertEqual(edited.body, TextNorm.matchKey(try text(41427)))
        XCTAssertFalse(edited.body.isEmpty)
        for rowid: Int64 in [41483, 40978] {
            let unsent = try XCTUnwrap(try db.editState(rowid: rowid))
            XCTAssertEqual(unsent.dateRetractedNs, 0)
            XCTAssertNotEqual(unsent.dateEditedNs, 0)
            XCTAssertEqual(unsent.body, "")
        }
        let legacy = try XCTUnwrap(try db.editState(rowid: Manifest.first("unsent_legacy")))
        XCTAssertEqual(legacy.dateRetractedNs, 803_541_775_426_938_000)
        XCTAssertEqual(legacy.body, "")
        let copy = try FixtureCopy()
        try copy.exec("UPDATE message SET date_retracted = \(Fixture.nowNs) WHERE ROWID = 41555")
        XCTAssertEqual(try copy.database().editState(rowid: 41555)?.body, "")
        XCTAssertFalse(try XCTUnwrap(try db.editState(rowid: 41555)).body.isEmpty)
        XCTAssertNil(try db.editState(rowid: 999_999))
    }

    func testNewestIncomingIsTheLatestVisibleInboundRow() throws {
        XCTAssertEqual(try db.newestIncoming(for: db.resolve("Mom"))?.rowid, 41556)
        XCTAssertEqual(try db.newestIncoming(for: db.resolve("Dad"))?.rowid, try newestInbound("Dad"))
        let copy = try FixtureCopy()
        try copy.insertMessage(rowid: 41600, guid: "MINE", chat: 7, handle: 3, text: "later", fromMe: true,
                               date: Fixture.nowNs)
        try copy.exec("""
            INSERT INTO message (ROWID, guid, text, handle_id, service, date, is_from_me, associated_message_type,
                                 associated_message_guid)
            VALUES (41601, 'TB', NULL, 3, 'iMessage', \(Fixture.nowNs), 0, 2000, 'p:0/X');
            INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (7, 41601, \(Fixture.nowNs));
            """)
        let local = try copy.database()
        XCTAssertEqual(try local.newestIncoming(for: local.resolve("Mom"))?.rowid, 41556)
        var gone = try db.resolve("Mom")
        gone.canonical = CanonicalChatID(rawValue: "handle:none")
        gone.chatRowIDs = [999]
        XCTAssertNil(try db.newestIncoming(for: gone))
    }

    private func newestInbound(_ who: String) throws -> Int64 {
        try XCTUnwrap(try reader.allVisible(who).filter { !$0.fromMe && $0.event == nil }
            .max { ($0.dateNs, $0.rowid) < ($1.dateNs, $1.rowid) }).rowid
    }

    // MARK: ChatActivitySource

    func testInboundRowsAfterATimeOldestFirst() throws {
        let mom = try db.resolve("Mom")
        let rows = try db.inboundRows(in: mom, afterNs: 815_530_000_000_000_000, limit: 50)
        let expected = try reader.allVisible("Mom").filter { !$0.fromMe && $0.event == nil && $0.dateNs > 815_530_000_000_000_000 }
        XCTAssertEqual(rows.map(\.rowid), expected.map(\.rowid))
        XCTAssertFalse(rows.isEmpty)
        XCTAssertEqual(rows.map(\.dateNs), rows.map(\.dateNs).sorted())
        for row in rows {
            XCTAssertEqual(row.bodyDigest, TextNorm.textDigest(try text(row.rowid)))
            XCTAssertEqual(row.guid, try guid(row.rowid))
        }
        XCTAssertEqual(try db.inboundRows(in: mom, afterNs: 815_530_000_000_000_000, limit: 1).map(\.rowid),
                       [rows[0].rowid])
        XCTAssertEqual(try db.inboundRows(in: mom, afterNs: 815_530_000_000_000_000, limit: 0), [])
        XCTAssertEqual(try db.inboundRows(in: mom, afterNs: 815_632_922_051_314_000, limit: 5), [])
        XCTAssertEqual(try db.inboundRows(in: mom, afterNs: 815_632_922_051_313_999, limit: 5).map(\.rowid), [41556])
    }

    func testInboundRowsSkipEchoesTapbacksAndMine() throws {
        let notes = try db.resolve("2")
        let rows = try db.inboundRows(in: notes, afterNs: 0, limit: 200).map(\.rowid)
        XCTAssertTrue(Set(rows).isDisjoint(with: Manifest.edge("self_echo_assumed")))
        let dad = try db.inboundRows(in: db.resolve("Dad"), afterNs: 0, limit: 500).map(\.rowid)
        XCTAssertFalse(dad.contains(41548))
        XCTAssertTrue(Set(dad).isDisjoint(with: try db.fromMeRows(aboveRowID: 0, limit: 5_000).map(\.rowid)))
    }

    func testInboundRowsSpanTheMergedSMSChat() throws {
        let copy = try FixtureCopy()
        try copy.insertChat(rowid: 90, guid: "SMS;-;+14155550101", identifier: "+14155550101", service: "SMS", handles: [3])
        try copy.insertMessage(rowid: 41600, guid: "SMS-1", chat: 90, handle: 3, text: "by sms", fromMe: false,
                               date: 815_632_900_000_000_000, service: "SMS")
        let local = try copy.database()
        let rows = try local.inboundRows(in: local.resolve("Mom"), afterNs: 815_632_800_000_000_000, limit: 10)
        XCTAssertEqual(rows.map(\.rowid), [41555, 41600, 41556])
    }

    func testConcurrentCallsAgreeWithSerialCalls() throws {
        let conversations = try db.conversations()
        let probes = try db.fromMeRows(aboveRowID: 41000, limit: 200)
        let mismatches = Counter()
        DispatchQueue.concurrentPerform(iterations: 12) { i in
            do {
                if i % 2 == 0 {
                    if try db.conversations() != conversations { mismatches.add() }
                } else if try db.fromMeRows(aboveRowID: 41000, limit: 200) != probes {
                    mismatches.add()
                }
            } catch {
                mismatches.add()
            }
        }
        XCTAssertEqual(mismatches.value, 0)
    }
}
