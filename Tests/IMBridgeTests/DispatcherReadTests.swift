import XCTest
@testable import IMBridge
import IMCore
import IMPolicy
import IMSend
import IMStore
import IMTestSupport
import IMUI

/// Read verbs, op routing and request checks through `OpDispatcher`.
final class DispatcherReadTests: XCTestCase {
    func testGoldenCasesRenderTheSameThroughTheDispatcher() throws {
        let h = try Harness()
        let ctx = Golden.context
        var compared = 0
        for c in try Golden.cases() where c.name != "read-12-n200" {
            let body = try GoldenCommand.body(c)
            let got = Data(Format.render(h.call(body), ctx).utf8)
            let want = try Golden.expectedText(c) { chat, rowid in
                guard case .messages(let page) = h.call(.messages(MessagesArgs(who: String(chat), limit: 1, after: rowid)))
                else { throw StoreError.decode("read \(chat)") }
                return !page.messages.isEmpty
            }
            XCTAssertEqual(got, want, "\(c.command) [\(c.name)]")
            compared += 1
        }
        XCTAssertEqual(compared, try Golden.cases().count - 1)
    }

    func testEveryReadVerbAnswersWithItsOwnPayload() throws {
        let h = try Harness()
        guard case .chats(let chats) = h.call(.chats(ChatsArgs(limit: 3))) else { return XCTFail("chats") }
        XCTAssertEqual(chats.chats.count, 3)
        guard case .messages(let page) = h.call(.messages(MessagesArgs(who: "Mom", limit: 5))) else {
            return XCTFail("messages")
        }
        XCTAssertEqual(page.chat.rowid, Mom.chatRowID)
        let rowid = try XCTUnwrap(page.messages.last?.rowid)
        guard case .message(let detail) = h.call(.message(MessageArgs(rowid: rowid))) else { return XCTFail("message") }
        XCTAssertEqual(detail.message.rowid, rowid)
        guard case .unread = h.call(.unread(UnreadArgs())) else { return XCTFail("unread") }
        guard case .contacts(let contacts) = h.call(.contacts(ContactsArgs(name: "Mom"))) else { return XCTFail("contacts") }
        XCTAssertFalse(contacts.contacts.isEmpty)
        guard case .changes = h.call(.changes(ChangesArgs())) else { return XCTFail("changes") }
        guard case .search = h.call(.search(SearchArgs(text: "dinner"))) else { return XCTFail("search") }
        guard case .pong(let pong) = h.call(.ping) else { return XCTFail("ping") }
        XCTAssertEqual(pong.bridgeVersion, AppIdentity.version)
        XCTAssertEqual(pong.pid, getpid())
    }

    func testASearchOver500CharactersIsAnErrorLineWithAFix() throws {
        let h = try Harness()
        let text = String(repeating: "d", count: Limits.searchQueryMaxChars + 1)
        let error = try XCTUnwrap(h.call(.search(SearchArgs(text: text))).failure)
        XCTAssertEqual(Format.error(error), "error: search text is over 500 characters fix: search a shorter phrase\n")
    }

    func testSeveralMatchesCarryCandidatesAndRunNothing() throws {
        let h = try Harness(Harness.Options(contacts: try TwoSams.contactsFile()))
        let error = try XCTUnwrap(h.call(.messages(MessagesArgs(who: "Sam"))).failure)
        XCTAssertEqual(error.result.code, .error(.severalMatches))
        XCTAssertEqual(error.candidates.map(\.label), ["Sam Lee", "Sam Ortiz"])
        XCTAssertNotNil(error.result.fix)

        let before = h.messageCount
        let send = try XCTUnwrap(h.send("hi", to: "Sam").failure)
        XCTAssertEqual(send.result.code, .error(.severalMatches))
        XCTAssertTrue(h.scripts.calls.isEmpty)
        XCTAssertTrue(h.presenter.prompts.isEmpty)
        XCTAssertTrue(h.journal.allEntries().isEmpty)
        XCTAssertEqual(h.messageCount, before)
    }

    func testNoMatchIsOneErrorLineWithAFix() throws {
        let h = try Harness()
        let chat = try XCTUnwrap(h.call(.messages(MessagesArgs(who: "Nobody Atall"))).failure)
        XCTAssertEqual(chat.result.code, .error(.message("no chat or contact matches \"Nobody Atall\"")))
        XCTAssertEqual(chat.result.fix, "pass a phone number, an email or a chat id from imessage chats")
        XCTAssertEqual(Format.error(chat), "error: no chat or contact matches \"Nobody Atall\" fix: pass a phone number, "
                       + "an email or a chat id from imessage chats\n")
    }

    /// Each form of target gets the fix for that form, on every op that takes a target (section 5).
    func testNoMatchFixDependsOnTheFormOfTheTarget() throws {
        let h = try Harness()
        let fixes: [(String, String)] = [
            ("4242", "imessage chats"),
            ("bob@home", "check the email address"),
            ("555-0199", "pass the whole number with + and its country code"),
        ]
        for (who, fix) in fixes {
            XCTAssertEqual(h.call(.messages(MessagesArgs(who: who))).failure?.result.fix, fix, who)
            XCTAssertEqual(h.send("hi", to: who).failure?.result.fix, fix, who)
            XCTAssertEqual(h.call(.allow(AllowArgs(who: who))).failure?.result.fix, fix, who)
        }
        XCTAssertEqual(h.call(.contacts(ContactsArgs(name: "Nobody Atall"))).failure?.result.fix, "imessage chats")
        XCTAssertTrue(h.scripts.calls.isEmpty)
        XCTAssertTrue(h.journal.allEntries().isEmpty)
    }

    func testMissingMessageAndAttachmentAreErrors() throws {
        let h = try Harness()
        XCTAssertEqual(h.call(.message(MessageArgs(rowid: 9_999_999))).failure?.result.code,
                       .error(.message("no message 9999999")))
        XCTAssertEqual(h.call(.attachment(AttachmentArgs(id: 9_999_999))).failure?.result.code,
                       .error(.message("no attachment a9999999")))
    }

    func testStoreErrorsMapToOneLineErrorsWithFixes() {
        let errors: [StoreError] = [.notPermitted, .notFound("x"), .severalMatches([Candidate(label: "A", argument: "1")]),
                                    .noMatch("x"), .timeout, .rowCapExceeded, .sqlite(code: 5, message: "busy\nnow"),
                                    .decode("row 4")]
        for error in errors {
            let wire = WireErrors.map(error, op: .messages)
            XCTAssertNotNil(wire.result.fix, "\(error)")
            let line = Format.error(wire)
            XCTAssertEqual(line.filter { $0 == "\n" }.count, 1, "\(error)")
            XCTAssertTrue(line.hasSuffix("\n"), "\(error)")
        }
        XCTAssertEqual(WireErrors.map(StoreError.noMatch("Zed"), op: .contacts).result.code,
                       .error(.message("no contact matches \"Zed\"")))
        let attachment: [AttachmentError] = [.unsafeCache("/x"), .io("disk"), .conversion("bad")]
        for error in attachment { XCTAssertNotNil(WireErrors.map(error, op: .attachment).result.fix) }
        XCTAssertEqual(WireErrors.upload(UploadError.badName).result, .badRequest)
        for error: UploadError in [.tooLarge, .shortRead, .io("x")] {
            XCTAssertNotNil(WireErrors.upload(error).result.fix)
        }
    }

    func testOtherProtocolVersionsAreBadRequests() throws {
        let h = try Harness()
        var request = Request(body: .ping)
        request.v = 2
        let response = h.dispatcher.handle(request, upload: nil, events: { _ in })
        XCTAssertEqual(response.payload.failure?.result, .badRequest)
        XCTAssertEqual(response.id, request.id)
    }

    func testUploadsAreRefusedOnEveryOpButSend() throws {
        let h = try Harness()
        let bodies: [RequestBody] = [.ping, .chats(ChatsArgs()), .allow(AllowArgs(who: "Mom")),
                                     .ui(UIArgs(action: .unsend(rowid: 1))), .pending(PendingArgs()), .status]
        for body in bodies {
            let payload = h.call(body, upload: Data("abc".utf8))
            XCTAssertEqual(payload.failure?.result, .badRequest, "\(body.op)")
        }
        XCTAssertTrue(h.presenter.prompts.isEmpty)
        XCTAssertTrue(h.journal.allEntries().isEmpty)
    }

    func testAttachmentConversionFollowsTheCapability() throws {
        let rowid = try XCTUnwrap(Int64(try FixtureCopy().strings(
            "SELECT ROWID FROM attachment WHERE transfer_name LIKE '%.HEIC' AND transfer_state = 5 ORDER BY ROWID LIMIT 1").first ?? ""))
        let on = try Harness(Harness.Options(capabilities: [.attachmentConversion]))
        let off = try Harness(Harness.Options(capabilities: []))
        guard case .attachment(let converted) = on.call(.attachment(AttachmentArgs(id: rowid))),
              case .attachment(let original) = off.call(.attachment(AttachmentArgs(id: rowid))) else {
            return XCTFail("attachment")
        }
        XCTAssertNil(converted.result)
        XCTAssertNil(original.result)
        XCTAssertTrue(converted.converted)
        XCTAssertFalse(original.converted)
        XCTAssertNotEqual(converted.path, original.path)
    }

    func testCapsReadsAccessibilitySilently() throws {
        let h = try Harness(Harness.Options(capabilities: [.unsend]))
        h.permissions.accessibilityState = .denied
        guard case .caps(let report) = h.call(.caps) else { return XCTFail("caps") }
        XCTAssertFalse(report.accessibilityTrusted)
        XCTAssertEqual(report.entries.first { $0.name == "unsend" }?.status, .supported)
        XCTAssertEqual(h.permissions.calls, [.accessibility(prompt: false)])
    }
}

/// A golden case's command as a request body, the way the CLI builds it.
enum GoldenCommand {
    static func body(_ c: Golden.Case) throws -> RequestBody {
        let w = Array(c.command.split(separator: " ").map(String.init).dropFirst(2))
        func value(_ flag: String) -> String? {
            guard let i = w.firstIndex(of: flag), i + 1 < w.count else { return nil }
            return w[i + 1]
        }
        switch c.verb {
        case "chats":
            return .chats(ChatsArgs(limit: value("-n").flatMap(Int.init) ?? Limits.defaultChatsLimit,
                                    unreadOnly: w.contains("--unread")))
        case "unread":
            return .unread(UnreadArgs(context: value("-c").flatMap(Int.init) ?? Limits.defaultUnreadContext))
        case "read":
            let valued: Set<String> = ["-n", "--before", "--after", "--around", "--since"]
            var who: [String] = []
            var i = 0
            while i < w.count {
                if valued.contains(w[i]) { i += 2 } else if w[i].hasPrefix("--") { i += 1 } else { who.append(w[i]); i += 1 }
            }
            var args = MessagesArgs(who: who.joined(separator: " "), limit: value("-n").flatMap(Int.init) ?? Limits.defaultReadLimit)
            args.before = value("--before").flatMap { Int64($0) }
            args.after = value("--after").flatMap { Int64($0) }
            args.around = value("--around").flatMap { Int64($0) }
            if let since = value("--since") {
                args.sinceNs = try XCTUnwrap(TimeSpec.parseNanos(since, now: Fixture.now, timeZone: Fixture.timeZone))
            }
            return .messages(args)
        case "show":
            return .message(MessageArgs(rowid: try XCTUnwrap(Int64(w[0]))))
        case "who":
            return .contacts(ContactsArgs(name: w.joined(separator: " ")))
        default:
            XCTFail("unknown verb \(c.verb)")
            return .ping
        }
    }
}
