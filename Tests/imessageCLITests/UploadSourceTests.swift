import XCTest
import IMCore
import IMTestSupport
@testable import imessage

/// Rule: a file over 100 MB is a usage error before any connection. The CLI streams the bytes, and the bridge gets
/// the byte count and the base name, never the caller's path.
final class UploadSourceTests: XCTestCase {
    func testExactly100MBIsAcceptedAndOneByteMoreIsRefused() throws {
        let dir = try makeTempDir()
        let atLimit = try UploadSource(path: try dir.sparse("limit.bin", size: Limits.maxUploadBytes))
        XCTAssertEqual(atLimit.byteCount, 100_000_000)
        XCTAssertEqual(atLimit.header, UploadHeader(byteCount: 100_000_000, fileName: "limit.bin"))

        let over = try dir.sparse("over.bin", size: Limits.maxUploadBytes + 1)
        XCTAssertThrowsError(try UploadSource(path: over)) { e in
            let u = e as? UsageError
            XCTAssertEqual(u?.message, "\"over.bin\" is 100000001 bytes, over the 100 MB limit")
            XCTAssertEqual(u?.fix, "send a file of 100000000 bytes or less")
        }
    }

    func testOversizedFileExitsTwoWithoutConnecting() throws {
        let dir = try makeTempDir()
        let over = try dir.sparse("movie.mov", size: Limits.maxUploadBytes + 1)
        let bridge = try makeBridge { _ in P.send([P.text(.submitted)]) }
        let run = CLIRun()
        XCTAssertEqual(run.run(["send", "Mom", "--file", over], bridge.client()), 2)
        XCTAssertEqual(run.stderrText, "error: \"movie.mov\" is 100000001 bytes, over the 100 MB limit "
                       + "fix: send a file of 100000000 bytes or less\n")
        XCTAssertEqual(run.stdoutText, "")
        XCTAssertEqual(bridge.connections, 0)
        XCTAssertTrue(bridge.requests.isEmpty)
    }

    /// A FIFO would block a plain open() until a writer appears; the non-blocking open returns at once.
    func testFoldersAndPipesAreRefusedWithoutBlocking() throws {
        let dir = try makeTempDir()
        let folder = dir.url.appendingPathComponent("folder").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false)
        let fifo = dir.url.appendingPathComponent("pipe").path
        XCTAssertEqual(mkfifo(fifo, 0o600), 0)
        for path in [folder, fifo] {
            let start = Date()
            XCTAssertThrowsError(try UploadSource(path: path)) { e in
                XCTAssertEqual((e as? UsageError)?.message, "\"\(path)\" isn't a regular file")
                XCTAssertEqual((e as? UsageError)?.fix, "pass a file, not a folder, pipe or device")
            }
            XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        }
    }

    func testMissingAndUnreadableFilesAreUsageErrors() throws {
        let dir = try makeTempDir()
        let missing = dir.url.appendingPathComponent("nope.pdf").path
        XCTAssertThrowsError(try UploadSource(path: missing)) { e in
            XCTAssertEqual((e as? UsageError)?.message, "can't open \"\(missing)\": No such file or directory")
        }
        let locked = try dir.file("locked.pdf", Data("secret".utf8))
        XCTAssertEqual(chmod(locked, 0), 0)
        defer { chmod(locked, 0o600) }
        XCTAssertThrowsError(try UploadSource(path: locked)) { e in
            XCTAssertEqual((e as? UsageError)?.message, "can't open \"\(locked)\": Permission denied")
        }
    }

    func testHeaderCarriesOnlyTheBaseName() throws {
        let dir = try makeTempDir()
        let sub = dir.url.appendingPathComponent("Private Folder")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)
        let path = sub.appendingPathComponent("Report Q3.pdf").path
        try Data("pdf".utf8).write(to: URL(fileURLWithPath: path))
        let source = try UploadSource(path: path)
        XCTAssertEqual(source.header, UploadHeader(byteCount: 3, fileName: "Report Q3.pdf"))
        XCTAssertTrue(source.header.isValid)
    }

    func testStreamWritesExactlyTheFileBytes() throws {
        let dir = try makeTempDir()
        var data = Data(count: 3 * UploadSource.chunkBytes + 17)
        for i in 0..<data.count { data[i] = UInt8(truncatingIfNeeded: i &* 31 &+ i >> 9) }
        let source = try UploadSource(path: try dir.file("data.bin", data))
        let got = try streamed(source, readBytes: data.count + 1)
        XCTAssertEqual(got.count, data.count)
        XCTAssertEqual(got, data)
    }

    func testEmptyFileStreamsNothing() throws {
        let dir = try makeTempDir()
        let source = try UploadSource(path: try dir.file("empty.txt", Data()))
        XCTAssertEqual(source.byteCount, 0)
        XCTAssertEqual(try streamed(source, readBytes: 1), Data())
    }

    /// The size is fixed when the file opens. A file cut short afterwards fails the upload instead of sending
    /// fewer bytes than the header promised.
    func testFileThatShrinksWhileStreamingIsAnUploadFailure() throws {
        let dir = try makeTempDir()
        let path = try dir.file("shrinks.bin", Data(repeating: 7, count: 2 * UploadSource.chunkBytes))
        let source = try UploadSource(path: path)
        XCTAssertEqual(truncate(path, off_t(UploadSource.chunkBytes)), 0)
        XCTAssertThrowsError(try streamed(source, readBytes: 3 * UploadSource.chunkBytes)) { e in
            XCTAssertEqual(e as? ClientError, .uploadFailed("shrinks.bin got shorter while it was sent"))
        }
        XCTAssertEqual(Output.exitCode(for: ClientError.uploadFailed("x")), .failure)
    }

    func testSendFileStreamsTheBytesAndNeverTheDirectory() throws {
        let dir = try makeTempDir()
        let bytes = Data((0..<70_000).map { UInt8(truncatingIfNeeded: $0 * 7) })
        let path = try dir.file("photo.heic", bytes)
        let bridge = try makeBridge { _ in
            P.send([SendPartOutcome(part: .file, result: ActionResult(.submitted), rowid: 41601)])
        }
        let run = CLIRun()
        XCTAssertEqual(run.run(["send", "Mom", "--file", path], bridge.client()), 0, run.stderrText)
        let got = try XCTUnwrap(bridge.all.first)
        XCTAssertEqual(got.request.upload, UploadHeader(byteCount: 70_000, fileName: "photo.heic"))
        XCTAssertEqual(got.request.body, .send(SendArgs(who: "Mom", text: nil)))
        XCTAssertEqual(got.upload, bytes)
        let frame = String(decoding: got.frame, as: UTF8.self)
        XCTAssertFalse(frame.contains(dir.url.lastPathComponent), frame)
        XCTAssertFalse(frame.contains("/"), frame)
    }

    func testCaptionAndFileGoInOneRequest() throws {
        let dir = try makeTempDir()
        let path = try dir.file("a.pdf", Data("%PDF".utf8))
        let bridge = try makeBridge { _ in P.send([P.text(.submitted)]) }
        let run = CLIRun()
        XCTAssertEqual(run.run(["send", "Mom", "see attached", "--file", path], bridge.client()), 0, run.stderrText)
        XCTAssertEqual(bridge.requests.map(\.body), [.send(SendArgs(who: "Mom", text: "see attached"))])
        XCTAssertEqual(bridge.all.first?.upload, Data("%PDF".utf8))
    }

    /// Streams `source` into one end of a socket pair while another thread reads up to `readBytes` from the other.
    func streamed(_ source: UploadSource, readBytes: Int) throws -> Data {
        let (a, b) = try SocketPair.make()
        let channel = FrameChannel(fd: a)
        let done = DispatchSemaphore(value: 0)
        let box = LockedData()
        Thread {
            box.set((try? SocketPair.read(b, count: readBytes)) ?? Data())
            done.signal()
        }.start()
        defer {
            channel.close()
            _ = done.wait(timeout: .now() + 10)
            close(b)
        }
        try source.stream(to: channel)
        channel.close()
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success)
        done.signal()
        return box.get()
    }
}

final class LockedData {
    private let lock = NSLock()
    private var data = Data()
    func set(_ d: Data) { lock.withLock { data = d } }
    func get() -> Data { lock.withLock { data } }
}
