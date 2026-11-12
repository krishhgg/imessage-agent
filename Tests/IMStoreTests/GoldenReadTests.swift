import XCTest
import IMCore
@testable import IMStore
import IMTestSupport

/// End to end on the fixture: each golden case runs through `ReadService`, `Format` renders the page, and the bytes
/// must equal what bench/renderers/ours.py printed (docs/BUILD-PLAN.md, IMCore checklist). Bytes are compared, not
/// Swift strings, because String equality treats NFC and NFD as equal.
final class GoldenReadTests: XCTestCase {
    /// ours.py prints 253 lines for this case, past the 200-line cap. Its records are compared instead.
    static let overCap: Set<String> = ["read-12-n200"]

    /// The words of a golden command after `imessage <verb>`. Quoting never appears in the cases.
    static func words(_ command: String) -> [String] {
        Array(command.split(separator: " ").map(String.init).dropFirst(2))
    }

    static func value(_ flag: String, in words: [String]) -> String? {
        guard let i = words.firstIndex(of: flag), i + 1 < words.count else { return nil }
        return words[i + 1]
    }

    /// The positional words: everything that is not a flag or a flag's value.
    static func positional(_ words: [String], flagsWithValues: Set<String>) -> [String] {
        var out: [String] = []
        var i = 0
        while i < words.count {
            if flagsWithValues.contains(words[i]) {
                i += 2
            } else if words[i].hasPrefix("--") {
                i += 1
            } else {
                out.append(words[i])
                i += 1
            }
        }
        return out
    }

    func render(_ c: Golden.Case, _ reader: ReadService) throws -> String {
        let ctx = Golden.context
        let w = GoldenReadTests.words(c.command)
        switch c.verb {
        case "chats":
            let n = GoldenReadTests.value("-n", in: w).flatMap(Int.init) ?? Limits.defaultChatsLimit
            return Format.chats(try reader.chats(ChatsArgs(limit: n, unreadOnly: w.contains("--unread"))), ctx)
        case "unread":
            let context = GoldenReadTests.value("-c", in: w).flatMap(Int.init) ?? Limits.defaultUnreadContext
            return Format.unread(try reader.unread(UnreadArgs(context: context)), ctx)
        case "read":
            return Format.messages(try reader.messages(try GoldenReadTests.messagesArgs(w)), ctx)
        case "show":
            return Format.show(try reader.message(MessageArgs(rowid: try XCTUnwrap(Int64(w[0])))), ctx)
        case "who":
            return Format.who(try reader.contacts(ContactsArgs(name: w.joined(separator: " "))))
        default:
            XCTFail("unknown verb \(c.verb)")
            return ""
        }
    }

    static func messagesArgs(_ w: [String]) throws -> MessagesArgs {
        let valued: Set<String> = ["-n", "--before", "--after", "--around", "--since"]
        let who = positional(w, flagsWithValues: valued).joined(separator: " ")
        var args = MessagesArgs(who: who, limit: value("-n", in: w).flatMap(Int.init) ?? Limits.defaultReadLimit)
        args.before = value("--before", in: w).flatMap { Int64($0) }
        args.after = value("--after", in: w).flatMap { Int64($0) }
        args.around = value("--around", in: w).flatMap { Int64($0) }
        if let since = value("--since", in: w) {
            args.sinceNs = try XCTUnwrap(TimeSpec.parseNanos(since, now: Fixture.now, timeZone: Fixture.timeZone))
        }
        return args
    }

    func testEveryCaseMatchesOursByteForByte() throws {
        let reader = try TestStore.reader()
        let cases = try Golden.cases()
        XCTAssertGreaterThanOrEqual(cases.count, 70)
        var compared = 0
        for c in cases where !GoldenReadTests.overCap.contains(c.name) {
            let want = try Golden.expectedText(c) { chat, rowid in
                !(try reader.messages(MessagesArgs(who: String(chat), limit: 1, after: rowid)).messages.isEmpty)
            }
            let got: Data
            do {
                got = Data(try render(c, reader).utf8)
            } catch {
                XCTFail("\(c.command) [\(c.name)] threw \(error)")
                continue
            }
            compared += 1
            if got != want {
                let w = String(decoding: want, as: UTF8.self).components(separatedBy: "\n")
                let g = String(decoding: got, as: UTF8.self).components(separatedBy: "\n")
                let i = (0..<min(w.count, g.count)).first { Data(w[$0].utf8) != Data(g[$0].utf8) }
                    ?? min(w.count, g.count)
                XCTFail("\(c.command) [\(c.name)] differs at line \(i + 1)\nwant: \(i < w.count ? w[i] : "<end>")"
                        + "\n got: \(i < g.count ? g[i] : "<end>")")
            }
        }
        XCTAssertEqual(compared, cases.count - GoldenReadTests.overCap.count)
    }

    /// The over-cap case renders through Format's cap, so its page is compared message by message with the
    /// captured record instead.
    func testOverCapReadReturnsTheCapturedMessages() throws {
        let reader = try TestStore.reader()
        for name in GoldenReadTests.overCap {
            let c = try XCTUnwrap(Golden.cases().first { $0.name == name })
            let want = try Golden.record(MessagesPage.self, name)
            let got = try reader.messages(try GoldenReadTests.messagesArgs(GoldenReadTests.words(c.command)))
            XCTAssertEqual(got.messages.map(\.rowid), want.messages.map(\.rowid))
            XCTAssertEqual(got.totalVisible, want.totalVisible)
            XCTAssertEqual(got.olderExists, want.olderExists)
            let ctx = Golden.context
            XCTAssertEqual(Data(Format.messages(got, ctx).utf8), Data(Format.messages(want, ctx).utf8))
        }
    }
}
