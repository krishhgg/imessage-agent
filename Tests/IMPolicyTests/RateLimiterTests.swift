import Foundation
import IMCore
@testable import IMPolicy
import IMStore
import IMTestSupport
import XCTest

/// Section 2, Rate limits: 1 per 20 s per chat, 30 per chat per day, 100 per day, 3 in a row with no reply.
final class RateLimiterTests: XCTestCase {
    private var clock: FakeClock!
    private var activity: ScriptedActivity!
    private var limiter: RateLimiter!
    private let mom = T.chat(T.mom)

    override func setUp() {
        clock = FakeClock()
        activity = ScriptedActivity()
        limiter = RateLimiter(clock: clock, activity: activity, ownAddresses: { [T.ownAddress] })
    }

    private func ago(_ seconds: TimeInterval) -> Date { clock.now.addingTimeInterval(-seconds) }

    private func sent(_ secondsAgo: TimeInterval, to chat: CanonicalChatID = T.mom, guid: String? = nil,
                      text: String? = nil) {
        limiter.record(SendEvent(chat: chat, at: ago(secondsAgo), guid: guid,
                                 textDigest: text.map(TextNorm.textDigest)))
    }

    private func check(_ chat: CanonicalChatID = T.mom) -> RateLimitBreach? {
        do { return try limiter.check(chat: T.chat(chat)) } catch {
            XCTFail("check threw \(error)")
            return nil
        }
    }

    /// A reply from the other side, so the consecutive check stays out of the way.
    private func reply(_ chat: CanonicalChatID = T.mom, _ secondsAgo: TimeInterval = 1) {
        activity.inbound(chat, at: ago(secondsAgo))
    }

    // MARK: 1 send per 20 s per chat

    func testSendWithinTwentySecondsBreaches() {
        sent(19.999)
        XCTAssertEqual(check(), .perChatInterval)
    }

    func testSendExactlyTwentySecondsLaterIsAllowed() {
        sent(20)
        XCTAssertNil(check())
    }

    func testIntervalIsPerChat() {
        sent(1, to: T.dad)
        XCTAssertNil(check(T.mom))
        XCTAssertEqual(check(T.dad), .perChatInterval)
    }

    // MARK: 30 per chat per day

    func testThirtiethSendIsAllowedAndTheThirtyFirstAsks() {
        reply()
        for i in 0..<29 { sent(Double(i) * 600 + 60) }
        XCTAssertNil(check())
        sent(29 * 600 + 60)
        XCTAssertEqual(check(), .perChatDaily)
    }

    func testASendExactly24HoursOldNoLongerCounts() {
        reply()
        for i in 0..<29 { sent(Double(i) * 600 + 60) }
        sent(RateLimiter.day)
        XCTAssertNil(check())
        sent(RateLimiter.day - 0.001)
        XCTAssertEqual(check(), .perChatDaily)
    }

    // MARK: 100 per day

    func testHundredSendsAcrossChatsAsksForAnyChat() {
        let chats = (0..<4).map { CanonicalChatID.direct(handle: "+1415555020\($0)") }
        for chat in chats { reply(chat) }
        for n in 0..<99 { sent(Double(n) * 120 + 60, to: chats[n % 4]) }
        XCTAssertNil(check(T.sis))
        sent(99 * 120 + 60, to: chats[3])
        XCTAssertEqual(check(T.sis), .globalDaily)
    }

    func testGlobalDayIsRollingToo() {
        let chats = (0..<4).map { CanonicalChatID.direct(handle: "+1415555030\($0)") }
        for n in 0..<99 { sent(Double(n) * 120 + 60, to: chats[n % 4]) }
        sent(RateLimiter.day, to: chats[0])
        XCTAssertNil(check(T.sis))
    }

    // MARK: 3 in a row with no reply

    func testThreeSendsWithNoReplyBreach() {
        sent(300)
        sent(200)
        XCTAssertNil(check())
        sent(100)
        XCTAssertEqual(check(), .consecutive)
    }

    func testAReplyAfterTheOldestOfTheLastThreeResetsTheCount() {
        sent(300)
        sent(200)
        sent(100)
        reply(T.mom, 250)
        XCTAssertNil(check())
    }

    func testAReplyBeforeTheLastThreeDoesntCount() {
        sent(400)
        reply(T.mom, 350)
        sent(300)
        sent(200)
        sent(100)
        XCTAssertEqual(check(), .consecutive)
    }

    func testAReplyInAnotherChatDoesntCount() {
        sent(300)
        sent(200)
        sent(100)
        reply(T.dad, 50)
        XCTAssertEqual(check(), .consecutive)
    }

    func testTheCheckAsksForRowsAfterTheOldestOfTheLastThree() throws {
        sent(400)
        sent(300)
        sent(200)
        sent(100)
        _ = check()
        XCTAssertEqual(activity.calls.first?.afterNs, AppleTime.nanos(from: ago(300)))
        XCTAssertEqual(activity.calls.first?.chat, T.mom)
        XCTAssertEqual(activity.calls.first?.limit, RateLimiter.inboundPageSize)
    }

    // MARK: Echo rows

    func testRowWithASentGUIDIsAnEcho() {
        sent(300, guid: "SENT-1")
        sent(200, guid: "SENT-2")
        sent(100, guid: "SENT-3")
        activity.inbound(T.mom, at: ago(199), guid: "SENT-2")
        XCTAssertEqual(check(), .consecutive)
    }

    func testRowWithASentDigestInTheSelfChatIsAnEcho() {
        sent(300, to: T.me, text: "one")
        sent(200, to: T.me, text: "two")
        sent(100, to: T.me, text: "On my way")
        activity.inbound(T.me, at: ago(99), text: "  On my way\n")
        XCTAssertEqual(check(T.me), .consecutive)
    }

    func testEchoDatedBeforeItsSendIsStillAnEcho() {
        // An incoming copy can carry a server time a little before the bridge's own clock.
        sent(300, to: T.me, text: "a")
        sent(200, to: T.me, text: "b")
        sent(100, to: T.me, text: "c")
        activity.inbound(T.me, at: ago(102), text: "c")
        XCTAssertEqual(check(T.me), .consecutive)
    }

    func testSameTextReplyInAnotherPersonsChatResetsTheCount() {
        // Only a self-chat gets copies of the user's own sends, so here the same text is a real reply.
        sent(300, text: "a")
        sent(200, text: "ok")
        sent(100, text: "c")
        activity.inbound(T.mom, at: ago(50), text: "ok")
        XCTAssertNil(check())
    }

    func testSelfChatIsAOneToOneChatWithAnOwnAddress() {
        XCTAssertTrue(RateLimiter.isSelfChat(T.chat(T.me), own: [T.ownAddress]))
        XCTAssertTrue(RateLimiter.isSelfChat(T.chat(T.me), own: ["(415) 555-0100"]), "compared normalized")
        XCTAssertFalse(RateLimiter.isSelfChat(mom, own: [T.ownAddress]))
        XCTAssertFalse(RateLimiter.isSelfChat(T.chat(T.me), own: []))
        var group = T.chat(T.group)
        group.canonical = T.me
        XCTAssertFalse(RateLimiter.isSelfChat(group, own: [T.ownAddress]), "a group is never a self-chat")
    }

    func testDigestOfAnotherChatsSendIsARealReply() {
        sent(500, to: T.dad, text: "hello")
        sent(300, to: T.me, text: "a")
        sent(200, to: T.me, text: "b")
        sent(100, to: T.me, text: "c")
        activity.inbound(T.me, at: ago(50), text: "hello")
        XCTAssertNil(check(T.me))
    }

    func testRealReplyBehindAPageOfEchoesIsFound() {
        sent(300, to: T.me, text: "a")
        sent(200, to: T.me, text: "b")
        sent(100, to: T.me, text: "c")
        for i in 0..<RateLimiter.inboundPageSize {
            activity.inbound(T.me, at: ago(90 - Double(i)), text: "c")
        }
        activity.inbound(T.me, at: ago(5), text: "real reply")
        XCTAssertNil(check(T.me))
        XCTAssertEqual(activity.calls.count, 2)
    }

    func testOnlyEchoesUpToThePageCapStillBreach() {
        sent(3000, to: T.me, text: "a")
        sent(2900, to: T.me, text: "b")
        sent(2800, to: T.me, text: "c")
        let echoes = RateLimiter.inboundPageSize * RateLimiter.maxInboundPages
        for i in 0..<echoes { activity.inbound(T.me, at: ago(2700 - Double(i) * 2), text: "c") }
        activity.inbound(T.me, at: ago(1), text: "real reply")
        XCTAssertEqual(check(T.me), .consecutive)
        XCTAssertEqual(activity.calls.count, RateLimiter.maxInboundPages)
    }

    // MARK: Errors

    func testInboundReadErrorThrows() {
        sent(300)
        sent(200)
        sent(100)
        activity.error = FakeFailure()
        XCTAssertThrowsError(try limiter.check(chat: mom)) { XCTAssertEqual($0 as? FakeFailure, FakeFailure()) }
    }

    func testFewerThanThreeSendsNeverReadChatDB() {
        sent(300)
        sent(200)
        activity.error = FakeFailure()
        XCTAssertNoThrow(try limiter.check(chat: mom))
        XCTAssertTrue(activity.calls.isEmpty)
    }

    func testIntervalIsReportedBeforeTheOtherLimits() {
        for i in 0..<29 { sent(Double(i) * 600 + 60) }
        sent(5)
        XCTAssertEqual(check(), .perChatInterval)
    }

    // MARK: History

    func testHistoryIsSortedAndKeepsSevenDays() {
        sent(100)
        sent(500)
        sent(300)
        XCTAssertEqual(limiter.history.map(\.at), [ago(500), ago(300), ago(100)])
        sent(Limits.journalRetention)
        XCTAssertEqual(limiter.history.count, 3)
        sent(Limits.journalRetention - 1)
        XCTAssertEqual(limiter.history.count, 4)
    }

    func testHistoryPassedAtStartIsUsedAndPruned() {
        let history = [
            SendEvent(chat: T.mom, at: ago(5), guid: nil, textDigest: nil),
            SendEvent(chat: T.mom, at: ago(Limits.journalRetention + 1), guid: nil, textDigest: nil),
        ]
        let restarted = RateLimiter(clock: clock, activity: activity, ownAddresses: { [] }, history: history)
        XCTAssertEqual(restarted.history.count, 1)
        XCTAssertEqual(try restarted.check(chat: mom), .perChatInterval)
    }

    func testLimitsSurviveARestartThroughTheJournal() throws {
        let dir = TempDir()
        let journal = try Journal(directory: dir.url, clock: clock)
        let entry = try journal.begin(key: T.sendKey(), action: .send, chat: T.mom, binding: T.sendBinding(T.mom))
        try journal.recorder(for: entry.id).willInvoke(InvocationFacts(snapshotRowID: 500))
        try journal.finish(entry.id, result: ActionResult(.delivered),
                           response: T.sendOutcome(ActionResult(.delivered), guid: "ROW-GUID"))
        limiter.record(try XCTUnwrap(journal.sendEvent(for: entry.id)))

        clock.advance(10)
        let reopened = try Journal(directory: dir.url, clock: clock)
        let restarted = RateLimiter(clock: clock, activity: activity, ownAddresses: { [] },
                                    history: reopened.sendEvents())
        XCTAssertEqual(restarted.history, limiter.history)
        XCTAssertEqual(restarted.history.first?.guid, "ROW-GUID")
        XCTAssertEqual(restarted.history.first?.textDigest, TextNorm.textDigest("On my way"))
        XCTAssertEqual(try restarted.check(chat: mom), .perChatInterval)
    }

    // MARK: Thread safety

    func testConcurrentRecordsAndChecks() {
        let limiter = RateLimiter(clock: SystemClock(), activity: activity, ownAddresses: { [] })
        let base = Date()
        concurrently(200) { i in
            if i % 2 == 0 {
                limiter.record(SendEvent(chat: T.mom, at: base.addingTimeInterval(-Double(i) * 30), guid: "g\(i)",
                                         textDigest: nil))
            } else {
                _ = try? limiter.check(chat: self.mom)
            }
        }
        let history = limiter.history
        XCTAssertEqual(history.count, 100)
        XCTAssertEqual(history.map(\.at), history.map(\.at).sorted())
    }
}
