import Foundation

/// SplitMix64. Small, fast and identical on every platform, so a seed always gives the same fixture.
struct Rng {
  private var state: UInt64

  init(seed: UInt64) { state = seed }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }

  /// Uniform in [0, 1).
  mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }

  /// Uniform in lo...hi.
  mutating func int(_ lo: Int, _ hi: Int) -> Int {
    precondition(hi >= lo)
    return lo + Int(next() % UInt64(hi - lo + 1))
  }

  mutating func chance(_ p: Double) -> Bool { unit() < p }

  mutating func pick<T>(_ items: [T]) -> T { items[int(0, items.count - 1)] }

  mutating func weighted<T>(_ items: [(T, Double)]) -> T {
    let total = items.reduce(0) { $0 + $1.1 }
    var x = unit() * total
    for (item, w) in items {
      if x < w { return item }
      x -= w
    }
    return items[items.count - 1].0
  }

  mutating func shuffled<T>(_ items: [T]) -> [T] {
    var a = items
    if a.count < 2 { return a }
    for i in stride(from: a.count - 1, to: 0, by: -1) {
      let j = int(0, i)
      a.swapAt(i, j)
    }
    return a
  }

  /// An uppercase version-4 style UUID string drawn from this generator.
  mutating func uuid() -> String {
    var bytes = (0..<16).map { _ in UInt8(truncatingIfNeeded: next()) }
    bytes[6] = (bytes[6] & 0x0F) | 0x40
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    let hex = bytes.map { String(format: "%02X", $0) }.joined()
    let c = Array(hex)
    return "\(String(c[0..<8]))-\(String(c[8..<12]))-\(String(c[12..<16]))-\(String(c[16..<20]))-\(String(c[20..<32]))"
  }

  mutating func hex(_ n: Int) -> String {
    (0..<n).map { _ in String(format: "%x", Int(next() % 16)) }.joined()
  }

  mutating func digits(_ n: Int) -> String {
    (0..<n).map { i in String(i == 0 ? 1 + Int(next() % 9) : Int(next() % 10)) }.joined()
  }
}
