import Foundation

/// Parses `--since T` for `read` and `search` (section 5). Owner: IMCore.
///
/// Accepted forms, all in the caller's time zone:
/// - `30m`, `12h`, `7d`, `2w`: relative to `now`. Minutes and hours are exact seconds. Days and weeks are calendar
///   days, so `7d` lands on the same wall-clock time across a DST change.
/// - `today`, `yesterday`: start of that local day
/// - `2026-10-01`: start of that local day
/// - `2026-10-01T09:30`: that local minute. In a repeated hour after a DST change it is the first occurrence.
///
/// Anything else, including an impossible date such as `2026-02-30`, returns nil. Surrounding whitespace is ignored.
public enum TimeSpec {
    /// The count in a relative form has at most this many digits, so the arithmetic can't overflow.
    static let maxCountDigits = 6

    public static func parse(_ s: String, now: Date, timeZone: TimeZone) -> Date? {
        let text = s.trimmingCharacters(in: .whitespaces)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        switch text.lowercased() {
        case "today":
            return cal.startOfDay(for: now)
        case "yesterday":
            guard let d = cal.date(byAdding: .day, value: -1, to: now) else { return nil }
            return cal.startOfDay(for: d)
        default:
            break
        }
        if let d = relative(text, now: now, cal: cal) { return d }
        return absolute(text, cal: cal)
    }

    /// `parse` converted to Apple-epoch nanoseconds for the wire.
    public static func parseNanos(_ s: String, now: Date, timeZone: TimeZone) -> AppleNanos? {
        parse(s, now: now, timeZone: timeZone).map(AppleTime.nanos(from:))
    }

    private static func relative(_ s: String, now: Date, cal: Calendar) -> Date? {
        let scalars = Array(s.unicodeScalars)
        guard scalars.count >= 2, let unit = scalars.last else { return nil }
        let digits = scalars.dropLast()
        guard digits.count <= maxCountDigits, digits.allSatisfy({ ("0"..."9").contains($0) }),
              let n = Int(String(String.UnicodeScalarView(digits))) else { return nil }
        switch unit {
        case "m": return now.addingTimeInterval(-Double(n) * 60)
        case "h": return now.addingTimeInterval(-Double(n) * 3600)
        case "d": return cal.date(byAdding: .day, value: -n, to: now)
        case "w": return cal.date(byAdding: .day, value: -7 * n, to: now)
        default: return nil
        }
    }

    /// `YYYY-MM-DD` or `YYYY-MM-DDTHH:MM`, digits only, every field range-checked.
    private static func absolute(_ s: String, cal: Calendar) -> Date? {
        let b = Array(s.utf8)
        guard b.count == 10 || b.count == 16 else { return nil }
        func number(_ r: Range<Int>) -> Int? {
            var v = 0
            for i in r {
                guard b[i] >= 0x30, b[i] <= 0x39 else { return nil }
                v = v * 10 + Int(b[i] - 0x30)
            }
            return v
        }
        guard b[4] == 0x2D, b[7] == 0x2D, let year = number(0..<4), let month = number(5..<7),
              let day = number(8..<10), year >= 1, (1...12).contains(month), day >= 1 else { return nil }
        var hour = 0
        var minute = 0
        if b.count == 16 {
            guard b[10] == 0x54, b[13] == 0x3A, let h = number(11..<13), let m = number(14..<16),
                  (0...23).contains(h), (0...59).contains(m) else { return nil }
            hour = h
            minute = m
        }
        guard let first = cal.date(from: DateComponents(year: year, month: month, day: 1)),
              let days = cal.range(of: .day, in: .month, for: first), days.contains(day),
              let noon = cal.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) else {
            return nil
        }
        let dayStart = cal.startOfDay(for: noon)
        if b.count == 10 { return dayStart }
        // The first instant on that day showing that wall-clock time. In a repeated hour that is its first
        // occurrence. In a skipped hour it is the same instant the earlier offset gives, one hour later on the clock.
        return cal.nextDate(after: dayStart.addingTimeInterval(-1),
                            matching: DateComponents(hour: hour, minute: minute, second: 0),
                            matchingPolicy: .nextTimePreservingSmallerComponents, repeatedTimePolicy: .first,
                            direction: .forward)
    }
}
