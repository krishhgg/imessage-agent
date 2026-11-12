import Foundation
import IMCore
import IMStore

/// Idempotency key (DESIGN.md section 3 item 1). Only digests and GUIDs, never text.
public struct IdempotencyKey: Hashable, Codable, Sendable {
    /// SHA-256 hex of the canonical key fields.
    public var value: String
    /// `<target guid>/<part>` for UI actions. A later final key on the same target whose result may have taken effect
    /// supersedes this one.
    public var targetSlot: String?

    public init(value: String, targetSlot: String?) {
        self.value = value
        self.targetSlot = targetSlot
    }

    /// Send key: chat, plain or threaded, bound parent GUID, text digest (`TextNorm.textDigest`), attachment digest.
    public static func send(chat: CanonicalChatID, threaded: Bool, parentGUID: String?, textDigest: String?,
                            attachmentDigest: String?) -> IdempotencyKey {
        let fields = ["send", chat.rawValue, threaded ? "threaded" : "plain", parentGUID, textDigest, attachmentDigest]
        return IdempotencyKey(value: digest(fields), targetSlot: nil)
    }

    /// UI key: action, target GUID and part, set or remove, tapback kind or `TextNorm.textDigest` of the new text.
    public static func ui(action: UIActionKind, targetGUID: String, part: Int, remove: Bool, tapback: TapbackKind?,
                          newTextDigest: String?) -> IdempotencyKey {
        let fields = ["ui", action.rawValue, targetGUID, String(part), remove ? "remove" : "set", tapback?.wireName,
                      newTextDigest]
        return IdempotencyKey(value: digest(fields), targetSlot: "\(targetGUID)/\(part)")
    }

    /// Each field is written as `<utf8 length>:<value>;`, or `-;` when absent, so no two field lists share an input.
    static func digest(_ fields: [String?]) -> String {
        var s = ""
        for field in fields {
            if let field { s += "\(field.utf8.count):\(field);" } else { s += "-;" }
        }
        return TextNorm.sha256Hex(Data(s.utf8))
    }
}

/// Durable states (section 3 item 2).
public enum JournalState: String, Hashable, Codable, Sendable, Comparable {
    case received
    case approved
    /// Written and fsynced before the Apple Event, press or Return.
    case invoking
    /// Written once that call returns.
    case invoked
    /// The result has been recorded.
    case final

    private var rank: Int {
        switch self {
        case .received: return 0
        case .approved: return 1
        case .invoking: return 2
        case .invoked: return 3
        case .final: return 4
        }
    }

    public static func < (a: JournalState, b: JournalState) -> Bool { a.rank < b.rank }
}

/// What a journal entry stores. States, results, times, action names, approval ids, transfer names, GUIDs, ROWIDs
/// and digests. Never message text (section 3 item 2).
///
/// Crash reconciliation needs only `binding` and `facts`: the binding holds the text and attachment digests, the
/// target GUID and part, the parent GUID, the tapback kind and set or remove; the facts hold the snapshot ROWID, the
/// target ROWID, the transfer names and date_edited before an edit.
public struct JournalEntry: Hashable, Codable, Sendable {
    public var id: String
    public var key: IdempotencyKey
    public var action: MutationKind
    public var chat: CanonicalChatID?
    /// What the request is bound to, written with `received`. Digests only, never text.
    public var binding: ApprovalBinding
    public var state: JournalState
    public var receivedAt: Date
    public var updatedAt: Date
    public var approvalID: String?
    public var facts: InvocationFacts?
    /// The response the first request got, replayed for a repeated key. `finish` strips message text from it
    /// (`SendOutcome.text`, quoted bodies) before writing, so the journal never holds text.
    public var response: ResponsePayload?
    public var result: ActionResult?
    /// True from just before `ForegroundMachine.run` until the entry records `final`. IMBridge sets it with
    /// `markForeground(id, true)` and `finish` writes it false. Only IMBridge knows when the machine starts, so the
    /// machine itself never writes it. A crash while it is set turns foreground mode off (section 3 item 2).
    public var foreground: Bool
    /// When the entry reached `invoking`. A send counts toward the rate limits from then (`Journal.sendEvent`).
    public var invokingAt: Date?
    /// GUIDs of the rows crash recovery matched, because the response it stores is `.failure` and carries none. Nil
    /// for every other entry: a normal send keeps its GUIDs in `response`.
    public var sentGUIDs: [String]?

    public init(id: String, key: IdempotencyKey, action: MutationKind, chat: CanonicalChatID?,
                binding: ApprovalBinding, state: JournalState, receivedAt: Date, updatedAt: Date,
                approvalID: String? = nil, facts: InvocationFacts? = nil, response: ResponsePayload? = nil,
                result: ActionResult? = nil, foreground: Bool = false, invokingAt: Date? = nil,
                sentGUIDs: [String]? = nil) {
        self.id = id
        self.key = key
        self.action = action
        self.chat = chat
        self.binding = binding
        self.state = state
        self.receivedAt = receivedAt
        self.updatedAt = updatedAt
        self.approvalID = approvalID
        self.facts = facts
        self.response = response
        self.result = result
        self.foreground = foreground
        self.invokingAt = invokingAt
        self.sentGUIDs = sentGUIDs
    }
}

/// What a new request finds for its key (section 3 item 1).
public enum KeyLookup: Hashable, Sendable {
    /// No live entry, or `--again` with no entry for the key at `invoking` or `invoked`: run it.
    case fresh
    /// A final entry whose result holds the key: return it, send nothing.
    case replay(ResponsePayload)
    /// Waiting for approval, or approved and not yet at `invoking`: `pending <id>`.
    case pending(approvalID: String)
    /// At `invoking` or `invoked`: `may_have_completed`, never run again.
    case mayHaveCompleted
    /// A repeated tapback key whose first result was `ok`: re-read the current reaction and report it.
    case rereadReaction(JournalEntry)
}

/// What `Journal.claim` found for a new request.
public enum KeyClaim: Hashable, Sendable {
    /// The key is free, or `--again` was given and no entry for the key is at `invoking` or `invoked`: the request
    /// runs as this new `received` entry.
    case run(JournalEntry)
    /// The key is held or in flight: answer with this and run nothing. Never `.fresh`.
    case found(KeyLookup)
}

/// Reconciles `invoking` and `invoked` entries after a crash, from chat.db only, for up to 10 s (section 3 item 2).
/// Live: `IMBridge.ReconcileAdapter` over IMSend's correlator, IMUI's verify-only paths and IMForeground's verifier.
/// It works from `entry.binding` and `entry.facts` alone. Never presses or sends.
public protocol JournalReconciling: AnyObject {
    /// `deadline` is a `Clock.uptime` value, `Limits.reconcileTimeout` after the call starts. The reconciler returns
    /// by then: a matched or verifying row's result, else `may_have_completed`.
    func reconcile(_ entry: JournalEntry, deadline: TimeInterval) -> ActionResult
    /// `reconcile` plus the GUIDs of the rows a send or threaded reply matched. `recoverAfterCrash` calls this one.
    func reconcileRows(_ entry: JournalEntry, deadline: TimeInterval) -> Reconciliation
}

extension JournalReconciling {
    /// For conformers that implement only `reconcile`: its result, with no row GUIDs.
    public func reconcileRows(_ entry: JournalEntry, deadline: TimeInterval) -> Reconciliation {
        Reconciliation(result: reconcile(entry, deadline: deadline))
    }
}

/// A reconciled result with the GUIDs of the rows it matched. Recovery stores them in `JournalEntry.sentGUIDs`, so a
/// send reconciled after a crash still reaches `ChatDatabase.agentSentGUIDs` and the rate-limit history.
public struct Reconciliation: Hashable, Sendable {
    public var result: ActionResult
    public var sentGUIDs: [String]

    public init(result: ActionResult, sentGUIDs: [String] = []) {
        self.result = result
        self.sentGUIDs = sentGUIDs
    }
}

public enum JournalError: Error, Hashable, Sendable {
    case unknownEntry(String)
    /// `advance` only moves forward: received to approved or invoking, approved to invoking, invoking to invoked.
    case invalidTransition(id: String, from: JournalState, to: JournalState)
    /// The entry already recorded `final`.
    case alreadyFinal(String)
    /// A record that isn't the last line failed to decode. The bridge doesn't serve mutations on a journal it can't
    /// read, since a lost `invoking` record could make a retry send twice.
    case corruptRecord(line: Int)
}

/// Append-only journal under `Paths.journalDir`, one fsynced record per transition, kept 7 days. Owner: IMPolicy.
///
/// Lookups use a sliding 10-minute window from when each final entry reached `invoking`, or from its final write if
/// it never did. A result holds the key only when `ActionResult.holdsIdempotencyKey` is true.
///
/// File format: `journal.ndjson`, one JSON `JournalEntry` per line, each line the entry's full state after one
/// transition. The last line for an id wins. Every append is flushed (`F_FULLFSYNC`) before the call returns, so
/// `willInvoke` returning means `invoking` is on disk. A crash in the middle of an append leaves a partial last line;
/// the next start cuts it off, and the entry keeps its previous state. That is safe because the caller only acts
/// after `willInvoke` returns. `prune` rewrites the file with one line per kept entry and renames it into place.
///
/// Lookup rules:
/// - `again` skips the lookup, with one exception: an entry with the key at `invoking` or `invoked` still gives
///   `may_have_completed`, because that request may have sent already and never runs twice (section 3 item 1).
///   Final, `received` and `approved` entries don't count under `again`.
/// - An entry that isn't final matches whatever its age, so a request still in flight never runs twice.
///   `received` or `approved` gives `pending <approval id>` (the entry id if it needed no approval). `invoking` or
///   `invoked` gives `may_have_completed`.
/// - Otherwise the newest final entry with the key whose window started less than 10 minutes ago and whose result
///   holds the key is replayed. A react whose result was `ok` gives `rereadReaction` instead.
/// - That entry no longer matches once a later request with a different key on the same target slot is final with a
///   result that may have taken effect (`holdsIdempotencyKey`). A later `not_loaded`, `unsupported` or other result
///   that changed nothing leaves the earlier key held.
///
/// Thread safe. One lock covers the in-memory index and every file write.
public final class Journal {
    public let directory: URL
    public let clock: Clock

    /// The journal file inside `directory`.
    public let fileURL: URL

    /// The journal is a week of small records; anything over this is refused at start.
    static let maxFileBytes = 256 * 1024 * 1024

    private let lock = NSLock()
    private var entries: [String: JournalEntry] = [:]

    public init(directory: URL, clock: Clock) throws {
        self.directory = directory
        self.clock = clock
        self.fileURL = directory.appendingPathComponent("journal.ndjson")
        try DurableFile.ensureDirectory(directory)
        // Temp files from a prune interrupted before its rename. The journal file itself is intact.
        DurableFile.removeLeftoverTemps(of: fileURL)
        entries = try Journal.loadRecords(fileURL)
    }

    public func lookup(_ key: IdempotencyKey, again: Bool) -> KeyLookup {
        lock.lock()
        defer { lock.unlock() }
        return again ? againLookupLocked(key) : lookupLocked(key)
    }

    /// Writes `received` with the binding and returns the new entry.
    public func begin(key: IdempotencyKey, action: MutationKind, chat: CanonicalChatID?,
                      binding: ApprovalBinding) throws -> JournalEntry {
        lock.lock()
        defer { lock.unlock() }
        return try beginLocked(key: key, action: action, chat: chat, binding: binding)
    }

    /// `lookup` and `begin` under one lock. With `lookup` then `begin`, two requests with the same key that arrive
    /// together can both find it fresh and both run. With `claim`, the second one finds the first one's `received`
    /// entry and gets `pending <id>`. `again` skips the lookup as in `lookup`, so a same-key entry at `invoking` or
    /// `invoked` still gives `may_have_completed` and writes nothing.
    public func claim(key: IdempotencyKey, again: Bool, action: MutationKind, chat: CanonicalChatID?,
                      binding: ApprovalBinding) throws -> KeyClaim {
        lock.lock()
        defer { lock.unlock() }
        let found = again ? againLookupLocked(key) : lookupLocked(key)
        if found != .fresh { return .found(found) }
        return .run(try beginLocked(key: key, action: action, chat: chat, binding: binding))
    }

    /// Records the open dialog's id on a `received` entry, so a repeated key gets `pending <approval id>` while the
    /// dialog is up. An `approved` entry takes it too: an approved threaded reply asks again when the rate recheck
    /// under the queue finds a breach its dialog didn't name. Fsynced before returning.
    public func attachApproval(_ id: String, approvalID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var entry = try liveEntryLocked(id)
        guard entry.state == .received || entry.state == .approved else {
            throw JournalError.invalidTransition(id: id, from: entry.state, to: .received)
        }
        entry.approvalID = approvalID
        entry.updatedAt = clock.now
        try commitLocked(entry)
    }

    /// Writes a state transition and fsyncs before returning.
    public func advance(_ id: String, to state: JournalState, approvalID: String? = nil,
                        facts: InvocationFacts? = nil) throws {
        lock.lock()
        defer { lock.unlock() }
        var entry = try liveEntryLocked(id)
        guard Journal.allowed(from: entry.state, to: state) else {
            throw JournalError.invalidTransition(id: id, from: entry.state, to: state)
        }
        let now = clock.now
        entry.state = state
        entry.updatedAt = now
        if let approvalID { entry.approvalID = approvalID }
        if let facts { entry.facts = facts }
        if state == .invoking { entry.invokingAt = now }
        try commitLocked(entry)
    }

    /// IMBridge calls `markForeground(id, true)` right before `ForegroundMachine.run`, whatever the entry's state.
    /// Fsynced before returning.
    public func markForeground(_ id: String, _ on: Bool) throws {
        lock.lock()
        defer { lock.unlock() }
        var entry = try liveEntryLocked(id)
        entry.foreground = on
        entry.updatedAt = clock.now
        try commitLocked(entry)
    }

    /// Writes `final` with the result and the response to replay, and sets `foreground` false in the same record.
    /// Message text is stripped from the response first (`withoutMessageText`).
    ///
    /// If the append fails, the entry still turns final in memory and the error is rethrown. Lookups then answer
    /// from the real result, not `pending <id>`, and the next `prune` writes the final record from memory. A crash
    /// before that prune leaves the earlier state on disk, which `recoverAfterCrash` finishes at the next start.
    public func finish(_ id: String, result: ActionResult, response: ResponsePayload) throws {
        lock.lock()
        defer { lock.unlock() }
        let entry = try finalEntryLocked(id, result: result, response: response, sentGUIDs: nil)
        do {
            try commitLocked(entry)
        } catch {
            entries[entry.id] = entry
            throw error
        }
    }

    /// For `recoverAfterCrash`: a failed append leaves the entry open, so the bridge keeps refusing mutations.
    private func finishStrict(_ id: String, result: ActionResult, response: ResponsePayload,
                              sentGUIDs: [String]?) throws {
        lock.lock()
        defer { lock.unlock() }
        try commitLocked(try finalEntryLocked(id, result: result, response: response, sentGUIDs: sentGUIDs))
    }

    private func finalEntryLocked(_ id: String, result: ActionResult, response: ResponsePayload,
                                  sentGUIDs: [String]?) throws -> JournalEntry {
        var entry = try liveEntryLocked(id)
        entry.state = .final
        entry.updatedAt = clock.now
        entry.result = result
        entry.response = Journal.withoutMessageText(response, result: result)
        entry.foreground = false
        entry.sentGUIDs = sentGUIDs
        return entry
    }

    /// The `InvocationRecorder` that IMSend, IMUI and IMForeground call for this entry.
    public func recorder(for id: String) -> InvocationRecorder { JournalRecorder(journal: self, id: id) }

    public func entry(_ id: String) -> JournalEntry? {
        lock.lock()
        defer { lock.unlock() }
        return entries[id]
    }

    /// The entry `imessage pending <id>` names: the one whose approval id is `pendingID`, else the one with that id.
    public func entry(pendingID: String) -> JournalEntry? {
        lock.lock()
        defer { lock.unlock() }
        let byApproval = entries.values.filter { $0.approvalID == pendingID }.max { $0.receivedAt < $1.receivedAt }
        return byApproval ?? entries[pendingID]
    }

    /// Every entry, oldest first. IMBridge seeds `ChatDatabase.agentSentGUIDs` and the rate limiter from these.
    public func allEntries() -> [JournalEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries.values.sorted { ($0.receivedAt, $0.id) < ($1.receivedAt, $1.id) }
    }

    /// The rate-limit event for a send or threaded reply that reached `invoking`, nil for anything else. IMBridge
    /// passes it to `RateLimiter.record` after `finish`, and `sendEvents` rebuilds the same events at start.
    public func sendEvent(for id: String) -> SendEvent? {
        lock.lock()
        defer { lock.unlock() }
        return entries[id].flatMap(Journal.sendEvent(from:))
    }

    /// Rate-limit history for `RateLimiter(history:)` after a restart, oldest first.
    public func sendEvents() -> [SendEvent] {
        allEntries().compactMap(Journal.sendEvent(from:))
    }

    /// GUIDs of every row a journaled send produced, for `ChatDatabase.agentSentGUIDs`, including the rows crash
    /// recovery matched (`JournalEntry.sentGUIDs`).
    public func agentSentGUIDs() -> Set<String> {
        var guids = Set<String>()
        for entry in allEntries() {
            guids.formUnion(entry.sentGUIDs ?? [])
            guard case .send(let outcome)? = entry.response else { continue }
            for part in outcome.parts { if let g = part.guid { guids.insert(g) } }
        }
        return guids
    }

    /// Run once at bridge start, before the socket is served.
    /// - `received` or `approved`: `failed: bridge restarted`, final, key not held.
    /// - `invoking` or `invoked`: reconciled result or `may_have_completed`, final, key held. A reconciled result
    ///   that wouldn't hold the key becomes `may_have_completed`, since the action may have run. The GUIDs of the
    ///   rows it matched go in `JournalEntry.sentGUIDs`.
    /// - Returns true if any entry that wasn't final had `foreground` set, whatever its state. A crash after
    ///   activation and before the first press leaves the entry at `approved`, and that still counts. The caller then
    ///   turns foreground mode off and keeps the crash note for `doctor`.
    ///
    /// The stored response is `.failure` carrying the result, because the original response never got written.
    /// Throws if a `final` record can't be written; the bridge must not serve mutations then.
    public func recoverAfterCrash(using reconciler: JournalReconciling) throws -> Bool {
        let open = allEntries().filter { $0.state != .final }
        var foregroundCrash = false
        for entry in open {
            if entry.foreground { foregroundCrash = true }
            let result: ActionResult
            var guids: [String]?
            switch entry.state {
            case .received, .approved:
                result = ActionResult(.failed(.bridgeRestarted))
            case .invoking, .invoked:
                let reconciled = reconciler.reconcileRows(entry, deadline: clock.uptime + Limits.reconcileTimeout)
                result = reconciled.result.holdsIdempotencyKey ? reconciled.result : ActionResult(.mayHaveCompleted)
                if !reconciled.sentGUIDs.isEmpty { guids = reconciled.sentGUIDs }
            case .final:
                continue
            }
            try finishStrict(entry.id, result: result, response: .failure(WireError(result: result)), sentGUIDs: guids)
        }
        return foregroundCrash
    }

    /// Deletes records older than `Limits.journalRetention`, counted from each entry's last write. Entries that
    /// aren't final are kept. Rewrites the file with one line per kept entry.
    public func prune() throws {
        lock.lock()
        defer { lock.unlock() }
        let now = clock.now
        let kept = entries.values
            .filter { $0.state != .final || now.timeIntervalSince($0.updatedAt) <= Limits.journalRetention }
            .sorted { ($0.receivedAt, $0.id) < ($1.receivedAt, $1.id) }
        var data = Data()
        for entry in kept { data.append(try Journal.line(entry)) }
        try DurableFile.replace(fileURL, with: data)
        entries = Dictionary(uniqueKeysWithValues: kept.map { ($0.id, $0) })
    }

    // MARK: - Internals

    private func lookupLocked(_ key: IdempotencyKey) -> KeyLookup {
        let now = clock.now
        let same = entries.values.filter { $0.key.value == key.value }
            .sorted { ($0.receivedAt, $0.id) > ($1.receivedAt, $1.id) }

        let inFlight = same.filter { $0.state != .final }
        if inFlight.contains(where: { $0.state >= .invoking }) { return .mayHaveCompleted }
        if let waiting = inFlight.first { return .pending(approvalID: waiting.approvalID ?? waiting.id) }

        guard let held = same.first(where: { entry in
            now.timeIntervalSince(Journal.windowStart(entry)) < Limits.idempotencyWindow
                && entry.result?.holdsIdempotencyKey == true && entry.response != nil
        }) else { return .fresh }

        if let slot = key.targetSlot {
            let superseded = entries.values.contains { other in
                other.key.targetSlot == slot && other.key.value != key.value && other.state == .final
                    && other.result?.holdsIdempotencyKey == true && other.receivedAt > held.receivedAt
            }
            if superseded { return .fresh }
        }
        if held.action == .react, held.result?.code == .ok { return .rereadReaction(held) }
        return held.response.map(KeyLookup.replay) ?? .fresh
    }

    /// The lookup under `--again`: `may_have_completed` while an entry with the key is at `invoking` or `invoked`,
    /// whatever its age, else `fresh`.
    private func againLookupLocked(_ key: IdempotencyKey) -> KeyLookup {
        let invoked = entries.values.contains { entry in
            entry.key.value == key.value && (entry.state == .invoking || entry.state == .invoked)
        }
        return invoked ? .mayHaveCompleted : .fresh
    }

    /// Where a final entry's 10-minute window starts: when it reached `invoking`, or for an entry that never did, its
    /// final write. `finish` sets `updatedAt` and nothing writes a final entry again. Measuring from `receivedAt`
    /// would let a slow approval, the queue and correlation use up the window before the send even landed.
    static func windowStart(_ entry: JournalEntry) -> Date {
        entry.invokingAt ?? entry.updatedAt
    }

    private func beginLocked(key: IdempotencyKey, action: MutationKind, chat: CanonicalChatID?,
                             binding: ApprovalBinding) throws -> JournalEntry {
        var id = ShortID.make()
        while entries[id] != nil { id = ShortID.make() }
        let now = clock.now
        let entry = JournalEntry(id: id, key: key, action: action, chat: chat, binding: binding, state: .received,
                                 receivedAt: now, updatedAt: now)
        try commitLocked(entry)
        return entry
    }

    private func liveEntryLocked(_ id: String) throws -> JournalEntry {
        guard let entry = entries[id] else { throw JournalError.unknownEntry(id) }
        guard entry.state != .final else { throw JournalError.alreadyFinal(id) }
        return entry
    }

    /// Appends and flushes the record, then updates memory. A failed write leaves memory unchanged.
    private func commitLocked(_ entry: JournalEntry) throws {
        try DurableFile.append(fileURL, try Journal.line(entry))
        entries[entry.id] = entry
    }

    static func allowed(from: JournalState, to: JournalState) -> Bool {
        switch (from, to) {
        case (.received, .approved), (.received, .invoking), (.approved, .invoking), (.invoking, .invoked):
            return true
        default:
            return false
        }
    }

    static func line(_ entry: JournalEntry) throws -> Data {
        var data = try JSONEncoder.wire.encode(entry)
        data.append(0x0A)
        return data
    }

    static func loadRecords(_ url: URL) throws -> [String: JournalEntry] {
        let data: Data
        switch DurableFile.read(url, maxBytes: maxFileBytes, requireOwnerOnlyMode: false) {
        case .missing: return [:]
        case .foreign: throw StorageError(operation: "open", path: url.path, code: EFTYPE)
        case .unreadable(let code): throw StorageError(operation: "read", path: url.path, code: code)
        case .data(let d): data = d
        }
        // Cut a partial last line left by a crash in the middle of an append.
        let complete = data.lastIndex(of: 0x0A).map { data.index(after: $0) } ?? data.startIndex
        if complete != data.endIndex {
            try DurableFile.truncate(url, to: complete - data.startIndex)
        }
        var out: [String: JournalEntry] = [:]
        let decoder = JSONDecoder.wire
        for (n, line) in data[data.startIndex..<complete].split(separator: 0x0A).enumerated() {
            guard let entry = try? decoder.decode(JournalEntry.self, from: Data(line)) else {
                throw JournalError.corruptRecord(line: n + 1)
            }
            out[entry.id] = entry
        }
        return out
    }

    static func sendEvent(from entry: JournalEntry) -> SendEvent? {
        guard entry.action.isRateLimited, let at = entry.invokingAt, let chat = entry.chat else { return nil }
        var guid: String?
        if case .send(let outcome)? = entry.response {
            guid = outcome.parts.first { $0.part == .text && $0.guid != nil }?.guid
                ?? outcome.parts.first { $0.guid != nil }?.guid
        }
        return SendEvent(chat: chat, at: at, guid: guid ?? entry.sentGUIDs?.first, textDigest: entry.binding.textDigest)
    }

    /// The response with every piece of message text removed: the send text, voice transcripts on staged
    /// attachments, and the quoted target of a UI action. Mutations answer with `send`, `ui`, `policy` or `failure`,
    /// and the last two carry no message text. Any other payload is replaced by `.failure` carrying the result.
    static func withoutMessageText(_ payload: ResponsePayload, result: ActionResult) -> ResponsePayload {
        switch payload {
        case .send(var outcome):
            outcome.text = nil
            for i in outcome.parts.indices { outcome.parts[i].attachment?.transcript = nil }
            return .send(outcome)
        case .ui(var outcome):
            outcome.targetQuote = nil
            return .ui(outcome)
        case .policy, .failure:
            return payload
        default:
            return .failure(WireError(result: result))
        }
    }
}

/// `Journal.recorder(for:)`. `willInvoke` writes `invoking` with the facts and returns only once it is on disk.
final class JournalRecorder: InvocationRecorder {
    let journal: Journal
    let id: String

    init(journal: Journal, id: String) {
        self.journal = journal
        self.id = id
    }

    func willInvoke(_ facts: InvocationFacts) throws {
        try journal.advance(id, to: .invoking, facts: facts)
    }

    func didInvoke() throws {
        try journal.advance(id, to: .invoked)
    }
}
