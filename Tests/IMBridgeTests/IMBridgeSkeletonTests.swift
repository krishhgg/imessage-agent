import XCTest
@testable import IMBridge
import IMCore
import IMTestSupport

/// launchd socket adoption over a fake `launch_activate_socket`. Tests never call launchd.
final class IMBridgeSkeletonTests: XCTestCase {
    func testNotLaunchedByLaunchd() {
        var asked: [String] = []
        let fds = LaunchActivation.adopt(name: AppIdentity.launchdSocketName) { name, _, _ in
            asked.append(String(cString: name))
            return ESRCH
        }
        XCTAssertNil(fds, "a process launchd didn't start gets nil and kickstarts the job instead")
        XCTAssertEqual(asked, [AppIdentity.launchdSocketName])
    }

    func testTheListeningFdsLaunchdHoldsAreAdopted() {
        let fds = LaunchActivation.adopt(name: AppIdentity.launchdSocketName) { _, out, count in
            let array = malloc(2 * MemoryLayout<Int32>.size)!.bindMemory(to: Int32.self, capacity: 2)
            array[0] = 7
            array[1] = 9
            out.pointee = array
            count.pointee = 2
            return 0
        }
        XCTAssertEqual(fds, [7, 9])
    }

    func testAnEmptyListIsNotAnActivation() {
        let fds = LaunchActivation.adopt(name: AppIdentity.launchdSocketName) { _, out, count in
            out.pointee = malloc(MemoryLayout<Int32>.size)?.bindMemory(to: Int32.self, capacity: 1)
            count.pointee = 0
            return 0
        }
        XCTAssertNil(fds)
    }
}
