import Foundation
import IMCore
@testable import IMPolicy
import IMTestSupport
import XCTest

/// Section 3 item 2: durable states, no message text, 7-day retention.
final class JournalTests: XCTestCase {
    private var dir: TempDir!
    private var clock: FakeClock!
    private var journal: Journal!
    private var t0: Date!

    override func setUp() {
        dir = TempDir()
        clock = FakeClock()
        journal = try! Journal(directory: journalDir, clock: clock)
        t0 = clock.now
    }

    override func tearDown() {
        journal = nil
        dir = nil
    }

    private var journalDir: URL { dir.url.appendingPathComponent("journal", isDirectory: true) }
    private var fileText: String { String(decoding: (try? Data(contentsOf: journal.fileURL)) ?? Data(), as: UTF8.self) }
    private var lines: [String] { fileText.split(separator: "\n").map(String.init) }

    private func reopen() throws -> Journal { try Journal(directory: journalDir, clock: clock) }

    /// Every binding and fact field set.
    private let binding = ApprovalBinding(chat: T.mom, action: .edit, textDigest: TextNorm.textDigest("new"),
                                          attachmentDigest: "attach", targetGUID: "TARGET", targetPart: 1,
                                          parentGUID: "PARENT", tapback: .laugh, remove: true, scope: .files)
    private let facts = InvocationFacts(snapshotRowID: 41_500, targetGUID: "TARGET", targetPart: 1,
                                        targetRowID: 41_418, transferNames: ["a1b2-photo.jpg"],
                                        dateEditedBeforeNs: 815_000_000_000_000_000)

    private func begin(_ key: IdempotencyKey = T.sendKey(), action: MutationKind = .send) throws -> JournalEntry {
        try journal.begin(key: key, action: action, chat: T.mom, binding: T.sendBinding(T.mom))
    }

    // MARK: States on disk

    func testEveryTransitionIsOneRecordOnDisk() throws {
        let entry = try begin()
        try journal.attachApproval(entry.id, approvalID: "a1b2c3d4")
        try journal.advance(entry.id, to: .approved)
        try journal.recorder(for: entry.id).willInvoke(facts)
        try journal.recorder(for: entry.id).didInvoke()
        try journal.finish(entry.id, result: ActionResult(.delivered), response: T.sendOutcome(ActionResult(.delivered)))

        let states = try lines.map { try JSONDecoder.wire.decode(JournalEntry.self, from: Data($0.utf8)).state }
        XCTAssertEqual(states, [.received, .received, .approved, .invoking, .invoked, .final])
    }

    func testWillInvokeIsOnDiskBeforeItReturns() throws {
        let entry = try begin()
        clock.advance(2)
        try journal.recorder(for: entry.id).willInvoke(facts)
        let last = try JSONDecoder.wire.decode(JournalEntry.self, from: Data(try XCTUnwrap(lines.last).utf8))
        XCTAssertEqual(last.state, .invoking)
        XCTAssertEqual(last.facts, facts)
        XCTAssertEqual(last.invokingAt, t0.addingTimeInterval(2))
        XCTAssertEqual(try reopen().entry(entry.id)?.state, .invoking)
    }

    func testWillInvokeThrowsAndRecordsNothingWhenTheWriteFails() throws {
        let entry = try begin()
        chmod(journal.fileURL.path, 0o400)
        defer { chmod(journal.fileURL.path, 0o600) }
        XCTAssertThrowsError(try journal.recorder(for: entry.id).willInvoke(facts))
        XCTAssertEqual(journal.entry(entry.id)?.state, .received)
        XCTAssertEqual(journal.lookup(T.sendKey(), again: false), .pending(approvalID: entry.id))
    }

    func testFailedFinalWriteStillFreesTheKeyAndTheNextPruneWritesIt() throws {
        let entry = try begin()
        let busy = ActionResult(.busy(.queue))
        chmod(journal.fileURL.path, 0o400)
        XCTAssertThrowsError(try journal.finish(entry.id, result: busy, response: .failure(WireError(result: busy))))
        chmod(journal.fileURL.path, 0o600)

        // Memory has the result, so a retry runs again instead of answering pending until a restart.
        XCTAssertEqual(journal.entry(entry.id)?.state, .final)
        XCTAssertEqual(journal.lookup(T.sendKey(), again: false), .fresh)
        XCTAssertThrowsError(try journal.advance(entry.id, to: .invoking)) {
            XCTAssertEqual($0 as? JournalError, .alreadyFinal(entry.id))
        }
        XCTAssertEqual(try reopen().entry(entry.id)?.state, .received)

        try journal.prune()
        let onDisk = try reopen().entry(entry.id)
        XCTAssertEqual(onDisk?.state, .final)
        XCTAssertEqual(onDisk?.result, busy)
    }

    func testEntriesSurviveAReopen() throws {
        let entry = try journal.begin(key: T.sendKey(), action: .edit, chat: T.mom, binding: binding)
        try journal.attachApproval(entry.id, approvalID: "a1b2c3d4")
        try journal.advance(entry.id, to: .approved)
        try journal.advance(entry.id, to: .invoking, facts: facts)
        try journal.markForeground(entry.id, true)
        let before = try XCTUnwrap(journal.entry(entry.id))
        XCTAssertEqual(try reopen().entry(entry.id), before)
    }

    func testBeginStoresTheBindingAndFactsForReconciling() throws {
        let entry = try journal.begin(key: T.sendKey(), action: .edit, chat: T.mom, binding: binding)
        XCTAssertEqual(entry.state, .received)
        XCTAssertEqual(entry.binding, binding)
        XCTAssertEqual(entry.receivedAt, t0)
        try journal.recorder(for: entry.id).willInvoke(facts)
        let stored = try XCTUnwrap(try reopen().entry(entry.id))
        XCTAssertEqual(stored.binding, binding)
        XCTAssertEqual(stored.facts, facts)
        XCTAssertEqual(stored.chat, T.mom)
        XCTAssertEqual(stored.action, .edit)
    }

    func testFileIsOwnerOnly() throws {
        _ = try begin()
        XCTAssertEqual(fileMode(journal.fileURL), 0o600)
        XCTAssertEqual(fileMode(journalDir), 0o700)
    }

    // MARK: No message text

    func testFinishStripsMessageText() throws {
        let attachment = AttachmentRecord(rowid: 9, guid: "ATT", kind: .voice, transferName: "voice.caf",
                                          transcript: "voice note secret")
        let send = SendOutcome(chat: ChatRef(rowid: 7, label: "Mom", isGroup: false), approved: true, early: nil,
                               text: "text body secret", threadParentRowID: nil,
                               parts: [SendPartOutcome(part: .text, result: ActionResult(.delivered), rowid: 501,
                                                       guid: "G-TEXT"),
                                       SendPartOutcome(part: .file, result: ActionResult(.delivered), rowid: 502,
                                                       guid: "G-FILE", attachment: attachment)],
                               replayed: false)
        let a = try begin()
        try journal.finish(a.id, result: ActionResult(.delivered), response: .send(send))
        let b = try begin(T.sendKey(text: "b"), action: .react)
        try journal.finish(b.id, result: ActionResult(.ok),
                           response: T.uiOutcome(ActionResult(.ok), quote: "quoted secret"))

        XCTAssertFalse(fileText.contains("secret"), fileText)
        XCTAssertFalse(fileText.contains("On my way"))
        guard case .send(let stored)? = journal.entry(a.id)?.response else { return XCTFail() }
        XCTAssertNil(stored.text)
        XCTAssertNil(stored.parts[1].attachment?.transcript)
        XCTAssertEqual(stored.parts.map(\.guid), ["G-TEXT", "G-FILE"])
        XCTAssertEqual(stored.parts[1].attachment?.transferName, "voice.caf")
    }

    func testOtherPayloadsAreStoredAsTheResultOnly() throws {
        let entry = try begin()
        let list = PendingList(items: [PendingItem(id: "x", summary: "send to Mom \"secret\"", createdAt: t0,
                                                   expiresAt: t0)])
        try journal.finish(entry.id, result: ActionResult(.denied(.user)), response: .pending(list))
        XCTAssertEqual(journal.entry(entry.id)?.response, .failure(WireError(result: ActionResult(.denied(.user)))))
        XCTAssertFalse(fileText.contains("secret"))
    }

    func testPolicyAndFailurePayloadsAreKept() throws {
        let policy = ResponsePayload.policy(PolicyOutcome(change: .allowChat, chat: nil, scope: .files,
                                                          result: ActionResult(.ok)))
        let a = try begin()
        try journal.finish(a.id, result: ActionResult(.ok), response: policy)
        XCTAssertEqual(journal.entry(a.id)?.response, policy)
        let failure = ResponsePayload.failure(.message("bad request"))
        let b = try begin(T.sendKey(text: "b"))
        try journal.finish(b.id, result: ActionResult(.error(.message("bad request"))), response: failure)
        XCTAssertEqual(journal.entry(b.id)?.response, failure)
    }

    func testBindingHoldsDigestsOnly() throws {
        _ = try journal.begin(key: T.sendKey(text: "private words"), action: .send, chat: T.mom,
                              binding: T.sendBinding(T.mom, text: "private words"))
        XCTAssertFalse(fileText.contains("private"))
        XCTAssertTrue(fileText.contains(TextNorm.textDigest("private words")))
    }

    // MARK: Transitions

    func testTransitionsOnlyMoveForward() throws {
        let entry = try begin()
        XCTAssertThrowsError(try journal.advance(entry.id, to: .invoked)) {
            XCTAssertEqual($0 as? JournalError, .invalidTransition(id: entry.id, from: .received, to: .invoked))
        }
        XCTAssertThrowsError(try journal.advance(entry.id, to: .final))
        XCTAssertThrowsError(try journal.advance(entry.id, to: .received))
        try journal.advance(entry.id, to: .approved)
        XCTAssertThrowsError(try journal.advance(entry.id, to: .approved))
        // An approved threaded reply asks again when the rate recheck under the queue finds a breach.
        try journal.attachApproval(entry.id, approvalID: "again")
        XCTAssertEqual(journal.entry(entry.id)?.approvalID, "again")
        XCTAssertEqual(journal.entry(entry.id)?.state, .approved)
        try journal.advance(entry.id, to: .invoking)
        XCTAssertThrowsError(try journal.attachApproval(entry.id, approvalID: "late"))
        XCTAssertThrowsError(try journal.advance(entry.id, to: .approved))
        XCTAssertThrowsError(try journal.advance(entry.id, to: .invoking))
        try journal.advance(entry.id, to: .invoked)
        XCTAssertThrowsError(try journal.advance(entry.id, to: .invoking))
        XCTAssertEqual(journal.entry(entry.id)?.state, .invoked)
    }

    func testReceivedCanGoStraightToInvoking() throws {
        let entry = try begin()
        try journal.advance(entry.id, to: .invoking)
        XCTAssertEqual(journal.entry(entry.id)?.state, .invoking)
    }

    func testFinalEntryRefusesEveryWrite() throws {
        let entry = try begin()
        try journal.finish(entry.id, result: ActionResult(.denied(.user)), response: T.sendOutcome(ActionResult(.denied(.user))))
        let final = JournalError.alreadyFinal(entry.id)
        XCTAssertThrowsError(try journal.advance(entry.id, to: .invoking)) { XCTAssertEqual($0 as? JournalError, final) }
        XCTAssertThrowsError(try journal.finish(entry.id, result: ActionResult(.ok), response: .failure(.message("x")))) {
            XCTAssertEqual($0 as? JournalError, final)
        }
        XCTAssertThrowsError(try journal.markForeground(entry.id, true)) { XCTAssertEqual($0 as? JournalError, final) }
        XCTAssertThrowsError(try journal.attachApproval(entry.id, approvalID: "x"))
        XCTAssertEqual(journal.entry(entry.id)?.result, ActionResult(.denied(.user)))
    }

    func testUnknownEntryThrows() {
        XCTAssertThrowsError(try journal.advance("missing", to: .invoking)) {
            XCTAssertEqual($0 as? JournalError, .unknownEntry("missing"))
        }
        XCTAssertThrowsError(try journal.finish("missing", result: ActionResult(.ok), response: .failure(.message("x"))))
        XCTAssertThrowsError(try journal.markForeground("missing", true))
        XCTAssertThrowsError(try journal.recorder(for: "missing").willInvoke(InvocationFacts()))
    }

    // MARK: Crash in the middle of an append

    func testPartialLastLineIsCutAtStart() throws {
        let entry = try begin()
        try journal.advance(entry.id, to: .approved)
        let intact = try Data(contentsOf: journal.fileURL)
        let handle = try FileHandle(forWritingTo: journal.fileURL)
        handle.seekToEndOfFile()
        handle.write(Data("{\"id\":\"\(entry.id)\",\"state\":\"invok".utf8))
        try handle.close()

        let reopened = try reopen()
        XCTAssertEqual(reopened.entry(entry.id)?.state, .approved)
        XCTAssertEqual(try Data(contentsOf: journal.fileURL), intact)
        try reopened.advance(entry.id, to: .invoking)
        XCTAssertEqual(try reopen().entry(entry.id)?.state, .invoking)
    }

    func testCorruptRecordBeforeTheLastLineRefusesToOpen() throws {
        _ = try begin()
        let handle = try FileHandle(forWritingTo: journal.fileURL)
        handle.seekToEndOfFile()
        handle.write(Data("not a record\n".utf8))
        try handle.close()
        _ = try begin(T.sendKey(text: "later"))
        XCTAssertThrowsError(try reopen()) { XCTAssertEqual($0 as? JournalError, .corruptRecord(line: 2)) }
    }

    func testJournalThatIsASymlinkRefusesToOpen() throws {
        _ = try begin()
        let real = dir.file("elsewhere.ndjson")
        try FileManager.default.moveItem(at: journal.fileURL, to: real)
        try FileManager.default.createSymbolicLink(at: journal.fileURL, withDestinationURL: real)
        XCTAssertThrowsError(try reopen())
    }

    func testLeftoverPruneFileIsRemovedAtStart() throws {
        _ = try begin()
        // The name `DurableFile.replace` gives its temp file, left by a prune that died before its rename.
        let leftover = journalDir.appendingPathComponent(".journal.ndjson.deadbeef.tmp")
        let unrelated = journalDir.appendingPathComponent("notes.tmp")
        try Data("partial".utf8).write(to: leftover)
        try Data("keep".utf8).write(to: unrelated)
        let reopened = try reopen()
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        XCTAssertEqual(reopened.allEntries().count, 1)
    }

    func testFailedAppendLeavesNoPartialRecord() throws {
        let entry = try begin()
        let intact = try Data(contentsOf: journal.fileURL)
        // A file size limit just past the current end makes the append write part of the record and then fail with
        // EFBIG, like a disk that fills up in the middle of a write.
        var old = rlimit()
        XCTAssertEqual(getrlimit(RLIMIT_FSIZE, &old), 0)
        var tight = old
        tight.rlim_cur = rlim_t(intact.count + 10)
        let oldHandler = signal(SIGXFSZ, SIG_IGN)
        XCTAssertEqual(setrlimit(RLIMIT_FSIZE, &tight), 0)
        let failed = Result { try journal.recorder(for: entry.id).willInvoke(facts) }
        setrlimit(RLIMIT_FSIZE, &old)
        signal(SIGXFSZ, oldHandler)

        guard case .failure(let error) = failed else { return XCTFail("the append should have failed") }
        XCTAssertEqual((error as? StorageError)?.code, EFBIG)
        XCTAssertEqual(try Data(contentsOf: journal.fileURL), intact)
        XCTAssertEqual(journal.entry(entry.id)?.state, .received)

        // The next append lands on a clean line, so the journal still opens.
        try journal.recorder(for: entry.id).willInvoke(facts)
        try journal.finish(entry.id, result: ActionResult(.delivered), response: T.sendOutcome(ActionResult(.delivered)))
        let reopened = try reopen()
        XCTAssertEqual(reopened.entry(entry.id)?.state, .final)
        XCTAssertEqual(lines.count, 3)
    }

    // MARK: Retention

    func testPruneKeepsFinalEntriesForExactlySevenDays() throws {
        let entry = try begin()
        try journal.finish(entry.id, result: ActionResult(.delivered), response: T.sendOutcome(ActionResult(.delivered)))
        clock.now = t0.addingTimeInterval(Limits.journalRetention)
        try journal.prune()
        XCTAssertNotNil(journal.entry(entry.id))
        clock.now = t0.addingTimeInterval(Limits.journalRetention + 0.001)
        try journal.prune()
        XCTAssertNil(journal.entry(entry.id))
        XCTAssertNil(try reopen().entry(entry.id))
    }

    func testPruneKeepsEntriesThatArentFinal() throws {
        let entry = try begin()
        clock.now = t0.addingTimeInterval(30 * 24 * 3600)
        try journal.prune()
        XCTAssertNotNil(try reopen().entry(entry.id))
    }

    func testPruneRewritesOneLinePerKeptEntry() throws {
        let old = try begin()
        try journal.finish(old.id, result: ActionResult(.delivered), response: T.sendOutcome(ActionResult(.delivered)))
        clock.now = t0.addingTimeInterval(Limits.journalRetention + 1)
        let kept = try begin(T.sendKey(text: "kept"))
        try journal.advance(kept.id, to: .approved)
        try journal.advance(kept.id, to: .invoking)
        XCTAssertEqual(lines.count, 5)
        try journal.prune()
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(fileMode(journal.fileURL), 0o600)
        let names = try FileManager.default.contentsOfDirectory(atPath: journalDir.path)
        XCTAssertEqual(names, ["journal.ndjson"])
        XCTAssertEqual(try reopen().entry(kept.id), journal.entry(kept.id))
    }

    // MARK: What IMBridge seeds from the journal

    func testSendEventsComeFromSendsThatReachedInvoking() throws {
        let sent = try begin()
        clock.advance(3)
        try journal.advance(sent.id, to: .invoking)
        try journal.finish(sent.id, result: ActionResult(.delivered),
                           response: T.sendOutcome(ActionResult(.delivered), guid: "ROW-GUID"))
        let neverRan = try begin(T.sendKey(text: "denied"))
        try journal.finish(neverRan.id, result: ActionResult(.denied(.user)),
                           response: T.sendOutcome(ActionResult(.denied(.user))))
        let tapback = try begin(T.sendKey(text: "tapback"), action: .react)
        try journal.advance(tapback.id, to: .invoking)

        let event = SendEvent(chat: T.mom, at: t0.addingTimeInterval(3), guid: "ROW-GUID",
                              textDigest: TextNorm.textDigest("On my way"))
        XCTAssertEqual(journal.sendEvent(for: sent.id), event)
        XCTAssertNil(journal.sendEvent(for: neverRan.id))
        XCTAssertNil(journal.sendEvent(for: tapback.id))
        XCTAssertEqual(try reopen().sendEvents(), [event])
    }

    func testAgentSentGUIDsListEveryPart() throws {
        let send = SendOutcome(chat: ChatRef(rowid: 7, label: "Mom", isGroup: false), approved: false, early: nil,
                               text: nil, threadParentRowID: nil,
                               parts: [SendPartOutcome(part: .text, result: ActionResult(.delivered), guid: "G-TEXT"),
                                       SendPartOutcome(part: .file, result: ActionResult(.delivered), guid: "G-FILE")],
                               replayed: false)
        let entry = try begin()
        try journal.advance(entry.id, to: .invoking)
        try journal.finish(entry.id, result: ActionResult(.delivered), response: .send(send))
        XCTAssertEqual(try reopen().agentSentGUIDs(), ["G-TEXT", "G-FILE"])
    }

    func testPendingIDFindsTheEntryByApprovalOrByItsOwnID() throws {
        let asked = try begin()
        try journal.attachApproval(asked.id, approvalID: "a1b2c3d4")
        let silent = try begin(T.sendKey(text: "silent"))
        XCTAssertEqual(journal.entry(pendingID: "a1b2c3d4")?.id, asked.id)
        XCTAssertEqual(journal.entry(pendingID: silent.id)?.id, silent.id)
        XCTAssertNil(journal.entry(pendingID: "unknown"))
    }

    // MARK: Thread safety

    func testConcurrentRequestsAreAllDurable() throws {
        let journal = try Journal(directory: journalDir, clock: SystemClock())
        let lock = NSLock()
        var errors: [Error] = []
        concurrently(32) { i in
            do {
                let key = T.sendKey(text: "message \(i)")
                let entry = try journal.begin(key: key, action: .send, chat: T.mom,
                                              binding: T.sendBinding(T.mom, text: "message \(i)"))
                try journal.recorder(for: entry.id).willInvoke(InvocationFacts(snapshotRowID: Int64(i)))
                try journal.recorder(for: entry.id).didInvoke()
                try journal.finish(entry.id, result: ActionResult(.delivered),
                                   response: T.sendOutcome(ActionResult(.delivered), guid: "G\(i)"))
            } catch {
                lock.lock(); errors.append(error); lock.unlock()
            }
        }
        XCTAssertTrue(errors.isEmpty, "\(errors)")
        let reopened = try reopen()
        XCTAssertEqual(reopened.allEntries().count, 32)
        XCTAssertTrue(reopened.allEntries().allSatisfy { $0.state == .final })
        XCTAssertEqual(reopened.agentSentGUIDs().count, 32)
        XCTAssertEqual(lines.count, 32 * 4)
    }
}
