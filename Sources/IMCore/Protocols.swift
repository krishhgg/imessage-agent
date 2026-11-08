import Foundation

// Protocols shared across modules. Live implementations sit in the module named on each one; tests use the fakes
// in Tests/IMTestSupport. Nothing here imports AppKit, so the CLI stays free of it.

// MARK: - Clock

/// Wall time and monotonic time. Every timeout and window in DESIGN.md runs off this, so tests can drive time.
public protocol Clock: AnyObject {
    /// Wall clock, for row dates, approval expiry and the journal.
    var now: Date { get }
    /// Monotonic seconds, for deadlines (section 4: `t_front`, the 3 s Return deadline).
    var uptime: TimeInterval { get }
    /// Blocks the calling thread. Fakes advance time instead.
    func sleep(_ seconds: TimeInterval)
}

/// Live clock. Owner: IMCore.
public final class SystemClock: Clock {
    public init() {}
    public var now: Date { Date() }
    public var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }
    public func sleep(_ seconds: TimeInterval) {
        if seconds > 0 { Thread.sleep(forTimeInterval: seconds) }
    }
}

// MARK: - Messages process control

/// Snapshot of Messages as the window rules see it (section 4, Window rules).
public struct MessagesAppState: Hashable, Sendable {
    public var isRunning: Bool
    public var pid: Int32?
    public var isFrontmost: Bool
    /// Polled value of `NSRunningApplication.isHidden`. The return value of `hide()` is never trusted.
    public var isHidden: Bool
    /// Windows Messages reports through AX (needs the Accessibility grant). -1 if unknown.
    public var axWindowCount: Int
    /// On-screen windows owned by Messages from the window server, at any layer and size.
    public var onScreenWindowCount: Int
    /// Messages' real windows on every Space, from the window server's full list: layer 0, both sides at least
    /// 100 points. AX and the on-screen list both miss a window on another Space or full screen in its own Space, and
    /// this count has it. The size floor drops the 1512 x 33 menu bar strips every app owns there on macOS 26
    /// (docs/BUILD-PLAN.md entry 49). -1 if the window server gives no list.
    public var allSpacesWindowCount: Int
    /// The windows in `allSpacesWindowCount` that the window server puts on at least one Space. Messages also owns a
    /// 500 x 500 layer 0 window it never shows, at the screen's bottom-left corner on no Space, and this count drops
    /// it (docs/BUILD-PLAN.md entry 51). Only the hidden rule's one-window test uses it. Equal to
    /// `allSpacesWindowCount` when the Space lookup isn't available, and -1 when the window server gives no list.
    public var spaceWindowCount: Int

    /// `spaceWindowCount` defaults to `allSpacesWindowCount`.
    public init(isRunning: Bool, pid: Int32?, isFrontmost: Bool, isHidden: Bool, axWindowCount: Int,
                onScreenWindowCount: Int, allSpacesWindowCount: Int, spaceWindowCount: Int? = nil) {
        self.isRunning = isRunning
        self.pid = pid
        self.isFrontmost = isFrontmost
        self.isHidden = isHidden
        self.axWindowCount = axWindowCount
        self.onScreenWindowCount = onScreenWindowCount
        self.allSpacesWindowCount = allSpacesWindowCount
        self.spaceWindowCount = spaceWindowCount ?? allSpacesWindowCount
    }

    public static let notRunning = MessagesAppState(isRunning: false, pid: nil, isFrontmost: false, isHidden: false,
                                                    axWindowCount: 0, onScreenWindowCount: 0,
                                                    allSpacesWindowCount: 0)
}

/// The frontmost app, recorded before foreground mode and restored after it (section 4 step 6).
public struct FrontApp: Hashable, Sendable {
    public var bundleID: String?
    public var name: String
    public var pid: Int32
    /// A reopen event would create a window for an app with none, so focus restore skips it (section 4 step 6).
    public var hasWindows: Bool

    public init(bundleID: String?, name: String, pid: Int32, hasWindows: Bool) {
        self.bundleID = bundleID
        self.name = name
        self.pid = pid
        self.hasWindows = hasWindows
    }
}

/// Process-level control of Messages. Live implementation: `IMUI.LiveMessagesApp`.
/// Used by IMSend (cold start), IMUI (window rules) and IMForeground (activation, hide, focus restore).
public protocol MessagesAppControl: AnyObject {
    func state() -> MessagesAppState
    /// Whether Messages is the frontmost app, read without the AX window count or the window list, which can block.
    /// The ownership check and the foreground polls that need only this bit use it. The default reads `state()`.
    func isFrontmost() -> Bool
    /// `/usr/bin/open -g -j -b com.apple.MobileSMS` (section 4). Returns when `open` exits.
    func launchHidden() -> Bool
    /// Quits Messages through Apple Events (section 4, no-window path). Does not wait.
    func quit() -> Bool
    /// Polls until Messages has exited or `timeout` passes.
    func waitForExit(timeout: TimeInterval) -> Bool
    /// `/usr/bin/open -b com.apple.MobileSMS`, the only activation that worked in S3. Foreground mode only.
    /// Returns once `open` has started, without waiting for it to exit, so the caller can watch the front app while
    /// `open` runs.
    func activateForeground() -> Bool
    /// `NSRunningApplication.hide()`. Callers poll `state().isHidden` afterwards.
    func hide()
    func frontmostApp() -> FrontApp?
    /// `/usr/bin/open -b <bundleID>` to restore the user's earlier app (section 4 step 6).
    func reopen(bundleID: String) -> Bool
}

extension MessagesAppControl {
    public func isFrontmost() -> Bool { state().isFrontmost }
}

// MARK: - AppleScript

/// Handler names in the bridge's one compiled script. The source is `IMSend.SendScripts.source`.
/// Arguments are passed as Apple Event descriptors, never interpolated into source (S2).
public enum ScriptHandler: String, Sendable, CaseIterable {
    /// `send_text(handle, text, service)`.
    case sendText = "send_text"
    /// `send_file(handle, posixPath, service)`.
    case sendFile = "send_file"
    /// `send_chat_text(chatGUID, text)`: a group chat, addressed by its chat.db guid.
    case sendChatText = "send_chat_text"
    /// `send_chat_file(chatGUID, posixPath)`: a group chat, addressed by its chat.db guid.
    case sendChatFile = "send_chat_file"
    /// `quit_messages()`.
    case quitMessages = "quit_messages"
    /// `account_ready(service)`: returns "1" once the account can send (section 3 item 4).
    case accountReady = "account_ready"
}

public struct AppleScriptOutcome: Hashable, Sendable {
    public var ok: Bool
    public var value: String?
    public var errorNumber: Int?
    public var errorMessage: String?
    public var elapsedMs: Int

    public init(ok: Bool, value: String? = nil, errorNumber: Int? = nil, errorMessage: String? = nil, elapsedMs: Int = 0) {
        self.ok = ok
        self.value = value
        self.errorNumber = errorNumber
        self.errorMessage = errorMessage
        self.elapsedMs = elapsedMs
    }
}

/// Calls a handler of the compiled script. Live implementation: `IMSend.NSAppleScriptRunner`.
/// The AppleScript result is never trusted as a send result (section 3 item 5).
public protocol AppleScriptRunning: AnyObject {
    func call(_ handler: ScriptHandler, arguments: [String]) -> AppleScriptOutcome
}

// MARK: - Journal hooks

/// Facts the journal stores when a request reaches `invoking` (section 3 item 2). Never message text.
/// Crash reconciliation reads these together with the entry's `ApprovalBinding` (IMPolicy `JournalEntry.binding`).
public struct InvocationFacts: Hashable, Codable, Sendable {
    /// Highest message ROWID before the action (section 3 item 5).
    public var snapshotRowID: Int64?
    public var targetGUID: String?
    public var targetPart: Int?
    /// chat.db ROWID of the target message for tapbacks, unsend and edit. Unsend and edit reconcile by it.
    public var targetRowID: Int64?
    /// Unique staged transfer names (section 3 item 7).
    public var transferNames: [String]
    /// `date_edited` before an edit (section 4 step 7).
    public var dateEditedBeforeNs: AppleNanos?

    public init(snapshotRowID: Int64? = nil, targetGUID: String? = nil, targetPart: Int? = nil,
                targetRowID: Int64? = nil, transferNames: [String] = [], dateEditedBeforeNs: AppleNanos? = nil) {
        self.snapshotRowID = snapshotRowID
        self.targetGUID = targetGUID
        self.targetPart = targetPart
        self.targetRowID = targetRowID
        self.transferNames = transferNames
        self.dateEditedBeforeNs = dateEditedBeforeNs
    }
}

/// Bound to one journal entry. Live implementation: `IMPolicy.Journal.recorder(for:)`.
/// IMSend calls it around the Apple Event, IMUI around the press, IMForeground before its first press after `t_front`.
public protocol InvocationRecorder: AnyObject {
    /// Writes `invoking` and flushes it to disk. If it throws, the caller performs nothing.
    func willInvoke(_ facts: InvocationFacts) throws
    /// Writes `invoked` once the call returns.
    func didInvoke() throws
}

/// The no-window relaunch waits until no staged file is waiting for transfer_state 5 (section 3 item 3).
/// Live implementation: `IMSend.StagingArea`.
public protocol PendingTransferChecking: AnyObject {
    func hasPendingTransfers() -> Bool
}
