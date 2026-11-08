import XCTest
import IMCore
import IMUI
import IMTestSupport

final class IMUISkeletonTests: XCTestCase {
    func testEnglishActionNames() {
        XCTAssertEqual(UINames.tapbackAction(.heart), "Heart")
        XCTAssertEqual(UINames.tapbackAction(.laugh), "Ha ha!")
        XCTAssertEqual(UINames.undoSend, "Undo Send")
    }

    func testCapabilityPrerequisites() {
        for cap: Capability in [.tapbackOwnMessages(.heart), .tapbackIncoming(.like), .emojiTapback, .unsend] {
            XCTAssertTrue(cap.isUIAction)
            XCTAssertEqual(cap.prerequisites, [.targeting])
        }
        for cap: Capability in [.edit, .threadedReply] {
            XCTAssertEqual(cap.prerequisites, [.targeting, .foregroundMode])
        }
        for cap: Capability in [.imageSend, .attachmentConversion, .groupSend, .hiddenChatSwitch, .targeting,
                                .foregroundMode] {
            XCTAssertFalse(cap.isUIAction)
            XCTAssertTrue(cap.prerequisites.isEmpty)
        }
        // Every UI action runs in place on the chat already selected, so none needs the hidden chat switch.
        for cap in Capability.reported + [.tapbackIncoming(.emoji("😭")), .tapbackOwnMessages(.emoji("😭"))] {
            XCTAssertFalse(cap.prerequisites.contains(.hiddenChatSwitch), cap.name)
        }
    }
}
