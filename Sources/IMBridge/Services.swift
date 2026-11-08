import AppKit
import CoreServices
import Foundation
import IMCore
import IMPolicy
import IMStore
import IMUI

/// Every TCC check and the Full Disk Access pane, behind one protocol so tests never raise an Automation or
/// Accessibility prompt, never open System Settings and never touch the real chat.db (DESIGN.md section 1, TCC
/// contract; install flow steps 4 and 5). `BridgeContainer.permissions` holds it. Tests use a fake that records calls.
public protocol PermissionProbing: AnyObject {
    /// Tries chat.db once (`ChatDatabase.probe`), so macOS lists the bridge in the Full Disk Access pane.
    func fullDiskAccess() -> PermissionState
    /// `AEDeterminePermissionToAutomateTarget` for Messages. `ask` true raises the Automation prompt and returns
    /// without waiting for the user: `notDetermined` while the prompt is up.
    func automation(ask: Bool) -> PermissionState
    /// The same check without the prompt, for `doctor`. Says when Messages is closed instead of folding that into
    /// `unknown`.
    func silentAutomation() -> SilentAutomation
    /// `AXIsProcessTrustedWithOptions`. `prompt` true raises the Accessibility prompt.
    func accessibility(prompt: Bool) -> PermissionState
    /// Opens Privacy & Security > Full Disk Access and returns at once. Returns the pane URL it opened, or nil.
    func openFullDiskAccessPane() -> String?
}

/// The silent Automation check's answer. macOS answers only for a running target.
public enum SilentAutomation: Hashable, Sendable {
    case answered(PermissionState)
    /// `procNotFound`: Messages isn't running, so macOS can't say.
    case messagesClosed
}

/// Live `PermissionProbing`: `ChatDatabase.probe(path: paths.chatDB.path)`, `AEDeterminePermissionToAutomateTarget`,
/// `AXTrust`, and `NSWorkspace.open` on the Full Disk Access pane URL. Never run in tests. Owner: IMBridge.
public final class LivePermissionProbe: PermissionProbing {
    public let paths: Paths

    /// Privacy & Security > Full Disk Access.
    static let fullDiskAccessPane = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    /// How long `automation(ask: true)` waits for the user's answer before it returns `notDetermined`.
    static let askWait: TimeInterval = 1
    /// How long an ask keeps retrying while Messages is still starting (`procNotFound`).
    static let launchWait: TimeInterval = 10

    private let asks = BoundedAsk(wait: LivePermissionProbe.askWait)

    public init(paths: Paths) { self.paths = paths }

    public func fullDiskAccess() -> PermissionState {
        LivePermissionProbe.state(ChatDatabase.probe(path: paths.chatDB.path))
    }

    /// With `ask` true, `AEDeterminePermissionToAutomateTarget` blocks until the user answers the prompt, so it runs
    /// on its own thread and this returns `notDetermined` after `askWait`.
    public func automation(ask: Bool) -> PermissionState {
        guard ask else { return LivePermissionProbe.automationState(LivePermissionProbe.determine(ask: false)) }
        return asks.run {
            let deadline = ProcessInfo.processInfo.systemUptime + LivePermissionProbe.launchWait
            var status = LivePermissionProbe.determine(ask: true)
            while status == OSStatus(procNotFound), ProcessInfo.processInfo.systemUptime < deadline {
                Thread.sleep(forTimeInterval: 0.25)
                status = LivePermissionProbe.determine(ask: true)
            }
            return LivePermissionProbe.automationState(status)
        }
    }

    public func silentAutomation() -> SilentAutomation {
        LivePermissionProbe.silentAutomation(LivePermissionProbe.determine(ask: false))
    }

    private static func determine(ask: Bool) -> OSStatus {
        var target = AEAddressDesc()
        let created: OSErr = AppIdentity.messagesBundleID.withCString { bytes in
            AECreateDesc(typeApplicationBundleID, bytes, strlen(bytes), &target)
        }
        guard created == noErr else { return OSStatus(created) }
        defer { AEDisposeDesc(&target) }
        return AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, ask)
    }

    public func accessibility(prompt: Bool) -> PermissionState {
        // Accessibility trust has no "not asked yet" state that a process can read.
        (prompt ? AXTrust.prompt() : AXTrust.isTrusted()) ? .granted : .denied
    }

    public func openFullDiskAccessPane() -> String? {
        guard let url = URL(string: LivePermissionProbe.fullDiskAccessPane), NSWorkspace.shared.open(url) else {
            return nil
        }
        return LivePermissionProbe.fullDiskAccessPane
    }

    /// A chat.db probe as a Full Disk Access state. A missing or broken chat.db says nothing about the grant.
    static func state(_ probe: DatabaseProbe) -> PermissionState {
        switch probe {
        case .ok: return .granted
        case .notPermitted: return .denied
        case .missing, .failed: return .unknown
        }
    }

    /// A silent check's result. `procNotFound` is Messages closed, and the rest map as in `automationState`.
    static func silentAutomation(_ status: OSStatus) -> SilentAutomation {
        status == OSStatus(procNotFound) ? .messagesClosed : .answered(automationState(status))
    }

    /// `AEDeterminePermissionToAutomateTarget` results. Messages not running (`procNotFound`) is `unknown`.
    static func automationState(_ status: OSStatus) -> PermissionState {
        switch status {
        case OSStatus(noErr): return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .notDetermined
        default: return .unknown
        }
    }
}

/// Runs a blocking permission ask on its own thread and waits at most `wait` seconds for the answer. A call that runs
/// out of time returns `notDetermined`, which the CLI shows as "answer the prompt on the Mac". Only one ask is open at
/// a time, and a call made while one is open waits on that one.
final class BoundedAsk {
    private final class Ask {
        let done = DispatchGroup()
        var state: PermissionState = .notDetermined
    }

    let wait: TimeInterval
    private let lock = NSLock()
    private var open: Ask?

    init(wait: TimeInterval) { self.wait = wait }

    func run(_ body: @escaping () -> PermissionState) -> PermissionState {
        lock.lock()
        let ask: Ask
        if let open {
            ask = open
        } else {
            ask = Ask()
            ask.done.enter()
            open = ask
            Thread { [self] in
                let state = body()
                lock.lock()
                ask.state = state
                open = nil
                lock.unlock()
                ask.done.leave()
            }.start()
        }
        lock.unlock()
        guard ask.done.wait(timeout: .now() + wait) == .success else { return .notDetermined }
        lock.lock()
        defer { lock.unlock() }
        return ask.state
    }
}

/// Silent permission checks (DESIGN.md section 1, `status`). Never raises a prompt. Owner: IMBridge.
/// - Full Disk Access: `container.permissions.fullDiskAccess()`.
/// - Automation: `container.permissions.automation(ask: false)`.
/// - Accessibility: `container.permissions.accessibility(prompt: false)`.
public final class StatusService {
    public let container: BridgeContainer

    public init(container: BridgeContainer) { self.container = container }

    public func status() -> StatusReport {
        let c = container
        let policy = c.policy.effective
        let trusted: Bool
        if case .trusted = c.policy.load() { trusted = true } else { trusted = false }
        return StatusReport(bridgeVersion: AppIdentity.version, pid: getpid(), fullDiskAccess: fullDiskAccess(),
                            automation: automation(), accessibility: accessibility(),
                            messagesRunning: c.app.state().isRunning, foregroundMode: policy.foregroundMode,
                            foregroundOffReason: policy.foregroundOffReason, allowlistTrusted: trusted,
                            allowedChats: policy.entries.count, openApprovals: c.approvals.pendingItems().count,
                            crashNote: c.crashNote)
    }

    public func fullDiskAccess() -> PermissionState { container.permissions.fullDiskAccess() }
    public func automation() -> PermissionState { container.permissions.automation(ask: false) }
    public func accessibility() -> PermissionState { container.permissions.accessibility(prompt: false) }
}

/// `setup` (install flow step 4). Owner: IMBridge. Every TCC call goes through `container.permissions`.
/// - `fullDiskAccess`: `fullDiskAccess()` once so macOS lists the bridge, then `openFullDiskAccessPane()`, return at
///   once. When access is already granted it opens chat.db instead of the pane.
/// - `automation`: `automation(ask: true)`, after starting Messages hidden if it isn't running, because macOS shows
///   the Automation prompt only for a running target. Raises the prompt only.
/// - `accessibility`: `accessibility(prompt: true)`.
public final class SetupService {
    public let container: BridgeContainer

    public init(container: BridgeContainer) { self.container = container }

    public func run(_ args: SetupArgs) -> SetupReport {
        let permissions = container.permissions
        switch args.stage {
        case .fullDiskAccess:
            let state = permissions.fullDiskAccess()
            if state == .granted {
                _ = container.openStoreIfNeeded()
                return SetupReport(stage: .fullDiskAccess, state: state, openedPane: nil)
            }
            return SetupReport(stage: .fullDiskAccess, state: state, openedPane: permissions.openFullDiskAccessPane())
        case .automation:
            return SetupReport(stage: .automation, state: SetupService.askAutomation(container), openedPane: nil)
        case .accessibility:
            return SetupReport(stage: .accessibility, state: permissions.accessibility(prompt: true), openedPane: nil)
        }
    }

    /// Raises the Automation prompt. Starts Messages hidden first (`/usr/bin/open -g -j`, as before a send) when it
    /// isn't running, since `AEDeterminePermissionToAutomateTarget` can't ask about an app that isn't running.
    static func askAutomation(_ c: BridgeContainer) -> PermissionState {
        if !c.app.state().isRunning { _ = c.app.launchHidden() }
        return c.permissions.automation(ask: true)
    }
}

/// `doctor` (install flow step 5; sections 3 item 2 and 4). Owner: IMBridge. Every TCC call goes through
/// `container.permissions`.
/// - chat.db opens; if not and `afterKickstart` is false, `needsKickstart` is true and the CLI restarts the job once.
/// - Automation (`silentAutomation`) and, if `wantUIActions` (`doctor --ui`), Accessibility, checked silently. The
///   CLI raises those prompts afterwards with `setup(automation)` and `setup(accessibility)`, after any kickstart, so
///   each prompt comes up once and from the bridge that keeps running.
/// - Allowlist tamper state, foreground mode and why it turned off, the crash note.
/// - Re-checks the action names it can see on a loaded bubble (Undo Send and Edit are checked when they run).
/// - `releaseTestBuild` is `CapabilityRegistry.isReleaseTestBuild`, so a release-test build says so in the header.
public final class DoctorService {
    public let container: BridgeContainer

    public init(container: BridgeContainer) { self.container = container }

    public func run(_ args: DoctorArgs) -> DoctorReport {
        let c = container
        var checks: [DoctorCheck] = []

        let probe = c.openStoreIfNeeded()
        checks.append(DoctorService.chatDBCheck(probe))
        let opened: Bool
        if case .ok = probe { opened = true } else { opened = false }
        let needsKickstart = !opened && !args.afterKickstart

        checks.append(DoctorService.automationCheck(c.permissions.silentAutomation()))

        let accessibility = c.permissions.accessibility(prompt: false)
        let axTrusted = accessibility == .granted
        if args.wantUIActions {
            checks.append(DoctorCheck(name: "Accessibility", ok: axTrusted, detail: accessibility.rawValue,
                                      fix: axTrusted ? nil : "turn on iMessage Agent in Privacy & Security > Accessibility"))
        }

        switch c.policy.load() {
        case .trusted:
            checks.append(DoctorCheck(name: "allowlist", ok: true, detail: "\(c.policy.effective.entries.count) chats"))
        case .untrusted(let reason):
            checks.append(DoctorCheck(name: "allowlist", ok: false, detail: DoctorService.describe(reason),
                                      fix: "approve each chat again with imessage allow <who>"))
        }

        let policy = c.policy.effective
        if policy.foregroundMode {
            checks.append(DoctorCheck(name: "foreground mode", ok: true, detail: "on"))
        } else if let reason = policy.foregroundOffReason {
            checks.append(DoctorCheck(name: "foreground mode", ok: true, detail: "off: \(reason)",
                                      fix: "imessage allow --foreground"))
        } else {
            checks.append(DoctorCheck(name: "foreground mode", ok: true, detail: "off"))
        }

        if let note = c.crashNote {
            checks.append(DoctorCheck(name: "last run", ok: false, detail: note,
                                      fix: "check Messages for the agent's text and close any open edit"))
        }

        if axTrusted, c.app.state().isRunning, let names = DoctorService.actionNamesCheck(c.ax) {
            checks.append(names)
        }

        return DoctorReport(checks: checks, needsKickstart: needsKickstart,
                            releaseTestBuild: CapabilityRegistry.isReleaseTestBuild)
    }

    /// The silent Automation state as a check. macOS can't say anything about a target that isn't running
    /// (`procNotFound`), and doctor doesn't start Messages, so that case is a note and not a failure. The CLI's
    /// prompt step that follows gives the answer. The probe's own status decides it, not a separate look at whether
    /// Messages runs. Only `denied` points at System Settings.
    static func automationCheck(_ answer: SilentAutomation) -> DoctorCheck {
        let name = "Automation"
        guard case .answered(let state) = answer else {
            return DoctorCheck(name: name, ok: true, detail: "can't check while Messages is closed")
        }
        switch state {
        case .granted:
            return DoctorCheck(name: name, ok: true, detail: state.rawValue)
        case .denied:
            return DoctorCheck(name: name, ok: false, detail: state.rawValue,
                               fix: "allow Messages for iMessage Agent in Privacy & Security > Automation")
        case .notDetermined:
            return DoctorCheck(name: name, ok: false, detail: state.rawValue,
                               fix: "answer the Automation prompt on the Mac")
        case .unknown:
            return DoctorCheck(name: name, ok: false, detail: state.rawValue, fix: "run imessage doctor again")
        }
    }

    static func chatDBCheck(_ probe: DatabaseProbe) -> DoctorCheck {
        switch probe {
        case .ok(let rows):
            return DoctorCheck(name: "chat.db", ok: true, detail: "\(rows) messages")
        case .notPermitted:
            return DoctorCheck(name: "chat.db", ok: false, detail: "no Full Disk Access", fix: "imessage setup")
        case .missing:
            return DoctorCheck(name: "chat.db", ok: false, detail: "not found",
                               fix: "sign in to iMessage in Messages, then run imessage doctor")
        case .failed(let why):
            return DoctorCheck(name: "chat.db", ok: false, detail: TextNorm.oneLine(why), fix: "run imessage doctor")
        }
    }

    static func describe(_ reason: TamperReason) -> String {
        switch reason {
        case .fileChangedOutsideBridge: return "the policy file changed outside the bridge"
        case .fileMissing: return "the policy file is missing"
        case .fileUnreadable: return "the policy file can't be read"
        case .hashMissing: return "the Keychain hash is missing"
        case .hashUnreadable: return "the Keychain hash can't be read"
        }
    }

    /// The classic tapback names on the newest loaded bubble that has named actions. Nil when no loaded bubble has
    /// any, because then there is nothing to compare. Reads the AX tree only; presses nothing.
    static func actionNamesCheck(_ ax: MessagesAXDriving) -> DoctorCheck? {
        guard let bubbles = try? ax.loadedBubbles(),
              let newest = bubbles.last(where: { !$0.actionNames.isEmpty }) else { return nil }
        let missing = UINames.classicTapbacks.filter { !newest.actionNames.contains($0) }
        if missing.isEmpty { return DoctorCheck(name: "action names", ok: true, detail: "tapbacks found") }
        return DoctorCheck(name: "action names", ok: false, detail: "missing: " + missing.joined(separator: ", "),
                           fix: "set the macOS language to English, or update iMessage Agent")
    }
}
