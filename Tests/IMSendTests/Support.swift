import Foundation
import XCTest
import IMCore
import IMStore
@testable import IMSend
import IMTestSupport

// Fakes for IMSend's tests. None of them sends an Apple Event, launches Messages or opens a real chat.db.

/// Thread-safe ordered log shared by the fakes, so a test can check the order of work across them.
final class EventLog {
    private let lock = NSLock()
    private var items: [String] = []

    func add(_ item: String) {
        lock.lock()
        items.append(item)
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

/// `SendRowSource` whose rows appear and change as a `FakeClock` advances. Times are seconds after the source was
/// made. Thread-safe, so concurrency tests can share it.
final class ScriptedRowSource: SendRowSource {
    private let lock = NSLock()
    private let clock: Clock
    private let origin: TimeInterval
    private var pending: [(at: TimeInterval, apply: (inout [Int64: SentRowProbe]) -> Void)] = []
    private var rows: [Int64: SentRowProbe] = [:]
    private var baseMaxRowID: Int64
    private var extraStates: [String: Int] = [:]
    private var identities: [Int64: CanonicalChatID] = [:]
    private var calls: [String] = []

    var log: EventLog?
    /// Reads throw while the clock is before this time (seconds after origin). `.infinity` makes them always throw.
    var failReadsUntil: TimeInterval = 0
    var failMaxRowID = false
    var failTransferStates = false
    /// Returns every row from `fromMeRows`, ignoring `aboveRowID`, to check that the correlator applies the snapshot
    /// itself.
    var ignoresAboveRowID = false

    struct ReadFailure: Error {}

    init(clock: Clock, maxRowID: Int64 = 1000) {
        self.clock = clock
        self.origin = clock.uptime
        self.baseMaxRowID = maxRowID
    }

    var elapsed: TimeInterval { clock.uptime - origin }

    func add(at t: TimeInterval, _ row: SentRowProbe) {
        locked { pending.append((t, { $0[row.rowid] = row })) }
    }

    /// Adds `row` `delay` seconds from now.
    func addAfter(_ delay: TimeInterval, _ row: SentRowProbe) {
        add(at: elapsed + delay, row)
    }

    func update(at t: TimeInterval, rowid: Int64, _ change: @escaping (inout SentRowProbe) -> Void) {
        locked {
            pending.append((t, { rows in
                if var row = rows[rowid] {
                    change(&row)
                    rows[rowid] = row
                }
            }))
        }
    }

    func updateAfter(_ delay: TimeInterval, rowid: Int64, _ change: @escaping (inout SentRowProbe) -> Void) {
        update(at: elapsed + delay, rowid: rowid, change)
    }

    func setTransferState(_ name: String, _ state: Int?) {
        locked { extraStates[name] = state }
    }

    /// The identity `canonicalChatID(chatRowID:)` gives for a chat. Chats with none set read as missing.
    func setIdentity(_ chatRowID: Int64, _ canonical: CanonicalChatID) {
        locked { identities[chatRowID] = canonical }
    }

    var callLog: [String] { locked { calls } }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// Applies every change due by now. Caller holds the lock.
    private func catchUp() {
        let now = clock.uptime - origin + 1e-9
        var due: [(at: TimeInterval, apply: (inout [Int64: SentRowProbe]) -> Void)] = []
        pending.removeAll { item in
            if item.at <= now { due.append(item); return true }
            return false
        }
        for item in due.sorted(by: { $0.at < $1.at }) { item.apply(&rows) }
    }

    func maxMessageRowID() throws -> Int64 {
        log?.add("maxMessageRowID")
        return try locked {
            calls.append("maxMessageRowID")
            if failMaxRowID { throw ReadFailure() }
            catchUp()
            return max(baseMaxRowID, rows.keys.max() ?? 0)
        }
    }

    func fromMeRows(aboveRowID rowid: Int64, limit: Int) throws -> [SentRowProbe] {
        try locked {
            calls.append("fromMeRows")
            if elapsed < failReadsUntil { throw ReadFailure() }
            catchUp()
            let floor = ignoresAboveRowID ? Int64.min : rowid
            return Array(rows.values.filter { $0.rowid > floor }.sorted { $0.rowid < $1.rowid }.prefix(limit))
        }
    }

    func sentRow(rowid: Int64) throws -> SentRowProbe? {
        locked {
            catchUp()
            return rows[rowid]
        }
    }

    func transferStates(transferNames: [String]) throws -> [String: Int] {
        try locked {
            calls.append("transferStates")
            if failTransferStates { throw ReadFailure() }
            catchUp()
            var out: [String: Int] = [:]
            for row in rows.values {
                for (name, state) in row.transferStates where transferNames.contains(name) { out[name] = state }
            }
            for (name, state) in extraStates where transferNames.contains(name) { out[name] = state }
            return out
        }
    }

    func canonicalChatID(chatRowID: Int64) throws -> CanonicalChatID? {
        try locked {
            calls.append("canonicalChatID")
            if elapsed < failReadsUntil { throw ReadFailure() }
            return identities[chatRowID]
        }
    }
}

/// `AppleScriptRunning` that answers from a closure and logs each call. Never runs AppleScript.
final class ScriptedRunner: AppleScriptRunning {
    private let lock = NSLock()
    private var recorded: [(ScriptHandler, [String])] = []
    var log: EventLog?
    var respond: (ScriptHandler, [String]) -> AppleScriptOutcome

    init(respond: @escaping (ScriptHandler, [String]) -> AppleScriptOutcome = { _, _ in
        AppleScriptOutcome(ok: true, value: "sent")
    }) {
        self.respond = respond
    }

    var calls: [(ScriptHandler, [String])] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func handlers() -> [ScriptHandler] { calls.map(\.0) }

    func call(_ handler: ScriptHandler, arguments: [String]) -> AppleScriptOutcome {
        lock.lock()
        recorded.append((handler, arguments))
        lock.unlock()
        log?.add("call \(handler.rawValue)")
        return respond(handler, arguments)
    }
}

/// `InvocationRecorder` that logs into an `EventLog`.
final class LoggingRecorder: InvocationRecorder {
    struct Failure: Error {}

    var log: EventLog?
    var failWillInvoke = false
    var failDidInvoke = false
    private(set) var facts: [InvocationFacts] = []
    private(set) var didInvokeCount = 0

    func willInvoke(_ facts: InvocationFacts) throws {
        log?.add("willInvoke")
        if failWillInvoke { throw Failure() }
        self.facts.append(facts)
    }

    func didInvoke() throws {
        log?.add("didInvoke")
        didInvokeCount += 1
        if failDidInvoke { throw Failure() }
    }
}

/// A Messages that `open` can't start.
final class UnlaunchableMessagesApp: MessagesAppControl {
    private(set) var launches = 0

    func state() -> MessagesAppState { .notRunning }
    func launchHidden() -> Bool { launches += 1; return false }
    func quit() -> Bool { false }
    func waitForExit(timeout: TimeInterval) -> Bool { true }
    func activateForeground() -> Bool { false }
    func hide() {}
    func frontmostApp() -> FrontApp? { nil }
    func reopen(bundleID: String) -> Bool { false }
}

/// Clock with a fixed wall time and a real monotonic time, safe to read from several threads.
final class FixedWallClock: Clock {
    let now: Date
    init(now: Date = Fixture.now) { self.now = now }
    var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }
    func sleep(_ seconds: TimeInterval) {}
}

// MARK: - Builders

enum Handles {
    static let mom = "+14155550101"
    static let dad = "+14155550102"
    static let owner = "+14155550100"
    static let jordan = "jordan.kim@example.com"
}

func momChat(service: String = "iMessage") -> ResolvedChat {
    ResolvedChat(canonical: .direct(handle: Handles.mom), chatRowIDs: [7], chatGUIDs: ["any;-;+14155550101"],
                 primaryChatRowID: 7, label: "Mom", isGroup: false, handles: [Handles.mom],
                 sendHandle: Handles.mom, service: service)
}

func selfChat() -> ResolvedChat {
    ResolvedChat(canonical: .direct(handle: Handles.owner), chatRowIDs: [2], chatGUIDs: ["any;-;+14155550100"],
                 primaryChatRowID: 2, label: "You", isGroup: false, handles: [], sendHandle: Handles.owner,
                 service: "iMessage")
}

func familyGroup() -> ResolvedChat {
    ResolvedChat(canonical: .group(identifier: "chat836828054889214904"), chatRowIDs: [12],
                 chatGUIDs: ["any;+;chat836828054889214904"], primaryChatRowID: 12, label: "Family 🏡", isGroup: true,
                 handles: [Handles.mom, Handles.dad, "+14155550103", "+14155550104"], sendHandle: nil,
                 service: "iMessage")
}

/// A from_me row. `dateNs` defaults to 1 ms after `after`.
func row(_ rowid: Int64, after date: Date, offsetNs: Int64 = 1_000_000, handle: String? = Handles.mom,
         service: String? = "iMessage", body: String = "", hasBody: Bool? = nil, transferNames: [String] = [],
         transferStates: [String: Int] = [:], error: Int = 0, deliveredNs: AppleNanos = 0, joined: Int64? = 7,
         guid: String? = nil) -> SentRowProbe {
    SentRowProbe(rowid: rowid, guid: guid ?? "GUID-\(rowid)", handle: handle, service: service,
                 dateNs: AppleTime.nanos(from: date) + offsetNs, body: TextNorm.matchKey(body),
                 hasBody: hasBody ?? !body.isEmpty, transferNames: transferNames, transferStates: transferStates,
                 error: error, isSent: true, isDelivered: deliveredNs > 0, dateDeliveredNs: deliveredNs,
                 joinedChatRowID: joined, threadOriginatorGUID: nil, itemType: 0)
}

/// A nonzero date_delivered.
func deliveredStamp(_ date: Date) -> AppleNanos { AppleTime.nanos(from: date) + 2_000_000_000 }

/// A fresh folder under the test temp folder, removed by `removeTempFolders`.
final class TempFolders {
    private(set) var made: [URL] = []

    func make(_ label: String = "imsend") -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        made.append(url)
        return url
    }

    func removeAll() {
        for url in made { try? FileManager.default.removeItem(at: url) }
        made = []
    }
}

/// Feeds `data` to `UploadFreezer.freeze` the way the bridge's socket reader would.
func freeze(_ data: Data, name: String, with freezer: UploadFreezer) throws -> FrozenFile {
    var offset = 0
    return try freezer.freeze(header: UploadHeader(byteCount: Int64(data.count), fileName: name)) { buffer in
        let n = min(buffer.count, data.count - offset)
        guard n > 0 else { return 0 }
        let start = data.startIndex + offset
        buffer.copyBytes(from: data[start..<(start + n)])
        offset += n
        return n
    }
}

func filesIn(_ folder: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
}

func posixMode(_ url: URL) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber)?.intValue ?? -1
}

enum SampleImages {
    /// 1x1 PNG.
    static let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!
}
