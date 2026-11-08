import XCTest
import IMCore
import IMTestSupport
@testable import imessage

/// Each parsed command becomes one typed wire request (named ops only), with `--since` converted by `TimeSpec` in the
/// caller's time zone, and a response wait that covers the approval wait, the queue wait and the action's timeouts.
final class RequestMappingTests: XCTestCase {
    let now = Fixture.now
    let la = Fixture.timeZone

    func body(_ args: [String], file: StaticString = #filePath, line: UInt = #line) throws -> RequestBody {
        let command = try XCTUnwrap(parsed(args, file: file, line: line), file: file, line: line)
        return try CLI.request(for: command, now: now, timeZone: la).body
    }

    func testEveryCommandMapsToItsNamedOp() throws {
        let cases: [([String], RequestBody)] = [
            (["chats", "-n", "3", "--unread"], .chats(ChatsArgs(limit: 3, unreadOnly: true))),
            (["unread", "-c", "0"], .unread(UnreadArgs(context: 0))),
            (["read", "Mom", "-n", "10", "--around", "41418"],
             .messages(MessagesArgs(who: "Mom", limit: 10, around: 41418))),
            (["show", "41558", "--from", "8192"], .message(MessageArgs(rowid: 41558, fromByte: 8192))),
            (["search", "address", "--in", "Dad", "-n", "5"], .search(SearchArgs(text: "address", inWho: "Dad", limit: 5))),
            (["who", "Jordan", "Kim"], .contacts(ContactsArgs(name: "Jordan Kim"))),
            (["att", "a9904"], .attachment(AttachmentArgs(id: 9904))),
            (["send", "Mom", "hi", "--again"], .send(SendArgs(who: "Mom", text: "hi", again: true))),
            (["send", "Mom", "yes", "--thread"], .send(SendArgs(who: "Mom", text: "yes", thread: true))),
            (["react", "41418", "laugh", "--remove"],
             .ui(UIArgs(action: .react(rowid: 41418, kind: .laugh, remove: true)))),
            (["unsend", "41418", "--again"], .ui(UIArgs(action: .unsend(rowid: 41418), again: true))),
            (["edit", "41418", "new"], .ui(UIArgs(action: .edit(rowid: 41418, text: "new")))),
            (["allow", "Mom", "--files"], .allow(AllowArgs(who: "Mom", files: true))),
            (["allow", "--foreground"], .allow(AllowArgs(who: nil, foreground: true))),
            (["revoke", "Mom"], .revoke(RevokeArgs(who: "Mom"))),
            (["revoke", "--foreground"], .revoke(RevokeArgs(who: nil, foreground: true))),
            (["pending", "ap-1"], .pending(PendingArgs(id: "ap-1"))),
            (["wait", "--from", "Mom", "--timeout", "45"], .wait(WaitArgs(fromWho: "Mom", timeout: 45))),
            (["changes", "--since", "1:2"], .changes(ChangesArgs(since: "1:2"))),
            (["caps"], .caps),
            (["doctor", "--ui"], .doctor(DoctorArgs(wantUIActions: true))),
            (["setup"], .setup(SetupArgs(stage: .fullDiskAccess))),
        ]
        for (args, want) in cases {
            XCTAssertEqual(try body(args), want, "\(args)")
        }
    }

    func testRequestsCarryTheWireVersionAndApprovalWait() throws {
        let r = try CLI.request(for: .send(who: "Mom", text: "hi", file: nil, again: false, thread: false),
                                now: now, timeZone: la)
        XCTAssertEqual(r.v, Request.protocolVersion)
        XCTAssertNil(r.upload)
        guard case .send(let a) = r.body else { return XCTFail("\(r.body)") }
        XCTAssertEqual(a.approvalWait, Limits.approvalWait)
    }

    /// The golden `read 12 --since 2026-10-30T01:30` is exactly seven days before the fixture's now, in Los Angeles.
    func testSinceIsConvertedInTheCallersTimeZone() throws {
        guard case .messages(let a) = try body(["read", "12", "--since", "2026-10-30T01:30"]) else { return XCTFail() }
        XCTAssertEqual(a.sinceNs, Fixture.nowNs - 7 * 86_400 * 1_000_000_000)

        for t in ["30m", "12h", "7d", "2w", "today", "yesterday", "2026-10-01", "2026-10-01T09:30"] {
            guard case .search(let s) = try body(["search", "x", "--since", t]) else { return XCTFail(t) }
            XCTAssertEqual(s.sinceNs, TimeSpec.parseNanos(t, now: now, timeZone: la), t)
        }
        let utc = TimeZone(identifier: "UTC")!
        let inUTC = try CLI.request(for: .read(who: "7", limit: 30, before: nil, after: nil, around: nil, since: "today"),
                                    now: now, timeZone: utc)
        guard case .messages(let u) = inUTC.body, case .messages(let l) = try body(["read", "7", "--since", "today"])
        else { return XCTFail() }
        XCTAssertNotEqual(u.sinceNs, l.sinceNs)
        XCTAssertEqual(l.sinceNs, TimeSpec.parseNanos("today", now: now, timeZone: la))
    }

    func testBadSinceIsAUsageErrorBeforeTheRequestExists() {
        XCTAssertThrowsError(try CLI.request(for: .read(who: "7", limit: 30, before: nil, after: nil, around: nil,
                                                        since: "someday"), now: now, timeZone: la)) { e in
            XCTAssertEqual((e as? UsageError)?.message, "--since \"someday\" isn't a time")
        }
    }

    func testHelpNeverBecomesARequest() {
        XCTAssertThrowsError(try CLI.request(for: .help(topic: nil), now: now, timeZone: la)) { e in
            XCTAssertTrue(e is UsageError)
        }
    }

    func testResponseWaitCoversApprovalQueueAndActionTimeouts() {
        let slack = CLI.responseSlack
        let send = CLI.responseTimeout(for: .send(SendArgs(who: "Mom", text: "hi")))
        XCTAssertEqual(send, Limits.approvalWait + Limits.queueWait + CLI.sendActionTime + slack)
        let ui = CLI.responseTimeout(for: .ui(UIArgs(action: .unsend(rowid: 1))))
        XCTAssertGreaterThan(ui, Limits.approvalWait + Limits.queueWait + Limits.coldStartTimeout
                             + Limits.idleGateTimeout + Limits.foregroundVerifyTimeout)
        XCTAssertEqual(CLI.responseTimeout(for: .allow(AllowArgs(who: "Mom"))), Limits.approvalWait + slack)
        XCTAssertEqual(CLI.responseTimeout(for: .revoke(RevokeArgs(who: "Mom"))), Limits.approvalWait + slack)
        XCTAssertEqual(CLI.responseTimeout(for: .wait(WaitArgs(timeout: 300))), 300 + slack)
        XCTAssertEqual(CLI.responseTimeout(for: .search(SearchArgs(text: "x"))), Limits.searchBudget + slack)
        XCTAssertEqual(CLI.responseTimeout(for: .chats(ChatsArgs())), slack)
        XCTAssertEqual(CLI.responseTimeout(for: .doctor(DoctorArgs())), Limits.coldStartTimeout + slack)
        // A shorter approval wait shortens the client's wait with it.
        XCTAssertEqual(CLI.responseTimeout(for: .send(SendArgs(who: "Mom", text: "hi", approvalWait: 10))), send - 110)
    }

    /// The longest plain send, a text plus a file with one cold-start retry: a cold start, the text call and the
    /// file call, one of which finds Messages closed, a second cold start and that call again, then the correlation
    /// wait. Each call counts at its full timeout.
    func testSendWaitCoversTextFileAndOneColdStartRetry() {
        let coldStarts = 2 * Limits.coldStartTimeout
        let calls = 3 * Limits.sendEventTimeout
        XCTAssertEqual(CLI.sendActionTime, coldStarts + calls + Limits.correlationTimeout)
        XCTAssertEqual(CLI.sendActionTime, 160, "60 + 10 + 10 + 60 + 10, then 10 of correlation")
        let send = CLI.responseTimeout(for: .send(SendArgs(who: "Mom", text: "hi")))
        XCTAssertEqual(send, Limits.approvalWait + Limits.queueWait + 160 + CLI.responseSlack)
        // One cold start and the correlation, the wait before, left the calls and the retry to the slack.
        XCTAssertGreaterThan(CLI.sendActionTime, Limits.coldStartTimeout + Limits.correlationTimeout + CLI.responseSlack)
    }

    /// `send --thread` is a foreground action, so its wait also covers the idle gate and the foreground steps. It makes
    /// no script call, so the plain send's calls and retry aren't in it.
    func testThreadedReplyWaitCoversTheForegroundSteps() {
        let thread = CLI.responseTimeout(for: .send(SendArgs(who: "Mom", text: "hi", thread: true)))
        let foreground = Limits.idleGateTimeout + Limits.activationTimeout + Limits.lateActivationWatch
            + Limits.returnDeadline + Limits.hidePoll + Limits.focusRestoreWait + Limits.foregroundVerifyTimeout
        XCTAssertEqual(CLI.foregroundActionTime, foreground)
        XCTAssertEqual(thread, Limits.approvalWait + Limits.queueWait + Limits.coldStartTimeout
                       + Limits.correlationTimeout + foreground + CLI.responseSlack)
        XCTAssertGreaterThan(thread, Limits.approvalWait + Limits.queueWait + Limits.coldStartTimeout + foreground
                             + Limits.correlationTimeout)
        // edit, the other foreground action, gets at least as long.
        XCTAssertGreaterThanOrEqual(CLI.responseTimeout(for: .ui(UIArgs(action: .edit(rowid: 1, text: "x")))), thread)
    }

    func testMutationsAreMarkedSoALostAnswerNeverSuggestsAgain() {
        let mutations: [Command] = [
            .send(who: "M", text: "x", file: nil, again: true, thread: false),
            .react(rowid: 1, kind: .heart, remove: false, again: true), .unsend(rowid: 1, again: true),
            .edit(rowid: 1, text: "x", again: true), .allow(who: "M", files: false, foreground: false),
            .revoke(who: nil, foreground: true),
        ]
        XCTAssertTrue(mutations.allSatisfy(\.isMutation))
        let reads: [Command] = [.chats(limit: 1, unreadOnly: false), .unread(context: 0), .who(name: "x"), .caps,
                                .pending(id: nil), .wait(fromWho: nil, timeout: 1), .changes(since: nil), .setup,
                                .doctor(wantUIActions: false), .att(id: 1), .show(rowid: 1, fromByte: 0)]
        XCTAssertFalse(reads.contains(where: \.isMutation))
    }
}
