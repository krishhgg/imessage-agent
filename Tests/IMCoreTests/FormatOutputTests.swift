import XCTest
@testable import IMCore
import IMTestSupport

/// Properties every output shares: dispatch, one trailing newline, no stray line breaks, NDJSON records, and the
/// same text from many threads at once.
final class FormatOutputTests: XCTestCase {
    let ctx = B.ctx

    /// One payload of every kind. `dirty` puts line breaks into every name, label and text a line prints.
    func payloads(dirty: Bool) -> [ResponsePayload] {
        func s(_ base: String) -> String { dirty ? base + "\n\r\u{2028}\u{85}\u{0B}x" : base + " x" }
        let chatRef = ChatRef(rowid: 7, label: s("Mom"), isGroup: false)
        let groupRef = ChatRef(rowid: 12, label: s("Fam"), isGroup: true)
        var m = B.msg(100, s("hello"), from: s("Mom"))
        m.replyTo = ReplyRef(rowid: 50, senderName: s("Dad"), text: s("quote"))
        m.attachments = [AttachmentRecord(rowid: 9902, guid: "g", kind: .file, transferName: s("menu.pdf"), totalBytes: 10),
                         AttachmentRecord(rowid: 9903, guid: "g", kind: .voice, transferName: "v.caf", transcript: s("words"))]
        m.reactions = [B.reaction(.heart, s("Priya"), rowid: 1)]
        m.stickers = [StickerRecord(actorName: s("Dad"), fromMe: false, part: 0, rowid: 2)]
        var linked = B.msg(101, "https://example.com/a")
        linked.link = LinkRecord(url: "https://example.com/a", site: s("example.com"), title: s("A post"))
        var event = B.msg(102, "", from: s("Dad"))
        event.event = EventRecord(kind: .renamed, actorName: s("Dad"), title: s("Desai Fam"), itemType: 2, groupActionType: 0)
        let chat = B.chat(7, s("Mom"), last: m)
        let group = B.chat(12, s("Fam"), group: true, name: s("Fam"), members: [s("Mom"), s("Dad")], last: event)
        let contact = ContactRecord(shortName: s("Mom"), firstName: s("Meera"), lastName: s("Desai"),
                                    handles: [HandleRecord(id: s("a@b.c"), services: [s("iMessage")])], chats: [chatRef, groupRef])
        let quote = ReplyRef(rowid: 100, senderName: s("Mom"), text: s("hello"))
        let att = AttachmentRecord(rowid: 9904, guid: "g", kind: .photo, transferName: s("IMG.HEIC"), totalBytes: 5)
        return [
            .chats(ChatsPage(chats: [chat, group], hasMore: true, limit: 20)),
            .unread(UnreadPage(groups: [UnreadGroup(chat: group, entries: [
                UnreadEntry(message: m, isUnread: false, gapBefore: false),
                UnreadEntry(message: linked, isUnread: true, gapBefore: true),
            ], unreadCount: 1)], totalUnread: 1)),
            .messages(MessagesPage(chat: group, messages: [m, linked, event], totalVisible: 9, olderExists: true)),
            .message(MessageDetail(message: B.msg(100, "body", from: s("Mom")), chat: chatRef, fromByte: 0, totalBytes: 4)),
            .search(SearchPage(query: s("q"), inChat: groupRef, hits: [SearchHit(chat: groupRef, message: m)],
                               scannedBackToNs: 0, windowStartNs: 0, nextCursor: "1:2:3", budgetExhausted: false)),
            .contacts(ContactsPage(query: s("Mom"), contacts: [contact])),
            .contacts(ContactsPage(query: s("nobody"), contacts: [])),
            .changes(ChangesPage(cursor: "1:2", changes: [ChangeRecord(kind: .new, chat: groupRef, message: m)], truncated: true)),
            .wait(WaitOutcome(chat: groupRef, message: m, timedOut: false)),
            .wait(WaitOutcome(chat: nil, message: nil, timedOut: true)),
            .attachment(AttachmentExport(attachment: att, path: s("/cache/9904.jpg"), converted: true, result: nil)),
            .attachment(AttachmentExport(attachment: att, path: nil, converted: false,
                                         result: ActionResult(.notDownloaded, notes: [.axState(s("field"))]))),
            .send(SendOutcome(chat: chatRef, approved: true, early: nil, text: s("hi"), threadParentRowID: 41418, parts: [
                SendPartOutcome(part: .text, result: ActionResult(.delivered), rowid: 1),
                SendPartOutcome(part: .file, result: ActionResult(.failed(.rowError(22))), rowid: 2, attachment: att),
            ], replayed: true)),
            .send(SendOutcome(chat: chatRef, approved: false, early: ActionResult(.error(.message(s("no chat"))), fix: s("fix")),
                              text: nil, threadParentRowID: nil, parts: [], replayed: false)),
            .ui(UIOutcome(action: .react, targetRowID: 100, chat: groupRef, tapback: .emoji("🎉"), remove: false, approved: true,
                          result: ActionResult(.ok, notes: [.frontApp(s("Safari"))]), currentReaction: .heart, replayed: true,
                          targetQuote: quote)),
            .policy(PolicyOutcome(change: .allowChat, chat: chatRef, scope: .files,
                                  result: ActionResult(.ok, fix: s("note")))),
            .pending(PendingList(items: [PendingItem(id: "ab12", summary: s("send to Mom"), createdAt: Fixture.now,
                                                     expiresAt: Fixture.now)])),
            .caps(CapsReport(macOSVersion: s("26.2"), uiLanguageEnglish: false, accessibilityTrusted: true, foregroundMode: false,
                             entries: [CapEntry(name: s("react"), status: .supported, note: s("note"))])),
            .status(StatusReport(bridgeVersion: s("0.1"), pid: 1, fullDiskAccess: .granted, automation: .denied,
                                 accessibility: .unknown, messagesRunning: true, foregroundMode: false,
                                 foregroundOffReason: s("off"), allowlistTrusted: true, allowedChats: 2, openApprovals: 1,
                                 crashNote: s("crash"))),
            .setup(SetupReport(stage: .automation, state: .denied, openedPane: s("Automation"))),
            .doctor(DoctorReport(checks: [DoctorCheck(name: s("db"), ok: false, detail: s("detail"), fix: s("fix"))],
                                 needsKickstart: true, releaseTestBuild: true)),
            .pong(PongInfo(bridgeVersion: s("0.1"), pid: 3)),
            .failure(WireError(result: ActionResult(.error(.severalMatches), notes: [.axState(s("a"))], fix: s("pick")),
                               candidates: [Candidate(label: s("Jordan"), argument: s("23"))])),
        ]
    }

    static let strayBreaks: Set<UInt32> = [0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029]

    func testNamesAndTextsNeverAddALine() {
        let clean = payloads(dirty: false)
        let dirty = payloads(dirty: true)
        for (c, d) in zip(clean, dirty) {
            let a = Format.render(c, ctx)
            let b = Format.render(d, ctx)
            XCTAssertEqual(B.lines(b).count, B.lines(a).count, "\(c)")
            XCTAssertFalse(b.unicodeScalars.contains { Self.strayBreaks.contains($0.value) }, b)
        }
    }

    func testEveryOutputEndsWithOneNewline() {
        for p in payloads(dirty: false) + payloads(dirty: true) {
            let s = Format.render(p, ctx)
            XCTAssertTrue(s.hasSuffix("\n"), s)
            XCTAssertFalse(s.hasSuffix("\n\n"), s)
            XCTAssertFalse(s.hasPrefix("\n"), s)
        }
    }

    func testRenderDispatchesToTheVerb() {
        for p in payloads(dirty: false) {
            let expected: String
            switch p {
            case .chats(let x): expected = Format.chats(x, ctx)
            case .unread(let x): expected = Format.unread(x, ctx)
            case .messages(let x): expected = Format.messages(x, ctx)
            case .message(let x): expected = Format.show(x, ctx)
            case .search(let x): expected = Format.search(x, ctx)
            case .contacts(let x): expected = Format.who(x)
            case .changes(let x): expected = Format.changes(x, ctx)
            case .wait(let x): expected = Format.wait(x, ctx)
            case .attachment(let x): expected = Format.attachment(x)
            case .send(let x): expected = Format.send(x, ctx)
            case .ui(let x): expected = Format.ui(x, ctx)
            case .policy(let x): expected = Format.policy(x)
            case .pending(let x): expected = Format.pending(x, ctx)
            case .caps(let x): expected = Format.caps(x)
            case .status(let x): expected = Format.status(x)
            case .setup(let x): expected = Format.setup(x)
            case .doctor(let x): expected = Format.doctor(x)
            case .pong(let x): expected = "pong · bridge \(x.bridgeVersion) pid \(x.pid)\n"
            case .failure(let x): expected = Format.error(x)
            }
            XCTAssertEqual(Format.render(p, ctx), expected)
        }
    }

    // MARK: NDJSON

    func records(_ p: ResponsePayload) throws -> [[String: Any]] {
        let out = Format.ndjson(p)
        XCTAssertTrue(out.hasSuffix("\n"))
        return try B.lines(out).map { line in
            let o = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            XCTAssertNotNil(o, line)
            return o ?? [:]
        }
    }

    func testEveryNDJSONLineIsAnObjectWithAType() throws {
        for p in payloads(dirty: true) {
            let recs = try records(p)
            XCTAssertFalse(recs.isEmpty)
            for r in recs { XCTAssertNotNil(r["type"] as? String, "\(r)") }
            XCTAssertEqual(B.lines(Format.ndjson(p)).count, recs.count, "one record per line")
        }
    }

    func testNDJSONPrintsEachChatOnce() throws {
        let hits = [
            SearchHit(chat: B.family, message: B.msg(3, "a", chat: 12)), SearchHit(chat: B.family, message: B.msg(2, "b", chat: 12)),
            SearchHit(chat: B.mom, message: B.msg(1, "c")),
        ]
        let page = SearchPage(query: "q", inChat: nil, hits: hits, scannedBackToNs: Fixture.nowNs, windowStartNs: 0,
                              nextCursor: "9:9:9", budgetExhausted: true)
        let recs = try records(.search(page))
        XCTAssertEqual(recs.map { $0["type"] as? String }, ["search", "chat", "message", "message", "chat", "message"])
        XCTAssertEqual(recs[0]["cursor"] as? String, "9:9:9")
        XCTAssertEqual(recs[0]["scannedBackTo"] as? String, "2026-11-06T08:30:00Z")
        XCTAssertEqual(recs[0]["windowStart"] as? String, "2001-01-01T00:00:00Z")
        XCTAssertEqual(recs[0]["budgetExhausted"] as? Bool, true)
        XCTAssertEqual(recs[1]["id"] as? Int, 12)
        XCTAssertEqual(recs[4]["id"] as? Int, 7)
        XCTAssertEqual(recs[2]["chat"] as? Int, 12)
    }

    func testNDJSONMessageRecord() throws {
        var m = B.msg(100, String(repeating: "z", count: 500), at: Fixture.nowNs)
        m.replyTo = ReplyRef(rowid: 50, senderName: "Dad", text: "q")
        m.attachments = [AttachmentRecord(rowid: 9, guid: "g", kind: .photo, transferName: "a.jpg", uti: "public.jpeg",
                                          totalBytes: 10, width: 4, height: 3, onDisk: false, transferState: 2)]
        m.partCount = 2
        m.dateDeliveredNs = Fixture.nowNs + 5
        m.edited = true
        m.errorCode = 22
        m.reactions = [B.reaction(.heart, "Priya", rowid: 1)]
        m.link = LinkRecord(url: "https://example.com/a/b", site: "example.com", title: "T")
        m.agentSent = true
        let recs = try records(.messages(MessagesPage(chat: B.chat(7, "Mom"), messages: [m], totalVisible: 1, olderExists: false)))
        XCTAssertEqual(recs.count, 2)
        XCTAssertEqual(recs[0]["type"] as? String, "chat")
        XCTAssertEqual(recs[0]["total"] as? Int, 1)
        XCTAssertEqual(recs[0]["older"] as? Bool, false)
        let r = recs[1]
        XCTAssertEqual(r["type"] as? String, "message")
        XCTAssertEqual((r["text"] as? String)?.count, 500, "NDJSON text is never cut")
        XCTAssertEqual(r["date"] as? String, "2026-11-06T08:30:00Z")
        XCTAssertEqual(r["ns"] as? Int64, Fixture.nowNs)
        XCTAssertEqual(r["from"] as? String, "Mom")
        XCTAssertEqual(r["read"] as? Bool, true)
        XCTAssertNil(r["me"])
        XCTAssertEqual(r["reply"] as? Int, 50)
        XCTAssertEqual(r["edited"] as? Bool, true)
        XCTAssertEqual(r["failed"] as? Int, 22)
        XCTAssertEqual(r["agent"] as? Bool, true)
        XCTAssertNil(r["unsent"])
        let att = (r["att"] as? [[String: Any]])?.first
        XCTAssertEqual(att?["onDisk"] as? Bool, false)
        XCTAssertEqual(att?["state"] as? Int, 2)
        XCTAssertEqual(att?["uti"] as? String, "public.jpeg")
        XCTAssertEqual(att?["w"] as? Int, 4)
        XCTAssertEqual(r["parts"] as? Int, 2)
        XCTAssertEqual(r["delivered"] as? Int64, Fixture.nowNs + 5)
        XCTAssertEqual(((r["react"] as? [[String: Any]])?.first)?["emoji"] as? String, "❤️")
        XCTAssertEqual((r["link"] as? [String: Any])?["url"] as? String, "https://example.com/a/b")
        XCTAssertTrue(Format.ndjson(.messages(MessagesPage(chat: B.chat(7, "Mom"), messages: [m], totalVisible: 1,
                                                           olderExists: false))).contains("https://example.com/a/b"),
                      "slashes are not escaped")
    }

    func testNDJSONOtherRecords() throws {
        XCTAssertEqual(try records(.chats(ChatsPage(chats: [], hasMore: true, limit: 20))).first?["next"] as? String,
                       "imessage chats -n 40")
        XCTAssertEqual(try records(.wait(WaitOutcome(chat: nil, message: nil, timedOut: true))).map { $0["type"] as? String },
                       ["timeout"])
        let failure = try records(.failure(WireError(result: ActionResult(.error(.severalMatches), fix: "pick"),
                                                     candidates: [Candidate(label: "Jordan", argument: "23")])))
        XCTAssertEqual(failure.count, 1)
        XCTAssertEqual(failure[0]["type"] as? String, "error")
        XCTAssertEqual(failure[0]["code"] as? String, "error: several matches")
        XCTAssertEqual(failure[0]["line"] as? String, "error: several matches: Jordan (23) fix: pick")
        XCTAssertEqual(failure[0]["fix"] as? String, "pick")
        XCTAssertEqual((failure[0]["candidates"] as? [[String: String]])?.first?["argument"], "23")
        let nobody = try records(.contacts(ContactsPage(query: "zz", contacts: [])))
        XCTAssertEqual(nobody.count, 1)
        XCTAssertEqual(nobody[0]["type"] as? String, "error")
        XCTAssertEqual(nobody[0]["line"] as? String, "error: no contact matches \"zz\" fix: imessage chats")
        let changes = try records(.changes(ChangesPage(cursor: "1:2", changes: [
            ChangeRecord(kind: .read, chat: B.mom, message: B.msg(5, "x")),
            ChangeRecord(kind: .new, chat: B.mom, message: B.msg(6, "y")),
        ], truncated: false)))
        XCTAssertEqual(changes.map { $0["type"] as? String }, ["cursor", "chat", "change", "change"])
        XCTAssertEqual(changes[2]["kind"] as? String, "read")
        let send = try records(.send(SendOutcome(chat: B.mom, approved: true, early: nil, text: "hi", threadParentRowID: nil,
                                                 parts: [SendPartOutcome(part: .text, result: ActionResult(.delivered), rowid: 1)],
                                                 replayed: false)))
        XCTAssertEqual(send.first?["type"] as? String, "send")
        XCTAssertEqual(((send.first?["parts"] as? [[String: Any]])?.first?["result"] as? [String: Any])?["code"] as? String,
                       "delivered")
    }

    // MARK: NDJSON cap

    /// Records of an NDJSON page after checking the 200-record and 12,000-byte cap.
    func cappedRecords(_ p: ResponsePayload, file: StaticString = #filePath, line: UInt = #line) throws -> [[String: Any]] {
        let out = Format.ndjson(p)
        XCTAssertLessThanOrEqual(B.lines(out).count, Limits.outputMaxLines, "records", file: file, line: line)
        XCTAssertLessThanOrEqual(out.utf8.count, Limits.outputMaxBytes, "bytes", file: file, line: line)
        return try records(p)
    }

    func types(_ recs: [[String: Any]]) -> [String] { recs.map { $0["type"] as? String ?? "" } }

    /// The page is full: one more record as long as `sample`, the last one shown, would pass 12,000 bytes.
    func assertFull(_ p: ResponsePayload, sample: [String: Any], file: StaticString = #filePath, line: UInt = #line) {
        let size = Format.ndjson(p).utf8.count
        XCTAssertGreaterThan(size + NDJSON.serialize(sample).utf8.count + 1, Limits.outputMaxBytes, file: file, line: line)
    }

    func ids(_ recs: [[String: Any]], _ type: String) -> [Int] {
        recs.filter { $0["type"] as? String == type }.compactMap { $0["id"] as? Int }
    }

    func testNDJSONRecordCapIs200() {
        let units = (0..<250).map { [["type": "x", "i": $0]] as [[String: Any]] }
        let head: (Int) -> [[String: Any]] = { _ in [["type": "h"]] }
        let more: (Int) -> [String: Any] = { NDJSON.more("next \($0)") }
        XCTAssertEqual(NDJSON.keep(head: head, units: units, more: more, tail: []), 198)
        let page = NDJSON.page(head: head, units: units, more: more)
        XCTAssertEqual(page.count, 200)
        XCTAssertEqual(page.last?["next"] as? String, "next 198")
        // With nothing after the last unit, 199 units fill the 200 records.
        XCTAssertEqual(NDJSON.page(head: head, units: Array(units.prefix(199)), more: more).count, 200)
        XCTAssertEqual(NDJSON.keep(head: head, units: Array(units.prefix(199)), more: more, tail: []), 199)
        XCTAssertEqual(NDJSON.keep(head: head, units: [], more: more, tail: []), 0)
    }

    func testNDJSONReadKeepsTheNewestRecordsThatFit() throws {
        let msgs = (0..<300).map { B.msg(Int64(1000 + $0), "m", at: B.yesterday1802 + Int64($0)) }
        let payload = ResponsePayload.messages(MessagesPage(chat: B.chat(7, "Mom"), messages: msgs, totalVisible: 900,
                                                            olderExists: false))
        var recs = try cappedRecords(payload)
        let kept = ids(recs, "message")
        XCTAssertGreaterThan(kept.count, 10)
        XCTAssertEqual(types(recs), ["chat"] + Array(repeating: "message", count: kept.count) + ["more"])
        XCTAssertEqual(kept, Array((1300 - kept.count)...1299), "the newest, oldest first")
        XCTAssertEqual(recs.last?["next"] as? String, "imessage read 7 --before \(kept[0])")
        assertFull(payload, sample: NDJSON.message(msgs[0]))

        // 600-character bodies stay whole, so fewer of them fit.
        let long = (0..<40).map { B.msg(Int64(1000 + $0), String(repeating: "x", count: 600)) }
        recs = try cappedRecords(.messages(MessagesPage(chat: B.chat(7, "Mom"), messages: long, totalVisible: 40,
                                                        olderExists: false)))
        let whole = recs.filter { $0["type"] as? String == "message" }
        XCTAssertLessThan(whole.count, 40)
        XCTAssertTrue(whole.allSatisfy { ($0["text"] as? String)?.count == 600 })
        XCTAssertEqual(whole.last?["id"] as? Int, 1039)
        XCTAssertEqual(recs.last?["next"] as? String, "imessage read 7 --before \(whole.first?["id"] as? Int ?? 0)")

        // One record larger than the budget still prints whole, so the page moves forward.
        let huge = MessagesPage(chat: B.chat(7, "Mom"), messages: [B.msg(1, "older"), B.msg(2, String(repeating: "x", count: 13_000))],
                                totalVisible: 2, olderExists: false)
        recs = try records(.messages(huge))
        XCTAssertEqual(types(recs), ["chat", "message", "more"])
        XCTAssertEqual(recs[1]["id"] as? Int, 2)
        XCTAssertEqual(recs[2]["next"] as? String, "imessage read 7 --before 2")
    }

    func testNDJSONChatsCap() throws {
        let chats = (0..<250).map { B.chat(Int64(100 + $0), "Chat \($0)", last: B.msg(Int64($0), "hi")) }
        let payload = ResponsePayload.chats(ChatsPage(chats: chats, hasMore: true, limit: 250))
        let recs = try cappedRecords(payload)
        let shown = ids(recs, "chat")
        XCTAssertEqual(shown, Array(100..<(100 + shown.count)))
        XCTAssertEqual(types(recs).last, "more")
        XCTAssertEqual(types(recs).filter { $0 == "more" }.count, 1)
        XCTAssertEqual(recs.last?["next"] as? String, "imessage read \(100 + shown.count)", "the text footer's command")
        assertFull(payload, sample: recs[recs.count - 2])
        let fits = try cappedRecords(.chats(ChatsPage(chats: Array(chats.prefix(5)), hasMore: true, limit: 5)))
        XCTAssertEqual(fits.count, 6)
        XCTAssertEqual(fits.last?["next"] as? String, "imessage chats -n 25")
    }

    func testNDJSONUnreadCap() throws {
        func group(_ chat: Int64, _ n: Int, from rowid: Int64) -> UnreadGroup {
            UnreadGroup(chat: B.chat(chat, "Chat \(chat)"), entries: (0..<n).map {
                UnreadEntry(message: B.msg(rowid + Int64($0), "u", chat: chat), isUnread: true, gapBefore: false)
            }, unreadCount: n)
        }
        let one = ResponsePayload.unread(UnreadPage(groups: [group(7, 300, from: 1000)], totalUnread: 300))
        var recs = try cappedRecords(one)
        XCTAssertEqual(types(recs).prefix(2), ["unread", "chat"])
        let shown = ids(recs, "message")
        XCTAssertEqual(shown, Array(1000..<(1000 + shown.count)))
        XCTAssertEqual(recs.last?["next"] as? String, "imessage read 7 --after \(shown.last ?? 0)")
        assertFull(one, sample: recs[recs.count - 2])

        // Cut inside the second chat: read the rest of that chat.
        recs = try cappedRecords(.unread(UnreadPage(groups: [group(7, 2, from: 1000), group(9, 300, from: 5000)],
                                                    totalUnread: 302)))
        XCTAssertEqual(recs.last?["next"] as? String, "imessage read 9 --after \(ids(recs, "message").last ?? 0)")

        // The second chat's first message doesn't fit: point at that chat, as the text footer does.
        var found = false
        for n in 1...150 {
            let page = UnreadPage(groups: [group(7, n, from: 1000), group(9, 5, from: 5000)], totalUnread: n + 5)
            recs = try cappedRecords(.unread(page))
            guard recs.last?["next"] as? String == "imessage read 9" else { continue }
            found = true
            XCTAssertEqual(ids(recs, "message").count, n)
            XCTAssertEqual(ids(recs, "chat"), [7])
            break
        }
        XCTAssertTrue(found)
    }

    /// ReadService leaves a group's entries partial or empty past the 200-line text page. The NDJSON page ends at
    /// the first such group with a `more` record, even when its records would fit.
    func testNDJSONUnreadEndsAtTheFirstGroupTheStoreCut() throws {
        func group(_ chat: Int64, _ n: Int, of count: Int, from rowid: Int64) -> UnreadGroup {
            UnreadGroup(chat: B.chat(chat, "Chat \(chat)"), entries: (0..<n).map {
                UnreadEntry(message: B.msg(rowid + Int64($0), "u", chat: chat), isUnread: true, gapBefore: false)
            }, unreadCount: count)
        }
        var recs = try records(.unread(UnreadPage(groups: [group(7, 2, of: 2, from: 1000), group(9, 3, of: 50, from: 5000),
                                                         group(11, 0, of: 4, from: 0)], totalUnread: 56)))
        XCTAssertEqual(types(recs), ["unread", "chat", "message", "message", "chat", "message", "message", "message", "more"])
        XCTAssertEqual(ids(recs, "chat"), [7, 9])
        XCTAssertEqual(recs.last?["next"] as? String, "imessage read 9 --after 5002")

        recs = try records(.unread(UnreadPage(groups: [group(7, 2, of: 2, from: 1000), group(9, 0, of: 3, from: 0),
                                                      group(11, 0, of: 4, from: 0)], totalUnread: 9)))
        XCTAssertEqual(types(recs), ["unread", "chat", "message", "message", "more"])
        XCTAssertEqual(recs.last?["next"] as? String, "imessage read 9")
    }

    func testNDJSONSearchCap() throws {
        let hits = (0..<250).map {
            SearchHit(chat: B.mom, message: B.msg(Int64(9000 - $0), "jalebi", at: B.yesterday1802 - Int64($0) * 1_000_000_000))
        }
        let payload = ResponsePayload.search(SearchPage(query: "jalebi", inChat: B.mom, hits: hits,
                                                        scannedBackToNs: B.ns(2026, 1, 1), windowStartNs: 77,
                                                        nextCursor: "x:y:z", budgetExhausted: false))
        let recs = try cappedRecords(payload)
        let shown = ids(recs, "message")
        XCTAssertEqual(shown, (0..<shown.count).map { 9000 - $0 })
        let last = hits[shown.count - 1].message
        let cursor = "\(last.dateNs):\(last.rowid):77"
        XCTAssertEqual(recs[0]["cursor"] as? String, cursor, "the header cursor resumes after the last hit shown")
        XCTAssertEqual(recs.last?["next"] as? String, "imessage search --in 7 --cursor \(cursor) jalebi")
        assertFull(payload, sample: recs[recs.count - 2])
    }

    func testNDJSONWhoCap() throws {
        let people = (0..<250).map {
            ContactRecord(shortName: "P\($0)", firstName: "Pat", lastName: "\($0)", handles: [], chats: [])
        }
        let payload = ResponsePayload.contacts(ContactsPage(query: "Pat", contacts: people))
        let recs = try cappedRecords(payload)
        let shown = types(recs).filter { $0 == "contact" }.count
        XCTAssertEqual(types(recs), Array(repeating: "contact", count: shown) + ["more"])
        XCTAssertEqual(recs.last?["left"] as? Int, 250 - shown)
        assertFull(payload, sample: recs[recs.count - 2])
        XCTAssertFalse(Format.ndjson(.contacts(ContactsPage(query: "Pat", contacts: Array(people.prefix(20))))).contains("more"))
    }

    func testNDJSONChangesCap() throws {
        let changes = (0..<250).map {
            ChangeRecord(kind: .new, chat: B.mom, message: B.msg(Int64(50_000 + $0), "n"))
        }
        let payload = ResponsePayload.changes(ChangesPage(cursor: "50249:900", changes: changes, truncated: false))
        let recs = try cappedRecords(payload)
        let shown = ids(recs, "change")
        XCTAssertEqual(shown, Array(50_000..<(50_000 + shown.count)))
        let resume = "\(50_000 + shown.count - 1):900"
        XCTAssertEqual(recs[0]["cursor"] as? String, resume, "a script that reads the cursor skips nothing")
        XCTAssertEqual(recs[0]["truncated"] as? Bool, true)
        XCTAssertEqual(recs.last?["next"] as? String, "imessage changes --since \(resume)")
        assertFull(payload, sample: recs[recs.count - 2])
    }

    func testNDJSONShowPagesTheBodyLikeTheText() throws {
        let body = String(repeating: "x", count: 20_000)
        func page(_ from: Int, _ text: String = body) throws -> [String: Any] {
            let d = MessageDetail(message: B.msg(100, text), chat: B.mom, fromByte: from, totalBytes: text.utf8.count)
            let recs = try cappedRecords(.message(d))
            XCTAssertEqual(types(recs), ["chat", "message"])
            return recs[1]
        }
        var r = try page(0)
        XCTAssertEqual((r["text"] as? String)?.utf8.count, Limits.showCapBytes)
        XCTAssertEqual(r["offset"] as? Int, 0)
        XCTAssertEqual(r["from"] as? String, "Mom", "from stays the sender, not the byte offset")
        XCTAssertEqual(r["total"] as? Int, 20_000)
        XCTAssertEqual(r["next"] as? String, "imessage show 100 --from 8192")
        r = try page(16_384)
        XCTAssertEqual(r["offset"] as? Int, 16_384)
        XCTAssertEqual((r["text"] as? String)?.utf8.count, 20_000 - 16_384)
        XCTAssertNil(r["next"])

        // The same page ends as the text output's, after the 197th line break.
        let lines = (0..<1000).map { "l\($0)" }.joined(separator: "\n")
        r = try page(0, lines)
        let end = (0..<197).reduce(0) { $0 + "l\($1)".utf8.count + 1 }
        XCTAssertEqual(r["next"] as? String, "imessage show 100 --from \(end)")
        let text = Format.show(MessageDetail(message: B.msg(100, lines), chat: B.mom, fromByte: 0, totalBytes: 0), ctx)
        XCTAssertTrue(text.hasSuffix("imessage show 100 --from \(end))\n"))
        XCTAssertEqual(r["text"] as? String, String(lines.prefix(end)))

        // A short body is one page with offset and total.
        r = try page(0, "hi")
        XCTAssertEqual(r["text"] as? String, "hi")
        XCTAssertEqual(r["total"] as? Int, 2)
        XCTAssertNil(r["next"])
    }

    // MARK: Threads

    func testConcurrentRenderingMatchesSerial() throws {
        let inputs = payloads(dirty: true) + payloads(dirty: false)
        let serial = inputs.map { Format.render($0, ctx) + Format.ndjson($0) }
        let results = Results(count: inputs.count * 8)
        DispatchQueue.concurrentPerform(iterations: inputs.count * 8) { i in
            let p = inputs[i % inputs.count]
            results.set(i, Format.render(p, ctx) + Format.ndjson(p))
        }
        for i in 0..<(inputs.count * 8) { XCTAssertEqual(results.get(i), serial[i % inputs.count]) }
    }
}

/// A locked array the concurrent test writes into.
final class Results: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String?]

    init(count: Int) { values = Array(repeating: nil, count: count) }

    func set(_ i: Int, _ v: String) {
        lock.lock()
        values[i] = v
        lock.unlock()
    }

    func get(_ i: Int) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[i]
    }
}
