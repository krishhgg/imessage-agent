import XCTest
import IMCore
import IMStore
@testable import IMUI
import IMTestSupport

/// Checklist items 6 to 10: groups, the lookalike checks, exact row matching, the post-press signature check and
/// bubble matching.
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

    func rig(rows: [ConversationRowInfo]? = nil, others: [ConversationSummary] = []) -> (Rig, ChatTargeter) {
        let rig = Rig()
        rig.source.summaries = [Make.summary()] + others
        rig.ax.rows = rows ?? [Make.row(1, "Taylor, hey, 12:05 AM"), Make.row(2, expectedRow)]
        rig.ax.bubbles = { [unowned ax = rig.ax] in
            ax.pressedRows.isEmpty ? [] : self.targetTranscript()
        }
        return (rig, rig.targeter())
    }

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
        XCTAssertEqual(rig.ax.pressedRows, [AXRef(id: 2)])
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

    func testExactlyOneMatchingRowIsPressedOnce() {
        let (rig, targeter) = rig()
        XCTAssertEqual(targeter.selectChat(Make.chat()), .selected)
        XCTAssertEqual(rig.ax.pressedRows, [AXRef(id: 2)])
        XCTAssertEqual(rig.log.count(of: "ax.pressRow"), 1)
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
            let (rig, targeter) = rig(rows: [Make.row(1, "Taylor, hey, 12:05 AM"), Make.row(2, shown)])
            XCTAssertEqual(targeter.selectChat(Make.chat()), .selected, "case \(i)")
            XCTAssertEqual(rig.ax.pressedRows, [AXRef(id: 2)], "case \(i)")
        }
    }

    func testExpectedTextWithNarrowOrNoBreakSpacesMatchesAPlainRow() {
        // The other side: a contact name or preview from chat.db holding U+00A0 or U+202F.
        let rig = Rig()
        rig.source.summaries = [Make.summary(name: "Jordan\u{00A0}Kim", preview: "see\u{202F}you",
                                             signature: [SignatureRow(fromMe: false, body: "see you"),
                                                         SignatureRow(fromMe: true, body: "on my way")])]
        rig.ax.rows = [Make.row(1, "Taylor, hey, 12:05 AM"), Make.row(2, "Jordan Kim, see you, 12:20 AM")]
        rig.ax.bubbles = { [unowned ax = rig.ax] in ax.pressedRows.isEmpty ? [] : self.targetTranscript() }
        XCTAssertEqual(rig.targeter().selectChat(Make.chat()), .selected)
        XCTAssertEqual(rig.ax.pressedRows, [AXRef(id: 2)])
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
        // Messages runs in French while the system is in English: the row text still matches.
        let french = ["Désépingler", "Marquer comme non lu", "Masquer les alertes",
                      "Ouvrir dans une nouvelle fenêtre", "Supprimer…"]
        let row = ConversationRowInfo(ref: AXRef(id: 2), description: expectedRow, isSelected: false,
                                      actionNames: french)
        let (rig, targeter) = rig(rows: [row])
        let result = targeter.selectChat(Make.chat())
        XCTAssertEqual(result, .refused(UIResults.messagesNotEnglish))
        XCTAssertEqual(UIResults.messagesNotEnglish.code, .unsupported)
        XCTAssertFalse(UIResults.messagesNotEnglish.notes.contains(.mayHaveMarkedRead))
        XCTAssertEqual(UIResults.messagesNotEnglish.rendered,
                       "unsupported fix: set Messages' language to English and retry")
        XCTAssertNoPress(rig.log)
        XCTAssertTrue(rig.ax.pressedRows.isEmpty)
    }

    func testEnglishRowActionsOfEveryRowShapeAllowThePress() {
        XCTAssertTrue(UINames.showsEnglishRowActions(UINames.englishRowActions))
        XCTAssertFalse(UINames.showsEnglishRowActions([]))
        XCTAssertFalse(UINames.showsEnglishRowActions(["Open in New Window"]))
        XCTAssertFalse(UINames.showsEnglishRowActions(["Open in New Window", "Delete..."]), "three dots, not …")
        for actions in [["AXPress", "AXShowMenu", "Pin Jordan", "Mark as Read", "Hide Alerts", "Open in New Window",
                         "Delete…"],
                        ["Unpin", "Mark as Unread", "Hide Alerts", "Open in New Window", "Delete…"]] {
            let row = ConversationRowInfo(ref: AXRef(id: 2), description: expectedRow, isSelected: false,
                                          actionNames: actions)
            let (rig, targeter) = rig(rows: [row])
            XCTAssertEqual(targeter.selectChat(Make.chat()), .selected, "\(actions)")
            XCTAssertEqual(rig.ax.pressedRows, [AXRef(id: 2)])
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

    func testPressErrorsThatProveNoPressCarryNoMarkReadNote() {
        let (rig, targeter) = rig()
        rig.ax.pressError = .staleReference
        XCTAssertEqual(targeter.selectChat(Make.chat()), .refused(ActionResult(.notLoaded)))
        rig.ax.pressError = .axError(-25204)
        XCTAssertEqual(targeter.selectChat(Make.chat()),
                       .refused(ActionResult(.notLoaded, notes: [.mayHaveMarkedRead])))
    }

    // MARK: - After the press (item 9)

    func testWrongTranscriptAfterThePressIsWrongChat() {
        let (rig, targeter) = rig()
        rig.ax.bubbles = { [Make.bubble(9, fromMe: false, text: "someone else's chat", minute: "12:00 AM")] }
        let start = rig.clock.uptime
        XCTAssertEqual(targeter.selectChat(Make.chat()),
                       .refused(UIResults.wrongChat))
        XCTAssertEqual(UIResults.wrongChat.rendered, "error: wrong chat, chat opened, may be marked read fix: retry")
        XCTAssertFalse(UIResults.wrongChat.holdsIdempotencyKey)
        XCTAssertEqual(rig.clock.uptime - start, targeter.settleTimeout, accuracy: 0.0001)
    }

    func testTranscriptGetsTheSettleTimeToShowThePressedChat() {
        func run(showAfter delay: TimeInterval) -> ChatSelection {
            let (rig, targeter) = rig()
            targeter.pollInterval = 0.25
            let clock = rig.clock
            let start = clock.uptime
            rig.ax.bubbles = { clock.uptime - start >= delay ? self.targetTranscript() : [] }
            return targeter.selectChat(Make.chat())
        }
        XCTAssertEqual(run(showAfter: 2.0), .selected)
        XCTAssertEqual(run(showAfter: 2.01), .refused(UIResults.wrongChat))
    }

    func testZeroPollIntervalStillEndsTheSettleWait() {
        let (rig, targeter) = rig()
        targeter.pollInterval = 0
        rig.ax.bubbles = { [] }
        let start = rig.clock.uptime
        XCTAssertEqual(targeter.selectChat(Make.chat()), .refused(UIResults.wrongChat))
        XCTAssertEqual(rig.clock.uptime - start, targeter.settleTimeout, accuracy: 0.0001)
        XCTAssertFalse(rig.clock.sleeps.contains { $0 <= 0 })
    }

    func testTranscriptMustMatchByDirection() {
        let (rig, targeter) = rig()
        rig.ax.bubbles = {
            [Make.bubble(51, fromMe: true, text: "on my way"), Make.bubble(52, fromMe: true, text: "see you")]
        }
        XCTAssertEqual(targeter.selectChat(Make.chat()),
                       .refused(UIResults.wrongChat))
    }

    func testNewestMatchIgnoresNonTextBubbles() {
        let bubbles = [Make.bubble(51, fromMe: true, text: "on my way"),
                       Make.bubble(52, fromMe: false, text: "see you"),
                       Make.bubble(53, fromMe: false, text: "", hasText: false)]
        XCTAssertTrue(ChatTargeter.newestMatch(bubbles, Make.summary().signature))
        XCTAssertFalse(ChatTargeter.newestMatch(Array(bubbles.prefix(1)), Make.summary().signature))
        XCTAssertFalse(ChatTargeter.newestMatch(bubbles, []))
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
