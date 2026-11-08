import AppKit
import XCTest
@testable import IMBridge
import IMCore
import IMPolicy

/// What the dialog shows and how presses become one decision. The panel tests build an `ApprovalPanel` but never
/// order it front, so nothing appears on screen.
final class ApprovalPanelTests: XCTestCase {
    private func prompt(_ action: MutationKind, text: String? = "On my way", parent: String? = nil,
                        file: String? = nil, bytes: Int64? = nil, alwaysAllow: Bool = true) -> ApprovalPrompt {
        ApprovalPrompt(id: "ab12", binding: ApprovalBinding(chat: nil, action: action), title: "Send to Mom",
                       chatLabel: "Mom", text: text, parentText: parent, attachmentName: file, attachmentBytes: bytes,
                       offersAlwaysAllow: alwaysAllow, reason: "this chat isn't allowed yet")
    }

    func testASendShowsTheChatTheTextAndTheFile() {
        let model = ApprovalPanelModel(prompt: prompt(.send, file: "list.txt", bytes: 2_048))
        XCTAssertEqual(model.title, "Send to Mom")
        XCTAssertEqual(model.lines, [
            .init(label: "Chat", value: "Mom"),
            .init(label: "Text", value: "On my way"),
            .init(label: "File", value: "list.txt (" + ApprovalPanelModel.byteString(2_048) + ")"),
        ])
        XCTAssertEqual(model.reason, "this chat isn't allowed yet")
        XCTAssertTrue(model.showsAlwaysAllow)
    }

    /// A 1:1 prompt as `PolicyEngine` builds it, with the chat's send handle and service.
    private func direct(_ action: MutationKind, label: String = "Juan", handle: String? = "+15512345678",
                        service: String? = "iMessage") -> ApprovalPrompt {
        var p = prompt(action, alwaysAllow: false)
        p.chatLabel = label
        p.sendHandle = handle
        p.service = service
        return p
    }

    func testAOneToOneSendAndAllowNameTheHandleAndServiceNextToTheLabel() {
        for action in [MutationKind.send, .allowChat] {
            XCTAssertEqual(ApprovalPanelModel(prompt: direct(action)).lines.first,
                           .init(label: "Chat", value: "Juan, +15512345678 on iMessage"), "\(action)")
        }
        XCTAssertEqual(ApprovalPanelModel(prompt: direct(.send, service: "SMS")).lines.first?.value,
                       "Juan, +15512345678 on SMS")
        XCTAssertEqual(ApprovalPanelModel(prompt: direct(.send, handle: "juan@example.com")).lines.first?.value,
                       "Juan, juan@example.com on iMessage")
    }

    /// A threaded reply is typed through Reply to Last Message…, and Messages picks its service, so the line names
    /// the handle and claims no service.
    func testAOneToOneThreadedReplyNamesTheHandleAndNoService() {
        for service in ["iMessage", "SMS", "RCS", ""] {
            let reply = direct(.threadedReply, label: "Sam Lee", handle: "+16505550142", service: service)
            XCTAssertEqual(ApprovalPanelModel(prompt: reply).lines.first,
                           .init(label: "Chat", value: "Sam Lee, +16505550142, reply in thread"), service)
        }
        XCTAssertEqual(ApprovalPanelModel(prompt: direct(.threadedReply, label: "+16505550142", handle: "+16505550142"))
                        .lines.first?.value, "+16505550142, reply in thread")
        XCTAssertEqual(ApprovalPanelModel(prompt: direct(.threadedReply, handle: nil)).lines.first?.value, "Juan",
                       "a group reply shows its label")
    }

    func testThePanelRendersTheHandleAndService() throws {
        let built = content(direct(.send))
        XCTAssertEqual(try value(built, "Chat").textView.string, "Juan, +15512345678 on iMessage")
    }

    func testALabelThatIsTheHandleIsShownOnce() {
        XCTAssertEqual(ApprovalPanelModel(prompt: direct(.send, label: "+15512345678")).lines.first?.value,
                       "+15512345678 on iMessage")
    }

    func testWithNoHandleOrServiceTheLineIsWhatIsKnown() {
        XCTAssertEqual(ApprovalPanelModel(prompt: direct(.send, handle: nil)).lines.first?.value, "Juan",
                       "a group or a chat with no send handle shows its label")
        XCTAssertEqual(ApprovalPanelModel(prompt: direct(.send, service: nil)).lines.first?.value,
                       "Juan, +15512345678")
        XCTAssertEqual(ApprovalPanelModel(prompt: direct(.send, service: "")).lines.first?.value,
                       "Juan, +15512345678")
    }

    func testActionsOnAnExistingMessageAndRevokeShowTheLabelAlone() {
        for action in [MutationKind.react, .unsend, .edit, .revokeChat] {
            XCTAssertEqual(ApprovalPanelModel(prompt: direct(action)).lines.first?.value, "Juan", "\(action)")
        }
    }

    func testAFileWithoutASizeShowsItsName() {
        let model = ApprovalPanelModel(prompt: prompt(.send, text: nil, file: "list.txt"))
        XCTAssertEqual(model.lines.last, .init(label: "File", value: "list.txt"))
        XCTAssertEqual(model.lines.map(\.label), ["Chat", "File"])
    }

    func testAThreadedReplyShowsTheMessageItAnswers() {
        let model = ApprovalPanelModel(prompt: prompt(.threadedReply, parent: "Are you coming?", alwaysAllow: false))
        XCTAssertEqual(model.lines.map(\.label), ["Chat", "Replying to", "Text"])
        XCTAssertEqual(model.lines[1].value, "Are you coming?")
        XCTAssertFalse(model.showsAlwaysAllow)
    }

    func testAnEditShowsTheCurrentAndTheNewText() {
        let model = ApprovalPanelModel(prompt: prompt(.edit, text: "at 6", parent: "at 5", alwaysAllow: false))
        XCTAssertEqual(model.lines, [
            .init(label: "Chat", value: "Mom"),
            .init(label: "Current text", value: "at 5"),
            .init(label: "New text", value: "at 6"),
        ])
    }

    func testButtonTitles() {
        XCTAssertEqual(ApprovalPanelModel.denyTitle, "Deny")
        XCTAssertEqual(ApprovalPanelModel.allowOnceTitle, "Allow once")
        XCTAssertEqual(ApprovalPanelModel.alwaysAllowTitle, "Always allow this chat")
    }

    func testDenyCountsAtOnceAndAllowWaitsForTheButtonDelay() {
        var decisions: [ApprovalDecision] = []
        let early = ApprovalDecisionSession(offersAlwaysAllow: true, enabledAt: 10) { decisions.append($0) }
        XCTAssertFalse(early.press(.allowOnce, at: 9.999))
        XCTAssertFalse(early.press(.alwaysAllow, at: 9.999))
        XCTAssertTrue(decisions.isEmpty)
        XCTAssertTrue(early.press(.deny, at: 0))
        XCTAssertFalse(early.press(.allowOnce, at: 11), "only the first decision counts")
        XCTAssertEqual(decisions, [.deny])
    }

    func testAllowCountsFromTheMomentTheButtonsEnable() {
        var decisions: [ApprovalDecision] = []
        let session = ApprovalDecisionSession(offersAlwaysAllow: true, enabledAt: 10) { decisions.append($0) }
        XCTAssertTrue(session.press(.alwaysAllow, at: 10))
        XCTAssertEqual(decisions, [.alwaysAllow])
        XCTAssertTrue(session.isDone)
    }

    func testAlwaysAllowIsIgnoredWhenNotOffered() {
        var decisions: [ApprovalDecision] = []
        let session = ApprovalDecisionSession(offersAlwaysAllow: false, enabledAt: 0) { decisions.append($0) }
        XCTAssertFalse(session.press(.alwaysAllow, at: 5))
        XCTAssertTrue(session.press(.allowOnce, at: 5))
        XCTAssertEqual(decisions, [.allowOnce])
    }

    func testAWithdrawnSessionIgnoresEveryPress() {
        var decisions: [ApprovalDecision] = []
        let session = ApprovalDecisionSession(offersAlwaysAllow: true, enabledAt: 0) { decisions.append($0) }
        session.withdraw()
        XCTAssertFalse(session.press(.deny, at: 5))
        XCTAssertFalse(session.press(.allowOnce, at: 5))
        XCTAssertTrue(decisions.isEmpty)
    }

    // MARK: - What the panel renders

    private func content(_ prompt: ApprovalPrompt, deny: @escaping () -> Void = {}) -> ApprovalPanelContent {
        ApprovalPanel.makeContent(ApprovalPanelModel(prompt: prompt), target: nil, deny: deny)
    }

    /// The value shown under `label`. `values` follows the model's lines, so the label's index finds it.
    private func value(_ content: ApprovalPanelContent, _ label: String,
                       file: StaticString = #filePath, line: UInt = #line) throws -> ApprovalPanelContent.Value {
        let labels = content.values.map(\.label)
        let index = try XCTUnwrap(labels.firstIndex(of: label), "no value under \(label) in \(labels)", file: file, line: line)
        return content.values[index]
    }

    func testATextOverTwelveLinesIsShownInFullWithACaption() throws {
        let lines = (1...30).map { "line \($0)" } + ["https://example.invalid/pay"]
        let text = lines.joined(separator: "\n")
        let built = content(prompt(.send, text: text))
        let shown = try value(built, "Text")
        XCTAssertEqual(shown.textView.string, text, "the panel shows the bound text, every line of it")
        XCTAssertFalse(shown.textView.isEditable)
        XCTAssertTrue(shown.textView.isSelectable)
        XCTAssertTrue(shown.scrollView.hasVerticalScroller)
        XCTAssertTrue(shown.scrollView.documentView === shown.textView)
        let caption = try XCTUnwrap(shown.caption, "a value taller than the view says so")
        XCTAssertEqual(caption.stringValue, "31 lines, \(text.count) characters. Scroll to read all of it.")
        XCTAssertTrue((built.view as? NSStackView)?.arrangedSubviews.contains(caption) == true)
        built.view.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(shown.scrollView.frame.height, ApprovalPanel.valueMaxHeight)
    }

    func testLeadingBlankLinesDontHideTheText() throws {
        let text = String(repeating: "\n", count: 20) + "https://example.invalid/pay"
        let shown = try value(content(prompt(.send, text: text)), "Text")
        XCTAssertEqual(shown.textView.string, text)
        XCTAssertEqual(shown.caption?.stringValue, "21 lines, \(text.count) characters. Scroll to read all of it.")
    }

    func testTheCurrentTextAndTheMessageRepliedToAreShownInFull() throws {
        let long = (1...20).map { "old \($0)" }.joined(separator: "\n")
        let edit = content(prompt(.edit, text: "at 6", parent: long, alwaysAllow: false))
        XCTAssertEqual(try value(edit, "Current text").textView.string, long)
        XCTAssertNotNil(try value(edit, "Current text").caption)
        XCTAssertEqual(try value(edit, "New text").textView.string, "at 6")
        XCTAssertNil(try value(edit, "New text").caption, "a short value needs no caption")

        let reply = content(prompt(.threadedReply, parent: long, alwaysAllow: false))
        XCTAssertEqual(try value(reply, "Replying to").textView.string, long)
        XCTAssertNotNil(try value(reply, "Replying to").caption)
    }

    func testAShortTextFitsWithoutACaption() throws {
        let built = content(prompt(.send, text: "On my way"))
        XCTAssertEqual(built.values.map(\.textView.string), ["Mom", "On my way"])
        XCTAssertTrue(built.values.allSatisfy { $0.caption == nil })
        built.view.layoutSubtreeIfNeeded()
        for shown in built.values { XCTAssertLessThan(shown.scrollView.frame.height, ApprovalPanel.valueMaxHeight) }
    }

    func testTheCaptionCountsLinesAndCharacters() {
        XCTAssertEqual(ApprovalPanelModel.sizeCaption(for: "a\nb\r\nc"), "3 lines, 5 characters. Scroll to read all of it.")
        XCTAssertEqual(ApprovalPanelModel.sizeCaption(for: "x"), "1 line, 1 character. Scroll to read all of it.")
    }

    func testReturnAndEscapeInAValueDeny() throws {
        var denies = 0
        let built = content(prompt(.send, text: "On my way")) { denies += 1 }
        let shown = try value(built, "Text")
        shown.textView.insertNewline(nil)
        shown.textView.cancelOperation(nil)
        XCTAssertEqual(denies, 2)
        XCTAssertEqual(shown.textView.string, "On my way", "Return never edits the value")
    }

    func testTheAllowButtonsHaveNoShortcutStartDisabledAndRefuseKeyboardFocus() {
        let built = content(prompt(.send))
        XCTAssertEqual(built.deny.title, ApprovalPanelModel.denyTitle)
        XCTAssertEqual(built.deny.keyEquivalent, "\r")
        XCTAssertEqual(built.allowButtons.map(\.title),
                       [ApprovalPanelModel.allowOnceTitle, ApprovalPanelModel.alwaysAllowTitle])
        for button in built.allowButtons {
            XCTAssertEqual(button.keyEquivalent, "", button.title)
            XCTAssertFalse(button.isEnabled, button.title)
            XCTAssertTrue(button.refusesFirstResponder, button.title)
            XCTAssertFalse(button.acceptsFirstResponder, button.title)
        }
        XCTAssertEqual(content(prompt(.send, alwaysAllow: false)).allowButtons.map(\.title),
                       [ApprovalPanelModel.allowOnceTitle])
    }

    func testThePanelUsesTheSettingsS1PassedWith() {
        let session = ApprovalDecisionSession(offersAlwaysAllow: true, enabledAt: 0) { _ in }
        let panel = ApprovalPanel(model: ApprovalPanelModel(prompt: prompt(.send)), session: session, cascade: 0)
        defer { panel.close() }
        XCTAssertEqual(panel.level, .statusBar)
        XCTAssertEqual(panel.collectionBehavior, [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary])
        XCTAssertEqual(panel.styleMask, [.titled, .nonactivatingPanel, .utilityWindow])
        XCTAssertTrue(panel.isFloatingPanel)
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertTrue(panel.canBecomeKey, "a click still makes it key")
        XCTAssertFalse(panel.isVisible)
        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertEqual(panel.allowButtons.count, 2)
        XCTAssertTrue(panel.allowButtons.allSatisfy(\.refusesFirstResponder))
        XCTAssertGreaterThanOrEqual(panel.contentLayoutRect.width, ApprovalPanel.valueWidth)
    }
}
