import Foundation
import IMCore
import IMPolicy
import IMStore
import IMTestSupport
import XCTest

// Fakes for IMPolicy's own protocols. Nothing here touches the Keychain, Messages or chat.db.

struct FakeFailure: Error, Equatable {}

/// In-memory `KeychainHashStoring`. Thread safe, because the store is called from several connections.
final class InMemoryKeychain: KeychainHashStoring {
    private let lock = NSLock()
    private var stored: Data?
    private var _failRead = false
    private var _failWrite = false
    private var _writes = 0

    init(hash: Data? = nil) { stored = hash }

    var hash: Data? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
    var failRead: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _failRead }
        set { lock.lock(); _failRead = newValue; lock.unlock() }
    }
    var failWrite: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _failWrite }
        set { lock.lock(); _failWrite = newValue; lock.unlock() }
    }
    var writes: Int { lock.lock(); defer { lock.unlock() }; return _writes }

    func readHash() throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        if _failRead { throw FakeFailure() }
        return stored
    }

    func writeHash(_ hash: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        if _failWrite { throw FakeFailure() }
        stored = hash
        _writes += 1
    }

    func deleteHash() throws {
        lock.lock()
        defer { lock.unlock() }
        stored = nil
    }
}

/// `ApprovalPresenting` that records prompts and answers when the test says so. Thread safe.
final class FakePresenter: ApprovalPresenting {
    private let lock = NSLock()
    private var _prompts: [ApprovalPrompt] = []
    private var _withdrawn: [String] = []
    private var callbacks: [String: (ApprovalDecision) -> Void] = [:]
    /// If set, answers inside `present`, before it returns.
    var immediate: ApprovalDecision?

    var prompts: [ApprovalPrompt] { lock.lock(); defer { lock.unlock() }; return _prompts }
    var withdrawn: [String] { lock.lock(); defer { lock.unlock() }; return _withdrawn }

    func present(_ prompt: ApprovalPrompt, decided: @escaping (ApprovalDecision) -> Void) {
        lock.lock()
        _prompts.append(prompt)
        callbacks[prompt.id] = decided
        let answer = immediate
        lock.unlock()
        if let answer { decided(answer) }
    }

    func withdraw(id: String) {
        lock.lock()
        _withdrawn.append(id)
        lock.unlock()
    }

    /// Clicks a button on the panel with this id.
    func answer(_ id: String, _ decision: ApprovalDecision) {
        lock.lock()
        let callback = callbacks[id]
        lock.unlock()
        callback?(decision)
    }
}

/// `ChatActivitySource` returning scripted inbound rows per conversation, honoring `afterNs` and `limit`.
final class ScriptedActivity: ChatActivitySource {
    private let lock = NSLock()
    private var rows: [CanonicalChatID: [InboundRow]] = [:]
    var error: Error?
    private(set) var calls: [(chat: CanonicalChatID, afterNs: AppleNanos, limit: Int)] = []

    func add(_ row: InboundRow, to chat: CanonicalChatID) {
        lock.lock()
        rows[chat, default: []].append(row)
        rows[chat]!.sort { $0.dateNs < $1.dateNs }
        lock.unlock()
    }

    /// An inbound row at `date` with `text` (or a digest of a unique body).
    @discardableResult
    func inbound(_ chat: CanonicalChatID, at date: Date, text: String? = nil, guid: String = UUID().uuidString)
        -> InboundRow {
        let row = InboundRow(rowid: Int64.random(in: 1...1_000_000), guid: guid, dateNs: AppleTime.nanos(from: date),
                             bodyDigest: TextNorm.textDigest(text ?? UUID().uuidString))
        add(row, to: chat)
        return row
    }

    func inboundRows(in chat: ResolvedChat, afterNs: AppleNanos, limit: Int) throws -> [InboundRow] {
        lock.lock()
        defer { lock.unlock() }
        calls.append((chat.canonical, afterNs, limit))
        if let error { throw error }
        return Array((rows[chat.canonical] ?? []).filter { $0.dateNs > afterNs }.prefix(limit))
    }
}

/// `JournalReconciling` returning scripted results per entry id, recording what it was given.
final class ScriptedReconciler: JournalReconciling {
    var results: [String: ActionResult] = [:]
    /// Row GUIDs `reconcileRows` reports per entry id.
    var guids: [String: [String]] = [:]
    var fallback = ActionResult(.mayHaveCompleted)
    private(set) var seen: [(entry: JournalEntry, deadline: TimeInterval)] = []

    func reconcile(_ entry: JournalEntry, deadline: TimeInterval) -> ActionResult {
        seen.append((entry, deadline))
        return results[entry.id] ?? fallback
    }

    func reconcileRows(_ entry: JournalEntry, deadline: TimeInterval) -> Reconciliation {
        Reconciliation(result: reconcile(entry, deadline: deadline), sentGUIDs: guids[entry.id] ?? [])
    }
}

/// A clock like `FakeClock` that also runs scheduled actions when time passes, on the thread that slept. Used where
/// something must happen in the middle of a wait: a click at 30 s, a release at 29.98 s.
final class ScriptedClock: Clock {
    private let lock = NSLock()
    private var _now: Date
    private var _uptime: TimeInterval
    private var actions: [(at: TimeInterval, run: () -> Void)] = []

    init(now: Date = Fixture.now, uptime: TimeInterval = 1000) {
        _now = now
        _uptime = uptime
    }

    var now: Date { lock.lock(); defer { lock.unlock() }; return _now }
    var uptime: TimeInterval { lock.lock(); defer { lock.unlock() }; return _uptime }

    /// Runs `action` the first time the clock reaches `seconds` from its current uptime.
    func after(_ seconds: TimeInterval, _ action: @escaping () -> Void) {
        lock.lock()
        actions.append((_uptime + seconds, action))
        lock.unlock()
    }

    func sleep(_ seconds: TimeInterval) { advance(seconds) }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        _now = _now.addingTimeInterval(seconds)
        _uptime += seconds
        let due = actions.filter { $0.at <= _uptime + 1e-6 }
        actions.removeAll { $0.at <= _uptime + 1e-6 }
        lock.unlock()
        for action in due { action.run() }
    }
}

/// A fresh folder under the temp directory, removed when the test ends.
final class TempDir {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("impolicy-tests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func file(_ name: String) -> URL { url.appendingPathComponent(name) }

    deinit {
        // Restore write access first, in case a test made something read-only.
        if let items = FileManager.default.enumerator(atPath: url.path) {
            for case let item as String in items { chmod(url.appendingPathComponent(item).path, 0o700) }
        }
        chmod(url.path, 0o700)
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Builders

enum T {
    static let mom = CanonicalChatID.direct(handle: "+14155550101")
    static let dad = CanonicalChatID.direct(handle: "+14155550102")
    static let sis = CanonicalChatID.direct(handle: "sis@example.com")
    /// The user's own address, and the self-chat with it.
    static let ownAddress = "+14155550100"
    static let me = CanonicalChatID.direct(handle: ownAddress)
    static let group = CanonicalChatID.group(identifier: "chat123456")

    static func chat(_ canonical: CanonicalChatID, label: String? = nil, rowid: Int64 = 7) -> ResolvedChat {
        let handle = canonical.rawValue.replacingOccurrences(of: "handle:", with: "")
        return ResolvedChat(canonical: canonical, chatRowIDs: [rowid], chatGUIDs: ["iMessage;-;\(handle)"],
                            primaryChatRowID: rowid, label: label ?? handle, isGroup: canonical.isGroup,
                            handles: [handle], sendHandle: handle, service: "iMessage")
    }

    static func sendBinding(_ chat: CanonicalChatID, text: String? = "On my way", attachment: String? = nil)
        -> ApprovalBinding {
        ApprovalBinding(chat: chat, action: .send, textDigest: text.map(TextNorm.textDigest),
                        attachmentDigest: attachment)
    }

    static func sendRequest(_ chat: CanonicalChatID, text: String? = "On my way", attachment: String? = nil)
        -> MutationRequest {
        MutationRequest(binding: sendBinding(chat, text: text, attachment: attachment), chat: T.chat(chat),
                        requiredScope: attachment == nil ? .text : .files, text: text,
                        attachmentName: attachment == nil ? nil : "photo.jpg",
                        attachmentBytes: attachment == nil ? nil : 2_200_000)
    }

    static func request(_ binding: ApprovalBinding, scope: AllowScope = .text) -> MutationRequest {
        MutationRequest(binding: binding, chat: binding.chat.map { T.chat($0) }, requiredScope: scope)
    }

    static func prompt(_ binding: ApprovalBinding, id: String = "", offersAlwaysAllow: Bool = true,
                       text: String? = "On my way") -> ApprovalPrompt {
        ApprovalPrompt(id: id, binding: binding, title: "Send to Mom", chatLabel: "Mom", text: text, parentText: nil,
                       attachmentName: nil, attachmentBytes: nil, offersAlwaysAllow: offersAlwaysAllow,
                       reason: "this chat isn't allowed yet")
    }

    static func sendKey(_ chat: CanonicalChatID = mom, text: String = "On my way") -> IdempotencyKey {
        .send(chat: chat, threaded: false, parentGUID: nil, textDigest: TextNorm.textDigest(text),
              attachmentDigest: nil)
    }

    static func sendOutcome(_ result: ActionResult, text: String? = "On my way", guid: String? = "G-1")
        -> ResponsePayload {
        .send(SendOutcome(chat: ChatRef(rowid: 7, label: "Mom", isGroup: false), approved: false, early: nil,
                          text: text, threadParentRowID: nil,
                          parts: [SendPartOutcome(part: .text, result: result, rowid: 501, guid: guid)],
                          replayed: false))
    }

    static func uiOutcome(_ result: ActionResult, kind: TapbackKind = .heart, quote: String = "See you soon")
        -> ResponsePayload {
        .ui(UIOutcome(action: .react, targetRowID: 41418, chat: ChatRef(rowid: 7, label: "Mom", isGroup: false),
                      tapback: kind, remove: false, approved: false, result: result, currentReaction: nil,
                      replayed: false, targetQuote: ReplyRef(rowid: 41418, senderName: "Mom", text: quote)))
    }
}

/// Runs `body` on `count` threads at once and waits for all of them.
func concurrently(_ count: Int, _ body: @escaping (Int) -> Void) {
    DispatchQueue.concurrentPerform(iterations: count, execute: body)
}

func fileMode(_ url: URL) -> Int {
    var st = stat()
    guard lstat(url.path, &st) == 0 else { return -1 }
    return Int(st.st_mode & 0o777)
}
