import XCTest
@testable import IMBridge
import IMCore
import IMPolicy
import IMSend
import IMStore
import IMTestSupport

/// A phone number with no chat in the fixture, and the chat Messages makes for it on the first send.
enum NewPhone {
    static let typed = "(415) 555-0199"
    static let handle = "+14155550199"
    static let canonical = CanonicalChatID.direct(handle: handle)
    static let chatRowID: Int64 = 94
    static let handleRowID: Int64 = 94
}

/// `send` and `allow` to a phone with no chat yet, end to end over the fixture: the dialog, the allowlist key, the
/// approval binding, the idempotency key, the rate limits, the AppleScript call and correlation.
final class NewDirectTargetTests: XCTestCase {
    private func harness(_ options: Harness.Options = Harness.Options()) throws -> Harness {
        let h = try Harness(options)
        h.scripts.newChats = [NewPhone.handle: (chat: NewPhone.chatRowID, handle: NewPhone.handleRowID)]
        return h
    }

    func testASendToAPhoneWithNoChatAsksSendsByHandleAndMatchesTheNewChat() throws {
        let h = try harness()
        let db = try XCTUnwrap(h.container.db)
        let before = try db.resolve(NewPhone.typed)
        XCTAssertEqual(before.canonical, NewPhone.canonical)
        XCTAssertEqual(before.primaryChatRowID, 0)
        XCTAssertTrue(before.chatRowIDs.isEmpty)

        guard case .messages(let empty) = h.call(.messages(MessagesArgs(who: NewPhone.typed))) else {
            return XCTFail("read of a handle with no chat")
        }
        XCTAssertEqual(Format.messages(empty, FormatContext(now: h.clock.now, timeZone: Fixture.timeZone)),
                       "chat \(NewPhone.handle) \(before.label) · 0 of 0 · times PST\n",
                       "the header names the handle, which read takes back, and never chat 0")

        let events = EventLog()
        let outcome = try XCTUnwrap(h.send("Hi, this is Alex", to: NewPhone.typed, events: events).sendOutcome)
        XCTAssertNil(outcome.early)
        XCTAssertTrue(outcome.approved)
        let prompt = try XCTUnwrap(h.presenter.prompts.first)
        XCTAssertEqual(h.presenter.prompts.count, 1)
        XCTAssertEqual(events.events, [.approvalShown(id: prompt.id)])
        XCTAssertEqual(prompt.reason, "this chat isn't allowed yet")
        XCTAssertTrue(prompt.offersAlwaysAllow)
        XCTAssertEqual(prompt.binding.chat, NewPhone.canonical)
        XCTAssertEqual(prompt.chatLabel, before.label)

        XCTAssertEqual(h.scripts.calls.map(\.0), [.sendText])
        XCTAssertEqual(h.scripts.calls.first?.1, [NewPhone.handle, "Hi, this is Alex", "iMessage"])
        XCTAssertEqual(outcome.parts.map(\.result), [ActionResult(.delivered)],
                       "the row joined to the chat Messages just made is confirmed, with no chat unconfirmed note")
        let rowid = try XCTUnwrap(outcome.parts.first?.rowid)
        XCTAssertEqual(try h.copy.int("SELECT chat_id FROM chat_message_join WHERE message_id = \(rowid)"),
                       NewPhone.chatRowID)

        let entry = try h.onlyEntry()
        XCTAssertEqual(entry.state, .final)
        XCTAssertEqual(entry.chat, NewPhone.canonical)
        XCTAssertEqual(entry.binding.chat, NewPhone.canonical)
        XCTAssertEqual(entry.approvalID, prompt.id)
        let guid = try XCTUnwrap(outcome.parts.first?.guid)
        XCTAssertEqual(h.container.engine.limiter.history.map(\.chat), [NewPhone.canonical])
        XCTAssertEqual(h.container.engine.limiter.history.map(\.guid), [guid])
        XCTAssertNil(h.policy.entry(for: NewPhone.canonical), "allow once leaves the chat off the list")

        let after = try db.resolve(NewPhone.typed)
        XCTAssertEqual(after.canonical, NewPhone.canonical, "the new chat keeps the key the send used")
        XCTAssertEqual(after.primaryChatRowID, NewPhone.chatRowID)

        let repeated = try XCTUnwrap(h.send("Hi, this is Alex", to: "+1 415 555 0199").sendOutcome)
        XCTAssertTrue(repeated.replayed, "the same text to the same identity is the same idempotency key")
        XCTAssertEqual(repeated.parts.map(\.guid), outcome.parts.map(\.guid))
        XCTAssertEqual(h.scripts.sentTexts.count, 1)
        XCTAssertEqual(h.presenter.prompts.count, 1)

        let line = Format.send(outcome, FormatContext(now: h.clock.now, timeZone: Fixture.timeZone))
        XCTAssertEqual(line, "approved\nsent \(rowid) to \(before.label) \"Hi, this is Alex\" · delivered\n")
    }

    func testAllowingAPhoneWithNoChatStoresItsIdentitySoItsFirstSendSkipsTheDialog() throws {
        let h = try harness()
        let allowed = try XCTUnwrap(h.call(.allow(AllowArgs(who: NewPhone.typed))).policyOutcome)
        XCTAssertEqual(allowed.result.code, .ok)
        XCTAssertEqual(allowed.chat?.rowid, 0)
        let prompt = try XCTUnwrap(h.presenter.prompts.first)
        XCTAssertEqual(prompt.binding.chat, NewPhone.canonical)
        XCTAssertEqual(h.policy.entry(for: NewPhone.canonical)?.scope, .text)
        let label = try XCTUnwrap(allowed.chat?.label)
        XCTAssertEqual(Format.policy(allowed), "allow \(label) (text) · ok\n", "no chat number 0 in the line")

        let first = try XCTUnwrap(h.send("Running late", to: NewPhone.handle).sendOutcome)
        XCTAssertFalse(first.approved)
        XCTAssertEqual(first.parts.map(\.result.code), [.delivered])
        XCTAssertEqual(h.presenter.prompts.count, 1)

        // The chat exists now. It is the same allowlist key, and the same rate-limit history.
        XCTAssertEqual(h.call(.allow(AllowArgs(who: NewPhone.typed))).headline, .already)
        h.clock.advance(Limits.minSecondsBetweenSendsPerChat - 1)
        let tooSoon = try XCTUnwrap(h.send("one more", to: NewPhone.typed).sendOutcome)
        XCTAssertTrue(tooSoon.approved)
        XCTAssertEqual(h.presenter.prompts.last?.reason, RateLimitBreach.perChatInterval.dialogReason)
        XCTAssertEqual(h.presenter.prompts.last?.namesRateLimit, true)
        XCTAssertEqual(h.scripts.sentTexts, ["Running late", "one more"])
        XCTAssertEqual(h.scripts.calls.last?.1.first, NewPhone.handle)
    }

    func testTheDialogNamesTheHandleAndServiceTheSendThenUses() throws {
        let h = try harness()
        try h.copy.exec("INSERT INTO handle (ROWID, id, service) VALUES (\(NewPhone.handleRowID), '\(NewPhone.handle)', 'SMS')")
        let label = try XCTUnwrap(h.container.db).resolve(NewPhone.typed).label
        let shown = label == NewPhone.handle ? "\(NewPhone.handle) on SMS" : "\(label), \(NewPhone.handle) on SMS"

        XCTAssertEqual(h.call(.allow(AllowArgs(who: NewPhone.typed))).policyOutcome?.result.code, .ok)
        let allow = try XCTUnwrap(h.presenter.prompts.last)
        XCTAssertEqual(ApprovalPanelModel(prompt: allow).lines.first, .init(label: "Chat", value: shown))
        try h.policy.revoke(NewPhone.canonical)

        XCTAssertEqual(h.send("Text me back", to: NewPhone.typed).headline, .submitted)
        let send = try XCTUnwrap(h.presenter.prompts.last)
        XCTAssertEqual(send.binding.action, .send)
        XCTAssertEqual(ApprovalPanelModel(prompt: send).lines.first, .init(label: "Chat", value: shown))
        XCTAssertEqual(h.scripts.calls.first?.1, [NewPhone.handle, "Text me back", "SMS"],
                       "the send goes to the handle and service the dialog named")
    }

    /// Juan Perez is saved as `55 1234 5678`, and his real chat is +525512345678 (chat 98). In a +1 region the
    /// card's number is a new direct target, and the dialog names `+15512345678 on iMessage` before anything goes
    /// out. Elsewhere `send`, `allow` and `read` stop with the saved number and ask for the country code, `who`
    /// prints the number as saved, and the whole number reaches chat 98 with a dialog that names it.
    func testTheJuanCaseThroughTheBridgeDependsOnTheRegion() throws {
        func harness(region: String) throws -> Harness {
            let copy = try FixtureCopy()
            try copy.insertDirectChat(rowid: 98, handleRowID: 40, handle: "+525512345678", service: "iMessage")
            try copy.insertMessage(rowid: 41600, guid: "JUAN-1", chat: 98, handle: 40, text: "hola", fromMe: false,
                                   date: Fixture.nowNs - 60_000_000_000)
            var options = Harness.Options()
            options.copy = copy
            options.contacts = Fixture.contactsLocalNumberJSON
            options.regionCode = region
            return try Harness(options)
        }
        func who(_ h: Harness) throws -> String {
            guard case .contacts(let page) = h.call(.contacts(ContactsArgs(name: "Juan"))) else {
                throw XCTSkip("who returned no page")
            }
            return Format.who(page)
        }

        let us = try harness(region: "US")
        us.scripts.newChats = ["+15512345678": (chat: 95, handle: 95)]
        XCTAssertEqual(try who(us), "Juan = Juan Perez · +1 551-234-5678 · chats: \n")
        XCTAssertEqual(us.send("hola Juan", to: "Juan").headline, .delivered)
        let usPrompt = try XCTUnwrap(us.presenter.prompts.last)
        XCTAssertEqual(usPrompt.binding.chat, .direct(handle: "+15512345678"))
        XCTAssertEqual(ApprovalPanelModel(prompt: usPrompt).lines.first,
                       .init(label: "Chat", value: "Juan Perez, +15512345678 on iMessage"))
        XCTAssertEqual(us.scripts.calls.map(\.1), [["+15512345678", "hola Juan", "iMessage"]])

        for region in ["MX", "GB"] {
            let h = try harness(region: region)
            let before = h.messageCount
            let fix = "pass the whole number with + and its country code"
            let bodies: [RequestBody] = [
                .send(SendArgs(who: "Juan", text: "hola Juan", again: false, thread: false, approvalWait: 120)),
                .allow(AllowArgs(who: "Juan")),
                .messages(MessagesArgs(who: "Juan")),
            ]
            for body in bodies {
                let failure = try XCTUnwrap(h.call(body).failure, "\(region) \(body)")
                XCTAssertEqual(failure.result, WireError.message("no chat or contact matches \"55 1234 5678\"",
                                                                 fix: fix).result, "\(region) \(body)")
            }
            XCTAssertTrue(h.presenter.prompts.isEmpty, region)
            XCTAssertTrue(h.scripts.calls.isEmpty, region)
            XCTAssertEqual(h.messageCount, before, region)
            XCTAssertEqual(try who(h), "Juan = Juan Perez · 55 1234 5678 · chats: \n",
                           "\(region): who never offers the +1 number resolving refused")

            _ = h.send("hola Juan", to: "+52 55 1234 5678")
            let prompt = try XCTUnwrap(h.presenter.prompts.last, region)
            XCTAssertEqual(prompt.binding.chat, .direct(handle: "+525512345678"))
            let label = try XCTUnwrap(prompt.chatLabel)
            let shown = label == "+525512345678" ? "+525512345678 on iMessage" : "\(label), +525512345678 on iMessage"
            XCTAssertEqual(ApprovalPanelModel(prompt: prompt).lines.first, .init(label: "Chat", value: shown), region)
            XCTAssertEqual(h.scripts.calls.map(\.1), [["+525512345678", "hola Juan", "iMessage"]], region)
        }
    }

    func testAHandleChatDBKnowsOnlyFromSMSSendsOnSMS() throws {
        let h = try harness()
        try h.copy.exec("INSERT INTO handle (ROWID, id, service) VALUES (\(NewPhone.handleRowID), '\(NewPhone.handle)', 'SMS')")
        let target = try XCTUnwrap(h.container.db).resolve(NewPhone.typed)
        XCTAssertEqual(target.service, "SMS")
        XCTAssertTrue(target.chatRowIDs.isEmpty)

        let outcome = try XCTUnwrap(h.send("Text me back", to: NewPhone.typed).sendOutcome)
        XCTAssertEqual(h.scripts.calls.first?.1, [NewPhone.handle, "Text me back", "SMS"])
        XCTAssertEqual(outcome.parts.map(\.result), [ActionResult(.submitted)],
                       "SMS never sets date_delivered, and the new chat confirms the row")
        XCTAssertNotNil(outcome.parts.first?.rowid)
    }
}
