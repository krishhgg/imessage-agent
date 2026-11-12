import XCTest
@testable import IMBridge
import IMCore
import IMPolicy
import IMStore
import IMTestSupport
import IMUI

/// `status`, `setup`, `doctor`, and opening chat.db, over recording permission fakes.
final class ServicesTests: XCTestCase {
    func testStatusChecksEveryPermissionSilently() throws {
        let h = try Harness()
        try h.allowMom()
        guard case .status(let status) = h.call(.status) else { return XCTFail("status") }
        XCTAssertEqual(h.permissions.calls, [.fullDiskAccess, .automation(ask: false), .accessibility(prompt: false)])
        XCTAssertEqual(status.bridgeVersion, AppIdentity.version)
        XCTAssertEqual(status.pid, getpid())
        XCTAssertTrue(status.messagesRunning)
        XCTAssertFalse(status.foregroundMode)
        XCTAssertTrue(status.allowlistTrusted)
        XCTAssertEqual(status.allowedChats, 1)
        XCTAssertEqual(status.openApprovals, 0)
        XCTAssertNil(status.crashNote)
    }

    func testStatusCountsOpenApprovals() throws {
        let h = try Harness(Harness.Options(plan: .hold))
        let first = try XCTUnwrap(h.call(.allow(AllowArgs(who: nil, foreground: true, approvalWait: 0))).policyOutcome)
        guard case .pending(let id) = first.result.code else { return XCTFail("pending") }
        guard case .status(let status) = h.call(.status) else { return XCTFail("status") }
        XCTAssertEqual(status.openApprovals, 1)
        h.presenter.decide(id, .deny)
        h.waitUntilIdle()
        XCTAssertFalse(h.policy.isForegroundModeOn)
    }

    func testStatusAndDoctorReportAnAllowlistChangedOutsideTheBridge() throws {
        let h = try Harness()
        try h.allowMom()
        try Data(#"{"version":1,"entries":[],"foregroundMode":true}"#.utf8).write(to: h.policy.fileURL)
        guard case .status(let status) = h.call(.status) else { return XCTFail("status") }
        XCTAssertFalse(status.allowlistTrusted)
        XCTAssertFalse(status.foregroundMode, "an untrusted file never turns foreground mode on")
        guard case .doctor(let report) = h.call(.doctor(DoctorArgs())) else { return XCTFail("doctor") }
        guard case .untrusted(let reason) = h.policy.load() else { return XCTFail("still trusted") }
        let check = try XCTUnwrap(report.checks.first { $0.name == "allowlist" })
        XCTAssertFalse(check.ok)
        XCTAssertEqual(check.detail, DoctorService.describe(reason))
        XCTAssertEqual(check.fix, "approve each chat again with imessage allow <who>")
    }

    func testSetupOpensTheFullDiskAccessPaneOnlyWhenNeeded() throws {
        let h = try Harness()
        h.permissions.fullDiskAccessState = .denied
        guard case .setup(let denied) = h.call(.setup(SetupArgs(stage: .fullDiskAccess))) else { return XCTFail("setup") }
        XCTAssertEqual(denied.state, .denied)
        XCTAssertEqual(denied.openedPane, h.permissions.paneURL)
        XCTAssertEqual(h.permissions.calls, [.fullDiskAccess, .openPane])

        let g = try Harness()
        guard case .setup(let granted) = g.call(.setup(SetupArgs(stage: .fullDiskAccess))) else { return XCTFail("setup") }
        XCTAssertEqual(granted.state, .granted)
        XCTAssertNil(granted.openedPane)
        XCTAssertEqual(g.permissions.calls, [.fullDiskAccess])
    }

    func testSetupRaisesTheAutomationAndAccessibilityPrompts() throws {
        let h = try Harness()
        h.permissions.automationState = .notDetermined
        guard case .setup(let automation) = h.call(.setup(SetupArgs(stage: .automation))) else { return XCTFail("a") }
        XCTAssertEqual(automation.state, .notDetermined)
        guard case .setup(let ax) = h.call(.setup(SetupArgs(stage: .accessibility))) else { return XCTFail("ax") }
        XCTAssertEqual(ax.state, .granted)
        XCTAssertEqual(h.permissions.calls, [.automation(ask: true), .accessibility(prompt: true)])
        XCTAssertFalse(h.app.calls.contains("launchHidden"), "a running Messages is left alone")
    }

    func testSetupStartsMessagesHiddenBeforeTheAutomationPrompt() throws {
        let h = try Harness()
        h.app.state_ = .notRunning
        guard case .setup(let report) = h.call(.setup(SetupArgs(stage: .automation))) else { return XCTFail("setup") }
        XCTAssertEqual(report.state, .granted)
        XCTAssertEqual(h.app.calls, ["launchHidden"])
        XCTAssertEqual(h.permissions.calls, [.automation(ask: true)])
    }

    func testDoctorListsItsChecksAndRaisesNoPrompt() throws {
        let h = try Harness()
        h.app.state_ = .notRunning
        guard case .doctor(let report) = h.call(.doctor(DoctorArgs())) else { return XCTFail("doctor") }
        XCTAssertEqual(report.checks.map(\.name), ["chat.db", "Automation", "allowlist", "foreground mode"])
        XCTAssertTrue(report.checks.allSatisfy(\.ok))
        XCTAssertFalse(report.needsKickstart)
        XCTAssertEqual(report.releaseTestBuild, CapabilityRegistry.isReleaseTestBuild)
        XCTAssertEqual(h.permissions.calls, [.silentAutomation, .accessibility(prompt: false)],
                       "the CLI raises the prompts with setup stages")
        XCTAssertTrue(h.app.calls.isEmpty, "doctor never starts Messages")

        h.permissions.automationState = .denied
        guard case .doctor(let denied) = h.call(.doctor(DoctorArgs())) else { return XCTFail("doctor") }
        let automation = try XCTUnwrap(denied.checks.first { $0.name == "Automation" })
        XCTAssertFalse(automation.ok)
        XCTAssertNotNil(automation.fix)
    }

    func testDoctorWithUIActionsChecksAccessibilityAndTheActionNames() throws {
        let h = try Harness()
        h.ax.bubbles = [FakeTargeting.fullBubble]
        guard case .doctor(let report) = h.call(.doctor(DoctorArgs(wantUIActions: true))) else { return XCTFail("d") }
        XCTAssertEqual(h.permissions.calls, [.silentAutomation, .accessibility(prompt: false)])
        XCTAssertEqual(report.checks.first { $0.name == "Accessibility" }?.ok, true)
        XCTAssertEqual(report.checks.first { $0.name == "action names" }?.ok, true)

        var renamed = FakeTargeting.fullBubble
        renamed.actionNames = renamed.actionNames.filter { $0 != "Heart" }
        h.ax.bubbles = [FakeTargeting.fullBubble, renamed]
        guard case .doctor(let missing) = h.call(.doctor(DoctorArgs(wantUIActions: true))) else { return XCTFail("d") }
        let names = try XCTUnwrap(missing.checks.first { $0.name == "action names" })
        XCTAssertFalse(names.ok)
        XCTAssertEqual(names.detail, "missing: Heart")
        XCTAssertEqual(names.fix, "set the macOS language to English, or update iMessage Agent")

        h.permissions.accessibilityState = .denied
        guard case .doctor(let untrusted) = h.call(.doctor(DoctorArgs(wantUIActions: true))) else { return XCTFail("d") }
        XCTAssertNil(untrusted.checks.first { $0.name == "action names" }, "no AX reads without trust")
        XCTAssertEqual(untrusted.checks.first { $0.name == "Accessibility" }?.ok, false)

        h.permissions.accessibilityState = .granted
        h.ax.bubbles = []
        guard case .doctor(let empty) = h.call(.doctor(DoctorArgs(wantUIActions: true))) else { return XCTFail("d") }
        XCTAssertNil(empty.checks.first { $0.name == "action names" }, "nothing loaded, nothing to compare")
    }

    func testDoctorReportsForegroundModeAndWhyItTurnedOff() throws {
        let h = try Harness()
        try h.policy.setForegroundMode(true)
        guard case .doctor(let on) = h.call(.doctor(DoctorArgs())) else { return XCTFail("doctor") }
        XCTAssertEqual(on.checks.first { $0.name == "foreground mode" }?.detail, "on")
        h.policy.turnForegroundOff(reason: "Messages came to the front")
        guard case .doctor(let off) = h.call(.doctor(DoctorArgs())) else { return XCTFail("doctor") }
        let mode = try XCTUnwrap(off.checks.first { $0.name == "foreground mode" })
        XCTAssertEqual(mode.detail, "off: Messages came to the front")
        XCTAssertEqual(mode.fix, "imessage allow --foreground")
    }

    func testDoctorAsksForOneKickstartWhenChatDBWontOpenAndNeverPrompts() throws {
        let missing = TempDir.make("imbridge-nodb").appendingPathComponent("chat.db").path
        let h = try Harness(Harness.Options(injectStore: false, chatDBPath: missing))
        h.app.state_ = .notRunning
        guard case .doctor(let before) = h.call(.doctor(DoctorArgs(wantUIActions: true))) else {
            return XCTFail("doctor")
        }
        XCTAssertTrue(before.needsKickstart)
        let check = try XCTUnwrap(before.checks.first { $0.name == "chat.db" })
        XCTAssertFalse(check.ok)
        XCTAssertEqual(check.detail, "not found")
        XCTAssertEqual(h.permissions.calls.filter { $0 != .fullDiskAccess },
                       [.silentAutomation, .accessibility(prompt: false)],
                       "the bridge the kickstart replaces raises no prompt")
        XCTAssertTrue(h.app.calls.isEmpty)

        let afterKickstart = DoctorArgs(wantUIActions: true, afterKickstart: true)
        guard case .doctor(let after) = h.call(.doctor(afterKickstart)) else { return XCTFail("d") }
        XCTAssertFalse(after.needsKickstart)
        XCTAssertEqual(h.permissions.calls.filter { $0 != .fullDiskAccess }.suffix(2),
                       [.silentAutomation, .accessibility(prompt: false)])
        XCTAssertTrue(h.app.calls.isEmpty)
    }

    func testChatDBOpensOnTheFirstRequestAfterAccessIsGranted() throws {
        let copy = try FixtureCopy()
        XCTAssertEqual(chmod(copy.path, 0o000), 0)
        defer { chmod(copy.path, 0o644) }
        let h = try Harness(Harness.Options(injectStore: false, copy: copy))
        XCTAssertEqual(h.call(.chats(ChatsArgs())).failure, WireErrors.noFullDiskAccess)
        XCTAssertEqual(h.send("hi").failure, WireErrors.noFullDiskAccess)
        XCTAssertNil(h.container.db)
        XCTAssertTrue(h.journal.allEntries().isEmpty)

        XCTAssertEqual(chmod(copy.path, 0o644), 0)
        guard case .chats(let page) = h.call(.chats(ChatsArgs())) else { return XCTFail("chats") }
        XCTAssertFalse(page.chats.isEmpty)
        XCTAssertNotNil(h.container.sender)
        XCTAssertNotNil(h.container.tapbacks)
        XCTAssertNotNil(h.container.unsend)
        let opened = h.container.openStoreIfNeeded()
        guard case .ok = opened else { return XCTFail("\(opened)") }
        XCTAssertEqual(h.container.openStoreIfNeeded(), opened, "an open store is never probed again")
    }

    func testAMissingChatDBIsReportedThenFoundOnTheNextRequest() throws {
        let dir = TempDir.make("imbridge-latedb")
        let path = dir.appendingPathComponent("chat.db").path
        let h = try Harness(Harness.Options(injectStore: false, chatDBPath: path))
        let error = try XCTUnwrap(h.call(.chats(ChatsArgs())).failure)
        XCTAssertEqual(error.result.code, .error(.message("chat.db not found")))
        try FileManager.default.copyItem(atPath: h.copy.path, toPath: path)
        guard case .chats = h.call(.chats(ChatsArgs())) else { return XCTFail("chats") }
    }

    func testDoctorCheckLinesForEveryProbe() {
        XCTAssertEqual(DoctorService.chatDBCheck(.ok(messageRows: 3)).detail, "3 messages")
        XCTAssertEqual(DoctorService.chatDBCheck(.notPermitted).fix, "imessage setup")
        XCTAssertEqual(DoctorService.chatDBCheck(.missing).detail, "not found")
        XCTAssertEqual(DoctorService.chatDBCheck(.failed("disk\nI/O")).detail, "disk / I/O")
        for reason: TamperReason in [.fileChangedOutsideBridge, .fileMissing, .fileUnreadable, .hashMissing,
                                     .hashUnreadable] {
            XCTAssertFalse(DoctorService.describe(reason).isEmpty)
        }
    }

    func testABlockingAskAnswersNotDeterminedInTimeAndCallersShareIt() {
        let ask = BoundedAsk(wait: 0.05)
        let release = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var runs = 0
        let body: () -> PermissionState = {
            lock.lock()
            runs += 1
            lock.unlock()
            _ = release.wait(timeout: .now() + 10)
            return .granted
        }
        let start = Date()
        XCTAssertEqual(ask.run(body), .notDetermined)
        XCTAssertEqual(ask.run(body), .notDetermined, "a call while the ask is open waits on the same ask")
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        release.signal()
        XCTAssertTrue(eventually {
            lock.lock()
            defer { lock.unlock() }
            return runs == 1
        })

        let quick = BoundedAsk(wait: 5)
        XCTAssertEqual(quick.run { .granted }, .granted)
        XCTAssertEqual(quick.run { .denied }, .denied, "a finished ask is never reused")
    }

    func testLivePermissionResultsMapToStates() {
        XCTAssertEqual(LivePermissionProbe.state(.ok(messageRows: 1)), .granted)
        XCTAssertEqual(LivePermissionProbe.state(.notPermitted), .denied)
        XCTAssertEqual(LivePermissionProbe.state(.missing), .unknown)
        XCTAssertEqual(LivePermissionProbe.state(.failed("x")), .unknown)
        XCTAssertEqual(LivePermissionProbe.automationState(OSStatus(noErr)), .granted)
        XCTAssertEqual(LivePermissionProbe.automationState(OSStatus(errAEEventNotPermitted)), .denied)
        XCTAssertEqual(LivePermissionProbe.automationState(OSStatus(errAEEventWouldRequireUserConsent)), .notDetermined)
        XCTAssertEqual(LivePermissionProbe.automationState(OSStatus(procNotFound)), .unknown)
        XCTAssertTrue(LivePermissionProbe.fullDiskAccessPane.hasSuffix("Privacy_AllFiles"))
    }
}
