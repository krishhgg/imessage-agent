import XCTest
@testable import IMBridge
import IMCore
import IMPolicy
import IMStore
import IMTestSupport

/// `allow` and `revoke`, for chats and for foreground mode. Every change goes through the dialog.
final class PolicyChangeTests: XCTestCase {
    func testAllowAsksThenAddsTheChat() throws {
        let h = try Harness()
        let events = EventLog()
        let outcome = try XCTUnwrap(h.call(.allow(AllowArgs(who: Mom.who)), events: events).policyOutcome)
        XCTAssertEqual(outcome.result.code, .ok)
        XCTAssertEqual(outcome.change, .allowChat)
        XCTAssertEqual(outcome.scope, .text)
        XCTAssertEqual(outcome.chat?.rowid, Mom.chatRowID)
        let prompt = try XCTUnwrap(h.presenter.prompts.first)
        XCTAssertEqual(prompt.reason, "changes to the allowed chats always ask")
        XCTAssertFalse(prompt.offersAlwaysAllow)
        XCTAssertEqual(events.events, [.approvalShown(id: prompt.id)])
        XCTAssertEqual(h.policy.entry(for: try h.mom().canonical)?.scope, .text)
        let entry = try h.onlyEntry()
        XCTAssertEqual(entry.state, .final)
        XCTAssertNotNil(entry.invokingAt, "a policy write is journaled as invoking first")
        XCTAssertEqual(h.queue.acquisitions, 0, "policy changes don't touch Messages, so they never queue")
    }

    func testAllowThatChangesNothingIsAlreadyWithoutADialog() throws {
        let h = try Harness()
        try h.allowMom(scope: .files)
        XCTAssertEqual(h.call(.allow(AllowArgs(who: Mom.who))).headline, .already)
        XCTAssertEqual(h.call(.allow(AllowArgs(who: Mom.who, files: true))).headline, .already)
        XCTAssertTrue(h.presenter.prompts.isEmpty)
        XCTAssertTrue(h.journal.allEntries().isEmpty)
    }

    func testAllowWithFilesWidensATextEntry() throws {
        let h = try Harness()
        try h.allowMom(scope: .text)
        let outcome = try XCTUnwrap(h.call(.allow(AllowArgs(who: Mom.who, files: true))).policyOutcome)
        XCTAssertEqual(outcome.result.code, .ok)
        XCTAssertEqual(h.presenter.prompts.first?.title.hasSuffix(", with files"), true)
        XCTAssertEqual(h.policy.entry(for: try h.mom().canonical)?.scope, .files)
    }

    func testRevokeAsksThenRemovesTheChat() throws {
        let h = try Harness()
        try h.allowMom()
        XCTAssertEqual(h.call(.revoke(RevokeArgs(who: Mom.who))).headline, .ok)
        XCTAssertNil(h.policy.entry(for: try h.mom().canonical))
        XCTAssertEqual(h.presenter.prompts.count, 1)
        XCTAssertEqual(h.call(.revoke(RevokeArgs(who: Mom.who))).headline, .already)
        XCTAssertEqual(h.presenter.prompts.count, 1)
    }

    func testADeniedChangeLeavesThePolicyAlone() throws {
        let h = try Harness(Harness.Options(plan: .decide(.deny, after: 1.5)))
        XCTAssertEqual(h.call(.allow(AllowArgs(who: Mom.who))).headline, .denied(.user))
        XCTAssertNil(h.policy.entry(for: try h.mom().canonical))
        // Each change gets a key of its own, so asking again shows the dialog again.
        XCTAssertEqual(h.call(.allow(AllowArgs(who: Mom.who))).headline, .denied(.user))
        XCTAssertEqual(h.presenter.prompts.count, 2)
    }

    func testForegroundModeGoesOnAndOffThroughTheDialog() throws {
        let h = try Harness()
        let on = try XCTUnwrap(h.call(.allow(AllowArgs(who: nil, foreground: true))).policyOutcome)
        XCTAssertEqual(on.change, .foregroundOn)
        XCTAssertEqual(on.result.code, .ok)
        XCTAssertNil(on.chat)
        XCTAssertTrue(h.policy.isForegroundModeOn)
        XCTAssertEqual(h.presenter.prompts.first?.reason, "foreground mode changes always ask")
        XCTAssertEqual(h.call(.allow(AllowArgs(who: nil, foreground: true))).headline, .already)

        let off = try XCTUnwrap(h.call(.revoke(RevokeArgs(who: nil, foreground: true))).policyOutcome)
        XCTAssertEqual(off.change, .foregroundOff)
        XCTAssertFalse(h.policy.isForegroundModeOn)
        XCTAssertEqual(h.call(.revoke(RevokeArgs(who: nil, foreground: true))).headline, .already)
        XCTAssertEqual(h.presenter.prompts.count, 2)
    }

    func testAChangeNamesExactlyOneTarget() throws {
        let h = try Harness()
        XCTAssertEqual(h.call(.allow(AllowArgs(who: Mom.who, foreground: true))).failure?.result, .badRequest)
        XCTAssertEqual(h.call(.allow(AllowArgs(who: nil))).failure?.result, .badRequest)
        XCTAssertEqual(h.call(.allow(AllowArgs(who: "  "))).failure?.result, .badRequest)
        XCTAssertEqual(h.call(.revoke(RevokeArgs(who: nil))).failure?.result, .badRequest)
        XCTAssertTrue(h.presenter.prompts.isEmpty)
    }

    func testAPolicyFileThatCantBeSavedIsAnError() throws {
        let h = try Harness()
        let dir = h.policy.fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(dir.path, 0o500), 0)
        defer { chmod(dir.path, 0o700) }
        let outcome = try XCTUnwrap(h.call(.allow(AllowArgs(who: Mom.who))).policyOutcome)
        XCTAssertEqual(outcome.result, MutationPipeline.policySaveFailed)
        XCTAssertNil(h.policy.entry(for: try h.mom().canonical))
    }
}
