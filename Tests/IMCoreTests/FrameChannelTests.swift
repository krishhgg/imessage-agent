import XCTest
@testable import IMCore
import IMTestSupport

/// FrameChannel over a real socketpair, plus a scripted `SocketIO` for short transfers and errno paths.
final class FrameChannelTests: XCTestCase {
    typealias FrameError = FrameCodec.FrameError

    var toClose: [Int32] = []

    override func tearDown() {
        for fd in toClose { Darwin.close(fd) }
        toClose = []
        super.tearDown()
    }

    /// A channel on one end and the raw fd of the other.
    func pair() throws -> (FrameChannel, Int32) {
        let (a, b) = try SocketPair.make()
        toClose.append(b)
        return (FrameChannel(fd: a), b)
    }

    func header(_ n: UInt32) -> Data {
        Data([UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)])
    }

    func assertFrameError<T>(_ expected: FrameError, _ body: () throws -> T, file: StaticString = #filePath,
                             line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual($0 as? FrameError, expected, file: file, line: line)
        }
    }

    /// Runs `body` on a global queue. A thrown error fails the test. The expectation is fulfilled when it returns.
    func background(_ name: String, file: StaticString = #filePath, line: UInt = #line,
                    _ body: @escaping () throws -> Void) -> XCTestExpectation {
        let done = expectation(description: name)
        DispatchQueue.global().async {
            do { try body() } catch { XCTFail("\(name): \(error)", file: file, line: line) }
            done.fulfill()
        }
        return done
    }

    // MARK: Round trips

    func testFramesRoundTripInOrderOverOneConnection() throws {
        let (a, b) = try SocketPair.make()
        let client = FrameChannel(fd: a)
        let server = FrameChannel(fd: b)
        let request = Request(id: "r1", body: .send(SendArgs(who: "Mom", text: "café 🎉")))
        try client.writeFrame(request)
        try server.writeFrame(ServerFrame.event(.queued))
        try server.writeFrame(ServerFrame.response(Response(id: "r1", payload: .pong(PongInfo(bridgeVersion: "1", pid: 7)))))
        XCTAssertEqual(try server.readFrame(Request.self), request)
        XCTAssertEqual(try client.readFrame(ServerFrame.self), .event(.queued))
        XCTAssertEqual(try client.readFrame(ServerFrame.self),
                       .response(Response(id: "r1", payload: .pong(PongInfo(bridgeVersion: "1", pid: 7)))))
    }

    func testLargeFrameMovesWhileThePeerReads() throws {
        let (a, b) = try SocketPair.make()
        let writer = FrameChannel(fd: a)
        let reader = FrameChannel(fd: b)
        let text = String(repeating: "0123456789abcdef", count: 256 * 1024)
        let done = background("written") { try writer.writeFrame(text) }
        XCTAssertEqual(try reader.readFrame(String.self), text)
        wait(for: [done], timeout: 10)
    }

    // MARK: The 8 MiB cap

    func testBodyOfExactlyTheCapIsRead() throws {
        let (channel, peer) = try pair()
        let max = Limits.maxFrameBytes
        let body = Data("\"".utf8) + Data(repeating: UInt8(ascii: "a"), count: max - 2) + Data("\"".utf8)
        XCTAssertEqual(body.count, max)
        let frame = header(UInt32(max)) + body
        let sent = background("sent") { try SocketPair.writeAll(peer, frame) }
        XCTAssertEqual(try channel.readFrame(String.self).utf8.count, max - 2)
        wait(for: [sent], timeout: 10)
    }

    func testLengthOverTheCapIsRejectedWithoutReadingTheBody() throws {
        let (channel, peer) = try pair()
        try SocketPair.writeAll(peer, header(UInt32(Limits.maxFrameBytes + 1)) + Data("xyz".utf8))
        assertFrameError(.tooLarge(Limits.maxFrameBytes + 1)) { try channel.readFrame(String.self) }
        XCTAssertEqual(try channel.readRaw(max: 3), Data("xyz".utf8))
    }

    func testOversizeWriteSendsNothing() throws {
        let (a, b) = try SocketPair.make()
        let writer = FrameChannel(fd: a)
        let reader = FrameChannel(fd: b)
        assertFrameError(.tooLarge(Limits.maxFrameBytes + 1)) {
            try writer.writeFrame(String(repeating: "a", count: Limits.maxFrameBytes - 1))
        }
        try writer.writeFrame("ok")
        XCTAssertEqual(try reader.readFrame(String.self), "ok")
    }

    // MARK: End of stream

    func testEndOfStreamBeforeAFrameIsClosed() throws {
        let (channel, peer) = try pair()
        Darwin.close(peer)
        toClose.removeAll { $0 == peer }
        assertFrameError(.closed) { try channel.readFrame(String.self) }
    }

    func testEndOfStreamInsideTheHeaderIsTruncated() throws {
        let (channel, peer) = try pair()
        try SocketPair.writeAll(peer, Data([0, 0]))
        shutdown(peer, SHUT_WR)
        assertFrameError(.truncated) { try channel.readFrame(String.self) }
    }

    func testEndOfStreamInsideTheBodyIsTruncated() throws {
        let (channel, peer) = try pair()
        try SocketPair.writeAll(peer, header(10) + Data("\"abc".utf8))
        shutdown(peer, SHUT_WR)
        assertFrameError(.truncated) { try channel.readFrame(String.self) }
    }

    // MARK: Body checks

    func testBodyThatIsNotUTF8IsRejected() throws {
        let (channel, peer) = try pair()
        let bodies: [[UInt8]] = [
            [0xFF, 0xFE, 0x22, 0x00, 0x61, 0x00, 0x22, 0x00], // UTF-16LE with a BOM
            [0x22, 0xC3, 0x22], // truncated sequence
            [0x22, 0xC0, 0x80, 0x22], // overlong NUL
            [0x22, 0xED, 0xA0, 0x80, 0x22], // UTF-16 surrogate
        ]
        for b in bodies { try SocketPair.writeAll(peer, header(UInt32(b.count)) + Data(b)) }
        try SocketPair.writeAll(peer, header(7) + Data("\"café\"".utf8))
        for _ in bodies { assertFrameError(.notUTF8) { try channel.readFrame(String.self) } }
        XCTAssertEqual(try channel.readFrame(String.self), "café")
    }

    func testBadJSONThrowsADecodingError() throws {
        let (channel, peer) = try pair()
        try SocketPair.writeAll(peer, header(1) + Data("{".utf8))
        try SocketPair.writeAll(peer, header(2) + Data("{}".utf8))
        XCTAssertThrowsError(try channel.readFrame(Request.self)) { XCTAssertTrue($0 is DecodingError) }
        XCTAssertThrowsError(try channel.readFrame(Request.self)) { XCTAssertTrue($0 is DecodingError) }
    }

    // MARK: Timeouts

    func testReadWithNothingSentTimesOut() throws {
        let (channel, _) = try pair()
        try channel.setTimeouts(read: 0.05, write: 0)
        let start = Date()
        assertFrameError(.timedOut) { try channel.readFrame(String.self) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testStalledPartialHeaderTimesOut() throws {
        let (channel, peer) = try pair()
        try channel.setTimeouts(read: 0.05, write: 0)
        try SocketPair.writeAll(peer, Data([0, 0]))
        assertFrameError(.timedOut) { try channel.readFrame(String.self) }
    }

    func testWriteToAPeerThatNeverReadsTimesOut() throws {
        let (channel, _) = try pair()
        try channel.setTimeouts(read: 0, write: 0.05)
        assertFrameError(.timedOut) { try channel.writeFrame(String(repeating: "a", count: 4 * 1024 * 1024)) }
    }

    func testTimeoutValues() throws {
        func tv(_ t: TimeInterval) throws -> [Int] {
            let v = try FrameChannel.timeval(t)
            return [v.tv_sec, Int(v.tv_usec)]
        }
        XCTAssertEqual(try tv(0), [0, 0])
        XCTAssertEqual(try tv(0.05), [0, 50_000])
        XCTAssertEqual(try tv(1.5), [1, 500_000])
        XCTAssertEqual(try tv(30), [30, 0])
        XCTAssertEqual(try tv(1e-9), [0, 1])
        XCTAssertEqual(try tv(0.9999999), [1, 0])
        XCTAssertEqual(try tv(1e12), [Int(Int32.max), 0])
        for bad in [-1, -1e-9, .nan, .infinity] {
            XCTAssertThrowsError(try FrameChannel.timeval(bad)) { XCTAssertEqual($0 as? FrameError, .system(EINVAL)) }
        }
        let (channel, _) = try pair()
        assertFrameError(.system(EINVAL)) { try channel.setTimeouts(read: -1, write: 0) }
        try channel.setTimeouts(read: 0.25, write: 2)
        var r = timeval()
        var size = socklen_t(MemoryLayout<timeval>.size)
        XCTAssertEqual(getsockopt(channel.fd, SOL_SOCKET, SO_RCVTIMEO, &r, &size), 0)
        XCTAssertEqual([r.tv_sec, Int(r.tv_usec)], [0, 250_000])
        XCTAssertEqual(getsockopt(channel.fd, SOL_SOCKET, SO_SNDTIMEO, &r, &size), 0)
        XCTAssertEqual([r.tv_sec, Int(r.tv_usec)], [2, 0])
    }

    // MARK: Closed peers

    func testWritingToAClosedPeerThrowsClosedWithoutSIGPIPE() throws {
        let (channel, peer) = try pair()
        var on: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        XCTAssertEqual(getsockopt(channel.fd, SOL_SOCKET, SO_NOSIGPIPE, &on, &size), 0)
        XCTAssertNotEqual(on, 0)
        Darwin.close(peer)
        toClose.removeAll { $0 == peer }
        assertFrameError(.closed) {
            for _ in 0..<4 { try channel.writeFrame("x") }
        }
    }

    // MARK: Scripted IO

    func testShortTransfersAndEINTRStillMoveWholeFrames() throws {
        let script = ScriptedIO()
        script.readSteps = [.fail(EINTR), .bytes(1), .fail(EINTR), .bytes(2), .bytes(1), .fail(EINTR), .bytes(3)]
        script.writeSteps = [.fail(EINTR), .bytes(1), .bytes(2), .fail(EINTR), .bytes(5)]
        let channel = try script.channel()
        let value = Request(id: "short", body: .contacts(ContactsArgs(name: "Jordan")))
        try channel.writeFrame(value)
        XCTAssertEqual(script.writeErrorsSeen, 2)
        script.source = script.sink
        XCTAssertEqual(try channel.readFrame(Request.self), value)
        XCTAssertEqual(script.readErrorsSeen, 3)
    }

    func testReadErrnoMapping() throws {
        let cases: [(Int32, FrameError)] = [
            (EAGAIN, .timedOut), (ECONNRESET, .closed), (ENOTCONN, .closed), (EBADF, .closed), (EIO, .system(EIO)),
        ]
        for (err, expected) in cases {
            let script = ScriptedIO()
            script.readSteps = [.fail(err)]
            script.source = Array(header(2) + Data("\"\"".utf8))
            let channel = try script.channel()
            assertFrameError(expected) { try channel.readFrame(String.self) }
        }
        // An error inside the body maps the same way, not to `truncated`.
        let script = ScriptedIO()
        script.readSteps = [.bytes(4), .bytes(1), .fail(EAGAIN)]
        script.source = Array(header(2) + Data("\"\"".utf8))
        assertFrameError(.timedOut) { try script.channel().readFrame(String.self) }
    }

    func testWriteErrnoMapping() throws {
        let cases: [(ScriptedIO.Step, FrameError)] = [
            (.fail(EAGAIN), .timedOut), (.fail(EPIPE), .closed), (.fail(ECONNRESET), .closed),
            (.fail(ENOTCONN), .closed), (.fail(EBADF), .closed), (.fail(EIO), .system(EIO)), (.zero, .closed),
        ]
        for (step, expected) in cases {
            let script = ScriptedIO()
            script.writeSteps = [.bytes(3), step]
            let channel = try script.channel()
            assertFrameError(expected) { try channel.writeFrame("hello") }
            assertFrameError(expected) {
                script.writeSteps = [step]
                try channel.writeRaw(Data([1, 2, 3]))
            }
        }
    }

    func testReadRawAsksForAtMostOneMebibyte() throws {
        let script = ScriptedIO()
        script.source = [UInt8](repeating: 7, count: 3 << 20)
        let channel = try script.channel()
        XCTAssertEqual(try channel.readRaw(max: 5 << 20).count, 1 << 20)
        XCTAssertEqual(script.lastReadCount, 1 << 20)
        XCTAssertEqual(try channel.readRaw(max: 10).count, 10)
        XCTAssertEqual(script.lastReadCount, 10)
    }

    // MARK: Real signals

    func testRealSignalInterruptingAReadIsRetried() throws {
        var action = sigaction()
        action.__sigaction_u.__sa_handler = { _ in }
        action.sa_flags = 0 // no SA_RESTART, so a blocked read returns EINTR
        sigemptyset(&action.sa_mask)
        var old = sigaction()
        XCTAssertEqual(sigaction(SIGUSR1, &action, &old), 0)
        defer { sigaction(SIGUSR1, &old, nil) }

        let (a, peer) = try SocketPair.make()
        toClose.append(peer)
        let recorder = RecordingIO()
        let channel = FrameChannel(fd: a, io: recorder.io)
        let thread = ThreadBox()
        let finished = expectation(description: "read returned")
        let reader = Thread {
            thread.set(pthread_self())
            let got = Result { try channel.readFrame(String.self) }
            XCTAssertEqual(try? got.get(), "after the signal", "\(got)")
            finished.fulfill()
        }
        reader.start()

        let deadline = Date().addingTimeInterval(10)
        while recorder.interrupts == 0 && Date() < deadline {
            if let t = thread.get() { pthread_kill(t, SIGUSR1) }
            usleep(10_000)
        }
        XCTAssertGreaterThan(recorder.interrupts, 0, "the read was never interrupted")
        try SocketPair.writeAll(peer, try FrameCodec.encode("after the signal"))
        wait(for: [finished], timeout: 10)
    }

    // MARK: Raw upload bytes

    func testFrameFollowedByRawUploadBytes() throws {
        let (a, b) = try SocketPair.make()
        let client = FrameChannel(fd: a)
        let server = FrameChannel(fd: b)
        let payload = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let request = Request(id: "u", body: .send(SendArgs(who: "Mom", text: nil)),
                              upload: UploadHeader(byteCount: Int64(payload.count), fileName: "IMG_4420.HEIC"))
        let sent = background("sent") {
            try client.writeFrame(request)
            try client.writeRaw(payload)
            Darwin.shutdown(client.fd, SHUT_WR)
        }
        let got = try server.readFrame(Request.self)
        XCTAssertEqual(got, request)
        var received = Data()
        while true {
            let chunk = try server.readRaw(max: 65_536)
            if chunk.isEmpty { break }
            XCTAssertLessThanOrEqual(chunk.count, 65_536)
            received.append(chunk)
        }
        XCTAssertEqual(received, payload)
        XCTAssertEqual(try server.readRaw(max: 1), Data())
        wait(for: [sent], timeout: 10)
        _ = client
    }

    func testReadRawIntoABuffer() throws {
        let (channel, peer) = try pair()
        try SocketPair.writeAll(peer, Data([1, 2, 3, 4, 5]))
        var buffer = [UInt8](repeating: 0, count: 3)
        let n = try buffer.withUnsafeMutableBytes { try channel.readRaw(into: $0) }
        XCTAssertEqual(n, 3)
        XCTAssertEqual(buffer, [1, 2, 3])
        var rest = [UInt8](repeating: 0, count: 8)
        XCTAssertEqual(try rest.withUnsafeMutableBytes { try channel.readRaw(into: $0) }, 2)
        XCTAssertEqual(Array(rest.prefix(2)), [4, 5])
        shutdown(peer, SHUT_WR)
        XCTAssertEqual(try rest.withUnsafeMutableBytes { try channel.readRaw(into: $0) }, 0)
    }

    func testReadRawRejectsAnEmptyRequest() throws {
        let (channel, _) = try pair()
        assertFrameError(.system(EINVAL)) { try channel.readRaw(max: 0) }
        assertFrameError(.system(EINVAL)) { try channel.readRaw(max: -1) }
        var empty = [UInt8]()
        assertFrameError(.system(EINVAL)) { try empty.withUnsafeMutableBytes { try channel.readRaw(into: $0) } }
    }

    // MARK: Close

    func testCloseIsIdempotentAndEveryCallAfterItThrowsClosed() throws {
        let (channel, peer) = try pair()
        channel.close()
        channel.close()
        XCTAssertEqual(fcntl(channel.fd, F_GETFD), -1)
        XCTAssertEqual(try SocketPair.read(peer, count: 1), Data())
        assertFrameError(.closed) { try channel.readFrame(String.self) }
        assertFrameError(.closed) { try channel.writeFrame("x") }
        assertFrameError(.closed) { try channel.writeRaw(Data([1])) }
        assertFrameError(.closed) { try channel.readRaw(max: 1) }
        assertFrameError(.closed) { try channel.setTimeouts(read: 1, write: 1) }
    }

    func testCloseFromAnotherThreadWakesABlockedRead() throws {
        let (channel, _) = try pair()
        let started = expectation(description: "read started")
        let woke = background("read woke") {
            started.fulfill()
            XCTAssertThrowsError(try channel.readFrame(String.self)) {
                XCTAssertEqual($0 as? FrameError, .closed)
            }
        }
        wait(for: [started], timeout: 5)
        usleep(50_000)
        channel.close()
        wait(for: [woke], timeout: 5)
    }

    func testCloseFromAnotherThreadWakesABlockedWrite() throws {
        // The peer never reads, so a 4 MiB frame fills the socket buffer and the write blocks with no timeout set.
        let (channel, _) = try pair()
        let started = expectation(description: "write started")
        let woke = background("write woke") {
            started.fulfill()
            XCTAssertThrowsError(try channel.writeFrame(String(repeating: "a", count: 4 * 1024 * 1024))) {
                XCTAssertEqual($0 as? FrameError, .closed)
            }
        }
        wait(for: [started], timeout: 5)
        usleep(50_000)
        channel.close()
        wait(for: [woke], timeout: 5)
        XCTAssertEqual(fcntl(channel.fd, F_GETFD), -1)
    }

    func testDeinitClosesTheSocket() throws {
        let (a, peer) = try SocketPair.make()
        toClose.append(peer)
        do {
            let channel = FrameChannel(fd: a)
            try channel.writeFrame("bye")
        }
        XCTAssertEqual(try SocketPair.read(peer, count: 64).count, FrameCodec.headerBytes + 5)
        XCTAssertEqual(try SocketPair.read(peer, count: 1), Data())
    }

    // MARK: Thread safety

    func testConcurrentWritersNeverInterleaveFrames() throws {
        let (a, b) = try SocketPair.make()
        let writer = FrameChannel(fd: a)
        let reader = FrameChannel(fd: b)
        let threads = 8
        let perThread = 40
        let group = DispatchGroup()
        for t in 0..<threads {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    for i in 0..<perThread {
                        try writer.writeFrame(String(repeating: Character(UnicodeScalar(UInt8(65 + t))), count: 20_000 + i))
                    }
                } catch {
                    XCTFail("writer \(t): \(error)")
                }
            }
        }
        var counts = [Int](repeating: 0, count: threads)
        for _ in 0..<(threads * perThread) {
            let s = try reader.readFrame(String.self)
            let first = s.unicodeScalars.first!
            XCTAssertTrue(s.unicodeScalars.allSatisfy { $0 == first }, "interleaved frame")
            counts[Int(first.value) - 65] += 1
        }
        XCTAssertEqual(group.wait(timeout: .now() + 20), .success)
        XCTAssertEqual(counts, [Int](repeating: perThread, count: threads))
    }

    func testWriteProceedsWhileAnotherThreadIsBlockedReading() throws {
        let (a, b) = try SocketPair.make()
        let local = FrameChannel(fd: a)
        let remote = FrameChannel(fd: b)
        let replied = background("reply read") { XCTAssertEqual(try local.readFrame(String.self), "pong") }
        usleep(50_000)
        let wrote = background("write returned") { try local.writeFrame("ping") }
        wait(for: [wrote], timeout: 5)
        XCTAssertEqual(try remote.readFrame(String.self), "ping")
        try remote.writeFrame("pong")
        wait(for: [replied], timeout: 5)
    }
}

/// A `SocketIO` that follows a script of steps, then moves everything that's left.
final class ScriptedIO {
    enum Step {
        /// Moves at most this many bytes.
        case bytes(Int)
        /// Returns -1 with this errno.
        case fail(Int32)
        /// Returns 0.
        case zero
    }

    private let lock = NSLock()
    var readSteps: [Step] = []
    var writeSteps: [Step] = []
    var source: [UInt8] = []
    var sink: [UInt8] = []
    var readErrorsSeen = 0
    var writeErrorsSeen = 0
    var lastReadCount = 0

    func channel() throws -> FrameChannel {
        let (a, b) = try SocketPair.make()
        Darwin.close(b)
        return FrameChannel(fd: a, io: io)
    }

    var io: SocketIO {
        SocketIO(
            read: { [self] _, buf, n in
                lock.lock()
                defer { lock.unlock() }
                lastReadCount = n
                var limit = n
                if !readSteps.isEmpty {
                    switch readSteps.removeFirst() {
                    case .bytes(let k): limit = min(n, k)
                    case .fail(let e):
                        readErrorsSeen += 1
                        return (-1, e)
                    case .zero: return (0, 0)
                    }
                }
                let k = min(limit, source.count)
                source.withUnsafeBytes { buf.copyMemory(from: $0.baseAddress!, byteCount: k) }
                source.removeFirst(k)
                return (k, 0)
            },
            write: { [self] _, buf, n in
                lock.lock()
                defer { lock.unlock() }
                var limit = n
                if !writeSteps.isEmpty {
                    switch writeSteps.removeFirst() {
                    case .bytes(let k): limit = min(n, k)
                    case .fail(let e):
                        writeErrorsSeen += 1
                        return (-1, e)
                    case .zero: return (0, 0)
                    }
                }
                sink.append(contentsOf: UnsafeRawBufferPointer(start: buf, count: limit))
                return (limit, 0)
            }
        )
    }
}

/// The system calls, counting reads that returned EINTR.
final class RecordingIO {
    private let lock = NSLock()
    private var seen = 0

    var interrupts: Int {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }

    var io: SocketIO {
        SocketIO(
            read: { [self] fd, buf, n in
                let r = SocketIO.system.read(fd, buf, n)
                if r.0 < 0 && r.1 == EINTR {
                    lock.lock()
                    seen += 1
                    lock.unlock()
                }
                return r
            },
            write: SocketIO.system.write
        )
    }
}

final class ThreadBox {
    private let lock = NSLock()
    private var value: pthread_t?

    func set(_ t: pthread_t) {
        lock.lock()
        value = t
        lock.unlock()
    }

    func get() -> pthread_t? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
