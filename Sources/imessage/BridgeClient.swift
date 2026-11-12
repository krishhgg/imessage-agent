import Foundation
import IMCore

enum ClientError: Error, Hashable {
    /// No socket at the resolved path, or connect refused.
    case bridgeNotRunning
    /// The socket's owner uid isn't ours.
    case wrongOwner
    case protocolMismatch(Int)
    /// A system call failed before the request was sent, so nothing ran.
    case io(String)
    /// The socket path holds something other than a socket, a symlink included.
    case notSocket
    /// The request frame or its upload didn't fully reach the bridge. The bridge runs nothing for a short request.
    case requestNotDelivered(String)
    /// The request reached the bridge, but no response came back. A mutation may have run.
    case noResponse(String)
    /// The caller's file couldn't be read while it was streamed. The bridge gets a short upload and refuses it.
    case uploadFailed(String)

    /// True when the request never reached the bridge, so nothing ran (exit 3).
    var beforeDelivery: Bool {
        switch self {
        case .bridgeNotRunning, .wrongOwner, .io, .notSocket, .requestNotDelivered: return true
        case .protocolMismatch, .noResponse, .uploadFailed: return false
        }
    }
}

/// Connects to the bridge socket and runs one request (wire protocol in Sources/IMCore/Wire.swift).
/// Owner: imessage CLI.
///
/// - Socket path: `Paths.resolvedSocketPath()`. Before connecting, `lstat` the socket and refuse it unless its owner
///   uid is ours.
/// - Writes the request frame, then the upload bytes if any, then reads event frames until the response.
/// - Events go to `onEvent` (stderr). The approval wait is the bridge's; the client read timeout is the approval
///   wait plus `Limits.queueWait` plus the action's own timeouts.
///
/// `readTimeout` bounds the whole wait for the response, events included, so a bridge that keeps sending events
/// can't hold the CLI forever. Each blocking read gets the time that is left as its `SO_RCVTIMEO`.
/// If the bridge closes the connection while the upload is still streaming, the client still reads the response the
/// bridge wrote before closing, so an early refusal prints as the bridge's own error line.
///
/// The client keeps no state between calls, so several threads can run requests on one client at once.
final class BridgeClient {
    let paths: Paths
    /// The uid the socket file must belong to. Always `getuid()` outside tests.
    let ownerUID: uid_t
    /// `SO_SNDTIMEO` for each write of the request frame and the upload.
    let writeTimeout: TimeInterval

    static let defaultWriteTimeout: TimeInterval = 30
    /// The `noResponse` detail when the response wait ran out.
    static let noAnswerInTime = "no answer in time"

    init(paths: Paths = Paths()) {
        self.paths = paths
        self.ownerUID = getuid()
        self.writeTimeout = BridgeClient.defaultWriteTimeout
    }

    /// Tests pass another owner uid to reach the refusal path, and a short write timeout.
    init(paths: Paths, ownerUID: uid_t, writeTimeout: TimeInterval = BridgeClient.defaultWriteTimeout) {
        self.paths = paths
        self.ownerUID = ownerUID
        self.writeTimeout = writeTimeout
    }

    func run(_ request: Request, upload: UploadSource?, readTimeout: TimeInterval,
             onEvent: (BridgeEvent) -> Void) throws -> Response {
        let path = try socketPath()
        try checkSocket(path)
        let channel = FrameChannel(fd: try connect(path))
        defer { channel.close() }
        let deadline = ProcessInfo.processInfo.systemUptime + readTimeout
        do {
            try channel.setTimeouts(read: readTimeout, write: writeTimeout)
            try channel.writeFrame(request)
        } catch {
            throw ClientError.requestNotDelivered(BridgeClient.describe(error))
        }
        if let upload {
            do {
                try upload.stream(to: channel)
            } catch let e as ClientError {
                throw e
            } catch FrameCodec.FrameError.closed {
                // The bridge answered before it read the whole upload, then closed. Its answer is still readable.
                // With no answer, the bridge got a short upload and ran nothing.
                do {
                    return try readResponse(channel, deadline: deadline, onEvent: onEvent)
                } catch ClientError.noResponse {
                    throw ClientError.requestNotDelivered("the bridge closed the connection during the upload")
                }
            } catch {
                throw ClientError.requestNotDelivered(BridgeClient.describe(error))
            }
        }
        return try readResponse(channel, deadline: deadline, onEvent: onEvent)
    }

    /// The path launchd listens on, the same rule the LaunchAgent plist uses.
    func socketPath() throws -> String {
        do {
            return try paths.resolvedSocketPath()
        } catch {
            throw ClientError.io("the socket path is longer than \(Paths.maxSocketPathBytes) bytes")
        }
    }

    /// `lstat`, so a symlink is refused rather than followed. The file must be a socket owned by `ownerUID`.
    func checkSocket(_ path: String) throws {
        var st = stat()
        guard lstat(path, &st) == 0 else {
            let e = errno
            if e == ENOENT || e == ENOTDIR { throw ClientError.bridgeNotRunning }
            throw ClientError.io("can't check the socket: \(BridgeClient.errnoText(e))")
        }
        guard st.st_mode & S_IFMT == S_IFSOCK else { throw ClientError.notSocket }
        guard st.st_uid == ownerUID else { throw ClientError.wrongOwner }
    }

    func connect(_ path: String) throws -> Int32 {
        var addr = sockaddr_un()
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else {
            throw ClientError.io("the socket path is longer than \(Paths.maxSocketPathBytes) bytes")
        }
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ClientError.io("socket: \(BridgeClient.errnoText(errno))") }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard r == 0 else {
            let e = errno
            Darwin.close(fd)
            if e == ECONNREFUSED || e == ENOENT { throw ClientError.bridgeNotRunning }
            throw ClientError.io("connect: \(BridgeClient.errnoText(e))")
        }
        return fd
    }

    /// Event frames go to `onEvent` until the response arrives or `deadline` (system uptime) passes.
    func readResponse(_ channel: FrameChannel, deadline: TimeInterval, onEvent: (BridgeEvent) -> Void) throws -> Response {
        while true {
            let left = deadline - ProcessInfo.processInfo.systemUptime
            guard left > 0 else { throw ClientError.noResponse(BridgeClient.noAnswerInTime) }
            let frame: ServerFrame
            do {
                try channel.setTimeouts(read: left, write: writeTimeout)
            } catch FrameCodec.FrameError.system(EINVAL) {
                // macOS refuses socket options once the peer has closed. A read can't block then: it returns what
                // the bridge wrote before closing, then end of stream.
            } catch {
                throw ClientError.noResponse(BridgeClient.describe(error))
            }
            do {
                frame = try channel.readFrame(ServerFrame.self)
            } catch FrameCodec.FrameError.timedOut {
                throw ClientError.noResponse(BridgeClient.noAnswerInTime)
            } catch FrameCodec.FrameError.closed, FrameCodec.FrameError.truncated {
                throw ClientError.noResponse("the bridge closed the connection")
            } catch FrameCodec.FrameError.tooLarge {
                throw ClientError.noResponse("the answer is over \(Limits.maxFrameBytes) bytes")
            } catch is DecodingError {
                throw ClientError.noResponse("the answer isn't one this CLI can read")
            } catch {
                throw ClientError.noResponse(BridgeClient.describe(error))
            }
            switch frame {
            case .event(let e):
                onEvent(e)
            case .response(let response):
                guard response.v == Request.protocolVersion else { throw ClientError.protocolMismatch(response.v) }
                return response
            }
        }
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case FrameCodec.FrameError.timedOut: return "timed out"
        case FrameCodec.FrameError.closed: return "the bridge closed the connection"
        case FrameCodec.FrameError.truncated: return "the connection ended inside a frame"
        case FrameCodec.FrameError.tooLarge(let n): return "a frame of \(n) bytes is over the cap"
        case FrameCodec.FrameError.notUTF8: return "a frame isn't UTF-8"
        case FrameCodec.FrameError.system(let e): return errnoText(e)
        default: return "\(error)"
        }
    }

    static func errnoText(_ e: Int32) -> String { String(cString: strerror(e)) }
}

/// The caller's file, opened by the unprivileged CLI and streamed to the bridge (section 3 item 7).
/// At most `Limits.maxUploadBytes`; a larger file is a usage error before connecting.
///
/// The file is opened once, without blocking so a FIFO can't stall the open, and its size comes from `fstat` on that
/// descriptor, so the size check and the streamed bytes are the same file. Only regular files are accepted. The
/// bridge gets the byte count and the base name in `header`, never the path. `stream` sends exactly `byteCount`
/// bytes; a file that shrinks while it streams is an `uploadFailed` error.
final class UploadSource {
    let url: URL
    let byteCount: Int64
    private let fd: Int32

    static let chunkBytes = 1 << 20

    init(path: String) throws {
        self.url = URL(fileURLWithPath: path)
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            let e = errno
            throw UsageError(message: "can't open \(ArgumentParser.quoted(path)): \(BridgeClient.errnoText(e))",
                             fix: "check the path and that you can read the file")
        }
        var st = stat()
        guard fstat(fd, &st) == 0 else {
            let e = errno
            Darwin.close(fd)
            throw UsageError(message: "can't read \(ArgumentParser.quoted(path)): \(BridgeClient.errnoText(e))",
                             fix: "check the path and that you can read the file")
        }
        guard st.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(fd)
            throw UsageError(message: "\(ArgumentParser.quoted(path)) isn't a regular file",
                             fix: "pass a file, not a folder, pipe or device")
        }
        guard Int64(st.st_size) <= Limits.maxUploadBytes else {
            Darwin.close(fd)
            throw UsageError(message: "\(ArgumentParser.quoted(url.lastPathComponent)) is \(st.st_size) bytes, "
                                + "over the \(Limits.maxUploadBytes / 1_000_000) MB limit",
                             fix: "send a file of \(Limits.maxUploadBytes) bytes or less")
        }
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) }
        self.fd = fd
        self.byteCount = Int64(st.st_size)
        guard header.isValid else {
            throw UsageError(message: "the file name \(ArgumentParser.quoted(url.lastPathComponent)) can't be sent",
                             fix: "rename the file to a name of 255 bytes or less")
        }
    }

    deinit { Darwin.close(fd) }

    var header: UploadHeader { UploadHeader(byteCount: byteCount, fileName: url.lastPathComponent) }

    /// Writes exactly `byteCount` bytes from the start of the file. Read failures throw `ClientError.uploadFailed`;
    /// write failures throw the channel's `FrameError`.
    func stream(to channel: FrameChannel) throws {
        var offset: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: UploadSource.chunkBytes)
        while offset < byteCount {
            let want = Int(min(Int64(UploadSource.chunkBytes), byteCount - offset))
            let n = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, want, off_t(offset)) }
            if n < 0 {
                let e = errno
                if e == EINTR { continue }
                throw ClientError.uploadFailed("\(url.lastPathComponent): \(BridgeClient.errnoText(e))")
            }
            if n == 0 {
                throw ClientError.uploadFailed("\(url.lastPathComponent) got shorter while it was sent")
            }
            try channel.writeRaw(Data(buffer[0..<n]))
            offset += Int64(n)
        }
    }
}
