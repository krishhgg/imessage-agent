import Foundation
import XCTest
import IMCore
@testable import IMSend
import IMTestSupport

/// Engine that records what the runner gives it. It never compiles or runs AppleScript.
final class RecordingEngine: AppleScriptEngine {
    private let lock = NSLock()
    private(set) var compiledSources: [String] = []
    private(set) var events: [NSAppleEventDescriptor] = []
    private(set) var onMainThread: [Bool] = []
    private var running = 0
    private(set) var maxConcurrent = 0

    var compileErrors: [NSDictionary?] = []
    var executeResult: (NSAppleEventDescriptor?, NSDictionary?) = (NSAppleEventDescriptor(string: "sent"), nil)
    var executeDelay: TimeInterval = 0

    func compile(_ source: String) -> NSDictionary? {
        lock.lock()
        defer { lock.unlock() }
        compiledSources.append(source)
        onMainThread.append(Thread.isMainThread)
        return compileErrors.isEmpty ? nil : compileErrors.removeFirst()
    }

    func execute(_ event: NSAppleEventDescriptor) -> (result: NSAppleEventDescriptor?, error: NSDictionary?) {
        lock.lock()
        events.append(event)
        onMainThread.append(Thread.isMainThread)
        running += 1
        maxConcurrent = max(maxConcurrent, running)
        lock.unlock()
        if executeDelay > 0 { Thread.sleep(forTimeInterval: executeDelay) }
        lock.lock()
        running -= 1
        lock.unlock()
        return executeResult
    }
}

private func strings(in list: NSAppleEventDescriptor?) -> [String] {
    guard let list, list.numberOfItems > 0 else { return [] }
    return (1...list.numberOfItems).compactMap { list.atIndex($0)?.stringValue }
}

final class ScriptsTests: XCTestCase {
    private let hostile = "he said \"hi\" & (do shell script \"touch /tmp/x\") & \"\nend send_text"

    // MARK: One compiled script

    func testScriptDeclaresEveryHandler() {
        for handler in ScriptHandler.allCases {
            XCTAssertTrue(SendScripts.source.contains("on \(handler.rawValue)("), handler.rawValue)
            XCTAssertTrue(SendScripts.source.contains("end \(handler.rawValue)"), handler.rawValue)
        }
    }

    /// The lines from `on <name>(` through `end <name>`.
    private func handlerBody(_ name: String) -> [String] {
        let lines = SendScripts.source.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = lines.firstIndex(where: { $0.hasPrefix("on \(name)(") }),
              let last = lines[first...].firstIndex(of: "end \(name)") else { return [] }
        return Array(lines[first...last])
    }

    /// The handlers the source declares, in order.
    private func declaredHandlers() -> [String] {
        SendScripts.source.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("on ") }
            .compactMap { $0.dropFirst(3).split(separator: "(").first.map(String.init) }
    }

    private let messagesTell = "tell application id \"com.apple.MobileSMS\""

    /// Each handler's `with timeout` length.
    private let timeouts: [ScriptHandler: TimeInterval] = [
        .sendText: SendScripts.sendEventTimeout,
        .sendFile: SendScripts.sendEventTimeout,
        .sendChatText: SendScripts.sendEventTimeout,
        .sendChatFile: SendScripts.sendEventTimeout,
        .quitMessages: SendScripts.quitEventTimeout,
        .accountReady: SendScripts.accountReadyTimeout,
    ]

    func testGroupHandlersAddressTheChatByIDAndNeverAParticipant() {
        XCTAssertEqual(handlerBody("send_chat_text").first, "on send_chat_text(g, t)")
        XCTAssertTrue(handlerBody("send_chat_text").contains("send t to chat id g"))
        XCTAssertEqual(handlerBody("send_chat_file").first, "on send_chat_file(g, p)")
        XCTAssertTrue(handlerBody("send_chat_file").contains("send f to chat id g"))
        for name in ["send_chat_text", "send_chat_file"] {
            XCTAssertFalse(handlerBody(name).contains { $0.contains("participant") }, name)
        }
    }

    func testSourceDeclaresOnlyTheCalledHandlersAndNoneCallsAnother() {
        let declared = declaredHandlers()
        XCTAssertEqual(declared, ScriptHandler.allCases.map(\.rawValue),
                       "a helper handler would send its Apple Events outside the caller's timeout")
        for handler in declared {
            for other in declared where other != handler {
                XCTAssertFalse(handlerBody(handler).dropFirst().contains { $0.contains("\(other)(") },
                               "\(handler) calls \(other)")
            }
        }
    }

    func testEveryTellToMessagesSitsInsideAWithTimeoutBlock() {
        var depth = 0
        var tells = 0
        for line in SendScripts.source.components(separatedBy: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            if line.hasPrefix("with timeout of ") { depth += 1 }
            if line == "end timeout" { depth -= 1 }
            if line.contains(messagesTell) {
                tells += 1
                XCTAssertGreaterThan(depth, 0, "outside a timeout: \(line)")
            }
            XCTAssertFalse(line.hasPrefix("tell ") && !line.contains(messagesTell), "unexpected target: \(line)")
        }
        XCTAssertEqual(depth, 0)
        XCTAssertEqual(tells, ScriptHandler.allCases.count, "one tell per handler")
    }

    func testEachHandlerBoundsEveryAppleEventItSendsWithItsOwnTimeout() throws {
        for handler in ScriptHandler.allCases {
            let body = handlerBody(handler.rawValue)
            let seconds = try XCTUnwrap(timeouts[handler], handler.rawValue)
            let timeout = "with timeout of \(Int(seconds)) seconds"
            let open = try XCTUnwrap(body.firstIndex(of: timeout), body.joined(separator: "\n"))
            let close = try XCTUnwrap(body.firstIndex(of: "end timeout"), handler.rawValue)
            let tells = body.indices.filter { body[$0].hasPrefix("tell ") }
            XCTAssertEqual(tells.count, 1, handler.rawValue)
            XCTAssertTrue(tells.allSatisfy { $0 > open && $0 < close }, "\(handler.rawValue): tell outside the timeout")
            if handler == .sendText || handler == .sendFile {
                let lookup = try XCTUnwrap(body.firstIndex { $0.contains("1st account whose service type") },
                                           handler.rawValue)
                XCTAssertTrue(lookup > open && lookup < close, "\(handler.rawValue): account lookup outside the timeout")
            }
        }
        XCTAssertLessThan(SendScripts.accountReadyTimeout, Limits.coldStartTimeout)
        XCTAssertLessThan(SendScripts.quitEventTimeout, Limits.quitWait)
    }

    func testEveryHandlerChecksMessagesIsRunningFirst() throws {
        let check = "if not (application id \"com.apple.MobileSMS\" is running) then return \"\(SendScripts.notRunning)\""
        for handler in ScriptHandler.allCases {
            let body = handlerBody(handler.rawValue)
            XCTAssertEqual(body.dropFirst().first, check, "\(handler.rawValue): the running check comes first")
            let checked = try XCTUnwrap(body.firstIndex(of: check), handler.rawValue)
            let tell = try XCTUnwrap(body.firstIndex { $0.hasPrefix("tell ") }, handler.rawValue)
            let timeout = try XCTUnwrap(body.firstIndex { $0.hasPrefix("with timeout of ") }, handler.rawValue)
            XCTAssertLessThan(checked, timeout, handler.rawValue)
            XCTAssertLessThan(checked, tell, handler.rawValue)
            if handler != .accountReady, handler != .quitMessages {
                let send = try XCTUnwrap(body.firstIndex { $0.hasPrefix("send ") }, handler.rawValue)
                XCTAssertLessThan(checked, send, handler.rawValue)
            }
            XCTAssertEqual(body.filter { $0.contains("is running") }.count, 1, handler.rawValue)
        }
        XCTAssertNotEqual(SendScripts.notRunning, "1", "account_ready's not_running must read as not ready")
        XCTAssertFalse(check.contains("tell "), "the check sends Messages no Apple Event, so it can't launch it")
        XCTAssertEqual(SendScripts.notRunning, "not_running")
        XCTAssertNotEqual(SendScripts.notRunning, "sent")
    }

    func testCompilesOnceAcrossManyCalls() {
        let engine = RecordingEngine()
        let runner = NSAppleScriptRunner(source: SendScripts.source, engine: engine)
        for handler in ScriptHandler.allCases + ScriptHandler.allCases {
            _ = runner.call(handler, arguments: ["a"])
        }
        XCTAssertEqual(engine.compiledSources.count, 1)
        XCTAssertEqual(engine.events.count, ScriptHandler.allCases.count * 2)
    }

    func testFailedCompileIsReportedAndRetriedUntilItSucceeds() {
        let engine = RecordingEngine()
        engine.compileErrors = [[NSAppleScript.errorNumber: NSNumber(value: -2741),
                                 NSAppleScript.errorMessage: "syntax"], nil]
        let runner = NSAppleScriptRunner(source: SendScripts.source, engine: engine)

        let first = runner.call(.accountReady, arguments: ["iMessage"])
        XCTAssertFalse(first.ok)
        XCTAssertEqual(first.errorNumber, -2741)
        XCTAssertEqual(first.errorMessage, "syntax")
        XCTAssertTrue(engine.events.isEmpty, "nothing runs without a compiled script")

        XCTAssertTrue(runner.call(.accountReady, arguments: ["iMessage"]).ok)
        _ = runner.call(.accountReady, arguments: ["iMessage"])
        XCTAssertEqual(engine.compiledSources.count, 2)
        XCTAssertEqual(engine.events.count, 2)
    }

    // MARK: Descriptor arguments, never source interpolation

    func testHandlerEventCarriesEachArgumentAsAStringDescriptor() {
        let args = [Handles.mom, hostile, "iMessage"]
        let event = NSAppleScriptRunner.handlerEvent(.sendText, arguments: args)

        XCTAssertEqual(event.eventClass, AppleEventCode.fourCC("ascr"))
        XCTAssertEqual(event.eventID, AppleEventCode.fourCC("psbr"))
        XCTAssertEqual(event.paramDescriptor(forKeyword: AppleEventCode.fourCC("snam"))?.stringValue, "send_text")
        let list = event.paramDescriptor(forKeyword: AppleEventCode.fourCC("----"))
        XCTAssertEqual(list?.descriptorType, AppleEventCode.fourCC("list"))
        XCTAssertEqual(strings(in: list), args)
    }

    func testHandlerEventWithNoArguments() {
        let event = NSAppleScriptRunner.handlerEvent(.quitMessages, arguments: [])
        XCTAssertEqual(event.paramDescriptor(forKeyword: AppleEventCode.fourCC("snam"))?.stringValue, "quit_messages")
        XCTAssertEqual(event.paramDescriptor(forKeyword: AppleEventCode.fourCC("----"))?.numberOfItems, 0)
    }

    func testArgumentsNeverReachTheSource() {
        let engine = RecordingEngine()
        let runner = NSAppleScriptRunner(source: SendScripts.source, engine: engine)
        _ = runner.call(.sendText, arguments: [Handles.mom, hostile, "iMessage"])
        _ = runner.call(.sendFile, arguments: [Handles.mom, "/Users/x/Pictures/a\"b.txt", "SMS"])

        XCTAssertEqual(engine.compiledSources, [SendScripts.source])
        XCTAssertFalse(SendScripts.source.contains("do shell script"))
        XCTAssertEqual(strings(in: engine.events[0].paramDescriptor(forKeyword: AppleEventCode.fourCC("----"))),
                       [Handles.mom, hostile, "iMessage"])
        XCTAssertEqual(engine.events[1].paramDescriptor(forKeyword: AppleEventCode.fourCC("snam"))?.stringValue,
                       "send_file")
    }

    // MARK: Outcomes

    func testResultValueIsPassedBack() {
        let engine = RecordingEngine()
        engine.executeResult = (NSAppleEventDescriptor(string: "1"), nil)
        let outcome = NSAppleScriptRunner(source: SendScripts.source, engine: engine)
            .call(.accountReady, arguments: ["iMessage"])
        XCTAssertTrue(outcome.ok)
        XCTAssertEqual(outcome.value, "1")
        XCTAssertNil(outcome.errorNumber)
    }

    func testExecutionErrorBecomesAFailedOutcome() {
        let engine = RecordingEngine()
        engine.executeResult = (nil, [NSAppleScript.errorNumber: NSNumber(value: -1728),
                                      NSAppleScript.errorMessage: "Can't get account"])
        let outcome = NSAppleScriptRunner(source: SendScripts.source, engine: engine)
            .call(.sendText, arguments: [Handles.mom, "hi", "SMS"])
        XCTAssertFalse(outcome.ok)
        XCTAssertNil(outcome.value)
        XCTAssertEqual(outcome.errorNumber, -1728)
        XCTAssertEqual(outcome.errorMessage, "Can't get account")
    }

    // MARK: Main thread

    func testCallsFromBackgroundThreadsRunOnTheMainThreadOneAtATime() {
        let engine = RecordingEngine()
        engine.executeDelay = 0.002
        let runner = NSAppleScriptRunner(source: SendScripts.source, engine: engine)
        let done = expectation(description: "background calls")
        DispatchQueue.global().async {
            DispatchQueue.concurrentPerform(iterations: 24) { i in
                XCTAssertFalse(Thread.isMainThread)
                _ = runner.call(.sendText, arguments: [Handles.mom, "message \(i)", "iMessage"])
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 10)

        XCTAssertEqual(engine.compiledSources.count, 1)
        XCTAssertEqual(engine.events.count, 24)
        XCTAssertEqual(engine.onMainThread.count, 25)
        XCTAssertTrue(engine.onMainThread.allSatisfy { $0 })
        XCTAssertEqual(engine.maxConcurrent, 1)
    }

    func testCallOnTheMainThreadRunsInline() {
        XCTAssertTrue(Thread.isMainThread)
        let engine = RecordingEngine()
        _ = NSAppleScriptRunner(source: SendScripts.source, engine: engine).call(.quitMessages, arguments: [])
        XCTAssertEqual(engine.onMainThread, [true, true])
    }
}
