import Foundation
import IMCore
@testable import IMPolicy
import IMTestSupport
import XCTest

/// Section 3 item 3: one FIFO queue, 30 s in all, then `busy: queue`.
final class ActionQueueTests: XCTestCase {
    func testFreeQueueIsTakenAtOnce() {
        let clock = FakeClock()
        let queue = ActionQueue(clock: clock)
        XCTAssertFalse(queue.isHeld)
        XCTAssertNotNil(queue.acquire(timeout: Limits.queueWait))
        XCTAssertTrue(queue.isHeld)
        XCTAssertTrue(clock.sleeps.isEmpty)
    }

    func testBusyQueueGivesUpAfterExactlyThirtySeconds() {
        let clock = FakeClock()
        let queue = ActionQueue(clock: clock)
        _ = queue.acquire(timeout: Limits.queueWait)
        let start = clock.uptime
        XCTAssertNil(queue.acquire(timeout: Limits.queueWait))
        XCTAssertEqual(clock.uptime - start, Limits.queueWait, accuracy: 1e-6)
        XCTAssertTrue(clock.sleeps.allSatisfy { $0 > 0 && $0 <= ActionQueue.pollInterval + 1e-12 })
        XCTAssertEqual(queue.waitingCount, 0)
        XCTAssertEqual(ActionResult(.busy(.queue)).rendered, "busy: queue")
    }

    func testReleaseJustBeforeTheTimeoutHandsTheQueueOver() {
        let clock = ScriptedClock()
        let queue = ActionQueue(clock: clock)
        let first = queue.acquire(timeout: Limits.queueWait)!
        clock.after(Limits.queueWait - 0.02) { queue.release(first) }
        let start = clock.uptime
        let second = queue.acquire(timeout: Limits.queueWait)
        XCTAssertNotNil(second)
        XCTAssertNotEqual(second, first)
        XCTAssertLessThanOrEqual(clock.uptime - start, Limits.queueWait + 1e-6)
        XCTAssertTrue(queue.isHeld)
    }

    func testReleaseAfterTheTimeoutIsTooLate() {
        let clock = ScriptedClock()
        let queue = ActionQueue(clock: clock)
        let first = queue.acquire(timeout: Limits.queueWait)!
        clock.after(Limits.queueWait + 0.02) { queue.release(first) }
        XCTAssertNil(queue.acquire(timeout: Limits.queueWait))
        XCTAssertTrue(queue.isHeld)
    }

    func testZeroTimeoutOnABusyQueueReturnsAtOnce() {
        let clock = FakeClock()
        let queue = ActionQueue(clock: clock)
        _ = queue.acquire(timeout: Limits.queueWait)
        XCTAssertNil(queue.acquire(timeout: 0))
        XCTAssertNil(queue.acquire(timeout: -5))
        XCTAssertTrue(clock.sleeps.isEmpty)
        XCTAssertEqual(queue.waitingCount, 0)
    }

    func testTimedOutWaiterLeavesTheLine() {
        let clock = FakeClock()
        let queue = ActionQueue(clock: clock)
        let first = queue.acquire(timeout: Limits.queueWait)!
        XCTAssertNil(queue.acquire(timeout: Limits.queueWait))
        queue.release(first)
        XCTAssertFalse(queue.isHeld)
        let sleeps = clock.sleeps.count
        XCTAssertNotNil(queue.acquire(timeout: Limits.queueWait))
        XCTAssertEqual(clock.sleeps.count, sleeps)
    }

    func testStaleOrDoubleReleaseIsIgnored() {
        let queue = ActionQueue(clock: FakeClock())
        let first = queue.acquire(timeout: 0)!
        queue.release(first)
        let second = queue.acquire(timeout: 0)!
        queue.release(first)
        queue.release(QueueTicket(serial: 999))
        XCTAssertTrue(queue.isHeld)
        XCTAssertNil(queue.acquire(timeout: 0))
        queue.release(second)
        XCTAssertFalse(queue.isHeld)
    }

    func testReleaseHandsTheQueueToTheWaiterBeforeANewcomer() {
        let queue = ActionQueue(clock: SystemClock())
        let first = queue.acquire(timeout: 0)!
        let got = expectation(description: "waiter got the queue")
        var waiterTicket: QueueTicket?
        Thread.detachNewThread {
            waiterTicket = queue.acquire(timeout: 10)
            got.fulfill()
        }
        waitUntil { queue.waitingCount == 1 }
        queue.release(first)
        // The waiter may not have woken yet, but the queue is already its own.
        XCTAssertNil(queue.acquire(timeout: 0))
        wait(for: [got], timeout: 10)
        XCTAssertNotNil(waiterTicket)
        queue.release(waiterTicket!)
        XCTAssertFalse(queue.isHeld)
    }

    func testWaitersGetTheQueueInArrivalOrder() {
        let queue = ActionQueue(clock: SystemClock())
        let first = queue.acquire(timeout: 0)!
        let lock = NSLock()
        var order: [Int] = []
        let group = DispatchGroup()
        for n in 0..<5 {
            group.enter()
            Thread.detachNewThread {
                guard let ticket = queue.acquire(timeout: 20) else { return group.leave() }
                lock.lock(); order.append(n); lock.unlock()
                queue.release(ticket)
                group.leave()
            }
            // Start the next waiter only once this one is in line.
            waitUntil { queue.waitingCount == n + 1 }
        }
        queue.release(first)
        XCTAssertEqual(group.wait(timeout: .now() + 20), .success)
        XCTAssertEqual(order, [0, 1, 2, 3, 4])
        XCTAssertFalse(queue.isHeld)
    }

    func testOnlyOneHolderAtATime() {
        let queue = ActionQueue(clock: SystemClock())
        let lock = NSLock()
        var inside = 0
        var most = 0
        var served = 0
        concurrently(16) { _ in
            guard let ticket = queue.acquire(timeout: 20) else { return }
            lock.lock(); inside += 1; most = max(most, inside); served += 1; lock.unlock()
            Thread.sleep(forTimeInterval: 0.002)
            lock.lock(); inside -= 1; lock.unlock()
            queue.release(ticket)
        }
        XCTAssertEqual(served, 16)
        XCTAssertEqual(most, 1)
        XCTAssertFalse(queue.isHeld)
        XCTAssertEqual(queue.waitingCount, 0)
    }

    /// Polls `condition` on the real clock for up to 5 s.
    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            if Date() > deadline { return XCTFail("condition not met", file: file, line: line) }
            Thread.sleep(forTimeInterval: 0.001)
        }
    }
}
