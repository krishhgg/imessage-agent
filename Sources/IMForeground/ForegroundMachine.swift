import Foundation
import IMCore
import IMPolicy
import IMSend
import IMStore
import IMUI

/// The two foreground actions (DESIGN.md section 4, Foreground mode).
public enum ForegroundAction: Hashable, Sendable {
    /// Bubble's Edit action on the target, then the new text. Approval binds target GUID and text.
    case edit(target: MessageTargetInfo, newText: String)
    /// Menu item "Reply to Last Message…", which targets the chat's newest incoming message.
    /// `parent` is `UITargetSource.newestIncoming(for:)` as IMBridge read it for the approval, which binds
    /// `parent.guid` and the text and shows `parent.body`. Steps 1 and 4 compare the chat's newest incoming GUID with
    /// `parent.guid`, and step 4 compares the thread view's parent bubble with `parent.fromMe`, `parent.body` (as
    /// `TextNorm.matchKey`) and the minute of `parent.dateNs`.
    case threadedReply(parent: MessageTargetInfo, text: String)
}

/// Where the machine is. Logged, and used by the crash note in `doctor`.
public enum ForegroundPhase: String, Hashable, Codable, Sendable {
    case idleGate
    case preconditions
    case activationCheck
    case activating
    case lateActivationWatch
    /// `t_front` recorded; the ownership check runs before every step from here.
    case front
    case beforeReturn
    case takeover
    case bridgeOwnedCleanup
    case finishing
    case verifying
    case done
}

/// Step 1's "Messages is hidden": the window rules on the hidden window (section 4, Window rules). Live: IMUI's
/// `HiddenWindowManager`, which may cold launch or relaunch Messages hidden while the machine holds the queue.
public protocol HiddenWindowPreparing: AnyObject {
    /// `early` is nil when Messages is hidden with one window, and otherwise the result to return. `notes` are what
    /// the action adds to its own result when it goes ahead, such as `error: Messages became visible` after a cold
    /// launch or relaunch that showed a window (section 4, Window rules).
    func prepare(queueDeadline: TimeInterval) -> WindowPreparation
    /// The window rules again, launching and quitting nothing (`HiddenWindowManager.recheck`): nil while Messages is
    /// still hidden with one window, otherwise the result to return, such as `busy: screen locked` or
    /// `busy: Messages is open`. Step 1 calls it after the chat check, which can wait seconds for the list to load,
    /// and after a `not_loaded` refusal from that check, since a lock or a second window during the wait ends there.
    func recheck() -> ActionResult?
}

extension HiddenWindowManager: HiddenWindowPreparing {}

/// Everything the machine touches, injected so tests drive it with fakes and a fake clock.
public struct ForegroundEnvironment {
    public var clock: Clock
    public var input: InputMonitoring
    public var app: MessagesAppControl
    public var ax: MessagesAXDriving
    public var keys: KeyPosting
    public var verifier: ForegroundVerifying
    public var queue: ActionQueueing
    public var targeting: ChatTargeting
    public var windows: HiddenWindowManager
    public var source: UITargetSource
    public var rows: SendRowSource
    public var mode: ForegroundModeSwitching
    /// Called with `BridgeEvent.waitingForIdle` while the idle gate waits, and with `BridgeEvent.queued` when the
    /// queue is held by another request as the machine asks for it.
    public var progress: (BridgeEvent) -> Void
    /// What step 1 calls for the window rules. `init` sets it to `windows`; tests replace it.
    public var windowRules: HiddenWindowPreparing
    /// The 15-minute edit window from the row's date (section 2). `init` sets it to IMUI's `ActionWindows.editOpen`;
    /// tests replace it.
    public var editWindowOpen: (_ rowDateNs: AppleNanos, _ now: Date) -> Bool
    /// The release-test build's bridge markers for tests 4, 5 and 6b (scripts/release-tests/README.md, Bridge
    /// markers; docs/BUILD-PLAN.md item 10). The machine calls it with an event such as `phase front` or
    /// `key return` right before that step, after the step's ownership check passed. `init` sets it to a writer of
    /// `release-test <unix ms> <event>` lines on standard error, which the LaunchAgent sends to bridge.log, in a build
    /// compiled with `-DIMESSAGE_RELEASE_TESTS`, and to nil otherwise, so a normal build writes none. Tests replace it.
    public var marker: ((String) -> Void)?

    public init(clock: Clock, input: InputMonitoring, app: MessagesAppControl, ax: MessagesAXDriving,
                keys: KeyPosting, verifier: ForegroundVerifying, queue: ActionQueueing, targeting: ChatTargeting,
                windows: HiddenWindowManager, source: UITargetSource, rows: SendRowSource,
                mode: ForegroundModeSwitching, progress: @escaping (BridgeEvent) -> Void) {
        self.clock = clock
        self.input = input
        self.app = app
        self.ax = ax
        self.keys = keys
        self.verifier = verifier
        self.queue = queue
        self.targeting = targeting
        self.windows = windows
        self.source = source
        self.rows = rows
        self.mode = mode
        self.progress = progress
        self.windowRules = windows
        self.editWindowOpen = { ActionWindows.editOpen(rowDateNs: $0, now: $1) }
        #if IMESSAGE_RELEASE_TESTS
        self.marker = ReleaseTestMarkers.writer(clock: clock)
        #else
        self.marker = nil
        #endif
    }
}

/// The marker lines release tests 4, 5 and 6b read from bridge.log (`markers_since` in
/// scripts/release-tests/lib.sh).
enum ReleaseTestMarkers {
    /// `release-test <unix ms> <event>` and a newline, with the wall-clock time in whole milliseconds.
    static func line(_ event: String, at date: Date) -> String {
        let ms = Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
        return "release-test \(ms) \(event)\n"
    }

    #if IMESSAGE_RELEASE_TESTS
    /// Writes each marker to standard error in one write.
    static func writer(clock: Clock) -> (String) -> Void {
        { event in try? FileHandle.standardError.write(contentsOf: Data(line(event, at: clock.now).utf8)) }
    }
    #endif
}

public struct ForegroundRun: Hashable, Sendable {
    public var chat: ResolvedChat
    public var action: ForegroundAction
    /// Monotonic deadline for the queue wait (section 3 item 3), as of the call to `run`. Time at the idle gate
    /// doesn't count: the machine moves the deadline later by the time it waited there, so the whole budget starts
    /// when it first asks for the queue.
    public var queueDeadline: TimeInterval

    public init(chat: ResolvedChat, action: ForegroundAction, queueDeadline: TimeInterval) {
        self.chat = chat
        self.action = action
        self.queueDeadline = queueDeadline
    }
}

public struct ForegroundOutcome: Hashable, Sendable {
    public var result: ActionResult
    public var lastPhase: ForegroundPhase
    /// True if the machine turned foreground mode off (left in edit mode, transcript not back, wrong parent).
    public var turnedModeOff: Bool
    /// GUID of the reply row, for `ChatDatabase.agentSentGUIDs`.
    public var sentGUID: String?
    /// The queue ticket the machine still holds. IMBridge releases it after the journal records `final`.
    /// Nil when the machine never got the queue or gave it back (`busy: user active`, `busy: queue`,
    /// `error: foreground mode is off` before the queue).
    public var ticket: QueueTicket?

    public init(result: ActionResult, lastPhase: ForegroundPhase, turnedModeOff: Bool, sentGUID: String?,
                ticket: QueueTicket?) {
        self.result = result
        self.lastPhase = lastPhase
        self.turnedModeOff = turnedModeOff
        self.sentGUID = sentGUID
        self.ticket = ticket
    }
}

/// Ownership from `t_front` until the hide: Messages frontmost and no input since the step 3 activation check.
/// After the hide: no input. Checked before every AX action, attribute write, key event, the hide and the focus
/// restore (section 4, Ownership check). Owner: IMForeground.
///
/// Input counts when the HID state's last input is later than the activation check. The first failure sticks:
/// `owns()` stays false for the rest of the run, even if Messages comes back to the front. Before `markFront`
/// (the late-activation watch) only input counts. Thread-safe.
public final class OwnershipGuard {
    public let input: InputMonitoring
    public let app: MessagesAppControl
    public let clock: Clock

    private let lock = NSLock()
    private var checkAt: TimeInterval?
    private var frontAt: TimeInterval?
    private var hidden = false
    private var failed = false

    public init(input: InputMonitoring, app: MessagesAppControl, clock: Clock) {
        self.input = input
        self.app = app
        self.clock = clock
    }

    /// Records the activation check time. Input before it doesn't count. The machine calls this before it reads
    /// the input for the check, so input landing between the read and the mark can't slip through.
    public func markActivationCheck() {
        lock.lock()
        defer { lock.unlock() }
        checkAt = clock.uptime
    }

    /// Records `t_front`. From here until `markHidden`, Messages must also be frontmost.
    public func markFront() {
        lock.lock()
        defer { lock.unlock() }
        frontAt = clock.uptime
    }

    public func markHidden() {
        lock.lock()
        defer { lock.unlock() }
        hidden = true
    }

    /// `t_front`, once recorded.
    public var tFront: TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        return frontAt
    }

    /// True once a check has failed.
    public var hasFailed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return failed
    }

    /// False on the first failure; the machine then takes the takeover path. False with no activation check.
    ///
    /// The frontmost read comes first and the input sample last, so input that lands while the read runs is still
    /// seen, and nothing read after the sample can hide input before a key post. The frontmost read is
    /// `MessagesAppControl.isFrontmost()`, which reads no AX window count and no window list.
    public func owns() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if failed { return false }
        guard let checkAt else {
            failed = true
            return false
        }
        if frontAt != nil, !hidden, !app.isFrontmost() {
            failed = true
            return false
        }
        let elapsed = clock.uptime - checkAt
        let since = input.secondsSinceLastInput()
        if since.isNaN || since <= elapsed {
            failed = true
            return false
        }
        return true
    }
}

/// Foreground mode steps 1 to 7 as a state machine (section 4). Owner: IMForeground.
///
/// The machine takes the queue itself, after the idle gate, because a foreground action waiting at its idle gate must
/// not hold it (section 3 item 3). IMBridge must not acquire the queue before calling `run`.
///
/// Rule checklist:
/// - Idle gate first (2 s of no input, 30 s budget, `busy: user active`), then the queue, then step 1 checks.
/// - Step 1: Messages hidden, the chat already the one selected chat and checked, with no row press
///   (`busy: chat not open in Messages` otherwise), after that check the same Messages pid and the window rules
///   again (`HiddenWindowPreparing.recheck`, so a locked screen is `busy: screen locked`, also in place of a
///   `not_loaded` refusal from that check), empty composer
///   (`busy: draft in Messages`), no edit field and no thread view (`busy: edit in progress`), parent unchanged
///   (`newestIncoming(for:)?.guid == parent.guid`, else `aborted: parent changed`), bubble and action or menu item
///   present (`unsupported`).
/// - Step 3: input in the last 2 s releases the queue and returns to the idle gate. `open -b`. `t_front` within 1 s,
///   else watch 5 s more (`aborted: late activation`, takeover, or `aborted: activation`).
/// - `recorder.willInvoke` before the first press after `t_front`, with the snapshot ROWID, and for an edit the target
///   GUID, part, ROWID and date_edited before. Return within 3 s of `t_front` (`aborted: deadline`).
/// - Step 4 re-reads before Return. For a reply, `ax.threadView()?.parent` must match the bound parent's direction,
///   NFC body and minute, and the newest incoming GUID must still be `parent.guid`. Both are read again after the
///   focused-field read right before Return, the thread view first and the GUID last. A change at either read is
///   `aborted: parent changed`, and a failed read or no parent bubble is `aborted: view`. Step 5 takeover makes
///   at most one AX write; bridge-owned cleanup presses Escape at most 3 times. Step 6 finish and focus restore.
///   Step 7 verify with `TextNorm.textDigest` of the text.
/// - Every AX press and write passes a final check (`AXFinalCheck`), which the driver runs after its own reads: the
///   ownership check, after the edit window for the Edit press. The takeover's one reset write passes `{}`.
/// - The machine never writes the journal's `foreground` flag. IMBridge sets it before `run`.
/// - Edit window: checked after approval (IMBridge), on leaving the queue, right before `open -b`, right before the
///   Edit press and again as its final check, and right before Return, before the last ownership check.
/// - Foreground mode is checked at the start and each time the machine gets the queue. The machine only ever turns it
///   off; only the native dialog turns it back on.
///
/// Check names in `aborted: <check>`: `press` (the item to press was missing or the press failed), `view`, `field`,
/// and before activation `AX read` and `chat.db read` when a check couldn't be read.
///
/// Several connections may call `run` at once. Each run keeps its own state; they meet only at the queue.
public final class ForegroundMachine {
    public let env: ForegroundEnvironment

    public init(env: ForegroundEnvironment) { self.env = env }

    private let phaseLock = NSLock()
    private var currentPhase: ForegroundPhase = .idleGate

    /// The phase most recently entered by any run.
    public private(set) var phase: ForegroundPhase {
        get {
            phaseLock.lock()
            defer { phaseLock.unlock() }
            return currentPhase
        }
        set {
            phaseLock.lock()
            currentPhase = newValue
            phaseLock.unlock()
        }
    }

    public func run(_ run: ForegroundRun, recorder: InvocationRecorder) -> ForegroundOutcome {
        let runner = ForegroundRunner(env: env, run: run, recorder: recorder) { [weak self] next in
            self?.phase = next
        }
        return runner.execute()
    }
}
