import XCTest
@testable import IMBridge
import IMCore
import IMPolicy
import IMSend
import IMStore
import IMTestSupport

/// A bridge that stopped mid-request, then started again over the same journal, policy file and chat.db.
final class RecoveryTests: XCTestCase {
    /// A second bridge over the first one's home folder, chat.db copy, clock and Keychain.
    private func restart(_ first: Harness, _ options: Harness.Options = Harness.Options()) throws -> Harness {
        var o = options
        o.home = first.home
        o.copy = first.copy
        return try Harness(o, clock: first.clock, keychain: first.keychain)
    }

    private func claim(_ h: Harness, _ action: MutationKind, text: String, parentGUID: String? = nil) throws
        -> JournalEntry {
        let mom = try h.mom()
        let digest = TextNorm.textDigest(text)
        let key = IdempotencyKey.send(chat: mom.canonical, threaded: action == .threadedReply, parentGUID: parentGUID,
                                      textDigest: digest, attachmentDigest: nil)
        let binding = ApprovalBinding(chat: mom.canonical, action: action, textDigest: digest, parentGUID: parentGUID)
        guard case .run(let entry) = try h.journal.claim(key: key, again: false, action: action, chat: mom.canonical,
                                                         binding: binding) else {
            throw XCTSkip("claim found an entry")
        }
        return entry
    }

    func testAnInvokingSendIsReconciledSoARepeatReplays() throws {
        let first = try Harness()
        try first.allowMom()
        let entry = try claim(first, .send, text: "On my way")
        let snapshot = try first.copy.int("SELECT MAX(ROWID) FROM message")
        try first.journal.advance(entry.id, to: .invoking, facts: InvocationFacts(snapshotRowID: snapshot))
        // Messages sent it, then the bridge stopped before `final`.
        try first.copy.insertMessage(rowid: 63_000, guid: "CRASH-SENT", text: "On my way", fromMe: true,
                                     date: AppleTime.nanos(from: first.clock.now))

        let second = try restart(first)
        XCTAssertFalse(BridgeMain.prepare(second.container))
        let recovered = try XCTUnwrap(second.journal.entry(entry.id))
        XCTAssertEqual(recovered.state, .final)
        XCTAssertEqual(recovered.result?.code, .delivered)
        XCTAssertEqual(recovered.sentGUIDs, ["CRASH-SENT"])
        XCTAssertTrue(try XCTUnwrap(second.container.db).agentSentGUIDs.contains("CRASH-SENT"),
                      "wait never reports the reconciled send")
        XCTAssertEqual(second.journal.sendEvent(for: entry.id)?.guid, "CRASH-SENT")

        let repeated = try XCTUnwrap(second.send("On my way").sendOutcome)
        XCTAssertTrue(repeated.replayed)
        XCTAssertEqual(repeated.early?.code, .delivered)
        XCTAssertTrue(second.scripts.calls.isEmpty, "a reconciled send never goes out twice")
        XCTAssertFalse(second.policy.effective.foregroundOffReason != nil)
        XCTAssertNil(second.container.crashNote)
    }

    func testAnInvokingSendWithNoRowIsMayHaveCompletedAndHoldsTheKey() throws {
        let first = try Harness()
        try first.allowMom()
        let entry = try claim(first, .send, text: "lost")
        try first.journal.advance(entry.id, to: .invoking,
                                  facts: InvocationFacts(snapshotRowID: try first.copy.int("SELECT MAX(ROWID) FROM message")))
        let second = try restart(first)
        BridgeMain.prepare(second.container)
        XCTAssertEqual(second.journal.entry(entry.id)?.result?.code, .mayHaveCompleted)
        XCTAssertEqual(second.send("lost").headline, .mayHaveCompleted)
        XCTAssertTrue(second.scripts.calls.isEmpty)
        XCTAssertEqual(second.send("lost", again: true).sendOutcome?.replayed, false)
    }

    func testARequestThatNeverInvokedFailsAndFreesTheKey() throws {
        let first = try Harness()
        try first.allowMom()
        let entry = try claim(first, .send, text: "never sent")
        let second = try restart(first)
        XCTAssertFalse(BridgeMain.prepare(second.container))
        XCTAssertEqual(second.journal.entry(entry.id)?.result?.code, .failed(.bridgeRestarted))
        let retry = try XCTUnwrap(second.send("never sent").sendOutcome)
        XCTAssertFalse(retry.replayed)
        XCTAssertEqual(retry.parts.map(\.result.code), [.delivered])
    }

    func testAForegroundCrashTurnsForegroundModeOffWithANote() throws {
        let first = try Harness(Harness.Options(foreground: true))
        try first.policy.setForegroundMode(true)
        let entry = try claim(first, .threadedReply, text: "Yes!", parentGUID: "PARENT")
        try first.journal.markForeground(entry.id, true)

        let second = try restart(first, Harness.Options(foreground: true))
        XCTAssertTrue(BridgeMain.prepare(second.container))
        XCTAssertFalse(second.policy.isForegroundModeOn)
        XCTAssertEqual(second.policy.effective.foregroundOffReason, BridgeMain.crashReason)
        XCTAssertEqual(second.container.crashNote, BridgeMain.crashNote)
        let recovered = try XCTUnwrap(second.journal.entry(entry.id))
        XCTAssertEqual(recovered.result?.code, .failed(.bridgeRestarted))
        XCTAssertFalse(recovered.foreground)

        guard case .status(let status) = second.call(.status) else { return XCTFail("status") }
        XCTAssertEqual(status.crashNote, BridgeMain.crashNote)
        XCTAssertFalse(status.foregroundMode)
        XCTAssertEqual(status.foregroundOffReason, BridgeMain.crashReason)

        guard case .doctor(let report) = second.call(.doctor(DoctorArgs())) else { return XCTFail("doctor") }
        let lastRun = try XCTUnwrap(report.checks.first { $0.name == "last run" })
        XCTAssertFalse(lastRun.ok)
        XCTAssertEqual(lastRun.detail, BridgeMain.crashNote)
        let mode = try XCTUnwrap(report.checks.first { $0.name == "foreground mode" })
        XCTAssertEqual(mode.detail, "off: \(BridgeMain.crashReason)")
        XCTAssertEqual(mode.fix, "imessage allow --foreground")

        XCTAssertEqual(second.send("Yes!", thread: true).failure?.result, .foregroundModeOff)
    }

    func testAJournalThatCantBeRecoveredTurnsForegroundModeOff() throws {
        let first = try Harness()
        try first.policy.setForegroundMode(true)
        _ = try claim(first, .send, text: "stuck")
        let second = try restart(first)
        let file = second.journal.fileURL.path
        XCTAssertEqual(chmod(file, 0o400), 0)
        defer { chmod(file, 0o600) }
        XCTAssertTrue(BridgeMain.prepare(second.container))
        XCTAssertFalse(second.policy.isForegroundModeOn)
        XCTAssertEqual(second.policy.effective.foregroundOffReason, BridgeMain.recoveryFailedReason)
    }

    func testMutationsAreRefusedUntilCrashRecoveryCanWriteTheJournal() throws {
        let first = try Harness()
        try first.allowMom()
        let stuck = try claim(first, .send, text: "stuck")
        let second = try restart(first)
        let file = second.journal.fileURL.path
        let dir = second.journal.fileURL.deletingLastPathComponent().path
        // A read-only file and folder, so neither an append nor the prune's rename can write.
        XCTAssertEqual(chmod(file, 0o400), 0)
        XCTAssertEqual(chmod(dir, 0o500), 0)
        defer {
            chmod(dir, 0o700)
            chmod(file, 0o600)
        }
        XCTAssertTrue(BridgeMain.prepare(second.container))
        XCTAssertTrue(second.container.journalNeedsRecovery)

        XCTAssertEqual(second.send("On my way").sendOutcome?.early, .journalWriteFailed)
        XCTAssertEqual(second.send("stuck").sendOutcome?.early, .journalWriteFailed,
                       "a key whose entry is still open neither runs nor replays")
        XCTAssertEqual(second.call(.revoke(RevokeArgs(who: Mom.who))).policyOutcome?.result, .journalWriteFailed)
        XCTAssertTrue(second.scripts.calls.isEmpty)
        XCTAssertTrue(second.presenter.prompts.isEmpty)
        XCTAssertEqual(second.journal.entry(stuck.id)?.state, .received)
        XCTAssertNotNil(second.policy.entry(for: try second.mom().canonical))

        XCTAssertEqual(chmod(dir, 0o700), 0)
        XCTAssertEqual(chmod(file, 0o600), 0)
        let sent = try XCTUnwrap(second.send("On my way").sendOutcome)
        XCTAssertEqual(sent.parts.map(\.result.code), [.delivered])
        XCTAssertFalse(second.container.journalNeedsRecovery)
        XCTAssertEqual(second.journal.entry(stuck.id)?.result?.code, .failed(.bridgeRestarted))
        XCTAssertEqual(second.scripts.sentTexts, ["On my way"])
    }

    func testRestartSeedsAgentGUIDsAndRateLimitHistoryFromTheJournal() throws {
        let first = try Harness()
        try first.allowMom()
        let sent = try XCTUnwrap(first.send("hello").sendOutcome)
        let guid = try XCTUnwrap(sent.parts.first?.guid)

        let second = try restart(first, Harness.Options(injectStore: false))
        XCTAssertEqual(second.container.engine.limiter.history.map(\.guid), [guid])
        BridgeMain.prepare(second.container)
        XCTAssertTrue(try XCTUnwrap(second.container.db).agentSentGUIDs.contains(guid))

        first.clock.advance(5)
        let next = try XCTUnwrap(second.send("again soon").sendOutcome)
        XCTAssertTrue(next.approved)
        XCTAssertEqual(second.presenter.prompts.first?.reason, RateLimitBreach.perChatInterval.dialogReason)
    }

    func testPendingAfterARestartAnswersFromTheJournalWithoutText() throws {
        let first = try Harness()
        let sent = try XCTUnwrap(first.send("Dinner at 7?").sendOutcome)
        XCTAssertTrue(sent.approved)
        let id = try XCTUnwrap(first.presenter.prompts.first?.id)
        XCTAssertEqual(first.call(.pending(PendingArgs(id: id))).sendOutcome?.text, "Dinner at 7?")

        let second = try restart(first)
        BridgeMain.prepare(second.container)
        let answer = try XCTUnwrap(second.call(.pending(PendingArgs(id: id))).sendOutcome)
        XCTAssertNil(answer.text)
        XCTAssertEqual(answer.parts.map(\.result.code), [.delivered])
    }

    func testPrepareClearsLeftoverUploads() throws {
        let first = try Harness()
        let dir = first.container.uploads.directory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: dir.appendingPathComponent("left-over"))
        let second = try restart(first)
        BridgeMain.prepare(second.container)
        XCTAssertTrue(second.uploadFiles.isEmpty)
    }
}

/// The bridge's timers and the small objects around them.
final class MaintenanceTests: XCTestCase {
    func testJobsRunOnTheirSchedule() throws {
        let h = try Harness()
        let m = Maintenance(container: h.container)
        XCTAssertEqual(m.runDue(uptime: 0), [.expireApprovals, .sweepStaging, .purgeCache, .pruneJournal])
        XCTAssertEqual(m.runDue(uptime: Maintenance.tick), [.expireApprovals])
        XCTAssertEqual(m.runDue(uptime: Maintenance.stagingInterval - 0.1), [.expireApprovals])
        XCTAssertEqual(m.runDue(uptime: Maintenance.stagingInterval), [.expireApprovals, .sweepStaging])
        XCTAssertEqual(m.runDue(uptime: Maintenance.hourlyInterval - 0.1), [.expireApprovals, .sweepStaging])
        XCTAssertEqual(m.runDue(uptime: Maintenance.hourlyInterval), [.expireApprovals, .purgeCache, .pruneJournal])
    }

    func testTheTickWithdrawsExpiredDialogsAndDropsOldAnswers() throws {
        let h = try Harness(Harness.Options(plan: .hold))
        let first = try XCTUnwrap(h.send("hello?", approvalWait: 0).sendOutcome)
        guard case .pending(let id)? = first.early?.code else { return XCTFail("pending") }
        let m = Maintenance(container: h.container)
        h.clock.advance(Limits.approvalExpiry)
        m.runDue(uptime: h.clock.uptime)
        XCTAssertTrue(h.presenter.withdrawn.contains(id))
        h.waitUntilIdle()
        XCTAssertEqual(h.container.inFlight.count, 1)
        XCTAssertEqual(h.call(.pending(PendingArgs(id: id))).sendOutcome?.early?.code, .denied(.approvalExpired))

        h.clock.advance(InFlightRegistry.retention)
        m.runDue(uptime: h.clock.uptime)
        XCTAssertEqual(h.container.inFlight.count, 0)
        XCTAssertEqual(h.call(.pending(PendingArgs(id: id))).sendOutcome?.early?.code, .denied(.approvalExpired),
                       "the journal still answers once the in-memory copy is gone")
    }

    func testClearUploadsRemovesOnlyRegularFiles() throws {
        let h = try Harness()
        let dir = h.container.uploads.directory
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("folder"), withIntermediateDirectories: true)
        try Data("a".utf8).write(to: dir.appendingPathComponent("upload-1"))
        try Data("b".utf8).write(to: dir.appendingPathComponent("folder/inside"))
        let outside = TempDir.make("imbridge-outside").appendingPathComponent("keep")
        try Data("c".utf8).write(to: outside)
        try fm.createSymbolicLink(at: dir.appendingPathComponent("link"), withDestinationURL: outside)

        Maintenance.clearUploads(h.container)
        XCTAssertEqual(Set(h.uploadFiles), ["folder", "link"])
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent("folder/inside").path))
        XCTAssertTrue(fm.fileExists(atPath: outside.path))
    }

    func testInFlightAnswersKeepTheirFinalAndDropAfterRetention() {
        let registry = InFlightRegistry()
        let now = Fixture.now
        let pending = ResponsePayload.failure(WireError(result: ActionResult(.pending(id: "ab12"))))
        let done = ResponsePayload.failure(WireError(result: ActionResult(.ok)))
        registry.alias("ab12", to: "entry")
        registry.setPending("entry", pending)
        XCTAssertEqual(registry.pendingPayload("entry"), pending)
        XCTAssertEqual(registry.entryID(forApproval: "ab12"), "entry")
        registry.finish("entry", done, at: now)
        registry.setPending("entry", pending)
        XCTAssertNil(registry.pendingPayload("entry"), "a late pending never hides the final answer")
        XCTAssertEqual(registry.finalPayload("entry"), done)

        registry.prune(now: now.addingTimeInterval(InFlightRegistry.retention - 1))
        XCTAssertEqual(registry.count, 1)
        registry.prune(now: now.addingTimeInterval(InFlightRegistry.retention))
        XCTAssertEqual(registry.count, 0)
        XCTAssertNil(registry.entryID(forApproval: "ab12"))
    }

    func testResidencyCountsHoldsAndNeverGoesNegative() {
        let lock = NSLock()
        var log: [String] = []
        let guardian = ResidencyGuard(onFirstEnter: { lock.lock(); log.append("hold"); lock.unlock() },
                                      onLastLeave: { lock.lock(); log.append("release"); lock.unlock() })
        guardian.leave()
        XCTAssertEqual(guardian.holds, 0)
        DispatchQueue.concurrentPerform(iterations: 50) { _ in guardian.enter() }
        XCTAssertEqual(guardian.holds, 50)
        DispatchQueue.concurrentPerform(iterations: 50) { _ in guardian.leave() }
        XCTAssertEqual(guardian.holds, 0)
        XCTAssertEqual(log, ["hold", "release"])
    }

    func testTheRateLimiterReadsFailClosedUntilTheStoreOpens() throws {
        let source = DeferredActivitySource()
        let h = try Harness()
        XCTAssertThrowsError(try source.inboundRows(in: try h.mom(), afterNs: 0, limit: 1)) { error in
            XCTAssertEqual(error as? StoreError, .notPermitted)
        }
        source.container = h.container
        XCTAssertNoThrow(try source.inboundRows(in: try h.mom(), afterNs: 0, limit: 1))
    }

    func testTheRateLimiterGetsTheUsersOwnAddressesFromTheStore() throws {
        let source = DeferredActivitySource()
        XCTAssertEqual(source.ownAddresses(), [], "no store, no self-chat")
        let h = try Harness()
        source.container = h.container
        XCTAssertEqual(source.ownAddresses(), Set(Fixture.ownerHandles))
        XCTAssertEqual(h.container.engine.limiter.ownAddresses(), Set(Fixture.ownerHandles))
    }
}
