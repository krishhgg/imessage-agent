import CoreGraphics
import Foundation
import IMCore

/// User input as the idle gate and ownership check read it (DESIGN.md section 4 steps 2 and 3).
public protocol InputMonitoring: AnyObject {
    /// Seconds since the last key, flags, mouse button or scroll event in the HID event state.
    func secondsSinceLastInput() -> TimeInterval
}

/// Live `InputMonitoring` over `CGEventSource.secondsSinceLastEventType(.hidSystemState, ...)`, the smallest value
/// over `eventTypes`. Keys the bridge posts to the Messages pid come from a private event source and never pass
/// through the HID system state, so they shouldn't count; release test 5 checks that. The S3 spike read
/// `combinedSessionState` for key down and left click only; reading `hidSystemState` is the design choice in
/// section 4 step 2. Owner: IMForeground.
public final class HIDInputMonitor: InputMonitoring {
    /// Key, flags, every mouse button (down, up and dragged) and scroll events. Mouse moves don't count.
    public static let eventTypes: [CGEventType] = [
        .keyDown, .keyUp, .flagsChanged,
        .leftMouseDown, .leftMouseUp, .leftMouseDragged,
        .rightMouseDown, .rightMouseUp, .rightMouseDragged,
        .otherMouseDown, .otherMouseUp, .otherMouseDragged,
        .scrollWheel,
    ]

    public init() {}

    /// A NaN reading counts as input right now, so a bad read never opens the idle gate.
    public func secondsSinceLastInput() -> TimeInterval {
        var least = TimeInterval.infinity
        for type in Self.eventTypes {
            let seconds = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: type)
            if seconds.isNaN { return 0 }
            least = min(least, seconds)
        }
        return least
    }
}
