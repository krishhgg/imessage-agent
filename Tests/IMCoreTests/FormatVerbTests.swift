import XCTest
@testable import IMCore
import IMTestSupport

/// Exact output of each verb on small hand-built records.
final class FormatVerbTests: XCTestCase {
    let ctx = B.ctx

    // MARK: chats

    func testChatLines() {
        let today = B.ns(2026, 11, 6, 0, 15)
        var unsent = B.msg(1, "x", at: today)
        unsent.unsent = true
        var photoOnly = B.msg(2, "", at: today)
        photoOnly.attachments = [B.photo()]
        var left = B.msg(3, "", at: today, from: "Dad")
        left.event = EventRecord(kind: .left, actorName: "Dad", itemType: 1, groupActionType: 0)
        let page = ChatsPage(chats: [
            B.chat(7, "Mom", last: B.msg(4, "hi", at: today)),
            B.chat(9, "Dad", unread: 1, last: B.msg(5, "call me", at: today, from: "Dad")),
            B.chat(12, "Desai Fam", group: true, name: "Desai Fam", members: ["Mom", "Dad", "Priya", "Arjun", "Meera"],
                   unread: 3, last: B.msg(6, String(repeating: "a", count: 61), from: "Priya")),
            B.chat(23, "Jordan Kim", last: unsent),
            B.chat(31, "Sam Lee", service: "RCS", last: photoOnly),
            B.chat(19, "group: Jordan, Taylor", group: true, members: ["Jordan", "Taylor"], last: left),
            B.chat(56, "+1 415-555-0199", service: "SMS"),
        ], hasMore: true, limit: 20)
        XCTAssertEqual(Format.chats(page, ctx), """
        7 Mom · 00:15 Mom: hi
        9 Dad · 00:15 Dad: call me (unread)
        12 Desai Fam (group: Mom, Dad, Priya, 2 more) 3 unread · Yesterday 18:02 Priya: \(String(repeating: "a", count: 60))…
        23 Jordan Kim · 00:15 Mom: (unsent)
        31 Sam Lee · 00:15 Mom: [photo] (RCS)
        19 group: Jordan, Taylor · 00:15 * Dad left the group
        56 +1 415-555-0199 (SMS)
        more: imessage chats -n 40

        """)
        XCTAssertEqual(Format.chats(ChatsPage(chats: [], hasMore: false, limit: 20), ctx), "no chats\n")
    }

    // MARK: unread

    func testUnreadBlockMarkers() {
        let entries = [
            UnreadEntry(message: B.msg(201, "context", at: B.ns(2026, 11, 4, 10, 0), me: true), isUnread: false, gapBefore: false),
            UnreadEntry(message: B.msg(202, "first"), isUnread: true, gapBefore: false),
            UnreadEntry(message: B.msg(203, "second", at: B.ns(2026, 11, 5, 18, 3)), isUnread: true, gapBefore: false),
            UnreadEntry(message: B.msg(210, "later", at: B.ns(2026, 11, 6, 0, 15)), isUnread: true, gapBefore: true),
        ]
        let page = UnreadPage(groups: [UnreadGroup(chat: B.chat(7, "Mom"), entries: entries, unreadCount: 3)], totalUnread: 3)
        XCTAssertEqual(Format.unread(page, ctx), """
        unread · 3 messages in 1 chat · times PST
        chat 7 Mom · 3 unread
        -- Wed Nov 4
        201 10:00 You: context
        -- Yesterday Thu Nov 5
        -- unread
        202 18:02 Mom: first
        203 18:03 Mom: second
        …
        -- Today Fri Nov 6
        -- unread
        210 00:15 Mom: later

        """)
        XCTAssertEqual(Format.unread(UnreadPage(groups: [], totalUnread: 0), ctx), "unread · 0 messages in 0 chats · times PST\n")
    }

    // MARK: read

    func testReadHeaderSeparatorsAndFooter() {
        let msgs = [B.msg(300, "a", at: B.ns(2026, 11, 4, 9, 0)), B.msg(301, "b"), B.msg(302, "c", me: true)]
        let page = MessagesPage(chat: B.chat(7, "Mom"), messages: msgs, totalVisible: 90, olderExists: true)
        XCTAssertEqual(Format.messages(page, ctx), """
        chat 7 Mom · 3 of 90 · times PST
        -- Wed Nov 4
        300 09:00 Mom: a
        -- Yesterday Thu Nov 5
        301 18:02 Mom: b
        302 18:02 You: c
        more: imessage read 7 --before 300

        """)
        let first = MessagesPage(chat: B.chat(7, "Mom"), messages: msgs, totalVisible: 3, olderExists: false)
        XCTAssertFalse(Format.messages(first, ctx).contains("more:"))
        let empty = MessagesPage(chat: B.chat(7, "Mom"), messages: [], totalVisible: 0, olderExists: true)
        XCTAssertEqual(Format.messages(empty, ctx), "chat 7 Mom · 0 of 0 · times PST\n")
        let group = MessagesPage(chat: B.chat(12, "Desai Fam", group: true, name: "Desai Fam", members: ["Mom", "Dad"]),
                                 messages: [], totalVisible: 0, olderExists: false)
        XCTAssertEqual(Format.messages(group, ctx), "chat 12 Desai Fam (group: Mom, Dad, You) · 0 of 0 · times PST\n")
    }

    func testReadHeaderOfAHandleWithNoChatYetNamesTheHandle() {
        let fresh = ChatRecord(rowid: 0, guid: "", identifier: "+14155550199",
                               canonical: .direct(handle: "+14155550199"), displayName: "",
                               label: "+1 (415) 555-0199", isGroup: false, memberNames: [], service: "iMessage",
                               unreadCount: 0, last: nil)
        let page = MessagesPage(chat: fresh, messages: [], totalVisible: 0, olderExists: false)
        XCTAssertEqual(Format.messages(page, ctx), "chat +14155550199 +1 (415) 555-0199 · 0 of 0 · times PST\n")
    }

    // MARK: show

    func detail(_ text: String, from: Int = 0, sender: String = "Mom") -> MessageDetail {
        MessageDetail(message: B.msg(100, text, from: sender), chat: B.mom, fromByte: from, totalBytes: text.utf8.count)
    }

    func testShowPrintsTheBodyAsIs() {
        XCTAssertEqual(Format.show(detail("line one\n\nline two"), ctx),
                       "100 Yesterday Thu Nov 5 18:02 in chat 7 Mom\nMom: line one\n\nline two\n")
        XCTAssertEqual(Format.show(detail("hi", sender: "Mo\nm"), ctx), "100 Yesterday Thu Nov 5 18:02 in chat 7 Mom\nMo / m: hi\n")
    }

    func testShowPagesAt8192Bytes() {
        let head = "100 Yesterday Thu Nov 5 18:02 in chat 7 Mom\nMom: "
        let exact = String(repeating: "a", count: 8192)
        XCTAssertEqual(Format.show(detail(exact), ctx), head + exact + "\n")
        XCTAssertEqual(Format.show(detail(exact + "b"), ctx), head + exact + "\n…(+1 bytes: imessage show 100 --from 8192)\n")
        let long = String(repeating: "a", count: 20_000)
        XCTAssertTrue(Format.show(detail(long), ctx).hasSuffix("\n…(+11,808 bytes: imessage show 100 --from 8192)\n"))
        XCTAssertEqual(Format.show(detail(long, from: 16_384), ctx), head + String(repeating: "a", count: 3616) + "\n")
    }

    func testShowNeverSplitsACharacter() {
        // "€" is 3 bytes at 8190...8192, so the page ends before it.
        let body = String(repeating: "a", count: 8190) + "€b"
        XCTAssertEqual(Format.show(detail(body), ctx),
                       "100 Yesterday Thu Nov 5 18:02 in chat 7 Mom\nMom: \(String(repeating: "a", count: 8190))"
                       + "\n…(+4 bytes: imessage show 100 --from 8190)\n")
        XCTAssertEqual(Format.show(detail(body, from: 8190), ctx), "100 Yesterday Thu Nov 5 18:02 in chat 7 Mom\nMom: €b\n")
        // A start inside a character moves forward to the next one.
        XCTAssertEqual(Format.show(detail(body, from: 8191), ctx), "100 Yesterday Thu Nov 5 18:02 in chat 7 Mom\nMom: b\n")
        XCTAssertEqual(Format.show(detail(body, from: 99_999), ctx), "100 Yesterday Thu Nov 5 18:02 in chat 7 Mom\nMom: \n")
        XCTAssertEqual(Format.show(detail("hi", from: -5), ctx), "100 Yesterday Thu Nov 5 18:02 in chat 7 Mom\nMom: hi\n")
        let emoji = String(repeating: "🎉", count: 3000) // 12,000 bytes of 4-byte scalars
        let out = Format.show(detail(emoji), ctx)
        XCTAssertTrue(out.hasSuffix("\n…(+3,808 bytes: imessage show 100 --from 8192)\n"))
        XCTAssertTrue(out.contains("Mom: " + String(repeating: "🎉", count: 2048) + "\n"))
    }

    // MARK: search

    func searchPage(_ hits: [SearchHit], in chat: ChatRef? = nil, query: String = "jalebi", next: String? = nil) -> SearchPage {
        SearchPage(query: query, inChat: chat, hits: hits, scannedBackToNs: B.ns(2025, 11, 6), windowStartNs: B.ns(2025, 11, 6),
                   nextCursor: next, budgetExhausted: false)
    }

    func testSearchLinesAndFooter() {
        let hits = [
            SearchHit(chat: B.family, message: B.msg(300, "Mom made jalebi today", chat: 12)),
            SearchHit(chat: B.mom, message: B.msg(299, "JALEBI!", at: B.ns(2026, 10, 30))),
        ]
        XCTAssertEqual(Format.search(searchPage(hits), ctx), """
        search "jalebi" · 2 hits, newest first · scanned back to Nov 6 2025
        12 Desai Fam · Yesterday 18:02 · 300 Mom: Mom made jalebi today
        7 Mom · Oct 30 · 299 Mom: JALEBI!

        """)
        let next = SearchCursor(dateNs: 5, rowid: 299, windowStartNs: 1).text
        XCTAssertEqual(Format.search(searchPage(Array(hits.prefix(1)), in: B.family, query: "it's here", next: next), ctx), """
        search "it's here" in Desai Fam · 1 hit, newest first · scanned back to Nov 6 2025
        12 Desai Fam · Yesterday 18:02 · 300 Mom: Mom made jalebi today
        more: imessage search --in 12 --cursor 5:299:1 'it'\\''s here'

        """)
        XCTAssertEqual(Format.search(searchPage([], next: next), ctx), """
        search "jalebi" · 0 hits, newest first · scanned back to Nov 6 2025
        more: imessage search --cursor 5:299:1 jalebi

        """)
        XCTAssertEqual(Format.search(searchPage([], query: "-1 day", next: next), ctx), """
        search "-1 day" · 0 hits, newest first · scanned back to Nov 6 2025
        more: imessage search --cursor 5:299:1 -- '-1 day'

        """, "a query that starts with - follows --, so the CLI doesn't read it as a flag")
    }

    func testSnippets() {
        func snip(_ body: String, _ q: String = "jalebi") -> String { Renderer.snippet(body, query: q) }
        let a = { (n: Int) in String(repeating: "a", count: n) }
        let b = { (n: Int) in String(repeating: "b", count: n) }
        XCTAssertEqual(snip("short jalebi"), "short jalebi")
        XCTAssertEqual(snip(a(120)), a(120))
        XCTAssertEqual(snip(a(121)), a(120) + "…")
        XCTAssertEqual(snip(a(200) + "jalebi" + b(200)), "…" + a(40) + "jalebi" + b(74) + "…")
        XCTAssertEqual(snip(a(10) + "jalebi" + b(200)), a(10) + "jalebi" + b(104) + "…")
        XCTAssertEqual(snip(a(300) + "jalebi"), "…" + a(40) + "jalebi")
        XCTAssertEqual(snip(a(200) + "JaLeBi" + b(200)), "…" + a(40) + "JaLeBi" + b(74) + "…")
        XCTAssertEqual(snip(a(200) + "É" + b(200), "é"), a(120) + "…", "case folding is ASCII only")
        XCTAssertEqual(snip(a(200) + "cafe\u{301}" + b(200), "café"), "…" + a(40) + "café" + b(76) + "…")
        XCTAssertEqual(snip(a(200) + "\n" + b(200), "b"), "…" + a(37) + " / " + b(80) + "…")
    }

    // MARK: who

    func testWho() {
        let meera = ContactRecord(shortName: "Mom", firstName: "Meera", lastName: "Desai", handles: [
            HandleRecord(id: "+14155550101", services: ["iMessage", "SMS", "iMessage"]),
            HandleRecord(id: "meera@example.com", services: []),
            HandleRecord(id: "+442079460123", services: ["SMS"]),
        ], chats: [B.mom, B.family])
        XCTAssertEqual(Format.who(ContactsPage(query: "Mom", contacts: [meera])),
                       "Mom = Meera Desai · +1 415-555-0101 (SMS, iMessage) · meera@example.com · +442079460123 (SMS)"
                       + " · chats: 7 (direct), 12 Desai Fam\n")
        XCTAssertEqual(Format.who(ContactsPage(query: "zz", contacts: [])), "error: no contact matches \"zz\" fix: imessage chats\n")
    }

    // MARK: att

    func testAttachmentExport() {
        let heic = AttachmentRecord(rowid: 9904, guid: "g", kind: .photo, transferName: "IMG_4420.HEIC",
                                    totalBytes: 1_900_000, width: 4032, height: 3024)
        let path = "/Users/x/Library/Caches/io.github.krishhgg.imessage-agent/attachments/9904.jpg"
        XCTAssertEqual(Format.attachment(AttachmentExport(attachment: heic, path: path, converted: true, result: nil)),
                       "a9904 photo IMG_4420.HEIC 1.9MB 4032x3024 -> \(path) (1600px)\n")
        let pdf = AttachmentRecord(rowid: 9902, guid: "g", kind: .file, transferName: "menu.pdf", totalBytes: 348_000)
        XCTAssertEqual(Format.attachment(AttachmentExport(attachment: pdf, path: "/c/9902.pdf", converted: false, result: nil)),
                       "a9902 file menu.pdf 348KB -> /c/9902.pdf\n")
        XCTAssertEqual(Format.attachment(AttachmentExport(attachment: heic, path: nil, converted: false,
                                                          result: ActionResult(.notDownloaded))),
                       "a9904 photo IMG_4420.HEIC · not_downloaded\n")
        XCTAssertEqual(Format.attachment(AttachmentExport(attachment: heic, path: nil, converted: false,
                                                          result: ActionResult(.error(.message("no attachment a9904"))))),
                       "error: no attachment a9904\n")
        XCTAssertEqual(Format.attachment(AttachmentExport(attachment: heic, path: nil, converted: false, result: nil)),
                       "error: no viewable copy of a9904\n")
        XCTAssertFalse(Format.attachment(AttachmentExport(attachment: heic, path: path, converted: true, result: nil))
            .contains("/tmp/imessage"))
    }

    // MARK: send

    func send(_ parts: [SendPartOutcome], text: String? = "On my way", approved: Bool = false, early: ActionResult? = nil,
              thread: Int64? = nil, replayed: Bool = false) -> String {
        Format.send(SendOutcome(chat: B.mom, approved: approved, early: early, text: text, threadParentRowID: thread,
                                parts: parts, replayed: replayed), ctx)
    }

    func testSendLines() {
        let delivered = ActionResult(.delivered)
        XCTAssertEqual(send([SendPartOutcome(part: .text, result: delivered, rowid: 41600)], approved: true),
                       "approved\nsent 41600 to Mom \"On my way\" · delivered\n")
        XCTAssertEqual(send([SendPartOutcome(part: .text, result: ActionResult(.submitted, notes: [.chatUnconfirmed]),
                                             rowid: 41600)], text: "ok", thread: 41418),
                       "sent 41600 to Mom ↩41418 \"ok\" · submitted, chat unconfirmed\n")
        XCTAssertEqual(send([SendPartOutcome(part: .text, result: delivered, rowid: 41600),
                             SendPartOutcome(part: .file, result: delivered, rowid: 41601, attachment: B.photo())], text: "hi"),
                       "sent 41600,41601 to Mom \"hi\" [photo a9901 2.2MB] · delivered\n")
        XCTAssertEqual(send([SendPartOutcome(part: .text, result: delivered, rowid: 41600),
                             SendPartOutcome(part: .file, result: ActionResult(.failed(.transferFailed)), rowid: 41601)],
                            text: "hi"),
                       "sent 41600 to Mom \"hi\" · delivered\nsent 41601 to Mom [file] · failed transfer_state 6\n")
        XCTAssertEqual(send([SendPartOutcome(part: .text, result: ActionResult(.failed(.messagesNotReady)))]),
                       "send to Mom \"On my way\" · failed: Messages not ready\n")
        XCTAssertEqual(send([SendPartOutcome(part: .text, result: delivered, rowid: 41600)], text: "two\nlines"),
                       "sent 41600 to Mom \"two / lines\" · delivered\n")
        let long = String(repeating: "x", count: 401)
        XCTAssertEqual(send([SendPartOutcome(part: .text, result: delivered, rowid: 1)], text: long),
                       "sent 1 to Mom \"\(String(repeating: "x", count: 400))…\" · delivered\n")
    }

    func testSendEarlyAndReplay() {
        XCTAssertEqual(send([], early: .messagesOpen), "busy: Messages is open fix: hide Messages (⌘H) and retry\n")
        XCTAssertEqual(send([], early: ActionResult(.pending(id: "ab12"))), "pending ab12\n")
        XCTAssertEqual(send([], early: ActionResult(.mayHaveCompleted), replayed: true), "may_have_completed (repeat)\n")
        XCTAssertEqual(send([]), "may_have_completed\n")
        XCTAssertEqual(send([SendPartOutcome(part: .text, result: ActionResult(.delivered), rowid: 41600)], replayed: true),
                       "sent 41600 to Mom \"On my way\" · delivered (repeat)\n")
        XCTAssertEqual(send([SendPartOutcome(part: .text, result: .journalWriteFailed)], approved: true),
                       "approved\nerror: journal write failed fix: free disk space and retry\n")
    }

    func testRepeatNoteSitsBeforeFix() {
        let ghost = ActionResult(.ghost, notes: [.chatUnconfirmed], fix: "imessage read 7")
        XCTAssertEqual(send([], early: ghost, replayed: true), "ghost, chat unconfirmed (repeat) fix: imessage read 7\n")
        XCTAssertEqual(send([SendPartOutcome(part: .text, result: ghost, rowid: 41600)], replayed: true),
                       "sent 41600 to Mom \"On my way\" · ghost, chat unconfirmed (repeat) fix: imessage read 7\n")
        let ok = ActionResult(.ok, fix: "imessage read 12")
        XCTAssertEqual(ui(.react, ok, replayed: true, now: .laugh),
                       "reacted ❤️ to 41418 in chat 12 · ok (repeat, now 😂) fix: imessage read 12\n")
        XCTAssertEqual(ui(.unsend, ok, tapback: nil, replayed: true), "unsent 41418 in chat 12 · ok (repeat) fix: imessage read 12\n")
    }

    // MARK: react, unsend, edit

    func ui(_ action: UIActionKind, _ result: ActionResult, tapback: TapbackKind? = .heart, remove: Bool = false,
            quote: ReplyRef? = nil, replayed: Bool = false, now: TapbackKind? = nil, approved: Bool = false) -> String {
        Format.ui(UIOutcome(action: action, targetRowID: 41418, chat: B.family, tapback: tapback, remove: remove,
                            approved: approved, result: result, currentReaction: now, replayed: replayed,
                            targetQuote: quote), ctx)
    }

    func testUILines() {
        let quote = ReplyRef(rowid: 41418, senderName: "Mom", text: "Dinner at 8?")
        XCTAssertEqual(ui(.react, ActionResult(.ok), quote: quote), "reacted ❤️ to 41418 (Mom: Dinner at 8?) in chat 12 · ok\n")
        XCTAssertEqual(ui(.react, ActionResult(.ok), remove: true), "removed ❤️ from 41418 in chat 12 · ok\n")
        XCTAssertEqual(ui(.react, ActionResult(.busy(.userActive)), tapback: .emoji("🎉")),
                       "react 🎉 to 41418 in chat 12 · busy: user active\n")
        XCTAssertEqual(ui(.react, ActionResult(.ok), replayed: true, now: .laugh),
                       "reacted ❤️ to 41418 in chat 12 · ok (repeat, now 😂)\n")
        XCTAssertEqual(ui(.react, ActionResult(.ok), replayed: true), "reacted ❤️ to 41418 in chat 12 · ok (repeat, now none)\n")
        XCTAssertEqual(ui(.unsend, ActionResult(.ok), tapback: nil, approved: true), "approved\nunsent 41418 in chat 12 · ok\n")
        XCTAssertEqual(ui(.unsend, ActionResult(.ok), tapback: nil, replayed: true), "unsent 41418 in chat 12 · ok (repeat)\n")
        XCTAssertEqual(ui(.edit, ActionResult(.untested), tapback: nil), "edit 41418 in chat 12 · untested\n")
        XCTAssertEqual(ui(.edit, .foregroundModeOff, tapback: nil), "error: foreground mode is off fix: imessage allow --foreground\n")
        let long = ReplyRef(rowid: 41418, senderName: "Mom", text: String(repeating: "q", count: 31))
        XCTAssertEqual(ui(.react, ActionResult(.ok), quote: long),
                       "reacted ❤️ to 41418 (Mom: \(String(repeating: "q", count: 30))…) in chat 12 · ok\n")
    }

    // MARK: allow, revoke, pending

    func testPolicyLines() {
        func p(_ c: PolicyChange, _ r: ActionResult = ActionResult(.ok), scope: AllowScope? = nil) -> String {
            Format.policy(PolicyOutcome(change: c, chat: c == .allowChat || c == .revokeChat ? B.mom : nil, scope: scope, result: r))
        }
        XCTAssertEqual(p(.allowChat, scope: .files), "allow 7 Mom (files) · ok\n")
        XCTAssertEqual(p(.allowChat), "allow 7 Mom (text) · ok\n")
        XCTAssertEqual(p(.allowChat, ActionResult(.denied(.user))), "allow 7 Mom (text) · denied\n")
        XCTAssertEqual(p(.revokeChat), "revoke 7 Mom · ok\n")
        XCTAssertEqual(p(.foregroundOn), "allow --foreground · ok\n")
        XCTAssertEqual(p(.foregroundOff), "revoke --foreground · ok\n")
        XCTAssertEqual(p(.allowChat, ActionResult(.error(.message("no chat matches \"x\"")))), "error: no chat matches \"x\"\n")
        let fresh = ChatRef(rowid: 0, label: "+1 (415) 555-0199", isGroup: false)
        XCTAssertEqual(Format.policy(PolicyOutcome(change: .allowChat, chat: fresh, scope: .text, result: ActionResult(.ok))),
                       "allow +1 (415) 555-0199 (text) · ok\n", "a handle with no chat yet has no chat number")
        XCTAssertEqual(Format.policy(PolicyOutcome(change: .revokeChat, chat: fresh, scope: nil, result: ActionResult(.ok))),
                       "revoke +1 (415) 555-0199 · ok\n")
    }

    func testPending() {
        let item = PendingItem(id: "ab12", summary: "send to Mom \"On my way\"", createdAt: B.date(2026, 11, 6, 0, 20),
                               expiresAt: B.date(2026, 11, 6, 0, 30))
        XCTAssertEqual(Format.pending(PendingList(items: [item]), ctx),
                       "pending · 1 open approval\nab12 send to Mom \"On my way\" · asked 00:20 · expires 00:30\n")
        XCTAssertEqual(Format.pending(PendingList(items: []), ctx), "pending · 0 open approvals\n")
    }

    // MARK: changes, wait

    func testChangesLines() {
        var edited = B.msg(41500, "new text", from: "Dad", chat: 12)
        edited.edited = true
        let page = ChangesPage(cursor: "41601:815646000000000000", changes: [
            ChangeRecord(kind: .new, chat: B.mom, message: B.msg(41601, "hi", at: B.ns(2026, 11, 6, 0, 20))),
            ChangeRecord(kind: .edited, chat: B.family, message: edited),
        ], truncated: false)
        XCTAssertEqual(Format.changes(page, ctx), """
        changes · 2 changes · times PST
        -- Today Fri Nov 6
        new 7 Mom · 41601 00:20 Mom: hi
        -- Yesterday Thu Nov 5
        edited 12 Desai Fam · 41500 18:02 Dad: new text (edited)
        cursor 41601:815646000000000000

        """)
        var truncated = page
        truncated.truncated = true
        XCTAssertTrue(Format.changes(truncated, ctx).hasSuffix("\nmore: imessage changes --since 41601:815646000000000000\n"))
        XCTAssertEqual(Format.changes(ChangesPage(cursor: "9:9", changes: [], truncated: false), ctx),
                       "changes · 0 changes · times PST\ncursor 9:9\n")
    }

    func testWait() {
        XCTAssertEqual(Format.wait(WaitOutcome(chat: nil, message: nil, timedOut: true), ctx), "timeout\n")
        XCTAssertEqual(Format.wait(WaitOutcome(chat: B.mom, message: nil, timedOut: false), ctx), "timeout\n")
        XCTAssertEqual(Format.wait(WaitOutcome(chat: B.mom, message: B.msg(41600, "hi"), timedOut: false), ctx),
                       "chat 7 Mom · 41600 18:02 Mom: hi\n")
        XCTAssertEqual(Format.wait(WaitOutcome(chat: nil, message: B.msg(41600, "hi"), timedOut: false), ctx),
                       "41600 18:02 Mom: hi\n")
    }

    // MARK: caps, status, setup, doctor, pong

    func testCaps() {
        let r = CapsReport(macOSVersion: "26.2", uiLanguageEnglish: true, accessibilityTrusted: false, foregroundMode: false,
                           entries: [CapEntry(name: "react", status: .supported),
                                     CapEntry(name: "edit", status: .untested, note: "release-test build")])
        XCTAssertEqual(Format.caps(r), """
        caps · macOS 26.2 · release-test build · Accessibility off · foreground mode off
        react supported
        edit untested (release-test build)

        """)
        let fr = CapsReport(macOSVersion: "26.2", uiLanguageEnglish: false, accessibilityTrusted: true, foregroundMode: true,
                            entries: [CapEntry(name: "react", status: .unsupported, note: "UI language")])
        XCTAssertEqual(Format.caps(fr), """
        caps · macOS 26.2 · UI language isn't English, UI actions unsupported · Accessibility on · foreground mode on
        react unsupported (UI language)

        """)
    }

    func testStatus() {
        var r = StatusReport(bridgeVersion: "0.1.0", pid: 4242, fullDiskAccess: .granted, automation: .notDetermined,
                             accessibility: .denied, messagesRunning: false, foregroundMode: false,
                             foregroundOffReason: "Accessibility is off", allowlistTrusted: true, allowedChats: 1,
                             openApprovals: 0, crashNote: nil)
        XCTAssertEqual(Format.status(r), """
        status · bridge 0.1.0 pid 4242
        Full Disk Access granted
        Automation not determined
        Accessibility denied
        Messages not running
        foreground mode off: Accessibility is off
        allowlist 1 chat
        approvals 0 open

        """)
        r.allowlistTrusted = false
        r.foregroundMode = true
        r.messagesRunning = true
        r.accessibility = .unknown
        r.crashNote = "Messages left open after a crash"
        XCTAssertEqual(Format.status(r), """
        status · bridge 0.1.0 pid 4242
        Full Disk Access granted
        Automation not determined
        Accessibility unknown
        Messages running
        foreground mode on
        allowlist failed its check, nothing is allowed until chats are approved again
        approvals 0 open
        crash: Messages left open after a crash

        """)
    }

    func testSetupAndDoctor() {
        XCTAssertEqual(Format.setup(SetupReport(stage: .fullDiskAccess, state: .denied,
                                                openedPane: "Privacy & Security > Full Disk Access")),
                       "setup Full Disk Access: denied · opened Privacy & Security > Full Disk Access\n")
        XCTAssertEqual(Format.setup(SetupReport(stage: .automation, state: .granted, openedPane: nil)), "setup Automation: granted\n")
        XCTAssertEqual(Format.setup(SetupReport(stage: .accessibility, state: .notDetermined, openedPane: nil)),
                       "setup Accessibility: not determined\n")
        let r = DoctorReport(checks: [
            DoctorCheck(name: "chat.db", ok: true, detail: "readable", fix: "not shown when ok"),
            DoctorCheck(name: "automation", ok: false, detail: "not determined", fix: "imessage setup automation"),
            DoctorCheck(name: "socket", ok: false),
        ], needsKickstart: true, releaseTestBuild: true)
        XCTAssertEqual(Format.doctor(r), """
        doctor · 3 checks, 2 failing · release-test build
        ok chat.db: readable
        fail automation: not determined fix: imessage setup automation
        fail socket
        kickstart needed: the bridge can't open chat.db yet

        """)
        XCTAssertEqual(Format.doctor(DoctorReport(checks: [DoctorCheck(name: "x", ok: true)], needsKickstart: false)),
                       "doctor · 1 check, 0 failing\nok x\n")
    }

    // MARK: errors

    func testErrorLines() {
        let twelve = (0..<12).map { Candidate(label: "Jordan \($0)", argument: "\($0)") }
        let e = WireError(result: ActionResult(.error(.severalMatches), fix: "pass a chat id"), candidates: twelve)
        let listed = (0..<10).map { "Jordan \($0) (\($0))" }.joined(separator: ", ")
        XCTAssertEqual(Format.error(e), "error: several matches: \(listed), 2 more fix: pass a chat id\n")
        let ten = WireError(result: ActionResult(.error(.severalMatches)), candidates: Array(twelve.prefix(10)))
        XCTAssertEqual(Format.error(ten), "error: several matches: \(listed)\n")
        XCTAssertEqual(Format.error(.message("bad\nthing", fix: "x\r\ny")), "error: bad / thing fix: x / y\n")
        XCTAssertEqual(Format.error(WireError(result: .badRequest)),
                       "error: bad request fix: retry, and run imessage doctor if it happens again\n")
        XCTAssertEqual(Format.error(WireError(result: ActionResult(.busy(.queue)))), "busy: queue\n")
        XCTAssertEqual(Format.render(.pong(PongInfo(bridgeVersion: "0.1.0", pid: 7)), ctx), "pong · bridge 0.1.0 pid 7\n")
    }
}
