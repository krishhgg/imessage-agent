import XCTest
@testable import IMCore
import IMTestSupport

/// The ours.py helpers: message lines, tokens, sizes, events, titles and dates. Expected values come from
/// running the same inputs through bench/renderers/ours.py and CPython.
final class FormatPiecesTests: XCTestCase {
    let ctx = B.ctx

    func line(_ m: MessageRecord, _ onScreen: Set<Int64> = []) -> String { Format.messageLine(m, onScreen: onScreen, ctx) }

    // MARK: Message lines

    func testPlainLine() {
        XCTAssertEqual(line(B.msg(100, "hi")), "100 18:02 Mom: hi")
        XCTAssertEqual(line(B.msg(100, "hi", me: true)), "100 18:02 You: hi")
        XCTAssertEqual(line(B.msg(100, "")), "100 18:02 Mom: ")
        XCTAssertEqual(line(B.msg(100, "  padded \n")), "100 18:02 Mom: padded")
    }

    func testEventLineReplacesEverythingElse() {
        var m = B.msg(100, "ignored")
        m.replyTo = ReplyRef(rowid: 50, senderName: "Mom", text: "q")
        m.reactions = [B.reaction(.heart, "Priya", rowid: 1)]
        m.event = EventRecord(kind: .renamed, actorName: "Dad", title: "Desai Fam", itemType: 2, groupActionType: 0)
        XCTAssertEqual(line(m), "100 18:02 * Dad renamed the group to \"Desai Fam\"")
    }

    func testReplyQuoteOnlyWhenTheParentIsOffScreen() {
        var m = B.msg(100, "hi")
        m.replyTo = ReplyRef(rowid: 50, senderName: "Mom", text: "abcdefghijklmnopqrstuvwxyz0123456789")
        XCTAssertEqual(line(m), "100 18:02 Mom: ↩50 (Mom: abcdefghijklmnopqrstuvwxyz0123…) hi")
        XCTAssertEqual(line(m, [50]), "100 18:02 Mom: ↩50 hi")
        m.replyTo = ReplyRef(rowid: 50, senderName: "Mom", text: String(repeating: "q", count: 30))
        XCTAssertEqual(line(m), "100 18:02 Mom: ↩50 (Mom: \(String(repeating: "q", count: 30))) hi")
        m.replyTo = ReplyRef(rowid: 50, senderName: "Mom", text: "two\nlines")
        XCTAssertEqual(line(m), "100 18:02 Mom: ↩50 (Mom: two / lines) hi")
    }

    func testUnsentKeepsTheReplyTokenAndDropsTheRest() {
        var m = B.msg(100, "secret")
        m.unsent = true
        m.edited = true
        m.attachments = [B.photo()]
        m.reactions = [B.reaction(.heart, "Priya", rowid: 1)]
        XCTAssertEqual(line(m), "100 18:02 Mom: (unsent)")
        m.replyTo = ReplyRef(rowid: 50, senderName: "Dad", text: "x")
        XCTAssertEqual(line(m, [50]), "100 18:02 Mom: ↩50 (unsent)")
    }

    func testLinkTokenOnlyWhenTheBodyIsTheURL() {
        var m = B.msg(100, " https://example.com/a\n")
        m.link = LinkRecord(url: "https://example.com/a", site: "example.com", title: "A post")
        XCTAssertEqual(line(m), "100 18:02 Mom: [link example.com: A post]")
        m.text = "see https://example.com/a"
        XCTAssertEqual(line(m), "100 18:02 Mom: see https://example.com/a")
    }

    func testBodyCutAt400Scalars() {
        let a400 = String(repeating: "a", count: 400)
        XCTAssertEqual(line(B.msg(100, a400)), "100 18:02 Mom: " + a400)
        XCTAssertEqual(line(B.msg(100, a400 + "b")), "100 18:02 Mom: " + a400 + "…(+1 chars: imessage show 100)")
        XCTAssertEqual(line(B.msg(100, a400 + String(repeating: "b", count: 1234))),
                       "100 18:02 Mom: " + a400 + "…(+1,234 chars: imessage show 100)")
        // Python counts code points, so a combining mark is its own character and the cut can split it.
        let nfd = String(repeating: "a", count: 399) + "e\u{301}"
        XCTAssertEqual(Array(line(B.msg(100, nfd)).unicodeScalars),
                       Array(("100 18:02 Mom: " + String(repeating: "a", count: 399) + "e…(+1 chars: imessage show 100)").unicodeScalars))
    }

    func testTokenOrder() {
        var m = B.msg(100, "look")
        m.attachments = [B.photo(), AttachmentRecord(rowid: 9902, guid: "x", kind: .file, transferName: "menu.pdf", totalBytes: 348_000)]
        m.edited = true
        m.errorCode = 22
        m.reactions = [B.reaction(.heart, "Priya", rowid: 1)]
        XCTAssertEqual(line(m), "100 18:02 Mom: look [photo a9901 2.2MB] [file a9902 menu.pdf 348KB] (edited) (failed) [❤️Priya]")
        m.partUnsent = true
        XCTAssertEqual(line(m), "100 18:02 Mom: look [photo a9901 2.2MB] [file a9902 menu.pdf 348KB] (part unsent) (failed) [❤️Priya]")
        m.text = ""
        m.attachments = [B.photo()]
        m.partUnsent = false
        m.edited = false
        m.errorCode = 0
        m.reactions = []
        XCTAssertEqual(line(m), "100 18:02 Mom: [photo a9901 2.2MB]")
    }

    func testEveryLineBreakFoldsInsideALine() {
        XCTAssertEqual(line(B.msg(100, "a\u{2028}b")), "100 18:02 Mom: a / b")
        XCTAssertEqual(line(B.msg(100, "a\rb")), "100 18:02 Mom: a / b")
        XCTAssertEqual(line(B.msg(100, "a\n\nb")), "100 18:02 Mom: a / b")
        XCTAssertEqual(line(B.msg(100, "hi", from: "Mo\nm")), "100 18:02 Mo / m: hi")
    }

    // MARK: Tokens

    func testSizesMatchPython() {
        let cases: [(Int64?, String)] = [
            (nil, ""), (0, "0B"), (999, "999B"), (1000, "1KB"), (1499, "1KB"), (1500, "2KB"), (2500, "2KB"),
            (999_499, "999KB"), (999_500, "1000KB"), (1_000_000, "1.0MB"), (2_250_000, "2.2MB"),
            (2_350_000, "2.4MB"), (15_250_000, "15.2MB"),
        ]
        for (n, s) in cases { XCTAssertEqual(Format.size(n), s, "\(String(describing: n))") }
    }

    func testAttachmentTokens() {
        func a(_ kind: AttachmentKind, _ name: String = "x", bytes: Int64? = nil, transcript: String? = nil) -> String {
            Format.attachmentToken(AttachmentRecord(rowid: 5, guid: "g", kind: kind, transferName: name, totalBytes: bytes,
                                                    transcript: transcript))
        }
        XCTAssertEqual(a(.photo, bytes: 2_250_000), "[photo a5 2.2MB]")
        XCTAssertEqual(a(.photo), "[photo a5]")
        XCTAssertEqual(a(.video, bytes: 15_250_000), "[video a5 15.2MB]")
        XCTAssertEqual(a(.voice, transcript: "call me"), "[voice a5 \"call me\"]")
        XCTAssertEqual(a(.voice, transcript: ""), "[voice a5]")
        XCTAssertEqual(a(.voice), "[voice a5]")
        XCTAssertEqual(a(.sticker, bytes: 10), "[sticker a5]")
        XCTAssertEqual(a(.file, "menu.pdf", bytes: 348_000), "[file a5 menu.pdf 348KB]")
        XCTAssertEqual(a(.file, ""), "[file a5]")
    }

    func testReactionsGroupByEmojiInRowidOrder() {
        var m = B.msg(100, "x")
        XCTAssertEqual(Format.reactionsToken(m), "")
        m.reactions = [
            B.reaction(.heart, "Mom", rowid: 3), B.reaction(.laugh, "Priya", rowid: 1),
            B.reaction(.laugh, "Alex", rowid: 2, me: true), B.reaction(.emoji("🎉"), "Dad", rowid: 4),
        ]
        XCTAssertEqual(Format.reactionsToken(m), "[😂Priya,You ❤️Mom 🎉Dad]")
        m.stickers = [StickerRecord(actorName: "Dad", fromMe: false, part: 0, rowid: 9)]
        XCTAssertEqual(Format.reactionsToken(m), "[😂Priya,You ❤️Mom 🎉Dad sticker by Dad]")
        m.reactions = []
        m.stickers = [StickerRecord(actorName: "Alex", fromMe: true, part: 0, rowid: 9)]
        XCTAssertEqual(Format.reactionsToken(m), "[sticker by You]")
    }

    func testEventTexts() {
        func e(_ k: GroupEventKind, other: String? = nil, title: String? = nil, item: Int = 1) -> String {
            Format.eventText(EventRecord(kind: k, actorName: "Dad", otherName: other, title: title, itemType: item,
                                         groupActionType: 0))
        }
        XCTAssertEqual(e(.renamed, title: "Desai Fam"), "* Dad renamed the group to \"Desai Fam\"")
        XCTAssertEqual(e(.added, other: "Meera"), "* Dad added Meera")
        XCTAssertEqual(e(.added), "* Dad added someone")
        XCTAssertEqual(e(.removed, other: "Arjun"), "* Dad removed Arjun")
        XCTAssertEqual(e(.left), "* Dad left the group")
        XCTAssertEqual(e(.poll, title: "Dinner?"), "* Dad started a poll \"Dinner?\"")
        XCTAssertEqual(e(.poll), "* Dad started a poll")
        XCTAssertEqual(e(.poll, title: ""), "* Dad started a poll")
        XCTAssertEqual(e(.location), "* Dad shared a location")
        XCTAssertEqual(e(.other, item: 6), "* Dad group event 6")
    }

    func testChatTitles() {
        let five = B.chat(12, "Desai Fam", group: true, name: "Desai Fam", members: ["Mom", "Dad", "Priya", "Arjun", "Meera"])
        XCTAssertEqual(Format.chatTitle(five, withYou: false, cap: 3), "Desai Fam (group: Mom, Dad, Priya, 2 more)")
        XCTAssertEqual(Format.chatTitle(five, withYou: true, cap: nil), "Desai Fam (group: Mom, Dad, Priya, Arjun, Meera, You)")
        let four = B.chat(12, "x", group: true, name: "Fam", members: ["Mom", "Dad", "Priya", "Arjun"])
        XCTAssertEqual(Format.chatTitle(four, withYou: false, cap: 3), "Fam (group: Mom, Dad, Priya, Arjun)")
        let unnamed = B.chat(19, "Jordan, Taylor", group: true, members: ["Jordan", "Taylor"])
        XCTAssertEqual(Format.chatTitle(unnamed, withYou: true, cap: 3), "group: Jordan, Taylor, You")
        XCTAssertEqual(Format.chatTitle(B.chat(7, "Mom"), withYou: true, cap: 3), "Mom")
    }

    // MARK: Dates

    func testDayLabels() {
        let cases: [(Date, String)] = [
            (B.date(2026, 11, 6, 0, 15), "Today Fri Nov 6"), (B.date(2026, 11, 5, 23, 59), "Yesterday Thu Nov 5"),
            (B.date(2026, 11, 4), "Wed Nov 4"), (B.date(2026, 11, 1), "Sun Nov 1"), (B.date(2026, 10, 31, 0, 0), "Sat Oct 31"),
            (B.date(2026, 10, 30, 23, 59), "Oct 30"), (B.date(2026, 10, 29), "Oct 29"), (B.date(2025, 10, 28), "Oct 28 2025"),
            (B.date(2026, 11, 7, 10, 0), "Sat Nov 7"), (B.date(2027, 1, 2), "Sat Jan 2"),
        ]
        for (d, s) in cases { XCTAssertEqual(Format.dayLabel(d, ctx), s) }
    }

    func testWhenShort() {
        let cases: [(Date, String)] = [
            (B.date(2026, 11, 6, 0, 15), "00:15"), (B.date(2026, 11, 5, 18, 2), "Yesterday 18:02"),
            (B.date(2026, 10, 31, 0, 0), "Sat 00:00"), (B.date(2026, 10, 31, 9, 4), "Sat 09:04"),
            (B.date(2026, 10, 30, 23, 59), "Oct 30"), (B.date(2025, 12, 31), "Dec 31 2025"),
            (B.date(2026, 11, 7, 10, 0), "Sat 10:00"),
        ]
        for (d, s) in cases { XCTAssertEqual(Format.whenShort(d, ctx), s) }
    }

    /// CPython's `fromtimestamp` rounds to microseconds half to even, then floors to whole seconds.
    func testWholeSecondsLikeFromtimestamp() {
        XCTAssertEqual(Renderer.wholeSeconds(1.9999996), 2)
        XCTAssertEqual(Renderer.wholeSeconds(1.9999994), 1)
        XCTAssertEqual(Renderer.wholeSeconds(-0.5), -1)
        XCTAssertEqual(Renderer.wholeSeconds(-1.0), -1)
        XCTAssertEqual(Renderer.wholeSeconds(0), 0)
        // 2026-11-05 23:59:59.9999996 PST prints as Today 00:00.
        let t = B.date(2026, 11, 6, 0, 0).timeIntervalSince1970 - 0.0000004
        XCTAssertEqual(Format.whenShort(Date(timeIntervalSince1970: t), ctx), "00:00")
    }

    func testZoneAbbreviationFollowsTheClock() {
        XCTAssertEqual(Format.zoneAbbreviation(ctx), "PST")
        XCTAssertEqual(Format.zoneAbbreviation(FormatContext(now: B.date(2026, 7, 1), timeZone: Fixture.timeZone)), "PDT")
    }

    // MARK: Helpers

    func testGroupingAndShellQuoting() {
        XCTAssertEqual(Format.grouped(0), "0")
        XCTAssertEqual(Format.grouped(999), "999")
        XCTAssertEqual(Format.grouped(1000), "1,000")
        XCTAssertEqual(Format.grouped(1_234_567), "1,234,567")
        XCTAssertEqual(Format.grouped(-1234), "-1,234")
        XCTAssertEqual(Format.shellQuote("jalebi"), "jalebi")
        XCTAssertEqual(Format.shellQuote("a.b/c-d_e@f%g+h=i:j,k"), "a.b/c-d_e@f%g+h=i:j,k")
        XCTAssertEqual(Format.shellQuote("two words"), "'two words'")
        XCTAssertEqual(Format.shellQuote("it's"), "'it'\\''s'")
        XCTAssertEqual(Format.shellQuote(""), "''")
        XCTAssertEqual(Format.shellQuote("$(rm)"), "'$(rm)'")
        XCTAssertEqual(Format.shellQuote("café"), "'café'")
    }
}
