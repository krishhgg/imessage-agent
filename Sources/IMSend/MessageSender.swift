import Foundation
import IMCore
import IMStore

/// One approved send, already past policy and holding the queue.
public struct SendRequest: Hashable, Sendable {
    public var chat: ResolvedChat
    public var text: String?
    public var file: FrozenFile?

    public init(chat: ResolvedChat, text: String?, file: FrozenFile?) {
        self.chat = chat
        self.text = text
        self.file = file
    }
}

public struct SendResult: Hashable, Sendable {
    /// Text first, then file, each with its own result (section 3 item 6).
    public var parts: [SendPartOutcome]
    /// GUIDs of rows the bridge sent, added to `ChatDatabase.agentSentGUIDs` so `wait` skips them.
    public var sentGUIDs: [String]

    public init(parts: [SendPartOutcome], sentGUIDs: [String]) {
        self.parts = parts
        self.sentGUIDs = sentGUIDs
    }
}

/// Performs a send through Apple Events and verifies it in chat.db (DESIGN.md section 3). Owner: IMSend.
///
/// Order of work:
/// 1. Cold start if needed (`ColdStarter`).
/// 2. Stage the file if there is one.
/// 3. Snapshot the max ROWID, then `recorder.willInvoke` with the snapshot and transfer names. If it throws, stop.
/// 4. Call `send_text` and/or `send_file` (`send_chat_text` and `send_chat_file` for a group), then
///    `recorder.didInvoke`. Each part keeps its call's outcome.
///    Each handler first checks that Messages is running, which doesn't launch it, and returns
///    `SendScripts.notRunning` without an Apple Event to Messages when it isn't. The first time a call answers that,
///    the sender runs the hidden cold start again and, once it is ready, calls the same handler once more. One retry
///    per request. The call that answered `not_running` sent nothing, so the retry isn't a second send.
/// 5. Correlate every part.
///
/// Notes on each step:
/// - A 1:1 chat is addressed by its send handle and a group by its chat.db guid (`chatGUIDs.first`). Group sends stay
///   off while `caps` reports them `untested` (section 3 item 8): IMBridge refuses the group before this runs, so no
///   Apple Event reaches Messages until release test 8's group case passes.
/// - A text that is empty after `TextNorm.matchKey` isn't a part. A request with no part, a 1:1 chat with no
///   send handle, or a group with no chat guid is `error: bad request` and nothing runs.
/// - Every result returned once the cold start is done carries `error: Messages became visible` if a window showed,
///   including `failed: Messages not ready`. That covers the cold start before a retry too.
/// - A part whose last call answered `not_running` and whose correlation matched no row is
///   `failed: Messages not ready`: nothing reached Messages, and the result doesn't hold the key.
/// - Nothing reaches Messages before `willInvoke` returns. A failed snapshot, staging or journal write sends
///   nothing and removes the staged copy.
/// - A `didInvoke` failure doesn't change the result: the send already happened and the journal's `invoking` state
///   makes crash recovery reconcile it.
/// - Text goes first, then the file, as separate Apple Events, and each part gets its own correlation result.
/// - chat.db decides each part's result, with one exception. A part whose call macOS refused with -1743
///   (`errAEEventNotPermitted`) or -1744 (`errAEEventWouldRequireUserConsent`) and whose correlation matched no row
///   (`may_have_completed` or `ghost`) is `error: Messages automation not allowed`. macOS refuses such an event
///   before it reaches Messages, so nothing was sent, a ghost row can't be this part's, and the result doesn't hold
///   the key (section 3 item 1). A refused part with one or two matched rows keeps chat.db's result. Any other error
///   outcome, such as a -1712 timeout, stays advisory. Each part is decided on its own call and its own correlation.
public final class MessageSender {
    public let scripts: AppleScriptRunning
    public let coldStart: ColdStarter
    public let staging: StagingArea
    public let correlator: SendCorrelator
    public let rows: SendRowSource
    public let clock: Clock

    /// `unsupported` for a group chat while group sends are off. IMBridge returns it before the dialog.
    public static let groupUnsupported = ActionResult(.unsupported, fix: "send to each person on their own")
    /// No part to send, or no handle to address. Error lines carry a fix (section 5, Output).
    public static let badRequest = ActionResult(.error(.message("bad request")),
                                                fix: "send text or --file to a phone number or email")
    /// `willInvoke` threw, so nothing was sent (BUILD-PLAN cross-module contracts). Nothing holds the key, so a retry
    /// runs again.
    public static let journalWriteFailed = ActionResult.journalWriteFailed
    /// The max ROWID couldn't be read, so the send couldn't be correlated and nothing was sent.
    public static let chatDBUnreadable = ActionResult(.error(.message("can't read chat.db")),
                                                      fix: "run imessage doctor")
    /// The frozen copy couldn't be staged, so nothing was sent.
    public static let stagingFailed = ActionResult(.error(.message("file staging failed")),
                                                   fix: "check that ~/Pictures/\(AppIdentity.appName) is writable")
    /// macOS refused the part's Apple Event because the bridge has no Automation grant for Messages, and no row
    /// matched it, so nothing was sent. Nothing holds the key, so a retry runs again.
    public static let automationNotAllowed = ActionResult(.error(.message("Messages automation not allowed")),
                                                          fix: "run imessage doctor")
    /// `errAEEventNotPermitted` and `errAEEventWouldRequireUserConsent`: TCC refused the event before delivery.
    static let automationRefusedErrors: Set<Int> = [-1743, -1744]

    public init(scripts: AppleScriptRunning, coldStart: ColdStarter, staging: StagingArea, correlator: SendCorrelator,
                rows: SendRowSource, clock: Clock) {
        self.scripts = scripts
        self.coldStart = coldStart
        self.staging = staging
        self.correlator = correlator
        self.rows = rows
        self.clock = clock
    }

    public func send(_ request: SendRequest, recorder: InvocationRecorder) -> SendResult {
        let chat = request.chat
        let text = request.text.flatMap { TextNorm.matchKey($0).isEmpty ? nil : $0 }
        var kinds: [SendPartKind] = []
        if text != nil { kinds.append(.text) }
        if request.file != nil { kinds.append(.file) }

        var notes: [ResultNote] = []
        func everyPart(_ result: ActionResult) -> SendResult {
            var result = result
            result.notes += notes
            let shown = kinds.isEmpty ? [SendPartKind.text] : kinds
            return SendResult(parts: shown.map { SendPartOutcome(part: $0, result: result) }, sentGUIDs: [])
        }

        let address = chat.isGroup ? chat.chatGUIDs.first : chat.sendHandle
        guard !kinds.isEmpty, let address, !address.isEmpty else { return everyPart(MessageSender.badRequest) }

        let start = coldStart.start(service: chat.service)
        if start.becameVisible { notes.append(.messagesBecameVisible) }
        guard start.ready else { return everyPart(ActionResult(.failed(.messagesNotReady))) }

        var staged: StagedFile?
        if let file = request.file {
            do {
                staged = try staging.stage(file)
            } catch {
                return everyPart(MessageSender.stagingFailed)
            }
        }

        let maxRowID: Int64
        do {
            maxRowID = try rows.maxMessageRowID()
        } catch {
            if let staged { staging.remove(staged) }
            return everyPart(MessageSender.chatDBUnreadable)
        }
        let snapshot = SendSnapshot(maxRowID: maxRowID, requestedAt: clock.now)
        do {
            try recorder.willInvoke(InvocationFacts(snapshotRowID: maxRowID,
                                                    transferNames: staged.map { [$0.transferName] } ?? []))
        } catch {
            if let staged { staging.remove(staged) }
            return everyPart(MessageSender.journalWriteFailed)
        }

        // A handler that found Messages closed sent nothing. The first time, cold start it hidden and call again.
        var retried = false
        func call(_ handler: ScriptHandler, _ arguments: [String]) -> AppleScriptOutcome {
            let outcome = scripts.call(handler, arguments: arguments)
            guard MessageSender.foundMessagesClosed(outcome), !retried else { return outcome }
            retried = true
            let restart = coldStart.start(service: chat.service)
            if restart.becameVisible, !notes.contains(.messagesBecameVisible) { notes.append(.messagesBecameVisible) }
            guard restart.ready else { return outcome }
            return scripts.call(handler, arguments: arguments)
        }

        // In `kinds` order. Only an Automation refusal or a closed Messages, with no matched row, changes a result
        // below.
        var outcomes: [AppleScriptOutcome] = []
        if let text {
            outcomes.append(chat.isGroup ? call(.sendChatText, [address, text])
                                         : call(.sendText, [address, text, chat.service]))
        }
        if let staged {
            outcomes.append(chat.isGroup ? call(.sendChatFile, [address, staged.url.path])
                                         : call(.sendFile, [address, staged.url.path, chat.service]))
        }
        try? recorder.didInvoke()

        var expectations: [PartExpectation] = []
        if let text { expectations.append(.text(matchKey: TextNorm.matchKey(text))) }
        if let staged { expectations.append(.file(transferName: staged.transferName)) }
        let correlations = correlator.correlate(snapshot: snapshot, chat: chat, parts: expectations)

        var parts: [SendPartOutcome] = []
        var guids: [String] = []
        for ((kind, correlation), outcome) in zip(zip(kinds, correlations), outcomes) {
            let refused = MessageSender.isAutomationRefusal(outcome) && MessageSender.matchedNoRow(correlation)
            let closed = MessageSender.foundMessagesClosed(outcome) && MessageSender.matchedNoRow(correlation)
            var result = refused ? MessageSender.automationNotAllowed
                : closed ? ActionResult(.failed(.messagesNotReady)) : correlation.result
            result.notes += notes
            let row = refused || closed ? nil : correlation.row
            let delivered = row.flatMap { $0.dateDeliveredNs > 0 ? $0.dateDeliveredNs : nil }
            parts.append(SendPartOutcome(part: kind, result: result, rowid: row?.rowid, guid: row?.guid,
                                         dateDeliveredNs: delivered))
            if let guid = row?.guid, !guids.contains(guid) { guids.append(guid) }
        }
        return SendResult(parts: parts, sentGUIDs: guids)
    }

    /// The handler's running check found Messages closed and returned before any Apple Event to it.
    static func foundMessagesClosed(_ outcome: AppleScriptOutcome) -> Bool {
        outcome.ok && outcome.value == SendScripts.notRunning
    }

    static func isAutomationRefusal(_ outcome: AppleScriptOutcome) -> Bool {
        !outcome.ok && outcome.errorNumber.map(automationRefusedErrors.contains) == true
    }

    /// No row matched the part: `may_have_completed`, or `ghost`, whose row is an empty SMS row and not a match.
    static func matchedNoRow(_ correlation: PartCorrelation) -> Bool {
        switch correlation.result.code {
        case .mayHaveCompleted, .ghost: return true
        default: return false
        }
    }
}
