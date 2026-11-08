import XCTest
import IMCore

/// Section 1: the socket path is 104 bytes or less with its NUL, with `~/.imessage-agent/bridge.sock` as fallback.
final class PathsTests: XCTestCase {
    static let primarySuffix = "/Library/Application Support/iMessage Agent/bridge.sock"
    static let fallbackSuffix = "/.imessage-agent/bridge.sock"

    func paths(_ home: String) -> Paths { Paths(home: URL(fileURLWithPath: home, isDirectory: true)) }

    /// A home whose primary socket path is exactly `bytes` UTF-8 bytes long.
    func home(primaryBytes bytes: Int, filler: String = "a") -> String {
        let base = "/Users/"
        let room = bytes - Self.primarySuffix.utf8.count - base.utf8.count
        let unit = filler.utf8.count
        return base + String(repeating: filler, count: room / unit) + String(repeating: "a", count: room % unit)
    }

    func testSocketPathFitsCountsTheNul() {
        XCTAssertEqual(Paths.maxSocketPathBytes, 104)
        XCTAssertTrue(Paths.socketPathFits("/" + String(repeating: "a", count: 102)))
        XCTAssertFalse(Paths.socketPathFits("/" + String(repeating: "a", count: 103)))
    }

    func testPrimaryOf103BytesIsUsed() throws {
        let p = paths(home(primaryBytes: 103))
        XCTAssertEqual(p.primarySocketPath.utf8.count, 103)
        XCTAssertEqual(try p.resolvedSocketPath(), p.primarySocketPath)
        XCTAssertTrue(p.primarySocketPath.hasSuffix(Self.primarySuffix))
    }

    func testPrimaryOf104BytesFallsBack() throws {
        let p = paths(home(primaryBytes: 104))
        XCTAssertEqual(p.primarySocketPath.utf8.count, 104)
        XCTAssertEqual(try p.resolvedSocketPath(), p.fallbackSocketPath)
        XCTAssertTrue(p.fallbackSocketPath.hasSuffix(Self.fallbackSuffix))
        XCTAssertTrue(p.fallbackSocketPath.hasPrefix(p.home.path))
    }

    func testMultibyteHomeIsMeasuredInBytes() throws {
        // "日" is 3 UTF-8 bytes and has no decomposition, so the path keeps its byte count.
        let fits = paths(home(primaryBytes: 103, filler: "日"))
        XCTAssertLessThan(fits.primarySocketPath.count, 90)
        XCTAssertEqual(fits.primarySocketPath.utf8.count, 103)
        XCTAssertEqual(try fits.resolvedSocketPath(), fits.primarySocketPath)

        let long = paths(home(primaryBytes: 104, filler: "日"))
        XCTAssertEqual(long.primarySocketPath.utf8.count, 104)
        XCTAssertEqual(try long.resolvedSocketPath(), long.fallbackSocketPath)
    }

    func testThrowsWhenNeitherPathFits() throws {
        let base = "/Users/"
        let room = 104 - Self.fallbackSuffix.utf8.count - base.utf8.count
        let justFits = paths(base + String(repeating: "b", count: room - 1))
        XCTAssertEqual(justFits.fallbackSocketPath.utf8.count, 103)
        XCTAssertEqual(try justFits.resolvedSocketPath(), justFits.fallbackSocketPath)

        let tooLong = paths(base + String(repeating: "b", count: room))
        XCTAssertEqual(tooLong.fallbackSocketPath.utf8.count, 104)
        XCTAssertThrowsError(try tooLong.resolvedSocketPath()) { error in
            XCTAssertEqual(error as? Paths.PathError, .socketPathTooLong(tooLong.primarySocketPath))
        }
    }

    /// The LaunchAgent plist and the CLI both call `resolvedSocketPath()`, so the result depends on the home only.
    func testResolvedPathDependsOnlyOnHome() throws {
        for bytes in [70, 103, 104, 120] {
            let h = home(primaryBytes: bytes)
            XCTAssertEqual(try paths(h).resolvedSocketPath(), try paths(h).resolvedSocketPath())
        }
        XCTAssertEqual(try paths("/Users/someone").resolvedSocketPath(),
                       "/Users/someone/Library/Application Support/iMessage Agent/bridge.sock")
    }
}
