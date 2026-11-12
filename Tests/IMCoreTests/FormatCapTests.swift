import XCTest
@testable import IMCore
import IMTestSupport

/// The 200-line and 12,000-byte output cap, footer included, at its exact boundaries.
final class FormatCapTests: XCTestCase {
    let ctx = B.ctx
    let maxLines = Limits.outputMaxLines
    let maxBytes = Limits.outputMaxBytes

    func assertWithinCap(_ s: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThanOrEqual(B.lines(s).count, maxLines, "lines", file: file, line: line)
        XCTAssertLessThanOrEqual(s.utf8.count, maxBytes, "bytes", file: file, line: line)
        XCTAssertTrue(s.hasSuffix("\n") && !s.hasSuffix("\n\n"), file: file, line: line)
    }

    // MARK: read

    /// `n` messages on 2026-11-05, one minute apart from 10:00, ROWIDs from 1000.
    func window(_ n: Int, text: (Int) -> String = { _ in "m" }) -> [MessageRecord] {
        (0..<n).map { B.msg(Int64(1000 + $0), text($0), at: B.ns(2026, 11, 5, 10, 0) + Int64($0) * 60_000_000_000) }
    }

    func read(_ msgs: [MessageRecord], older: Bool) -> String {
        Format.messages(MessagesPage(chat: B.chat(7, "Mom"), messages: msgs, totalVisible: 500, olderExists: older), ctx)
    }

    func testReadLineCapBoundaries() {
        // header + separator + 197 messages + footer = 200
        var out = read(window(197), older: true)
        XCTAssertEqual(B.lines(out).count, 200)
        XCTAssertEqual(B.messageLines(out).count, 197)
        XCTAssertTrue(out.hasSuffix("more: imessage read 7 --before 1000\n"))

        out = read(window(198), older: true)
        assertWithinCap(out)
        XCTAssertEqual(B.messageLines(out).count, 197)
        XCTAssertTrue(out.hasPrefix("chat 7 Mom · 197 of 500 · times PST\n"))
        XCTAssertTrue(out.hasSuffix("more: imessage read 7 --before 1001\n"))

        // With nothing older the footer isn't needed, so one more message fits.
        out = read(window(198), older: false)
        XCTAssertEqual(B.lines(out).count, 200)
        XCTAssertEqual(B.messageLines(out).count, 198)
        XCTAssertFalse(out.contains("more:"))

        out = read(window(199), older: false)
        assertWithinCap(out)
        XCTAssertEqual(B.messageLines(out).count, 197)
        XCTAssertEqual(B.messageLines(out).first?.hasPrefix("1002 "), true)
        XCTAssertTrue(out.hasSuffix("more: imessage read 7 --before 1002\n"))
    }

    func testNewerMessagesGetAnAfterFooterCountedInTheCap() {
        func page(_ msgs: [MessageRecord], older: Bool) -> String {
            Format.messages(MessagesPage(chat: B.chat(7, "Mom"), messages: msgs, totalVisible: 500, olderExists: older,
                                         newerExists: true), ctx)
        }
        var out = page(window(5), older: true)
        XCTAssertTrue(out.hasSuffix("more: imessage read 7 --before 1000\nmore: imessage read 7 --after 1004\n"), out)

        // Without the newer footer 198 messages fit (testReadLineCapBoundaries). With it, the --before footer
        // comes back and 196 fit.
        out = page(window(198), older: false)
        assertWithinCap(out)
        XCTAssertEqual(B.lines(out).count, 200)
        XCTAssertEqual(B.messageLines(out).count, 196)
        XCTAssertTrue(out.hasSuffix("more: imessage read 7 --before 1002\nmore: imessage read 7 --after 1197\n"))

        out = page(window(197), older: false)
        XCTAssertEqual(B.lines(out).count, 200)
        XCTAssertEqual(B.messageLines(out).count, 197)
        XCTAssertFalse(out.contains("--before"))
        XCTAssertTrue(out.hasSuffix("more: imessage read 7 --after 1196\n"))

        XCTAssertFalse(read(window(5), older: false).contains("--after"), "no footer without newer messages")
        XCTAssertTrue(page([], older: false).hasPrefix("chat 7 Mom · 0 of 500"))
        XCTAssertFalse(page([], older: false).contains("--after"))
    }

    func testNewerFooterFitsTheByteCap() {
        let msgs = window(60) { _ in String(repeating: "y", count: 300) }
        let out = Format.messages(MessagesPage(chat: B.chat(7, "Mom"), messages: msgs, totalVisible: 500,
                                               olderExists: true, newerExists: true), ctx)
        assertWithinCap(out)
        XCTAssertTrue(out.hasSuffix("more: imessage read 7 --after 1059\n"))
    }

    func testReadCountsEveryDaySeparator() {
        let msgs = (0..<200).map { i -> MessageRecord in
            let day = i < 100 ? 4 : 5
            return B.msg(Int64(1000 + i), "m", at: B.ns(2026, 11, day, 10, 0) + Int64(i % 100) * 60_000_000_000)
        }
        let out = read(msgs, older: false)
        XCTAssertEqual(B.lines(out).count, 200)
        XCTAssertEqual(B.messageLines(out).count, 196)
        XCTAssertTrue(out.contains("\n-- Wed Nov 4\n1004 "))
        XCTAssertTrue(out.contains("\n-- Yesterday Thu Nov 5\n1100 "))
        XCTAssertTrue(out.hasSuffix("more: imessage read 7 --before 1004\n"))
    }

    func testReadByteCapBoundary() {
        var texts = Array(repeating: String(repeating: "x", count: 300), count: 30)
        let msgs = { self.window(30) { texts[$0] } }
        var room = maxBytes - read(msgs(), older: false).utf8.count
        XCTAssertGreaterThan(room, 0)
        var i = 0
        while room > 0 {
            XCTAssertLessThan(i, 29, "fixture needs more messages")
            let add = min(100, room)
            texts[i] += String(repeating: "x", count: add)
            room -= add
            i += 1
        }
        let exact = read(msgs(), older: false)
        XCTAssertEqual(exact.utf8.count, maxBytes)
        XCTAssertEqual(B.messageLines(exact).count, 30)
        XCTAssertFalse(exact.contains("more:"))

        texts[29] += "x"
        let over = read(msgs(), older: false)
        assertWithinCap(over)
        XCTAssertEqual(B.messageLines(over).count, 29)
        XCTAssertTrue(over.hasSuffix("more: imessage read 7 --before 1001\n"))
    }

    // MARK: One entry over the cap

    /// A bare link whose preview title is 13,000 characters and whose site is 50.
    func linked(_ rowid: Int64) -> MessageRecord {
        var m = B.msg(rowid, "https://example.com/a")
        m.link = LinkRecord(url: "https://example.com/a", site: String(repeating: "s", count: 50),
                            title: String(repeating: "t", count: 13_000))
        return m
    }

    /// A voice message whose transcript is 13,000 characters.
    func voiced(_ rowid: Int64) -> MessageRecord {
        var m = B.msg(rowid, "")
        m.attachments = [AttachmentRecord(rowid: 9903, guid: "g", kind: .voice, transferName: "v.caf",
                                          transcript: String(repeating: "w", count: 13_000))]
        return m
    }

    let linkToken = "[link " + String(repeating: "s", count: 30) + "…: " + String(repeating: "t", count: 400) + "…]"
    let voiceToken = "[voice a9903 \"" + String(repeating: "w", count: 400) + "…\"]"

    func testLongLinkTitleAndTranscriptAreCutInRead() {
        for (m, token) in [(linked(1000), linkToken), (voiced(1000), voiceToken)] {
            let out = read([m], older: true)
            assertWithinCap(out)
            XCTAssertEqual(B.lines(out), ["chat 7 Mom · 1 of 500 · times PST", "-- Yesterday Thu Nov 5",
                                          "1000 18:02 Mom: " + token, "more: imessage read 7 --before 1000"])
        }
    }

    func testLongLinkTitleAndTranscriptAreCutInChanges() {
        for (m, token) in [(linked(50_000), linkToken), (voiced(50_000), voiceToken)] {
            let page = ChangesPage(cursor: "50000:900", changes: [ChangeRecord(kind: .new, chat: B.mom, message: m)],
                                   truncated: false)
            let out = Format.changes(page, ctx)
            assertWithinCap(out)
            XCTAssertEqual(B.lines(out), ["changes · 1 change · times PST", "-- Yesterday Thu Nov 5",
                                          "new 7 Mom · 50000 18:02 Mom: " + token, "cursor 50000:900"])
        }
    }

    func testLongLinkTitleAndTranscriptHitsPrintInSearch() {
        let hits = [SearchHit(chat: B.mom, message: linked(9001)), SearchHit(chat: B.mom, message: voiced(9000))]
        let page = SearchPage(query: "example", inChat: nil, hits: hits, scannedBackToNs: B.ns(2026, 1, 1),
                              windowStartNs: 77, nextCursor: nil, budgetExhausted: false)
        let out = Format.search(page, ctx)
        assertWithinCap(out)
        XCTAssertEqual(B.lines(out).count, 3)
        XCTAssertTrue(out.hasPrefix("search \"example\" · 2 hits, newest first"))
    }

    /// A sender name no cut applies to, so the line itself passes 12,000 bytes.
    let longName = String(repeating: "N", count: 13_000)

    /// Within the cap, and the cut line used the room left. `slack` is the part of a footer reserve left unused.
    func assertFilled(_ out: String, slack: Int = 8, file: StaticString = #filePath, line: UInt = #line) {
        assertWithinCap(out, file: file, line: line)
        XCTAssertGreaterThan(out.utf8.count, maxBytes - slack, "the cut line uses the room left", file: file, line: line)
    }

    func testReadFirstLineOverTheCapPrintsCut() {
        let msgs = [B.msg(1000, "older"), B.msg(1001, "hi", from: longName)]
        var out = read(msgs, older: false)
        assertFilled(out)
        var lines = B.lines(out)
        XCTAssertEqual(lines.count, 4)
        guard lines.count == 4 else { return }
        XCTAssertEqual(lines[0], "chat 7 Mom · 1 of 500 · times PST")
        XCTAssertTrue(lines[2].hasPrefix("1001 18:02 NNNN") && lines[2].hasSuffix("N…"), lines[2])
        XCTAssertEqual(lines[3], "more: imessage read 7 --before 1001")

        out = read(Array(msgs.suffix(1)), older: false)
        assertWithinCap(out)
        lines = B.lines(out)
        XCTAssertEqual(lines.count, 3, "nothing older, so no footer")
        XCTAssertTrue(lines.last?.hasSuffix("N…") == true)
        XCTAssertGreaterThan(out.utf8.count, maxBytes - 8)
    }

    func testUnreadFirstLineOverTheCapPrintsCut() {
        var big = unreadGroup(7, 2, from: 1000)
        big.entries[0].message.senderName = longName
        var out = Format.unread(UnreadPage(groups: [big], totalUnread: 2), ctx)
        assertFilled(out)
        var lines = B.lines(out)
        XCTAssertEqual(lines.count, 6)
        guard lines.count == 6 else { return }
        XCTAssertEqual(Array(lines.prefix(4)), ["unread · 2 messages in 1 chat · times PST", "chat 7 Chat 7 · 2 unread",
                                                "-- Yesterday Thu Nov 5", "-- unread"])
        XCTAssertTrue(lines[4].hasPrefix("1000 10:00 NNNN") && lines[4].hasSuffix("N…"), lines[4])
        XCTAssertEqual(lines.last, "more: imessage read 7 --after 1000")

        // The chat's only message is the one cut, so the footer points at the next chat.
        var alone = unreadGroup(7, 1, from: 1000)
        alone.entries[0].message.senderName = longName
        out = Format.unread(UnreadPage(groups: [alone, unreadGroup(9, 1, from: 5000)], totalUnread: 2), ctx)
        assertFilled(out)
        lines = B.lines(out)
        XCTAssertEqual(lines.count, 6)
        XCTAssertEqual(lines.last, "more: imessage read 9")
    }

    func testChangesFirstLineOverTheCapPrintsCutAndTheCursorMovesPastIt() {
        let changes = [ChangeRecord(kind: .new, chat: B.mom, message: B.msg(50_000, "hi", from: longName)),
                       ChangeRecord(kind: .new, chat: B.mom, message: B.msg(50_001, "next"))]
        let out = Format.changes(ChangesPage(cursor: "50001:900", changes: changes, truncated: false), ctx)
        assertFilled(out, slack: 80)
        let lines = B.lines(out)
        XCTAssertEqual(lines.count, 4)
        guard lines.count == 4 else { return }
        XCTAssertEqual(lines[0], "changes · 1 change · times PST")
        XCTAssertTrue(lines[2].hasPrefix("new 7 Mom · 50000 18:02 NNNN") && lines[2].hasSuffix("N…"), lines[2])
        XCTAssertEqual(lines[3], "more: imessage changes --since 50000:900")
        let next = ChangeCursor(text: String(lines[3].split(separator: " ").last!))
        XCTAssertEqual(next?.rowid, 50_000, "rows above 50000 come next, so 50000 isn't shown again")
    }

    func testSearchFirstHitOverTheCapPrintsCut() {
        func page(_ hits: [SearchHit], next: String?) -> String {
            Format.search(SearchPage(query: "hi", inChat: nil, hits: hits, scannedBackToNs: B.ns(2026, 1, 1),
                                     windowStartNs: 77, nextCursor: next, budgetExhausted: false), ctx)
        }
        let big = SearchHit(chat: B.mom, message: B.msg(9001, "hi", from: longName))
        let small = SearchHit(chat: B.mom, message: B.msg(9000, "hi again", at: B.yesterday1802 - 1))

        var out = page([big], next: nil)
        assertFilled(out)
        var lines = B.lines(out)
        XCTAssertEqual(lines.count, 2)
        guard lines.count == 2 else { return }
        XCTAssertTrue(lines[0].hasPrefix("search \"hi\" · 1 hit, newest first"))
        XCTAssertTrue(lines[1].hasPrefix("7 Mom · Yesterday 18:02 · 9001 NNNN") && lines[1].hasSuffix("N…"), lines[1])

        out = page([big, small], next: nil)
        assertFilled(out)
        lines = B.lines(out)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines.last, "more: imessage search --cursor \(B.yesterday1802):9001:77 hi")

        out = page([big], next: "5:6:77")
        assertFilled(out)
        XCTAssertEqual(B.lines(out).last, "more: imessage search --cursor 5:6:77 hi")
    }

    func testFitCutsAtACharacterBoundary() {
        let line = "1 10:00 Mom: " + String(repeating: "👍🏽", count: 100)
        for budget in 14...60 {
            let cut = Renderer.fit(line, budget)
            XCTAssertLessThanOrEqual(cut.utf8.count + 1, budget)
            XCTAssertTrue(cut.hasSuffix("…"))
            XCTAssertTrue(line.hasPrefix(cut.dropLast()), "only whole characters are kept")
        }
        XCTAssertEqual(Renderer.fit("short", 6), "short")
    }

    // MARK: chats

    func chatList(_ n: Int, preview: String = "hi") -> [ChatRecord] {
        (0..<n).map { B.chat(Int64(100 + $0), "Chat \($0)", last: B.msg(Int64($0), preview)) }
    }

    func chats(_ n: Int, hasMore: Bool, limit: Int = 200, preview: String = "hi") -> String {
        Format.chats(ChatsPage(chats: chatList(n, preview: preview), hasMore: hasMore, limit: limit), ctx)
    }

    func testChatsLineCapBoundaries() {
        var out = chats(200, hasMore: false)
        XCTAssertEqual(B.lines(out).count, 200)
        XCTAssertFalse(out.contains("more:"))

        out = chats(201, hasMore: false)
        XCTAssertEqual(B.lines(out).count, 200)
        XCTAssertTrue(out.hasSuffix("more: imessage read 299\n"))
        XCTAssertEqual(B.lines(out).dropLast().last?.hasPrefix("298 Chat 198 "), true)

        out = chats(200, hasMore: true)
        XCTAssertEqual(B.lines(out).count, 200)
        XCTAssertTrue(out.hasSuffix("more: imessage read 299\n"))

        out = chats(199, hasMore: true)
        XCTAssertEqual(B.lines(out).count, 200)
        XCTAssertTrue(out.hasSuffix("more: imessage chats -n 220\n"))
    }

    func testChatsByteCap() {
        let out = chats(190, hasMore: true, preview: String(repeating: "€", count: 80))
        assertWithinCap(out)
        let shown = B.lines(out).dropLast()
        XCTAssertLessThan(shown.count, 190)
        let next = 100 + shown.count
        XCTAssertTrue(out.hasSuffix("more: imessage read \(next)\n"))
        // The next chat's line and its footer would not have fit.
        let unshown = chatList(shown.count + 1, preview: String(repeating: "€", count: 80)).last!
        let nextLine = B.lines(Format.chats(ChatsPage(chats: [unshown], hasMore: false, limit: 1), ctx))[0]
        let used = shown.reduce(0) { $0 + $1.utf8.count + 1 }
        XCTAssertGreaterThan(used + nextLine.utf8.count + 1 + "more: imessage read \(next + 1)\n".utf8.count, maxBytes)
    }

    // MARK: unread

    func unreadGroup(_ chat: Int64, _ n: Int, from rowid: Int64) -> UnreadGroup {
        let entries = (0..<n).map {
            UnreadEntry(message: B.msg(rowid + Int64($0), "u", at: B.ns(2026, 11, 5, 10, 0) + Int64($0) * 60_000_000_000,
                                       chat: chat), isUnread: true, gapBefore: false)
        }
        return UnreadGroup(chat: B.chat(chat, "Chat \(chat)"), entries: entries, unreadCount: n)
    }

    func testUnreadWholeBlocksAndNextChatFooter() {
        // header + (title, day, marker, 195 messages) + footer for the next chat = 200
        let page = UnreadPage(groups: [unreadGroup(7, 195, from: 1000), unreadGroup(9, 1, from: 5000)], totalUnread: 196)
        let out = Format.unread(page, ctx)
        XCTAssertEqual(B.lines(out).count, 200)
        XCTAssertEqual(B.messageLines(out).count, 195)
        XCTAssertTrue(out.hasSuffix("more: imessage read 9\n"))

        // One chat with nothing after it: a block that fills all 200 lines prints whole.
        let alone = Format.unread(UnreadPage(groups: [unreadGroup(7, 196, from: 1000)], totalUnread: 196), ctx)
        XCTAssertEqual(B.lines(alone).count, 200)
        XCTAssertFalse(alone.contains("more:"))
    }

    func testUnreadFirstBlockTooBigPrintsAPartialBlock() {
        let out = Format.unread(UnreadPage(groups: [unreadGroup(7, 197, from: 1000), unreadGroup(9, 1, from: 5000)],
                                           totalUnread: 198), ctx)
        XCTAssertEqual(B.lines(out).count, 200)
        XCTAssertEqual(B.messageLines(out).count, 195)
        XCTAssertTrue(out.hasSuffix("more: imessage read 7 --after 1194\n"))
    }

    func testUnreadByteCap() {
        var big = unreadGroup(7, 40, from: 1000)
        for i in big.entries.indices { big.entries[i].message.text = String(repeating: "€", count: 120) }
        let out = Format.unread(UnreadPage(groups: [big], totalUnread: 40), ctx)
        assertWithinCap(out)
        XCTAssertGreaterThan(out.utf8.count, maxBytes - 400)
        let last = B.messageLines(out).last!.split(separator: " ")[0]
        XCTAssertTrue(out.hasSuffix("more: imessage read 7 --after \(last)\n"))
    }

    // MARK: search

    func testSearchCapCursorPointsAtTheLastShownHit() {
        let hits = (0..<250).map {
            SearchHit(chat: B.mom, message: B.msg(Int64(9000 - $0), "jalebi \($0)", at: B.yesterday1802 - Int64($0) * 1_000_000_000))
        }
        let page = SearchPage(query: "jalebi", inChat: nil, hits: hits, scannedBackToNs: B.ns(2026, 1, 1),
                              windowStartNs: 77, nextCursor: "x:y:z", budgetExhausted: false)
        let out = Format.search(page, ctx)
        XCTAssertEqual(B.lines(out).count, 200)
        XCTAssertTrue(out.hasPrefix("search \"jalebi\" · 198 hits, newest first"))
        let lastShown = hits[197].message
        XCTAssertTrue(out.hasSuffix("more: imessage search --cursor \(lastShown.dateNs):\(lastShown.rowid):77 jalebi\n"))
        XCTAssertNotNil(SearchCursor(text: "\(lastShown.dateNs):\(lastShown.rowid):77"))
    }

    func testSearchCapCursorUsesTheJoinDateTheStorePagesOn() {
        // The join row's message_date can differ from message.date, and the store's cursor is on the join date.
        let hits = (0..<250).map { i -> SearchHit in
            let sent = B.yesterday1802 - Int64(i) * 1_000_000_000
            return SearchHit(chat: B.mom, message: B.msg(Int64(9000 - i), "jalebi \(i)", at: sent),
                             cursorNs: sent - 5_000_000_000)
        }
        let page = SearchPage(query: "jalebi", inChat: nil, hits: hits, scannedBackToNs: B.ns(2026, 1, 1),
                              windowStartNs: 77, nextCursor: "x:y:z", budgetExhausted: false)
        let out = Format.search(page, ctx)
        let lastShown = hits[197]
        XCTAssertNotEqual(lastShown.cursorNs, lastShown.message.dateNs)
        XCTAssertTrue(out.hasSuffix("more: imessage search --cursor \(lastShown.cursorNs!):\(lastShown.message.rowid):77 jalebi\n"),
                      B.lines(out).last!)
    }

    func testSearchByteCap() {
        let hits = (0..<150).map {
            SearchHit(chat: B.mom, message: B.msg(Int64(9000 - $0), String(repeating: "€", count: 119) + "q", at: B.yesterday1802))
        }
        let page = SearchPage(query: "q", inChat: B.mom, hits: hits, scannedBackToNs: B.ns(2026, 1, 1), windowStartNs: 1,
                              nextCursor: nil, budgetExhausted: true)
        let out = Format.search(page, ctx)
        assertWithinCap(out)
        XCTAssertTrue(B.lines(out).last!.hasPrefix("more: imessage search --in 7 --cursor "))
    }

    func testLongestSearchQueryLeavesRoomForHitsAndAnExactFooter() {
        // 500 four-byte scalars is the most bytes a query can add: about 2 KB in the header and 2 KB, quoted,
        // in the footer.
        let query = String(repeating: "\u{1F600}", count: Limits.searchQueryMaxChars)
        let hits = (0..<150).map {
            SearchHit(chat: B.mom, message: B.msg(Int64(9000 - $0), "\u{1F600} jalebi \($0)",
                                                  at: B.yesterday1802 - Int64($0) * 1_000_000_000))
        }
        let page = SearchPage(query: query, inChat: B.mom, hits: hits, scannedBackToNs: B.ns(2026, 1, 1),
                              windowStartNs: 77, nextCursor: "1:2:77", budgetExhausted: false)
        let out = Format.search(page, ctx)
        assertWithinCap(out)
        let lines = B.lines(out)
        XCTAssertTrue(lines[0].hasPrefix("search \"\(query)\" in Mom · "), "the header keeps the whole query")
        XCTAssertGreaterThan(lines.count - 2, 20, "hits still fit next to the query")
        let lastShown = hits[lines.count - 3].message
        XCTAssertEqual(lines.last, "more: imessage search --in 7 --cursor \(lastShown.dateNs):\(lastShown.rowid):77 '\(query)'")
    }

    // MARK: who, pending, changes

    /// `n` group chats with 40-byte labels.
    func manyChats(_ n: Int) -> [ChatRef] {
        (0..<n).map { ChatRef(rowid: Int64(1000 + $0), label: "Group chat \($0) with a fairly long name", isGroup: true) }
    }

    func testWhoCutsTheChatsListOfOneContactInto400Chats() {
        let p = ContactRecord(shortName: "Pat", firstName: "Pat", lastName: "Lee",
                              handles: [HandleRecord(id: "+14155550101", services: ["iMessage"])], chats: manyChats(400))
        let out = Format.who(ContactsPage(query: "Pat", contacts: [p]))
        assertWithinCap(out)
        let lines = B.lines(out)
        XCTAssertEqual(lines.count, 1, "the one contact prints and no contact is left out")
        let line = lines.first ?? ""
        XCTAssertTrue(line.hasPrefix("Pat = Pat Lee · +1 415-555-0101 (iMessage) · chats: 1000 Group chat 0 "), line)
        let left = Int(line.components(separatedBy: ", +").last?.split(separator: " ").first ?? "")
        XCTAssertNotNil(left)
        XCTAssertTrue(line.hasSuffix(" more chats"))
        let shown = line.components(separatedBy: " with a fairly long name").count - 1
        XCTAssertGreaterThan(shown, 100)
        XCTAssertEqual(shown + (left ?? 0), 400)
        // One more chat would not have fit.
        XCTAssertGreaterThan(out.utf8.count + ", 1999 Group chat 999 with a fairly long name".utf8.count, maxBytes)
    }

    func testWhoFirstOfTwoContactsOverTheCap() {
        let big = ContactRecord(shortName: "Pat", firstName: "Pat", lastName: "Lee", handles: [], chats: manyChats(400))
        let small = ContactRecord(shortName: "Patty", firstName: "Patty", lastName: "Ray", handles: [], chats: [])
        var out = Format.who(ContactsPage(query: "Pat", contacts: [big, small]))
        assertWithinCap(out)
        var lines = B.lines(out)
        XCTAssertEqual(lines.count, 2)
        guard lines.count == 2 else { return }
        XCTAssertTrue(lines[0].hasPrefix("Pat = Pat Lee ·  · chats: 1000 ") && lines[0].hasSuffix(" more chats"), lines[0])
        XCTAssertEqual(lines[1], "more: 1 more contact match \"Pat\", pass a fuller name")

        // Second and over the cap: it prints cut and nothing is left out.
        out = Format.who(ContactsPage(query: "Pat", contacts: [small, big]))
        assertWithinCap(out)
        lines = B.lines(out)
        XCTAssertEqual(lines.count, 2)
        guard lines.count == 2 else { return }
        XCTAssertEqual(lines[0], "Patty = Patty Ray ·  · chats: ")
        XCTAssertTrue(lines[1].hasSuffix(" more chats"))

        // A line too long even with no chats still prints, cut.
        let named = ContactRecord(shortName: longName, firstName: "Pat", lastName: "Lee", handles: [], chats: manyChats(3))
        out = Format.who(ContactsPage(query: "Pat", contacts: [named, small]))
        assertWithinCap(out)
        lines = B.lines(out)
        XCTAssertEqual(lines.count, 2)
        guard lines.count == 2 else { return }
        XCTAssertTrue(lines[0].hasPrefix("NNNN") && lines[0].hasSuffix("N…"))
        XCTAssertEqual(lines[1], "more: 1 more contact match \"Pat\", pass a fuller name")
    }

    func testWhoCap() {
        let people = (0..<250).map {
            ContactRecord(shortName: "P\($0)", firstName: "Pat", lastName: "\($0)", handles: [], chats: [])
        }
        let out = Format.who(ContactsPage(query: "Pat", contacts: people))
        XCTAssertEqual(B.lines(out).count, 200)
        XCTAssertTrue(out.hasSuffix("more: 51 more contacts match \"Pat\", pass a fuller name\n"))
        let exact = Format.who(ContactsPage(query: "Pat", contacts: Array(people.prefix(200))))
        XCTAssertEqual(B.lines(exact).count, 200)
        XCTAssertFalse(exact.contains("more:"))
    }

    // MARK: show

    func show(_ text: String, from: Int) -> String {
        Format.show(MessageDetail(message: B.msg(100, text), chat: B.mom, fromByte: from, totalBytes: text.utf8.count), ctx)
    }

    /// The body bytes one `show` output printed and the `--from` offset its footer gives, if any.
    func showPage(_ out: String) -> (text: String, next: Int?) {
        var lines = B.lines(out)
        lines.removeFirst()
        var next: Int?
        if let last = lines.last, last.hasPrefix("…(+"), let n = Int(last.split(separator: " ").last!.dropLast()) {
            next = n
            lines.removeLast()
        }
        let text = lines.joined(separator: "\n")
        XCTAssertTrue(text.hasPrefix("Mom: "))
        return (String(text.dropFirst(5)), next)
    }

    func testShowEndsThePageAfter197LineBreaks() {
        let body = (0..<1000).map { "l\($0)" }.joined(separator: "\n")
        let out = show(body, from: 0)
        assertWithinCap(out)
        XCTAssertEqual(B.lines(out).count, 200)
        let breakAfter197 = (0..<197).reduce(0) { $0 + "l\($1)".utf8.count + 1 }
        XCTAssertTrue(out.hasSuffix("\n\n…(+\(Format.grouped(body.utf8.count - breakAfter197)) bytes: imessage show 100 --from \(breakAfter197))\n"))
        let second = show(body, from: breakAfter197)
        XCTAssertEqual(B.lines(second)[1], "Mom: l197")
        XCTAssertEqual(B.lines(second).count, 200)
    }

    func testShowPagesTileTheBody() {
        let bodies = [
            (0..<1000).map { "l\($0)" }.joined(separator: "\n"),
            (0..<700).map { "é\($0)" }.joined(separator: "\r\n"),
            (0..<500).map { "\($0)" }.joined(separator: "\u{2028}"),
            String(repeating: "ab€\n", count: 3000) + "end",
            String(repeating: "x", count: 20_000),
        ]
        for body in bodies {
            var from = 0
            var pages = ""
            var count = 0
            while true {
                let out = show(body, from: from)
                assertWithinCap(out)
                let page = showPage(out)
                pages += page.text
                count += 1
                guard let next = page.next else { break }
                XCTAssertGreaterThan(next, from)
                from = next
            }
            XCTAssertEqual(Data(pages.utf8), Data(body.utf8), "pages put together give the body back")
            XCTAssertGreaterThan(count, 1)
        }
        // CR LF counts as one break: the page ends after the 197th pair.
        let crlf = (0..<300).map { "\($0)" }.joined(separator: "\r\n")
        let end = Renderer.showPage(Array(crlf.utf8), from: 0).upperBound
        XCTAssertEqual(end, (0..<197).reduce(0) { $0 + "\($1)".utf8.count + 2 })
    }

    func testPendingCap() {
        let items = (0..<250).map {
            PendingItem(id: "id\($0)", summary: "send to Mom", createdAt: B.date(2026, 11, 6, 0, 20), expiresAt: B.date(2026, 11, 6, 0, 30))
        }
        let out = Format.pending(PendingList(items: items), ctx)
        assertWithinCap(out)
        XCTAssertTrue(B.lines(out).last!.hasPrefix("more: "))
    }

    func testChangesCapResumeCursorCoversEveryUnshownChange() {
        let changes = (0..<250).map {
            ChangeRecord(kind: .new, chat: B.mom, message: B.msg(Int64(50_000 + $0), "n", at: B.yesterday1802))
        }
        let page = ChangesPage(cursor: "50249:900", changes: changes, truncated: false)
        let out = Format.changes(page, ctx)
        XCTAssertEqual(B.lines(out).count, 200)
        XCTAssertTrue(out.hasPrefix("changes · 197 changes · times PST\n"))
        XCTAssertTrue(out.hasSuffix("more: imessage changes --since 50196:900\n"))
    }

    func testResumeCursorTakesTheEarliestUnshownTime() {
        var read = B.msg(10, "r")
        read.dateReadNs = 500
        var delivered = B.msg(11, "d")
        delivered.dateDeliveredNs = 700
        var edited = B.msg(12, "e")
        edited.dateEditedNs = 300
        let page = ChangesPage(cursor: "90:1000", changes: [
            ChangeRecord(kind: .new, chat: B.mom, message: B.msg(95, "n")),
            ChangeRecord(kind: .read, chat: B.mom, message: read, eventNs: 500),
            ChangeRecord(kind: .delivered, chat: B.mom, message: delivered, eventNs: 700),
            ChangeRecord(kind: .edited, chat: B.mom, message: edited, eventNs: 300),
            ChangeRecord(kind: .new, chat: B.mom, message: B.msg(80, "n")),
        ], truncated: false)
        XCTAssertEqual(Renderer.resumeCursor(page, unshown: page.changes[1...]), "79:299")
        XCTAssertEqual(Renderer.resumeCursor(page, unshown: page.changes[1...3]), "90:299")
        XCTAssertEqual(Renderer.resumeCursor(page, unshown: page.changes[1...2]), "90:499")
        XCTAssertEqual(Renderer.resumeCursor(page, unshown: page.changes[0...0]), "90:1000")
        let bad = ChangesPage(cursor: "garbage", changes: page.changes, truncated: false)
        XCTAssertEqual(Renderer.resumeCursor(bad, unshown: bad.changes[0...]), "garbage")
    }

    func testResumeCursorInsideOneTimeKeepsTheTimeAndTakesATieRowID() {
        // 250 reads at one time, more than a page shows. Moving the time back would bring the same page again.
        let changes = (0..<250).map { i -> ChangeRecord in
            var m = B.msg(Int64(10_000 + i), "r", at: B.yesterday1802)
            m.dateReadNs = 500
            return ChangeRecord(kind: .read, chat: B.mom, message: m, eventNs: 500)
        }
        let page = ChangesPage(cursor: "90:500", changes: changes, truncated: true)
        let lines = B.lines(Format.changes(page, ctx))
        XCTAssertEqual(lines.count, 200)
        XCTAssertEqual(lines.first, "changes · 197 changes · times PST")
        XCTAssertEqual(lines.last, "more: imessage changes --since 90:500:10196")
        XCTAssertEqual(ChangeCursor(text: "90:500:10196")?.isBefore(time: 500, rowid: 10_197), true,
                       "the first row not shown comes next")
        // With nothing shown at that time, the time alone moves back.
        XCTAssertEqual(Renderer.resumeCursor(page, unshown: page.changes[0...]), "90:499")
        // A page cursor that is already inside the time only moves back within it.
        let tied = ChangesPage(cursor: "90:500:10220", changes: changes, truncated: true)
        XCTAssertEqual(Renderer.resumeCursor(tied, unshown: tied.changes[197...]), "90:500:10196")
        XCTAssertEqual(Renderer.resumeCursor(tied, unshown: tied.changes[240...]), "90:500:10220")
    }

    func testResumeCursorIgnoresMissingTimes() {
        // A change with no event time must not drag the cursor to -1, which would rescan every row.
        let page = ChangesPage(cursor: "90:1000", changes: [
            ChangeRecord(kind: .read, chat: B.mom, message: B.msg(10, "r")),
            ChangeRecord(kind: .delivered, chat: B.mom, message: B.msg(11, "d")),
            ChangeRecord(kind: .edited, chat: B.mom, message: B.msg(12, "e")),
            ChangeRecord(kind: .unsent, chat: B.mom, message: B.msg(13, "u")),
        ], truncated: false)
        XCTAssertEqual(page.changes.map(\.eventNs), [0, 0, 0, 0])
        XCTAssertEqual(Renderer.resumeCursor(page, unshown: page.changes[0...]), "90:1000")
    }

    func testRetractOnlyUnsentPastTheCapLowersTheCursorBelowItsRetractTime() {
        // An unsend that set only date_retracted has date_edited 0, so only eventNs says when it happened.
        let changes = (0..<199).map {
            ChangeRecord(kind: .new, chat: B.mom, message: B.msg(Int64(50_000 + $0), "n\($0)", at: B.yesterday1802))
        } + [ChangeRecord(kind: .unsent, chat: B.mom, message: B.msg(40_908, ""), eventNs: 800)]
        XCTAssertEqual(changes.last?.message.dateEditedNs, 0)
        let out = Format.changes(ChangesPage(cursor: "50198:900", changes: changes, truncated: false), ctx)
        assertWithinCap(out)
        XCTAssertFalse(out.contains("40908"), "the unsend is past the cap")
        XCTAssertTrue(B.lines(out).last!.hasSuffix(":799"), B.lines(out).last!)
    }

    func testChangesByteCap() {
        let changes = (0..<100).map {
            ChangeRecord(kind: .new, chat: B.mom, message: B.msg(Int64(50_000 + $0), String(repeating: "€", count: 100), at: B.yesterday1802))
        }
        let out = Format.changes(ChangesPage(cursor: "50099:900", changes: changes, truncated: true), ctx)
        assertWithinCap(out)
        XCTAssertTrue(B.lines(out).last!.hasPrefix("more: imessage changes --since 500"))
    }
}
