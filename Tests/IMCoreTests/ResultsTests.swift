import XCTest
import IMCore

/// Section 3 item 1 and section 5: result strings, the idempotency rule and one-line rendering.
final class ResultsTests: XCTestCase {
    /// Every code with whether it holds the idempotency key on its own (no agent-text note).
    static let all: [(ResultCode, Bool)] = [
        (.submitted, true), (.delivered, true), (.failed(.rowError(22)), true), (.failed(.transferFailed), true),
        (.failed(.sentWithWrongParent("p:0/ABC")), true), (.failed(.sentWithWrongParent(nil)), true),
        (.ghost, true), (.ambiguous(.twoRowsMatched), true), (.mayHaveCompleted, true), (.ok, true),
        (.denied(.user), true),
        (.failed(.messagesNotReady), false), (.failed(.bridgeRestarted), false), (.ambiguous(.target), false),
        (.already, false), (.expired, false), (.denied(.approvalExpired), false), (.pending(id: "ab12"), false),
        (.busy(.queue), false), (.busy(.messagesOpen), false), (.busy(.draftInMessages), false),
        (.busy(.editInProgress), false), (.busy(.userActive), false), (.notLoaded, false), (.notDownloaded, false),
        (.unsupported, false), (.unsupportedTarget, false), (.untested, false), (.noHiddenWindow, false),
        (.aborted(.userTookOver), false), (.aborted(.parentChanged), false), (.aborted(.lateActivation), false),
        (.aborted(.activation), false), (.aborted(.deadline), false), (.aborted(.check("view")), false),
        (.timeout, false), (.error(.wrongChat), false), (.error(.severalMatches), false),
        (.error(.message("journal write failed")), false),
    ]

    static let notes: [ResultNote] = [
        .chatUnconfirmed, .messagesBecameVisible, .messagesLeftInEditMode, .messagesLeftOpen, .frontApp("Safari"),
        .userTookOver, .agentTextMayRemain, .axState("an edit field"), .mayHaveMarkedRead,
    ]

    func testHoldsIdempotencyKeyMatchesSection3Item1() {
        for (code, holds) in Self.all {
            XCTAssertEqual(ActionResult(code).holdsIdempotencyKey, holds, code.wire)
            // Any result that says the agent's text may still be in the field holds the key.
            XCTAssertTrue(ActionResult(code, notes: [.agentTextMayRemain]).holdsIdempotencyKey, code.wire)
            // Other notes never change the answer.
            XCTAssertEqual(ActionResult(code, notes: [.chatUnconfirmed, .messagesLeftOpen]).holdsIdempotencyKey,
                           holds, code.wire)
        }
    }

    func testWireStringsAreExactAndRoundTrip() {
        let expected: [String] = [
            "submitted", "delivered", "failed 22", "failed transfer_state 6", "failed: sent with wrong parent p:0/ABC",
            "failed: sent with wrong parent none", "ghost", "ambiguous: two rows matched", "may_have_completed", "ok",
            "denied", "failed: Messages not ready", "failed: bridge restarted", "ambiguous", "already", "expired",
            "denied: approval expired", "pending ab12", "busy: queue", "busy: Messages is open",
            "busy: draft in Messages", "busy: edit in progress", "busy: user active", "not_loaded", "not_downloaded",
            "unsupported", "unsupported_target", "untested", "no_hidden_window", "aborted: user took over",
            "aborted: parent changed", "aborted: late activation", "aborted: activation", "aborted: deadline",
            "aborted: view", "timeout", "error: wrong chat", "error: several matches", "error: journal write failed",
        ]
        XCTAssertEqual(Self.all.map { $0.0.wire }, expected)
        for (code, _) in Self.all { XCTAssertEqual(ResultCode(wire: code.wire), code, code.wire) }
        for note in Self.notes { XCTAssertEqual(ResultNote(wire: note.wire), note, note.wire) }
        XCTAssertNil(ResultCode(wire: "verified"))
        XCTAssertNil(ResultCode(wire: "delivered 12:41"))
    }

    func testRenderedJoinsNotesAndFixWithOneSpace() {
        XCTAssertEqual(ActionResult(.submitted, notes: [.chatUnconfirmed]).rendered, "submitted, chat unconfirmed")
        XCTAssertEqual(ActionResult.messagesOpen.rendered, "busy: Messages is open fix: hide Messages (⌘H) and retry")
        let r = ActionResult(.error(.message("no chat or contact matches \"zz\"")), fix: "imessage chats")
        XCTAssertEqual(r.rendered, "error: no chat or contact matches \"zz\" fix: imessage chats")
        XCTAssertFalse(r.rendered.contains(". fix:"))
        XCTAssertEqual(ActionResult(.ok, notes: [.frontApp("Safari"), .mayHaveMarkedRead]).rendered,
                       "ok, Safari in front, chat opened, may be marked read")
    }

    func testRenderedIsAlwaysOneLine() {
        let r = ActionResult(.error(.message("bad\nname\r\u{2028}x")), notes: [.axState("a\nb")], fix: "one\ntwo")
        let line = r.rendered
        XCTAssertFalse(line.unicodeScalars.contains(where: TextNorm.isLineBreak), line)
        XCTAssertEqual(line, "error: bad / name / x, AX shows a / b fix: one / two")
    }

    func testBuildPlanErrorLines() {
        XCTAssertEqual(ActionResult.journalWriteFailed.rendered,
                       "error: journal write failed fix: free disk space and retry")
        XCTAssertEqual(ActionResult.foregroundModeOff.rendered,
                       "error: foreground mode is off fix: imessage allow --foreground")
        XCTAssertEqual(ActionResult.threadWithFile.rendered,
                       "error: --thread can't be combined with --file fix: send the file and the reply separately")
        XCTAssertEqual(ActionResult.badRequest.rendered,
                       "error: bad request fix: retry, and run imessage doctor if it happens again")
        for r in [ActionResult.journalWriteFailed, .foregroundModeOff, .threadWithFile, .badRequest, .messagesOpen] {
            XCTAssertFalse(r.holdsIdempotencyKey, r.rendered)
        }
    }

    func testCodableUsesWireStrings() throws {
        let r = ActionResult(.failed(.rowError(25)), notes: [.chatUnconfirmed], fix: "f")
        let json = String(decoding: try JSONEncoder.wire.encode(r), as: UTF8.self)
        XCTAssertEqual(json, #"{"code":"failed 25","fix":"f","notes":["chat unconfirmed"]}"#)
        XCTAssertEqual(try JSONDecoder.wire.decode(ActionResult.self, from: Data(json.utf8)), r)
        XCTAssertThrowsError(try JSONDecoder.wire.decode(ActionResult.self, from: Data(#"{"code":"verified","notes":[]}"#.utf8)))
    }
}
