import Foundation
@testable import IMCore
import IMTestSupport

/// Small record builders for the hand-written Format tests. Times are local to America/Los_Angeles and the
/// clock is the fixture's: Friday 2026-11-06 00:30 PST.
enum B {
    static let ctx = Golden.context

    static var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = Fixture.timeZone
        return c
    }

    static func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 12, _ mi: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    static func ns(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 12, _ mi: Int = 0) -> AppleNanos {
        AppleTime.nanos(from: date(y, mo, d, h, mi))
    }

    /// Thursday 2026-11-05 18:02, shown as `18:02` or `Yesterday 18:02`.
    static let yesterday1802 = ns(2026, 11, 5, 18, 2)

    static func msg(_ rowid: Int64, _ text: String, at: AppleNanos = yesterday1802, from: String = "Mom",
                    me: Bool = false, chat: Int64 = 7) -> MessageRecord {
        MessageRecord(rowid: rowid, guid: "g\(rowid)", chatRowID: chat, dateNs: at, fromMe: me, senderName: from,
                      text: text)
    }

    static func chat(_ rowid: Int64, _ label: String, group: Bool = false, name: String = "", members: [String] = [],
                     service: String = "iMessage", unread: Int = 0, last: MessageRecord? = nil) -> ChatRecord {
        ChatRecord(rowid: rowid, guid: "c\(rowid)", identifier: "id\(rowid)",
                   canonical: CanonicalChatID(rawValue: group ? "group:c\(rowid)" : "direct:id\(rowid)"),
                   displayName: name, label: label, isGroup: group, memberNames: members, service: service,
                   unreadCount: unread, last: last)
    }

    static let mom = ChatRef(rowid: 7, label: "Mom", isGroup: false)
    static let family = ChatRef(rowid: 12, label: "Desai Fam", isGroup: true)

    static func photo(_ rowid: Int64 = 9901, bytes: Int64? = 2_250_000) -> AttachmentRecord {
        AttachmentRecord(rowid: rowid, guid: "a\(rowid)", kind: .photo, transferName: "IMG_4420.HEIC", totalBytes: bytes)
    }

    static func reaction(_ kind: TapbackKind, _ who: String, rowid: Int64, me: Bool = false) -> ReactionRecord {
        ReactionRecord(kind: kind, actorName: who, fromMe: me, part: 0, rowid: rowid)
    }

    /// Output lines without the final empty piece after the last `\n`.
    static func lines(_ s: String) -> [String] {
        var parts = s.components(separatedBy: "\n")
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    /// Lines that look like a message line: `<rowid> <HH:MM> …`.
    static func messageLines(_ s: String) -> [String] {
        lines(s).filter { line in
            let f = line.split(separator: " ", maxSplits: 2)
            return f.count >= 2 && Int64(f[0]) != nil && f[1].count == 5 && f[1].dropFirst(2).first == ":"
        }
    }
}
