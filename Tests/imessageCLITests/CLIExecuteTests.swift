import XCTest
import IMCore
import IMTestSupport
@testable import imessage

/// Rules: events go to stderr and stdout holds only the rendered result or NDJSON. Exit codes are 0 (the action
/// took effect, is pending, or the answer is a report or list), 1 (error line or failed action), 2 (usage) and 3
/// (nothing reached the bridge).
final class CLIExecuteTests: XCTestCase {
    let ctx = Golden.context

    func testEventsGoToStderrAndStdoutHoldsOnlyTheRender() throws {
        let payload = P.send([P.text(.submitted)], approved: true)
        let events: [BridgeEvent] = [.queued, .approvalShown(id: "ap-1"), .waitingForIdle]
        let bridge = try makeBridge { _ in .reply(events, payload) }
        let run = CLIRun()
        XCTAssertEqual(run.run(["send", "Mom", "On my way"], bridge.client()), 0)
        XCTAssertEqual(run.stdout, Data(Format.render(payload, ctx).utf8))
        XCTAssertEqual(run.stderrText,
                       "waiting for the queue\nwaiting for approval on the Mac\nwaiting until the Mac is idle\n")
    }

    func testJsonPrintsNDJSONAndEveryLineIsJSON() throws {
        let page = try Golden.record(ChatsPage.self, "chats-n5")
        let bridge = try makeBridge { _ in .reply([.queued], .chats(page)) }
        let run = CLIRun()
        XCTAssertEqual(run.run(["chats", "-n", "5", "--json"], bridge.client()), 0)
        XCTAssertEqual(run.stdout, Data(Format.ndjson(.chats(page)).utf8))
        XCTAssertTrue(run.stdoutText.hasSuffix("\n"))
        let lines = run.stdoutText.split(separator: "\n", omittingEmptySubsequences: false).dropLast()
        XCTAssertFalse(lines.isEmpty)
        for line in lines {
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(line.utf8)), String(line))
        }
        XCTAssertEqual(run.stderrText, "waiting for the queue\n")
    }

    /// The bridge's own error line is its answer, so it prints on stdout like any result and exits 1.
    func testBridgeErrorLinePrintsOnStdoutAndExitsOne() throws {
        let payload = P.failure("no chat matches \"Nobody\"", fix: "imessage chats")
        let bridge = try makeBridge { _ in payload }
        let run = CLIRun()
        XCTAssertEqual(run.run(["read", "Nobody"], bridge.client()), 1)
        XCTAssertEqual(run.stdoutText, Format.render(payload, ctx))
        XCTAssertEqual(run.stderrText, "")
    }

    func testExitCodesForEveryResultCode() {
        let tookEffect: [ResultCode] = [.submitted, .delivered, .ok, .already, .pending(id: "ap-1")]
        let failed: [ResultCode] = [.failed(.rowError(22)), .failed(.transferFailed), .ghost,
                                    .ambiguous(.twoRowsMatched), .mayHaveCompleted, .expired, .denied(.user),
                                    .denied(.approvalExpired), .busy(.queue), .busy(.messagesOpen), .notLoaded,
                                    .notDownloaded, .unsupported, .unsupportedTarget, .untested, .noHiddenWindow,
                                    .aborted(.userTookOver), .timeout, .error(.wrongChat), .error(.severalMatches)]
        for code in tookEffect {
            XCTAssertEqual(Output.exitCode(for: P.send([P.text(code)])), .ok, "\(code)")
            XCTAssertEqual(Output.exitCode(for: P.ui(code)), .ok, "\(code)")
            XCTAssertEqual(Output.exitCode(for: P.policy(code)), .ok, "\(code)")
        }
        for code in failed {
            XCTAssertEqual(Output.exitCode(for: P.send([P.text(code)])), .failure, "\(code)")
            XCTAssertEqual(Output.exitCode(for: P.ui(code)), .failure, "\(code)")
            XCTAssertEqual(Output.exitCode(for: P.policy(code)), .failure, "\(code)")
        }
    }

    func testSendExitsZeroOnlyWhenEveryPartTookEffect() {
        let file = SendPartOutcome(part: .file, result: ActionResult(.failed(.transferFailed)), rowid: 9)
        XCTAssertEqual(Output.exitCode(for: P.send([P.text(.submitted), file])), .failure)
        XCTAssertEqual(Output.exitCode(for: P.send([P.text(.submitted), P.text(.delivered)])), .ok)
        XCTAssertEqual(Output.exitCode(for: P.send([])), .failure)
        XCTAssertEqual(Output.exitCode(for: P.send([], early: ActionResult(.denied(.user)))), .failure)
        XCTAssertEqual(Output.exitCode(for: P.send([], early: ActionResult(.pending(id: "ap-2")))), .ok)
        XCTAssertEqual(Output.exitCode(for: P.send([], early: ActionResult(.already))), .ok)
    }

    func testExitCodesForReportsListsAndLookups() throws {
        let att = AttachmentRecord(rowid: 9904, guid: "g", kind: .photo, transferName: "IMG.HEIC", totalBytes: 5)
        XCTAssertEqual(Output.exitCode(for: .attachment(AttachmentExport(attachment: att, path: "/tmp/a.jpg",
                                                                         converted: true, result: nil))), .ok)
        XCTAssertEqual(Output.exitCode(for: .attachment(AttachmentExport(attachment: att, path: nil, converted: false,
                                                                         result: ActionResult(.notDownloaded)))),
                       .failure)
        XCTAssertEqual(Output.exitCode(for: .attachment(AttachmentExport(attachment: att, path: "", converted: false,
                                                                         result: nil))), .failure)
        XCTAssertEqual(Output.exitCode(for: .contacts(ContactsPage(query: "Zed", contacts: []))), .failure)
        XCTAssertEqual(Output.exitCode(for: .contacts(try Golden.record(ContactsPage.self, "who-mom"))), .ok)
        XCTAssertEqual(Output.exitCode(for: .wait(WaitOutcome(chat: nil, message: nil, timedOut: true))), .ok)
        XCTAssertEqual(Output.exitCode(for: .pending(PendingList(items: []))), .ok)
        XCTAssertEqual(Output.exitCode(for: P.doctor([DoctorCheck(name: "x", ok: false)])), .ok)
        XCTAssertEqual(Output.exitCode(for: P.setup(.automation, .denied)), .ok)
        XCTAssertEqual(Output.exitCode(for: .chats(try Golden.record(ChatsPage.self, "chats"))), .ok)
        XCTAssertEqual(Output.exitCode(for: P.failure("x")), .failure)
    }

    func testThreadWithFileIsAUsageErrorBeforeAnyConnection() throws {
        let dir = try makeTempDir()
        let path = try dir.file("a.pdf", Data("x".utf8))
        let bridge = try makeBridge { _ in P.send([P.text(.submitted)]) }
        let run = CLIRun()
        XCTAssertEqual(run.run(["send", "Mom", "yes", "--thread", "--file", path], bridge.client()), 2)
        XCTAssertEqual(run.stderrText,
                       "error: --thread can't be combined with --file fix: send the file and the reply separately\n")
        XCTAssertEqual(run.stderrText, ActionResult.threadWithFile.rendered + "\n")
        XCTAssertEqual(run.stdoutText, "")
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(bridge.connections, 0)
    }

    func testUsageErrorsExitTwoOnStderrWithoutConnecting() throws {
        let bridge = try makeBridge { _ in P.pong }
        for args in [["chats", "-n", "0"], ["bogus"], [], ["send", "Mom"], ["react", "1", "nope"], ["read"],
                     ["read", "7", "--since", "someday"]] {
            let run = CLIRun()
            XCTAssertEqual(run.run(args, bridge.client()), 2, "\(args)")
            XCTAssertEqual(run.stdoutText, "", "\(args)")
            XCTAssertTrue(run.stderrText.hasPrefix("error: "), "\(args)")
            XCTAssertEqual(run.stderrText.filter { $0 == "\n" }.count, 1, "\(args)")
        }
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(bridge.connections, 0)
    }

    func testUnreachableBridgeExitsThreeWithNothingOnStdout() {
        let client = BridgeClient(paths: Paths(home: FakeBridge.makeHome()), ownerUID: getuid())
        for args in [["chats"], ["send", "Mom", "hi"], ["setup"], ["doctor"]] {
            let run = CLIRun()
            XCTAssertEqual(run.run(args, client), 3, "\(args)")
            XCTAssertEqual(run.stdoutText, "", "\(args)")
            XCTAssertTrue(run.stderrText.hasPrefix("error: the bridge isn't running fix: launchctl bootstrap gui/"),
                          run.stderrText)
            XCTAssertEqual(run.kickstarts, 0)
        }
    }

    func testHelpPrintsWithoutConnecting() {
        let client = BridgeClient(paths: Paths(home: FakeBridge.makeHome()), ownerUID: getuid())
        for args in [["help"], ["--help"], ["-h"]] {
            let run = CLIRun()
            XCTAssertEqual(run.run(args, client), 0, "\(args)")
            XCTAssertEqual(run.stdoutText, ArgumentParser.helpText(nil))
            XCTAssertEqual(run.stderrText, "")
        }
        for args in [["help", "send"], ["send", "--help"]] {
            let run = CLIRun()
            XCTAssertEqual(run.run(args, client), 0, "\(args)")
            XCTAssertEqual(run.stdoutText, ArgumentParser.helpText("send"))
            XCTAssertTrue(run.stdoutText.contains("send <who>"))
        }
    }

    func testWhoWithNoMatchExitsOne() throws {
        let empty = ResponsePayload.contacts(ContactsPage(query: "Zed", contacts: []))
        let bridge = try makeBridge { _ in empty }
        let run = CLIRun()
        XCTAssertEqual(run.run(["who", "Zed"], bridge.client()), 1)
        XCTAssertEqual(run.stdoutText, Format.render(empty, ctx))
    }

    func testWaitThatTimedOutExitsZero() throws {
        let timedOut = ResponsePayload.wait(WaitOutcome(chat: nil, message: nil, timedOut: true))
        let bridge = try makeBridge { _ in timedOut }
        let run = CLIRun()
        XCTAssertEqual(run.run(["wait", "--timeout", "1"], bridge.client()), 0)
        XCTAssertEqual(run.stdoutText, Format.render(timedOut, ctx))
        XCTAssertEqual(bridge.requests.map(\.body), [.wait(WaitArgs(fromWho: nil, timeout: 1))])
    }

    func testPendingApprovalExitsZero() throws {
        let payload = P.send([], early: ActionResult(.pending(id: "ap-9")))
        let bridge = try makeBridge { _ in .reply([.approvalShown(id: "ap-9")], payload) }
        let run = CLIRun()
        XCTAssertEqual(run.run(["send", "Mom", "hi"], bridge.client()), 0)
        XCTAssertEqual(run.stdoutText, Format.render(payload, ctx))
        XCTAssertEqual(run.stderrText, "waiting for approval on the Mac\n")
    }

    func testFailedUIActionExitsOne() throws {
        let payload = P.ui(.busy(.messagesOpen))
        let bridge = try makeBridge { _ in payload }
        let run = CLIRun()
        XCTAssertEqual(run.run(["react", "41418", "heart"], bridge.client()), 1)
        XCTAssertEqual(run.stdoutText, Format.render(payload, ctx))
    }

    func testOutputTimesUseTheCallersClockAndZone() throws {
        let page = try Golden.record(ChatsPage.self, "chats")
        let bridge = try makeBridge { _ in .chats(page) }
        let run = CLIRun()
        let utc = TimeZone(identifier: "UTC")!
        let env = run.environment(bridge.client(), now: Fixture.now, timeZone: utc)
        XCTAssertEqual(CLI.run(arguments: ["chats"], environment: env), 0)
        XCTAssertEqual(run.stdoutText, Format.render(.chats(page), FormatContext(now: Fixture.now, timeZone: utc)))
    }

    /// An error the CLI doesn't name still prints as an error line with a fix.
    func testUnexpectedErrorsGetAnErrorLineWithAFix() {
        struct Odd: Error, CustomStringConvertible { var description: String { "something odd" } }
        XCTAssertEqual(Output.unexpected(Odd()).rendered,
                       "error: something odd fix: retry, and run imessage doctor if it happens again")
    }

    func testShellQuoteLeavesSafePathsAndQuotesTheRest() {
        XCTAssertEqual(Output.shellQuote("/Users/a/Library/LaunchAgents/x.plist"), "/Users/a/Library/LaunchAgents/x.plist")
        XCTAssertEqual(Output.shellQuote("/Users/a b/x.plist"), "'/Users/a b/x.plist'")
        XCTAssertEqual(Output.shellQuote("/Users/o'neil/x"), "'/Users/o'\\''neil/x'")
        XCTAssertEqual(Output.shellQuote(""), "''")
    }
}
