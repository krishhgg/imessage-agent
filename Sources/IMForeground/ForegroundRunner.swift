import Foundation
import IMCore
import IMPolicy
import IMSend
import IMStore
import IMUI

/// Check names for `aborted: <check>` (DESIGN.md section 4 step 5).
enum ForegroundCheck {
    /// The item to press was missing or disabled, the press failed, or a key couldn't be posted.
    static let press = "press"
    /// Step 4's view check. For a reply, a failed read, no thread view or a thread view with no parent bubble (a
    /// parent bubble that doesn't match is `aborted: parent changed`). For an edit, the edit field, its owner and the
    /// chat's signature.
    static let view = "view"
    /// The field doesn't hold exactly the intended text, or the write failed.
    static let field = "field"
    /// An AX read a step 1 check needs failed, so the check couldn't run.
    static let axRead = "AX read"
    /// A chat.db read a step 1 check needs failed.
    static let databaseRead = "chat.db read"
}

/// Poll intervals. DESIGN.md fixes the windows, not how often they're read. Powers of two keep `FakeClock` sums
/// exact at window edges.
enum ForegroundTiming {
    static let poll: TimeInterval = 1.0 / 64.0
    /// How long one cleanup Escape gets to take effect before the next.
    static let escapeSettle: TimeInterval = 0.5
    static let verifyPoll: TimeInterval = 0.25
}

extension ActionResult {
    static func abortedCheck(_ check: String) -> ActionResult { ActionResult(.aborted(.check(check))) }
}

/// The error lines this module returns. Error lines end in ` fix: <fix>` (section 5, Output). Both are IMCore's
/// `Results.swift` values, which IMSend and IMUI return too.
enum ForegroundResults {
    /// `willInvoke` threw, so nothing was pressed and nothing holds the key.
    static let journalWriteFailed = ActionResult.journalWriteFailed
    static let foregroundModeOff = ActionResult.foregroundModeOff
}

/// One run of the machine. Every value here belongs to this run only, so concurrent runs share nothing but the
/// injected objects.
final class ForegroundRunner {
    enum Step {
        /// Return was posted.
        case returned
        /// An ownership check failed.
        case takeover
        /// A bridge-owned check failed with this result.
        case failed(ActionResult)
    }

    enum Cleanup {
        case done([ResultNote])
        case takeover
    }

    /// What a final check (`AXFinalCheck`) throws to stop an AX press or write: the step the run takes instead.
    struct FinalCheckStop: Error {
        let step: Step
    }

    let env: ForegroundEnvironment
    let run: ForegroundRun
    let recorder: InvocationRecorder
    let owner: OwnershipGuard
    private let publish: (ForegroundPhase) -> Void

    private var lastPhase: ForegroundPhase = .idleGate
    /// The phase the last `phase` marker named, so a phase entered twice in a row gets one marker.
    private var markedPhase: ForegroundPhase?
    private var ticket: QueueTicket?
    /// When `execute` started. `run.queueDeadline` minus this is the queue budget.
    private var startedAt: TimeInterval = 0
    /// The queue deadline, set when the machine first asks for the queue (`takeQueue`).
    private var queueDeadline: TimeInterval?
    private var pid: Int32 = 0
    private var earlierApp: FrontApp?
    private var snapshot = SendSnapshot(maxRowID: 0, requestedAt: Date(timeIntervalSince1970: 0))
    private var dateEditedBefore: AppleNanos = 0
    /// Set right before `open -b`. Every result from then on carries the mark-read note, since the chat step 1
    /// found selected is the one Messages shows in front. Step 1 presses nothing, so its refusals carry no note.
    private var chatOpened = false
    /// Notes from the window rules, such as `error: Messages became visible`, added to every result after them.
    private var windowNotes: [ResultNote] = []
    private var tFront: TimeInterval = 0
    private var field: AXRef?
    private var fieldEarlier = ""
    /// The main composer's value at step 1, which requires it empty. A threaded reply must leave it so.
    private var composerEarlier = ""
    /// The main composer step 1 read. The reply never writes it.
    private var mainComposer: AXRef?
    /// The edit's signature and bound row, read from chat.db in step 1 so step 4 reads AX only.
    private var editExpectation: SelectionExpectation?
    private var wroteField = false
    /// The field was restored or reset (or that was attempted). No further write to it.
    private var fieldSettled = false
    private var agentTextMayRemain = false
    private var turnedModeOff = false
    private var sentGUID: String?

    init(env: ForegroundEnvironment, run: ForegroundRun, recorder: InvocationRecorder,
         publish: @escaping (ForegroundPhase) -> Void) {
        self.env = env
        self.run = run
        self.recorder = recorder
        self.owner = OwnershipGuard(input: env.input, app: env.app, clock: env.clock)
        self.publish = publish
    }

    private var intendedText: String {
        switch run.action {
        case .edit(_, let newText): return newText
        case .threadedReply(_, let text): return text
        }
    }

    // MARK: - Steps 2, 1 and 3 up to `open -b`

    func execute() -> ForegroundOutcome {
        startedAt = env.clock.uptime
        let idleDeadline = startedAt + Limits.idleGateTimeout
        enter(.idleGate)
        guard env.mode.isForegroundModeOn else { return outcome(ForegroundResults.foregroundModeOff) }
        var retaking = false
        while true {
            enter(.idleGate)
            guard waitForIdle(until: idleDeadline) else { return outcome(ActionResult(.busy(.userActive))) }
            if let early = takeQueue(idleDeadline: retaking ? idleDeadline : nil) { return outcome(early) }
            if let early = onLeavingQueue() { return outcome(early) }
            enter(.preconditions)
            if let early = preconditions() { return outcome(early) }
            enter(.activationCheck)
            if retaking, env.clock.uptime > idleDeadline {
                releaseTicket()
                return outcome(ActionResult(.busy(.userActive)))
            }
            // The front app to restore later is read before the checks, so no read sits between them and `open -b`.
            earlierApp = env.app.frontmostApp()
            owner.markActivationCheck()
            if sinceLastInput() < Limits.idleThreshold {
                releaseTicket()
                retaking = true
                continue
            }
            if case .edit(let target, _) = run.action, !editWindowOpen(target) {
                return outcome(ActionResult(.expired))
            }
            return activate()
        }
    }

    /// Step 2. Waits until no input for `Limits.idleThreshold`, checking once more at the deadline.
    private func waitForIdle(until deadline: TimeInterval) -> Bool {
        var announced = false
        while true {
            let since = sinceLastInput()
            if since >= Limits.idleThreshold { return true }
            let left = deadline - env.clock.uptime
            if left <= 0 { return false }
            if !announced {
                env.progress(.waitingForIdle)
                announced = true
            }
            env.clock.sleep(min(max(Limits.idleThreshold - since, ForegroundTiming.poll), left))
        }
    }

    /// NaN or negative readings count as input right now.
    private func sinceLastInput() -> TimeInterval {
        let since = env.input.secondsSinceLastInput()
        return since.isNaN || since < 0 ? 0 : since
    }

    /// The first take waits up to the queue deadline. Time at the idle gate isn't queue time (section 3 item 3), so
    /// the deadline starts counting here: the queue budget the bridge gave (`run.queueDeadline` minus the start of
    /// `run`) from the first ask. A retake after a failed activation check keeps that deadline and also stays inside
    /// the idle gate's 30 s, and running out of that gives `busy: user active`.
    private func takeQueue(idleDeadline: TimeInterval?) -> ActionResult? {
        let now = env.clock.uptime
        let deadline = queueDeadline ?? now + max(0, run.queueDeadline - startedAt)
        queueDeadline = deadline
        var timeout = max(0, deadline - now)
        var idleBound = false
        if let idleDeadline, idleDeadline - now < timeout {
            timeout = max(0, idleDeadline - now)
            idleBound = true
        }
        if env.queue.isHeld { env.progress(.queued) }
        guard let taken = env.queue.acquire(timeout: timeout) else {
            return ActionResult(idleBound ? .busy(.userActive) : .busy(.queue))
        }
        ticket = taken
        return nil
    }

    private func onLeavingQueue() -> ActionResult? {
        guard env.mode.isForegroundModeOn else { return ForegroundResults.foregroundModeOff }
        if case .edit(let target, _) = run.action, !editWindowOpen(target) { return ActionResult(.expired) }
        return nil
    }

    /// Step 1, on the hidden window, holding the queue.
    private func preconditions() -> ActionResult? {
        let window = env.windowRules.prepare(queueDeadline: queueDeadline ?? run.queueDeadline)
        for note in window.notes where !windowNotes.contains(note) { windowNotes.append(note) }
        if let early = window.early { return early }
        let state = env.app.state()
        guard state.isRunning, let messagesPID = state.pid, messagesPID > 0 else { return ActionResult(.noHiddenWindow) }
        guard state.isHidden, !state.isFrontmost else { return .messagesOpen }
        pid = messagesPID

        // `selectChat` presses no row. A chat that isn't the one selected chat is `busy: chat not open in Messages`,
        // returned like the other step 1 refusals, with nothing pressed and no mark-read note.
        if case .refused(let early) = env.targeting.selectChat(run.chat) { return early }

        do {
            guard let composer = try env.ax.composer() else { return .abortedCheck(ForegroundCheck.axRead) }
            guard composer.value.isEmpty else { return ActionResult(.busy(.draftInMessages)) }
            composerEarlier = composer.value
            mainComposer = composer.ref
            // Two edit fields showing means an edit is in progress, though neither can be named the open one.
            let editOpen: Bool
            do {
                editOpen = try env.ax.editField() != nil
            } catch AXDriveError.severalEditFields {
                editOpen = true
            }
            let threadOpen = try env.ax.threadView() != nil
            if editOpen || threadOpen { return ActionResult(.busy(.editInProgress)) }
        } catch {
            return .abortedCheck(ForegroundCheck.axRead)
        }

        switch run.action {
        case .threadedReply(let parent, _):
            do {
                guard try env.source.newestIncoming(for: run.chat)?.guid == parent.guid else {
                    return ActionResult(.aborted(.parentChanged))
                }
            } catch {
                return .abortedCheck(ForegroundCheck.databaseRead)
            }
            // While Messages is hidden the item can read Reply to Message… (S3). Either title shows it exists, and
            // after t_front only the exact Reply to Last Message… item is waited for and pressed.
            do {
                guard try env.ax.menuItem(titled: UINames.replyToLastMessage) != nil
                        || env.ax.menuItem(titled: UINames.replyToMessage) != nil else {
                    return ActionResult(.unsupported)
                }
            } catch {
                return .abortedCheck(ForegroundCheck.axRead)
            }
        case .edit(let target, _):
            do {
                guard let state = try env.source.editState(rowid: target.rowid) else {
                    return .abortedCheck(ForegroundCheck.databaseRead)
                }
                dateEditedBefore = state.dateEditedNs
            } catch {
                return .abortedCheck(ForegroundCheck.databaseRead)
            }
            switch env.targeting.findBubble(target) {
            case .refused(let early):
                return early
            case .found(let bubble):
                guard bubble.actionNames.contains(UINames.edit) else {
                    return ActionResult(editWindowOpen(target) ? .unsupported : .expired)
                }
            }
            guard let expected = env.targeting.selectionExpectation(run.chat, excluding: target.rowid) else {
                return .abortedCheck(ForegroundCheck.databaseRead)
            }
            editExpectation = expected
        }

        do {
            snapshot = SendSnapshot(maxRowID: try env.rows.maxMessageRowID(), requestedAt: env.clock.now)
        } catch {
            return .abortedCheck(ForegroundCheck.databaseRead)
        }
        return nil
    }

    // MARK: - Step 3 from `open -b`, steps 4 and 5

    private func activate() -> ForegroundOutcome {
        enter(.activating)
        let tOpen = env.clock.uptime
        chatOpened = true
        // `activateForeground` returns once `open` has started, so the front app is polled while `open` runs.
        // `t_front` is when the first read that shows Messages frontmost started. A read that ends after the 1 s
        // doesn't count, so a call or read that blocked can't move either limit.
        _ = env.app.activateForeground()
        guard let front = firstSeen(until: tOpen + Limits.activationTimeout, { env.app.isFrontmost() }) else {
            return lateActivation(tOpen: tOpen)
        }
        tFront = front
        owner.markFront()
        // Messages is in front, so `open` has done its job. Left running, it could bring Messages forward again after
        // the hide.
        (env.app as? ActivationEnding)?.endActivation()
        enter(.front)

        let step: Step
        switch run.action {
        case .edit(let target, let newText): step = editUntilReturn(target: target, newText: newText)
        case .threadedReply(let parent, let text): step = replyUntilReturn(parent: parent, text: text)
        }
        switch step {
        case .takeover: return outcome(takeoverResult())
        case .failed(let failure): return bridgeOwnedFailure(failure)
        case .returned: break
        }

        enter(.finishing)
        let cleanup = finish()
        enter(.verifying)
        var result = verify()
        switch cleanup {
        case .done(let notes): result.notes += notes
        case .takeover: result.notes.append(.userTookOver)
        }
        enter(.done)
        return outcome(result)
    }

    /// Messages wasn't frontmost within 1 s of `open -b`. Posts nothing and keeps the queue for 5 s more.
    private func lateActivation(tOpen: TimeInterval) -> ForegroundOutcome {
        enter(.lateActivationWatch)
        let watchEnd = tOpen + Limits.activationTimeout + Limits.lateActivationWatch
        var cameForward = false
        var tookOver = false
        _ = waitFor(until: watchEnd) {
            if !owner.owns() {
                tookOver = true
                return true
            }
            if env.app.isFrontmost() {
                cameForward = true
                return true
            }
            return false
        }
        // An `open` still running now could bring Messages forward after the result, with the queue released.
        (env.app as? ActivationEnding)?.endActivation()
        if tookOver { return outcome(takeoverResult()) }
        if cameForward {
            owner.markFront()
            switch hideAndRestore() {
            case .takeover: return outcome(takeoverResult())
            case .done(let notes): return outcome(ActionResult(.aborted(.lateActivation), notes: notes))
            }
        }
        if !env.app.state().isHidden {
            switch hideAndRestore() {
            case .takeover: return outcome(takeoverResult())
            case .done(let notes): return outcome(ActionResult(.aborted(.activation), notes: notes))
            }
        }
        return outcome(ActionResult(.aborted(.activation)))
    }

    private func editUntilReturn(target: MessageTargetInfo, newText: String) -> Step {
        guard owner.owns() else { return .takeover }
        guard withinDeadline() else { return .failed(ActionResult(.aborted(.deadline))) }
        guard editWindowOpen(target) else { return .failed(ActionResult(.expired)) }
        // Step 1 ran the chat.db duplicate check, so inside the 3 s window the bubble is found again from AX only.
        guard case .found(let bubble) = env.targeting.findLoadedBubble(target),
              bubble.actionNames.contains(UINames.edit) else {
            return .failed(.abortedCheck(ForegroundCheck.press))
        }
        let facts = InvocationFacts(snapshotRowID: snapshot.maxRowID, targetGUID: target.guid, targetPart: 0,
                                    targetRowID: target.rowid, dateEditedBeforeNs: dateEditedBefore)
        if let failure = recordInvoking(facts) { return failure }
        guard owner.owns() else { return .takeover }
        // Again after the AX walk, the journal flush and the ownership check, any of which can block.
        guard editWindowOpen(target) else { return .failed(ActionResult(.expired)) }
        // And once more as the press's final check, after the driver's own reads of the bubble: the window, then the
        // ownership check, so input is sampled last.
        do {
            try env.ax.perform(action: UINames.edit, on: bubble.ref, finalCheck: {
                guard editWindowOpen(target) else { throw FinalCheckStop(step: .failed(ActionResult(.expired))) }
                try ownershipCheck()
            })
        } catch let stop as FinalCheckStop {
            return stop.step
        } catch {
            return .failed(.abortedCheck(ForegroundCheck.press))
        }

        var opened: FieldInfo?
        let fieldShown = waitFor(until: returnDeadline) {
            opened = try? env.ax.editField()
            return opened != nil
        }
        guard fieldShown, let editField = opened else { return .failed(ActionResult(.aborted(.deadline))) }
        if let stop = write(newText, into: editField) { return stop }

        enter(.beforeReturn)
        guard owner.owns() else { return .takeover }
        guard withinDeadline() else { return .failed(ActionResult(.aborted(.deadline))) }
        guard editWindowOpen(target) else { return .failed(ActionResult(.expired)) }
        guard let current = try? env.ax.editField(), current.ref == editField.ref,
              current.owningBubble == bubble.ref, let expected = editExpectation,
              env.targeting.verifySelected(expected) else {
            return .failed(.abortedCheck(ForegroundCheck.view))
        }
        guard (try? env.ax.readValue(of: editField.ref)) == newText else {
            return .failed(.abortedCheck(ForegroundCheck.field))
        }
        return postReturn(into: editField.ref, editTarget: target)
    }

    private func replyUntilReturn(parent: MessageTargetInfo, text: String) -> Step {
        guard owner.owns() else { return .takeover }
        guard withinDeadline() else { return .failed(ActionResult(.aborted(.deadline))) }
        var item: MenuItemInfo?
        let enabled = waitFor(until: returnDeadline) {
            item = try? env.ax.menuItem(titled: UINames.replyToLastMessage)
            return item?.enabled == true
        }
        guard enabled, let menuItem = item else { return .failed(ActionResult(.aborted(.deadline))) }
        if let failure = recordInvoking(InvocationFacts(snapshotRowID: snapshot.maxRowID)) { return failure }
        guard owner.owns() else { return .takeover }
        do {
            try env.ax.press(menuItem: menuItem.ref, finalCheck: { try ownershipCheck() })
        } catch let stop as FinalCheckStop {
            return stop.step
        } catch {
            return .failed(.abortedCheck(ForegroundCheck.press))
        }

        // The reply field is the text field Messages focuses in the thread view, as in S3. The main composer is a
        // different element, and text written there would go out unthreaded on the user's next Return.
        var threadShown = false
        var opened: FieldInfo?
        let fieldShown = waitFor(until: returnDeadline) {
            guard (try? env.ax.threadView()) != nil else { return false }
            if withinDeadline() { threadShown = true }
            opened = try? env.ax.focusedField()
            return opened != nil
        }
        // A thread view or field first read after the deadline missed it.
        guard threadShown, fieldShown || opened == nil else { return .failed(ActionResult(.aborted(.deadline))) }
        guard fieldShown, let replyField = opened, replyField.ref != mainComposer else {
            return .failed(.abortedCheck(ForegroundCheck.field))
        }
        if let stop = write(text, into: replyField) { return stop }

        enter(.beforeReturn)
        guard owner.owns() else { return .takeover }
        guard withinDeadline() else { return .failed(ActionResult(.aborted(.deadline))) }
        let newest: MessageTargetInfo?
        do {
            newest = try env.source.newestIncoming(for: run.chat)
        } catch {
            return .failed(.abortedCheck(ForegroundCheck.view))
        }
        guard newest?.guid == parent.guid else { return .failed(ActionResult(.aborted(.parentChanged))) }
        guard let thread = try? env.ax.threadView(), let shown = thread.parent else {
            return .failed(.abortedCheck(ForegroundCheck.view))
        }
        guard ParentBubbleMatch.matches(shown, parent: parent) else {
            return .failed(ActionResult(.aborted(.parentChanged)))
        }
        guard (try? env.ax.readValue(of: replyField.ref)) == text else {
            return .failed(.abortedCheck(ForegroundCheck.field))
        }
        let main: FieldInfo?
        do {
            main = try env.ax.composer()
        } catch {
            return .failed(.abortedCheck(ForegroundCheck.field))
        }
        if let main, main.ref != replyField.ref, main.value != composerEarlier {
            return .failed(.abortedCheck(ForegroundCheck.field))
        }
        return postReturn(into: replyField.ref, parent: parent)
    }

    /// Records the field's earlier value, then writes the text.
    private func write(_ text: String, into target: FieldInfo) -> Step? {
        field = target.ref
        fieldEarlier = target.value
        guard owner.owns() else { return .takeover }
        guard withinDeadline() else { return .failed(ActionResult(.aborted(.deadline))) }
        wroteField = true
        mark("field-set")
        do {
            try env.ax.setValue(text, of: target.ref, finalCheck: { try ownershipCheck() })
        } catch let stop as FinalCheckStop {
            // The check stopped the write, so the field holds nothing of the bridge's and the takeover leaves it.
            wroteField = false
            return stop.step
        } catch {
            return .failed(.abortedCheck(ForegroundCheck.field))
        }
        return nil
    }

    /// The ownership check as the final check of a foreground AX press or write (`AXFinalCheck`): the driver runs it
    /// after its own reads, right before the press or write. It reads the front app first and samples input last.
    private func ownershipCheck() throws {
        guard owner.owns() else { throw FinalCheckStop(step: .takeover) }
    }

    /// Return goes to whatever Messages has focused, so it is posted only while the written field still has focus and
    /// the value that read returns is exactly the intended text. Anything else is `aborted: field`. Focus is never
    /// set, because section 4 allows only value writes. After the focused-field read, which can block, a reply reads
    /// its parent again (`parentStillBound`). Then the deadline, for an edit the 15-minute window, and last the
    /// ownership check, which reads the front app and then the input state. Nothing that can block sits between that
    /// check and the key post.
    private func postReturn(into written: AXRef, editTarget: MessageTargetInfo? = nil,
                            parent: MessageTargetInfo? = nil) -> Step {
        guard owner.owns() else { return .takeover }
        guard withinDeadline() else { return .failed(ActionResult(.aborted(.deadline))) }
        guard let focused = try? env.ax.focusedField(), focused.ref == written, focused.value == intendedText else {
            return .failed(.abortedCheck(ForegroundCheck.field))
        }
        if let parent, let stop = parentStillBound(parent) { return stop }
        guard withinDeadline() else { return .failed(ActionResult(.aborted(.deadline))) }
        if let editTarget, !editWindowOpen(editTarget) { return .failed(ActionResult(.expired)) }
        guard owner.owns() else { return .takeover }
        mark("key return")
        guard env.keys.post(.returnKey, toPID: pid) else { return .failed(.abortedCheck(ForegroundCheck.press)) }
        try? recorder.didInvoke()
        return .returned
    }

    /// Step 4's parent check once more, right before Return: the thread view's parent bubble and the chat's newest
    /// incoming GUID are still the bound parent. The thread view walk comes first, because each of its AX reads can
    /// block, and the GUID last, one chat.db query, so a message that arrived during the composer walk, the
    /// focused-field read or the thread view walk changes it. Either change is `aborted: parent changed`. A read that
    /// fails, or a thread view with no parent bubble, is `aborted: view`, as at step 4.
    private func parentStillBound(_ parent: MessageTargetInfo) -> Step? {
        guard let thread = try? env.ax.threadView(), let shown = thread.parent else {
            return .failed(.abortedCheck(ForegroundCheck.view))
        }
        guard ParentBubbleMatch.matches(shown, parent: parent) else {
            return .failed(ActionResult(.aborted(.parentChanged)))
        }
        let newest: MessageTargetInfo?
        do {
            newest = try env.source.newestIncoming(for: run.chat)
        } catch {
            return .failed(.abortedCheck(ForegroundCheck.view))
        }
        guard newest?.guid == parent.guid else { return .failed(ActionResult(.aborted(.parentChanged))) }
        return nil
    }

    /// `willInvoke` must return before the press. If it throws, nothing is pressed.
    private func recordInvoking(_ facts: InvocationFacts) -> Step? {
        guard owner.owns() else { return .takeover }
        do {
            try recorder.willInvoke(facts)
            return nil
        } catch {
            return .failed(ForegroundResults.journalWriteFailed)
        }
    }

    private var returnDeadline: TimeInterval { tFront + Limits.returnDeadline }

    private func withinDeadline() -> Bool { env.clock.uptime <= returnDeadline }

    // MARK: - Step 5 paths

    /// Takeover before Return: no key events, no hide, no focus change, at most one AX write.
    private func takeoverResult() -> ActionResult {
        enter(.takeover)
        resetFieldOnTakeover()
        var notes: [ResultNote] = []
        if agentTextMayRemain { notes.append(.agentTextMayRemain) }
        notes.append(.axState(axStateDescription()))
        return ActionResult(.aborted(.userTookOver), notes: notes)
    }

    /// The one write a takeover may make: back to the earlier value, only if the field still holds exactly the
    /// bridge's text. Anything else is left alone. Its marker is `field-reset`, never a `key` marker.
    private func resetFieldOnTakeover() {
        guard wroteField, !fieldSettled, let field else { return }
        fieldSettled = true
        let current: String
        do {
            current = try env.ax.readValue(of: field)
        } catch {
            agentTextMayRemain = true
            return
        }
        if current == intendedText {
            mark("field-reset")
            // The one write allowed after a failed ownership check, so it has nothing left to check.
            try? env.ax.setValue(fieldEarlier, of: field, finalCheck: {})
            if (try? env.ax.readValue(of: field)) != fieldEarlier { agentTextMayRemain = true }
        } else if current != fieldEarlier {
            agentTextMayRemain = true
        }
    }

    /// Bridge-owned failure: restore the field, Escape until no edit field and no thread view, then step 6.
    /// Step 7 is skipped. Any failed ownership check on the way turns it into a takeover.
    private func bridgeOwnedFailure(_ failure: ActionResult) -> ForegroundOutcome {
        enter(.bridgeOwnedCleanup)
        if wroteField, !fieldSettled, let field {
            if (try? env.ax.readValue(of: field)) != fieldEarlier {
                guard owner.owns() else { return outcome(takeoverResult()) }
                fieldSettled = true
                mark("field-restore")
                do {
                    try env.ax.setValue(fieldEarlier, of: field, finalCheck: { try ownershipCheck() })
                } catch is FinalCheckStop {
                    // Nothing was written, so the takeover makes its one reset as it would before the restore.
                    fieldSettled = false
                    return outcome(takeoverResult())
                } catch {}
                if (try? env.ax.readValue(of: field)) != fieldEarlier { agentTextMayRemain = true }
            } else {
                fieldSettled = true
            }
        }

        var escapes = 0
        while !showsNoEditOrThread() {
            guard escapes < Limits.maxEscapePresses else {
                turnModeOff(reason: ResultNote.messagesLeftInEditMode.wire)
                return outcome(withCleanupNotes(failure, [.messagesLeftInEditMode]))
            }
            guard owner.owns() else { return outcome(takeoverResult()) }
            mark("key escape")
            _ = env.keys.post(.escape, toPID: pid)
            escapes += 1
            _ = waitFor(until: env.clock.uptime + ForegroundTiming.escapeSettle) { showsNoEditOrThread() }
        }

        switch finish() {
        case .takeover: return outcome(takeoverResult())
        case .done(let notes): return outcome(withCleanupNotes(failure, notes))
        }
    }

    private func withCleanupNotes(_ result: ActionResult, _ notes: [ResultNote]) -> ActionResult {
        var result = result
        if agentTextMayRemain, !result.notes.contains(.agentTextMayRemain) { result.notes.append(.agentTextMayRemain) }
        result.notes += notes
        return result
    }

    // MARK: - Step 6

    /// Escape (at most 3) until the main transcript shows, then hide and restore focus.
    private func finish() -> Cleanup {
        enter(.finishing)
        var escapes = 0
        while !showsMainTranscript() {
            guard escapes < Limits.maxEscapePresses else {
                turnModeOff(reason: ResultNote.messagesLeftOpen.wire)
                return .done([.messagesLeftOpen])
            }
            guard owner.owns() else { return .takeover }
            mark("key escape")
            _ = env.keys.post(.escape, toPID: pid)
            escapes += 1
            _ = waitFor(until: env.clock.uptime + ForegroundTiming.escapeSettle) { showsMainTranscript() }
        }
        return hideAndRestore()
    }

    /// Hide, poll `isHidden` for 1 s, then the focus restore. Used by step 6 and the late-activation path. A read
    /// that shows Messages hidden counts even if it returns after the 1 s, because Messages is hidden either way.
    private func hideAndRestore() -> Cleanup {
        guard owner.owns() else { return .takeover }
        mark("hide")
        env.app.hide()
        owner.markHidden()
        var hidden = false
        _ = waitFor(until: env.clock.uptime + Limits.hidePoll) {
            hidden = env.app.state().isHidden
            return hidden
        }
        guard hidden else { return .done([.messagesLeftOpen]) }
        return restoreFocus()
    }

    /// The ownership check runs here even when no reopen turns out to be needed, so input before the focus restore
    /// always shows in the result. NSWorkspace moves the front app off Messages a run-loop turn or more after
    /// `isHidden` turns true, so the restore first waits up to `Limits.focusRestoreWait` for an app other than
    /// Messages to be in front, with the ownership check before each read. Only then does it decide between done and
    /// the reopen, and only after that does it name the app in front. The check runs again right before the reopen.
    private func restoreFocus() -> Cleanup {
        guard owner.owns() else { return .takeover }
        guard let earlier = earlierApp else { return .done([]) }
        var front: FrontApp?
        var tookOver = false
        _ = waitFor(until: env.clock.uptime + Limits.focusRestoreWait) {
            guard owner.owns() else {
                tookOver = true
                return true
            }
            front = env.app.frontmostApp()
            return front.map { !isMessages($0) } ?? false
        }
        if tookOver { return .takeover }
        if isEarlierApp(front) { return .done([]) }
        if earlier.hasWindows, let bundleID = earlier.bundleID {
            guard owner.owns() else { return .takeover }
            mark("focus-restore \(bundleID)")
            _ = env.app.reopen(bundleID: bundleID)
            _ = waitFor(until: env.clock.uptime + Limits.focusRestoreWait) { isEarlierApp(env.app.frontmostApp()) }
            front = env.app.frontmostApp()
        }
        if isEarlierApp(front) { return .done([]) }
        if let front { return .done([.frontApp(front.name)]) }
        return .done([])
    }

    private func isEarlierApp(_ app: FrontApp?) -> Bool {
        guard let app, let earlierApp else { return false }
        return app.pid == earlierApp.pid
    }

    private func isMessages(_ app: FrontApp) -> Bool {
        app.pid == pid || app.bundleID == AppIdentity.messagesBundleID
    }

    // MARK: - Step 7

    private func verify() -> ActionResult {
        switch run.action {
        case .edit(let target, let newText):
            return env.verifier.verifyEdit(rowid: target.rowid, dateEditedBeforeNs: dateEditedBefore,
                                           newTextDigest: TextNorm.textDigest(newText),
                                           timeout: Limits.foregroundVerifyTimeout)
        case .threadedReply(let parent, let text):
            let checked = env.verifier.verifyReplyRow(snapshot: snapshot, chat: run.chat,
                                                      textDigest: TextNorm.textDigest(text),
                                                      parentGUID: parent.guid,
                                                      timeout: Limits.foregroundVerifyTimeout)
            sentGUID = checked.rowGUID
            if case .failed(.sentWithWrongParent) = checked.result.code {
                turnModeOff(reason: checked.result.code.wire)
            }
            return checked.result
        }
    }

    // MARK: - Helpers

    private func enter(_ next: ForegroundPhase) {
        lastPhase = next
        publish(next)
        if markedPhase != next {
            markedPhase = next
            mark("phase \(next.rawValue)")
        }
    }

    /// A release-test marker for the step that comes next (`ForegroundEnvironment.marker`).
    private func mark(_ event: String) {
        env.marker?(event)
    }

    private func outcome(_ result: ActionResult) -> ForegroundOutcome {
        var result = result
        for note in windowNotes where !result.notes.contains(note) { result.notes.append(note) }
        if chatOpened, !result.notes.contains(.mayHaveMarkedRead) { result.notes.append(.mayHaveMarkedRead) }
        return ForegroundOutcome(result: result, lastPhase: lastPhase, turnedModeOff: turnedModeOff,
                                 sentGUID: sentGUID, ticket: ticket)
    }

    private func releaseTicket() {
        if let held = ticket { env.queue.release(held) }
        ticket = nil
    }

    private func turnModeOff(reason: String) {
        env.mode.turnForegroundOff(reason: reason)
        turnedModeOff = true
    }

    private func editWindowOpen(_ target: MessageTargetInfo) -> Bool {
        env.editWindowOpen(target.dateNs, env.clock.now)
    }

    /// Checks `condition` until it holds or `deadline` passes, and once more at the deadline.
    private func waitFor(until deadline: TimeInterval, _ condition: () -> Bool) -> Bool {
        firstSeen(until: deadline, condition) != nil
    }

    /// The uptime when the first check that saw `condition` hold started, checking until `deadline` and once more
    /// at it. A slow check can't make the condition look later than it was, and a check that returns after
    /// `deadline` doesn't count even if it holds.
    private func firstSeen(until deadline: TimeInterval, _ condition: () -> Bool) -> TimeInterval? {
        while true {
            let started = env.clock.uptime
            let holds = condition()
            let now = env.clock.uptime
            if holds { return now <= deadline ? started : nil }
            if now >= deadline { return nil }
            env.clock.sleep(min(ForegroundTiming.poll, deadline - now))
        }
    }

    /// A read error counts as still showing.
    private func showsNoEditOrThread() -> Bool {
        do {
            return try env.ax.editField() == nil && env.ax.threadView() == nil
        } catch {
            return false
        }
    }

    /// A read error counts as not showing.
    private func showsMainTranscript() -> Bool {
        (try? env.ax.showsMainTranscript()) ?? false
    }

    private func axStateDescription() -> String {
        do {
            let edit: String?
            do {
                edit = try env.ax.editField() != nil ? "an edit field" : nil
            } catch AXDriveError.severalEditFields {
                edit = "more than one edit field"
            }
            let thread = try env.ax.threadView() != nil
            switch (edit, thread) {
            case (let edit?, true): return "\(edit) and a thread view"
            case (let edit?, false): return edit
            case (nil, true): return "a thread view"
            case (nil, false): return "no edit field or thread view"
            }
        } catch {
            return "no readable state"
        }
    }
}

/// Step 4's thread-view check: the parent bubble shows the bound parent's direction, NFC body and minute
/// (DESIGN.md section 4, Message and step 4). Bodies compare as `TextNorm.matchKey`, as IMUI's targeting does, so
/// whitespace at either end of the chat.db body doesn't fail the check.
public enum ParentBubbleMatch {
    public static func matches(_ bubble: BubbleInfo, parent: MessageTargetInfo,
                               timeZone: TimeZone = .current) -> Bool {
        guard bubble.fromMe == parent.fromMe else { return false }
        guard TextNorm.matchKey(bubble.text) == TextNorm.matchKey(parent.body) else { return false }
        guard let shown = hourAndMinute(in: bubble.minuteLabel) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute], from: AppleTime.date(fromNanos: parent.dateNs))
        return parts.hour == shown.hour && parts.minute == shown.minute
    }

    /// The one `h:mm`, `h:mm AM` or `HH:mm` time in a label, as a 24-hour hour and a minute. Nil when the label holds
    /// no time, more than one, or an impossible one.
    static func hourAndMinute(in label: String) -> (hour: Int, minute: Int)? {
        let spaced = label.replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
        guard let pattern = try? NSRegularExpression(pattern: "(?<![0-9])([0-9]{1,2}):([0-9]{2})(?![0-9])(\\s*([AaPp])\\.?[Mm]\\.?)?") else {
            return nil
        }
        let range = NSRange(spaced.startIndex..., in: spaced)
        let found = pattern.matches(in: spaced, range: range)
        guard found.count == 1, let match = found.first,
              let hourRange = Range(match.range(at: 1), in: spaced),
              let minuteRange = Range(match.range(at: 2), in: spaced),
              var hour = Int(spaced[hourRange]), let minute = Int(spaced[minuteRange]),
              (0...59).contains(minute) else { return nil }
        if let markRange = Range(match.range(at: 4), in: spaced) {
            guard (1...12).contains(hour) else { return nil }
            let pm = spaced[markRange].lowercased() == "p"
            hour = hour % 12 + (pm ? 12 : 0)
        } else {
            guard (0...23).contains(hour) else { return nil }
        }
        return (hour, minute)
    }
}
