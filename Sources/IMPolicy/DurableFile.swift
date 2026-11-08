import Darwin
import Foundation

/// A file system call failed while the policy store or the journal was writing or reading.
public struct StorageError: Error, Hashable, Sendable, CustomStringConvertible {
    public var operation: String
    public var path: String
    public var code: Int32

    public init(operation: String, path: String, code: Int32) {
        self.operation = operation
        self.path = path
        self.code = code
    }

    public var description: String { "\(operation) \(path): \(String(cString: strerror(code)))" }
}

/// Durable writes for the policy file and the journal (DESIGN.md sections 2 and 3 item 2).
///
/// "Flushed to disk" means `F_FULLFSYNC`, because plain `fsync` on macOS leaves the data in the drive's cache. A file
/// system that doesn't support `F_FULLFSYNC` gets `fsync`. Every file is created 0600 and every folder 0700.
enum DurableFile {
    static let fileMode: mode_t = 0o600
    static let directoryMode: mode_t = 0o700

    /// Creates `dir` and any missing parents with mode 0700. An existing folder is left as it is.
    static func ensureDirectory(_ dir: URL) throws {
        let path = dir.standardizedFileURL.path
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir) {
            if isDir.boolValue { return }
            throw StorageError(operation: "mkdir", path: path, code: ENOTDIR)
        }
        let parent = dir.standardizedFileURL.deletingLastPathComponent()
        if parent.path != path { try ensureDirectory(parent) }
        if mkdir(path, directoryMode) != 0 {
            if errno == EEXIST { return }
            throw StorageError(operation: "mkdir", path: path, code: errno)
        }
        // mkdir applies the umask, so set the mode exactly.
        guard chmod(path, directoryMode) == 0 else { throw StorageError(operation: "chmod", path: path, code: errno) }
    }

    /// Writes every byte, retrying short writes and `EINTR`.
    static func writeAll(_ fd: Int32, _ data: Data, path: String) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard var p = raw.baseAddress else { return }
            var left = raw.count
            while left > 0 {
                let n = Darwin.write(fd, p, left)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw StorageError(operation: "write", path: path, code: errno)
                }
                p += n
                left -= n
            }
        }
    }

    /// Flushes the file's data and metadata to the disk itself.
    static func flush(_ fd: Int32, path: String) throws {
        if fcntl(fd, F_FULLFSYNC) == 0 { return }
        while fsync(fd) != 0 {
            if errno == EINTR { continue }
            throw StorageError(operation: "fsync", path: path, code: errno)
        }
    }

    /// Flushes a folder so a new or renamed entry in it survives a crash.
    static func syncDirectory(_ dir: URL) throws {
        let fd = open(dir.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw StorageError(operation: "open", path: dir.path, code: errno) }
        defer { close(fd) }
        try flush(fd, path: dir.path)
    }

    /// Replaces `url` with `data` atomically: a 0600 temp file in the same folder, written and flushed, then renamed
    /// over the target, then the folder flushed. A crash leaves either the old file or the new one, never a mix, plus
    /// possibly a temp file, which the next `replace` of the same file deletes. Callers serialize their own calls.
    static func replace(_ url: URL, with data: Data) throws {
        let dir = url.deletingLastPathComponent()
        try ensureDirectory(dir)
        removeLeftoverTemps(of: url)
        let temp = dir.appendingPathComponent(tempPrefix(of: url) + "\(ShortID.make()).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, fileMode)
        guard fd >= 0 else { throw StorageError(operation: "create", path: temp.path, code: errno) }
        var renamed = false
        defer {
            if !renamed { unlink(temp.path) }
        }
        do {
            // The umask can only clear bits, but set the mode exactly anyway.
            guard fchmod(fd, fileMode) == 0 else { throw StorageError(operation: "chmod", path: temp.path, code: errno) }
            try writeAll(fd, data, path: temp.path)
            try flush(fd, path: temp.path)
        } catch {
            close(fd)
            throw error
        }
        close(fd)
        guard rename(temp.path, url.path) == 0 else {
            throw StorageError(operation: "rename", path: url.path, code: errno)
        }
        renamed = true
        try syncDirectory(dir)
    }

    /// Temp files `replace` makes for `url` are named `.<name>.<id>.tmp`.
    private static func tempPrefix(of url: URL) -> String { ".\(url.lastPathComponent)." }

    /// Deletes temp files left by a `replace` of `url` that died before its rename. Other files are left alone.
    static func removeLeftoverTemps(of url: URL) {
        let dir = url.deletingLastPathComponent()
        let prefix = tempPrefix(of: url)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names where name.hasPrefix(prefix) && name.hasSuffix(".tmp") {
            unlink(dir.appendingPathComponent(name).path)
        }
    }

    /// Appends `data` to `url` (created 0600 if missing) and flushes it before returning.
    ///
    /// If the write or the flush fails, the file is cut back to its earlier length before the error is thrown. A
    /// failed append therefore leaves no partial record, which a later append would otherwise bury in the middle of
    /// the file, where it would stop the journal from opening.
    static func append(_ url: URL, _ data: Data) throws {
        let existed = FileManager.default.fileExists(atPath: url.path)
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, fileMode)
        guard fd >= 0 else { throw StorageError(operation: "open", path: url.path, code: errno) }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw StorageError(operation: "stat", path: url.path, code: errno) }
        do {
            try writeAll(fd, data, path: url.path)
            try flush(fd, path: url.path)
        } catch {
            if ftruncate(fd, st.st_size) == 0 { try? flush(fd, path: url.path) }
            throw error
        }
        if !existed { try syncDirectory(url.deletingLastPathComponent()) }
    }

    enum ReadResult: Equatable {
        case missing
        /// Exists but isn't a regular 0600 file owned by this user, or is a symlink. The bridge never makes one.
        case foreign
        case unreadable(Int32)
        case data(Data)
    }

    /// Reads a file the bridge wrote, refusing symlinks, FIFOs and anything over `maxBytes`.
    static func read(_ url: URL, maxBytes: Int, requireOwnerOnlyMode: Bool) -> ReadResult {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            switch errno {
            case ENOENT: return .missing
            case ELOOP: return .foreign
            default: return .unreadable(errno)
            }
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { return .unreadable(errno) }
        guard (st.st_mode & S_IFMT) == S_IFREG else { return .foreign }
        if requireOwnerOnlyMode {
            guard st.st_mode & 0o777 == fileMode, st.st_uid == getuid() else { return .foreign }
        }
        guard st.st_size <= off_t(maxBytes) else { return .unreadable(EFBIG) }
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = buf.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0 {
                if errno == EINTR { continue }
                return .unreadable(errno)
            }
            if n == 0 { break }
            out.append(contentsOf: buf[0..<n])
            if out.count > maxBytes { return .unreadable(EFBIG) }
        }
        return .data(out)
    }

    /// Cuts `url` to `length` bytes and flushes it.
    static func truncate(_ url: URL, to length: Int) throws {
        let fd = open(url.path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw StorageError(operation: "open", path: url.path, code: errno) }
        defer { close(fd) }
        guard ftruncate(fd, off_t(length)) == 0 else {
            throw StorageError(operation: "truncate", path: url.path, code: errno)
        }
        try flush(fd, path: url.path)
    }
}

/// Short random ids for approvals and journal entries, typed back by `imessage pending <id>`.
enum ShortID {
    static func make() -> String {
        var g = SystemRandomNumberGenerator()
        let n = g.next() as UInt64
        return String(format: "%08llx", n & 0xffff_ffff)
    }
}
