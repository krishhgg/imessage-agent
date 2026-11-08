import CoreServices
import XCTest
@testable import IMBridge
import IMCore

/// doctor's silent Automation check. It never starts Messages, and only a denial points at System Settings.
final class DoctorTests: XCTestCase {
    private static let settingsFix = "allow Messages for iMessage Agent in Privacy & Security > Automation"

    private func automation(_ state: PermissionState, running: Bool, closed: Bool = false) throws -> DoctorCheck {
        let h = try Harness()
        h.app.state_ = running ? SafeMessagesApp.hiddenReady : .notRunning
        h.permissions.automationState = state
        h.permissions.messagesClosed = closed
        guard case .doctor(let report) = h.call(.doctor(DoctorArgs())) else {
            XCTFail("doctor")
            return DoctorCheck(name: "", ok: false)
        }
        XCTAssertEqual(h.permissions.calls.first, .silentAutomation, "checked silently")
        XCTAssertFalse(h.permissions.calls.contains(.automation(ask: true)), "doctor raises no prompt")
        XCTAssertTrue(h.app.calls.isEmpty, "doctor never starts Messages")
        return try XCTUnwrap(report.checks.first { $0.name == "Automation" })
    }

    func testMessagesClosedIsANoteAndNotAFailure() throws {
        // The probe's procNotFound decides it, even when the app list still shows Messages as running.
        for running in [false, true] {
            let check = try automation(.unknown, running: running, closed: true)
            XCTAssertTrue(check.ok, "running: \(running)")
            XCTAssertEqual(check.detail, "can't check while Messages is closed")
            XCTAssertNil(check.fix)
        }
    }

    func testTheReportCountsMessagesClosedAsNoFailure() throws {
        let h = try Harness()
        h.app.state_ = .notRunning
        h.permissions.messagesClosed = true
        guard case .doctor(let report) = h.call(.doctor(DoctorArgs())) else { return XCTFail("doctor") }
        let text = Format.doctor(report)
        XCTAssertTrue(text.contains("ok Automation: can't check while Messages is closed"), text)
        XCTAssertTrue(text.hasPrefix("doctor · \(report.checks.count) checks, 0 failing"), text)
        XCTAssertTrue(h.app.calls.isEmpty, "doctor never starts Messages")
    }

    func testOnlyProcNotFoundMeansMessagesIsClosed() {
        XCTAssertEqual(LivePermissionProbe.silentAutomation(OSStatus(procNotFound)), .messagesClosed)
        XCTAssertEqual(LivePermissionProbe.silentAutomation(OSStatus(noErr)), .answered(.granted))
        XCTAssertEqual(LivePermissionProbe.silentAutomation(OSStatus(errAEEventNotPermitted)), .answered(.denied))
        XCTAssertEqual(LivePermissionProbe.silentAutomation(OSStatus(errAEEventWouldRequireUserConsent)),
                       .answered(.notDetermined))
        XCTAssertEqual(LivePermissionProbe.silentAutomation(-1), .answered(.unknown))
    }

    func testGrantedPassesWhetherOrNotMessagesIsRunning() throws {
        for running in [false, true] {
            let check = try automation(.granted, running: running)
            XCTAssertTrue(check.ok, "running: \(running)")
            XCTAssertEqual(check.detail, "granted")
            XCTAssertNil(check.fix)
        }
    }

    func testDeniedFailsWithTheSettingsFix() throws {
        for running in [false, true] {
            let check = try automation(.denied, running: running)
            XCTAssertFalse(check.ok, "running: \(running)")
            XCTAssertEqual(check.detail, "denied")
            XCTAssertEqual(check.fix, DoctorTests.settingsFix)
        }
    }

    func testOnlyADenialPointsAtSystemSettings() throws {
        let notAsked = try automation(.notDetermined, running: true)
        XCTAssertFalse(notAsked.ok)
        XCTAssertEqual(notAsked.fix, "answer the Automation prompt on the Mac")

        for running in [false, true] {
            let unknown = try automation(.unknown, running: running)
            XCTAssertFalse(unknown.ok, "an answer macOS couldn't give for a running Messages is a real failure")
            XCTAssertEqual(unknown.fix, "run imessage doctor again")
        }

        let answers: [SilentAutomation] = [.answered(.granted), .answered(.notDetermined), .answered(.unknown),
                                           .messagesClosed]
        for answer in answers {
            XCTAssertNotEqual(DoctorService.automationCheck(answer).fix, DoctorTests.settingsFix, "\(answer)")
        }
    }
}
