# Build plan for imessage-agent

This plan splits DESIGN.md v5.4 into Swift modules that can be built in parallel. Doc comments on public types and functions cite the DESIGN.md section they implement.

Names: repo `imessage-agent`, CLI `imessage`, bridge app "iMessage Agent", bundle id and LaunchAgent label `io.github.krishhgg.imessage-agent`. The constants live in `Sources/IMCore/Identity.swift`.

## Module graph

```
IMCore <- IMStore <- IMPolicy, IMSend, IMUI <- IMForeground <- IMBridge <- IMessageAgent (app executable)
IMCore <- imessage (CLI executable)
IMCore <- IMTestSupport (test-only fakes and fixture paths)
```

- IMPolicy, IMSend and IMUI are siblings. None of them imports another. When one needs something the other provides, the protocol lives in IMCore or IMStore and IMBridge wires the live object in.
- The CLI imports IMCore only. It never links SQLite, AppKit or ApplicationServices.
- Only system frameworks: Foundation, AppKit, ApplicationServices, CoreGraphics, SQLite3 (`libsqlite3`), ImageIO, Security, CryptoKit. No Contacts framework: AddressBook source databases are read with SQLite like chat.db (section 1, SQLite hardening).
- Swift tools 6.0, language mode 5, macOS 14 deployment target.

## Rules for every module owner

- Edit only your owner files, your test target and new files inside your own `Sources/<Module>/` and `Tests/<Module>Tests/` folders. A change to another module's public API needs that owner's agreement first. The contracts at the end of this plan list who owns what.
- Replace stubs in place. Keep the public signatures unless the contract owner agrees to a change.
- Tests never send Apple Events, never launch or touch Messages, never open the real `~/Library/Messages/chat.db` or a TCC database, and never post HID events. They use `Tests/Fixtures/chat.db` and the fakes.
- Prose in comments and docs is plain and direct, with sentence-case headings and no em dashes.
- Use your own scratch path, so parallel builds don't fight over `.build`.
- `Package.swift` belongs to the IMCore owner. Ask that owner for a new target, dependency or linker setting. Test data goes under `Tests/Fixtures/`, which is outside every target, so it never needs a resources entry.

Commands, with `<m>` as the lowercase module name (`imcore`, `imstore`, `impolicy`, `imsend`, `imui`, `imforeground`, `imbridge`, `cli`):

```
swift build --target <Module> --scratch-path .build-<m>
swift build --target <Module>Tests --scratch-path .build-<m>
swift test --filter <Module>Tests --scratch-path .build-<m>
```

`swift build --target <Module>Tests` compiles only that test target and its dependencies, so it's the fast check. `swift test` always links one test bundle for the whole package, so it compiles every module and every test target even with `--filter`, and `--skip-build` doesn't help unless the whole bundle was built. If another module doesn't compile at that moment, your `swift test` fails for a reason outside your module. Keep your module compiling at every save, and when the failure is in someone else's files, wait and retry or work in your own git worktree with its own scratch path. The full check is:

```
swift build --scratch-path .build-skeleton
swift test --scratch-path .build-skeleton
```

## Shared test support

`Tests/IMTestSupport` is a library target that only test targets depend on. It exists so the IMCore fakes aren't copied into eight test targets. The IMCore owner owns it. Other modules add fakes for their own protocols inside their own test targets.

- `Fixture.swift`: paths to `Tests/Fixtures/chat.db`, `contacts.json`, `contacts-firstname.json`, `manifest.json`, `Attachments/` and `golden/` (`Fixture.goldenDir`). Fixture "now" is `815646600000000000` Apple-epoch nanoseconds (2026-11-06 00:30 America/Los_Angeles). Owner handles are `+14155550100` and `alex@example.com`.
- `Fakes.swift`: `FakeClock` (sleep advances time), `FakeMessagesApp` (scripted `MessagesAppState`, records calls; `onCall` runs after each control call, `onState` on every `state()` read and `onFrontmost` on every `frontmostApp()` read, so a test can change the state as `FakeClock.uptime` moves), `FakeAppleScriptRunner` (records handler calls, returns queued outcomes), `FakeInvocationRecorder` (records facts, can throw from `willInvoke`), `FakePendingTransfers`.

`Tests/Fixtures/README.md` and `manifest.json` describe every chat, edge case, body, tapback net state and benchmark answer the fixture holds. `Tests/Fixtures/build.sh` rebuilds it reproducibly. Store and format tests assert against `manifest.json`, not against hand-copied numbers.

## IMCore

Shared vocabulary, wire protocol, rendering and protocols. No AppKit, no SQLite.

Owner files:
- `Sources/IMCore/Identity.swift`
- `Sources/IMCore/Paths.swift`
- `Sources/IMCore/Limits.swift`
- `Sources/IMCore/TextNorm.swift`
- `Sources/IMCore/Results.swift`
- `Sources/IMCore/Records.swift`
- `Sources/IMCore/Pages.swift`
- `Sources/IMCore/Wire.swift`
- `Sources/IMCore/Protocols.swift`
- `Sources/IMCore/TimeSpec.swift`
- `Sources/IMCore/Format.swift`
- `Tests/IMCoreTests/`, `Tests/IMTestSupport/`, `Tests/Fixtures/golden/`
- `Package.swift`

DESIGN sections: 1 (named operations, socket path), 3 item 6 (result strings), 5 (verbs, output format), plus every number in sections 1 to 5.

Rule checklist:
- [ ] Socket path is 104 bytes or less with its terminating NUL. Fall back to `~/.imessage-agent/bridge.sock` when the app-support path is too long. The LaunchAgent plist and the CLI use the same resolved path.
- [ ] Frames are a 4-byte big-endian length plus UTF-8 JSON, at most 8 MiB. Upload bytes follow the request frame raw, at most 100 MB.
- [ ] `FrameChannel` handles short reads and writes, `EINTR`, and the `SO_RCVTIMEO`/`SO_SNDTIMEO` timeouts.
- [ ] Every result string comes from `Results.swift`. `ActionResult.holdsIdempotencyKey` matches section 3 item 1 exactly: `submitted`, `delivered`, `failed <error>`, `ghost`, `ambiguous: two rows matched`, `may_have_completed`, `ok`, `failed: sent with wrong parent`, `denied`, and any result with the agent-text note. `denied: approval expired` doesn't hold it.
- [ ] `TimeSpec` accepts `30m`, `12h`, `7d`, `2w`, `today`, `yesterday`, `YYYY-MM-DD` and `YYYY-MM-DDTHH:MM` in the given time zone.
- [ ] Each message renders as one line: `<rowid> <HH:MM> <Sender>: [↩<rowid>] <text> [attachments] [(edited)|(unsent)] [reactions]`.
- [ ] Every list has a header line, day separators split it, and a footer gives the next page. A `read` page from `--after` or `--around` that stops short of the newest message (`MessagesPage.newerExists`) also ends with `more: imessage read <chat> --after <newest shown>`, counted in the cap.
- [ ] Attachments render as `[photo a9901 2.2MB]`. Group events, polls, stickers and locations render as short events.
- [ ] Bodies are cut at 400 characters with a `show` pointer. `show` pages at 8 KB.
- [ ] Every call's output is at most 200 lines and about 12 KB, with a footer for the rest.
- [ ] Errors are one line: `error: <message> fix: <fix>`, with one space before `fix:` as `ActionResult.rendered` writes it. `--json` gives NDJSON.
- [ ] `TextNorm.textDigest(text)` is `TextNorm.digest(TextNorm.matchKey(text))`, NFC plus trimming. Every text digest anyone stores or binds uses it (see the behavior contracts below).
- [ ] The success output of `chats`, `unread`, `read`, `show` and `who` equals `bench/renderers/ours.py` byte for byte on the fixture. The golden files are captured once from `ours.py` with `python3 -I` into `Tests/Fixtures/golden/`, and the capture command is recorded next to them. One exception: `ours.py` prints no footer for newer messages, so a `--after` or `--around` case whose chat has newer rows expects the golden text plus the `--after` footer (`Golden.expectedText`).
- [ ] The `search` footer is `more: imessage search [--in <chat>] --cursor C <query>`, flags first, with `--` before a query that starts with `-`, so the CLI parses the suggested command. A query at the 500-scalar cap still prints hits and an exact footer within 12 KB.
- [ ] For `search`, `send`, `react`, `unsend`, `edit`, `att` and every error line, DESIGN.md and `Results.swift` win over `ours.py`, and their expectations are written by hand. `ours.py` differs in these places: `react` ends in `· verified` (DESIGN: `ok`), `send` prints `delivered HH:MM` (DESIGN: `delivered`), an offloaded file is an `error:` line (DESIGN: `not_downloaded`), several matches print `error: "x" matches 2 contacts: …` (DESIGN: `error: several matches` plus candidates), errors use `. fix:`, `att` prints `/tmp/imessage/…` instead of the cache path, and `search` uses a ROWID cursor and never says how far back it scanned.

Public interfaces: `AppIdentity`, `Paths`, `Limits`, `AppleTime`, `TextNorm`, `ActionResult` and its reason enums, `ResultCode`, `ResultNote`, the record structs (`MessageRecord`, `ChatRecord`, `CanonicalChatID`, `TapbackKind` and the rest), the page structs, `Op`, `RequestBody`, `Request`, `Response`, `ResponsePayload`, `BridgeEvent`, `ServerFrame`, `FrameCodec`, `FrameChannel`, `TimeSpec`, `Format`, `FormatContext`, and the protocols `Clock`, `MessagesAppControl`, `AppleScriptRunning`, `InvocationRecorder`, `PendingTransferChecking`.

Fakes its tests use: `FakeClock`. Format tests build records by hand or decode them from JSON in `Tests/Fixtures/golden/`. They don't need IMStore.

Commands:
```
swift build --target IMCore --scratch-path .build-imcore
swift build --target IMCoreTests --scratch-path .build-imcore
swift test --filter IMCoreTests --scratch-path .build-imcore
```

## IMStore

Read-only access to chat.db and the AddressBook databases. Decoding, folding, search, attachments, and the read interfaces the modules above it use.

Owner files:
- `Sources/IMStore/SQLite.swift`
- `Sources/IMStore/TypedStream.swift`
- `Sources/IMStore/Contacts.swift`
- `Sources/IMStore/ChatDatabase.swift`
- `Sources/IMStore/ReadService.swift`
- `Sources/IMStore/Attachments.swift`
- `Sources/IMStore/ConsumerProtocols.swift`
- `Tests/IMStoreTests/`

DESIGN sections: 1 (named ops, `attachment`, SQLite hardening, search), 5 (target resolution, `unread`, `read`, `show`, `search`, `who`, `att`, `wait`, `changes`), 7.

Rule checklist:
- [ ] Open chat.db and the AddressBook source databases with `mode=ro` URIs, at hard-coded paths only. Nothing from the socket becomes a path or SQL.
- [ ] `SQLITE_LIMIT_ATTACHED` is 0. Extension loading is off.
- [ ] The authorizer allows only SELECT, READ and `SQLiteConnection.allowedFunctions`. It denies ATTACH, PRAGMA writes and `load_extension`.
- [ ] Every query uses fixed SQL with bound parameters and a row cap.
- [ ] Interactive reads stop after 2 s and return a timeout error. Search runs on its own budget (5 s, `Limits.searchBudget`).
- [ ] Decode `attributedBody` typedstream when `text` is NULL. 93% of fixture rows need it.
- [ ] Fold tapbacks into net state per actor and part, for both `p:N/<guid>` and `bp:<guid>` targets. The result matches `manifest.json` `tapback_net_state`.
- [ ] Decode `message_summary_info` (`ec` edit history, `rp` retracted parts, `otr`) for `(edited)`, `(unsent)` and `(part unsent)`.
- [ ] Apply the visibility rules in `ReadService`'s doc comment: folded tapbacks and stickers, self-chat echo drop, URL balloon merge, Recently Deleted skip.
- [ ] Target resolution accepts a name, phone, email, chat id or chat number. A contact's iMessage and SMS chats are one conversation. More than one match throws `StoreError.severalMatches` with candidates, and nothing runs. A phone or email with no chat is a new direct target (entry 26 below).
- [ ] `resolve(canonical:)` rebuilds a `ResolvedChat` from a `CanonicalChatID` (crash reconciliation), and `resolve(chatRowID:)` from a chat.db chat (UI actions that name a message). Both return nil when chat.db no longer has the chat. `sendTarget(canonical:)` also covers a `handle:` ID with no chat yet (entry 36 below).
- [ ] `search` uses a `text LIKE ?` or `ci_contains(attributedBody, ?)` prefilter, confirms the match on the decoded body, and returns hits newest first inside a 1-year default window. Each page reports how far back it scanned and returns a cursor. There is no persistent index.
- [ ] `ci_contains` folds ASCII case and searches for the needle in both NFC and NFD.
- [ ] `changes` returns rows above the cursor ROWID plus rows with date_edited, date_read or date_delivered after the cursor time. With no `since` it returns the cursor and no rows. It keeps no state.
- [ ] `wait` skips rows in `agentSentGUIDs` and their self-chat echoes. `changes` never lists those rows as new and drops their echoes, but reports a later delivery, read, edit or unsend of a bridge send (section 3 item 5: "`changes` reports later deliveries").
- [ ] `attachment` resolves the path with realpath and refuses anything outside the Attachments root. It copies the file into the 0700 cache. `export(_:convertHEIC:)` converts HEIC to JPEG with the long side at most 1600 px only when `convertHEIC` is true; IMBridge sets it from the capability registry. Cache entries expire after 24 h. An offloaded file returns `not_downloaded`.
- [ ] `ConsumerProtocols.swift` implementations return what each consumer documents: correlation probes for IMSend, signatures, reaction rows and `newestIncoming(for:)` (the full `MessageTargetInfo`, not just a GUID) for IMUI and IMForeground, inbound rows with `bodyDigest = TextNorm.textDigest(body)` for IMPolicy.

Public interfaces: `SQLiteConnection`, `StoreError`, `DatabaseProbe`, `TypedStreamDecoder`, `SummaryInfo`, `LinkMetadataDecoder`, `ContactsSource` (`AddressBookContacts`, `JSONContacts`), `ContactBook`, `HandleNormalizer`, `StoreConfiguration`, `ChatDatabase`, `ResolvedChat`, `ReadService`, `TapbackFolder`, `CaseInsensitiveContains`, `AttachmentService`, `HEICConverter`, and the consumer protocols `SendRowSource`, `UITargetSource`, `ChatActivitySource`.

Fakes its tests use: `Fixture`, `FakeClock`, `JSONContacts(url: Fixture.contactsJSON)`. `StoreConfiguration` points at `Fixture.chatDB` and `Fixture.attachmentsRoot`, with a temp cache directory and the Los Angeles time zone.

Commands:
```
swift build --target IMStore --scratch-path .build-imstore
swift build --target IMStoreTests --scratch-path .build-imstore
swift test --filter IMStoreTests --scratch-path .build-imstore
```

## IMPolicy

The allowlist store, approvals, rate limits, the journal and the action queue.

Owner files:
- `Sources/IMPolicy/PolicyStore.swift`
- `Sources/IMPolicy/Approvals.swift`
- `Sources/IMPolicy/RateLimiter.swift`
- `Sources/IMPolicy/Journal.swift`
- `Sources/IMPolicy/ActionQueue.swift`
- `Sources/IMPolicy/PolicyEngine.swift`
- `Tests/IMPolicyTests/`

DESIGN sections: 2 (all of it), 3 items 1 to 3.

Rule checklist:
- [ ] The policy file is mode 0600 and written atomically with fsync. Its SHA-256 lives in a Keychain item the bridge created, whose access list names only the bridge's designated requirement.
- [ ] A mismatched, missing or unreadable file or hash means nothing is allowed and foreground mode is off until the user re-approves. A first run with neither is trusted and empty.
- [ ] Each allowlist entry has scope `text` (text and tapbacks) or `files` (adds attachments). "Always allow" grants the approved action's scope.
- [ ] Unsend, edit and threaded reply always ask, and their dialog has no "Always allow". `allow`, `revoke`, `allow --foreground` and `revoke --foreground` always go through the dialog.
- [ ] An approval binds the canonical chat, the action, the text digest, the frozen attachment digest, the target GUID and part, or the parent GUID. It is single use and expires after 10 minutes.
- [ ] Deny is the default button. The allow buttons have no keyboard shortcut and stay disabled for 1 s. The panel itself is IMBridge's; IMPolicy only defines `ApprovalPresenting`.
- [ ] The CLI waits 120 s, then gets the result, `denied` or `pending <id>`. `pending <id>` collects the result later. An approval unanswered for 10 minutes gives `denied: approval expired`.
- [ ] Rate limits are 1 send per 20 s per chat, 30 per chat per day and 100 per day, plus at most 3 consecutive agent sends with no inbound message in between. Echo rows never count as inbound: an inbound row whose GUID equals a `SendEvent.guid` is an echo, and in a self-chat so is one whose `bodyDigest` equals a `SendEvent.textDigest` for the same chat (entry 34 below). A breach turns the send into one that asks.
- [ ] Idempotency keys use a sliding 10-minute window. For a send the key is the chat, plain or threaded, the parent GUID, the text digest and the attachment digest. For a UI action it is the action, the target GUID and part, set or remove, and the tapback kind or new-text digest. A later final key on the same target and part supersedes an earlier one only if its result holds the key (entry 33 below). `--again` skips the lookup, never the dialog, except that a same-key entry at `invoking` or `invoked` still gives `may_have_completed` (entry 44 below).
- [ ] The lookup returns the replayed first result for a held key. It returns `pending <id>` while waiting for approval or before `invoking`, and `may_have_completed` at `invoking` or `invoked`. A repeated tapback key whose first result was `ok` re-reads the current reaction instead.
- [ ] The journal records `received`, `approved`, `invoking` (fsynced before the action), `invoked` and `final`. It stores no message text and keeps records 7 days.
- [ ] `begin(key:action:chat:binding:)` stores the `ApprovalBinding` on the entry. With `InvocationFacts` (snapshot ROWID, target GUID, part and ROWID, transfer names, date_edited before) it is everything `ReconcileAdapter` needs.
- [ ] Crash recovery turns `received` or `approved` into `failed: bridge restarted`, which doesn't hold the key. `invoking` or `invoked` is reconciled from chat.db for up to 10 s, else `may_have_completed`, and holds the key. The GUIDs of the rows `reconcileRows` matched go in `JournalEntry.sentGUIDs`, so `agentSentGUIDs()` and `sendEvents()` still see a reconciled send.
- [ ] `JournalEntry.foreground` is set by IMBridge with `markForeground(id, true)` right before `ForegroundMachine.run`, and `finish` clears it. `recoverAfterCrash` returns true for any non-final entry with `foreground` set, whatever its state, so a crash after activation but before the first press still turns foreground mode off.
- [ ] One FIFO queue, taken after approval, released when the journal records `final`. A request waits 30 s in all, then gets `busy: queue`.

Public interfaces: `PolicyStore`, `PolicyState`, `AllowlistEntry`, `PolicyLoad`, `TamperReason`, `KeychainHashStoring` (`LiveKeychainHashStore`), `ForegroundModeSwitching`, `MutationKind`, `ApprovalBinding`, `ApprovalPrompt`, `ApprovalDecision`, `ApprovalPresenting`, `ApprovalStatus`, `ApprovalBook`, `RateLimiter`, `SendEvent`, `RateLimitBreach`, `IdempotencyKey`, `JournalState`, `JournalEntry`, `KeyLookup`, `JournalReconciling`, `Reconciliation`, `Journal`, `ActionQueueing` (`ActionQueue`), `QueueTicket`, `MutationRequest`, `PolicyDecision`, `PolicyEngine`.

Fakes its tests use: `FakeClock`, plus fakes in `Tests/IMPolicyTests/`: an in-memory `KeychainHashStoring`, an `ApprovalPresenting` that answers on cue, a `ChatActivitySource` returning scripted inbound rows, and a `JournalReconciling` returning scripted results. The journal and store write into a temp directory.

Commands:
```
swift build --target IMPolicy --scratch-path .build-impolicy
swift build --target IMPolicyTests --scratch-path .build-impolicy
swift test --filter IMPolicyTests --scratch-path .build-impolicy
```

## IMSend

Apple Event sends, cold start, upload freezing, staging and correlation.

Owner files:
- `Sources/IMSend/Scripts.swift`
- `Sources/IMSend/ColdStart.swift`
- `Sources/IMSend/Staging.swift`
- `Sources/IMSend/Correlation.swift`
- `Sources/IMSend/MessageSender.swift`
- `Tests/IMSendTests/`

DESIGN sections: 3 items 4 to 8, the section 4 window rules for cold launch.

Rule checklist:
- [ ] One compiled script. Handlers get their arguments as Apple Event descriptors, never by source interpolation. Calls run on the main thread.
- [ ] The AppleScript result is never trusted as a send result.
- [ ] Cold start launches Messages with `open -g -j -b com.apple.MobileSMS` through `MessagesAppControl`. It waits up to 60 s for `account_ready`, else returns `failed: Messages not ready`. After a launch it polls visibility for 1 s and adds `error: Messages became visible` if a window showed.
- [ ] Freeze the upload while it arrives. Refuse more than 100 MB or a byte count that disagrees with the header. Hash the bytes with SHA-256 and never open the caller's path.
- [ ] Stage into `~/Pictures/iMessage Agent/` under a unique name that becomes the `transfer_name`. Never stage in `/private/var/tmp/com.apple.messages/`.
- [ ] Delete a staged copy when its transfer_state reaches 5, or 10 minutes after staging, including copies from an earlier run.
- [ ] Before sending, record the max ROWID, then call `recorder.willInvoke`. If that throws, send nothing.
- [ ] Correlate only from_me rows above the snapshot, for the recipient's handle (for a group, whose rows have no handle, a join row naming one of the group's chats), dated at or after the request. Text rows match on the NFC, trimmed body (`PartExpectation.text`) or on its `TextNorm.textDigest` (`PartExpectation.textDigest`, for reconciliation and the foreground verifier); file rows match on `transfer_name`.
- [ ] Wait up to 10 s. On delivered or failed, wait up to 1 s more for the join row and return. Otherwise return `submitted` at 10 s.
- [ ] No match is `may_have_completed`, or `ghost` if an empty unjoined from_me SMS row appeared. Two candidates are `ambiguous: two rows matched`. A missing join row at return adds `chat unconfirmed`. A 1:1 row joined to another conversation's chat never matches (entry 32 below).
- [ ] A nonzero `error` is `failed <error>`. transfer_state 6 is `failed transfer_state 6` when `error` is 0. SMS stays `submitted`.
- [ ] Text and file parts get separate results.
- [ ] Group sends return `unsupported` with no Apple Event while `caps` reports them `untested` (section 3 item 8). IMBridge's `groupSend` gate is the only refusal. Once it passes, `MessageSender` calls `send_chat_text` and `send_chat_file` with the group's chat guid.

Public interfaces: `SendScripts`, `NSAppleScriptRunner` (live `AppleScriptRunning`), `ColdStarter`, `ColdStartResult`, `UploadFreezer`, `FrozenFile`, `UploadError`, `StagingArea` (live `PendingTransferChecking`), `StagedFile`, `SendSnapshot`, `PartExpectation`, `PartCorrelation`, `SendCorrelator`, `SendRequest`, `SendResult`, `MessageSender`.

Fakes its tests use: `FakeClock`, `FakeMessagesApp`, `FakeAppleScriptRunner`, `FakeInvocationRecorder`, and a scripted `SendRowSource` in `Tests/IMSendTests/` that adds rows as the fake clock advances. That covers the join-row lag, a late `date_delivered`, error 25, transfer_state 6, ghost rows and two matching rows. `NSAppleScriptRunner` isn't run in tests. The placeholder test checks the script source declares every `ScriptHandler`.

Commands:
```
swift build --target IMSend --scratch-path .build-imsend
swift build --target IMSendTests --scratch-path .build-imsend
swift test --filter IMSendTests --scratch-path .build-imsend
```

## IMUI

Hidden UI actions: the window rules, AX access, targeting, tapbacks, unsend and capabilities.

Owner files:
- `Sources/IMUI/AX.swift`
- `Sources/IMUI/MessagesApp.swift`
- `Sources/IMUI/WindowRules.swift`
- `Sources/IMUI/Targeting.swift`
- `Sources/IMUI/Actions.swift`
- `Sources/IMUI/Capabilities.swift`
- `Tests/IMUITests/`

DESIGN sections: 4 (design rule, window rules, targeting, tapback semantics, unsend, capabilities and evidence), 2 (Undo Send window checks).

Rule checklist:
- [ ] Not running: launch with `open -g -j -b`. Frontmost, a window that isn't hidden, or hidden with more than one window (the larger of the AX count and the real windows on every Space): `busy: Messages is open`, with the ⌘H fix when a window is showing.
- [ ] No window and not frontmost: while holding the queue, and after no staged file is waiting, quit through Apple Events, wait 10 s, then relaunch hidden. Messages not exiting, or not exactly one hidden window 10 s after the relaunch, gives `no_hidden_window`.
- [ ] Never use Window > Messages or `imessage://`. Never hide the user's window or switch the user's chat.
- [ ] After each hidden action, cold launch and relaunch, poll `isHidden` and the on-screen window list for 1 s and add `error: Messages became visible` if a window showed.
- [ ] Use only named AX actions, plus value writes in foreground mode. No arbitrary AX paths, no other apps, no System Events.
- [ ] Every AX press and write takes a final check (`AXFinalCheck`, entry 50) that `LiveMessagesAX` runs after its own reads, on the line right before the AX call. A hidden bubble action's check runs the window rules recheck, then the caller's check.
- [ ] Group chats return `unsupported_target` with no press. A chat with no text rows returns `not_loaded`.
- [ ] Before any press, build the expected row description and the signature (5 newest text rows by direction and body). A duplicate description, or a duplicate signature cut to the target signature's length, in any other conversation means no press and `ambiguous`.
- [ ] Press a row only if exactly one loaded row's full description matches. No match is `not_loaded`, several are `ambiguous`. No prefix matching, no scrolling.
- [ ] After the press, the newest loaded text bubbles must equal the signature, otherwise `error: wrong chat`.
- [ ] A bubble matches on direction, NFC text and minute. More than one loaded match, or another chat.db message with the same direction, body and minute on any day, gives `ambiguous`. Only single-part text (`p:0`) is targeted; others give `unsupported_target`.
- [ ] Tapbacks read the current reaction first and return `already` when nothing would change. After the press, wait 10 s for the verifying row (2000 to 2006 add, 3000 to 3006 remove): `ok`, else `may_have_completed`.
- [ ] Unsend checks the 2-minute window from the row date after approval, on leaving the queue, before `willInvoke`, and again as the press's final check, after `willInvoke`, the window recheck and the driver's own reads. Closed there is `expired` with no press, and the entry never reaches `invoked`. It waits 10 s for date_edited set and an empty body: `ok`, else `may_have_completed`.
- [ ] A missing action name at run time is `unsupported` with no press, or `expired` if the window closed.
- [ ] Results after a press say the chat may have been marked read.
- [ ] `caps` reports `supported` only with a release-evidence record for the running macOS major.minor. Without one, UI actions are `untested` and off. On a non-English UI language they are unsupported. Tapbacks on incoming messages stay off until release test 2's consenting-sender case passes.
- [ ] A capability is supported only if every one of its `Capability.prerequisites` is. Every UI action needs `.hiddenChatSwitch` (test 1) and `.targeting` (test 3). Edit and threaded reply also need `.foregroundMode` (tests 5 and 6b). `.imageSend`, `.attachmentConversion` and `.groupSend` (test 8) each turn off only their own part.

Public interfaces: `AXRef`, `ConversationRowInfo`, `BubbleInfo`, `FieldInfo`, `MenuItemInfo`, `ThreadViewInfo`, `MessagesAXDriving` (`LiveMessagesAX`), `AXTrust`, `LiveMessagesApp` (live `MessagesAppControl`), `WindowDecision`, `WindowRules`, `VisibilityCheck`, `HiddenWindowManager`, `ExpectedRow`, `RowDescriptionBuilder`, `ChatSelection`, `BubbleLookup`, `ChatTargeting` (`ChatTargeter`), `SelectionExpectation`, `UINames`, `UIActionResult`, `TapbackRequest`, `TapbackRunner`, `UnsendRunner`, `ActionWindows`, `Capability`, `EvidenceRecord`, `CapabilityRegistry`, `UIResults.unsupportedTarget` (IMBridge refuses the same targets before the dialog), `UIResults.accessibilityMissing` (IMBridge returns it before the dialog when `accessibility(prompt: false)` isn't granted, and `HiddenWindowManager.prepare` returns it on `notTrusted` before it launches or quits Messages).

Fakes its tests use: `FakeClock`, `FakeMessagesApp` (`onState` scripts the 1 s `isHidden` poll and the single hidden window within 10 s of a relaunch), `FakePendingTransfers`, `FakeInvocationRecorder`, and in `Tests/IMUITests/` a scripted `MessagesAXDriving` (rows, bubbles, action names, presses recorded) and a `UITargetSource` fake. `RowDescriptionBuilder` and the duplicate checks can also run against the real fixture through `ChatDatabase`. `LiveMessagesAX` and `LiveMessagesApp` aren't run in tests.

Commands:
```
swift build --target IMUI --scratch-path .build-imui
swift build --target IMUITests --scratch-path .build-imui
swift test --filter IMUITests --scratch-path .build-imui
```

## IMForeground

Foreground mode for edit and threaded reply, steps 1 to 7 of section 4.

Owner files:
- `Sources/IMForeground/Input.swift`
- `Sources/IMForeground/Keys.swift`
- `Sources/IMForeground/Verifier.swift`
- `Sources/IMForeground/ForegroundMachine.swift`
- `Tests/IMForegroundTests/`

DESIGN sections: 4 (foreground mode, ownership check, steps 1 to 7), 2 (edit window checks), 3 item 2 (crash during a foreground action).

Rule checklist:
- [ ] Step 2, the idle gate, runs first: no key, flags, mouse button or scroll event for 2 s, read from `hidSystemState`. It waits 30 s, then returns `busy: user active`. The queue isn't held while waiting, and the queue's 30 s start when the machine first asks for it, so time at the idle gate doesn't count against `ForegroundRun.queueDeadline`.
- [ ] Step 1, after taking the queue: Messages hidden, chat selected and checked, composer empty (`busy: draft in Messages`), no edit field or thread view (`busy: edit in progress`), parent unchanged (`newestIncoming(for:)?.guid` equals the bound `parent.guid`, else `aborted: parent changed`), bubble and Edit action or menu item present (`unsupported`). While hidden the menu item may read `Reply to Message…` (S3), which step 1 accepts. After `t_front` only the exact `Reply to Last Message…` item is waited for and pressed, and `UINames.lookupOnlyMenuTitles` are never pressed.
- [ ] Step 3, the activation check: input in the last 2 s means release the queue, return to the idle gate and repeat step 1's checks, all inside the 30 s. The earlier front app is read before this check, so nothing is read between it and `open -b`. Then `open -b`.
- [ ] Record `t_front` when Messages becomes frontmost, from the first front-state read that shows it while `open` runs (entry 46 below). If that doesn't happen within 1 s, post nothing and watch 5 s more. The outcome is `aborted: late activation`, a takeover if input arrived, or `aborted: activation`.
- [ ] Call `recorder.willInvoke` before the first press after `t_front`.
- [ ] Post Return within 3 s of `t_front`, otherwise `aborted: deadline`.
- [ ] Run the ownership check before every AX action, attribute write, key event, the hide and the focus restore. The first failure goes to the takeover path, even mid-cleanup. The check reads the frontmost app first, with `MessagesAppControl.isFrontmost()` (NSWorkspace only, no AX read), and samples input last, so input during the read still counts. For an AX press or write it runs again as the driver's final check, after the driver's own reads (entry 50).
- [ ] Step 4, right before Return: ownership holds, the deadline holds, and the edit window is still open (`expired`). The view still matches: the thread view's parent bubble has the bound parent's direction, NFC body and minute (from `ForegroundAction.threadedReply(parent:text:)`) and the newest incoming GUID is unchanged, or the edit field belongs to the bound bubble and the other bubbles match the signature. The field holds exactly the intended text. For edit, step 1 reads the signature and bound row (`ChatTargeting.selectionExpectation`), and after `t_front` the bubble lookup and the signature check read AX only (`findLoadedBubble`, `verifySelected(_:)`), so no chat.db call sits between `t_front` and Return except the journal write and a reply's parent reread. The last steps before Return run in this order: the focused-field read, for a reply the thread view's parent and then the newest incoming GUID read again (`aborted: parent changed`), the deadline, for an edit the 15-minute window, then the ownership check, then the key post (entry 50).
- [ ] The reply writes the text field AX reports focused in the thread view (`MessagesAXDriving.focusedField()`), never the main composer from step 1, and the main composer still holds its step 1 value before Return. Return is posted only while the written field still has focus (otherwise `aborted: field`). Focus is never set.
- [ ] Takeover: no more key events, no hide, no focus change. Make at most one AX write, resetting the field only if it still holds exactly the bridge's text. The result is `aborted: user took over` plus the AX state, and says the agent's text may remain when it does.
- [ ] Bridge-owned failure: restore the field and press Escape at most 3 times until no edit field or thread view shows. If one still shows, stop, add `Messages left in edit mode` and turn foreground mode off.
- [ ] Step 6, finish: press Escape (at most 3) until the main transcript shows, then hide and poll `isHidden` for 1 s. Reopen the earlier app with `open -b` unless it has no windows, and wait 2 s. Add `Messages left open` or the name of the app in front when those happen.
- [ ] Step 7, verify: for an edit, date_edited is later and the body matches; for a reply, the correlated row has the bound `thread_originator_guid`. Wait 10 s. A wrong or missing parent is `failed: sent with wrong parent <guid|none>` and turns foreground mode off. `ForegroundVerifying` takes `TextNorm.textDigest` values, not text, so IMBridge's crash reconciliation calls the same code.
- [ ] The machine never writes the journal's `foreground` flag; IMBridge sets it before `run`.
- [ ] Only the native dialog turns foreground mode back on.

Public interfaces: `InputMonitoring` (`HIDInputMonitor`), `ForegroundKey`, `KeyPosting` (`PidKeyPoster`), `ForegroundVerifying` (`LiveForegroundVerifier`), `ForegroundAction`, `ForegroundPhase`, `ForegroundEnvironment`, `ForegroundRun`, `ForegroundOutcome`, `OwnershipGuard`, `ForegroundMachine`.

Fakes its tests use: `FakeClock`, `FakeMessagesApp` (`onState` and `onFrontmost` script `t_front` within 1 s, Messages coming forward inside the 5 s watch, the 1 s hide poll and the 2 s focus-restore wait against `FakeClock.uptime`), `FakeInvocationRecorder`, plus fakes in `Tests/IMForegroundTests/`: an `InputMonitoring` with input injected at chosen phases, a recording `KeyPosting`, a scripted `MessagesAXDriving`, `ChatTargeting`, `ForegroundVerifying`, `ActionQueueing` and `ForegroundModeSwitching`. Release test 5's injection points (before the field is set, during restore, between Escapes, before the hide, before focus restore) are unit tests here first.

Commands:
```
swift build --target IMForeground --scratch-path .build-imforeground
swift build --target IMForegroundTests --scratch-path .build-imforeground
swift test --filter IMForegroundTests --scratch-path .build-imforeground
```

## IMBridge and IMessageAgent

The bridge process: launchd socket, request dispatch, the mutation pipeline, the approval panel, setup, status and doctor, and the live wiring.

Owner files:
- `Sources/IMBridge/BridgeMain.swift`
- `Sources/IMBridge/LaunchActivation.swift`
- `Sources/IMBridge/SocketServer.swift`
- `Sources/IMBridge/Dispatch.swift`
- `Sources/IMBridge/ApprovalPanel.swift`
- `Sources/IMBridge/Services.swift`
- `Sources/IMBridge/Container.swift`
- `Sources/IMessageAgent/main.swift`
- `Tests/IMBridgeTests/`

DESIGN sections: 1 (TCC contract, named ops, residency), 2 (dialog), 3 items 1 to 3 (order of journal, queue and approval), 5 (`setup`, `doctor`, `status`), the install flow steps 4 and 5.

Rule checklist:
- [ ] Adopt the socket with `launch_activate_socket("Listener")` before `NSApplicationMain`. A launch outside launchd kickstarts the job and exits.
- [ ] Use activation policy `.accessory` (LSUIElement). Stay resident while an approval or connection is open.
- [ ] Refuse a peer whose `getpeereid` uid isn't the bridge's uid.
- [ ] Only named ops cross the socket, with typed arguments and no SQL, paths or AX expressions.
- [ ] Run the pipeline order in `MutationPipeline`'s doc comment. Claim the key with `Journal.claim`, which journals `received` before the dialog, then `approved` after, `final` with every result, early ones included.
- [ ] On the 120 s approval timeout, return `pending <id>` and keep the request running in the background.
- [ ] Reject `send --thread --file`. Reject a foreground action while foreground mode is off.
- [ ] Hidden actions and sends take the queue in the pipeline. Foreground actions don't; the machine takes it after its idle gate.
- [ ] Before serving, run journal crash recovery through `ReconcileAdapter`, which reads chat.db only and works from `entry.binding` and `entry.facts` as its doc comment maps them. A foreground crash turns foreground mode off and sets the crash note for `doctor`.
- [ ] Call `journal.markForeground(id, true)` right before `ForegroundMachine.run`. `finish` clears it.
- [ ] Resolve a UI action's chat with `ChatDatabase.resolve(chatRowID:)`. For `send --thread`, read the parent with `newestIncoming(for:)`, bind its GUID, show its body in the dialog and pass it to `ForegroundAction.threadedReply(parent:text:)`.
- [ ] A file part with a correlated row gets `SendPartOutcome.attachment` from chat.db, so the result prints `[photo a9901 2.2MB]`.
- [ ] An image file send (ImageIO recognizes the frozen bytes as an image) returns `unsupported` and sends nothing while `.imageSend` isn't `supported`. `att` calls `export(_:convertHEIC:)` with `convertHEIC` true only while `.attachmentConversion` is `supported`.
- [ ] Every TCC check and the Full Disk Access pane go through `BridgeContainer.permissions` (`PermissionProbing`). `openStoreIfNeeded` opens `BridgeContainer.store.chatDBPath`. Tests inject a recording `PermissionProbing` and a fixture `StoreConfiguration`, so no test raises a prompt, opens System Settings or opens the real chat.db.
- [ ] Retry opening chat.db on each read request, so a Full Disk Access grant takes effect without a restart.
- [ ] `status` and `doctor` check permissions silently. `setup` raises one prompt or opens the FDA pane and returns at once. The CLI raises doctor's prompts with `setup` stages after any kickstart.
- [ ] `doctor` reports `needsKickstart` only if chat.db still can't be opened. It re-checks the action names visible on a loaded bubble and reports why foreground mode turned off.
- [ ] The approval panel is a floating, non-activating NSPanel. Deny is the default button. The allow buttons have no key equivalent and stay disabled for 1 s. "Always allow" is hidden for always-ask actions. A threaded reply shows the parent's text.
- [ ] Seed `ChatDatabase.agentSentGUIDs` and the rate limiter history from the journal at start.
- [ ] Timers sweep staging, purge the attachment cache, prune the journal and expire approvals.

Public interfaces: `BridgeMain`, `LaunchActivation`, `UploadReading`, `RequestHandling`, `SocketServer`, `OpDispatcher`, `MutationPipeline`, `ApprovalPanelController` (live `ApprovalPresenting`), `PermissionProbing` (`LivePermissionProbe`), `StatusService`, `SetupService`, `DoctorService`, `BridgeContainer`, `ReconcileAdapter` (live `JournalReconciling`).

Fakes its tests use: everything from IMTestSupport, the fixture `ChatDatabase`, and fakes for `ApprovalPresenting`, `KeychainHashStoring`, `MessagesAXDriving`, `ActionQueueing` and `PermissionProbing`. Tests build `BridgeContainer` with its memberwise init and call `OpDispatcher.handle` directly. Socket tests use `socketpair`, never the launchd socket. The golden-output test lives here because it needs IMStore and IMCore together: it renders `ReadService` pages for `chats`, `unread`, `read`, `show` and `who` over the fixture with `Format` and compares them with the text in `Tests/Fixtures/golden/`.

Commands:
```
swift build --target IMBridge --scratch-path .build-imbridge
swift build --target IMessageAgent --scratch-path .build-imbridge
swift build --target IMBridgeTests --scratch-path .build-imbridge
swift test --filter IMBridgeTests --scratch-path .build-imbridge
```

## imessage CLI

The unprivileged client. It parses arguments, streams file bytes, renders records and runs the setup and doctor flows. Its types are internal so the test target uses `@testable import imessage`.

Owner files:
- `Sources/imessage/main.swift`
- `Sources/imessage/Command.swift`
- `Sources/imessage/BridgeClient.swift`
- `Sources/imessage/Flows.swift`
- `Tests/imessageCLITests/`

DESIGN sections: 5, 3 item 7 (streaming), the install flow steps 4 and 5.

Rule checklist:
- [ ] Every verb and flag in the section 5 table parses. `show --from` comes from `ours.py`. `--json` is accepted anywhere.
- [ ] `send` needs text unless `--file` is given. `--thread` with `--file` is a usage error before any connection.
- [ ] Reject a file over 100 MB before connecting. Stream the bytes; the bridge never gets the caller's path.
- [ ] Refuse the socket unless its owner uid is ours.
- [ ] Events go to stderr. Stdout holds only the rendered result or NDJSON.
- [ ] `setup` sends the FDA stage and returns at once. `doctor [--ui]` runs `launchctl kickstart -k gui/<uid>/io.github.krishhgg.imessage-agent` once if the bridge says it needs it, then raises the Automation prompt, and Accessibility when `--ui` is given.
- [ ] `DoctorFlow.run` takes the kickstart as a `kickstart: () -> Bool` parameter. `CLI.execute` passes `DoctorFlow.liveKickstart`; tests pass a recording closure, so no test restarts an installed bridge.
- [ ] Exit codes are 0 for success, 1 for `error:` lines and failed actions, 2 for usage errors and 3 when the bridge is unreachable.

Public interfaces: none outside the module. Internal: `Command`, `Invocation`, `UsageError`, `ArgumentParser`, `ExitCode`, `ClientError`, `BridgeClient`, `UploadSource`, `SetupFlow`, `DoctorFlow`, `Output`, `CLI`.

Fakes its tests use: `Fixture` and `FakeClock` for `TimeSpec` cases. `BridgeClient` tests run a tiny in-test server on a `socketpair` or a temp-dir socket, using `FrameChannel`.

Commands:
```
swift build --target imessage --scratch-path .build-cli
swift build --target imessageCLITests --scratch-path .build-cli
swift test --filter imessageCLITests --scratch-path .build-cli
```

## Cross-module contracts

| Contract | Declared in | Live implementation | Consumers |
| --- | --- | --- | --- |
| `Clock` | IMCore `Protocols.swift` | `SystemClock` (IMCore) | every module |
| `MessagesAppControl` | IMCore `Protocols.swift` | `LiveMessagesApp` (IMUI) | IMSend cold start, IMUI window rules, IMForeground |
| `AppleScriptRunning` | IMCore `Protocols.swift` | `NSAppleScriptRunner` (IMSend) | IMSend, `LiveMessagesApp.quit` |
| `InvocationRecorder` | IMCore `Protocols.swift` | `Journal.recorder(for:)` (IMPolicy) | IMSend, IMUI, IMForeground |
| `PendingTransferChecking` | IMCore `Protocols.swift` | `StagingArea` (IMSend) | IMUI `HiddenWindowManager` |
| Wire protocol, `ActionResult`, records, pages | IMCore `Wire.swift`, `Results.swift`, `Records.swift`, `Pages.swift` | IMCore | IMBridge, CLI, every module that returns results |
| `SendRowSource` | IMStore `ConsumerProtocols.swift` | `ChatDatabase` | IMSend, IMForeground |
| `UITargetSource` | IMStore `ConsumerProtocols.swift` | `ChatDatabase` | IMUI, IMForeground, IMBridge |
| `ChatActivitySource` | IMStore `ConsumerProtocols.swift` | `ChatDatabase` | IMPolicy `RateLimiter` |
| `ApprovalPresenting` | IMPolicy `Approvals.swift` | `ApprovalPanelController` (IMBridge) | IMPolicy `ApprovalBook` |
| `KeychainHashStoring` | IMPolicy `PolicyStore.swift` | `LiveKeychainHashStore` (IMPolicy) | IMPolicy `PolicyStore` |
| `ForegroundModeSwitching` | IMPolicy `PolicyStore.swift` | `PolicyStore` | IMForeground, IMBridge |
| `ActionQueueing` | IMPolicy `ActionQueue.swift` | `ActionQueue` | IMBridge, IMForeground |
| `JournalReconciling` | IMPolicy `Journal.swift` | `ReconcileAdapter` (IMBridge) | IMPolicy `Journal.recoverAfterCrash` |
| `MessagesAXDriving`, `ChatTargeting`, `HiddenWindowManager` | IMUI | `LiveMessagesAX`, `ChatTargeter` | IMForeground |
| `SendCorrelator` | IMSend `Correlation.swift` | itself | IMForeground verifier, IMBridge reconcile |
| `InputMonitoring`, `KeyPosting`, `ForegroundVerifying` | IMForeground | `HIDInputMonitor`, `PidKeyPoster`, `LiveForegroundVerifier` | IMForeground; `ForegroundVerifying` also IMBridge reconcile |
| `PermissionProbing` | IMBridge `Services.swift` | `LivePermissionProbe` | `StatusService`, `SetupService`, `DoctorService` |
| `RequestHandling` | IMBridge `SocketServer.swift` | `OpDispatcher` | `SocketServer` |

Behavior contracts that cross modules:
- `willInvoke` is called and returns before the Apple Event, the AX press or the Return that performs the action. If it throws, the caller performs nothing and returns `error: journal write failed`.
- Every caller treats the AppleScript return value as advisory and correlates in chat.db.
- `Journal.finish` strips message text from the stored response before writing.
- IMBridge adds every GUID in `SendResult.sentGUIDs` and `ForegroundOutcome.sentGUID` to `ChatDatabase.agentSentGUIDs`, and records each send that reached `invoking` with `RateLimiter.record`. After crash recovery it adds `Journal.agentSentGUIDs()`, which includes the rows reconciliation matched.
- A foreground action returns holding the queue ticket in `ForegroundOutcome.ticket`. IMBridge releases it after the journal records `final`.
- Window-rule busy results come back to the pipeline as `ActionResult` values, never as thrown errors, so the journal records them as `final` and they don't hold the key.
- `StoreError.severalMatches` becomes `error: several matches` with the candidates on the wire.
- Error lines more than one module returns come from IMCore `Results.swift`: `ActionResult.journalWriteFailed`, `.foregroundModeOff`, `.threadWithFile` and `.badRequest`, each with its fix. IMSend, IMUI, IMForeground and IMPolicy return those values. `MessageSender.badRequest` (no part or no handle) is a different cause with its own fix.
- Every text digest anyone stores or binds is `TextNorm.textDigest(text)`, which is `TextNorm.digest(TextNorm.matchKey(text))`: `ApprovalBinding.textDigest`, the idempotency key's text digest, `SendEvent.textDigest` and `InboundRow.bodyDigest`. `SentRowProbe.body` and `EditStateProbe.body` are already `matchKey` values, so `TextNorm.textDigest(probe.body)` compares with a stored digest directly.
- Crash reconciliation works from `JournalEntry.binding` and `JournalEntry.facts` alone. `JournalReconciling.reconcile` gets `deadline` as an absolute `Clock.uptime` value, not a duration. Anyone who calls `willInvoke` fills the facts the `ReconcileAdapter` doc comment lists for that action: the snapshot ROWID always, the target GUID, part and ROWID for tapbacks, unsend and edit, date_edited before for edit, and the transfer names for file sends.
- `ForegroundAction.threadedReply` carries the parent `MessageTargetInfo` IMBridge read for the approval, so the machine compares the thread view with it and never looks a GUID up again.

## Packaging

Owner: packaging. Signing material never enters the repo.

Owner files:
- `scripts/build.sh`
- `packaging/Info.plist`
- `packaging/entitlements.plist`
- `packaging/io.github.krishhgg.imessage-agent.plist` (LaunchAgent template)
- `install.sh`
- `INSTALL.md`
- `README.md`
- `skill/imessage/SKILL.md`
- `skill/imessage/reference.md`

### scripts/build.sh

- Builds `IMessageAgent` and `imessage` in release mode for arm64 and x86_64 with `swift build -c release --arch arm64 --arch x86_64 --scratch-path .build-release`. If the toolchain can't do both arches in one call, it builds each arch into its own scratch path and joins them with `lipo -create`. It checks the result with `lipo -archs`.
- Assembles `out/iMessage Agent.app/Contents/{MacOS/IMessageAgent,Info.plist,Resources/release-evidence.json}`. There are no embedded frameworks.
- Info.plist sets `CFBundleIdentifier` to `io.github.krishhgg.imessage-agent`, `CFBundleName` and `CFBundleDisplayName` to "iMessage Agent", `CFBundleExecutable` to `IMessageAgent`, `CFBundleShortVersionString` from `AppIdentity.version`, `LSUIElement` true, `LSMultipleInstancesProhibited` true, `LSMinimumSystemVersion` 14.0, `NSAppleEventsUsageDescription` and `NSAccessibilityUsageDescription`.
- Entitlements contain only `com.apple.security.automation.apple-events`. No `get-task-allow`, `allow-dyld-environment-variables` or `disable-library-validation`.
- Signing reads `SIGN_IDENTITY`, `SIGN_KEYCHAIN` and `SIGN_KEYCHAIN_PW_FILE` from the environment. If any is unset or the identity isn't in that keychain, the script exits nonzero and builds nothing unsigned. It unlocks the keychain from the password file, adds it to the user search list for the signing step, and restores the old search list in a `trap` on exit.
- It signs the app with `codesign --force --options runtime --timestamp=none --keychain "$SIGN_KEYCHAIN" --sign "$SIGN_IDENTITY" --entitlements packaging/entitlements.plist --identifier io.github.krishhgg.imessage-agent`. It signs the CLI with the same identity, the runtime option and the identifier `io.github.krishhgg.imessage-agent.cli`.
- It checks the result with `codesign --verify --strict --deep` and `codesign -d --entitlements -`. The designated requirement must be the bundle id plus the certificate root, not a cdhash; the script prints it and fails if it contains `cdhash`.
- It writes `out/imessage-agent-<version>.tar.gz` holding the app, the CLI, the LaunchAgent template, the skill folder and `install.sh`, plus `out/SHA256SUMS`.

### LaunchAgent plist

- `Label`: `io.github.krishhgg.imessage-agent`.
- `Program`: `~/Applications/iMessage Agent.app/Contents/MacOS/IMessageAgent`, expanded to an absolute path at install.
- `AssociatedBundleIdentifiers`: `io.github.krishhgg.imessage-agent`.
- `LimitLoadToSessionType`: `Aqua`. `ProcessType`: `Interactive`.
- `Sockets` / `Listener`: `SockPathName` is the path `Paths.resolvedSocketPath()` gives, 104 bytes or less. `SockPathMode` is 384 (0600).
- `StandardErrorPath`: `~/Library/Application Support/iMessage Agent/bridge.log`.
- No `EnvironmentVariables` key.

### install.sh

- Takes no network actions of its own beyond fetching the tarball for the tag. It doesn't use git, Homebrew, Xcode or Python. It never sends Apple Events.
- Checks the tarball's SHA-256 against the value pinned in the script and stops on mismatch.
- Installs the app at `~/Applications/iMessage Agent.app`, the CLI at `~/.local/bin/imessage` and the LaunchAgent at `~/Library/LaunchAgents/io.github.krishhgg.imessage-agent.plist`.
- Registers the app with `lsregister -f`. Runs `launchctl bootout` for an old job, then `launchctl bootstrap gui/<uid>`.
- Writes an install manifest under the app-support folder listing every path it created.
- `--skill-dir <dir>` copies `skill/imessage` into `<dir>/imessage`, for example `~/.agents/skills` or `~/.claude/skills`, and adds it to the manifest.
- `--uninstall` boots out the job and removes every path in the manifest, the skill copies included. It deletes the Keychain item and the app-support, cache and staging folders. It prints `tccutil reset SystemPolicyAllFiles io.github.krishhgg.imessage-agent`, `tccutil reset AppleEvents io.github.krishhgg.imessage-agent` and `tccutil reset Accessibility io.github.krishhgg.imessage-agent` for the user to run.

### INSTALL.md, README.md and the skill

- `INSTALL.md` is the Grok Bot prompt for install flow steps 1 to 7. It pins the `install.sh` SHA-256 for the tag.
- `README.md` states the honest limit from section 2, what Grok Bot's "always allow" for Shell means, that private APIs exist and this repo doesn't call them, the tested macOS versions (only after release tests pass), and only measured token numbers.
- `skill/imessage/SKILL.md` has a listing description of 40 tokens or fewer and a body of 400 tokens or fewer, counted with o200k. The body covers the six points in section 6 and calls the CLI by absolute path.
- `skill/imessage/reference.md` holds the rare details, including that a case difference outside ASCII can miss in search.
- A check script, `scripts/check-skill-tokens.sh`, fails the build when either cap is exceeded.

## Release-test harness

Owner: packaging, with the IMUI and IMForeground owners reviewing the test steps.

Owner files:
- `scripts/release-tests/sampler.swift`, adapted from `spikes/s3b/vis.swift`
- `scripts/release-tests/run.sh`
- `scripts/release-tests/t1-bridge.sh` through `scripts/release-tests/t8-files-groups.sh`
- `scripts/release-tests/hid-inject.swift` (test 5 only)
- `scripts/release-tests/write-evidence.swift`
- `scripts/release-tests/README.md`

Changes the sampler needs relative to `vis.swift`:
- Count every on-screen window owned by the Messages pid, at any layer and size. `vis.swift` counted only layer 0 windows taller than 100 px.
- Sample every 10 ms, and record the front app by bundle id at each sample.
- Record HID input times from `CGEventSource.secondsSinceLastEventType(.hidSystemState, ...)`, so a change with user input in the 1 s before it marks the test for a rerun instead of a failure.
- Write JSON lines with only pids, bounds, layers and bundle ids, never window titles or content.
- Run as its own process next to the bridge. The actions under test run through the CLI, so the bridge performs them under its own grants.

`run.sh` records the macOS version, runs each test, and calls `write-evidence.swift` to append passing records keyed on major.minor. `build.sh` copies the evidence file into the bundle at the next tag build.

The helpers in `scripts/release-tests/lib.sh` read the CLI's `--json` output by its NDJSON key names (`id`, `ns`, `me`, `reply`, `parts`, `delivered`, `att.N.id/name/state/uti`, `react.N.kind/by`) and pick read records by `type`. `scripts/tests/fixtures/*.ndjson` holds the exact bytes `NDJSON.render` prints for fixed records. `NDJSONGoldenTests` compares them byte for byte, and `scripts/tests/harness-test.sh` feeds the same files to the helpers, so a key rename fails both.

## Items DESIGN.md doesn't settle

These came up while mapping the design to modules. Each has a working choice in the skeleton that its owner can revisit.

1. Ops beyond the section 1 table. `unread`, `wait`, `caps`, `doctor` and `ping` are wire ops because section 5's verbs need them. `status` is an op with no CLI verb; `doctor` shows its data.
2. Rate limits name sends only. The skeleton counts sends and threaded replies, not tapbacks, unsend or edit, and uses a rolling 24 h day.
3. The search budget has no number. `Limits.searchBudget` is 5 s.
4. transfer_state 6 with `error` 0 has no fixed rendering. It renders as `failed transfer_state 6`.
5. `show --from` paging comes from `ours.py`, not the section 5 table.
6. A send to a group while group sends are off returns `unsupported` with a fix; section 3 item 8 only says `caps` shows `untested`.
7. Result wording DESIGN.md describes but doesn't quote: the mark-read note (`chat opened, may be marked read`), the agent-text note (`agent text may still be in the field`), the AX state note (`AX shows <state>`) and the front-app note (`<app> in front`).
8. New error lines: `error: journal write failed`, `error: foreground mode is off`, `error: --thread can't be combined with --file` and `error: bad request`.
9. Release tests say they "sample from the bridge". The harness runs the sampler as a separate process while the bridge performs the actions. Putting a sampler inside the bridge would add code that ships to users.
10. Release tests must exercise actions that `caps` reports as `untested` and therefore off. DESIGN.md doesn't say how. Packaging needs a release-test build or a maintainer-only switch, and it must not be reachable from the socket or the user-writable LaunchAgent plist. Settled: `scripts/build.sh --release-tests` compiles with `-Xswiftc -DIMESSAGE_RELEASE_TESTS`. Under that condition `CapabilityRegistry` reports every capability as `supported (release-test build)` on any version, and `caps` and `doctor` say so in their header. That build goes to `out/release-tests/`, is signed with the same identity and bundle id so grants carry over, and never goes into the tarball or `SHA256SUMS`. A normal build has no code path that reads the condition at run time.
11. The evidence file lives in the signed bundle (`Contents/Resources/release-evidence.json`), so adding evidence means a re-sign. That keeps grants because the designated requirement isn't a cdhash.
12. The idempotency replay must return the first result while the journal must never store message text. `Journal.finish` strips text from the stored response.
13. `wait` and the consecutive-send limit need agent-sent GUIDs across restarts. IMBridge seeds them from the journal's 7 days.
14. Section 3 item 3 says foreground actions at their idle gate don't hold the queue, and step 3 releases and retakes it. So the foreground machine owns its queue handling, not the pipeline.
15. `account_ready` is a new AppleScript handler. It checks that the account is `enabled` and `connected` using terms that exist in `research/messages.sdef`, but no spike has run it. The cold-start tests need to confirm it on 26.2.
16. RCS appears in the Messages scripting dictionary as a service type. DESIGN.md doesn't mention it. The script sends on the SMS account for `SMS` and on iMessage for everything else.
17. The CLI exit codes aren't in DESIGN.md.
18. `IMTestSupport` is a test-only target added to the requested list.
19. Section 5 lists bare `doctor`, and install flow step 5 says it raises the Accessibility prompt only if the user wants UI actions. The flag is `doctor [--ui]`, and `INSTALL.md` uses that spelling.
20. `ours.py` disagrees with DESIGN.md on several outputs (see the IMCore checklist). Only the success output of `chats`, `unread`, `read`, `show` and `who` is held to `ours.py`; DESIGN.md and `Results.swift` win everywhere else, and error lines use ` fix:`.
21. Release evidence records passes only, so a missing record can't be told apart from a failed test. Image sends, `att` conversion and group sends therefore need a record for the running version, like UI actions. On an untested version, image file sends return `unsupported`, `att` returns an unconverted copy, and plain text and non-image file sends still work.
22. An image file is one whose frozen bytes ImageIO recognizes as an image. The caller's file name isn't used.
23. `TextNorm.textDigest` trims, so two texts that differ only in leading or trailing whitespace share an idempotency key and an approval binding. Correlation already treats them as the same row.
24. DESIGN.md gives no search query length. The query prints in the `search` header and again, shell-quoted, in the `more:` footer, so a long one could fill the 12 KB page with no hits. `Limits.searchQueryMaxChars` is 500 Unicode scalars. The CLI parser and `ReadService.search` both refuse a longer query with `error: search text is over 500 characters fix: search a shorter phrase`.
25. A target matches a group on the group's display name. A group with no display name matches on its members' names only when nothing else matches, so `Jordan` stays Jordan Kim's 1:1 chat and isn't also the unnamed group of Jordan and Taylor.
26. A phone number or email with no chat, or a contact whose only handle has no chat, is a new direct target. It has no chat ROWIDs, its chat number is 0, and its send handle is the normalized handle. A phone qualifies with a leading + and 7 to 15 digits not starting with 0, or in a +1 region (entry 41) with 10 digits, or with 11 digits starting with 1. An email needs one @, a local part and a dotted domain. A contact with several handles and no chat returns several matches, one per handle. A contact with some handles in chats resolves to those chats only. The send goes on SMS when chat.db's handle table lists that handle as SMS and never as iMessage, and on iMessage otherwise (RCS counts as neither). Its canonical ID is `handle:<normalized>`, the same one the chat Messages creates gets, so the allowlist entry, approval binding, idempotency key and rate-limit history carry over once the chat exists.
27. A several-matches candidate for a chat passes its chat number, or its chat guid when the number itself matches more than one conversation (a ROWID that is also a short code). A new direct target passes its handle.
28. `changes` has no age bound on the changed message. No index covers the four event times, so the query walks message by ROWID up to the highest ROWID. An inner select keeps only (chat, ROWID, event time) in a top-N sort capped at the 5,000-row cap, and only those rows get their columns and neighbor rows, so a cursor of any age costs about the same. On a 1.1 million message synthetic copy (`scripts/tests/make-large-chatdb.zsh`), every cursor from 1 minute to 2,200 days old, and `1:0`, returns in 0.2 to 0.8 s. Before, it took 0.35 to 1.32 s and timed out at 2,200 days. A fetch that fills the 5,000-row cap with more than one event time drops the rows at the last time and resumes there. A `changes` timeout gives `error: chat.db read timed out fix: retry, or run imessage changes with no --since for a fresh cursor`. With no `--since`, `changes` returns the current cursor and no rows, so an agent whose old cursor keeps timing out can start again from now.
29. Failed AX reads. DESIGN.md says a failed check refuses but not which AX errors count as a failed read. `noValue` and `attributeUnsupported` mean the element lacks the attribute and read as "" or no children. Every other error, the 2 s messaging timeout included, throws. A field's AXValue counts only when the read succeeds and returns a string. So foreground step 1 returns `aborted: AX read` when the composer, edit field or thread view can't be read, and a pre-press re-read that fails refuses with nothing pressed. Release tests 3 and 4 should check this on 26.2: if Messages reports another code for a missing AXIdentifier, AXSubrole or AXChildren, UI actions fail closed with `not_loaded` or `aborted: AX read`.
30. Row descriptions compare with U+202F and U+00A0 read as plain spaces on both sides, as bubble descriptions do. The duplicate-description check uses the same rule.
31. Threaded replies count under the send rate limits. A breach, or a check that failed, replaces "threaded replies always ask" as the dialog reason. An approved threaded reply whose dialog didn't name a breach is checked again once `ForegroundMachine` holds the queue. A breach then releases the queue, records the new approval id on the approved journal entry and asks again with the breach named. Approving a dialog that named the breach stands. Plain sends approved through a not-allowed, scope or untrusted-store dialog still skip the recheck under the queue, as before.
32. A 1:1 row whose join row names a chat outside the conversation's chat ROWIDs belongs to another conversation and never matches. With no other match the part is `may_have_completed` (section 3 item 5). A new direct target has no chat ROWIDs yet, so its rows match on the handle. A join row then confirms the chat when the joined chat's canonical ID is the target's, and a join row naming a chat with another canonical ID isn't ours. A row with no join row yet adds `chat unconfirmed`.
33. Only a later final result that holds its key (`holdsIdempotencyKey`, so it may have taken effect) supersedes an earlier key on the same target GUID and part. A later `not_loaded`, `unsupported`, `busy`, `failed: bridge restarted` or `denied: approval expired` leaves the earlier key held.
34. The consecutive-send echo rule that matches inbound text digests against agent sends applies only to a self-chat, a 1:1 chat whose handle is one of `ContactBook.ownerHandles`. GUID echoes count in every chat. In any other chat, a reply with the same text as an agent send is a real reply and resets the count.
35. When the silent Automation check gets `procNotFound`, `doctor` reports `ok Automation: can't check while Messages is closed`, which isn't a failure, and leaves the answer to the CLI's prompt step. The probe's own status decides this, not the running-app list. `doctor` never launches Messages. The line uses the `ok` prefix because `DoctorCheck` has only ok and fail.
36. Crash recovery rebuilds a send's chat with `ChatDatabase.sendTarget(canonical:)`. It returns the conversation when chat.db has it, and a new direct target for a `handle:` ID it doesn't, so a send that stopped before Messages made the chat is still matched by its handle. `resolve(canonical:)` still returns nil for that case.
37. A new direct target's chat number is 0, which no command takes. The `read` header prints its handle in place of the number (`chat +14155550199 …`), and `allow` and `revoke` print its label alone. `ours.py` has no such case, so entry 20 doesn't apply to it.
38. `error: no chat or contact matches` gets a fix that fits the input. A chat number points at `imessage chats`, a string with @ says to check the email address, a phone number that can't be addressed asks for the whole number with its country code, and anything else asks for a phone number, an email or a chat id from `imessage chats`. `who` keeps `imessage chats`.
39. The `changes` cursor can carry a third part, a tie ROWID: `<rowid>:<ns>:<tie>`. DESIGN.md gives the cursor as (ROWID, time), and that can't name a place inside one time. A bulk mark-read that gives more rows one date_read than a page shows would then bring back the same page and footer on every call. Changes go in (time, ROWID) order, and a tie cursor also takes the rows above the tie ROWID at exactly its time. The text and NDJSON footers give one when a page stops inside a time that a shown change has. The bridge gives one when a fetch that fills the 5,000-row cap has a single time, and then resumes from the last ROWID fetched. Otherwise the footer moves the time back as before. A two-part cursor still parses, and the CLI accepts both forms.
40. A target matches a group's display name where the text starts a word of it: at the start of the name, or after a character that isn't a letter or digit. A chat number (six digits or fewer) never matches a display name. So `Fam` still finds `Family 🏡` and `Mom` still finds `Mom & Dad`, but `Dad` doesn't also match `Grandad 80th`, `12` doesn't match `Class of 2012`, and `7` stays chat 7 next to a group named `Team 7`. Digits alone, like `2012`, name chat 2012 or nothing. The fallback on an unnamed group's member names (entry 25) still matches anywhere in the label.
41. A phone number without a leading `+` becomes a new direct target only when the Mac's region uses the +1 plan, one of the North American Numbering Plan regions in `HandleNormalizer.northAmericanRegions`. `StoreConfiguration.regionCode` holds the region and defaults to `Locale.current`. No region counts as outside the plan. The rule covers typed numbers and contact-card numbers. Matching a number to an existing chat is unchanged, because `HandleNormalizer` still reads 10 digits as a +1 number. Outside a +1 region such a number with no chat is `error: no chat or contact matches "<number>"`. A name whose one contact has only numbers saved without a `+`, and no chat, gives the same error with the card's first such number. That contact still counts as a match. Next to another match, such as a group whose display name starts with the same word, it gives several matches, with the contact listed by its first handle as saved. The fallback on an unnamed group's member names (entry 25) doesn't take its name. The fix for any phone number is `pass the whole number with + and its country code`, with no +1 example to copy. `who` shows a number saved without a `+` that chat.db's handle table doesn't list as saved, not as a +1 number, so it never offers a number that resolving the card refuses. For the same reason, a contact listed under `error: several matches` carries its first handle that has a chat or is a valid new direct target in the region, else its first handle as saved. Tests pin the region to `US` unless they set it.
42. Section 5 counts a contact's iMessage and SMS chats as one conversation. The bridge merges chats on the same normalized handle only. A contact whose chats are on different handles, for example an email on iMessage and a phone on SMS, returns `error: several matches` with each chat, and nothing runs. That is the safe reading, because merging across handles would let the bridge pick a handle the agent never named.
43. For a 1:1 send or allow, the approval dialog's chat line names the send handle and the service next to the label, for example `Juan, +15512345678 on iMessage`. Both come from the request's `ResolvedChat` (`sendHandle`, `service`), the same value the job sends with after approval. The service shown is the account the send scripts use (entry 16), `SMS` for an SMS chat and `iMessage` for any other, RCS included. A threaded reply is typed through Reply to Last Message…, so Messages picks its service, and its chat line names the handle and no service, for example `Sam Lee, +16505550142, reply in thread`. A label equal to the handle is shown once. React, unsend, edit, revoke and group dialogs show the label alone.
44. `--again` skips the idempotency lookup except when an entry with the same key is at `invoking` or `invoked`. Then it answers `may_have_completed`, writes nothing and runs nothing, because section 3 item 1 says such a request never runs again. Entries at `received`, `approved` or final still don't count under `--again`.
45. The four send handlers (`send_text`, `send_file`, `send_chat_text` and `send_chat_file`) first check `application id "com.apple.MobileSMS" is running`, which doesn't launch Messages, and return `not_running` before any Apple Event to it. `MessageSender` then runs the hidden cold start and calls the same handler once more, with one retry per request. This happens after `invoking` is journaled and before any send event reaches Messages. A part whose last call answered `not_running` and matched no row is `failed: Messages not ready`, which doesn't hold the key. The entry reached `invoking`, so it counts toward the rate limits, as an Automation refusal does. The check line compiles in a script that names another app, but nobody has compiled it inside the real script on 26.2, because that reads Messages' terminology. Release test 1 or the cold-start live test has to confirm that it compiles there and doesn't launch Messages. `account_ready` starts with the same check and returns `not_running` too. `ColdStarter` counts only "1" as ready, so that answer keeps the poll going.
46. `t_front` is the uptime when the first read that shows Messages frontmost started. `activateForeground` returns once `/usr/bin/open -b` has started, and the machine reads the front state every 1/64 s while `open` runs. That poll, the late-activation watch and the ownership check read only `isFrontmost()`, never the AX window count. Once `t_front` is recorded, an `open` still running is terminated, before the first press and the hide, so it can't bring Messages forward again after the hide. An `open` still running when the late-activation watch ends is terminated then, before the last `isHidden` read and any hide (`LiveMessagesApp.endActivation` through `IMUI.ActivationEnding`). That can't recall an activation `open` has already handed to LaunchServices. Any other `open` still running after 10 s is terminated. A read that returns after the 1 s activation limit or the 3 s window doesn't count even if it shows the condition, and a slow read that returns in time still dates `t_front` from its start. So a slow `open` or read leads to the late-activation watch or `aborted: deadline`, never to a late `t_front` or a press after the 3 s. In the hide poll, a read that shows Messages hidden counts even when it returns after the 1 s, because Messages is hidden either way. For an edit, the 15-minute window is checked again right before the Edit press, after the bubble lookup, `willInvoke` and the ownership check, and again as the press's final check (entry 50). It is checked once more right before Return, before the last ownership check (entry 50).
47. An AX tree walk that reaches its 20,000-node cap with nodes left unread throws `AXDriveError.walkLimit` instead of returning what it read. Foreground step 1 then gives `aborted: AX read`, hidden targeting gives `not_loaded`, and cleanup treats the edit field, thread view or transcript as still unresolved. Two edit fields showing throw `AXDriveError.severalEditFields`, which step 1 reads as `busy: edit in progress`. A takeover result then says `AX shows more than one edit field`, or `AX shows more than one edit field and a thread view`. Nobody has counted the AX nodes in a real Messages window. If one has more than 20,000, every UI action fails closed, and release tests 3 and 4 show it as `not_loaded` or `aborted: AX read`.
48. Release test 4 takes `t_front` from the sampler's first sample with Messages frontmost, not from the bridge's `phase front` marker. That marker comes from the bridge's own record of `t_front`, so a late record would hide a late Return. Return, from the `key return` marker, must come 0 to 3,000 ms after that sample. A Return before it, or no Messages front sample at all, fails. The test detail gives the marker's offset only as a cross-check.
49. The window rules count Messages' real windows on every Space, because AXWindows and the on-screen window list miss a window on another Space or full screen in its own Space. `MessagesAppState.allSpacesWindowCount` counts the windows in `CGWindowListCopyWindowInfo` with `optionAll` that Messages' pid owns at layer 0 with width and height both at least 100 points, and is -1 when the window server gives no list. The size floor drops the four 1512 x 33 layer-0 menu bar strips that every app with windows owns on macOS 26 (research/live-tests/2026-11-07-windows.md). With no AX window and Messages not hidden, any such window, or an unknown count, gives `busy: Messages is open` with the hide fix, never a quit and relaunch. Hidden with no AX window still quits and relaunches. `WindowRules.busyResult` counts the same windows, and the earlier front app's `hasWindows` (`LiveMessagesApp.hasNormalWindow`) uses the same floor. The count on every Space decides only busy against quit (`decide` and `busyResult`), and the `error: Messages became visible` note (`WindowRules.showsWindow` and `ColdStarter.windowShowed`) counts only what the user can see, an on-screen window or an unknown on-screen count, Messages frontmost, or Messages not hidden with an AX window, so neither a window on another Space nor an unknown AX count, which every sample has without the Accessibility grant, adds it while `isHidden` lags a launch. Nobody has measured what AX and the full list show with a Messages window on another Space or full screen in its own Space. Release test 1 cases i and j (gates `other-space-busy` and `fullscreen-space-busy`) check that a hidden action answers busy there and leaves Messages running with its window. Nobody has measured either whether Messages keeps a window closed with Command-W in the full list. If it does, Messages running with no open window and not hidden gives busy with the hide fix, and after Command-H the hidden rule quits and relaunches. That is the safe side, because a closed window and a window on another Space look the same in the public lists. Release test 1 case h accepts either path and records which one ran.
50. Final checks and the last reads before an effect. Every AX mutation in `MessagesAXDriving` (`press(row:)`, `perform(action:on:)`, `press(menuItem:)` and `setValue(_:of:)`) takes a final check, `AXFinalCheck`, as an explicit parameter with no default, so each call site states its check, and a call with nothing to check passes `{}`. `LiveMessagesAX` runs it after its own reads for that mutation (the description or title fingerprint, the action names, and for a row press the window rules), on the line right before `AXUIElementPerformAction` or `AXUIElementSetAttributeValue`, with no AX read between them, which a source-guard test holds. If the check throws, nothing is pressed or written and the caller gets its own error back. A hidden bubble action's check runs the window rules recheck, then the caller's check, so Undo Send's 2-minute window is checked after the driver's reads too: expired there is `expired` with no press, and the entry goes from `invoking` to final without `invoked` and holds no key. Every refusal at a hidden tapback's or Undo Send's final check, from the window rules or the caller's check, takes that path, while an AX error from the press itself still records `invoked` and keeps the `may_have_completed` handling. The row press passes `{}`, because the driver reads the window rules last itself. `LiveMessagesApp.state()`, which those window rules read, takes the AX window count and both window lists first and samples `isHidden` and frontmost last. When that AX count is -1 and the fallback AX read fills it, `app.state()` runs again after that read, and the filled count is used only if the new state's AX count is still -1. In foreground mode the Edit press checks the edit window and then ownership, and the Reply to Last Message… press, the field write and the bridge-owned restore check ownership. The takeover's one reset write passes `{}`. A failed ownership check there takes the takeover path as before: a stopped write wrote nothing, so the takeover leaves the field alone, and a stopped restore leaves the field to the takeover's one reset. The markers stay after each step's own ownership check. Right before Return the order is the focused-field read, for a reply the parent rereads (the thread view's parent bubble, whose AX walk can block, then the newest incoming GUID, one chat.db query), the deadline, for an edit the 15-minute window, then the ownership check, which samples input last, then the key post. These checks right before Return are one group that runs after every other step. Only one read can come last, so the group ends with the ownership check: user input at any point before Return is caught. A change to the field, the edit view or the parent bubble that comes with no user input, during a later read in the group, isn't seen; only Messages itself or another AX client could make one. The focused-field read must return the written field holding exactly the intended text, or the result is `aborted: field` with no Return. A changed GUID or parent bubble there, or at step 4's check after the write, is `aborted: parent changed` with no Return, and a failed read, no thread view or a thread view with no parent bubble is `aborted: view`. Step 3 reads the earlier front app, whose `hasWindows` reads the window list, before the activation check, so no read sits between that check and `open -b`. Hidden with more than one window is busy using the larger of the AX count and `allSpacesWindowCount`, and an unknown all-Spaces count (-1) doesn't raise it. `ColdStarter.windowShowed` counts an unknown on-screen count (-1) as shown, as `WindowRules.showsWindow` does, and an unknown AX count alone as not shown (entry 49). `quit_messages` starts with entry 45's running check and returns `not_running` without an Apple Event to Messages. `LiveMessagesApp.quit` returns true for it, and the exit wait that follows returns at once. The CLI's wait for a plain send covers a text plus a file with one cold-start retry: `2 * Limits.coldStartTimeout + 3 * Limits.sendEventTimeout + Limits.correlationTimeout` (160 s) after the approval and queue waits, plus the 30 s slack. `Limits.sendEventTimeout` is the send handlers' 10 s `with timeout`, which `SendScripts.sendEventTimeout` reads. Each cold start's last `account_ready` call can run up to 5 s past its deadline, and that falls inside the slack. `send --thread` makes no script call and keeps its earlier wait. Left as they are: the hide's running-app lookup after its ownership check, which is the same LaunchServices lookup `isFrontmost` makes inside the check and reads neither AX nor the window list; `send_file`'s `POSIX file p as alias` between the running check and the `tell`, which resolves a local path and sends no Apple Event; and the release-test marker writes after each check, which a normal build doesn't make.
