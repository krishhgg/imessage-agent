import XCTest
import IMCore
import IMStore
import IMTestSupport

final class IMStoreSkeletonTests: XCTestCase {
    func testFixtureIsPresent() {
        XCTAssertTrue(FileManager.default.fileExists(atPath: Fixture.chatDB.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: Fixture.contactsJSON.path))
    }

    func testConfigurationPointsAtFixture() {
        let config = StoreConfiguration(chatDBPath: Fixture.chatDB.path, attachmentsRoot: Fixture.attachmentsRoot,
                                        attachmentCacheDir: FileManager.default.temporaryDirectory,
                                        timeZone: Fixture.timeZone)
        XCTAssertEqual(config.chatDBPath, Fixture.chatDB.path)
    }
}
