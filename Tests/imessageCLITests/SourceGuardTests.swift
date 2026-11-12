import XCTest

/// Rule: the CLI is unprivileged. It imports IMCore only, reaches the bridge only through the socket, and never
/// touches Messages, its database, Apple Events, events or TCC itself. These checks read the CLI's own sources.
final class SourceGuardTests: XCTestCase {
    static let sourceDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/imessage", isDirectory: true)

    func sources() throws -> [(String, String)] {
        let names = try FileManager.default.contentsOfDirectory(atPath: SourceGuardTests.sourceDir.path)
            .filter { $0.hasSuffix(".swift") }.sorted()
        XCTAssertEqual(names, ["BridgeClient.swift", "Command.swift", "Flows.swift", "main.swift"])
        return try names.map { ($0, try String(contentsOf: SourceGuardTests.sourceDir.appendingPathComponent($0),
                                               encoding: .utf8)) }
    }

    func testImportsAreFoundationAndIMCoreOnly() throws {
        for (name, text) in try sources() {
            let imports = text.split(separator: "\n").filter { $0.hasPrefix("import ") || $0.contains(" import ") }
            for line in imports {
                XCTAssertTrue(["import Foundation", "import IMCore"].contains(String(line)), "\(name): \(line)")
            }
        }
    }

    func testNoPrivilegedAPIsOrTools() throws {
        let banned = ["osascript", "NSAppleScript", "NSAppleEventDescriptor", "NSWorkspace", "lsregister", "tccutil",
                      "CGEvent", "AXUIElement", "SQLite3", "sqlite3_", "Library/Messages", "chat.db", "TCC.db",
                      "/usr/bin/open", "bridge.sock", "fatalError"]
        for (name, text) in try sources() {
            for word in banned { XCTAssertFalse(text.contains(word), "\(name) mentions \(word)") }
        }
    }

    /// The only child process is `launchctl kickstart`, from `liveKickstart`.
    func testTheOnlyProcessIsTheKickstart() throws {
        let all = try sources().map(\.1).joined(separator: "\n")
        XCTAssertEqual(all.components(separatedBy: "Process()").count - 1, 1)
        XCTAssertEqual(all.components(separatedBy: "executableURL").count - 1, 1)
        XCTAssertTrue(all.contains("URL(fileURLWithPath: launchctlPath)"))
    }

    func testCommentsHaveNoEmDashes() throws {
        for (name, text) in try sources() { XCTAssertFalse(text.contains("\u{2014}"), name) }
    }
}
