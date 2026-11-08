import Foundation

/// A small reader for `bplist00` data that keeps keyed-archiver UIDs, which `PropertyListSerialization` hands back
/// as opaque objects. Used for URL balloon `payload_data`. Every offset and count is bounds-checked; each object is
/// parsed once and a reference cycle is an error.
enum BinaryPlist {
    indirect enum Value: Equatable {
        case null
        case bool(Bool)
        case int(Int64)
        case real(Double)
        case data(Data)
        case string(String)
        case uid(Int)
        case array([Value])
        case dict([String: Value])
    }

    enum ParseError: Error, Equatable {
        case notBinaryPlist
        case corrupt
    }

    static let maxDepth = 32
    static let maxObjects = 100_000

    static func parse(_ data: Data) throws -> Value {
        var parser = try Parser(Array(data))
        return try parser.object(parser.topObject, depth: 0)
    }

    private struct Parser {
        let b: [UInt8]
        let offsetSize: Int
        let refSize: Int
        let count: Int
        let topObject: Int
        let tableOffset: Int
        var cache: [Int: Value] = [:]
        var inProgress: Set<Int> = []

        init(_ bytes: [UInt8]) throws {
            b = bytes
            guard b.count >= 40, b[0..<8].elementsEqual("bplist00".utf8) else { throw ParseError.notBinaryPlist }
            let t = b.count - 32
            offsetSize = Int(b[t + 6])
            refSize = Int(b[t + 7])
            guard (1...8).contains(offsetSize), (1...8).contains(refSize) else { throw ParseError.corrupt }
            let n = Parser.be(b, t + 8, 8)
            let top = Parser.be(b, t + 16, 8)
            let table = Parser.be(b, t + 24, 8)
            guard n > 0, n <= UInt64(Self.limit), top < n, table >= 8, table < UInt64(t),
                  UInt64(t) - table >= n * UInt64(offsetSize) else { throw ParseError.corrupt }
            count = Int(n)
            topObject = Int(top)
            tableOffset = Int(table)
        }

        static var limit: Int { BinaryPlist.maxObjects }

        static func be(_ b: [UInt8], _ at: Int, _ n: Int) -> UInt64 {
            var v: UInt64 = 0
            for i in 0..<n { v = v << 8 | UInt64(b[at + i]) }
            return v
        }

        func read(_ at: Int, _ n: Int) throws -> UInt64 {
            guard at >= 0, n >= 0, n <= 8, at <= b.count - n else { throw ParseError.corrupt }
            return Parser.be(b, at, n)
        }

        func offset(of index: Int) throws -> Int {
            guard index >= 0, index < count else { throw ParseError.corrupt }
            let o = try read(tableOffset + index * offsetSize, offsetSize)
            guard o >= 8, o < UInt64(tableOffset) else { throw ParseError.corrupt }
            return Int(o)
        }

        /// Length of a data, string, array or dict object, and where its contents start.
        func length(_ marker: UInt8, at p: Int) throws -> (Int, Int) {
            let info = Int(marker & 0x0F)
            if info != 0x0F { return (info, p + 1) }
            guard p + 1 < b.count, b[p + 1] >> 4 == 0x1 else { throw ParseError.corrupt }
            let width = 1 << Int(b[p + 1] & 0x0F)
            guard width <= 8 else { throw ParseError.corrupt }
            let n = try read(p + 2, width)
            guard n <= UInt64(b.count) else { throw ParseError.corrupt }
            return (Int(n), p + 2 + width)
        }

        func refs(at p: Int, _ n: Int) throws -> [Int] {
            guard n >= 0, n <= b.count, p >= 0, p <= b.count - n * refSize else { throw ParseError.corrupt }
            return try (0..<n).map { Int(try read(p + $0 * refSize, refSize)) }
        }

        mutating func object(_ index: Int, depth: Int) throws -> Value {
            if let cached = cache[index] { return cached }
            guard depth <= BinaryPlist.maxDepth, !inProgress.contains(index) else { throw ParseError.corrupt }
            inProgress.insert(index)
            defer { inProgress.remove(index) }
            let p = try offset(of: index)
            let marker = b[p]
            let value: Value
            switch marker >> 4 {
            case 0x0:
                switch marker {
                case 0x08: value = .bool(false)
                case 0x09: value = .bool(true)
                default: value = .null
                }
            case 0x1:
                let width = 1 << Int(marker & 0x0F)
                guard width <= 8 else { throw ParseError.corrupt }
                let raw = try read(p + 1, width)
                value = .int(width == 8 ? Int64(bitPattern: raw) : Int64(raw))
            case 0x2, 0x3:
                let width = marker >> 4 == 0x3 ? 8 : 1 << Int(marker & 0x0F)
                let raw = try read(p + 1, width)
                switch width {
                case 4: value = .real(Double(Float(bitPattern: UInt32(raw))))
                case 8: value = .real(Double(bitPattern: raw))
                default: throw ParseError.corrupt
                }
            case 0x4:
                let (n, start) = try length(marker, at: p)
                guard start <= b.count - n else { throw ParseError.corrupt }
                value = .data(Data(b[start..<(start + n)]))
            case 0x5:
                let (n, start) = try length(marker, at: p)
                guard start <= b.count - n else { throw ParseError.corrupt }
                value = .string(String(decoding: b[start..<(start + n)], as: UTF8.self))
            case 0x6:
                let (n, start) = try length(marker, at: p)
                guard n <= b.count / 2, start <= b.count - 2 * n else { throw ParseError.corrupt }
                let units = (0..<n).map { UInt16(b[start + 2 * $0]) << 8 | UInt16(b[start + 2 * $0 + 1]) }
                value = .string(String(decoding: units, as: UTF16.self))
            case 0x8:
                let raw = try read(p + 1, Int(marker & 0x0F) + 1)
                guard raw <= UInt64(Int32.max) else { throw ParseError.corrupt }
                value = .uid(Int(raw))
            case 0xA, 0xB, 0xC:
                let (n, start) = try length(marker, at: p)
                var items: [Value] = []
                for r in try refs(at: start, n) { items.append(try object(r, depth: depth + 1)) }
                value = .array(items)
            case 0xD:
                let (n, start) = try length(marker, at: p)
                let keys = try refs(at: start, n)
                let values = try refs(at: start + n * refSize, n)
                var out: [String: Value] = [:]
                for (k, v) in zip(keys, values) {
                    guard case .string(let key) = try object(k, depth: depth + 1) else { continue }
                    out[key] = try object(v, depth: depth + 1)
                }
                value = .dict(out)
            default:
                throw ParseError.corrupt
            }
            cache[index] = value
            return value
        }
    }
}
