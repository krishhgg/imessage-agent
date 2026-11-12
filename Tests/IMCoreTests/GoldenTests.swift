import XCTest
@testable import IMCore
import IMTestSupport

/// The success output of chats, unread, read, show and who equals bench/renderers/ours.py byte for byte on the
/// fixture. Bytes are compared, not Swift strings, because String equality treats NFC and NFD as equal.
final class GoldenTests: XCTestCase {
    /// ours.py prints 253 lines for this case, past the 200-line cap, so it gets its own cap test.
    static let overCap: Set<String> = ["read-12-n200"]

    func render(_ c: Golden.Case) throws -> String {
        let ctx = Golden.context
        switch c.verb {
        case "chats": return Format.chats(try Golden.record(ChatsPage.self, c.name), ctx)
        case "unread": return Format.unread(try Golden.record(UnreadPage.self, c.name), ctx)
        case "read": return Format.messages(try Golden.record(MessagesPage.self, c.name), ctx)
        case "show": return Format.show(try Golden.record(MessageDetail.self, c.name), ctx)
        case "who": return Format.who(try Golden.record(ContactsPage.self, c.name))
        default:
            XCTFail("unknown verb \(c.verb)")
            return ""
        }
    }

    func testEveryCaseMatchesOursByteForByte() throws {
        let cases = try Golden.cases()
        XCTAssertGreaterThanOrEqual(cases.count, 70)
        XCTAssertEqual(Set(cases.map(\.verb)), ["chats", "unread", "read", "show", "who"])
        var compared = 0
        for c in cases where !GoldenTests.overCap.contains(c.name) {
            let want = try Golden.text(c.name)
            let got = Data(try render(c).utf8)
            compared += 1
            if got != want {
                let w = String(decoding: want, as: UTF8.self).components(separatedBy: "\n")
                let g = String(decoding: got, as: UTF8.self).components(separatedBy: "\n")
                let i = (0..<min(w.count, g.count)).first { Data(w[$0].utf8) != Data(g[$0].utf8) } ?? min(w.count, g.count)
                XCTFail("\(c.command) [\(c.name)] differs at line \(i + 1)\nwant: \(i < w.count ? w[i] : "<end>")\n got: \(i < g.count ? g[i] : "<end>")")
            }
        }
        XCTAssertEqual(compared, cases.count - GoldenTests.overCap.count)
    }

    /// ours.py prints 253 lines for `read 12 -n 200`. Here the cap keeps the newest messages that fit, in ours.py's
    /// exact text, and the footer pages back from the first one kept.
    func testReadOverTheLineCapKeepsTheNewestSuffix() throws {
        let c = try XCTUnwrap(Golden.cases().first { $0.name == "read-12-n200" })
        let ours = String(decoding: try Golden.text(c.name), as: UTF8.self)
        let page = try Golden.record(MessagesPage.self, c.name)
        let got = try render(c)
        let lines = B.lines(got)
        XCTAssertGreaterThan(B.lines(ours).count, Limits.outputMaxLines)
        XCTAssertLessThanOrEqual(lines.count, Limits.outputMaxLines)
        XCTAssertLessThanOrEqual(got.utf8.count, Limits.outputMaxBytes)
        let kept = B.messageLines(got)
        let all = B.messageLines(ours)
        XCTAssertGreaterThan(kept.count, 150)
        XCTAssertEqual(Array(all.suffix(kept.count)).map { Data($0.utf8) }, kept.map { Data($0.utf8) })
        let first = try XCTUnwrap(kept.first?.split(separator: " ").first)
        XCTAssertEqual(lines.last, "more: imessage read 12 --before \(first)")
        XCTAssertTrue(lines[0].hasPrefix("chat 12 "))
        XCTAssertTrue(lines[0].contains(" · \(kept.count) of \(page.totalVisible) · times PST"))
        // Lines are full: one more message and its separator would pass 200.
        XCTAssertGreaterThanOrEqual(lines.count, Limits.outputMaxLines - 1)
    }

    /// Rendering is a pure function of its input, so many threads get the same bytes as one.
    func testGoldenCasesRenderTheSameFromManyThreads() throws {
        let cases = try Golden.cases()
        let serial = try cases.map { Data(try render($0).utf8) }
        let rounds = 4
        let out = Results(count: cases.count * rounds)
        DispatchQueue.concurrentPerform(iterations: cases.count * rounds) { i in
            let text = (try? self.render(cases[i % cases.count])) ?? "render failed"
            out.set(i, text)
        }
        for i in 0..<(cases.count * rounds) {
            XCTAssertEqual(out.get(i).map { Data($0.utf8) }, serial[i % cases.count], cases[i % cases.count].name)
        }
    }
}
