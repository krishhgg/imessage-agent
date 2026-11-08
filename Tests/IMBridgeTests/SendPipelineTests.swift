import XCTest
@testable import IMBridge
import IMCore
import IMPolicy
import IMSend
import IMStore
import IMTestSupport
import IMUI

/// `send` through policy, approval, journal, queue and IMSend.
final class SendPipelineTests: XCTestCase {
    // MARK: - Allowed chats and approvals

    func testAnAllowedChatSendsWithoutADialog() throws {
        let h = try Harness()
        try h.allowMom()
        let events = EventLog()
        let outcome = try XCTUnwrap(h.send("On my way", events: events).sendOutcome)
        XCTAssertNil(outcome.early)
        XCTAssertFalse(outcome.approved)
        XCTAssertEqual(outcome.text, "On my way")
        XCTAssertEqual(outcome.parts.map(\.result.code), [.delivered])
        XCTAssertEqual(h.scripts.sentTexts, ["On my way"])
        XCTAssertTrue(h.presenter.prompts.isEmpty)
        XCTAssertTrue(events.events.isEmpty)

        let entry = try h.onlyEntry()
        XCTAssertEqual(entry.state, .final)
        XCTAssertNotNil(entry.invokingAt)
        XCTAssertFalse(entry.foreground)
        guard case .send(let stored)? = entry.response else { return XCTFail("stored response") }
        XCTAssertNil(stored.text, "the journal keeps no message text")
        let guid = try XCTUnwrap(outcome.parts.first?.guid)
        XCTAssertTrue(try XCTUnwrap(h.container.db).agentSentGUIDs.contains(guid))
        XCTAssertEqual(h.container.engine.limiter.history.map(\.guid), [guid])
        XCTAssertEqual(h.queue.acquisitions, 1)
        XCTAssertFalse(h.queue.isHeld)
    }

    func testAllowOnceSendsAndLeavesTheChatOffTheList() throws {
        let h = try Harness()
        let events = EventLog()
        let outcome = try XCTUnwrap(h.send("Dinner at 7?", events: events).sendOutcome)
        XCTAssertTrue(outcome.approved)
        XCTAssertEqual(outcome.parts.map(\.result.code), [.delivered])
        let prompt = try XCTUnwrap(h.presenter.prompts.first)
        XCTAssertEqual(h.presenter.prompts.count, 1)
        XCTAssertEqual(events.events, [.approvalShown(id: prompt.id)])
        XCTAssertEqual(prompt.text, "Dinner at 7?")
        XCTAssertEqual(prompt.reason, "this chat isn't allowed yet")
        XCTAssertTrue(prompt.offersAlwaysAllow)
        XCTAssertEqual(ApprovalPanelModel(prompt: prompt).lines.first,
                       .init(label: "Chat", value: "Mom, +14155550101 on iMessage"),
                       "the dialog names the handle and service the send uses")
        XCTAssertEqual(h.scripts.calls.first?.1, ["+14155550101", "Dinner at 7?", "iMessage"])
        XCTAssertNil(h.policy.entry(for: try h.mom().canonical))
        let entry = try h.onlyEntry()
        XCTAssertEqual(entry.approvalID, prompt.id)
        XCTAssertEqual(entry.state, .final)
    }

    /// Fixture chat 31 is Sam Lee's RCS chat. `send_text` gets the chat's service and uses the iMessage account for
    /// any service but SMS (BUILD-PLAN 16), so the dialog names iMessage.
    func testAnRCSChatsDialogNamesTheAccountTheSendGoesOn() throws {
        let h = try Harness()
        XCTAssertEqual(try XCTUnwrap(h.container.db).resolve("31").service, "RCS")
        _ = h.send("probe text", to: "31")
        let prompt = try XCTUnwrap(h.presenter.prompts.first)
        XCTAssertEqual(ApprovalPanelModel(prompt: prompt).lines.first,
                       .init(label: "Chat", value: "Sam Lee, +16505550142 on iMessage"))
        XCTAssertEqual(h.scripts.calls.first?.1, ["+16505550142", "probe text", "RCS"])
    }

    func testAlwaysAllowAddsTheChatSoTheNextSendSkipsTheDialog() throws {
        let h = try Harness(Harness.Options(plan: .decide(.alwaysAllow, after: 1.5)))
        XCTAssertEqual(h.send("first").sendOutcome?.approved, true)
        XCTAssertEqual(h.policy.entry(for: try h.mom().canonical)?.scope, .text)
        h.clock.advance(Limits.minSecondsBetweenSendsPerChat + 1)
        let second = try XCTUnwrap(h.send("second").sendOutcome)
        XCTAssertFalse(second.approved)
        XCTAssertEqual(second.parts.map(\.result.code), [.delivered])
        XCTAssertEqual(h.presenter.prompts.count, 1)
    }

    func testDenyHoldsTheKeyUntilAgain() throws {
        let h = try Harness(Harness.Options(plan: .decide(.deny, after: 1.5)))
        let first = try XCTUnwrap(h.send("Call me").sendOutcome)
        XCTAssertEqual(first.early?.code, .denied(.user))
        XCTAssertFalse(first.replayed)

        let repeated = try XCTUnwrap(h.send("Call me").sendOutcome)
        XCTAssertEqual(repeated.early?.code, .denied(.user))
        XCTAssertTrue(repeated.replayed)
        XCTAssertEqual(repeated.text, "Call me")
        XCTAssertEqual(h.presenter.prompts.count, 1, "a held deny never shows a second dialog")

        h.presenter.queue(.decide(.allowOnce, after: 1.5))
        let again = try XCTUnwrap(h.send("Call me", again: true).sendOutcome)
        XCTAssertTrue(again.approved)
        XCTAssertEqual(h.presenter.prompts.count, 2)
        XCTAssertEqual(h.scripts.sentTexts, ["Call me"])
    }

    func testAnAllowBeforeTheButtonsEnableCountsAsDeny() throws {
        let h = try Harness(Harness.Options(plan: .decide(.allowOnce, after: Limits.approvalButtonDelay / 2)))
        XCTAssertEqual(h.send("too fast").headline, .denied(.user))
        XCTAssertTrue(h.scripts.calls.isEmpty)
    }

    func testAnExpiredApprovalIsDeniedAndFreesTheKey() throws {
        let h = try Harness(Harness.Options(plan: .hold))
        h.jumpOnNextSleep(Limits.approvalExpiry)
        let first = try XCTUnwrap(h.send("Still there?").sendOutcome)
        XCTAssertEqual(first.early?.code, .denied(.approvalExpired))
        let id = try XCTUnwrap(h.presenter.prompts.first?.id)
        XCTAssertTrue(h.presenter.withdrawn.contains(id))
        XCTAssertTrue(h.scripts.calls.isEmpty)
        XCTAssertEqual(try h.onlyEntry().result?.code, .denied(.approvalExpired))

        h.presenter.queue(.decide(.allowOnce, after: 1.5))
        let retry = try XCTUnwrap(h.send("Still there?").sendOutcome)
        XCTAssertFalse(retry.replayed)
        XCTAssertTrue(retry.approved)
        XCTAssertEqual(h.presenter.prompts.count, 2)
    }

    func testAnAllowArrivingAfterExpiryRunsNothing() throws {
        let h = try Harness(Harness.Options(plan: .hold))
        let first = try XCTUnwrap(h.send("late", approvalWait: 0).sendOutcome)
        guard case .pending(let id)? = first.early?.code else { return XCTFail("pending") }
        h.clock.advance(Limits.approvalExpiry)
        h.presenter.decide(id, .allowOnce)
        h.waitUntilIdle()
        XCTAssertTrue(h.scripts.calls.isEmpty)
        XCTAssertEqual(try h.onlyEntry().result?.code, .denied(.approvalExpired))
    }

    // MARK: - Idempotency

    func testARepeatReplaysAndAgainSendsOnceMore() throws {
        let h = try Harness()
        try h.allowMom()
        let first = try XCTUnwrap(h.send("See you at 6").sendOutcome)
        XCTAssertEqual(first.parts.map(\.result.code), [.delivered])

        let repeated = try XCTUnwrap(h.send("See you at 6").sendOutcome)
        XCTAssertTrue(repeated.replayed)
        XCTAssertEqual(repeated.text, "See you at 6", "the replay puts the text back")
        XCTAssertEqual(repeated.parts.map(\.guid), first.parts.map(\.guid))
        XCTAssertEqual(h.scripts.sentTexts.count, 1)
        XCTAssertEqual(h.journal.allEntries().count, 1)

        h.clock.advance(Limits.minSecondsBetweenSendsPerChat + 1)
        let again = try XCTUnwrap(h.send("See you at 6", again: true).sendOutcome)
        XCTAssertFalse(again.replayed)
        XCTAssertNotEqual(again.parts.first?.guid, first.parts.first?.guid)
        XCTAssertEqual(h.scripts.sentTexts, ["See you at 6", "See you at 6"])
    }

    func testAgainWhileTheSameSendIsInvokingAnswersMayHaveCompletedAndSendsNothing() throws {
        let h = try Harness()
        try h.allowMom()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        h.scripts.onCall = { handler in
            guard handler == .sendText else { return }
            entered.signal()
            release.wait()
        }
        let lock = NSLock()
        var first: SendOutcome?
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let outcome = h.send("See you at 6").sendOutcome
            lock.lock(); first = outcome; lock.unlock()
            done.signal()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 10), .success, "the first send reaches its Apple Event")
        h.scripts.onCall = nil
        XCTAssertEqual(h.journal.allEntries().map(\.state), [.invoking])

        let again = try XCTUnwrap(h.send("See you at 6", again: true).sendOutcome)
        XCTAssertEqual(again.early?.code, .mayHaveCompleted)
        XCTAssertTrue(again.replayed)
        XCTAssertTrue(again.parts.isEmpty)
        XCTAssertEqual(h.scripts.sentTexts, ["See you at 6"], "--again sent nothing")
        XCTAssertEqual(h.journal.allEntries().count, 1, "--again journaled nothing")
        XCTAssertEqual(h.queue.acquisitions, 1, "--again never queued")

        release.signal()
        XCTAssertEqual(done.wait(timeout: .now() + 30), .success)
        lock.lock(); let finished = first; lock.unlock()
        XCTAssertEqual(finished?.parts.map(\.result.code), [.delivered])
        XCTAssertEqual(h.scripts.sentTexts.count, 1)
    }

    func testTheKeyIsReleasedAfterTheIdempotencyWindow() throws {
        let h = try Harness()
        try h.allowMom()
        XCTAssertEqual(h.send("ping").headline, .delivered)
        h.clock.advance(Limits.idempotencyWindow)
        let later = try XCTUnwrap(h.send("ping").sendOutcome)
        XCTAssertFalse(later.replayed)
        XCTAssertEqual(h.scripts.sentTexts.count, 2)
    }

    func testConcurrentRequestsWithOneKeyShowOneDialog() throws {
        let h = try Harness(Harness.Options(plan: .hold))
        let n = 8
        let lock = NSLock()
        var answers: [SendOutcome] = []
        DispatchQueue.concurrentPerform(iterations: n) { _ in
            let outcome = h.send("Be there soon", approvalWait: 0).sendOutcome
            lock.lock()
            if let outcome { answers.append(outcome) }
            lock.unlock()
        }
        XCTAssertEqual(answers.count, n)
        XCTAssertEqual(h.presenter.prompts.count, 1)
        let entry = try h.onlyEntry()
        for answer in answers {
            guard case .pending(let id)? = answer.early?.code else { return XCTFail("\(answer)") }
            XCTAssertTrue(id == entry.approvalID || id == entry.id, id)
        }
        XCTAssertEqual(answers.filter(\.replayed).count, n - 1)
        h.presenter.decide(try XCTUnwrap(h.presenter.prompts.first?.id), .deny)
        h.waitUntilIdle()
        XCTAssertTrue(h.scripts.calls.isEmpty)
    }

    // MARK: - Pending in the background

    func testAPendingRequestFinishesInTheBackgroundAndPendingCollectsIt() throws {
        let h = try Harness(Harness.Options(plan: .hold))
        let first = try XCTUnwrap(h.send("Running late", approvalWait: 0).sendOutcome)
        guard case .pending(let id)? = first.early?.code else { return XCTFail("pending") }
        XCTAssertEqual(h.container.residency.holds, 1, "an open approval keeps the bridge resident")

        XCTAssertEqual(h.call(.pending(PendingArgs(id: id))).sendOutcome?.early?.code, .pending(id: id))
        guard case .pending(let list) = h.call(.pending(PendingArgs())) else { return XCTFail("list") }
        XCTAssertEqual(list.items.map(\.id), [id])
        let repeated = try XCTUnwrap(h.send("Running late").sendOutcome)
        XCTAssertEqual(repeated.early?.code, .pending(id: id))
        XCTAssertTrue(repeated.replayed)
        XCTAssertTrue(h.scripts.calls.isEmpty)

        h.clock.advance(Limits.approvalButtonDelay + 1)
        h.presenter.decide(id, .allowOnce)
        h.waitUntilIdle()
        let done = try XCTUnwrap(h.call(.pending(PendingArgs(id: id))).sendOutcome)
        XCTAssertTrue(done.approved)
        XCTAssertEqual(done.text, "Running late")
        XCTAssertEqual(done.parts.map(\.result.code), [.delivered])
        XCTAssertEqual(h.scripts.sentTexts, ["Running late"])
        guard case .pending(let after) = h.call(.pending(PendingArgs())) else { return XCTFail("list") }
        XCTAssertTrue(after.items.isEmpty)
        XCTAssertTrue(try XCTUnwrap(h.send("Running late").sendOutcome).replayed)
    }

    func testAnUndecidedDialogAnswersPendingWhenTheWaitRunsOut() throws {
        let h = try Harness(Harness.Options(plan: .hold))
        let start = h.clock.uptime
        let first = try XCTUnwrap(h.send("Are you up?", approvalWait: Limits.approvalWait).sendOutcome)
        guard case .pending(let id)? = first.early?.code else { return XCTFail("pending") }
        let waited = h.clock.uptime - start
        XCTAssertGreaterThanOrEqual(waited, Limits.approvalWait)
        XCTAssertLessThan(waited, Limits.approvalWait + 1)
        XCTAssertEqual(try h.onlyEntry().state, .received, "nothing runs while the dialog is open")
        XCTAssertTrue(h.scripts.calls.isEmpty)
        h.presenter.decide(id, .deny)
        h.waitUntilIdle()
        XCTAssertEqual(try h.onlyEntry().result?.code, .denied(.user))
    }

    func testPendingWithAnUnknownIDIsAnError() throws {
        let h = try Harness()
        let error = try XCTUnwrap(h.call(.pending(PendingArgs(id: "zzzz"))).failure)
        XCTAssertEqual(error.result.code, .error(.message("no request zzzz")))
        XCTAssertEqual(error.result.fix, "imessage pending lists open approvals")
    }

    func testTheApprovalWaitIsClamped() {
        XCTAssertEqual(MutationPipeline.clampWait(-5), 0)
        XCTAssertEqual(MutationPipeline.clampWait(Limits.approvalExpiry + 1), Limits.approvalExpiry)
        XCTAssertEqual(MutationPipeline.clampWait(.nan), Limits.approvalWait)
        XCTAssertEqual(MutationPipeline.clampWait(.infinity), Limits.approvalWait)
        XCTAssertEqual(MutationPipeline.clampWait(42), 42)
    }

    // MARK: - Rate limits

    func testASecondSendWithinTwentySecondsAsksWithTheBreach() throws {
        let h = try Harness()
        try h.allowMom()
        XCTAssertEqual(h.send("one").headline, .delivered)
        h.clock.advance(Limits.minSecondsBetweenSendsPerChat - 1)
        let second = try XCTUnwrap(h.send("two").sendOutcome)
        XCTAssertTrue(second.approved)
        let prompt = try XCTUnwrap(h.presenter.prompts.first)
        XCTAssertEqual(prompt.reason, RateLimitBreach.perChatInterval.dialogReason)
        XCTAssertFalse(prompt.offersAlwaysAllow, "Always allow wouldn't lift a rate limit")

        let last = try XCTUnwrap(h.container.engine.limiter.history.last?.at)
        h.clock.advance(Limits.minSecondsBetweenSendsPerChat - h.clock.now.timeIntervalSince(last) + 0.01)
        let third = try XCTUnwrap(h.send("three").sendOutcome)
        XCTAssertFalse(third.approved, "past 20 seconds the allowed chat sends without a dialog")
        XCTAssertEqual(h.presenter.prompts.count, 1)

        h.clock.advance(Limits.minSecondsBetweenSendsPerChat + 1)
        XCTAssertTrue(try XCTUnwrap(h.send("four").sendOutcome).approved)
        XCTAssertEqual(h.presenter.prompts.last?.reason, RateLimitBreach.consecutive.dialogReason)
        XCTAssertEqual(h.scripts.sentTexts, ["one", "two", "three", "four"])
    }

    func testTwoSendsThatBothPassTheFirstCheckAreCheckedAgainUnderTheQueue() throws {
        let h = try Harness(Harness.Options(queueClock: SystemClock(), plan: .decide(.deny, after: 1.5)))
        try h.allowMom()
        let held = try XCTUnwrap(h.queue.acquire(timeout: 0))
        let lock = NSLock()
        var outcomes: [String: SendOutcome] = [:]
        let logs = ["first": EventLog(), "second": EventLog()]
        let group = DispatchGroup()
        for (text, log) in logs {
            DispatchQueue.global().async(group: group) {
                let outcome = h.send(text, events: log).sendOutcome
                lock.lock()
                outcomes[text] = outcome
                lock.unlock()
            }
        }
        XCTAssertTrue(eventually { h.queue.waiters == 2 })
        XCTAssertTrue(h.presenter.prompts.isEmpty, "both passed the first check")
        h.queue.release(held)
        XCTAssertEqual(group.wait(timeout: .now() + 30), .success)

        XCTAssertEqual(h.scripts.sentTexts.count, 1)
        XCTAssertEqual(h.presenter.prompts.count, 1)
        XCTAssertEqual(h.presenter.prompts.first?.reason, RateLimitBreach.perChatInterval.dialogReason)
        let codes = outcomes.values.map { $0.early?.code ?? $0.parts.first?.result.code }
        XCTAssertEqual(codes.filter { $0 == .delivered }.count, 1)
        XCTAssertEqual(codes.filter { $0 == .denied(.user) }.count, 1)
        for log in logs.values { XCTAssertTrue(log.events.contains(.queued)) }
        XCTAssertFalse(h.queue.isHeld)
    }

    func testADialogRaisedUnderTheQueueAnswersPendingWithinTheApprovalWait() throws {
        let h = try Harness(Harness.Options(plan: .hold))
        try h.allowMom()
        let mom = try h.mom()
        let queue = h.queue
        let limiter = h.container.engine.limiter
        let held = try XCTUnwrap(queue.acquire(timeout: 0))
        let start = h.clock.uptime
        // Another send to Mom lands just before the queue frees up, so the check under the queue raises a dialog.
        let lock = NSLock()
        var fired = false
        h.clock.onSleep { c in
            guard c.uptime >= start + Limits.queueWait - 1 else { return }
            lock.lock()
            let go = !fired
            fired = true
            lock.unlock()
            guard go else { return }
            limiter.record(SendEvent(chat: mom.canonical, at: c.now, guid: nil, textDigest: nil))
            queue.release(held)
        }
        let events = EventLog()
        let outcome = try XCTUnwrap(h.send("hello", approvalWait: Limits.approvalWait, events: events).sendOutcome)
        guard case .pending(let id)? = outcome.early?.code else { return XCTFail("pending") }
        let waited = h.clock.uptime - start
        XCTAssertGreaterThanOrEqual(waited, Limits.approvalWait - 1, "the dialog got what was left of the wait")
        XCTAssertLessThan(waited, Limits.approvalWait + 1, "pending comes within the CLI's approval wait")
        XCTAssertEqual(h.presenter.prompts.map(\.reason), [RateLimitBreach.perChatInterval.dialogReason])
        XCTAssertEqual(events.events.first, .queued)
        XCTAssertFalse(queue.isHeld, "the queue is free while the dialog is up")
        XCTAssertTrue(h.scripts.calls.isEmpty)

        h.presenter.decide(id, .deny)
        h.waitUntilIdle()
        XCTAssertEqual(try h.onlyEntry().result?.code, .denied(.user))
    }

    func testTheApprovalWaitLeftNeverGoesBelowZero() throws {
        let h = try Harness()
        let pong = ResponsePayload.pong(PongInfo(bridgeVersion: "", pid: 0))
        let request = MutationRequest(binding: ApprovalBinding(chat: nil, action: .send), chat: try h.mom(),
                                      requiredScope: .text)
        var job = MutationJob(key: IdempotencyKey(value: "k", targetSlot: nil), again: false, request: request,
                              approvalWait: 120, startedAt: h.clock.uptime, queue: .pipeline, windowOpen: nil,
                              early: { _, _ in pong }, found: { _ in pong },
                              act: { _ in ActionOutcome(result: ActionResult(.ok), payload: pong) })
        let pipeline = MutationPipeline(container: h.container)
        XCTAssertEqual(pipeline.approvalWaitLeft(job), 120)
        h.clock.advance(30)
        XCTAssertEqual(pipeline.approvalWaitLeft(job), 90)
        h.clock.advance(200)
        XCTAssertEqual(pipeline.approvalWaitLeft(job), 0)
        job.startedAt = h.clock.uptime + 5
        XCTAssertEqual(pipeline.approvalWaitLeft(job), 120, "a start in the future counts as now")
    }

    // MARK: - Queue

    func testAHeldQueueAnswersBusyAfterThirtySeconds() throws {
        let h = try Harness()
        try h.allowMom()
        let held = try XCTUnwrap(h.queue.acquire(timeout: 0))
        let events = EventLog()
        let start = h.clock.uptime
        let outcome = try XCTUnwrap(h.send("hello", events: events).sendOutcome)
        XCTAssertEqual(outcome.early?.code, .busy(.queue))
        XCTAssertEqual(events.events, [.queued])
        XCTAssertGreaterThanOrEqual(h.clock.uptime - start, Limits.queueWait)
        XCTAssertTrue(h.scripts.calls.isEmpty)
        XCTAssertEqual(try h.onlyEntry().result?.code, .busy(.queue))

        h.queue.release(held)
        let retry = try XCTUnwrap(h.send("hello").sendOutcome)
        XCTAssertFalse(retry.replayed, "busy doesn't hold the key")
        XCTAssertEqual(retry.parts.map(\.result.code), [.delivered])
    }

    // MARK: - Refusals before the journal

    func testThreadWithFileAndForegroundOffNeverReachTheJournal() throws {
        let h = try Harness(Harness.Options(foreground: true))
        XCTAssertEqual(h.send("hi", thread: true, file: Data("x".utf8)).failure?.result, .threadWithFile)
        XCTAssertEqual(h.send("hi", thread: true).failure?.result, .foregroundModeOff)
        XCTAssertTrue(h.journal.allEntries().isEmpty)
        XCTAssertTrue(h.presenter.prompts.isEmpty)
        XCTAssertTrue(h.uploadFiles.isEmpty)
    }

    func testAThreadedReplyWithoutAForegroundMachineIsRefused() throws {
        let h = try Harness()
        try h.policy.setForegroundMode(true)
        XCTAssertEqual(h.send("hi", thread: true).failure?.result, MutationPipeline.foregroundUnavailable)
        XCTAssertTrue(h.journal.allEntries().isEmpty)
    }

    func testEmptyTextWithoutAFileIsABadRequest() throws {
        let h = try Harness()
        XCTAssertEqual(h.send("  \n").failure?.result, MessageSender.badRequest)
        XCTAssertEqual(h.send(nil).failure?.result, MessageSender.badRequest)
        XCTAssertTrue(h.journal.allEntries().isEmpty)
    }

    func testAnUploadWithABadHeaderIsRefused() throws {
        let h = try Harness()
        let header = UploadHeader(byteCount: 3, fileName: "")
        let request = Request(body: .send(SendArgs(who: Mom.who, text: "hi")), upload: header)
        let payload = h.dispatcher.handle(request, upload: DataUpload(Data("abc".utf8)), events: { _ in }).payload
        XCTAssertEqual(payload.failure?.result, .badRequest)
        XCTAssertTrue(h.journal.allEntries().isEmpty)
    }

    func testAJournalThatCantBeWrittenRunsNothing() throws {
        let h = try Harness()
        try h.allowMom()
        let dir = h.journal.directory.path
        XCTAssertEqual(chmod(dir, 0o500), 0)
        defer { chmod(dir, 0o700) }
        let outcome = try XCTUnwrap(h.send("hello").sendOutcome)
        XCTAssertEqual(outcome.early, .journalWriteFailed)
        XCTAssertTrue(h.scripts.calls.isEmpty)
        XCTAssertFalse(h.queue.isHeld)
    }

    // MARK: - Threaded replies

    func testAThreadedReplyBindsTheNewestIncomingMessage() throws {
        let h = try Harness(Harness.Options(foreground: true, plan: .decide(.deny, after: 1.5)))
        try h.policy.setForegroundMode(true)
        let parent = try XCTUnwrap(h.container.db?.newestIncoming(for: try h.mom()))
        XCTAssertEqual(parent.rowid, 41556)

        let outcome = try XCTUnwrap(h.send("Yes!", thread: true).sendOutcome)
        XCTAssertEqual(outcome.early?.code, .denied(.user))
        XCTAssertEqual(outcome.threadParentRowID, parent.rowid)
        let prompt = try XCTUnwrap(h.presenter.prompts.first)
        XCTAssertEqual(prompt.binding.action, .threadedReply)
        XCTAssertEqual(prompt.binding.parentGUID, parent.guid)
        XCTAssertEqual(prompt.parentText, parent.body)
        XCTAssertFalse(prompt.offersAlwaysAllow)
        XCTAssertEqual(ApprovalPanelModel(prompt: prompt).lines.first,
                       .init(label: "Chat", value: "Mom, +14155550101, reply in thread"),
                       "Messages picks the reply's service, so the dialog claims none")
        XCTAssertEqual(try h.onlyEntry().binding.parentGUID, parent.guid)

        // The same text as a plain send has a key of its own.
        let plain = try XCTUnwrap(h.send("Yes!").sendOutcome)
        XCTAssertFalse(plain.replayed)
        XCTAssertEqual(h.presenter.prompts.count, 2)
    }

    func testAThreadedReplyWithNoIncomingMessageIsAnError() throws {
        let h = try Harness(Harness.Options(foreground: true))
        try h.policy.setForegroundMode(true)
        try h.copy.exec("DELETE FROM chat_message_join WHERE chat_id = 7 AND message_id IN "
                        + "(SELECT ROWID FROM message WHERE is_from_me = 0)")
        let error = try XCTUnwrap(h.send("Yes!", thread: true).failure)
        guard case .error(.message(let line)) = error.result.code else { return XCTFail("\(error)") }
        XCTAssertTrue(line.hasPrefix("no incoming message to reply to in "), line)
        XCTAssertEqual(error.result.fix, "send without --thread")
        XCTAssertTrue(h.journal.allEntries().isEmpty)
    }

    func testAThreadedReplyFollowsItsCapability() throws {
        let h = try Harness(Harness.Options(capabilities: Capability.reported.filter { $0 != .threadedReply },
                                            foreground: true))
        try h.policy.setForegroundMode(true)
        XCTAssertEqual(h.send("Yes!", thread: true).headline, .untested)
        XCTAssertTrue(h.journal.allEntries().isEmpty)
        XCTAssertTrue(h.presenter.prompts.isEmpty)
    }

    // MARK: - Files and groups

    func testAFileSendStagesItAndNeedsTheFilesScope() throws {
        let h = try Harness()
        try h.allowMom(scope: .text)
        let bytes = Data("grocery list".utf8)
        let outcome = try XCTUnwrap(h.send(nil, file: bytes, fileName: "list.txt").sendOutcome)
        XCTAssertTrue(outcome.approved, "a text-only allow asks for a file")
        let prompt = try XCTUnwrap(h.presenter.prompts.first)
        XCTAssertEqual(prompt.attachmentName, "list.txt")
        XCTAssertEqual(prompt.attachmentBytes, Int64(bytes.count))
        XCTAssertEqual(prompt.binding.attachmentDigest, TextNorm.sha256Hex(bytes))
        XCTAssertEqual(outcome.parts.map(\.part), [.file])
        XCTAssertEqual(outcome.parts.first?.result.code, .delivered)
        let part = try XCTUnwrap(outcome.parts.first)
        let rowid = try XCTUnwrap(part.rowid)
        let attachment = try XCTUnwrap(part.attachment, "the file part carries the attachment chat.db recorded")
        XCTAssertEqual(attachment.rowid, 90_000 + rowid)
        let staged = try XCTUnwrap(h.scripts.calls.first?.1[1])
        XCTAssertEqual(attachment.transferName, URL(fileURLWithPath: staged).lastPathComponent)
        XCTAssertEqual(h.scripts.calls.map(\.0), [.sendFile])
        XCTAssertTrue(h.uploadFiles.isEmpty, "the frozen upload is discarded after final")
    }

    func testAnImageIsUnsupportedWithoutImageSend() throws {
        let h = try Harness(Harness.Options(capabilities: Capability.reported.filter { $0 != .imageSend }))
        let photo = try Data(contentsOf: Photo.heic)
        let outcome = try XCTUnwrap(h.send(nil, file: photo, fileName: "IMG_2439.HEIC").sendOutcome)
        XCTAssertEqual(outcome.early, MutationPipeline.imageUnsupported)
        XCTAssertTrue(h.journal.allEntries().isEmpty)
        XCTAssertTrue(h.scripts.calls.isEmpty)
        XCTAssertTrue(h.uploadFiles.isEmpty)
    }

    func testAnImageReachesTheDialogWithImageSend() throws {
        let h = try Harness(Harness.Options(plan: .decide(.deny, after: 1.5)))
        let photo = try Data(contentsOf: Photo.heic)
        XCTAssertEqual(h.send(nil, file: photo, fileName: "IMG_2439.HEIC").headline, .denied(.user))
        XCTAssertEqual(h.presenter.prompts.first?.attachmentName, "IMG_2439.HEIC")
        XCTAssertTrue(h.uploadFiles.isEmpty)
    }

    func testAGroupSendIsUnsupportedWithoutGroupSend() throws {
        let h = try Harness(Harness.Options(capabilities: Capability.reported.filter { $0 != .groupSend }))
        let outcome = try XCTUnwrap(h.send("hi all", to: "12").sendOutcome)
        XCTAssertEqual(outcome.early, MessageSender.groupUnsupported)
        XCTAssertTrue(h.journal.allEntries().isEmpty)
        XCTAssertTrue(h.presenter.prompts.isEmpty)
        XCTAssertTrue(h.scripts.calls.isEmpty, "no Apple Event while group sends are untested")
    }

    func testAGroupSendWithGroupSendGoesToTheChatAndMatchesItsJoinRow() throws {
        let h = try Harness()
        let outcome = try XCTUnwrap(h.send("hi all", to: "12").sendOutcome)
        XCTAssertNil(outcome.early)
        XCTAssertEqual(h.scripts.calls.map(\.0), [.sendChatText])
        XCTAssertEqual(h.scripts.calls.first?.1, [SendingScripts.familyGUID, "hi all"])
        XCTAssertEqual(outcome.parts.map(\.result), [ActionResult(.delivered)])
        XCTAssertNotNil(outcome.parts.first?.rowid)
    }
}
