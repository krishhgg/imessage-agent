import Foundation
import IMCore
@testable import IMPolicy
import IMTestSupport
import XCTest

/// Section 3 item 1: what goes into a key, and that nothing else does.
final class IdempotencyKeyTests: XCTestCase {
    private let text = TextNorm.textDigest("On my way")

    private func send(chat: CanonicalChatID = T.mom, threaded: Bool = false, parent: String? = nil,
                      text: String? = TextNorm.textDigest("On my way"), attachment: String? = nil) -> IdempotencyKey {
        .send(chat: chat, threaded: threaded, parentGUID: parent, textDigest: text, attachmentDigest: attachment)
    }

    private func ui(action: UIActionKind = .react, guid: String = "TARGET", part: Int = 0, remove: Bool = false,
                    tapback: TapbackKind? = .heart, newText: String? = nil) -> IdempotencyKey {
        .ui(action: action, targetGUID: guid, part: part, remove: remove, tapback: tapback, newTextDigest: newText)
    }

    func testSendKeyDependsOnEveryField() {
        let base = send()
        let variants = [
            send(chat: T.dad),
            send(threaded: true),
            send(threaded: true, parent: "PARENT"),
            send(parent: "PARENT"),
            send(text: TextNorm.textDigest("On my way!")),
            send(text: nil),
            send(attachment: "file-digest"),
        ]
        XCTAssertEqual(Set(variants.map(\.value) + [base.value]).count, variants.count + 1)
        XCTAssertEqual(send(), base)
        XCTAssertNil(base.targetSlot)
    }

    func testUIKeyDependsOnEveryField() {
        let base = ui()
        let variants = [
            ui(action: .unsend, tapback: nil),
            ui(action: .edit, tapback: nil, newText: text),
            ui(action: .edit, tapback: nil, newText: TextNorm.textDigest("other")),
            ui(guid: "OTHER"),
            ui(part: 1),
            ui(remove: true),
            ui(tapback: .like),
            ui(tapback: .emoji("🎉")),
            ui(tapback: .emoji("🔥")),
        ]
        XCTAssertEqual(Set(variants.map(\.value) + [base.value]).count, variants.count + 1)
        XCTAssertEqual(ui(), base)
    }

    func testUIKeysShareATargetSlotPerGUIDAndPart() {
        XCTAssertEqual(ui().targetSlot, "TARGET/0")
        XCTAssertEqual(ui(remove: true).targetSlot, "TARGET/0")
        XCTAssertEqual(ui(action: .unsend, tapback: nil).targetSlot, "TARGET/0")
        XCTAssertEqual(ui(part: 2).targetSlot, "TARGET/2")
    }

    func testKeysHoldOnlyADigest() throws {
        let key = send(text: TextNorm.textDigest("a secret plan"))
        XCTAssertEqual(key.value.count, 64)
        XCTAssertTrue(key.value.allSatisfy(\.isHexDigit))
        let json = String(decoding: try JSONEncoder.wire.encode(key), as: UTF8.self)
        XCTAssertFalse(json.contains("secret"))
        XCTAssertFalse(json.contains(T.mom.rawValue))
    }

    func testTrimmedAndDecomposedTextShareAKey() {
        XCTAssertEqual(send(text: TextNorm.textDigest("Caf\u{E9}")),
                       send(text: TextNorm.textDigest(" Cafe\u{301}\n")))
    }

    func testFieldEncodingIsUnambiguous() {
        XCTAssertNotEqual(IdempotencyKey.digest(["ab", "c"]), IdempotencyKey.digest(["a", "bc"]))
        XCTAssertNotEqual(IdempotencyKey.digest([nil]), IdempotencyKey.digest([""]))
        XCTAssertNotEqual(IdempotencyKey.digest([nil]), IdempotencyKey.digest(["-"]))
        XCTAssertNotEqual(IdempotencyKey.digest(["a;", "b"]), IdempotencyKey.digest(["a", ";b"]))
        XCTAssertNotEqual(IdempotencyKey.digest(["1:a;"]), IdempotencyKey.digest(["a"]))
        XCTAssertEqual(IdempotencyKey.digest(["x", nil]), IdempotencyKey.digest(["x", nil]))
    }
}
