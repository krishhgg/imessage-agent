import XCTest
import IMCore
import IMTestSupport
@testable import imessage

final class CLISkeletonTests: XCTestCase {
    func testUsageListsEveryVerb() {
        for verb in ["chats", "unread", "read", "show", "search", "who", "att", "send", "react", "unsend", "edit",
                     "allow", "revoke", "pending", "wait", "changes", "caps", "doctor", "setup"] {
            XCTAssertTrue(ArgumentParser.usage.contains(verb), verb)
        }
        XCTAssertEqual(ExitCode.usage.rawValue, 2)
        XCTAssertTrue(ArgumentParser.usage.contains("doctor [--ui]"))
    }
}
