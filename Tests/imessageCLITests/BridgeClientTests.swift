import XCTest
import IMCore
import IMTestSupport
@testable import imessage

/// Rule: the client refuses the socket unless its owner uid is ours, and it reaches the bridge only through the
/// Unix socket with `FrameChannel`: one request, events, then one response, all within the response wait.
final class BridgeClientTests: XCTestCase {
    func caps() -> Request { Request(body: .caps) }

    func runCaps(_ client: BridgeClient, timeout: TimeInterval = 5) throws -> Response {
        try client.run(caps(), upload: nil, readTimeout: timeout, onEvent: { _ in })
    }

    func testRunsOneRequestAndReturnsItsResponse() throws {
        let bridge = try makeBridge { _ in P.pong }
        let request = caps()
        let response = try bridge.client().run(request, upload: nil, readTimeout: 5, onEvent: { _ in })
        XCTAssertEqual(response.id, request.id)
        XCTAssertEqual(response.payload, P.pong)
        XCTAssertEqual(bridge.requests, [request])
    }

    func testSocketOwnedByAnotherUserIsRefusedBeforeConnecting() throws {
        let bridge = try makeBridge { _ in P.pong }
        let client = bridge.client(ownerUID: getuid() + 1)
        XCTAssertThrowsError(try runCaps(client)) { XCTAssertEqual($0 as? ClientError, .wrongOwner) }
        let run = CLIRun()
        XCTAssertEqual(run.run(["caps"], client), 3)
        XCTAssertEqual(run.stderrText, "error: the bridge socket \(bridge.socketPath) belongs to another user "
                       + "fix: delete it, then run install.sh again\n")
        XCTAssertEqual(run.stdoutText, "")
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(bridge.connections, 0)
    }

    /// `lstat` sees the link itself, so a symlink to a real socket is refused rather than followed.
    func testSymlinkOrPlainFileAtTheSocketPathIsRefused() throws {
        let real = try makeBridge { _ in P.pong }
        let home = FakeBridge.makeHome()
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let paths = Paths(home: home)
        let path = try paths.resolvedSocketPath()
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        XCTAssertEqual(symlink(real.socketPath, path), 0)
        let client = BridgeClient(paths: paths, ownerUID: getuid())
        XCTAssertThrowsError(try runCaps(client)) { XCTAssertEqual($0 as? ClientError, .notSocket) }
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(real.connections, 0)

        unlink(path)
        XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: Data("x".utf8)))
        XCTAssertThrowsError(try runCaps(client)) { XCTAssertEqual($0 as? ClientError, .notSocket) }
        let run = CLIRun()
        XCTAssertEqual(run.run(["chats"], client), 3)
        XCTAssertEqual(run.stderrText, "error: \(path) isn't a socket fix: delete it, then run install.sh again\n")
    }

    func testMissingSocketMeansTheBridgeIsNotRunning() throws {
        let home = FakeBridge.makeHome()
        let client = BridgeClient(paths: Paths(home: home), ownerUID: getuid())
        XCTAssertThrowsError(try runCaps(client)) { XCTAssertEqual($0 as? ClientError, .bridgeNotRunning) }
        let run = CLIRun()
        XCTAssertEqual(run.run(["chats"], client), 3)
        let plist = Paths(home: home).launchAgentPlist.path
        XCTAssertEqual(run.stderrText, "error: the bridge isn't running "
                       + "fix: launchctl bootstrap gui/\(getuid()) \(Output.shellQuote(plist)), or run install.sh again\n")
    }

    /// A socket file left behind by a bridge that exited refuses connections.
    func testStaleSocketMeansTheBridgeIsNotRunning() throws {
        let bridge = try makeBridge { _ in P.pong }
        let paths = bridge.paths
        let path = bridge.socketPath
        let fd = try FakeBridge.listen(at: path)
        close(fd)
        XCTAssertThrowsError(try runCaps(BridgeClient(paths: paths, ownerUID: getuid()))) {
            XCTAssertEqual($0 as? ClientError, .bridgeNotRunning)
        }
    }

    /// A home whose primary socket path is over 104 bytes uses `~/.imessage-agent/bridge.sock`, the same rule
    /// launchd uses.
    func testLongHomeUsesTheFallbackSocketPath() throws {
        let long = FakeBridge.makeHome().appendingPathComponent(String(repeating: "h", count: 40), isDirectory: true)
        let paths = Paths(home: long)
        XCTAssertGreaterThan(paths.primarySocketPath.utf8.count, Paths.maxSocketPathBytes)
        let bridge = try makeBridge(home: long) { _ in P.pong }
        XCTAssertEqual(bridge.socketPath, long.appendingPathComponent(".imessage-agent/bridge.sock").path)
        XCTAssertEqual(try bridge.client().socketPath(), bridge.socketPath)
        XCTAssertEqual(try runCaps(bridge.client()).payload, P.pong)
    }

    func testEventsReachOnEventInOrderBeforeTheResponse() throws {
        let events: [BridgeEvent] = [.queued, .approvalShown(id: "ap-1"), .waitingForIdle]
        let bridge = try makeBridge { _ in .reply(events, P.pong) }
        var seen: [BridgeEvent] = []
        let r = try bridge.client().run(caps(), upload: nil, readTimeout: 5) { seen.append($0) }
        XCTAssertEqual(seen, events)
        XCTAssertEqual(r.payload, P.pong)
    }

    func testResponseFromAnotherProtocolVersionIsRefused() throws {
        let bridge = try makeBridge { _ in .version(2, P.pong) }
        XCTAssertThrowsError(try runCaps(bridge.client())) { XCTAssertEqual($0 as? ClientError, .protocolMismatch(2)) }
        let run = CLIRun()
        XCTAssertEqual(run.run(["caps"], bridge.client()), 1)
        XCTAssertEqual(run.stderrText, "error: the bridge speaks protocol 2, this CLI speaks 1 "
                       + "fix: install the app and the CLI from the same release\n")
    }

    func testSilentBridgeTimesOutAtTheResponseWait() throws {
        let bridge = try makeBridge { _ in .hang }
        let start = Date()
        XCTAssertThrowsError(try runCaps(bridge.client(), timeout: 0.4)) {
            XCTAssertEqual($0 as? ClientError, .noResponse("no answer in time"))
        }
        let took = Date().timeIntervalSince(start)
        XCTAssertGreaterThanOrEqual(took, 0.35)
        XCTAssertLessThan(took, 3)
    }

    /// Events don't restart the clock: the wait covers the whole exchange.
    func testEventsForeverCantExtendTheResponseWait() throws {
        let bridge = try makeBridge { _ in .eventsForever(.queued, every: 0.01) }
        var count = 0
        let start = Date()
        XCTAssertThrowsError(try bridge.client().run(caps(), upload: nil, readTimeout: 0.5) { _ in count += 1 }) {
            XCTAssertEqual($0 as? ClientError, .noResponse("no answer in time"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertGreaterThan(count, 2)
    }

    /// The request reached the bridge, so a mutation may have run. The fix asks for a plain repeat, which returns
    /// the first result, and never for `--again`.
    func testClosedWithoutAnswerIsNoResponseAndNeverSuggestsAgain() throws {
        let bridge = try makeBridge { _ in .close }
        XCTAssertThrowsError(try runCaps(bridge.client())) {
            XCTAssertEqual($0 as? ClientError, .noResponse("the bridge closed the connection"))
        }
        let send = CLIRun()
        XCTAssertEqual(send.run(["send", "Mom", "hi", "--again"], bridge.client()), 1)
        XCTAssertEqual(send.stderrText, "error: no answer from the bridge: the bridge closed the connection "
                       + "fix: repeat the command without --again to get its result\n")
        let read = CLIRun()
        XCTAssertEqual(read.run(["chats"], bridge.client()), 1)
        XCTAssertEqual(read.stderrText, "error: no answer from the bridge: the bridge closed the connection "
                       + "fix: retry, and run imessage doctor if it happens again\n")
        for verb in [["react", "1", "heart"], ["unsend", "1"], ["edit", "1", "x"], ["allow", "Mom"], ["revoke", "Mom"]] {
            let r = CLIRun()
            XCTAssertEqual(r.run(verb, bridge.client()), 1)
            XCTAssertTrue(r.stderrText.hasSuffix("fix: repeat the command without --again to get its result\n"), "\(verb)")
        }
    }

    func testBrokenFramesAreNoResponse() throws {
        var oversized = Data()
        withUnsafeBytes(of: UInt32(Limits.maxFrameBytes + 1).bigEndian) { oversized.append(contentsOf: $0) }
        let garbage = try FrameCodec.encode(["not": "a frame"])
        let cases: [(Data, String)] = [
            (Data([0, 0, 0, 40]) + Data("{\"response\"".utf8), "the bridge closed the connection"),
            (Data([0, 0]), "the bridge closed the connection"),
            (oversized, "the answer is over \(Limits.maxFrameBytes) bytes"),
            (garbage, "the answer isn't one this CLI can read"),
        ]
        for (bytes, want) in cases {
            let bridge = try makeBridge { _ in .raw(bytes) }
            XCTAssertThrowsError(try runCaps(bridge.client())) {
                XCTAssertEqual($0 as? ClientError, .noResponse(want), "\(Array(bytes.prefix(8)))")
            }
            bridge.stop()
        }
    }

    /// The bridge may refuse a send before it reads the upload, for example an unknown contact. Its answer prints
    /// even though the upload was cut off.
    func testEarlyAnswerDuringTheUploadIsStillRead() throws {
        let dir = try makeTempDir()
        let path = try dir.file("big.bin", Data(repeating: 1, count: 24 * UploadSource.chunkBytes))
        let refusal = P.failure("no chat matches \"Nobody\"", fix: "imessage chats")
        let bridge = try makeBridge { _ in .replyBeforeUpload(refusal) }
        let run = CLIRun()
        let code = run.run(["send", "Nobody", "--file", path], bridge.client())
        XCTAssertEqual(code, 1, run.stderrText)
        XCTAssertEqual(run.stdoutText, Format.render(refusal, Golden.context))
        XCTAssertEqual(run.stderrText, "")
    }

    /// An early answer from another protocol version is still a version mismatch (exit 1), not a request that
    /// never arrived.
    func testEarlyAnswerFromAnotherVersionIsAProtocolMismatch() throws {
        let dir = try makeTempDir()
        let path = try dir.file("big.bin", Data(repeating: 3, count: 24 * UploadSource.chunkBytes))
        let bridge = try makeBridge { _ in .replyBeforeUpload(P.failure("x"), version: 2) }
        let run = CLIRun()
        XCTAssertEqual(run.run(["send", "Mom", "--file", path], bridge.client()), 1)
        XCTAssertEqual(run.stderrText, "error: the bridge speaks protocol 2, this CLI speaks 1 "
                       + "fix: install the app and the CLI from the same release\n")
        XCTAssertEqual(run.stdoutText, "")
    }

    /// A bridge that closes during the upload without answering got a short upload. It ran nothing, so the exit is 3.
    func testClosedDuringTheUploadWithoutAnswerIsRequestNotDelivered() throws {
        let dir = try makeTempDir()
        let path = try dir.file("big.bin", Data(repeating: 4, count: 24 * UploadSource.chunkBytes))
        let bridge = try makeBridge { _ in .closeBeforeUpload }
        let run = CLIRun()
        XCTAssertEqual(run.run(["send", "Mom", "--file", path], bridge.client()), 3)
        XCTAssertEqual(run.stderrText, "error: the request didn't reach the bridge: the bridge closed the connection "
                       + "during the upload fix: retry, and run imessage doctor if it happens again\n")
        XCTAssertEqual(run.stdoutText, "")
    }

    /// The live client checks the socket against the caller's own uid.
    func testTheDefaultOwnerIsTheCallingUser() {
        let client = BridgeClient(paths: Paths(home: FakeBridge.makeHome()))
        XCTAssertEqual(client.ownerUID, getuid())
        XCTAssertEqual(client.writeTimeout, BridgeClient.defaultWriteTimeout)
    }

    /// A bridge that never reads the upload fills the socket buffer. The write timeout ends the send, and nothing
    /// ran, so the exit is 3.
    func testStalledUploadIsRequestNotDelivered() throws {
        let dir = try makeTempDir()
        let source = try UploadSource(path: try dir.file("big.bin", Data(repeating: 2, count: 8 * UploadSource.chunkBytes)))
        let bridge = try makeBridge { _ in .ignoreUpload }
        var request = Request(body: .send(SendArgs(who: "Mom", text: nil)))
        request.upload = source.header
        let start = Date()
        XCTAssertThrowsError(try bridge.client(writeTimeout: 0.3).run(request, upload: source, readTimeout: 5,
                                                                      onEvent: { _ in })) { e in
            XCTAssertEqual(e as? ClientError, .requestNotDelivered("timed out"))
            XCTAssertEqual((e as? ClientError).map(Output.exitCode(for:)), .bridgeUnavailable)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
    }

    /// The client keeps no state between calls, so concurrent requests on one client each get their own answer.
    func testConcurrentRequestsEachGetTheirOwnResponse() throws {
        let bridge = try makeBridge { r in
            guard case .contacts(let a) = r.body else { return P.failure("unexpected") }
            return .contacts(ContactsPage(query: a.name, contacts: []))
        }
        let client = bridge.client()
        let n = 16
        let lock = NSLock()
        var got: [Int: String] = [:]
        DispatchQueue.concurrentPerform(iterations: n) { i in
            let r = try? client.run(Request(body: .contacts(ContactsArgs(name: "name\(i)"))), upload: nil,
                                    readTimeout: 10, onEvent: { _ in })
            if case .contacts(let p)? = r?.payload { lock.withLock { got[i] = p.query } }
        }
        XCTAssertEqual(got.count, n)
        for i in 0..<n { XCTAssertEqual(got[i], "name\(i)") }
        XCTAssertEqual(bridge.requests.count, n)
    }

    func testOnlyErrorsBeforeDeliveryAreExitThree() {
        let before: [ClientError] = [.bridgeNotRunning, .wrongOwner, .notSocket, .io("x"), .requestNotDelivered("x")]
        let after: [ClientError] = [.noResponse("x"), .protocolMismatch(2), .uploadFailed("x")]
        XCTAssertTrue(before.allSatisfy { Output.exitCode(for: $0) == .bridgeUnavailable })
        XCTAssertTrue(after.allSatisfy { Output.exitCode(for: $0) == .failure })
        XCTAssertEqual(ExitCode.bridgeUnavailable.rawValue, 3)
    }
}
