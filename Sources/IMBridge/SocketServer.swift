import Foundation
import IMCore

/// Reads the raw upload bytes that follow a request frame. Handed to the handler only when `Request.upload` is set.
/// Live: the connection's `FrameChannel.readRaw(into:)`, which reads straight into the buffer.
public protocol UploadReading: AnyObject {
    /// Reads up to `buffer.count` bytes. Returns 0 at end of stream.
    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int
}

/// One request in, events and one response out (wire protocol in Sources/IMCore/Wire.swift).
public protocol RequestHandling: AnyObject {
    /// `peerGone` returns true once the client has hung up. A request that blocks for a long time, like `wait`,
    /// checks it and stops early, since nobody is left to read the answer.
    func handle(_ request: Request, upload: UploadReading?, events: @escaping (BridgeEvent) -> Void,
                peerGone: @escaping () -> Bool) -> Response
}

extension RequestHandling {
    /// A request whose client never hangs up early.
    public func handle(_ request: Request, upload: UploadReading?, events: @escaping (BridgeEvent) -> Void) -> Response {
        handle(request, upload: upload, events: events, peerGone: { false })
    }
}

/// Accept loop on the launchd listening fd. Owner: IMBridge.
///
/// - Each connection is served on its own thread; mutations serialize later on the action queue.
/// - The peer's uid from `getpeereid` must equal the bridge's uid, otherwise the connection is closed unanswered.
/// - Frames over `Limits.maxFrameBytes`, bodies that aren't UTF-8 or JSON, and a protocol version other than 1 get
///   `ActionResult.badRequest`.
/// - Socket mode 0600 is set by launchd (`SockPathMode` 384).
///
/// Per connection: read one request frame, hand the handler a reader capped at the upload's byte count, write each
/// event as it comes, read and drop whatever upload bytes the handler left (the client writes them all before it
/// reads), write the one response, close. A peer that hangs up or stalls past `ioTimeout` before its request is
/// complete gets no answer. The handler gets `peerHasLeft` for the connection, so a `wait` ends soon after its client
/// hangs up. Set `residency` and `ioTimeout` before `start`.
public final class SocketServer {
    public let listenFD: Int32
    public let handler: RequestHandling
    /// Held for each connection while it is served. The container's guard in the bridge.
    public var residency: ResidencyGuard?
    /// SO_RCVTIMEO and SO_SNDTIMEO on each connection. Each blocking call gets the full timeout, so a slow upload
    /// that keeps moving stays connected.
    public var ioTimeout: TimeInterval = 30

    /// The uid a peer must have. Tests change it to check the refusal path without a second user.
    var allowedUID: uid_t = getuid()

    private let acceptQueue = DispatchQueue(label: "\(AppIdentity.bundleID).accept")
    private let lock = NSLock()
    private var source: DispatchSourceRead?
    private var active = 0

    public init(listenFD: Int32, handler: RequestHandling) {
        self.listenFD = listenFD
        self.handler = handler
    }

    /// Starts the dispatch source. Returns immediately.
    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard source == nil else { return }
        let flags = fcntl(listenFD, F_GETFL)
        if flags >= 0 { _ = fcntl(listenFD, F_SETFL, flags | O_NONBLOCK) }
        let src = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: acceptQueue)
        src.setEventHandler { [weak self] in self?.acceptPending() }
        source = src
        src.resume()
    }

    /// Stops accepting. Connections already accepted run to the end. The listening fd stays open; launchd owns it.
    public func stop() {
        lock.lock()
        let src = source
        source = nil
        lock.unlock()
        src?.cancel()
    }

    /// Connections currently being served. The bridge stays resident while this or an approval is open.
    public var activeConnections: Int {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    public static func peerUID(fd: Int32) -> uid_t? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else { return nil }
        return uid
    }

    // MARK: - Accept

    /// Accepts until the backlog is empty. Runs on `acceptQueue`.
    private func acceptPending() {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 {
                switch errno {
                case EINTR, ECONNABORTED:
                    continue
                case EMFILE, ENFILE:
                    // Out of descriptors. The listening socket stays readable, so pause the source briefly instead
                    // of spinning on it.
                    pauseAccepting()
                    return
                default:
                    return
                }
            }
            SocketServer.prepareConnection(fd)
            guard SocketServer.peerUID(fd: fd) == allowedUID else {
                close(fd)
                continue
            }
            begin()
            let thread = Thread { [self] in
                serve(fd)
                end()
            }
            thread.name = "\(AppIdentity.bundleID).connection"
            thread.start()
        }
    }

    private func pauseAccepting() {
        lock.lock()
        let src = source
        lock.unlock()
        guard let src else { return }
        src.suspend()
        acceptQueue.asyncAfter(deadline: .now() + 0.1) { src.resume() }
    }

    /// The accepted fd inherits O_NONBLOCK from the listening socket on macOS. Connections use blocking IO with
    /// timeouts, so clear it. FD_CLOEXEC keeps the fd out of `open` and `launchctl` children.
    static func prepareConnection(_ fd: Int32) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) }
    }

    private func begin() {
        lock.lock()
        active += 1
        lock.unlock()
        residency?.enter()
    }

    private func end() {
        lock.lock()
        active -= 1
        lock.unlock()
        residency?.leave()
    }

    // MARK: - One connection

    /// Serves one connected fd and closes it. Internal so tests can drive it over a socketpair.
    func serve(_ fd: Int32) {
        let channel = FrameChannel(fd: fd)
        defer { channel.close() }
        try? channel.setTimeouts(read: ioTimeout, write: ioTimeout)

        let incoming: IncomingRequest
        do {
            incoming = try channel.readFrame(IncomingRequest.self)
        } catch let error as FrameCodec.FrameError {
            switch error {
            case .tooLarge, .notUTF8:
                SocketServer.respond(channel, Response(id: "", payload: .failure(WireError(result: .badRequest))))
            case .truncated, .closed, .timedOut, .system:
                break
            }
            return
        } catch {
            // Valid UTF-8 that isn't JSON.
            SocketServer.respond(channel, Response(id: "", payload: .failure(WireError(result: .badRequest))))
            return
        }

        guard let request = incoming.request, request.v == Request.protocolVersion else {
            SocketServer.respond(channel, Response(id: incoming.id ?? "", payload: .failure(WireError(result: .badRequest))))
            return
        }

        // A header with a bad file name still has a byte count in range, and the client writes that many bytes before
        // it reads. Those bytes are drained too, so the refusal reaches the client.
        var pending: ConnectionUpload?
        if let header = request.upload, (0...Limits.maxUploadBytes).contains(header.byteCount) {
            pending = ConnectionUpload(channel: channel, byteCount: header.byteCount)
        }
        let upload = request.upload?.isValid == true ? pending : nil
        let response = handler.handle(request, upload: upload, events: { event in
            try? channel.writeFrame(ServerFrame.event(event))
        }, peerGone: { SocketServer.peerHasLeft(fd) })
        pending?.drain()
        SocketServer.respond(channel, response)
    }

    /// True once the client has closed its end. `poll` with no wait reports a hang-up or readable bytes, then a
    /// peeking, non-blocking `recv` finds end of stream or a reset. Bytes waiting to be read mean the client is still
    /// there. Reads nothing off the socket. A client that shuts down only its write side also counts as gone; the CLI
    /// never does that, it keeps the connection open until it has read the response.
    static func peerHasLeft(_ fd: Int32) -> Bool {
        var entry = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&entry, 1, 0)
        if ready < 0 { return errno != EINTR && errno != EAGAIN }
        if ready == 0 { return false }
        if entry.revents & Int16(POLLNVAL) != 0 { return true }
        guard entry.revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 else { return false }
        var byte: UInt8 = 0
        let n = recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        if n > 0 { return false }
        if n == 0 { return true }
        return errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR
    }

    /// Writes the response. One that encodes past the frame cap is replaced by a short failure, so the client always
    /// gets an answer it can read.
    static func respond(_ channel: FrameChannel, _ response: Response) {
        do {
            try channel.writeFrame(ServerFrame.response(response))
        } catch FrameCodec.FrameError.tooLarge {
            let tooLarge = WireError.message("response too large", fix: "ask for fewer rows with -n")
            try? channel.writeFrame(ServerFrame.response(Response(id: response.id, payload: .failure(tooLarge))))
        } catch {}
    }
}

/// A request frame decoded leniently, so a malformed request still gets an answer carrying its id.
struct IncomingRequest: Decodable {
    var id: String?
    var v: Int?
    var request: Request?

    private enum Keys: String, CodingKey { case id, v }

    init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: Keys.self)
        id = try? container?.decode(String.self, forKey: .id)
        v = try? container?.decode(Int.self, forKey: .v)
        request = try? Request(from: decoder)
    }
}

/// The upload bytes on a connection, never more than the header's byte count. Used only on the connection's thread.
final class ConnectionUpload: UploadReading {
    let channel: FrameChannel
    private(set) var remaining: Int64

    init(channel: FrameChannel, byteCount: Int64) {
        self.channel = channel
        self.remaining = byteCount
    }

    func read(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard remaining > 0, buffer.count > 0 else { return 0 }
        let want = Int(min(Int64(buffer.count), remaining))
        let n = try channel.readRaw(into: UnsafeMutableRawBufferPointer(rebasing: buffer[0..<want]))
        remaining -= Int64(n)
        return n
    }

    /// Reads and drops the bytes the handler didn't take. Stops at end of stream or on an error.
    func drain() {
        guard remaining > 0 else { return }
        let scratch = UnsafeMutableRawBufferPointer.allocate(byteCount: 64 * 1024, alignment: 16)
        defer { scratch.deallocate() }
        while remaining > 0 {
            guard let n = try? read(into: scratch), n > 0 else { return }
        }
    }
}
