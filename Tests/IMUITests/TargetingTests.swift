import XCTest
import IMCore
import IMStore
@testable import IMUI
import IMTestSupport

/// Checklist items 6 to 10: groups, the lookalike checks, exact row matching, the selected-row rule, the signature
/// check and bubble matching.
final class TargetingTests: XCTestCase {
    // Fixture.now is Friday 2026-11-06 00:30 in Los Angeles. The default summary's newest row is at 00:20.
    let expectedRow = "Jordan, see you, 12:20 AM"

    /// The transcript of the target chat, oldest first: signature rows newest first are (in, "see you") and
    /// (out, "on my way").
    func targetTranscript() -> [BubbleInfo] {
        [Make.bubble(50, fromMe: false, text: "older", minute: "12:01 AM"),
         Make.bubble(51, fromMe: true, text: "on my way", minute: "12:10 AM"),
         Make.bubble(52, fromMe: false, text: "see you", minute: "12:20 AM")]
    }

    /// By default the target's row is the one selected row and Messages shows its transcript.
    func rig(rows: [ConversationRowInfo]? = nil, others: [ConversationSummary] = []) -> (Rig, ChatTargeter) {
        let rig = Rig()
        rig.source.summaries = [Make.summary()] + others
        rig.ax.rows = rows ?? [Make.row(1, "Taylor, hey, 12:05 AM"), Make.row(2, expectedRow, selected: true)]
        rig.ax.bubbles = { self.targetTranscript() }
        return (rig, rig.targeter())
    }

    /// The busy result for `Make.chat()`, whose label is its handle.
    let chatNotOpen = ActionResult(.busy(.chatNotOpen), fix: "open +15550001111 in Messages, hide it (⌘H), then retry")

    // MARK: - Row text

    func testExpectedDescriptionUsesNamePreviewAndTime() {
        let expected = Make.builder().expected(for: Make.summary())
        XCTAssertEqual(expected.description, expectedRow)
        XCTAssertEqual(expected.signature, Make.summary().signature)
    }

    func testSignatureIsTheFiveNewestRows() {
        let rows = (0..<7).map { SignatureRow(fromMe: $0 % 2 == 0, body: "m\($0)") }
        let expected = Make.builder().expected(for: Make.summary(signature: rows))
        XCTAssertEqual(expected.signature, Array(rows.prefix(Limits.signatureRows)))
        XCTAssertEqual(expected.signature.count, 5)
    }

    func testRowTimeLabels() {
        let b = Make.builder()
        XCTAssertEqual(b.rowTimeLabel(forNanos: Make.nanos(2026, 11, 6, 0, 0)), "12:00 AM")
        XCTAssertEqual(b.rowTimeLabel(forNanos: Make.nanos(2026, 11, 6, 0, 30)), "12:30 AM")
        XCTAssertEqual(b.rowTimeLabel(forNanos: Make.nanos(2026, 11, 5, 23, 59, 59)), "Yesterday")
        XCTAssertEqual(b.rowTimeLabel(forNanos: Make.nanos(2026, 11, 5, 0, 0)), "Yesterday")
        XCTAssertEqual(b.rowTimeLabel(forNanos: Make.nanos(2026, 11, 4, 23, 0)), "Wednesday")
        // Six days back crosses the DST change on November 1 and is still a weekday name.
        XCTAssertEqual(b.rowTimeLabel(forNanos: Make.nanos(2026, 10, 31, 9, 0)), "Saturday")
        XCTAssertEqual(b.rowTimeLabel(forNanos: Make.nanos(2026, 10, 30, 23, 59)), "10/30/26")
        XCTAssertEqual(b.rowTimeLabel(forNanos: Make.nanos(2025, 1, 2, 8, 0)), "1/2/25")
        // A row dated in the future (clock skew) gets the date form, never "Yesterday".
        XCTAssertEqual(b.rowTimeLabel(forNanos: Make.nanos(2026, 11, 7, 9, 0)), "11/7/26")
    }

    func testMinuteLabelUsesAPlainSpace() {
        let b = Make.builder()
        XCTAssertEqual(b.minuteLabel(forNanos: Make.nanos(2026, 11, 6, 13, 5)), "1:05 PM")
        XCTAssertEqual(b.minuteLabel(forNanos: Make.nanos(2026, 11, 6, 0, 29, 59)), "12:29 AM")
    }

    func testBuilderIsSafeAcrossThreads() {
        let b = Make.builder()
        let ns = Make.nanos(2026, 11, 4, 23, 0)
        let lock = NSLock()
        var labels = Set<String>()
        DispatchQueue.concurrentPerform(iterations: 200) { _ in
            let label = b.rowTimeLabel(forNanos: ns) + "|" + b.minuteLabel(forNanos: ns)
            lock.lock()
            labels.insert(label)
            lock.unlock()
        }
        XCTAssertEqual(labels, ["Wednesday|11:00 PM"])
    }

    // MARK: - Groups and empty chats (item 6)

    func testGroupChatIsUnsupportedTargetWithNoReadOrPress() {
        let (rig, targeter) = rig()
        XCTAssertEqual(targeter.selectChat(Make.chat("chat123", group: true)),
                       .refused(ActionResult(.unsupportedTarget)))
        XCTAssertNoPress(rig.log)
        XCTAssertFalse(rig.log.contains("ax."))
    }

    func testGroupSummaryIsUnsupportedTarget() {
        let rig = Rig()
        var summary = Make.summary()
        summary.isGroup = true
        rig.source.summaries = [summary]
        rig.ax.rows = [Make.row(2, expectedRow)]
        XCTAssertEqual(rig.targeter().selectChat(Make.chat()), .refused(ActionResult(.unsupportedTarget)))
        XCTAssertNoPress(rig.log)
    }

    func testChatWithNoTextRowsIsNotLoaded() {
        let rig = Rig()
        rig.source.summaries = [Make.summary(signature: [])]
        rig.ax.rows = [Make.row(2, expectedRow)]
        XCTAssertEqual(rig.targeter().selectChat(Make.chat()), .refused(ActionResult(.notLoaded)))
        XCTAssertNoPress(rig.log)
    }

    func testUnknownConversationIsNotLoaded() {
        let (rig, targeter) = rig()
        XCTAssertEqual(targeter.selectChat(Make.chat("+15559999999")), .refused(ActionResult(.notLoaded)))
        XCTAssertNoPress(rig.log)
    }

    func testReadErrorPressesNothing() {
        for op in [FakeUISource.Op.conversation, .conversations] {
            let (rig, targeter) = rig()
            rig.source.failing = [op]
            XCTAssertEqual(targeter.selectChat(Make.chat()), .refused(UIResults.readFailed))
            XCTAssertEqual(UIResults.readFailed.rendered, "error: can't read chat.db fix: run imessage doctor")
            XCTAssertNoPress(rig.log)
        }
    }

    // MARK: - Lookalikes (item 7)

    func testOtherChatWithTheSameDescriptionIsAmbiguousWithNoPress() {
        let twin = Make.summary("+15552223333", signature: [SignatureRow(fromMe: true, body: "different")])
        let (rig, targeter) = rig(others: [twin])
        XCTAssertEqual(targeter.selectChat(Make.chat()), .refused(ActionResult(.ambiguous(.target))))
        XCTAssertNoPress(rig.log)
        XCTAssertFalse(rig.log.contains("ax.rows"), "the check runs before any AX read")
    }

    func testOtherChatWithTheSameSignatureIsAmbiguous() {
        let twin = Make.summary("+15552223333", name: "Someone else", preview: "see you")
        let (rig, targeter) = rig(others: [twin])
        XCTAssertEqual(targeter.selectChat(Make.chat()), .refused(ActionResult(.ambiguous(.target))))
        XCTAssertNoPress(rig.log)
    }

    func testLongerSignatureIsCutToTheTargetLength() {
        // The other chat's newest two rows equal the target's two; its older rows don't matter.
        let longer = Make.summary("+15552223333", name: "Other", preview: "x",
                                  signature: Make.summary().signature + [SignatureRow(fromMe: false, body: "old")])
        let (rig, targeter) = rig(others: [longer])
        XCTAssertEqual(targeter.selectChat(Make.chat()), .refused(ActionResult(.ambiguous(.target))))
        XCTAssertNoPress(rig.log)
    }

    func testSignatureThatDiffersInOneRowOrDirectionIsNotALookalike() {
        let oneOff = Make.summary("+15552223333", name: "Other", preview: "x",
                                  signature: [SignatureRow(fromMe: false, body: "see you"),
                                              SignatureRow(fromMe: true, body: "on my way!")])
        let direction = Make.summary("+15554445555", name: "Third", preview: "y",
                                     signature: [SignatureRow(fromMe: true, body: "see you"),
                                                 SignatureRow(fromMe: true, body: "on my way")])
        let shorter = Make.summary("+15556667777", name: "Fourth", preview: "z",
                                   signature: [SignatureRow(fromMe: false, body: "see you")])
        let (rig, targeter) = rig(others: [oneOff, direction, shorter])
        XCTAssertEqual(targeter.selectChat(Make.chat()), .selected)
        XCTAssertNoPress(rig.log)
    }

    func testSignatureBodiesCompareAfterNFCAndTrim() {
        let padded = Make.summary("+15552223333", name: "Other", preview: "x",
                               signature: [SignatureRow(fromMe: false, body: " see you\n"),
                                           SignatureRow(fromMe: true, body: "on my way")])
        let (rig, targeter) = rig(others: [padded])
        XCTAssertEqual(targeter.selectChat(Make.chat()), .refused(ActionResult(.ambiguous(.target))))
        XCTAssertNoPress(rig.log)
    }

    func testMergedChatsOfTheSameContactAreNotLookalikes() {
        // The same canonical handle (iMessage and SMS chats merged) is the target itself.
        var merged = Make.summary()
        merged.chatRowIDs = [7]
        let (_, targeter) = rig(others: [merged])
        XCTAssertEqual(targeter.selectChat(Make.chat()), .selected)
    }

    // MARK: - Row matching (item 8)

    func testExactlyOneMatchingSelectedRowIsSelectedWithNoPress() {
        let (rig, targeter) = rig()
        rig.ax.pressError = .axError(-25204)
        XCTAssertEqual(targeter.selectChat(Make.chat()), .selected)
        XCTAssertTrue(rig.ax.pressedRows.isEmpty)
        XCTAssertEqual(rig.log.count(of: "ax.pressRow"), 0)
        XCTAssertNoPress(rig.log)
    }

    func testNoMatchingRowIsNotLoaded() {
        let (rig, targeter) = rig(rows: [Make.row(1, "Taylor, hey, 12:05 AM")])
        XCTAssertEqual(targeter.selectChat(Make.chat()), .refused(ActionResult(.notLoaded)))
        XCTAssertNoPress(rig.log)
    }

    func testPrefixAndCaseVariantsDoNotMatch() {
        let rows = [Make.row(1, "Jordan, see you, 12:20 AM, unread"), Make.row(2, "Jordan, see you, 12:20"),
                    Make.row(3, "jordan, see you, 12:20 AM"), Make.row(4, "Jordan, see you, 12:20\u{2009}AM"),
                    Make.row(5, "Jordan, see you, 12:20  AM")]
        let (rig, targeter) = rig(rows: rows)
        XCTAssertEqual(targeter.selectChat(Make.chat()), .refused(ActionResult(.notLoaded)))
        XCTAssertNoPress(rig.log)
    }

    func testRowWithNarrowOrNoBreakSpacesMatchesAsBubblesDo() {
        // Bubbles show U+202F before AM or PM. A row written the same way, or with U+00A0, is the same row text.
        for (i, shown) in ["Jordan, see you, 12:20\u{202F}AM", "Jordan, see\u{00A0}you, 12:20\u{00A0}AM"].enumerated() {
            let (rig, targeter) = rig(rows: [Make.row(1, "Taylor, hey, 12:05 AM"), Make.row(2, shown, selected: true)])
            XCTAssertEqual(targeter.selectChat(Make.chat()), .selected, "case \(i)")
            XCTAssertNoPress(rig.log)
        }
    }

    func testExpectedTextWithNarrowOrNoBreakSpacesMatchesAPlainRow() {
        // The other side: a contact name or preview from chat.db holding U+00A0 or U+202F.
        let rig = Rig()
        rig.source.summaries = [Make.summary(name: "Jordan\u{00A0}Kim", preview: "see\u{202F}you",
                                             signature: [SignatureRow(fromMe: false, body: "see you"),
                                                         SignatureRow(fromMe: true, body: "on my way")])]
        rig.ax.rows = [Make.row(1, "Taylor, hey, 12:05 AM"),
                       Make.row(2, "Jordan Kim, see you, 12:20 AM", selected: true)]
        rig.ax.bubbles = { self.targetTranscript() }
        XCTAssertEqual(rig.targeter().selectChat(Make.chat()), .selected)
        XCTAssertNoPress(rig.log)
    }

    func testRowsThatDifferOnlyInSpaceKindAreAmbiguous() {
        let (rig, targeter) = rig(rows: [Make.row(1, expectedRow), Make.row(2, "Jordan, see you, 12:20\u{202F}AM")])
        XCTAssertEqual(targeter.selectChat(Make.chat()), .refused(ActionResult(.ambiguous(.target))))
        XCTAssertNoPress(rig.log)
    }

    func testOtherChatWhoseDescriptionDiffersOnlyInSpaceKindIsALookalike() {
        // Its row would match the target's expected text, so the target can't be told apart.
        let twin = Make.summary("+15552223333", name: "Jordan", preview: "see\u{00A0}you",
                                signature: [SignatureRow(fromMe: true, body: "different")])
        let (rig, targeter) = rig(others: [twin])
        XCTAssertEqual(targeter.selectChat(Make.chat()), .refused(ActionResult(.ambiguous(.target))))
        XCTAssertNoPress(rig.log)
    }

    func testTwoMatchingRowsAreAmbiguousWithNoPress() {
        let (rig, targeter) = rig(rows: [Make.row(1, expectedRow), Make.row(2, expectedRow)])
        XCTAssertEqual(targeter.selectChat(Make.chat()), .refused(ActionResult(.ambiguous(.target))))
        XCTAssertNoPress(rig.log)
    }

    func testPinnedRowsShowOnlyTheNameAndAreNeverMatched() {
        // S3 ax1.txt: pinned rows (actions start with Unpin) describe themselves by the name alone, unpinned rows
        // by name, preview and time. The target is pinned, so no row equals its full description.
        let pinned = ["Unpin", "Mark as Unread", "Hide Alerts", "Open in New Window", "Delete…"]
        let rows = [ConversationRowInfo(ref: AXRef(id: 1), description: "Jordan", isSelected: false,
                                        actionNames: pinned),
                    ConversationRowInfo(ref: AXRef(id: 2), description: "Taylor", isSelected: false,
                                        actionNames: pinned),
                    ConversationRowInfo(ref: AXRef(id: 3), description: "Riley, hey, 12:05 AM", isSelected: false,
                                        actionNames: ["Pin Riley", "Mark as Unread", "Hide Alerts",
                                                      "Open in New Window", "Delete…"])]
        let (rig, targeter) = rig(rows: rows)
        XCTAssertEqual(targeter.selectChat(Make.chat()), .refused(ActionResult(.notLoaded)))
        XCTAssertNoPress(rig.log)
    }

    func testRowWithoutEnglishRowActionsIsUnsupportedWithNoPress() {
        // Messages runs in French while the system is in English: the row text still matches. The language check
        // comes before the selected-row rule, so a row that isn't selected is `unsupported` too, not busy.
        let french = ["Désépingler", "Marquer comme non lu", "Masquer les alertes",
                      "Ouvrir dans une nouvelle fenêtre", "Supprimer…"]
        for selected in [true, false] {
            let row = ConversationRowInfo(ref: AXRef(id: 2), description: expectedRow, isSelected: selected,
                                          actionNames: french)
            let (rig, targeter) = rig(rows: [row])
            let result = targeter.selectChat(Make.chat())
            XCTAssertEqual(result, .refused(UIResults.messagesNotEnglish), "selected: \(selected)")
            XCTAssertNoPress(rig.log)
            XCTAssertTrue(rig.ax.pressedRows.isEmpty)
        }
        XCTAssertEqual(UIResults.messagesNotEnglish.code, .unsupported)
        XCTAssertFalse(UIResults.messagesNotEnglish.notes.contains(.mayHaveMarkedRead))
        XCTAssertEqual(UIResults.messagesNotEnglish.rendered,
                       "unsupported fix: set Messages' language to English and retry")
    }

    func testEnglishRowActionsOfEveryRowShapeAllowTheAction() {
        XCTAssertTrue(UINames.showsEnglishRowActions(UINames.englishRowActions))
        XCTAssertFalse(UINames.showsEnglishRowActions([]))
        XCTAssertFalse(UINames.showsEnglishRowActions(["Open in New Window"]))
        XCTAssertFalse(UINames.showsEnglishRowActions(["Open in New Window", "Delete..."]), "three dots, not …")
        for actions in [["AXPress", "AXShowMenu", "Pin Jordan", "Mark as Read", "Hide Alerts", "Open in New Window",
                         "Delete…"],
                        ["Unpin", "Mark as Unread", "Hide Alerts", "Open in New Window", "Delete…"]] {
            let row = ConversationRowInfo(ref: AXRef(id: 2), description: expectedRow, isSelected: true,
                                          actionNames: actions)
            let (rig, targeter) = rig(rows: [row])
            XCTAssertEqual(targeter.selectChat(Make.chat()), .selected, "\(actions)")
            XCTAssertNoPress(rig.log)
        }
    }

    func testRowReadFailures() {
        let (rig, targeter) = rig()
        rig.ax.rowsError = .notTrusted
        XCTAssertEqual(targeter.selectChat(Make.chat()), .refused(UIResults.accessibilityMissing))
        rig.ax.rowsError = .notRunning
        XCTAssertEqual(targeter.selectChat(Make.chat()), .refused(ActionResult(.noHiddenWindow)))
        rig.ax.rowsError = .axError(-25204)
        XCTAssertEqual(targeter.selectChat(Make.chat()), .refused(ActionResult(.notLoaded)))
        XCTAssertNoPress(rig.log)
    }

    // MARK: - A conversation list still loading after a launch

    /// The rows once the list has loaded, with the target selected.
    var loadedRows: [ConversationRowInfo] {
        [Make.row(1, "Taylor, hey, 12:05 AM"), Make.row(2, expectedRow, selected: true)]
    }

    /// Scripts a list that reads loading for `loadingReads` reads, then shows `rows`. While it loads, its children
    /// are placeholder groups, so the row read finds none.
    func loadingList(_ rig: Rig, loadingReads: Int, then rows: [ConversationRowInfo]) {
        rig.ax.rows = []
        var reads = 0
        rig.ax.listState = { [unowned ax = rig.ax] in
            reads += 1
            guard reads > loadingReads else { return .loading }
            ax.rows = rows
            return .loaded
        }
    }

    func testRowsThatLoadAfterSomePollsAreMatchedAndTheActionProceeds() {
        let (rig, targeter) = rig()
        loadingList(rig, loadingReads: 4, then: loadedRows)
        let start = rig.clock.uptime
        XCTAssertEqual(targeter.selectChat(Make.chat()), .selected)
        // One loading read after the first row read, then one per poll until the list reads loaded.
        XCTAssertEqual(rig.log.count(of: "ax.listState"), 5)
        XCTAssertEqual(rig.clock.sleeps, Array(repeating: targeter.pollInterval, count: 4))
        XCTAssertEqual(rig.clock.uptime - start, 4 * targeter.pollInterval, accuracy: 0.0001)
        XCTAssertEqual(rig.log.count(of: "ax.rows"), 2, "the rows are read again once, after the list loads")
        XCTAssertNoPress(rig.log)
        XCTAssertTrue(rig.ax.pressedRows.isEmpty)
    }

    func testAListThatLoadsAtTheTimeoutIsMatchedAndOneThatLoadsLaterIsNotLoaded() {
        func run(loadsAfter delay: TimeInterval) -> (ChatSelection, Rig) {
            let (rig, targeter) = rig()
            targeter.pollInterval = 0.25
            let clock = rig.clock
            let start = clock.uptime
            let rows = loadedRows
            rig.ax.rows = []
            rig.ax.listState = { [unowned ax = rig.ax] in
                guard clock.uptime - start >= delay else { return .loading }
                ax.rows = rows
                return .loaded
            }
            return (targeter.selectChat(Make.chat()), rig)
        }
        let atTimeout = run(loadsAfter: 6.0)
        XCTAssertEqual(atTimeout.0, .selected)
        XCTAssertNoPress(atTimeout.1.log)
        let late = run(loadsAfter: 6.01)
        XCTAssertEqual(late.0, .refused(ActionResult(.notLoaded)))
        XCTAssertNoPress(late.1.log)
    }

    func testAListStillLoadingAtTheTimeoutIsNotLoaded() {
        let (rig, targeter) = rig(rows: [])
        rig.ax.listState = { .loading }
        let start = rig.clock.uptime
        XCTAssertEqual(targeter.selectChat(Make.chat()), .refused(ActionResult(.notLoaded)))
        XCTAssertEqual(targeter.listLoadTimeout, 6)
        XCTAssertEqual(rig.clock.uptime - start, targeter.listLoadTimeout, accuracy: 0.0001)
        XCTAssertTrue(rig.clock.sleeps.allSatisfy { $0 > 0 && $0 <= targeter.pollInterval + 0.0001 },
                      "\(rig.clock.sleeps)")
        XCTAssertEqual(rig.log.count(of: "ax.listState"), rig.clock.sleeps.count + 1)
        XCTAssertEqual(rig.log.count(of: "ax.rows"), 1, "no row read after the timeout")
        XCTAssertFalse(rig.log.contains("ax.bubbles"), "no transcript wait")
        XCTAssertNoPress(rig.log)
        XCTAssertTrue(rig.ax.pressedRows.isEmpty)
    }

    func testALoadedListWithNoMatchIsNotLoadedWithNoWait() {
        // Rows that don't match, as today, and a list with no rows at all, which the live read calls loaded.
        for rows in [[Make.row(1, "Taylor, hey, 12:05 AM", selected: true)], []] {
            let (rig, targeter) = rig(rows: rows)
            let start = rig.clock.uptime
            XCTAssertEqual(targeter.selectChat(Make.chat()), .refused(ActionResult(.notLoaded)), "\(rows)")
            XCTAssertEqual(rig.log.count(of: "ax.listState"), 1)
            // The first read and the read again once the list reads loaded (the list can load between them).
            XCTAssertEqual(rig.log.count(of: "ax.rows"), 2)
            XCTAssertTrue(rig.clock.sleeps.isEmpty, "zero polls")
            XCTAssertEqual(rig.clock.uptime, start)
            XCTAssertNoPress(rig.log)
        }
    }

    func testAListThatLoadsWithoutTheTargetIsNotLoadedWithNoFurtherWait() {
        let (rig, targeter) = rig()
        loadingList(rig, loadingReads: 2, then: [Make.row(1, "Taylor, hey, 12:05 AM", selected: true)])
        let start = rig.clock.uptime
        XCTAssertEqual(targeter.selectChat(Make.chat()), .refused(ActionResult(.notLoaded)))
        XCTAssertEqual(rig.clock.uptime - start, 2 * targeter.pollInterval, accuracy: 0.0001)
        XCTAssertEqual(rig.log.count(of: "ax.listState"), 3)
        XCTAssertNoPress(rig.log)
    }

    func testRowsThatLoadKeepTheSelectedRowRule() {
        // After the wait the rows are checked as on any read: a target that isn't the one selected row is busy.
        let (rig, targeter) = rig()
        loadingList(rig, loadingReads: 3, then: [Make.row(1, "Taylor, hey, 12:05 AM", selected: true),
                                                 Make.row(2, expectedRow)])
        XCTAssertEqual(targeter.selectChat(Make.chat()), .refused(chatNotOpen))
        XCTAssertFalse(rig.log.contains("ax.bubbles"))
        XCTAssertNoPress(rig.log)
    }

    func testAnAXErrorDuringTheWaitRefusesAsAnAXFailure() {
        let errors: [(AXDriveError, ActionResult)] = [(.notTrusted, UIResults.accessibilityMissing),
                                                      (.notRunning, ActionResult(.noHiddenWindow)),
                                                      (.axError(-25204), ActionResult(.notLoaded))]
        for (error, expected) in errors {
            // On the first loading read, and on a poll in the middle of the wait.
            for failingRead in [1, 3] {
                let (rig, targeter) = rig(rows: [])
                var reads = 0
                rig.ax.listState = {
                    reads += 1
                    if reads == failingRead { throw error }
                    return .loading
                }
                XCTAssertEqual(targeter.selectChat(Make.chat()), .refused(expected),
                               "\(error) on read \(failingRead)")
                XCTAssertEqual(rig.log.count(of: "ax.listState"), failingRead)
                XCTAssertEqual(rig.clock.sleeps.count, failingRead - 1)
                XCTAssertFalse(rig.log.contains("ax.bubbles"))
                XCTAssertNoPress(rig.log)
            }
            // On the row read again once the list has loaded.
            let (rig, targeter) = rig(rows: [])
            var reads = 0
            rig.ax.listState = { [unowned ax = rig.ax] in
                reads += 1
                guard reads > 2 else { return .loading }
                ax.rowsError = error
                return .loaded
            }
            XCTAssertEqual(targeter.selectChat(Make.chat()), .refused(expected), "\(error) on the second row read")
            XCTAssertEqual(rig.log.count(of: "ax.rows"), 2)
            XCTAssertNoPress(rig.log)
        }
    }

    func testTheLoadingReadIsNeverMadeWhenTheFirstReadMatches() {
        // Selected, not selected, and two matches: each decides from the first read.
        let cases: [([ConversationRowInfo], ChatSelection)] = [
            (loadedRows, .selected),
            ([Make.row(1, "Taylor, hey, 12:05 AM", selected: true), Make.row(2, expectedRow)], .refused(chatNotOpen)),
            ([Make.row(1, expectedRow), Make.row(2, expectedRow)], .refused(ActionResult(.ambiguous(.target)))),
        ]
        for (rows, expected) in cases {
            let (rig, targeter) = rig(rows: rows)
            rig.ax.listState = { .loading }
            XCTAssertEqual(targeter.selectChat(Make.chat()), expected)
            XCTAssertEqual(rig.log.count(of: "ax.listState"), 0, "\(rows)")
            XCTAssertEqual(rig.log.count(of: "ax.rows"), 1)
            XCTAssertNoPress(rig.log)
        }
    }

    func testZeroOrNegativePollIntervalStillEndsTheListWait() {
        for interval in [0, -1] as [TimeInterval] {
            let (rig, targeter) = rig(rows: [])
            targeter.pollInterval = interval
            var reads = 0
            // Capped, so a loop that stops moving the clock fails here instead of spinning.
            rig.ax.listState = {
                reads += 1
                return reads < 5000 ? .loading : .loaded
            }
            let start = rig.clock.uptime
            XCTAssertEqual(targeter.selectChat(Make.chat()), .refused(ActionResult(.notLoaded)), "\(interval)")
            XCTAssertEqual(rig.clock.uptime - start, targeter.listLoadTimeout, accuracy: 0.0001, "\(interval)")
            XCTAssertFalse(rig.clock.sleeps.contains { $0 <= 0 }, "\(interval)")
            XCTAssertLessThan(reads, 5000, "\(interval)")
            XCTAssertNoPress(rig.log)
        }
    }

    // MARK: - A stale read while the list loads

    func testAStaleReadWhileTheListLoadsCountsAsStillLoading() {
        // Messages replaces the list's children as it loads, so a read can hit one it has just destroyed. Here that
        // happens on the first state read, on a poll, and on the row read once the list reads loaded.
        let (rig, targeter) = rig(rows: [])
        let rows = loadedRows
        var reads = 0
        rig.ax.listState = { [unowned ax = rig.ax] in
            reads += 1
            if reads == 1 || reads == 3 { throw AXDriveError.staleReference }
            if reads < 5 { return .loading }
            if reads == 5 {
                ax.rowsError = .staleReference
                return .loaded
            }
            ax.rowsError = nil
            ax.rows = rows
            return .loaded
        }
        XCTAssertEqual(targeter.selectChat(Make.chat()), .selected)
        XCTAssertEqual(rig.log.count(of: "ax.listState"), 6)
        XCTAssertEqual(rig.log.count(of: "ax.rows"), 3)
        XCTAssertEqual(rig.clock.sleeps, Array(repeating: targeter.pollInterval, count: 5))
        XCTAssertNoPress(rig.log)
    }

    func testAStaleFirstRowReadIsReadAgainOnceTheListReadsLoaded() {
        let (rig, targeter) = rig()
        rig.ax.rowsError = .staleReference
        rig.ax.listState = { [unowned ax = rig.ax] in
            ax.rowsError = nil
            return .loaded
        }
        XCTAssertEqual(targeter.selectChat(Make.chat()), .selected)
        XCTAssertEqual(rig.clock.sleeps, [targeter.pollInterval])
        XCTAssertEqual(rig.log.count(of: "ax.listState"), 1)
        XCTAssertEqual(rig.log.count(of: "ax.rows"), 2)
        XCTAssertNoPress(rig.log)
    }

    func testRowsThatLoadBetweenTheRowReadAndTheStateReadAreReadAgain() {
        // The first row read sees placeholders only, and Messages swaps in the rows before the state read.
        let (rig, targeter) = rig()
        let loaded = rig.ax.rows
        rig.ax.rows = []
        rig.ax.listState = { [unowned ax = rig.ax] in
            ax.rows = loaded
            return .loaded
        }
        XCTAssertEqual(targeter.selectChat(Make.chat()), .selected)
        XCTAssertTrue(rig.clock.sleeps.isEmpty, "no wait")
        XCTAssertEqual(rig.log.count(of: "ax.listState"), 1)
        XCTAssertEqual(rig.log.count(of: "ax.rows"), 2)
        XCTAssertNoPress(rig.log)
    }

    func testAStaleRowReadAgainAfterTheListReadsLoadedWaitsForTheList() {
        let (rig, targeter) = rig()
        let loaded = rig.ax.rows
        rig.ax.rows = []
        var states = 0
        rig.ax.listState = { [unowned ax = rig.ax] in
            states += 1
            if states == 1 { ax.rowsError = .staleReference } else { ax.rowsError = nil; ax.rows = loaded }
            return .loaded
        }
        XCTAssertEqual(targeter.selectChat(Make.chat()), .selected)
        XCTAssertEqual(rig.clock.sleeps, [targeter.pollInterval])
        XCTAssertEqual(rig.log.count(of: "ax.listState"), 2)
        XCTAssertEqual(rig.log.count(of: "ax.rows"), 3)
        XCTAssertNoPress(rig.log)
    }

    func testStaleReadsUntilTheTimeoutAreNotLoaded() {
        let (rig, targeter) = rig(rows: [])
        rig.ax.listState = { throw AXDriveError.staleReference }
        let start = rig.clock.uptime
        XCTAssertEqual(targeter.selectChat(Make.chat()), .refused(ActionResult(.notLoaded)))
        XCTAssertEqual(rig.clock.uptime - start, targeter.listLoadTimeout, accuracy: 0.0001)
        XCTAssertEqual(rig.log.count(of: "ax.rows"), 1)
        XCTAssertFalse(rig.log.contains("ax.bubbles"))
        XCTAssertNoPress(rig.log)
    }

    // MARK: - No list shows

    /// A cold launch through the rig's window manager, as `prepare` runs before the action. Returns the time of
    /// the `open`.
    func launch(_ rig: Rig) -> TimeInterval {
        let clock = rig.clock
        var openedAt: TimeInterval?
        rig.app.current = .notRunning
        rig.app.onCall = { call, state in
            guard call == .launchHidden else { return }
            openedAt = clock.uptime
            state = Make.readyState
        }
        XCTAssertNil(rig.windows.ensureHiddenWindow(queueDeadline: clock.uptime + 30))
        XCTAssertNotNil(openedAt)
        XCTAssertEqual(rig.windows.lastLaunchUptime, openedAt)
        return openedAt ?? clock.uptime
    }

    func testAMissingListWithNoRecentLaunchIsNotLoadedWithNoWait() {
        // A warm, hidden Messages whose one window shows no list, for example a lone Settings window.
        let (warm, warmTargeter) = rig(rows: [])
        warm.ax.listState = { .missing }
        XCTAssertNil(warm.windows.lastLaunchUptime)
        let start = warm.clock.uptime
        XCTAssertEqual(warmTargeter.selectChat(Make.chat()), .refused(ActionResult(.notLoaded)))
        XCTAssertTrue(warm.clock.sleeps.isEmpty, "zero polls")
        XCTAssertEqual(warm.clock.uptime, start)
        XCTAssertEqual(warm.log.count(of: "ax.listState"), 1)
        XCTAssertNoPress(warm.log)

        // The same long after the bridge's own launch.
        let (late, lateTargeter) = rig(rows: [])
        let launched = launch(late)
        late.ax.listState = { .missing }
        late.clock.advance(lateTargeter.listLoadTimeout)
        XCTAssertGreaterThan(late.clock.uptime - launched, lateTargeter.listLoadTimeout)
        let sleeps = late.clock.sleeps.count
        let lateStart = late.clock.uptime
        XCTAssertEqual(lateTargeter.selectChat(Make.chat()), .refused(ActionResult(.notLoaded)))
        XCTAssertEqual(late.clock.sleeps.count, sleeps, "zero polls")
        XCTAssertEqual(late.clock.uptime, lateStart)
        XCTAssertNoPress(late.log)
    }

    func testAMissingListRightAfterALaunchWaitsForTheListToLoad() {
        let (rig, targeter) = rig(rows: [])
        let launched = launch(rig)
        let clock = rig.clock
        let rows = loadedRows
        rig.ax.listState = { [unowned ax = rig.ax] in
            let since = clock.uptime - launched
            if since < 2.5 { return .missing }
            if since < 4.5 { return .loading }
            ax.rows = rows
            return .loaded
        }
        XCTAssertEqual(targeter.selectChat(Make.chat()), .selected)
        XCTAssertEqual(clock.uptime - launched, 4.5, accuracy: targeter.pollInterval + 0.0001)
        XCTAssertEqual(rig.log.count(of: "ax.rows"), 2)
        XCTAssertNoPress(rig.log)
    }

    func testAMissingListAfterALaunchCountsAsLoadingOnlyWithinTheTimeoutOfTheLaunch() {
        let (rig, targeter) = rig(rows: [])
        let launched = launch(rig)
        rig.ax.listState = { .missing }
        let start = rig.clock.uptime
        XCTAssertGreaterThan(start, launched, "the launch wait and the visibility poll come first")
        XCTAssertEqual(targeter.selectChat(Make.chat()), .refused(ActionResult(.notLoaded)))
        // The wait ends once the launch is `listLoadTimeout` old, before the poll's own deadline.
        XCTAssertEqual(rig.clock.uptime - launched, targeter.listLoadTimeout, accuracy: targeter.pollInterval + 0.0001)
        XCTAssertLessThan(rig.clock.uptime, start + targeter.listLoadTimeout)
        XCTAssertEqual(rig.log.count(of: "ax.rows"), 2, "read again once the missing list stops counting as loading")
        XCTAssertFalse(rig.log.contains("ax.bubbles"))
        XCTAssertNoPress(rig.log)
    }

    // MARK: - A list with rows and placeholders

    /// Some rows show and the target's is still a placeholder, the part of a launch nothing has sampled.
    let partlyLoaded = ConversationListRule.state(children: [.row, .placeholder])
    let filledIn = ConversationListRule.state(children: [.row, .row])

    func testAPartlyLoadedListRightAfterALaunchWaitsAndThenMatches() {
        let (rig, targeter) = rig(rows: [Make.row(1, "Taylor, hey, 12:05 AM")])
        let launched = launch(rig)
        let clock = rig.clock
        let rows = loadedRows
        let partlyLoaded = self.partlyLoaded
        let filledIn = self.filledIn
        XCTAssertEqual(partlyLoaded, .partlyLoaded)
        rig.ax.listState = { [unowned ax = rig.ax] in
            guard clock.uptime - launched >= 3.5 else { return partlyLoaded }
            ax.rows = rows
            return filledIn
        }
        let sleeps = clock.sleeps.count
        XCTAssertEqual(targeter.selectChat(Make.chat()), .selected)
        XCTAssertEqual(clock.uptime - launched, 3.5, accuracy: targeter.pollInterval + 0.0001)
        XCTAssertGreaterThan(clock.sleeps.count, sleeps, "it waited")
        XCTAssertEqual(rig.log.count(of: "ax.rows"), clock.sleeps.count - sleeps + 1,
                       "the first read, then one on each poll while rows show next to placeholders")
        XCTAssertNoPress(rig.log)
    }

    func testATargetRowThatShowsNextToPlaceholdersAfterALaunchIsMatchedWithoutWaitingForTheRest() {
        // Some placeholders never fill in. The target's row shows 1.5 s after the launch, and the wait ends there,
        // not when the launch is `listLoadTimeout` old.
        let (rig, targeter) = rig(rows: [Make.row(1, "Taylor, hey, 12:05 AM")])
        let launched = launch(rig)
        let clock = rig.clock
        let rows = loadedRows
        let partlyLoaded = self.partlyLoaded
        rig.ax.listState = { [unowned ax = rig.ax] in
            if clock.uptime - launched >= 1.5 { ax.rows = rows }
            return partlyLoaded
        }
        let sleeps = clock.sleeps.count
        XCTAssertEqual(targeter.selectChat(Make.chat()), .selected)
        XCTAssertEqual(clock.uptime - launched, 1.5, accuracy: targeter.pollInterval + 0.0001)
        XCTAssertLessThan(clock.uptime - launched, targeter.listLoadTimeout)
        XCTAssertEqual(rig.log.count(of: "ax.rows"), clock.sleeps.count - sleeps + 1)
        XCTAssertNoPress(rig.log)
    }

    func testAPartlyLoadedListThatStaysSoAfterALaunchWaitsOnlyUntilTheLaunchIsTimeoutOld() {
        let (rig, targeter) = rig(rows: [Make.row(1, "Taylor, hey, 12:05 AM")])
        let launched = launch(rig)
        let partlyLoaded = self.partlyLoaded
        rig.ax.listState = { partlyLoaded }
        let start = rig.clock.uptime
        let sleeps = rig.clock.sleeps.count
        XCTAssertEqual(targeter.selectChat(Make.chat()), .refused(ActionResult(.notLoaded)))
        XCTAssertEqual(rig.clock.uptime - launched, targeter.listLoadTimeout, accuracy: targeter.pollInterval + 0.0001)
        XCTAssertLessThan(rig.clock.uptime, start + targeter.listLoadTimeout)
        XCTAssertEqual(rig.log.count(of: "ax.rows"), rig.clock.sleeps.count - sleeps + 1,
                       "the first read, one on each poll, the last once the list stops counting as loading")
        XCTAssertFalse(rig.log.contains("ax.bubbles"))
        XCTAssertNoPress(rig.log)
    }

    func testAPartlyLoadedListLongAfterALaunchIsNotLoadedWithNoWait() {
        let (rig, targeter) = rig(rows: [Make.row(1, "Taylor, hey, 12:05 AM", selected: true)])
        let launched = launch(rig)
        let partlyLoaded = self.partlyLoaded
        rig.ax.listState = { partlyLoaded }
        rig.clock.advance(targeter.listLoadTimeout)
        XCTAssertGreaterThan(rig.clock.uptime - launched, targeter.listLoadTimeout)
        let sleeps = rig.clock.sleeps.count
        let start = rig.clock.uptime
        XCTAssertEqual(targeter.selectChat(Make.chat()), .refused(ActionResult(.notLoaded)))
        XCTAssertEqual(rig.clock.sleeps.count, sleeps, "zero polls")
        XCTAssertEqual(rig.clock.uptime, start)
        XCTAssertEqual(rig.log.count(of: "ax.listState"), 1)
        XCTAssertEqual(rig.log.count(of: "ax.rows"), 2)
        XCTAssertNoPress(rig.log)
    }

    func testAWarmListWithPinnedTilesAndNoMatchIsNotLoadedWithNoWait() {
        // The bridge never launched Messages. Tiles that aren't rows, with or without a description, sit next to
        // rows that don't match, so the list reads loaded as before and nothing waits.
        let tiles: [[ConversationListChild]] = [[.placeholder, .placeholder, .row, .row], [.other, .other, .row, .row]]
        for children in tiles {
            let (rig, targeter) = rig(rows: [Make.row(1, "Taylor, hey, 12:05 AM", selected: true),
                                             Make.row(2, "Riley, ok, 12:01 AM")])
            XCTAssertNil(rig.windows.lastLaunchUptime)
            rig.ax.listState = { ConversationListRule.state(children: children) }
            let start = rig.clock.uptime
            XCTAssertEqual(targeter.selectChat(Make.chat()), .refused(ActionResult(.notLoaded)), "\(children)")
            XCTAssertTrue(rig.clock.sleeps.isEmpty, "zero polls, \(children)")
            XCTAssertEqual(rig.clock.uptime, start)
            XCTAssertEqual(rig.log.count(of: "ax.listState"), 1)
            XCTAssertEqual(rig.log.count(of: "ax.rows"), 2)
            XCTAssertNoPress(rig.log)
        }
    }

    // MARK: - The selected row (item 9)

    func testTargetThatIsNotSelectedIsBusyWithItsFixAndNoPress() {
        // Another chat is selected, or no chat is. A row press would do nothing while Messages is hidden.
        for other in [true, false] {
            let (rig, targeter) = rig(rows: [Make.row(1, "Taylor, hey, 12:05 AM", selected: other),
                                             Make.row(2, expectedRow)])
            let start = rig.clock.uptime
            XCTAssertEqual(targeter.selectChat(Make.chat()), .refused(chatNotOpen), "other selected: \(other)")
            XCTAssertNoPress(rig.log)
            XCTAssertTrue(rig.ax.pressedRows.isEmpty)
            XCTAssertFalse(rig.log.contains("ax.bubbles"), "no transcript wait")
            XCTAssertEqual(rig.clock.uptime, start)
        }
        XCTAssertEqual(chatNotOpen.notes, [])
        XCTAssertFalse(chatNotOpen.holdsIdempotencyKey)
        XCTAssertEqual(chatNotOpen.rendered,
                       "busy: chat not open in Messages fix: open +15550001111 in Messages, hide it (⌘H), then retry")
    }

    func testTwoSelectedRowsAreBusyWithNoPress() {
        let (rig, targeter) = rig(rows: [Make.row(1, "Taylor, hey, 12:05 AM", selected: true),
                                         Make.row(2, expectedRow, selected: true)])
        XCTAssertEqual(targeter.selectChat(Make.chat()), .refused(chatNotOpen))
        XCTAssertNoPress(rig.log)
        XCTAssertFalse(rig.log.contains("ax.bubbles"))
    }

    func testUnknownSelectionReadIsBusyWithNoPress() {
        // `AXSelected` that reads unknown, on the target's row or on another row, can't show that the target is the
        // one selected chat.
        let unknownTarget = [Make.row(1, "Taylor, hey, 12:05 AM"), Make.row(2, expectedRow, selected: nil)]
        let unknownOther = [Make.row(1, "Taylor, hey, 12:05 AM", selected: nil),
                            Make.row(2, expectedRow, selected: true)]
        for (i, rows) in [unknownTarget, unknownOther].enumerated() {
            let (rig, targeter) = rig(rows: rows)
            XCTAssertEqual(targeter.selectChat(Make.chat()), .refused(chatNotOpen), "case \(i)")
            XCTAssertNoPress(rig.log)
            XCTAssertTrue(rig.ax.pressedRows.isEmpty)
            XCTAssertFalse(rig.log.contains("ax.bubbles"), "case \(i): no transcript wait")
        }
    }

    func testChatNotOpenFixNamesTheChatByItsLabel() {
        var chat = Make.chat()
        chat.label = "Jordan Kim"
        XCTAssertEqual(UIResults.chatNotOpen(chat).fix, "open Jordan Kim in Messages, hide it (⌘H), then retry")
        chat.label = "Jordan\nKim"
        XCTAssertEqual(UIResults.chatNotOpen(chat).fix, "open Jordan / Kim in Messages, hide it (⌘H), then retry")
        chat.label = ""
        XCTAssertEqual(UIResults.chatNotOpen(chat),
                       ActionResult(.busy(.chatNotOpen), fix: "open the chat in Messages, hide it (⌘H), then retry"))
        chat.label = " \n "
        XCTAssertEqual(UIResults.chatNotOpen(chat).fix, "open the chat in Messages, hide it (⌘H), then retry")
    }

    func testSelectedTargetWithAMismatchedTranscriptIsNotLoadedWithNoNote() {
        let (rig, targeter) = rig()
        rig.ax.bubbles = { [Make.bubble(9, fromMe: false, text: "someone else's chat", minute: "12:00 AM")] }
        let start = rig.clock.uptime
        XCTAssertEqual(targeter.selectChat(Make.chat()), .refused(ActionResult(.notLoaded)))
        XCTAssertEqual(rig.clock.uptime - start, targeter.settleTimeout, accuracy: 0.0001)
        XCTAssertNoPress(rig.log)
        XCTAssertTrue(rig.ax.pressedRows.isEmpty)
    }

    func testTranscriptGetsTheSettleTimeToShowTheSelectedChat() {
        func run(showAfter delay: TimeInterval) -> (ChatSelection, EventLog) {
            let (rig, targeter) = rig()
            targeter.pollInterval = 0.25
            let clock = rig.clock
            let start = clock.uptime
            rig.ax.bubbles = { clock.uptime - start >= delay ? self.targetTranscript() : [] }
            return (targeter.selectChat(Make.chat()), rig.log)
        }
        let shown = run(showAfter: 2.0)
        XCTAssertEqual(shown.0, .selected)
        XCTAssertNoPress(shown.1)
        let late = run(showAfter: 2.01)
        XCTAssertEqual(late.0, .refused(ActionResult(.notLoaded)))
        XCTAssertNoPress(late.1)
    }

    func testZeroPollIntervalStillEndsTheSettleWait() {
        let (rig, targeter) = rig()
        targeter.pollInterval = 0
        rig.ax.bubbles = { [] }
        let start = rig.clock.uptime
        XCTAssertEqual(targeter.selectChat(Make.chat()), .refused(ActionResult(.notLoaded)))
        XCTAssertEqual(rig.clock.uptime - start, targeter.settleTimeout, accuracy: 0.0001)
        XCTAssertFalse(rig.clock.sleeps.contains { $0 <= 0 })
    }

    func testTranscriptMustMatchByDirection() {
        let (rig, targeter) = rig()
        rig.ax.bubbles = {
            [Make.bubble(51, fromMe: true, text: "on my way"), Make.bubble(52, fromMe: true, text: "see you")]
        }
        XCTAssertEqual(targeter.selectChat(Make.chat()), .refused(ActionResult(.notLoaded)))
        XCTAssertNoPress(rig.log)
    }

    func testNewestMatchIgnoresNonTextBubbles() {
        let bubbles = [Make.bubble(51, fromMe: true, text: "on my way"),
                       Make.bubble(52, fromMe: false, text: "see you"),
                       Make.bubble(53, fromMe: false, text: "", hasText: false)]
        XCTAssertTrue(ChatTargeter.newestMatch(bubbles, Make.summary().signature))
        XCTAssertFalse(ChatTargeter.newestMatch(Array(bubbles.prefix(1)), Make.summary().signature))
        XCTAssertFalse(ChatTargeter.newestMatch(bubbles, []))
    }

    func testNewestMatchReadsADateBubbleFromItsDescription() {
        let signature = Make.summary(signature: [SignatureRow(fromMe: false, body: "dinner at 7 tomorrow"),
                                                 SignatureRow(fromMe: true, body: "on my way")]).signature
        let dated = [Make.bubble(51, fromMe: true, text: "on my way"),
                     Make.dateBubble(52, fromMe: false, text: "dinner at 7 tomorrow", minute: "12:20 AM")]
        XCTAssertTrue(ChatTargeter.newestMatch(dated, signature))
        // An attachment after it is skipped, as before.
        let photo = Make.bubble(53, fromMe: false, text: "", minute: "12:21 AM", hasText: false,
                                description: "Jordan, IMG_0001.heic, Image · 2 MB, 12:21 AM")
        XCTAssertTrue(ChatTargeter.newestMatch(dated + [photo], signature))
        // A date bubble with other text must show the row like any text bubble, so the match fails.
        let other = [Make.bubble(51, fromMe: true, text: "on my way"),
                     Make.dateBubble(52, fromMe: false, text: "dinner at 8 tomorrow", minute: "12:20 AM")]
        XCTAssertFalse(ChatTargeter.newestMatch(other, signature))
        // Nor does one from the other direction.
        let flipped = [Make.bubble(51, fromMe: true, text: "on my way"),
                       Make.dateBubble(52, fromMe: true, text: "dinner at 7 tomorrow", minute: "12:20 AM")]
        XCTAssertFalse(ChatTargeter.newestMatch(flipped, signature))
    }

    func testNewestMatchRefusesANewerDateBubbleThatIsNotInTheSignature() {
        // The transcript has a newer text than chat.db's newest rows, as another chat with the same older rows would.
        let signature = Make.summary(signature: [SignatureRow(fromMe: false, body: "dinner at 7 tomorrow"),
                                                 SignatureRow(fromMe: true, body: "on my way")]).signature
        let bubbles = [Make.bubble(51, fromMe: true, text: "on my way"),
                       Make.dateBubble(52, fromMe: false, text: "dinner at 7 tomorrow", minute: "12:20 AM"),
                       Make.dateBubble(53, fromMe: false, text: "dinner at 8 tomorrow", minute: "12:21 AM")]
        XCTAssertFalse(ChatTargeter.newestMatch(bubbles, signature))
        let plain = [Make.bubble(51, fromMe: true, text: "on my way"),
                     Make.bubble(52, fromMe: false, text: "see you"),
                     Make.dateBubble(53, fromMe: false, text: "lunch at 1pm", minute: "12:21 AM")]
        XCTAssertFalse(ChatTargeter.newestMatch(plain, Make.summary().signature))
    }

    func testNewestMatchNeverReadsAnAttachmentAsText() {
        // A text row whose body is exactly what a file bubble's description holds after the prefix.
        let name = "s2-a8734a42.txt, Text Document · 23 bytes"
        let signature = Make.summary(signature: [SignatureRow(fromMe: true, body: name),
                                                 SignatureRow(fromMe: true, body: "on my way")]).signature
        let bubbles = [Make.bubble(51, fromMe: true, text: "on my way"),
                       Make.fileBubble(52, name: "s2-a8734a42.txt", minute: "12:20 AM")]
        XCTAssertFalse(ChatTargeter.newestMatch(bubbles, signature))
    }

    func testVerifySelectedPassesWhenTheNewestTextHasADetectedDate() {
        let rig = Rig()
        rig.source.summaries = [Make.summary(signature: [SignatureRow(fromMe: true, body: "see you 2026-11-12"),
                                                         SignatureRow(fromMe: false, body: "see you"),
                                                         SignatureRow(fromMe: true, body: "on my way")])]
        rig.ax.bubbles = {
            [Make.bubble(51, fromMe: true, text: "on my way", minute: "12:10 AM"),
             Make.bubble(52, fromMe: false, text: "see you", minute: "12:20 AM"),
             Make.dateBubble(53, fromMe: true, text: "see you 2026-11-12", minute: "12:30 AM")]
        }
        XCTAssertTrue(rig.targeter().verifySelected(Make.chat(), excluding: nil))
        XCTAssertNoPress(rig.log)
    }

    func testVerifySelectedReReadsWithoutPressing() {
        let rig = Rig()
        rig.source.summaries = [Make.summary()]
        rig.ax.bubbles = { self.targetTranscript() }
        let targeter = rig.targeter()
        XCTAssertTrue(targeter.verifySelected(Make.chat(), excluding: nil))
        XCTAssertFalse(targeter.verifySelected(Make.chat("chat1", group: true), excluding: nil))
        rig.ax.bubblesError = .axError(-25204)
        XCTAssertFalse(targeter.verifySelected(Make.chat(), excluding: nil))
        XCTAssertNoPress(rig.log)
    }

    func testVerifySelectedExcludingTheBoundMessage() {
        let rig = Rig()
        rig.source.summaries = [Make.summary()]
        let bound = Make.target(rowid: 77, fromMe: true, body: "on my way",
                                dateNs: Make.nanos(2026, 11, 6, 0, 10))
        rig.source.targets = [77: bound]
        let targeter = rig.targeter()
        // The bound message is being edited, so its bubble is gone from the transcript.
        rig.ax.bubbles = { [Make.bubble(52, fromMe: false, text: "see you", minute: "12:20 AM")] }
        XCTAssertTrue(targeter.verifySelected(Make.chat(), excluding: 77))
        // A bound row in another conversation is refused.
        var elsewhere = bound
        elsewhere.canonical = .direct(handle: "+15552223333")
        rig.source.targets = [77: elsewhere]
        XCTAssertFalse(targeter.verifySelected(Make.chat(), excluding: 77))
        // An unknown bound row is refused.
        rig.source.targets = [:]
        XCTAssertFalse(targeter.verifySelected(Make.chat(), excluding: 77))
    }

    func testExpectationReadEarlierIsCheckedFromAXAlone() throws {
        let rig = Rig()
        rig.source.summaries = [Make.summary()]
        let bound = Make.target(rowid: 77, fromMe: true, body: "on my way",
                                dateNs: Make.nanos(2026, 11, 6, 0, 10))
        rig.source.targets = [77: bound]
        let targeter = rig.targeter()
        let expected = try XCTUnwrap(targeter.selectionExpectation(Make.chat(), excluding: 77))
        XCTAssertEqual(expected.bound, bound)
        XCTAssertEqual(expected.signature, Array(Make.summary().signature.prefix(Limits.signatureRows)))
        let before = rig.log.count(of: "db.")
        rig.ax.bubbles = { [Make.bubble(52, fromMe: false, text: "see you", minute: "12:20 AM")] }
        XCTAssertTrue(targeter.verifySelected(expected))
        // A message that arrived after the read shows as an extra bubble and fails the check.
        rig.ax.bubbles = { [Make.bubble(52, fromMe: false, text: "see you", minute: "12:20 AM"),
                            Make.bubble(53, fromMe: false, text: "where are you?", minute: "12:21 AM")] }
        XCTAssertFalse(targeter.verifySelected(expected))
        XCTAssertEqual(rig.log.count(of: "db."), before, "the AX half reads no chat.db")
        XCTAssertNil(targeter.selectionExpectation(Make.chat("chat1", group: true), excluding: nil))
        rig.source.targets = [:]
        XCTAssertNil(targeter.selectionExpectation(Make.chat(), excluding: 77))
        XCTAssertNoPress(rig.log)
    }

    func testFindLoadedBubbleSkipsTheChatDBDuplicateCheck() {
        let rig = Rig()
        let targeter = rig.targeter()
        rig.ax.bubbles = { [Make.bubble(41, fromMe: true, text: "on my way", minute: "12:10 AM")] }
        let lookup = targeter.findLoadedBubble(target())
        guard case .found(let bubble) = lookup else { return XCTFail("\(lookup)") }
        XCTAssertEqual(bubble.text, "on my way")
        XCTAssertFalse(rig.log.contains("db."), "AX only")
        XCTAssertNoPress(rig.log)
    }

    // MARK: - Bubble matching (item 10)

    func target(body: String = "on my way", minute: (Int, Int) = (0, 10), fromMe: Bool = true) -> MessageTargetInfo {
        Make.target(fromMe: fromMe, body: body, dateNs: Make.nanos(2026, 11, 6, minute.0, minute.1))
    }

    func testOneBubbleMatchingDirectionTextAndMinuteIsFound() {
        let (rig, targeter) = rig()
        rig.ax.bubbles = { self.targetTranscript() }
        XCTAssertEqual(targeter.findBubble(target()), .found(targetTranscript()[1]))
    }

    func testBubbleTextComparesAsNFC() {
        let (rig, targeter) = rig()
        let decomposed = "cafe\u{301}"
        rig.ax.bubbles = { [Make.bubble(60, fromMe: true, text: "caf\u{E9}", minute: "12:10 AM")] }
        XCTAssertEqual(targeter.findBubble(target(body: decomposed)).bubbleID, 60)
    }

    func testDirectionTextOrMinuteMismatchIsNotLoaded() {
        let (rig, targeter) = rig()
        rig.ax.bubbles = { self.targetTranscript() }
        XCTAssertEqual(targeter.findBubble(target(minute: (0, 11))), .refused(ActionResult(.notLoaded)))
        XCTAssertEqual(targeter.findBubble(target(fromMe: false)), .refused(ActionResult(.notLoaded)))
        XCTAssertEqual(targeter.findBubble(target(body: "on my way!")), .refused(ActionResult(.notLoaded)))
        XCTAssertNoPress(rig.log)
    }

    func testADateBubbleIsFoundByItsDescription() {
        let (rig, targeter) = rig()
        let body = "meet at 5pm 2026-11-12"
        rig.ax.bubbles = { [Make.bubble(51, text: "on my way", minute: "12:09 AM"),
                            Make.dateBubble(52, text: body, minute: "12:10 AM")] }
        XCTAssertEqual(targeter.findBubble(target(body: body)).bubbleID, 52)
        XCTAssertEqual(targeter.findBubble(target(body: body, minute: (0, 11))), .refused(ActionResult(.notLoaded)))
        XCTAssertEqual(targeter.findBubble(target(body: body, fromMe: false)), .refused(ActionResult(.notLoaded)))
        XCTAssertEqual(targeter.findBubble(target(body: "meet at 5pm")), .refused(ActionResult(.notLoaded)))
        XCTAssertNoPress(rig.log)
    }

    func testAnAttachmentIsNeverFoundForATextTarget() {
        let (rig, targeter) = rig()
        rig.ax.bubbles = { [Make.fileBubble(52, name: "s2-a8734a42.txt", minute: "12:10 AM")] }
        XCTAssertEqual(targeter.findBubble(target(body: "s2-a8734a42.txt, Text Document · 23 bytes")),
                       .refused(ActionResult(.notLoaded)))
        XCTAssertNoPress(rig.log)
    }

    func testAnIncomingDateBubbleIsFoundOnlyWhenItsDescriptionSplitsOneWay() {
        let (rig, targeter) = rig()
        rig.ax.bubbles = { [Make.dateBubble(52, fromMe: false, text: "see you at 5", minute: "12:10 AM")] }
        XCTAssertEqual(targeter.findBubble(target(body: "see you at 5", fromMe: false)).bubbleID, 52)
        // A sender named "Kim, Jordan" sending "see you at 5" reads the same as "Kim" sending "Jordan, see you at 5".
        rig.ax.bubbles = { [Make.dateBubble(52, fromMe: false, text: "see you at 5", minute: "12:10 AM",
                                            sender: "Kim, Jordan")] }
        XCTAssertEqual(targeter.findBubble(target(body: "Jordan, see you at 5", fromMe: false)),
                       .refused(ActionResult(.notLoaded)))
        XCTAssertEqual(targeter.findBubble(target(body: "see you at 5", fromMe: false)),
                       .refused(ActionResult(.notLoaded)))
        XCTAssertNoPress(rig.log)
    }

    func testADateBubbleAndATextBubbleWithTheSameTextAndMinuteAreAmbiguous() {
        let (rig, targeter) = rig()
        rig.ax.bubbles = { [Make.bubble(51, text: "at 5pm", minute: "12:10 AM"),
                            Make.dateBubble(52, text: "at 5pm", minute: "12:10 AM")] }
        XCTAssertEqual(targeter.findBubble(target(body: "at 5pm")), .refused(ActionResult(.ambiguous(.target))))
    }

    func testVerifySelectedDropsABoundDateBubble() {
        let rig = Rig()
        let bound = Make.target(rowid: 77, fromMe: true, body: "see you 2026-11-12",
                                dateNs: Make.nanos(2026, 11, 6, 0, 30))
        rig.source.summaries = [Make.summary(signature: [SignatureRow(fromMe: true, body: bound.body),
                                                         SignatureRow(fromMe: false, body: "see you")])]
        rig.source.targets = [77: bound]
        rig.ax.bubbles = { [Make.bubble(52, fromMe: false, text: "see you", minute: "12:20 AM"),
                            Make.dateBubble(53, fromMe: true, text: bound.body, minute: "12:30 AM")] }
        XCTAssertTrue(rig.targeter().verifySelected(Make.chat(), excluding: 77))
    }

    func testVerifySelectedRefusesADateBubbleLeftOverOnceTheBoundRowIsDropped() {
        let rig = Rig()
        let bound = Make.target(rowid: 77, fromMe: true, body: "on my way", dateNs: Make.nanos(2026, 11, 6, 0, 10))
        rig.source.summaries = [Make.summary(signature: [SignatureRow(fromMe: true, body: "on my way")])]
        rig.source.targets = [77: bound]
        rig.ax.bubbles = { [Make.bubble(51, fromMe: true, text: "on my way", minute: "12:10 AM"),
                            Make.dateBubble(52, fromMe: false, text: "see you at 5", minute: "12:20 AM")] }
        XCTAssertFalse(rig.targeter().verifySelected(Make.chat(), excluding: 77))
        rig.ax.bubbles = { [Make.bubble(51, fromMe: true, text: "on my way", minute: "12:10 AM"),
                            Make.fileBubble(52, fromMe: false, name: "IMG_0001.heic", minute: "12:20 AM")] }
        XCTAssertTrue(rig.targeter().verifySelected(Make.chat(), excluding: 77), "an attachment is skipped as before")
        // While the bound bubble is being edited it holds an edit field and no text view, so it isn't bare.
        rig.ax.bubbles = { [Make.bubble(51, fromMe: true, text: "", minute: "12:10 AM", hasText: false,
                                        description: "Your iMessage, on my way, 12:10 AM")] }
        XCTAssertTrue(rig.targeter().verifySelected(Make.chat(), excluding: 77), "a bubble being edited is skipped")
    }

    func testTwoLoadedMatchesAreAmbiguous() {
        let (rig, targeter) = rig()
        rig.ax.bubbles = {
            [Make.bubble(51, text: "on my way", minute: "12:10 AM"), Make.bubble(55, text: "on my way", minute: "12:10 AM")]
        }
        XCTAssertEqual(targeter.findBubble(target()), .refused(ActionResult(.ambiguous(.target))))
    }

    func testSameBodyAndMinuteOnAnotherDayIsAmbiguousBeforeAnyAXRead() {
        let (rig, targeter) = rig()
        rig.source.sameBodyCount = 1
        rig.ax.bubbles = { self.targetTranscript() }
        XCTAssertEqual(targeter.findBubble(target()), .refused(ActionResult(.ambiguous(.target))))
        XCTAssertFalse(rig.log.contains("ax.bubbles"))
    }

    func testNonTextBubbleIsNeverTheTarget() {
        let (rig, targeter) = rig()
        rig.ax.bubbles = { [Make.bubble(70, text: "on my way", minute: "12:10 AM", hasText: false)] }
        XCTAssertEqual(targeter.findBubble(target()), .refused(ActionResult(.notLoaded)))
    }

    func testOnlySinglePartTextIsTargeted() {
        let (rig, targeter) = rig()
        rig.ax.bubbles = { self.targetTranscript() }
        let cases = [Make.target(parts: 2), Make.target(singlePartText: false), Make.target(group: true),
                     Make.target(unsent: true), Make.target(body: "  ")]
        for target in cases {
            XCTAssertEqual(targeter.findBubble(target), .refused(ActionResult(.unsupportedTarget)), "\(target)")
        }
        XCTAssertFalse(rig.log.contains("db.sameBody"))
        XCTAssertFalse(rig.log.contains("ax.bubbles"))
    }

    func testBubbleReadErrors() {
        let (rig, targeter) = rig()
        rig.source.failing = [.sameBody]
        XCTAssertEqual(targeter.findBubble(target()), .refused(UIResults.readFailed))
        rig.source.failing = []
        rig.ax.bubblesError = .notTrusted
        XCTAssertEqual(targeter.findBubble(target()), .refused(UIResults.accessibilityMissing))
    }
}

extension BubbleLookup {
    var bubbleID: UInt64? {
        if case .found(let bubble) = self { return bubble.ref.id }
        return nil
    }
}
