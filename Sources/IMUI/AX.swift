import ApplicationServices
import Foundation
import IMCore
import IMStore

/// Opaque handle to an AX element, valid until the next `MessagesAXDriving` snapshot call. Fakes use plain ids.
public struct AXRef: Hashable, Sendable {
    public var id: UInt64

    public init(id: UInt64) { self.id = id }
}

/// One conversation row in the sidebar, as AX reports it.
public struct ConversationRowInfo: Hashable, Sendable {
    public var ref: AXRef
    /// The row's full AX description: name, preview and time as Messages renders them.
    public var description: String
    /// `AXSelected`, or nil when it reads unknown: the row lacks the attribute, has no value, or holds something
    /// other than a Bool.
    public var isSelected: Bool?
    /// The row's action names as Messages lists them, for example "Mark as Unread" and "Open in New Window".
    /// `ChatTargeter` acts on a row's chat only if they include Messages' English row actions.
    public var actionNames: [String]

    public init(ref: AXRef, description: String, isSelected: Bool?,
                actionNames: [String] = UINames.englishRowActions) {
        self.ref = ref
        self.description = description
        self.isSelected = isSelected
        self.actionNames = actionNames
    }
}

/// One loaded message bubble (AXIdentifier `Sticker` in S3), newest last.
public struct BubbleInfo: Hashable, Sendable {
    public var ref: AXRef
    public var fromMe: Bool
    /// Text of the `CKBalloonTextView`, NFC.
    public var text: String
    /// The bubble's time, to the minute, parsed from its description.
    public var minuteLabel: String
    public var hasTextBubble: Bool
    /// Named actions with the `Name:` prefix and trailing lines stripped, for example "Heart", "Undo Send", "Edit".
    public var actionNames: [String]
    /// The bubble's AX description, NFC: "Your iMessage, <text>, 4:33 PM" or "<sender>, <text>, <time>".
    public var axDescription: String
    /// An `AXGroup` with no children and no text view. Messages 26 shows a text holding a date or time it detected
    /// this way, with the text only in the description (live test, 2026-11-11). The file attachment S2 recorded was
    /// an `AXButton`, so it is not bare.
    public var isBareGroup: Bool

    public init(ref: AXRef, fromMe: Bool, text: String, minuteLabel: String, hasTextBubble: Bool,
                actionNames: [String], axDescription: String = "", isBareGroup: Bool = false) {
        self.ref = ref
        self.fromMe = fromMe
        self.text = text
        self.minuteLabel = minuteLabel
        self.hasTextBubble = hasTextBubble
        self.actionNames = actionNames
        self.axDescription = axDescription
        self.isBareGroup = isBareGroup && !hasTextBubble
    }

    /// A bubble that shows a text row: one with a text view, or a bare group. Anything else, such as an
    /// attachment, is not compared with text rows at all.
    public var showsText: Bool { hasTextBubble || isBareGroup }

    /// True when this bubble shows `text` from that direction. A bubble with a `CKBalloonTextView` compares that
    /// view's text. A bare group compares its description (`BubbleDescription.carries`). Any other bubble shows no
    /// text, whatever its description says.
    public func shows(_ text: String, fromMe: Bool) -> Bool {
        guard self.fromMe == fromMe else { return false }
        if hasTextBubble { return TextNorm.matchKey(self.text) == TextNorm.matchKey(text) }
        return isBareGroup && BubbleDescription.carries(axDescription, text: text, fromMe: fromMe)
    }
}

/// The composer (`messageBodyField`) or an edit field.
public struct FieldInfo: Hashable, Sendable {
    public var ref: AXRef
    /// The field's text as read. A driver whose read of it fails throws instead of returning a `FieldInfo`.
    public var value: String
    /// For an edit field, the bubble it belongs to.
    public var owningBubble: AXRef?

    public init(ref: AXRef, value: String, owningBubble: AXRef?) {
        self.ref = ref
        self.value = value
        self.owningBubble = owningBubble
    }
}

public struct MenuItemInfo: Hashable, Sendable {
    public var ref: AXRef
    public var title: String
    public var enabled: Bool

    public init(ref: AXRef, title: String, enabled: Bool) {
        self.ref = ref
        self.title = title
        self.enabled = enabled
    }
}

/// The thread view a threaded reply opens, with the parent bubble it shows.
public struct ThreadViewInfo: Hashable, Sendable {
    public var ref: AXRef
    public var parent: BubbleInfo?

    public init(ref: AXRef, parent: BubbleInfo?) {
        self.ref = ref
        self.parent = parent
    }
}

public enum AXDriveError: Error, Hashable, Sendable {
    case notTrusted
    case notRunning
    case staleReference
    case actionMissing(String)
    case axError(Int32)
    /// Right before a row press in `press(row:)`, which nothing calls now, Messages was no longer hidden with one
    /// window (the user may have shown it), so nothing was pressed. Carries the state that failed the window rules.
    case messagesVisible(MessagesAppState)
    /// A tree walk reached its node cap with nodes left unread, so it can't show that something is absent.
    case walkLimit
    /// More than one edit field shows, so none of them can be called the edit in progress.
    case severalEditFields
}

/// The caller's last check before an AX mutation. The driver runs it after all its own reads for that mutation (the
/// element's description or title, its action names, the window rules) and right before
/// `AXUIElementPerformAction` or `AXUIElementSetAttributeValue`, with no read in between. If it throws, nothing is
/// pressed or written and the caller gets its own error back unchanged. Every mutation call passes one; a call with
/// nothing to check passes `{}`.
public typealias AXFinalCheck = () throws -> Void

/// Accessibility access to Messages, limited to what DESIGN.md section 4 (Targeting) allows: named actions, reads,
/// and value writes to the composer or an edit field. No arbitrary paths, no other apps, no System Events.
/// Live: `LiveMessagesAX`. Tests: a scripted fake. Each mutation takes an `AXFinalCheck` and runs it last, after the
/// reads it makes itself, so no read can block between the caller's check and the press or write.
public protocol MessagesAXDriving: AnyObject {
    /// AX windows of Messages.
    func windowCount() throws -> Int
    func conversationRows() throws -> [ConversationRowInfo]
    /// What the conversation list shows (`ConversationListRule.state`): no list, a list still loading (placeholder
    /// children and no `AXStaticText` row among them), a list with rows and placeholders, or a loaded list. Reads
    /// the children's roles, and the descriptions of those that aren't rows, and hands out no refs.
    func conversationListState() throws -> ConversationListState
    /// `AXPress` on a conversation row. Live, it checks the window rules after its description read and throws
    /// `messagesVisible` (or `notRunning`) instead of pressing if Messages isn't hidden with one window. Then
    /// `finalCheck`, then the press. Nothing calls it now, since `ChatTargeter.selectChat` acts only on a chat that is
    /// already selected. It is kept for the chat switch flows, which wait for probes (research/chat-switch.md).
    func press(row: AXRef, finalCheck: AXFinalCheck) throws
    func loadedBubbles() throws -> [BubbleInfo]
    /// `AXUIElementPerformAction` with the full `Name:<action>` string, after the description and action-name reads
    /// and `finalCheck`.
    func perform(action: String, on bubble: AXRef, finalCheck: AXFinalCheck) throws
    /// Nil when no composer shows. Throws when a read fails, its value included, so a failed read never shows as an
    /// empty composer. `editField` and `focusedField` throw the same way.
    func composer() throws -> FieldInfo?
    /// An edit field other than the composer, if one is open. Throws `severalEditFields` when more than one shows.
    func editField() throws -> FieldInfo?
    /// The text field Messages has focused (the app's `AXFocusedUIElement`), only if it is an `AXTextField` that
    /// isn't a search field. Read only: nothing sets focus, because section 4 allows only value writes. The same
    /// element gets the same ref here as from `composer` and `editField`.
    func focusedField() throws -> FieldInfo?
    func threadView() throws -> ThreadViewInfo?
    /// True when the main transcript is showing (no edit field, no thread view).
    func showsMainTranscript() throws -> Bool
    /// A Messages menu bar item by exact title, for example "Reply to Last Message…". Only titles
    /// `UINames.mayLookUpMenuItem` allows.
    func menuItem(titled title: String) throws -> MenuItemInfo?
    /// Presses an item only when `UINames.mayPressMenuItem` allows its title, after the title read and `finalCheck`.
    func press(menuItem: AXRef, finalCheck: AXFinalCheck) throws
    /// `kAXValueAttribute` write, right after `finalCheck`. Foreground mode only.
    func setValue(_ value: String, of field: AXRef, finalCheck: AXFinalCheck) throws
    func readValue(of field: AXRef) throws -> String
}

/// `AXIsProcessTrusted` with and without the prompt option. Owner: IMUI.
public enum AXTrust {
    public static func isTrusted() -> Bool { AXIsProcessTrusted() }

    /// Raises the Accessibility prompt (setup and doctor only).
    public static func prompt() -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
}

/// Maps `AXRef` ids to live elements. Ids are never reused. An element seen again with the same fingerprint (its
/// description or title) keeps its id. One seen with a different fingerprint gets a new id and the old id goes
/// stale, because Messages reuses row and bubble views for other content. Past `capacity` the oldest half is dropped.
/// Thread safe.
final class RefTable<Element: Hashable> {
    enum Kind: Hashable {
        case row, bubble, field, menuItem, thread
    }

    struct Entry {
        var element: Element
        var kind: Kind
        /// What the element showed when it was handed out. Callers compare it again before acting.
        var fingerprint: String
        /// For a bubble, the container that keeps its description in edit mode.
        var container: Element?
    }

    private struct Key: Hashable {
        var element: Element
        var kind: Kind
    }

    let capacity: Int
    private let lock = NSLock()
    private var nextID: UInt64 = 1
    private var entries: [UInt64: Entry] = [:]
    private var ids: [Key: UInt64] = [:]

    init(capacity: Int = 4096) { self.capacity = max(2, capacity) }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    func register(_ element: Element, kind: Kind, fingerprint: String, container: Element? = nil) -> AXRef {
        lock.lock()
        defer { lock.unlock() }
        let key = Key(element: element, kind: kind)
        if let id = ids[key], let entry = entries[id] {
            if entry.fingerprint == fingerprint {
                entries[id]?.container = container
                return AXRef(id: id)
            }
            entries[id] = nil
            ids[key] = nil
        }
        if entries.count >= capacity { evictOldestHalf() }
        let id = nextID
        nextID += 1
        entries[id] = Entry(element: element, kind: kind, fingerprint: fingerprint, container: container)
        ids[key] = id
        return AXRef(id: id)
    }

    /// The entry for `ref`, or `staleReference` if it was dropped, never handed out, or is of another kind.
    func entry(for ref: AXRef, kind: Kind) throws -> Entry {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[ref.id], entry.kind == kind else { throw AXDriveError.staleReference }
        return entry
    }

    private func evictOldestHalf() {
        let drop = entries.keys.sorted().prefix(entries.count / 2 + 1)
        for id in drop {
            if let entry = entries.removeValue(forKey: id) { ids[Key(element: entry.element, kind: entry.kind)] = nil }
        }
    }
}

/// Direction and minute from a bubble's AX description: "Your iMessage, <text>, 9:38 AM" for the user's own
/// messages, "<sender>, <text>, <time>" for others (S3).
enum BubbleDescription {
    /// First components that mark the user's own message.
    static let ownPrefixes: Set<String> = ["Your iMessage", "Your SMS", "Your text message", "Your RCS message",
                                           "Your message"]

    static func parse(_ description: String) -> (fromMe: Bool, minute: String) {
        let text = normalizeSpaces(description)
        let first = text.range(of: ", ").map { String(text[..<$0.lowerBound]) } ?? text
        let last = text.range(of: ", ", options: .backwards).map { String(text[$0.upperBound...]) } ?? ""
        return (ownPrefixes.contains(first), isMinute(last) ? last : "")
    }

    /// True when `description` reads only one way, as the direction, `text` and a minute. The user's own message is
    /// "<own prefix>, <text>, <minute>": the prefix is fixed, so `text` may hold ", ". Anyone else's is
    /// "<sender>, <text>, <minute>", and the sender is a name with no fixed end, so that form counts only with
    /// exactly three components. A sender or a text with ", " in it could be split another way, so it never
    /// matches. Spaces in the minute compare as in `normalizeSpaces`, and the text as in `TextNorm.matchKey`, as a
    /// text view's text does.
    static func carries(_ description: String, text: String, fromMe: Bool) -> Bool {
        let wanted = TextNorm.matchKey(text)
        guard !wanted.isEmpty else { return false }
        let full = description.precomposedStringWithCanonicalMapping
        guard let last = full.range(of: ", ", options: .backwards),
              isMinute(normalizeSpaces(String(full[last.upperBound...]))),
              let first = full.range(of: ", "), first.upperBound <= last.lowerBound else { return false }
        let sender = String(full[..<first.lowerBound])
        let body = String(full[first.upperBound..<last.lowerBound])
        if fromMe {
            guard ownPrefixes.contains(sender) else { return false }
        } else {
            guard !sender.isEmpty, !ownPrefixes.contains(sender), !body.contains(", ") else { return false }
        }
        let key = TextNorm.matchKey(body)
        return !endsLikeAnAttachment(key) && key == wanted
    }

    /// True when `body` ends as an attachment description's middle does, with a kind and a size:
    /// "s2-a8734a42.txt, Text Document · 23 bytes", as S2 recorded it, with U+00B7 and plain spaces. `carries` passes
    /// the text after `TextNorm.matchKey`, the form it compares. No recorded attachment is a bare group, but a
    /// description that reads like one never stands in for a text row.
    static func endsLikeAnAttachment(_ body: String) -> Bool {
        guard let comma = body.range(of: ", ", options: .backwards),
              let dot = body[comma.upperBound...].range(of: " · ", options: .backwards) else { return false }
        let size = body[dot.upperBound...].split(separator: " ", omittingEmptySubsequences: false)
        guard size.count == 2, let number = size.first, !number.isEmpty,
              number.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "." || $0 == ",") }) else { return false }
        return ["byte", "bytes", "KB", "MB", "GB"].contains(String(size[1]))
    }

    /// `BubbleInfo.isBareGroup` from a `Sticker`'s shape: no text view, the role `AXGroup` and no children. The role is
    /// read only without a text view, and the children only for an `AXGroup`. A failed read throws.
    static func isBareGroup(hasTextView: Bool, role: () throws -> String, childCount: () throws -> Int) rethrows
        -> Bool {
        guard !hasTextView, try role() == "AXGroup" else { return false }
        return try childCount() == 0
    }

    /// Messages writes bubble times with U+202F before AM or PM. S3 saw rows with a plain space, but row matching
    /// (`ChatTargeter.sameRowText`) reads both through this too.
    static func normalizeSpaces(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    /// `h:mm AM` or `hh:mm PM`, as `RowDescriptionBuilder.minuteLabel` writes it.
    static func isMinute(_ s: String) -> Bool {
        let parts = s.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[1] == "AM" || parts[1] == "PM" else { return false }
        let clock = parts[0].split(separator: ":", omittingEmptySubsequences: false)
        guard clock.count == 2, (1...2).contains(clock[0].count), clock[1].count == 2,
              let hour = Int(clock[0]), let minute = Int(clock[1]),
              clock[0].allSatisfy(\.isASCII), clock[1].allSatisfy(\.isASCII) else { return false }
        return (1...12).contains(hour) && (0...59).contains(minute)
    }
}

/// The short name of an AX action: "Name:Heart\nTarget:..." gives "Heart". Plain names are kept as they are.
func shortActionName(_ full: String) -> String {
    guard full.hasPrefix("Name:") else { return full }
    let firstLine = full.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
    return String(firstLine.dropFirst(5))
}

/// `AXError` to the driver's error cases.
func axDriveError(_ error: AXError, action: String? = nil) -> AXDriveError {
    switch error {
    case .apiDisabled: return .notTrusted
    case .invalidUIElement: return .staleReference
    case .actionUnsupported: return .actionMissing(action ?? "")
    default: return .axError(error.rawValue)
    }
}

/// What `walkAXTree` does after visiting a node.
enum AXWalkStep {
    /// Read the node's children and visit them.
    case descend
    /// Leave the node's children unread.
    case skipChildren
    /// End the walk.
    case stop
}

/// Throws `AXDriveError.axError(cannotComplete)` for `.cannotComplete`, the error AX returns when Messages doesn't
/// answer within the messaging timeout.
func throwIfTimedOut(_ error: AXError) throws {
    if error == .cannotComplete { throw AXDriveError.axError(AXError.cannotComplete.rawValue) }
}

/// How the live driver treats the error of one AX attribute read. An element that lacks the attribute reports
/// `noValue` or `attributeUnsupported`, and that reads as absent: no identifier, no children. Every other error,
/// the messaging timeout's `cannotComplete` included, throws, so a check that needs a value never gets "" or "no
/// children" in place of a read that failed.
enum AXRead {
    /// True when the read gave a value, false when the element lacks the attribute. Throws for any other error.
    static func present(_ error: AXError) throws -> Bool {
        switch error {
        case .success: return true
        case .noValue, .attributeUnsupported: return false
        default: throw axDriveError(error)
        }
    }

    /// The value of one read, nil when the element lacks the attribute. Throws for a failed read.
    static func optional(_ error: AXError, _ value: CFTypeRef?) throws -> CFTypeRef? {
        try present(error) ? value : nil
    }

    /// A text field's `AXValue`. Only a successful read of a string counts. An error, no value or a value that isn't
    /// a string throws, so a composer or edit field that can't be read is never taken as empty.
    static func fieldValue(_ error: AXError, _ value: CFTypeRef?) throws -> String {
        guard error == .success else { throw axDriveError(error) }
        guard let string = value as? String else { throw AXDriveError.axError(AXError.noValue.rawValue) }
        return string
    }
}

/// A depth-first walk from `root` at depth 0, children in order, bounded by `maxDepth` and by `maxNodes` visits.
/// `readChildren` returns a node's children and the `AXError` of that read. A node that lacks children (`noValue`,
/// `attributeUnsupported`) has none. Any other error ends the walk and is thrown (`AXRead.present`), so a stalled
/// Messages or a failed read gives an error, not a partial result. `visit` gets the node, its parent and its depth.
/// A node within `maxDepth` left unvisited after `maxNodes` visits throws `AXDriveError.walkLimit` for the same
/// reason. A walk that `visit` stops, and nodes below `maxDepth`, don't.
func walkAXTree<Node>(from root: Node, maxDepth: Int, maxNodes: Int,
                      readChildren: (Node) -> (children: [Node], error: AXError),
                      visit: (_ node: Node, _ parent: Node?, _ depth: Int) throws -> AXWalkStep) throws {
    var visited = 0
    var stopped = false
    func walk(_ node: Node, parent: Node?, depth: Int) throws {
        guard !stopped, depth <= maxDepth else { return }
        guard visited < maxNodes else { throw AXDriveError.walkLimit }
        visited += 1
        switch try visit(node, parent, depth) {
        case .stop:
            stopped = true
            return
        case .skipChildren:
            return
        case .descend:
            break
        }
        guard depth < maxDepth else { return }
        let read = readChildren(node)
        guard try AXRead.present(read.error) else { return }
        for child in read.children {
            try walk(child, parent: node, depth: depth + 1)
            if stopped { return }
        }
    }
    try walk(root, parent: nil, depth: 0)
}

/// A node as `ThreadViewRule` sees it: its AXIdentifier and its ancestors' identifiers, root first.
struct AXNodeSummary: Hashable {
    var identifier: String
    var ancestorIdentifiers: [String]
}

/// Which element is the thread view a threaded reply opens (section 4 steps 1 and 6). No spike captured one, so
/// release test 4 checks it.
enum ThreadViewRule {
    /// Subtrees that never hold the thread view: bubbles (a reply count inside a bubble may mention a thread) and the
    /// conversation list.
    static let excludedAncestors: Set<String> = ["Sticker", "ConversationList"]

    /// True for an element whose identifier contains "thread" in any case and that isn't inside a bubble or the
    /// conversation list.
    static func namesThreadView(_ node: AXNodeSummary) -> Bool {
        node.identifier.range(of: "thread", options: .caseInsensitive) != nil
            && !node.ancestorIdentifiers.contains(where: excludedAncestors.contains)
    }

    /// The index in `nodes` (walk order) of the thread view: the first node `namesThreadView` accepts, else the
    /// second `TranscriptCollectionView`, else nil.
    static func pick(_ nodes: [AXNodeSummary]) -> Int? {
        if let named = nodes.firstIndex(where: namesThreadView) { return named }
        let transcripts = nodes.indices.filter { nodes[$0].identifier == "TranscriptCollectionView" }
        return transcripts.count > 1 ? transcripts[1] : nil
    }
}

/// What `MessagesAXDriving.conversationListState` read.
public enum ConversationListState: Hashable, Sendable {
    /// No window, or a window with no `ConversationList` element.
    case missing
    /// The list has children, none of its direct children is an `AXStaticText` row, and at least one is a placeholder.
    case loading
    /// Some direct child is an `AXStaticText` row and some other is a placeholder (`ConversationListChild`). Right
    /// after a launch, rows may still be filling in. On a warm Messages it may be a pinned tile, so `ChatTargeter`
    /// counts it as loading only within `listLoadTimeout` of its own launch.
    case partlyLoaded
    /// No direct child is a placeholder: some are `AXStaticText` rows, or all of them have descriptions (pinned tiles,
    /// say), or the list has no children.
    case loaded
}

/// A direct child of the conversation list, as `ConversationListRule` sorts it.
enum ConversationListChild: Hashable {
    /// An `AXStaticText` conversation row.
    case row
    /// Not `AXStaticText` and no `AXDescription`, like the groups Messages shows before it fills in the rows.
    case placeholder
    /// Not `AXStaticText`, with a description.
    case other
}

/// When the conversation list counts as still loading. About 1 to 2 s after a hidden launch its direct children were
/// all `AXGroup` with no description, and about 6 s after it they were all `AXStaticText` rows
/// (research/live-tests/2026-11-07-sends.md, Conversation rows after a hidden launch). Nothing sampled the list in
/// between, so a list with some rows may still hold placeholders, one of them the target's. Pinned chats may show as
/// tiles that aren't `AXStaticText`, so a child that isn't a row doesn't by itself mean the list is loading.
enum ConversationListRule {
    /// `missing` with no list (`children` nil), `loading` with placeholders and no row, `partlyLoaded` with a row and
    /// a placeholder, otherwise `loaded`. A list with no children, or whose children all have descriptions, reads
    /// loaded, so a warm Messages that shows only pinned tiles never waits.
    static func state(children: [ConversationListChild]?) -> ConversationListState {
        guard let children else { return .missing }
        guard children.contains(.placeholder) else { return .loaded }
        return children.contains(.row) ? .partlyLoaded : .loading
    }

    /// Sorts one child by its role. `description` is read only for a child that isn't `AXStaticText`, and a child
    /// without the attribute reads "" there, so it counts as a placeholder.
    static func child(role: String, description: () throws -> String) rethrows -> ConversationListChild {
        if role == "AXStaticText" { return .row }
        return try description().isEmpty ? .placeholder : .other
    }
}

/// An `AXUIElement` usable as a dictionary key (`CFEqual` and `CFHash`).
struct AXElement: Hashable {
    let raw: AXUIElement

    static func == (a: AXElement, b: AXElement) -> Bool { CFEqual(a.raw, b.raw) }
    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(raw)) }
}

/// Live AX driver over `AXUIElementCreateApplication(pid)`. Owner: IMUI.
/// Element ids from S3: bubbles `Sticker`, text `CKBalloonTextView`, composer `messageBodyField`.
///
/// - Reads only Messages' one window, the transcript, the conversation list, the menu bar and the app's focused
///   text field. More than one window is an error, so a press can't land in a second window.
/// - Runs only the bubble actions `UINames.isAllowedBubbleAction` allows, presses only the menu items in
///   `UINames.allowedMenuTitles` (it looks up `lookupOnlyMenuTitles` too but never presses them), and writes values
///   only to the composer, an edit field or the focused reply field. `press(row:)` can press a row with `AXPress`,
///   but nothing calls it now.
/// - Before acting on a ref it re-reads the element's description or title and refuses with `staleReference` if
///   it changed or can't be read. `press(row:)` also checks the window rules again and refuses with
///   `messagesVisible`. The caller's `AXFinalCheck` runs after all of these, as the line right before
///   `AXUIElementPerformAction` or `AXUIElementSetAttributeValue`.
/// - Every AX read gets `messagingTimeout`. A failed read, a timeout included, throws (`AXRead`) and ends any tree
///   walk. Only an attribute the element lacks reads as "" or no children, and a field's value must read as a string.
///   A walk that reaches `maxNodes` with nodes left throws `walkLimit`, so no read returns part of the window.
public final class LiveMessagesAX: MessagesAXDriving {
    public let app: MessagesAppControl

    static let maxDepth = 40
    static let maxNodes = 20_000
    static let messagingTimeout: Float = 2

    private let refs = RefTable<AXElement>()
    private let lock = NSLock()
    private var pendingEdit: (bubble: AXRef, container: AXElement?, description: String)?

    public init(app: MessagesAppControl) {
        self.app = app
        // A timeout set on one element covers only that element. Set on the system-wide element, it is the default
        // for every element this process reads, so windows, rows and bubbles copied from the application element
        // get the same 2 s.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), Self.messagingTimeout)
    }

    public func windowCount() throws -> Int {
        try windows().count
    }

    public func conversationRows() throws -> [ConversationRowInfo] {
        guard let list = try conversationList() else { return [] }
        return try Self.children(of: list).compactMap { row in
            guard try Self.string(row, "AXRole") == "AXStaticText" else { return nil }
            let description = try Self.string(row, "AXDescription")
            let ref = refs.register(AXElement(raw: row), kind: .row, fingerprint: description)
            return ConversationRowInfo(ref: ref, description: description,
                                       isSelected: try Self.bool(row, "AXSelected"),
                                       actionNames: try Self.actionNamesOrThrow(row).map(shortActionName))
        }
    }

    /// `ConversationListRule.state` on the list's direct children, each sorted by `ConversationListRule.child`. With
    /// no window there is no list either, so that reads `missing` too.
    public func conversationListState() throws -> ConversationListState {
        guard let list = try conversationList() else { return ConversationListRule.state(children: nil) }
        let children = try Self.children(of: list).map { child in
            try ConversationListRule.child(role: try Self.string(child, "AXRole"),
                                           description: { try Self.string(child, "AXDescription") })
        }
        return ConversationListRule.state(children: children)
    }

    /// Unused for now and kept for the chat switch flows, which wait for probes. See the protocol requirement.
    public func press(row: AXRef, finalCheck: AXFinalCheck) throws {
        try requireTrust()
        let entry = try refs.entry(for: row, kind: .row)
        try Self.requireUnchanged(entry.element.raw, "AXDescription", fingerprint: entry.fingerprint)
        // The window rules again, the last read before the press: the user may have shown Messages since `prepare`.
        try Self.requireHiddenWindow(hiddenWindowState())
        try finalCheck()
        try Self.check(AXUIElementPerformAction(entry.element.raw, "AXPress" as CFString), action: "AXPress")
    }

    public func loadedBubbles() throws -> [BubbleInfo] {
        guard let window = try singleWindow(),
              let transcript = try Self.first(in: window, where: Self.isTranscript) else { return [] }
        return try bubbles(in: transcript)
    }

    public func perform(action: String, on bubble: AXRef, finalCheck: AXFinalCheck) throws {
        guard UINames.isAllowedBubbleAction(action) else { throw AXDriveError.actionMissing(action) }
        try requireTrust()
        let entry = try refs.entry(for: bubble, kind: .bubble)
        let element = entry.element.raw
        try Self.requireUnchanged(element, "AXDescription", fingerprint: entry.fingerprint)
        guard let full = Self.actionNames(element).first(where: { shortActionName($0) == action }) else {
            throw AXDriveError.actionMissing(action)
        }
        try finalCheck()
        try Self.check(AXUIElementPerformAction(element, full as CFString), action: action)
        if action == UINames.edit {
            lock.lock()
            pendingEdit = (bubble, entry.container, entry.fingerprint)
            lock.unlock()
        }
    }

    public func composer() throws -> FieldInfo? {
        guard let window = try singleWindow(),
              let field = try Self.first(in: window, where: {
                  try Self.string($0, "AXRole") == "AXTextField"
                      && Self.string($0, "AXIdentifier") == "messageBodyField"
              }) else { return nil }
        return try fieldInfo(field, owner: nil)
    }

    public func editField() throws -> FieldInfo? {
        guard let window = try singleWindow() else { return nil }
        guard let field = try Self.onlyEditField(try Self.all(in: window, where: isEditField)) else { return nil }
        return try fieldInfo(field, owner: try editOwner())
    }

    /// The one edit field among `candidates`, nil with none. More than one throws `severalEditFields`, so two
    /// showing never reads as no edit in progress.
    static func onlyEditField<Element>(_ candidates: [Element]) throws -> Element? {
        guard candidates.count <= 1 else { throw AXDriveError.severalEditFields }
        return candidates.first
    }

    public func focusedField() throws -> FieldInfo? {
        guard try singleWindow() != nil else { return nil }
        let focused = try Self.attribute(try appElement(), "AXFocusedUIElement")
        guard let field = Self.element(focused), try Self.isWritableTextField(field) else { return nil }
        return try fieldInfo(field, owner: nil)
    }

    /// An `AXTextField` that isn't a search field, by subrole or by the "Search" description S3 saw. A failed read
    /// throws, so a search field whose subrole can't be read isn't taken for a text field.
    static func isWritableTextField(_ e: AXUIElement) throws -> Bool {
        try string(e, "AXRole") == "AXTextField" && string(e, "AXSubrole") != "AXSearchField"
            && string(e, "AXDescription") != "Search"
    }

    /// One fingerprint for every field, so the composer, an edit field and the focused field keep one ref per
    /// element whichever call registered it.
    private func fieldRef(_ field: AXUIElement) -> AXRef {
        refs.register(AXElement(raw: field), kind: .field, fingerprint: "field")
    }

    /// The only place a `FieldInfo` is made. Its value comes from `fieldValue`, so a field whose value can't be read
    /// throws instead of showing as empty.
    private func fieldInfo(_ field: AXUIElement, owner: AXRef?) throws -> FieldInfo {
        FieldInfo(ref: fieldRef(field), value: try Self.fieldValue(field), owningBubble: owner)
    }

    public func threadView() throws -> ThreadViewInfo? {
        guard let window = try singleWindow(), let view = try threadCandidate(in: window) else { return nil }
        let ref = refs.register(AXElement(raw: view), kind: .thread, fingerprint: "thread")
        return ThreadViewInfo(ref: ref, parent: try bubbles(in: view).first(where: \.hasTextBubble))
    }

    public func showsMainTranscript() throws -> Bool {
        guard let window = try singleWindow() else { return false }
        let transcripts = try Self.all(in: window, where: Self.isTranscript)
        return try transcripts.count == 1 && Self.all(in: window, where: isEditField).isEmpty
            && threadCandidate(in: window) == nil
    }

    public func menuItem(titled title: String) throws -> MenuItemInfo? {
        guard UINames.mayLookUpMenuItem(title) else { throw AXDriveError.actionMissing(title) }
        guard let menuBar = Self.element(try Self.attribute(try appElement(), "AXMenuBar")) else { return nil }
        guard let item = try Self.first(in: menuBar, maxDepth: 8, where: {
            try Self.string($0, "AXRole") == "AXMenuItem" && Self.string($0, "AXTitle") == title
        }) else { return nil }
        let ref = refs.register(AXElement(raw: item), kind: .menuItem, fingerprint: title)
        return MenuItemInfo(ref: ref, title: title, enabled: try Self.bool(item, "AXEnabled") ?? false)
    }

    public func press(menuItem: AXRef, finalCheck: AXFinalCheck) throws {
        try requireTrust()
        let entry = try refs.entry(for: menuItem, kind: .menuItem)
        guard UINames.mayPressMenuItem(entry.fingerprint) else { throw AXDriveError.staleReference }
        try Self.requireUnchanged(entry.element.raw, "AXTitle", fingerprint: entry.fingerprint)
        try finalCheck()
        try Self.check(AXUIElementPerformAction(entry.element.raw, "AXPress" as CFString), action: "AXPress")
    }

    public func setValue(_ value: String, of field: AXRef, finalCheck: AXFinalCheck) throws {
        try requireTrust()
        let entry = try refs.entry(for: field, kind: .field)
        try finalCheck()
        try Self.check(AXUIElementSetAttributeValue(entry.element.raw, "AXValue" as CFString, value as CFString))
    }

    public func readValue(of field: AXRef) throws -> String {
        try requireTrust()
        let entry = try refs.entry(for: field, kind: .field)
        return try Self.fieldValue(entry.element.raw)
    }

    // MARK: - Snapshot parts

    /// The `Sticker` elements below `transcript`, in walk order. Throws if a read fails.
    private func bubbles(in transcript: AXUIElement) throws -> [BubbleInfo] {
        var result: [BubbleInfo] = []
        try walkAXTree(from: transcript, maxDepth: Self.maxDepth, maxNodes: Self.maxNodes,
                       readChildren: Self.readChildren) { element, parent, depth in
            guard depth > 0, try Self.string(element, "AXIdentifier") == "Sticker" else { return .descend }
            result.append(try bubble(element, container: parent))
            return .skipChildren
        }
        return result
    }

    private func bubble(_ sticker: AXUIElement, container: AXUIElement?) throws -> BubbleInfo {
        let description = try Self.string(sticker, "AXDescription")
        let parsed = BubbleDescription.parse(description)
        let textView = try Self.first(in: sticker, maxDepth: 4, where: {
            try Self.string($0, "AXIdentifier") == "CKBalloonTextView"
        })
        let text = try textView.map { try Self.string($0, "AXValue") } ?? ""
        let bare = try BubbleDescription.isBareGroup(hasTextView: textView != nil,
                                                     role: { try Self.string(sticker, "AXRole") },
                                                     childCount: { try Self.children(of: sticker).count })
        let names = Self.actionNames(sticker).filter { $0.hasPrefix("Name:") || !$0.hasPrefix("AX") }
        let ref = refs.register(AXElement(raw: sticker), kind: .bubble, fingerprint: description,
                                container: container.map(AXElement.init(raw:)))
        return BubbleInfo(ref: ref, fromMe: parsed.fromMe, text: text.precomposedStringWithCanonicalMapping,
                          minuteLabel: parsed.minute, hasTextBubble: textView != nil,
                          actionNames: names.map(shortActionName),
                          axDescription: description.precomposedStringWithCanonicalMapping, isBareGroup: bare)
    }

    /// An inline edit field (S3): an `AXTextField` inside a `Sticker` group, other than the composer and the search
    /// field. A failed read throws, so an edit field whose role or parent can't be read never counts as none.
    private func isEditField(_ element: AXUIElement) throws -> Bool {
        guard try Self.string(element, "AXRole") == "AXTextField",
              try Self.string(element, "AXIdentifier") != "messageBodyField",
              try Self.string(element, "AXSubrole") != "AXSearchField",
              let parent = Self.element(try Self.attribute(element, "AXParent")) else { return false }
        return try Self.string(parent, "AXIdentifier") == "Sticker"
    }

    /// The bubble the open edit field belongs to: the one "Edit" ran on, if its container still shows the same
    /// description and has lost its `Sticker` child, as in S3. A failed read throws, so it can't pass as a lost child.
    private func editOwner() throws -> AXRef? {
        lock.lock()
        let pending = pendingEdit
        lock.unlock()
        guard let pending, let container = pending.container?.raw,
              try Self.string(container, "AXDescription") == pending.description else { return nil }
        let stillShowsBubble = try Self.children(of: container).contains {
            try Self.string($0, "AXIdentifier") == "Sticker"
        }
        return stillShowsBubble ? nil : pending.bubble
    }

    /// The thread view a threaded reply opens, as `ThreadViewRule.pick` chooses it from one walk of the window.
    private func threadCandidate(in window: AXUIElement) throws -> AXUIElement? {
        var elements: [AXUIElement] = []
        var nodes: [AXNodeSummary] = []
        var path: [String] = []
        try walkAXTree(from: window, maxDepth: Self.maxDepth, maxNodes: Self.maxNodes,
                       readChildren: Self.readChildren) { element, _, depth in
            // Pre-order: cut to `depth` entries, the path holds this node's ancestors, root first.
            path.removeLast(max(0, path.count - depth))
            let identifier = try Self.string(element, "AXIdentifier")
            elements.append(element)
            nodes.append(AXNodeSummary(identifier: identifier, ancestorIdentifiers: path))
            path.append(identifier)
            return .descend
        }
        return ThreadViewRule.pick(nodes).map { elements[$0] }
    }

    // MARK: - Process and windows

    private func requireTrust() throws {
        guard AXIsProcessTrusted() else { throw AXDriveError.notTrusted }
    }

    /// `app.state()`, with the AX window count filled in as `HiddenWindowManager` fills it.
    private func hiddenWindowState() -> MessagesAppState {
        HiddenWindowManager.state(of: app, countWindows: { try windows().count })
    }

    /// Throws unless the window rules allow a hidden action in `state`: `notRunning` if Messages is gone, otherwise
    /// `messagesVisible`.
    static func requireHiddenWindow(_ state: MessagesAppState) throws {
        guard state.isRunning else { throw AXDriveError.notRunning }
        guard WindowRules.allowsHiddenAction(state) else { throw AXDriveError.messagesVisible(state) }
    }

    private func appElement() throws -> AXUIElement {
        try requireTrust()
        let pid: pid_t?
        if let live = app as? LiveMessagesApp { pid = live.runningPID() } else { pid = app.state().pid }
        guard let pid else { throw AXDriveError.notRunning }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
        return element
    }

    private func windows() throws -> [AXUIElement] {
        let application = try appElement()
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(application, "AXWindows" as CFString, &value)
        if error == .noValue { return [] }
        try Self.check(error)
        return Self.elements(value)
    }

    /// Messages' one window, nil with none, an error with more than one.
    private func singleWindow() throws -> AXUIElement? {
        let all = try windows()
        guard all.count <= 1 else { throw AXDriveError.axError(AXError.failure.rawValue) }
        return all.first
    }

    /// The window's `ConversationList` element, nil with no window or no list.
    private func conversationList() throws -> AXUIElement? {
        guard let window = try singleWindow() else { return nil }
        return try Self.first(in: window, where: { try Self.string($0, "AXIdentifier") == "ConversationList" })
    }

    // MARK: - AX helpers

    private static func isTranscript(_ element: AXUIElement) throws -> Bool {
        try string(element, "AXIdentifier") == "TranscriptCollectionView"
    }

    private static func check(_ error: AXError, action: String? = nil) throws {
        guard error == .success else { throw axDriveError(error, action: action) }
    }

    /// The attribute's value, nil when the element lacks it. A failed read throws (`AXRead.optional`).
    private static func attribute(_ element: AXUIElement, _ name: String) throws -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return try AXRead.optional(error, value)
    }

    /// A string attribute, "" only when the element lacks it. A failed read throws.
    private static func string(_ element: AXUIElement, _ name: String) throws -> String {
        try attribute(element, name) as? String ?? ""
    }

    private static func bool(_ element: AXUIElement, _ name: String) throws -> Bool? {
        try attribute(element, name) as? Bool
    }

    /// A text field's `AXValue` (`AXRead.fieldValue`): a string, or an error.
    private static func fieldValue(_ field: AXUIElement) throws -> String {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(field, "AXValue" as CFString, &value)
        return try AXRead.fieldValue(error, value)
    }

    /// Re-reads `name` right before an action and throws `staleReference` unless it still equals `fingerprint`. A
    /// failed read refuses the same way, since nothing has been pressed yet.
    private static func requireUnchanged(_ element: AXUIElement, _ name: String, fingerprint: String) throws {
        guard let current = try? string(element, name), current == fingerprint else {
            throw AXDriveError.staleReference
        }
    }

    private static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func elements(_ value: CFTypeRef?) -> [AXUIElement] {
        guard let array = value as? [AnyObject] else { return [] }
        return array.compactMap { element($0) }
    }

    /// The children and the error of one `AXChildren` read.
    private static func readChildren(_ element: AXUIElement) -> (children: [AXUIElement], error: AXError) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, "AXChildren" as CFString, &value)
        return (error == .success ? elements(value) : [], error)
    }

    /// The children of `element`, none when it lacks them. A failed read throws (`AXRead.present`).
    private static func children(of element: AXUIElement) throws -> [AXUIElement] {
        let read = readChildren(element)
        return try AXRead.present(read.error) ? read.children : []
    }

    private static func actionNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return names as? [String] ?? []
    }

    /// `actionNames`, but a read that times out throws instead of giving no names, so a stalled Messages isn't
    /// taken for one running in another language.
    private static func actionNamesOrThrow(_ element: AXUIElement) throws -> [String] {
        var names: CFArray?
        let error = AXUIElementCopyActionNames(element, &names)
        try throwIfTimedOut(error)
        return error == .success ? names as? [String] ?? [] : []
    }

    /// The first element under `root`, `root` included, that `match` accepts. Throws if a read fails.
    private static func first(in root: AXUIElement, maxDepth: Int = LiveMessagesAX.maxDepth,
                              where match: (AXUIElement) throws -> Bool) throws -> AXUIElement? {
        var found: AXUIElement?
        try walkAXTree(from: root, maxDepth: maxDepth, maxNodes: maxNodes, readChildren: readChildren) { element, _, _ in
            guard try match(element) else { return .descend }
            found = element
            return .stop
        }
        return found
    }

    /// Every element under `root`, `root` included, that `match` accepts. Throws if a read fails.
    private static func all(in root: AXUIElement,
                            where match: (AXUIElement) throws -> Bool) throws -> [AXUIElement] {
        var found: [AXUIElement] = []
        try walkAXTree(from: root, maxDepth: maxDepth, maxNodes: maxNodes, readChildren: readChildren) { element, _, _ in
            if try match(element) { found.append(element) }
            return .descend
        }
        return found
    }
}
