import Foundation
import IMCore

/// Proof of holding the queue. Released exactly once.
public struct QueueTicket: Hashable, Sendable {
    public var serial: UInt64

    public init(serial: UInt64) { self.serial = serial }
}

/// The one serialized queue for sends and UI actions (DESIGN.md section 3 item 3).
///
/// - Taken after approval, in arrival order, released when the request records `final`.
/// - Requests waiting for approval and foreground actions at their idle gate don't hold it.
/// - A request waits up to `Limits.queueWait` in all, then returns `busy: queue`.
public protocol ActionQueueing: AnyObject {
    /// Blocks up to `timeout`. Nil means `busy: queue`.
    func acquire(timeout: TimeInterval) -> QueueTicket?
    func release(_ ticket: QueueTicket)
    var isHeld: Bool { get }
}

/// FIFO queue with direct hand-off. Owner: IMPolicy.
///
/// - Each `acquire` takes the next serial number, which is also its ticket. Callers get the queue in serial order.
/// - `release` hands the queue straight to the oldest waiter, so a newcomer can never jump ahead of it.
/// - A waiter that reaches its timeout leaves the line and gets nil. The timeout counts on `clock.uptime`; a waiter
///   whose turn came before it gave up keeps the ticket.
/// - `release` of a ticket that doesn't hold the queue (stale, or already released) does nothing, so a double
///   release can't free the queue under the next holder.
///
/// Waiters poll through the injected clock every `pollInterval`, which hands the queue over within 20 ms live and
/// lets `FakeClock` tests run the 30 s wait at once. Thread safe.
public final class ActionQueue: ActionQueueing {
    public let clock: Clock

    static let pollInterval: TimeInterval = 0.02

    private let lock = NSLock()
    private var holder: UInt64?
    /// Serials waiting, oldest first.
    private var waiters: [UInt64] = []
    private var nextSerial: UInt64 = 1

    public init(clock: Clock) { self.clock = clock }

    public func acquire(timeout: TimeInterval) -> QueueTicket? {
        lock.lock()
        let serial = nextSerial
        nextSerial += 1
        if holder == nil && waiters.isEmpty {
            holder = serial
            lock.unlock()
            return QueueTicket(serial: serial)
        }
        waiters.append(serial)
        lock.unlock()

        let deadline = clock.uptime + max(0, timeout)
        while true {
            let now = clock.uptime
            lock.lock()
            if holder == serial {
                lock.unlock()
                return QueueTicket(serial: serial)
            }
            if now >= deadline {
                waiters.removeAll { $0 == serial }
                lock.unlock()
                return nil
            }
            lock.unlock()
            clock.sleep(min(ActionQueue.pollInterval, deadline - now))
        }
    }

    public func release(_ ticket: QueueTicket) {
        lock.lock()
        defer { lock.unlock() }
        guard holder == ticket.serial else { return }
        holder = waiters.isEmpty ? nil : waiters.removeFirst()
    }

    public var isHeld: Bool {
        lock.lock()
        defer { lock.unlock() }
        return holder != nil
    }

    /// Requests waiting for the queue right now. Tests use it to line waiters up.
    var waitingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return waiters.count
    }
}
