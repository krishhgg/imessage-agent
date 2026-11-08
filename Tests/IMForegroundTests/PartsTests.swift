import Foundation
import XCTest
@testable import IMForeground
import IMCore
import IMStore
import IMTestSupport
import IMUI

/// The parent-bubble matcher, the key codes and the result helpers.
final class PartsTests: XCTestCase {
    private let la = Fixture.timeZone

    func testMinuteLabelParsing() {
        let cases: [(String, Int?, Int?)] = [
            ("9:05\u{202F}AM", 9, 5),
            ("9:05 PM", 21, 5),
            ("12:00\u{00A0}AM", 0, 0),
            ("12:30 PM", 12, 30),
            ("Sam, Are you close?, 4:07 p.m.", 16, 7),
            ("16:07", 16, 7),
            ("0:59", 0, 59),
            ("Yesterday", nil, nil),
            ("13:00 PM", nil, nil),
            ("0:30 AM", nil, nil),
            ("24:00", nil, nil),
            ("9:60", nil, nil),
            ("9:05 AM, 10:06 AM", nil, nil),
            ("123:45", nil, nil),
        ]
        for (label, hour, minute) in cases {
            let parsed = ParentBubbleMatch.hourAndMinute(in: label)
            XCTAssertEqual(parsed?.hour, hour, label)
            XCTAssertEqual(parsed?.minute, minute, label)
        }
    }

    func testParentMatchUsesTheMinuteInTheGivenTimeZone() {
        let h = Harness()
        // Los Angeles and Kolkata are 13.5 hours apart, so the same row shows a different minute.
        var parent = h.parent
        parent.dateNs = Fixture.nowNs - 120_000_000_000
        let bubble = BubbleInfo(ref: AXRef(id: 1), fromMe: false, text: parent.body,
                                minuteLabel: Harness.minuteLabel(parent.dateNs, timeZone: la), hasTextBubble: true,
                                actionNames: [])
        XCTAssertTrue(ParentBubbleMatch.matches(bubble, parent: parent, timeZone: la))
        XCTAssertFalse(ParentBubbleMatch.matches(bubble, parent: parent,
                                                 timeZone: TimeZone(identifier: "Asia/Kolkata")!))
    }

    func testParentMatchIgnoresSecondsInsideTheMinute() {
        let h = Harness()
        var parent = h.parent
        let label = Harness.minuteLabel(parent.dateNs, timeZone: la)
        let bubble = BubbleInfo(ref: AXRef(id: 1), fromMe: false, text: parent.body, minuteLabel: label,
                                hasTextBubble: true, actionNames: [])
        let seconds = Int64(AppleTime.date(fromNanos: parent.dateNs).timeIntervalSince1970) % 60
        parent.dateNs += (59 - seconds) * 1_000_000_000
        XCTAssertTrue(ParentBubbleMatch.matches(bubble, parent: parent, timeZone: la))
        parent.dateNs += 1_000_000_000
        XCTAssertFalse(ParentBubbleMatch.matches(bubble, parent: parent, timeZone: la))
    }

    func testParentMatchChecksDirectionAndNFCBody() {
        let h = Harness()
        let parent = h.parent
        let bubble = BubbleInfo(ref: AXRef(id: 1), fromMe: false, text: parent.body,
                                minuteLabel: Harness.minuteLabel(parent.dateNs, timeZone: la), hasTextBubble: true,
                                actionNames: [])
        XCTAssertTrue(ParentBubbleMatch.matches(bubble, parent: parent, timeZone: la))
        var mine = bubble
        mine.fromMe = true
        XCTAssertFalse(ParentBubbleMatch.matches(mine, parent: parent, timeZone: la))
        var longer = bubble
        longer.text += "!"
        XCTAssertFalse(ParentBubbleMatch.matches(longer, parent: parent, timeZone: la))
    }

    func testParentMatchTrimsWhitespaceAtTheEndsOfBothBodies() {
        let h = Harness()
        var parent = h.parent
        parent.body = "Are you close?\n "
        var bubble = BubbleInfo(ref: AXRef(id: 1), fromMe: false, text: "Are you close?",
                                minuteLabel: Harness.minuteLabel(parent.dateNs, timeZone: la), hasTextBubble: true,
                                actionNames: [])
        XCTAssertTrue(ParentBubbleMatch.matches(bubble, parent: parent, timeZone: la))
        bubble.text = " Are you close?"
        XCTAssertTrue(ParentBubbleMatch.matches(bubble, parent: parent, timeZone: la))
        bubble.text = "Are you  close?"
        XCTAssertFalse(ParentBubbleMatch.matches(bubble, parent: parent, timeZone: la), "inner spaces still count")
    }

    func testKeyCodesAreReturnAndEscape() {
        XCTAssertEqual(PidKeyPoster.virtualKey(for: .returnKey), 36)
        XCTAssertEqual(PidKeyPoster.virtualKey(for: .escape), 53)
    }

    func testCheckNamesRenderAsAbortedLines() {
        XCTAssertEqual(ActionResult.abortedCheck(ForegroundCheck.press).rendered, "aborted: press")
        XCTAssertEqual(ActionResult.abortedCheck(ForegroundCheck.view).rendered, "aborted: view")
        XCTAssertEqual(ActionResult.abortedCheck(ForegroundCheck.field).rendered, "aborted: field")
        XCTAssertEqual(ForegroundResults.foregroundModeOff.rendered,
                       "error: foreground mode is off fix: imessage allow --foreground")
        XCTAssertEqual(ForegroundResults.journalWriteFailed.rendered,
                       "error: journal write failed fix: free disk space and retry")
    }

    func testPollIntervalsAddUpExactlyAtWindowEdges() {
        var sum = 0.0
        for _ in 0..<(64 * 3) { sum += ForegroundTiming.poll }
        XCTAssertEqual(sum, Limits.returnDeadline)
        var verify = 0.0
        for _ in 0..<40 { verify += ForegroundTiming.verifyPoll }
        XCTAssertEqual(verify, Limits.foregroundVerifyTimeout)
    }
}
