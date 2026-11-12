import Foundation
import XCTest
import IMCore
import IMStore
@testable import IMSend
import IMTestSupport

final class CorrelationTests: XCTestCase {
    private var clock: FakeClock!
    private var rows: ScriptedRowSource!
    private var correlator: SendCorrelator!
    private var snapshot: SendSnapshot!
    private var start: TimeInterval = 0

    override func setUp() {
        super.setUp()
        clock = FakeClock()
        rows = ScriptedRowSource(clock: clock, maxRowID: 1000)
        correlator = SendCorrelator(rows: rows, clock: clock)
        snapshot = SendSnapshot(maxRowID: 1000, requestedAt: clock.now)
        start = clock.uptime
    }

    private var requested: Date { snapshot.requestedAt }
    private var elapsed: TimeInterval { clock.uptime - start }

    private func correlate(_ parts: [PartExpectation], chat: ResolvedChat = momChat()) -> [PartCorrelation] {
        correlator.correlate(snapshot: snapshot, chat: chat, parts: parts)
    }

    private func correlateText(_ text: String = "see you at 6", chat: ResolvedChat = momChat()) -> PartCorrelation {
        correlate([.text(matchKey: TextNorm.matchKey(text))], chat: chat)[0]
    }

    private func textRow(_ rowid: Int64 = 1001, body: String = "see you at 6", delivered: Bool = false,
                         joined: Int64? = 7, handle: String? = Handles.mom, service: String? = "iMessage",
                         error: Int = 0, offsetNs: Int64 = 1_000_000) -> SentRowProbe {
        row(rowid, after: requested, offsetNs: offsetNs, handle: handle, service: service, body: body, error: error,
            deliveredNs: delivered ? deliveredStamp(requested) : 0, joined: joined)
    }

    // MARK: Which rows count

    func testRowAtTheSnapshotIsIgnoredAndTheOneAboveMatches() {
        rows.ignoresAboveRowID = true
        rows.add(at: 0.5, textRow(999, delivered: true))
        rows.add(at: 0.5, textRow(1000, delivered: true))
        XCTAssertEqual(correlateText().result, ActionResult(.mayHaveCompleted))

        setUp()
        rows.add(at: 0.5, textRow(1001))
        XCTAssertEqual(correlateText().row?.rowid, 1001)
    }

    func testRowForAnotherHandleIsIgnored() {
        rows.add(at: 0.5, textRow(delivered: true, handle: Handles.dad))
        rows.add(at: 0.5, textRow(1002, delivered: true, handle: nil))
        XCTAssertEqual(correlateText().result, ActionResult(.mayHaveCompleted))
    }

    func testRowDatedBeforeTheRequestIsIgnoredAndOneDatedAtItCounts() {
        rows.add(at: 0.5, textRow(offsetNs: -1))
        XCTAssertEqual(correlateText().result, ActionResult(.mayHaveCompleted))

        setUp()
        rows.add(at: 0.5, textRow(offsetNs: 0))
        XCTAssertEqual(correlateText().row?.rowid, 1001)
    }

    func testHandlesAreComparedNormalized() {
        rows.add(at: 0.5, textRow(delivered: true, handle: "+1 (415) 555-0101"))
        XCTAssertEqual(correlateText().result.code, .delivered)

        setUp()
        let jordan = ResolvedChat(canonical: .direct(handle: Handles.jordan), chatRowIDs: [23], chatGUIDs: [],
                                  primaryChatRowID: 23, label: "Jordan", isGroup: false, handles: [Handles.jordan],
                                  sendHandle: Handles.jordan, service: "iMessage")
        rows.add(at: 0.5, row(1001, after: requested, handle: "Jordan.Kim@Example.com", body: "see you at 6",
                              deliveredNs: deliveredStamp(requested), joined: 23))
        XCTAssertEqual(correlateText(chat: jordan).result, ActionResult(.delivered))
    }

    func testSelfChatMatchesOnTheSendHandle() {
        rows.add(at: 0.5, row(1001, after: requested, handle: Handles.owner, body: "note to self",
                              deliveredNs: deliveredStamp(requested), joined: 2))
        XCTAssertEqual(correlateText("note to self", chat: selfChat()).result, ActionResult(.delivered))
    }

    /// Correlation compares handles through `HandleNormalizer.normalize`, so these are the keys it matches on.
    func testHandlesFollowHandleNormalizer() {
        XCTAssertEqual(HandleNormalizer.normalize("(415) 555-0101"), "+14155550101")
        XCTAssertEqual(HandleNormalizer.normalize("+44 20 7946 0958"), "+442079460958")
        XCTAssertEqual(HandleNormalizer.normalize(" Jordan.Kim@Example.COM "), "jordan.kim@example.com")
        XCTAssertEqual(HandleNormalizer.normalize("+14155550101"), "+14155550101")
        XCTAssertEqual(HandleNormalizer.normalize("urn:biz:5551234567"), "urn:biz:5551234567")
    }

    private func bizChat(_ handle: String = "urn:biz:5551234567") -> ResolvedChat {
        ResolvedChat(canonical: .direct(handle: handle), chatRowIDs: [7], chatGUIDs: [], primaryChatRowID: 7,
                     label: "Shop", isGroup: false, handles: [handle], sendHandle: handle, service: "iMessage")
    }

    func testLetterHandleNeverMatchesThePhoneNumberWithItsDigits() {
        rows.add(at: 0.5, textRow(delivered: true, handle: "+15551234567"))
        XCTAssertEqual(correlateText(chat: bizChat()).result, ActionResult(.mayHaveCompleted))

        setUp()
        rows.add(at: 0.5, textRow(delivered: true, handle: "urn:biz:5551234567"))
        var phone = momChat()
        phone.handles = ["+15551234567"]
        phone.sendHandle = "+15551234567"
        XCTAssertEqual(correlateText(chat: phone).result, ActionResult(.mayHaveCompleted))

        setUp()
        rows.add(at: 0.5, textRow(delivered: true, handle: " urn:biz:5551234567 "))
        XCTAssertEqual(correlateText(chat: bizChat()).result, ActionResult(.delivered))
    }

    // MARK: How parts match

    func testTextMatchesAfterNFCAndTrimming() {
        rows.add(at: 0.5, textRow(body: "Caf\u{E9} at 6", delivered: true))
        XCTAssertEqual(correlateText("  Cafe\u{301} at 6 \n").result, ActionResult(.delivered))
    }

    func testDifferentTextDoesNotMatch() {
        rows.add(at: 0.5, textRow(body: "see you at 7", delivered: true))
        XCTAssertEqual(correlateText("see you at 6").result, ActionResult(.mayHaveCompleted))
    }

    func testTextDigestMatches() {
        rows.add(at: 0.5, textRow(delivered: true))
        let result = correlate([.textDigest(TextNorm.textDigest(" see you at 6\n"))])[0]
        XCTAssertEqual(result.result, ActionResult(.delivered))
        XCTAssertEqual(result.row?.rowid, 1001)
    }

    func testFileMatchesOnTransferNameAndTextNeverMatchesAFileRow() {
        let name = "report-0123456789abcdef.pdf"
        rows.add(at: 0.5, row(1001, after: requested, transferNames: [name], transferStates: [name: 5],
                              deliveredNs: deliveredStamp(requested)))
        let results = correlate([.file(transferName: name), .text(matchKey: "see you at 6")])
        XCTAssertEqual(results[0].result, ActionResult(.delivered))
        XCTAssertEqual(results[0].row?.rowid, 1001)
        XCTAssertEqual(results[1].result, ActionResult(.mayHaveCompleted))
    }

    func testOtherTransferNameDoesNotMatch() {
        rows.add(at: 0.5, row(1001, after: requested, transferNames: ["report-ffffffffffffffff.pdf"],
                              deliveredNs: deliveredStamp(requested)))
        XCTAssertEqual(correlate([.file(transferName: "report-0123456789abcdef.pdf")])[0].result,
                       ActionResult(.mayHaveCompleted))
    }

    // MARK: Waiting

    func testDeliveredAndJoinedRowReturnsAsSoonAsItIsSeen() {
        rows.add(at: 0.5, textRow())
        rows.update(at: 2, rowid: 1001) { $0.dateDeliveredNs = deliveredStamp(self.requested) }
        let result = correlateText()
        XCTAssertEqual(result.result, ActionResult(.delivered))
        XCTAssertEqual(elapsed, 2, accuracy: 1e-9)
    }

    func testLaggingJoinRowIsAwaitedAfterDelivery() {
        rows.add(at: 0.5, textRow(joined: nil))
        rows.update(at: 1, rowid: 1001) { $0.dateDeliveredNs = deliveredStamp(self.requested) }
        rows.update(at: 1.75, rowid: 1001) { $0.joinedChatRowID = 7 }
        XCTAssertEqual(correlateText().result, ActionResult(.delivered))
        XCTAssertEqual(elapsed, 1.75, accuracy: 1e-9)
    }

    func testJoinRowAtTheEndOfTheGraceSecondConfirmsTheChat() {
        rows.add(at: 0.5, textRow(joined: nil))
        rows.update(at: 1, rowid: 1001) { $0.dateDeliveredNs = deliveredStamp(self.requested) }
        rows.update(at: 2, rowid: 1001) { $0.joinedChatRowID = 7 }
        XCTAssertEqual(correlateText().result, ActionResult(.delivered))
        XCTAssertEqual(elapsed, 2, accuracy: 1e-9)
    }

    func testJoinRowStillMissingAfterTheGraceSecondIsChatUnconfirmed() {
        rows.add(at: 0.5, textRow(joined: nil))
        rows.update(at: 1, rowid: 1001) { $0.dateDeliveredNs = deliveredStamp(self.requested) }
        rows.update(at: 2.1, rowid: 1001) { $0.joinedChatRowID = 7 }
        XCTAssertEqual(correlateText().result, ActionResult(.delivered, notes: [.chatUnconfirmed]))
        XCTAssertEqual(elapsed, 2, accuracy: 1e-9, "returns 1 s after delivery, not at 10 s")
    }

    func testGraceSecondEndsAtTheTenSecondBudget() {
        rows.add(at: 0.5, textRow(joined: nil))
        rows.update(at: 9.5, rowid: 1001) { $0.dateDeliveredNs = deliveredStamp(self.requested) }
        XCTAssertEqual(correlateText().result, ActionResult(.delivered, notes: [.chatUnconfirmed]))
        XCTAssertEqual(elapsed, Limits.correlationTimeout, accuracy: 1e-9)
    }

    func testRowThatIsNeitherDeliveredNorFailedIsSubmittedAtTenSeconds() {
        rows.add(at: 0.5, textRow())
        XCTAssertEqual(correlateText().result, ActionResult(.submitted))
        XCTAssertEqual(elapsed, 10, accuracy: 1e-9)
    }

    func testSubmittedWithoutAJoinRowIsChatUnconfirmed() {
        rows.add(at: 0.5, textRow(joined: nil))
        XCTAssertEqual(correlateText().result, ActionResult(.submitted, notes: [.chatUnconfirmed]))
    }

    func testDeliveryAtExactlyTenSecondsCounts() {
        rows.add(at: 0.5, textRow())
        rows.update(at: 10, rowid: 1001) { $0.dateDeliveredNs = deliveredStamp(self.requested) }
        XCTAssertEqual(correlateText().result, ActionResult(.delivered))
        XCTAssertEqual(elapsed, 10, accuracy: 1e-9)
    }

    func testLateDeliveryAfterTenSecondsLeavesItSubmitted() {
        rows.add(at: 0.5, textRow())
        rows.update(at: 10.1, rowid: 1001) { $0.dateDeliveredNs = deliveredStamp(self.requested) }
        XCTAssertEqual(correlateText().result, ActionResult(.submitted))
        XCTAssertEqual(elapsed, 10, accuracy: 1e-9)
    }

    func testRowAppearingAtTenSecondsIsSubmittedAndOneAfterIsMayHaveCompleted() {
        rows.add(at: 10, textRow())
        XCTAssertEqual(correlateText().result, ActionResult(.submitted))

        setUp()
        rows.add(at: 10.1, textRow())
        XCTAssertEqual(correlateText().result, ActionResult(.mayHaveCompleted))
        XCTAssertEqual(elapsed, 10, accuracy: 1e-9)
    }

    func testNoRowIsMayHaveCompletedAtTenSeconds() {
        let result = correlateText()
        XCTAssertEqual(result.result, ActionResult(.mayHaveCompleted))
        XCTAssertNil(result.row)
        XCTAssertEqual(elapsed, 10, accuracy: 1e-9)
        XCTAssertTrue(clock.sleeps.allSatisfy { $0 > 0 && $0 <= SendCorrelator.pollInterval + 1e-9 })
    }

    // MARK: Ghost, ambiguous and chat unconfirmed

    private func emptyRow(_ rowid: Int64, handle: String? = nil, service: String = "SMS",
                          joined: Int64? = nil) -> SentRowProbe {
        row(rowid, after: requested, handle: handle, service: service, body: "", joined: joined)
    }

    func testEmptyUnjoinedSMSRowIsGhost() {
        rows.add(at: 0.5, emptyRow(1001))
        let result = correlateText()
        XCTAssertEqual(result.result, ActionResult(.ghost))
        XCTAssertEqual(result.row?.rowid, 1001)
        XCTAssertEqual(elapsed, 10, accuracy: 1e-9, "a real row may still come, so ghost waits the full 10 s")
    }

    func testGhostRowMayCarryTheRecipientsHandle() {
        rows.add(at: 0.5, emptyRow(1001, handle: Handles.mom))
        XCTAssertEqual(correlateText().result, ActionResult(.ghost))
    }

    func testEmptyRowsThatArentGhosts() {
        for ghostless in [emptyRow(1001, joined: 7), emptyRow(1001, service: "iMessage"),
                          emptyRow(1001, handle: Handles.dad)] {
            setUp()
            rows.add(at: 0.5, ghostless)
            XCTAssertEqual(correlateText().result, ActionResult(.mayHaveCompleted), "\(ghostless)")
        }
        setUp()
        rows.add(at: 0.5, row(1001, after: requested, handle: nil, service: "SMS", body: "", hasBody: true,
                              joined: nil))
        XCTAssertEqual(correlateText().result, ActionResult(.mayHaveCompleted), "a row with a body isn't empty")

        setUp()
        var dated = emptyRow(1001)
        dated.dateNs = AppleTime.nanos(from: requested) - 1
        rows.add(at: 0.5, dated)
        XCTAssertEqual(correlateText().result, ActionResult(.mayHaveCompleted), "dated before the request")
    }

    func testMatchedRowWinsOverAGhost() {
        rows.add(at: 0.5, emptyRow(1001))
        rows.add(at: 0.5, textRow(1002, delivered: true))
        XCTAssertEqual(correlateText().row?.rowid, 1002)
    }

    func testTwoMatchingRowsAreAmbiguous() {
        rows.add(at: 0.5, textRow(1001))
        rows.add(at: 1.5, textRow(1002))
        let result = correlateText()
        XCTAssertEqual(result.result, ActionResult(.ambiguous(.twoRowsMatched)))
        XCTAssertEqual(result.result.rendered, "ambiguous: two rows matched")
        XCTAssertNil(result.row)
        XCTAssertEqual(elapsed, 1.5, accuracy: 1e-9)
    }

    func testTwoRowsWithTheSameTransferNameAreAmbiguous() {
        let name = "a-0000000000000000.txt"
        rows.add(at: 0.5, row(1001, after: requested, transferNames: [name]))
        rows.add(at: 0.5, row(1002, after: requested, transferNames: [name]))
        XCTAssertEqual(correlate([.file(transferName: name)])[0].result, ActionResult(.ambiguous(.twoRowsMatched)))
    }

    func testRowJoinedToAnotherChatIsNotOurs() {
        rows.add(at: 0.5, textRow(delivered: true, joined: 99))
        let result = correlateText()
        XCTAssertEqual(result.result, ActionResult(.mayHaveCompleted), "no row matched (section 3 item 5)")
        XCTAssertNil(result.row)
        XCTAssertEqual(elapsed, 10, accuracy: 1e-9, "it waits the full 10 s for a row of its own")

        setUp()
        rows.add(at: 0.5, textRow(1001, delivered: true, joined: 99))
        rows.add(at: 1, textRow(1002, delivered: true, joined: 7))
        let ours = correlateText()
        XCTAssertEqual(ours.result, ActionResult(.delivered), "the other chat's row doesn't make it ambiguous")
        XCTAssertEqual(ours.row?.rowid, 1002)

        setUp()
        rows.add(at: 0, textRow(1001, delivered: true, joined: 99))
        XCTAssertEqual(correlator.matchOnce(snapshot: snapshot, chat: momChat(),
                                            parts: [.textDigest(TextNorm.textDigest("see you at 6"))]).map(\.result),
                       [ActionResult(.mayHaveCompleted)], "reconciliation doesn't claim it either")
    }

    func testRowThatLaterJoinsAnotherChatDropsOut() {
        rows.add(at: 0.5, textRow(joined: nil))
        rows.update(at: 1, rowid: 1001) { $0.dateDeliveredNs = deliveredStamp(self.requested) }
        rows.update(at: 1.5, rowid: 1001) { $0.joinedChatRowID = 99 }
        XCTAssertEqual(correlateText().result, ActionResult(.mayHaveCompleted))
        XCTAssertEqual(elapsed, 10, accuracy: 1e-9)
    }

    func testChatWithNoChatsYetMatchesOnTheHandle() {
        var fresh = momChat()
        fresh.chatRowIDs = []
        fresh.chatGUIDs = []
        rows.add(at: 0.5, textRow(delivered: true, joined: 99))
        XCTAssertEqual(correlateText(chat: fresh).result, ActionResult(.delivered, notes: [.chatUnconfirmed]))
    }

    /// A new direct target's first send makes its chat, so the join row confirms by the chat's identity.
    func testChatWithNoChatsYetIsConfirmedByItsNewChatsIdentity() {
        var fresh = momChat()
        fresh.chatRowIDs = []
        fresh.chatGUIDs = []
        rows.setIdentity(94, fresh.canonical)
        rows.add(at: 0.5, textRow(joined: nil))
        rows.update(at: 0.75, rowid: 1001) { $0.dateDeliveredNs = deliveredStamp(self.requested) }
        rows.update(at: 1.25, rowid: 1001) { $0.joinedChatRowID = 94 }
        let result = correlateText(chat: fresh)
        XCTAssertEqual(result.result, ActionResult(.delivered))
        XCTAssertEqual(result.row?.rowid, 1001)
        XCTAssertEqual(elapsed, 1.25, accuracy: 1e-9, "it returns once the join row appears")
        XCTAssertEqual(correlator.matchOnce(snapshot: snapshot, chat: fresh,
                                            parts: [.textDigest(TextNorm.textDigest("see you at 6"))]).map(\.result),
                       [ActionResult(.delivered)])
    }

    func testChatWithNoChatsYetNeverClaimsAnotherConversationsRow() {
        var fresh = momChat()
        fresh.chatRowIDs = []
        fresh.chatGUIDs = []
        rows.setIdentity(94, fresh.canonical)
        rows.setIdentity(99, .group(identifier: "chat99"))
        rows.add(at: 0.5, textRow(1001, delivered: true, joined: 99))
        XCTAssertEqual(correlateText(chat: fresh).result, ActionResult(.mayHaveCompleted))

        setUp()
        rows.setIdentity(94, fresh.canonical)
        rows.setIdentity(99, .group(identifier: "chat99"))
        rows.add(at: 0.5, textRow(1001, delivered: true, joined: 99))
        rows.add(at: 1, textRow(1002, delivered: true, joined: 94))
        let ours = correlateText(chat: fresh)
        XCTAssertEqual(ours.result, ActionResult(.delivered), "the other conversation's row doesn't make it ambiguous")
        XCTAssertEqual(ours.row?.rowid, 1002)
    }

    // MARK: Failures and SMS

    func testNonzeroErrorIsFailedWithTheCode() {
        rows.add(at: 0.5, textRow())
        rows.update(at: 1.5, rowid: 1001) { $0.error = 25 }
        let result = correlateText().result
        XCTAssertEqual(result, ActionResult(.failed(.rowError(25))))
        XCTAssertEqual(result.rendered, "failed 25")
        XCTAssertEqual(elapsed, 1.5, accuracy: 1e-9)
    }

    func testTransferStateSixWithNoErrorIsFailedTransferState() {
        let name = "a-0000000000000000.txt"
        rows.add(at: 0.5, row(1001, after: requested, transferNames: [name], transferStates: [name: 1]))
        rows.update(at: 2, rowid: 1001) { $0.transferStates[name] = 6 }
        let result = correlate([.file(transferName: name)])[0].result
        XCTAssertEqual(result, ActionResult(.failed(.transferFailed)))
        XCTAssertEqual(result.rendered, "failed transfer_state 6")
        XCTAssertEqual(elapsed, 2, accuracy: 1e-9)
    }

    func testErrorCodeWinsOverTransferStateSix() {
        let name = "a-0000000000000000.txt"
        rows.add(at: 0.5, row(1001, after: requested, transferNames: [name], transferStates: [name: 6], error: 25))
        XCTAssertEqual(correlate([.file(transferName: name)])[0].result, ActionResult(.failed(.rowError(25))))
    }

    func testFailedRowStillWaitsForItsJoinRow() {
        rows.add(at: 0.5, textRow(joined: nil, error: 22))
        XCTAssertEqual(correlateText().result, ActionResult(.failed(.rowError(22)), notes: [.chatUnconfirmed]))
        XCTAssertEqual(elapsed, 1.5, accuracy: 1e-9)
    }

    func testSMSStaysSubmittedForTheFullTenSeconds() {
        rows.add(at: 0.5, textRow(delivered: true, service: "SMS"))
        XCTAssertEqual(correlateText(chat: momChat(service: "SMS")).result, ActionResult(.submitted))
        XCTAssertEqual(elapsed, 10, accuracy: 1e-9)
    }

    func testIMessageSentAsSMSStaysSubmitted() {
        rows.add(at: 0.5, textRow(delivered: true, service: "SMS"))
        XCTAssertEqual(correlateText(chat: momChat(service: "iMessage")).result, ActionResult(.submitted))
    }

    func testRowWithNoServiceUsesTheChatsService() {
        rows.add(at: 0.5, textRow(delivered: true, service: nil))
        XCTAssertEqual(correlateText(chat: momChat(service: "SMS")).result, ActionResult(.submitted))
    }

    func testSMSErrorIsFailed() {
        rows.add(at: 0.5, textRow(service: "SMS", error: 1))
        XCTAssertEqual(correlateText(chat: momChat(service: "SMS")).result, ActionResult(.failed(.rowError(1))))
    }

    // MARK: Separate parts

    func testTextAndFilePartsGetTheirOwnResults() {
        let name = "photo-0000000000000000.heic"
        rows.add(at: 0.5, textRow(delivered: true))
        rows.add(at: 0.75, row(1002, after: requested, transferNames: [name], transferStates: [name: 1]))
        rows.update(at: 3, rowid: 1002) { $0.transferStates[name] = 6 }
        let results = correlate([.text(matchKey: "see you at 6"), .file(transferName: name)])
        XCTAssertEqual(results.map(\.result), [ActionResult(.delivered), ActionResult(.failed(.transferFailed))])
        XCTAssertEqual(results.map { $0.row?.rowid }, [1001, 1002])
        XCTAssertEqual(elapsed, 3, accuracy: 1e-9)
    }

    func testOnePartFinishingDoesNotCutTheOtherShort() {
        let name = "photo-0000000000000000.heic"
        rows.add(at: 0.5, textRow(delivered: true))
        let results = correlate([.text(matchKey: "see you at 6"), .file(transferName: name)])
        XCTAssertEqual(results.map(\.result), [ActionResult(.delivered), ActionResult(.mayHaveCompleted)])
        XCTAssertEqual(elapsed, 10, accuracy: 1e-9)
    }

    func testNoPartsReturnsAtOnce() {
        XCTAssertEqual(correlate([]), [])
        XCTAssertEqual(elapsed, 0)
    }

    // MARK: chat.db reads

    func testReadFailuresAreRetried() {
        rows.failReadsUntil = 3
        rows.add(at: 0.5, textRow(delivered: true))
        XCTAssertEqual(correlateText().result, ActionResult(.delivered))
        XCTAssertEqual(elapsed, 3, accuracy: 1e-9)
    }

    func testChatDBThatNeverReadsIsMayHaveCompleted() {
        rows.failReadsUntil = .infinity
        rows.add(at: 0.5, textRow(delivered: true))
        XCTAssertEqual(correlateText().result, ActionResult(.mayHaveCompleted))
    }

    func testReadsPagePastOnePage() {
        for i in 0..<(SendCorrelator.pageSize + 20) {
            rows.add(at: 0, textRow(Int64(1001 + i), body: "other \(i)", delivered: true))
        }
        let target = Int64(1001 + SendCorrelator.pageSize + 20)
        rows.add(at: 0, textRow(target, delivered: true))
        XCTAssertEqual(correlateText().row?.rowid, target)
    }

    // MARK: matchOnce

    func testMatchOnceNeverWaits() {
        rows.add(at: 0, textRow(1001, body: "one", joined: nil))
        rows.add(at: 0, textRow(1002, body: "two", delivered: true))
        rows.add(at: 0, textRow(1003, body: "three", error: 25))
        let results = correlator.matchOnce(snapshot: snapshot, chat: momChat(), parts: [
            .textDigest(TextNorm.textDigest("one")), .textDigest(TextNorm.textDigest("two")),
            .textDigest(TextNorm.textDigest("three")), .textDigest(TextNorm.textDigest("four")),
        ])
        XCTAssertEqual(results.map(\.result), [ActionResult(.submitted, notes: [.chatUnconfirmed]),
                                               ActionResult(.delivered), ActionResult(.failed(.rowError(25))),
                                               ActionResult(.mayHaveCompleted)])
        XCTAssertTrue(clock.sleeps.isEmpty)
    }

    func testMatchOnceNeverReportsAGhost() {
        rows.add(at: 0, emptyRow(1001))
        rows.add(at: 0, emptyRow(1002, handle: Handles.mom))
        let results = correlator.matchOnce(snapshot: snapshot, chat: momChat(), parts: [
            .textDigest(TextNorm.textDigest("see you at 6")), .file(transferName: "a-0000000000000000.txt"),
        ])
        XCTAssertEqual(results.map(\.result), [ActionResult(.mayHaveCompleted), ActionResult(.mayHaveCompleted)])
        XCTAssertEqual(results.map(\.row), [nil, nil], "reconciliation names no row it didn't match")

        // The same rows still give ghost when a live send waits its 10 s.
        XCTAssertEqual(correlateText().result, ActionResult(.ghost))
    }

    func testMatchOnceWithUnreadableChatDBIsMayHaveCompleted() {
        rows.failReadsUntil = .infinity
        let results = correlator.matchOnce(snapshot: snapshot, chat: momChat(), parts: [.file(transferName: "x")])
        XCTAssertEqual(results.map(\.result), [ActionResult(.mayHaveCompleted)])
    }

    func testMatchOnceFromSeveralThreads() {
        let source = ScriptedRowSource(clock: FixedWallClock(), maxRowID: 1000)
        source.add(at: -1, textRow(1001, delivered: true))
        let shared = SendCorrelator(rows: source, clock: FixedWallClock())
        var results: [ActionResult] = []
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            let r = shared.matchOnce(snapshot: snapshot, chat: momChat(), parts: [.text(matchKey: "see you at 6")])
            lock.lock()
            results += r.map(\.result)
            lock.unlock()
        }
        XCTAssertEqual(results.count, 64)
        XCTAssertTrue(results.allSatisfy { $0 == ActionResult(.delivered) })
    }
}
