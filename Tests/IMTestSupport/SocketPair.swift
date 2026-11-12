import Foundation

/// A connected AF_UNIX stream socket pair for FrameChannel tests. Both ends are blocking.
public enum SocketPair {
    public struct Failure: Error, Equatable {
        public let errno: Int32
    }

    public static func make() throws -> (Int32, Int32) {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw Failure(errno: errno) }
        return (fds[0], fds[1])
    }

    /// Writes all of `data` to `fd`, looping over short writes. Test helper for the peer side.
    public static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw Failure(errno: errno)
                }
                off += n
            }
        }
    }

    /// Reads exactly `count` bytes from `fd`, or fewer if the stream ends. Test helper for the peer side.
    public static func read(_ fd: Int32, count: Int) throws -> Data {
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 65_536)
        while out.count < count {
            let n = Darwin.read(fd, &buf, min(buf.count, count - out.count))
            if n < 0 {
                if errno == EINTR { continue }
                throw Failure(errno: errno)
            }
            if n == 0 { break }
            out.append(contentsOf: buf[0..<n])
        }
        return out
    }
}
