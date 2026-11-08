import Foundation
import IMCore
import IMStore

/// English AX action and menu names (DESIGN.md section 4). `caps` checks them; other UI languages are unsupported.
public enum UINames {
    /// The bubble action for a tapback kind. Nil for an emoji kind that isn't a single emoji, so a kind parsed from
    /// text such as "Delete…" or "Reply…" can never name another bubble action.
    public static func tapbackAction(_ kind: TapbackKind) -> String? {
        switch kind {
        case .heart: return "Heart"
        case .like: return "Thumbs up"
        case .dislike: return "Thumbs down"
        case .laugh: return "Ha ha!"
        case .emphasize: return "Exclamation mark"
        case .question: return "Question mark"
        case .emoji(let e): return isEmojiTapback(e) ? e : nil
        }
    }

    public static let undoSend = "Undo Send"
    public static let edit = "Edit"
    public static let replyToLastMessage = "Reply to Last Message…"

    /// The six classic tapback action names.
    public static let classicTapbacks: [String] = ["Heart", "Thumbs up", "Thumbs down", "Ha ha!", "Exclamation mark",
                                                   "Question mark"]

    /// The conversation row actions S3 saw in an English Messages, other than Pin, Unpin and Mark as Read, which
    /// depend on the row. The default for `ConversationRowInfo.actionNames`.
    public static let englishRowActions: [String] = ["Mark as Unread", "Hide Alerts", "Open in New Window", "Delete…"]

    /// The row actions every conversation row shows in an English Messages, read or unread, pinned or not (S3).
    public static let requiredRowActions: [String] = ["Open in New Window", "Delete…"]

    /// True when a row's action names include every `requiredRowActions` name, so Messages runs in English.
    public static func showsEnglishRowActions(_ names: [String]) -> Bool {
        requiredRowActions.allSatisfy(names.contains)
    }

    /// The only menu item IMUI presses (foreground threaded reply). Window > Messages is never used.
    public static let allowedMenuTitles: Set<String> = [replyToLastMessage]

    /// The title S3 saw on the same item while Messages was hidden or a bubble was selected. Step 1 may look it up
    /// to learn the item exists, but it is never pressed.
    public static let replyToMessage = "Reply to Message…"
    public static let lookupOnlyMenuTitles: Set<String> = [replyToMessage]

    /// `MessagesAXDriving.menuItem(titled:)` reads only these titles.
    public static func mayLookUpMenuItem(_ title: String) -> Bool {
        allowedMenuTitles.contains(title) || lookupOnlyMenuTitles.contains(title)
    }

    /// `MessagesAXDriving.press(menuItem:)` presses only these titles.
    public static func mayPressMenuItem(_ title: String) -> Bool {
        allowedMenuTitles.contains(title)
    }

    /// The bubble actions `MessagesAXDriving.perform` may run: the classic tapbacks, a single recent emoji,
    /// Undo Send and Edit. Delete, Forward, Reply and every other bubble action are refused.
    public static func isAllowedBubbleAction(_ name: String) -> Bool {
        classicTapbacks.contains(name) || name == undoSend || name == edit || isEmojiTapback(name)
    }

    /// True for exactly one emoji grapheme: flags, keycaps, skin tones and ZWJ sequences included, plain ASCII,
    /// symbols like "…" and several emoji excluded.
    public static func isEmojiTapback(_ s: String) -> Bool {
        guard s.count == 1 else { return false }
        var sawEmoji = false
        for scalar in s.unicodeScalars {
            let p = scalar.properties
            switch scalar.value {
            case 0x200D, 0xFE0F, 0xE0020...0xE007F:
                continue
            case 0x20E3:
                sawEmoji = true
            default:
                if p.isEmojiPresentation || p.isEmojiModifier || p.isEmoji && scalar.value > 0x7F {
                    sawEmoji = true
                } else if !(p.isEmoji && scalar.value <= 0x7F) {
                    return false
                }
            }
        }
        return sawEmoji
    }
}

/// What a hidden UI action returns to IMBridge.
public struct UIActionResult: Hashable, Sendable {
    public var result: ActionResult
    /// The user's reaction after the action, re-read from chat.db.
    public var currentReaction: TapbackKind?
    /// True once the press happened, so the caller knows the chat may be marked read.
    public var pressed: Bool

    public init(result: ActionResult, currentReaction: TapbackKind?, pressed: Bool) {
        self.result = result
        self.currentReaction = currentReaction
        self.pressed = pressed
    }
}

public struct TapbackRequest: Hashable, Sendable {
    public var target: MessageTargetInfo
    public var chat: ResolvedChat
    public var kind: TapbackKind
    public var remove: Bool

    public init(target: MessageTargetInfo, chat: ResolvedChat, kind: TapbackKind, remove: Bool) {
        self.target = target
        self.chat = chat
        self.kind = kind
        self.remove = remove
    }
}

/// `react` (section 4, Tapback semantics). Owner: IMUI.
///
/// 1. Read the current reaction from chat.db. Already matching, or `--remove` of a kind that isn't set: `already`.
/// 2. Window rules, the chat check, bubble lookup. The chat must already be the one selected chat, otherwise the
///    result is `busy: chat not open in Messages` with nothing pressed. Then read the reaction again, since the
///    window work can take about 20 s and another device may have set it: nothing left to change is `already`.
///    Action name missing: `unsupported`.
/// 3. `recorder.willInvoke` with the snapshot ROWID, the target GUID, part and ROWID, then press, then
///    `recorder.didInvoke`. A refusal at the press's final check pressed nothing and skips `didInvoke`.
/// 4. The 1 s visibility poll, then reads until 10 s after the press for type 2000 to 2006 (add) or 3000 to 3006
///    (remove) on `p:0/<guid>`: `ok`, else `may_have_completed`.
/// 5. Add the visibility note if a window showed, and the mark-read note once the tapback was pressed.
///
/// An AX error that proves the action didn't run maps to its own result: a vanished action name is `unsupported`,
/// a stale bubble `not_loaded`, no Accessibility grant `error: Accessibility not granted`, and Messages gone
/// `no_hidden_window`. Any other AX error at the press may have come back after the press, so the runner verifies.
///
/// Group, multipart and non-text targets are `unsupported_target`, and an emoji kind that isn't one emoji is
/// `unsupported`, before anything is read or pressed. The caller holds the queue and has checked `caps`.
public final class TapbackRunner {
    public let ax: MessagesAXDriving
    public let windows: HiddenWindowManager
    public let targeting: ChatTargeting
    public let source: UITargetSource
    public let clock: Clock
    /// How often chat.db is read while waiting for the verifying row.
    public var pollInterval: TimeInterval = 0.25

    public init(ax: MessagesAXDriving, windows: HiddenWindowManager, targeting: ChatTargeting, source: UITargetSource,
                clock: Clock) {
        self.ax = ax
        self.windows = windows
        self.targeting = targeting
        self.source = source
        self.clock = clock
    }

    public func run(_ request: TapbackRequest, queueDeadline: TimeInterval,
                    recorder: InvocationRecorder) -> UIActionResult {
        let target = request.target
        if let refusal = UIResults.unsupportedTarget(target) {
            return UIActionResult(result: refusal, currentReaction: nil, pressed: false)
        }
        guard let actionName = UINames.tapbackAction(request.kind) else {
            return UIActionResult(result: ActionResult(.unsupported), currentReaction: nil, pressed: false)
        }

        let initial: TapbackKind?
        do {
            initial = try source.currentUserReaction(messageGUID: target.guid, part: 0)
        } catch {
            return UIActionResult(result: UIResults.readFailed, currentReaction: nil, pressed: false)
        }
        if Self.nothingToChange(request, current: initial) {
            return UIActionResult(result: ActionResult(.already), currentReaction: initial, pressed: false)
        }

        var flow = HiddenActionFlow(windows: windows, targeting: targeting)
        let bubble: BubbleInfo
        switch flow.reachBubble(chat: request.chat, target: target, queueDeadline: queueDeadline) {
        case .refused(let result):
            return UIActionResult(result: flow.finish(result), currentReaction: initial, pressed: flow.pressed)
        case .found(let found):
            bubble = found
        }
        // The window work and the transcript wait can take about 20 s, so read the reaction again before pressing.
        let current: TapbackKind?
        do {
            current = try source.currentUserReaction(messageGUID: target.guid, part: 0)
        } catch {
            return UIActionResult(result: flow.finish(UIResults.readFailed), currentReaction: initial,
                                  pressed: flow.pressed)
        }
        if Self.nothingToChange(request, current: current) {
            return UIActionResult(result: flow.finish(ActionResult(.already)), currentReaction: current,
                                  pressed: flow.pressed)
        }
        guard bubble.actionNames.contains(actionName) else {
            return UIActionResult(result: flow.finish(ActionResult(.unsupported)), currentReaction: current,
                                  pressed: flow.pressed)
        }

        let snapshot: Int64
        do { snapshot = try source.maxMessageRowID() } catch {
            return UIActionResult(result: flow.finish(UIResults.readFailed), currentReaction: current,
                                  pressed: flow.pressed)
        }
        do {
            try recorder.willInvoke(InvocationFacts(snapshotRowID: snapshot, targetGUID: target.guid, targetPart: 0,
                                                    targetRowID: target.rowid))
        } catch {
            return UIActionResult(result: flow.finish(UIResults.journalWriteFailed), currentReaction: current,
                                  pressed: flow.pressed)
        }
        switch flow.perform(actionName, on: bubble, ax: ax) {
        case .refused(let result):
            // The final check pressed nothing, so the entry goes from `invoking` to final without `invoked`.
            return UIActionResult(result: flow.finish(result), currentReaction: current, pressed: flow.pressed)
        case .notPerformed(let error):
            try? recorder.didInvoke()
            let result = UIResults.notPerformed(error, missingAction: ActionResult(.unsupported))
            return UIActionResult(result: flow.finish(result), currentReaction: current, pressed: flow.pressed)
        case .performed:
            try? recorder.didInvoke()
        }

        let verified = waitForVerifyingRow(request, aboveRowID: snapshot, deadline: flow.verifyDeadline)
        let after = rereadReaction(request, verified: verified, fallback: current)
        return UIActionResult(result: flow.finish(ActionResult(verified ? .ok : .mayHaveCompleted)),
                              currentReaction: after, pressed: flow.pressed)
    }

    /// Reconciliation for a journal entry: one read of chat.db, never presses (section 4). `ReconcileAdapter` passes
    /// `facts.targetGUID`, `facts.targetPart` and `facts.snapshotRowID`, and `binding.tapback` and `binding.remove`.
    /// `ok` if the verifying row is there, else `may_have_completed`.
    public func verifyOnly(targetGUID: String, part: Int, aboveRowID: Int64, kind: TapbackKind,
                           remove: Bool) -> ActionResult {
        let found = (try? Self.verifyingRowExists(in: source, targetGUID: targetGUID, part: part,
                                                  aboveRowID: aboveRowID, kind: kind, remove: remove)) ?? false
        return ActionResult(found ? .ok : .mayHaveCompleted)
    }

    /// Already matching, or `--remove` of a kind that isn't set.
    static func nothingToChange(_ request: TapbackRequest, current: TapbackKind?) -> Bool {
        request.remove ? current != request.kind : current == request.kind
    }

    // MARK: - Verification

    private func waitForVerifyingRow(_ request: TapbackRequest, aboveRowID: Int64, deadline: TimeInterval) -> Bool {
        while true {
            let found = (try? Self.verifyingRowExists(in: source, targetGUID: request.target.guid, part: 0,
                                                      aboveRowID: aboveRowID, kind: request.kind,
                                                      remove: request.remove)) ?? false
            if found { return true }
            let left = deadline - clock.uptime
            if left <= 0 { return false }
            sleepPollStep(clock, interval: pollInterval, left: left)
        }
    }

    /// A from_me row above the snapshot with type `2000 + offset` (add) or `3000 + offset` (remove). An emoji add
    /// must carry the same emoji; an emoji remove may carry it or none.
    static func verifyingRowExists(in source: UITargetSource, targetGUID: String, part: Int, aboveRowID: Int64,
                                   kind: TapbackKind, remove: Bool) throws -> Bool {
        let wantedType = remove ? kind.removeType : kind.addType
        let rows = try source.reactionRows(aboveRowID: aboveRowID, targetGUID: targetGUID, part: part)
        return rows.contains { row in
            guard row.fromMe, row.rowid > aboveRowID, row.associatedType == wantedType else { return false }
            guard case .emoji(let wanted) = kind else { return true }
            guard let emoji = row.emoji else { return remove }
            return emoji.precomposedStringWithCanonicalMapping == wanted.precomposedStringWithCanonicalMapping
        }
    }

    /// The reaction after the press, from chat.db. If the read fails, the verified outcome, or the reaction before.
    private func rereadReaction(_ request: TapbackRequest, verified: Bool, fallback: TapbackKind?) -> TapbackKind? {
        do {
            return try source.currentUserReaction(messageGUID: request.target.guid, part: 0)
        } catch {
            guard verified else { return fallback }
            return request.remove ? nil : request.kind
        }
    }
}

/// `unsend` (section 4, Unsend). Owner: IMUI.
///
/// Checks the 2-minute window from the row's date after approval, when leaving the queue, before `willInvoke`, and
/// once more as the press's final check, which the AX driver runs after its own description and action-name reads
/// and after the window recheck, right before `AXUIElementPerformAction` (`expired`). Calls
/// `recorder.willInvoke` with the target GUID, part and ROWID, presses "Undo Send", runs the 1 s
/// visibility poll, then reads until 10 s after the press for date_edited set and an empty body: `ok`, else
/// `may_have_completed`. A missing action name is `unsupported`, or `expired` if the window closed. Other AX errors
/// that prove nothing ran map as in `TapbackRunner`. A chat that isn't the one selected chat in Messages is
/// `busy: chat not open in Messages`, with nothing pressed and no `willInvoke`.
///
/// IMBridge runs the check after approval with `ActionWindows.undoSendOpen`; `run` starts when the request leaves
/// the queue. Incoming, group, multipart and non-text targets are `unsupported_target`. A message chat.db already
/// shows as unsent is `already`.
public final class UnsendRunner {
    public let ax: MessagesAXDriving
    public let windows: HiddenWindowManager
    public let targeting: ChatTargeting
    public let source: UITargetSource
    public let clock: Clock
    /// How often chat.db is read while waiting for the unsent state.
    public var pollInterval: TimeInterval = 0.25

    public init(ax: MessagesAXDriving, windows: HiddenWindowManager, targeting: ChatTargeting, source: UITargetSource,
                clock: Clock) {
        self.ax = ax
        self.windows = windows
        self.targeting = targeting
        self.source = source
        self.clock = clock
    }

    public func run(target: MessageTargetInfo, chat: ResolvedChat, queueDeadline: TimeInterval,
                    recorder: InvocationRecorder) -> UIActionResult {
        func early(_ result: ActionResult) -> UIActionResult {
            UIActionResult(result: result, currentReaction: nil, pressed: false)
        }
        if target.isGroupChat || target.canonical.isGroup || !target.fromMe {
            return early(ActionResult(.unsupportedTarget))
        }
        if target.isUnsent { return early(ActionResult(.already)) }
        if let state = try? source.editState(rowid: target.rowid), Self.isUnsent(state) {
            return early(ActionResult(.already))
        }
        if let refusal = UIResults.unsupportedTarget(target) { return early(refusal) }
        // Leaving the queue.
        guard windowOpen(target) else { return early(ActionResult(.expired)) }

        var flow = HiddenActionFlow(windows: windows, targeting: targeting)
        let bubble: BubbleInfo
        switch flow.reachBubble(chat: chat, target: target, queueDeadline: queueDeadline) {
        case .refused(let result):
            return UIActionResult(result: flow.finish(result), currentReaction: nil, pressed: flow.pressed)
        case .found(let found):
            bubble = found
        }
        func after(_ result: ActionResult) -> UIActionResult {
            UIActionResult(result: flow.finish(result), currentReaction: nil, pressed: flow.pressed)
        }
        guard bubble.actionNames.contains(UINames.undoSend) else {
            return after(ActionResult(windowOpen(target) ? .unsupported : .expired))
        }
        let snapshot: Int64
        do { snapshot = try source.maxMessageRowID() } catch { return after(UIResults.readFailed) }
        // Before the journal write, so a window already closed writes no `invoking`.
        guard windowOpen(target) else { return after(ActionResult(.expired)) }
        do {
            try recorder.willInvoke(InvocationFacts(snapshotRowID: snapshot, targetGUID: target.guid, targetPart: 0,
                                                    targetRowID: target.rowid))
        } catch {
            return after(UIResults.journalWriteFailed)
        }
        // The journal flush, the window recheck and the driver's own reads of the bubble can block past the window's
        // end, so it is checked again after all of them, as the press's final check. A refusal there, `expired` or a
        // window rule, pressed nothing, so the entry goes from `invoking` to final without `invoked`, and none of
        // those results hold the key, as an edit whose window closes after `willInvoke` does.
        switch flow.perform(UINames.undoSend, on: bubble, ax: ax, lastCheck: {
            windowOpen(target) ? nil : ActionResult(.expired)
        }) {
        case .refused(let result):
            return after(result)
        case .notPerformed(let error):
            try? recorder.didInvoke()
            let missing = ActionResult(windowOpen(target) ? .unsupported : .expired)
            return after(UIResults.notPerformed(error, missingAction: missing))
        case .performed:
            try? recorder.didInvoke()
        }

        let deadline = flow.verifyDeadline
        while true {
            if verifyOnly(rowid: target.rowid).code == .ok { return after(ActionResult(.ok)) }
            let left = deadline - clock.uptime
            if left <= 0 { return after(ActionResult(.mayHaveCompleted)) }
            sleepPollStep(clock, interval: pollInterval, left: left)
        }
    }

    /// Reconciliation: one read of the row at `facts.targetRowID`, never presses. `ok` if date_edited is set and the
    /// body is empty, else `may_have_completed`.
    public func verifyOnly(rowid: Int64) -> ActionResult {
        guard let state = (try? source.editState(rowid: rowid)).flatMap({ $0 }) else {
            return ActionResult(.mayHaveCompleted)
        }
        return ActionResult(Self.isUnsent(state) ? .ok : .mayHaveCompleted)
    }

    static func isUnsent(_ state: EditStateProbe) -> Bool {
        state.dateEditedNs != 0 && TextNorm.matchKey(state.body).isEmpty
    }

    private func windowOpen(_ target: MessageTargetInfo) -> Bool {
        ActionWindows.undoSendOpen(rowDateNs: target.dateNs, now: clock.now)
    }
}

/// Undo Send and edit windows, counted from the row's date (section 2).
///
/// A window is open while less than its length has passed since the row's date, and closed from the exact boundary
/// on: 120 s after the row, Undo Send is closed. The comparison runs in integer nanoseconds.
public enum ActionWindows {
    public static func undoSendOpen(rowDateNs: AppleNanos, now: Date) -> Bool {
        isOpen(rowDateNs: rowDateNs, now: now, length: Limits.undoSendWindow)
    }

    public static func editOpen(rowDateNs: AppleNanos, now: Date) -> Bool {
        isOpen(rowDateNs: rowDateNs, now: now, length: Limits.editWindow)
    }

    static func isOpen(rowDateNs: AppleNanos, now: Date, length: TimeInterval) -> Bool {
        let elapsed = AppleTime.nanos(from: now) &- rowDateNs
        return elapsed < Int64(length * 1_000_000_000)
    }
}

/// What `HiddenActionFlow.perform` found at the press.
enum PressOutcome {
    /// The action ran, or an AX error came back that doesn't prove it didn't.
    case performed
    /// The error proves the action didn't run.
    case notPerformed(AXDriveError)
    /// The press's final check failed (`HiddenWindowManager.recheck` or the caller's `lastCheck`), so nothing ran
    /// and the runner doesn't call `didInvoke`.
    case refused(ActionResult)
}

/// What a hidden press's final check throws to stop the press, with the result to return.
struct PressRefusal: Error {
    let result: ActionResult
}

/// The part every hidden UI action shares: window rules, the chat check, the bubble lookup, the named-action press,
/// and the closing notes. `selectChat` presses nothing, so only the named-action press brings the visibility poll
/// and the mark-read note.
struct HiddenActionFlow {
    let windows: HiddenWindowManager
    let targeting: ChatTargeting
    /// Set once the named action ran, or came back with an AX error that doesn't prove it didn't. Only then does
    /// `finish` add the visibility note and the mark-read note. A refusal at the press's final check and an error
    /// that proves nothing ran leave it false.
    private(set) var pressed = false
    /// `uptime` when the named action returned plus `Limits.uiVerifyTimeout`. Verification reads until then.
    private(set) var verifyDeadline: TimeInterval = 0
    private var notes: [ResultNote] = []
    /// The visibility poll that ran right after the named action, so `finish` doesn't poll again.
    private var pollAfterAction: VisibilityCheck?

    init(windows: HiddenWindowManager, targeting: ChatTargeting) {
        self.windows = windows
        self.targeting = targeting
    }

    /// Window rules, then `selectChat`, then `findBubble`.
    mutating func reachBubble(chat: ResolvedChat, target: MessageTargetInfo, queueDeadline: TimeInterval) -> BubbleLookup {
        let prep = windows.prepare(queueDeadline: queueDeadline)
        notes.append(contentsOf: prep.notes)
        if let early = prep.early { return .refused(early) }
        // `selectChat` presses nothing, so a refusal there, `busy: chat not open in Messages` included, and the
        // results up to the bubble press leave `pressed` false. A lock or a second window during its list wait makes
        // the live AX reads come back empty or fail, which it reports as `not_loaded`, so that refusal runs the
        // window recheck and its busy line wins, as in foreground step 1.
        if case .refused(let result) = targeting.selectChat(chat) {
            if result.code == .notLoaded, let busy = windows.recheck() { return .refused(busy) }
            return .refused(result)
        }
        return targeting.findBubble(target)
    }

    /// Runs the named action, then the 1 s visibility poll right away, so a window that shows at the press is seen
    /// before verification starts. Sets `verifyDeadline` from the moment the action returned. The press's final
    /// check, which the driver runs after its own reads of the bubble, checks the window rules again and then
    /// `lastCheck`. If Messages is no longer hidden with one window, or `lastCheck` returns a result, it presses
    /// nothing and returns `refused` with that result.
    mutating func perform(_ action: String, on bubble: BubbleInfo, ax: MessagesAXDriving,
                          lastCheck: () -> ActionResult? = { nil }) -> PressOutcome {
        let windows = self.windows
        var outcome = PressOutcome.performed
        do {
            try ax.perform(action: action, on: bubble.ref, finalCheck: {
                if let busy = windows.recheck() { throw PressRefusal(result: busy) }
                if let stop = lastCheck() { throw PressRefusal(result: stop) }
            })
        } catch let refusal as PressRefusal {
            return .refused(refusal.result)
        } catch let error as AXDriveError where !UIResults.mayHaveActed(error) {
            outcome = .notPerformed(error)
        } catch {}
        // An error that proves the action didn't run pressed nothing, so `finish` adds no note for it.
        if case .performed = outcome { pressed = true }
        verifyDeadline = windows.clock.uptime + Limits.uiVerifyTimeout
        pollAfterAction = windows.visibilityCheck()
        return outcome
    }

    /// Adds the launch notes, and after any press the visibility note and the mark-read note. The 1 s poll runs here
    /// unless it already ran right after the named action.
    func finish(_ result: ActionResult) -> ActionResult {
        var closing = notes
        if pressed {
            let check = pollAfterAction ?? windows.visibilityCheck()
            if check.becameVisible { closing.append(.messagesBecameVisible) }
            closing.append(.mayHaveMarkedRead)
        }
        return result.adding(closing)
    }
}
