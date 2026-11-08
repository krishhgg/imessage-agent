import XCTest
@testable import IMCore

/// Frames are a 4-byte big-endian length plus UTF-8 JSON, at most 8 MiB. Uploads follow raw, at most 100 MB.
final class WireTests: XCTestCase {
    func testLimits() {
        XCTAssertEqual(Limits.maxFrameBytes, 8 * 1024 * 1024)
        XCTAssertEqual(Limits.maxUploadBytes, 100_000_000)
        XCTAssertEqual(FrameCodec.headerBytes, 4)
    }

    func testHeaderIsBigEndianLength() throws {
        let frame = try FrameCodec.encode(String(repeating: "x", count: 300))
        let body = frame.dropFirst(4)
        XCTAssertEqual(body.count, 302)
        XCTAssertEqual(Array(frame.prefix(4)), [0, 0, 0x01, 0x2E])
        XCTAssertEqual(try FrameCodec.bodyLength(header: Data([0x00, 0x7F, 0x03, 0x04])), 0x007F_0304)
        XCTAssertEqual(try FrameCodec.decode(String.self, body: Data(body)).count, 300)
    }

    func testFrameCapBoundary() throws {
        let max = Limits.maxFrameBytes
        var header = Data(count: 4)
        func set(_ n: UInt32) {
            header = Data([UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)])
        }
        set(UInt32(max))
        XCTAssertEqual(try FrameCodec.bodyLength(header: header), max)
        set(UInt32(max + 1))
        XCTAssertThrowsError(try FrameCodec.bodyLength(header: header)) {
            XCTAssertEqual($0 as? FrameCodec.FrameError, .tooLarge(max + 1))
        }
        set(UInt32.max)
        XCTAssertThrowsError(try FrameCodec.bodyLength(header: header)) {
            XCTAssertEqual($0 as? FrameCodec.FrameError, .tooLarge(Int(UInt32.max)))
        }
        XCTAssertThrowsError(try FrameCodec.bodyLength(header: Data([0, 0, 1]))) {
            XCTAssertEqual($0 as? FrameCodec.FrameError, .truncated)
        }

        // A JSON string body is the text plus two quotes.
        XCTAssertEqual(try FrameCodec.encode(String(repeating: "a", count: max - 2)).count, max + 4)
        XCTAssertThrowsError(try FrameCodec.encode(String(repeating: "a", count: max - 1))) {
            XCTAssertEqual($0 as? FrameCodec.FrameError, .tooLarge(max + 1))
        }
    }

    func testEveryRequestBodyRoundTrips() throws {
        let bodies: [RequestBody] = [
            .chats(ChatsArgs(limit: 5, unreadOnly: true)), .unread(UnreadArgs(context: 0)),
            .messages(MessagesArgs(who: "Mom", limit: 10, around: 41000, sinceNs: 5)),
            .message(MessageArgs(rowid: 40927, fromByte: 8192)),
            .search(SearchArgs(text: "jalebi", inWho: "12", cursor: "1:2:3", limit: 3)),
            .contacts(ContactsArgs(name: "Mom")), .changes(ChangesArgs(since: "41000:5")),
            .wait(WaitArgs(fromWho: "Mom", timeout: 30)), .attachment(AttachmentArgs(id: 9904)),
            .send(SendArgs(who: "Mom", text: "hi", again: true, thread: true)),
            .ui(UIArgs(action: .react(rowid: 41418, kind: .emoji("🎉"), remove: true))),
            .ui(UIArgs(action: .unsend(rowid: 1))), .ui(UIArgs(action: .edit(rowid: 2, text: "new"))),
            .allow(AllowArgs(who: "Mom", files: true)), .allow(AllowArgs(who: nil, foreground: true)),
            .revoke(RevokeArgs(who: nil, foreground: true)), .pending(PendingArgs(id: "ab12")), .caps, .status,
            .setup(SetupArgs(stage: .automation)), .doctor(DoctorArgs(wantUIActions: true)), .ping,
        ]
        XCTAssertEqual(Set(bodies.map(\.op)), Set(Op.allCases))
        for body in bodies {
            let request = Request(id: "r", body: body, upload: UploadHeader(byteCount: 3, fileName: "a.txt"))
            let frame = try FrameCodec.encode(request)
            let decoded = try FrameCodec.decode(Request.self, body: frame.dropFirst(4))
            XCTAssertEqual(decoded, request)
            XCTAssertEqual(decoded.v, 1)
        }
        let response = Response(id: "r", payload: .failure(WireError.message("bad request")))
        XCTAssertEqual(try FrameCodec.decode(Response.self, body: try FrameCodec.encode(response).dropFirst(4)), response)
    }

    func testUploadHeaderValidity() {
        let max = Limits.maxUploadBytes
        XCTAssertTrue(UploadHeader(byteCount: 0, fileName: "a.txt").isValid)
        XCTAssertTrue(UploadHeader(byteCount: max, fileName: "IMG_4420.HEIC").isValid)
        XCTAssertFalse(UploadHeader(byteCount: max + 1, fileName: "a.txt").isValid)
        XCTAssertFalse(UploadHeader(byteCount: -1, fileName: "a.txt").isValid)
        for bad in ["", ".", "..", "a/b", "/etc/passwd", "a\u{0}b"] {
            XCTAssertFalse(UploadHeader(byteCount: 1, fileName: bad).isValid, bad)
        }
        XCTAssertTrue(UploadHeader(byteCount: 1, fileName: String(repeating: "n", count: 255)).isValid)
        XCTAssertFalse(UploadHeader(byteCount: 1, fileName: String(repeating: "n", count: 256)).isValid)
    }

    func testSearchAndChangeCursorsRoundTrip() {
        let c = SearchCursor(dateNs: 815_646_600_000_000_000, rowid: 41418, windowStartNs: -5)
        XCTAssertEqual(c.text, "815646600000000000:41418:-5")
        XCTAssertEqual(SearchCursor(text: c.text), c)
        for bad in ["", "1:2", "1:2:3:4", "a:2:3", "1::3"] { XCTAssertNil(SearchCursor(text: bad), bad) }
        XCTAssertEqual(ChangeCursor(text: "41000:77"), ChangeCursor(rowid: 41000, timeNs: 77))
        let cc = ChangeCursor(rowid: 41000, timeNs: 815_646_600_000_000_000)
        XCTAssertEqual(ChangeCursor(text: cc.text), cc)
        let tied = ChangeCursor(rowid: 41000, timeNs: 77, tieRowID: 40100)
        XCTAssertEqual(tied.text, "41000:77:40100")
        XCTAssertEqual(ChangeCursor(text: tied.text), tied)
        XCTAssertNotEqual(ChangeCursor(text: "41000:77:40100"), ChangeCursor(text: "41000:77"))
        XCTAssertTrue(tied.isBefore(time: 77, rowid: 40101))
        XCTAssertFalse(tied.isBefore(time: 77, rowid: 40100))
        XCTAssertTrue(tied.isBefore(time: 78, rowid: 1))
        XCTAssertFalse(ChangeCursor(rowid: 41000, timeNs: 77).isBefore(time: 77, rowid: .max))
        XCTAssertTrue(ChangeCursor(rowid: 41000, timeNs: 77).isBefore(time: 78, rowid: 1))
        for bad in ["", ":", ":5", "5:", "5::3", ":5:3", "5:3:", "a:b", "1:2:x", "1:2:3:4", "1:x"] {
            XCTAssertNil(ChangeCursor(text: bad), bad)
        }
    }

    func testTapbackKindFromAssociatedType() {
        let named: [TapbackKind] = [.heart, .like, .dislike, .laugh, .emphasize, .question]
        for (i, kind) in named.enumerated() {
            XCTAssertEqual(TapbackKind(associatedType: 2000 + i, emoji: nil), kind)
            XCTAssertEqual(TapbackKind(associatedType: 3000 + i, emoji: nil), kind)
        }
        XCTAssertEqual(TapbackKind(associatedType: 2006, emoji: "🔥"), .emoji("🔥"))
        XCTAssertEqual(TapbackKind(associatedType: 3006, emoji: "🔥"), .emoji("🔥"))
        XCTAssertNil(TapbackKind(associatedType: 2006, emoji: nil))
        XCTAssertNil(TapbackKind(associatedType: 2006, emoji: ""))
        // Stickers (1000), plain rows (0) and other families are not tapbacks.
        for t in [0, 1, 6, 1000, 1001, 2007, 3007, 4000, 5000, -1000, -2000] {
            XCTAssertNil(TapbackKind(associatedType: t, emoji: "🔥"), "\(t)")
        }
    }

    func testTapbackKindWireNames() {
        XCTAssertEqual(TapbackKind(wireName: "Love"), .heart)
        XCTAssertEqual(TapbackKind(wireName: "emphasis"), .emphasize)
        XCTAssertEqual(TapbackKind(wireName: "🔥"), .emoji("🔥"))
        for bad in ["", "wow", "hearts"] { XCTAssertNil(TapbackKind(wireName: bad), bad) }
        for kind in [TapbackKind.heart, .like, .dislike, .laugh, .emphasize, .question, .emoji("🔥")] {
            XCTAssertEqual(TapbackKind(wireName: kind.wireName), kind)
        }
    }

    func testDoctorReportDecodesWithoutReleaseFlag() throws {
        let json = Data(#"{"checks":[{"name":"chat.db","ok":true}],"needsKickstart":false}"#.utf8)
        let r = try JSONDecoder.wire.decode(DoctorReport.self, from: json)
        XCTAssertFalse(r.releaseTestBuild)
        let flagged = DoctorReport(checks: [], needsKickstart: false, releaseTestBuild: true)
        XCTAssertEqual(try JSONDecoder.wire.decode(DoctorReport.self, from: JSONEncoder.wire.encode(flagged)), flagged)
    }
}
