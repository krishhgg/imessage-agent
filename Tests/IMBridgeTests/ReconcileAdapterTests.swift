import XCTest
@testable import IMBridge
import IMCore
import IMPolicy
import IMStore
import IMTestSupport

/// How crash recovery maps an `invoking` entry to a result from chat.db, one action at a time.
final class ReconcileAdapterTests: XCTestCase {
    private func entry(_ h: Harness, _ action: MutationKind, binding: ApprovalBinding,
                       facts: InvocationFacts?) -> JournalEntry {
        JournalEntry(id: "rc01", key: IdempotencyKey(value: "rc-key", targetSlot: nil), action: action,
                     chat: binding.chat, binding: binding, state: .invoking, receivedAt: h.clock.now,
                     updatedAt: h.clock.now, facts: facts)
    }

    /// One pass, with no time left to wait.
    private func reconcile(_ h: Harness, _ e: JournalEntry) -> ActionResult {
        ReconcileAdapter(container: h.container).reconcile(e, deadline: h.clock.uptime)
    }

    private func snapshot(_ h: Harness) throws -> Int64 { try h.copy.int("SELECT MAX(ROWID) FROM message") }

    func testAReactionIsOkOnlyWithItsOwnTapbackRowAboveTheSnapshot() throws {
        let h = try Harness()
        let mom = try h.mom()
        let target = try XCTUnwrap(try XCTUnwrap(h.container.db).messageTarget(rowid: UIPipelineTests.incoming))
        let above = try snapshot(h)
        let binding = ApprovalBinding(chat: mom.canonical, action: .react, targetGUID: target.guid, targetPart: 0,
                                      tapback: .heart)
        let e = entry(h, .react, binding: binding,
                      facts: InvocationFacts(snapshotRowID: above, targetGUID: target.guid, targetPart: 0))
        XCTAssertEqual(reconcile(h, e).code, .mayHaveCompleted)

        try h.copy.insertMessage(rowid: above + 1, guid: "RC-LIKE", text: nil, fromMe: true,
                                 date: AppleTime.nanos(from: h.clock.now), associatedType: 2001,
                                 associatedGUID: "p:0/\(target.guid)")
        XCTAssertEqual(reconcile(h, e).code, .mayHaveCompleted, "a different tapback proves nothing")

        try h.copy.insertMessage(rowid: above + 2, guid: "RC-HEART", text: nil, fromMe: true,
                                 date: AppleTime.nanos(from: h.clock.now), associatedType: 2000,
                                 associatedGUID: "p:0/\(target.guid)")
        XCTAssertEqual(reconcile(h, e).code, .ok)
    }

    func testAnUnsendIsOkOnceTheRowIsEmptied() throws {
        let h = try Harness()
        let mom = try h.mom()
        let rowid = try h.insertOwnMessage(62_100, text: "running late", age: 10)
        let binding = ApprovalBinding(chat: mom.canonical, action: .unsend, targetGUID: "OWN-62100", targetPart: 0)
        let e = entry(h, .unsend, binding: binding,
                      facts: InvocationFacts(targetGUID: "OWN-62100", targetPart: 0, targetRowID: rowid))
        XCTAssertEqual(reconcile(h, e).code, .mayHaveCompleted)
        try h.copy.exec("UPDATE message SET date_edited = \(AppleTime.nanos(from: h.clock.now)), text = NULL "
                        + "WHERE ROWID = \(rowid)")
        XCTAssertEqual(reconcile(h, e).code, .ok)
    }

    func testASendRowThatLandsWhileRecoveryWaitsIsFound() throws {
        let h = try Harness()
        let mom = try h.mom()
        let digest = TextNorm.textDigest("On my way")
        let above = try snapshot(h)
        let e = entry(h, .send, binding: ApprovalBinding(chat: mom.canonical, action: .send, textDigest: digest),
                      facts: InvocationFacts(snapshotRowID: above))
        let inserted = NSLock()
        var once = false
        h.clock.onSleep { [copy = h.copy] c in
            inserted.lock()
            defer { inserted.unlock() }
            guard !once else { return }
            once = true
            try? copy.insertMessage(rowid: above + 1, guid: "RC-LATE", text: "On my way", fromMe: true,
                                    date: AppleTime.nanos(from: c.now))
        }
        let start = h.clock.uptime
        let found = ReconcileAdapter(container: h.container).reconcileRows(e, deadline: start + Limits.reconcileTimeout)
        XCTAssertEqual(found.result.code, .delivered)
        XCTAssertEqual(found.sentGUIDs, ["RC-LATE"], "the matched row's GUID comes back for agentSentGUIDs")
        XCTAssertLessThan(h.clock.uptime - start, Limits.reconcileTimeout)
    }

    func testASendToAPhoneWithNoChatYetIsReconciledByItsHandle() throws {
        let h = try Harness()
        let digest = TextNorm.textDigest("Hi, this is Alex")
        let above = try snapshot(h)
        let e = entry(h, .send, binding: ApprovalBinding(chat: NewPhone.canonical, action: .send, textDigest: digest),
                      facts: InvocationFacts(snapshotRowID: above))
        XCTAssertEqual(reconcile(h, e).code, .mayHaveCompleted, "nothing was written yet")

        // The row is there and names the handle, but no chat holds it yet.
        try h.copy.exec("INSERT INTO handle (ROWID, id, service) VALUES (\(NewPhone.handleRowID), "
                        + "'\(NewPhone.handle)', 'iMessage')")
        try h.copy.insertMessage(rowid: above + 1, guid: "RC-NEW", chat: NewPhone.chatRowID,
                                 handle: NewPhone.handleRowID, text: "Hi, this is Alex", fromMe: true,
                                 date: AppleTime.nanos(from: h.clock.now))
        try h.copy.exec("DELETE FROM chat_message_join WHERE message_id = \(above + 1)")
        XCTAssertEqual(reconcile(h, e), ActionResult(.delivered, notes: [.chatUnconfirmed]))

        // Messages made the chat and joined the row to it.
        try h.copy.insertDirectChat(rowid: NewPhone.chatRowID, handleRowID: NewPhone.handleRowID,
                                    handle: NewPhone.handle, service: "iMessage")
        try h.copy.exec("INSERT INTO chat_message_join (chat_id, message_id, message_date) "
                        + "VALUES (\(NewPhone.chatRowID), \(above + 1), \(AppleTime.nanos(from: h.clock.now)))")
        XCTAssertEqual(reconcile(h, e), ActionResult(.delivered))
    }

    func testRecoveryStopsWaitingAtTheDeadline() throws {
        let h = try Harness()
        let mom = try h.mom()
        let e = entry(h, .send, binding: ApprovalBinding(chat: mom.canonical, action: .send,
                                                         textDigest: TextNorm.textDigest("never arrives")),
                      facts: InvocationFacts(snapshotRowID: try snapshot(h)))
        let start = h.clock.uptime
        let found = ReconcileAdapter(container: h.container).reconcileRows(e, deadline: start + Limits.reconcileTimeout)
        XCTAssertEqual(found.result.code, .mayHaveCompleted)
        XCTAssertTrue(found.sentGUIDs.isEmpty)
        XCTAssertEqual(h.clock.uptime - start, Limits.reconcileTimeout, accuracy: 0.001)
    }

    func testAnEntryMissingAFactItNeedsIsMayHaveCompleted() throws {
        let h = try Harness()
        let mom = try h.mom()
        let digest = TextNorm.textDigest("On my way")
        try h.copy.insertMessage(rowid: try snapshot(h) + 1, guid: "RC-SENT", text: "On my way", fromMe: true,
                                 date: AppleTime.nanos(from: h.clock.now))
        let send = ApprovalBinding(chat: mom.canonical, action: .send, textDigest: digest)
        XCTAssertEqual(reconcile(h, entry(h, .send, binding: send, facts: nil)).code, .mayHaveCompleted)
        XCTAssertEqual(reconcile(h, entry(h, .send, binding: send, facts: InvocationFacts())).code, .mayHaveCompleted,
                       "a send with no snapshot can't tell its row from an earlier one")
        let edit = ApprovalBinding(chat: mom.canonical, action: .edit, textDigest: digest)
        XCTAssertEqual(reconcile(h, entry(h, .edit, binding: edit, facts: InvocationFacts(targetRowID: 41_556))).code,
                       .mayHaveCompleted)
        let react = ApprovalBinding(chat: mom.canonical, action: .react, tapback: .heart)
        XCTAssertEqual(reconcile(h, entry(h, .react, binding: react, facts: InvocationFacts(snapshotRowID: 1))).code,
                       .mayHaveCompleted)
        let nochat = ApprovalBinding(chat: nil, action: .send, textDigest: digest)
        XCTAssertEqual(reconcile(h, entry(h, .send, binding: nochat, facts: InvocationFacts(snapshotRowID: 1))).code,
                       .mayHaveCompleted)
    }

    func testPolicyChangesAreNeverReconciled() throws {
        let h = try Harness()
        let mom = try h.mom()
        for action: MutationKind in [.allowChat, .revokeChat, .foregroundOn, .foregroundOff] {
            let binding = ApprovalBinding(chat: mom.canonical, action: action)
            XCTAssertEqual(reconcile(h, entry(h, action, binding: binding, facts: InvocationFacts())).code,
                           .mayHaveCompleted, "\(action)")
        }
    }

    func testAClosedStoreGivesMayHaveCompleted() throws {
        let missing = TempDir.make("imbridge-rc-nodb").appendingPathComponent("chat.db").path
        let h = try Harness(Harness.Options(injectStore: false, chatDBPath: missing))
        let binding = ApprovalBinding(chat: .direct(handle: "+15555550123"), action: .send,
                                      textDigest: TextNorm.textDigest("hi"))
        XCTAssertEqual(reconcile(h, entry(h, .send, binding: binding, facts: InvocationFacts(snapshotRowID: 1))).code,
                       .mayHaveCompleted)
    }

    func testCombinePutsUnknownThenFailedThenAmbiguousFirst() {
        let delivered = ActionResult(.delivered)
        let unknown = ActionResult(.mayHaveCompleted)
        let failed = ActionResult(.failed(.transferFailed))
        let ambiguous = ActionResult(.ambiguous(.twoRowsMatched))
        XCTAssertEqual(ReconcileAdapter.combine([]), unknown)
        XCTAssertEqual(ReconcileAdapter.combine([delivered, failed, unknown]), unknown)
        XCTAssertEqual(ReconcileAdapter.combine([delivered, ambiguous, failed]), failed)
        XCTAssertEqual(ReconcileAdapter.combine([delivered, ambiguous]), ambiguous)
        XCTAssertEqual(ReconcileAdapter.combine([ActionResult(.submitted), delivered]), ActionResult(.submitted))
    }
}
