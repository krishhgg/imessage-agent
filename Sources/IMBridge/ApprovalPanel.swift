import AppKit
import Foundation
import IMCore
import IMPolicy

/// The native approval dialog (DESIGN.md section 2). Owner: IMBridge.
///
/// - Non-activating `NSPanel` with the settings S1 passed with: `.titled`, `.nonactivatingPanel`, `.utilityWindow`,
///   level `.statusBar`, joins all Spaces, `.stationary`, `.fullScreenAuxiliary`. It is ordered front with
///   `orderFrontRegardless`, so it never takes key focus from the app the user is typing in. A click makes it key
///   without activating the bridge.
/// - Buttons Deny (default, Return and Escape), Allow once, Always allow this chat. The allow buttons have no key
///   equivalent, refuse first responder so keyboard navigation can't reach them, and stay disabled for
///   `Limits.approvalButtonDelay`.
/// - "Always allow" is hidden when `ApprovalPrompt.offersAlwaysAllow` is false.
/// - Shows the chat label, the text, the parent's text for a threaded reply, and the file name and size. For a 1:1
///   send or allow the chat line also gives the send handle and the service, and for a 1:1 threaded reply the send
///   handle and no service. Each value is shown in full in a read-only, selectable text view. A value taller than
///   `ApprovalPanel.valueMaxHeight` scrolls, and a caption under it gives its line and character count.
/// - Over a full-screen app the panel is unconfirmed (release test 6).
///
/// `present` and `withdraw` may be called from any thread; the panels live on the main thread.
public final class ApprovalPanelController: ApprovalPresenting {
    private var open: [String: (panel: ApprovalPanel, session: ApprovalDecisionSession)] = [:]

    public init() {}

    public func present(_ prompt: ApprovalPrompt, decided: @escaping (ApprovalDecision) -> Void) {
        let model = ApprovalPanelModel(prompt: prompt)
        DispatchQueue.main.async { [self] in
            let id = prompt.id
            let session = ApprovalDecisionSession(offersAlwaysAllow: model.showsAlwaysAllow,
                                                  enabledAt: ProcessInfo.processInfo.systemUptime + Limits.approvalButtonDelay) {
                [weak self] decision in
                decided(decision)
                self?.close(id: id)
            }
            let panel = ApprovalPanel(model: model, session: session, cascade: open.count)
            open[id] = (panel, session)
            panel.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + Limits.approvalButtonDelay) { [weak panel] in
                panel?.enableAllowButtons()
            }
        }
    }

    public func withdraw(id: String) {
        DispatchQueue.main.async { [self] in
            open[id]?.session.withdraw()
            close(id: id)
        }
    }

    private func close(id: String) {
        guard let item = open.removeValue(forKey: id) else { return }
        item.panel.orderOut(nil)
        item.panel.close()
    }
}

/// What the panel shows for one prompt. Pure, so tests check it without AppKit windows.
struct ApprovalPanelModel: Equatable {
    struct Line: Equatable {
        var label: String
        var value: String
    }

    var title: String
    var lines: [Line]
    var reason: String
    var showsAlwaysAllow: Bool

    static let denyTitle = "Deny"
    static let allowOnceTitle = "Allow once"
    static let alwaysAllowTitle = "Always allow this chat"

    init(prompt: ApprovalPrompt) {
        title = prompt.title
        var lines: [Line] = []
        if let chat = prompt.chatLabel {
            let recipient = ApprovalPanelModel.namesRecipient(prompt.binding.action)
            lines.append(Line(label: "Chat", value: ApprovalPanelModel.chatValue(
                chat, handle: recipient ? prompt.sendHandle : nil, service: recipient ? prompt.service : nil,
                inThread: prompt.binding.action == .threadedReply)))
        }
        if let parent = prompt.parentText {
            let label = prompt.binding.action == .edit ? "Current text" : "Replying to"
            lines.append(Line(label: label, value: parent))
        }
        if let text = prompt.text {
            lines.append(Line(label: prompt.binding.action == .edit ? "New text" : "Text", value: text))
        }
        if let name = prompt.attachmentName {
            let size = prompt.attachmentBytes.map { " (" + ApprovalPanelModel.byteString($0) + ")" } ?? ""
            lines.append(Line(label: "File", value: name + size))
        }
        self.lines = lines
        reason = prompt.reason
        showsAlwaysAllow = prompt.offersAlwaysAllow
    }

    /// A 1:1 send, threaded reply or allow names the handle next to the label, so a contact's number that resolved to
    /// the wrong country shows before anything is sent or allowed.
    static func namesRecipient(_ action: MutationKind) -> Bool {
        action == .send || action == .threadedReply || action == .allowChat
    }

    /// The chat line, for example `Juan, +15512345678 on iMessage`. A label that is the handle itself isn't shown
    /// twice, an empty service is left out, and with no handle the line is the label alone. A threaded reply is typed
    /// through Reply to Last Message… and Messages picks its service, so its line names no service:
    /// `Sam Lee, +16505550142, reply in thread`.
    static func chatValue(_ label: String, handle: String?, service: String?, inThread: Bool = false) -> String {
        guard let handle, !handle.isEmpty else { return label }
        var recipient = handle
        if inThread {
            recipient += ", reply in thread"
        } else if let service, !service.isEmpty {
            recipient += " on " + service
        }
        return label == handle ? recipient : label + ", " + recipient
    }

    static func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// The caption under a value too tall to show at once. Lines are counted at each line break.
    static func sizeCaption(for value: String) -> String {
        let lines = value.reduce(1) { $1.isNewline ? $0 + 1 : $0 }
        let characters = value.count
        return "\(lines) \(lines == 1 ? "line" : "lines"), \(characters) \(characters == 1 ? "character" : "characters")."
            + " Scroll to read all of it."
    }
}

/// Turns button presses into one decision. Deny always counts. An allow before `enabledAt` is ignored, and so is
/// "Always allow" when the prompt didn't offer it. After the first decision or a withdraw, nothing counts.
/// Main thread only.
final class ApprovalDecisionSession {
    let offersAlwaysAllow: Bool
    let enabledAt: TimeInterval
    private let decided: (ApprovalDecision) -> Void
    private(set) var isDone = false

    init(offersAlwaysAllow: Bool, enabledAt: TimeInterval, decided: @escaping (ApprovalDecision) -> Void) {
        self.offersAlwaysAllow = offersAlwaysAllow
        self.enabledAt = enabledAt
        self.decided = decided
    }

    /// Returns true if the press counted.
    @discardableResult
    func press(_ decision: ApprovalDecision, at uptime: TimeInterval) -> Bool {
        guard !isDone else { return false }
        switch decision {
        case .deny:
            break
        case .allowOnce:
            guard uptime >= enabledAt else { return false }
        case .alwaysAllow:
            guard offersAlwaysAllow, uptime >= enabledAt else { return false }
        }
        isDone = true
        decided(decision)
        return true
    }

    func withdraw() { isDone = true }
}

/// The panel itself. Escape and Return both deny.
final class ApprovalPanel: NSPanel {
    static let styleMask: NSWindow.StyleMask = [.titled, .nonactivatingPanel, .utilityWindow]
    static let panelLevel: NSWindow.Level = .statusBar
    static let collection: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    static let valueWidth: CGFloat = 408
    /// The tallest a value's text view gets. Taller text scrolls.
    static let valueMaxHeight: CGFloat = 160

    private let session: ApprovalDecisionSession
    private(set) var content: ApprovalPanelContent!

    init(model: ApprovalPanelModel, session: ApprovalDecisionSession, cascade: Int) {
        self.session = session
        super.init(contentRect: NSRect(x: 0, y: 0, width: 440, height: 200),
                   styleMask: ApprovalPanel.styleMask, backing: .buffered, defer: false)
        title = AppIdentity.appName
        // Setting `isFloatingPanel` resets the level to `.floating`, so it goes first.
        isFloatingPanel = true
        level = ApprovalPanel.panelLevel
        collectionBehavior = ApprovalPanel.collection
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        let content = ApprovalPanel.makeContent(model, target: self, deny: { [weak self] in self?.press(.deny) })
        self.content = content
        contentView = content.view
        setContentSize(content.view.fittingSize)
        center()
        let offset = CGFloat(cascade % 8) * 24
        setFrameOrigin(NSPoint(x: frame.origin.x + offset, y: frame.origin.y - offset))
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) { press(.deny) }

    var allowButtons: [NSButton] { content.allowButtons }

    func enableAllowButtons() {
        for button in content.allowButtons { button.isEnabled = true }
    }

    private func press(_ decision: ApprovalDecision) {
        session.press(decision, at: ProcessInfo.processInfo.systemUptime)
    }

    @objc func denyPressed(_ sender: Any?) { press(.deny) }
    @objc func allowOncePressed(_ sender: Any?) { press(.allowOnce) }
    @objc func alwaysAllowPressed(_ sender: Any?) { press(.alwaysAllow) }

    /// Builds the panel's views without a window, so tests can check what it shows. `target` gets the button actions
    /// (`denyPressed`, `allowOncePressed`, `alwaysAllowPressed`). `deny` runs when Return or Escape reaches a value's
    /// text view.
    static func makeContent(_ model: ApprovalPanelModel, target: AnyObject?,
                            deny: @escaping () -> Void) -> ApprovalPanelContent {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)

        let heading = NSTextField(wrappingLabelWithString: model.title)
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 1)
        heading.preferredMaxLayoutWidth = valueWidth
        stack.addArrangedSubview(heading)

        var values: [ApprovalPanelContent.Value] = []
        for line in model.lines {
            let label = NSTextField(labelWithString: line.label)
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
            stack.addArrangedSubview(label)
            let value = valueView(line.value, label: line.label, deny: deny)
            stack.addArrangedSubview(value.scrollView)
            if let caption = value.caption { stack.addArrangedSubview(caption) }
            values.append(value)
        }

        let reason = NSTextField(wrappingLabelWithString: model.reason)
        reason.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        reason.textColor = .secondaryLabelColor
        reason.preferredMaxLayoutWidth = valueWidth
        stack.addArrangedSubview(reason)

        let denyButton = NSButton(title: ApprovalPanelModel.denyTitle, target: target,
                                  action: #selector(ApprovalPanel.denyPressed(_:)))
        denyButton.keyEquivalent = "\r"
        var allow = [allowButton(ApprovalPanelModel.allowOnceTitle, target: target,
                                 action: #selector(ApprovalPanel.allowOncePressed(_:)))]
        if model.showsAlwaysAllow {
            allow.append(allowButton(ApprovalPanelModel.alwaysAllowTitle, target: target,
                                     action: #selector(ApprovalPanel.alwaysAllowPressed(_:))))
        }
        let row = NSStackView(views: [denyButton] + allow)
        row.orientation = .horizontal
        row.spacing = 8
        stack.addArrangedSubview(row)
        return ApprovalPanelContent(view: stack, values: values, deny: denyButton, allowButtons: allow)
    }

    /// No key equivalent, disabled until the button delay passes, and never first responder, so Tab and Space can't
    /// press it. A click still does.
    private static func allowButton(_ title: String, target: AnyObject?, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.keyEquivalent = ""
        button.isEnabled = false
        button.refusesFirstResponder = true
        return button
    }

    /// The whole value in a read-only text view, at most `valueMaxHeight` tall, with a vertical scroller. When the
    /// text needs more room, a caption under it gives the line and character count.
    static func valueView(_ text: String, label: String, deny: @escaping () -> Void) -> ApprovalPanelContent.Value {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: valueWidth, height: valueMaxHeight))
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = false
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = false
        let size = scroll.contentSize

        // TextKit 1, built by hand, so the height can be measured before the view is on screen.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: size.width, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        let textView = ApprovalValueTextView(frame: NSRect(origin: .zero, size: size), textContainer: container)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.usesFontPanel = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 2, height: 4)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.string = text
        textView.deny = deny
        scroll.documentView = textView

        layout.ensureLayout(for: container)
        let needed = ceil(layout.usedRect(for: container).height + 2 * textView.textContainerInset.height)
        let border = scroll.frame.height - size.height
        let overflows = needed > valueMaxHeight - border
        let height = min(needed + border, valueMaxHeight)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalToConstant: valueWidth),
            scroll.heightAnchor.constraint(equalToConstant: height),
        ])

        var caption: NSTextField?
        if overflows {
            let note = NSTextField(wrappingLabelWithString: ApprovalPanelModel.sizeCaption(for: text))
            note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            note.textColor = .secondaryLabelColor
            note.preferredMaxLayoutWidth = valueWidth
            caption = note
        }
        return ApprovalPanelContent.Value(label: label, scrollView: scroll, textView: textView, caption: caption)
    }
}

/// The views `ApprovalPanel.makeContent` builds.
struct ApprovalPanelContent {
    struct Value {
        let label: String
        let scrollView: NSScrollView
        let textView: NSTextView
        /// Set only when the text is taller than the view.
        let caption: NSTextField?
    }

    let view: NSView
    /// One per `ApprovalPanelModel.lines` entry, in order.
    let values: [Value]
    let deny: NSButton
    let allowButtons: [NSButton]
}

/// A value's text view. Read-only, so Return and Escape have nothing to do here. They deny, as they do anywhere else
/// in the panel.
final class ApprovalValueTextView: NSTextView {
    var deny: () -> Void = {}

    override func insertNewline(_ sender: Any?) { deny() }
    override func cancelOperation(_ sender: Any?) { deny() }
}
