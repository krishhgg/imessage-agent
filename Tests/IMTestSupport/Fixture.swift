import Foundation
import IMCore

/// The synthetic fixture under Tests/Fixtures (see Tests/Fixtures/README.md and manifest.json).
/// Tests never open the real ~/Library/Messages/chat.db.
public enum Fixture {
    public static let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)

    public static var chatDB: URL { root.appendingPathComponent("chat.db") }
    public static var contactsJSON: URL { root.appendingPathComponent("contacts.json") }
    public static var contactsFirstNameJSON: URL { root.appendingPathComponent("contacts-firstname.json") }
    /// contacts.json plus Juan Perez, saved as `55 1234 5678` with no country code (region tests).
    public static var contactsLocalNumberJSON: URL { root.appendingPathComponent("contacts-local-number.json") }
    public static var manifest: URL { root.appendingPathComponent("manifest.json") }
    /// Stands in for `~/Library/Messages/Attachments/`; `attachment.filename` values map onto it.
    public static var attachmentsRoot: URL { root.appendingPathComponent("Attachments", isDirectory: true) }
    /// Golden text captured from bench/renderers/ours.py and the record JSON Format tests decode, with the capture
    /// command recorded next to them. It sits outside every target folder, so SwiftPM needs no resources entry and
    /// Package.swift doesn't change when a golden file is added. Owner: IMCore.
    public static var goldenDir: URL { root.appendingPathComponent("golden", isDirectory: true) }

    /// "Now" for every fixture test, Apple-epoch nanoseconds (manifest.json `fixture_now_ns`).
    public static let nowNs: AppleNanos = 815_646_600_000_000_000
    public static var now: Date { AppleTime.date(fromNanos: nowNs) }
    public static let timeZone = TimeZone(identifier: "America/Los_Angeles")!

    /// The owner's handles in contacts.json.
    public static let ownerHandles = ["+14155550100", "alex@example.com"]
}
