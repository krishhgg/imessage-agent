import XCTest
import IMCore
import IMTestSupport
@testable import imessage

/// Rules: `setup` sends the Full Disk Access stage and returns at once. `doctor [--ui]` runs the kickstart once if
/// the bridge says it needs it, then raises the Automation prompt, and Accessibility with `--ui`. `DoctorFlow.run`
/// takes the kickstart as a closure, so tests record it and never restart a bridge.
final class FlowTests: XCTestCase {
    let target = Paths.launchdServiceTarget()
    let fda = DoctorCheck(name: "Full Disk Access", ok: true, detail: "granted")

    /// Answers `doctor` with `report` and every `setup` stage with `prompts[stage]`, granted by default.
    func doctorBridge(report: @escaping (DoctorArgs) -> FakeBridge.Script,
                      prompts: [SetupStage: PermissionState] = [:]) throws -> FakeBridge {
        try makeBridge { r in
            switch r.body {
            case .doctor(let a): return report(a)
            case .setup(let a): return .reply([], P.setup(a.stage, prompts[a.stage] ?? .granted))
            default: return .reply([], P.failure("unexpected request"))
            }
        }
    }

    func bodies(_ b: FakeBridge) -> [RequestBody] { b.requests.map(\.body) }

    func testSetupSendsOnlyTheFullDiskAccessStage() throws {
        let report = P.setup(.fullDiskAccess, .notDetermined, pane: "Full Disk Access")
        let bridge = try makeBridge { _ in report }
        let run = CLIRun()
        XCTAssertEqual(run.run(["setup"], bridge.client()), 0)
        XCTAssertEqual(bodies(bridge), [.setup(SetupArgs(stage: .fullDiskAccess))])
        XCTAssertEqual(run.stdoutText, Format.render(report, Golden.context))
        XCTAssertEqual(run.kickstarts, 0)
    }

    func testDoctorWithoutUIRaisesOnlyTheAutomationPrompt() throws {
        let bridge = try doctorBridge(report: { _ in .reply([], P.doctor([self.fda])) })
        let run = CLIRun()
        XCTAssertEqual(run.run(["doctor"], bridge.client()), 0)
        XCTAssertEqual(bodies(bridge), [.doctor(DoctorArgs(wantUIActions: false, afterKickstart: false)),
                                        .setup(SetupArgs(stage: .automation))])
        let want = P.doctor([fda, DoctorCheck(name: "Automation prompt", ok: true, detail: "granted")])
        XCTAssertEqual(run.stdoutText, Format.render(want, Golden.context))
        XCTAssertEqual(run.kickstarts, 0)
    }

    func testDoctorWithUIAlsoRaisesTheAccessibilityPrompt() throws {
        let bridge = try doctorBridge(report: { _ in .reply([], P.doctor([self.fda])) },
                                      prompts: [.accessibility: .notDetermined])
        let payload = try DoctorFlow.run(client: bridge.client(), wantUIActions: true, kickstart: { false },
                                         pause: { _ in })
        XCTAssertEqual(bodies(bridge), [.doctor(DoctorArgs(wantUIActions: true, afterKickstart: false)),
                                        .setup(SetupArgs(stage: .automation)),
                                        .setup(SetupArgs(stage: .accessibility))])
        XCTAssertEqual(payload, P.doctor([
            fda,
            DoctorCheck(name: "Automation prompt", ok: true, detail: "granted"),
            DoctorCheck(name: "Accessibility prompt", ok: true, detail: "asked, answer the prompt on the Mac"),
        ]))
    }

    func testKickstartRunsOnceWhenTheBridgeAsksAndTheSecondDoctorSaysSo() throws {
        let after = DoctorCheck(name: "Full Disk Access", ok: true, detail: "granted after restart")
        let bridge = try doctorBridge(report: { a in
            // Still asks for a kickstart after one ran, to prove the flow doesn't loop.
            .reply([], P.doctor(a.afterKickstart ? [after] : [self.fda], needsKickstart: true))
        })
        let run = CLIRun()
        XCTAssertEqual(run.run(["doctor"], bridge.client()), 0)
        XCTAssertEqual(run.kickstarts, 1)
        XCTAssertEqual(bodies(bridge), [.doctor(DoctorArgs(wantUIActions: false, afterKickstart: false)),
                                        .doctor(DoctorArgs(wantUIActions: false, afterKickstart: true)),
                                        .setup(SetupArgs(stage: .automation))])
        let want = P.doctor([DoctorCheck(name: "restart", ok: true, detail: "ran launchctl kickstart -k \(target)"),
                             after, DoctorCheck(name: "Automation prompt", ok: true, detail: "granted")],
                            needsKickstart: true)
        XCTAssertEqual(run.stdoutText, Format.render(want, Golden.context))
        XCTAssertTrue(run.paused.isEmpty)
    }

    func testNoKickstartUnlessTheBridgeAsks() throws {
        let bridge = try doctorBridge(report: { _ in .reply([], P.doctor([self.fda], needsKickstart: false)) })
        var kicks = 0
        _ = try DoctorFlow.run(client: bridge.client(), wantUIActions: false, kickstart: { kicks += 1; return true },
                               pause: { _ in })
        XCTAssertEqual(kicks, 0)
    }

    /// The restarted job takes a moment; the flow retries, `reconnectDelay` apart, until the bridge answers.
    func testWaitsForTheRestartedBridge() throws {
        let refusals = Countdown(3)
        let bridge = try doctorBridge(report: { a in
            if a.afterKickstart, refusals.take() { return .close }
            return .reply([], P.doctor([self.fda], needsKickstart: !a.afterKickstart))
        })
        let run = CLIRun()
        XCTAssertEqual(run.run(["doctor"], bridge.client()), 0)
        XCTAssertEqual(run.kickstarts, 1)
        XCTAssertEqual(run.paused, [0.5, 0.5, 0.5])
        XCTAssertEqual(bodies(bridge).filter { $0 == .doctor(DoctorArgs(afterKickstart: true)) }.count, 4)
        XCTAssertTrue(run.stdoutText.contains("restart"))
        XCTAssertEqual(bodies(bridge).last, .setup(SetupArgs(stage: .automation)))
    }

    func testGivesUpAfterTheLastReconnectAndRaisesNoPrompts() throws {
        let bridge = try doctorBridge(report: { a in
            a.afterKickstart ? .close : .reply([], P.doctor([self.fda], needsKickstart: true))
        })
        let run = CLIRun()
        let env = run.environment(bridge.client())
        let payload = try DoctorFlow.run(client: env.client, wantUIActions: true, kickstart: env.kickstart,
                                         pause: env.pause)
        XCTAssertEqual(run.kickstarts, 1)
        XCTAssertEqual(run.paused.count, DoctorFlow.reconnectAttempts - 1)
        XCTAssertEqual(bodies(bridge).count, 1 + DoctorFlow.reconnectAttempts)
        XCTAssertFalse(bodies(bridge).contains { if case .setup = $0 { return true } else { return false } })
        XCTAssertEqual(payload, P.doctor([
            DoctorCheck(name: "restart", ok: false, detail: "the bridge didn't answer after launchctl kickstart -k \(target)",
                        fix: "imessage doctor"),
            fda,
        ], needsKickstart: true))
    }

    /// A try that runs out of time isn't repeated, so a hung bridge can't hold the CLI for twenty response waits.
    func testATimedOutTryAfterTheRestartEndsTheRetries() throws {
        let bridge = try doctorBridge(report: { a in
            a.afterKickstart ? .hang : .reply([], P.doctor([self.fda], needsKickstart: true))
        })
        var pauses = 0
        let start = Date()
        let payload = try DoctorFlow.run(client: bridge.client(), wantUIActions: false, kickstart: { true },
                                         pause: { _ in pauses += 1 }, doctorTimeout: 0.3)
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        XCTAssertEqual(pauses, 0)
        XCTAssertEqual(bodies(bridge).count, 2)
        XCTAssertEqual(payload, P.doctor([
            DoctorCheck(name: "restart", ok: false, detail: "the bridge didn't answer after launchctl kickstart -k \(target)",
                        fix: "imessage doctor"),
            fda,
        ], needsKickstart: true))
    }

    func testFailedKickstartIsReportedAndPromptsAreStillRaised() throws {
        let bridge = try doctorBridge(report: { _ in .reply([], P.doctor([self.fda], needsKickstart: true)) })
        let run = CLIRun()
        run.kickstartResult = false
        XCTAssertEqual(run.run(["doctor"], bridge.client()), 0)
        XCTAssertEqual(run.kickstarts, 1)
        XCTAssertEqual(bodies(bridge), [.doctor(DoctorArgs(wantUIActions: false, afterKickstart: false)),
                                        .setup(SetupArgs(stage: .automation))])
        let want = P.doctor([DoctorCheck(name: "restart", ok: false, detail: "launchctl kickstart -k \(target) failed",
                                         fix: "launchctl kickstart -k \(target)"),
                             fda, DoctorCheck(name: "Automation prompt", ok: true, detail: "granted")],
                            needsKickstart: true)
        XCTAssertEqual(run.stdoutText, Format.render(want, Golden.context))
    }

    func testDeniedPromptFailsWithTheSettingsFix() throws {
        let bridge = try doctorBridge(report: { _ in .reply([], P.doctor([])) },
                                      prompts: [.automation: .denied, .accessibility: .denied])
        let payload = try DoctorFlow.run(client: bridge.client(), wantUIActions: true, kickstart: { true },
                                         pause: { _ in })
        XCTAssertEqual(payload, P.doctor([
            DoctorCheck(name: "Automation prompt", ok: false, detail: "denied",
                        fix: "turn on iMessage Agent in System Settings > Privacy & Security > Automation"),
            DoctorCheck(name: "Accessibility prompt", ok: false, detail: "denied",
                        fix: "turn on iMessage Agent in System Settings > Privacy & Security > Accessibility"),
        ]))
    }

    func testOpenedPaneIsNamedInThePromptCheck() throws {
        let bridge = try makeBridge { r in
            if case .setup(let a) = r.body { return P.setup(a.stage, .notDetermined, pane: "Automation") }
            return P.doctor([])
        }
        XCTAssertEqual(DoctorFlow.promptCheck(.automation, client: bridge.client()),
                       DoctorCheck(name: "Automation prompt", ok: true,
                                   detail: "asked, answer the prompt on the Mac, opened Automation"))
    }

    /// A prompt request that fails becomes a failing check, so the report the bridge already gave still prints.
    func testFailedPromptRequestBecomesAFailingCheck() throws {
        let bridge = try makeBridge { r in
            switch r.body {
            case .doctor: return .reply([], P.doctor([self.fda]))
            default: return .close
            }
        }
        let payload = try DoctorFlow.run(client: bridge.client(), wantUIActions: false, kickstart: { true },
                                         pause: { _ in })
        guard case .doctor(let report) = payload else { return XCTFail("\(payload)") }
        XCTAssertEqual(report.checks.first, fda)
        let prompt = try XCTUnwrap(report.checks.last)
        XCTAssertEqual(prompt.name, "Automation prompt")
        XCTAssertFalse(prompt.ok)
        XCTAssertEqual(prompt.fix, "retry, and run imessage doctor if it happens again")

        let failing = try makeBridge { r in
            if case .setup = r.body { return P.failure("no app bundle", fix: "run install.sh again") }
            return P.doctor([])
        }
        XCTAssertEqual(DoctorFlow.promptCheck(.automation, client: failing.client()),
                       DoctorCheck(name: "Automation prompt", ok: false, detail: "error: no app bundle",
                                   fix: "run install.sh again"))
    }

    func testDoctorFailureIsReturnedAsIs() throws {
        let failure = P.failure("the bridge is still starting", fix: "imessage doctor")
        let bridge = try makeBridge { _ in failure }
        let run = CLIRun()
        XCTAssertEqual(run.run(["doctor", "--ui"], bridge.client()), 1)
        XCTAssertEqual(run.stdoutText, Format.render(failure, Golden.context))
        XCTAssertEqual(bodies(bridge), [.doctor(DoctorArgs(wantUIActions: true, afterKickstart: false))])
        XCTAssertEqual(run.kickstarts, 0)
    }

    func testLiveKickstartTargetsTheLaunchAgent() {
        XCTAssertEqual(DoctorFlow.launchctlPath, "/bin/launchctl")
        XCTAssertEqual(DoctorFlow.kickstartArguments(uid: 501),
                       ["kickstart", "-k", "gui/501/\(AppIdentity.launchAgentLabel)"])
        XCTAssertEqual(DoctorFlow.kickstartArguments(), ["kickstart", "-k", target])
        XCTAssertEqual(DoctorFlow.kickstartTimeout, 30)
    }

    /// The kickstart's wait is bounded. These run harmless system tools, never launchctl.
    func testRunToExitIsTrueOnlyForAZeroExitWithinTheTimeout() {
        func process(_ path: String, _ args: [String] = []) -> Process {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            p.standardInput = FileHandle.nullDevice
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            return p
        }
        XCTAssertTrue(DoctorFlow.runToExit(process("/usr/bin/true"), timeout: 5))
        XCTAssertFalse(DoctorFlow.runToExit(process("/usr/bin/false"), timeout: 5))
        XCTAssertFalse(DoctorFlow.runToExit(process("/nonexistent/tool"), timeout: 5))

        let slow = process("/bin/sleep", ["5"])
        let start = Date()
        XCTAssertFalse(DoctorFlow.runToExit(slow, timeout: 0.2))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        slow.waitUntilExit()
        XCTAssertEqual(slow.terminationReason, .uncaughtSignal)
    }

    /// `CLI.execute` hands the doctor flow the environment's kickstart, so the live process gets `liveKickstart`
    /// and tests get the recorder.
    func testExecutePassesTheEnvironmentsKickstart() throws {
        let bridge = try doctorBridge(report: { a in .reply([], P.doctor([], needsKickstart: !a.afterKickstart)) })
        let run = CLIRun()
        var calledInside = false
        run.onKickstart = { calledInside = true }
        let code = CLI.execute(try ArgumentParser.parse(["doctor"]), environment: run.environment(bridge.client()))
        XCTAssertEqual(code, .ok)
        XCTAssertTrue(calledInside)
        XCTAssertEqual(run.kickstarts, 1)
    }
}

/// Says yes the first `n` times `take()` is called, then no. Safe across connection threads.
final class Countdown {
    private let lock = NSLock()
    private var left: Int

    init(_ n: Int) { left = n }

    func take() -> Bool {
        lock.withLock {
            guard left > 0 else { return false }
            left -= 1
            return true
        }
    }
}
