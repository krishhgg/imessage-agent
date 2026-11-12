import ApplicationServices
import XCTest
import IMCore
@testable import IMUI
import IMTestSupport

/// Checklist item 5: named actions only, the parsing the live driver relies on, the tree walk, the thread-view rule,
/// the row-press window check and the ref table. None of these tests creates a `LiveMessagesAX` or `LiveMessagesApp`
/// or reads AX; `LiveMessagesAX.requireHiddenWindow` is a pure check over a state value. The process tests start
/// `/bin/sleep`, never `open`.
final class AXSupportTests: XCTestCase {
    // MARK: - Action names

    func testClassicTapbackNames() {
        let expected: [(TapbackKind, String)] = [(.heart, "Heart"), (.like, "Thumbs up"), (.dislike, "Thumbs down"),
                                                 (.laugh, "Ha ha!"), (.emphasize, "Exclamation mark"),
                                                 (.question, "Question mark")]
        for (kind, name) in expected { XCTAssertEqual(UINames.tapbackAction(kind), name) }
        XCTAssertEqual(UINames.classicTapbacks, expected.map(\.1))
        XCTAssertEqual(UINames.edit, "Edit")
        XCTAssertEqual(UINames.replyToLastMessage, "Reply to Last Message…")
    }

    func testEmojiTapbackMustBeOneEmoji() {
        for ok in ["😭", "🥀", "✌️", "🥲", "🙏🏾", "🇺🇸", "👨‍👩‍👧", "#️⃣", "🏳️‍🌈"] {
            XCTAssertTrue(UINames.isEmojiTapback(ok), ok)
            XCTAssertEqual(UINames.tapbackAction(.emoji(ok)), ok)
        }
        for bad in ["Delete…", "Reply…", "Forward…", "…", "1", "#", "a", "", " ", "😭😭", "😭 ", "Heart",
                    "Add Emoji as Tapback", "Name:Heart", "\u{200D}", "\u{FE0F}"] {
            XCTAssertFalse(UINames.isEmojiTapback(bad), bad)
            XCTAssertNil(UINames.tapbackAction(.emoji(bad)), bad)
        }
    }

    func testOnlyAllowedBubbleActionsCanBePerformed() {
        for ok in UINames.classicTapbacks + [UINames.undoSend, UINames.edit, "😭", "🙏🏾"] {
            XCTAssertTrue(UINames.isAllowedBubbleAction(ok), ok)
        }
        // Every other action S3 saw on a bubble.
        for bad in ["Delete…", "Reply…", "Forward…", "Copy", "Pin", "Add Emoji as Tapback", "Attach Sticker…",
                    "Open URL", "Unmute", "Show Times", "AXPress", "AXShowMenu", "Mark as Unread",
                    "Open in New Window", "heart", "Heart ", ""] {
            XCTAssertFalse(UINames.isAllowedBubbleAction(bad), bad)
        }
    }

    func testOnlyReplyToLastMessageIsAnAllowedMenuItem() {
        XCTAssertEqual(UINames.allowedMenuTitles, ["Reply to Last Message…"])
        XCTAssertFalse(UINames.allowedMenuTitles.contains("Messages"), "Window > Messages shows a window")
    }

    func testHiddenReplyTitleCanBeLookedUpButNeverPressed() {
        XCTAssertEqual(UINames.lookupOnlyMenuTitles, ["Reply to Message…"])
        XCTAssertTrue(UINames.lookupOnlyMenuTitles.isDisjoint(with: UINames.allowedMenuTitles))
        XCTAssertTrue(UINames.mayLookUpMenuItem("Reply to Message…"))
        XCTAssertFalse(UINames.mayPressMenuItem("Reply to Message…"))
        XCTAssertTrue(UINames.mayLookUpMenuItem("Reply to Last Message…"))
        XCTAssertTrue(UINames.mayPressMenuItem("Reply to Last Message…"))
        for bad in ["Messages", "Send Message", "Tapback Message…", "Edit Last Message…", "Reply to ", ""] {
            XCTAssertFalse(UINames.mayLookUpMenuItem(bad), bad)
            XCTAssertFalse(UINames.mayPressMenuItem(bad), bad)
        }
    }

    func testShortActionName() {
        XCTAssertEqual(shortActionName("Name:Heart\nTarget:0x0\nSelector:(null)"), "Heart")
        XCTAssertEqual(shortActionName("Name:Undo Send"), "Undo Send")
        XCTAssertEqual(shortActionName("Name:🙏🏾\nTarget:0x1"), "🙏🏾")
        XCTAssertEqual(shortActionName("AXPress"), "AXPress")
    }

    // MARK: - Bubble descriptions (S3)

    func testOwnBubbleDescriptionWithNarrowNoBreakSpace() {
        let parsed = BubbleDescription.parse("Your iMessage, S2 spike cold s2-67e39189, 9:38\u{202F}AM")
        XCTAssertTrue(parsed.fromMe)
        XCTAssertEqual(parsed.minute, "9:38 AM")
    }

    func testIncomingBubbleDescriptionWithCommasInTheText() {
        let parsed = BubbleDescription.parse("Jordan, yes, see you, at noon, 12:07 PM")
        XCTAssertFalse(parsed.fromMe)
        XCTAssertEqual(parsed.minute, "12:07 PM")
    }

    func testOtherOwnServicePrefixes() {
        for prefix in ["Your SMS", "Your text message", "Your RCS message", "Your message"] {
            XCTAssertTrue(BubbleDescription.parse("\(prefix), hi, 1:00 PM").fromMe, prefix)
        }
        XCTAssertFalse(BubbleDescription.parse("Your iMessageX, hi, 1:00 PM").fromMe)
    }

    func testDescriptionCarriesTheTextOfADateBubble() {
        // The live bubble from 2026-11-11: a detected date, so no text view, and the text only in the description.
        let live = "Your iMessage, imessage-agent live test 2026-11-11: send after re-approval (heart target), 4:33\u{202F}PM"
        XCTAssertTrue(BubbleDescription.carries(live, text: "imessage-agent live test 2026-11-11: send after re-approval (heart target)",
                                                fromMe: true))
        XCTAssertFalse(BubbleDescription.carries(live, text: "imessage-agent live test 2026-11-11", fromMe: true))
        XCTAssertFalse(BubbleDescription.carries(live, text: "imessage-agent live test 2026-11-11: send after re-approval (heart target)",
                                                 fromMe: false), "direction must match")
        XCTAssertTrue(BubbleDescription.carries("Jordan, lunch at 1, ok?, 12:07 PM", text: " lunch at 1, ok? ", fromMe: false),
                      "commas in the text, and the text trimmed")
        XCTAssertTrue(BubbleDescription.carries("Your iMessage, cafe\u{301} at 5, 9:38 AM", text: "caf\u{E9} at 5", fromMe: true),
                      "compared as NFC")
    }

    func testDescriptionCarriesFailsClosed() {
        XCTAssertFalse(BubbleDescription.carries("Kim, Jordan, see you, 12:07 PM", text: "see you", fromMe: false),
                       "a sender with a comma never matches")
        XCTAssertFalse(BubbleDescription.carries("Your iMessage, photo.heic, Image · 2 MB, 9:38 AM", text: "photo.heic",
                                                 fromMe: true), "an attachment adds its kind and size")
        XCTAssertFalse(BubbleDescription.carries("Your iMessage, see you at 5, Yesterday", text: "see you at 5", fromMe: true),
                       "no minute")
        XCTAssertFalse(BubbleDescription.carries("Your iMessage, 9:38 AM", text: "9:38 AM", fromMe: true), "no text part")
        XCTAssertFalse(BubbleDescription.carries("Your iMessage, , 9:38 AM", text: "", fromMe: true), "empty text")
        XCTAssertFalse(BubbleDescription.carries("Your iMessage, see you, 9:38 AM", text: "see you", fromMe: false),
                       "an own prefix isn't a sender")
        XCTAssertFalse(BubbleDescription.carries("", text: "see you", fromMe: true))
    }

    func testDescriptionWithoutAMinuteGivesNoMinute() {
        XCTAssertEqual(BubbleDescription.parse("Your iMessage, hi").minute, "")
        XCTAssertEqual(BubbleDescription.parse("Your iMessage, hi, Yesterday").minute, "")
        XCTAssertEqual(BubbleDescription.parse("Your iMessage, hi, 13:00 PM").minute, "")
        XCTAssertEqual(BubbleDescription.parse("Your iMessage, hi, 9:60 AM").minute, "")
        XCTAssertEqual(BubbleDescription.parse("Your iMessage, hi, ９:38 AM").minute, "", "full-width digits")
        XCTAssertEqual(BubbleDescription.parse("").minute, "")
    }

    func testParsedMinuteMatchesTheBuilder() {
        let ns = Make.nanos(2026, 11, 6, 21, 5)
        XCTAssertEqual(BubbleDescription.parse("Your iMessage, x, 9:05\u{202F}PM").minute,
                       Make.builder().minuteLabel(forNanos: ns))
    }

    // MARK: - Error mapping

    func testAXErrorMapping() {
        XCTAssertEqual(axDriveError(.apiDisabled), .notTrusted)
        XCTAssertEqual(axDriveError(.invalidUIElement), .staleReference)
        XCTAssertEqual(axDriveError(.actionUnsupported, action: "Heart"), .actionMissing("Heart"))
        XCTAssertEqual(axDriveError(.cannotComplete), .axError(AXError.cannotComplete.rawValue))
        XCTAssertEqual(axDriveError(.failure), .axError(AXError.failure.rawValue))
    }

    func testErrorsThatProveNothingWasPressed() {
        XCTAssertFalse(UIResults.mayHaveActed(AXDriveError.actionMissing("Heart")))
        XCTAssertFalse(UIResults.mayHaveActed(AXDriveError.staleReference))
        XCTAssertFalse(UIResults.mayHaveActed(AXDriveError.notTrusted))
        XCTAssertFalse(UIResults.mayHaveActed(AXDriveError.notRunning))
        XCTAssertTrue(UIResults.mayHaveActed(AXDriveError.axError(AXError.cannotComplete.rawValue)))
        XCTAssertTrue(UIResults.mayHaveActed(TestError()))
    }

    func testShownMessagesBeforeARowPressMapsToBusyAndProvesNoPress() {
        let shown = Make.state(hidden: false, ax: 1, onScreen: 1)
        XCTAssertEqual(UIResults.axFailure(AXDriveError.messagesVisible(shown)), .messagesOpen)
        let twoHidden = Make.state(hidden: true, ax: 2)
        XCTAssertEqual(UIResults.axFailure(AXDriveError.messagesVisible(twoHidden)),
                       WindowRules.busyResult(for: twoHidden))
        XCTAssertFalse(UIResults.mayHaveActed(AXDriveError.messagesVisible(shown)))
        // A screen that locks between `prepare` and the press: the final check refuses with the lock's own result.
        let locked = Make.state(locked: true)
        XCTAssertThrowsError(try LiveMessagesAX.requireHiddenWindow(locked)) {
            XCTAssertEqual($0 as? AXDriveError, .messagesVisible(locked))
        }
        XCTAssertEqual(UIResults.axFailure(AXDriveError.messagesVisible(locked)), .screenLocked)
        XCTAssertFalse(UIResults.mayHaveActed(AXDriveError.messagesVisible(locked)))
    }

    func testRowPressNeedsTheHiddenWindowStateRightBeforeThePress() {
        XCTAssertNoThrow(try LiveMessagesAX.requireHiddenWindow(Make.readyState))
        let refused: [MessagesAppState] = [
            Make.state(hidden: false, ax: 1), Make.state(frontmost: true), Make.state(onScreen: 1),
            Make.state(ax: 2), Make.state(ax: 0), Make.state(ax: -1),
        ]
        for state in refused {
            XCTAssertThrowsError(try LiveMessagesAX.requireHiddenWindow(state), "\(state)") {
                XCTAssertEqual($0 as? AXDriveError, .messagesVisible(state))
            }
        }
        XCTAssertThrowsError(try LiveMessagesAX.requireHiddenWindow(.notRunning)) {
            XCTAssertEqual($0 as? AXDriveError, .notRunning)
        }
    }

    // MARK: - Tree walk

    /// A tree of named nodes. A node missing from `tree` has no children and a successful read.
    final class Tree {
        var tree: [String: (children: [String], error: AXError)]
        private(set) var reads: [String] = []
        private(set) var visits: [String] = []

        init(_ tree: [String: (children: [String], error: AXError)]) { self.tree = tree }

        func read(_ node: String) -> (children: [String], error: AXError) {
            reads.append(node)
            return tree[node] ?? ([], .success)
        }

        func walk(maxDepth: Int = 40, maxNodes: Int = 20_000,
                  visit: (String, String?, Int) throws -> AXWalkStep = { _, _, _ in .descend }) throws {
            try walkAXTree(from: "root", maxDepth: maxDepth, maxNodes: maxNodes, readChildren: read) { node, parent, depth in
                self.visits.append(node)
                return try visit(node, parent, depth)
            }
        }
    }

    func testWalkVisitsDepthFirstWithParentsAndDepths() throws {
        let tree = Tree(["root": (["a", "b"], .success), "a": (["a1", "a2"], .success), "b": (["b1"], .success)])
        var seen: [String] = []
        try tree.walk { node, parent, depth in
            seen.append("\(node)<\(parent ?? "-")@\(depth)")
            return .descend
        }
        XCTAssertEqual(seen, ["root<-@0", "a<root@1", "a1<a@2", "a2<a@2", "b<root@1", "b1<b@2"])
    }

    func testTimedOutChildReadStopsTheWalkAndThrows() {
        let timedOut = Tree(["root": (["a", "b"], .success), "a": ([], .cannotComplete), "b": (["b1"], .success)])
        XCTAssertThrowsError(try timedOut.walk()) {
            XCTAssertEqual($0 as? AXDriveError, .axError(AXError.cannotComplete.rawValue))
        }
        XCTAssertEqual(timedOut.reads, ["root", "a"], "no read after the one that timed out")
        XCTAssertEqual(timedOut.visits, ["root", "a"])

        // A timed-out read at the root gives an error, never an empty result.
        let root = Tree(["root": (["a"], .cannotComplete)])
        XCTAssertThrowsError(try root.walk())
        XCTAssertEqual(root.visits, ["root"])
    }

    func testNodesWithoutChildrenCountAsLeaves() throws {
        let tree = Tree(["root": (["a", "b"], .success), "a": (["lost"], .noValue), "b": (["b1"], .success),
                         "b1": (["lost"], .attributeUnsupported)])
        try tree.walk()
        XCTAssertEqual(tree.visits, ["root", "a", "b", "b1"])
    }

    func testFailedChildReadStopsTheWalkAndThrows() {
        // A subtree that couldn't be read might hold the edit field, row or bubble a check looks for.
        let failures: [(AXError, AXDriveError)] = [
            (.failure, .axError(AXError.failure.rawValue)), (.invalidUIElement, .staleReference),
            (.illegalArgument, .axError(AXError.illegalArgument.rawValue)),
            (.notImplemented, .axError(AXError.notImplemented.rawValue)), (.apiDisabled, .notTrusted),
        ]
        for (error, expected) in failures {
            let tree = Tree(["root": (["a", "b"], .success), "a": (["a1"], error), "b": (["b1"], .success)])
            XCTAssertThrowsError(try tree.walk(), "\(error)") { XCTAssertEqual($0 as? AXDriveError, expected) }
            XCTAssertEqual(tree.visits, ["root", "a"], "\(error)")
        }
    }

    // MARK: - Strict attribute reads

    func testMissingAttributeReadsAsAbsent() throws {
        for error in [AXError.noValue, .attributeUnsupported] {
            XCTAssertFalse(try AXRead.present(error))
            XCTAssertNil(try AXRead.optional(error, "left over" as CFString))
        }
        XCTAssertTrue(try AXRead.present(.success))
        XCTAssertEqual(try AXRead.optional(.success, "Sticker" as CFString) as? String, "Sticker")
        XCTAssertNil(try AXRead.optional(.success, nil))
    }

    func testFailedAttributeReadThrowsAndNeverReadsAsEmpty() {
        let failures: [(AXError, AXDriveError)] = [
            (.cannotComplete, .axError(AXError.cannotComplete.rawValue)),
            (.failure, .axError(AXError.failure.rawValue)), (.invalidUIElement, .staleReference),
            (.illegalArgument, .axError(AXError.illegalArgument.rawValue)),
            (.notImplemented, .axError(AXError.notImplemented.rawValue)), (.apiDisabled, .notTrusted),
        ]
        for (error, expected) in failures {
            XCTAssertThrowsError(try AXRead.present(error), "\(error)") {
                XCTAssertEqual($0 as? AXDriveError, expected)
            }
            XCTAssertThrowsError(try AXRead.optional(error, "" as CFString), "\(error)")
            XCTAssertThrowsError(try AXRead.fieldValue(error, "" as CFString), "\(error)") {
                XCTAssertEqual($0 as? AXDriveError, expected)
            }
        }
    }

    func testFieldValueIsOnlyAStringThatWasRead() throws {
        XCTAssertEqual(try AXRead.fieldValue(.success, "" as CFString), "")
        XCTAssertEqual(try AXRead.fieldValue(.success, "half a thought" as CFString), "half a thought")
        // A composer that reports no value isn't shown to be empty.
        let noValue = AXDriveError.axError(AXError.noValue.rawValue)
        XCTAssertThrowsError(try AXRead.fieldValue(.noValue, nil)) { XCTAssertEqual($0 as? AXDriveError, noValue) }
        XCTAssertThrowsError(try AXRead.fieldValue(.attributeUnsupported, nil))
        XCTAssertThrowsError(try AXRead.fieldValue(.success, nil)) { XCTAssertEqual($0 as? AXDriveError, noValue) }
        XCTAssertThrowsError(try AXRead.fieldValue(.success, NSNumber(value: 0)))
    }

    func testWalkBoundsAndSteps() throws {
        let chain = Tree(["root": (["d1"], .success), "d1": (["d2"], .success), "d2": (["d3"], .success)])
        try chain.walk(maxDepth: 2)
        XCTAssertEqual(chain.visits, ["root", "d1", "d2"])
        XCTAssertEqual(chain.reads, ["root", "d1"], "a node at the depth limit isn't read")

        let wide = Tree(["root": (["a", "b", "c"], .success), "a": (["a1"], .success)])
        XCTAssertThrowsError(try wide.walk(maxNodes: 3)) { XCTAssertEqual($0 as? AXDriveError, .walkLimit) }
        XCTAssertEqual(wide.visits, ["root", "a", "a1"])

        let stop = Tree(["root": (["a", "b"], .success), "a": (["a1"], .success)])
        try stop.walk { node, _, _ in node == "a1" ? .stop : .descend }
        XCTAssertEqual(stop.visits, ["root", "a", "a1"])

        let skip = Tree(["root": (["a", "b"], .success), "a": (["a1"], .success)])
        try skip.walk { node, _, _ in node == "a" ? .skipChildren : .descend }
        XCTAssertEqual(skip.visits, ["root", "a", "b"])
        XCTAssertFalse(skip.reads.contains("a"))
    }

    func testAWalkThatReachesTheNodeCapWithNodesLeftThrows() throws {
        // Nodes past the cap might hold the edit field, thread view or bubble a check looks for.
        let leftUnder = Tree(["root": (["a"], .success), "a": (["a1"], .success)])
        XCTAssertThrowsError(try leftUnder.walk(maxNodes: 2)) { XCTAssertEqual($0 as? AXDriveError, .walkLimit) }
        XCTAssertEqual(leftUnder.visits, ["root", "a"])

        let exactFit = Tree(["root": (["a", "b"], .success)])
        try exactFit.walk(maxNodes: 3)
        XCTAssertEqual(exactFit.visits, ["root", "a", "b"])

        let stopsAtTheCap = Tree(["root": (["a", "b", "c"], .success)])
        try stopsAtTheCap.walk(maxNodes: 3) { node, _, _ in node == "b" ? .stop : .descend }
        XCTAssertEqual(stopsAtTheCap.visits, ["root", "a", "b"])

        let skipsAtTheCap = Tree(["root": (["a"], .success), "a": (["a1"], .success)])
        try skipsAtTheCap.walk(maxNodes: 2) { node, _, _ in node == "a" ? .skipChildren : .descend }
        XCTAssertEqual(skipsAtTheCap.visits, ["root", "a"])

        let belowTheDepthLimit = Tree(["root": (["d1"], .success), "d1": (["d2"], .success)])
        try belowTheDepthLimit.walk(maxDepth: 1, maxNodes: 2)
        XCTAssertEqual(belowTheDepthLimit.visits, ["root", "d1"])
    }

    func testTwoEditFieldsShowingThrowsInsteadOfReadingAsNone() throws {
        XCTAssertNil(try LiveMessagesAX.onlyEditField([Int]()))
        XCTAssertEqual(try LiveMessagesAX.onlyEditField([7]), 7)
        XCTAssertThrowsError(try LiveMessagesAX.onlyEditField([7, 8])) {
            XCTAssertEqual($0 as? AXDriveError, .severalEditFields)
        }
    }

    func testVisitErrorsEndTheWalk() {
        let tree = Tree(["root": (["a", "b"], .success)])
        XCTAssertThrowsError(try tree.walk { node, _, _ in
            if node == "a" { throw AXDriveError.axError(AXError.cannotComplete.rawValue) }
            return .descend
        })
        XCTAssertEqual(tree.visits, ["root", "a"])
    }

    // MARK: - Thread view rule

    func node(_ identifier: String, _ ancestors: [String] = ["window"]) -> AXNodeSummary {
        AXNodeSummary(identifier: identifier, ancestorIdentifiers: ancestors)
    }

    func testThreadIdentifierInsideABubbleOrTheConversationListDoesNotCount() {
        let inBubble = node("ReplyThreadCount", ["window", "", "TranscriptCollectionView", "", "Sticker", ""])
        let inList = node("threadPreview", ["window", "", "ConversationList"])
        XCTAssertFalse(ThreadViewRule.namesThreadView(inBubble))
        XCTAssertFalse(ThreadViewRule.namesThreadView(inList))
        XCTAssertNil(ThreadViewRule.pick([node("window", []), node("TranscriptCollectionView"), inBubble, inList]))
    }

    func testThreadIdentifierOutsideThoseSubtreesCounts() {
        let view = node("ThreadView", ["window", ""])
        XCTAssertTrue(ThreadViewRule.namesThreadView(view))
        XCTAssertTrue(ThreadViewRule.namesThreadView(node("replyTHREADContainer")))
        XCTAssertFalse(ThreadViewRule.namesThreadView(node("TranscriptCollectionView")))
        let nodes = [node("window", []), node("TranscriptCollectionView"),
                     node("ThreadReplies", ["window", "TranscriptCollectionView", "Sticker"]), view]
        XCTAssertEqual(ThreadViewRule.pick(nodes), 3)
    }

    func testSecondTranscriptIsTheThreadView() {
        let one = [node("window", []), node("TranscriptCollectionView")]
        XCTAssertNil(ThreadViewRule.pick(one))
        let two = one + [node("Sticker", ["window", "TranscriptCollectionView"]), node("TranscriptCollectionView")]
        XCTAssertEqual(ThreadViewRule.pick(two), 3)
    }

    // MARK: - Conversation list loading

    func testChildrenSortByRoleThenDescription() throws {
        let row = ConversationListRule.child(role: "AXStaticText", description: {
            XCTFail("a row's description isn't read")
            return ""
        })
        XCTAssertEqual(row, .row)
        XCTAssertEqual(ConversationListRule.child(role: "AXGroup", description: { "" }), .placeholder)
        XCTAssertEqual(ConversationListRule.child(role: "", description: { "" }), .placeholder, "a child with no role")
        XCTAssertEqual(ConversationListRule.child(role: "AXGroup", description: { "Jordan" }), .other)
        XCTAssertThrowsError(try ConversationListRule.child(role: "AXGroup", description: { throw TestError() }))
    }

    func testAListWithNoRowIsLoading() {
        // About 1 to 2 s after a hidden launch: 11 children, all `AXGroup` with no description.
        XCTAssertEqual(ConversationListRule.state(children: Array(repeating: .placeholder, count: 11)), .loading)
        // A placeholder next to children with a description, and no row, still reads loading.
        XCTAssertEqual(ConversationListRule.state(children: [.other, .placeholder]), .loading)
    }

    func testAListOfDescribedChildrenWithNoRowIsLoaded() {
        // A warm Messages that shows only pinned tiles: each has a description, so none is a placeholder and
        // nothing waits.
        XCTAssertEqual(ConversationListRule.state(children: [.other]), .loaded)
        XCTAssertEqual(ConversationListRule.state(children: [.other, .other, .other]), .loaded)
    }

    func testNoListIsMissing() {
        // Whether that means loading depends on how long ago the bridge launched Messages, so the targeter decides.
        XCTAssertEqual(ConversationListRule.state(children: nil), .missing)
    }

    func testRowsNextToAPlaceholderArePartlyLoaded() {
        // Between the all-placeholder list and the all-row list some rows may show while others are placeholders.
        // The targeter decides from the time since its own launch whether that is still loading.
        XCTAssertEqual(ConversationListRule.state(children: [.row, .placeholder, .row]), .partlyLoaded)
        XCTAssertEqual(ConversationListRule.state(children: [.placeholder, .other, .row]), .partlyLoaded)
    }

    func testRowsWithNoPlaceholderOrAnEmptyListAreLoaded() {
        XCTAssertEqual(ConversationListRule.state(children: Array(repeating: .row, count: 11)), .loaded)
        // Pinned chats may show as tiles that aren't rows, next to the unpinned rows.
        XCTAssertEqual(ConversationListRule.state(children: [.other, .other, .row]), .loaded)
        XCTAssertEqual(ConversationListRule.state(children: []), .loaded, "no conversations")
    }

    // MARK: - Ref table

    func testSameElementAndFingerprintKeepsItsID() throws {
        let table = RefTable<String>()
        let a = table.register("row-1", kind: .row, fingerprint: "Jordan, hi, 9:00 AM")
        let b = table.register("row-1", kind: .row, fingerprint: "Jordan, hi, 9:00 AM")
        XCTAssertEqual(a, b)
        XCTAssertEqual(try table.entry(for: a, kind: .row).element, "row-1")
    }

    func testReusedViewWithNewContentGetsANewIDAndTheOldGoesStale() throws {
        let table = RefTable<String>()
        let old = table.register("cell", kind: .row, fingerprint: "Jordan, hi, 9:00 AM")
        let new = table.register("cell", kind: .row, fingerprint: "Taylor, yo, 9:01 AM")
        XCTAssertNotEqual(old, new)
        XCTAssertThrowsError(try table.entry(for: old, kind: .row)) {
            XCTAssertEqual($0 as? AXDriveError, .staleReference)
        }
        XCTAssertEqual(try table.entry(for: new, kind: .row).fingerprint, "Taylor, yo, 9:01 AM")
    }

    func testWrongKindOrUnknownIDIsStale() {
        let table = RefTable<String>()
        let row = table.register("x", kind: .row, fingerprint: "d")
        XCTAssertThrowsError(try table.entry(for: row, kind: .bubble))
        XCTAssertThrowsError(try table.entry(for: row, kind: .field))
        XCTAssertThrowsError(try table.entry(for: AXRef(id: 999), kind: .row))
        XCTAssertThrowsError(try table.entry(for: AXRef(id: 0), kind: .row))
    }

    func testCapacityDropsTheOldestHalf() throws {
        let table = RefTable<String>(capacity: 4)
        let refs = (0..<4).map { table.register("e\($0)", kind: .bubble, fingerprint: "f\($0)") }
        XCTAssertEqual(table.count, 4)
        let fifth = table.register("e4", kind: .bubble, fingerprint: "f4")
        XCTAssertLessThanOrEqual(table.count, 4)
        XCTAssertThrowsError(try table.entry(for: refs[0], kind: .bubble))
        XCTAssertNoThrow(try table.entry(for: fifth, kind: .bubble))
        XCTAssertNoThrow(try table.entry(for: refs[3], kind: .bubble))
        // A dropped element registered again gets a fresh id.
        XCTAssertNotEqual(table.register("e0", kind: .bubble, fingerprint: "f0"), refs[0])
    }

    func testBubbleKeepsItsContainer() throws {
        let table = RefTable<String>()
        let ref = table.register("sticker", kind: .bubble, fingerprint: "Your iMessage, hi, 9:00 AM",
                                 container: "group")
        XCTAssertEqual(try table.entry(for: ref, kind: .bubble).container, "group")
    }

    func testRefTableIsSafeFromSeveralThreads() {
        let table = RefTable<String>(capacity: 10_000)
        let lock = NSLock()
        var byElement: [String: Set<UInt64>] = [:]
        DispatchQueue.concurrentPerform(iterations: 2_000) { i in
            let element = "e\(i % 50)"
            let ref = table.register(element, kind: .bubble, fingerprint: "same")
            _ = try? table.entry(for: ref, kind: .bubble)
            lock.lock()
            byElement[element, default: []].insert(ref.id)
            lock.unlock()
        }
        XCTAssertEqual(byElement.count, 50)
        XCTAssertTrue(byElement.values.allSatisfy { $0.count == 1 }, "an element got two ids")
        XCTAssertEqual(table.count, 50)
    }

    // MARK: - Starting open

    func testStartingAProcessReturnsWhileItRuns() throws {
        // `activateForeground` returns while `open` still runs, so the front app is watched during it.
        let started = ProcessInfo.processInfo.systemUptime
        let process = try XCTUnwrap(LiveMessagesApp.startProcess(URL(fileURLWithPath: "/bin/sleep"), ["5"]))
        defer { if process.isRunning { process.terminate() } }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1)
        XCTAssertTrue(process.isRunning)
    }

    func testAStartedProcessStillRunningAfterItsTimeoutIsTerminated() throws {
        let process = try XCTUnwrap(LiveMessagesApp.startProcess(URL(fileURLWithPath: "/bin/sleep"), ["5"],
                                                                 timeout: 0.1))
        defer { if process.isRunning { process.terminate() } }
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.05) }
        XCTAssertFalse(process.isRunning)
        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
    }

    func testAProcessThatCannotStartGivesNil() {
        XCTAssertNil(LiveMessagesApp.startProcess(URL(fileURLWithPath: "/nonexistent/open"), []))
    }

    func testEndingAStartedProcessTerminatesItBeforeItsTimeout() throws {
        // `activateForeground` keeps its `open` here, and `endActivation` ends it when the late-activation watch
        // ends instead of at the 10 s timeout.
        let started = StartedProcess()
        let process = try XCTUnwrap(started.start(URL(fileURLWithPath: "/bin/sleep"), ["30"]))
        defer { if process.isRunning { process.terminate() } }
        XCTAssertTrue(process.isRunning)
        started.end()
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertFalse(process.isRunning)
        if !process.isRunning { XCTAssertEqual(process.terminationReason, .uncaughtSignal) }
        // Nothing kept, a process that already exited, and one that never started are all fine to end.
        started.end()
        let exited = try XCTUnwrap(started.start(URL(fileURLWithPath: "/usr/bin/true"), []))
        exited.waitUntilExit()
        started.end()
        XCTAssertEqual(exited.terminationReason, .exit)
        XCTAssertNil(started.start(URL(fileURLWithPath: "/nonexistent/open"), []))
        started.end()
    }

    // MARK: - Real windows on every Space

    /// One window-server entry, as `CGWindowListCopyWindowInfo` gives it.
    private func windowInfo(pid: pid_t, layer: Int = 0, id: Int? = nil, _ rect: CGRect) -> [String: Any] {
        var info: [String: Any] = [kCGWindowOwnerPID as String: NSNumber(value: pid),
                                   kCGWindowLayer as String: NSNumber(value: layer),
                                   kCGWindowBounds as String: rect.dictionaryRepresentation]
        if let id { info[kCGWindowNumber as String] = NSNumber(value: id) }
        return info
    }

    func testTheSpaceWindowCountDropsTheWindowMessagesNeverShows() {
        // The live list on macOS 26.2 (research/live-tests/2026-11-07-sends.md, test 2): four strips, the 500 x 500
        // window at the bottom-left corner on no Space, and the 660 x 667 chat window on Space 1.
        let pid: pid_t = 4242
        let strips = (0..<4).map { windowInfo(pid: pid, id: 10 + $0, CGRect(x: 0, y: 0, width: 1512, height: 33)) }
        let helper = windowInfo(pid: pid, id: 20, CGRect(x: 0, y: 482, width: 500, height: 500))
        let chat = windowInfo(pid: pid, id: 30, CGRect(x: 840, y: 190, width: 660, height: 667))
        let live: [Int: Int] = [10: 0, 11: 0, 12: 0, 13: 0, 20: 0, 30: 1]
        let list = strips + [helper, chat]
        XCTAssertEqual(LiveMessagesApp.realWindowCount(pid: pid, in: list), 2, "the size floor alone keeps the helper")
        XCTAssertEqual(LiveMessagesApp.spaceWindowCount(pid: pid, in: list, spaces: { live[$0] }), 1)
        XCTAssertEqual(LiveMessagesApp.spaceWindowCount(pid: pid, in: list, spaces: { _ in 2 }), 2,
                       "the strips stay out under the size floor whatever the lookup says")
        XCTAssertEqual(LiveMessagesApp.spaceWindowCount(pid: pid, in: nil, spaces: { live[$0] }), -1)
        XCTAssertEqual(LiveMessagesApp.spaceWindowCount(pid: pid, in: [], spaces: { live[$0] }), 0)
    }

    func testAWindowTheSpaceLookupCantPlaceStillCounts() {
        let pid: pid_t = 4242
        let helper = windowInfo(pid: pid, id: 20, CGRect(x: 0, y: 482, width: 500, height: 500))
        let noID = windowInfo(pid: pid, CGRect(x: 0, y: 482, width: 500, height: 500))
        XCTAssertEqual(LiveMessagesApp.spaceWindowCount(pid: pid, in: [helper], spaces: { _ in nil }), 1,
                       "no lookup counts every real window, as before")
        XCTAssertEqual(LiveMessagesApp.spaceWindowCount(pid: pid, in: [noID], spaces: { _ in 0 }), 1,
                       "no window id counts")
        XCTAssertEqual(LiveMessagesApp.spaceWindowCount(pid: 77, in: [helper], spaces: { _ in 1 }), 0, "another pid")
    }

    func testTheSpaceLookupPutsNoWindowOnASpaceForAnIDThatDoesntExist() {
        // The private function is looked up at run time. Where it exists, a window id nobody owns is on no Space.
        if let count = WindowSpaces.count(of: Int(Int32.max)) { XCTAssertEqual(count, 0) }
    }

    func testTheAppStateDefaultsTheSpaceCountToTheCountOnEverySpace() {
        let state = MessagesAppState(isRunning: true, pid: 1, isFrontmost: false, isHidden: true, axWindowCount: 1,
                                     onScreenWindowCount: 0, allSpacesWindowCount: 2)
        XCTAssertEqual(state.spaceWindowCount, 2)
        XCTAssertEqual(MessagesAppState.notRunning.spaceWindowCount, 0)
    }

    func testTheRealWindowCountDropsTheMenuBarStrips() {
        // The live probe on macOS 26.2 (research/live-tests/2026-11-07-windows.md): four 1512 x 33 layer 0 strips
        // at (0, 0) and the real 1024 x 768 window off screen.
        let pid: pid_t = 4242
        let strips = (0..<4).map { _ in windowInfo(pid: pid, CGRect(x: 0, y: 0, width: 1512, height: 33)) }
        let window = windowInfo(pid: pid, CGRect(x: -1268, y: 0, width: 1024, height: 768))
        XCTAssertEqual(LiveMessagesApp.realWindowCount(pid: pid, in: strips + [window]), 1)
        XCTAssertEqual(LiveMessagesApp.realWindowCount(pid: pid, in: strips), 0, "the strips alone are no window")
        XCTAssertEqual(LiveMessagesApp.realWindowCount(pid: pid, in: nil), -1, "no list is unknown")
        XCTAssertEqual(LiveMessagesApp.realWindowCount(pid: pid, in: []), 0)
    }

    func testTheRealWindowCountNeedsTheOwnerLayerZeroAndBothSidesAtTheFloor() {
        let pid: pid_t = 4242
        let floor = LiveMessagesApp.realWindowMinimumSide
        XCTAssertEqual(floor, 100)
        let list: [[String: Any]] = [
            windowInfo(pid: 77, CGRect(x: 0, y: 0, width: 1024, height: 768)),
            windowInfo(pid: pid, layer: 25, CGRect(x: 0, y: 0, width: 1024, height: 768)),
            windowInfo(pid: pid, CGRect(x: 0, y: 0, width: 1512, height: floor - 1)),
            windowInfo(pid: pid, CGRect(x: 0, y: 0, width: floor - 1, height: 768)),
            [kCGWindowOwnerPID as String: NSNumber(value: pid), kCGWindowLayer as String: NSNumber(value: 0)],
            windowInfo(pid: pid, CGRect(x: 0, y: 0, width: floor, height: floor)),
        ]
        XCTAssertEqual(LiveMessagesApp.realWindowCount(pid: pid, in: list), 1,
                       "another pid, another layer, a side under the floor or no bounds doesn't count")
    }

    // MARK: - Reopen bundle id check

    func testReopenAcceptsOnlyPlainBundleIDs() {
        for ok in ["com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox", "com.example.my-app"] {
            XCTAssertTrue(isPlainBundleID(ok), ok)
        }
        for bad in ["", "-a", "--args", ".hidden", "com.example/../x", "com.example app", "com.é.app",
                    String(repeating: "a", count: 256), "com.x;rm"] {
            XCTAssertFalse(isPlainBundleID(bad), bad)
        }
        XCTAssertTrue(isPlainBundleID(String(repeating: "a", count: 255)))
    }

    // MARK: - Screen lock flag (docs/BUILD-PLAN.md entry 52)

    func testTheScreenLockFlagReadsTheSessionDictionary() {
        let console = "kCGSSessionOnConsoleKey"
        XCTAssertTrue(ScreenLock.isLocked(["CGSSessionScreenIsLocked": 1, console: 1]), "the measured locked session")
        XCTAssertTrue(ScreenLock.isLocked(["CGSSessionScreenIsLocked": true]))
        XCTAssertTrue(ScreenLock.isLocked([console: 0]), "another user on the console")
        XCTAssertTrue(ScreenLock.isLocked([console: false]))
        XCTAssertFalse(ScreenLock.isLocked(["CGSSessionScreenIsLocked": 0, console: 1]))
        XCTAssertFalse(ScreenLock.isLocked([console: 1]), "unlocked: the lock key is missing")
        XCTAssertFalse(ScreenLock.isLocked([:]), "no keys reads as unlocked")
        XCTAssertFalse(ScreenLock.isLocked(["CGSSessionScreenIsLocked": "1"]), "a string isn't a flag")
        XCTAssertTrue(ScreenLock.isLocked([console: 1], frontBundleID: "com.apple.loginwindow"),
                      "the lock key missing while the lock screen is in front")
        XCTAssertTrue(ScreenLock.isLocked([:], frontBundleID: "com.apple.loginwindow"))
        XCTAssertFalse(ScreenLock.isLocked([console: 1], frontBundleID: "com.apple.finder"))
        XCTAssertFalse(ScreenLock.isLocked([console: 1], frontBundleID: nil), "no front app reads as unlocked")
        XCTAssertEqual(console, kCGSessionOnConsoleKey as String)
    }
}
