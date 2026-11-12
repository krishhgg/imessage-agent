import Foundation

enum Service: String {
  case iMessage, SMS, RCS
}

struct Person {
  let key: String
  let first: String
  let last: String?
  let nickname: String?
  /// False means the person is missing from the synthetic contacts list, so a reader
  /// must fall back to the phone number or email.
  let inContacts: Bool
  var label: String { nickname ?? first }
}

struct HandleDef {
  let rowid: Int64
  let id: String
  let service: Service
  let country: String?
  let uncanonicalized: String?
  let person: String
}

struct ChatDef {
  let rowid: Int64
  let key: String
  let guid: String
  let style: Int  // 45 direct, 43 group
  let identifier: String
  let service: Service
  let roomName: String?
  let displayName: String
  let label: String
  /// Handle keys in chat_handle_join at the end of the timeline (external members only).
  let currentMembers: [String]
  /// The local address the user talks from in this chat.
  let callerID: String
  let readReceipts: Bool
  let groupID: String
  var isGroup: Bool { style == 43 }
}

enum Who: Equatable {
  case me
  case person(String)
}

enum AttKind: String {
  case photo, pdf, voice, sticker, video
}

struct AttDef {
  var index: Int
  var rowid: Int64 = 0
  var guid: String
  var kind: AttKind
  var transferName: String
  var uti: String
  var mime: String
  var onDisk: Bool
  var fileData: Data?
  var claimedBytes: Int
  var width: Int?
  var height: Int?
  var transcript: String?
  var isSticker: Bool
  var isOutgoing: Bool
  var dirA: String
  var dirB: String
  var messageIndex: Int = -1

  var dbPath: String { "~/Library/Messages/Attachments/\(dirA)/\(dirB)/\(guid)/\(transferName)" }
  var fixtureRelativePath: String { "Attachments/\(dirA)/\(dirB)/\(guid)/\(transferName)" }
  /// Invented original size. The file on disk is a tiny stand-in, so this never matches its length.
  var totalBytes: Int { claimedBytes }
}

struct Part {
  enum Kind {
    case text(String)
    case attachment(Int)
  }

  var kind: Kind
  var mentions: [(text: String, handle: String)] = []
  var bold: [String] = []

  static func t(_ s: String) -> Part { Part(kind: .text(s)) }
  static func a(_ i: Int) -> Part { Part(kind: .attachment(i)) }

  var text: String? { if case .text(let s) = kind { return s } else { return nil } }
  var attachment: Int? { if case .attachment(let i) = kind { return i } else { return nil } }
  /// The characters this part occupies in the body.
  var bodyString: String { text ?? "\u{FFFC}" }
}

enum MsgKind {
  case normal
  case tapback(type: Int, target: Int, part: Int, emoji: String?)
  case placedSticker(target: Int, part: Int)
  case groupEvent(itemType: Int, action: Int, other: String?, title: String?)
  case linkBalloon(url: String, title: String, summary: String, site: String)
}

enum Unsend {
  /// macOS 15 and 26 shape: date_retracted stays 0, body cleared, date_edited and rp set.
  case modern(at: Int64)
  /// Older shape: date_retracted set, body cleared.
  case legacy(at: Int64)
  /// Only some parts retracted; the rest of the body stays.
  case partial(at: Int64, parts: [Int])
}

struct Msg {
  var index: Int
  var chat: String
  var who: Who
  var dateNs: Int64
  var parts: [Part]
  var kind: MsgKind = .normal
  /// Overrides the person's default handle, for example Mom's SMS handle.
  var handleKey: String?
  var service: Service?
  var threadTarget: (msg: Int, part: Int)?
  /// Full edit history, oldest first. The last entry is the current text of part 0.
  var editHistory: [(ns: Int64, text: String)] = []
  var unsend: Unsend?
  var unread = false
  var failed = false
  var notDelivered = false
  var effect: String?
  var isAudio = false
  var played = false
  var textColumn = false
  var immutableArchive = false
  var echo = false
  var dataDetected = false
  var recentlyDeleted = false
  var gapFiller = false
  var edgeKeys: [String] = []

  // Filled in when ROWIDs are assigned.
  var rowid: Int64 = 0
  var guid: String = ""
  var replyToGUID: String?

  var isTapback: Bool { if case .tapback = kind { return true } else { return false } }
  var isEvent: Bool { if case .groupEvent = kind { return true } else { return false } }
  var isPlacedSticker: Bool { if case .placedSticker = kind { return true } else { return false } }

  /// Body text as the archived string, or nil when the row has no attributedBody.
  var bodyString: String? {
    if isEvent { return nil }
    if case .modern = unsend { return nil }
    if case .legacy = unsend { return nil }
    if case .partial(_, let gone) = unsend {
      return parts.enumerated().filter { !gone.contains($0.offset) }.map { $0.element.bodyString }.joined()
    }
    return parts.map(\.bodyString).joined()
  }

  /// Visible text of part 0 when it is text, used for tapback quotes.
  var firstText: String? { parts.first?.text }
}
