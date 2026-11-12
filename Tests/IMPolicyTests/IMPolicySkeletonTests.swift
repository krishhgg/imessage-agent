import XCTest
import IMCore
import IMPolicy
import IMTestSupport

final class IMPolicySkeletonTests: XCTestCase {
    func testAlwaysAskActions() {
        XCTAssertTrue(MutationKind.unsend.alwaysAsks)
        XCTAssertTrue(MutationKind.edit.alwaysAsks)
        XCTAssertTrue(MutationKind.threadedReply.alwaysAsks)
        XCTAssertFalse(MutationKind.send.alwaysAsks)
    }

    func testJournalStatesAreOrdered() {
        XCTAssertLessThan(JournalState.approved, JournalState.invoking)
        XCTAssertLessThan(JournalState.invoked, JournalState.final)
    }
}
