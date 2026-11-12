import Foundation
import IMCore

/// Every gated capability (DESIGN.md section 4, Capabilities and evidence; section 3 item 8; Release tests, "What a
/// failure does"). Each one is on only with a passing release-evidence record for the running macOS major.minor.
public enum Capability: Hashable, Sendable {
    /// Release tests 1 (Heart) and 2 (the other kinds), on the user's own messages.
    case tapbackOwnMessages(TapbackKind)
    /// Release test 2, consenting-sender case. Until it passes, tapbacks stay limited to the user's own messages.
    case tapbackIncoming(TapbackKind)
    /// Release test 2, one recent emoji, verified as type 2006 and 3006.
    case emojiTapback
    /// Release test 1.
    case unsend
    /// Release test 4, edit part.
    case edit
    /// Release test 4, threaded-reply part.
    case threadedReply
    /// Release test 1, the hidden chat switch. Every UI action needs it.
    case hiddenChatSwitch
    /// Release test 3. Every UI action needs it.
    case targeting
    /// Release tests 5 and 6b, the foreground abort path and full screen. Edit and threaded reply need it. This is
    /// the release evidence, not the user's foreground-mode setting, which `report` takes separately.
    case foregroundMode
    /// Release test 8, the HEIC photo send. While it isn't supported, IMBridge returns `unsupported` for an image
    /// file send and sends nothing.
    case imageSend
    /// Release test 8, `att` HEIC to JPEG conversion. While it isn't supported, IMBridge calls
    /// `AttachmentService.export` with `convertHEIC` false.
    case attachmentConversion
    /// Release test 8, group case. Group sends stay `untested` until it passes (section 3 item 8).
    case groupSend

    /// Name used in `caps` output and in release-evidence.json.
    ///
    /// An own-message emoji tapback and `emojiTapback` share "tapback.emoji". Every incoming kind shares
    /// "tapback.incoming", because release test 2 runs one consenting-sender Heart.
    public var name: String {
        switch self {
        case .tapbackOwnMessages(.emoji), .emojiTapback: return "tapback.emoji"
        case .tapbackOwnMessages(let kind): return "tapback.\(kind.wireName)"
        case .tapbackIncoming: return "tapback.incoming"
        case .unsend: return "unsend"
        case .edit: return "edit"
        case .threadedReply: return "threaded-reply"
        case .hiddenChatSwitch: return "hidden-chat-switch"
        case .targeting: return "targeting"
        case .foregroundMode: return "foreground-mode"
        case .imageSend: return "image-send"
        case .attachmentConversion: return "attachment-conversion"
        case .groupSend: return "group-send"
        }
    }

    /// The release tests that must each have a record under `name` for this macOS major.minor. Foreground mode needs
    /// both test 5 and test 6 (part 6b; 6a blocks the tag instead).
    public var releaseTests: [Int] {
        switch self {
        // Test 2 also runs Heart on an earlier day's message and on the newest one, and a failure there turns
        // Heart off.
        case .tapbackOwnMessages(.heart): return [1, 2]
        case .unsend, .hiddenChatSwitch: return [1]
        case .tapbackOwnMessages, .tapbackIncoming, .emojiTapback: return [2]
        case .targeting: return [3]
        case .edit, .threadedReply: return [4]
        case .foregroundMode: return [5, 6]
        case .imageSend, .attachmentConversion, .groupSend: return [8]
        }
    }

    /// True when the capability drives the Messages UI by English names, so a non-English UI language makes it
    /// `unsupported`. Sends, image sends and `att` conversion don't.
    public var usesMessagesUI: Bool {
        switch self {
        case .hiddenChatSwitch, .targeting, .foregroundMode: return true
        default: return isUIAction
        }
    }

    /// The capability that gates a tapback of `kind` on a message from the user (`fromMe`) or from someone else.
    public static func tapback(_ kind: TapbackKind, onOwnMessage: Bool) -> Capability {
        if !onOwnMessage { return .tapbackIncoming(kind) }
        if case .emoji = kind { return .emojiTapback }
        return .tapbackOwnMessages(kind)
    }

    /// The rows `caps` shows, in order. Incoming tapbacks show as one row, keyed on the Heart.
    public static let reported: [Capability] = [
        .hiddenChatSwitch, .targeting,
        .tapbackOwnMessages(.heart), .tapbackOwnMessages(.like), .tapbackOwnMessages(.dislike),
        .tapbackOwnMessages(.laugh), .tapbackOwnMessages(.emphasize), .tapbackOwnMessages(.question),
        .emojiTapback, .tapbackIncoming(.heart), .unsend,
        .foregroundMode, .edit, .threadedReply,
        .imageSend, .attachmentConversion, .groupSend,
    ]

    /// True for actions that press in Messages: tapbacks, unsend, edit and threaded reply.
    public var isUIAction: Bool {
        switch self {
        case .tapbackOwnMessages, .tapbackIncoming, .emojiTapback, .unsend, .edit, .threadedReply: return true
        case .hiddenChatSwitch, .targeting, .foregroundMode, .imageSend, .attachmentConversion, .groupSend: return false
        }
    }

    /// Capabilities that must also be supported before this one is. A failed chat switch or test 3 turns off every
    /// UI action, and tests 5 and 6b turn off both foreground actions.
    public var prerequisites: [Capability] {
        switch self {
        case .edit, .threadedReply: return [.hiddenChatSwitch, .targeting, .foregroundMode]
        case .tapbackOwnMessages, .tapbackIncoming, .emojiTapback, .unsend: return [.hiddenChatSwitch, .targeting]
        case .hiddenChatSwitch, .targeting, .foregroundMode, .imageSend, .attachmentConversion, .groupSend: return []
        }
    }
}

/// One passed release test, written by the release run into `Contents/Resources/release-evidence.json`.
public struct EvidenceRecord: Hashable, Codable, Sendable {
    /// `major.minor`, for example `26.2`. A point update keeps the record.
    public var macOS: String
    public var capability: String
    public var releaseTest: Int
    public var passedAt: Date
    public var bridgeVersion: String

    public init(macOS: String, capability: String, releaseTest: Int, passedAt: Date, bridgeVersion: String) {
        self.macOS = macOS
        self.capability = capability
        self.releaseTest = releaseTest
        self.passedAt = passedAt
        self.bridgeVersion = bridgeVersion
    }
}

/// Decides what `caps` reports and what the bridge allows. Owner: IMUI.
///
/// - A capability is `supported` only with an evidence record for the running major.minor, and only if every one of
///   its `prerequisites` is supported too.
/// - No record for this version: UI actions are `untested` and off. So are image sends, `att` conversion and group
///   sends, because evidence records only passes and a missing record can't be told apart from a failed test.
/// - Non-English UI language: UI actions are `unsupported`.
/// - Times not on a 12-hour clock, or short dates other than `M/d/yy`: every capability that drives the Messages UI
///   is `unsupported` with `formatNote`, because `RowDescriptionBuilder` rebuilds row and bubble times only in
///   those forms (S3) and every row or bubble would fail to match.
/// - Tapbacks on incoming messages stay off until release test 2's consenting-sender case passes.
/// - Group sends stay `untested` until release test 8's group case passes.
/// - Edit and threaded reply also need the user's foreground-mode setting on.
///
/// The evidence file is a JSON array of `EvidenceRecord` with ISO 8601 dates. It is read once, at init. A missing,
/// unreadable, oversized or malformed file counts as no records, so everything gated stays off.
///
/// A build compiled with `-DIMESSAGE_RELEASE_TESTS` (`scripts/build.sh --release-tests`) reports every capability
/// as `supported (release-test build)` on any version. A normal build doesn't contain that branch.
///
/// The registry is immutable after init, so the bridge may call it from any connection at once.
public final class CapabilityRegistry: Sendable {
    public let evidenceURL: URL
    /// The running macOS as major.minor. A point version passed in is cut to major.minor.
    public let macOSVersion: String
    public let uiLanguageEnglish: Bool
    /// `formatsMatch` for the locale passed at init.
    public let uiFormatsMatch: Bool
    /// The records read at init, in file order.
    public let records: [EvidenceRecord]
    private let passed: Set<String>

    /// The evidence file's size limit. A larger file counts as no records.
    public static let maxEvidenceBytes = 1 << 20

    #if IMESSAGE_RELEASE_TESTS
    /// True in a release-test build. `caps` and `doctor` say so in their header.
    public static let isReleaseTestBuild = true
    #else
    /// True in a release-test build. `caps` and `doctor` say so in their header.
    public static let isReleaseTestBuild = false
    #endif

    /// The note on every entry of a release-test build.
    public static let releaseTestNote = "release-test build"
    /// The note on edit and threaded reply while the user's foreground-mode setting is off.
    public static let foregroundOffNote = "foreground mode off"
    /// The note on every capability that drives the Messages UI while `uiFormatsMatch` is false.
    public static let formatNote = "needs 12-hour time and M/d/yy dates"

    /// `locale` is the one Messages formats times and dates with: `Locale.current` in the bridge.
    public init(evidenceURL: URL, macOSVersion: String, uiLanguageEnglish: Bool, locale: Locale = .current) {
        self.evidenceURL = evidenceURL
        let version = Self.majorMinor(macOSVersion)
        self.macOSVersion = version
        self.uiLanguageEnglish = uiLanguageEnglish
        self.uiFormatsMatch = Self.formatsMatch(locale)
        let records = Self.loadEvidence(from: evidenceURL)
        self.records = records
        self.passed = Set(records.compactMap { record in
            Self.majorMinor(record.macOS) == version ? Self.key(record.capability, record.releaseTest) : nil
        })
    }

    public func status(_ capability: Capability) -> CapStatus {
        #if IMESSAGE_RELEASE_TESTS
        return .supported
        #else
        return evaluate(capability)
        #endif
    }

    public func report(accessibilityTrusted: Bool, foregroundMode: Bool) -> CapsReport {
        let entries = Capability.reported.map { capability -> CapEntry in
            #if IMESSAGE_RELEASE_TESTS
            var notes = [Self.releaseTestNote]
            #else
            var notes: [String] = []
            #endif
            if !uiFormatsMatch, capability.usesMessagesUI { notes.append(Self.formatNote) }
            if !foregroundMode, capability == .edit || capability == .threadedReply {
                notes.append(Self.foregroundOffNote)
            }
            return CapEntry(name: capability.name, status: status(capability),
                            note: notes.isEmpty ? nil : notes.joined(separator: ", "))
        }
        return CapsReport(macOSVersion: macOSVersion, uiLanguageEnglish: uiLanguageEnglish,
                          accessibilityTrusted: accessibilityTrusted, foregroundMode: foregroundMode, entries: entries)
    }

    /// `major.minor` of `ProcessInfo.operatingSystemVersion`.
    public static func currentMajorMinor() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion)"
    }

    /// True if the first preferred language is English.
    public static func currentUIIsEnglish() -> Bool {
        isEnglish(Locale.preferredLanguages.first)
    }

    /// True when `locale` writes times on a 12-hour clock with AM and PM (`j` gives a pattern with `a`) and short
    /// dates as `M/d/yy`, the forms `RowDescriptionBuilder` rebuilds. Other formats aren't rebuilt in v1.
    public static func formatsMatch(_ locale: Locale) -> Bool {
        let hour = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale) ?? ""
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return unquoted(hour).contains("a") && formatter.dateFormat == "M/d/yy"
    }

    /// A date pattern with its quoted literals removed, so a literal "a" doesn't count as the AM/PM field.
    static func unquoted(_ pattern: String) -> String {
        pattern.split(separator: "'", omittingEmptySubsequences: false).enumerated()
            .filter { $0.offset.isMultiple(of: 2) }.map(\.element).joined()
    }

    // MARK: - Evidence

    /// The records in `url`, or none if the file is missing, larger than `maxEvidenceBytes` or malformed.
    public static func loadEvidence(from url: URL) -> [EvidenceRecord] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxEvidenceBytes + 1), data.count <= maxEvidenceBytes else {
            return []
        }
        return (try? evidenceDecoder().decode([EvidenceRecord].self, from: data)) ?? []
    }

    /// The decoder for release-evidence.json: ISO 8601 dates.
    public static func evidenceDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// The encoder `write-evidence.swift` should match: ISO 8601 dates, sorted keys.
    public static func evidenceEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    // MARK: - Rules

    /// The evidence rules, without the release-test switch.
    func evaluate(_ capability: Capability) -> CapStatus {
        var result = ownStatus(capability)
        if case .tapbackIncoming(let kind) = capability {
            result = Self.worse(result, evaluate(.tapback(kind, onOwnMessage: true)))
        }
        for prerequisite in capability.prerequisites {
            result = Self.worse(result, evaluate(prerequisite))
        }
        return result
    }

    private func ownStatus(_ capability: Capability) -> CapStatus {
        if capability.usesMessagesUI && !(uiLanguageEnglish && uiFormatsMatch) { return .unsupported }
        let name = capability.name
        let tests = capability.releaseTests
        guard !tests.isEmpty, tests.allSatisfy({ passed.contains(Self.key(name, $0)) }) else { return .untested }
        return .supported
    }

    private static func worse(_ a: CapStatus, _ b: CapStatus) -> CapStatus {
        func rank(_ s: CapStatus) -> Int {
            switch s {
            case .supported: return 0
            case .untested: return 1
            case .unsupported: return 2
            }
        }
        return rank(a) >= rank(b) ? a : b
    }

    private static func key(_ name: String, _ test: Int) -> String { "\(name)|\(test)" }

    /// "26.2.1" and "26.2" give "26.2", "26" gives "26.0". Anything else is kept trimmed, so it matches nothing
    /// a release run would write.
    static func majorMinor(_ version: String) -> String {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count), let major = Int(parts[0]), major >= 0 else { return trimmed }
        let minor = parts.count > 1 ? Int(parts[1]) : 0
        guard let minor, minor >= 0, parts.count < 3 || Int(parts[2]) != nil else { return trimmed }
        return "\(major).\(minor)"
    }

    /// True for a language identifier whose language code is `en`: "en", "en-US", "en_GB", "en-Latn-US".
    static func isEnglish(_ identifier: String?) -> Bool {
        guard let identifier else { return false }
        let code = identifier.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
        return code.lowercased() == "en"
    }
}
