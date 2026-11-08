import XCTest
@testable import IMBridge
import IMCore
import IMPolicy
import IMStore
import IMTestSupport
import IMUI

/// Tapbacks, unsend and edit through the pipeline. The AX tree and the chat switch are fakes; chat.db is a fixture
/// copy, and each press writes the row Messages would write.
final class UIPipelineTests: XCTestCase {
    static let incoming: Int64 = 41556

    private func react(_ h: Harness, _ rowid: Int64 = UIPipelineTests.incoming, kind: TapbackKind = .heart,
                       remove: Bool = false, again: Bool = false) -> ResponsePayload {
        h.call(.ui(UIArgs(action: .react(rowid: rowid, kind: kind, remove: remove), again: again)))
    }

    /// Each "Heart" press writes an outgoing heart on `guid`; each other press is only recorded.
    private func writeHearts(_ h: Harness, on guid: String) {
        let lock = NSLock()
        var next: Int64 = 61_000
        h.ax.onPerform = { [copy = h.copy, clock = h.clock] name in
            guard name == "Heart" else { return }
            lock.lock()
            let rowid = next
            next += 1
            lock.unlock()
            try? copy.insertMessage(rowid: rowid, guid: "TB-\(rowid)", text: nil, fromMe: true,
                                    date: AppleTime.nanos(from: clock.now), associatedType: 2000,
                                    associatedGUID: "p:0/\(guid)")
        }
    }

    private func target(_ h: Harness, _ rowid: Int64) throws -> MessageTargetInfo {
        try XCTUnwrap(try XCTUnwrap(h.container.db).messageTarget(rowid: rowid))
    }

    // MARK: - Tapbacks

    func testAReactionResolvesItsChatFromTheMessageAndVerifies() throws {
        let h = try Harness()
        try h.allowMom()
        let guid = try target(h, UIPipelineTests.incoming).guid
        writeHearts(h, on: guid)

        let outcome = try XCTUnwrap(react(h).uiOutcome)
        XCTAssertEqual(outcome.result.code, .ok)
        XCTAssertEqual(outcome.chat?.rowid, Mom.chatRowID)
        XCTAssertEqual(outcome.currentReaction, .heart)
        XCTAssertEqual(outcome.targetQuote?.rowid, UIPipelineTests.incoming)
        XCTAssertNotEqual(outcome.targetQuote?.senderName, "You")
        XCTAssertEqual(h.ax.performed, ["Heart"])
        XCTAssertEqual(h.targeting.selected.count, 1)
        XCTAssertTrue(h.presenter.prompts.isEmpty)
        let entry = try h.onlyEntry()
        XCTAssertEqual(entry.binding.targetGUID, guid)
        XCTAssertEqual(entry.binding.targetPart, 0)
        XCTAssertEqual(entry.facts?.targetRowID, UIPipelineTests.incoming)
        XCTAssertNil(entry.response.flatMap { $0.uiOutcome?.targetQuote }, "the journal keeps no quote")
        XCTAssertFalse(h.queue.isHeld)
    }

    func testAReactionWithoutAccessibilityOpensNoDialogAndRunsNothing() throws {
        let h = try Harness(Harness.Options(plan: .decide(.allowOnce, after: 0)))
        h.permissions.accessibilityState = .denied
        let outcome = try XCTUnwrap(react(h).uiOutcome)
        XCTAssertEqual(outcome.result, UIResults.accessibilityMissing)
        XCTAssertEqual(outcome.result.rendered, "error: Accessibility not granted fix: run imessage doctor --ui")
        XCTAssertFalse(outcome.approved)
        XCTAssertTrue(h.presenter.prompts.isEmpty)
        XCTAssertTrue(h.journal.allEntries().isEmpty)
        XCTAssertTrue(h.ax.performed.isEmpty)
        XCTAssertTrue(h.targeting.selected.isEmpty)
        XCTAssertTrue(h.app.calls.isEmpty, "Messages is not launched")
        XCTAssertEqual(h.permissions.calls, [.accessibility(prompt: false)], "the check never prompts")
    }

    func testAReactionThatIsAlreadyThereRunsNothing() throws {
        let h = try Harness()
        try h.allowMom()
        writeHearts(h, on: try target(h, UIPipelineTests.incoming).guid)
        XCTAssertEqual(react(h).headline, .ok)
        let again = try XCTUnwrap(react(h).uiOutcome)
        XCTAssertEqual(again.result.code, .already)
        XCTAssertEqual(again.currentReaction, .heart)
        XCTAssertEqual(h.ax.performed.count, 1)
        XCTAssertEqual(h.journal.allEntries().count, 1)

        let removeNothing = try XCTUnwrap(react(h, kind: .like, remove: true).uiOutcome)
        XCTAssertEqual(removeNothing.result.code, .already)
        XCTAssertEqual(h.journal.allEntries().count, 1)
    }

    func testARepeatedReactionKeyRereadsTheReactionAndNeverPressesAgain() throws {
        let h = try Harness()
        try h.allowMom()
        let guid = try target(h, UIPipelineTests.incoming).guid
        writeHearts(h, on: guid)
        XCTAssertEqual(react(h).headline, .ok)
        // The user takes the heart off in Messages.
        try h.copy.insertMessage(rowid: 61_500, guid: "TB-OFF", text: nil, fromMe: true,
                                 date: AppleTime.nanos(from: h.clock.now), associatedType: 3000,
                                 associatedGUID: "p:0/\(guid)")
        let repeated = try XCTUnwrap(react(h).uiOutcome)
        XCTAssertTrue(repeated.replayed)
        XCTAssertEqual(repeated.result.code, .ok)
        XCTAssertNil(repeated.currentReaction, "the reaction comes from chat.db, not the first answer")
        XCTAssertEqual(repeated.targetQuote?.rowid, UIPipelineTests.incoming)
        XCTAssertEqual(h.ax.performed.count, 1)
    }

    func testATapbackFollowsItsCapability() throws {
        let h = try Harness(Harness.Options(capabilities: []))
        try h.allowMom()
        XCTAssertEqual(react(h).headline, .untested)
        XCTAssertTrue(h.journal.allEntries().isEmpty)
        XCTAssertTrue(h.ax.performed.isEmpty)
    }

    func testAnIncomingTapbackUsesTheIncomingCapability() throws {
        let own: [Capability] = [.tapbackOwnMessages(.heart)]
        let h = try Harness(Harness.Options(capabilities: own))
        try h.allowMom()
        XCTAssertEqual(react(h).headline, .untested, "own-message evidence doesn't cover an incoming message")
        h.clock.advance(1)
        try h.insertOwnMessage(60_900, text: "my note", age: 5)
        writeHearts(h, on: "OWN-60900")
        XCTAssertEqual(react(h, 60_900).headline, .ok, "hearts get rowids above the snapshot, as in Messages")
    }

    func testAMissingMessageIsAnError() throws {
        let h = try Harness()
        let error = try XCTUnwrap(react(h, 9_999_999).failure)
        XCTAssertEqual(error.result.code, .error(.message("no message 9999999")))
        XCTAssertEqual(error.result.fix, "imessage read <who> shows message ids")
    }

    func testAGroupTargetIsUnsupportedBeforeTheDialog() throws {
        let h = try Harness()
        let rowid = try XCTUnwrap(Int64(try h.copy.strings(
            "SELECT message_id FROM chat_message_join WHERE chat_id = 12 ORDER BY message_id DESC LIMIT 1").first ?? ""))
        XCTAssertEqual(react(h, rowid).headline, .unsupportedTarget)
        XCTAssertTrue(h.presenter.prompts.isEmpty)
        XCTAssertTrue(h.journal.allEntries().isEmpty)
    }

    // MARK: - Unsend

    func testUnsendAsksAndPressesUndoSend() throws {
        let h = try Harness()
        try h.allowMom()
        let rowid = try h.insertOwnMessage(62_000, text: "running late", age: 10)
        h.ax.onPerform = { [copy = h.copy, clock = h.clock] name in
            guard name == UINames.undoSend else { return }
            try? copy.exec("UPDATE message SET date_edited = \(AppleTime.nanos(from: clock.now)), text = NULL "
                           + "WHERE ROWID = \(rowid)")
        }
        let outcome = try XCTUnwrap(h.call(.ui(UIArgs(action: .unsend(rowid: rowid)))).uiOutcome)
        XCTAssertEqual(outcome.result.code, .ok)
        XCTAssertTrue(outcome.approved)
        XCTAssertEqual(outcome.targetQuote?.senderName, "You")
        let prompt = try XCTUnwrap(h.presenter.prompts.first)
        XCTAssertEqual(prompt.reason, "unsend always asks")
        XCTAssertFalse(prompt.offersAlwaysAllow)
        XCTAssertEqual(prompt.text, "running late")
        XCTAssertEqual(h.ax.performed, [UINames.undoSend])
    }

    func testUnsendPastTheWindowIsExpiredBeforeTheDialog() throws {
        let h = try Harness()
        let rowid = try h.insertOwnMessage(62_001, text: "too old", age: Limits.undoSendWindow + 1)
        XCTAssertEqual(h.call(.ui(UIArgs(action: .unsend(rowid: rowid)))).headline, .expired)
        XCTAssertTrue(h.presenter.prompts.isEmpty)
        XCTAssertTrue(h.journal.allEntries().isEmpty)
    }

    func testUnsendWhoseWindowClosesDuringTheDialogIsExpired() throws {
        let h = try Harness()
        let rowid = try h.insertOwnMessage(62_002, text: "almost", age: Limits.undoSendWindow - 1)
        let outcome = try XCTUnwrap(h.call(.ui(UIArgs(action: .unsend(rowid: rowid)))).uiOutcome)
        XCTAssertEqual(outcome.result.code, .expired)
        XCTAssertTrue(outcome.approved)
        XCTAssertEqual(h.presenter.prompts.count, 1)
        XCTAssertTrue(h.ax.performed.isEmpty)
        XCTAssertEqual(try h.onlyEntry().result?.code, .expired)
        XCTAssertEqual(h.queue.acquisitions, 0, "an expired action never takes the queue")
    }

    func testUnsendOfAnIncomingMessageIsAnUnsupportedTarget() throws {
        let h = try Harness()
        XCTAssertEqual(h.call(.ui(UIArgs(action: .unsend(rowid: UIPipelineTests.incoming)))).headline,
                       .unsupportedTarget)
        XCTAssertTrue(h.journal.allEntries().isEmpty)
    }

    func testUnsendOfAnUnsentMessageIsAlready() throws {
        let h = try Harness()
        let rowid = try h.insertOwnMessage(62_003, text: "gone", age: 5)
        try h.copy.exec("UPDATE message SET date_edited = \(AppleTime.nanos(from: h.clock.now)), text = NULL "
                        + "WHERE ROWID = \(rowid)")
        XCTAssertEqual(h.call(.ui(UIArgs(action: .unsend(rowid: rowid)))).headline, .already)
        XCTAssertTrue(h.journal.allEntries().isEmpty)
    }

    // MARK: - The press's final check

    /// Messages showing with one window on screen, as the user opening it would leave it.
    private static let shown = MessagesAppState(isRunning: true, pid: 4242, isFrontmost: false, isHidden: false,
                                                axWindowCount: 1, onScreenWindowCount: 1, allSpacesWindowCount: 1)

    /// The states the journal wrote for `id`, in order, read from its file. Unsend writes `received` twice, the
    /// second time with its dialog's id.
    private func states(_ h: Harness, _ id: String) throws -> [JournalState] {
        let lines = try String(contentsOf: h.journal.fileURL, encoding: .utf8).split(separator: "\n")
        return try lines.map { try JSONDecoder.wire.decode(JournalEntry.self, from: Data($0.utf8)) }
            .filter { $0.id == id }
            .map(\.state)
    }

    private func holdsKey(_ h: Harness, _ entry: JournalEntry) -> Bool {
        if case .fresh = h.journal.lookup(entry.key, again: false) { return false }
        return true
    }

    func testATapbackRefusedAtTheFinalCheckGoesFromInvokingToFinal() throws {
        let h = try Harness()
        try h.allowMom()
        h.ax.beforeFinalCheck = { [app = h.app] in app.state_ = UIPipelineTests.shown }
        let outcome = try XCTUnwrap(react(h).uiOutcome)
        XCTAssertEqual(outcome.result.code, .busy(.messagesOpen))
        XCTAssertTrue(h.ax.performed.isEmpty)
        let entry = try h.onlyEntry()
        XCTAssertEqual(try states(h, entry.id), [.received, .invoking, .final])
        XCTAssertFalse(holdsKey(h, entry))
    }

    func testATapbackErrorAfterThePressStillRecordsInvoked() throws {
        let h = try Harness()
        try h.allowMom()
        h.ax.performError = AXDriveError.axError(-25204)
        let outcome = try XCTUnwrap(react(h).uiOutcome)
        XCTAssertEqual(outcome.result.code, .mayHaveCompleted)
        XCTAssertEqual(h.ax.performed, ["Heart"])
        let entry = try h.onlyEntry()
        XCTAssertEqual(try states(h, entry.id), [.received, .invoking, .invoked, .final])
        XCTAssertTrue(holdsKey(h, entry))
    }

    func testAnUnsendThatExpiresAtTheFinalCheckGoesFromInvokingToFinal() throws {
        let h = try Harness()
        let rowid = try h.insertOwnMessage(62_010, text: "nearly", age: Limits.undoSendWindow - 10)
        h.ax.beforeFinalCheck = { [clock = h.clock] in clock.advance(20) }
        let outcome = try XCTUnwrap(h.call(.ui(UIArgs(action: .unsend(rowid: rowid)))).uiOutcome)
        XCTAssertEqual(outcome.result.code, .expired)
        XCTAssertTrue(outcome.approved)
        XCTAssertTrue(h.ax.performed.isEmpty)
        let entry = try h.onlyEntry()
        XCTAssertEqual(try states(h, entry.id), [.received, .received, .approved, .invoking, .final])
        XCTAssertFalse(holdsKey(h, entry))
    }

    func testAnUnsendRefusedByTheWindowRulesAtTheFinalCheckGoesFromInvokingToFinal() throws {
        let h = try Harness()
        let rowid = try h.insertOwnMessage(62_011, text: "running late", age: 10)
        h.ax.beforeFinalCheck = { [app = h.app] in app.state_ = UIPipelineTests.shown }
        let outcome = try XCTUnwrap(h.call(.ui(UIArgs(action: .unsend(rowid: rowid)))).uiOutcome)
        XCTAssertEqual(outcome.result.code, .busy(.messagesOpen))
        XCTAssertTrue(h.ax.performed.isEmpty)
        let entry = try h.onlyEntry()
        XCTAssertEqual(try states(h, entry.id), [.received, .received, .approved, .invoking, .final])
        XCTAssertFalse(holdsKey(h, entry))
    }

    func testAnUnsendErrorAfterThePressStillRecordsInvoked() throws {
        let h = try Harness()
        let rowid = try h.insertOwnMessage(62_012, text: "running late", age: 10)
        h.ax.performError = AXDriveError.axError(-25204)
        let outcome = try XCTUnwrap(h.call(.ui(UIArgs(action: .unsend(rowid: rowid)))).uiOutcome)
        XCTAssertEqual(outcome.result.code, .mayHaveCompleted)
        XCTAssertEqual(h.ax.performed, [UINames.undoSend])
        let entry = try h.onlyEntry()
        XCTAssertEqual(try states(h, entry.id), [.received, .received, .approved, .invoking, .invoked, .final])
        XCTAssertTrue(holdsKey(h, entry))
    }

    // MARK: - A chat that isn't open in Messages

    private static let chatNotOpen = ActionResult(.busy(.chatNotOpen),
                                                  fix: "open Mom in Messages, hide it (⌘H), then retry")

    func testAReactionOnAChatThatIsNotOpenIsAnEarlyBusyRefusal() throws {
        let h = try Harness()
        try h.allowMom()
        h.targeting.selection = .refused(UIPipelineTests.chatNotOpen)
        let outcome = try XCTUnwrap(react(h).uiOutcome)
        XCTAssertEqual(outcome.result, UIPipelineTests.chatNotOpen)
        XCTAssertEqual(outcome.result.rendered,
                       "busy: chat not open in Messages fix: open Mom in Messages, hide it (⌘H), then retry")
        XCTAssertTrue(h.ax.performed.isEmpty)
        XCTAssertEqual(h.targeting.selected.count, 1)
        let entry = try h.onlyEntry()
        XCTAssertEqual(try states(h, entry.id), [.received, .final])
        XCTAssertNil(entry.facts)
        XCTAssertFalse(holdsKey(h, entry))
        XCTAssertFalse(h.queue.isHeld)
    }

    func testAnUnsendOnAChatThatIsNotOpenIsAnEarlyBusyRefusal() throws {
        let h = try Harness()
        let rowid = try h.insertOwnMessage(62_013, text: "running late", age: 10)
        h.targeting.selection = .refused(UIPipelineTests.chatNotOpen)
        let outcome = try XCTUnwrap(h.call(.ui(UIArgs(action: .unsend(rowid: rowid)))).uiOutcome)
        XCTAssertEqual(outcome.result, UIPipelineTests.chatNotOpen)
        XCTAssertTrue(outcome.approved)
        XCTAssertTrue(h.ax.performed.isEmpty)
        let entry = try h.onlyEntry()
        XCTAssertEqual(try states(h, entry.id), [.received, .received, .approved, .final])
        XCTAssertNil(entry.facts)
        XCTAssertFalse(holdsKey(h, entry))
        XCTAssertFalse(h.queue.isHeld)
    }

    // MARK: - Edit

    func testEditChecksItsTextAndForegroundModeBeforeTheJournal() throws {
        let h = try Harness(Harness.Options(foreground: true))
        let rowid = try h.insertOwnMessage(62_004, text: "see you at 5", age: 30)
        let empty = try XCTUnwrap(h.call(.ui(UIArgs(action: .edit(rowid: rowid, text: " ")))).failure)
        XCTAssertEqual(empty.result.code, .error(.message("edit needs the new text")))
        XCTAssertEqual(h.call(.ui(UIArgs(action: .edit(rowid: rowid, text: "6")))).failure?.result,
                       .foregroundModeOff)
        try h.policy.setForegroundMode(true)
        XCTAssertEqual(h.call(.ui(UIArgs(action: .edit(rowid: UIPipelineTests.incoming, text: "6")))).headline,
                       .unsupportedTarget)
        XCTAssertTrue(h.journal.allEntries().isEmpty)
        XCTAssertTrue(h.presenter.prompts.isEmpty)
    }

    func testEditWithoutAForegroundMachineIsRefused() throws {
        let h = try Harness()
        try h.policy.setForegroundMode(true)
        let rowid = try h.insertOwnMessage(62_005, text: "see you at 5", age: 30)
        XCTAssertEqual(h.call(.ui(UIArgs(action: .edit(rowid: rowid, text: "6")))).failure?.result,
                       MutationPipeline.foregroundUnavailable)
    }

    func testEditPromptShowsTheCurrentAndNewText() throws {
        let h = try Harness(Harness.Options(foreground: true, plan: .decide(.deny, after: 1.5)))
        try h.policy.setForegroundMode(true)
        let rowid = try h.insertOwnMessage(62_006, text: "see you at 5", age: 30)
        XCTAssertEqual(h.call(.ui(UIArgs(action: .edit(rowid: rowid, text: "see you at 6")))).headline, .denied(.user))
        let prompt = try XCTUnwrap(h.presenter.prompts.first)
        XCTAssertEqual(prompt.parentText, "see you at 5")
        XCTAssertEqual(prompt.text, "see you at 6")
        XCTAssertEqual(prompt.binding.textDigest, TextNorm.textDigest("see you at 6"))
        XCTAssertEqual(ApprovalPanelModel(prompt: prompt).lines.map(\.label), ["Chat", "Current text", "New text"])
    }

    // MARK: - Pre-checks

    func testTargetRefusalRules() throws {
        let h = try Harness()
        let chat = try h.mom()
        var t = try target(h, UIPipelineTests.incoming)
        XCTAssertNil(MutationPipeline.targetRefusal(.react, target: t, chat: chat, editState: nil))
        XCTAssertEqual(MutationPipeline.targetRefusal(.unsend, target: t, chat: chat, editState: nil)?.code,
                       .unsupportedTarget)
        XCTAssertEqual(MutationPipeline.targetRefusal(.edit, target: t, chat: chat, editState: nil)?.code,
                       .unsupportedTarget)
        t.partCount = 2
        XCTAssertEqual(MutationPipeline.targetRefusal(.react, target: t, chat: chat, editState: nil)?.code,
                       .unsupportedTarget)
        t.partCount = 1
        t.isGroupChat = true
        XCTAssertEqual(MutationPipeline.targetRefusal(.react, target: t, chat: chat, editState: nil)?.code,
                       .unsupportedTarget)
        t.isGroupChat = false
        t.fromMe = true
        t.isUnsent = true
        XCTAssertEqual(MutationPipeline.targetRefusal(.unsend, target: t, chat: chat, editState: nil)?.code, .already)
        t.isUnsent = false
        let edited = EditStateProbe(rowid: t.rowid, dateEditedNs: 5, dateRetractedNs: 0, body: "")
        XCTAssertEqual(MutationPipeline.targetRefusal(.unsend, target: t, chat: chat, editState: edited)?.code, .already)
        t.body = " "
        XCTAssertEqual(MutationPipeline.targetRefusal(.react, target: t, chat: chat, editState: nil)?.code,
                       .unsupportedTarget)
    }

    func testCapabilityGateMapsEachStatus() {
        XCTAssertNil(MutationPipeline.gate(.supported))
        XCTAssertEqual(MutationPipeline.gate(.untested)?.code, .untested)
        XCTAssertEqual(MutationPipeline.gate(.unsupported)?.code, .unsupported)
    }
}
