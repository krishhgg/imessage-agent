import Foundation

/// Clock and zone the renderer uses for relative days and `times <TZ>` headers.
public struct FormatContext: Sendable {
    public var now: Date
    public var timeZone: TimeZone

    public init(now: Date = Date(), timeZone: TimeZone = .current) {
        self.now = now
        self.timeZone = timeZone
    }
}

/// The compact text renderer, DESIGN.md section 5 "Output". Owner: IMCore.
///
/// Golden scope: the success output of `chats`, `unread`, `read`, `show` and `who` must match
/// bench/renderers/ours.py byte for byte on the fixture (the S5 numbers rest on it). Golden text lives in
/// `Tests/Fixtures/golden/` (`Fixture.goldenDir`). For `search`, `send`, `react`, `unsend`, `edit`, `att` and every
/// error line, DESIGN.md and Results.swift win over ours.py:
/// - Result lines end in the `ActionResult.rendered` text (`· ok`, `· submitted`, `· delivered`), not ours.py's
///   `· verified` or `delivered HH:MM`.
/// - Error lines use `error: <message> fix: <fix>` with a single space before `fix:`, never ours.py's `. fix:`.
/// - A target with several matches is `error: several matches` plus the candidates (section 5).
/// - An offloaded attachment is `not_downloaded` (section 1). `att` prints the cache path from
///   `AttachmentExport.path`, never `/tmp/imessage/`.
/// - `search` uses `SearchPage`'s cursor and says how far back the page scanned (section 1, Search).
///
/// Rules (section 5 and research/tokens.md section 5):
/// - One line per message: `<rowid> <HH:MM> <Sender>: [↩<rowid>] <text> [attachments] [(edited)|(unsent)] [reactions]`.
/// - A header line opens a list, `-- <day>` separators split it, a `more: …` footer gives the next page.
/// - Tapbacks fold into the parent line as net state, grouped by emoji: `[❤️Mom 😂Priya,You]`.
/// - Attachments print as `[photo a9901 2.2MB]`, `[voice a9903 "transcript"]`, `[file a9902 name.pdf 348KB]`.
/// - Group events, polls and locations print as `* Dad renamed the group to "Desai Fam"`.
/// - Bodies are cut at 400 characters with `…(+N chars: imessage show <rowid>)`. Link titles and voice transcripts
///   are cut at 400 characters and link sites at 30, each ending in `…`.
/// - At most 200 lines and 12,000 bytes per call, footer included. `read`, `unread`, `chats`, `search`,
///   `changes`, `pending` and `who` stop early and end with a `more:` footer when they would pass either cap.
///   When the first entry of a `read`, `unread`, `search` or `changes` page can't fit whole, it prints cut to the
///   bytes left (`Renderer.fit`), so a page is never empty and its footer moves past it. `who` cuts a contact's
///   chats list instead and ends it with `+N more chats`. `show` pages at 8 KB or 197 line breaks, whichever
///   comes first. ours.py lets `read -n 200` run past 200 lines; here the cap wins.
/// - Errors are one line: `error: … fix: …`, from `ActionResult.rendered`.
/// - `--json` prints NDJSON, one record per line (`ndjson`), under the same 200-record and 12,000-byte cap.
///
/// Character counts are Unicode scalar counts, the unit ours.py's `len` uses. Every line except the body `show`
/// prints in full has its line breaks folded to ` / `, so a name or a message can't add a line.
public enum Format {
    // MARK: Verbs

    /// `chats`: `12 Desai Fam (group: Mom, Dad, Priya, 2 more) 3 unread · 12:30 Arjun: <first 60 chars>`.
    public static func chats(_ page: ChatsPage, _ ctx: FormatContext) -> String { Renderer(ctx).chats(page) }

    /// `unread`: header `unread · N messages in M chats · times PST`, one block per chat, `-- unread` markers.
    public static func unread(_ page: UnreadPage, _ ctx: FormatContext) -> String { Renderer(ctx).unread(page) }

    /// `read`: header `chat <id> <title> · <shown> of <total> · times <TZ>`, day separators, footer.
    public static func messages(_ page: MessagesPage, _ ctx: FormatContext) -> String { Renderer(ctx).messages(page) }

    /// `show`: `<rowid> <day> <HH:MM> in chat <id> <label>` then `<Sender>: <body>`, 8 KB with a `--from` footer.
    public static func show(_ detail: MessageDetail, _ ctx: FormatContext) -> String { Renderer(ctx).show(detail) }

    /// `search`: header `search "x"[ in <chat>] · N hits, newest first · scanned back to <when>`, hits with
    /// 120-character snippets, and a `more: imessage search [--in <chat>] --cursor C <query>` footer. The flags come
    /// first and a query that starts with `-` follows `--`, so the CLI never reads the query as a flag.
    public static func search(_ page: SearchPage, _ ctx: FormatContext) -> String { Renderer(ctx).search(page) }

    /// `who`: `Mom = Meera Desai · +1 415-555-0101 (iMessage) · chats: 7 (direct), 12 Desai Fam`.
    public static func who(_ page: ContactsPage) -> String { Renderer.who(page) }

    /// `att`: `a9904 photo IMG_4420.HEIC 1.9MB 4032x3024 -> <path> (1600px)`, or the `not_downloaded` line.
    public static func attachment(_ export: AttachmentExport) -> String { Renderer.attachment(export) }

    /// `send`: optional `approved` line, then `sent <rowid> to <label> [↩<rowid>] "<text>" [file] · <result>`,
    /// one line per part when their results differ.
    public static func send(_ outcome: SendOutcome, _ ctx: FormatContext) -> String { Renderer.send(outcome) }

    /// `react`, `unsend`, `edit`: `reacted ❤️ to 41418 (Mom: …) in chat 12 · ok` and the other result lines.
    public static func ui(_ outcome: UIOutcome, _ ctx: FormatContext) -> String { Renderer.ui(outcome) }

    /// `allow`, `revoke`.
    public static func policy(_ outcome: PolicyOutcome) -> String { Renderer.policy(outcome) }

    /// `pending` with no id.
    public static func pending(_ list: PendingList, _ ctx: FormatContext) -> String { Renderer(ctx).pending(list) }

    /// `changes`: one message line per change with its kind, then `cursor <c>`.
    public static func changes(_ page: ChangesPage, _ ctx: FormatContext) -> String { Renderer(ctx).changes(page) }

    /// `wait`: the new message line, or `timeout`.
    public static func wait(_ outcome: WaitOutcome, _ ctx: FormatContext) -> String { Renderer(ctx).wait(outcome) }

    public static func caps(_ report: CapsReport) -> String { Renderer.caps(report) }
    public static func status(_ report: StatusReport) -> String { Renderer.status(report) }
    public static func setup(_ report: SetupReport) -> String { Renderer.setup(report) }
    public static func doctor(_ report: DoctorReport) -> String { Renderer.doctor(report) }

    /// One-line error with candidates for `error: several matches`.
    public static func error(_ e: WireError) -> String { Renderer.error(e) }

    /// Dispatches on the payload. The CLI calls only this and `ndjson`.
    public static func render(_ payload: ResponsePayload, _ ctx: FormatContext) -> String {
        switch payload {
        case .chats(let p): return chats(p, ctx)
        case .unread(let p): return unread(p, ctx)
        case .messages(let p): return messages(p, ctx)
        case .message(let d): return show(d, ctx)
        case .search(let p): return search(p, ctx)
        case .contacts(let p): return who(p)
        case .changes(let p): return changes(p, ctx)
        case .wait(let o): return wait(o, ctx)
        case .attachment(let e): return attachment(e)
        case .send(let o): return send(o, ctx)
        case .ui(let o): return ui(o, ctx)
        case .policy(let o): return policy(o)
        case .pending(let l): return pending(l, ctx)
        case .caps(let r): return caps(r)
        case .status(let r): return status(r)
        case .setup(let r): return setup(r)
        case .doctor(let r): return doctor(r)
        case .pong(let p): return Renderer.finish([Format.noBreaks("pong · bridge \(p.bridgeVersion) pid \(p.pid)")])
        case .failure(let e): return error(e)
        }
    }

    /// `--json`: NDJSON, one record per line, short keys, no repeated chat fields. Every record has a `type`.
    /// List message records carry the full text, uncut; `show` pages it as the text output does. A list cut by the
    /// cap ends with a `more` record. A failure, and `who` with no match, print one `error` record.
    public static func ndjson(_ payload: ResponsePayload) -> String { NDJSON.render(payload) }

    // MARK: Pieces (ours.py helpers), public so tests can pin them

    /// `message_line` in ours.py. `onScreen` holds ROWIDs shown in the same output, so replies to them skip the quote.
    public static func messageLine(_ m: MessageRecord, onScreen: Set<Int64>, _ ctx: FormatContext) -> String {
        Renderer(ctx).messageLine(m, onScreen)
    }

    /// `Today Thu Nov 5`, `Yesterday Wed Nov 4`, `Mon Nov 2`, `Oct 28`, `Oct 28 2025`.
    public static func dayLabel(_ date: Date, _ ctx: FormatContext) -> String {
        let r = Renderer(ctx)
        return r.dayLabel(r.civil(date))
    }

    /// `when_short`: `12:30`, `Yesterday 18:02`, `Mon 09:04`, `Oct 28`, `Oct 28 2025`.
    public static func whenShort(_ date: Date, _ ctx: FormatContext) -> String {
        let r = Renderer(ctx)
        return r.whenShort(r.civil(date))
    }

    /// `fmt_size`: `2.2MB`, `348KB`, `512B`, empty for nil.
    public static func size(_ bytes: Int64?) -> String {
        guard let n = bytes else { return "" }
        if n >= 1_000_000 { return String(format: "%.1fMB", Double(n) / 1e6) }
        if n >= 1000 { return "\(Int64((Double(n) / 1e3).rounded(.toNearestOrEven)))KB" }
        return "\(n)B"
    }

    /// `[photo a9901 2.2MB]` and the other attachment tokens.
    public static func attachmentToken(_ a: AttachmentRecord) -> String {
        let id = "a\(a.rowid)"
        let sz = size(a.totalBytes)
        switch a.kind {
        case .photo: return "[" + join("photo", id, sz) + "]"
        case .video: return "[" + join("video", id, sz) + "]"
        case .voice:
            if let t = a.transcript, !t.isEmpty { return "[voice \(id) \"\(cut(t, Limits.bodyCutChars))\"]" }
            return "[voice \(id)]"
        case .sticker: return "[sticker \(id)]"
        case .file: return "[" + join("file", id, a.transferName, sz) + "]"
        }
    }

    /// `[❤️Mom 😂Priya,You sticker by Dad]`, or empty.
    public static func reactionsToken(_ m: MessageRecord) -> String {
        if m.reactions.isEmpty && m.stickers.isEmpty { return "" }
        var groups: [(emoji: String, names: [String])] = []
        for r in m.reactions.sorted(by: { $0.rowid < $1.rowid }) {
            let who = r.fromMe ? "You" : r.actorName
            let e = r.kind.displayEmoji
            if let i = groups.firstIndex(where: { $0.emoji == e }) {
                groups[i].names.append(who)
            } else {
                groups.append((e, [who]))
            }
        }
        var parts = groups.map { $0.emoji + $0.names.joined(separator: ",") }
        for s in m.stickers { parts.append("sticker by " + (s.fromMe ? "You" : s.actorName)) }
        return "[" + parts.joined(separator: " ") + "]"
    }

    /// `* Dad renamed the group to "Desai Fam"`.
    public static func eventText(_ e: EventRecord) -> String {
        let actor = e.actorName
        let other = e.otherName ?? "someone"
        switch e.kind {
        case .renamed: return "* \(actor) renamed the group to \"\(e.title ?? "")\""
        case .added: return "* \(actor) added \(other)"
        case .removed: return "* \(actor) removed \(other)"
        case .left: return "* \(actor) left the group"
        case .poll:
            if let t = e.title, !t.isEmpty { return "* \(actor) started a poll \"\(t)\"" }
            return "* \(actor) started a poll"
        case .location: return "* \(actor) shared a location"
        case .other: return "* \(actor) group event \(e.itemType)"
        }
    }

    /// `Family (group: Mom, Dad, You)` or `group: Jordan, Taylor` (`chat_title` in ours.py).
    public static func chatTitle(_ c: ChatRecord, withYou: Bool, cap: Int?) -> String {
        guard c.isGroup else { return c.label }
        var names = c.memberNames
        if let cap, cap > 0, names.count > cap + 1 {
            names = Array(names.prefix(cap)) + ["\(c.memberNames.count - cap) more"]
        }
        if withYou { names.append("You") }
        let members = names.joined(separator: ", ")
        if !c.displayName.isEmpty { return "\(c.displayName) (group: \(members))" }
        return "group: " + members
    }

    /// Time zone abbreviation for headers (`times PST`).
    public static func zoneAbbreviation(_ ctx: FormatContext) -> String {
        ctx.timeZone.abbreviation(for: ctx.now) ?? ctx.timeZone.identifier
    }

    // MARK: Small helpers shared with the renderer

    /// Joins the non-empty pieces with one space.
    static func join(_ pieces: String...) -> String {
        pieces.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// `q[:n] + "…"` when `q` has more than `n` scalars, as ours.py cuts quotes and previews.
    static func cut(_ s: String, _ n: Int) -> String {
        let u = s.unicodeScalars
        guard u.count > n else { return s }
        return String(String.UnicodeScalarView(u.prefix(n))) + "…"
    }

    /// The first `n` scalars.
    static func prefix(_ s: String, _ n: Int) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.prefix(n)))
    }

    /// Python's `"{:,}".format(n)`.
    static func grouped(_ n: Int) -> String {
        let digits = String(n.magnitude)
        var out = ""
        for (i, ch) in digits.enumerated() {
            if i > 0, (digits.count - i) % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        return n < 0 ? "-" + out : out
    }

    /// Folds any line break inside `s` to ` / ` without trimming, so one rendered line stays one line.
    static func noBreaks(_ s: String) -> String {
        guard s.unicodeScalars.contains(where: TextNorm.isLineBreak) else { return s }
        return TextNorm.fold(s, strip: false, isBreak: TextNorm.isLineBreak)
    }

    /// `reader_format` in ours.py: `+1 415-555-0101` for an 11-digit number starting with 1, else the handle as is.
    static func readerFormat(_ h: String) -> String {
        let d = h.unicodeScalars.filter { ("0"..."9").contains($0) }.map(Character.init)
        guard !h.contains("@"), d.count == 11, d[0] == "1" else { return h }
        let s = String(d)
        let a = s.dropFirst(1).prefix(3), b = s.dropFirst(4).prefix(3), c = s.dropFirst(7)
        return "+1 \(a)-\(b)-\(c)"
    }

    /// Quotes `s` for a POSIX shell when it holds anything outside a safe set, so a footer is a command to copy.
    static func shellQuote(_ s: String) -> String {
        let safe = s.unicodeScalars.allSatisfy { c in
            c.isASCII && (CharacterSet.alphanumerics.contains(c) || "_@%+=:,./-".unicodeScalars.contains(c))
        }
        if !s.isEmpty && safe { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
}

// MARK: - Renderer

/// One local calendar position, computed the way Python's `datetime.fromtimestamp` does.
struct Civil: Equatable {
    var year: Int
    var month: Int
    var day: Int
    var hour: Int
    var minute: Int
    /// 1 is Sunday.
    var weekday: Int
    /// Days since 1970-01-01 of the local date, for day differences.
    var dayNumber: Int
}

/// Rendering state for one call: the calendar, today's position and the zone label.
struct Renderer {
    static let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    static let maxLines = Limits.outputMaxLines
    static let maxBytes = Limits.outputMaxBytes

    let cal: Calendar
    let today: Civil
    let zone: String

    init(_ ctx: FormatContext) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = ctx.timeZone
        self.cal = cal
        self.today = Renderer.civil(unix: ctx.now.timeIntervalSince1970, cal)
        self.zone = Format.zoneAbbreviation(ctx)
    }

    // MARK: Dates

    /// Whole Unix seconds of `t` the way CPython's `fromtimestamp` gets them: round the fraction to microseconds
    /// half to even, then carry.
    static func wholeSeconds(_ t: Double) -> Int64 {
        var whole = t.rounded(.towardZero)
        let micros = ((t - whole) * 1e6).rounded(.toNearestOrEven)
        if micros >= 1e6 { whole += 1 } else if micros < 0 { whole -= 1 }
        return Int64(whole)
    }

    static func civil(unix t: Double, _ cal: Calendar) -> Civil {
        let date = Date(timeIntervalSince1970: Double(wholeSeconds(t)))
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: date)
        let y = c.year ?? 1970, m = c.month ?? 1, d = c.day ?? 1
        return Civil(year: y, month: m, day: d, hour: c.hour ?? 0, minute: c.minute ?? 0, weekday: c.weekday ?? 1,
                     dayNumber: daysFromCivil(y, m, d))
    }

    /// Days since 1970-01-01 of a proleptic Gregorian date.
    static func daysFromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    func civil(_ date: Date) -> Civil { Renderer.civil(unix: date.timeIntervalSince1970, cal) }

    /// The same float arithmetic as `ns_to_unix` in bench/reader.py.
    func civil(ns: AppleNanos) -> Civil { Renderer.civil(unix: Double(ns) / 1e9 + AppleTime.epochOffset, cal) }

    func hhmm(_ c: Civil) -> String { String(format: "%02d:%02d", c.hour, c.minute) }

    func weekday(_ c: Civil) -> String { Renderer.weekdays[(c.weekday - 1 + 7) % 7] }

    func month(_ c: Civil) -> String { Renderer.months[(c.month - 1 + 12) % 12] }

    func dateOnly(_ c: Civil) -> String {
        c.year == today.year ? "\(month(c)) \(c.day)" : "\(month(c)) \(c.day) \(c.year)"
    }

    func dayLabel(_ c: Civil) -> String {
        let d = today.dayNumber - c.dayNumber
        let tail = "\(weekday(c)) \(month(c)) \(c.day)"
        if d == 0 { return "Today " + tail }
        if d == 1 { return "Yesterday " + tail }
        if d < 7 { return tail }
        return dateOnly(c)
    }

    func whenShort(_ c: Civil) -> String {
        let d = today.dayNumber - c.dayNumber
        if d == 0 { return hhmm(c) }
        if d == 1 { return "Yesterday " + hhmm(c) }
        if d <= 6 { return weekday(c) + " " + hhmm(c) }
        return dateOnly(c)
    }

    // MARK: Lines

    static func finish(_ lines: [String]) -> String { lines.joined(separator: "\n") + "\n" }

    static func bytes(_ s: String) -> Int { s.utf8.count + 1 }

    /// The backstop for the first entry of a page that can't fit whole: `line` cut at a character boundary and
    /// ended with `…` so it takes at most `budget` bytes with its newline. Every page then shows at least one
    /// entry, and its footer moves past it.
    static func fit(_ line: String, _ budget: Int) -> String {
        guard bytes(line) > budget else { return line }
        let room = budget - 1 - "…".utf8.count
        var used = 0
        var end = line.startIndex
        for i in line.indices {
            let n = line[i].utf8.count
            if used + n > room { break }
            used += n
            end = line.index(after: i)
        }
        return String(line[..<end]) + "…"
    }

    static func sender(_ m: MessageRecord) -> String { m.fromMe ? "You" : m.senderName }

    func messageLine(_ m: MessageRecord, _ onScreen: Set<Int64>) -> String {
        let head = "\(m.rowid) \(hhmm(civil(ns: m.dateNs)))"
        if let e = m.event { return Format.noBreaks(head + " " + Format.eventText(e)) }
        var bits: [String] = []
        if let r = m.replyTo {
            var token = "↩\(r.rowid)"
            if !onScreen.contains(r.rowid) {
                token += " (\(r.senderName): \(Format.cut(TextNorm.oneLine(r.text), Limits.quoteChars)))"
            }
            bits.append(token)
        }
        let sender = Renderer.sender(m)
        if m.unsent {
            bits.append("(unsent)")
            return Format.noBreaks(head + " " + sender + ": " + bits.joined(separator: " "))
        }
        var text = TextNorm.oneLine(m.text)
        if let link = m.link, TextNorm.pyStrip(m.text) == (link.url ?? "") {
            let site = Format.cut(link.site ?? "", Limits.quoteChars)
            text = "[link \(site): \(Format.cut(link.title ?? "", Limits.bodyCutChars))]"
        } else if text.unicodeScalars.count > Limits.bodyCutChars {
            let extra = text.unicodeScalars.count - Limits.bodyCutChars
            text = Format.prefix(text, Limits.bodyCutChars)
                + "…(+\(Format.grouped(extra)) chars: imessage show \(m.rowid))"
        }
        if !text.isEmpty { bits.append(text) }
        for a in m.attachments { bits.append(Format.attachmentToken(a)) }
        if m.partUnsent {
            bits.append("(part unsent)")
        } else if m.edited {
            bits.append("(edited)")
        }
        if m.errorCode != 0 { bits.append("(failed)") }
        let rt = Format.reactionsToken(m)
        if !rt.isEmpty { bits.append(rt) }
        return Format.noBreaks(head + " " + sender + ": " + bits.joined(separator: " "))
    }

    // MARK: chats

    func chatLine(_ c: ChatRecord) -> String {
        var line = "\(c.rowid) \(Format.chatTitle(c, withYou: false, cap: 3))"
        let u = c.unreadCount
        if u > 1 { line += " \(u) unread" }
        if let last = c.last {
            let when = whenShort(civil(ns: last.dateNs))
            if let e = last.event {
                line += " · \(when) \(Format.eventText(e))"
            } else {
                var prev: String
                if last.unsent {
                    prev = "(unsent)"
                } else {
                    prev = TextNorm.oneLine(last.text)
                    if prev.isEmpty, let a = last.attachments.first { prev = "[\(a.kind.rawValue)]" }
                    prev = Format.cut(prev, Limits.chatPreviewChars)
                }
                line += " · \(when) \(Renderer.sender(last)): \(prev)"
            }
            if u == 1 { line += " (unread)" }
        }
        if !c.service.isEmpty && c.service != "iMessage" { line += " (\(c.service))" }
        return Format.noBreaks(line)
    }

    func chats(_ page: ChatsPage) -> String {
        let pageFooter = page.hasMore ? "more: imessage chats -n \(page.limit + 20)" : nil
        func capFooter(_ c: ChatRecord) -> String { "more: imessage read \(c.rowid)" }
        var lines: [String] = []
        var size = 0
        for (i, c) in page.chats.enumerated() {
            let line = chatLine(c)
            let isLast = i == page.chats.count - 1
            let reserve = isLast ? pageFooter : capFooter(page.chats[i + 1])
            let needLines = lines.count + 1 + (reserve == nil ? 0 : 1)
            let needBytes = size + Renderer.bytes(line) + (reserve.map(Renderer.bytes) ?? 0)
            if needLines > Renderer.maxLines || needBytes > Renderer.maxBytes {
                lines.append(capFooter(c))
                return Renderer.finish(lines)
            }
            lines.append(line)
            size += Renderer.bytes(line)
        }
        if let pageFooter { lines.append(pageFooter) }
        if lines.isEmpty { return Renderer.finish(["no chats"]) }
        return Renderer.finish(lines)
    }

    // MARK: unread

    /// One chat's block, each line with the ROWID it shows, if it is a message line.
    func unreadBlock(_ g: UnreadGroup) -> [(text: String, rowid: Int64?)] {
        let title = Format.chatTitle(g.chat, withYou: true, cap: nil)
        var block: [(text: String, rowid: Int64?)] = [
            (Format.noBreaks("chat \(g.chat.rowid) \(title) · \(g.unreadCount) unread"), nil),
        ]
        let onScreen = Set(g.entries.map { $0.message.rowid })
        var lastDay: Int?
        for (j, e) in g.entries.enumerated() {
            if j > 0 && e.gapBefore { block.append(("…", nil)) }
            let c = civil(ns: e.message.dateNs)
            if c.dayNumber != lastDay {
                block.append(("-- " + dayLabel(c), nil))
                lastDay = c.dayNumber
            }
            if e.isUnread && (j == 0 || e.gapBefore || !g.entries[j - 1].isUnread) {
                block.append(("-- unread", nil))
            }
            block.append((messageLine(e.message, onScreen), e.message.rowid))
        }
        return block
    }

    func unread(_ page: UnreadPage) -> String {
        let header = "unread · \(Format.plural(page.totalUnread, "message")) in \(Format.plural(page.groups.count, "chat"))"
            + " · times \(zone)"
        var out = [header]
        var size = Renderer.bytes(header)
        for (gi, g) in page.groups.enumerated() {
            let block = unreadBlock(g)
            let bsize = block.reduce(0) { $0 + Renderer.bytes($1.text) }
            let next = gi + 1 < page.groups.count ? "more: imessage read \(page.groups[gi + 1].chat.rowid)" : nil
            if out.count + block.count + (next == nil ? 0 : 1) <= Renderer.maxLines,
               size + bsize + (next.map(Renderer.bytes) ?? 0) <= Renderer.maxBytes {
                out += block.map { $0.text }
                size += bsize
                continue
            }
            // The block doesn't fit. ours.py points at the chat. When nothing has been shown yet, show as much of
            // the block as fits instead, so a chat with many unread messages still prints something.
            if gi == 0 {
                var best: (count: Int, footer: String)?
                var first: Int?
                var lines = 0
                var bytes = 0
                for (k, item) in block.enumerated() {
                    lines += 1
                    bytes += Renderer.bytes(item.text)
                    guard let rowid = item.rowid else { continue }
                    let footer = "more: imessage read \(g.chat.rowid) --after \(rowid)"
                    if out.count + lines + 1 > Renderer.maxLines
                        || size + bytes + Renderer.bytes(footer) > Renderer.maxBytes {
                        if best == nil { first = k }
                        break
                    }
                    best = (lines, footer)
                }
                if let best {
                    out += block.prefix(best.count).map { $0.text }
                    out.append(best.footer)
                    return Renderer.finish(out)
                }
                if let k = first, let rowid = block[k].rowid {
                    // Even the first message line can't fit: print it cut after the lines that lead up to it.
                    // When it is the block's only message line, the footer points at the next chat, if any.
                    let footer = k == block.count - 1 ? next : "more: imessage read \(g.chat.rowid) --after \(rowid)"
                    let lead = block[..<k].map { $0.text }
                    let room = Renderer.maxBytes - size - lead.reduce(0) { $0 + Renderer.bytes($1) }
                        - (footer.map(Renderer.bytes) ?? 0)
                    out += lead
                    out.append(Renderer.fit(block[k].text, room))
                    if let footer { out.append(footer) }
                    return Renderer.finish(out)
                }
            }
            out.append("more: imessage read \(g.chat.rowid)")
            break
        }
        return Renderer.finish(out)
    }

    // MARK: read

    /// A new direct target has no chat yet (ROWID 0), so the header names its handle, which `read` takes back.
    func readHeader(_ page: MessagesPage, kept: Int) -> String {
        let id = page.chat.rowid == 0 && !page.chat.identifier.isEmpty ? page.chat.identifier : "\(page.chat.rowid)"
        return Format.noBreaks("chat \(id) \(Format.chatTitle(page.chat, withYou: true, cap: nil))"
            + " · \(kept) of \(page.totalVisible) · times \(zone)")
    }

    func messages(_ page: MessagesPage) -> String {
        let window = page.messages
        let onScreen = Set(window.map { $0.rowid })
        var lines = window.map { messageLine($0, onScreen) }
        let days = window.map { civil(ns: $0.dateNs) }
        // The newest message is always kept, so this footer is the same whatever the cap cuts.
        let newer = page.newerExists ? window.last.map { "more: imessage read \(page.chat.rowid) --after \($0.rowid)" }
            : nil
        let newerBytes = newer.map(Renderer.bytes) ?? 0
        let newerLines = newer == nil ? 0 : 1
        // Keep the newest messages that fit: header, day separators, message lines and footers together stay
        // within 200 lines and 12,000 bytes.
        var start = window.count
        var lineBytes = 0
        var separators = 0
        var separatorBytes = 0
        var i = window.count - 1
        while i >= 0 {
            let newDay = start == window.count || days[i].dayNumber != days[start].dayNumber
            let sepBytes = newDay ? Renderer.bytes("-- " + dayLabel(days[i])) : 0
            let kept = window.count - i
            let footer = (i > 0 || page.olderExists) ? "more: imessage read \(page.chat.rowid) --before \(window[i].rowid)" : nil
            let total = Renderer.bytes(readHeader(page, kept: kept)) + separatorBytes + sepBytes + lineBytes
                + Renderer.bytes(lines[i]) + (footer.map(Renderer.bytes) ?? 0) + newerBytes
            let count = 1 + separators + (newDay ? 1 : 0) + kept + (footer == nil ? 0 : 1) + newerLines
            if total > Renderer.maxBytes || count > Renderer.maxLines { break }
            start = i
            lineBytes += Renderer.bytes(lines[i])
            if newDay {
                separators += 1
                separatorBytes += sepBytes
            }
            i -= 1
        }
        if start == window.count, let k = window.indices.last {
            // The newest line alone can't fit. Print it cut, so the page isn't empty and the footer moves past it.
            let footer = (k > 0 || page.olderExists) ? "more: imessage read \(page.chat.rowid) --before \(window[k].rowid)" : nil
            let room = Renderer.maxBytes - Renderer.bytes(readHeader(page, kept: 1))
                - Renderer.bytes("-- " + dayLabel(days[k])) - (footer.map(Renderer.bytes) ?? 0) - newerBytes
            lines[k] = Renderer.fit(lines[k], room)
            start = k
        }
        var out = [readHeader(page, kept: window.count - start)]
        var lastDay: Int?
        for k in start..<window.count {
            if days[k].dayNumber != lastDay {
                out.append("-- " + dayLabel(days[k]))
                lastDay = days[k].dayNumber
            }
            out.append(lines[k])
        }
        if start < window.count, start > 0 || page.olderExists {
            out.append("more: imessage read \(page.chat.rowid) --before \(window[start].rowid)")
        }
        if let newer { out.append(newer) }
        return Renderer.finish(out)
    }

    // MARK: show

    func show(_ detail: MessageDetail) -> String {
        let m = detail.message
        let c = civil(ns: m.dateNs)
        let head = Format.noBreaks("\(m.rowid) \(dayLabel(c)) \(hhmm(c)) in chat \(detail.chat.rowid) \(detail.chat.label)")
        let body = Array(m.text.utf8)
        let page = Renderer.showPage(body, from: detail.fromByte)
        var s = head + "\n" + Format.noBreaks(Renderer.sender(m)) + ": " + String(decoding: body[page], as: UTF8.self)
        if page.upperBound < body.count {
            s += "\n…(+\(Format.grouped(body.count - page.upperBound)) bytes: \(Renderer.showNext(m.rowid, page)))"
        }
        return s + "\n"
    }

    /// Line breaks one `show` page may hold: the head, the sender line and the footer take the other three of the
    /// 200 lines.
    static let showMaxBreaks = Limits.outputMaxLines - 3

    /// The bytes of `body` one `show` page prints. It starts at `fromByte`, moved forward off a continuation byte,
    /// and holds at most `Limits.showCapBytes`, cut back to a character boundary. It also ends right after its
    /// 197th line break (`TextNorm.isLineBreak`, CR LF counted once), so a body of short lines stays within 200.
    static func showPage(_ body: [UInt8], from fromByte: Int) -> Range<Int> {
        func isContinuation(_ b: UInt8) -> Bool { b & 0xC0 == 0x80 }
        var from = min(max(fromByte, 0), body.count)
        while from < body.count && isContinuation(body[from]) { from += 1 }
        var end = min(from + Limits.showCapBytes, body.count)
        if end < body.count {
            while end > from && isContinuation(body[end]) { end -= 1 }
        }
        func breakLength(_ j: Int) -> Int {
            func at(_ k: Int) -> UInt8? { k < body.count ? body[k] : nil }
            switch body[j] {
            case 0x0D: return at(j + 1) == 0x0A ? 2 : 1
            case 0x0A, 0x0B, 0x0C: return 1
            case 0xC2: return at(j + 1) == 0x85 ? 2 : 0
            case 0xE2: return at(j + 1) == 0x80 && (at(j + 2) == 0xA8 || at(j + 2) == 0xA9) ? 3 : 0
            default: return 0
            }
        }
        var breaks = 0
        var j = from
        while j < end {
            let n = breakLength(j)
            guard n > 0 else {
                j += 1
                continue
            }
            j += n
            breaks += 1
            if breaks == showMaxBreaks {
                end = min(end, j)
                break
            }
        }
        return from..<end
    }

    /// `imessage show <rowid> --from <end>`, the command for the page after `page`.
    static func showNext(_ rowid: Int64, _ page: Range<Int>) -> String {
        "imessage show \(rowid) --from \(page.upperBound)"
    }

    // MARK: search

    /// About 120 characters around the first match: 40 before it, `…` at each cut edge (research/tokens.md
    /// section 6). The match is ASCII case-insensitive on NFC text, as section 1's search is. No match starts at 0.
    static func snippet(_ text: String, query: String) -> String {
        let body = Array(TextNorm.oneLine(text).precomposedStringWithCanonicalMapping.unicodeScalars)
        let width = Limits.searchSnippetChars
        guard body.count > width else { return String(String.UnicodeScalarView(body)) }
        let lo = max(0, (matchIndex(body, query) ?? 0) - 40)
        let hi = min(lo + width, body.count)
        return (lo > 0 ? "…" : "") + String(String.UnicodeScalarView(body[lo..<hi])) + (lo + width < body.count ? "…" : "")
    }

    static func matchIndex(_ body: [Unicode.Scalar], _ query: String) -> Int? {
        let q = Array(query.precomposedStringWithCanonicalMapping.unicodeScalars)
        guard !q.isEmpty, q.count <= body.count else { return nil }
        func fold(_ c: Unicode.Scalar) -> UInt32 { (0x41...0x5A).contains(c.value) ? c.value + 32 : c.value }
        for i in 0...(body.count - q.count) {
            var j = 0
            while j < q.count, fold(body[i + j]) == fold(q[j]) { j += 1 }
            if j == q.count { return i }
        }
        return nil
    }

    /// `imessage search [--in <chat>] --cursor C <query>`, flags first, `--` before a query that starts with `-`.
    static func searchNext(_ page: SearchPage, cursor: String) -> String {
        let inArg = page.inChat.map { " --in \($0.rowid)" } ?? ""
        let query = (page.query.hasPrefix("-") ? "-- " : "") + Format.shellQuote(page.query)
        return "imessage search\(inArg) --cursor \(cursor) \(query)"
    }

    /// The cursor for the hits older than `hit`, in `SearchCursor` form.
    static func searchCursor(_ page: SearchPage, after hit: SearchHit) -> String {
        SearchCursor(dateNs: hit.cursorNs ?? hit.message.dateNs, rowid: hit.message.rowid,
                     windowStartNs: page.windowStartNs).text
    }

    func search(_ page: SearchPage) -> String {
        func header(_ n: Int) -> String {
            let inPart = page.inChat.map { " in \($0.label)" } ?? ""
            return Format.noBreaks("search \"\(page.query)\"\(inPart) · \(Format.plural(n, "hit")), newest first"
                + " · scanned back to \(whenShort(civil(ns: page.scannedBackToNs)))")
        }
        func footer(_ cursor: String) -> String { Format.noBreaks("more: " + Renderer.searchNext(page, cursor: cursor)) }
        func cursor(after hit: SearchHit) -> String { Renderer.searchCursor(page, after: hit) }
        var lines: [String] = []
        var size = Renderer.bytes(header(page.hits.count))
        var shown = 0
        for (i, hit) in page.hits.enumerated() {
            let m = hit.message
            let line = Format.noBreaks("\(hit.chat.rowid) \(hit.chat.label) · \(whenShort(civil(ns: m.dateNs)))"
                + " · \(m.rowid) \(Renderer.sender(m)): \(Renderer.snippet(m.text, query: page.query))")
            let isLast = i == page.hits.count - 1
            let reserve: String? = isLast ? page.nextCursor.map(footer) : footer(cursor(after: hit))
            if 1 + lines.count + 1 + (reserve == nil ? 0 : 1) > Renderer.maxLines
                || size + Renderer.bytes(line) + (reserve.map(Renderer.bytes) ?? 0) > Renderer.maxBytes {
                guard shown == 0 else { break }
                // The first hit alone can't fit: print it cut, so the page isn't empty and the cursor moves past it.
                lines.append(Renderer.fit(line, Renderer.maxBytes - size - (reserve.map(Renderer.bytes) ?? 0)))
                shown = 1
                break
            }
            lines.append(line)
            size += Renderer.bytes(line)
            shown += 1
        }
        var out = [header(shown)] + lines
        if shown < page.hits.count {
            if shown > 0 {
                out.append(footer(cursor(after: page.hits[shown - 1])))
            } else if let next = page.nextCursor {
                out.append(footer(next))
            }
        } else if let next = page.nextCursor {
            out.append(footer(next))
        }
        return Renderer.finish(out)
    }

    // MARK: who

    /// `who` with no match is an error in both the text and the NDJSON output.
    static func noContact(_ query: String) -> WireError {
        WireError.message("no contact matches \"\(query)\"", fix: "imessage chats")
    }

    static func who(_ page: ContactsPage) -> String {
        guard !page.contacts.isEmpty else { return error(noContact(page.query)) }
        func footer(_ left: Int) -> String {
            Format.noBreaks("more: \(Format.plural(left, "more contact")) match \"\(page.query)\", pass a fuller name")
        }
        var out: [String] = []
        var size = 0
        for (i, p) in page.contacts.enumerated() {
            let after = page.contacts.count - i - 1
            let reserve = after > 0 ? footer(after) : nil
            let roomBytes = maxBytes - size - (reserve.map(bytes) ?? 0)
            if out.count + 1 + (reserve == nil ? 0 : 1) <= maxLines,
               let line = contactLine(p, budget: roomBytes, mustPrint: i == 0) {
                out.append(line.text)
                size += bytes(line.text)
                guard line.cut else { continue }
                // The chats list was cut to fit, so nothing more fits after it.
                if let reserve { out.append(reserve) }
                break
            }
            out.append(footer(page.contacts.count - i))
            break
        }
        return finish(out)
    }

    /// One `who` line. When it passes `budget` bytes with its newline, the chats list keeps the chats that fit and
    /// ends in `+N more chats`. Nil when not even that fits, unless `mustPrint`, which cuts the line as a backstop.
    static func contactLine(_ p: ContactRecord, budget: Int, mustPrint: Bool) -> (text: String, cut: Bool)? {
        let handles = p.handles.map { h -> String in
            let label = Format.readerFormat(h.id)
            let services = Array(Set(h.services)).sorted()
            return services.isEmpty ? label : "\(label) (\(services.joined(separator: ", ")))"
        }
        let chats = p.chats.map { $0.isGroup ? "\($0.rowid) \($0.label)" : "\($0.rowid) (direct)" }
        let head = "\(p.shortName) = \(p.firstName) \(p.lastName) · \(handles.joined(separator: " · ")) · chats: "
        let full = Format.noBreaks(head + chats.joined(separator: ", "))
        if bytes(full) <= budget { return (full, false) }
        func rest(_ kept: Int) -> String { "+" + Format.plural(chats.count - kept, "more chat") }
        // Each chat is folded on its own: the `, ` between chats keeps a fold from spanning two of them.
        var used = bytes(Format.noBreaks(head))
        var best: Int?
        for k in 0..<chats.count {
            let sep = k == 0 ? 0 : 2
            if used + sep + rest(k).utf8.count <= budget { best = k }
            used += sep + Format.noBreaks(chats[k]).utf8.count
        }
        if let k = best {
            let kept = chats.prefix(k) + [rest(k)]
            return (Format.noBreaks(head + kept.joined(separator: ", ")), true)
        }
        guard mustPrint else { return nil }
        return (fit(Format.noBreaks(head + (chats.isEmpty ? "" : rest(0))), budget), true)
    }

    // MARK: att

    static func attachment(_ export: AttachmentExport) -> String {
        let a = export.attachment
        let base = Format.join("a\(a.rowid)", a.kind.rawValue, a.transferName)
        if let r = export.result {
            if case .error = r.code { return finish([r.rendered]) }
            return finish([Format.noBreaks(base + " · " + r.rendered)])
        }
        guard let path = export.path, !path.isEmpty else {
            return finish([ActionResult(.error(.message("no viewable copy of a\(a.rowid)"))).rendered])
        }
        var dims = ""
        if let w = a.width, let h = a.height, w > 0, h > 0 { dims = "\(w)x\(h)" }
        var line = Format.join(base, Format.size(a.totalBytes), dims) + " -> " + path
        if export.converted { line += " (\(Limits.heicMaxPixel)px)" }
        return finish([Format.noBreaks(line)])
    }

    // MARK: send

    static func send(_ o: SendOutcome) -> String {
        var out: [String] = o.approved ? ["approved"] : []
        let repeatNote = o.replayed ? " (repeat)" : ""
        if let early = o.early {
            out.append(early.rendered(tail: repeatNote))
            return finish(out)
        }
        guard let first = o.parts.first else {
            out.append(ActionResult(.mayHaveCompleted).rendered(tail: repeatNote))
            return finish(out)
        }
        let label = o.chat.label
        var textPieces: [String] = []
        if let p = o.threadParentRowID { textPieces.append("↩\(p)") }
        if let t = o.text {
            let one = TextNorm.oneLine(t)
            if !one.isEmpty { textPieces.append("\"" + Format.cut(one, Limits.bodyCutChars) + "\"") }
        }
        func pieces(_ part: SendPartOutcome) -> [String] {
            switch part.part {
            case .text: return textPieces
            case .file: return part.attachment.map { [Format.attachmentToken($0)] } ?? ["[file]"]
            }
        }
        func line(_ rowids: [Int64], _ items: [String], _ result: ActionResult) -> String {
            let verb = rowids.isEmpty ? "send" : "sent " + rowids.map(String.init).joined(separator: ",")
            return Format.noBreaks(Format.join(verb, "to", label, items.joined(separator: " ")) + " · "
                + result.rendered(tail: repeatNote))
        }
        if o.parts.allSatisfy({ $0.result == first.result }) {
            if case .error = first.result.code {
                out.append(first.result.rendered)
            } else {
                out.append(line(o.parts.compactMap { $0.rowid }, o.parts.flatMap(pieces), first.result))
            }
        } else {
            for part in o.parts {
                out.append(line(part.rowid.map { [$0] } ?? [], pieces(part), part.result))
            }
        }
        return finish(out)
    }

    // MARK: react, unsend, edit

    static func ui(_ o: UIOutcome) -> String {
        var out: [String] = o.approved ? ["approved"] : []
        if case .error = o.result.code {
            out.append(o.result.rendered)
            return finish(out)
        }
        let done = o.result.code == .ok
        let target = "\(o.targetRowID)"
        let emoji = o.tapback?.displayEmoji ?? ""
        var head: String
        switch o.action {
        case .react where o.remove: head = Format.join(done ? "removed" : "remove", emoji, "from", target)
        case .react: head = Format.join(done ? "reacted" : "react", emoji, "to", target)
        case .unsend: head = (done ? "unsent " : "unsend ") + target
        case .edit: head = (done ? "edited " : "edit ") + target
        }
        if let q = o.targetQuote {
            head += " (\(q.senderName): \(Format.cut(TextNorm.oneLine(q.text), Limits.quoteChars)))"
        }
        if let c = o.chat { head += " in chat \(c.rowid)" }
        var repeatNote = ""
        if o.replayed {
            repeatNote = o.action == .react ? " (repeat, now \(o.currentReaction?.displayEmoji ?? "none"))" : " (repeat)"
        }
        out.append(Format.noBreaks(head + " · " + o.result.rendered(tail: repeatNote)))
        return finish(out)
    }

    // MARK: allow, revoke

    static func policy(_ o: PolicyOutcome) -> String {
        if case .error = o.result.code { return finish([o.result.rendered]) }
        // A new direct target has no chat number yet (ROWID 0), so only its label prints.
        let chat = o.chat.map { $0.rowid == 0 ? $0.label : "\($0.rowid) \($0.label)" } ?? "chat"
        let head: String
        switch o.change {
        case .allowChat: head = "allow \(chat) (\((o.scope ?? .text).rawValue))"
        case .revokeChat: head = "revoke \(chat)"
        case .foregroundOn: head = "allow --foreground"
        case .foregroundOff: head = "revoke --foreground"
        }
        return finish([Format.noBreaks(head + " · " + o.result.rendered)])
    }

    // MARK: pending

    func pending(_ list: PendingList) -> String {
        var out = ["pending · \(Format.plural(list.items.count, "open approval"))"]
        var size = Renderer.bytes(out[0])
        for (i, item) in list.items.enumerated() {
            let line = Format.noBreaks("\(item.id) \(item.summary) · asked \(whenShort(civil(item.createdAt)))"
                + " · expires \(whenShort(civil(item.expiresAt)))")
            let footer = "more: \(list.items.count - i) not shown, imessage pending <id> shows one"
            let last = i == list.items.count - 1
            if out.count + 1 + (last ? 0 : 1) > Renderer.maxLines
                || size + Renderer.bytes(line) + (last ? 0 : Renderer.bytes(footer) + 8) > Renderer.maxBytes {
                out.append(footer)
                break
            }
            out.append(line)
            size += Renderer.bytes(line)
        }
        return Renderer.finish(out)
    }

    // MARK: changes

    /// A cursor that still covers every change in `unshown`: the ROWID drops below the lowest unshown new row and
    /// the time below the earliest unshown edit, unsend, read or delivery. Some shown changes come back again;
    /// none are skipped. A change whose time is 0 or less can't be found by time, so it doesn't move the time back.
    /// When a shown change has the same time as an unshown one, the page stopped inside that time, so the cursor
    /// keeps the time and takes a tie ROWID just below the unshown row. Moving the time back would bring the same
    /// page again when one time holds more changes than a page shows.
    static func resumeCursor(_ page: ChangesPage, unshown: ArraySlice<ChangeRecord>) -> String {
        guard var cur = ChangeCursor(text: page.cursor) else { return page.cursor }
        let shownTimes = Set(page.changes[..<unshown.startIndex].filter { $0.kind != .new }.map(\.eventNs))
        func lowerTime(_ ns: AppleNanos, _ rowid: Int64) {
            guard ns > 0 else { return }
            let before = shownTimes.contains(ns) ? ChangeCursor(rowid: cur.rowid, timeNs: ns, tieRowID: rowid - 1)
                : ChangeCursor(rowid: cur.rowid, timeNs: ns - 1)
            if before.position < cur.position { cur = before }
        }
        for c in unshown {
            switch c.kind {
            case .new: cur.rowid = min(cur.rowid, c.message.rowid - 1)
            case .edited, .unsent, .read, .delivered: lowerTime(c.eventNs, c.message.rowid)
            }
        }
        return cur.text
    }

    func changes(_ page: ChangesPage) -> String {
        func header(_ n: Int) -> String { "changes · \(Format.plural(n, "change")) · times \(zone)" }
        // Every footer form is `more: imessage changes --since <rowid>:<ns>[:<tie>]` or `cursor <rowid>:<ns>[:<tie>]`,
        // under 96 bytes.
        let footerReserve = 96
        let onScreen = Set(page.changes.map { $0.message.rowid })
        var lines: [String] = []
        var size = Renderer.bytes(header(page.changes.count)) + footerReserve
        var lastDay: Int?
        var shown = 0
        for ch in page.changes {
            let c = civil(ns: ch.message.dateNs)
            var add: [String] = []
            if c.dayNumber != lastDay { add.append("-- " + dayLabel(c)) }
            add.append(Format.noBreaks("\(ch.kind.rawValue) \(ch.chat.rowid) \(ch.chat.label) · "
                + messageLine(ch.message, onScreen)))
            let addBytes = add.reduce(0) { $0 + Renderer.bytes($1) }
            if 1 + lines.count + add.count + 1 > Renderer.maxLines || size + addBytes > Renderer.maxBytes {
                guard shown == 0 else { break }
                // The first change alone can't fit: print it cut, so the cursor moves past it.
                let lead = add.dropLast().reduce(0) { $0 + Renderer.bytes($1) }
                add[add.count - 1] = Renderer.fit(add[add.count - 1], Renderer.maxBytes - size - lead)
                lines += add
                shown = 1
                break
            }
            lines += add
            size += addBytes
            lastDay = c.dayNumber
            shown += 1
        }
        var out = [header(shown)] + lines
        if shown < page.changes.count {
            out.append("more: imessage changes --since \(Renderer.resumeCursor(page, unshown: page.changes[shown...]))")
        } else if page.truncated {
            out.append("more: imessage changes --since \(page.cursor)")
        } else {
            out.append("cursor \(page.cursor)")
        }
        return Renderer.finish(out.map(Format.noBreaks))
    }

    // MARK: wait

    func wait(_ o: WaitOutcome) -> String {
        guard !o.timedOut, let m = o.message else { return Renderer.finish([ResultCode.timeout.wire]) }
        let line = messageLine(m, [])
        guard let c = o.chat else { return Renderer.finish([line]) }
        return Renderer.finish([Format.noBreaks("chat \(c.rowid) \(c.label) · ") + line])
    }

    // MARK: caps, status, setup, doctor

    static let releaseTestNote = "release-test build"

    static func caps(_ r: CapsReport) -> String {
        var head = "caps · macOS \(r.macOSVersion)"
        if r.entries.contains(where: { $0.note == releaseTestNote }) { head += " · \(releaseTestNote)" }
        if !r.uiLanguageEnglish { head += " · UI language isn't English, UI actions unsupported" }
        head += " · Accessibility \(r.accessibilityTrusted ? "on" : "off")"
        head += " · foreground mode \(r.foregroundMode ? "on" : "off")"
        let lines = r.entries.map { e in
            Format.noBreaks("\(e.name) \(e.status.rawValue)" + (e.note.map { " (\($0))" } ?? ""))
        }
        return finish([Format.noBreaks(head)] + lines)
    }

    static func permission(_ p: PermissionState) -> String {
        switch p {
        case .granted: return "granted"
        case .denied: return "denied"
        case .notDetermined: return "not determined"
        case .unknown: return "unknown"
        }
    }

    static func status(_ r: StatusReport) -> String {
        var out = ["status · bridge \(r.bridgeVersion) pid \(r.pid)"]
        out.append("Full Disk Access \(permission(r.fullDiskAccess))")
        out.append("Automation \(permission(r.automation))")
        out.append("Accessibility \(permission(r.accessibility))")
        out.append("Messages \(r.messagesRunning ? "running" : "not running")")
        var fg = "foreground mode \(r.foregroundMode ? "on" : "off")"
        if let reason = r.foregroundOffReason, !r.foregroundMode { fg += ": \(reason)" }
        out.append(fg)
        out.append(r.allowlistTrusted
                   ? "allowlist \(Format.plural(r.allowedChats, "chat"))"
                   : "allowlist failed its check, nothing is allowed until chats are approved again")
        out.append("approvals \(r.openApprovals) open")
        if let note = r.crashNote { out.append("crash: \(note)") }
        return finish(out.map(Format.noBreaks))
    }

    static func stageName(_ s: SetupStage) -> String {
        switch s {
        case .fullDiskAccess: return "Full Disk Access"
        case .automation: return "Automation"
        case .accessibility: return "Accessibility"
        }
    }

    static func setup(_ r: SetupReport) -> String {
        var line = "setup \(stageName(r.stage)): \(permission(r.state))"
        if let pane = r.openedPane { line += " · opened \(pane)" }
        return finish([Format.noBreaks(line)])
    }

    static func doctor(_ r: DoctorReport) -> String {
        let failing = r.checks.filter { !$0.ok }.count
        var head = "doctor · \(Format.plural(r.checks.count, "check")), \(failing) failing"
        if r.releaseTestBuild { head += " · \(releaseTestNote)" }
        var out = [head]
        for c in r.checks {
            var line = (c.ok ? "ok " : "fail ") + c.name
            if let d = c.detail { line += ": \(d)" }
            if !c.ok, let fix = c.fix { line += " fix: \(fix)" }
            out.append(Format.noBreaks(line))
        }
        if r.needsKickstart { out.append("kickstart needed: the bridge can't open chat.db yet") }
        return finish(out)
    }

    // MARK: errors

    /// At most this many candidates print after `error: several matches`, so the line stays short.
    static let maxCandidates = 10

    static func error(_ e: WireError) -> String {
        var s = e.result.code.wire
        if !e.candidates.isEmpty {
            var items = e.candidates.prefix(maxCandidates).map { "\($0.label) (\($0.argument))" }
            if e.candidates.count > maxCandidates { items.append("\(e.candidates.count - maxCandidates) more") }
            s += ": " + items.joined(separator: ", ")
        }
        for n in e.result.notes { s += ", " + n.wire }
        if let fix = e.result.fix { s += " fix: " + fix }
        return finish([TextNorm.singleLine(s)])
    }
}

// MARK: - NDJSON

/// `--json` output. One JSON object per line, sorted keys. Lists print one record per item. A chat prints once,
/// and its messages carry only its ROWID.
///
/// Lists keep the cap of the text output: at most 200 records and 12,000 bytes. A list cut short ends with one
/// `{"type":"more","next":"<command>"}` record holding the command the text footer gives; `who` has no next
/// page, so its record counts the contacts left out instead (`"left"`). A record is never split, so the first one
/// always prints and every page moves forward. An `unread` page also ends at the first chat whose entries
/// ReadService cut, with a `more` record for the rest of that chat. `show` pages the body as the text output does
/// and adds `offset` (the page's first byte), `total` and, while bytes remain, `next`.
///
/// A message record has `id`, `guid`, `chat`, `date`, `ns`, `from` (the sender) and `text`, plus `me` when the user
/// sent it, `read` when someone else did, `reply` (the parent's ROWID), `parts` when it has more than one part,
/// `delivered` (Apple ns) once delivered, `att` entries with `id`, `kind`, `name`, `onDisk`, `state` (transfer_state)
/// and `uti`, and `react` entries with `kind` and `by` (`You` for the user). scripts/tests/fixtures holds golden
/// output that `NDJSONGoldenTests` and the release-test harness test both read.
enum NDJSON {
    static let maxRecords = Limits.outputMaxLines
    static let maxBytes = Limits.outputMaxBytes

    static func render(_ payload: ResponsePayload) -> String {
        var lines: [[String: Any]] = []
        switch payload {
        case .chats(let p):
            let units = p.chats.map { c -> [[String: Any]] in
                var o = chat(c)
                if let last = c.last { o["last"] = message(last, chat: c.rowid, type: false) }
                return [o]
            }
            let tail = p.hasMore ? [more("imessage chats -n \(p.limit + 20)")] : []
            lines = page(head: { _ in [] }, units: units, more: { more("imessage read \(p.chats[$0].rowid)") }, tail: tail)
        case .unread(let p):
            let summary: [String: Any] = ["type": "unread", "total": p.totalUnread, "chats": p.groups.count]
            var units: [[[String: Any]]] = []
            var spots: [(chat: Int64, rowid: Int64?)] = []
            var stop: [[String: Any]] = []
            for g in p.groups {
                // ReadService stops building entries once the 200-line text page is full, so a group can hold
                // fewer unread rows than its count. The page ends there and points at the rest of that chat.
                let complete = g.entries.filter(\.isUnread).count >= g.unreadCount
                var o = chat(g.chat)
                o["unread"] = g.unreadCount
                var lead = [o]
                if g.entries.isEmpty, complete {
                    units.append(lead)
                    spots.append((g.chat.rowid, nil))
                }
                for e in g.entries {
                    var m = message(e.message, chat: g.chat.rowid)
                    m["unread"] = e.isUnread
                    if e.gapBefore { m["gap"] = true }
                    units.append(lead + [m])
                    lead = []
                    spots.append((g.chat.rowid, e.message.rowid))
                }
                if !complete {
                    let after = g.entries.last.map { " --after \($0.message.rowid)" } ?? ""
                    stop = [more("imessage read \(g.chat.rowid)\(after)")]
                    break
                }
            }
            // Cut inside a chat: read the rest of it. Cut before a chat: read that chat.
            func next(_ kept: Int) -> [String: Any] {
                let chat = spots[kept].chat
                if kept > 0, spots[kept - 1].chat == chat, let after = spots[kept - 1].rowid {
                    return more("imessage read \(chat) --after \(after)")
                }
                return more("imessage read \(chat)")
            }
            lines = page(head: { _ in [summary] }, units: units, more: next, tail: stop)
        case .messages(let p):
            var o = chat(p.chat)
            o["total"] = p.totalVisible
            o["older"] = p.olderExists
            if p.newerExists { o["newer"] = true }
            // Keep the newest messages that fit, as the text output does, and print them oldest first.
            let back = Array(p.messages.reversed())
            let units = back.map { [message($0, chat: p.chat.rowid)] }
            func before(_ kept: Int) -> [String: Any] { more("imessage read \(p.chat.rowid) --before \(back[kept - 1].rowid)") }
            let kept = keep(head: { _ in [o] }, units: units, more: before, tail: [])
            lines = [o] + units.prefix(kept).reversed().flatMap { $0 }
            if kept < units.count { lines.append(before(kept)) }
        case .message(let d):
            lines.append(ref(d.chat))
            let body = Array(d.message.text.utf8)
            let range = Renderer.showPage(body, from: d.fromByte)
            var o = message(d.message, chat: d.chat.rowid)
            o["text"] = String(decoding: body[range], as: UTF8.self)
            o["offset"] = range.lowerBound
            o["total"] = body.count
            if range.upperBound < body.count { o["next"] = Renderer.showNext(d.message.rowid, range) }
            lines.append(o)
        case .search(let p):
            func cursor(_ kept: Int) -> String { Renderer.searchCursor(p, after: p.hits[kept - 1]) }
            func head(_ kept: Int) -> [[String: Any]] {
                var o: [String: Any] = ["type": "search", "query": p.query, "scannedBackTo": iso(p.scannedBackToNs),
                                        "windowStart": iso(p.windowStartNs), "budgetExhausted": p.budgetExhausted]
                if let c = p.inChat { o["in"] = c.rowid }
                if let next = kept < p.hits.count ? cursor(kept) : p.nextCursor { o["cursor"] = next }
                return [o]
            }
            var seen = Set<Int64>()
            let units = p.hits.map { h -> [[String: Any]] in
                (seen.insert(h.chat.rowid).inserted ? [ref(h.chat)] : []) + [message(h.message, chat: h.chat.rowid)]
            }
            lines = page(head: head, units: units, more: { more(Renderer.searchNext(p, cursor: cursor($0))) })
        case .contacts(let p):
            if p.contacts.isEmpty {
                lines.append(failure(Renderer.noContact(p.query)))
                break
            }
            let units = p.contacts.map { c -> [[String: Any]] in [[
                "type": "contact", "short": c.shortName, "first": c.firstName, "last": c.lastName,
                "handles": c.handles.map { ["id": $0.id, "services": $0.services] as [String: Any] },
                "chats": c.chats.map { ["id": $0.rowid, "label": $0.label, "group": $0.isGroup] as [String: Any] },
            ]] }
            lines = page(head: { _ in [] }, units: units, more: { ["type": "more", "left": p.contacts.count - $0] })
        case .changes(let p):
            // A cut page's cursor is the one the text footer gives, so a script that reads it skips nothing.
            func cursor(_ kept: Int) -> String { Renderer.resumeCursor(p, unshown: p.changes[kept...]) }
            func head(_ kept: Int) -> [[String: Any]] {
                let cut = kept < p.changes.count
                return [["type": "cursor", "cursor": cut ? cursor(kept) : p.cursor, "truncated": p.truncated || cut]]
            }
            var seen = Set<Int64>()
            let units = p.changes.map { c -> [[String: Any]] in
                var m = message(c.message, chat: c.chat.rowid)
                m["type"] = "change"
                m["kind"] = c.kind.rawValue
                return (seen.insert(c.chat.rowid).inserted ? [ref(c.chat)] : []) + [m]
            }
            lines = page(head: head, units: units, more: { more("imessage changes --since \(cursor($0))") })
        case .wait(let o):
            if o.timedOut || o.message == nil {
                lines.append(["type": "timeout"])
            } else {
                if let c = o.chat { lines.append(ref(c)) }
                if let m = o.message { lines.append(message(m, chat: o.chat?.rowid ?? m.chatRowID)) }
            }
        case .failure(let e):
            lines.append(failure(e))
        case .attachment(let v): lines.append(encoded(v, type: "attachment"))
        case .send(let v): lines.append(encoded(v, type: "send"))
        case .ui(let v): lines.append(encoded(v, type: "ui"))
        case .policy(let v): lines.append(encoded(v, type: "policy"))
        case .pending(let v): lines.append(encoded(v, type: "pending"))
        case .caps(let v): lines.append(encoded(v, type: "caps"))
        case .status(let v): lines.append(encoded(v, type: "status"))
        case .setup(let v): lines.append(encoded(v, type: "setup"))
        case .doctor(let v): lines.append(encoded(v, type: "doctor"))
        case .pong(let v): lines.append(encoded(v, type: "pong"))
        }
        return lines.map(serialize).map { $0 + "\n" }.joined()
    }

    static func more(_ next: String) -> [String: Any] { ["type": "more", "next": next] }

    /// `head(kept)`, the units that fit in order, then `tail` when all of them fit or `more(kept)` when not.
    static func page(head: (Int) -> [[String: Any]], units: [[[String: Any]]], more: (Int) -> [String: Any],
                     tail: [[String: Any]] = []) -> [[String: Any]] {
        let kept = keep(head: head, units: units, more: more, tail: tail)
        return head(kept) + units.prefix(kept).flatMap { $0 } + (kept < units.count ? [more(kept)] : tail)
    }

    /// How many leading `units` fit in 200 records and 12,000 bytes together with `head(kept)` and what closes the
    /// page: `tail` once every unit is in, else `more(kept)`. At least one unit is kept when there is one, even a
    /// unit larger than the budget, because a record is never split.
    static func keep(head: (Int) -> [[String: Any]], units: [[[String: Any]]], more: (Int) -> [String: Any],
                     tail: [[String: Any]]) -> Int {
        func size(_ records: [[String: Any]]) -> (count: Int, bytes: Int) {
            (records.count, records.reduce(0) { $0 + serialize($1).utf8.count + 1 })
        }
        var count = 0
        var bytes = 0
        var kept = 0
        for (i, unit) in units.enumerated() {
            let k = i + 1
            let u = size(unit)
            let h = size(head(k))
            let close = size(k == units.count ? tail : [more(k)])
            if h.count + count + u.count + close.count > maxRecords || h.bytes + bytes + u.bytes + close.bytes > maxBytes {
                break
            }
            count += u.count
            bytes += u.bytes
            kept = k
        }
        return max(kept, min(1, units.count))
    }

    static func failure(_ e: WireError) -> [String: Any] {
        var o: [String: Any] = ["type": "error", "code": e.result.code.wire, "line": TextNorm.singleLine(Format.error(e))]
        if let fix = e.result.fix { o["fix"] = fix }
        if !e.candidates.isEmpty {
            o["candidates"] = e.candidates.map { ["label": $0.label, "argument": $0.argument] }
        }
        return o
    }

    static func serialize(_ o: [String: Any]) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes]),
              let s = String(data: d, encoding: .utf8) else { return "{\"type\":\"error\"}" }
        return s
    }

    /// The value's wire encoding (JSONEncoder.wire) with a `type` key added.
    static func encoded<T: Encodable>(_ v: T, type: String) -> [String: Any] {
        guard let data = try? JSONEncoder.wire.encode(v),
              var o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return ["type": type] }
        o["type"] = type
        return o
    }

    /// ISO 8601 UTC with seconds, `2026-11-06T08:30:00Z`.
    static func iso(_ ns: AppleNanos) -> String {
        let secs = Renderer.wholeSeconds(Double(ns) / 1e9 + AppleTime.epochOffset)
        var t = time_t(secs)
        var tm = tm()
        gmtime_r(&t, &tm)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02dZ", Int(tm.tm_year) + 1900, Int(tm.tm_mon) + 1,
                      Int(tm.tm_mday), Int(tm.tm_hour), Int(tm.tm_min), Int(tm.tm_sec))
    }

    static func chat(_ c: ChatRecord) -> [String: Any] {
        var o: [String: Any] = ["type": "chat", "id": c.rowid, "label": c.label, "group": c.isGroup,
                                "service": c.service, "unread": c.unreadCount]
        if c.isGroup { o["members"] = c.memberNames }
        if !c.displayName.isEmpty { o["name"] = c.displayName }
        return o
    }

    static func ref(_ c: ChatRef) -> [String: Any] {
        ["type": "chat", "id": c.rowid, "label": c.label, "group": c.isGroup]
    }

    /// `chat` is the ROWID of the chat record the message prints under. For a contact's merged iMessage and SMS
    /// chats that is the conversation's primary chat, not the chat.db chat in `m.chatRowID`, so every message names
    /// a chat record in the same output.
    static func message(_ m: MessageRecord, chat: Int64, type: Bool = true) -> [String: Any] {
        var o: [String: Any] = ["id": m.rowid, "guid": m.guid, "chat": chat, "date": iso(m.dateNs),
                                "ns": m.dateNs, "from": m.fromMe ? "You" : m.senderName, "text": m.text]
        if type { o["type"] = "message" }
        if m.fromMe { o["me"] = true }
        if !m.fromMe { o["read"] = m.isRead }
        if let r = m.replyTo { o["reply"] = r.rowid }
        if m.partCount > 1 { o["parts"] = m.partCount }
        if m.dateDeliveredNs != 0 { o["delivered"] = m.dateDeliveredNs }
        if !m.attachments.isEmpty {
            o["att"] = m.attachments.map { a -> [String: Any] in
                var x: [String: Any] = ["id": a.rowid, "kind": a.kind.rawValue, "name": a.transferName,
                                        "onDisk": a.onDisk, "state": a.transferState]
                if let u = a.uti { x["uti"] = u }
                if let b = a.totalBytes { x["bytes"] = b }
                if let w = a.width, let h = a.height { x["w"] = w; x["h"] = h }
                if let t = a.transcript { x["transcript"] = t }
                return x
            }
        }
        if m.edited { o["edited"] = true }
        if m.unsent { o["unsent"] = true }
        if m.partUnsent { o["partUnsent"] = true }
        if m.errorCode != 0 { o["failed"] = m.errorCode }
        if !m.reactions.isEmpty {
            o["react"] = m.reactions.map { ["kind": $0.kind.wireName, "emoji": $0.kind.displayEmoji,
                                            "by": $0.fromMe ? "You" : $0.actorName, "part": $0.part] as [String: Any] }
        }
        if !m.stickers.isEmpty {
            o["stickers"] = m.stickers.map { ["by": $0.fromMe ? "You" : $0.actorName, "part": $0.part] as [String: Any] }
        }
        if let e = m.event {
            var x: [String: Any] = ["kind": e.kind.rawValue, "actor": e.actorName]
            if let other = e.otherName { x["other"] = other }
            if let t = e.title { x["title"] = t }
            o["event"] = x
        }
        if let l = m.link {
            var x: [String: Any] = [:]
            if let u = l.url { x["url"] = u }
            if let s = l.site { x["site"] = s }
            if let t = l.title { x["title"] = t }
            o["link"] = x
        }
        if m.agentSent { o["agent"] = true }
        return o
    }
}
