import XCTest
import IMCore
@testable import IMUI
import IMTestSupport

/// Checklist item 15: evidence, prerequisites, language, incoming tapbacks and the release-test switch.
final class CapabilitiesTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("imui-caps-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    static let allCapabilities: [Capability] = Capability.reported + [
        .tapbackIncoming(.like), .tapbackIncoming(.emoji("😭")), .tapbackOwnMessages(.emoji("😭")),
    ]

    /// One record per release test each capability needs, on `macOS`.
    func records(_ macOS: String = "26.2", except skipped: Set<String> = []) -> [EvidenceRecord] {
        var out: [EvidenceRecord] = []
        var seen = Set<String>()
        for capability in Self.allCapabilities {
            for test in capability.releaseTests {
                let key = "\(capability.name)|\(test)"
                guard !skipped.contains(key), !skipped.contains(capability.name), seen.insert(key).inserted else {
                    continue
                }
                out.append(EvidenceRecord(macOS: macOS, capability: capability.name, releaseTest: test,
                                          passedAt: Date(timeIntervalSince1970: 1_790_000_000),
                                          bridgeVersion: "1.0.0"))
            }
        }
        return out
    }

    func write(_ records: [EvidenceRecord]) throws -> URL {
        let url = dir.appendingPathComponent("release-evidence.json")
        try CapabilityRegistry.evidenceEncoder().encode(records).write(to: url)
        return url
    }

    /// US formats, so the host's own time and date settings never change these tests.
    static let us = Locale(identifier: "en_US")

    func registry(_ records: [EvidenceRecord]? = nil, macOS: String = "26.2", english: Bool = true,
                  locale: Locale = CapabilitiesTests.us) throws -> CapabilityRegistry {
        let url = try write(records ?? self.records())
        return CapabilityRegistry(evidenceURL: url, macOSVersion: macOS, uiLanguageEnglish: english, locale: locale)
    }

    // MARK: - Names

    func testNames() {
        XCTAssertEqual(Capability.tapbackOwnMessages(.heart).name, "tapback.heart")
        XCTAssertEqual(Capability.tapbackOwnMessages(.question).name, "tapback.question")
        XCTAssertEqual(Capability.tapbackOwnMessages(.emoji("😭")).name, "tapback.emoji")
        XCTAssertEqual(Capability.emojiTapback.name, "tapback.emoji")
        XCTAssertEqual(Capability.tapbackIncoming(.like).name, "tapback.incoming")
        XCTAssertEqual(Capability.threadedReply.name, "threaded-reply")
        XCTAssertEqual(Capability.hiddenChatSwitch.name, "hidden-chat-switch")
        XCTAssertEqual(Capability.foregroundMode.name, "foreground-mode")
        XCTAssertEqual(Capability.attachmentConversion.name, "attachment-conversion")
        XCTAssertEqual(Set(Capability.reported.map(\.name)).count, Capability.reported.count)
    }

    func testReleaseTestsFollowTheDesign() {
        XCTAssertEqual(Capability.tapbackOwnMessages(.heart).releaseTests, [1, 2])
        XCTAssertEqual(Capability.unsend.releaseTests, [1])
        XCTAssertEqual(Capability.hiddenChatSwitch.releaseTests, [1])
        XCTAssertEqual(Capability.tapbackOwnMessages(.like).releaseTests, [2])
        XCTAssertEqual(Capability.emojiTapback.releaseTests, [2])
        XCTAssertEqual(Capability.tapbackIncoming(.heart).releaseTests, [2])
        XCTAssertEqual(Capability.targeting.releaseTests, [3])
        XCTAssertEqual(Capability.edit.releaseTests, [4])
        XCTAssertEqual(Capability.threadedReply.releaseTests, [4])
        XCTAssertEqual(Capability.foregroundMode.releaseTests, [5, 6])
        XCTAssertEqual(Capability.groupSend.releaseTests, [8])
    }

    func testTapbackCapabilityForADirection() {
        XCTAssertEqual(Capability.tapback(.heart, onOwnMessage: true), .tapbackOwnMessages(.heart))
        XCTAssertEqual(Capability.tapback(.emoji("😭"), onOwnMessage: true), .emojiTapback)
        XCTAssertEqual(Capability.tapback(.like, onOwnMessage: false), .tapbackIncoming(.like))
    }

    // MARK: - Evidence rules

    #if !IMESSAGE_RELEASE_TESTS
    func testFullEvidenceOnTheRunningVersionSupportsEverything() throws {
        let caps = try registry()
        for capability in Self.allCapabilities {
            XCTAssertEqual(caps.status(capability), .supported, capability.name)
        }
    }

    func testNoEvidenceFileLeavesEverythingUntestedAndOff() {
        let caps = CapabilityRegistry(evidenceURL: dir.appendingPathComponent("missing.json"), macOSVersion: "26.2",
                                      uiLanguageEnglish: true, locale: Self.us)
        for capability in Self.allCapabilities {
            XCTAssertEqual(caps.status(capability), .untested, capability.name)
        }
        XCTAssertTrue(caps.records.isEmpty)
    }

    func testRecordsForAnotherVersionDoNotCount() throws {
        let caps = try registry(records("26.1"), macOS: "26.2")
        for capability in Self.allCapabilities {
            XCTAssertEqual(caps.status(capability), .untested, capability.name)
        }
    }

    func testPointUpdateKeepsTheRecords() throws {
        XCTAssertEqual(try registry(macOS: "26.2.1").status(.unsend), .supported)
        XCTAssertEqual(try registry(macOS: "26.2.1").macOSVersion, "26.2")
        XCTAssertEqual(try registry(records("26.0"), macOS: "26").status(.unsend), .supported)
        XCTAssertEqual(try registry(macOS: "26.20").status(.unsend), .untested)
    }

    func testFailedTargetingTurnsOffEveryUIAction() throws {
        let caps = try registry(records(except: ["targeting"]))
        for capability in Self.allCapabilities where capability.isUIAction {
            XCTAssertEqual(caps.status(capability), .untested, capability.name)
        }
        for capability: Capability in [.hiddenChatSwitch, .imageSend, .attachmentConversion, .groupSend,
                                       .foregroundMode] {
            XCTAssertEqual(caps.status(capability), .supported, capability.name)
        }
    }

    func testFailedChatSwitchTurnsOffNoUIAction() throws {
        let caps = try registry(records(except: ["hidden-chat-switch"]))
        XCTAssertEqual(caps.status(.hiddenChatSwitch), .untested)
        for capability in Self.allCapabilities where capability != .hiddenChatSwitch {
            XCTAssertEqual(caps.status(capability), .supported, capability.name)
        }
        let report = caps.report(accessibilityTrusted: true, foregroundMode: true)
        XCTAssertEqual(report.entries.first { $0.name == "hidden-chat-switch" }?.status, .untested)
        XCTAssertEqual(report.entries.first { $0.name == "unsend" }?.status, .supported)
        XCTAssertEqual(report.entries.first { $0.name == "edit" }?.status, .supported)
    }

    func testForegroundEvidenceNeedsBothTests() throws {
        let caps = try registry(records(except: ["foreground-mode|6"]))
        XCTAssertEqual(caps.status(.foregroundMode), .untested)
        XCTAssertEqual(caps.status(.edit), .untested)
        XCTAssertEqual(caps.status(.threadedReply), .untested)
        XCTAssertEqual(caps.status(.tapbackOwnMessages(.heart)), .supported)
        XCTAssertEqual(caps.status(.unsend), .supported)
    }

    func testEachActionNeedsItsOwnRecord() throws {
        let caps = try registry(records(except: ["tapback.like", "unsend", "edit"]))
        XCTAssertEqual(caps.status(.tapbackOwnMessages(.like)), .untested)
        XCTAssertEqual(caps.status(.tapbackOwnMessages(.heart)), .supported)
        XCTAssertEqual(caps.status(.unsend), .untested)
        XCTAssertEqual(caps.status(.edit), .untested)
        XCTAssertEqual(caps.status(.threadedReply), .supported)
    }

    func testHeartNeedsBothTestOneAndTestTwo() throws {
        // Test 2's earlier-day and newest-message Heart cases turn Heart off when they fail.
        for missing in ["tapback.heart|1", "tapback.heart|2"] {
            let caps = try registry(records(except: [missing]))
            XCTAssertEqual(caps.status(.tapbackOwnMessages(.heart)), .untested, missing)
            XCTAssertEqual(caps.status(.tapbackIncoming(.heart)), .untested, missing)
            XCTAssertEqual(caps.status(.tapbackOwnMessages(.like)), .supported, missing)
        }
    }

    func testARecordUnderTheWrongTestNumberDoesNotCount() throws {
        var list = records(except: ["tapback.heart"])
        list.append(EvidenceRecord(macOS: "26.2", capability: "tapback.heart", releaseTest: 2, passedAt: Date(),
                                   bridgeVersion: "1.0.0"))
        XCTAssertEqual(try registry(list).status(.tapbackOwnMessages(.heart)), .untested)
    }

    func testIncomingTapbacksStayOffUntilTheConsentingSenderCasePasses() throws {
        let caps = try registry(records(except: ["tapback.incoming"]))
        XCTAssertEqual(caps.status(.tapbackOwnMessages(.heart)), .supported)
        XCTAssertEqual(caps.status(.tapbackIncoming(.heart)), .untested)
        XCTAssertEqual(caps.status(.tapbackIncoming(.like)), .untested)
    }

    func testIncomingTapbackAlsoNeedsThatKindOnOwnMessages() throws {
        let caps = try registry(records(except: ["tapback.like", "tapback.emoji"]))
        XCTAssertEqual(caps.status(.tapbackIncoming(.heart)), .supported)
        XCTAssertEqual(caps.status(.tapbackIncoming(.like)), .untested)
        XCTAssertEqual(caps.status(.tapbackIncoming(.emoji("😭"))), .untested)
    }

    func testTestEightPartsTurnOffOnlyThemselves() throws {
        for name in ["image-send", "attachment-conversion", "group-send"] {
            let caps = try registry(records(except: [name]))
            for capability: Capability in [.imageSend, .attachmentConversion, .groupSend] {
                XCTAssertEqual(caps.status(capability), capability.name == name ? .untested : .supported,
                               "\(name) missing: \(capability.name)")
            }
            XCTAssertEqual(caps.status(.unsend), .supported)
        }
    }

    func testNonEnglishUIMakesUIActionsUnsupportedButNotSends() throws {
        let caps = try registry(english: false)
        for capability in Self.allCapabilities where capability.usesMessagesUI {
            XCTAssertEqual(caps.status(capability), .unsupported, capability.name)
        }
        for capability: Capability in [.imageSend, .attachmentConversion, .groupSend] {
            XCTAssertEqual(caps.status(capability), .supported, capability.name)
        }
    }

    func testUnsupportedOutranksUntested() throws {
        let caps = CapabilityRegistry(evidenceURL: dir.appendingPathComponent("none.json"), macOSVersion: "26.2",
                                      uiLanguageEnglish: false, locale: Self.us)
        XCTAssertEqual(caps.status(.unsend), .unsupported)
        XCTAssertEqual(caps.status(.imageSend), .untested)
    }

    // MARK: - Time and date formats

    func testFormatCheck() {
        XCTAssertTrue(CapabilityRegistry.formatsMatch(Locale(identifier: "en_US")))
        XCTAssertTrue(CapabilityRegistry.formatsMatch(Locale(identifier: "en_US@hours=h12")))
        XCTAssertFalse(CapabilityRegistry.formatsMatch(Locale(identifier: "en_GB")), "24-hour and d/M dates")
        XCTAssertFalse(CapabilityRegistry.formatsMatch(Locale(identifier: "en_US@hours=h23")), "24-hour override")
        XCTAssertFalse(CapabilityRegistry.formatsMatch(Locale(identifier: "en_GB@hours=h12")), "dd/MM/y dates")
        XCTAssertFalse(CapabilityRegistry.formatsMatch(Locale(identifier: "en_AU")), "d/M/y dates")
        XCTAssertEqual(CapabilityRegistry.unquoted("HH 'h' mm"), "HH  mm")
        XCTAssertEqual(CapabilityRegistry.unquoted("h:mm a"), "h:mm a")
        XCTAssertFalse(CapabilityRegistry.unquoted("HH 'at' mm").contains("a"))
    }

    func testUSFormatsKeepUIActionsSupported() throws {
        let caps = try registry(locale: Locale(identifier: "en_US"))
        XCTAssertTrue(caps.uiFormatsMatch)
        for capability in Self.allCapabilities {
            XCTAssertEqual(caps.status(capability), .supported, capability.name)
        }
        let report = caps.report(accessibilityTrusted: true, foregroundMode: true)
        XCTAssertFalse(report.entries.contains { $0.note?.contains(CapabilityRegistry.formatNote) == true })
    }

    func testOtherFormatsMakeEveryMessagesUICapabilityUnsupportedWithTheNote() throws {
        for id in ["en_GB", "en_US@hours=h23"] {
            let caps = try registry(locale: Locale(identifier: id))
            XCTAssertFalse(caps.uiFormatsMatch, id)
            for capability in Self.allCapabilities {
                XCTAssertEqual(caps.status(capability), capability.usesMessagesUI ? .unsupported : .supported,
                               "\(id): \(capability.name)")
            }
            let report = caps.report(accessibilityTrusted: true, foregroundMode: true)
            for (capability, entry) in zip(Capability.reported, report.entries) {
                XCTAssertEqual(entry.note, capability.usesMessagesUI ? "needs 12-hour time and M/d/yy dates" : nil,
                               "\(id): \(entry.name)")
            }
            XCTAssertTrue(report.uiLanguageEnglish, "the language flag stays a language flag")
            let off = caps.report(accessibilityTrusted: true, foregroundMode: false)
            XCTAssertEqual(off.entries.first { $0.name == "edit" }?.note,
                           "needs 12-hour time and M/d/yy dates, foreground mode off")
        }
    }

    // MARK: - Evidence file handling

    func testMalformedEvidenceCountsAsNone() throws {
        let url = dir.appendingPathComponent("bad.json")
        try Data("{\"not\": \"an array\"}".utf8).write(to: url)
        let caps = CapabilityRegistry(evidenceURL: url, macOSVersion: "26.2", uiLanguageEnglish: true, locale: Self.us)
        XCTAssertEqual(caps.status(.hiddenChatSwitch), .untested)

        try Data("[{\"macOS\": \"26.2\", \"capability\": \"unsend\", \"releaseTest\": 1, \"passedAt\": 3}]".utf8)
            .write(to: url)
        XCTAssertTrue(CapabilityRegistry.loadEvidence(from: url).isEmpty, "a numeric date or missing field fails")
    }

    func testEvidenceSizeLimitBoundary() throws {
        let body = try CapabilityRegistry.evidenceEncoder().encode(records())
        func padded(to size: Int) throws -> URL {
            var data = body
            data.append(Data(repeating: UInt8(ascii: " "), count: size - body.count))
            let url = dir.appendingPathComponent("evidence-\(size).json")
            try data.write(to: url)
            return url
        }
        let limit = CapabilityRegistry.maxEvidenceBytes
        XCTAssertFalse(CapabilityRegistry.loadEvidence(from: try padded(to: limit)).isEmpty)
        XCTAssertTrue(CapabilityRegistry.loadEvidence(from: try padded(to: limit + 1)).isEmpty)
    }

    func testEvidenceRoundTripsWithISODates() throws {
        let record = EvidenceRecord(macOS: "26.2", capability: "unsend", releaseTest: 1,
                                    passedAt: Date(timeIntervalSince1970: 1_790_000_000), bridgeVersion: "1.0.0")
        let data = try CapabilityRegistry.evidenceEncoder().encode([record])
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"passedAt\" : \"2026-09-21T"))
        XCTAssertEqual(try CapabilityRegistry.evidenceDecoder().decode([EvidenceRecord].self, from: data), [record])
    }

    // MARK: - Report

    func testReportListsEveryRowWithTheForegroundNote() throws {
        let caps = try registry(records(except: ["edit"]))
        let off = caps.report(accessibilityTrusted: true, foregroundMode: false)
        XCTAssertEqual(off.entries.map(\.name), Capability.reported.map(\.name))
        XCTAssertEqual(off.macOSVersion, "26.2")
        XCTAssertTrue(off.uiLanguageEnglish)
        XCTAssertTrue(off.accessibilityTrusted)
        XCTAssertFalse(off.foregroundMode)
        let edit = off.entries.first { $0.name == "edit" }!
        XCTAssertEqual(edit, CapEntry(name: "edit", status: .untested, note: "foreground mode off"))
        XCTAssertEqual(off.entries.first { $0.name == "threaded-reply" }?.note, "foreground mode off")
        XCTAssertNil(off.entries.first { $0.name == "unsend" }?.note)

        let on = caps.report(accessibilityTrusted: false, foregroundMode: true)
        XCTAssertTrue(on.entries.allSatisfy { $0.note == nil })
        XCTAssertFalse(on.accessibilityTrusted)
    }

    func testNormalBuildIsNotAReleaseTestBuild() throws {
        XCTAssertFalse(CapabilityRegistry.isReleaseTestBuild)
        let caps = CapabilityRegistry(evidenceURL: dir.appendingPathComponent("none.json"), macOSVersion: "99.9",
                                      uiLanguageEnglish: true, locale: Self.us)
        XCTAssertEqual(caps.status(.unsend), .untested)
        let report = caps.report(accessibilityTrusted: true, foregroundMode: true)
        XCTAssertFalse(report.entries.contains { $0.note?.contains("release-test build") == true })
    }
    #else
    func testReleaseTestBuildSupportsEverythingOnAnyVersion() {
        XCTAssertTrue(CapabilityRegistry.isReleaseTestBuild)
        let caps = CapabilityRegistry(evidenceURL: dir.appendingPathComponent("none.json"), macOSVersion: "99.9",
                                      uiLanguageEnglish: false, locale: Self.us)
        for capability in Self.allCapabilities {
            XCTAssertEqual(caps.status(capability), .supported, capability.name)
        }
        let report = caps.report(accessibilityTrusted: true, foregroundMode: false)
        XCTAssertTrue(report.entries.allSatisfy { $0.status == .supported })
        XCTAssertTrue(report.entries.allSatisfy { $0.note?.hasPrefix("release-test build") == true })
        XCTAssertEqual(report.entries.first { $0.name == "edit" }?.note, "release-test build, foreground mode off")
    }
    #endif

    // MARK: - Helpers and threads

    func testMajorMinor() {
        XCTAssertEqual(CapabilityRegistry.majorMinor("26.2"), "26.2")
        XCTAssertEqual(CapabilityRegistry.majorMinor("26.2.1"), "26.2")
        XCTAssertEqual(CapabilityRegistry.majorMinor("26"), "26.0")
        XCTAssertEqual(CapabilityRegistry.majorMinor(" 15.7 "), "15.7")
        XCTAssertEqual(CapabilityRegistry.majorMinor("26.x"), "26.x")
        XCTAssertEqual(CapabilityRegistry.majorMinor("26.2.1.4"), "26.2.1.4")
    }

    func testCurrentMajorMinorHasTwoNumbers() {
        let parts = CapabilityRegistry.currentMajorMinor().split(separator: ".")
        XCTAssertEqual(parts.count, 2)
        XCTAssertTrue(parts.allSatisfy { Int($0) != nil })
    }

    func testEnglishDetection() {
        for id in ["en", "en-US", "en_GB", "EN-au", "en-Latn-US"] { XCTAssertTrue(CapabilityRegistry.isEnglish(id), id) }
        for id in ["fr-FR", "de", "eng", "", "zh-Hans-US"] { XCTAssertFalse(CapabilityRegistry.isEnglish(id), id) }
        XCTAssertFalse(CapabilityRegistry.isEnglish(nil))
    }

    func testStatusIsSafeFromSeveralConnections() throws {
        let caps = try registry(records(except: ["tapback.incoming"]))
        let lock = NSLock()
        var seen: [String: Set<CapStatus>] = [:]
        DispatchQueue.concurrentPerform(iterations: 400) { i in
            let capability = Self.allCapabilities[i % Self.allCapabilities.count]
            let status = caps.status(capability)
            lock.lock()
            seen["\(capability)", default: []].insert(status)
            lock.unlock()
        }
        XCTAssertTrue(seen.values.allSatisfy { $0.count == 1 }, "\(seen)")
    }
}
