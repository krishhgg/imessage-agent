import Foundation
import IMCore

/// One attribute run of a decoded attributedBody, in UTF-16 offsets.
public struct AttributeRun: Hashable, Sendable {
    public var utf16Start: Int
    public var utf16Length: Int
    /// Attribute dictionary with NSString, NSNumber, NSDictionary and NSArray values turned into Swift values.
    /// Keys Messages uses: `__kIMMessagePartAttributeName`, `__kIMFileTransferGUIDAttributeName`,
    /// `__kIMLinkAttributeName`, `__kIMInlineMediaWidthAttributeName`, `__kIMInlineMediaHeightAttributeName`.
    public var attributes: [String: TypedValue]

    public init(utf16Start: Int, utf16Length: Int, attributes: [String: TypedValue]) {
        self.utf16Start = utf16Start
        self.utf16Length = utf16Length
        self.attributes = attributes
    }
}

/// Plain values pulled out of a typedstream.
public enum TypedValue: Hashable, Sendable {
    case string(String)
    case int(Int64)
    case double(Double)
    case data(Data)
    case array([TypedValue])
    case dictionary([String: TypedValue])
    case null

    /// The value as an integer, for numeric attributes stored as int or double.
    var integerValue: Int64? {
        switch self {
        case .int(let v): return v
        case .double(let d) where d.isFinite && abs(d) < 9e18: return Int64(d)
        default: return nil
        }
    }
}

public struct DecodedBody: Hashable, Sendable {
    /// Full string, including U+FFFC attachment placeholders.
    public var text: String
    public var runs: [AttributeRun]

    public init(text: String, runs: [AttributeRun]) {
        self.text = text
        self.runs = runs
    }

    /// Text without U+FFFC, as records carry it.
    public var displayText: String { text.replacingOccurrences(of: "\u{FFFC}", with: "") }
}

/// NSArchiver typedstream reader for `attributedBody` and the `ec` edit history (section 1: "The bridge decodes
/// attributedBody"). Port of bench/typedstream.py. Owner: IMStore.
/// Must decode all 1,526 fixture bodies and reproduce manifest.json `bodies.sha256`.
public enum TypedStreamDecoder {
    public enum DecodeError: Error, Equatable {
        case notTypedStream
        case truncated
        case unsupportedType(Character)
        case badReference
        /// Nesting or work went past the reader's limits, which no Messages body comes near.
        case limitExceeded
    }

    /// Decodes an archived NSAttributedString or NSMutableAttributedString.
    public static func decodeAttributedString(_ data: Data) throws -> DecodedBody {
        let reader = try TypedStreamReader(Array(data))
        guard case .object(let root) = try reader.readRoot() else { return DecodedBody(text: "", runs: []) }
        var text: String?
        var runs: [AttributeRun] = []
        var position = 0
        let f = root.fields
        // One work budget for every attribute run: a run can reference its own object, and walking that by value
        // would otherwise branch on every level down to the depth cap.
        var budget = reader.maxSteps
        var k = 0
        while k < f.count {
            if text == nil, case .object(let obj) = f[k] {
                text = nsString(obj)
                k += 1
                continue
            }
            if text != nil, case .int = f[k], k + 2 < f.count, case .int(let length) = f[k + 1] {
                let attrs: [String: TypedValue]
                if case .dictionary(let d) = try plain(f[k + 2], budget: &budget) { attrs = d } else { attrs = [:] }
                let len = Int(clamping: length)
                runs.append(AttributeRun(utf16Start: position, utf16Length: len, attributes: attrs))
                position = position &+ len
                k += 3
                continue
            }
            k += 1
        }
        return DecodedBody(text: text ?? "", runs: runs)
    }

    /// `_ns_string`: the first byte-string field of an object, decoded as UTF-8.
    static func nsString(_ obj: TSObject) -> String? {
        for field in obj.fields {
            if case .bytes(let b) = field { return String(decoding: b, as: UTF8.self) }
        }
        return nil
    }

    /// `_plain`: NSString, NSNumber, NSDictionary and NSArray objects to plain values. Each value visited takes
    /// one from `budget`; past zero it throws `limitExceeded`.
    static func plain(_ v: TSValue, depth: Int = 0, budget: inout Int) throws -> TypedValue {
        budget -= 1
        if budget < 0 { throw DecodeError.limitExceeded }
        if depth > 64 { return .null }
        switch v {
        case .object(let obj):
            let name = obj.cls?.name ?? ""
            if name.contains("String") && !name.contains("Attributed") {
                return nsString(obj).map(TypedValue.string) ?? .null
            }
            if name == "NSNumber" || name == "NSValue" {
                guard obj.fields.count > 1 else { return .null }
                switch obj.fields[1] {
                case .int(let i): return .int(i)
                case .double(let d): return .double(d)
                case .bytes(let b): return .data(Data(b))
                default: return try plain(obj.fields[1], depth: depth + 1, budget: &budget)
                }
            }
            if name.contains("Dictionary") {
                guard case .int(let n)? = obj.fields.first, n > 0 else { return .dictionary([:]) }
                var out: [String: TypedValue] = [:]
                var i = 0
                while i < Int(clamping: n), 2 + 2 * i < obj.fields.count {
                    if case .string(let key) = try plain(obj.fields[1 + 2 * i], depth: depth + 1, budget: &budget) {
                        out[key] = try plain(obj.fields[2 + 2 * i], depth: depth + 1, budget: &budget)
                    }
                    i += 1
                }
                return .dictionary(out)
            }
            if name.contains("Array") {
                var items: [TypedValue] = []
                for field in obj.fields.dropFirst() { items.append(try plain(field, depth: depth + 1, budget: &budget)) }
                return .array(items)
            }
            return .null
        case .bytes(let b):
            return .string(String(decoding: b, as: UTF8.self))
        case .int(let i):
            return .int(i)
        case .double(let d):
            return .double(d)
        case .list(let items):
            var out: [TypedValue] = []
            for item in items { out.append(try plain(item, depth: depth + 1, budget: &budget)) }
            return .array(out)
        case .null, .cls:
            return .null
        }
    }
}

final class TSObject {
    var cls: TSClass?
    var fields: [TSValue] = []
}

final class TSClass {
    let name: String
    let version: Int64
    var superclass: TSClass?

    init(name: String, version: Int64) {
        self.name = name
        self.version = version
    }
}

/// Raw typedstream values, before `plain` maps them.
enum TSValue {
    case int(Int64)
    case double(Double)
    case bytes([UInt8])
    case null
    case object(TSObject)
    case cls(TSClass)
    case list([TSValue])
}

/// The reader itself. Every read is bounds-checked; nesting depth and total work are capped so a hostile blob
/// fails with an error instead of exhausting the stack or the budget.
final class TypedStreamReader {
    private typealias DecodeError = TypedStreamDecoder.DecodeError

    private static let tagInt16: UInt8 = 0x81
    private static let tagInt32: UInt8 = 0x82
    private static let tagFloat: UInt8 = 0x83
    private static let tagNew: UInt8 = 0x84
    private static let tagNil: UInt8 = 0x85
    private static let tagEnd: UInt8 = 0x86
    private static let refBase: Int64 = -110
    static let maxDepth = 64

    private let b: [UInt8]
    private var p = 0
    private var strings: [[UInt8]] = []
    private var objects: [TSValue] = []
    private var depth = 0
    private var steps = 0
    /// Most values one blob may produce. `TypedStreamDecoder.plain` gets the same budget.
    let maxSteps: Int

    init(_ bytes: [UInt8]) throws {
        b = bytes
        maxSteps = max(4_096, bytes.count * 8)
        _ = try byte() // version
        let n = Int(try byte())
        guard try take(n) == Array("streamtyped".utf8) else { throw DecodeError.notTypedStream }
        _ = try readInt() // system version
    }

    private func byte() throws -> UInt8 {
        guard p < b.count else { throw DecodeError.truncated }
        defer { p += 1 }
        return b[p]
    }

    private func peek() throws -> UInt8 {
        guard p < b.count else { throw DecodeError.truncated }
        return b[p]
    }

    private func take(_ n: Int) throws -> [UInt8] {
        guard n >= 0, n <= b.count - p else { throw DecodeError.truncated }
        defer { p += n }
        return Array(b[p..<(p + n)])
    }

    private func intFrom(_ head: UInt8) throws -> Int64 {
        switch head {
        case TypedStreamReader.tagInt16:
            let v = try take(2)
            return Int64(Int16(bitPattern: UInt16(v[0]) | UInt16(v[1]) << 8))
        case TypedStreamReader.tagInt32:
            let v = try take(4)
            let u = UInt32(v[0]) | UInt32(v[1]) << 8 | UInt32(v[2]) << 16 | UInt32(v[3]) << 24
            return Int64(Int32(bitPattern: u))
        default:
            return Int64(Int8(bitPattern: head))
        }
    }

    func readInt() throws -> Int64 { try intFrom(try byte()) }

    private func refIndex(_ head: UInt8) throws -> Int {
        let i = try intFrom(head) - TypedStreamReader.refBase
        guard i >= 0, i < Int64(Int.max) else { throw DecodeError.badReference }
        return Int(i)
    }

    private func sharedString() throws -> [UInt8]? {
        let head = try byte()
        if head == TypedStreamReader.tagNil { return nil }
        if head == TypedStreamReader.tagNew {
            let n = try readInt()
            guard n >= 0, n <= Int64(b.count) else { throw DecodeError.truncated }
            let s = try take(Int(n))
            strings.append(s)
            return s
        }
        let i = try refIndex(head)
        guard i < strings.count else { throw DecodeError.badReference }
        return strings[i]
    }

    private func cString() throws -> TSValue {
        let head = try peek()
        if head == TypedStreamReader.tagNil {
            p += 1
            return .null
        }
        if head == TypedStreamReader.tagNew {
            p += 1
            let value: TSValue = try sharedString().map { .bytes($0) } ?? .null
            objects.append(value)
            return value
        }
        p += 1
        let i = try refIndex(head)
        guard i < objects.count else { throw DecodeError.badReference }
        return objects[i]
    }

    private func enterNesting() throws {
        depth += 1
        if depth > TypedStreamReader.maxDepth { throw DecodeError.limitExceeded }
    }

    private func readClass() throws -> TSValue {
        let head = try byte()
        if head == TypedStreamReader.tagNil { return .null }
        if head == TypedStreamReader.tagNew {
            try enterNesting()
            defer { depth -= 1 }
            guard let nameBytes = try sharedString() else { throw DecodeError.badReference }
            let cls = TSClass(name: String(decoding: nameBytes, as: UTF8.self), version: try readInt())
            objects.append(.cls(cls))
            if case .cls(let superclass) = try readClass() { cls.superclass = superclass }
            return .cls(cls)
        }
        let i = try refIndex(head)
        guard i < objects.count else { throw DecodeError.badReference }
        return objects[i]
    }

    private func readObject() throws -> TSValue {
        let head = try byte()
        if head == TypedStreamReader.tagNil { return .null }
        if head == TypedStreamReader.tagNew {
            try enterNesting()
            defer { depth -= 1 }
            let obj = TSObject()
            objects.append(.object(obj))
            if case .cls(let cls) = try readClass() { obj.cls = cls }
            while try peek() != TypedStreamReader.tagEnd {
                guard let types = try sharedString() else { throw DecodeError.badReference }
                obj.fields.append(contentsOf: try readValues(types))
            }
            p += 1
            return .object(obj)
        }
        let i = try refIndex(head)
        guard i < objects.count else { throw DecodeError.badReference }
        return objects[i]
    }

    func readRoot() throws -> TSValue {
        guard let types = try sharedString() else { return .null }
        return try readValues(types).first ?? .null
    }

    private func readValues(_ t: [UInt8]) throws -> [TSValue] {
        try enterNesting()
        defer { depth -= 1 }
        var out: [TSValue] = []
        var i = 0
        while i < t.count {
            let (v, next) = try readOne(t, i)
            out.append(v)
            i = next
        }
        return out
    }

    private static func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }

    private func readOne(_ t: [UInt8], _ i: Int) throws -> (TSValue, Int) {
        steps += 1
        if steps > maxSteps { throw DecodeError.limitExceeded }
        let c = t[i]
        switch c {
        case UInt8(ascii: "c"), UInt8(ascii: "C"), UInt8(ascii: "s"), UInt8(ascii: "S"), UInt8(ascii: "i"),
             UInt8(ascii: "I"), UInt8(ascii: "l"), UInt8(ascii: "L"), UInt8(ascii: "q"), UInt8(ascii: "Q"):
            return (.int(try readInt()), i + 1)
        case UInt8(ascii: "f"), UInt8(ascii: "d"):
            let head = try byte()
            if head == TypedStreamReader.tagFloat {
                if c == UInt8(ascii: "f") {
                    let v = try take(4)
                    let u = UInt32(v[0]) | UInt32(v[1]) << 8 | UInt32(v[2]) << 16 | UInt32(v[3]) << 24
                    return (.double(Double(Float(bitPattern: u))), i + 1)
                }
                let v = try take(8)
                var u: UInt64 = 0
                for (k, x) in v.enumerated() { u |= UInt64(x) << (8 * UInt64(k)) }
                return (.double(Double(bitPattern: u)), i + 1)
            }
            return (.double(Double(try intFrom(head))), i + 1)
        case UInt8(ascii: "@"):
            return (try readObject(), i + 1)
        case UInt8(ascii: "#"):
            return (try readClass(), i + 1)
        case UInt8(ascii: "*"):
            return (try cString(), i + 1)
        case UInt8(ascii: "%"), UInt8(ascii: ":"):
            return (try sharedString().map { .bytes($0) } ?? .null, i + 1)
        case UInt8(ascii: "+"):
            let n = try readInt()
            guard n >= 0, n <= Int64(b.count) else { throw DecodeError.truncated }
            return (.bytes(try take(Int(n))), i + 1)
        case UInt8(ascii: "["):
            var j = i + 1
            while j < t.count, TypedStreamReader.isDigit(t[j]), j - i <= 9 { j += 1 }
            guard j > i + 1, let count = Int(String(decoding: t[(i + 1)..<j], as: UTF8.self)) else {
                throw DecodeError.unsupportedType("[")
            }
            let end = try TypedStreamReader.matching(t, i, open: UInt8(ascii: "["), close: UInt8(ascii: "]"))
            let inner = Array(t[j..<end])
            if inner == [UInt8(ascii: "c")] || inner == [UInt8(ascii: "C")] {
                return (.bytes(try take(count)), end + 1)
            }
            guard !inner.isEmpty else { throw DecodeError.unsupportedType("[") }
            var values: [TSValue] = []
            for _ in 0..<count { values.append(contentsOf: try readValues(inner)) }
            return (.list(values), end + 1)
        case UInt8(ascii: "{"):
            let end = try TypedStreamReader.matching(t, i, open: UInt8(ascii: "{"), close: UInt8(ascii: "}"))
            let body = Array(t[(i + 1)..<end])
            let fields = body.firstIndex(of: UInt8(ascii: "=")).map { Array(body[($0 + 1)...]) } ?? body
            return (.list(try readValues(fields)), end + 1)
        default:
            throw DecodeError.unsupportedType(Character(Unicode.Scalar(c)))
        }
    }

    private static func matching(_ t: [UInt8], _ i: Int, open: UInt8, close: UInt8) throws -> Int {
        var depth = 0
        for j in i..<t.count {
            if t[j] == open { depth += 1 } else if t[j] == close {
                depth -= 1
                if depth == 0 { return j }
            }
        }
        throw DecodeError.unsupportedType(Character(Unicode.Scalar(open)))
    }
}

/// `message_summary_info` (binary plist): `otr` original ranges, `ec` edit versions, `rp` unsent parts.
public struct SummaryInfo: Hashable, Sendable {
    /// Number of edits: the versions after the first, summed over parts. Edited twice is 2.
    public var editCount: Int
    public var unsentParts: [Int]
    /// Edited versions per part, oldest first, each decoded from its own typedstream.
    public var editVersions: [Int: [String]]
    /// `otr`: each part's original UTF-16 range in the body.
    public var originalRanges: [Int: Range<Int>] = [:]

    public init(editCount: Int, unsentParts: [Int], editVersions: [Int: [String]]) {
        self.editCount = editCount
        self.unsentParts = unsentParts
        self.editVersions = editVersions
    }

    public static func decode(_ data: Data) throws -> SummaryInfo {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = plist as? [String: Any] else {
            throw StoreError.decode("message_summary_info is not a property list dictionary")
        }
        let unsent = (dict["rp"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue }
        var versions: [Int: [String]] = [:]
        var edits = 0
        for (key, value) in dict["ec"] as? [String: Any] ?? [:] {
            guard let part = Int(key) else { continue }
            let list = value as? [Any] ?? []
            versions[part] = list.map { entry in
                guard let t = (entry as? [String: Any])?["t"] as? Data,
                      let body = try? TypedStreamDecoder.decodeAttributedString(t) else { return "" }
                return body.displayText
            }
            edits += max(0, list.count - 1)
        }
        var info = SummaryInfo(editCount: edits, unsentParts: unsent, editVersions: versions)
        for (key, value) in dict["otr"] as? [String: Any] ?? [:] {
            guard let part = Int(key), let r = value as? [String: Any],
                  let lo = (r["lo"] as? NSNumber)?.intValue, let le = (r["le"] as? NSNumber)?.intValue,
                  lo >= 0, le >= 0, lo <= Int.max - le else { continue }
            info.originalRanges[part] = lo..<(lo + le)
        }
        return info
    }
}

/// LPLinkMetadata from a URL balloon's `payload_data` (NSKeyedArchiver). Port of `_link_metadata` in bench/reader.py.
/// The archive is read with a small binary plist parser because Foundation can't read keyed-archiver UIDs.
public enum LinkMetadataDecoder {
    public static func decode(_ payload: Data) -> LinkRecord? {
        guard let root = try? BinaryPlist.parse(payload), case .dict(let top) = root,
              case .array(let objects)? = top["$objects"] else { return nil }

        func deref(_ v: BinaryPlist.Value?) -> BinaryPlist.Value? {
            guard let v else { return nil }
            if case .uid(let i) = v { return i >= 0 && i < objects.count ? objects[i] : nil }
            return v
        }
        func string(_ v: BinaryPlist.Value?) -> String? {
            guard case .string(let s)? = deref(v), s != "$null" else { return nil }
            return s
        }

        for object in objects {
            guard case .dict(let o) = object, o["title"] != nil, o["URL"] != nil || o["originalURL"] != nil else {
                continue
            }
            var url: String?
            if case .dict(let u)? = deref(o["URL"] ?? o["originalURL"]) { url = string(u["NS.relative"]) }
            return LinkRecord(url: url, site: string(o["siteName"]), title: string(o["title"]))
        }
        return nil
    }
}
