import XCTest
import IMCore

/// Text normalization and the Python parity rules Format depends on. Expected values come from CPython 3.
final class TextNormTests: XCTestCase {
    func testAppleEpoch() {
        XCTAssertEqual(AppleTime.epochOffset, 978_307_200)
        XCTAssertEqual(AppleTime.date(fromNanos: 0).timeIntervalSince1970, 978_307_200)
        XCTAssertEqual(AppleTime.nanos(from: Date(timeIntervalSince1970: 978_307_201.5)), 1_500_000_000)
        XCTAssertEqual(AppleTime.nanos(from: AppleTime.date(fromNanos: 815_646_600_000_000_000)), 815_646_600_000_000_000)
    }

    func testDigestVectors() {
        XCTAssertEqual(TextNorm.sha256Hex(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        let cafe = "850f7dc43910ff890f8879c0ed26fe697c93a067ad93a7d50f466a7028a9bf4e"
        XCTAssertEqual(TextNorm.digest("café"), cafe)
        XCTAssertEqual(TextNorm.digest("cafe\u{301}"), cafe, "NFD must digest like NFC")
        XCTAssertEqual(TextNorm.textDigest("  cafe\u{301}\n"), cafe)
        XCTAssertNotEqual(TextNorm.digest(" café"), cafe)
    }

    func testMatchKey() {
        XCTAssertEqual(TextNorm.matchKey("\n cafe\u{301} \t"), "café")
        XCTAssertEqual(Array(TextNorm.matchKey("cafe\u{301}").unicodeScalars).count, 4)
        XCTAssertEqual(TextNorm.matchKey("a\nb"), "a\nb")
    }

    /// `re.sub(r"\s*\n+\s*", " / ", text.strip())` in CPython.
    func testOneLineMatchesPython() {
        let cases: [(String, String)] = [
            ("  a \n\n b  ", "a / b"), ("a\tb", "a\tb"), ("a \u{2028} b", "a \u{2028} b"), ("\u{A0}x\u{A0}", "x"),
            ("a\r\nb", "a / b"), ("a\rb", "a\rb"), ("x\n", "x"), ("a \u{3000}\n\u{3000} b", "a / b"),
            ("\u{1C} a \n b", "a / b"), ("", ""), ("\n\n", ""), ("a\u{85}b", "a\u{85}b"), ("\u{200B}a", "\u{200B}a"),
            ("a\nb\nc", "a / b / c"), ("a \n b \t c", "a / b \t c"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(Array(TextNorm.oneLine(input).unicodeScalars), Array(expected.unicodeScalars), input.debugDescription)
        }
    }

    func testSingleLineFoldsEveryBreak() {
        let cases: [(String, String)] = [
            ("a \u{2028} b", "a / b"), ("a\rb", "a / b"), ("a\u{85}b", "a / b"), ("a\u{0B}b", "a / b"),
            ("a\u{0C}b", "a / b"), ("a\u{2029}b", "a / b"), ("  a \n\n b  ", "a / b"), ("a\tb", "a\tb"),
            ("\r\n", ""),
        ]
        for (input, expected) in cases {
            let out = TextNorm.singleLine(input)
            XCTAssertEqual(Array(out.unicodeScalars), Array(expected.unicodeScalars), input.debugDescription)
            XCTAssertFalse(out.unicodeScalars.contains(where: TextNorm.isLineBreak))
        }
    }

    /// Python's `str.isspace` set, checked against CPython over the whole BMP.
    func testPythonWhitespaceSet() {
        var expected = Set<UInt32>([0x20, 0x85, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000])
        expected.formUnion(0x09...0x0D)
        expected.formUnion(0x1C...0x1F)
        expected.formUnion(0x2000...0x200A)
        var found = Set<UInt32>()
        for v in UInt32(0)...0xFFFF {
            if let s = Unicode.Scalar(v), TextNorm.isPythonWhitespace(s) { found.insert(v) }
        }
        XCTAssertEqual(found, expected)
        XCTAssertEqual(TextNorm.pyStrip("\u{1F}\u{205F} x y \u{3000}"), "x y")
        XCTAssertEqual(TextNorm.pyStrip("\u{FEFF}x"), "\u{FEFF}x")
    }

    func testLineBreakSet() {
        let breaks: [UInt32] = [0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029]
        for v in UInt32(0)...0x3000 {
            guard let s = Unicode.Scalar(v) else { continue }
            XCTAssertEqual(TextNorm.isLineBreak(s), breaks.contains(v), String(v, radix: 16))
        }
    }
}
