import Foundation
import XCTest
@testable import IMForeground
import IMCore
import IMTestSupport
import IMUI

/// The edit path reads chat.db before `t_front` only, so a parallel read holding the interactive connection can't
/// push Return past the 3 s deadline.
final class EditTests: XCTestCase {
    /// Calls recorded at `log.events.count` `c` ran after event `c - 1`.
    private func reads(_ h: Harness) -> [Int] { (h.source.readsAt + h.targeting.chatDBReadsAt).sorted() }

    func testEditMakesNoChatDBCallBetweenFrontAndReturn() throws {
        let h = Harness()
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result.code, .ok)
        let front = try XCTUnwrap(h.log.index(of: .activate))
        let returned = try XCTUnwrap(h.log.index(of: .key(.returnKey)))
        XCTAssertFalse(reads(h).isEmpty)
        XCTAssertTrue(reads(h).contains { $0 <= front }, "step 1 reads chat.db")
        XCTAssertEqual(reads(h).filter { $0 > front && $0 <= returned }, [], "no chat.db call inside the 3 s window")
        XCTAssertEqual(h.log.count(.verifySelected), 1, "step 4 still checks the signature, from AX")
    }

    func testTheSignatureAndBoundRowAreReadInStepOne() {
        let h = Harness()
        h.runEdit()
        XCTAssertEqual(h.targeting.verifyExcluding, [410])
    }

    func testAnExpectationThatCannotBeReadStopsBeforeActivation() {
        let h = Harness()
        h.targeting.failExpectation = true
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result.code, .aborted(.check("chat.db read")))
        XCTAssertEqual(h.log.count(.activate), 0)
        XCTAssertTrue(h.log.writes.isEmpty)
        XCTAssertTrue(h.log.keys.isEmpty)
    }

    func testAnEditFieldWhoseValueCannotBeReadIsNeverWritten() {
        // The live driver throws when the field's value can't be read, so there is no earlier value to restore and
        // the runner never writes or records "" in its place.
        let h = Harness()
        h.log.onEvent = { [unowned h] event in if event == .perform(UINames.edit) { h.ax.failEditField = true } }
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result.code, .aborted(.deadline))
        XCTAssertTrue(h.log.writes.isEmpty, "\(h.log.writes)")
        XCTAssertFalse(h.log.markers.contains("field-set"))
        XCTAssertFalse(h.log.keys.contains(.returnKey))
    }

    func testASignatureMismatchInStepFourIsAbortedView() {
        let h = Harness()
        h.targeting.signatureMatches = false
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result.code, .aborted(.check("view")))
        XCTAssertFalse(h.log.keys.contains(.returnKey))
    }
}
