import Foundation
import XCTest
@testable import IMForeground
import IMCore
import IMTestSupport
import IMUI

/// The release-test markers that tests 4, 5 and 6b read from bridge.log (scripts/release-tests/README.md, Bridge
/// markers). Each one comes right before its step, after that step's ownership check passed.
final class MarkerTests: XCTestCase {
    static let start = ["phase idleGate", "phase preconditions", "phase activationCheck", "phase activating",
                        "phase front"]

    // MARK: - Order

    func testEditWritesEveryMarkerRightBeforeItsStep() {
        let h = Harness()
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result.code, .ok)
        XCTAssertEqual(h.actionsAndMarkers, [
            .marker("phase idleGate"), .acquire(30),
            .marker("phase preconditions"), .ensureHidden, .selectChat, .findBubble,
            .marker("phase activationCheck"), .marker("phase activating"), .activate,
            .marker("phase front"), .findBubble, .willInvoke, .perform(UINames.edit),
            .marker("field-set"), .setValue(Harness.newText),
            .marker("phase beforeReturn"), .verifySelected,
            .marker("key return"), .key(.returnKey), .didInvoke,
            .marker("phase finishing"), .marker("hide"), .hide,
            .marker("phase verifying"), .verify,
            .marker("phase done"),
        ])
        assertMarkersPrecedeEffects(h)
    }

    func testReplyMarksEachFinishEscape() {
        let h = Harness()
        h.ax.escapesToClose = 2
        let outcome = h.runReply()
        XCTAssertEqual(outcome.result.code, .submitted)
        XCTAssertEqual(h.log.markers, Self.start + [
            "field-set", "phase beforeReturn", "key return", "phase finishing", "key escape", "key escape", "hide",
            "phase verifying", "phase done",
        ])
        assertMarkersPrecedeEffects(h)
    }

    func testFocusRestoreMarkerNamesTheEarlierAppRightBeforeTheReopen() {
        let h = Harness()
        h.frontAfterHide = Harness.finder
        h.runEdit()
        XCTAssertEqual(Array(h.log.markers.suffix(5)),
                       ["phase finishing", "hide", "focus-restore com.apple.Safari", "phase verifying", "phase done"])
        XCTAssertEqual(h.log.count(.reopen("com.apple.Safari")), 1)
        assertMarkersPrecedeEffects(h)
    }

    func testBridgeOwnedFailureMarksTheRestoreAndEachEscape() {
        let h = Harness()
        // The edit window closes after Messages comes forward, as in release test 6b's timed edit.
        h.editWindowByCall = { $0 < 6 }
        h.ax.escapesToClose = 2
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result.code, .expired)
        XCTAssertEqual(h.log.markers, Self.start + [
            "field-set", "phase beforeReturn", "phase bridgeOwnedCleanup", "field-restore", "key escape",
            "key escape", "phase finishing", "hide",
        ])
        XCTAssertEqual(h.log.writes, [Harness.newText, Harness.oldText])
        assertMarkersPrecedeEffects(h)
    }

    func testTakeoverWritesTheFieldResetMarkerAndNoKeyMarker() {
        let h = Harness()
        h.injectInput(on: .setValue(Harness.newText))
        let outcome = h.runEdit()
        XCTAssertEqual(outcome.result.code, .aborted(.userTookOver))
        XCTAssertEqual(h.log.markers, Self.start + ["field-set", "phase beforeReturn", "phase takeover", "field-reset"])
        XCTAssertEqual(h.log.writes, [Harness.newText, Harness.oldText])
        assertMarkersPrecedeEffects(h)
    }

    func testTakeoverThatLeavesTheFieldAloneWritesNoFieldMarker() {
        let h = Harness()
        h.injectInput(on: .setValue(Harness.newText)) { [unowned h] in
            h.ax.transform = { $0 + "!" }
            return true
        }
        h.runEdit()
        XCTAssertEqual(markersAfterInput(h), ["phase beforeReturn", "phase takeover"])
    }

    // MARK: - Release test 5

    /// Release test 5 posts input as soon as a point's marker shows (`trigger_for` in t5-abort.sh) and fails the
    /// case on any `key`, `hide` or `focus-restore` marker after the input. The step whose marker the input follows
    /// may still run, inside the test's 15 ms grace.
    func testNoKeyHideOrFocusMarkerFollowsInputAtAnyReleaseTestFivePoint() {
        let expired: (Harness) -> Void = { $0.editWindowByCall = { $0 < 6 } }
        let cases: [(point: String, trigger: String, setup: (Harness) -> Void, beforeReturn: Bool)] = [
            ("before-field", "phase front", { _ in }, true),
            ("field-restore", "phase bridgeOwnedCleanup", expired, true),
            ("between-escapes", "key escape", { expired($0); $0.ax.escapesToClose = 2 }, true),
            ("before-hide", "phase finishing", { _ in }, false),
            ("before-focus-restore", "hide", { $0.frontAfterHide = Harness.finder }, false),
        ]
        for c in cases {
            let h = Harness()
            c.setup(h)
            h.injectInput(on: .marker(c.trigger))
            let outcome = h.runEdit()
            XCTAssertTrue(h.log.events.contains(.input), c.point)
            let after = markersAfterInput(h)
            XCTAssertFalse(after.contains { $0.hasPrefix("key ") || $0 == "hide" || $0.hasPrefix("focus-restore") },
                           "\(c.point): \(after)")
            XCTAssertTrue(after.contains("phase takeover") || outcome.result.notes.contains(.userTookOver), c.point)
            if c.beforeReturn {
                XCTAssertEqual(outcome.result.code, .aborted(.userTookOver), c.point)
                XCTAssertFalse(h.log.keys.contains(.returnKey), c.point)
            } else {
                XCTAssertEqual(outcome.result.code, .ok, c.point)
                XCTAssertTrue(outcome.result.notes.contains(.userTookOver), c.point)
            }
        }
    }

    // MARK: - Lines

    func testMarkerLineIsWhatTheReleaseTestScriptsRead() {
        let line = ReleaseTestMarkers.line("phase front", at: Date(timeIntervalSince1970: 1_767_225_600.1239))
        XCTAssertEqual(line, "release-test 1767225600123 phase front\n")
        // `have_markers` in scripts/release-tests/lib.sh.
        XCTAssertNotNil(line.range(of: "release-test [0-9]+ phase ", options: .regularExpression))
        XCTAssertEqual(ReleaseTestMarkers.line("focus-restore com.apple.Safari", at: Date(timeIntervalSince1970: 2)),
                       "release-test 2000 focus-restore com.apple.Safari\n")
    }

    func testPhaseMarkersUseTheNamesTheScriptsMatch() {
        // README.md lists these, and t4 and t5 match `phase front`, `phase bridgeOwnedCleanup` and `phase finishing`.
        let names: [ForegroundPhase] = [.idleGate, .preconditions, .activationCheck, .activating,
                                        .lateActivationWatch, .front, .beforeReturn, .takeover,
                                        .bridgeOwnedCleanup, .finishing, .verifying, .done]
        XCTAssertEqual(names.map(\.rawValue), [
            "idleGate", "preconditions", "activationCheck", "activating", "lateActivationWatch", "front",
            "beforeReturn", "takeover", "bridgeOwnedCleanup", "finishing", "verifying", "done",
        ])
    }

    func testInitWritesMarkersOnlyInTheReleaseTestBuild() {
        let h = Harness()
        let windows = HiddenWindowManager(app: h.app, ax: h.ax, transfers: FakePendingTransfers(), clock: h.clock)
        let env = ForegroundEnvironment(clock: h.clock, input: h.input, app: h.app, ax: h.ax, keys: h.keys,
                                        verifier: h.verifier, queue: h.queue, targeting: h.targeting,
                                        windows: windows, source: h.source, rows: h.rows, mode: h.mode) { _ in }
        #if IMESSAGE_RELEASE_TESTS
        XCTAssertNotNil(env.marker)
        #else
        XCTAssertNil(env.marker)
        #endif
    }

    func testNoMarkerWriterRunsWithoutOne() {
        let h = Harness()
        var env = h.machine.env
        env.marker = nil
        let outcome = ForegroundMachine(env: env).run(
            ForegroundRun(chat: h.chat, action: .edit(target: h.target, newText: Harness.newText),
                          queueDeadline: h.queueDeadline),
            recorder: h.recorder)
        XCTAssertEqual(outcome.result.code, .ok)
        XCTAssertTrue(h.log.markers.isEmpty)
    }
}

/// Markers logged after the first injected input.
func markersAfterInput(_ h: Harness) -> [String] {
    h.log.afterInput.compactMap { if case .marker(let marker) = $0 { return marker } else { return nil } }
}

/// Every field write, key, hide and reopen comes right after its marker, and every step marker right before its
/// step, reads aside.
func assertMarkersPrecedeEffects(_ h: Harness, file: StaticString = #filePath, line: UInt = #line) {
    let events = h.actionsAndMarkers
    for (i, event) in events.enumerated() {
        let previous: String? = {
            guard i > 0, case .marker(let marker) = events[i - 1] else { return nil }
            return marker
        }()
        switch event {
        case .setValue:
            XCTAssertTrue(["field-set", "field-restore", "field-reset"].contains(previous ?? ""),
                          "write at \(i) after \(previous ?? "no marker")", file: file, line: line)
        case .key(.returnKey):
            XCTAssertEqual(previous, "key return", "Return at \(i)", file: file, line: line)
        case .key(.escape):
            XCTAssertEqual(previous, "key escape", "Escape at \(i)", file: file, line: line)
        case .hide:
            XCTAssertEqual(previous, "hide", "hide at \(i)", file: file, line: line)
        case .reopen(let bundleID):
            XCTAssertEqual(previous, "focus-restore \(bundleID)", "reopen at \(i)", file: file, line: line)
        case .marker(let marker) where !marker.hasPrefix("phase "):
            let next = i + 1 < events.count ? events[i + 1] : nil
            let matches: Bool
            switch (marker, next) {
            case ("field-set", .setValue?), ("field-restore", .setValue?), ("field-reset", .setValue?),
                 ("key return", .key(.returnKey)?), ("key escape", .key(.escape)?), ("hide", .hide?):
                matches = true
            case (_, .reopen(let bundleID)?):
                matches = marker == "focus-restore \(bundleID)"
            default:
                matches = false
            }
            XCTAssertTrue(matches, "marker \(marker) at \(i) is followed by \(String(describing: next))",
                          file: file, line: line)
        default:
            break
        }
    }
}
