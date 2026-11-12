import CoreGraphics
import Foundation
import ImageIO
import XCTest
import IMCore
@testable import IMStore
import IMTestSupport

/// Checklist item 16: realpath and root refusal, the 0700 cache, HEIC to JPEG at 1600 px only when asked,
/// 24 h expiry and `not_downloaded`.
final class AttachmentTests: XCTestCase {
    private let photo: Int64 = 9014
    private var photoFile: URL {
        Fixture.attachmentsRoot.appendingPathComponent("76/09/CBF6F44C-5BD1-4B89-9C7E-1D3801BC9BAD/IMG_4420.HEIC")
    }

    private func service(db: String = Fixture.chatDB.path, root: URL = Fixture.attachmentsRoot, cache: URL? = nil,
                         clock: FakeClock = FakeClock()) throws -> AttachmentService {
        let config = TestStore.configuration(db: db, root: root, cache: cache)
        return AttachmentService(db: try TestStore.database(config, clock: clock), clock: clock)
    }

    private func mode(_ path: String) -> mode_t {
        var st = stat()
        XCTAssertEqual(lstat(path, &st), 0, path)
        return st.st_mode & 0o7777
    }

    private func pixelSize(_ data: Data) -> (Int, Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (w, h)
    }

    private func image(width: Int, height: Int, type: String) -> Data? {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cg = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, type as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    /// A fixture copy whose attachment 9014 names `filename`.
    private func copy(filename: String?) throws -> FixtureCopy {
        let copy = try FixtureCopy()
        let value = filename.map { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" } ?? "NULL"
        try copy.exec("UPDATE attachment SET filename = \(value) WHERE ROWID = \(photo)")
        return copy
    }

    private func assertOutside(_ body: @autoclosure () throws -> AttachmentExport, file: StaticString = #filePath,
                               line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            guard case StoreError.notFound(let what) = error, what.contains("outside the Attachments folder") else {
                return XCTFail("\(error)", file: file, line: line)
            }
        }
    }

    // MARK: Export

    func testHEICConvertsToAJPEGInThePrivateCache() throws {
        let cache = TempDir.make().appendingPathComponent("cache")
        let export = try service(cache: cache).export(AttachmentArgs(id: photo), convertHEIC: true)
        XCTAssertTrue(export.converted)
        XCTAssertNil(export.result)
        XCTAssertEqual(export.attachment.rowid, photo)
        XCTAssertEqual(export.attachment.kind, .photo)
        XCTAssertEqual(export.attachment.transferName, "IMG_4420.HEIC")
        let path = try XCTUnwrap(export.path)
        XCTAssertEqual(path, cache.path + "/a9014.jpg")
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertEqual(Array(data.prefix(3)), [0xFF, 0xD8, 0xFF])
        XCTAssertEqual(CGImageSourceGetType(CGImageSourceCreateWithData(data as CFData, nil)!) as String?, "public.jpeg")
        let size = try XCTUnwrap(pixelSize(data))
        XCTAssertEqual(size.0, 64)
        XCTAssertEqual(size.1, 48)
        XCTAssertEqual(mode(path), 0o600)
        XCTAssertEqual(mode(cache.path), 0o700)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.path), ["a9014.jpg"])
    }

    func testWithoutConversionTheCacheHoldsAnExactCopy() throws {
        let cache = TempDir.make().appendingPathComponent("cache")
        let export = try service(cache: cache).export(AttachmentArgs(id: photo), convertHEIC: false)
        XCTAssertFalse(export.converted)
        XCTAssertEqual(export.path, cache.path + "/a9014.heic")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: export.path!)), try Data(contentsOf: photoFile))
        XCTAssertEqual(mode(export.path!), 0o600)
    }

    func testNonImagesAreCopiedEvenWhenConversionIsOn() throws {
        let svc = try service()
        let pdf = try svc.export(AttachmentArgs(id: 9011), convertHEIC: true)
        XCTAssertFalse(pdf.converted)
        XCTAssertTrue(pdf.path!.hasSuffix("/a9011.pdf"))
        let source = Fixture.attachmentsRoot
            .appendingPathComponent("f8/01/4CFD9F41-6467-441F-91C0-52B068179B02/Insurance_Renewal_2026.pdf")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: pdf.path!)), try Data(contentsOf: source))
        let voice = try svc.export(AttachmentArgs(id: 9008), convertHEIC: true)
        XCTAssertTrue(voice.path!.hasSuffix("/a9008.caf"))
        XCTAssertEqual(voice.attachment.kind, .voice)
    }

    func testFileLabeledHEICThatIsNotHEICIsCopiedUnconverted() throws {
        let copy = try FixtureCopy()
        try copy.exec("""
            UPDATE attachment SET uti = 'public.heic', mime_type = 'image/heic', transfer_name = 'fake.heic'
            WHERE ROWID = 9011
            """)
        let export = try service(db: copy.path).export(AttachmentArgs(id: 9011), convertHEIC: true)
        XCTAssertFalse(export.converted)
        XCTAssertTrue(export.path!.hasSuffix("/a9011.heic"))
        XCTAssertEqual(Array(try Data(contentsOf: URL(fileURLWithPath: export.path!)).prefix(4)), Array("%PDF".utf8))
    }

    func testLargeHEICIsScaledToALongSideOf1600() throws {
        guard let heic = image(width: 3200, height: 2400, type: "public.heic") else {
            throw XCTSkip("this Mac cannot encode HEIC")
        }
        let root = TempDir.make().appendingPathComponent("Attachments")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("aa/01"), withIntermediateDirectories: true)
        try heic.write(to: root.appendingPathComponent("aa/01/big.HEIC"))
        let db = try copy(filename: "~/Library/Messages/Attachments/aa/01/big.HEIC")
        let svc = try service(db: db.path, root: root)
        let export = try svc.export(AttachmentArgs(id: photo), convertHEIC: true)
        XCTAssertTrue(export.converted)
        let size = try XCTUnwrap(pixelSize(try Data(contentsOf: URL(fileURLWithPath: export.path!))))
        XCTAssertEqual(size.0, 1600)
        XCTAssertEqual(size.1, 1200)
        let plain = try svc.export(AttachmentArgs(id: photo), convertHEIC: false)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: plain.path!)), heic)
    }

    func testOffloadedAndMissingFilesAreNotDownloaded() throws {
        let svc = try service()
        for convert in [true, false] {
            let export = try svc.export(AttachmentArgs(id: 9001), convertHEIC: convert)
            XCTAssertEqual(export.result, ActionResult(.notDownloaded))
            XCTAssertNil(export.path)
            XCTAssertFalse(export.converted)
            XCTAssertFalse(export.attachment.onDisk)
            XCTAssertEqual(export.attachment.rowid, 9001)
        }
        for name in [nil, "", "~/Library/Messages/Attachments/zz/none.heic",
                     "~/Library/Messages/Attachments/76/09/CBF6F44C-5BD1-4B89-9C7E-1D3801BC9BAD/IMG_4420.HEIC/x"] {
            let db = try copy(filename: name)
            let export = try service(db: db.path).export(AttachmentArgs(id: photo), convertHEIC: true)
            XCTAssertEqual(export.result?.code, .notDownloaded, name ?? "NULL")
            XCTAssertNil(export.path)
        }
    }

    func testUnknownAttachmentThrowsNotFound() throws {
        XCTAssertThrowsError(try service().export(AttachmentArgs(id: 1), convertHEIC: true)) { error in
            XCTAssertEqual(error as? StoreError, .notFound("attachment a1"))
        }
    }

    func testFilenamesOutsideTheRootAreRefused() throws {
        let cache = TempDir.make().appendingPathComponent("cache")
        for name in ["~/Library/Messages/Attachments/../../../../../../etc/hosts", "/etc/hosts",
                     "~/Library/Messages/Attachments/../chat.db", "Attachments/76/09/x.heic", "~/etc/hosts",
                     "~/Library/Messages/AttachmentsX/a.heic", "~/Library/Messages/Attachments/",
                     Fixture.attachmentsRoot.path + "/../chat.db", Fixture.attachmentsRoot.path + "2/x.heic"] {
            let db = try copy(filename: name)
            assertOutside(try service(db: db.path, cache: cache).export(AttachmentArgs(id: photo), convertHEIC: true))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
    }

    func testAbsolutePathInsideTheRootIsAccepted() throws {
        let db = try copy(filename: photoFile.path)
        let export = try service(db: db.path).export(AttachmentArgs(id: photo), convertHEIC: false)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: export.path!)), try Data(contentsOf: photoFile))
    }

    func testSymlinksThatLeaveTheRootAreRefused() throws {
        let base = TempDir.make()
        let root = base.appendingPathComponent("Attachments")
        let outsideDir = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("aa/01"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: outsideDir.appendingPathComponent("secret.heic"))
        try Data("inside".utf8).write(to: root.appendingPathComponent("aa/01/real.heic"))
        let fm = FileManager.default
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("aa/01/file.heic").path,
                                  withDestinationPath: outsideDir.appendingPathComponent("secret.heic").path)
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("dir").path, withDestinationPath: outsideDir.path)
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("aa/01/inner.heic").path,
                                  withDestinationPath: root.appendingPathComponent("aa/01/real.heic").path)
        for name in ["aa/01/file.heic", "dir/secret.heic"] {
            let db = try copy(filename: "~/Library/Messages/Attachments/" + name)
            assertOutside(try service(db: db.path, root: root).export(AttachmentArgs(id: photo), convertHEIC: false))
        }
        let db = try copy(filename: "~/Library/Messages/Attachments/aa/01/inner.heic")
        let inner = try service(db: db.path, root: root).export(AttachmentArgs(id: photo), convertHEIC: false)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: inner.path!)), Data("inside".utf8))
    }

    func testDirectoriesAndFIFOsAreNotExported() throws {
        let root = TempDir.make().appendingPathComponent("Attachments")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("aa/dir.heic"), withIntermediateDirectories: true)
        XCTAssertEqual(mkfifo(root.appendingPathComponent("aa/pipe.heic").path, 0o600), 0)
        for name in ["aa/dir.heic", "aa/pipe.heic"] {
            let db = try copy(filename: "~/Library/Messages/Attachments/" + name)
            let svc = try service(db: db.path, root: root)
            let done = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var outcome: Result<AttachmentExport, Error>?
            DispatchQueue.global().async {
                outcome = Result { try svc.export(AttachmentArgs(id: self.photo), convertHEIC: false) }
                done.signal()
            }
            XCTAssertEqual(done.wait(timeout: .now() + 5), .success, "\(name) blocked")
            guard case .failure(let error)? = outcome else { return XCTFail("\(name) exported") }
            guard case AttachmentError.io = error else { return XCTFail("\(name): \(error)") }
        }
    }

    func testConcurrentExportsLeaveOneCompleteEntry() throws {
        let cache = TempDir.make().appendingPathComponent("cache")
        let svc = try service(cache: cache)
        let failures = Counter()
        DispatchQueue.concurrentPerform(iterations: 16) { i in
            do { _ = try svc.export(AttachmentArgs(id: photo), convertHEIC: i % 2 == 0) } catch { failures.add() }
        }
        XCTAssertEqual(failures.value, 0)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: cache.path)), ["a9014.jpg", "a9014.heic"])
        XCTAssertEqual(try Data(contentsOf: cache.appendingPathComponent("a9014.heic")), try Data(contentsOf: photoFile))
    }

    // MARK: Cache

    func testCacheDirectoryIsTightenedTo0700() throws {
        let cache = TempDir.make().appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        XCTAssertEqual(mode(cache.path), 0o755)
        _ = try service(cache: cache).export(AttachmentArgs(id: photo), convertHEIC: false)
        XCTAssertEqual(mode(cache.path), 0o700)
        let nested = TempDir.make().appendingPathComponent("a/b/cache")
        _ = try service(cache: nested).export(AttachmentArgs(id: photo), convertHEIC: false)
        XCTAssertEqual(mode(nested.path), 0o700)
    }

    func testSymlinkedOrNonDirectoryCacheIsRefused() throws {
        let base = TempDir.make()
        let target = base.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let link = base.appendingPathComponent("cache-link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
        let file = base.appendingPathComponent("cache-file")
        try Data().write(to: file)
        for cache in [link, file] {
            let svc = try service(cache: cache)
            XCTAssertThrowsError(try svc.export(AttachmentArgs(id: photo), convertHEIC: false)) { error in
                guard case AttachmentError.unsafeCache = error else { return XCTFail("\(error)") }
            }
            XCTAssertThrowsError(try svc.purgeExpiredCache()) { error in
                guard case AttachmentError.unsafeCache = error else { return XCTFail("\(error)") }
            }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), [])
    }

    func testCacheEntriesExpireAtExactly24Hours() throws {
        XCTAssertEqual(Limits.attachmentCacheTTL, 86_400)
        let cache = TempDir.make().appendingPathComponent("cache")
        let clock = FakeClock()
        let svc = try service(cache: cache, clock: clock)
        let path = try XCTUnwrap(try svc.export(AttachmentArgs(id: photo), convertHEIC: false).path)
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let mtime = try XCTUnwrap(attrs[.modificationDate] as? Date)
        XCTAssertEqual(mtime.timeIntervalSince1970, Fixture.now.timeIntervalSince1970, accuracy: 0.001)
        try FileManager.default.createDirectory(at: cache.appendingPathComponent("keep"), withIntermediateDirectories: false)
        clock.advance(86_399)
        try svc.purgeExpiredCache()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        clock.advance(1)
        try svc.purgeExpiredCache()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.appendingPathComponent("keep").path))
    }

    func testReExportRestartsTheClock() throws {
        let cache = TempDir.make().appendingPathComponent("cache")
        let clock = FakeClock()
        let svc = try service(cache: cache, clock: clock)
        let path = try svc.export(AttachmentArgs(id: photo), convertHEIC: false).path!
        clock.advance(86_000)
        _ = try svc.export(AttachmentArgs(id: photo), convertHEIC: false)
        clock.advance(1_000)
        try svc.purgeExpiredCache()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testPurgeWithoutACacheDoesNothing() throws {
        let cache = TempDir.make().appendingPathComponent("missing")
        try service(cache: cache).purgeExpiredCache()
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
    }

    // MARK: Conversion

    func testLongSideIsAtMost1600AndSmallerImagesKeepTheirSize() throws {
        let cases: [(Int, Int, Int, Int)] = [(1600, 800, 1600, 800), (1601, 800, 1600, 799), (3200, 2400, 1600, 1200),
                                             (2400, 3200, 1200, 1600), (800, 600, 800, 600), (1, 1, 1, 1)]
        for (w, h, ew, eh) in cases {
            let png = try XCTUnwrap(image(width: w, height: h, type: "public.png"))
            let jpeg = try HEICConverter.jpegData(from: png, maxPixel: Limits.heicMaxPixel)
            let size = try XCTUnwrap(pixelSize(jpeg))
            XCTAssertEqual(max(size.0, size.1), max(ew, eh), "\(w)x\(h)")
            XCTAssertLessThanOrEqual(abs(size.0 - ew) + abs(size.1 - eh), 1, "\(w)x\(h) gave \(size)")
            XCTAssertEqual(Array(jpeg.prefix(2)), [0xFF, 0xD8])
        }
    }

    func testConversionRejectsBadInput() {
        XCTAssertThrowsError(try HEICConverter.jpegData(from: Data("not an image".utf8), maxPixel: 1600)) { error in
            guard case AttachmentError.conversion = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try HEICConverter.jpegData(from: Data(), maxPixel: 1600))
        let png = image(width: 10, height: 10, type: "public.png")!
        XCTAssertThrowsError(try HEICConverter.jpegData(from: png, maxPixel: 0))
    }

    func testHEICDetectionReadsTheBytes() throws {
        XCTAssertTrue(HEICConverter.isHEIC(try Data(contentsOf: photoFile)))
        XCTAssertFalse(HEICConverter.isHEIC(image(width: 4, height: 4, type: "public.png")!))
        XCTAssertFalse(HEICConverter.isHEIC(Data("%PDF-1.4".utf8)))
        XCTAssertFalse(HEICConverter.isHEIC(Data()))
    }

    func testConvertToJPEGWritesAFile() throws {
        let out = TempDir.make().appendingPathComponent("out.jpg")
        try HEICConverter.convertToJPEG(source: photoFile, destination: out)
        let data = try Data(contentsOf: out)
        XCTAssertEqual(Array(data.prefix(2)), [0xFF, 0xD8])
        XCTAssertThrowsError(try HEICConverter.convertToJPEG(source: TempDir.make().appendingPathComponent("none.heic"),
                                                             destination: out)) { error in
            guard case AttachmentError.io = error else { return XCTFail("\(error)") }
        }
    }

    // MARK: Path checks

    func testIsInsideResolvesSymlinksAndNeedsARegularFile() throws {
        let base = TempDir.make()
        let root = base.appendingPathComponent("root")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("d"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent("d/f"))
        try Data("x".utf8).write(to: base.appendingPathComponent("outside"))
        try FileManager.default.createDirectory(at: base.appendingPathComponent("root2"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: base.appendingPathComponent("root2/f"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("out").path,
                                                   withDestinationPath: base.appendingPathComponent("outside").path)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("in").path,
                                                   withDestinationPath: root.appendingPathComponent("d/f").path)
        XCTAssertTrue(AttachmentService.isInside(root.appendingPathComponent("d/f").path, root: root))
        XCTAssertTrue(AttachmentService.isInside(root.appendingPathComponent("in").path, root: root))
        XCTAssertFalse(AttachmentService.isInside(root.appendingPathComponent("out").path, root: root))
        XCTAssertFalse(AttachmentService.isInside(root.appendingPathComponent("d").path, root: root))
        XCTAssertFalse(AttachmentService.isInside(root.path, root: root))
        XCTAssertFalse(AttachmentService.isInside(root.path + "/d/../../outside", root: root))
        XCTAssertFalse(AttachmentService.isInside(base.appendingPathComponent("root2/f").path, root: root))
        XCTAssertFalse(AttachmentService.isInside(root.appendingPathComponent("missing").path, root: root))
        XCTAssertFalse(AttachmentService.isInside(root.path + "/d/f\u{0}", root: root))
    }

    func testContainsComparesBytes() {
        XCTAssertTrue(AttachmentService.contains("/a/b/c", in: "/a/b"))
        XCTAssertTrue(AttachmentService.contains("/a/b/c", in: "/a/b/"))
        XCTAssertFalse(AttachmentService.contains("/a/b", in: "/a/b"))
        XCTAssertFalse(AttachmentService.contains("/a/b/", in: "/a/b"))
        XCTAssertFalse(AttachmentService.contains("/a/bc/d", in: "/a/b"))
        XCTAssertFalse(AttachmentService.contains("/a/cafe\u{301}/x", in: "/a/caf\u{E9}"))
    }

    func testFilenamesMapOntoTheRootLexically() {
        let root = URL(fileURLWithPath: "/r/Attachments", isDirectory: true)
        XCTAssertEqual(AttachmentPaths.mapped("~/Library/Messages/Attachments/ab/01/x.heic", root: root)?.path,
                       "/r/Attachments/ab/01/x.heic")
        XCTAssertEqual(AttachmentPaths.mapped("/r/Attachments/ab/x.heic", root: root)?.path, "/r/Attachments/ab/x.heic")
        XCTAssertEqual(AttachmentPaths.mapped("~/Library/Messages/Attachments/ab/../cd/x", root: root)?.path,
                       "/r/Attachments/cd/x")
        for bad in ["~/Library/Messages/Attachments/../x", "~/Library/Messages/Attachments/ab/../../x",
                    "/r/Attachments", "/r/Attachments/", "/r/AttachmentsX/a", "/etc/hosts", "ab/x.heic", "",
                    "~/Library/Messages/Attachments/a\u{0}b", "~/Library/Messages/Attachments"] {
            XCTAssertNil(AttachmentPaths.mapped(bad, root: root), bad)
        }
    }

    func testCacheNamesUseASafeExtension() {
        XCTAssertEqual(AttachmentService.fileExtension("IMG_1.HEIC"), "heic")
        XCTAssertEqual(AttachmentService.fileExtension("Audio Message.caf"), "caf")
        XCTAssertEqual(AttachmentService.fileExtension("a.tar.gz"), "gz")
        XCTAssertEqual(AttachmentService.fileExtension("noext"), "")
        XCTAssertEqual(AttachmentService.fileExtension("x.a b"), "")
        XCTAssertEqual(AttachmentService.fileExtension("x.ab/c"), "")
        XCTAssertEqual(AttachmentService.fileExtension("x.é"), "")
        XCTAssertEqual(AttachmentService.fileExtension("x.abcdefghij"), "abcdefghij")
        XCTAssertEqual(AttachmentService.fileExtension("x.abcdefghijk"), "")
        XCTAssertEqual(AttachmentService.entryName(7, ""), "a7")
        XCTAssertEqual(AttachmentService.entryName(7, "pdf"), "a7.pdf")
    }
}

/// A lock-protected count for concurrent tests.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
