import Foundation
import XCTest
@testable import IMBridge
import IMCore
import IMTestSupport

/// A `wait` whose client hangs up ends within two polls, and the server lets go of its connection.
final class SocketServerTests: XCTestCase {
    /// A harness whose clock sleeps a few real milliseconds per call, so a `wait` that ignored the hang-up would run
    /// for many real seconds.
    private func slowHarness() throws -> Harness {
        try Harness(clock: TestClock(realPause: 0.005))
    }

    /// Signals once the connection thread has started polling.
    private func firstSleep(_ clock: TestClock) -> DispatchSemaphore {
        let polling = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var signalled = false
        clock.onSleep { _ in
            lock.lock()
            let go = !signalled
            signalled = true
            lock.unlock()
            if go { polling.signal() }
        }
        return polling
    }

    func testAWaitStopsWithinTwoPollsOfItsClientHangingUp() throws {
        let h = try slowHarness()
        let polling = firstSleep(h.clock)
        let (client, server) = try SocketPair.make()
        let socket = SocketServer(listenFD: -1, handler: h.dispatcher)
        socket.ioTimeout = 5
        let done = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var returnedAt: TimeInterval?
        Thread {
            socket.serve(server)
            lock.lock()
            returnedAt = h.clock.uptime
            lock.unlock()
            done.signal()
        }.start()
        try SocketPair.writeAll(client, try FrameCodec.encode(Request(body: .wait(WaitArgs(timeout: 3600)))))
        XCTAssertEqual(polling.wait(timeout: .now() + 10), .success, "the wait started polling")
        close(client)
        let closedAt = h.clock.uptime

        XCTAssertEqual(done.wait(timeout: .now() + 10), .success, "serve returned after the client hung up")
        lock.lock()
        let end = returnedAt
        lock.unlock()
        let elapsed = try XCTUnwrap(end) - closedAt
        XCTAssertLessThanOrEqual(elapsed, 2 * OpDispatcher.waitPollInterval)
    }

    func testAHungUpWaitReleasesItsConnectionAndResidency() throws {
        let h = try slowHarness()
        let polling = firstSleep(h.clock)
        let live = try LiveSocket(h)
        defer { live.stop() }
        let channel = try live.connect()
        try channel.writeFrame(Request(body: .wait(WaitArgs(timeout: 3600))))
        XCTAssertEqual(polling.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(live.server.activeConnections, 1)
        XCTAssertGreaterThanOrEqual(h.container.residency.holds, 1)
        channel.close()
        let closedAt = h.clock.uptime

        XCTAssertTrue(eventually { live.server.activeConnections == 0 })
        XCTAssertLessThanOrEqual(h.clock.uptime - closedAt, 2 * OpDispatcher.waitPollInterval)
        XCTAssertTrue(eventually { h.container.residency.holds == 0 })
    }

    func testAWaitWithItsClientStillThereRunsToItsTimeout() throws {
        let h = try Harness()
        let live = try LiveSocket(h)
        defer { live.stop() }
        let start = h.clock.uptime
        let answer = try live.round(.wait(WaitArgs(timeout: 5)))
        XCTAssertEqual(answer.payload, .wait(WaitOutcome(chat: nil, message: nil, timedOut: true)))
        XCTAssertGreaterThanOrEqual(h.clock.uptime - start, 5)
    }

    func testPeerHasLeftSeesAHangUpButNotAQuietOrTalkingPeer() throws {
        let (client, server) = try SocketPair.make()
        defer { close(server) }
        XCTAssertFalse(SocketServer.peerHasLeft(server), "a quiet peer is still there")
        try SocketPair.writeAll(client, Data([1, 2, 3]))
        XCTAssertFalse(SocketServer.peerHasLeft(server), "unread bytes mean the peer is still there")
        XCTAssertEqual(try SocketPair.read(server, count: 3), Data([1, 2, 3]), "the check reads nothing off the socket")
        close(client)
        XCTAssertTrue(SocketServer.peerHasLeft(server))
    }
}
