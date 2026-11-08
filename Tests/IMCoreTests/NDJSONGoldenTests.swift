import XCTest
@testable import IMCore
import IMTestSupport

/// The `--json` records the release-test harness parses. scripts/tests/fixtures holds the exact bytes NDJSON.render
/// prints for these fixed records, and scripts/tests/harness-test.sh feeds the same files to lib.sh. Renaming a key
/// here fails this test, and a harness that reads a key the CLI never prints fails harness-test.sh.
final class NDJSONGoldenTests: XCTestCase {
    static let dir = Fixture.root.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("scripts/tests/fixtures", isDirectory: true)

    static let sentNs: AppleNanos = 815_640_000_000_000_000
    static let me = ChatRef(rowid: 7, label: "Me", isGroup: false)
    static let meChat = ChatRecord(rowid: 7, guid: "iMessage;-;me@example.com", identifier: "me@example.com",
                                   canonical: CanonicalChatID(rawValue: "direct:me@example.com"), displayName: "",
                                   label: "Me", isGroup: false, memberNames: [], service: "iMessage", unreadCount: 2)

    static func msg(_ rowid: Int64, _ text: String, me: Bool, from: String = "Ann", at offset: Int64 = 0,
                    read: Bool = true) -> MessageRecord {
        MessageRecord(rowid: rowid, guid: "G\(rowid)", chatRowID: 7, dateNs: sentNs + offset * 60_000_000_000, fromMe: me,
                      senderName: me ? "You" : from, text: text, isRead: read)
    }

    static func heic(_ rowid: Int64, state: Int) -> AttachmentRecord {
        AttachmentRecord(rowid: rowid, guid: "A\(rowid)", kind: .photo, transferName: "IMG_0001.HEIC",
                         mimeType: "image/heic", uti: "public.heic", totalBytes: 2_400_000, width: 4032, height: 3024,
                         transferState: state)
    }

    /// Every golden file and the payload it holds.
    static var cases: [(name: String, payload: ResponsePayload)] {
        var hearted = msg(101, "hi", me: true)
        hearted.dateDeliveredNs = sentNs + 2_000_000_000
        hearted.reactions = [ReactionRecord(kind: .like, actorName: "Ann", fromMe: false, part: 0, rowid: 110),
                             ReactionRecord(kind: .heart, actorName: "You", fromMe: true, part: 0, rowid: 111)]
        var file = msg(202, "", me: true, at: 1)
        file.attachments = [heic(9901, state: 5)]
        file.dateDeliveredNs = sentNs + 64_000_000_000
        var pending = msg(203, "", me: true, at: 2)
        pending.attachments = [heic(9902, state: 1)]

        var multi = msg(3, "look", me: true, at: 3)
        multi.partCount = 2
        multi.attachments = [heic(9903, state: 5)]
        var unsent = msg(4, "", me: true, at: 4)
        unsent.unsent = true
        let page = MessagesPage(chat: meChat, messages: [
            msg(1, "a", me: true, at: 1), msg(2, "b", me: false, at: 2), multi, unsent, msg(5, "d", me: false, at: 5),
        ], totalVisible: 5, olderExists: false)
        var reply = msg(62, "reply", me: true, at: 3)
        reply.replyTo = ReplyRef(rowid: 61, senderName: "Ann", text: "second")
        let replied = MessagesPage(chat: meChat, messages: [msg(61, "second", me: false, at: 2), reply], totalVisible: 2,
                                   olderExists: false)

        let unread = UnreadPage(groups: [UnreadGroup(chat: meChat, entries: [
            UnreadEntry(message: msg(40, "context", me: false, at: 1), isUnread: false, gapBefore: false),
            UnreadEntry(message: msg(41, "a", me: false, at: 2, read: false), isUnread: true, gapBefore: false),
            UnreadEntry(message: msg(42, "b", me: false, at: 3, read: false), isUnread: true, gapBefore: false),
        ], unreadCount: 2)], totalUnread: 2)

        let send = SendOutcome(chat: me, approved: true, early: nil, text: "hi", threadParentRowID: nil, parts: [
            SendPartOutcome(part: .text, result: ActionResult(.submitted), rowid: 201, guid: "G201"),
            SendPartOutcome(part: .file, result: ActionResult(.submitted, notes: [.chatUnconfirmed]), rowid: 202,
                            guid: "G202", attachment: heic(9901, state: 1)),
        ], replayed: false)
        let denied = SendOutcome(chat: me, approved: false, early: ActionResult(.denied(.user)), text: "hi",
                                 threadParentRowID: nil, parts: [], replayed: false)
        func react(_ result: ActionResult) -> UIOutcome {
            UIOutcome(action: .react, targetRowID: 101, chat: me, tapback: .heart, remove: false, approved: false,
                      result: result, currentReaction: nil, replayed: false,
                      targetQuote: ReplyRef(rowid: 101, senderName: "You", text: "hi"))
        }

        return [
            ("show-heart", .message(MessageDetail(message: hearted, chat: me, fromByte: 0, totalBytes: 2))),
            ("show-file", .message(MessageDetail(message: file, chat: me, fromByte: 0, totalBytes: 0))),
            ("show-file-pending", .message(MessageDetail(message: pending, chat: me, fromByte: 0, totalBytes: 0))),
            ("read", .messages(page)),
            ("read-reply", .messages(replied)),
            ("read-empty", .messages(MessagesPage(chat: meChat, messages: [], totalVisible: 0, olderExists: false))),
            ("wait", .wait(WaitOutcome(chat: me, message: msg(61, "second", me: false, at: 2, read: false),
                                       timedOut: false))),
            ("wait-timeout", .wait(WaitOutcome(chat: nil, message: nil, timedOut: true))),
            ("unread", .unread(unread)),
            ("unread-none", .unread(UnreadPage(groups: [], totalUnread: 0))),
            ("show-not-found", .failure(WireError.message("no message 101", fix: "imessage read <who>"))),
            ("send-file", .send(send)),
            ("send-denied", .send(denied)),
            ("react", .ui(react(ActionResult(.ok)))),
            ("react-ambiguous", .ui(react(ActionResult(.ambiguous(.target))))),
        ]
    }

    func testRecordsMatchTheGoldenFilesByteForByte() throws {
        var seen: [String] = []
        for c in Self.cases {
            let url = Self.dir.appendingPathComponent("\(c.name).ndjson")
            let got = Data(NDJSON.render(c.payload).utf8)
            seen.append(url.lastPathComponent)
            let want = try? Data(contentsOf: url)
            if got != want {
                let out = FileManager.default.temporaryDirectory.appendingPathComponent("ndjson-golden-actual")
                try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
                try? got.write(to: out.appendingPathComponent(url.lastPathComponent))
                XCTFail("\(c.name): NDJSON differs from \(url.path). The new output is in \(out.path)\n"
                        + String(decoding: got, as: UTF8.self))
            }
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: Self.dir.path).filter { $0.hasSuffix(".ndjson") }
        XCTAssertEqual(Set(files), Set(seen), "every golden file has a case")
    }

    /// The keys the harness reads, named here so a reader sees what the golden files pin.
    func testGoldenFilesHoldTheKeysTheHarnessReads() throws {
        func records(_ name: String) throws -> [[String: Any]] {
            let text = try String(contentsOf: Self.dir.appendingPathComponent("\(name).ndjson"), encoding: .utf8)
            return try text.split(separator: "\n").map {
                try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
            }
        }
        let show = try records("show-heart")
        XCTAssertEqual(show.map { $0["type"] as? String }, ["chat", "message"])
        let react = try XCTUnwrap(show[1]["react"] as? [[String: Any]])
        XCTAssertEqual(react.map { $0["by"] as? String }, ["Ann", "You"])
        XCTAssertEqual(react.map { $0["kind"] as? String }, ["like", "heart"])
        XCTAssertEqual(show[1]["me"] as? Bool, true)
        XCTAssertNotNil(show[1]["delivered"] as? Int64)
        let file = try records("show-file")[1]
        let att = try XCTUnwrap((file["att"] as? [[String: Any]])?.first)
        XCTAssertEqual(att["state"] as? Int, 5)
        XCTAssertEqual(att["uti"] as? String, "public.heic")
        XCTAssertEqual(att["id"] as? Int, 9901)
        let read = try records("read")
        XCTAssertEqual(read.first?["type"] as? String, "chat")
        XCTAssertEqual(read[3]["parts"] as? Int, 2)
        XCTAssertNil(read[1]["parts"], "a single-part message has no parts key")
        XCTAssertEqual(try records("read-reply").last?["reply"] as? Int, 61)
        let wait = try records("wait")
        XCTAssertEqual(wait.map { $0["type"] as? String }, ["chat", "message"])
        XCTAssertEqual(wait[1]["id"] as? Int, 61)
        let send = try records("send-file")[0]
        let parts = try XCTUnwrap(send["parts"] as? [[String: Any]])
        XCTAssertEqual(parts.map { $0["part"] as? String }, ["text", "file"])
        XCTAssertEqual(parts.map { $0["rowid"] as? Int }, [201, 202])
        XCTAssertEqual((try records("react")[0]["result"] as? [String: Any])?["code"] as? String, "ok")
    }
}
