import XCTest
import IMCore
import IMTestSupport
@testable import imessage

/// Rule: every verb and flag in the section 5 table parses, `show --from` comes from ours.py, `--json` is accepted
/// anywhere, and `send` follows its text, `--file` and `--thread` rules.
final class ArgumentParserTests: XCTestCase {
    func testEveryVerbAndFlagInTheSection5TableParses() {
        let cases: [([String], Command)] = [
            (["chats"], .chats(limit: 20, unreadOnly: false)),
            (["chats", "-n", "5", "--unread"], .chats(limit: 5, unreadOnly: true)),
            (["unread"], .unread(context: 2)),
            (["unread", "-c", "4"], .unread(context: 4)),
            (["read", "Mom"], .read(who: "Mom", limit: 30, before: nil, after: nil, around: nil, since: nil)),
            (["read", "Mom", "-n", "10", "--before", "41000", "--since", "7d"],
             .read(who: "Mom", limit: 10, before: 41000, after: nil, around: nil, since: "7d")),
            (["read", "12", "--after", "41500"],
             .read(who: "12", limit: 30, before: nil, after: 41500, around: nil, since: nil)),
            (["read", "+14155550101", "--around", "41418", "-n", "12"],
             .read(who: "+14155550101", limit: 12, before: nil, after: nil, around: 41418, since: nil)),
            (["show", "40927"], .show(rowid: 40927, fromByte: 0)),
            (["show", "41558", "--from", "8192"], .show(rowid: 41558, fromByte: 8192)),
            (["search", "address"], .search(text: "address", inWho: nil, since: nil, cursor: nil, limit: 20)),
            (["search", "address", "--in", "Dad", "--since", "2w", "--cursor", "815000000000000000:41000:0", "-n", "5"],
             .search(text: "address", inWho: "Dad", since: "2w", cursor: "815000000000000000:41000:0", limit: 5)),
            (["who", "Mom"], .who(name: "Mom")),
            (["att", "a9904"], .att(id: 9904)),
            (["att", "9904"], .att(id: 9904)),
            (["send", "Mom", "On my way"], .send(who: "Mom", text: "On my way", file: nil, again: false, thread: false)),
            (["send", "Mom", "--file", "/tmp/a.pdf"], .send(who: "Mom", text: nil, file: "/tmp/a.pdf", again: false, thread: false)),
            (["send", "Mom", "caption", "--file", "a.pdf", "--again"],
             .send(who: "Mom", text: "caption", file: "a.pdf", again: true, thread: false)),
            (["send", "Mom", "yes", "--thread"], .send(who: "Mom", text: "yes", file: nil, again: false, thread: true)),
            (["react", "41418", "heart"], .react(rowid: 41418, kind: .heart, remove: false, again: false)),
            (["react", "41418", "like", "--remove", "--again"], .react(rowid: 41418, kind: .like, remove: true, again: true)),
            (["unsend", "41418"], .unsend(rowid: 41418, again: false)),
            (["unsend", "41418", "--again"], .unsend(rowid: 41418, again: true)),
            (["edit", "41418", "fixed text"], .edit(rowid: 41418, text: "fixed text", again: false)),
            (["edit", "41418", "fixed text", "--again"], .edit(rowid: 41418, text: "fixed text", again: true)),
            (["allow", "Mom"], .allow(who: "Mom", files: false, foreground: false)),
            (["allow", "Mom", "--files"], .allow(who: "Mom", files: true, foreground: false)),
            (["allow", "--foreground"], .allow(who: nil, files: false, foreground: true)),
            (["revoke", "Mom"], .revoke(who: "Mom", foreground: false)),
            (["revoke", "--foreground"], .revoke(who: nil, foreground: true)),
            (["pending"], .pending(id: nil)),
            (["pending", "ap-123"], .pending(id: "ap-123")),
            (["wait"], .wait(fromWho: nil, timeout: 300)),
            (["wait", "--from", "Mom", "--timeout", "60"], .wait(fromWho: "Mom", timeout: 60)),
            (["changes"], .changes(since: nil)),
            (["changes", "--since", "41500:815646600000000000"], .changes(since: "41500:815646600000000000")),
            (["changes", "--since", "41500:815646600000000000:41200"],
             .changes(since: "41500:815646600000000000:41200")),
            (["caps"], .caps),
            (["doctor"], .doctor(wantUIActions: false)),
            (["doctor", "--ui"], .doctor(wantUIActions: true)),
            (["setup"], .setup),
        ]
        for (args, want) in cases {
            XCTAssertEqual(parsed(args), want, "\(args)")
        }
        // Every verb the parser knows, except help, is covered above.
        let covered = Set(cases.map { $0.0[0] })
        XCTAssertEqual(covered, Set(ArgumentParser.specs.keys).subtracting(["help"]))
        // And every flag of every verb.
        for (verb, spec) in ArgumentParser.specs {
            for flag in spec.bools.union(spec.values) {
                XCTAssertTrue(cases.contains { $0.0[0] == verb && $0.0.contains(flag) }, "\(verb) \(flag)")
            }
        }
    }

    func testEveryTapbackKindParses() {
        let named: [(String, TapbackKind)] = [("heart", .heart), ("love", .heart), ("like", .like),
                                              ("dislike", .dislike), ("laugh", .laugh), ("emphasize", .emphasize),
                                              ("question", .question), ("HEART", .heart)]
        for (word, kind) in named {
            XCTAssertEqual(parsed(["react", "1", word]), .react(rowid: 1, kind: kind, remove: false, again: false))
        }
        for emoji in ["😂", "❤️", "👍🏽", "👨‍👩‍👧", "🇮🇳", "🫠"] {
            XCTAssertEqual(parsed(["react", "1", emoji]), .react(rowid: 1, kind: .emoji(emoji), remove: false, again: false),
                           emoji)
        }
    }

    func testReactRejectsAnythingButAKindOrOneEmoji() {
        for bad in ["hearts", "ok", "😂😂", "é", "ab😀", "1", "©", "x"] {
            let e = usageError(["react", "41418", bad])
            XCTAssertEqual(e?.fix, "use heart, like, dislike, laugh, emphasize, question or one emoji", bad)
        }
        XCTAssertEqual(usageError(["react", "41418", " "])?.message, "<kind> is empty")
    }

    /// ours.py's `show` footer is `…(+N bytes: imessage show <rowid> --from <N>)`; that command must parse.
    func testShowFromComesFromTheOursFooter() {
        XCTAssertEqual(parsed(["show", "41558", "--from", "8192"]), .show(rowid: 41558, fromByte: 8192))
        XCTAssertEqual(parsed(["show", "41558", "--from", "0"]), .show(rowid: 41558, fromByte: 0))
        XCTAssertNotNil(usageError(["show", "41558", "--from", "-1"]))
        XCTAssertNotNil(usageError(["show", "41558", "--from"]))
        XCTAssertTrue(ArgumentParser.helpText("show").contains("show <rowid> [--from N]"))
    }

    func testJsonIsAcceptedAnywhere() throws {
        let want = Command.read(who: "Mom", limit: 10, before: nil, after: nil, around: nil, since: nil)
        let spots: [[String]] = [
            ["--json", "read", "Mom", "-n", "10"],
            ["read", "--json", "Mom", "-n", "10"],
            ["read", "Mom", "--json", "-n", "10"],
            ["read", "Mom", "-n", "10", "--json"],
            ["--json", "read", "Mom", "--json", "-n", "10", "--json"],
        ]
        for args in spots {
            let inv = try ArgumentParser.parse(args)
            XCTAssertTrue(inv.json, "\(args)")
            XCTAssertEqual(inv.command, want, "\(args)")
        }
        XCTAssertFalse(try ArgumentParser.parse(["read", "Mom", "-n", "10"]).json)
        for verb in ["chats", "unread", "caps", "doctor", "setup", "pending", "changes", "wait"] {
            XCTAssertTrue(try ArgumentParser.parse([verb, "--json"]).json, verb)
        }
    }

    func testDoubleDashEndsFlagsSoTextCanStartWithADash() throws {
        XCTAssertEqual(parsed(["send", "Mom", "--", "-5 degrees here"]),
                       .send(who: "Mom", text: "-5 degrees here", file: nil, again: false, thread: false))
        let inv = try ArgumentParser.parse(["send", "Mom", "--", "--json"])
        XCTAssertFalse(inv.json)
        XCTAssertEqual(inv.command, .send(who: "Mom", text: "--json", file: nil, again: false, thread: false))
        let e = usageError(["send", "Mom", "-5 degrees"])
        XCTAssertEqual(e?.message, "send doesn't take \"-5 degrees\"")
        XCTAssertTrue(e?.fix?.contains("put -- before text that starts with -") ?? false)
    }

    /// The search footer puts its flags first and `--` before a query that starts with `-`.
    func testTheSearchFooterFormParses() {
        let cursor = SearchCursor(dateNs: 5, rowid: 299, windowStartNs: 1).text
        XCTAssertEqual(parsed(["search", "--in", "12", "--cursor", cursor, "--", "-1 day"]),
                       .search(text: "-1 day", inWho: "12", since: nil, cursor: cursor, limit: Limits.defaultSearchLimit))
        XCTAssertEqual(parsed(["search", "--cursor", cursor, "jalebi"]),
                       .search(text: "jalebi", inWho: nil, since: nil, cursor: cursor, limit: Limits.defaultSearchLimit))
    }

    func testSendNeedsTextUnlessFileIsGiven() {
        XCTAssertEqual(usageError(["send", "Mom"])?.message, "send needs text unless --file is given")
        XCTAssertEqual(usageError(["send", "Mom", ""])?.message, "send needs text unless --file is given")
        XCTAssertEqual(usageError(["send", "Mom", " \n\t "])?.message, "send needs text unless --file is given")
        XCTAssertEqual(usageError(["send", "Mom", "--again"])?.message, "send needs text unless --file is given")
        // Blank text with a file is no text part at all.
        XCTAssertEqual(parsed(["send", "Mom", "  ", "--file", "a.pdf"]),
                       .send(who: "Mom", text: nil, file: "a.pdf", again: false, thread: false))
        // Text is passed as typed, not trimmed.
        XCTAssertEqual(parsed(["send", "Mom", " hi "]),
                       .send(who: "Mom", text: " hi ", file: nil, again: false, thread: false))
        XCTAssertEqual(usageError(["send"])?.message, "send needs <who>")
        XCTAssertEqual(usageError(["send", "", "hi"])?.message, "<who> is empty")
        XCTAssertEqual(usageError(["send", "Mom", "--file", ""])?.message, "--file is empty")
        XCTAssertEqual(usageError(["send", "Mom", "--file"])?.message, "--file needs a value")
    }

    func testThreadWithFileIsTheResultsUsageError() {
        for args in [["send", "Mom", "hi", "--thread", "--file", "a.pdf"],
                     ["send", "Mom", "--file", "a.pdf", "--thread"],
                     ["send", "--thread", "--file", "a.pdf"]] {
            let e = usageError(args)
            XCTAssertEqual(e?.line, ActionResult.threadWithFile.rendered, "\(args)")
        }
        XCTAssertEqual(UsageError(ActionResult.threadWithFile).line,
                       "error: --thread can't be combined with --file fix: send the file and the reply separately")
        // --thread needs text, since the file can't carry it.
        XCTAssertEqual(usageError(["send", "Mom", "--thread"])?.message, "send needs text unless --file is given")
    }

    func testSendAndEditTakeOneTextArgument() {
        let e = usageError(["send", "Mom", "On", "my", "way"])
        XCTAssertEqual(e?.message, "too many arguments for send: \"my\"")
        XCTAssertEqual(e?.fix, "quote <text> if it has spaces, or see imessage help send")
        XCTAssertNotNil(usageError(["edit", "41418", "a", "b"]))
        XCTAssertEqual(usageError(["edit", "41418"])?.message, "edit needs <text>")
        XCTAssertEqual(usageError(["edit", "41418", "  "])?.message, "<text> is empty")
        XCTAssertNotNil(usageError(["read", "Jordan", "Kim"]))
    }

    func testWhoAndSearchJoinTheirWords() {
        XCTAssertEqual(parsed(["who", "Jordan", "Kim"]), .who(name: "Jordan Kim"))
        XCTAssertEqual(parsed(["search", "home", "address", "-n", "3"]),
                       .search(text: "home address", inWho: nil, since: nil, cursor: nil, limit: 3))
        XCTAssertEqual(usageError(["who"])?.message, "who needs <name>")
        XCTAssertEqual(usageError(["who", " "])?.message, "<name> is empty")
        XCTAssertEqual(usageError(["search"])?.message, "search needs <text>")
    }

    func testSearchTextIsCappedAt500Characters() {
        let longest = String(repeating: "\u{1F600}", count: Limits.searchQueryMaxChars)
        XCTAssertEqual(parsed(["search", longest]),
                       .search(text: longest, inWho: nil, since: nil, cursor: nil, limit: 20))
        let over = usageError(["search", longest + "a"])
        XCTAssertEqual(over?.message, "search text is over 500 characters")
        XCTAssertEqual(over?.fix, "search a shorter phrase")
        let words = Array(repeating: "ab", count: 168)
        XCTAssertEqual(usageError(["search"] + words)?.message, "search text is over 500 characters",
                       "the words join with spaces before the count")
    }

    func testAllowAndRevokeTakeWhoOrForegroundNotBoth() {
        XCTAssertEqual(usageError(["allow", "Mom", "--foreground"])?.message,
                       "allow takes <who> or --foreground, not both")
        XCTAssertEqual(usageError(["revoke", "--foreground", "Mom"])?.message,
                       "revoke takes <who> or --foreground, not both")
        XCTAssertEqual(usageError(["allow"])?.message, "allow needs <who> or --foreground")
        XCTAssertEqual(usageError(["revoke"])?.message, "revoke needs <who> or --foreground")
        XCTAssertEqual(usageError(["allow", "--foreground", "--files"])?.message, "--files only goes with allow <who>")
        XCTAssertEqual(usageError(["revoke", "Mom", "--files"])?.message, "revoke doesn't take \"--files\"")
        XCTAssertNotNil(usageError(["allow", "Mom", "Dad"]))
    }

    func testDoctorTakesOnlyUI() {
        XCTAssertEqual(usageError(["doctor", "--files"])?.message, "doctor doesn't take \"--files\"")
        XCTAssertNotNil(usageError(["doctor", "now"]))
        XCTAssertNotNil(usageError(["doctor", "--ui", "--ui"]))
    }

    func testNumbersAtTheirBoundaries() {
        XCTAssertEqual(parsed(["chats", "-n", "1"]), .chats(limit: 1, unreadOnly: false))
        XCTAssertNotNil(usageError(["chats", "-n", "0"]))
        XCTAssertEqual(parsed(["unread", "-c", "0"]), .unread(context: 0))
        XCTAssertNotNil(usageError(["unread", "-c", "-1"]))
        XCTAssertEqual(parsed(["show", "1"]), .show(rowid: 1, fromByte: 0))
        XCTAssertNotNil(usageError(["show", "0"]))
        XCTAssertEqual(parsed(["show", "9223372036854775807"]), .show(rowid: Int64.max, fromByte: 0))
        XCTAssertNotNil(usageError(["show", "9223372036854775808"]))
        XCTAssertEqual(parsed(["wait", "--timeout", "1"]), .wait(fromWho: nil, timeout: 1))
        XCTAssertNotNil(usageError(["wait", "--timeout", "0"]))
        XCTAssertEqual(parsed(["read", "7", "--before", "1"]),
                       .read(who: "7", limit: 30, before: 1, after: nil, around: nil, since: nil))
        XCTAssertNotNil(usageError(["read", "7", "--before", "0"]))
        for bad in ["+5", "5.0", " 5", "5 ", "0x10", "1e3", "١٢", "", "five"] {
            XCTAssertNotNil(usageError(["chats", "-n", bad]), bad)
            XCTAssertNotNil(usageError(["unsend", bad]), bad)
        }
        XCTAssertEqual(usageError(["chats", "-n", "0"])?.message, "-n needs a whole number of at least 1, got \"0\"")
    }

    func testAttachmentIDForms() {
        XCTAssertEqual(parsed(["att", "a1"]), .att(id: 1))
        for bad in ["a", "a0", "0", "aa1", "b12", "a-1", "a 1"] {
            XCTAssertNotNil(usageError(["att", bad]), bad)
        }
    }

    func testReadTakesOnlyOneOfBeforeAfterAround() {
        for pair in [["--before", "--after"], ["--before", "--around"], ["--after", "--around"]] {
            let e = usageError(["read", "7", pair[0], "10", pair[1], "20"])
            XCTAssertEqual(e?.message, "use only one of --before, --after and --around")
        }
        XCTAssertEqual(parsed(["read", "7", "--around", "40", "--since", "today"]),
                       .read(who: "7", limit: 30, before: nil, after: nil, around: 40, since: "today"))
    }

    func testSinceAcceptsEveryTimeSpecForm() {
        for t in ["30m", "12h", "7d", "2w", "today", "yesterday", "2026-10-01", "2026-10-01T09:30"] {
            XCTAssertEqual(parsed(["read", "7", "--since", t]),
                           .read(who: "7", limit: 30, before: nil, after: nil, around: nil, since: t), t)
            XCTAssertEqual(parsed(["search", "x", "--since", t]),
                           .search(text: "x", inWho: nil, since: t, cursor: nil, limit: 20), t)
        }
        for bad in ["2026-02-30", "soon", "7y", "2026-10-01 09:30", "-3d"] {
            XCTAssertNotNil(usageError(["read", "7", "--since", bad]), bad)
        }
    }

    func testCursorsMustParse() {
        XCTAssertEqual(usageError(["search", "x", "--cursor", "41000"])?.message,
                       "--cursor \"41000\" isn't a search cursor")
        XCTAssertEqual(usageError(["changes", "--since", "7d"])?.message, "--since \"7d\" isn't a changes cursor")
        XCTAssertNotNil(usageError(["changes", "--since", "1:2:3:4"]))
        XCTAssertNotNil(usageError(["changes", "--since", "1:2:x"]))
    }

    func testUnknownMissingAndRepeatedArguments() {
        XCTAssertEqual(usageError([])?.message, "missing verb")
        XCTAssertEqual(usageError(["--json"])?.message, "missing verb")
        XCTAssertEqual(usageError(["sned", "Mom", "hi"])?.message, "unknown verb \"sned\"")
        XCTAssertEqual(usageError(["--version"])?.message, "unknown flag \"--version\" before the verb")
        XCTAssertEqual(usageError(["chats", "--file", "x"])?.message, "chats doesn't take \"--file\"")
        XCTAssertEqual(usageError(["chats", "-n", "5", "-n", "6"])?.message, "-n is given twice")
        XCTAssertEqual(usageError(["send", "Mom", "hi", "--again", "--again"])?.message, "--again is given twice")
        XCTAssertEqual(usageError(["read", "Mom", "-n"])?.message, "-n needs a value")
        XCTAssertEqual(usageError(["caps", "now"])?.message, "caps takes no argument, got \"now\"")
        XCTAssertEqual(usageError(["read"])?.message, "read needs <who>")
        XCTAssertEqual(usageError(["read", ""])?.message, "<who> is empty")
        XCTAssertEqual(usageError(["wait", "--from", ""])?.message, "--from is empty")
    }

    func testHelpForms() {
        XCTAssertEqual(parsed(["help"]), .help(topic: nil))
        XCTAssertEqual(parsed(["--help"]), .help(topic: nil))
        XCTAssertEqual(parsed(["-h", "send"]), .help(topic: "send"))
        XCTAssertEqual(parsed(["help", "send"]), .help(topic: "send"))
        XCTAssertEqual(parsed(["send", "--help"]), .help(topic: "send"))
        XCTAssertEqual(parsed(["send", "Mom", "-h"]), .help(topic: "send"))
        let send = ArgumentParser.helpText("send")
        XCTAssertTrue(send.hasPrefix("usage: imessage <verb> [args] [--json]\n"))
        XCTAssertTrue(send.contains("send <who> [<text>] [--file P] [--again] [--thread]"))
        XCTAssertFalse(send.contains("unread [-c 2]"))
        XCTAssertEqual(ArgumentParser.helpText(nil), ArgumentParser.usage + "\n")
        XCTAssertEqual(ArgumentParser.helpText("nonsense"), ArgumentParser.usage + "\n")
    }

    func testUsageErrorLinesAreOneLineWithOneSpaceBeforeFix() {
        let e = UsageError(message: "bad\nthing", fix: "do\nthis")
        XCTAssertEqual(e.line, "error: bad / thing fix: do / this")
        XCTAssertEqual(UsageError(message: "plain", fix: nil).line, "error: plain")
    }
}
