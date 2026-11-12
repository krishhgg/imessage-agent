import Foundation
import XCTest
import IMCore
import IMTestSupport
@testable import imessage

/// A system call in a test helper failed.
struct SysError: Error, Equatable {
    let errno: Int32
}

/// A stand-in bridge on a temp-dir socket. It listens at `Paths(home:).resolvedSocketPath()` under a fresh home in
/// /tmp, so the client finds it by the same rule it uses for the real socket, and no test touches the real one.
/// Each connection runs on its own thread with `FrameChannel`, like the real `SocketServer`.
final class FakeBridge {
    /// What the bridge does with one request.
    enum Script {
        /// Writes the events, then the response.
        case reply([BridgeEvent], ResponsePayload)
        /// Writes a full response with this protocol version.
        case version(Int, ResponsePayload)
        /// Answers with this protocol version without reading the upload, then closes.
        case replyBeforeUpload(ResponsePayload, version: Int = Request.protocolVersion)
        /// Reads the request only, then closes without reading the upload or answering.
        case closeBeforeUpload
        /// Reads the request and the upload, then never answers until the bridge stops.
        case hang
        /// Reads the request only, never the upload, and never answers.
        case ignoreUpload
        /// Writes this event every `every` seconds and never answers.
        case eventsForever(BridgeEvent, every: TimeInterval)
        /// Closes the connection without answering.
        case close
        /// Writes these bytes as they are, then closes.
        case raw(Data)
    }

    struct Received {
        let request: Request
        /// The request frame body exactly as it arrived.
        let frame: Data
        let upload: Data
    }

    let home: URL
    let paths: Paths
    let socketPath: String
    private let listenFD: Int32
    private let lock = NSLock()
    private var received: [Received] = []
    private var accepted = 0
    private var open: [FrameChannel] = []
    private var stopped = false
    private var listenerClosed = false
    private let script: (Request) -> Script

    /// `home` defaults to a new short folder in /tmp. Pass one to test the fallback socket path.
    init(home: URL? = nil, script: @escaping (Request) -> Script) throws {
        let h = home ?? FakeBridge.makeHome()
        self.home = h
        self.paths = Paths(home: h)
        self.socketPath = try paths.resolvedSocketPath()
        self.script = script
        try FileManager.default.createDirectory(atPath: (socketPath as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        listenFD = try FakeBridge.listen(at: socketPath)
        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.start()
    }

    convenience init(home: URL? = nil, answer: @escaping (Request) -> ResponsePayload) throws {
        try self.init(home: home) { .reply([], answer($0)) }
    }

    deinit { stop() }

    /// A client for this bridge's socket.
    func client(ownerUID: uid_t = getuid(), writeTimeout: TimeInterval = BridgeClient.defaultWriteTimeout) -> BridgeClient {
        BridgeClient(paths: paths, ownerUID: ownerUID, writeTimeout: writeTimeout)
    }

    var requests: [Request] { lock.withLock { received.map(\.request) } }
    var all: [Received] { lock.withLock { received } }
    var connections: Int { lock.withLock { accepted } }

    /// Stops accepting, closes every open connection, then removes the temp home. The accept loop closes the
    /// listening socket itself once it sees the flag.
    func stop() {
        let channels: [FrameChannel]? = lock.withLock {
            if stopped { return nil }
            stopped = true
            return open
        }
        guard let channels else { return }
        channels.forEach { $0.close() }
        while !lock.withLock({ listenerClosed }) { usleep(5_000) }
        try? FileManager.default.removeItem(at: home)
    }

    static func makeHome() -> URL {
        let name = "imcli-" + UUID().uuidString.prefix(8).lowercased()
        return URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent(name, isDirectory: true)
    }

    static func listen(at path: String) throws -> Int32 {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SysError(errno: errno) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard r == 0, chmod(path, 0o600) == 0, Darwin.listen(fd, 64) == 0 else {
            let e = errno
            Darwin.close(fd)
            throw SysError(errno: e)
        }
        return fd
    }

    /// Polls so it notices `stop()` without relying on close() to wake a blocked accept().
    private func acceptLoop() {
        defer {
            Darwin.close(listenFD)
            lock.withLock { listenerClosed = true }
        }
        while !lock.withLock({ stopped }) {
            var p = pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, 20) > 0 else { continue }
            let fd = accept(listenFD, nil, nil)
            if fd < 0 { continue }
            let channel = FrameChannel(fd: fd)
            let keep: Bool = lock.withLock {
                guard !stopped else { return false }
                accepted += 1
                open.append(channel)
                return true
            }
            guard keep else {
                channel.close()
                return
            }
            Thread { [weak self] in self?.serve(channel) }.start()
        }
    }

    private func serve(_ channel: FrameChannel) {
        defer { channel.close() }
        guard let (frame, request) = try? readRequest(channel) else { return }
        let plan = script(request)
        var upload = Data()
        let skipUpload: Bool
        switch plan {
        case .replyBeforeUpload, .ignoreUpload, .closeBeforeUpload: skipUpload = true
        default: skipUpload = false
        }
        if let header = request.upload, !skipUpload {
            var left = Int(header.byteCount)
            while left > 0, let chunk = try? channel.readRaw(max: left), !chunk.isEmpty {
                upload.append(chunk)
                left -= chunk.count
            }
        }
        lock.withLock { received.append(Received(request: request, frame: frame, upload: upload)) }
        switch plan {
        case .reply(let events, let payload):
            for e in events { try? channel.writeFrame(ServerFrame.event(e)) }
            try? channel.writeFrame(ServerFrame.response(Response(id: request.id, payload: payload)))
        case .version(let v, let payload):
            var r = Response(id: request.id, payload: payload)
            r.v = v
            try? channel.writeFrame(ServerFrame.response(r))
        case .replyBeforeUpload(let payload, let v):
            var r = Response(id: request.id, payload: payload)
            r.v = v
            try? channel.writeFrame(ServerFrame.response(r))
        case .hang, .ignoreUpload:
            waitUntilClosed(channel)
        case .eventsForever(let e, let every):
            while !lock.withLock({ stopped }), (try? channel.writeFrame(ServerFrame.event(e))) != nil {
                Thread.sleep(forTimeInterval: every)
            }
        case .close, .closeBeforeUpload:
            break
        case .raw(let bytes):
            try? channel.writeRaw(bytes)
        }
    }

    /// Reads the 4-byte header and the body by hand, so the test can see the exact bytes the client sent.
    private func readRequest(_ channel: FrameChannel) throws -> (Data, Request) {
        let header = try readExactly(channel, FrameCodec.headerBytes)
        let n = try FrameCodec.bodyLength(header: header)
        let body = try readExactly(channel, n)
        return (body, try FrameCodec.decode(Request.self, body: body))
    }

    private func readExactly(_ channel: FrameChannel, _ n: Int) throws -> Data {
        var out = Data()
        while out.count < n {
            let chunk = try channel.readRaw(max: n - out.count)
            if chunk.isEmpty { throw FrameCodec.FrameError.truncated }
            out.append(chunk)
        }
        return out
    }

    /// Blocks until the bridge stops, without reading anything more.
    private func waitUntilClosed(_ channel: FrameChannel) {
        while !lock.withLock({ stopped }) { usleep(10_000) }
    }
}

/// Captured stdout and stderr, kickstart calls and pauses for `CLI.execute`.
final class CLIRun {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()
    private var kicks = 0
    private var pauses: [TimeInterval] = []
    var kickstartResult = true
    /// Runs inside the recording kickstart, for example to change what the fake bridge answers next.
    var onKickstart: () -> Void = {}

    var stdout: Data { lock.withLock { out } }
    var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    var stderrText: String { lock.withLock { String(decoding: err, as: UTF8.self) } }
    var kickstarts: Int { lock.withLock { kicks } }
    var paused: [TimeInterval] { lock.withLock { pauses } }

    func environment(_ client: BridgeClient, now: Date = Fixture.now,
                     timeZone: TimeZone = Fixture.timeZone) -> CLIEnvironment {
        CLIEnvironment(
            client: client, now: now, timeZone: timeZone,
            stdout: { s in self.lock.withLock { self.out.append(Data(s.utf8)) } },
            stderr: { s in self.lock.withLock { self.err.append(Data(s.utf8)) } },
            kickstart: {
                self.lock.withLock { self.kicks += 1 }
                self.onKickstart()
                return self.kickstartResult
            },
            pause: { t in self.lock.withLock { self.pauses.append(t) } })
    }

    /// Parses and runs `args` with `client` and returns the exit code.
    func run(_ args: [String], _ client: BridgeClient) -> Int32 {
        CLI.run(arguments: args, environment: environment(client))
    }
}

/// Small builders for payloads.
enum P {
    static let mom = ChatRef(rowid: 7, label: "Mom", isGroup: false)

    static func send(_ parts: [SendPartOutcome], early: ActionResult? = nil, approved: Bool = false,
                     replayed: Bool = false) -> ResponsePayload {
        .send(SendOutcome(chat: mom, approved: approved, early: early, text: "On my way", threadParentRowID: nil,
                          parts: parts, replayed: replayed))
    }

    static func text(_ code: ResultCode, rowid: Int64? = 41600) -> SendPartOutcome {
        SendPartOutcome(part: .text, result: ActionResult(code), rowid: rowid)
    }

    static func ui(_ code: ResultCode, action: UIActionKind = .react) -> ResponsePayload {
        .ui(UIOutcome(action: action, targetRowID: 41418, chat: mom, tapback: action == .react ? .heart : nil,
                      remove: false, approved: false, result: ActionResult(code), currentReaction: nil,
                      replayed: false, targetQuote: nil))
    }

    static func policy(_ code: ResultCode) -> ResponsePayload {
        .policy(PolicyOutcome(change: .allowChat, chat: mom, scope: .text, result: ActionResult(code)))
    }

    static func failure(_ m: String, fix: String? = nil) -> ResponsePayload { .failure(.message(m, fix: fix)) }

    static func doctor(_ checks: [DoctorCheck], needsKickstart: Bool = false) -> ResponsePayload {
        .doctor(DoctorReport(checks: checks, needsKickstart: needsKickstart))
    }

    static func setup(_ stage: SetupStage, _ state: PermissionState, pane: String? = nil) -> ResponsePayload {
        .setup(SetupReport(stage: stage, state: state, openedPane: pane))
    }

    static let pong = ResponsePayload.pong(PongInfo(bridgeVersion: "0.1.0", pid: 4242))
}

/// A temp folder for test files, removed by `cleanup`.
final class TempDir {
    let url: URL

    init() throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("imcli-files-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func file(_ name: String, _ data: Data) throws -> String {
        let u = url.appendingPathComponent(name)
        try data.write(to: u)
        return u.path
    }

    /// A sparse file of exactly `size` bytes, so the 100 MB boundary costs no disk space.
    func sparse(_ name: String, size: Int64) throws -> String {
        let path = url.appendingPathComponent(name).path
        let fd = open(path, O_CREAT | O_WRONLY | O_TRUNC, 0o600)
        guard fd >= 0 else { throw SysError(errno: errno) }
        defer { close(fd) }
        guard ftruncate(fd, off_t(size)) == 0 else { throw SysError(errno: errno) }
        return path
    }

    func cleanup() { try? FileManager.default.removeItem(at: url) }
}

extension XCTestCase {
    /// A fake bridge that stops when the test ends.
    func makeBridge(home: URL? = nil, script: @escaping (Request) -> FakeBridge.Script) throws -> FakeBridge {
        let b = try FakeBridge(home: home, script: script)
        addTeardownBlock { b.stop() }
        return b
    }

    func makeBridge(home: URL? = nil, answer: @escaping (Request) -> ResponsePayload) throws -> FakeBridge {
        try makeBridge(home: home) { .reply([], answer($0)) }
    }

    func makeTempDir() throws -> TempDir {
        let d = try TempDir()
        addTeardownBlock { d.cleanup() }
        return d
    }

    /// The usage error that parsing `args` throws. Parsing that succeeds fails the test.
    func usageError(_ args: [String], file: StaticString = #filePath, line: UInt = #line) -> UsageError? {
        do {
            let inv = try ArgumentParser.parse(args)
            XCTFail("\(args) parsed as \(inv)", file: file, line: line)
        } catch let e as UsageError {
            return e
        } catch {
            XCTFail("\(args) threw \(error)", file: file, line: line)
        }
        return nil
    }

    func parsed(_ args: [String], file: StaticString = #filePath, line: UInt = #line) -> Command? {
        do {
            return try ArgumentParser.parse(args).command
        } catch {
            XCTFail("\(args) threw \(error)", file: file, line: line)
            return nil
        }
    }
}
