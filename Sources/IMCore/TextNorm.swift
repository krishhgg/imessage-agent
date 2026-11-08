import CryptoKit
import Foundation

/// Apple epoch helpers. chat.db `message.date` is nanoseconds since 2001-01-01 UTC; `attachment.created_date` is seconds.
public enum AppleTime {
    public static let epochOffset: TimeInterval = 978_307_200

    public static func date(fromNanos ns: Int64) -> Date {
        Date(timeIntervalSince1970: Double(ns) / 1e9 + epochOffset)
    }

    public static func nanos(from date: Date) -> Int64 {
        Int64(((date.timeIntervalSince1970 - epochOffset) * 1e9).rounded())
    }
}

/// Text normalization shared by correlation (section 3 item 5), targeting (section 4) and search (section 1).
public enum TextNorm {
    /// NFC normalization plus whitespace trimming. Sections 3 item 5 and 4 step 7 compare bodies this way.
    public static func matchKey(_ s: String) -> String {
        s.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Folds line breaks to ` / ` for one-line output, exactly like bench/renderers/ours.py `one_line`:
    /// `re.sub(r"\s*\n+\s*", " / ", text.strip())`. It strips Python whitespace from both ends, then replaces
    /// every run of whitespace that holds at least one `\n` with ` / `. Runs without `\n` stay as they are.
    public static func oneLine(_ s: String) -> String {
        fold(s, strip: true) { $0 == "\n" }
    }

    /// `oneLine`, but every line break counts, not only `\n`: CR, VT, FF, U+0085, U+2028 and U+2029 too.
    /// Text with only `\n` breaks gives the same result as `oneLine`. Result and error lines use it so they stay
    /// on one line whatever a message or a name holds.
    public static func singleLine(_ s: String) -> String {
        fold(s, strip: true, isBreak: isLineBreak)
    }

    /// The scalars a terminal or a line reader treats as ending a line.
    public static func isLineBreak(_ c: Unicode.Scalar) -> Bool {
        switch c.value {
        case 0x0A...0x0D, 0x85, 0x2028, 0x2029: return true
        default: return false
        }
    }

    /// Replaces every run of Python whitespace that holds a break with ` / `, after an optional `strip()`.
    static func fold(_ s: String, strip: Bool, isBreak: (Unicode.Scalar) -> Bool) -> String {
        let all = Array(s.unicodeScalars)
        let scalars = strip ? pyStrip(all) : all[...]
        var out = String.UnicodeScalarView()
        var i = scalars.startIndex
        while i < scalars.endIndex {
            guard isPythonWhitespace(scalars[i]) else {
                out.append(scalars[i])
                i += 1
                continue
            }
            var j = i
            var hasBreak = false
            while j < scalars.endIndex, isPythonWhitespace(scalars[j]) {
                if isBreak(scalars[j]) { hasBreak = true }
                j += 1
            }
            if hasBreak {
                out.append(contentsOf: " / ".unicodeScalars)
            } else {
                out.append(contentsOf: scalars[i..<j])
            }
            i = j
        }
        return String(out)
    }

    /// Python's `str.strip()` with no arguments: drops `isPythonWhitespace` scalars from both ends.
    public static func pyStrip(_ s: String) -> String {
        String(String.UnicodeScalarView(pyStrip(Array(s.unicodeScalars))))
    }

    /// The characters Python's `str.isspace()` and the `\s` regex class accept, so the renderer folds and strips
    /// text the same way bench/renderers/ours.py does.
    public static func isPythonWhitespace(_ c: Unicode.Scalar) -> Bool {
        switch c.value {
        case 0x09...0x0D, 0x1C...0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
            return true
        default:
            return false
        }
    }

    private static func pyStrip(_ a: [Unicode.Scalar]) -> ArraySlice<Unicode.Scalar> {
        var lo = 0
        var hi = a.count
        while lo < hi, isPythonWhitespace(a[lo]) { lo += 1 }
        while hi > lo, isPythonWhitespace(a[hi - 1]) { hi -= 1 }
        return a[lo..<hi]
    }

    /// Lowercase hex SHA-256. Digests bind approvals and idempotency keys (sections 2 and 3 item 1).
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// SHA-256 of the NFC form of `s`, UTF-8 encoded.
    public static func digest(_ s: String) -> String {
        sha256Hex(Data(s.precomposedStringWithCanonicalMapping.utf8))
    }

    /// `digest(matchKey(s))`. Every text digest the bridge stores or binds uses this form: approval bindings,
    /// idempotency keys, the journal, `SendEvent.textDigest` and `InboundRow.bodyDigest`. A decoded row body
    /// (`SentRowProbe.body`, `EditStateProbe.body`, already `matchKey`) compares equal to a sent text exactly when
    /// their `textDigest` values are equal, so crash reconciliation works from the digest alone.
    public static func textDigest(_ s: String) -> String {
        digest(matchKey(s))
    }
}
