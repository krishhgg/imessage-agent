import Foundation
import IMCore
import IMSend
import IMStore

/// A reply verification with the row it correlated, so the machine can return `ForegroundOutcome.sentGUID`.
public struct ReplyVerification: Hashable, Sendable {
    public var result: ActionResult
    /// GUID of the correlated reply row, for `ChatDatabase.agentSentGUIDs`. Nil when no row matched.
    public var rowGUID: String?

    public init(result: ActionResult, rowGUID: String?) {
        self.result = result
        self.rowGUID = rowGUID
    }
}

/// Step 7 verification in chat.db (DESIGN.md section 4 step 7). Takes text digests (`TextNorm.textDigest`), not
/// text, so IMBridge's crash reconciliation can call it with what the journal stores: `facts.targetRowID`,
/// `facts.dateEditedBeforeNs`, `facts.snapshotRowID`, `binding.textDigest` and `binding.parentGUID`.
public protocol ForegroundVerifying: AnyObject {
    /// date_edited later than `dateEditedBeforeNs` and `TextNorm.textDigest` of the body equal to `newTextDigest`,
    /// within `timeout`. `ok`, else `may_have_completed`.
    func verifyEdit(rowid: Int64, dateEditedBeforeNs: AppleNanos, newTextDigest: String,
                    timeout: TimeInterval) -> ActionResult
    /// The new row, correlated as in section 3 with `PartExpectation.textDigest`, must have `thread_originator_guid`
    /// equal to `parentGUID`. Section 3's result, `may_have_completed`, or `failed: sent with wrong parent <guid|none>`.
    func verifyReply(snapshot: SendSnapshot, chat: ResolvedChat, textDigest: String, parentGUID: String,
                     timeout: TimeInterval) -> ActionResult
    /// `verifyReply` plus the GUID of the row it correlated. The machine calls this one.
    func verifyReplyRow(snapshot: SendSnapshot, chat: ResolvedChat, textDigest: String, parentGUID: String,
                        timeout: TimeInterval) -> ReplyVerification
}

extension ForegroundVerifying {
    /// For conformers that implement only `verifyReply`: its result, with no row GUID.
    public func verifyReplyRow(snapshot: SendSnapshot, chat: ResolvedChat, textDigest: String, parentGUID: String,
                               timeout: TimeInterval) -> ReplyVerification {
        ReplyVerification(result: verifyReply(snapshot: snapshot, chat: chat, textDigest: textDigest,
                                              parentGUID: parentGUID, timeout: timeout),
                          rowGUID: nil)
    }
}

/// The part of IMSend's `SendCorrelator` the verifier uses. Tests replace it with a scripted correlator.
protocol ReplyCorrelating: AnyObject {
    func correlate(snapshot: SendSnapshot, chat: ResolvedChat, parts: [PartExpectation],
                   timeout: TimeInterval) -> [PartCorrelation]
}

extension SendCorrelator: ReplyCorrelating {}

/// Live `ForegroundVerifying` over `UITargetSource` and IMSend's `SendCorrelator`. Owner: IMForeground.
///
/// - Edit: polls `editState(rowid:)` every 0.25 s until date_edited is later than the value recorded before the
///   action and the body's digest equals `newTextDigest`. A read error counts as not yet. A timeout of 0 makes one
///   read, which is what crash reconciliation wants.
/// - Reply: one text part, `.textDigest`, through the correlator's 10 s rules. A row that matched (`submitted`,
///   `delivered`, `failed <error>`, `failed transfer_state 6`) must carry the bound parent in
///   `thread_originator_guid`; an empty value counts as none. A matched result with no row is
///   `may_have_completed`. `may_have_completed`, `ghost` and `ambiguous: two rows matched` pass through with no
///   row GUID.
public final class LiveForegroundVerifier: ForegroundVerifying {
    public let source: UITargetSource
    public let correlator: SendCorrelator
    public let clock: Clock
    private let replies: ReplyCorrelating

    public init(source: UITargetSource, correlator: SendCorrelator, clock: Clock) {
        self.source = source
        self.correlator = correlator
        self.clock = clock
        self.replies = correlator
    }

    init(source: UITargetSource, correlator: SendCorrelator, clock: Clock, replies: ReplyCorrelating) {
        self.source = source
        self.correlator = correlator
        self.clock = clock
        self.replies = replies
    }

    public func verifyEdit(rowid: Int64, dateEditedBeforeNs: AppleNanos, newTextDigest: String,
                           timeout: TimeInterval) -> ActionResult {
        let deadline = clock.uptime + max(0, timeout)
        while true {
            if let state = try? source.editState(rowid: rowid), state.dateEditedNs > dateEditedBeforeNs,
               TextNorm.textDigest(state.body) == newTextDigest {
                return ActionResult(.ok)
            }
            let left = deadline - clock.uptime
            if left <= 0 { return ActionResult(.mayHaveCompleted) }
            clock.sleep(min(ForegroundTiming.verifyPoll, left))
        }
    }

    public func verifyReply(snapshot: SendSnapshot, chat: ResolvedChat, textDigest: String, parentGUID: String,
                            timeout: TimeInterval) -> ActionResult {
        verifyReplyRow(snapshot: snapshot, chat: chat, textDigest: textDigest, parentGUID: parentGUID,
                       timeout: timeout).result
    }

    public func verifyReplyRow(snapshot: SendSnapshot, chat: ResolvedChat, textDigest: String, parentGUID: String,
                               timeout: TimeInterval) -> ReplyVerification {
        let parts = replies.correlate(snapshot: snapshot, chat: chat, parts: [.textDigest(textDigest)],
                                      timeout: max(0, timeout))
        guard let part = parts.first else {
            return ReplyVerification(result: ActionResult(.mayHaveCompleted), rowGUID: nil)
        }
        switch part.result.code {
        case .submitted, .delivered, .failed(.rowError), .failed(.transferFailed):
            // A matched result with no row can't show its parent, so it can't count as a verified reply.
            guard let row = part.row else {
                return ReplyVerification(result: ActionResult(.mayHaveCompleted), rowGUID: nil)
            }
            let shownParent = row.threadOriginatorGUID.flatMap { $0.isEmpty ? nil : $0 }
            guard shownParent == parentGUID else {
                let wrong = ActionResult(.failed(.sentWithWrongParent(shownParent)), notes: part.result.notes)
                return ReplyVerification(result: wrong, rowGUID: row.guid)
            }
            return ReplyVerification(result: part.result, rowGUID: row.guid)
        default:
            return ReplyVerification(result: part.result, rowGUID: nil)
        }
    }
}
