import Foundation
import IMCore
import ImageIO

/// `attachment <id>` (DESIGN.md section 1). Owner: IMStore.
///
/// - Looks up `attachment.filename` by ROWID, maps `~/Library/Messages/Attachments/` to `attachmentsRoot`,
///   resolves it with realpath, and refuses anything outside `attachmentsRoot`.
/// - Copies the file into the 0700 cache so the unprivileged agent can read it (the original is behind FDA).
/// - Converts HEIC to JPEG with the long side at most 1600 px, only when `convertHEIC` is true. IMBridge passes
///   true only while `caps` reports `att` conversion supported (release test 8). With false, the cache holds an
///   unconverted copy and `converted` is false.
/// - Cache entries expire after 24 h (release test 8).
/// - iCloud-offloaded files (no file on disk) return `not_downloaded`.
public final class AttachmentService {
    public let db: ChatDatabase
    public let clock: Clock

    public init(db: ChatDatabase, clock: Clock) {
        self.db = db
        self.clock = clock
    }

    /// Exports one attachment into the cache.
    ///
    /// Throws `StoreError.notFound` for an unknown ROWID and for a filename or real path outside the Attachments
    /// root. A missing file is `not_downloaded`. The copy is written to a 0600 temporary file in the cache, its
    /// modification time set from `clock`, then renamed to `a<id>.<ext>` (`.jpg` when converted).
    public func export(_ args: AttachmentArgs, convertHEIC: Bool) throws -> AttachmentExport {
        let root = db.configuration.attachmentsRoot
        let (row, record) = try db.interactive { s -> (AttachmentRow, AttachmentRecord) in
            var found: AttachmentRow?
            try s.each(SQLText.shared.attachmentByID, [.int(args.id)], limit: 1) { found = AttachmentRow($0) }
            guard let row = found else { throw StoreError.notFound("attachment a\(args.id)") }
            let message = try row.messageRowID.flatMap { try s.row(id: $0) }
            return (row, row.record(runs: message?.runs ?? [], isAudioMessage: message?.isAudio ?? false, root: root))
        }
        let notDownloaded = AttachmentExport(attachment: record, path: nil, converted: false,
                                             result: ActionResult(.notDownloaded))
        guard let filename = row.filename, !filename.isEmpty else { return notDownloaded }
        let outside = StoreError.notFound("attachment a\(args.id) is outside the Attachments folder")
        guard let mapped = AttachmentPaths.mapped(filename, root: root) else { throw outside }

        guard let real = AttachmentService.realPath(mapped.path) else {
            if errno == ENOENT || errno == ENOTDIR { return notDownloaded }
            throw AttachmentError.io("cannot resolve attachment a\(args.id): \(String(cString: strerror(errno)))")
        }
        guard let rootReal = AttachmentService.realPath(root.path),
              AttachmentService.contains(real, in: rootReal) else { throw outside }

        // O_NONBLOCK keeps a FIFO from blocking the open. Reads from a regular file ignore it.
        let fd = open(real, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else {
            if errno == ENOENT { return notDownloaded }
            throw AttachmentError.io("cannot open attachment a\(args.id): \(String(cString: strerror(errno)))")
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else {
            throw AttachmentError.io("attachment a\(args.id) is not a regular file")
        }
        guard let opened = AttachmentService.descriptorPath(fd), AttachmentService.contains(opened, in: rootReal) else {
            throw outside
        }

        let cache = try ensureCacheDirectory()
        let ext = AttachmentService.fileExtension(record.transferName.isEmpty ? filename : record.transferName)
        if convertHEIC, AttachmentService.looksLikeHEIC(row, ext: ext) {
            let data = try AttachmentService.readAll(fd, limit: AttachmentService.maxImageBytes)
            if HEICConverter.isHEIC(data) {
                let jpeg = try HEICConverter.jpegData(from: data, maxPixel: Limits.heicMaxPixel)
                let path = try writeEntry(named: "a\(args.id).jpg", in: cache) { out in
                    try AttachmentService.write(jpeg, to: out)
                }
                return AttachmentExport(attachment: record, path: path, converted: true, result: nil)
            }
            let path = try writeEntry(named: AttachmentService.entryName(args.id, ext), in: cache) { out in
                try AttachmentService.write(data, to: out)
            }
            return AttachmentExport(attachment: record, path: path, converted: false, result: nil)
        }
        let path = try writeEntry(named: AttachmentService.entryName(args.id, ext), in: cache) { out in
            try AttachmentService.copy(from: fd, to: out)
        }
        return AttachmentExport(attachment: record, path: path, converted: false, result: nil)
    }

    /// Deletes cache entries older than `Limits.attachmentCacheTTL`. The bridge calls it at start and hourly.
    /// An entry expires once its age reaches the TTL. Directories in the cache are left alone.
    public func purgeExpiredCache() throws {
        let dir = db.configuration.attachmentCacheDir.path
        var st = stat()
        guard lstat(dir, &st) == 0 else {
            if errno == ENOENT { return }
            throw AttachmentError.io("cannot read the attachment cache: \(String(cString: strerror(errno)))")
        }
        try AttachmentService.checkPrivate(st, path: dir)
        let now = clock.now.timeIntervalSince1970
        for name in try FileManager.default.contentsOfDirectory(atPath: dir) {
            let path = dir + "/" + name
            var entry = stat()
            guard lstat(path, &entry) == 0 else { continue }
            let kind = entry.st_mode & S_IFMT
            guard kind == S_IFREG || kind == S_IFLNK else { continue }
            let mtime = TimeInterval(entry.st_mtimespec.tv_sec) + TimeInterval(entry.st_mtimespec.tv_nsec) / 1e9
            if now - mtime >= Limits.attachmentCacheTTL { unlink(path) }
        }
    }

    /// realpath check: true only for a regular file inside `root` after symlinks are resolved.
    public static func isInside(_ path: String, root: URL) -> Bool {
        guard let real = realPath(path), let rootReal = realPath(root.path), contains(real, in: rootReal) else {
            return false
        }
        var st = stat()
        return lstat(real, &st) == 0 && st.st_mode & S_IFMT == S_IFREG
    }

    // MARK: Paths

    /// Largest image read into memory for conversion.
    static let maxImageBytes = 256 << 20

    static func realPath(_ path: String) -> String? {
        guard !path.contains("\u{0}"), let p = realpath(path, nil) else { return nil }
        defer { free(p) }
        return String(cString: p)
    }

    /// Byte-wise prefix test, so Unicode equivalence never widens what counts as inside.
    static func contains(_ path: String, in root: String) -> Bool {
        let prefix = Array((root.hasSuffix("/") ? root : root + "/").utf8)
        let bytes = Array(path.utf8)
        return bytes.count > prefix.count && bytes.starts(with: prefix)
    }

    /// The path the kernel reports for an open descriptor.
    static func descriptorPath(_ fd: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// Lowercased extension of a file name, letters and digits only, at most 10 characters.
    static func fileExtension(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        let safe = ext.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
        guard !ext.isEmpty, ext.count <= 10, safe else { return "" }
        return ext
    }

    static func entryName(_ id: Int64, _ ext: String) -> String { ext.isEmpty ? "a\(id)" : "a\(id).\(ext)" }

    static func looksLikeHEIC(_ row: AttachmentRow, ext: String) -> Bool {
        let uti = (row.uti ?? "").lowercased()
        let mime = (row.mimeType ?? "").lowercased()
        return ["public.heic", "public.heif"].contains(uti) || ["image/heic", "image/heif"].contains(mime)
            || ["heic", "heif"].contains(ext)
    }

    // MARK: Cache

    /// Creates the cache when missing and checks it is a real directory owned by this user, then sets it to 0700.
    func ensureCacheDirectory() throws -> String {
        let dir = db.configuration.attachmentCacheDir.path
        var st = stat()
        if lstat(dir, &st) != 0 {
            guard errno == ENOENT else {
                throw AttachmentError.io("cannot read the attachment cache: \(String(cString: strerror(errno)))")
            }
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            guard lstat(dir, &st) == 0 else { throw AttachmentError.io("cannot create the attachment cache") }
        }
        try AttachmentService.checkPrivate(st, path: dir)
        if st.st_mode & 0o777 != 0o700, chmod(dir, 0o700) != 0 {
            throw AttachmentError.unsafeCache("cannot set the attachment cache to 0700")
        }
        return dir
    }

    static func checkPrivate(_ st: stat, path: String) throws {
        guard st.st_mode & S_IFMT == S_IFDIR else {
            throw AttachmentError.unsafeCache("\(path) is not a directory")
        }
        guard st.st_uid == getuid() else { throw AttachmentError.unsafeCache("\(path) belongs to another user") }
    }

    /// Writes through a 0600 temporary file, sets its modification time from the clock and renames it into place.
    func writeEntry(named name: String, in dir: String, _ fill: (Int32) throws -> Void) throws -> String {
        let final = dir + "/" + name
        let temp = dir + "/." + name + "." + UUID().uuidString + ".tmp"
        let out = open(temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard out >= 0 else {
            throw AttachmentError.io("cannot write to the attachment cache: \(String(cString: strerror(errno)))")
        }
        var renamed = false
        defer { if !renamed { unlink(temp) } }
        do {
            try fill(out)
            fchmod(out, 0o600)
            let now = clock.now.timeIntervalSince1970
            var times = [timeval(tv_sec: Int(now.rounded(.down)), tv_usec: Int32((now - now.rounded(.down)) * 1e6)),
                         timeval(tv_sec: Int(now.rounded(.down)), tv_usec: Int32((now - now.rounded(.down)) * 1e6))]
            guard futimes(out, &times) == 0 else { throw AttachmentError.io("cannot set the cache entry time") }
        } catch {
            close(out)
            throw error
        }
        guard close(out) == 0 else { throw AttachmentError.io("cannot finish the cache entry") }
        guard rename(temp, final) == 0 else {
            throw AttachmentError.io("cannot move the cache entry into place: \(String(cString: strerror(errno)))")
        }
        renamed = true
        return final
    }

    // MARK: I/O

    static func copy(from input: Int32, to output: Int32) throws {
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(input, $0.baseAddress, $0.count) }
            if n == 0 { return }
            if n < 0 {
                if errno == EINTR { continue }
                throw AttachmentError.io("cannot read the attachment: \(String(cString: strerror(errno)))")
            }
            try buffer.withUnsafeBytes { try writeFully(output, UnsafeRawBufferPointer(rebasing: $0[0..<n])) }
        }
    }

    static func readAll(_ fd: Int32, limit: Int) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n == 0 { return data }
            if n < 0 {
                if errno == EINTR { continue }
                throw AttachmentError.io("cannot read the attachment: \(String(cString: strerror(errno)))")
            }
            guard data.count + n <= limit else { throw AttachmentError.conversion("image is too large to convert") }
            data.append(contentsOf: buffer[0..<n])
        }
    }

    static func write(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { try writeFully(fd, $0) }
    }

    static func writeFully(_ fd: Int32, _ bytes: UnsafeRawBufferPointer) throws {
        var offset = 0
        while offset < bytes.count {
            let n = Darwin.write(fd, bytes.baseAddress! + offset, bytes.count - offset)
            if n < 0 {
                if errno == EINTR { continue }
                throw AttachmentError.io("cannot write to the attachment cache: \(String(cString: strerror(errno)))")
            }
            offset += n
        }
    }
}

/// Failures while exporting an attachment. IMBridge maps them to one-line errors.
public enum AttachmentError: Error, Equatable {
    /// The cache path is a symlink, not a directory, or belongs to another user.
    case unsafeCache(String)
    /// Reading the original or writing the copy failed.
    case io(String)
    /// ImageIO could not read or write the image.
    case conversion(String)
}

/// HEIC to JPEG through ImageIO, thumbnail with kCGImageSourceThumbnailMaxPixelSize. Owner: IMStore.
public enum HEICConverter {
    static let jpegQuality = 0.85

    public static func convertToJPEG(source: URL, destination: URL, maxPixel: Int = Limits.heicMaxPixel) throws {
        let data: Data
        do {
            data = try Data(contentsOf: source)
        } catch {
            throw AttachmentError.io("cannot read \(source.lastPathComponent)")
        }
        let jpeg = try jpegData(from: data, maxPixel: maxPixel)
        do {
            try jpeg.write(to: destination, options: .atomic)
        } catch {
            throw AttachmentError.io("cannot write \(destination.lastPathComponent)")
        }
    }

    /// True when ImageIO reads the data as HEIC or HEIF.
    static func isHEIC(_ data: Data) -> Bool {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(src) as String? else { return false }
        return ["public.heic", "public.heif", "public.heics"].contains(type)
    }

    /// A JPEG of the first image, oriented, with the long side at most `maxPixel`. Smaller images keep their size.
    static func jpegData(from data: Data, maxPixel: Int) throws -> Data {
        guard maxPixel > 0 else { throw AttachmentError.conversion("bad size limit") }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(src) > 0 else {
            throw AttachmentError.conversion("ImageIO cannot read the image")
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
            throw AttachmentError.conversion("ImageIO cannot decode the image")
        }
        let out = NSMutableData()
        let jpeg = "public.jpeg" as CFString
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, jpeg, 1, nil) else {
            throw AttachmentError.conversion("ImageIO cannot write JPEG")
        }
        let quality = [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary
        CGImageDestinationAddImage(dest, image, quality)
        guard CGImageDestinationFinalize(dest) else { throw AttachmentError.conversion("JPEG encoding failed") }
        return out as Data
    }
}
