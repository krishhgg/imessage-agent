import XCTest
import IMCore
import IMForeground
import IMTestSupport

final class IMForegroundSkeletonTests: XCTestCase {
    func testFakeClockDrivesTime() {
        let clock = FakeClock()
        let start = clock.uptime
        clock.sleep(Limits.idleThreshold)
        XCTAssertEqual(clock.uptime - start, Limits.idleThreshold)
        XCTAssertEqual(ForegroundPhase.front.rawValue, "front")
    }
}
