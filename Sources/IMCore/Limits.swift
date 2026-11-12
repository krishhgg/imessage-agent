import Foundation

/// Every number DESIGN.md fixes, in one place. Modules read these instead of repeating literals.
/// Times are in seconds unless the name says otherwise.
public enum Limits {
    // MARK: Wire (section 3 item 7, section 5)

    /// The CLI streams at most this many file bytes to the bridge: 100 MB, decimal, as section 3 item 7 writes it
    /// (docs/BUILD-PLAN.md sets it next to the 8 MiB frame cap).
    public static let maxUploadBytes: Int64 = 100_000_000
    /// Largest JSON frame either side accepts. Raw upload bytes are not framed and don't count.
    public static let maxFrameBytes = 8 * 1024 * 1024

    // MARK: Output (section 5)

    public static let outputMaxLines = 200
    public static let outputMaxBytes = 12_000
    public static let bodyCutChars = 400
    public static let showCapBytes = 8_192
    public static let quoteChars = 30
    public static let chatPreviewChars = 60
    /// Search snippet width. research/tokens.md section 6; DESIGN.md sets no snippet length.
    public static let searchSnippetChars = 120
    /// Longest search query, in Unicode scalars. The query prints in the search header and again, shell-quoted, in
    /// the `more:` footer, and at 500 scalars both still fit `outputMaxBytes` with hits shown.
    public static let searchQueryMaxChars = 500
    public static let defaultChatsLimit = 20
    public static let defaultReadLimit = 30
    public static let defaultSearchLimit = 20
    public static let defaultUnreadContext = 2
    public static let defaultWaitTimeout: TimeInterval = 300

    // MARK: SQLite (section 1)

    /// Interactive reads time out after 2 s.
    public static let interactiveReadTimeout: TimeInterval = 2
    /// Search has its own budget. DESIGN.md gives no number; 5 s is the build-plan choice.
    public static let searchBudget: TimeInterval = 5
    /// Default search window: 1 year back, `--since` changes it.
    public static let searchWindowDays = 365
    /// Default row cap per call.
    public static let defaultRowCap = 5_000

    // MARK: Attachments (section 1)

    public static let heicMaxPixel = 1_600
    public static let attachmentCacheTTL: TimeInterval = 24 * 3600

    // MARK: Approvals (section 2)

    /// The CLI waits up to 120 s for the dialog, then prints the result, `denied` or `pending <id>`.
    public static let approvalWait: TimeInterval = 120
    /// An approval is single-use and expires after 10 minutes.
    public static let approvalExpiry: TimeInterval = 600
    /// Allow buttons stay disabled for the first second.
    public static let approvalButtonDelay: TimeInterval = 1

    // MARK: Rate limits (section 2)

    public static let minSecondsBetweenSendsPerChat: TimeInterval = 20
    public static let maxSendsPerChatPerDay = 30
    public static let maxSendsPerDay = 100
    public static let maxConsecutiveAgentSends = 3

    // MARK: Time windows checked against the row date (section 2)

    public static let undoSendWindow: TimeInterval = 120
    public static let editWindow: TimeInterval = 900

    // MARK: Send contract (section 3)

    /// Idempotency lookup window, sliding.
    public static let idempotencyWindow: TimeInterval = 600
    /// Journal retention.
    public static let journalRetention: TimeInterval = 7 * 24 * 3600
    /// Crash reconcile budget per entry.
    public static let reconcileTimeout: TimeInterval = 10
    /// Total wait for the queue, including the staged-file wait before a relaunch.
    public static let queueWait: TimeInterval = 30
    /// Cold start: wait for the account to be ready.
    public static let coldStartTimeout: TimeInterval = 60
    /// Correlation budget after the Apple Event.
    public static let correlationTimeout: TimeInterval = 10
    /// Longest one send handler call waits for Messages, the `with timeout` in the script. A text plus file request
    /// makes one call per part.
    public static let sendEventTimeout: TimeInterval = 10
    /// Extra wait for the join row once delivered or failed is set, inside the 10 s.
    public static let joinRowGrace: TimeInterval = 1
    /// Staged copies are deleted at transfer_state 5, or this long after staging.
    public static let stagedFileTTL: TimeInterval = 600
    /// transfer_state values that matter (section 3 items 6 and 7).
    public static let transferStateDone = 5
    public static let transferStateFailed = 6

    // MARK: UI actions (section 4)

    /// Wait for Messages to exit before the no-window relaunch.
    public static let quitWait: TimeInterval = 10
    /// After the relaunch, a single hidden window must exist within this time.
    public static let relaunchWindowWait: TimeInterval = 10
    /// After each hidden UI action, cold launch and relaunch, poll isHidden and the window list this long.
    public static let visibilityPoll: TimeInterval = 1
    /// Wait for the verifying tapback row or the unsend state.
    public static let uiVerifyTimeout: TimeInterval = 10
    /// Target signature length: newest text rows by direction and body.
    public static let signatureRows = 5

    // MARK: Foreground mode (section 4 steps 1 to 7)

    public static let idleThreshold: TimeInterval = 2
    public static let idleGateTimeout: TimeInterval = 30
    public static let activationTimeout: TimeInterval = 1
    public static let lateActivationWatch: TimeInterval = 5
    public static let returnDeadline: TimeInterval = 3
    public static let maxEscapePresses = 3
    public static let hidePoll: TimeInterval = 1
    public static let focusRestoreWait: TimeInterval = 2
    public static let foregroundVerifyTimeout: TimeInterval = 10
}
