import Foundation
import IMCore

/// Reads the golden cases captured from bench/renderers/ours.py (see `Tests/Fixtures/golden/README.md`).
public enum Golden {
    /// One entry of `cases.json`.
    public struct Case: Decodable, Hashable {
        /// File stem: `<case>.txt` holds the text, `<case>.json` the record.
        public let name: String
        /// The CLI command the case renders, for failure messages.
        public let command: String
        /// `chats`, `unread`, `read`, `show` or `who`.
        public let verb: String

        enum CodingKeys: String, CodingKey {
            case name = "case", command, verb
        }
    }

    public static func cases() throws -> [Case] {
        try JSONDecoder().decode([Case].self, from: Data(contentsOf: Fixture.goldenDir.appendingPathComponent("cases.json")))
    }

    /// The exact bytes ours.py printed.
    public static func text(_ name: String) throws -> Data {
        try Data(contentsOf: Fixture.goldenDir.appendingPathComponent(name + ".txt"))
    }

    /// What the CLI prints for the case: the ours.py bytes, plus the footer for newer messages that ours.py lacks.
    /// DESIGN.md section 5 gives every list a footer for the next page, so a `read --after` or `read --around` page
    /// whose chat has a visible row past its last one ends with `more: imessage read <chat> --after <rowid>` as well
    /// (docs/BUILD-PLAN.md, IMCore checklist). `hasNewer(chat, rowid)` asks the store whether such a row exists.
    public static func expectedText(_ c: Case, hasNewer: (Int64, Int64) throws -> Bool) throws -> Data {
        let printed = try text(c.name)
        guard c.verb == "read", c.command.contains(" --after ") || c.command.contains(" --around ") else { return printed }
        let page = try record(MessagesPage.self, c.name)
        guard let last = page.messages.last, try hasNewer(page.chat.rowid, last.rowid) else { return printed }
        return printed + Data("more: imessage read \(page.chat.rowid) --after \(last.rowid)\n".utf8)
    }

    /// The page record for the case, decoded with the wire decoder.
    public static func record<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try JSONDecoder.wire.decode(type, from: Data(contentsOf: Fixture.goldenDir.appendingPathComponent(name + ".json")))
    }

    /// The renderer context every golden case uses: fixture now, America/Los_Angeles.
    public static var context: FormatContext { FormatContext(now: Fixture.now, timeZone: Fixture.timeZone) }
}
