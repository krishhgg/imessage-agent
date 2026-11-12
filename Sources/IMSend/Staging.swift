import CryptoKit
import Foundation
import ImageIO
import IMCore
import IMStore

/// The bridge's frozen copy of an upload (DESIGN.md section 3 item 7). The caller's path is never opened.
public struct FrozenFile: Hashable, Sendable {
    /// 0600 file under `Paths.uploadsDir`.
    public var url: URL
    public var byteCount: Int64
    /// SHA-256 hex of the bytes, bound into the approval and the idempotency key.
    public var sha256: String
    /// Base name from `UploadHeader.fileName`, sanitized.
    public var originalName: String
    /// ImageIO recognizes the frozen bytes as an image (BUILD-PLAN item 22). The caller's file name plays no part.
    /// IMBridge returns `unsupported` for an image send while `caps` doesn't report image sends as supported.
    public var isImage: Bool

    public init(url: URL, byteCount: Int64, sha256: String, originalName: String, isImage: Bool = false) {
        self.url = url
        self.byteCount = byteCount
        self.sha256 = sha256
        self.originalName = originalName
        self.isImage = isImage
    }
}

public enum UploadError: Error, Hashable, Sendable {
    case tooLarge
    case shortRead
    case badName
    case io(String)
}

/// Writes the raw bytes that follow the request frame into a frozen, hashed copy. Owner: IMSend.
/// Refuses more than `Limits.maxUploadBytes` and a byte count that disagrees with the header.
///
/// - A header over the limit is refused before a single byte is read.
/// - `read` is never asked for more than the bytes still owed, so the copy holds exactly `header.byteCount` bytes.
///   A stream that ends early is `shortRead`.
/// - The copy is a new 0600 file with a random name, created with `O_EXCL | O_NOFOLLOW`. The hash is taken from the
///   same bytes as they are written, so the digest the approval binds is the digest of the copy.
/// - Any failure removes the partial copy.
/// - Each call works on its own file and hasher, so several connections can freeze at once.
public final class UploadFreezer {
    public let directory: URL
    /// `Limits.maxUploadBytes` in the bridge.
    public let maxBytes: Int64

    static let chunkBytes = 64 * 1024

    public init(directory: URL) {
        self.directory = directory
        self.maxBytes = Limits.maxUploadBytes
    }

    init(directory: URL, maxBytes: Int64) {
        self.directory = directory
        self.maxBytes = maxBytes
    }

    /// `read` is called until it returns 0 bytes or `header.byteCount` is reached.
    public func freeze(header: UploadHeader, read: (UnsafeMutableRawBufferPointer) throws -> Int) throws -> FrozenFile {
        guard header.byteCount <= maxBytes else { throw UploadError.tooLarge }
        guard header.byteCount >= 0 else { throw UploadError.io("negative byte count") }
        let name = try UploadFreezer.sanitizedName(header.fileName)
        do {
            return try write(header: header, name: name, read: read)
        } catch let error as UploadError {
            throw error
        } catch {
            throw UploadError.io("\(error)")
        }
    }

    private func write(header: UploadHeader, name: String,
                       read: (UnsafeMutableRawBufferPointer) throws -> Int) throws -> FrozenFile {
        try FileSystem.makePrivateDirectory(directory)
        let url = directory.appendingPathComponent(UUID().uuidString, isDirectory: false)
        let fd = try FileSystem.createExclusive(url)
        var keep = false
        defer {
            close(fd)
            if !keep { unlink(url.path) }
        }

        var hasher = SHA256()
        var total: Int64 = 0
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: UploadFreezer.chunkBytes, alignment: 16)
        defer { buffer.deallocate() }
        while total < header.byteCount {
            let want = Int(min(Int64(UploadFreezer.chunkBytes), header.byteCount - total))
            let slice = UnsafeMutableRawBufferPointer(rebasing: buffer[0..<want])
            let got: Int
            do { got = try read(slice) } catch { throw UploadError.io("read failed: \(error)") }
            if got == 0 { throw UploadError.shortRead }
            guard got > 0, got <= want else { throw UploadError.io("reader returned \(got) for \(want) bytes") }
            let chunk = UnsafeRawBufferPointer(rebasing: slice[0..<got])
            try FileSystem.writeAll(fd, chunk)
            hasher.update(bufferPointer: chunk)
            total += Int64(got)
        }

        keep = true
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return FrozenFile(url: url, byteCount: total, sha256: digest, originalName: name,
                          isImage: UploadFreezer.isImage(at: url))
    }

    /// Removes a frozen copy. Only files directly inside `directory` are touched.
    public func discard(_ file: FrozenFile) {
        guard file.url.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path
        else { return }
        unlink(file.url.path)
    }

    /// ImageIO recognizes the bytes as one of its image types. The file has no extension, so ImageIO goes by content
    /// only. ImageIO also opens PDF, which isn't in its image type list, so a PDF isn't an image here.
    static func isImage(at url: URL) -> Bool {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let type = CGImageSourceGetType(source) as String?,
              CGImageSourceGetCount(source) > 0,
              let imageTypes = CGImageSourceCopyTypeIdentifiers() as? [String]
        else { return false }
        return imageTypes.contains(type)
    }

    /// The caller's base name for the extension and the approval dialog. A path, an empty name, `.`, `..`, a NUL or
    /// more than 255 UTF-8 bytes is `badName`. Control and format characters (bidi overrides among them, which
    /// could disguise the extension in the dialog) are dropped.
    static func sanitizedName(_ raw: String) throws -> String {
        if raw.contains("/") || raw.contains("\0") { throw UploadError.badName }
        var scalars = String.UnicodeScalarView()
        for scalar in raw.precomposedStringWithCanonicalMapping.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: continue
            default: scalars.append(scalar)
            }
        }
        let name = String(scalars).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 255 else { throw UploadError.badName }
        return name
    }
}

/// A frozen file copied into Messages' sandbox for one send.
public struct StagedFile: Hashable, Sendable {
    /// `~/Pictures/iMessage Agent/<unique name>`.
    public var url: URL
    /// The unique name the attachment row's `transfer_name` will carry (correlation key for file parts).
    public var transferName: String
    public var stagedAt: Date

    public init(url: URL, transferName: String, stagedAt: Date) {
        self.url = url
        self.transferName = transferName
        self.stagedAt = stagedAt
    }
}

public enum StagingError: Error, Hashable, Sendable {
    /// The staging folder is under `/private/var/tmp/com.apple.messages/`, where sends fail with error 25 (S2).
    case forbiddenDirectory(String)
    /// The staged bytes don't hash to the frozen file's digest, so they aren't what the approval bound.
    case digestMismatch
    case io(String)
}

/// Staging under `~/Pictures/iMessage Agent/` (section 3 item 7). Owner: IMSend.
///
/// - `stage` copies a frozen file under a unique name that keeps the original extension.
/// - `sweep` deletes a staged copy once its transfer_state reaches 5, or 10 minutes after staging, including copies
///   left by an earlier bridge run. The bridge calls it on a timer.
/// - `/private/var/tmp/com.apple.messages/` is never used (error 25 in S2).
///
/// State lives on disk: every visible regular file in `directory` is a staged copy, and its modification date is its
/// staging time (`stage` sets it from `clock.now`). That is how copies from an earlier run are found and aged.
/// `stage`, `sweep` and `hasPendingTransfers` hold one lock, so the bridge may call them from any thread.
public final class StagingArea: PendingTransferChecking {
    public let directory: URL
    public let clock: Clock
    public let rows: SendRowSource

    private let lock = NSLock()

    /// Folders that never hold a staged file, compared without case (APFS is case-insensitive by default).
    static let forbiddenRoots = ["/private/var/tmp/com.apple.messages", "/var/tmp/com.apple.messages"]
    /// Longest stem kept from the original name.
    static let maxStemLength = 40
    static let maxExtensionLength = 10

    public init(directory: URL, clock: Clock, rows: SendRowSource) {
        self.directory = directory
        self.clock = clock
        self.rows = rows
    }

    /// Copies `file` to `<directory>/<stem>-<16 hex>.<ext>`. The stem is the original stem in safe ASCII, so the
    /// transfer name compares byte for byte with what chat.db stores, and the extension is the original one.
    /// The copy is re-hashed and must match `file.sha256`.
    public func stage(_ file: FrozenFile) throws -> StagedFile {
        lock.lock()
        defer { lock.unlock() }

        try StagingArea.refuseForbidden(directory)
        do {
            try FileSystem.makePrivateDirectory(directory)
        } catch {
            throw StagingError.io("\(error)")
        }
        // The folder exists now, so a symlink to the forbidden folder resolves.
        try StagingArea.refuseForbidden(directory.resolvingSymlinksInPath())

        let stagedAt = clock.now
        for _ in 0..<8 {
            let name = StagingArea.uniqueName(for: file.originalName)
            let url = directory.appendingPathComponent(name, isDirectory: false)
            do {
                try StagingArea.copy(file, to: url)
            } catch let error as POSIXError where error.code == .EEXIST {
                continue
            } catch let error as StagingError {
                throw error
            } catch {
                throw StagingError.io("\(error)")
            }
            do {
                try FileManager.default.setAttributes([.modificationDate: stagedAt], ofItemAtPath: url.path)
            } catch {
                unlink(url.path)
                throw StagingError.io("could not set the staging time: \(error)")
            }
            return StagedFile(url: url, transferName: name, stagedAt: stagedAt)
        }
        throw StagingError.io("no unique name after 8 tries")
    }

    public func sweep() {
        lock.lock()
        defer { lock.unlock() }

        guard let files = stagedFiles(), !files.isEmpty else { return }
        // If chat.db can't be read, copies still go at 10 minutes.
        let states = (try? rows.transferStates(transferNames: files.map(\.name))) ?? [:]
        let now = clock.now
        for file in files {
            let done = states[file.name] == Limits.transferStateDone
            let expired = now.timeIntervalSince(file.stagedAt) >= Limits.stagedFileTTL
            if done || expired { unlink(file.url.path) }
        }
    }

    /// True while any staged file is waiting for transfer_state 5 (blocks the no-window relaunch).
    ///
    /// A copy is waiting until its transfer reaches 5 or fails (6), or until it is 10 minutes old and due for the
    /// sweep. A copy with no attachment row yet is waiting. If chat.db can't be read while any copy exists, or the
    /// folder exists but can't be listed, the answer is true, so Messages isn't quit in the middle of a transfer.
    public func hasPendingTransfers() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let files = stagedFiles() else { return true }
        let now = clock.now
        let live = files.filter { now.timeIntervalSince($0.stagedAt) < Limits.stagedFileTTL }
        guard !live.isEmpty else { return false }
        guard let states = try? rows.transferStates(transferNames: live.map(\.name)) else { return true }
        return live.contains { file in
            guard let state = states[file.name] else { return true }
            return state != Limits.transferStateDone && state != Limits.transferStateFailed
        }
    }

    /// Removes one staged copy right away. Used when the send stops before any Apple Event.
    func remove(_ staged: StagedFile) {
        lock.lock()
        defer { lock.unlock() }
        guard staged.url.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path
        else { return }
        unlink(staged.url.path)
    }

    // MARK: - Helpers

    private struct OnDisk {
        var url: URL
        var name: String
        var stagedAt: Date
    }

    /// Visible regular files directly in `directory`. Hidden files such as Finder's `.DS_Store` aren't staged copies.
    ///
    /// - No folder means no copies.
    /// - A symlink or a file in the folder's place holds no copies either, because `stage` refuses both. It is never
    ///   listed, so a sweep can't delete files wherever a symlink points.
    /// - Nil if the folder exists but can't be read, so callers can't tell what is staged.
    private func stagedFiles() -> [OnDisk]? {
        var info = stat()
        if lstat(directory.path, &info) != 0 { return errno == ENOENT || errno == ENOTDIR ? [] : nil }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { return [] }

        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return nil }
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let date = values.contentModificationDate else { return nil }
            return OnDisk(url: url, name: url.lastPathComponent, stagedAt: date)
        }
    }

    static func refuseForbidden(_ url: URL) throws {
        let path = url.standardizedFileURL.path.lowercased()
        for root in forbiddenRoots where path == root || path.hasPrefix(root + "/") {
            throw StagingError.forbiddenDirectory(url.path)
        }
    }

    /// `<stem>-<16 hex>.<ext>`. Characters outside ASCII letters, digits, `-` and `_` become `_` in the stem.
    /// An extension with anything but ASCII letters and digits, or longer than 10, is dropped.
    static func uniqueName(for originalName: String) -> String {
        let ns = originalName as NSString
        var ext = ns.pathExtension
        var stem = ns.deletingPathExtension
        if ext.isEmpty || ext.count > maxExtensionLength || !ext.unicodeScalars.allSatisfy(isASCIIAlphanumeric) {
            ext = ""
            stem = originalName
        }
        var safe = String(String.UnicodeScalarView(stem.unicodeScalars.map { s in
            isASCIIAlphanumeric(s) || s == "-" || s == "_" ? s : "_"
        }))
        while safe.hasPrefix("_") || safe.hasPrefix("-") { safe.removeFirst() }
        safe = String(safe.prefix(maxStemLength))
        if safe.isEmpty { safe = "file" }
        let suffix = String(format: "%016llx", UInt64.random(in: .min ... .max))
        return ext.isEmpty ? "\(safe)-\(suffix)" : "\(safe)-\(suffix).\(ext)"
    }

    private static func isASCIIAlphanumeric(_ s: Unicode.Scalar) -> Bool {
        s.isASCII && (("a"..."z").contains(s) || ("A"..."Z").contains(s) || ("0"..."9").contains(s))
    }

    /// Copies the frozen bytes into a new file and checks their digest. Throws `POSIXError(.EEXIST)` if the name is
    /// taken, so the caller can pick another.
    private static func copy(_ file: FrozenFile, to url: URL) throws {
        let input = open(file.url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard input >= 0 else { throw StagingError.io("could not open the frozen copy: errno \(errno)") }
        defer { close(input) }
        let output = try FileSystem.createExclusive(url)
        var keep = false
        defer {
            close(output)
            if !keep { unlink(url.path) }
        }

        var hasher = SHA256()
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: UploadFreezer.chunkBytes, alignment: 16)
        defer { buffer.deallocate() }
        while true {
            let got = Foundation.read(input, buffer.baseAddress, buffer.count)
            if got < 0 {
                if errno == EINTR { continue }
                throw StagingError.io("read failed: errno \(errno)")
            }
            if got == 0 { break }
            let chunk = UnsafeRawBufferPointer(rebasing: buffer[0..<got])
            try FileSystem.writeAll(output, chunk)
            hasher.update(bufferPointer: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == file.sha256 else { throw StagingError.digestMismatch }
        keep = true
    }
}

/// A file system call failed. The freezer reports it as `UploadError.io` and the staging area as `StagingError.io`.
struct FileSystemError: Error, CustomStringConvertible {
    var description: String
}

/// POSIX helpers shared by the freezer and the staging area.
enum FileSystem {
    /// Creates `url` (and parents) if needed and sets it to 0700. A symlink or non-folder at `url` is refused.
    static func makePrivateDirectory(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw FileSystemError(description: "could not create \(url.path): \(error)")
        }
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            throw FileSystemError(description: "\(url.path) isn't a folder")
        }
        if (info.st_mode & 0o777) != 0o700 { chmod(url.path, 0o700) }
    }

    /// A new 0600 file. Never follows a symlink and never opens an existing file.
    static func createExclusive(_ url: URL) throws -> Int32 {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            let code = errno
            if code == EEXIST { throw POSIXError(.EEXIST) }
            throw FileSystemError(description: "could not create \(url.lastPathComponent): errno \(code)")
        }
        return fd
    }

    static func writeAll(_ fd: Int32, _ bytes: UnsafeRawBufferPointer) throws {
        var offset = 0
        while offset < bytes.count {
            let n = write(fd, bytes.baseAddress! + offset, bytes.count - offset)
            if n < 0 {
                if errno == EINTR { continue }
                throw FileSystemError(description: "write failed: errno \(errno)")
            }
            offset += n
        }
    }
}
