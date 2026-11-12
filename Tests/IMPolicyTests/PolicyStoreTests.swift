import CryptoKit
import Foundation
import IMCore
@testable import IMPolicy
import IMTestSupport
import XCTest

/// Records the Keychain dialog setting instead of changing the real one.
private final class FakeInteractionSwitch: KeychainInteractionSwitching {
    private(set) var isInteractionAllowed: Bool
    private(set) var changes: [Bool] = []

    init(allowed: Bool) { isInteractionAllowed = allowed }

    func setInteractionAllowed(_ allowed: Bool) {
        changes.append(allowed)
        isInteractionAllowed = allowed
    }
}

/// Section 2, Storage: the 0600 file, its Keychain hash, and failing closed.
final class PolicyStoreTests: XCTestCase {
    private var dir: TempDir!
    private var keychain: InMemoryKeychain!
    private var store: PolicyStore!

    override func setUp() {
        dir = TempDir()
        keychain = InMemoryKeychain()
        store = PolicyStore(fileURL: dir.url.appendingPathComponent("support/policy.json"), keychain: keychain)
    }

    override func tearDown() {
        store = nil
        keychain = nil
        dir = nil
    }

    private var fileBytes: Data { try! Data(contentsOf: store.fileURL) }

    private func trustedState() -> PolicyState? {
        if case .trusted(let s) = store.load() { return s }
        return nil
    }

    private func seedTrusted(foreground: Bool = true) throws {
        try store.allow(T.mom, label: "Mom", scope: .text)
        try store.allow(T.dad, label: "Dad", scope: .files)
        try store.setForegroundMode(foreground)
    }

    // MARK: Mode 0600, atomic, fsync, SHA-256 in the Keychain

    func testSaveWritesFileWithMode0600AndFolder0700() throws {
        try store.save(PolicyState(entries: [], foregroundMode: false))
        XCTAssertEqual(fileMode(store.fileURL), 0o600)
        XCTAssertEqual(fileMode(store.fileURL.deletingLastPathComponent()), 0o700)
    }

    func testSaveResetsModeTo0600AfterOutsideChmod() throws {
        try store.save(.empty)
        chmod(store.fileURL.path, 0o644)
        try store.allow(T.mom, label: "Mom", scope: .text)
        XCTAssertEqual(fileMode(store.fileURL), 0o600)
    }

    func testKeychainHoldsSHA256OfTheExactFileBytes() throws {
        try seedTrusted()
        XCTAssertEqual(keychain.hash, Data(SHA256.hash(data: fileBytes)))
        XCTAssertEqual(keychain.hash?.count, 32)
    }

    func testSaveReplacesFileAtomicallyAndLeavesNoTempFiles() throws {
        try seedTrusted()
        let names = try FileManager.default.contentsOfDirectory(atPath: store.fileURL.deletingLastPathComponent().path)
        XCTAssertEqual(names, ["policy.json"])
        let decoded = try JSONDecoder.wire.decode(PolicyState.self, from: fileBytes)
        XCTAssertEqual(decoded.entries.map(\.chat), [T.dad, T.mom].sorted { $0.rawValue < $1.rawValue })
    }

    func testNextSaveRemovesATempFileAnInterruptedSaveLeft() throws {
        try store.allow(T.mom, label: "Mom", scope: .text)
        let folder = store.fileURL.deletingLastPathComponent()
        let leftover = folder.appendingPathComponent(".policy.json.0badc0de.tmp")
        try Data("half a policy".utf8).write(to: leftover)
        XCTAssertNotNil(trustedState())
        try store.allow(T.dad, label: "Dad", scope: .text)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["policy.json"])
    }

    func testFailedFileWriteKeepsPreviousTrustedState() throws {
        try store.allow(T.mom, label: "Mom", scope: .text)
        let folder = store.fileURL.deletingLastPathComponent()
        chmod(folder.path, 0o500)
        defer { chmod(folder.path, 0o700) }
        XCTAssertThrowsError(try store.allow(T.dad, label: "Dad", scope: .text))
        chmod(folder.path, 0o700)
        XCTAssertEqual(trustedState()?.entries.map(\.chat), [T.mom])
    }

    func testFailedHashWriteMakesStoreUntrusted() throws {
        try store.allow(T.mom, label: "Mom", scope: .text)
        keychain.failWrite = true
        XCTAssertThrowsError(try store.allow(T.dad, label: "Dad", scope: .text))
        XCTAssertEqual(store.load(), .untrusted(.fileChangedOutsideBridge))
        XCTAssertNil(store.entry(for: T.mom))
    }

    func testLiveKeychainStoreNamesTheBridgeItem() {
        // Construction only. Tests never call into the real Keychain.
        let live = LiveKeychainHashStore()
        XCTAssertEqual(live.service, AppIdentity.keychainService)
        XCTAssertEqual(live.account, AppIdentity.keychainAccount)
    }

    /// A locked keychain, or an access list that no longer matches the bridge, must fail the read instead of raising a
    /// dialog that blocks the store lock. The read runs with dialogs off and the earlier setting comes back after.
    func testLiveHashReadRunsWithKeychainDialogsOffAndFailsClosed() throws {
        let interaction = FakeInteractionSwitch(allowed: true)
        var allowedDuringRead: [Bool] = []
        let live = LiveKeychainHashStore(service: "test.service", account: "test.account",
                                         interaction: interaction) { _, _ in
            allowedDuringRead.append(interaction.isInteractionAllowed)
            return errSecInteractionNotAllowed
        }
        XCTAssertThrowsError(try live.readHash()) {
            XCTAssertEqual(($0 as? KeychainError)?.status, errSecInteractionNotAllowed)
        }
        XCTAssertEqual(allowedDuringRead, [false])
        XCTAssertTrue(interaction.isInteractionAllowed)

        let store = PolicyStore(fileURL: dir.file("live/policy.json"), keychain: live)
        XCTAssertEqual(store.load(), .untrusted(.hashUnreadable))
        try DurableFile.replace(store.fileURL, with: Data("{}".utf8))
        XCTAssertEqual(store.load(), .untrusted(.hashUnreadable))
        XCTAssertFalse(store.isForegroundModeOn)
        XCTAssertEqual(allowedDuringRead, [false, false, false, false])
        XCTAssertTrue(interaction.isInteractionAllowed)
    }

    func testLiveHashReadPutsBackASettingThatWasAlreadyOff() throws {
        let interaction = FakeInteractionSwitch(allowed: false)
        let hash = Data(repeating: 7, count: 32)
        let live = LiveKeychainHashStore(service: "test.service", account: "test.account",
                                         interaction: interaction) { _, out in
            out?.pointee = hash as CFData
            return errSecSuccess
        }
        XCTAssertEqual(try live.readHash(), hash)
        XCTAssertFalse(interaction.isInteractionAllowed)
        XCTAssertEqual(interaction.changes, [false, false])
    }

    // MARK: First run and failing closed

    func testFirstRunWithNeitherFileNorHashIsTrustedAndEmpty() {
        XCTAssertEqual(store.load(), .trusted(.empty))
        XCTAssertFalse(store.isForegroundModeOn)
    }

    func testFileEditedOutsideBridgeIsUntrusted() throws {
        try seedTrusted()
        var state = try JSONDecoder.wire.decode(PolicyState.self, from: fileBytes)
        state.entries.append(AllowlistEntry(chat: T.sis, label: "Sis", scope: .files, addedAt: Date()))
        try JSONEncoder.wire.encode(state).write(to: store.fileURL)
        chmod(store.fileURL.path, 0o600)
        XCTAssertEqual(store.load(), .untrusted(.fileChangedOutsideBridge))
    }

    func testOneByteChangeIsUntrusted() throws {
        try seedTrusted()
        var bytes = fileBytes
        bytes.append(0x20)
        try bytes.write(to: store.fileURL)
        chmod(store.fileURL.path, 0o600)
        XCTAssertEqual(store.load(), .untrusted(.fileChangedOutsideBridge))
    }

    func testFileMissingWithHashPresentIsUntrusted() throws {
        try seedTrusted()
        try FileManager.default.removeItem(at: store.fileURL)
        XCTAssertEqual(store.load(), .untrusted(.fileMissing))
    }

    func testHashMissingWithFilePresentIsUntrusted() throws {
        try seedTrusted()
        keychain.hash = nil
        XCTAssertEqual(store.load(), .untrusted(.hashMissing))
    }

    func testUnreadableHashIsUntrusted() throws {
        try seedTrusted()
        keychain.failRead = true
        XCTAssertEqual(store.load(), .untrusted(.hashUnreadable))
    }

    func testUnreadableHashWithNoFileIsNotAFirstRun() {
        keychain.failRead = true
        XCTAssertEqual(store.load(), .untrusted(.hashUnreadable))
    }

    func testWrongLengthHashIsUntrusted() throws {
        try seedTrusted()
        keychain.hash = Data([1, 2, 3])
        XCTAssertEqual(store.load(), .untrusted(.hashUnreadable))
    }

    func testUnreadableFileIsUntrusted() throws {
        try seedTrusted()
        chmod(store.fileURL.path, 0o000)
        defer { chmod(store.fileURL.path, 0o600) }
        XCTAssertEqual(store.load(), .untrusted(.fileUnreadable))
    }

    func testUndecodableFileWithMatchingHashIsUnreadable() throws {
        let garbage = Data("not json".utf8)
        try DurableFile.replace(store.fileURL, with: garbage)
        keychain.hash = Data(SHA256.hash(data: garbage))
        XCTAssertEqual(store.load(), .untrusted(.fileUnreadable))
    }

    func testUnknownVersionIsUnreadable() throws {
        let data = try JSONEncoder.wire.encode(PolicyState(version: 2, entries: [], foregroundMode: true))
        try DurableFile.replace(store.fileURL, with: data)
        keychain.hash = Data(SHA256.hash(data: data))
        XCTAssertEqual(store.load(), .untrusted(.fileUnreadable))
        XCTAssertFalse(store.isForegroundModeOn)
    }

    func testFileWithWrongModeIsUntrusted() throws {
        try seedTrusted()
        chmod(store.fileURL.path, 0o644)
        XCTAssertEqual(store.load(), .untrusted(.fileChangedOutsideBridge))
    }

    func testSymlinkInPlaceOfFileIsUntrusted() throws {
        try seedTrusted()
        let real = dir.file("elsewhere.json")
        try FileManager.default.moveItem(at: store.fileURL, to: real)
        try FileManager.default.createSymbolicLink(at: store.fileURL, withDestinationURL: real)
        XCTAssertEqual(store.load(), .untrusted(.fileChangedOutsideBridge))
    }

    func testUntrustedStoreAllowsNothingAndForegroundIsOff() throws {
        try seedTrusted(foreground: true)
        XCTAssertTrue(store.isForegroundModeOn)
        XCTAssertNotNil(store.entry(for: T.mom))
        keychain.hash = Data(repeating: 0, count: 32)
        XCTAssertEqual(store.effective.entries, [])
        XCTAssertNil(store.entry(for: T.mom))
        XCTAssertFalse(store.isForegroundModeOn)
    }

    func testTamperWhileRunningTakesEffectOnTheNextRead() throws {
        try seedTrusted()
        XCTAssertNotNil(store.entry(for: T.dad))
        try Data("{}".utf8).write(to: store.fileURL)
        chmod(store.fileURL.path, 0o600)
        XCTAssertNil(store.entry(for: T.dad))
    }

    func testReapprovingAfterTamperStartsFromEmptyAndIsTrusted() throws {
        try seedTrusted()
        keychain.hash = nil
        try store.allow(T.sis, label: "Sis", scope: .text)
        guard case .trusted(let state) = store.load() else { return XCTFail("expected trusted") }
        XCTAssertEqual(state.entries.map(\.chat), [T.sis])
        XCTAssertFalse(state.foregroundMode)
    }

    func testTurnForegroundOffNeverRetrustsAnUntrustedStore() throws {
        try seedTrusted()
        keychain.hash = nil
        let writes = keychain.writes
        store.turnForegroundOff(reason: "Messages left open")
        XCTAssertEqual(keychain.writes, writes)
        XCTAssertEqual(store.load(), .untrusted(.hashMissing))
    }

    // MARK: Foreground mode switch

    func testTurnForegroundOffPersistsReason() throws {
        try seedTrusted(foreground: true)
        store.turnForegroundOff(reason: "Messages left in edit mode")
        XCTAssertFalse(store.isForegroundModeOn)
        let reopened = PolicyStore(fileURL: store.fileURL, keychain: keychain)
        XCTAssertEqual(reopened.effective.foregroundOffReason, "Messages left in edit mode")
        XCTAssertFalse(reopened.isForegroundModeOn)
    }

    func testTurnForegroundOffStaysOffWhenTheSaveFails() throws {
        try seedTrusted(foreground: true)
        keychain.failWrite = true
        store.turnForegroundOff(reason: "bridge restarted during a foreground action")
        keychain.failWrite = false
        XCTAssertFalse(store.isForegroundModeOn)
        XCTAssertEqual(store.effective.foregroundOffReason, "bridge restarted during a foreground action")
    }

    func testOnlySetForegroundModeTurnsItBackOn() throws {
        try seedTrusted(foreground: true)
        store.turnForegroundOff(reason: "Messages left open")
        try store.allow(T.sis, label: "Sis", scope: .text)
        XCTAssertFalse(store.isForegroundModeOn)
        try store.setForegroundMode(true)
        XCTAssertTrue(store.isForegroundModeOn)
        XCTAssertNil(store.effective.foregroundOffReason)
    }

    // MARK: Scopes

    func testAllowAddsWidensAndNeverNarrows() throws {
        try store.allow(T.mom, label: "Mom", scope: .text)
        XCTAssertEqual(store.entry(for: T.mom)?.scope, .text)
        try store.allow(T.mom, label: "Mom", scope: .files)
        XCTAssertEqual(store.entry(for: T.mom)?.scope, .files)
        try store.allow(T.mom, label: "Mother", scope: .text)
        XCTAssertEqual(store.entry(for: T.mom)?.scope, .files)
        XCTAssertEqual(store.entry(for: T.mom)?.label, "Mother")
        XCTAssertEqual(store.effective.entries.count, 1)
    }

    func testRevokeRemovesTheEntry() throws {
        try seedTrusted()
        try store.revoke(T.mom)
        XCTAssertNil(store.entry(for: T.mom))
        XCTAssertNotNil(store.entry(for: T.dad))
    }

    // MARK: Thread safety

    func testConcurrentAllowsKeepEveryEntryAndStayTrusted() throws {
        let chats = (0..<24).map { CanonicalChatID.direct(handle: "+1415555\(String(format: "%04d", $0))") }
        let failures = NSLock()
        var errors: [Error] = []
        concurrently(chats.count) { i in
            do {
                try self.store.allow(chats[i], label: "c\(i)", scope: i % 2 == 0 ? .text : .files)
                // A reader racing the writers must never see a file and a hash from different saves.
                if case .untrusted(let r) = self.store.load() { throw StorageError(operation: "\(r)", path: "", code: 0) }
            } catch {
                failures.lock(); errors.append(error); failures.unlock()
            }
        }
        XCTAssertTrue(errors.isEmpty, "\(errors)")
        XCTAssertEqual(Set(store.effective.entries.map(\.chat)), Set(chats))
    }
}
