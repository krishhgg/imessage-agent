import Foundation
import XCTest
@testable import IMForeground
import IMCore
import IMSend
import IMStore
import IMTestSupport

/// Step 7 in the machine, and `LiveForegroundVerifier` against fake chat.db reads.
final class VerifyTests: XCTestCase {
    // MARK: - The machine

    func testEditVerifyGetsTheRowDateEditedBeforeTheTextDigestAndTenSeconds() {
        let h = Harness()
        h.runEdit("  see you at 6\n")
        XCTAssertEqual(h.verifier.editCalls, [
            FakeVerifier.EditCall(rowid: 410, before: 123, digest: TextNorm.textDigest("see you at 6"), timeout: 10),
        ])
        XCTAssertGreaterThan(h.log.index(of: .verify) ?? -1, h.log.index(of: .hide) ?? .max, "after step 6")
    }

    func testEditVerifyResultIsTheRunResult() {
        let h = Harness()
        h.verifier.editResult = ActionResult(.mayHaveCompleted)
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result, ActionResult(.mayHaveCompleted, notes: [.mayHaveMarkedRead]))
        XCTAssertTrue(h.mode.isForegroundModeOn)
    }

    func testReplyVerifyGetsTheStep1SnapshotTheChatTheDigestAndTheParent() {
        let h = Harness()
        var maxRowID: Int64 = 500
        h.rows.maxRowID = { maxRowID }
        h.log.onEvent = { event in if event == .activate { maxRowID = 900 } }
        let outcome = h.runReply()
        XCTAssertEqual(h.verifier.replyCalls, [
            FakeVerifier.ReplyCall(snapshot: SendSnapshot(maxRowID: 500, requestedAt: Fixture.now), chat: h.chat,
                                   digest: TextNorm.textDigest(Harness.replyText), parentGUID: "parent-guid",
                                   timeout: 10),
        ])
        XCTAssertEqual(outcome.sentGUID, "reply-row-guid")
        XCTAssertEqual(h.recorder.facts.first?.snapshotRowID, 500)
    }

    func testWrongOrMissingParentTurnsForegroundModeOff() {
        for shown in ["other-guid", nil] as [String?] {
            let h = Harness()
            let wrong = ActionResult(.failed(.sentWithWrongParent(shown)))
            h.verifier.reply = ReplyVerification(result: wrong, rowGUID: "reply-row-guid")
            let outcome = h.runReply()
            XCTAssertEqual(outcome.result.code, .failed(.sentWithWrongParent(shown)))
            XCTAssertTrue(outcome.turnedModeOff)
            XCTAssertEqual(h.mode.reasons, [wrong.code.wire])
            XCTAssertEqual(outcome.sentGUID, "reply-row-guid", "the row is still the agent's")
        }
    }

    func testReplyRowNotFoundLeavesModeOn() {
        let h = Harness()
        h.verifier.reply = ReplyVerification(result: ActionResult(.mayHaveCompleted), rowGUID: nil)
        let outcome = h.runReply()
        XCTAssertEqual(outcome.result.code, .mayHaveCompleted)
        XCTAssertFalse(outcome.turnedModeOff)
        XCTAssertNil(outcome.sentGUID)
    }

    // MARK: - LiveForegroundVerifier, edit

    private func liveVerifier(_ source: FakeSource, clock: FakeClock,
                              replies: ReplyCorrelating = ScriptedCorrelator()) -> LiveForegroundVerifier {
        LiveForegroundVerifier(source: source, correlator: SendCorrelator(rows: FakeRows(), clock: clock),
                               clock: clock, replies: replies)
    }

    private func editSource(clock: FakeClock, editedAt: TimeInterval, dateEditedNs: AppleNanos = 200,
                            body: String = "see you at 6") -> FakeSource {
        let source = FakeSource(newest: nil, edit: nil)
        source.edit = { rowid in
            if clock.uptime >= editedAt {
                return EditStateProbe(rowid: rowid, dateEditedNs: dateEditedNs, dateRetractedNs: 0, body: body)
            }
            return EditStateProbe(rowid: rowid, dateEditedNs: 100, dateRetractedNs: 0, body: "see you at 5")
        }
        return source
    }

    func testLiveEditIsOkOnceDateEditedIsLaterAndTheBodyMatches() {
        let clock = FakeClock()
        let verifier = liveVerifier(editSource(clock: clock, editedAt: 1001), clock: clock)
        let result = verifier.verifyEdit(rowid: 410, dateEditedBeforeNs: 100,
                                         newTextDigest: TextNorm.textDigest("see you at 6"), timeout: 10)
        XCTAssertEqual(result, ActionResult(.ok))
        XCTAssertEqual(clock.uptime, 1001)
    }

    func testLiveEditAtExactlyTenSecondsIsOkAndJustAfterIsMayHaveCompleted() {
        for (editedAt, expected) in [(1010.0, ResultCode.ok), (1010.25, .mayHaveCompleted)] {
            let clock = FakeClock()
            let verifier = liveVerifier(editSource(clock: clock, editedAt: editedAt), clock: clock)
            let result = verifier.verifyEdit(rowid: 410, dateEditedBeforeNs: 100,
                                             newTextDigest: TextNorm.textDigest("see you at 6"), timeout: 10)
            XCTAssertEqual(result.code, expected, "\(editedAt)")
            XCTAssertEqual(clock.uptime, 1010)
        }
    }

    func testLiveEditNeedsDateEditedStrictlyLater() {
        let clock = FakeClock()
        let source = editSource(clock: clock, editedAt: 0, dateEditedNs: 100)
        let result = liveVerifier(source, clock: clock)
            .verifyEdit(rowid: 410, dateEditedBeforeNs: 100, newTextDigest: TextNorm.textDigest("see you at 6"),
                        timeout: 10)
        XCTAssertEqual(result.code, .mayHaveCompleted)
    }

    func testLiveEditNeedsTheBodyDigest() {
        let clock = FakeClock()
        let source = editSource(clock: clock, editedAt: 0, body: "see you at 7")
        let result = liveVerifier(source, clock: clock)
            .verifyEdit(rowid: 410, dateEditedBeforeNs: 100, newTextDigest: TextNorm.textDigest("see you at 6"),
                        timeout: 10)
        XCTAssertEqual(result.code, .mayHaveCompleted)
    }

    func testLiveEditComparesAfterNFCAndTrimming() {
        let clock = FakeClock()
        let source = editSource(clock: clock, editedAt: 0, body: "Cafe\u{301}")
        let result = liveVerifier(source, clock: clock)
            .verifyEdit(rowid: 410, dateEditedBeforeNs: 100, newTextDigest: TextNorm.textDigest(" Caf\u{E9}\n"),
                        timeout: 10)
        XCTAssertEqual(result.code, .ok)
    }

    func testLiveEditReadErrorsCountAsNotYet() {
        let clock = FakeClock()
        let source = FakeSource(newest: nil, edit: nil)
        source.edit = { rowid in
            if clock.uptime < 1002 { throw FakeRows.Failure() }
            return EditStateProbe(rowid: rowid, dateEditedNs: 200, dateRetractedNs: 0, body: "see you at 6")
        }
        let result = liveVerifier(source, clock: clock)
            .verifyEdit(rowid: 410, dateEditedBeforeNs: 100, newTextDigest: TextNorm.textDigest("see you at 6"),
                        timeout: 10)
        XCTAssertEqual(result.code, .ok)
        XCTAssertEqual(clock.uptime, 1002)
    }

    func testLiveEditWithZeroTimeoutReadsOnce() {
        let clock = FakeClock()
        var reads = 0
        let source = FakeSource(newest: nil, edit: nil)
        source.edit = { _ in
            reads += 1
            return nil
        }
        let result = liveVerifier(source, clock: clock)
            .verifyEdit(rowid: 410, dateEditedBeforeNs: 100, newTextDigest: "d", timeout: 0)
        XCTAssertEqual(result.code, .mayHaveCompleted)
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(clock.uptime, 1000)
    }

    // MARK: - LiveForegroundVerifier, reply

    private func row(guid: String = "reply-row-guid", parent: String?) -> SentRowProbe {
        SentRowProbe(rowid: 501, guid: guid, handle: "+14155550111", service: "iMessage", dateNs: Fixture.nowNs,
                     body: "on my way", hasBody: true, transferNames: [], transferStates: [:], error: 0,
                     isSent: true, isDelivered: false, dateDeliveredNs: 0, joinedChatRowID: 7,
                     threadOriginatorGUID: parent, itemType: 0)
    }

    private func verifyReply(_ parts: [PartCorrelation]) -> (ReplyVerification, ScriptedCorrelator) {
        let clock = FakeClock()
        let correlator = ScriptedCorrelator()
        correlator.parts = parts
        let verifier = liveVerifier(FakeSource(newest: nil, edit: nil), clock: clock, replies: correlator)
        let chat = Harness().chat
        let checked = verifier.verifyReplyRow(snapshot: SendSnapshot(maxRowID: 500, requestedAt: Fixture.now),
                                              chat: chat, textDigest: "digest", parentGUID: "parent-guid",
                                              timeout: 10)
        return (checked, correlator)
    }

    func testLiveReplyCorrelatesOneTextDigestPartForTenSeconds() {
        let (_, correlator) = verifyReply([PartCorrelation(result: ActionResult(.submitted),
                                                           row: row(parent: "parent-guid"))])
        XCTAssertEqual(correlator.calls.count, 1)
        XCTAssertEqual(correlator.calls.first?.parts, [.textDigest("digest")])
        XCTAssertEqual(correlator.calls.first?.timeout, 10)
        XCTAssertEqual(correlator.calls.first?.snapshot.maxRowID, 500)
    }

    func testLiveReplyWithTheBoundParentKeepsTheCorrelationResult() {
        for code in [ResultCode.submitted, .delivered, .failed(.rowError(22)), .failed(.transferFailed)] {
            let result = ActionResult(code, notes: [.chatUnconfirmed])
            let (checked, _) = verifyReply([PartCorrelation(result: result, row: row(parent: "parent-guid"))])
            XCTAssertEqual(checked, ReplyVerification(result: result, rowGUID: "reply-row-guid"), "\(code)")
        }
    }

    func testLiveReplyWithAnotherParentIsSentWithWrongParent() {
        let (checked, _) = verifyReply([PartCorrelation(result: ActionResult(.delivered, notes: [.chatUnconfirmed]),
                                                        row: row(parent: "other-guid"))])
        XCTAssertEqual(checked.result, ActionResult(.failed(.sentWithWrongParent("other-guid")),
                                                    notes: [.chatUnconfirmed]))
        XCTAssertEqual(checked.rowGUID, "reply-row-guid")
    }

    func testLiveReplyWithNoParentIsSentWithWrongParentNone() {
        for parent in [nil, ""] as [String?] {
            let (checked, _) = verifyReply([PartCorrelation(result: ActionResult(.submitted),
                                                            row: row(parent: parent))])
            XCTAssertEqual(checked.result.code, .failed(.sentWithWrongParent(nil)), "\(String(describing: parent))")
            XCTAssertEqual(checked.result.code.wire, "failed: sent with wrong parent none")
        }
    }

    func testLiveReplyMatchWithoutARowIsMayHaveCompleted() {
        let (checked, _) = verifyReply([PartCorrelation(result: ActionResult(.submitted), row: nil)])
        XCTAssertEqual(checked, ReplyVerification(result: ActionResult(.mayHaveCompleted), rowGUID: nil))
    }

    func testLiveReplyWithNoPartsIsMayHaveCompleted() {
        let (checked, _) = verifyReply([])
        XCTAssertEqual(checked.result.code, .mayHaveCompleted)
    }

    func testLiveReplyPassesOtherResultsThroughWithNoRow() {
        for code in [ResultCode.mayHaveCompleted, .ghost, .ambiguous(.twoRowsMatched)] {
            let (checked, _) = verifyReply([PartCorrelation(result: ActionResult(code),
                                                            row: row(parent: "other-guid"))])
            XCTAssertEqual(checked, ReplyVerification(result: ActionResult(code), rowGUID: nil), "\(code)")
        }
    }

    func testVerifyReplyIsVerifyReplyRowWithoutTheGUID() {
        let clock = FakeClock()
        let correlator = ScriptedCorrelator()
        correlator.parts = [PartCorrelation(result: ActionResult(.submitted), row: row(parent: "other-guid"))]
        let verifier = liveVerifier(FakeSource(newest: nil, edit: nil), clock: clock, replies: correlator)
        let result = verifier.verifyReply(snapshot: SendSnapshot(maxRowID: 500, requestedAt: Fixture.now),
                                          chat: Harness().chat, textDigest: "digest", parentGUID: "parent-guid",
                                          timeout: 10)
        XCTAssertEqual(result.code, .failed(.sentWithWrongParent("other-guid")))
    }

    func testDefaultVerifyReplyRowWrapsVerifyReply() {
        let verifier = ReplyOnlyVerifier()
        let checked = verifier.verifyReplyRow(snapshot: SendSnapshot(maxRowID: 1, requestedAt: Fixture.now),
                                              chat: Harness().chat, textDigest: "d", parentGUID: "p", timeout: 10)
        XCTAssertEqual(checked, ReplyVerification(result: ActionResult(.delivered), rowGUID: nil))
    }
}

final class ScriptedCorrelator: ReplyCorrelating {
    struct Call {
        var snapshot: SendSnapshot
        var parts: [PartExpectation]
        var timeout: TimeInterval
    }

    var parts: [PartCorrelation] = []
    private(set) var calls: [Call] = []

    func correlate(snapshot: SendSnapshot, chat: ResolvedChat, parts expected: [PartExpectation],
                   timeout: TimeInterval) -> [PartCorrelation] {
        calls.append(Call(snapshot: snapshot, parts: expected, timeout: timeout))
        return parts
    }
}

/// A verifier that implements only the protocol's required methods.
final class ReplyOnlyVerifier: ForegroundVerifying {
    func verifyEdit(rowid: Int64, dateEditedBeforeNs: AppleNanos, newTextDigest: String,
                    timeout: TimeInterval) -> ActionResult { ActionResult(.ok) }

    func verifyReply(snapshot: SendSnapshot, chat: ResolvedChat, textDigest: String, parentGUID: String,
                     timeout: TimeInterval) -> ActionResult { ActionResult(.delivered) }
}
