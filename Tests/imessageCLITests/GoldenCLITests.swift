import XCTest
import IMCore
import IMTestSupport
@testable import imessage

/// Rule: the success output of chats, unread, read, show and who, run through `CLI.run` against a bridge that
/// answers with the golden record, equals bench/renderers/ours.py byte for byte. Bytes are compared, not Swift
/// strings, because String equality treats NFC and NFD as equal.
final class GoldenCLITests: XCTestCase {
    /// ours.py prints 253 lines for this case, past the 200-line cap. IMCore's own tests check the capped text.
    static let overCap: Set<String> = ["read-12-n200"]

    func payload(_ c: Golden.Case) throws -> ResponsePayload {
        switch c.verb {
        case "chats": return .chats(try Golden.record(ChatsPage.self, c.name))
        case "unread": return .unread(try Golden.record(UnreadPage.self, c.name))
        case "read": return .messages(try Golden.record(MessagesPage.self, c.name))
        case "show": return .message(try Golden.record(MessageDetail.self, c.name))
        case "who": return .contacts(try Golden.record(ContactsPage.self, c.name))
        default: throw SysError(errno: EINVAL)
        }
    }

    /// `imessage read 12 -n 10` as argv. The golden commands hold no quotes, so splitting on spaces is exact.
    static func argv(_ c: Golden.Case) -> [String] {
        Array(c.command.split(separator: " ").map(String.init).dropFirst())
    }

    /// The op each verb must send.
    static func op(_ body: RequestBody) -> String {
        switch body {
        case .chats: return "chats"
        case .unread: return "unread"
        case .messages: return "read"
        case .message: return "show"
        case .contacts: return "who"
        default: return "other"
        }
    }

    func testEveryCaseMatchesOursByteForByteThroughTheCLI() throws {
        let cases = try Golden.cases()
        XCTAssertGreaterThanOrEqual(cases.count, 70)
        let current = Current()
        let bridge = try makeBridge { r in
            guard let (c, p) = current.get(), GoldenCLITests.op(r.body) == c.verb else {
                return .reply([], P.failure("wrong op"))
            }
            return .reply([], p)
        }
        var compared = 0
        for c in cases {
            current.set((c, try payload(c)))
            let run = CLIRun()
            XCTAssertEqual(run.run(GoldenCLITests.argv(c), bridge.client()), 0, "\(c.command): \(run.stderrText)")
            XCTAssertEqual(run.stderrText, "", c.command)
            if GoldenCLITests.overCap.contains(c.name) {
                XCTAssertLessThanOrEqual(run.stdoutText.split(separator: "\n").count, Limits.outputMaxLines, c.command)
                XCTAssertLessThanOrEqual(run.stdout.count, Limits.outputMaxBytes, c.command)
                continue
            }
            let want = try Golden.text(c.name)
            compared += 1
            if run.stdout != want {
                let w = String(decoding: want, as: UTF8.self).components(separatedBy: "\n")
                let g = run.stdoutText.components(separatedBy: "\n")
                let i = (0..<min(w.count, g.count)).first { Data(w[$0].utf8) != Data(g[$0].utf8) } ?? min(w.count, g.count)
                XCTFail("\(c.command) [\(c.name)] differs at line \(i + 1)\nwant: \(i < w.count ? w[i] : "<end>")\n"
                        + " got: \(i < g.count ? g[i] : "<end>")")
            }
        }
        XCTAssertEqual(compared, cases.count - GoldenCLITests.overCap.count)
        XCTAssertEqual(bridge.requests.count, cases.count)
    }

    /// The requests behind the golden commands carry the arguments the records were made with.
    func testGoldenCommandsSendTheirArguments() throws {
        let bridge = try makeBridge { _ in P.failure("x") }
        let want: [String: RequestBody] = [
            "read-mom-n10": .messages(MessagesArgs(who: "Mom", limit: 10)),
            "read-12-since": .messages(MessagesArgs(who: "12", limit: 30, sinceNs: 815_041_800_000_000_000)),
            "read-9-before-41000": .messages(MessagesArgs(who: "9", before: 41000)),
            "read-7-after-41500": .messages(MessagesArgs(who: "7", after: 41500)),
            "read-around-multiline-long": .messages(MessagesArgs(who: "7", limit: 12, around: 40458)),
            "who-jordan-kim": .contacts(ContactsArgs(name: "Jordan Kim")),
            "who-meera-desai": .contacts(ContactsArgs(name: "meera desai")),
            "show-40927": .message(MessageArgs(rowid: 40927)),
            "chats-unread-n2": .chats(ChatsArgs(limit: 2, unreadOnly: true)),
            "unread-c0": .unread(UnreadArgs(context: 0)),
        ]
        let cases = try Golden.cases()
        for (name, body) in want {
            let c = try XCTUnwrap(cases.first { $0.name == name }, name)
            _ = CLIRun().run(GoldenCLITests.argv(c), bridge.client())
            XCTAssertEqual(bridge.requests.last?.body, body, c.command)
        }
        XCTAssertEqual(Fixture.nowNs - 7 * 86_400 * 1_000_000_000, 815_041_800_000_000_000)
    }

    func testJsonOfAGoldenCaseIsTheNDJSONOfItsRecord() throws {
        let page = try Golden.record(MessagesPage.self, "read-mom-n10")
        let bridge = try makeBridge { _ in .messages(page) }
        let run = CLIRun()
        XCTAssertEqual(run.run(["read", "Mom", "-n", "10", "--json"], bridge.client()), 0)
        XCTAssertEqual(run.stdout, Data(Format.ndjson(.messages(page)).utf8))
    }
}

/// The golden case the fake bridge answers right now.
final class Current {
    private let lock = NSLock()
    private var value: (Golden.Case, ResponsePayload)?
    func set(_ v: (Golden.Case, ResponsePayload)) { lock.withLock { value = v } }
    func get() -> (Golden.Case, ResponsePayload)? { lock.withLock { value } }
}
