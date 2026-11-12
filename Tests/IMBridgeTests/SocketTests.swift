import Foundation
import XCTest
@testable import IMBridge
import IMCore
import IMPolicy
import IMStore
import IMTestSupport

/// A real `SocketServer` on a short temp path in /tmp, with the harness dispatcher behind it. Never the launchd
/// socket. Requests go over `FrameChannel` the way the CLI sends them: the request frame, then any upload bytes, then
/// event frames until the one response.
final class LiveSocket {
    struct Answer {
        var payload: ResponsePayload
        var events: [BridgeEvent]
    }

    struct WrongID: Error {
        var sent: String
        var got: String
    }

    struct SystemError: Error {
        var call: String
        var errno: Int32
    }

    let path: String
    let listenFD: Int32
    let server: SocketServer

    init(handler: RequestHandling, residency: ResidencyGuard?, configure: (SocketServer) -> Void = { _ in }) throws {
        path = "/tmp/imb-\(getpid())-\(UUID().uuidString.prefix(8)).sock"
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SystemError(call: "socket", errno: errno) }
        var addr = LiveSocket.address(path)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let e = errno
            close(fd)
            throw SystemError(call: "bind", errno: e)
        }
        _ = chmod(path, 0o600)
        guard listen(fd, 32) == 0 else {
            let e = errno
            close(fd)
            unlink(path)
            throw SystemError(call: "listen", errno: e)
        }
        listenFD = fd
        server = SocketServer(listenFD: fd, handler: handler)
        server.residency = residency
        server.ioTimeout = 10
        configure(server)
        server.start()
    }

    convenience init(_ h: Harness) throws {
        try self.init(handler: h.dispatcher, residency: h.container.residency)
    }

    /// Stops accepting, gives the cancelled source a moment to let go of the fd, then closes and unlinks it.
    func stop() {
        server.stop()
        Thread.sleep(forTimeInterval: 0.02)
        close(listenFD)
        unlink(path)
    }

    static func address(_ path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        precondition(bytes.count < MemoryLayout.size(ofValue: addr.sun_path), "socket path too long")
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        return addr
    }

    func connect() throws -> FrameChannel {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SystemError(call: "socket", errno: errno) }
        var addr = LiveSocket.address(path)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            let e = errno
            close(fd)
            throw SystemError(call: "connect", errno: e)
        }
        let channel = FrameChannel(fd: fd)
        try channel.setTimeouts(read: 30, write: 30)
        return channel
    }

    /// One request on its own connection, as the CLI makes it.
    func round(_ body: RequestBody, upload: Data? = nil, fileName: String = "note.txt",
               id: String = UUID().uuidString) throws -> Answer {
        let channel = try connect()
        defer { channel.close() }
        let header = upload.map { UploadHeader(byteCount: Int64($0.count), fileName: fileName) }
        try channel.writeFrame(Request(id: id, body: body, upload: header))
        if let upload { try channel.writeRaw(upload) }
        var events: [BridgeEvent] = []
        while true {
            switch try channel.readFrame(ServerFrame.self) {
            case .event(let event):
                events.append(event)
            case .response(let response):
                guard response.id == id else { throw WrongID(sent: id, got: response.id) }
                return Answer(payload: response.payload, events: events)
            }
        }
    }
}

/// Counts the requests that reach the handler. Answers `pong` unless it wraps a real handler.
final class CountingHandler: RequestHandling {
    private let lock = NSLock()
    private var seen: [Request] = []
    let inner: RequestHandling?

    init(_ inner: RequestHandling? = nil) { self.inner = inner }

    var requests: [Request] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }

    func handle(_ request: Request, upload: UploadReading?, events: @escaping (BridgeEvent) -> Void,
                peerGone: @escaping () -> Bool) -> Response {
        lock.lock()
        seen.append(request)
        lock.unlock()
        if let inner { return inner.handle(request, upload: upload, events: events, peerGone: peerGone) }
        return Response(id: request.id, payload: .pong(PongInfo(bridgeVersion: "test", pid: 0)))
    }
}

/// Holds each request until `release` is signalled.
final class GateHandler: RequestHandling {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)

    func handle(_ request: Request, upload: UploadReading?, events: @escaping (BridgeEvent) -> Void,
                peerGone: @escaping () -> Bool) -> Response {
        entered.signal()
        _ = release.wait(timeout: .now() + 20)
        return Response(id: request.id, payload: .pong(PongInfo(bridgeVersion: "test", pid: 0)))
    }
}

/// The bridge end to end over a real socket: every read verb, sends through the dialog, idempotency, rate limits,
/// uploads, crash recovery and the connection rules.
final class SocketTests: XCTestCase {
    private func send(_ text: String?, again: Bool = false, approvalWait: TimeInterval = 120) -> RequestBody {
        .send(SendArgs(who: Mom.who, text: text, again: again, approvalWait: approvalWait))
    }

    // MARK: - Reads

    func testEveryReadVerbAnswersOverTheSocketAsItDoesInProcess() throws {
        let h = try Harness()
        let live = try LiveSocket(h)
        defer { live.stop() }
        let bodies: [RequestBody] = [
            .chats(ChatsArgs(limit: 5)), .unread(UnreadArgs()), .messages(MessagesArgs(who: Mom.who, limit: 5)),
            .message(MessageArgs(rowid: 41_556)), .search(SearchArgs(text: "dinner")),
            .contacts(ContactsArgs(name: "Mom")), .changes(ChangesArgs()), .pending(PendingArgs()), .caps, .status,
            .ping,
        ]
        for body in bodies {
            let answer = try live.round(body)
            XCTAssertEqual(answer.payload, h.call(body), "\(body.op)")
            XCTAssertTrue(answer.events.isEmpty)
            if case .failure(let error) = answer.payload { XCTFail("\(body.op): \(error)") }
        }
        XCTAssertTrue(h.scripts.calls.isEmpty)
        XCTAssertTrue(h.presenter.prompts.isEmpty)
    }

    func testConcurrentReadsOnSeparateConnectionsAllAnswer() throws {
        let h = try Harness()
        let live = try LiveSocket(h)
        defer { live.stop() }
        let bodies: [RequestBody] = [.messages(MessagesArgs(who: Mom.who, limit: 20)), .chats(ChatsArgs()),
                                     .search(SearchArgs(text: "dinner"))]
        let expected = bodies.map { h.call($0) }
        let lock = NSLock()
        var mismatches: [String] = []
        DispatchQueue.concurrentPerform(iterations: 24) { i in
            let k = i % bodies.count
            let payload = (try? live.round(bodies[k]))?.payload
            if payload != expected[k] {
                lock.lock()
                mismatches.append("\(i)")
                lock.unlock()
            }
        }
        XCTAssertEqual(mismatches, [])
        XCTAssertTrue(eventually { live.server.activeConnections == 0 })
    }

    // MARK: - Sends

    func testAnApprovedSendReportsTheDialogThenReplaysAndAgainSendsOnceMore() throws {
        let h = try Harness()
        let live = try LiveSocket(h)
        defer { live.stop() }
        let first = try live.round(send("On my way"))
        let outcome = try XCTUnwrap(first.payload.sendOutcome)
        XCTAssertTrue(outcome.approved)
        XCTAssertEqual(outcome.parts.map(\.result.code), [.delivered])
        let prompt = try XCTUnwrap(h.presenter.prompts.first)
        XCTAssertEqual(first.events, [.approvalShown(id: prompt.id)])

        let repeated = try live.round(send("On my way"))
        let replay = try XCTUnwrap(repeated.payload.sendOutcome)
        XCTAssertTrue(replay.replayed)
        XCTAssertEqual(replay.text, "On my way")
        XCTAssertEqual(replay.parts.map(\.guid), outcome.parts.map(\.guid))
        XCTAssertTrue(repeated.events.isEmpty, "a replay shows no dialog")
        XCTAssertEqual(h.presenter.prompts.count, 1)

        h.clock.advance(Limits.minSecondsBetweenSendsPerChat + 1)
        let again = try live.round(send("On my way", again: true))
        let second = try XCTUnwrap(again.payload.sendOutcome)
        XCTAssertFalse(second.replayed)
        XCTAssertEqual(second.parts.map(\.result.code), [.delivered])
        XCTAssertNotEqual(second.parts.first?.guid, outcome.parts.first?.guid)
        XCTAssertEqual(again.events.count, 1)
        XCTAssertEqual(h.scripts.sentTexts, ["On my way", "On my way"])
        XCTAssertEqual(h.presenter.prompts.count, 2)
    }

    func testADeniedAndAnExpiredApprovalRunNothing() throws {
        let h = try Harness(Harness.Options(plan: .decide(.deny, after: 1.5)))
        let live = try LiveSocket(h)
        defer { live.stop() }
        let denied = try live.round(send("Call me"))
        XCTAssertEqual(denied.payload.headline, .denied(.user))
        XCTAssertEqual(denied.events.count, 1)
        XCTAssertEqual(try live.round(send("Call me")).payload.sendOutcome?.replayed, true)

        h.presenter.queue(.hold)
        h.jumpOnNextSleep(Limits.approvalExpiry)
        let expired = try live.round(send("Still there?"))
        XCTAssertEqual(expired.payload.headline, .denied(.approvalExpired))
        let id = try XCTUnwrap(h.presenter.prompts.last?.id)
        XCTAssertEqual(expired.events, [.approvalShown(id: id)])
        XCTAssertTrue(h.presenter.withdrawn.contains(id))
        XCTAssertTrue(h.scripts.calls.isEmpty)
        XCTAssertEqual(h.presenter.prompts.count, 2)
    }

    func testTheRateLimitAsksForASecondSendWithinTwentySeconds() throws {
        let h = try Harness()
        let live = try LiveSocket(h)
        defer { live.stop() }
        let allowed = try live.round(.allow(AllowArgs(who: Mom.who)))
        XCTAssertEqual(allowed.payload.policyOutcome?.result.code, .ok)
        XCTAssertEqual(allowed.events.count, 1)

        let a = try live.round(send("first"))
        XCTAssertEqual(a.payload.sendOutcome?.approved, false)
        XCTAssertEqual(a.payload.headline, .delivered)
        XCTAssertTrue(a.events.isEmpty, "an allowed chat under its limits sends without a dialog")

        let b = try live.round(send("second"))
        XCTAssertEqual(b.payload.sendOutcome?.approved, true)
        XCTAssertEqual(b.events.count, 1)
        XCTAssertEqual(h.presenter.prompts.last?.reason, RateLimitBreach.perChatInterval.dialogReason)
        XCTAssertEqual(h.presenter.prompts.last?.offersAlwaysAllow, false)
        XCTAssertEqual(h.scripts.sentTexts, ["first", "second"])
    }

    func testAFileUploadLargerThanTheSocketBufferIsStagedAndSent() throws {
        let h = try Harness()
        try h.allowMom(scope: .files)
        let live = try LiveSocket(h)
        defer { live.stop() }
        let bytes = Data(repeating: UInt8(ascii: "a"), count: 300_000)
        let answer = try live.round(send(nil), upload: bytes, fileName: "list.txt")
        let outcome = try XCTUnwrap(answer.payload.sendOutcome)
        XCTAssertFalse(outcome.approved)
        XCTAssertEqual(outcome.parts.map(\.part), [.file])
        XCTAssertEqual(outcome.parts.first?.result.code, .delivered)
        XCTAssertEqual(h.scripts.calls.map(\.0), [.sendFile])
        XCTAssertTrue(h.uploadFiles.isEmpty)
    }

    func testAnUploadThatIsRefusedIsStillReadSoTheAnswerArrives() throws {
        let h = try Harness()
        try h.allowMom(scope: .files)
        let live = try LiveSocket(h)
        defer { live.stop() }
        let bytes = Data(repeating: 0, count: 300_000)
        XCTAssertEqual(try live.round(.ping, upload: bytes).payload.failure?.result, .badRequest)
        XCTAssertEqual(try live.round(send(nil), upload: bytes, fileName: "../list.txt").payload.failure?.result,
                       .badRequest)
        XCTAssertTrue(h.scripts.calls.isEmpty)
        XCTAssertTrue(h.journal.allEntries().isEmpty)
        XCTAssertTrue(h.uploadFiles.isEmpty)
    }

    func testABackgroundApprovalIsCollectedWithPending() throws {
        let h = try Harness(Harness.Options(plan: .hold))
        let live = try LiveSocket(h)
        defer { live.stop() }
        let first = try live.round(send("Running late", approvalWait: 0))
        guard case .pending(let id)? = first.payload.sendOutcome?.early?.code else { return XCTFail("pending") }
        XCTAssertEqual(first.events, [.approvalShown(id: id)])
        XCTAssertEqual(try live.round(.pending(PendingArgs(id: id))).payload.sendOutcome?.early?.code, .pending(id: id))

        h.clock.advance(Limits.approvalButtonDelay + 1)
        h.presenter.decide(id, .allowOnce)
        h.waitUntilIdle()
        let done = try XCTUnwrap(try live.round(.pending(PendingArgs(id: id))).payload.sendOutcome)
        XCTAssertTrue(done.approved)
        XCTAssertEqual(done.text, "Running late")
        XCTAssertEqual(done.parts.map(\.result.code), [.delivered])
        XCTAssertEqual(h.scripts.sentTexts, ["Running late"])
    }

    func testConcurrentClientsWithOneKeyShareOneDialog() throws {
        let h = try Harness(Harness.Options(plan: .hold))
        let live = try LiveSocket(h)
        defer { live.stop() }
        let n = 6
        let lock = NSLock()
        var answers: [SendOutcome] = []
        DispatchQueue.concurrentPerform(iterations: n) { _ in
            let outcome = (try? live.round(send("Be there soon", approvalWait: 0)))?.payload.sendOutcome
            lock.lock()
            if let outcome { answers.append(outcome) }
            lock.unlock()
        }
        XCTAssertEqual(answers.count, n)
        XCTAssertEqual(h.presenter.prompts.count, 1)
        XCTAssertEqual(answers.filter(\.replayed).count, n - 1)
        for answer in answers {
            guard case .pending = answer.early?.code else { return XCTFail("\(answer)") }
        }
        h.presenter.decide(try XCTUnwrap(h.presenter.prompts.first?.id), .deny)
        h.waitUntilIdle()
        XCTAssertTrue(h.scripts.calls.isEmpty)
        XCTAssertEqual(h.journal.allEntries().count, 1)
    }

    func testARepeatAfterACrashReplaysTheReconciledSend() throws {
        let first = try Harness()
        try first.allowMom()
        let mom = try first.mom()
        let digest = TextNorm.textDigest("On my way")
        let key = IdempotencyKey.send(chat: mom.canonical, threaded: false, parentGUID: nil, textDigest: digest,
                                      attachmentDigest: nil)
        let binding = ApprovalBinding(chat: mom.canonical, action: .send, textDigest: digest, parentGUID: nil)
        guard case .run(let entry) = try first.journal.claim(key: key, again: false, action: .send,
                                                              chat: mom.canonical, binding: binding) else {
            return XCTFail("claim")
        }
        try first.journal.advance(entry.id, to: .invoking,
                                  facts: InvocationFacts(snapshotRowID: try first.copy.int("SELECT MAX(ROWID) FROM message")))
        try first.copy.insertMessage(rowid: 63_100, guid: "CRASH-SOCKET", text: "On my way", fromMe: true,
                                     date: AppleTime.nanos(from: first.clock.now))

        var options = Harness.Options()
        options.home = first.home
        options.copy = first.copy
        let second = try Harness(options, clock: first.clock, keychain: first.keychain)
        XCTAssertFalse(BridgeMain.prepare(second.container))
        let live = try LiveSocket(second)
        defer { live.stop() }
        let answer = try live.round(send("On my way"))
        let outcome = try XCTUnwrap(answer.payload.sendOutcome)
        XCTAssertTrue(outcome.replayed)
        XCTAssertEqual(outcome.early?.code, .delivered)
        XCTAssertTrue(answer.events.isEmpty)
        XCTAssertTrue(second.scripts.calls.isEmpty, "a reconciled send never goes out twice")
    }

    // MARK: - Connection rules

    func testAPeerWithAnotherUIDIsClosedWithoutAnAnswer() throws {
        let handler = CountingHandler()
        let live = try LiveSocket(handler: handler, residency: nil) { $0.allowedUID = getuid() &+ 1 }
        defer { live.stop() }
        let channel = try live.connect()
        defer { channel.close() }
        try? channel.writeFrame(Request(body: .ping))
        XCTAssertThrowsError(try channel.readFrame(ServerFrame.self)) {
            XCTAssertEqual($0 as? FrameCodec.FrameError, .closed)
        }
        XCTAssertTrue(handler.requests.isEmpty)
        XCTAssertEqual(live.server.activeConnections, 0)
    }

    func testTheSameUIDIsServed() throws {
        let handler = CountingHandler()
        let live = try LiveSocket(handler: handler, residency: nil)
        defer { live.stop() }
        guard case .pong = try live.round(.ping).payload else { return XCTFail("pong") }
        XCTAssertEqual(handler.requests.map(\.body.op), [.ping])
    }

    /// Writes `bytes` on one end of a socketpair, serves the other end, and returns the answer, or nil when the
    /// server closed without one.
    private func exchange(_ bytes: Data, handler: CountingHandler, closeWrite: Bool = true,
                          ioTimeout: TimeInterval = 5) throws -> Response? {
        let (client, server) = try SocketPair.make()
        let socket = SocketServer(listenFD: -1, handler: handler)
        socket.ioTimeout = ioTimeout
        let done = DispatchSemaphore(value: 0)
        Thread {
            socket.serve(server)
            done.signal()
        }.start()
        try SocketPair.writeAll(client, bytes)
        if closeWrite { _ = shutdown(client, SHUT_WR) }
        let channel = FrameChannel(fd: client)
        defer { channel.close() }
        try channel.setTimeouts(read: 10, write: 10)
        var answer: Response?
        do {
            if case .response(let response) = try channel.readFrame(ServerFrame.self) { answer = response }
        } catch FrameCodec.FrameError.closed {
            answer = nil
        }
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success)
        return answer
    }

    private func frame(_ body: Data) -> Data {
        var n = UInt32(body.count).bigEndian
        return Data(bytes: &n, count: 4) + body
    }

    private func requestJSON(_ edit: (inout [String: Any]) -> Void) throws -> Data {
        let encoded = try JSONEncoder.wire.encode(Request(id: "req-7", body: .chats(ChatsArgs())))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        edit(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }

    func testBadFramesGetABadRequestAndNeverReachTheHandler() throws {
        let handler = CountingHandler()
        let badRequest = ResponsePayload.failure(WireError(result: .badRequest))
        var tooLarge = UInt32(Limits.maxFrameBytes + 1).bigEndian
        let cases: [(String, Data, String)] = [
            ("over the frame cap", Data(bytes: &tooLarge, count: 4), ""),
            ("not UTF-8", frame(Data([0xFF, 0xFE, 0x7B])), ""),
            ("not JSON", frame(Data("hello".utf8)), ""),
            ("protocol version 2", frame(try requestJSON { $0["v"] = 2 }), "req-7"),
            ("an op that isn't named", frame(Data(#"{"v":1,"id":"op-1","body":{"launch":{"_0":{}}}}"#.utf8)), "op-1"),
            ("an op with arguments it doesn't take",
             frame(try requestJSON { $0["body"] = ["chats": ["_0": ["limit": "all"]]] }), "req-7"),
        ]
        for (name, bytes, id) in cases {
            let answer = try exchange(bytes, handler: handler)
            XCTAssertEqual(answer?.payload, badRequest, name)
            XCTAssertEqual(answer?.id, id, name)
            XCTAssertEqual(answer?.v, Request.protocolVersion, name)
        }
        XCTAssertTrue(handler.requests.isEmpty)
    }

    func testAFrameThatEndsEarlyOrStallsGetsNoAnswer() throws {
        let handler = CountingHandler()
        XCTAssertNil(try exchange(Data([0, 0]), handler: handler), "truncated header")
        XCTAssertNil(try exchange(frame(Data("{\"v\":1".utf8)).prefix(6), handler: handler), "truncated body")
        let start = Date()
        XCTAssertNil(try exchange(Data([0, 0, 0]), handler: handler, closeWrite: false, ioTimeout: 0.2), "stalled")
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertTrue(handler.requests.isEmpty)
    }

    func testAWellFormedFrameReachesTheHandlerOnce() throws {
        let handler = CountingHandler()
        let answer = try exchange(try FrameCodec.encode(Request(id: "ok-1", body: .ping)), handler: handler)
        XCTAssertEqual(answer?.id, "ok-1")
        XCTAssertEqual(handler.requests.map(\.id), ["ok-1"])
    }

    func testEachConnectionHoldsResidencyWhileItIsServed() throws {
        let lock = NSLock()
        var transitions: [String] = []
        let residency = ResidencyGuard(onFirstEnter: { lock.lock(); transitions.append("enter"); lock.unlock() },
                                       onLastLeave: { lock.lock(); transitions.append("leave"); lock.unlock() })
        let handler = GateHandler()
        let live = try LiveSocket(handler: handler, residency: residency)
        defer { live.stop() }
        let finished = DispatchSemaphore(value: 0)
        var answer: LiveSocket.Answer?
        Thread {
            answer = try? live.round(.ping)
            finished.signal()
        }.start()
        XCTAssertEqual(handler.entered.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(live.server.activeConnections, 1)
        XCTAssertEqual(residency.holds, 1)
        handler.release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 10), .success)
        guard case .pong? = answer?.payload else { return XCTFail("pong") }
        XCTAssertTrue(eventually { live.server.activeConnections == 0 && residency.holds == 0 })
        lock.lock()
        XCTAssertEqual(transitions, ["enter", "leave"])
        lock.unlock()
    }
}
