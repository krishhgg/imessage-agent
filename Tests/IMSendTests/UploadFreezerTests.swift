import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import XCTest
import IMCore
@testable import IMSend
import IMTestSupport

final class UploadFreezerTests: XCTestCase {
    private let temp = TempFolders()
    private var uploads: URL!

    override func setUp() {
        super.setUp()
        uploads = temp.make("uploads").appendingPathComponent("uploads", isDirectory: true)
    }

    override func tearDown() {
        temp.removeAll()
        super.tearDown()
    }

    private func randomData(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) })
    }

    private func assertUploadError(_ expected: UploadError, _ body: () throws -> FrozenFile,
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual(error as? UploadError, expected, file: file, line: line)
        }
    }

    private func assertIOError(_ body: () throws -> FrozenFile, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            guard case .io = error as? UploadError else {
                return XCTFail("expected UploadError.io, got \(error)", file: file, line: line)
            }
        }
    }

    // MARK: Freezing and hashing

    func testFreezeWritesExactBytesAndTheirSHA256() throws {
        let data = randomData(3 * UploadFreezer.chunkBytes + 17)
        let frozen = try freeze(data, name: "report.pdf", with: UploadFreezer(directory: uploads))

        XCTAssertEqual(try Data(contentsOf: frozen.url), data)
        XCTAssertEqual(frozen.byteCount, Int64(data.count))
        XCTAssertEqual(frozen.sha256, TextNorm.sha256Hex(data))
        XCTAssertEqual(frozen.originalName, "report.pdf")
        XCTAssertEqual(frozen.url.deletingLastPathComponent().standardizedFileURL, uploads.standardizedFileURL)
        XCTAssertEqual(posixMode(frozen.url), 0o600)
        XCTAssertEqual(posixMode(uploads), 0o700)
    }

    func testCopyNameIsRandomAndNeverTheCallersName() throws {
        let freezer = UploadFreezer(directory: uploads)
        let a = try freeze(Data("a".utf8), name: "report.pdf", with: freezer)
        let b = try freeze(Data("a".utf8), name: "report.pdf", with: freezer)
        XCTAssertNotEqual(a.url, b.url)
        XCTAssertFalse(a.url.lastPathComponent.contains("report"))
        XCTAssertNotNil(UUID(uuidString: a.url.lastPathComponent))
    }

    func testTheCallersFileIsNeverOpened() throws {
        // The caller's file holds one thing and the stream another. Only the streamed bytes count.
        let callerDir = temp.make("caller")
        let callerFile = callerDir.appendingPathComponent("report.txt")
        try Data("ORIGINAL".utf8).write(to: callerFile)
        let streamed = Data("STREAMED BYTES".utf8)

        let frozen = try freeze(streamed, name: "report.txt", with: UploadFreezer(directory: uploads))
        XCTAssertEqual(try Data(contentsOf: frozen.url), streamed)
        XCTAssertEqual(frozen.sha256, TextNorm.sha256Hex(streamed))
        XCTAssertEqual(try Data(contentsOf: callerFile), Data("ORIGINAL".utf8))
    }

    func testEmptyUploadIsAllowed() throws {
        let frozen = try freeze(Data(), name: "empty.txt", with: UploadFreezer(directory: uploads))
        XCTAssertEqual(frozen.byteCount, 0)
        XCTAssertEqual(frozen.sha256, TextNorm.sha256Hex(Data()))
    }

    // MARK: Size limit

    func testHeaderOverTheLimitIsRefusedBeforeAnyRead() {
        var reads = 0
        assertUploadError(.tooLarge) {
            try UploadFreezer(directory: uploads).freeze(
                header: UploadHeader(byteCount: Limits.maxUploadBytes + 1, fileName: "big.mov")) { _ in
                reads += 1
                return 0
            }
        }
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(filesIn(uploads), [])
    }

    func testExactlyOneHundredMegabytesIsAccepted() throws {
        XCTAssertEqual(Limits.maxUploadBytes, 100_000_000)
        var hasher = SHA256Hasher()
        var sent: Int64 = 0
        let frozen = try UploadFreezer(directory: uploads).freeze(
            header: UploadHeader(byteCount: Limits.maxUploadBytes, fileName: "big.bin")) { buffer in
            let n = min(Int64(buffer.count), Limits.maxUploadBytes - sent)
            let chunk = UnsafeMutableRawBufferPointer(rebasing: buffer[0..<Int(n)])
            chunk.initializeMemory(as: UInt8.self, repeating: UInt8(truncatingIfNeeded: sent >> 16))
            hasher.update(UnsafeRawBufferPointer(chunk))
            sent += n
            return Int(n)
        }
        XCTAssertEqual(frozen.byteCount, Limits.maxUploadBytes)
        XCTAssertEqual(frozen.sha256, hasher.hex())
        let size = try FileManager.default.attributesOfItem(atPath: frozen.url.path)[.size] as? NSNumber
        XCTAssertEqual(size?.int64Value, Limits.maxUploadBytes)
    }

    func testLimitBoundaryIsInclusive() throws {
        let freezer = UploadFreezer(directory: uploads, maxBytes: 10)
        XCTAssertEqual(try freeze(Data(count: 10), name: "ten.bin", with: freezer).byteCount, 10)
        assertUploadError(.tooLarge) { try freeze(Data(count: 11), name: "eleven.bin", with: freezer) }
    }

    // MARK: Byte count that disagrees with the header

    func testShortStreamIsRefusedAndLeavesNothing() {
        let data = Data(count: 9)
        assertUploadError(.shortRead) {
            var offset = 0
            return try UploadFreezer(directory: uploads).freeze(header: UploadHeader(byteCount: 10, fileName: "a")) {
                buffer in
                let n = min(buffer.count, data.count - offset)
                offset += n
                return n
            }
        }
        XCTAssertEqual(filesIn(uploads), [])
    }

    func testReaderIsNeverAskedForMoreThanTheHeaderSays() throws {
        let declared = UploadFreezer.chunkBytes + 5
        var asked: [Int] = []
        let frozen = try UploadFreezer(directory: uploads).freeze(
            header: UploadHeader(byteCount: Int64(declared), fileName: "a.bin")) { buffer in
            asked.append(buffer.count)
            for i in 0..<buffer.count { buffer[i] = 7 }
            return buffer.count
        }
        XCTAssertEqual(asked, [UploadFreezer.chunkBytes, 5])
        XCTAssertEqual(frozen.byteCount, Int64(declared))
    }

    func testReaderErrorIsIOAndLeavesNothing() {
        struct Broken: Error {}
        var calls = 0
        assertIOError {
            try UploadFreezer(directory: uploads).freeze(header: UploadHeader(byteCount: 100, fileName: "a")) { _ in
                calls += 1
                if calls == 2 { throw Broken() }
                return 10
            }
        }
        XCTAssertEqual(filesIn(uploads), [])
    }

    func testReaderClaimingMoreThanTheBufferIsRefused() {
        assertIOError {
            try UploadFreezer(directory: uploads).freeze(header: UploadHeader(byteCount: 100, fileName: "a")) {
                $0.count + 1
            }
        }
        XCTAssertEqual(filesIn(uploads), [])
    }

    func testNegativeByteCountIsRefused() {
        var reads = 0
        assertIOError {
            try UploadFreezer(directory: uploads).freeze(header: UploadHeader(byteCount: -1, fileName: "a")) { _ in
                reads += 1
                return 0
            }
        }
        XCTAssertEqual(reads, 0)
    }

    // MARK: Names

    func testPathsAndEmptyNamesAreRefusedBeforeAnyRead() {
        let long = String(repeating: "a", count: 252) + ".txt"
        for name in ["", ".", "..", "  ", "a/b.txt", "/etc/passwd", "../x", "x\0y", "\u{202E}", long] {
            var reads = 0
            assertUploadError(.badName) {
                try UploadFreezer(directory: uploads).freeze(header: UploadHeader(byteCount: 1, fileName: name)) { _ in
                    reads += 1
                    return 0
                }
            }
            XCTAssertEqual(reads, 0, name)
        }
        XCTAssertEqual(filesIn(uploads), [])
    }

    func testLongestAllowedNameIs255Bytes() throws {
        let name = String(repeating: "a", count: 251) + ".txt"
        XCTAssertEqual(try freeze(Data("x".utf8), name: name, with: UploadFreezer(directory: uploads)).originalName,
                       name)
    }

    func testNameIsSanitized() throws {
        let freezer = UploadFreezer(directory: uploads)
        // A right-to-left override would show "invoiceexe.pdf" in the dialog for a file that ends in .exe.
        XCTAssertEqual(try freeze(Data("x".utf8), name: "invoice\u{202E}fdp.exe", with: freezer).originalName,
                       "invoicefdp.exe")
        XCTAssertEqual(try freeze(Data("x".utf8), name: "two\nlines\t.txt", with: freezer).originalName,
                       "twolines.txt")
        XCTAssertEqual(try freeze(Data("x".utf8), name: "Cafe\u{301}.txt", with: freezer).originalName,
                       "Caf\u{E9}.txt")
        XCTAssertEqual(try freeze(Data("x".utf8), name: " spaced.txt ", with: freezer).originalName, "spaced.txt")
    }

    // MARK: Image detection on the frozen bytes

    func testImageIsDetectedFromBytesNotFromTheName() throws {
        let freezer = UploadFreezer(directory: uploads)
        XCTAssertTrue(try freeze(SampleImages.png, name: "notes.txt", with: freezer).isImage)
        XCTAssertFalse(try freeze(Data("plain text\n".utf8), name: "photo.jpg", with: freezer).isImage)
        XCTAssertFalse(try freeze(Data(), name: "empty.png", with: freezer).isImage)
    }

    func testHEICAndJPEGAreImages() throws {
        let freezer = UploadFreezer(directory: uploads)
        for type in ["public.heic", "public.jpeg"] {
            let data = try XCTUnwrap(encodeImage(type: type), type)
            XCTAssertTrue(try freeze(data, name: "upload", with: freezer).isImage, type)
        }
    }

    func testPDFIsNotAnImage() throws {
        let pdf = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 10, height: 10)
        let context = try XCTUnwrap(CGContext(consumer: CGDataConsumer(data: pdf)!, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        XCTAssertFalse(try freeze(pdf as Data, name: "scan.png", with: UploadFreezer(directory: uploads)).isImage)
    }

    private func encodeImage(type: String) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil),
              let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = context.makeImage() else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    // MARK: Discard

    func testDiscardRemovesTheCopyAndNothingOutsideItsFolder() throws {
        let freezer = UploadFreezer(directory: uploads)
        let frozen = try freeze(Data("x".utf8), name: "a.txt", with: freezer)
        freezer.discard(frozen)
        XCTAssertFalse(FileManager.default.fileExists(atPath: frozen.url.path))

        let outside = temp.make("outside").appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: outside)
        freezer.discard(FrozenFile(url: outside, byteCount: 4, sha256: "", originalName: "keep.txt"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    // MARK: Several connections at once

    func testConcurrentFreezesGetTheirOwnCopiesAndHashes() {
        let freezer = UploadFreezer(directory: uploads)
        let inputs = (0..<16).map { randomData(10_000 + $0 * 997) }
        var results = [FrozenFile?](repeating: nil, count: inputs.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: inputs.count) { i in
            let frozen = try? freeze(inputs[i], name: "part\(i).bin", with: freezer)
            lock.lock()
            results[i] = frozen
            lock.unlock()
        }
        let frozen = results.compactMap { $0 }
        XCTAssertEqual(frozen.count, inputs.count)
        XCTAssertEqual(Set(frozen.map(\.url)).count, inputs.count)
        for (i, file) in frozen.enumerated() {
            XCTAssertEqual(file.sha256, TextNorm.sha256Hex(inputs[i]))
            XCTAssertEqual(try? Data(contentsOf: file.url), inputs[i])
        }
    }
}

/// Running SHA-256 for the 100 MB test, so the test doesn't hold the whole upload in memory.
struct SHA256Hasher {
    private var hasher = SHA256()
    mutating func update(_ bytes: UnsafeRawBufferPointer) { hasher.update(bufferPointer: bytes) }
    func hex() -> String { hasher.finalize().map { String(format: "%02x", $0) }.joined() }
}
