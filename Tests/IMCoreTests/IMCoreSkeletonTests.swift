import XCTest
import IMCore
import IMTestSupport

final class IMCoreSkeletonTests: XCTestCase {
    func testIdentityAndSocketPath() {
        XCTAssertEqual(AppIdentity.bundleID, "io.github.krishhgg.imessage-agent")
        XCTAssertEqual(AppIdentity.launchAgentLabel, AppIdentity.bundleID)
        let paths = Paths(home: URL(fileURLWithPath: "/Users/someone", isDirectory: true))
        XCTAssertTrue(Paths.socketPathFits(paths.primarySocketPath))
    }

    func testFrameRoundTrip() throws {
        let request = Request(id: "t1", body: .ping)
        let frame = try FrameCodec.encode(request)
        let length = try FrameCodec.bodyLength(header: frame.prefix(FrameCodec.headerBytes))
        XCTAssertEqual(length, frame.count - FrameCodec.headerBytes)
        let decoded = try FrameCodec.decode(Request.self, body: frame.dropFirst(FrameCodec.headerBytes))
        XCTAssertEqual(decoded, request)
    }

    func testTextDigestIsDigestOfMatchKey() {
        // NFD input with surrounding whitespace digests the same as the trimmed NFC form.
        XCTAssertEqual(TextNorm.textDigest(" cafe\u{301}\n"), TextNorm.textDigest("café"))
        XCTAssertEqual(TextNorm.textDigest("café"), TextNorm.digest(TextNorm.matchKey("café")))
        XCTAssertNotEqual(TextNorm.textDigest(" café"), TextNorm.digest(" café"))
    }

    func testFakeMessagesAppStateFollowsClock() {
        let clock = FakeClock()
        let start = clock.uptime
        let app = FakeMessagesApp(current: MessagesAppState(isRunning: true, pid: 1, isFrontmost: false,
                                                            isHidden: false, axWindowCount: 1,
                                                            onScreenWindowCount: 1, allSpacesWindowCount: 1))
        app.onState = { state in
            if clock.uptime - start >= 0.4 { state.isHidden = true }
        }
        XCTAssertFalse(app.state().isHidden)
        clock.sleep(0.5)
        XCTAssertTrue(app.state().isHidden)

        app.onFrontmost = { front in
            if clock.uptime - start >= 1 { front = FrontApp(bundleID: "com.apple.MobileSMS", name: "Messages", pid: 1,
                                                            hasWindows: true) }
        }
        XCTAssertNil(app.frontmostApp())
        clock.sleep(0.5)
        XCTAssertEqual(app.frontmostApp()?.name, "Messages")
    }

    func testGoldenDirSitsInFixtures() {
        XCTAssertEqual(Fixture.goldenDir.deletingLastPathComponent().standardizedFileURL,
                       Fixture.root.standardizedFileURL)
    }
}
