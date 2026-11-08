import XCTest
import IMCore
import IMSend
import IMTestSupport

final class IMSendSkeletonTests: XCTestCase {
    func testScriptDeclaresEveryHandler() {
        for handler in ScriptHandler.allCases {
            XCTAssertTrue(SendScripts.source.contains("on \(handler.rawValue)("), handler.rawValue)
        }
    }
}
