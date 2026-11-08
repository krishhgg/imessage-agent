import XCTest

/// Rule (docs/BUILD-PLAN.md): IMCore has no AppKit and no SQLite, and the CLI imports IMCore only and never links
/// SQLite, AppKit or ApplicationServices. Swift autolinks every module IMCore imports into the CLI, so IMCore may
/// import Foundation and CryptoKit and nothing else. These checks read IMCore's sources and Package.swift.
final class IMCoreSourceGuardTests: XCTestCase {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let allowed: Set<String> = ["import Foundation", "import CryptoKit"]
    static let modifiers: Set<String> = ["public", "package", "internal", "fileprivate", "private", "open"]

    /// Every import declaration in `text`, trimmed, whatever attributes (`@preconcurrency`, `@_implementationOnly`,
    /// `@testable`, `@_exported`) or access level come before `import`, and with `;` splitting one line.
    static func imports(_ text: String) -> [String] {
        var found: [String] = []
        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") { continue }
            for piece in trimmed.split(separator: ";") {
                let stmt = piece.trimmingCharacters(in: .whitespaces)
                var words = stmt.split(whereSeparator: { $0 == " " || $0 == "\t" })[...]
                while let w = words.first, w.hasPrefix("@") || modifiers.contains(String(w)) { words = words.dropFirst() }
                if words.first == "import" { found.append(stmt) }
            }
        }
        return found
    }

    func testTheImportScannerCatchesEveryForm() {
        let text = """
            @preconcurrency import AppKit
            @_implementationOnly import SQLite3
            @testable import IMStore
            public import ApplicationServices
            @_exported import CoreGraphics
            import struct Foundation.Date
            import Foundation; import Security
              import CryptoKit
            /// import AppKit is only a comment here
            let important = 1
            """
        let found = IMCoreSourceGuardTests.imports(text)
        XCTAssertEqual(found, ["@preconcurrency import AppKit", "@_implementationOnly import SQLite3", "@testable import IMStore",
                               "public import ApplicationServices", "@_exported import CoreGraphics",
                               "import struct Foundation.Date", "import Foundation", "import Security", "import CryptoKit"])
        XCTAssertEqual(found.filter { IMCoreSourceGuardTests.allowed.contains($0) }, ["import Foundation", "import CryptoKit"])
    }

    func testIMCoreImportsFoundationAndCryptoKitOnly() throws {
        let dir = IMCoreSourceGuardTests.root.appendingPathComponent("Sources/IMCore", isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { !$0.hasPrefix(".") }.sorted()
        XCTAssertTrue(names.contains("Format.swift"), "\(dir.path) holds IMCore")
        for name in names {
            XCTAssertTrue(name.hasSuffix(".swift"), "IMCore holds Swift sources only: \(name)")
            let text = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
            for line in IMCoreSourceGuardTests.imports(text) {
                XCTAssertTrue(IMCoreSourceGuardTests.allowed.contains(line), "\(name): \(line)")
            }
        }
    }

    /// The text of the `.target(` or `.executableTarget(` call that declares `name`, through its closing parenthesis.
    static func declaration(of name: String, in manifest: String) -> String? {
        for kind in [".target(", ".executableTarget("] {
            var from = manifest.startIndex
            while let r = manifest.range(of: kind, range: from..<manifest.endIndex) {
                var depth = 0
                var i = manifest.index(before: r.upperBound)
                var end: String.Index?
                while i < manifest.endIndex {
                    if manifest[i] == "(" { depth += 1 }
                    if manifest[i] == ")" {
                        depth -= 1
                        if depth == 0 {
                            end = i
                            break
                        }
                    }
                    i = manifest.index(after: i)
                }
                guard let end else { return nil }
                let decl = String(manifest[r.lowerBound...end])
                let args = decl.dropFirst(kind.count).trimmingCharacters(in: .whitespacesAndNewlines)
                if args.hasPrefix("name: \"\(name)\"") { return decl }
                from = r.upperBound
            }
        }
        return nil
    }

    func testPackageLinksNothingIntoIMCoreOrTheCLI() throws {
        let manifest = try String(contentsOf: IMCoreSourceGuardTests.root.appendingPathComponent("Package.swift"),
                                  encoding: .utf8)
        let core = try XCTUnwrap(IMCoreSourceGuardTests.declaration(of: "IMCore", in: manifest))
        let cli = try XCTUnwrap(IMCoreSourceGuardTests.declaration(of: "imessage", in: manifest))
        XCTAssertTrue(cli.hasPrefix(".executableTarget("))
        for (name, decl) in [("IMCore", core), ("imessage", cli)] {
            for word in ["linkerSettings", "linkedLibrary", "linkedFramework", "unsafeFlags"] {
                XCTAssertFalse(decl.contains(word), "\(name) target has \(word)")
            }
        }
        XCTAssertFalse(core.contains("dependencies"), "IMCore sits at the root of the module graph")
        let deps = try XCTUnwrap(cli.range(of: #"dependencies:\s*\[([^\]]*)\]"#, options: .regularExpression))
        let list = cli[deps].drop { $0 != "[" }.dropFirst().dropLast()
        XCTAssertEqual(list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }, ["\"IMCore\""])
        // The scanner finds the other targets too, so a miss above isn't a parsing gap.
        XCTAssertEqual(IMCoreSourceGuardTests.declaration(of: "IMStore", in: manifest)?.contains("linkedLibrary(\"sqlite3\")"), true)
        XCTAssertNil(IMCoreSourceGuardTests.declaration(of: "IMCor", in: manifest))
    }
}
