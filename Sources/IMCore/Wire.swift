import Foundation

// Wire protocol between the CLI and the bridge over the launchd Unix socket (DESIGN.md sections 1, 3 item 7, 5).
//
// One connection carries one request:
//   1. CLI -> bridge: one frame holding a `Request`.
//   2. If `Request.upload` is set, the CLI then writes exactly `upload.byteCount` raw bytes (no framing),
//      at most `Limits.maxUploadBytes`. The bridge freezes and hashes them as they arrive.
//   3. Bridge -> CLI: zero or more `ServerFrame.event` frames, then exactly one `ServerFrame.response`.
//   4. The bridge closes the connection.
// A frame is a 4-byte big-endian length followed by that many bytes of UTF-8 JSON, at most `Limits.maxFrameBytes`.
// No SQL, path or AX expression ever crosses the socket. Ops are named and their arguments are typed (section 1).

/// Named operations. Section 1's table, plus `unread`, `wait`, `caps`, `doctor` and `ping`, which section 5's verbs need.
public enum Op: String, Codable, Sendable, CaseIterable {
    case chats, unread, messages, message, search, contacts, changes, wait, attachment
    case send, ui, allow, revoke, pending
    case caps, status, setup, doctor, ping
}

public struct ChatsArgs: Hashable, Codable, Sendable {
    public var limit: Int
    public var unreadOnly: Bool

    public init(limit: Int = Limits.defaultChatsLimit, unreadOnly: Bool = false) {
        self.limit = limit
        self.unreadOnly = unreadOnly
    }
}

public struct UnreadArgs: Hashable, Codable, Sendable {
    public var context: Int

    public init(context: Int = Limits.defaultUnreadContext) { self.context = context }
}

/// `read <who>`. At most one of `before`, `after`, `around` is set.
public struct MessagesArgs: Hashable, Codable, Sendable {
    public var who: String
    public var limit: Int
    public var before: Int64?
    public var after: Int64?
    public var around: Int64?
    public var sinceNs: AppleNanos?

    public init(who: String, limit: Int = Limits.defaultReadLimit, before: Int64? = nil, after: Int64? = nil,
                around: Int64? = nil, sinceNs: AppleNanos? = nil) {
        self.who = who
        self.limit = limit
        self.before = before
        self.after = after
        self.around = around
        self.sinceNs = sinceNs
    }
}

/// `show <rowid> [--from N]`. `--from` comes from the renderer's continuation footer (bench/renderers/ours.py).
public struct MessageArgs: Hashable, Codable, Sendable {
    public var rowid: Int64
    public var fromByte: Int

    public init(rowid: Int64, fromByte: Int = 0) {
        self.rowid = rowid
        self.fromByte = fromByte
    }
}

public struct SearchArgs: Hashable, Codable, Sendable {
    public var text: String
    public var inWho: String?
    public var sinceNs: AppleNanos?
    public var cursor: String?
    public var limit: Int

    public init(text: String, inWho: String? = nil, sinceNs: AppleNanos? = nil, cursor: String? = nil,
                limit: Int = Limits.defaultSearchLimit) {
        self.text = text
        self.inWho = inWho
        self.sinceNs = sinceNs
        self.cursor = cursor
        self.limit = limit
    }
}

public struct ContactsArgs: Hashable, Codable, Sendable {
    public var name: String

    public init(name: String) { self.name = name }
}

public struct ChangesArgs: Hashable, Codable, Sendable {
    /// `ChangeCursor.text`, or nil to get the current cursor and no rows.
    public var since: String?

    public init(since: String? = nil) { self.since = since }
}

public struct WaitArgs: Hashable, Codable, Sendable {
    public var fromWho: String?
    public var timeout: TimeInterval

    public init(fromWho: String? = nil, timeout: TimeInterval = Limits.defaultWaitTimeout) {
        self.fromWho = fromWho
        self.timeout = timeout
    }
}

public struct AttachmentArgs: Hashable, Codable, Sendable {
    /// Attachment ROWID. The CLI accepts `a9904` or `9904`.
    public var id: Int64

    public init(id: Int64) { self.id = id }
}

/// `send`. The file, if any, follows the request frame as raw bytes (`Request.upload`).
public struct SendArgs: Hashable, Codable, Sendable {
    public var who: String
    public var text: String?
    public var again: Bool
    /// Threaded reply to the chat's newest incoming message. Foreground mode only. Rejected with a file.
    public var thread: Bool
    public var approvalWait: TimeInterval

    public init(who: String, text: String?, again: Bool = false, thread: Bool = false,
                approvalWait: TimeInterval = Limits.approvalWait) {
        self.who = who
        self.text = text
        self.again = again
        self.thread = thread
        self.approvalWait = approvalWait
    }
}

/// `react`, `unsend` and `edit` go through the single `ui` op (section 1).
public enum UIActionArgs: Hashable, Codable, Sendable {
    case react(rowid: Int64, kind: TapbackKind, remove: Bool)
    case unsend(rowid: Int64)
    case edit(rowid: Int64, text: String)
}

public struct UIArgs: Hashable, Codable, Sendable {
    public var action: UIActionArgs
    public var again: Bool
    public var approvalWait: TimeInterval

    public init(action: UIActionArgs, again: Bool = false, approvalWait: TimeInterval = Limits.approvalWait) {
        self.action = action
        self.again = again
        self.approvalWait = approvalWait
    }
}

/// `allow <who> [--files]` or `allow --foreground`. Exactly one of `who` and `foreground` is set.
public struct AllowArgs: Hashable, Codable, Sendable {
    public var who: String?
    public var files: Bool
    public var foreground: Bool
    public var approvalWait: TimeInterval

    public init(who: String?, files: Bool = false, foreground: Bool = false,
                approvalWait: TimeInterval = Limits.approvalWait) {
        self.who = who
        self.files = files
        self.foreground = foreground
        self.approvalWait = approvalWait
    }
}

/// `revoke <who>` or `revoke --foreground`.
public struct RevokeArgs: Hashable, Codable, Sendable {
    public var who: String?
    public var foreground: Bool
    public var approvalWait: TimeInterval

    public init(who: String?, foreground: Bool = false, approvalWait: TimeInterval = Limits.approvalWait) {
        self.who = who
        self.foreground = foreground
        self.approvalWait = approvalWait
    }
}

/// `pending [<id>]`. With an id, the response is that request's own payload (or still `pending <id>`).
public struct PendingArgs: Hashable, Codable, Sendable {
    public var id: String?

    public init(id: String? = nil) { self.id = id }
}

public struct SetupArgs: Hashable, Codable, Sendable {
    public var stage: SetupStage

    public init(stage: SetupStage) { self.stage = stage }
}

public struct DoctorArgs: Hashable, Codable, Sendable {
    /// Raise the Accessibility prompt too (install flow step 5).
    public var wantUIActions: Bool
    /// The CLI already ran `launchctl kickstart -k` once.
    public var afterKickstart: Bool

    public init(wantUIActions: Bool = false, afterKickstart: Bool = false) {
        self.wantUIActions = wantUIActions
        self.afterKickstart = afterKickstart
    }
}

/// The typed body of a request. The case decides the op.
public enum RequestBody: Hashable, Codable, Sendable {
    case chats(ChatsArgs)
    case unread(UnreadArgs)
    case messages(MessagesArgs)
    case message(MessageArgs)
    case search(SearchArgs)
    case contacts(ContactsArgs)
    case changes(ChangesArgs)
    case wait(WaitArgs)
    case attachment(AttachmentArgs)
    case send(SendArgs)
    case ui(UIArgs)
    case allow(AllowArgs)
    case revoke(RevokeArgs)
    case pending(PendingArgs)
    case caps
    case status
    case setup(SetupArgs)
    case doctor(DoctorArgs)
    case ping

    public var op: Op {
        switch self {
        case .chats: return .chats
        case .unread: return .unread
        case .messages: return .messages
        case .message: return .message
        case .search: return .search
        case .contacts: return .contacts
        case .changes: return .changes
        case .wait: return .wait
        case .attachment: return .attachment
        case .send: return .send
        case .ui: return .ui
        case .allow: return .allow
        case .revoke: return .revoke
        case .pending: return .pending
        case .caps: return .caps
        case .status: return .status
        case .setup: return .setup
        case .doctor: return .doctor
        case .ping: return .ping
        }
    }
}

/// Raw bytes that follow the request frame (section 3 item 7).
public struct UploadHeader: Hashable, Codable, Sendable {
    public var byteCount: Int64
    /// Base name of the caller's file, for the extension and the approval dialog. Never a path.
    public var fileName: String

    public init(byteCount: Int64, fileName: String) {
        self.byteCount = byteCount
        self.fileName = fileName
    }

    /// True if the byte count is within 0...`Limits.maxUploadBytes` and the file name is a plain base name:
    /// not empty, not `.` or `..`, no `/` and no NUL, at most 255 UTF-8 bytes. The bridge refuses anything else.
    public var isValid: Bool {
        guard byteCount >= 0, byteCount <= Limits.maxUploadBytes else { return false }
        guard !fileName.isEmpty, fileName != ".", fileName != "..", fileName.utf8.count <= 255 else { return false }
        return !fileName.unicodeScalars.contains { $0 == "/" || $0 == "\u{0}" }
    }
}

public struct Request: Hashable, Codable, Sendable {
    public static let protocolVersion = 1

    public var v: Int
    /// Client-chosen id, echoed in the response, for logs.
    public var id: String
    public var body: RequestBody
    public var upload: UploadHeader?

    public init(id: String = UUID().uuidString, body: RequestBody, upload: UploadHeader? = nil) {
        self.v = Request.protocolVersion
        self.id = id
        self.body = body
        self.upload = upload
    }
}

public enum ResponsePayload: Hashable, Codable, Sendable {
    case chats(ChatsPage)
    case unread(UnreadPage)
    case messages(MessagesPage)
    case message(MessageDetail)
    case search(SearchPage)
    case contacts(ContactsPage)
    case changes(ChangesPage)
    case wait(WaitOutcome)
    case attachment(AttachmentExport)
    case send(SendOutcome)
    case ui(UIOutcome)
    case policy(PolicyOutcome)
    case pending(PendingList)
    case caps(CapsReport)
    case status(StatusReport)
    case setup(SetupReport)
    case doctor(DoctorReport)
    case pong(PongInfo)
    case failure(WireError)
}

public struct Response: Hashable, Codable, Sendable {
    public var v: Int
    public var id: String
    public var payload: ResponsePayload

    public init(id: String, payload: ResponsePayload) {
        self.v = Request.protocolVersion
        self.id = id
        self.payload = payload
    }
}

/// Progress the bridge reports before the response. The CLI prints these to stderr only.
public enum BridgeEvent: Hashable, Codable, Sendable {
    /// The native dialog is open (section 2). The CLI may print `waiting for approval on the Mac`.
    case approvalShown(id: String)
    /// The request is waiting for the queue (section 3 item 3).
    case queued
    /// Foreground mode is waiting for the user to be idle (section 4 step 2).
    case waitingForIdle
}

public enum ServerFrame: Hashable, Codable, Sendable {
    case event(BridgeEvent)
    case response(Response)
}

/// Length-prefixed JSON framing.
public enum FrameCodec {
    public enum FrameError: Error, Equatable {
        /// The frame body is over `Limits.maxFrameBytes`. Nothing past the header is read.
        case tooLarge(Int)
        /// The stream ended inside a header or a body.
        case truncated
        /// The stream ended before a frame started, the peer is gone, or the channel was closed.
        case closed
        /// SO_RCVTIMEO or SO_SNDTIMEO ran out with nothing transferred.
        case timedOut
        /// The frame body isn't valid UTF-8.
        case notUTF8
        /// Any other system call failure, with its errno.
        case system(Int32)
    }

    public static let headerBytes = 4

    /// 4-byte big-endian length, then the JSON body.
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let body = try JSONEncoder.wire.encode(value)
        guard body.count <= Limits.maxFrameBytes else { throw FrameError.tooLarge(body.count) }
        var n = UInt32(body.count).bigEndian
        var out = Data(bytes: &n, count: headerBytes)
        out.append(body)
        return out
    }

    /// Reads the length from a 4-byte header and checks it against the frame cap.
    public static func bodyLength(header: Data) throws -> Int {
        guard header.count == headerBytes else { throw FrameError.truncated }
        let n = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard n <= Limits.maxFrameBytes else { throw FrameError.tooLarge(Int(n)) }
        return Int(n)
    }

    public static func decode<T: Decodable>(_ type: T.Type, body: Data) throws -> T {
        try JSONDecoder.wire.decode(type, from: body)
    }
}

/// Blocking frame and raw-byte IO over a connected socket fd. Both the CLI and the bridge use it.
///
/// - The channel owns `fd`. `close()` or deinit closes it once.
/// - Short reads and writes loop until the whole frame or buffer has moved. `EINTR` retries the call.
/// - `setTimeouts` sets SO_RCVTIMEO and SO_SNDTIMEO. A call that waits past one of them throws
///   `FrameError.timedOut`. The timeout applies to each blocking call, so a peer that keeps sending stays connected.
/// - SO_NOSIGPIPE is set, so writing to a closed peer throws `FrameError.closed` instead of raising SIGPIPE.
/// - Reads and writes each take their own lock, so one thread can read while another writes, and two writers never
///   interleave their frames. `close()` from another thread shuts the socket down first, which wakes a blocked call.
///   The locks guard all mutable state, so the channel is `Sendable`.
public final class FrameChannel: @unchecked Sendable {
    public let fd: Int32

    private let io: SocketIO
    private let readLock = NSLock()
    private let writeLock = NSLock()
    private let stateLock = NSLock()
    private var isClosed = false

    public convenience init(fd: Int32) { self.init(fd: fd, io: .system) }

    /// Tests pass a `SocketIO` that injects short transfers, `EINTR` and timeouts.
    init(fd: Int32, io: SocketIO) {
        self.fd = fd
        self.io = io
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit { close() }

    /// Sets SO_RCVTIMEO and SO_SNDTIMEO, rounded to the nearest microsecond. Zero means no timeout. A negative or
    /// non-finite value throws `FrameError.system(EINVAL)`. A positive value that rounds to zero becomes one
    /// microsecond, so it never turns into "no timeout". Values above `Int32.max` seconds are capped there.
    public func setTimeouts(read: TimeInterval, write: TimeInterval) throws {
        try checkOpen()
        var r = try FrameChannel.timeval(read)
        var w = try FrameChannel.timeval(write)
        let size = socklen_t(MemoryLayout<timeval>.size)
        if setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &r, size) != 0 { throw FrameCodec.FrameError.system(errno) }
        if setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &w, size) != 0 { throw FrameCodec.FrameError.system(errno) }
    }

    /// Encodes `value` and writes the whole frame. Throws `tooLarge` before writing anything if the body is over the cap.
    public func writeFrame<T: Encodable>(_ value: T) throws {
        let frame = try FrameCodec.encode(value)
        writeLock.lock()
        defer { writeLock.unlock() }
        try checkOpen()
        try writeAll(frame)
    }

    /// Reads one frame and decodes it. End of stream before the header is `closed`; inside the frame it is `truncated`.
    /// A length over the cap is `tooLarge` and the body is never read. A body that isn't UTF-8 is `notUTF8`.
    public func readFrame<T: Decodable>(_ type: T.Type) throws -> T {
        readLock.lock()
        defer { readLock.unlock() }
        try checkOpen()
        var header = Data(count: FrameCodec.headerBytes)
        let got = try readExactly(into: &header)
        if got == 0 { throw FrameCodec.FrameError.closed }
        if got < FrameCodec.headerBytes { throw FrameCodec.FrameError.truncated }
        let length = try FrameCodec.bodyLength(header: header)
        var body = Data(count: length)
        if length > 0, try readExactly(into: &body) < length { throw FrameCodec.FrameError.truncated }
        guard FrameChannel.isUTF8(body) else { throw FrameCodec.FrameError.notUTF8 }
        return try FrameCodec.decode(type, body: body)
    }

    /// Writes raw upload bytes after the request frame.
    public func writeRaw(_ data: Data) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        try checkOpen()
        try writeAll(data)
    }

    /// Reads up to `max` raw bytes (at most 1 MiB per call). Returns an empty Data at end of stream.
    /// `max` must be positive, otherwise it throws `FrameError.system(EINVAL)`.
    public func readRaw(max: Int) throws -> Data {
        guard max > 0 else { throw FrameCodec.FrameError.system(EINVAL) }
        var data = Data(count: Swift.min(max, 1 << 20))
        let n = try data.withUnsafeMutableBytes { try readRaw(into: $0) }
        data.count = n
        return data
    }

    /// Reads up to `buffer.count` raw bytes into `buffer`. Returns 0 at end of stream. This is the shape the bridge's
    /// `UploadReading` needs, so it can freeze an upload without copying through Data.
    public func readRaw(into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        guard let base = buffer.baseAddress, buffer.count > 0 else { throw FrameCodec.FrameError.system(EINVAL) }
        readLock.lock()
        defer { readLock.unlock() }
        try checkOpen()
        return try readOnce(base, buffer.count)
    }

    /// Shuts the socket down, which wakes any call blocked on it, then closes the fd once both locks are free.
    /// Calling it again does nothing.
    public func close() {
        stateLock.lock()
        if isClosed {
            stateLock.unlock()
            return
        }
        isClosed = true
        stateLock.unlock()
        _ = Darwin.shutdown(fd, SHUT_RDWR)
        readLock.lock()
        writeLock.lock()
        _ = Darwin.close(fd)
        writeLock.unlock()
        readLock.unlock()
    }

    // MARK: Internals

    private func checkOpen() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        if isClosed { throw FrameCodec.FrameError.closed }
    }

    private func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let (n, err) = io.write(fd, base + offset, raw.count - offset)
                if n > 0 {
                    offset += n
                    continue
                }
                if n == 0 { throw FrameCodec.FrameError.closed }
                switch err {
                case EINTR: continue
                case EAGAIN: throw FrameCodec.FrameError.timedOut
                case EPIPE, ECONNRESET, ENOTCONN, EBADF: throw FrameCodec.FrameError.closed
                default: throw FrameCodec.FrameError.system(err)
                }
            }
        }
    }

    /// Fills `buffer` unless the stream ends first. Returns the byte count read.
    private func readExactly(into buffer: inout Data) throws -> Int {
        let want = buffer.count
        return try buffer.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Int in
            guard let base = raw.baseAddress else { return 0 }
            var offset = 0
            while offset < want {
                let n = try readOnce(base + offset, want - offset)
                if n == 0 { break }
                offset += n
            }
            return offset
        }
    }

    /// One read, retried on EINTR. Returns 0 at end of stream.
    private func readOnce(_ base: UnsafeMutableRawPointer, _ count: Int) throws -> Int {
        while true {
            let (n, err) = io.read(fd, base, count)
            if n >= 0 { return n }
            switch err {
            case EINTR: continue
            case EAGAIN: throw FrameCodec.FrameError.timedOut
            case ECONNRESET, ENOTCONN, EBADF: throw FrameCodec.FrameError.closed
            default: throw FrameCodec.FrameError.system(err)
            }
        }
    }

    static func timeval(_ t: TimeInterval) throws -> Darwin.timeval {
        guard t.isFinite, t >= 0 else { throw FrameCodec.FrameError.system(EINVAL) }
        if t == 0 { return Darwin.timeval(tv_sec: 0, tv_usec: 0) }
        let capped = Swift.min(t, Double(Int32.max))
        var sec = capped.rounded(.down)
        var usec = ((capped - sec) * 1_000_000).rounded()
        if usec >= 1_000_000 {
            sec += 1
            usec -= 1_000_000
        }
        if sec == 0 && usec == 0 { usec = 1 }
        return Darwin.timeval(tv_sec: Int(sec), tv_usec: Int32(usec))
    }

    static func isUTF8(_ data: Data) -> Bool {
        var it = data.makeIterator()
        var decoder = UTF8()
        while true {
            switch decoder.decode(&it) {
            case .scalarValue: continue
            case .emptyInput: return true
            case .error: return false
            }
        }
    }
}

/// The two system calls `FrameChannel` makes, returning the result and the errno it left.
struct SocketIO {
    var read: (Int32, UnsafeMutableRawPointer, Int) -> (Int, Int32)
    var write: (Int32, UnsafeRawPointer, Int) -> (Int, Int32)

    static let system = SocketIO(
        read: { fd, buf, n in
            let r = Darwin.read(fd, buf, n)
            return (r, r < 0 ? errno : 0)
        },
        write: { fd, buf, n in
            let r = Darwin.write(fd, buf, n)
            return (r, r < 0 ? errno : 0)
        }
    )
}

extension JSONEncoder {
    /// Encoder both sides use: sorted keys, dates as seconds since 1970.
    public static var wire: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }
}

extension JSONDecoder {
    public static var wire: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }
}
