import CoreGraphics
import Foundation
import IMCore

/// The only keys the bridge ever posts (DESIGN.md section 4, Targeting).
public enum ForegroundKey: Hashable, Sendable {
    case returnKey
    case escape
}

/// Posts a key down and up to one pid. Live: `PidKeyPoster`. Tests: a recorder fake.
public protocol KeyPosting: AnyObject {
    /// False when nothing was posted.
    func post(_ key: ForegroundKey, toPID pid: Int32) -> Bool
}

/// `CGEvent(keyboardEventSource:virtualKey:keyDown:)` then `postToPid`, from a private event source with no
/// modifier flags (S3 `axkey.swift` and `fg.swift`). Events posted to a pid skip the HID system state, so the
/// ownership check doesn't see them as user input. Owner: IMForeground.
public final class PidKeyPoster: KeyPosting {
    public init() {}

    /// `kVK_Return` is 36 and `kVK_Escape` is 53.
    public static func virtualKey(for key: ForegroundKey) -> CGKeyCode {
        switch key {
        case .returnKey: return 36
        case .escape: return 53
        }
    }

    public func post(_ key: ForegroundKey, toPID pid: Int32) -> Bool {
        guard pid > 0, let source = CGEventSource(stateID: .privateState) else { return false }
        let code = Self.virtualKey(for: key)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else { return false }
        down.flags = []
        up.flags = []
        down.postToPid(pid)
        up.postToPid(pid)
        return true
    }
}
