import Foundation
import XCTest
import IMCore
@testable import IMSend
import IMTestSupport

final class StagingTests: XCTestCase {
    private let temp = TempFolders()
    private var root: URL!
    private var stagingDir: URL!
    private var freezer: UploadFreezer!

    override func setUp() {
        super.setUp()
        root = temp.make("staging")
        stagingDir = root.appendingPathComponent("Pictures/\(AppIdentity.appName)", isDirectory: true)
        freezer = UploadFreezer(directory: root.appendingPathComponent("uploads", isDirectory: true))
    }

    override func tearDown() {
        temp.removeAll()
        super.tearDown()
    }

    private func frozen(_ name: String = "report.pdf", _ text: String = "file bytes") throws -> FrozenFile {
        try freeze(Data(text.utf8), name: name, with: freezer)
    }

    /// A copy left in the folder by an earlier bridge run, staged `age` seconds before `clock.now`.
    @discardableResult
    private func leftover(_ name: String, age: TimeInterval, clock: FakeClock) throws -> URL {
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let url = stagingDir.appendingPathComponent(name)
        try Data("old".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: clock.now.addingTimeInterval(-age)],
                                              ofItemAtPath: url.path)
        return url
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    // MARK: Stage

    func testLiveStagingFolderIsPicturesIMessageAgent() {
        let paths = Paths(home: root)
        XCTAssertEqual(paths.stagingDir.path, root.appendingPathComponent("Pictures/iMessage Agent").path)
    }

    func testStageCopiesUnderAUniqueNameThatIsTheTransferName() throws {
        let clock = FakeClock()
        let area = StagingArea(directory: stagingDir, clock: clock, rows: ScriptedRowSource(clock: clock))
        let file = try frozen()
        let staged = try area.stage(file)

        XCTAssertEqual(staged.url.deletingLastPathComponent().standardizedFileURL, stagingDir.standardizedFileURL)
        XCTAssertEqual(staged.transferName, staged.url.lastPathComponent)
        XCTAssertNotNil(staged.transferName.range(of: "^report-[0-9a-f]{16}\\.pdf$", options: .regularExpression),
                        staged.transferName)
        XCTAssertEqual(try Data(contentsOf: staged.url), try Data(contentsOf: file.url))
        XCTAssertEqual(staged.stagedAt, clock.now)
        let mtime = try FileManager.default.attributesOfItem(atPath: staged.url.path)[.modificationDate] as? Date
        XCTAssertEqual(mtime?.timeIntervalSince1970 ?? 0, clock.now.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(posixMode(staged.url), 0o600)
        XCTAssertEqual(posixMode(stagingDir), 0o700)
        XCTAssertTrue(exists(file.url), "the frozen copy stays for the pipeline to discard")
    }

    func testStagingTheSameFileTwiceGivesTwoNames() throws {
        let clock = FakeClock()
        let area = StagingArea(directory: stagingDir, clock: clock, rows: ScriptedRowSource(clock: clock))
        let file = try frozen()
        let names = try (0..<20).map { _ in try area.stage(file).transferName }
        XCTAssertEqual(Set(names).count, 20)
    }

    func testUniqueNameKeepsTheOriginalExtension() {
        func name(_ original: String) -> String {
            StagingArea.uniqueName(for: original).replacingOccurrences(
                of: "[0-9a-f]{16}", with: "H", options: .regularExpression)
        }
        XCTAssertEqual(name("IMG_0001.HEIC"), "IMG_0001-H.HEIC")
        XCTAssertEqual(name("archive.tar.gz"), "archive_tar-H.gz")
        XCTAssertEqual(name("R\u{E9}sum\u{E9} final.pdf"), "R_sum__final-H.pdf")
        XCTAssertEqual(name("Makefile"), "Makefile-H")
        XCTAssertEqual(name(".bashrc"), "bashrc-H")
        XCTAssertEqual(name("\u{1F600}.png"), "file-H.png")
        XCTAssertEqual(name("notes.t xt"), "notes_t_xt-H", "an extension with a space is dropped")
        XCTAssertEqual(name(String(repeating: "x", count: 90) + ".txt"), String(repeating: "x", count: 40) + "-H.txt")
    }

    func testStagedBytesThatDontMatchTheApprovedDigestAreRefused() throws {
        let clock = FakeClock()
        let area = StagingArea(directory: stagingDir, clock: clock, rows: ScriptedRowSource(clock: clock))
        var file = try frozen()
        file.sha256 = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try area.stage(file)) { XCTAssertEqual($0 as? StagingError, .digestMismatch) }
        XCTAssertEqual(filesIn(stagingDir), [])
    }

    // MARK: Never the Messages tmp folder

    func testMessagesTmpFolderIsRefused() throws {
        let clock = FakeClock()
        let file = try frozen()
        let tag = "imsend-test-\(UUID().uuidString)"
        for path in ["/private/var/tmp/com.apple.messages", "/private/var/tmp/com.apple.messages/\(tag)",
                     "/var/tmp/com.apple.messages/\(tag)", "/PRIVATE/var/tmp/Com.Apple.Messages/\(tag)",
                     "/private/var/tmp/x/../com.apple.messages/\(tag)"] {
            let area = StagingArea(directory: URL(fileURLWithPath: path, isDirectory: true), clock: clock,
                                   rows: ScriptedRowSource(clock: clock))
            XCTAssertThrowsError(try area.stage(file), path) { error in
                guard case .forbiddenDirectory = error as? StagingError else {
                    return XCTFail("expected forbiddenDirectory, got \(error)")
                }
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/private/var/tmp/com.apple.messages/\(tag)"))
    }

    func testSimilarFolderNamesAreAllowed() throws {
        XCTAssertNoThrow(try StagingArea.refuseForbidden(URL(fileURLWithPath: "/private/var/tmp/com.apple.messagesX")))
        XCTAssertNoThrow(try StagingArea.refuseForbidden(stagingDir))
    }

    func testStagingFolderThatIsASymlinkIsRefused() throws {
        let clock = FakeClock()
        let real = temp.make("real")
        try FileManager.default.createDirectory(at: stagingDir.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: stagingDir, withDestinationURL: real)
        let area = StagingArea(directory: stagingDir, clock: clock, rows: ScriptedRowSource(clock: clock))
        XCTAssertThrowsError(try area.stage(try frozen()))
        XCTAssertEqual(filesIn(real), [])
    }

    // MARK: Sweep

    func testSweepDeletesACopyOnceItsTransferReachesFive() throws {
        let clock = FakeClock()
        let rows = ScriptedRowSource(clock: clock)
        let area = StagingArea(directory: stagingDir, clock: clock, rows: rows)
        let staged = try area.stage(try frozen())

        rows.setTransferState(staged.transferName, 3)
        area.sweep()
        XCTAssertTrue(exists(staged.url))
        rows.setTransferState(staged.transferName, Limits.transferStateDone)
        area.sweep()
        XCTAssertFalse(exists(staged.url))
    }

    func testSweepKeepsAWaitingCopyForTenMinutesExactly() throws {
        let clock = FakeClock()
        let rows = ScriptedRowSource(clock: clock)
        let area = StagingArea(directory: stagingDir, clock: clock, rows: rows)
        let noRow = try area.stage(try frozen())
        let failed = try area.stage(try frozen())
        rows.setTransferState(failed.transferName, Limits.transferStateFailed)

        clock.advance(Limits.stagedFileTTL - 0.5)
        area.sweep()
        XCTAssertTrue(exists(noRow.url))
        XCTAssertTrue(exists(failed.url))

        clock.advance(0.5)
        area.sweep()
        XCTAssertFalse(exists(noRow.url))
        XCTAssertFalse(exists(failed.url))
    }

    func testSweepDeletesCopiesFromAnEarlierRun() throws {
        let clock = FakeClock()
        let rows = ScriptedRowSource(clock: clock)
        let old = try leftover("old-0000000000000001.txt", age: Limits.stagedFileTTL, clock: clock)
        let done = try leftover("done-0000000000000002.txt", age: 30, clock: clock)
        let waiting = try leftover("wait-0000000000000003.txt", age: 30, clock: clock)
        rows.setTransferState(done.lastPathComponent, Limits.transferStateDone)

        StagingArea(directory: stagingDir, clock: clock, rows: rows).sweep()
        XCTAssertFalse(exists(old))
        XCTAssertFalse(exists(done))
        XCTAssertTrue(exists(waiting))
    }

    func testSweepStillAgesCopiesOutWhenChatDBCantBeRead() throws {
        let clock = FakeClock()
        let rows = ScriptedRowSource(clock: clock)
        rows.failTransferStates = true
        let old = try leftover("old-0000000000000001.txt", age: Limits.stagedFileTTL + 1, clock: clock)
        let fresh = try leftover("new-0000000000000002.txt", age: 1, clock: clock)

        StagingArea(directory: stagingDir, clock: clock, rows: rows).sweep()
        XCTAssertFalse(exists(old))
        XCTAssertTrue(exists(fresh))
    }

    func testSweepLeavesHiddenFilesAlone() throws {
        let clock = FakeClock()
        let dsStore = try leftover(".DS_Store", age: Limits.stagedFileTTL * 3, clock: clock)
        StagingArea(directory: stagingDir, clock: clock, rows: ScriptedRowSource(clock: clock)).sweep()
        XCTAssertTrue(exists(dsStore))
    }

    func testSweepWithNoFolderDoesNothing() {
        let clock = FakeClock()
        let rows = ScriptedRowSource(clock: clock)
        StagingArea(directory: stagingDir, clock: clock, rows: rows).sweep()
        XCTAssertFalse(exists(stagingDir))
        XCTAssertTrue(rows.callLog.isEmpty)
    }

    func testSweepNeverFollowsASymlinkInTheFoldersPlace() throws {
        let clock = FakeClock()
        let elsewhere = temp.make("elsewhere")
        let precious = elsewhere.appendingPathComponent("tax-return.pdf")
        try Data("keep".utf8).write(to: precious)
        try FileManager.default.setAttributes([.modificationDate: clock.now.addingTimeInterval(-3600)],
                                              ofItemAtPath: precious.path)
        try FileManager.default.createDirectory(at: stagingDir.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: stagingDir, withDestinationURL: elsewhere)
        let rows = ScriptedRowSource(clock: clock)
        let area = StagingArea(directory: stagingDir, clock: clock, rows: rows)

        area.sweep()
        XCTAssertTrue(exists(precious), "a sweep deletes only inside the real staging folder")
        XCTAssertFalse(area.hasPendingTransfers(), "stage refuses a symlinked folder, so nothing is staged there")
        XCTAssertTrue(rows.callLog.isEmpty)
    }

    func testUnreadableFolderCountsAsPendingAndIsLeftAlone() throws {
        let clock = FakeClock()
        let rows = ScriptedRowSource(clock: clock)
        let area = StagingArea(directory: stagingDir, clock: clock, rows: rows)
        let staged = try area.stage(try frozen())
        rows.setTransferState(staged.transferName, Limits.transferStateDone)
        clock.advance(Limits.stagedFileTTL * 2)

        XCTAssertEqual(chmod(stagingDir.path, 0), 0)
        defer { chmod(stagingDir.path, 0o700) }
        XCTAssertTrue(area.hasPendingTransfers(), "a folder that can't be read may hold a copy in transfer")
        area.sweep()
        chmod(stagingDir.path, 0o700)
        XCTAssertTrue(exists(staged.url))
    }

    func testFileInTheFoldersPlaceHoldsNothingPending() throws {
        let clock = FakeClock()
        try FileManager.default.createDirectory(at: stagingDir.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("x".utf8).write(to: stagingDir)
        let area = StagingArea(directory: stagingDir, clock: clock, rows: ScriptedRowSource(clock: clock))
        XCTAssertFalse(area.hasPendingTransfers())
        area.sweep()
        XCTAssertTrue(exists(stagingDir))
    }

    // MARK: Pending transfers

    func testNoStagedCopyMeansNothingPending() {
        let clock = FakeClock()
        let rows = ScriptedRowSource(clock: clock)
        rows.failTransferStates = true
        XCTAssertFalse(StagingArea(directory: stagingDir, clock: clock, rows: rows).hasPendingTransfers())
    }

    func testCopyIsPendingUntilItsTransferIsDoneOrFailed() throws {
        let clock = FakeClock()
        let rows = ScriptedRowSource(clock: clock)
        let area = StagingArea(directory: stagingDir, clock: clock, rows: rows)
        let staged = try area.stage(try frozen())

        XCTAssertTrue(area.hasPendingTransfers(), "no attachment row yet")
        for state in [0, 1, 2, 3, 4] {
            rows.setTransferState(staged.transferName, state)
            XCTAssertTrue(area.hasPendingTransfers(), "state \(state)")
        }
        rows.setTransferState(staged.transferName, Limits.transferStateDone)
        XCTAssertFalse(area.hasPendingTransfers())
        rows.setTransferState(staged.transferName, Limits.transferStateFailed)
        XCTAssertFalse(area.hasPendingTransfers())
    }

    func testOneWaitingCopyAmongDoneOnesIsPending() throws {
        let clock = FakeClock()
        let rows = ScriptedRowSource(clock: clock)
        let area = StagingArea(directory: stagingDir, clock: clock, rows: rows)
        let done = try area.stage(try frozen())
        _ = try area.stage(try frozen())
        rows.setTransferState(done.transferName, Limits.transferStateDone)
        XCTAssertTrue(area.hasPendingTransfers())
    }

    func testCopyFromAnEarlierRunCountsAsPending() throws {
        let clock = FakeClock()
        try leftover("old-0000000000000001.txt", age: 30, clock: clock)
        XCTAssertTrue(StagingArea(directory: stagingDir, clock: clock, rows: ScriptedRowSource(clock: clock))
            .hasPendingTransfers())
    }

    func testCopyTenMinutesOldIsNoLongerPending() throws {
        let clock = FakeClock()
        let rows = ScriptedRowSource(clock: clock)
        let area = StagingArea(directory: stagingDir, clock: clock, rows: rows)
        _ = try area.stage(try frozen())
        clock.advance(Limits.stagedFileTTL - 0.5)
        XCTAssertTrue(area.hasPendingTransfers())
        clock.advance(0.5)
        XCTAssertFalse(area.hasPendingTransfers())
    }

    func testUnreadableChatDBCountsAsPendingWhileACopyExists() throws {
        let clock = FakeClock()
        let rows = ScriptedRowSource(clock: clock)
        let area = StagingArea(directory: stagingDir, clock: clock, rows: rows)
        let staged = try area.stage(try frozen())
        rows.setTransferState(staged.transferName, Limits.transferStateDone)
        rows.failTransferStates = true
        XCTAssertTrue(area.hasPendingTransfers())
    }

    func testHiddenFilesAreNotPending() throws {
        let clock = FakeClock()
        try leftover(".DS_Store", age: 1, clock: clock)
        XCTAssertFalse(StagingArea(directory: stagingDir, clock: clock, rows: ScriptedRowSource(clock: clock))
            .hasPendingTransfers())
    }

    // MARK: Several threads

    func testStageSweepAndPendingChecksFromSeveralThreads() throws {
        let clock = FixedWallClock()
        let rows = ScriptedRowSource(clock: clock)
        let area = StagingArea(directory: stagingDir, clock: clock, rows: rows)
        let file = try frozen()
        var names: [String] = []
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: 60) { i in
            switch i % 3 {
            case 0:
                if let staged = try? area.stage(file) {
                    lock.lock()
                    names.append(staged.transferName)
                    lock.unlock()
                }
            case 1:
                area.sweep()
            default:
                _ = area.hasPendingTransfers()
            }
        }
        XCTAssertEqual(names.count, 20)
        XCTAssertEqual(Set(names).count, 20)
        XCTAssertEqual(Set(filesIn(stagingDir)), Set(names), "fresh copies with no row survive the sweeps")
        XCTAssertTrue(area.hasPendingTransfers())
    }
}
