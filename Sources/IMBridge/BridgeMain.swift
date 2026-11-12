import AppKit
import Foundation
import IMCore

/// Bridge process entry (DESIGN.md section 1). Owner: IMBridge.
///
/// 1. `LaunchActivation.activateSocket()`. Nil: `kickstartAndExit()`.
/// 2. Build `BridgeContainer.live()`, load the policy store, then `journal.recoverAfterCrash` with `ReconcileAdapter`
///    before serving. If it returns true (a non-final entry had `foreground` set), turn foreground mode off and keep
///    the crash note for `doctor`: Messages may be in front, in edit mode or holding the agent's text. If it throws,
///    turn foreground mode off and refuse mutations with `journal write failed` until a retry succeeds.
/// 3. Sweep staging and the attachment cache, prune the journal, start the timers.
/// 4. Start `SocketServer` with `OpDispatcher`.
/// 5. `NSApplication.shared`, activation policy `.accessory`, `run()`.
public enum BridgeMain {
    static let crashReason = "the bridge stopped during a foreground action"
    static let crashNote = "the bridge stopped during a foreground action; Messages may be in front, in edit mode or "
        + "holding the agent's text"
    static let recoveryFailedReason = "the journal couldn't be checked after a restart"

    public static func run() -> Never {
        guard let fds = LaunchActivation.activateSocket(), let listenFD = fds.first else {
            LaunchActivation.kickstartAndExit()
        }
        let container: BridgeContainer
        do {
            container = try BridgeContainer.live()
        } catch {
            BridgeLog.write("can't start: \(error)")
            exit(1)
        }
        prepare(container)
        let maintenance = Maintenance(container: container)
        maintenance.start()

        let server = SocketServer(listenFD: listenFD, handler: OpDispatcher(container: container))
        server.residency = container.residency
        server.start()

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        withExtendedLifetime((server, maintenance)) { app.run() }
        exit(0)
    }

    /// Steps 2 and 3, before the socket is served. Returns true when a foreground action was open at the crash.
    ///
    /// If the journal can't be recovered, the bridge can't tell whether a foreground action was open, so it turns
    /// foreground mode off as if one had been. Mutations then wait for `recoverIfNeeded` to succeed.
    @discardableResult
    static func prepare(_ container: BridgeContainer) -> Bool {
        _ = container.policy.load()
        _ = container.openStoreIfNeeded()
        container.recoveryLock.lock()
        let foregroundCrash = recover(container)
        container.recoveryLock.unlock()
        if foregroundCrash == nil { container.policy.turnForegroundOff(reason: recoveryFailedReason) }
        Maintenance.clearUploads(container)
        Maintenance(container: container).runDue(uptime: container.clock.uptime)
        return foregroundCrash ?? true
    }

    /// True once crash recovery has written a final record for every open entry. Until then each mutation calls
    /// this before it touches the journal, which runs recovery again, and is refused if that fails too.
    static func recoverIfNeeded(_ container: BridgeContainer) -> Bool {
        container.recoveryLock.lock()
        defer { container.recoveryLock.unlock() }
        guard container.journalNeedsRecovery else { return true }
        return recover(container) != nil
    }

    /// `journal.recoverAfterCrash` with `ReconcileAdapter`. Returns whether a foreground action was open, or nil if
    /// a final record couldn't be written. The caller holds `recoveryLock`. The rows recovery matched join
    /// `agentSentGUIDs`, so `wait` skips them.
    private static func recover(_ c: BridgeContainer) -> Bool? {
        do {
            let foregroundCrash = try c.journal.recoverAfterCrash(using: ReconcileAdapter(container: c))
            c.db?.addAgentSentGUIDs(c.journal.agentSentGUIDs())
            if foregroundCrash {
                c.policy.turnForegroundOff(reason: crashReason)
                c.crashNote = crashNote
            }
            c.journalNeedsRecovery = false
            return foregroundCrash
        } catch {
            BridgeLog.write("crash recovery failed: \(error)")
            c.journalNeedsRecovery = true
            return nil
        }
    }
}

/// The bridge's timers. Every `tick`: expire approvals and drop finished in-flight answers. Every minute: sweep
/// staging. Every hour: purge the attachment cache and prune the journal. One serial queue runs them all.
final class Maintenance {
    enum Job: Hashable {
        case expireApprovals
        case sweepStaging
        case purgeCache
        case pruneJournal
    }

    static let tick: TimeInterval = 5
    static let stagingInterval: TimeInterval = 60
    static let hourlyInterval: TimeInterval = 3600

    let container: BridgeContainer
    private let queue = DispatchQueue(label: "\(AppIdentity.bundleID).maintenance")
    private let lock = NSLock()
    private var lastStaging: TimeInterval?
    private var lastHourly: TimeInterval?
    private var timer: DispatchSourceTimer?

    init(container: BridgeContainer) { self.container = container }

    func start() {
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + Maintenance.tick, repeating: Maintenance.tick, leeway: .seconds(1))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            runDue(uptime: container.clock.uptime)
        }
        lock.lock()
        timer = source
        lock.unlock()
        source.resume()
    }

    func stop() {
        lock.lock()
        let source = timer
        timer = nil
        lock.unlock()
        source?.cancel()
    }

    /// Runs the jobs that are due at `uptime` and returns them. The first call runs every job.
    @discardableResult
    func runDue(uptime: TimeInterval) -> Set<Job> {
        lock.lock()
        var due: Set<Job> = [.expireApprovals]
        if lastStaging.map({ uptime - $0 >= Maintenance.stagingInterval }) ?? true {
            due.insert(.sweepStaging)
            lastStaging = uptime
        }
        if lastHourly.map({ uptime - $0 >= Maintenance.hourlyInterval }) ?? true {
            due.formUnion([.purgeCache, .pruneJournal])
            lastHourly = uptime
        }
        lock.unlock()

        let c = container
        c.approvals.expireOld()
        c.inFlight.prune(now: c.clock.now)
        if due.contains(.sweepStaging) { c.stagingArea?.sweep() }
        if due.contains(.purgeCache) {
            do { try c.attachments?.purgeExpiredCache() } catch { BridgeLog.write("cache purge failed: \(error)") }
        }
        if due.contains(.pruneJournal) {
            do { try c.journal.prune() } catch { BridgeLog.write("journal prune failed: \(error)") }
        }
        return due
    }

    /// Removes upload copies left by a previous run. Called once at start, before any request can freeze a file.
    /// Touches only regular files directly inside the uploads folder.
    static func clearUploads(_ container: BridgeContainer) {
        let dir = container.uploads.directory
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names {
            let path = dir.appendingPathComponent(name).path
            var st = stat()
            guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { continue }
            unlink(path)
        }
    }
}
