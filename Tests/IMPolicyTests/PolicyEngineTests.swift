import Foundation
import IMCore
@testable import IMPolicy
import IMStore
import IMTestSupport
import XCTest

/// Section 2: who asks, who is allowed, who is refused, and what "Always allow" grants.
final class PolicyEngineTests: XCTestCase {
    private var dir: TempDir!
    private var keychain: InMemoryKeychain!
    private var store: PolicyStore!
    private var clock: FakeClock!
    private var activity: ScriptedActivity!
    private var limiter: RateLimiter!
    private var engine: PolicyEngine!

    override func setUp() {
        dir = TempDir()
        keychain = InMemoryKeychain()
        store = PolicyStore(fileURL: dir.file("policy.json"), keychain: keychain)
        clock = FakeClock()
        activity = ScriptedActivity()
        limiter = RateLimiter(clock: clock, activity: activity, ownAddresses: { [] })
        engine = PolicyEngine(store: store, limiter: limiter, clock: clock)
    }

    override func tearDown() {
        engine = nil
        store = nil
        dir = nil
    }

    private func evaluate(_ request: MutationRequest) -> PolicyDecision {
        do { return try engine.evaluate(request) } catch {
            XCTFail("evaluate threw \(error)")
            return .refused(ActionResult(.error(.message("threw"))))
        }
    }

    private func prompt(_ request: MutationRequest, file: StaticString = #filePath, line: UInt = #line)
        -> ApprovalPrompt? {
        guard case .needsApproval(let p) = evaluate(request) else {
            XCTFail("expected a dialog, got \(evaluate(request))", file: file, line: line)
            return nil
        }
        return p
    }

    private func react(_ chat: CanonicalChatID, remove: Bool = false) -> MutationRequest {
        T.request(ApprovalBinding(chat: chat, action: .react, targetGUID: "G", targetPart: 0, tapback: .heart,
                                  remove: remove))
    }

    private func uiRequest(_ action: MutationKind, _ chat: CanonicalChatID = T.mom) -> MutationRequest {
        let digest = action == .unsend ? nil : TextNorm.textDigest("new text")
        let binding = ApprovalBinding(chat: chat, action: action, textDigest: digest,
                                      targetGUID: action == .threadedReply ? nil : "G",
                                      targetPart: action == .threadedReply ? nil : 0,
                                      parentGUID: action == .threadedReply ? "PARENT" : nil)
        return T.request(binding)
    }

    private func policyRequest(_ action: MutationKind) -> MutationRequest {
        let chat: CanonicalChatID? = (action == .allowChat || action == .revokeChat) ? T.mom : nil
        return T.request(ApprovalBinding(chat: chat, action: action, scope: action == .allowChat ? .files : nil))
    }

    private func tamper() {
        keychain.hash = Data(repeating: 7, count: 32)
    }

    // MARK: Allowed chats and scopes

    func testAllowedChatSendsTextWithoutAsking() throws {
        try store.allow(T.mom, label: "Mom", scope: .text)
        XCTAssertEqual(evaluate(T.sendRequest(T.mom)), .allowed)
    }

    func testChatNotAllowedAsksAndOffersAlwaysAllow() throws {
        try store.allow(T.dad, label: "Dad", scope: .files)
        let request = T.sendRequest(T.mom)
        guard let p = prompt(request) else { return }
        XCTAssertTrue(p.offersAlwaysAllow)
        XCTAssertEqual(p.reason, "this chat isn't allowed yet")
        XCTAssertEqual(p.binding, request.binding)
        XCTAssertEqual(p.title, "Send to +14155550101")
        XCTAssertEqual(p.text, "On my way")
        XCTAssertEqual(p.id.count, 8)
    }

    func testADirectChatsDialogCarriesTheHandleTheSendAddressesAndItsService() throws {
        var request = T.sendRequest(T.mom)
        request.chat?.label = "Juan"
        request.chat?.sendHandle = "+15512345678"
        request.chat?.service = "SMS"
        guard let p = prompt(request) else { return }
        XCTAssertEqual(p.chatLabel, "Juan")
        XCTAssertEqual(p.sendHandle, "+15512345678", "the chat's send handle, not the label or the canonical ID")
        XCTAssertEqual(p.service, "SMS")

        try store.setForegroundMode(true)
        for request in [uiRequest(.threadedReply), policyRequest(.allowChat)] {
            guard let p = prompt(request) else { return }
            XCTAssertEqual(p.sendHandle, "+14155550101", "\(request.binding.action)")
            XCTAssertEqual(p.service, "iMessage", "\(request.binding.action)")
        }
    }

    /// `send_text` and `send_file` use the SMS account for an SMS chat and the iMessage account for any other service
    /// (BUILD-PLAN 16), so the dialog carries that account and never `RCS`. The script's `is` ignores case.
    func testADirectChatsDialogCarriesTheAccountTheSendUses() throws {
        let cases = [("RCS", "iMessage"), ("iMessage", "iMessage"), ("SMS", "SMS"), ("sms", "SMS"), ("", "iMessage")]
        for (service, shown) in cases {
            var request = T.sendRequest(T.mom)
            request.chat?.service = service
            guard let p = prompt(request) else { return }
            XCTAssertEqual(p.service, shown, service)
        }
        var allow = policyRequest(.allowChat)
        allow.chat?.service = "RCS"
        XCTAssertEqual(prompt(allow)?.service, "iMessage", "an allow names the account later sends use")
    }

    func testAGroupDialogCarriesNoHandleOrService() {
        guard let p = prompt(T.sendRequest(T.group)) else { return }
        XCTAssertNil(p.sendHandle)
        XCTAssertNil(p.service)
        guard let off = prompt(policyRequest(.foregroundOn)) else { return }
        XCTAssertNil(off.sendHandle, "a request with no chat names no handle")
    }

    func testTextScopeAllowsTapbacks() throws {
        try store.allow(T.mom, label: "Mom", scope: .text)
        XCTAssertEqual(evaluate(react(T.mom)), .allowed)
        XCTAssertEqual(evaluate(react(T.mom, remove: true)), .allowed)
    }

    func testTextScopeAsksForAnAttachment() throws {
        try store.allow(T.mom, label: "Mom", scope: .text)
        guard let p = prompt(T.sendRequest(T.mom, text: nil, attachment: "file-digest")) else { return }
        XCTAssertTrue(p.offersAlwaysAllow)
        XCTAssertEqual(p.reason, "this chat is allowed for text and tapbacks only")
        XCTAssertEqual(p.title, "Send a file to +14155550101")
        XCTAssertEqual(p.attachmentName, "photo.jpg")
        XCTAssertEqual(p.attachmentBytes, 2_200_000)
    }

    func testFilesScopeAllowsAttachments() throws {
        try store.allow(T.dad, label: "Dad", scope: .files)
        XCTAssertEqual(evaluate(T.sendRequest(T.dad, attachment: "file-digest")), .allowed)
        XCTAssertEqual(evaluate(T.sendRequest(T.dad)), .allowed)
    }

    func testAttachmentDigestNeedsFilesScopeWhateverTheRequestSays() throws {
        try store.allow(T.mom, label: "Mom", scope: .text)
        var request = T.sendRequest(T.mom, attachment: "file-digest")
        request.requiredScope = .text
        XCTAssertEqual(PolicyEngine.requiredScope(request), .files)
        XCTAssertNotNil(prompt(request))
    }

    func testAlwaysAllowGrantsTheApprovedActionsScope() throws {
        try engine.applyAlwaysAllow(T.sendRequest(T.mom))
        XCTAssertEqual(store.entry(for: T.mom)?.scope, .text)
        XCTAssertEqual(evaluate(T.sendRequest(T.mom)), .allowed)
        XCTAssertNotNil(prompt(T.sendRequest(T.mom, attachment: "file-digest")))

        try engine.applyAlwaysAllow(T.sendRequest(T.mom, attachment: "file-digest"))
        XCTAssertEqual(store.entry(for: T.mom)?.scope, .files)
        XCTAssertEqual(evaluate(T.sendRequest(T.mom, attachment: "file-digest")), .allowed)
    }

    func testAlwaysAllowOnATapbackGrantsText() throws {
        try engine.applyAlwaysAllow(react(T.sis))
        XCTAssertEqual(store.entry(for: T.sis)?.scope, .text)
        XCTAssertEqual(store.entry(for: T.sis)?.label, "sis@example.com")
    }

    func testAlwaysAllowNeverNarrowsAScope() throws {
        try store.allow(T.dad, label: "Dad", scope: .files)
        try engine.applyAlwaysAllow(T.sendRequest(T.dad))
        XCTAssertEqual(store.entry(for: T.dad)?.scope, .files)
    }

    func testAlwaysAllowIsRefusedForActionsThatAlwaysAsk() throws {
        let requests = [uiRequest(.unsend), uiRequest(.edit), uiRequest(.threadedReply)]
            + [MutationKind.allowChat, .revokeChat, .foregroundOn, .foregroundOff].map(policyRequest)
        for request in requests {
            XCTAssertThrowsError(try engine.applyAlwaysAllow(request)) { error in
                XCTAssertEqual(error as? PolicyEngineError, .alwaysAllowNotOffered(request.binding.action))
            }
        }
        XCTAssertEqual(keychain.writes, 0)
        XCTAssertNil(store.entry(for: T.mom))
    }

    func testAlwaysAllowIsRefusedWhenTheChatDoesntMatch() {
        var request = T.sendRequest(T.mom)
        request.chat = T.chat(T.dad)
        XCTAssertThrowsError(try engine.applyAlwaysAllow(request)) { error in
            XCTAssertEqual(error as? PolicyEngineError, .chatMismatch)
        }
        request.chat = nil
        XCTAssertThrowsError(try engine.applyAlwaysAllow(request))
        XCTAssertEqual(keychain.writes, 0)
    }

    // MARK: Actions that always ask

    func testUnsendEditAndThreadedReplyAlwaysAskWithoutAlwaysAllow() throws {
        try store.allow(T.mom, label: "Mom", scope: .files)
        try store.setForegroundMode(true)
        let expected: [MutationKind: (String, String)] = [
            .unsend: ("unsend always asks", "Unsend your message in +14155550101"),
            .edit: ("edit always asks", "Edit your message in +14155550101"),
            .threadedReply: ("threaded replies always ask", "Reply in +14155550101"),
        ]
        for (action, (reason, title)) in expected {
            guard let p = prompt(uiRequest(action)) else { continue }
            XCTAssertFalse(p.offersAlwaysAllow, "\(action)")
            XCTAssertEqual(p.reason, reason)
            XCTAssertEqual(p.title, title)
        }
    }

    func testUnsendAsksEvenWithForegroundModeOff() throws {
        try store.allow(T.mom, label: "Mom", scope: .files)
        XCTAssertFalse(prompt(uiRequest(.unsend))?.offersAlwaysAllow ?? true)
    }

    func testPolicyChangesAlwaysGoThroughTheDialog() throws {
        try store.allow(T.mom, label: "Mom", scope: .files)
        try store.setForegroundMode(true)
        let titles: [MutationKind: String] = [
            .allowChat: "Allow +14155550101, with files",
            .revokeChat: "Revoke +14155550101",
            .foregroundOn: "Turn on foreground mode",
            .foregroundOff: "Turn off foreground mode",
        ]
        for (action, title) in titles {
            guard let p = prompt(policyRequest(action)) else { continue }
            XCTAssertFalse(p.offersAlwaysAllow, "\(action)")
            XCTAssertEqual(p.title, title)
        }
    }

    func testPolicyChangesAskWithoutAlwaysAllowOnAnUntrustedStore() throws {
        try store.allow(T.mom, label: "Mom", scope: .files)
        tamper()
        for action in [MutationKind.allowChat, .revokeChat, .foregroundOn, .foregroundOff] {
            XCTAssertFalse(prompt(policyRequest(action))?.offersAlwaysAllow ?? true, "\(action)")
        }
    }

    // MARK: Foreground mode

    func testForegroundActionsAreRefusedWhileForegroundModeIsOff() throws {
        try store.allow(T.mom, label: "Mom", scope: .files)
        for action in [MutationKind.edit, .threadedReply] {
            XCTAssertEqual(evaluate(uiRequest(action)), .refused(PolicyEngine.foregroundModeOff))
        }
        XCTAssertEqual(PolicyEngine.foregroundModeOff.rendered,
                       "error: foreground mode is off fix: imessage allow --foreground")
    }

    func testForegroundModeTurnedOffRefusesForegroundActions() throws {
        try store.allow(T.mom, label: "Mom", scope: .files)
        try store.setForegroundMode(true)
        XCTAssertNotNil(prompt(uiRequest(.edit)))
        store.turnForegroundOff(reason: "Messages left open")
        XCTAssertEqual(evaluate(uiRequest(.edit)), .refused(PolicyEngine.foregroundModeOff))
    }

    func testUntrustedStoreRefusesForegroundActions() throws {
        try store.allow(T.mom, label: "Mom", scope: .files)
        try store.setForegroundMode(true)
        tamper()
        XCTAssertEqual(evaluate(uiRequest(.threadedReply)), .refused(PolicyEngine.foregroundModeOff))
    }

    // MARK: Untrusted store

    func testUntrustedStoreAsksForEveryMutation() throws {
        try store.allow(T.mom, label: "Mom", scope: .files)
        tamper()
        for request in [T.sendRequest(T.mom), react(T.mom), T.sendRequest(T.mom, attachment: "d")] {
            guard let p = prompt(request) else { continue }
            XCTAssertTrue(p.offersAlwaysAllow)
            XCTAssertEqual(p.reason, "the allowed chats failed their tamper check, so every chat asks again")
        }
        XCTAssertFalse(prompt(uiRequest(.unsend))?.offersAlwaysAllow ?? true)
    }

    func testAlwaysAllowOnAnUntrustedStoreStartsAFreshTrustedList() throws {
        try store.allow(T.dad, label: "Dad", scope: .files)
        tamper()
        try engine.applyAlwaysAllow(T.sendRequest(T.mom))
        XCTAssertEqual(store.load(), .trusted(store.effective))
        XCTAssertEqual(store.effective.entries.map(\.chat), [T.mom])
        XCTAssertEqual(evaluate(T.sendRequest(T.mom)), .allowed)
        XCTAssertNotNil(prompt(T.sendRequest(T.dad)))
    }

    // MARK: Malformed requests

    func testChatActionWithoutAChatIsABadRequest() throws {
        try store.allow(T.mom, label: "Mom", scope: .files)
        var request = T.sendRequest(T.mom)
        request.chat = nil
        XCTAssertEqual(evaluate(request), .refused(PolicyEngine.badRequest))
    }

    func testRequestWhoseChatDiffersFromItsBindingIsABadRequest() throws {
        try store.allow(T.mom, label: "Mom", scope: .files)
        try store.allow(T.dad, label: "Dad", scope: .files)
        var request = T.sendRequest(T.mom)
        request.chat = T.chat(T.dad)
        XCTAssertEqual(evaluate(request), .refused(PolicyEngine.badRequest))
        var noChat = T.sendRequest(T.mom)
        noChat.binding.chat = nil
        XCTAssertEqual(evaluate(noChat), .refused(PolicyEngine.badRequest))
        XCTAssertEqual(PolicyEngine.badRequest.rendered,
                       "error: bad request fix: retry, and run imessage doctor if it happens again")
    }

    // MARK: Rate limits

    func testRateLimitBreachMakesAnAllowedSendAsk() throws {
        try store.allow(T.mom, label: "Mom", scope: .files)
        limiter.record(SendEvent(chat: T.mom, at: clock.now.addingTimeInterval(-5), guid: nil, textDigest: nil))
        guard let p = prompt(T.sendRequest(T.mom)) else { return }
        XCTAssertFalse(p.offersAlwaysAllow)
        XCTAssertEqual(p.reason, RateLimitBreach.perChatInterval.dialogReason)
        XCTAssertTrue(p.namesRateLimit)
    }

    func testThreadedReplyOverARateLimitNamesTheBreach() throws {
        try store.allow(T.mom, label: "Mom", scope: .files)
        try store.setForegroundMode(true)
        let within = prompt(uiRequest(.threadedReply))
        XCTAssertEqual(within?.reason, "threaded replies always ask")
        XCTAssertEqual(within?.namesRateLimit, false)

        limiter.record(SendEvent(chat: T.mom, at: clock.now.addingTimeInterval(-5), guid: nil, textDigest: nil))
        guard let p = prompt(uiRequest(.threadedReply)) else { return }
        XCTAssertEqual(p.reason, RateLimitBreach.perChatInterval.dialogReason)
        XCTAssertEqual(p.title, "Reply in +14155550101")
        XCTAssertFalse(p.offersAlwaysAllow)
        XCTAssertTrue(p.namesRateLimit)
        XCTAssertEqual(engine.rateLimitPrompt(uiRequest(.threadedReply))?.reason, p.reason)
    }

    func testThreadedReplyWhoseRateCheckFailsSaysSo() throws {
        try store.setForegroundMode(true)
        for s in [300.0, 200, 100] {
            limiter.record(SendEvent(chat: T.mom, at: clock.now.addingTimeInterval(-s), guid: nil, textDigest: nil))
        }
        activity.error = FakeFailure()
        XCTAssertEqual(prompt(uiRequest(.threadedReply))?.reason, "the rate limits couldn't be checked")
    }

    func testOnlySendsAndThreadedRepliesGetARateLimitPrompt() throws {
        try store.allow(T.mom, label: "Mom", scope: .files)
        limiter.record(SendEvent(chat: T.mom, at: clock.now.addingTimeInterval(-1), guid: nil, textDigest: nil))
        XCTAssertNil(engine.rateLimitPrompt(uiRequest(.unsend)))
        XCTAssertNil(engine.rateLimitPrompt(uiRequest(.edit)))
        XCTAssertNil(engine.rateLimitPrompt(react(T.mom)))
        XCTAssertNil(engine.rateLimitPrompt(T.sendRequest(T.dad)), "another chat is within its limits")
        XCTAssertNotNil(engine.rateLimitPrompt(T.sendRequest(T.mom)))
    }

    func testRateLimitReadErrorAsks() throws {
        try store.allow(T.mom, label: "Mom", scope: .files)
        for s in [300.0, 200, 100] {
            limiter.record(SendEvent(chat: T.mom, at: clock.now.addingTimeInterval(-s), guid: nil, textDigest: nil))
        }
        activity.error = FakeFailure()
        guard let p = prompt(T.sendRequest(T.mom)) else { return }
        XCTAssertFalse(p.offersAlwaysAllow)
        XCTAssertEqual(p.reason, "the rate limits couldn't be checked")
    }

    func testRateLimitsDontApplyToTapbacks() throws {
        try store.allow(T.mom, label: "Mom", scope: .files)
        limiter.record(SendEvent(chat: T.mom, at: clock.now.addingTimeInterval(-1), guid: nil, textDigest: nil))
        activity.error = FakeFailure()
        XCTAssertEqual(evaluate(react(T.mom)), .allowed)
    }

    func testNotAllowedChatAsksBeforeTheRateLimitsAreRead() throws {
        activity.error = FakeFailure()
        for s in [300.0, 200, 100] {
            limiter.record(SendEvent(chat: T.mom, at: clock.now.addingTimeInterval(-s), guid: nil, textDigest: nil))
        }
        XCTAssertEqual(prompt(T.sendRequest(T.mom))?.reason, "this chat isn't allowed yet")
        XCTAssertTrue(activity.calls.isEmpty)
    }

    // MARK: Titles

    func testTitlesNameTheActionAndTheChat() {
        let tapback = ApprovalBinding(chat: T.mom, action: .react, tapback: .heart)
        XCTAssertEqual(PolicyEngine.title(tapback, label: "Mom"), "React ❤️ in Mom")
        var remove = tapback
        remove.remove = true
        XCTAssertEqual(PolicyEngine.title(remove, label: "Mom"), "Remove ❤️ in Mom")
        XCTAssertEqual(PolicyEngine.title(ApprovalBinding(chat: T.mom, action: .allowChat, scope: .text), label: "Mom"),
                       "Allow Mom")
        XCTAssertEqual(PolicyEngine.title(T.sendBinding(T.mom, attachment: "d"), label: "Mom"), "Send to Mom")
        XCTAssertEqual(PolicyEngine.title(T.sendBinding(T.mom, text: nil, attachment: "d"), label: "Mom"),
                       "Send a file to Mom")
    }
}
