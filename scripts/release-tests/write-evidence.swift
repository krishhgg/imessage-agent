// Turns a release run's outcomes into release-evidence.json records (DESIGN.md section 4, "Capabilities and
// evidence"; docs/BUILD-PLAN.md "Release-test harness").
//
// Usage:
//   write-evidence --outcomes FILE --macos MAJOR.MINOR --bridge-version V [--evidence PATH] [--dry-run]
//
// --evidence defaults to packaging/release-evidence.json. scripts/build.sh copies that file into the app bundle at
// the next tag build.
//
// The outcomes file has one line per result: `cap <pass|fail|skip|rerun> <capability> <test> [detail]`. Other
// lines are ignored. For each capability named in the file, on this macOS version:
//   - any fail removes every record it has, so `caps` turns it off
//   - passes for every test it needs (requiredTests below) write one record per test, replacing older ones
//   - anything else (skipped or rerun parts) leaves its records as they were
//
// The output is a JSON array of EvidenceRecord (Sources/IMUI/Capabilities.swift) with ISO 8601 dates, one record
// per macOS version, capability and test, sorted. Exit status: 0 written, 1 can't read or write, 2 usage.
import Foundation

struct EvidenceRecord: Codable, Hashable {
    var macOS: String
    var capability: String
    var releaseTest: Int
    var passedAt: Date
    var bridgeVersion: String
}

/// Release tests each capability needs before it ships (DESIGN.md "Release tests", "What a failure does").
let requiredTests: [String: Set<Int>] = [
    "hidden-chat-switch": [1],
    "targeting": [3],
    "tapback.heart": [1, 2],
    "tapback.like": [2],
    "tapback.dislike": [2],
    "tapback.laugh": [2],
    "tapback.emphasize": [2],
    "tapback.question": [2],
    "tapback.emoji": [2],
    "tapback.incoming": [2],
    "unsend": [1],
    "edit": [4, 6],
    "threaded-reply": [4, 6],
    "foreground-mode": [5, 6],
    "image-send": [8],
    "attachment-conversion": [8],
    "group-send": [8],
]

func fail(_ code: Int32, _ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    if code == 2 {
        FileHandle.standardError.write(Data("usage: write-evidence --outcomes FILE --macos MAJOR.MINOR --bridge-version V [--evidence PATH] [--dry-run]\n".utf8))
    }
    exit(code)
}

var outcomesPath = ""
var macOS = ""
var bridgeVersion = ""
var evidencePath = "packaging/release-evidence.json"
var dryRun = false
var args = Array(CommandLine.arguments.dropFirst())
func value(_ flag: String) -> String {
    guard !args.isEmpty else { fail(2, "\(flag) needs a value") }
    return args.removeFirst()
}
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--outcomes": outcomesPath = value(a)
    case "--macos": macOS = value(a)
    case "--bridge-version": bridgeVersion = value(a)
    case "--evidence": evidencePath = value(a)
    case "--dry-run": dryRun = true
    default: fail(2, "unknown argument \(a)")
    }
}
if outcomesPath.isEmpty || macOS.isEmpty || bridgeVersion.isEmpty { fail(2, "--outcomes, --macos and --bridge-version are required") }
/// True for one or more ASCII digits. Character.isNumber alone would also take other scripts' digits and fractions.
func isDigits(_ s: Substring) -> Bool { !s.isEmpty && s.allSatisfy { $0.isASCII && $0.isNumber } }
let parts = macOS.split(separator: ".", omittingEmptySubsequences: false)
guard parts.count == 2, parts.allSatisfy(isDigits) else {
    fail(2, "--macos must be major.minor, for example 26.2")
}
let versionParts = bridgeVersion.split(separator: ".", omittingEmptySubsequences: false)
guard versionParts.count == 3, versionParts.allSatisfy(isDigits) else {
    fail(2, "--bridge-version must be major.minor.patch, for example 0.1.0")
}

guard let outcomesText = try? String(contentsOfFile: outcomesPath, encoding: .utf8) else {
    fail(1, "can't read \(outcomesPath)")
}

var passes: [String: Set<Int>] = [:]
var failures: [String: Set<Int>] = [:]
var mentioned: [String] = []
for raw in outcomesText.split(separator: "\n") {
    let f = raw.split(separator: " ", omittingEmptySubsequences: true)
    guard f.count >= 4, f[0] == "cap" else { continue }
    let status = String(f[1]), capability = String(f[2])
    guard let test = Int(f[3]) else { fail(1, "bad test number in: \(raw)") }
    guard requiredTests[capability] != nil else { fail(1, "unknown capability \(capability) in: \(raw)") }
    if !mentioned.contains(capability) { mentioned.append(capability) }
    switch status {
    case "pass": passes[capability, default: []].insert(test)
    case "fail": failures[capability, default: []].insert(test)
    case "skip", "rerun": break
    default: fail(1, "bad status \(status) in: \(raw)")
    }
}

let decoder = JSONDecoder()
decoder.dateDecodingStrategy = .iso8601
var records: [EvidenceRecord] = []
if FileManager.default.fileExists(atPath: evidencePath) {
    guard let data = FileManager.default.contents(atPath: evidencePath),
          let existing = try? decoder.decode([EvidenceRecord].self, from: data) else {
        fail(1, "\(evidencePath) isn't a JSON array of evidence records")
    }
    records = existing
}

let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
var report: [String] = []
for capability in mentioned {
    let needed = requiredTests[capability]!
    if let failed = failures[capability], !failed.isEmpty {
        let before = records.count
        records.removeAll { $0.macOS == macOS && $0.capability == capability }
        let tests = failed.sorted().map(String.init).joined(separator: ",")
        report.append("\(capability): failed in test \(tests), removed \(before - records.count) record(s), off on \(macOS)")
        continue
    }
    let passed = passes[capability] ?? []
    if needed.isSubset(of: passed) {
        records.removeAll { $0.macOS == macOS && $0.capability == capability }
        for test in needed.sorted() {
            records.append(EvidenceRecord(macOS: macOS, capability: capability, releaseTest: test, passedAt: now,
                                          bridgeVersion: bridgeVersion))
        }
        report.append("\(capability): passed test \(needed.sorted().map(String.init).joined(separator: ",")), recorded for \(macOS)")
    } else {
        let missing = needed.subtracting(passed).sorted().map(String.init).joined(separator: ",")
        report.append("\(capability): test \(missing) didn't pass in this run, records unchanged")
    }
}

// One record per macOS version, capability and test, keeping the newest.
var newest: [String: EvidenceRecord] = [:]
for r in records {
    let key = "\(r.macOS)|\(r.capability)|\(r.releaseTest)"
    if let old = newest[key], old.passedAt >= r.passedAt { continue }
    newest[key] = r
}
let sorted = newest.values.sorted {
    ($0.macOS, $0.capability, $0.releaseTest) < ($1.macOS, $1.capability, $1.releaseTest)
}

let encoder = JSONEncoder()
encoder.dateEncodingStrategy = .iso8601
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
guard var data = try? encoder.encode(sorted) else { fail(1, "can't encode the records") }
data.append(0x0A)

for line in report { print(line) }
if dryRun {
    print("dry run: \(evidencePath) not written (\(sorted.count) record(s))")
    exit(0)
}
do {
    try data.write(to: URL(fileURLWithPath: evidencePath), options: .atomic)
} catch {
    fail(1, "can't write \(evidencePath): \(error.localizedDescription)")
}
print("wrote \(sorted.count) record(s) to \(evidencePath)")
