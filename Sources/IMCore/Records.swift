import Foundation

// Records the bridge returns and the CLI renders (DESIGN.md sections 1 and 5).
// IMStore builds them from chat.db; Format turns them into the section 5 text.
// Times are Apple-epoch nanoseconds, the unit chat.db uses (see AppleTime).

public typealias AppleNanos = Int64

/// The canonical chat identity approvals and the allowlist bind to (section 2).
/// 1:1 chats: `handle:<normalized handle>`, so a contact's iMessage and SMS chats are one identity (section 4, Chat).
/// Group chats: `group:<chat_identifier>`.
public struct CanonicalChatID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    public static func direct(handle normalized: String) -> CanonicalChatID { .init(rawValue: "handle:" + normalized) }
    public static func group(identifier: String) -> CanonicalChatID { .init(rawValue: "group:" + identifier) }

    public var isGroup: Bool { rawValue.hasPrefix("group:") }
    /// The normalized handle of a 1:1 identity, nil for a group.
    public var directHandle: String? {
        rawValue.hasPrefix("handle:") ? String(rawValue.dropFirst("handle:".count)) : nil
    }
    public var description: String { rawValue }
}

/// Allowlist scope (section 2, Allowed chats).
public enum AllowScope: String, Codable, Sendable, Hashable, Comparable {
    /// Text and tapbacks.
    case text
    /// Adds attachments.
    case files

    public static func < (a: AllowScope, b: AllowScope) -> Bool { a == .text && b == .files }
}

/// Tapback kinds (section 4, Tapback semantics; section 5 `react`).
/// chat.db types: add is `2000 + typeOffset`, remove is `3000 + typeOffset`.
public enum TapbackKind: Hashable, Sendable {
    case heart, like, dislike, laugh, emphasize, question
    /// A recent emoji tapback, type 2006 and 3006 with `associated_message_emoji`.
    case emoji(String)

    public var typeOffset: Int {
        switch self {
        case .heart: return 0
        case .like: return 1
        case .dislike: return 2
        case .laugh: return 3
        case .emphasize: return 4
        case .question: return 5
        case .emoji: return 6
        }
    }

    public var addType: Int { 2000 + typeOffset }
    public var removeType: Int { 3000 + typeOffset }

    /// The glyph Format prints in folded reactions.
    public var displayEmoji: String {
        switch self {
        case .heart: return "❤️"
        case .like: return "👍"
        case .dislike: return "👎"
        case .laugh: return "😂"
        case .emphasize: return "‼️"
        case .question: return "❓"
        case .emoji(let e): return e
        }
    }

    /// CLI kind name: heart, like, dislike, laugh, emphasize, question, or the emoji itself.
    public var wireName: String {
        switch self {
        case .heart: return "heart"
        case .like: return "like"
        case .dislike: return "dislike"
        case .laugh: return "laugh"
        case .emphasize: return "emphasize"
        case .question: return "question"
        case .emoji(let e): return e
        }
    }

    /// Parses a CLI kind name. Any other non-empty string that isn't ASCII letters is taken as an emoji.
    public init?(wireName s: String) {
        switch s.lowercased() {
        case "heart", "love": self = .heart
        case "like": self = .like
        case "dislike": self = .dislike
        case "laugh": self = .laugh
        case "emphasize", "emphasis": self = .emphasize
        case "question": self = .question
        default:
            guard !s.isEmpty, !s.unicodeScalars.allSatisfy({ $0.isASCII }) else { return nil }
            self = .emoji(s)
        }
    }

    /// Kind from a chat.db `associated_message_type` (2000 to 2006 or 3000 to 3006) and its emoji column.
    /// Any other type, such as 1000 for a sticker, returns nil.
    public init?(associatedType: Int, emoji: String?) {
        guard (2000...2006).contains(associatedType) || (3000...3006).contains(associatedType) else { return nil }
        switch associatedType % 1000 {
        case 0: self = .heart
        case 1: self = .like
        case 2: self = .dislike
        case 3: self = .laugh
        case 4: self = .emphasize
        case 5: self = .question
        case 6:
            guard let emoji, !emoji.isEmpty else { return nil }
            self = .emoji(emoji)
        default: return nil
        }
    }
}

extension TapbackKind: Codable {
    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let k = TapbackKind(wireName: s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown tapback \(s)"))
        }
        self = k
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(wireName)
    }
}

/// A short chat reference used inside other records.
public struct ChatRef: Hashable, Codable, Sendable {
    public var rowid: Int64
    /// `chat_label` in ours.py: display name, contact nickname or full name, `You (notes)`, or a formatted handle.
    public var label: String
    public var isGroup: Bool

    public init(rowid: Int64, label: String, isGroup: Bool) {
        self.rowid = rowid
        self.label = label
        self.isGroup = isGroup
    }
}

/// A candidate listed by `error: several matches` (section 5).
public struct Candidate: Hashable, Codable, Sendable {
    public var label: String
    /// Something the user can pass instead, such as a chat id or a phone number.
    public var argument: String

    public init(label: String, argument: String) {
        self.label = label
        self.argument = argument
    }
}

public enum AttachmentKind: String, Codable, Sendable, Hashable {
    case photo, video, voice, sticker, file
}

/// One attachment, printed as `[photo a9901 2.2MB]` (section 5).
public struct AttachmentRecord: Hashable, Codable, Sendable {
    public var rowid: Int64
    public var guid: String
    public var kind: AttachmentKind
    public var transferName: String
    public var mimeType: String?
    public var uti: String?
    public var totalBytes: Int64?
    public var width: Int?
    public var height: Int?
    public var durationSeconds: Double?
    /// Voice transcript from `attachment.user_info` `audio-transcription`.
    public var transcript: String?
    /// False for iCloud-offloaded files (`att` returns `not_downloaded`).
    public var onDisk: Bool
    public var transferState: Int

    public init(rowid: Int64, guid: String, kind: AttachmentKind, transferName: String, mimeType: String? = nil,
                uti: String? = nil, totalBytes: Int64? = nil, width: Int? = nil, height: Int? = nil,
                durationSeconds: Double? = nil, transcript: String? = nil, onDisk: Bool = true, transferState: Int = 5) {
        self.rowid = rowid
        self.guid = guid
        self.kind = kind
        self.transferName = transferName
        self.mimeType = mimeType
        self.uti = uti
        self.totalBytes = totalBytes
        self.width = width
        self.height = height
        self.durationSeconds = durationSeconds
        self.transcript = transcript
        self.onDisk = onDisk
        self.transferState = transferState
    }
}

/// One folded reaction, the net state after replaying adds and removes in ROWID order (section 5).
public struct ReactionRecord: Hashable, Codable, Sendable {
    public var kind: TapbackKind
    public var actorName: String
    public var fromMe: Bool
    public var part: Int
    /// ROWID of the row that set it. Format groups by emoji in first-reaction order.
    public var rowid: Int64

    public init(kind: TapbackKind, actorName: String, fromMe: Bool, part: Int, rowid: Int64) {
        self.kind = kind
        self.actorName = actorName
        self.fromMe = fromMe
        self.part = part
        self.rowid = rowid
    }
}

/// A sticker placed on a message (`associated_message_type` 1000).
public struct StickerRecord: Hashable, Codable, Sendable {
    public var actorName: String
    public var fromMe: Bool
    public var part: Int
    public var rowid: Int64

    public init(actorName: String, fromMe: Bool, part: Int, rowid: Int64) {
        self.actorName = actorName
        self.fromMe = fromMe
        self.part = part
        self.rowid = rowid
    }
}

/// Rows that print as a short event instead of a message body (section 5, Output).
public enum GroupEventKind: String, Codable, Sendable, Hashable {
    case renamed, added, removed, left, other
    /// A poll balloon. `title` holds the question when known: `* Priya started a poll "Dinner?"`.
    case poll
    /// A shared location balloon: `* Dad shared a location`.
    case location
}

/// Group events, polls and locations print as short events: `* Dad renamed the group to "Desai Fam"` (section 5).
/// `other` prints `* <actor> group event <itemType>`.
public struct EventRecord: Hashable, Codable, Sendable {
    public var kind: GroupEventKind
    public var actorName: String
    public var otherName: String?
    public var title: String?
    public var itemType: Int
    public var groupActionType: Int

    public init(kind: GroupEventKind, actorName: String, otherName: String? = nil, title: String? = nil,
                itemType: Int, groupActionType: Int) {
        self.kind = kind
        self.actorName = actorName
        self.otherName = otherName
        self.title = title
        self.itemType = itemType
        self.groupActionType = groupActionType
    }
}

/// URL balloon metadata from `payload_data` (LPLinkMetadata).
public struct LinkRecord: Hashable, Codable, Sendable {
    public var url: String?
    public var site: String?
    public var title: String?

    public init(url: String? = nil, site: String? = nil, title: String? = nil) {
        self.url = url
        self.site = site
        self.title = title
    }
}

/// Parent of an inline reply: `↩48100 (Mom: Who is coming Sunday…)` when the parent is off screen.
public struct ReplyRef: Hashable, Codable, Sendable {
    public var rowid: Int64
    public var senderName: String
    /// The parent body on one line, not yet cut. Format cuts it to `Limits.quoteChars`.
    public var text: String

    public init(rowid: Int64, senderName: String, text: String) {
        self.rowid = rowid
        self.senderName = senderName
        self.text = text
    }
}

/// One visible message. Tapback rows, placed stickers, self-chat echoes and duplicate link rows are folded or dropped
/// by IMStore and never appear as their own record.
public struct MessageRecord: Hashable, Codable, Sendable {
    public var rowid: Int64
    public var guid: String
    public var chatRowID: Int64
    public var dateNs: AppleNanos
    public var fromMe: Bool
    /// `You` for the user, else the Contacts nickname or first name, else a formatted phone or the email.
    public var senderName: String
    public var senderHandle: String?
    public var service: String?
    /// Decoded body with U+FFFC attachment placeholders removed. Full length; Format cuts it.
    public var text: String
    public var replyTo: ReplyRef?
    public var attachments: [AttachmentRecord]
    public var edited: Bool
    public var unsent: Bool
    public var partUnsent: Bool
    /// The row's `error` column. Nonzero prints `(failed)`.
    public var errorCode: Int
    public var reactions: [ReactionRecord]
    public var stickers: [StickerRecord]
    public var event: EventRecord?
    public var link: LinkRecord?
    public var isRead: Bool
    public var dateDeliveredNs: AppleNanos
    public var dateReadNs: AppleNanos
    public var dateEditedNs: AppleNanos
    public var partCount: Int
    /// True if the bridge's journal says the bridge sent this row. `wait` and rate limits never count these as inbound.
    public var agentSent: Bool

    public init(rowid: Int64, guid: String, chatRowID: Int64, dateNs: AppleNanos, fromMe: Bool, senderName: String,
                senderHandle: String? = nil, service: String? = nil, text: String, replyTo: ReplyRef? = nil,
                attachments: [AttachmentRecord] = [], edited: Bool = false, unsent: Bool = false,
                partUnsent: Bool = false, errorCode: Int = 0, reactions: [ReactionRecord] = [],
                stickers: [StickerRecord] = [], event: EventRecord? = nil, link: LinkRecord? = nil,
                isRead: Bool = true, dateDeliveredNs: AppleNanos = 0, dateReadNs: AppleNanos = 0,
                dateEditedNs: AppleNanos = 0, partCount: Int = 1, agentSent: Bool = false) {
        self.rowid = rowid
        self.guid = guid
        self.chatRowID = chatRowID
        self.dateNs = dateNs
        self.fromMe = fromMe
        self.senderName = senderName
        self.senderHandle = senderHandle
        self.service = service
        self.text = text
        self.replyTo = replyTo
        self.attachments = attachments
        self.edited = edited
        self.unsent = unsent
        self.partUnsent = partUnsent
        self.errorCode = errorCode
        self.reactions = reactions
        self.stickers = stickers
        self.event = event
        self.link = link
        self.isRead = isRead
        self.dateDeliveredNs = dateDeliveredNs
        self.dateReadNs = dateReadNs
        self.dateEditedNs = dateEditedNs
        self.partCount = partCount
        self.agentSent = agentSent
    }
}

/// One conversation for `chats` and for page headers.
public struct ChatRecord: Hashable, Codable, Sendable {
    public var rowid: Int64
    public var guid: String
    public var identifier: String
    public var canonical: CanonicalChatID
    /// chat.db `display_name`, empty for unnamed chats.
    public var displayName: String
    /// `chat_label` in ours.py.
    public var label: String
    public var isGroup: Bool
    /// Member short names, without `You`.
    public var memberNames: [String]
    public var service: String
    public var unreadCount: Int
    /// Newest visible message, for the `chats` preview (section 5: time, sender, first 60 chars).
    public var last: MessageRecord?
    /// Every chat.db chat that makes up this conversation (a contact's iMessage and SMS chats count as one).
    public var mergedChatRowIDs: [Int64]

    public init(rowid: Int64, guid: String, identifier: String, canonical: CanonicalChatID, displayName: String,
                label: String, isGroup: Bool, memberNames: [String], service: String, unreadCount: Int = 0,
                last: MessageRecord? = nil, mergedChatRowIDs: [Int64] = []) {
        self.rowid = rowid
        self.guid = guid
        self.identifier = identifier
        self.canonical = canonical
        self.displayName = displayName
        self.label = label
        self.isGroup = isGroup
        self.memberNames = memberNames
        self.service = service
        self.unreadCount = unreadCount
        self.last = last
        self.mergedChatRowIDs = mergedChatRowIDs
    }

    public var ref: ChatRef { ChatRef(rowid: rowid, label: label, isGroup: isGroup) }
}

/// A handle and the services it appears on.
public struct HandleRecord: Hashable, Codable, Sendable {
    public var id: String
    public var services: [String]

    public init(id: String, services: [String]) {
        self.id = id
        self.services = services
    }
}

/// `who <name>`: `Mom = Meera Desai · +1 415-555-0101 (iMessage) · chats: 7 (direct), 12 Desai Fam`.
public struct ContactRecord: Hashable, Codable, Sendable {
    /// Nickname or first name.
    public var shortName: String
    public var firstName: String
    public var lastName: String
    public var handles: [HandleRecord]
    public var chats: [ChatRef]

    public init(shortName: String, firstName: String, lastName: String, handles: [HandleRecord], chats: [ChatRef]) {
        self.shortName = shortName
        self.firstName = firstName
        self.lastName = lastName
        self.handles = handles
        self.chats = chats
    }
}
