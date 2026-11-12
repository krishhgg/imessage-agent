import Foundation
import IMCore
import IMStore

/// The row description Messages is expected to show for a conversation (DESIGN.md section 4, Targeting).
public struct ExpectedRow: Hashable, Sendable {
    public var description: String
    public var signature: [SignatureRow]

    public init(description: String, signature: [SignatureRow]) {
        self.description = description
        self.signature = signature
    }
}

/// Rebuilds Messages' own row text from chat.db and Contacts: display name, newest preview and time (relative forms
/// such as Yesterday). Rebuilding that text is untested in DESIGN.md, so a mismatch must fail as `not_loaded`.
/// Owner: IMUI.
///
/// The row reads `<name>, <preview>, <time>` (S3). The time is `h:mm AM` today, `Yesterday`, the weekday name for
/// the five days before that, and `M/d/yy` otherwise, in English. Bubbles show the minute as `h:mm AM`.
public struct RowDescriptionBuilder {
    public var timeZone: TimeZone
    public var now: Date

    public init(timeZone: TimeZone, now: Date) {
        self.timeZone = timeZone
        self.now = now
    }

    public func expected(for conversation: ConversationSummary) -> ExpectedRow {
        let time = rowTimeLabel(forNanos: conversation.newestDateNs)
        return ExpectedRow(description: "\(conversation.displayName), \(conversation.newestPreview), \(time)",
                           signature: Array(conversation.signature.prefix(Limits.signatureRows)))
    }

    /// The time part of a conversation row.
    public func rowTimeLabel(forNanos ns: AppleNanos) -> String {
        let date = AppleTime.date(fromNanos: ns)
        let calendar = self.calendar
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? Int.min
        switch days {
        case 0: return format(date, "h:mm a")
        case 1: return "Yesterday"
        case 2...6: return format(date, "EEEE")
        default: return format(date, "M/d/yy")
        }
    }

    /// The minute a bubble shows, `h:mm AM`. `BubbleInfo.minuteLabel` uses the same form.
    public func minuteLabel(forNanos ns: AppleNanos) -> String {
        format(AppleTime.date(fromNanos: ns), "h:mm a")
    }

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }

    private func format(_ date: Date, _ pattern: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = timeZone
        f.dateFormat = pattern
        return f.string(from: date)
    }
}

/// What `ChatTargeting.selectChat(_:)` found. Neither case pressed anything.
public enum ChatSelection: Hashable, Sendable {
    /// The target's row was the one selected row and the transcript shows the target's newest messages.
    case selected
    /// Early result: `unsupported_target`, `ambiguous`, `not_loaded`, `unsupported`,
    /// `busy: chat not open in Messages`, or an AX or chat.db error. None carries the mark-read note.
    case refused(ActionResult)
}

public enum BubbleLookup: Hashable, Sendable {
    case found(BubbleInfo)
    /// `ambiguous`, `not_loaded`, `unsupported_target`.
    case refused(ActionResult)
}

/// Chat and message targeting. Live: `ChatTargeter`. IMForeground uses it for step 1 and the step 4 re-reads.
/// What `ChatTargeting.verifySelected(_:)` compares the transcript with, read from chat.db ahead of time so the
/// comparison reads AX only. The foreground edit reads it in step 1, before Messages comes forward, so step 4 makes
/// no chat.db call inside the 3 s window. A message that arrives in between shows as an extra bubble and fails it.
public struct SelectionExpectation: Hashable, Sendable {
    public var chat: ResolvedChat
    /// The chat's newest `Limits.signatureRows` signature rows.
    public var signature: [SignatureRow]
    /// The bound message, left out of the comparison. Nil compares the whole signature.
    public var bound: MessageTargetInfo?

    public init(chat: ResolvedChat, signature: [SignatureRow], bound: MessageTargetInfo?) {
        self.chat = chat
        self.signature = signature
        self.bound = bound
    }
}

public protocol ChatTargeting: AnyObject {
    /// Group check, duplicate description and duplicate signature checks, no-text-rows check, then exactly one
    /// matching row, after a bounded wait if the conversation list is still loading. The action runs in place: the
    /// target's row must already be the one selected row, and the newest loaded text bubbles must equal the
    /// signature. Otherwise it refuses. It never presses a row.
    func selectChat(_ chat: ResolvedChat) -> ChatSelection
    /// Re-reads the loaded bubbles against the signature without pressing anything.
    func verifySelected(_ chat: ResolvedChat, excluding rowid: Int64?) -> Bool
    /// The chat.db half of `verifySelected(_:excluding:)`. Nil for a group, a failed read, or a bound message from
    /// another conversation.
    func selectionExpectation(_ chat: ResolvedChat, excluding rowid: Int64?) -> SelectionExpectation?
    /// The AX half: the loaded bubbles against an expectation read earlier. Reads no chat.db.
    func verifySelected(_ expected: SelectionExpectation) -> Bool
    /// Direction, NFC text and minute must match, exactly one loaded bubble, no other chat.db message in the chat with
    /// the same direction, body and minute on any day, single-part text only.
    func findBubble(_ target: MessageTargetInfo) -> BubbleLookup
    /// `findBubble` without its chat.db duplicate check, for finding the bubble again once `findBubble` passed.
    /// Reads AX only.
    func findLoadedBubble(_ target: MessageTargetInfo) -> BubbleLookup
}

/// Live `ChatTargeting`. Owner: IMUI.
///
/// `selectChat`, in order. It presses nothing on any path, because on Messages 26 an `AXPress` on a conversation row
/// does nothing while Messages is hidden or minimized (research/chat-switch.md section 1):
/// 1. A group chat is `unsupported_target`. A chat with no text rows (or no conversation) is `not_loaded`.
/// 2. Another conversation (each group on its own, 1:1 chats grouped by handle, the target left out) with the same
///    expected description, or whose signature cut to the target signature's length equals it, is `ambiguous`.
/// 3. The conversation rows. If no row's description equals the expected one and the list is still loading, it
///    reads the list's state (`MessagesAXDriving.conversationListState`) every `pollInterval` until the list has
///    loaded, then reads the rows again. A list still loading after `listLoadTimeout` is `not_loaded`. The list is
///    still loading while it has children and none of them is a row, and after a read that hit an element Messages
///    had just replaced (`AXDriveError.staleReference`). Within `listLoadTimeout` of the bridge's last launch of
///    Messages (`lastLaunch`) it is also still loading while no list shows, or while a placeholder child sits next
///    to the rows (`ConversationListState.partlyLoaded`). A loaded list, or a missing or part-loaded one with no
///    recent launch, gets no polling wait. When its first read has no match, its rows are read once more, since
///    Messages can replace its placeholders between the row read and the state read.
/// 4. Exactly one loaded row whose full description equals the expected one (`sameRowText`). None is `not_loaded`,
///    several are `ambiguous`. No prefix matching and no scrolling. A row without the English row actions
///    (`UINames.requiredRowActions`) is `unsupported`: Messages isn't running in English.
/// 5. That row must read selected and no other row may. Otherwise, with the target not selected, two or more rows
///    selected, or any row's selection unknown, the result is `busy: chat not open in Messages` with the fix of
///    `UIResults.chatNotOpen`.
/// 6. The newest loaded text bubbles must equal the signature within `settleTimeout`, otherwise `not_loaded`.
///
/// Any other AX error in step 3, during the wait included, refuses as `UIResults.axFailure`.
///
/// No result carries the mark-read note, since no row was pressed. Bodies compare as `TextNorm.matchKey` (NFC,
/// trimmed). A chat.db read error is `error: can't read chat.db`.
public final class ChatTargeter: ChatTargeting {
    public let ax: MessagesAXDriving
    public let source: UITargetSource
    public let builder: () -> RowDescriptionBuilder
    public let clock: Clock
    /// How long the transcript of the selected chat gets to match the signature before the check fails.
    public var settleTimeout: TimeInterval = 2
    /// How long a conversation list that is still loading gets to load. A list still loading after it is
    /// `not_loaded`. On macOS 26.2 with Messages 26.0, the list's children were groups with no row text about 1 to
    /// 2 s after a hidden launch, and were all rows about 6 s after it (research/live-tests/2026-11-07-sends.md,
    /// Conversation rows after a hidden launch).
    public var listLoadTimeout: TimeInterval = 6
    public var pollInterval: TimeInterval = 0.1
    /// `clock.uptime` of the bridge's last launch of Messages (`HiddenWindowManager.lastLaunchUptime`), nil if it
    /// hasn't launched Messages. A missing conversation list, or one with a placeholder child next to its rows,
    /// counts as still loading only within `listLoadTimeout` of that launch. At any other time a window with no list
    /// stays `not_loaded` with no wait, and so does a list with any row. A list only counts as loading on its own when
    /// it has placeholders and no row, so pinned tiles with descriptions never cause a wait.
    public let lastLaunch: () -> TimeInterval?

    public convenience init(ax: MessagesAXDriving, source: UITargetSource,
                            builder: @escaping () -> RowDescriptionBuilder,
                            lastLaunch: @escaping () -> TimeInterval? = { nil }) {
        self.init(ax: ax, source: source, builder: builder, clock: SystemClock(), lastLaunch: lastLaunch)
    }

    public init(ax: MessagesAXDriving, source: UITargetSource, builder: @escaping () -> RowDescriptionBuilder,
                clock: Clock, lastLaunch: @escaping () -> TimeInterval? = { nil }) {
        self.ax = ax
        self.source = source
        self.builder = builder
        self.clock = clock
        self.lastLaunch = lastLaunch
    }

    public func selectChat(_ chat: ResolvedChat) -> ChatSelection {
        if chat.isGroup || chat.canonical.isGroup { return .refused(ActionResult(.unsupportedTarget)) }
        let target: ConversationSummary
        let all: [ConversationSummary]
        do {
            guard let found = try source.conversation(for: chat) else { return .refused(ActionResult(.notLoaded)) }
            target = found
            all = try source.conversations()
        } catch {
            return .refused(UIResults.readFailed)
        }
        if target.isGroup || target.canonical.isGroup { return .refused(ActionResult(.unsupportedTarget)) }
        let rowBuilder = builder()
        let expected = rowBuilder.expected(for: target)
        if expected.signature.isEmpty { return .refused(ActionResult(.notLoaded)) }
        if Self.hasLookalike(of: target, expected: expected, among: all, builder: rowBuilder) {
            return .refused(ActionResult(.ambiguous(.target)))
        }

        let read: [ConversationRowInfo]?
        do { read = try conversationRows(matching: expected.description) } catch {
            return .refused(UIResults.axFailure(error))
        }
        guard let rows = read else { return .refused(ActionResult(.notLoaded)) }
        let matches = rows.filter { Self.sameRowText($0.description, expected.description) }
        guard let row = matches.first else { return .refused(ActionResult(.notLoaded)) }
        guard matches.count == 1 else { return .refused(ActionResult(.ambiguous(.target))) }
        // The bubble actions are matched by English names. A row without Messages' English row actions means
        // Messages runs in another language, so the action can't run.
        guard UINames.showsEnglishRowActions(row.actionNames) else { return .refused(UIResults.messagesNotEnglish) }

        // A row press does nothing while Messages is hidden, so the action runs only on a chat that is already the
        // one selected chat. With two rows selected Messages shows no transcript, so that refuses too. A row whose
        // selection reads unknown could be a second selected row, so it refuses the same way.
        guard row.isSelected == true, !rows.contains(where: { $0.isSelected == nil }),
              rows.filter({ $0.isSelected == true }).count == 1 else {
            return .refused(UIResults.chatNotOpen(chat))
        }
        if waitForTranscript(matching: expected.signature) { return .selected }
        return .refused(ActionResult(.notLoaded))
    }

    /// With `rowid`, the bound message is left out of both sides: loaded bubbles with its direction, body and minute
    /// are dropped, and one signature row with its direction and body is dropped. When the bound row leaves the
    /// signature empty, no other bubble that shows text (`BubbleInfo.showsText`) may be loaded. Any read error, a group chat, a bound row in another
    /// conversation or an empty signature is false.
    public func verifySelected(_ chat: ResolvedChat, excluding rowid: Int64?) -> Bool {
        guard let expected = selectionExpectation(chat, excluding: rowid) else { return false }
        return verifySelected(expected)
    }

    public func selectionExpectation(_ chat: ResolvedChat, excluding rowid: Int64?) -> SelectionExpectation? {
        if chat.isGroup || chat.canonical.isGroup { return nil }
        do {
            guard let summary = try source.conversation(for: chat), !summary.isGroup else { return nil }
            let signature = Array(summary.signature.prefix(Limits.signatureRows))
            guard let rowid else { return SelectionExpectation(chat: chat, signature: signature, bound: nil) }
            guard let bound = try source.messageTarget(rowid: rowid), bound.canonical == summary.canonical else {
                return nil
            }
            return SelectionExpectation(chat: chat, signature: signature, bound: bound)
        } catch {
            return nil
        }
    }

    public func verifySelected(_ expected: SelectionExpectation) -> Bool {
        if expected.chat.isGroup || expected.chat.canonical.isGroup { return false }
        let signature = expected.signature
        guard var bubbles = try? ax.loadedBubbles() else { return false }
        guard let bound = expected.bound else { return !signature.isEmpty && Self.newestMatch(bubbles, signature) }
        let minute = builder().minuteLabel(forNanos: bound.dateNs)
        let key = TextNorm.matchKey(bound.body)
        bubbles.removeAll { $0.minuteLabel == minute && $0.shows(bound.body, fromMe: bound.fromMe) }
        let candidates = signature.indices.filter {
            signature[$0].fromMe == bound.fromMe && TextNorm.matchKey(signature[$0].body) == key
        }
        if candidates.isEmpty { return !signature.isEmpty && Self.newestMatch(bubbles, signature) }
        return candidates.contains { index in
            var rest = signature
            rest.remove(at: index)
            return rest.isEmpty ? !bubbles.contains(where: \.showsText) : Self.newestMatch(bubbles, rest)
        }
    }

    public func findBubble(_ target: MessageTargetInfo) -> BubbleLookup {
        if let refusal = UIResults.unsupportedTarget(target) { return .refused(refusal) }
        do {
            if try source.sameBodyAndMinuteCount(for: target) > 0 { return .refused(ActionResult(.ambiguous(.target))) }
        } catch {
            return .refused(UIResults.readFailed)
        }
        return findLoadedBubble(target)
    }

    public func findLoadedBubble(_ target: MessageTargetInfo) -> BubbleLookup {
        if let refusal = UIResults.unsupportedTarget(target) { return .refused(refusal) }
        let bubbles: [BubbleInfo]
        do { bubbles = try ax.loadedBubbles() } catch { return .refused(UIResults.axFailure(error)) }
        let minute = builder().minuteLabel(forNanos: target.dateNs)
        let matches = bubbles.filter { $0.minuteLabel == minute && $0.shows(target.body, fromMe: target.fromMe) }
        guard let bubble = matches.first else { return .refused(ActionResult(.notLoaded)) }
        guard matches.count == 1 else { return .refused(ActionResult(.ambiguous(.target))) }
        return .found(bubble)
    }

    // MARK: - Checks

    /// Section 4: any other conversation with the same description, or the same signature once its newest rows are
    /// cut to the target signature's length.
    static func hasLookalike(of target: ConversationSummary, expected: ExpectedRow, among all: [ConversationSummary],
                             builder: RowDescriptionBuilder) -> Bool {
        let wanted = expected.signature.map(SignatureKey.init)
        for other in all where other.canonical != target.canonical {
            if sameRowText(builder.expected(for: other).description, expected.description) { return true }
            if other.signature.prefix(wanted.count).map(SignatureKey.init) == wanted { return true }
        }
        return false
    }

    /// Row descriptions compare as bubble descriptions do: with U+202F and U+00A0 read as plain spaces on both sides,
    /// and otherwise exactly (no case folding, no prefix match). The lookalike check uses the same rule, so a chat it
    /// lets through can't match a row meant for another.
    static func sameRowText(_ a: String, _ b: String) -> Bool {
        BubbleDescription.normalizeSpaces(a) == BubbleDescription.normalizeSpaces(b)
    }

    /// The newest `signature.count` loaded bubbles that show text (`BubbleInfo.showsText`), newest first, equal the
    /// signature by direction and body. A bare group is a text with a detected date or time, so it must show its
    /// row like any text bubble, and one that doesn't refuses the match. Other bubbles, such as attachments, are
    /// skipped as before.
    static func newestMatch(_ bubbles: [BubbleInfo], _ signature: [SignatureRow]) -> Bool {
        let text = bubbles.filter(\.showsText)
        guard !signature.isEmpty, text.count >= signature.count else { return false }
        return zip(text.suffix(signature.count).reversed(), signature).allSatisfy { bubble, row in
            bubble.hasTextBubble ? SignatureKey(fromMe: bubble.fromMe, text: bubble.text) == SignatureKey(row)
                : bubble.shows(row.body, fromMe: row.fromMe)
        }
    }

    /// The conversation rows, read again once the list has loaded when no row matches `description` and the list is
    /// still loading (`listProgress`). Nil when it is still loading after `listLoadTimeout`. A row read that hits a
    /// stale element counts as a list still loading, since Messages replaces the list's children while it loads.
    /// When the first read has no match and the list no longer counts as loading, the rows are read once more,
    /// because Messages can replace its placeholders between the row read and the state read. While rows show next to
    /// placeholders after a launch, each poll reads the rows too and returns as soon as one matches. Throws any other
    /// AX error.
    private func conversationRows(matching description: String) throws -> [ConversationRowInfo]? {
        let matches: ([ConversationRowInfo]) -> Bool = { $0.contains { Self.sameRowText($0.description, description) } }
        do {
            let rows = try ax.conversationRows()
            if matches(rows) { return rows }
            if try listProgress() == .loaded { return try ax.conversationRows() }
        } catch AXDriveError.staleReference {}
        let deadline = clock.uptime + listLoadTimeout
        while true {
            let left = deadline - clock.uptime
            if left <= 0 { return nil }
            sleepPollStep(clock, interval: pollInterval, left: left)
            switch try listProgress() {
            case .loading:
                continue
            case .rowsShowing:
                do {
                    let rows = try ax.conversationRows()
                    if matches(rows) { return rows }
                } catch AXDriveError.staleReference {}
            case .loaded:
                do { return try ax.conversationRows() } catch AXDriveError.staleReference { continue }
            }
        }
    }

    private enum ListProgress { case loading, rowsShowing, loaded }

    /// `loading` while the list has placeholders and no row, and when the read hits a stale element. Within
    /// `listLoadTimeout` of `lastLaunch`, also `loading` while no list shows, and `rowsShowing` while a placeholder
    /// child sits next to the rows. Otherwise `loaded`. Throws any other AX error.
    private func listProgress() throws -> ListProgress {
        let state: ConversationListState
        do { state = try ax.conversationListState() } catch AXDriveError.staleReference { return .loading }
        switch state {
        case .loading: return .loading
        case .loaded: return .loaded
        case .missing: return launchedRecently() ? .loading : .loaded
        case .partlyLoaded: return launchedRecently() ? .rowsShowing : .loaded
        }
    }

    /// True within `listLoadTimeout` of the bridge's last launch of Messages.
    private func launchedRecently() -> Bool {
        guard let launched = lastLaunch() else { return false }
        return clock.uptime - launched <= listLoadTimeout
    }

    private func waitForTranscript(matching signature: [SignatureRow]) -> Bool {
        let deadline = clock.uptime + settleTimeout
        while true {
            if let bubbles = try? ax.loadedBubbles(), Self.newestMatch(bubbles, signature) { return true }
            let left = deadline - clock.uptime
            if left <= 0 { return false }
            sleepPollStep(clock, interval: pollInterval, left: left)
        }
    }
}

/// Direction and normalized body, the unit signatures compare.
struct SignatureKey: Hashable {
    var fromMe: Bool
    var body: String

    init(fromMe: Bool, text: String) {
        self.fromMe = fromMe
        self.body = TextNorm.matchKey(text)
    }

    init(_ row: SignatureRow) { self.init(fromMe: row.fromMe, text: row.body) }
}

/// Result lines IMUI produces that `ResultCode` has no dedicated case for, and the shared target checks.
/// `unsupportedTarget` and `accessibilityMissing` are public so IMBridge refuses the same requests before the dialog
/// and the journal.
public enum UIResults {
    // Error lines end in ` fix: <fix>` (section 5, Output). The first is IMCore's value, the second uses IMSend's
    // wording and fix.

    /// The journal's `invoking` write failed, so nothing was pressed (Cross-module contracts).
    static let journalWriteFailed = ActionResult.journalWriteFailed
    /// chat.db couldn't be read before the press, so nothing was pressed.
    static let readFailed = ActionResult(.error(.message("can't read chat.db")), fix: "run imessage doctor")
    /// No Accessibility grant. IMBridge returns it before the dialog, and `HiddenWindowManager.prepare` before it
    /// launches or quits anything.
    public static let accessibilityMissing = ActionResult(.error(.message("Accessibility not granted")),
                                                          fix: "run imessage doctor --ui")
    /// The matching row lacks Messages' English row actions, so Messages runs in another language. Nothing pressed.
    static let messagesNotEnglish = ActionResult(.unsupported, fix: "set Messages' language to English and retry")

    /// `busy: chat not open in Messages`: the target isn't the one selected chat, so nothing was pressed. The fix
    /// names the chat by its label, the name the request's own output shows for it, and leads to the one state where
    /// acting in place is measured: Messages hidden with that chat selected (research/chat-switch.md section 4).
    /// With an empty label it says "the chat".
    static func chatNotOpen(_ chat: ResolvedChat) -> ActionResult {
        let label = TextNorm.singleLine(chat.label)
        let name = label.isEmpty ? "the chat" : label
        return ActionResult(.busy(.chatNotOpen), fix: "open \(name) in Messages, hide it (⌘H), then retry")
    }

    /// An AX failure before anything was pressed.
    static func axFailure(_ error: Error) -> ActionResult {
        switch error as? AXDriveError {
        case .notTrusted?: return accessibilityMissing
        case .notRunning?: return ActionResult(.noHiddenWindow)
        case .messagesVisible(let state)?: return WindowRules.busyResult(for: state)
        default: return ActionResult(.notLoaded)
        }
    }

    /// False only for errors that prove nothing was performed: a missing action, a stale element, no grant,
    /// Messages not running, or Messages shown before the press. Any other AX error may have come back after the
    /// press happened.
    static func mayHaveActed(_ error: Error) -> Bool {
        switch error as? AXDriveError {
        case .actionMissing?, .staleReference?, .notTrusted?, .notRunning?, .messagesVisible?: return false
        default: return true
        }
    }

    /// The result for a named action that `mayHaveActed` says didn't run: `missingAction` when the action name was
    /// gone at the press, otherwise `axFailure`.
    static func notPerformed(_ error: AXDriveError, missingAction: ActionResult) -> ActionResult {
        if case .actionMissing = error { return missingAction }
        return axFailure(error)
    }

    /// Section 4: v1 targets 1:1 chats and single-part text (`p:0`) only. Groups, multipart, non-text, unsent and
    /// empty-bodied targets are `unsupported_target`.
    public static func unsupportedTarget(_ target: MessageTargetInfo) -> ActionResult? {
        if target.isGroupChat || target.canonical.isGroup { return ActionResult(.unsupportedTarget) }
        if !target.isSinglePartText || target.partCount > 1 || target.isUnsent { return ActionResult(.unsupportedTarget) }
        if TextNorm.matchKey(target.body).isEmpty { return ActionResult(.unsupportedTarget) }
        return nil
    }
}

extension ActionResult {
    /// Appends notes that aren't already present, in order.
    func adding(_ extra: [ResultNote]) -> ActionResult {
        var copy = self
        for note in extra where !copy.notes.contains(note) { copy.notes.append(note) }
        return copy
    }
}
