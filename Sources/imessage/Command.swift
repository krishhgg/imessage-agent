import Foundation
import IMCore

/// Every verb of DESIGN.md section 5, parsed. The CLI holds no grants and depends on IMCore only.
enum Command: Hashable {
    case chats(limit: Int, unreadOnly: Bool)
    case unread(context: Int)
    case read(who: String, limit: Int, before: Int64?, after: Int64?, around: Int64?, since: String?)
    /// `--from` pages a long body (from ours.py; not in the section 5 table).
    case show(rowid: Int64, fromByte: Int)
    case search(text: String, inWho: String?, since: String?, cursor: String?, limit: Int)
    case who(name: String)
    case att(id: Int64)
    case send(who: String, text: String?, file: String?, again: Bool, thread: Bool)
    case react(rowid: Int64, kind: TapbackKind, remove: Bool, again: Bool)
    case unsend(rowid: Int64, again: Bool)
    case edit(rowid: Int64, text: String, again: Bool)
    case allow(who: String?, files: Bool, foreground: Bool)
    case revoke(who: String?, foreground: Bool)
    case pending(id: String?)
    case wait(fromWho: String?, timeout: TimeInterval)
    case changes(since: String?)
    case caps
    /// `doctor [--ui]`. `--ui` also raises the Accessibility prompt (install flow step 5). Not in the section 5
    /// table; INSTALL.md uses this spelling.
    case doctor(wantUIActions: Bool)
    case setup
    case help(topic: String?)

    /// True for the verbs that can send, change or react to a message or change the policy. A lost response to one
    /// of these must not be answered with advice that could repeat it.
    var isMutation: Bool {
        switch self {
        case .send, .react, .unsend, .edit, .allow, .revoke: return true
        default: return false
        }
    }
}

struct Invocation: Hashable {
    var command: Command
    /// `--json`: NDJSON for scripts (section 5, Output).
    var json: Bool
}

/// One-line usage error: `error: <message> fix: <fix>`. Exit code 2.
struct UsageError: Error, Hashable {
    var message: String
    var fix: String?

    init(message: String, fix: String?) {
        self.message = message
        self.fix = fix
    }

    /// A usage error that prints the same line as an IMCore error result, such as `ActionResult.threadWithFile`.
    init(_ result: ActionResult) {
        if case .error(.message(let m)) = result.code {
            self.message = m
        } else {
            self.message = result.code.wire
        }
        self.fix = result.fix
    }

    /// The printed line, without a trailing newline. Rendered by `ActionResult.rendered`, so line breaks in the
    /// message fold and there is one space before `fix:`.
    var line: String { ActionResult(.error(.message(message)), fix: fix).rendered }
}

/// Hand-written parser, no third-party dependencies. Owner: imessage CLI.
///
/// Rules:
/// - `--json` is accepted anywhere.
/// - `send` needs text unless `--file` is given; `--thread` with `--file` is a usage error.
/// - `allow`/`revoke` take `<who>` or `--foreground`, not both.
/// - `doctor` takes only `--ui`, which sets `wantUIActions`.
/// - `react` kinds: heart, like, dislike, laugh, emphasize, question, or one emoji (`TapbackKind(wireName:)`).
/// - Numbers must be positive; `-n` and `-c` are capped by the bridge, not here.
///
/// Details the rules above leave open:
/// - `--help` or `-h` anywhere prints the usage for the verb. `--` ends the flags, so text that starts with `-`
///   can follow it. A flag that takes a value takes the next argument as it is.
/// - Unknown flags, a flag given twice, a missing value and extra arguments are usage errors.
/// - `-c` and `--from` may be 0, since `unread -c 0` and `show <rowid> --from 0` mean something. ROWIDs, `-n` and
///   `--timeout` must be 1 or more. Numbers are decimal digits only.
/// - `who` and `search` join their words with single spaces, so `who Jordan Kim` works unquoted. Other verbs take
///   one argument per slot; a name or text with spaces must be quoted.
/// - Text that is empty after trimming counts as no text.
/// - `--since T` must be a `TimeSpec` form. The `search --cursor` and `changes --since` cursors must parse as
///   `SearchCursor` and `ChangeCursor`.
enum ArgumentParser {
    static func parse(_ arguments: [String]) throws -> Invocation {
        var json = false
        var help = false
        var i = 0
        while i < arguments.count, globalFlags.contains(arguments[i]) {
            if arguments[i] == "--json" { json = true } else { help = true }
            i += 1
        }
        guard i < arguments.count else {
            if help { return Invocation(command: .help(topic: nil), json: json) }
            throw UsageError(message: "missing verb", fix: "imessage help")
        }
        let verb = arguments[i]
        guard let spec = specs[verb] else {
            if verb == "--" || (verb.count > 1 && verb.hasPrefix("-")) {
                throw UsageError(message: "unknown flag \(quoted(verb)) before the verb", fix: "imessage help")
            }
            throw UsageError(message: "unknown verb \(quoted(verb))", fix: "imessage help")
        }
        let scan = try Scan(arguments[(i + 1)...], verb: verb, spec: spec)
        json = json || scan.json
        if help || scan.help {
            return Invocation(command: .help(topic: verb == "help" ? scan.words.first : verb), json: json)
        }
        return Invocation(command: try build(verb, scan), json: json)
    }

    static let usage = """
    usage: imessage <verb> [args] [--json]
      chats [-n 20] [--unread]      unread [-c 2]
      read <who> [-n 30] [--before|--after|--around ROWID] [--since T]
      show <rowid> [--from N]       search <text> [--in who] [--since T] [--cursor C] [-n 20]
      who <name>                    att <id>
      send <who> [<text>] [--file P] [--again] [--thread]
      react <msg> <kind> [--remove] [--again]
      unsend <msg> [--again]        edit <msg> <text> [--again]
      allow <who> [--files]  revoke <who>  allow --foreground  revoke --foreground  pending [<id>]
      wait [--from who] [--timeout 300]  changes [--since CURSOR]
      caps  doctor [--ui]  setup
    """

    /// The usage text for `help`. With a known verb, the first line plus the lines that name it; otherwise all of it.
    static func helpText(_ topic: String?) -> String {
        let lines = usage.components(separatedBy: "\n")
        guard let topic, specs[topic] != nil, topic != "help" else { return usage + "\n" }
        let matching = lines.dropFirst().filter { line in
            line.split(separator: " ").contains { $0 == Substring(topic) }
        }
        guard !matching.isEmpty else { return usage + "\n" }
        return ([lines[0]] + matching).joined(separator: "\n") + "\n"
    }

    // MARK: Verb table

    struct Spec {
        var bools: Set<String> = []
        var values: Set<String> = []
    }

    static let globalFlags: Set<String> = ["--json", "--help", "-h"]

    static let specs: [String: Spec] = [
        "chats": Spec(bools: ["--unread"], values: ["-n"]),
        "unread": Spec(values: ["-c"]),
        "read": Spec(values: ["-n", "--before", "--after", "--around", "--since"]),
        "show": Spec(values: ["--from"]),
        "search": Spec(values: ["--in", "--since", "--cursor", "-n"]),
        "who": Spec(),
        "att": Spec(),
        "send": Spec(bools: ["--again", "--thread"], values: ["--file"]),
        "react": Spec(bools: ["--remove", "--again"]),
        "unsend": Spec(bools: ["--again"]),
        "edit": Spec(bools: ["--again"]),
        "allow": Spec(bools: ["--files", "--foreground"]),
        "revoke": Spec(bools: ["--foreground"]),
        "pending": Spec(),
        "wait": Spec(values: ["--from", "--timeout"]),
        "changes": Spec(values: ["--since"]),
        "caps": Spec(),
        "doctor": Spec(bools: ["--ui"]),
        "setup": Spec(),
        "help": Spec(),
    ]

    /// The arguments after the verb, split into words, boolean flags and flag values.
    struct Scan {
        let verb: String
        var words: [String] = []
        var flags: Set<String> = []
        var values: [String: String] = [:]
        var json = false
        var help = false

        init(_ args: ArraySlice<String>, verb: String, spec: Spec) throws {
            self.verb = verb
            var literal = false
            var idx = args.startIndex
            while idx < args.endIndex {
                let a = args[idx]
                idx += 1
                if literal {
                    words.append(a)
                    continue
                }
                switch a {
                case "--":
                    literal = true
                case "--json":
                    json = true
                case "--help", "-h":
                    help = true
                case _ where spec.values.contains(a):
                    guard idx < args.endIndex else {
                        throw UsageError(message: "\(a) needs a value", fix: "imessage help \(verb)")
                    }
                    guard values[a] == nil else { throw Scan.twice(a, verb) }
                    values[a] = args[idx]
                    idx += 1
                case _ where spec.bools.contains(a):
                    guard !flags.contains(a) else { throw Scan.twice(a, verb) }
                    flags.insert(a)
                case _ where a.count > 1 && a.hasPrefix("-"):
                    throw UsageError(message: "\(verb) doesn't take \(quoted(a))",
                                     fix: "imessage help \(verb), and put -- before text that starts with -")
                default:
                    words.append(a)
                }
            }
        }

        static func twice(_ flag: String, _ verb: String) -> UsageError {
            UsageError(message: "\(flag) is given twice", fix: "imessage help \(verb)")
        }

        func has(_ flag: String) -> Bool { flags.contains(flag) }

        func noWords() throws {
            guard words.isEmpty else {
                throw UsageError(message: "\(verb) takes no argument, got \(quoted(words[0]))",
                                 fix: "imessage help \(verb)")
            }
        }

        /// Exactly the named slots, each one non-empty after trimming.
        func exactly(_ names: [String]) throws -> [String] {
            try atMost(names)
            guard words.count == names.count else {
                throw UsageError(message: "\(verb) needs \(names[words.count])", fix: "imessage help \(verb)")
            }
            return try words.enumerated().map { try Scan.nonEmpty($0.element, names[$0.offset], verb) }
        }

        func atMost(_ names: [String]) throws {
            guard words.count <= names.count else {
                let what = names.last ?? "argument"
                throw UsageError(message: "too many arguments for \(verb): \(quoted(words[names.count]))",
                                 fix: "quote \(what) if it has spaces, or see imessage help \(verb)")
            }
        }

        /// Every word joined with one space, for `who` and `search`.
        func joined(_ name: String) throws -> String {
            guard !words.isEmpty else {
                throw UsageError(message: "\(verb) needs \(name)", fix: "imessage help \(verb)")
            }
            return try Scan.nonEmpty(words.joined(separator: " "), name, verb)
        }

        static func nonEmpty(_ s: String, _ name: String, _ verb: String) throws -> String {
            guard !TextNorm.matchKey(s).isEmpty else {
                throw UsageError(message: "\(name) is empty", fix: "imessage help \(verb)")
            }
            return s
        }

        func value(_ flag: String) throws -> String? {
            guard let v = values[flag] else { return nil }
            return try Scan.nonEmpty(v, flag, verb)
        }

        func count(_ flag: String, default d: Int, min: Int64) throws -> Int {
            guard let v = values[flag] else { return d }
            return Int(try ArgumentParser.number(v, flag, min: min))
        }

        func rowid(_ flag: String) throws -> Int64? {
            guard let v = values[flag] else { return nil }
            return try ArgumentParser.number(v, flag, min: 1)
        }

        func since(_ flag: String) throws -> String? {
            guard let v = values[flag] else { return nil }
            guard TimeSpec.parse(v, now: Date(timeIntervalSinceReferenceDate: 0), timeZone: .current) != nil else {
                throw UsageError(message: "\(flag) \(quoted(v)) isn't a time",
                                 fix: "use 30m, 12h, 7d, 2w, today, yesterday, 2026-10-01 or 2026-10-01T09:30")
            }
            return v
        }
    }

    // MARK: Building commands

    static func build(_ verb: String, _ s: Scan) throws -> Command {
        switch verb {
        case "chats":
            try s.noWords()
            return .chats(limit: try s.count("-n", default: Limits.defaultChatsLimit, min: 1),
                          unreadOnly: s.has("--unread"))
        case "unread":
            try s.noWords()
            return .unread(context: try s.count("-c", default: Limits.defaultUnreadContext, min: 0))
        case "read":
            let who = try s.exactly(["<who>"])[0]
            let before = try s.rowid("--before"), after = try s.rowid("--after"), around = try s.rowid("--around")
            guard [before, after, around].compactMap({ $0 }).count <= 1 else {
                throw UsageError(message: "use only one of --before, --after and --around", fix: "imessage help read")
            }
            return .read(who: who, limit: try s.count("-n", default: Limits.defaultReadLimit, min: 1),
                         before: before, after: after, around: around, since: try s.since("--since"))
        case "show":
            let rowid = try number(try s.exactly(["<rowid>"])[0], "<rowid>", min: 1)
            return .show(rowid: rowid, fromByte: try s.count("--from", default: 0, min: 0))
        case "search":
            let text = try s.joined("<text>")
            guard text.unicodeScalars.count <= Limits.searchQueryMaxChars else {
                throw UsageError(message: "search text is over \(Limits.searchQueryMaxChars) characters",
                                 fix: "search a shorter phrase")
            }
            let cursor = try s.value("--cursor")
            if let cursor, SearchCursor(text: cursor) == nil {
                throw UsageError(message: "--cursor \(quoted(cursor)) isn't a search cursor",
                                 fix: "pass the cursor from the last search footer")
            }
            return .search(text: text, inWho: try s.value("--in"), since: try s.since("--since"), cursor: cursor,
                           limit: try s.count("-n", default: Limits.defaultSearchLimit, min: 1))
        case "who":
            return .who(name: try s.joined("<name>"))
        case "att":
            return .att(id: try attachmentID(try s.exactly(["<id>"])[0]))
        case "send":
            return try buildSend(s)
        case "react":
            let w = try s.exactly(["<msg>", "<kind>"])
            return .react(rowid: try number(w[0], "<msg>", min: 1), kind: try tapback(w[1]),
                          remove: s.has("--remove"), again: s.has("--again"))
        case "unsend":
            let w = try s.exactly(["<msg>"])
            return .unsend(rowid: try number(w[0], "<msg>", min: 1), again: s.has("--again"))
        case "edit":
            let w = try s.exactly(["<msg>", "<text>"])
            return .edit(rowid: try number(w[0], "<msg>", min: 1), text: s.words[1], again: s.has("--again"))
        case "allow":
            if s.has("--foreground") {
                try whoOrForeground(s)
                guard !s.has("--files") else {
                    throw UsageError(message: "--files only goes with allow <who>", fix: "imessage allow --foreground")
                }
                return .allow(who: nil, files: false, foreground: true)
            }
            let who = try s.exactly(["<who> or --foreground"])[0]
            return .allow(who: who, files: s.has("--files"), foreground: false)
        case "revoke":
            if s.has("--foreground") {
                try whoOrForeground(s)
                return .revoke(who: nil, foreground: true)
            }
            return .revoke(who: try s.exactly(["<who> or --foreground"])[0], foreground: false)
        case "pending":
            try s.atMost(["<id>"])
            return .pending(id: try s.words.first.map { try Scan.nonEmpty($0, "<id>", "pending") })
        case "wait":
            try s.noWords()
            let timeout = try s.count("--timeout", default: Int(Limits.defaultWaitTimeout), min: 1)
            return .wait(fromWho: try s.value("--from"), timeout: TimeInterval(timeout))
        case "changes":
            try s.noWords()
            let since = try s.value("--since")
            if let since, ChangeCursor(text: since) == nil {
                throw UsageError(message: "--since \(quoted(since)) isn't a changes cursor",
                                 fix: "run imessage changes with no --since to get one")
            }
            return .changes(since: since)
        case "caps":
            try s.noWords()
            return .caps
        case "doctor":
            try s.noWords()
            return .doctor(wantUIActions: s.has("--ui"))
        case "setup":
            try s.noWords()
            return .setup
        default:
            try s.atMost(["<verb>"])
            return .help(topic: s.words.first)
        }
    }

    /// `allow` and `revoke` change one chat or foreground mode, never both in one call.
    static func whoOrForeground(_ s: Scan) throws {
        guard s.words.isEmpty else {
            throw UsageError(message: "\(s.verb) takes <who> or --foreground, not both",
                             fix: "run imessage \(s.verb) <who> and imessage \(s.verb) --foreground separately")
        }
    }

    static func buildSend(_ s: Scan) throws -> Command {
        let file = s.values["--file"]
        let thread = s.has("--thread")
        if thread && file != nil { throw UsageError(ActionResult.threadWithFile) }
        try s.atMost(["<who>", "<text>"])
        guard let first = s.words.first else {
            throw UsageError(message: "send needs <who>", fix: "imessage help send")
        }
        let who = try Scan.nonEmpty(first, "<who>", "send")
        if let file, file.isEmpty {
            throw UsageError(message: "--file is empty", fix: "imessage send <who> --file <path>")
        }
        var text: String?
        if s.words.count == 2, !TextNorm.matchKey(s.words[1]).isEmpty { text = s.words[1] }
        guard text != nil || file != nil else {
            throw UsageError(message: "send needs text unless --file is given",
                             fix: "imessage send <who> \"<text>\" or imessage send <who> --file <path>")
        }
        return .send(who: who, text: text, file: file, again: s.has("--again"), thread: thread)
    }

    // MARK: Values

    /// Decimal digits only, at least `min`, within Int64.
    static func number(_ s: String, _ name: String, min: Int64) throws -> Int64 {
        guard !s.isEmpty, s.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), let n = Int64(s), n >= min else {
            throw UsageError(message: "\(name) needs a whole number of at least \(min), got \(quoted(s))",
                             fix: "imessage help")
        }
        return n
    }

    /// `a9904` or `9904`.
    static func attachmentID(_ s: String) throws -> Int64 {
        let digits = s.hasPrefix("a") ? String(s.dropFirst()) : s
        guard let n = try? number(digits, "<id>", min: 1) else {
            throw UsageError(message: "<id> needs an attachment id such as a9904, got \(quoted(s))",
                             fix: "copy the id from a [photo a9904 …] token")
        }
        return n
    }

    /// heart, like, dislike, laugh, emphasize, question, or exactly one emoji.
    static func tapback(_ s: String) throws -> TapbackKind {
        let fail = UsageError(message: "\(quoted(s)) isn't a tapback kind",
                              fix: "use heart, like, dislike, laugh, emphasize, question or one emoji")
        guard let kind = TapbackKind(wireName: s) else { throw fail }
        if case .emoji(let e) = kind, !isSingleEmoji(e) { throw fail }
        return kind
    }

    /// One grapheme that renders as an emoji: its first scalar is an emoji with emoji presentation, or a text-style
    /// emoji followed by a selector or modifier, as in `❤️`.
    static func isSingleEmoji(_ s: String) -> Bool {
        guard s.count == 1, let c = s.first, let first = c.unicodeScalars.first else { return false }
        let props = first.properties
        guard props.isEmoji else { return false }
        return props.isEmojiPresentation || c.unicodeScalars.count > 1
    }

    static func quoted(_ s: String) -> String { "\"" + s + "\"" }
}

/// Process exit codes. 0 for any delivered response that isn't an error line, 1 for `error:` results and failed
/// actions, 2 for usage errors, 3 when the bridge can't be reached.
///
/// An action exits 0 only when its result says it took effect or already held (`submitted`, `delivered`, `ok`,
/// `already`) or is still waiting for approval (`pending <id>`). Every other action result, including `denied`,
/// `busy`, `expired` and `may_have_completed`, exits 1. Exit 3 means the request never reached the bridge, so nothing
/// ran; a response that went missing after the request was sent exits 1.
enum ExitCode: Int32 {
    case ok = 0
    case failure = 1
    case usage = 2
    case bridgeUnavailable = 3
}
