import CryptoKit
import Foundation
import XCTest
import IMCore
@testable import IMStore
import IMTestSupport

/// Checklist items 6 to 8: attributedBody decoding, tapback folding and message_summary_info.
final class DecodingTests: XCTestCase {
    private func blobs(_ sql: String, _ params: [SQLiteValue] = []) throws -> [(Int64, Data?, String?)] {
        let conn = try SQLiteConnection(readOnlyPath: Fixture.chatDB.path)
        defer { conn.close() }
        var out: [(Int64, Data?, String?)] = []
        try conn.query(sql, params + [.int(10_000)]) { out.append(($0.int(0), $0.blob(1), $0.text(2))) }
        return out
    }

    private func summaryBlob(_ rowid: Int64) throws -> Data {
        let rows = try blobs("SELECT ROWID, message_summary_info, NULL FROM message WHERE ROWID = ? LIMIT ?",
                             [.int(rowid)])
        return try XCTUnwrap(rows.first?.1)
    }

    // MARK: Item 6, attributedBody when text is NULL

    func testDecodedBodiesMatchTheManifestDigest() throws {
        let rows = try blobs("SELECT ROWID, attributedBody, text FROM message WHERE attributedBody IS NOT NULL "
                             + "ORDER BY ROWID LIMIT ?")
        let bodies = Manifest.json["bodies"] as! [String: Any]
        XCTAssertEqual(rows.count, (bodies["count"] as! NSNumber).intValue)
        var lines = Data()
        for (rowid, blob, _) in rows {
            let decoded = try TypedStreamDecoder.decodeAttributedString(try XCTUnwrap(blob))
            lines.append(Data("\(rowid)\t\(decoded.text)\n".utf8))
        }
        let digest = SHA256.hash(data: lines).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, bodies["sha256"] as? String)
    }

    func testRowsWithNullTextReadTheirBodyFromAttributedBody() throws {
        let rows = try blobs("SELECT ROWID, attributedBody, text FROM message WHERE text IS NULL "
                             + "AND attributedBody IS NOT NULL ORDER BY ROWID LIMIT ?")
        XCTAssertEqual(rows.count, 1424)
        let samples = Manifest.json["samples"] as! [[String: Any]]
        var checked = 0
        for sample in samples {
            let rowid = (sample["rowid"] as! NSNumber).int64Value
            guard let row = rows.first(where: { $0.0 == rowid }) else { continue }
            XCTAssertNil(row.2)
            XCTAssertEqual(MessageRow.decode(text: row.2, body: row.1).text, sample["body"] as? String, "row \(rowid)")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 3)
        let record = try TestStore.reader().message(MessageArgs(rowid: Manifest.first("nfc_text"))).message
        XCTAssertEqual(record.text, "the café with the blue door? yes")
    }

    func testTextColumnIsTheFallbackWhenTheBodyIsMissingOrBroken() {
        XCTAssertEqual(MessageRow.decode(text: "plain", body: nil).text, "plain")
        XCTAssertEqual(MessageRow.decode(text: "plain", body: Data()).text, "plain")
        XCTAssertEqual(MessageRow.decode(text: "plain", body: Data("garbage".utf8)).text, "plain")
        XCTAssertNil(MessageRow.decode(text: nil, body: nil).text)
    }

    func testAttributedBodyWinsOverTheTextColumn() throws {
        let rows = try blobs("SELECT ROWID, attributedBody, text FROM message WHERE text IS NOT NULL "
                             + "AND attributedBody IS NOT NULL ORDER BY ROWID LIMIT ?")
        let (_, blob, text) = try XCTUnwrap(rows.first)
        let decoded = MessageRow.decode(text: "a different text column", body: blob)
        XCTAssertEqual(decoded.text, try TypedStreamDecoder.decodeAttributedString(try XCTUnwrap(blob)).text)
        XCTAssertNotNil(text)
    }

    func testEveryTruncationOfABodyThrowsInsteadOfCrashing() throws {
        let rows = try blobs("SELECT ROWID, attributedBody, NULL FROM message WHERE ROWID = ? LIMIT ?",
                             [.int(Manifest.first("multipart"))])
        let blob = try XCTUnwrap(rows.first?.1)
        XCTAssertNoThrow(try TypedStreamDecoder.decodeAttributedString(blob))
        for n in 0..<blob.count {
            XCTAssertThrowsError(try TypedStreamDecoder.decodeAttributedString(blob.prefix(n)), "prefix \(n)")
        }
    }

    func testCorruptedBytesNeverCrash() throws {
        let rows = try blobs("SELECT ROWID, attributedBody, NULL FROM message WHERE attributedBody IS NOT NULL "
                             + "ORDER BY ROWID LIMIT ?")
        var generator = SystemRandomNumberGenerator()
        for (_, blob, _) in rows.prefix(40) {
            var bytes = [UInt8](try XCTUnwrap(blob))
            for _ in 0..<8 { bytes[Int.random(in: 0..<bytes.count, using: &generator)] = UInt8.random(in: 0...255) }
            _ = try? TypedStreamDecoder.decodeAttributedString(Data(bytes))
        }
        XCTAssertThrowsError(try TypedStreamDecoder.decodeAttributedString(Data("not a typedstream".utf8)))
    }

    /// An attribute run whose NSArray holds itself twice. Walking it by value branches on every level, so the walk
    /// has a work budget and the blob fails with `limitExceeded`; `MessageRow.decode` then uses the text column.
    func testSelfReferencingAttributeRunHitsTheWorkLimit() throws {
        func string(_ s: String) -> [UInt8] { [0x84, UInt8(s.utf8.count)] + Array(s.utf8) }
        func cls(_ name: String, version: UInt8) -> [UInt8] { [0x84] + string(name) + [version, 0x85] }
        var bytes: [UInt8] = [0x04] + [UInt8(11)] + Array("streamtyped".utf8) + [0x81, 0xE8, 0x03]
        bytes += string("@")                                    // root types, string 0
        bytes += [0x84] + cls("NSAttributedString", version: 0) // object 0, class object 1
        bytes += [0x92, 0x84] + cls("NSString", version: 1)     // object 2, class object 3
        bytes += string("+") + [0x05] + Array("hello".utf8) + [0x86]
        bytes += string("ii") + [0x01, 0x05]                    // the run: start 1, length 5
        bytes += [0x92, 0x84] + cls("NSArray", version: 0)      // object 4, class object 5
        bytes += string("i") + [0x02]
        bytes += [0x92, 0x96, 0x92, 0x96, 0x86]                 // two references to object 4
        bytes += [0x86]
        let blob = Data(bytes)
        let done = expectation(description: "decode returns")
        var result: Result<DecodedBody, Error>?
        DispatchQueue.global().async {
            result = Result { try TypedStreamDecoder.decodeAttributedString(blob) }
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        guard let result else { return XCTFail("decode did not return") }
        XCTAssertThrowsError(try result.get()) { error in
            XCTAssertEqual(error as? TypedStreamDecoder.DecodeError, .limitExceeded)
        }
        XCTAssertEqual(MessageRow.decode(text: "fallback", body: blob).text, "fallback")

        // The same blob with an empty array instead decodes, so the bytes above are a valid stream.
        var plain = Array(bytes.dropLast(6))
        plain[plain.count - 1] = 0x00
        plain += [0x86, 0x86]
        let decoded = try TypedStreamDecoder.decodeAttributedString(Data(plain))
        XCTAssertEqual(decoded.text, "hello")
        XCTAssertEqual(decoded.runs.map(\.utf16Length), [5])
    }

    func testRunsCarryPartsAndFileTransfers() throws {
        let reader = try TestStore.reader()
        let photo = try reader.message(MessageArgs(rowid: Manifest.first("photo_heic"), fromByte: 0)).message
        XCTAssertEqual(photo.attachments.first?.rowid, 9014)
        XCTAssertEqual(photo.attachments.first?.width, 4032)
        XCTAssertEqual(photo.attachments.first?.height, 3024)
        let multipart = try reader.message(MessageArgs(rowid: Manifest.first("multipart"), fromByte: 0)).message
        XCTAssertEqual(multipart.partCount, 2)
    }

    // MARK: Item 7, tapback folding per actor and part

    func testFoldedReactionsMatchTheManifestNetState() throws {
        let reader = try TestStore.reader()
        let expected = Manifest.json["tapback_net_state"] as! [String: [String: Any]]
        XCTAssertEqual(expected.count, 5)
        for (name, entry) in expected {
            let rowid = (entry["rowid"] as! NSNumber).int64Value
            let parts = entry["parts"] as! [String: [String]]
            let record = try reader.message(MessageArgs(rowid: rowid, fromByte: 0)).message
            for (part, lines) in parts {
                let got = record.reactions.filter { $0.part == Int(part)! }.map { "\($0.kind.displayEmoji) \($0.actorName)" }
                XCTAssertEqual(got, lines, "\(name) part \(part)")
            }
            XCTAssertEqual(record.reactions.count, parts.values.reduce(0) { $0 + $1.count }, name)
        }
    }

    func testReadFoldsTheSameReactionsAsShow() throws {
        let reader = try TestStore.reader()
        let page = try reader.messages(MessagesArgs(who: "12", limit: 200, around: 41418))
        let shown = try XCTUnwrap(page.message(41418))
        let single = try reader.message(MessageArgs(rowid: 41418, fromByte: 0)).message
        XCTAssertEqual(shown.reactions, single.reactions)
    }

    func testBpPrefixFoldsIntoPartZero() throws {
        let link = try TestStore.reader().message(MessageArgs(rowid: Manifest.first("link_preview_single_row"),
                                                              fromByte: 0)).message
        XCTAssertEqual(link.reactions.map { "\($0.kind.displayEmoji) \($0.actorName) \($0.part)" }, ["❤️ Priya 0"])
        XCTAssertEqual(link.reactions.first?.rowid, Manifest.first("tapback_bp_prefix"))
    }

    func testParseTarget() {
        XCTAssertEqual(TapbackFolder.parseTarget("p:0/ABC").part, 0)
        XCTAssertEqual(TapbackFolder.parseTarget("p:0/ABC").guid, "ABC")
        XCTAssertEqual(TapbackFolder.parseTarget("p:12/ABC-1").part, 12)
        XCTAssertEqual(TapbackFolder.parseTarget("p:12/ABC-1").guid, "ABC-1")
        XCTAssertEqual(TapbackFolder.parseTarget("bp:ABC").part, 0)
        XCTAssertEqual(TapbackFolder.parseTarget("bp:ABC").guid, "ABC")
        XCTAssertEqual(TapbackFolder.parseTarget("ABC").guid, "ABC")
        XCTAssertEqual(TapbackFolder.parseTarget("p:x/ABC").guid, "p:x/ABC")
        XCTAssertEqual(TapbackFolder.parseTarget("p:/ABC").guid, "p:/ABC")
    }

    private func row(_ id: Int64, _ target: String, _ type: Int, _ actor: String?, me: Bool = false,
                     emoji: String? = nil) -> TapbackFolder.Row {
        TapbackFolder.Row(rowid: id, associatedGUID: target, associatedType: type, emoji: emoji, fromMe: me,
                          actorHandle: actor)
    }

    private func names(_ rows: [TapbackFolder.Row]) -> [String] {
        let folded = TapbackFolder.fold(rows) { $0 == "+14155550101" ? "Mom" : ($0 ?? "?") }
        return (folded["G"] ?? []).map { "\($0.part) \($0.kind.displayEmoji) \($0.actorName)" }
    }

    func testOneReactionPerActorAndPartWithTheLatestWinning() {
        XCTAssertEqual(names([row(1, "p:0/G", 2000, "+14155550101"), row(2, "p:0/G", 2001, "+14155550101")]),
                       ["0 👍 Mom"])
        XCTAssertEqual(names([row(1, "p:0/G", 2000, "+14155550101"), row(2, "p:1/G", 2001, "+14155550101")]),
                       ["0 ❤️ Mom", "1 👍 Mom"])
        XCTAssertEqual(names([row(1, "p:0/G", 2000, "+14155550101"), row(2, "p:0/G", 2000, nil, me: true)]),
                       ["0 ❤️ Mom", "0 ❤️ You"])
    }

    func testActorsMatchAfterHandleNormalization() {
        XCTAssertEqual(names([row(1, "p:0/G", 2000, "+14155550101"), row(2, "p:0/G", 3000, "(415) 555-0101")]), [])
    }

    func testRemoveTakesAwayOnlyTheMatchingKind() {
        XCTAssertEqual(names([row(1, "p:0/G", 2000, "+14155550101"), row(2, "p:0/G", 3001, "+14155550101")]),
                       ["0 ❤️ Mom"])
        XCTAssertEqual(names([row(1, "p:0/G", 2000, "+14155550101"), row(2, "p:0/G", 3000, "+14155550101")]), [])
        XCTAssertEqual(names([row(1, "p:0/G", 2000, "+14155550101"), row(2, "p:1/G", 3000, "+14155550101")]),
                       ["0 ❤️ Mom"])
    }

    func testEmojiRemoveNeedsTheSameEmoji() {
        let add = row(1, "p:0/G", 2006, "+14155550101", emoji: "🪔")
        XCTAssertEqual(names([add, row(2, "p:0/G", 3006, "+14155550101", emoji: "🎉")]), ["0 🪔 Mom"])
        XCTAssertEqual(names([add, row(2, "p:0/G", 3006, "+14155550101", emoji: "🪔")]), [])
    }

    /// `TapbackRunner` accepts a 3006 row with no emoji as the removal, so the fold must take the reaction away too.
    func testEmojiRemoveWithoutAnEmojiTakesAwayTheActorsEmoji() {
        let add = row(1, "p:0/G", 2006, "+14155550101", emoji: "🪔")
        XCTAssertEqual(names([add, row(2, "p:0/G", 3006, "+14155550101")]), [])
        XCTAssertEqual(names([add, row(2, "p:1/G", 3006, "+14155550101")]), ["0 🪔 Mom"])
        XCTAssertEqual(names([add, row(2, "p:0/G", 3006, nil, me: true)]), ["0 🪔 Mom"])
        XCTAssertEqual(names([row(1, "p:0/G", 2000, "+14155550101"), row(2, "p:0/G", 3006, "+14155550101")]),
                       ["0 ❤️ Mom"])
        XCTAssertEqual(names([row(1, "p:0/G", 2006, nil, me: true, emoji: "🪔"), row(2, "p:0/G", 3006, nil, me: true),
                              row(3, "p:0/G", 2006, nil, me: true, emoji: "🪔")]), ["0 🪔 You"])
    }

    func testRowsReplayInRowIDOrderAndBadKindsAreSkipped() {
        XCTAssertEqual(names([row(5, "p:0/G", 3000, "+14155550101"), row(4, "p:0/G", 2000, "+14155550101")]), [])
        XCTAssertEqual(names([row(1, "p:0/G", 2007, "+14155550101"), row(2, "p:0/G", 2006, "+14155550101"),
                              row(3, "p:0/G", 1000, "+14155550101"), row(4, "p:0/G", 4000, "+14155550101")]), [])
    }

    func testPartsComeOutSortedAndBpCountsAsPartZero() {
        XCTAssertEqual(names([row(1, "p:1/G", 2001, "+14155550101"), row(2, "bp:G", 2000, nil, me: true)]),
                       ["0 ❤️ You", "1 👍 Mom"])
    }

    // MARK: Item 8, message_summary_info

    func testEditCountsFromEc() throws {
        let twice = try SummaryInfo.decode(try summaryBlob(Manifest.first("edited_twice")))
        XCTAssertEqual(twice.editCount, 2)
        XCTAssertEqual(twice.editVersions[0], ["Lunch at 12 at the noodle place?", "Lunch at 12:30 at the noodle place?",
                                               "Lunch at 12:30 at the dumpling place?"])
        for rowid in Manifest.edge("edited_once") {
            XCTAssertEqual(try SummaryInfo.decode(try summaryBlob(rowid)).editCount, 1, "row \(rowid)")
        }
    }

    func testUnsentPartsFromRpAndRangesFromOtr() throws {
        let partial = try SummaryInfo.decode(try summaryBlob(Manifest.first("unsent_partial")))
        XCTAssertEqual(partial.unsentParts, [1])
        XCTAssertEqual(partial.originalRanges.keys.sorted(), [0, 1])
        XCTAssertEqual(partial.originalRanges[0], 0..<1)
        let legacy = try SummaryInfo.decode(try summaryBlob(Manifest.first("unsent_legacy")))
        XCTAssertEqual(legacy.unsentParts, [0])
        XCTAssertEqual(legacy.editCount, 0)
    }

    func testSummaryDecodeRejectsNonDictionaries() throws {
        let array = try PropertyListSerialization.data(fromPropertyList: [1, 2], format: .binary, options: 0)
        XCTAssertThrowsError(try SummaryInfo.decode(array)) { error in
            guard case StoreError.decode = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try SummaryInfo.decode(Data("junk".utf8)))
        let empty = try PropertyListSerialization.data(fromPropertyList: [String: Any](), format: .binary, options: 0)
        XCTAssertEqual(try SummaryInfo.decode(empty).editCount, 0)
    }

    func testEditedUnsentAndPartUnsentFlagsOnRecords() throws {
        let reader = try TestStore.reader()
        func record(_ id: Int64) throws -> MessageRecord { try reader.message(MessageArgs(rowid: id, fromByte: 0)).message }
        XCTAssertTrue(try record(Manifest.first("edited_twice")).edited)
        for id in Manifest.edge("edited_once") { XCTAssertTrue(try record(id).edited, "row \(id)") }
        for name in ["unsent_legacy", "unsent_modern_outgoing", "unsent_modern_incoming"] {
            let r = try record(Manifest.first(name))
            XCTAssertTrue(r.unsent, name)
            XCTAssertFalse(r.partUnsent, name)
            XCTAssertEqual(r.text, "", name)
        }
        let partial = try record(Manifest.first("unsent_partial"))
        XCTAssertTrue(partial.partUnsent)
        XCTAssertFalse(partial.unsent)
        let plain = try record(Manifest.first("nfc_text"))
        XCTAssertFalse(plain.edited || plain.unsent || plain.partUnsent)
    }
}
