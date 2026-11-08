import XCTest
import IMCore
import IMTestSupport

/// `--since T` (section 5). Expected instants come from Python zoneinfo for America/Los_Angeles.
final class TimeSpecTests: XCTestCase {
    let now = Fixture.now // 2026-11-06 00:30 PST, a Friday
    let la = Fixture.timeZone

    func unix(_ s: String) -> Double? { TimeSpec.parse(s, now: now, timeZone: la)?.timeIntervalSince1970 }

    func testFixtureNow() {
        XCTAssertEqual(now.timeIntervalSince1970, 1_793_953_800)
    }

    func testRelativeForms() {
        XCTAssertEqual(unix("30m"), 1_793_953_800 - 1_800)
        XCTAssertEqual(unix("12h"), 1_793_953_800 - 43_200)
        XCTAssertEqual(unix("0d"), 1_793_953_800)
        XCTAssertEqual(unix("999999m"), 1_793_953_800 - 999_999 * 60)
    }

    /// Days and weeks are calendar days, so they keep the wall-clock time across the 2026-11-01 change.
    func testDaysAndWeeksKeepWallClockAcrossDST() {
        XCTAssertEqual(unix("7d"), 1_793_345_400) // 2026-10-30 00:30 PDT, 7 days and 1 hour back
        XCTAssertEqual(unix("1w"), 1_793_345_400)
        XCTAssertEqual(unix("2w"), 1_792_740_600)
        XCTAssertEqual(unix("168h"), 1_793_953_800 - 7 * 86_400)
    }

    func testTodayAndYesterdayAreLocalDayStarts() {
        XCTAssertEqual(unix("today"), 1_793_952_000)
        XCTAssertEqual(unix("TODAY"), 1_793_952_000)
        XCTAssertEqual(unix("yesterday"), 1_793_865_600)
        XCTAssertEqual(unix("Yesterday"), 1_793_865_600)
        XCTAssertEqual(unix("  today \t"), 1_793_952_000)
    }

    func testAbsoluteForms() {
        XCTAssertEqual(unix("2026-10-01"), 1_790_838_000)
        XCTAssertEqual(unix("2026-10-01T09:30"), 1_790_872_200)
        XCTAssertEqual(unix("2026-11-06T00:00"), 1_793_952_000)
        XCTAssertEqual(unix("2026-11-06T23:59"), 1_793_952_000 + 86_340)
        XCTAssertEqual(unix(" 2026-10-01 "), 1_790_838_000)
    }

    func testRepeatedHourTakesTheFirstOccurrence() {
        XCTAssertEqual(unix("2026-11-01T01:30"), 1_793_521_800) // 01:30 PDT
        XCTAssertEqual(unix("2026-11-01T02:00"), 1_793_527_200) // 02:00 PST, after the repeat
    }

    func testSkippedHourUsesTheEarlierOffset() {
        XCTAssertEqual(unix("2026-03-08T02:30"), 1_772_965_800) // shown as 03:30 PDT
        XCTAssertEqual(unix("2026-03-08T03:00"), 1_772_964_000)
        XCTAssertEqual(unix("2026-03-08T01:59"), 1_772_963_940)
    }

    func testLeapDays() {
        XCTAssertNotNil(unix("2028-02-29"))
        XCTAssertNil(unix("2026-02-29"))
        XCTAssertNil(unix("2100-02-29"))
        XCTAssertNotNil(unix("2000-02-29"))
    }

    func testRejects() {
        let bad = [
            "", " ", "7", "d", "7D", "7y", "7s", "-7d", "+7d", "7 d", "1234567d", "٣d", "7d7", "now", "tomorrow",
            "2026-02-30", "2026-04-31", "2026-13-01", "2026-00-10", "2026-10-00", "0000-01-01", "2026-1-01",
            "2026-10-1", "2026/10/01", "2026-10-01T24:00", "2026-10-01T09:60", "2026-10-01 09:30",
            "2026-10-01T9:30", "2026-10-01T09:30:00", "2026-10-01t09:30", "２０２６-10-01", "26-10-01",
        ]
        for s in bad { XCTAssertNil(unix(s), "accepted \(s)") }
    }

    /// The golden `read 12 --since 2026-10-30T01:30` case was captured with `now - 7 * 86400` seconds.
    func testGoldenSinceCutoff() throws {
        let cutoff = Fixture.nowNs - 7 * 86_400 * 1_000_000_000
        XCTAssertEqual(TimeSpec.parseNanos("2026-10-30T01:30", now: now, timeZone: la), cutoff)
        XCTAssertNotEqual(TimeSpec.parseNanos("7d", now: now, timeZone: la), cutoff)
        let page = try Golden.record(MessagesPage.self, "read-12-since")
        XCTAssertFalse(page.messages.isEmpty)
        XCTAssertTrue(page.messages.allSatisfy { $0.dateNs >= cutoff })
        let all = try Golden.record(MessagesPage.self, "read-12")
        XCTAssertTrue(all.messages.contains { $0.dateNs < cutoff })
    }

    func testParseNanosUsesTheAppleEpoch() {
        XCTAssertEqual(TimeSpec.parseNanos("2026-11-06", now: now, timeZone: la),
                       (1_793_952_000 - 978_307_200) * 1_000_000_000)
        XCTAssertNil(TimeSpec.parseNanos("soon", now: now, timeZone: la))
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(TimeSpec.parseNanos("2001-01-01", now: now, timeZone: utc), 0)
    }
}
