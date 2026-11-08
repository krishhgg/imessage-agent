# Messages in any state: state map and proposal

Scope: macOS 26.2, DESIGN.md v5.4. Messages' Info.plist reads CFBundleShortVersionString 26.0, build 1450.300.41.1.4, and its version.plist names the project Messages_iosmac. Messages is a Mac Catalyst app whose scene manifest allows several scenes, one of them a PosterBoard editor overlay (`ChatKit.PosterEditorOverlaySceneDelegate`). Notes that call it Messages 14.0 are wrong. Paths are relative to /Users/krishgarg/Documents/Projects/grokbotimessages/ unless they start with `~` or `/`.

Evidence labels:
- **Measured** means seen on this Mac. The source file is named.
- **Reported** means a third-party report. The source is named.
- **Code** means read from Sources/.
- **Assumed** means none of these.

Reported sources used below:
- cmsj/Hammerspoon2 PR 351 and issue 344. AXWindows leaves out windows in native full screen and on other Spaces, while AXMainWindow and AXFocusedWindow still return them. `CGWindowListCopyWindowInfo` with optionAll also lists ordered-out and closed helper windows. The PR drops those with the private `CGSCopySpacesForWindows`.
- lwouis/alt-tab-macos issue 1324: "AX APIs don't return other-Spaces windows." Its workaround is the private `_AXUIElementCreateWithRemoteToken`.
- vercel-labs/agent-desktop PR 415: "AXWindows lists only the windows on the current Space." It doesn't cover hidden apps. None of these three does.
- ThomasPraun/frameshell PR 407. Nothing in the CG window list tells minimized or hidden windows apart from windows on another Space.
- vorssaint/vorssaint-utils PR 3181, macOS 27.2. `unhide()` on an app that isn't hidden "moves all of its windows above other apps' windows, without activating it." The hidden case wasn't checked.
- Apple's AppKit release notes for 10.7 and Eclectic Light (2017). An app that supports automatic termination and is hidden or windowless and inactive can be turned into a background element, gone from the Dock and the app switcher while the process runs, and ended later.
- Apple Support. When one window leaves Split View, the partner app goes full screen alone in its own Space.
- MacMost. Command-H removes an app from the Stage Manager strip, and Hide isn't available for a full-screen window.

## 1. Summary

What "works in any state" means for each action family:

- **Reads**, `wait`, `changes`, `status` and `doctor`. They already work in every state, including with Messages quit, because they read chat.db. `doctor` also reads Messages' AX action names when Accessibility is granted and Messages runs (Services.swift:280). That read is read-only and allowed in any state, but it can block for 2 s when Messages hangs. No change.
- **Plain and file sends.** They already work in every state, because they use only the Apple Event and chat.db. One change: if the bridge started Messages from not running, including setup's hidden launch, it quits Messages again after 10 quiet minutes (G8), so a user who had quit Messages finds it quit.
- **Tapback and unsend**, and the chat selection they start with. Today they run only when Messages is hidden with one window. Under the proposal the flow follows the window:
  - Hidden: act hidden as today, then select the user's earlier chat again.
  - Shown on the current Space and not frontmost: act on the visible window without hiding it ("act in view"), behind a mouse and pointer gate, then select the earlier chat again. The user sees the chat switch, the tapback and the switch back. This waits for probe 4.
  - Shown, with nothing on screen (minimized, on another Space): hide, act, restore the chat, unhide. This waits for probes 1 and 2.
  - Frontmost: wait for Messages to leave the front. Under a separate opt-in, act in front, but only when the target chat is already the selected one, and only the bubble action.
  - Not running: launch hidden, act, restore the chat, quit later.
- **Edit and threaded reply.** They stay opt-in under foreground mode. They gain a start from a visible window, a start from a minimized or other-Space window, and a frontmost start when the target chat is already selected.

Some states still refuse, because the bridge can't read them or can't put them back:
- more than one conversation window
- a draft in the chat the bridge would leave (until probe 6), unread messages in it, or a user scrolled back in a visible window
- a new message, search, a thread view, edit mode, a sheet or popover, or an audio recording
- full screen or Split View in a Space the user isn't on, and any state with Stage Manager on (until probe 1)
- a window the CG list shows that AX never reaches (until probe 6)
- any window reading the bridge can't make

**The live refusal under this proposal.** Messages was unhidden and not frontmost, and nothing was on screen. optionAll listed one real layer-0 window, 500 x 500. That isn't the 1024 x 768 window probed that morning (2026-11-07-windows.md), and the probe didn't read AX. Before the second try the maintainer was asked to hide Messages, and the probe right after still read it unhidden. So the `fix: hide Messages (⌘H)` line already failed in practice. ⌘H acts on the front app, and Messages had nothing on screen to bring forward. Under the proposal the outcome depends on what that window was, which probes 1, 2 and 3 decide:
- If AX lists it with AXMinimized true, it is state 11. The bridge hides Messages, acts, restores the chat and unhides.
- If AX doesn't list it, but does after the bridge's hide, it is state 12, with the same flow.
- If AX doesn't reach it even after the hide, and AXMainWindow and AXFocusedWindow are nil, it may be a closed scene or helper window that optionAll still lists (Hammerspoon2 PR 351). That is state 17. The result is `busy: Messages window not reachable` with `fix: quit Messages and retry`, until probe 6 shows that drafts survive a quit. After that, the bridge quits Messages, relaunches it hidden and acts.

So the proposal may still refuse this Heart if the window was a phantom. The fix line it gives then is one the user can act on.

**Approval in the live case.** No panel showed, because the self chat is on the allowlist (Measured). `~/Library/Application Support/iMessage Agent/policy.json` holds one entry, "You (notes)", scope text, addedAt 2026-11-07 16:59:29 PST, which is the moment test 1 was approved. Both react entries in `journal/journal.ndjson` ended `busy: Messages is open` with no approval ID. The code saves an allowlist entry only on "Always allow this chat" (Pipeline.swift:299). The live note's "clicked Allow once" and "the allowlist stayed empty" are therefore likely wrong. The implication for this proposal: in allowlisted chats the bridge hides, switches chats and unhides with no panel at all, so the restore contract and the guards are the only protection there.

**The usual case.** Most requests arrive while the user is in Grok Bot, because they typed the request there and the approval panel doesn't activate (ApprovalPanel.swift). So at action time Messages is usually not frontmost, with its window anywhere. That is the path this proposal opens. A frontmost Messages is the rarer case, for example an agent loop reacting to an incoming message while the user reads it in Messages.

**Proposal.** Replace "act only if Messages is hidden" with "leave a visible Messages where it is, hide it only when nothing of it is on screen, and put back what changed". The steps:
1. Before any panel, the bridge reads a state sample. If the state is one that waiting can't fix, it returns busy with no panel (G13).
2. After approval, it reads the sample again, resolves the selected chat to one chat.db chat and records a restore plan. When AX can read the window only after a hide, as in state 12, it resolves the selected chat right after that hide (G1).
3. It picks the flow for the state (section 4). Every flow runs the G2 checks before its first press, and before its hide when AX already lists the window (G1).
4. It acts, restores the plan in reverse order, and names anything it couldn't restore.

Limits on what the bridge does to the user's window:
- It never hides a frontmost Messages, a full-screen or Split View Messages, or any Messages while Stage Manager is on.
- It never hides a window that is on screen, except in one fallback for state 10 where nothing covers the window and probe 1 has passed.
- It hides and unhides only behind the mouse and pointer gate (G1, G4), and it unhides only after the chat restore succeeded or had nothing to do.
- After every unhide it watches the front app for 1 s and gives focus back if Messages took it with no input.
- It never presses a conversation row on a frontmost Messages.

When Messages isn't running, the flow is: launch hidden, act, restore the chat, then quit after 10 quiet minutes. Every approval stays where it is now, before the queue.

## 2. The states

Duplicates from the earlier maps are merged. The matrix in section 4 refers to these numbers. There are 44 states.

### Process and account

| # | State | How the bridge detects it | Evidence |
| --- | --- | --- | --- |
| 1 | Not running | No `NSRunningApplication` for com.apple.MobileSMS, or `isTerminated` | Measured. Every cold launch and relaunch came up hidden with one window, focus unchanged (S3b, in research/spikes/S3.md) |
| 2 | Launching, started by the user (Dock, Spotlight, a notification click) or by the bridge | `isFinishedLaunching` false (not read today). AX count 0 or a timeout. No CG window yet | Assumed. Today this reads as running with no window, and the rules would quit it (WindowRules.swift:39-41) |
| 3 | Running, but the account isn't ready, is signed out, or iMessage is off | `account_ready` returns "0" | Assumed. `account_ready` was never spiked (research/council/impl-round-2.md, ColdStart.swift:76). The 1,194 ms in S2 is an AppleScript send that launched Messages, not an account reading |
| 4 | Hung or very slow | AX `cannotComplete` after 2 s, Apple Event -1712 | Assumed. No spike produced a hang |
| 5 | Quits, crashes or relaunches during an action | `isTerminated`, a new pid, AX errors on old elements | Assumed |
| 6 | Running but turned into a background element by automatic termination | `activationPolicy` isn't `.regular`. The pid, to catch a later exit | Measured: Info.plist sets NSSupportsAutomaticTermination and NSSupportsSuddenTermination to true. The behavior is Reported (AppKit 10.7 notes, Eclectic Light). Never seen for Messages. Probe 16 |

### Hidden

| # | State | How the bridge detects it | Evidence |
| --- | --- | --- | --- |
| 7 | Hidden with one window. Where the window was before the hide can't be read | `isHidden`, not frontmost, AX 1, on-screen 0. `AXMinimized`, `AXSubrole` and `AXFullScreen` return -25205 | Measured (research/live-tests/2026-11-07-windows.md). Heart, Undo Send and a row press worked here under another app's grant, and the front app didn't change (S3) |
| 8 | Hidden with no window | AX 0, all-Spaces 0, `AXMainWindow` and `AXFocusedWindow` nil, Stage Manager off | Measured: AX 0 after a hidden close (S3b). The checks beyond AX are new (G1) |
| 9 | More than one window, hidden or not: Settings, a conversation window from Open in New Window, the poster editor overlay, or a window the bridge can't classify | The larger of the AX and all-Spaces counts is above 1. A tree read classifies each window by whether it has a `ConversationList`, a `TranscriptCollectionView` or a `messageBodyField` | Assumed. The poster editor scene is Measured in Info.plist only |

### Not hidden, not frontmost

| # | State | How the bridge detects it | Evidence |
| --- | --- | --- | --- |
| 10 | Window on screen on the current Space, with Stage Manager off and no full screen or Split View: behind the front app, beside it, or on a second display | On-screen count 1 or more. CG bounds against the `NSScreen` frames name the display. The front-to-back order of the on-screen list shows which windows sit above it (not read today) | Measured once: a window that Window > Messages showed behind the front app was closed by the user within about a minute (S3). The rest is assumed |
| 11 | Minimized | AX 1 with `AXMinimized` true, on-screen 0. The attribute should read while unhidden (assumed), and it is read three-valued (G14) | Reported: AX lists minimized windows, and the CG list can't tell them from other-Space windows (frameshell PR 407). Not measured. A candidate for the live refusal |
| 12 | On another Space, on this display or another | AX 0 (Reported: alt-tab-macos issue 1324, agent-desktop PR 415), on-screen 0, all-Spaces 1 or more with `kCGWindowIsOnscreen` false. `AXMainWindow` may still return it (Hammerspoon2 PR 351) | Not measured. A candidate |
| 13 | Split View on the current Space, with the user in the partner app | On screen. `AXFullScreen` true through `AXMainWindow`. When that reads unknown, a window as tall as the full display, menu bar included, also counts. Tiled desktop windows sit inside `visibleFrame` and don't match | Not measured |
| 14 | Full screen or Split View in a Space the user isn't on | As 12, plus `AXFullScreen` true through `AXMainWindow`. Bounds equal to a display frame, or a full-height part of one, only break ties, because Rectangle and Raycast, both installed here, make half-screen and full-frame windows on ordinary Spaces | Not measured |
| 15 | Stage Manager on, with Messages on stage or in the strip | com.apple.WindowManager `GloballyEnabled` is 1 (Reported key). In the strip: AX 0 and CG bounds that change between reads and often fall under the 100-point floor (Reported) | Measured: the key reads 0 on this Mac, so a probe has to turn Stage Manager on. Today a strip window can read as no window, and the rules would quit Messages |
| 16 | No window (closed with ⌘W), still running | AX 0, all-Spaces 0, `AXMainWindow` and `AXFocusedWindow` nil, Stage Manager off | Not measured. If the window server keeps the closed window listed, it reads like 12 or 17. Probe 3 |
| 17 | A window the CG list shows that AX never reaches, even after the bridge's hide | All-Spaces 1 or more. AX 0 before and after the hide. `AXMainWindow` and `AXFocusedWindow` nil | Reported: optionAll lists ordered-out and closed helper windows (Hammerspoon2 PR 351). A candidate for the live 500 x 500 window |
| 18 | Window outside every display, for example after a display was unplugged | Its CG frame intersects no `NSScreen` frame | Measured once while hidden: the 1024 x 768 window sat at x -1268 on a 1512-point screen (2026-11-07-windows.md). Whether it was off screen before the hide is unknown |

### Frontmost and changing

| # | State | How the bridge detects it | Evidence |
| --- | --- | --- | --- |
| 19 | Frontmost with a window: normal, full screen or Split View, user active or idle | Frontmost pid. HID idle time. `AXFocusedUIElement` names where keys land | Assumed for UI actions |
| 20 | Frontmost with no window | Frontmost, AX 0 | Assumed |
| 21 | Frontmost because foreground mode put it there | The bridge's own `t_front` | Measured in S3 (one edit, one reply). Never run from the bridge |
| 22 | Visibility changing: a hide, unhide or activation in progress, by the user or the bridge | `isHidden` and frontmost disagree for a run-loop turn or longer. The on-screen count changes | Measured only with no window: `hide()` returns false and takes effect within 250 ms (S3b) |
| 23 | Unreadable: no Accessibility grant, an AX timeout, no window list, or a window attribute that reads unknown | Counts of -1, `notTrusted`, an unknown three-valued read (G14) | Code (WindowRules.swift:37, 141-147) |

### Inside the window

| # | State | How the bridge detects it | Evidence |
| --- | --- | --- | --- |
| 24 | Transient UI open: a sheet, a popover (Details, emoji, tapback picker, the add menu), an alert, an open menu, Quick Look, the poster editor | Extra Messages-owned CG windows at any layer. AX children with role `AXSheet` or `AXPopover`. Today a hidden popover isn't counted, because the all-Spaces count takes layer 0 only | Assumed. Probe 15 |
| 25 | Draft in the selected chat's composer | `messageBodyField` `AXValue` isn't empty. A draft with only an attachment may read as empty | The element was measured (S3). Whether Messages keeps a draft per chat was not. Probe 6 |
| 26 | New message in progress | No row with `AXSelected` true, or a To: field | Assumed. Probe 15 |
| 27 | Thread view open | `ThreadViewRule` (AX.swift:372-391) | Measured: it stays open after a row press (S3). Its AX shape was never captured |
| 28 | Edit mode open on a bubble | An `AXTextField` inside a Sticker group | Measured (S3). A hidden cancel leaves it open |
| 29 | Search active | A search field (subrole `AXSearchField` or description "Search") that holds a value | The description was measured (S3). The rest is assumed |
| 30 | An audio message recording in the composer, or audio or video playing in the transcript | The composer's "Record audio" button changes its label or state while recording (assumed). A playing control's label for playback (assumed) | The "Record audio" button was measured (S3). Its recording state wasn't. Probe 15 |
| 31 | The user has scrolled back in the selected chat | The newest loaded bubble's `AXPosition` and `AXSize` fall outside the transcript's visible frame, or the transcript's vertical scroll bar `AXValue` isn't at its end | Assumed for Messages. Probe 5 |
| 32 | Unread incoming messages in the selected chat | chat.db: incoming rows with is_read 0 in the chat the selected row resolves to | Assumed that a row press marks them read (DESIGN.md section 4). Probe 8 |
| 33 | The selected chat can't be identified: no row selected, more than one, or a description that doesn't resolve to exactly one chat.db chat under the lookalike rule | `AXSelected` on every loaded row. `RowDescriptionBuilder` over chat.db's conversations, with `ChatTargeter.hasLookalike` (Targeting.swift:270-278) | `AXSelected` is read (AX.swift:449), but no value has been recorded. Row text rebuilding is untested |
| 34 | Target chat already selected | `AXSelected` on its row, and the transcript matches the signature | As 33 |
| 35 | Target row not usable: not loaded, filtered, a pinned tile, different row text, collapsed sidebar, non-English UI, a tree over 20,000 nodes | The exact row match or the action-name check fails | Code: fails closed with `not_loaded`, `ambiguous` or `unsupported` |

### System

| # | State | How the bridge detects it | Evidence |
| --- | --- | --- | --- |
| 36 | Screen locked | `CGSSessionScreenIsLocked` in `CGSessionCopyCurrentDictionary` (undocumented), the `com.apple.screenIsLocked` and `com.apple.screenIsUnlocked` notifications | Measured: sends work while locked (S3b). UI actions while locked were never measured |
| 37 | Display asleep or screen saver running, screen unlocked | `CGDisplayIsAsleep`, the screen saver start and stop notifications, and no lock flag | Assumed. This is the common away case |
| 38 | Session not on the console (fast user switching) | `kCGSessionOnConsoleKey` false. Session resign and become-active notifications | Assumed |
| 39 | The user is in another app's full-screen Space | The front app's on-screen window is as tall as the full display, menu bar included | Assumed |
| 40 | Mission Control, App Exposé, Show Desktop or the app switcher showing | Dock-owned overlay windows in the on-screen list (assumed). A held modifier in `CGEventSource.flagsState(.hidSystemState)` | Assumed |
| 41 | Display reconfiguration during an action: a display plugged in or unplugged, the lid closed, a resolution change | `CGDisplayRegisterReconfigurationCallback` | Assumed |
| 42 | Waking from sleep, or the network is down | `didWake`, `account_ready` | Assumed |
| 43 | App Nap, Low Power Mode, thermal pressure | `isLowPowerModeEnabled`, `thermalState`. Another app's nap state can't be read | Measured: a hidden press took 31 ms (S3) and a hidden, locked send 33 ms (S3b). The nap state at the time is unknown |
| 44 | Secure Event Input on | `IsSecureEventInputEnabled()` | Assumed. Its effect on a Return posted to the Messages pid, and on the HID idle reading, is unknown. Probe 17 |

### States the signals can't tell apart, and why it matters here

- The live probe read only the CG counts. With those alone, states 11, 12, 14, 16 and 17 look the same. Today's rules also read AX, which is reported to be 1 for a minimized window and 0 for the others, so AX would have split 11 from the rest. The proposal reads AX, `AXMainWindow`, `AXFocusedWindow` and the bounds of every listed window. For an AX count of 0, it hides Messages and reads AX again. That separates 12 and 14 (reachable after the hide, or full screen) from 17 (never reachable). It still can't separate 16 from a closed window the CG list keeps. Probe 3 settles that.
- In state 7, Messages reads the same wherever its window was before the hide.
- In state 10, a window behind the front app and a window beside it differ only in stacking order. The in-view flow treats them the same. The hide fallback for state 10 doesn't (section 4).
- State 2 and state 16 look the same unless the bridge reads `isFinishedLaunching`. The proposal reads it.
- A tiled window and a Split View window can have the same bounds. `AXFullScreen` decides. Bounds break ties only when it reads unknown, and then the bridge treats the window as Split View and refuses.
- An attachment-only draft (25) may read the same as an empty composer. Probe 6 covers this.
- An older S3 dump read the window's subrole as `AXStandardWindow` while hidden (spikes/s3/ax1.txt). The 2026-11-07 hidden probe got -25205 for the same attribute. Probe 3 reads it again.
- State 6 looks like state 1 from the Dock, while `NSRunningApplication` still lists the process.

## 3. User activity

Each row lists what the user is doing, the race it creates under the proposal, the guard from section 6 that covers it, and what is left over.

| # | Activity | Race under the proposal | Guard | Left over |
| --- | --- | --- | --- | --- |
| A1 | Away, screen unlocked | The user comes back during the action and sees the target chat in a visible window, or a minimized window's tile gone for a moment | The span from the hide to the target press is capped at 2 s (G1). G3 restores the chat before G4 unhides. G15 shows a notice if the restore fails on a visible window | Read receipts sent during the action (probe 8) |
| A2 | Away with the screen locked, the display asleep, the screen saver on, or another session active | The idle gate passes trivially. Activation and a posted Return behind the lock are unmeasured | G9: act in view, act in front and foreground refuse. Hidden flows wait for probe 11 | Probe 11 |
| A3 | Working in another app, typing or clicking in Grok Bot | Hidden presses don't move focus (Measured, S3). Hiding a Messages that isn't frontmost shouldn't change the front app (assumed). An unhide may raise Messages above the user's app (Reported, vorssaint-utils PR 3181) or activate it, and then a click aimed at Grok Bot lands in Messages. An in-view press may activate or raise Messages (unmeasured). In foreground mode, a user who pauses 2 s and then types during the roughly 450 ms activation sends keys into Messages | G1, G4 and G16 gate on mouse, modifiers and the pointer, not on keys, because a Messages that isn't frontmost can't take keys. G4 watches the front app for 1 s after the unhide and gives focus back. G10 gives focus back after a fast takeover by keys | Stacking after the unhide (probe 1). Whether an in-view press activates Messages (probe 4) |
| A4 | Dragging, holding a mouse button, or the pointer over a Messages window | Messages hides or switches chats while a drop is on its way to it, or a click lands on a row as it changes | G1's mouse gate: no button, drag or scroll event in 2 s, `NSEvent.pressedMouseButtons` 0, and the topmost window under the pointer isn't Messages' | A drag that starts after the check drops on whatever lies underneath. Nothing is sent |
| A5 | Watching or reading with no input: video, a full-screen app, reading Messages | The gate passes. In view, the visible chat switches to the target and back. Foreground activation may switch Spaces | G1 never hides an on-screen window. G2 doesn't switch the chat of a visible window that is scrolled back. G6 waits while the front app is full screen | The visible switch, which the requirement accepts. Nothing tells watching apart from away |
| A6 | Input the monitor can't see: dictation, Voice Control, Screen Sharing, Universal Control, events another tool posts at the session tap. Also input that doesn't reset the timer: a held modifier, a held button with a still pointer, trackpad gestures | No effect on hidden flows. In view, a click through Screen Sharing can land mid-press. In front and in foreground mode, dictated text can land in the target field | G1 also requires no modifier held and no button pressed. G5 presses only a bubble, never a row, and stays off until probe 13 shows which sources reset the HID idle time. The field checks run before Return | Probe 13 |
| A7 | Looking at a visible Messages while another app is in front | The visible chat switches to the target and back | Act in view keeps the window in place. G3 restores in view. G2 refuses a switch while the user is scrolled back | A brief visible switch |
| A8 | Typing in a frontmost Messages, in their own chat or in the target chat | A row press would move their keys into the target chat's composer, where a Return sends them | The bridge never presses a row on a frontmost Messages. By default it waits for Messages to leave the front. Under the in-front opt-in it presses only a bubble in the chat already selected, after probe 7 shows focus stays put | Monitored input is covered only if probe 7 holds. Input the monitor can't see (A6) isn't covered, which is why G5 waits for probe 13 |
| A9 | A draft, a new message, search, a thread view, edit mode, a picker, a sheet or a recording open | A chat switch or an Escape loses or changes it | G2 refuses before anything is pressed on every path, including foreground step 1 before `selectChat`. It also refuses before the hide when AX already lists the window (G1) | The user has to finish or clear it. The result says which one |
| A10 | Sending from the Mac at the same moment | A user Return while the bridge's text sits in the reply field sends it, and a retry sends it again | G10: after any takeover that follows a field write, the key is held on any new from_me row in the target chat | None for monitored input |
| A11 | Changing Messages mid-action: showing, hiding, minimizing, closing or quitting it, switching chat, Space or app | The bridge's next press lands in a window the user now uses. Its unhide fights the user's hide. A relaunch undoes their quit. The user shows Messages while it holds the target chat | The recheck before each press. Restore steps run only if the state is still what the bridge left. No relaunch to restore anything. G8 cancels on any show. G15's notice names the chat Messages shows | Whatever was already done stays done: one tapback, a selected chat |
| A12 | Other devices and senders: an iPhone reply, reaction, edit or unsend, an incoming message, Share, Siri, a banner inline reply | The target row text changes. The earlier chat's row text changes. An iPhone reaction between the reread and the press gets toggled off. New messages arrive in the earlier chat | P2 and P3 as today. G3 holds the earlier chat by its chat.db ROWID and rebuilds its row text at restore time. G3 skips the restore press when new unread messages arrived there | The toggle window, small as today |
| A13 | Answering the approval panel | The click holds the idle gate for 2 s. A refusal after approval spends the approval | G13: a read-only sample before the panel, and the approval kept for one retry when nothing was pressed | Approvals for actions that reached `invoking` are still spent |
| A14 | Window-manager tools (Rectangle and Raycast are installed here) move, tile, hide or re-tile Messages during an action | A window moves under a press, or gets re-tiled after the unhide | The recheck before each press reads the bounds. G4 compares the bounds after the unhide and notes a change | Probe 1 runs with Rectangle running |
| A15 | Screen sharing, presenting or recording | Act in view, act in front and foreground show the target chat during the share. Hide, act, unhide shows nothing | None automatic. This isn't detectable with public API (assumed). The in-front and foreground opt-in dialogs name the risk | The user's choice to share |

## 4. The matrix

Flows used in the cells. Every UI flow runs the G2 preconditions before its first press, and before its hide when AX already lists the window (G1). Every UI flow runs the G3 chat restore after its last press.

- **As today.** No change.
- **Act hidden.** Today's hidden path, with the press skipped when the target is already selected, then the earlier chat restored while hidden.
- **Act in view.** Messages stays shown and not frontmost. The G16 gate and final checks run before every press, then G3 restores the chat in view. Waits for probe 4.
- **Hide, act, unhide.** Only where nothing of Messages is on screen. The checks that make the hide safe and the chat.db work that needs no window run before the hide. When AX already lists the window, so do the reads of the window's contents and the chat.db queries on the selected row. Then the G1 gate, the hide, the recheck, those reads and queries if AX reaches the window only now, act hidden, G3, and the G4 gated unhide. Every exit after the hide, refusals and AX errors included, runs G3 and G4.
- **Launch hidden, act, quit later.** `open -g -j -b`, capture the chat Messages reopened on, act hidden, G3, then the G8 quit.
- **Relaunch hidden, act.** Today's no-window path, with the no-window checks from state 8. Capture the chat Messages reopened on, act, G3, leave hidden. No quit later.
- **Act in front (separate opt-in).** Messages is frontmost and the target chat is already selected. Only the bubble action runs, under G5.
- **Wait for front.** Wait up to 30 s, without holding the queue, for Messages to leave the front, then pick the flow for the new state. Otherwise refuse with `busy: Messages is in use` and `fix: switch to <target> in Messages, or leave Messages`. The approval stays valid for one retry (G13).
- **Foreground.** Today's steps 1 to 7 from a hidden start, with the G2 checks before `selectChat`, then the chat restored while hidden after the finish hides Messages.
- **Foreground from view.** G6: no hide, the step 1 checks and the row press in view, activation, a finish that returns focus to the earlier app with Messages left showing behind it, then the G3 chat restore in view under G16.
- **Hide, foreground, unhide.** G1, then foreground, then G3 while hidden, then G4. Only once probe 12 passes. On a fail the cell refuses, with no activation fallback.
- **Foreground in front.** Messages is already frontmost and the target chat is already selected, so there is no activation, no hide at the end and no focus restore (G6).

"Today's busy" below means `busy: Messages is open` without the ⌘H fix line.

### Process and account

| # | State | Reads | Plain and file sends | Tapback and unsend | Edit and threaded reply |
| --- | --- | --- | --- | --- | --- |
| 1 | Not running | as today | launch hidden, send, quit later | launch hidden, act, quit later | launch hidden, foreground, quit later. The bridge's own activation doesn't cancel the quit. A takeover does |
| 2 | Launching | as today | as today. The event's 10 s timeout and chat.db decide | wait up to 10 s for the launch to finish (G7), then decide again. Never quit. A launch the user started gets no quit later | same as tapback |
| 3 | Account not ready | as today | as today | as today (`not_loaded` when no rows) | as today |
| 4 | Hung or slow | as today. `doctor`'s AX read can take 2 s | as today. Timeouts are advisory and chat.db decides | as today: fail closed | as today |
| 5 | Quits or crashes mid-action | as today | as today: `not_running`, then one hidden cold start | stop. The result comes from chat.db and names the restore items it skipped. No relaunch to restore | as today: takeover or chat.db result. No relaunch |
| 6 | Background element | as today | as today | the flow for its window state. The plan records the activation policy and pid, and G4 skips the unhide if the pid changed | same |

### Hidden

| # | State | Reads | Plain and file sends | Tapback and unsend | Edit and threaded reply |
| --- | --- | --- | --- | --- | --- |
| 7 | Hidden, one window | as today | as today | act hidden | foreground |
| 8 | Hidden, no window | as today | as today | relaunch hidden, act, leave hidden, only when every check in state 8's detection holds. Otherwise as 17. A draft held for a closed window is a known gap until probe 6's quit leg | relaunch hidden, foreground |
| 9 | More than one window | as today | as today | act hidden, after G1 hides Messages if needed, only when no other window has a `TranscriptCollectionView` or `messageBodyField`. Settings passes. A conversation window refuses with `busy: several Messages windows`. A window the driver can't classify keeps today's one-window error | refuse: `busy: several Messages windows` |

### Not hidden, not frontmost

| # | State | Reads | Plain and file sends | Tapback and unsend | Edit and threaded reply |
| --- | --- | --- | --- | --- | --- |
| 10 | On screen, current Space | as today | as today | act in view, once probe 4 passes. If probe 4 shows a press activates or raises Messages: hide, act, unhide, only when no window above Messages overlaps it and probe 1 passes for this state, waiting up to 30 s for that, then `busy: Messages is in use`. Until probe 4: today's busy | foreground from view, once probes 4 and 12 pass. Until then today's busy |
| 11 | Minimized | as today | as today | hide, act, unhide, once probes 1 and 2 pass. Until then today's busy | hide, foreground, unhide, once probe 12 passes. On a fail: `busy: Messages is minimized` |
| 12 | On another Space | as today | as today | hide, act, unhide, once probes 1 and 2 pass. If AX still shows 0 windows after the hide: as 17. Never quit, and no private API. If probe 2 fails: `busy: Messages is on another Space` with `fix: quit Messages and retry` | hide, foreground, unhide, once probe 12 passes. On a fail: `busy: Messages is on another Space` |
| 13 | Split View, current Space | as today | as today | never hide. Act in view, once probe 4's Split View leg passes. Until then `busy: Messages is in Split View` | foreground from view, once the Split View legs of probes 4 and 12 pass. Until then `busy: Messages is in Split View` |
| 14 | Full screen or Split View in another Space | as today | as today | refuse: `busy: Messages is full screen`. Hide-based flows stay refused unless probe 1 shows that a hide and unhide keep the Space, its place in Mission Control and the Split View partner | same |
| 15 | Stage Manager on | as today | as today | refuse: `busy: Messages is in Stage Manager`, until probe 1 passes with Stage Manager on. Never hide, never quit | same |
| 16 | No window, still running | as today | as today | until probes 3 and 6 pass: `busy: Messages window not reachable` with `fix: quit Messages and retry`. After them, with nothing listed: relaunch hidden, act, leave hidden. With a window listed: as 12 | same, with foreground |
| 17 | Listed, never reachable | as today | as today | `busy: Messages window not reachable` with `fix: quit Messages and retry`. Once probe 6 shows drafts survive a quit: quit, relaunch hidden, act, and leave hidden with `Messages left hidden` | same, with foreground |
| 18 | Outside every display | as today | as today | hide, act, unhide, once probe 1 includes this case, since nothing is visible either way. Until then today's busy | hide, foreground, unhide, once probe 12 includes this case |

### Frontmost and changing

| # | State | Reads | Plain and file sends | Tapback and unsend | Edit and threaded reply |
| --- | --- | --- | --- | --- | --- |
| 19 | Frontmost with a window | as today | as today (probe 9) | target already selected and the in-front opt-in on: act in front, once probes 7 and 13 pass. Otherwise wait for front | target already selected: foreground in front. Otherwise wait for front |
| 20 | Frontmost, no window | as today | as today | wait for front, then by the new state | same |
| 21 | Put in front by foreground mode | as today | wait in the queue, as today | wait in the queue | wait in the queue |
| 22 | Visibility changing | as today | as today | wait up to 1 s for the samples to agree, then decide. Mid-action, the recheck stops the next press, the restore skips anything the user changed, and G15 shows the notice if Messages now shows the target chat | same. The ownership check catches it |
| 23 | Unreadable | as today | as today | refuse as today. An unknown three-valued read refuses every cell that depends on it | same |

### Inside the window

| # | State | Reads | Plain and file sends | Tapback and unsend | Edit and threaded reply |
| --- | --- | --- | --- | --- | --- |
| 24 | Sheet, popover, alert, menu, Quick Look, poster editor | as today | as today | refuse: `busy: Messages dialog open` | refuse: `busy: Messages dialog open` (new on this path) |
| 25 | Draft in the selected chat | as today | as today (probe 9) | target already selected: act with no switch. Otherwise `busy: draft in Messages` until probe 6 passes | refuse: `busy: draft in Messages`, even when the target chat is selected |
| 26 | New message in progress | as today | as today | refuse: `busy: new message in Messages` | same |
| 27 | Thread view open | as today | as today | refuse: `busy: edit in progress` (new on this path) | as today |
| 28 | Edit mode open | as today | as today | refuse: `busy: edit in progress` (new on this path) | as today |
| 29 | Search active | as today | as today | refuse: `busy: search in Messages` | same |
| 30 | Audio recording or playback | as today | as today | refuse: `busy: audio in Messages` | same |
| 31 | User scrolled back | as today | as today | a window on screen and an action that switches chats: wait up to 30 s for the window to leave the screen, then `busy: Messages scrolled back`. Target already selected: act. Nothing on screen: act, with the note `scroll position may have moved` | same |
| 32 | Unread in the selected chat | as today | as today | the action switches chats and Messages started unhidden: `busy: unread messages in Messages`. Messages started hidden or quit: act, skip the restore press, and add `chat not restored: unread messages in <earlier chat>` | same |
| 33 | Selected chat not identified | as today | as today | Messages started unhidden: `busy: Messages chat not identified`. Started hidden or quit: act with no restore, and add `chat not restored`. After a launch with no row selected, there is nothing to restore | same |
| 34 | Target already selected | as today | as today | skip the row press, check the signature, act. Nothing to restore | same |
| 35 | Target row not usable | as today | as today | as today | as today |

### System

| # | State | Reads | Plain and file sends | Tapback and unsend | Edit and threaded reply |
| --- | --- | --- | --- | --- | --- |
| 36 | Screen locked | as today | as today (measured while locked) | act hidden, hide, act, unhide, and relaunch, once probe 11 passes. Until then `busy: screen locked`. Act in view and act in front always refuse | refuse: `busy: screen locked` |
| 37 | Display asleep or screen saver, unlocked | as today | as today | the hidden flows, once probe 11's display and screen saver legs pass. Until then `busy: display asleep`. Act in view and act in front refuse | refuse: `busy: display asleep` |
| 38 | Not on the console | as today | as today | refuse: `busy: session not active` | same |
| 39 | User in another app's full-screen Space | as today | as today | the flow for Messages' own state. The user can't see Messages there, so the hidden flows change nothing they see | wait up to 30 s, without holding the queue, for the front app to leave full screen, then `busy: full-screen app in front` |
| 40 | Mission Control, App Exposé, Show Desktop, app switcher | as today | as today | flows that hide, unhide or press in view wait while an overlay shows or a modifier is held, up to 30 s, then `busy: user active`. Act hidden on a Messages that is already hidden runs | wait the same way, then `busy: user active` |
| 41 | Display reconfiguration | as today | as today | as 22: stop before the next press, read the window state again, and restore only what still matches the plan | same |
| 42 | Wake, network down | as today | as today | as today | as today |
| 43 | App Nap, Low Power, thermal | as today | as today | as today. The 2 s AX timeout fails closed | as today. The 3 s deadline fails closed |
| 44 | Secure Event Input | as today | as today | as today for the hidden and in-view flows. Act in front refuses until probe 17 passes | refuse: `busy: secure input on`, until probe 17 passes |

## 5. The restore contract

Before the first effect, the bridge records a restore plan from its state sample. When AX can read the window only after the hide, as in state 12, the bridge adds the selected chat to the plan after the hide and before the first press (G1). After the last press, it puts back each item it changed, in this order:
1. the chat
2. hidden or shown
3. the front app
4. later, running or quit

Foreground mode is the exception. Its finish first takes Messages out of the front, by today's hide or by returning focus, and only then restores the chat, because the bridge never presses a row on a frontmost Messages (G6).

It restores an item only if the item still has the value the bridge left. If the user changed it, the user's choice stands. It unhides only if the chat restore succeeded or had nothing to do. The restore runs before the chat.db verification wait, so the user's state comes back within the action span, not after it. The result names each item that wasn't restored. The plan lives in memory. The journal holds only flags, the Messages pid, the earlier chat's ROWID and a digest of its row description (G12), because it never stores message text, and row descriptions contain message previews.

| Item | Recorded from | Restored by | Restorable |
| --- | --- | --- | --- |
| Running or quit | `NSRunningApplication`, and whether the bridge started Messages from not running | A quit after 10 quiet minutes under G8 | Yes. The Apple Event quit and the hidden relaunch were measured (S3b) |
| Background element | `activationPolicy` and the pid | Nothing. The bridge doesn't activate or relaunch Messages to undo it | Not needed. G4 skips the unhide if the pid changed |
| Hidden or shown | `isHidden` | `unhide()` under G4, only if the bridge hid Messages, it is still hidden with the same pid, and G3 restored the chat or had nothing to do | Assumed. Probe 1 |
| Front app | `NSWorkspace.frontmostApplication` | Hiding, unhiding and in-view presses shouldn't change it. G4 watches it for 1 s after the unhide and reopens the recorded app if Messages took the front with no input. Foreground mode keeps today's focus restore | Measured for foreground mode (S3). Assumed for the rest. Probes 1 and 4 |
| Selected chat | The row with `AXSelected`, resolved to one chat.db chat by its ROWID, plus that chat's signature and newest loaded bubbles | `selectChat` on that chat, with its description rebuilt from chat.db at restore time, the lookalike rule and the signature check | Usually. Not when the chat can't be identified (33), has unread incoming messages (32), or isn't loaded, or when no row was selected |
| Selected chat after a bridge launch or relaunch | The `AXSelected` row right after the launch, since Messages reopens on the last chat | G3, before Messages is left hidden or quit under G8 | Usually. Probe 5's cold-launch leg |
| Composer draft in the selected chat | `messageBodyField` value, read and never written | Messages' own draft keeping | Unknown (probe 6). Until probe 6 passes, a draft blocks a chat switch |
| Attachment-only draft | Can't be read | Nothing | No (probe 6) |
| New message in progress | AX (state 26) | Nothing | No. The action refuses |
| Minimized | `AXMinimized` while unhidden, three-valued | Unhiding keeps it, if probe 1 shows that | Unknown |
| Space and display | Can't be read with public API | Unhiding keeps it, if probe 1 shows that. Otherwise Messages stays hidden with `Messages left hidden`, and only in states with nothing on screen where probe 1 shows the Dock tile and the window's Space survive. A state with an on-screen window becomes act in view or a refusal, decided before any hide | Unknown |
| Full screen, Split View | `AXFullScreen`, bounds | Nothing needed. The bridge never hides them | Not needed |
| Stage Manager placement | Can't be read | Nothing needed. The bridge never hides Messages while Stage Manager is on | Not needed |
| Window position and size | CG bounds | Hiding shouldn't move the window (assumed). G4 compares the bounds after the unhide and notes a change | Assumed. Probe 1 |
| Stacking order | On-screen front-to-back order | Avoided by not hiding an on-screen window. The state 10 hide fallback runs only when no window above Messages overlaps it | Not needed while the in-view flow holds |
| Scroll position | The newest bubble's frame against the transcript, or the scroll bar value | Avoided. The bridge doesn't switch the chat of a visible window that is scrolled back | Not restorable, only protected |
| Thread view, edit mode, search, pickers, sheets, recordings | AX | Nothing | No. The action refuses before acting |
| Read state and read receipts | chat.db | Nothing. A receipt can't be recalled. The restore press is skipped when the earlier chat has unread incoming messages | No |
| Keyboard focus inside a frontmost Messages | `AXFocusedUIElement` | Nothing needed. The bridge never presses a row on a frontmost Messages, and the bubble press must leave focus where it was | Probe 7 |

## 6. Safety guards

Existing guards keep their names from the earlier maps:
- P2: the element fingerprint
- P3: chat targeting and the signature check
- P5: the reaction reread
- P6: the idle gate
- P8: the ownership check
- P10: the checks right before Return
- P11: the takeover
- P16: send correlation

The final-check rule in BUILD-PLAN entry 50 still holds for every new press, write, hide and unhide. Each one runs its check right before the effect, with no AX read in between. No call site passes an empty check `{}` where the driver's own hidden-window check has been removed.

**G1. Input gates and the hide**
- Two gates. The mouse gate requires all of these:
  - no mouse button, drag or scroll event for 2 s
  - `NSEvent.pressedMouseButtons` 0
  - no modifier held in `CGEventSource.flagsState(.hidSystemState)`
  - no Dock overlay window on screen (state 40)
  - the pointer check below
- The full gate is the mouse gate plus no key or flags event for 2 s, which is today's P6. The mouse gate is for a Messages that isn't frontmost, because it can't take keys, so typing in Grok Bot doesn't delay the action. The full gate is for activation and for G5. Both wait up to 30 s without holding the queue, then return `busy: user active`.
- The pointer check reads the pointer with `CGEvent(source: nil)?.location`, which uses the same coordinates as `kCGWindowBounds`. It finds the topmost on-screen window at that point in the front-to-back list, and blocks only when that window belongs to Messages. `NSEvent.mouseLocation` has a bottom-left origin and isn't used.
- The bridge hides Messages only when nothing of it is on screen (states 11, 12, 18, and 16 or 17 for the reachability test), or in the state 10 fallback from section 4. It never hides:
  - a frontmost Messages
  - a full-screen or Split View Messages, by `AXFullScreen` through `AXMainWindow` or the full-height bounds test
  - any Messages while Stage Manager is on
- Before the hide, the bridge does the checks that make the hide safe and the chat.db work that needs no window. The checks come from the state sample: the window counts, `AXMainWindow`, `AXFullScreen`, Stage Manager and the front app. The chat.db work is the target chat's lookup, its expected row text and signature, and the expected text of every chat for the lookalike rule. The reads of the window's contents are the G2 checks, the target row and bubble lookups, and the earlier chat's capture. They include the chat.db queries on the selected row: the chat it resolves to, that chat's ROWID, signature and highest message ROWID (G3), and G2's unread check. When AX already lists the window, as reported for state 11, they run before the hide, so a refusal there hides nothing. When AX lists no window until the hide, as in state 12, they run after the recheck and the reachability test below, and the bridge journals the capture (G12) before any press. In that case they count toward the 2 s cap. The driver repeats its fingerprint read before each press anyway.
- The bridge journals the `hid` flag and the Messages pid (G12), hides, and polls `isHidden` for up to 1 s. It then reads the state again. Messages must be hidden, not frontmost, with exactly one conversation window and nothing on screen, and the front app must be the one recorded before.
- The span from the hide to the target press is capped at 2 s. On overrun the bridge skips the effect, restores the chat if it changed, and unhides.
- If AX shows 0 windows after the bridge's own hide while the all-Spaces count is 1 or more, the bridge reads `AXMainWindow` and `AXFocusedWindow`. If both are nil, it unhides through G4 and returns state 17's result.
- It never quits a Messages it hid, or a Messages that may have a window. That covers an all-Spaces count of 1 or more, an unknown count, Stage Manager on, a non-nil `AXMainWindow` or `AXFocusedWindow`, and a launch not finished. That window may hold the user's draft.
- Every exit after the hide, including refusals and AX errors, runs G3 if a row was pressed, then G4.

**G2. Preconditions before any UI press on every path, and before the hide when AX already lists the window (G1).** These are new on the hidden path. Foreground step 1 gets them too, before `selectChat`, because today it presses the target row before it reads the composer, the edit field and the thread view (ForegroundRunner.swift:206-226).
- No edit field, thread view, new message, search text, sheet, popover, alert, open menu, Quick Look, poster editor or audio recording.
- Exactly one row reads `AXSelected`, and it resolves to exactly one chat.db chat (G3). A cold launch or relaunch by the bridge isn't exempt: the bridge captures the chat Messages reopened on. If no row is selected after a launch, there is nothing to restore.
- If the target isn't the selected chat:
  - The selected chat's composer must be empty, otherwise `busy: draft in Messages`. This lasts until probe 6 shows that drafts survive an AX chat switch. After that, the bridge switches and checks after the restore that the draft value came back.
  - When Messages started unhidden, the selected chat must have no unread incoming messages in chat.db, otherwise `busy: unread messages in Messages`.
  - When a window is on screen, the user must not be scrolled back in it (state 31).
- For every foreground start, the selected chat's composer is read before any press.
- The final check of every hidden press becomes "hidden, and matches the bridge's plan". Today it is "hidden because the user hid it".

**G3. Chat restore**
- Capture, before the first press:
  - the selected row's exact description
  - the chat.db chat it resolves to, matched against `RowDescriptionBuilder`'s expected text for every chat with the lookalike rule `selectChat` uses
  - that chat's ROWID, signature and newest loaded text bubbles
  - the highest message ROWID seen in it
- If the selected row resolves to a group chat, the restore uses the same row press and checks. Group row text rebuilding is untested, so a mismatch reads as state 33.
- Right before the restore press, the bridge checks chat.db for unread incoming rows in the earlier chat above the recorded ROWID. If there are any, it skips the press and adds `chat not restored: new messages in <earlier chat>`.
- The final check, right before the press:
  - The path check holds: still hidden and matching the plan on the hidden path, or G16's checks in view.
  - The selected row still resolves to the target, so the user hasn't picked another chat.
  - Exactly one loaded row equals the earlier chat's description, rebuilt from chat.db at that moment.
- The restore calls `selectChat` on the resolved chat, so the signature check runs. The captured bubbles must still be the newest ones, though bubbles that arrived since are allowed.
- Any failure stops the restore. Nothing more is pressed. The result adds `chat not restored: <target> is selected`, or `an unknown chat is selected` if the signature check failed after the press. If the bridge hid Messages, Messages stays hidden with `Messages left hidden`, and G4 doesn't run. If a window is visible, G15 shows its notice.
- The bridge never picks a row by a partial match.
- After a cold launch or relaunch, the same capture and restore run before Messages is left hidden or quit.
- The transcript wait after the restore press stays before the unhide, so a wrong chat is never shown.

**G4. Unhide**
- Only if all of these hold:
  - the plan says the bridge hid Messages
  - Messages still runs with the same pid and is still hidden
  - G3 restored the chat or had nothing to restore
- If the user has shown Messages already, the bridge skips this step.
- Before the call, the mouse gate runs. The pointer check also blocks when the pointer sits inside the recorded bounds of a window the unhide brings back on the current screen. The final check runs right before the call. If the gate doesn't open within 30 s, Messages stays hidden with `Messages left hidden`. Clicking its Dock icon shows it again.
- After the call, the bridge reads the front app every 1/64 s for 1 s, as the foreground machine does.
  - If Messages came to the front with no input since the unhide, the bridge runs today's focus restore at once (`open -b <recorded front app>`) behind the ownership check, and adds `Messages came to the front`.
  - If input arrived first, it posts nothing and doesn't touch the composer. It adds `Messages came to the front` and a note that typing may be in the user's own chat's composer.
- It compares the window bounds and the minimized state with the plan and notes a difference.
- Probe 1's pass criterion is that the front app stays unchanged during and after the unhide in every state, and that stacking against the front app's window doesn't change. A state that fails gets its cell changed before shipping:
  - a state with nothing on screen becomes "leave hidden", only if probe 1 shows the Dock tile and the window's Space survive
  - a state with an on-screen window becomes act in view or a refusal, decided before anything is hidden

**G5. Act in front on a frontmost Messages (separate opt-in)**
- Runs only when all of these hold:
  - the in-front setting is on, under its own consent (section 9)
  - Messages is frontmost with one conversation window
  - the target chat is already the selected one (state 34), and the action is a named bubble action
  - probe 7 has shown that the bubble press leaves keyboard focus where it was, and probe 13 has shown which input sources reset the HID idle time
  - the screen is unlocked, the display awake, the session on the console, and Secure Event Input off
  - the full gate and G2 have passed
- The full-gate pass takes the place of the activation check. From that moment, the ownership check (P8) runs before the press and is the press's final check.
- No row is pressed, before or after, so there is nothing to restore.
- In every other frontmost case the bridge waits for front.

**G6. Foreground actions from any state**
- **Hidden start.** Today's steps 1 to 7, with G2 before `selectChat`. The finish hides Messages as today, then runs G3 while hidden. Messages stays hidden, as it started.
- **From view** (states 10 and 13, once probes 4 and 12 pass). There is no G1 hide. Step 1's checks and the row press run in view behind G16, then activation runs behind the full gate. At the finish, the bridge presses Escape as today, then returns focus with `open -b <earlier app>` and leaves Messages showing behind it. Once the earlier app is in front, Messages is shown and not frontmost again, and G3 restores the user's chat in view under G16's gate and final check. So no row is pressed while Messages is frontmost. Only if the earlier app doesn't come to the front within 2 s does it fall back to today's finish hide, then G3 while hidden, with `Messages left hidden`. On a takeover it presses nothing more, so the user sees the target chat they are typing in.
- **Nothing on screen** (states 11, 12 and 18). G1, then the hidden start, then G3 while hidden, then G4. Probe 12 must pass first. A pass means no deminimize, no Space switch, no exit from the user's full-screen Space, and a Return that still lands within 3 s of `t_front`. On a fail the cell stays a refusal, with `busy: Messages is minimized` or `busy: Messages is on another Space`, and no activation fallback.
- **Frontmost start**, only when the target is already selected. The bridge calls `markActivationCheck` and requires 2 s with no input right before step 1. `t_front` is that moment, so the 3 s Return deadline still holds. Every press passes the ownership check as its final check, which needs a `finalCheck` parameter on `ChatTargeting.selectChat` and a mode on `LiveMessagesAX.press(row:)` that runs the caller's check in place of `requireHiddenWindow`. The finish presses Escape as today. It doesn't hide Messages or restore focus. In every other frontmost case the bridge waits for front.
- Foreground refuses any state with more than one real window, because Messages decides which window `open -b` brings forward and the posted Return could go to it.
- Foreground waits while the user is in another app's full-screen Space (state 39) and refuses while Secure Event Input is on until probe 17 passes.

**G7. Launch in progress.** If `isFinishedLaunching` is false, the bridge waits up to 10 s, then decides again. It never quits a Messages that is still launching. The plan marks a launch the user started, and G8 never quits it.

**G8. Quit later.**
- The bridge sets the `launched` journal flag only when it started Messages from not running (state 1), or when setup launched it hidden. A relaunch in states 8, 16 or 17 never sets it.
- It quits after 10 minutes with no bridge request of any kind, and the timer doesn't run while a `wait` is open. It quits only if all of these hold:
  - Messages stayed hidden and the user never brought it to the front. The bridge samples this at each request and on the NSWorkspace activate and unhide notifications. Its own foreground activation doesn't count, but a takeover does.
  - G3 has restored the chat Messages reopened on, or there was nothing to restore.
  - No staged file is waiting for transfer_state 5.
  - The pointer isn't over the Dock's window at the final read.
- To quit, the bridge takes a queue ticket, reads the state again, sends today's Apple Event quit, and waits for the exit (`Limits.quitWait`). Only then does it release the ticket. A send that arrives meanwhile waits, then cold starts Messages hidden, so its `tell` never reaches a Messages that is exiting (Scripts.swift:12-15).
- Any show by the user cancels the quit.

**G9. Lock, display and session.** The bridge reads the lock, display sleep, screen saver and console state before each UI action and again before each press. When the screen is locked, the display asleep, the screen saver running, or the session off the console, act in view, act in front and foreground refuse. The idle gate passes trivially there, and activation and Return behind the lock are unmeasured. The hidden flows refuse too until probe 11 passes for that leg.

**G10. Takeover fixes.** The any-state paths make two existing gaps more likely, so both get fixed.
- **Double send.** After any takeover that follows a field write, the bridge checks chat.db for up to 10 s. For a reply, it looks for any new from_me row in the target chat above the snapshot. For an edit, it looks for any change to date_edited on the target row. It doesn't match by text digest, because the user may have typed into the field before their Return. If chat.db shows one, the result is that row's result plus `user took over`, and the result holds the key. If the bridge wrote the field and didn't reset it, and the field reads back empty or at its earlier value, the result is `may_have_completed`, which also holds the key. This closes the case where the user's Return sends the agent's text and a retry sends it again (ForegroundRunner.swift:587-605, Results.swift:151-165).
- **Keys left in Messages.** Suppose the bridge activated Messages, and the takeover came from keys alone with Messages still frontmost. After the one field reset, the bridge runs today's focus restore only if the first key arrived within about 0.5 s of `t_front`, before the user could react to Messages appearing. For later keys, and after a click or an app switch, it leaves focus alone, as today.

**G11. Result notes.** `error: Messages became visible` is replaced by a comparison of the end state against the plan. A difference the bridge caused, such as a window it showed that wasn't showing before, gets an error note. A change the user made gets none.

**G12. Journal and crash.**
- Before the first hide or press, the journal records the Messages pid, because the plan lives in memory and recovery needs it to tell whether Messages is the same process. With the `hid` and `launched` flags and their times, the journal also records the earlier chat's chat.db ROWID and a digest of the captured row description. It records no text.
- After a crash, recovery never unhides or quits Messages on its own, because the user may have moved on.
- If Messages is still hidden, its pid matches the one the journal recorded, and its selected row resolves to the target chat, recovery runs the G3 restore once while Messages is hidden. Otherwise, including when the entry has no recorded pid, it leaves Messages alone and shows G15's notice.
- `doctor` says Messages may be hidden and showing another chat.
- A quit-later timer lost in a crash leaves Messages running hidden, which is harmless.

**G13. Approval.**
- Approval still comes before the queue and before every wait in this document.
- Before opening the panel, the bridge reads a read-only state sample. For states that waiting can't fix, it returns busy with no panel, and the recheck after approval stays as today. Those states are 9 (a second conversation window), 13 (until probe 4), 14, 15, 17, 23, 24, 25 when the action must switch chats, 26, 27, 28, 29, 30, 36, 38, and 44 for foreground actions.
- If a busy after approval proves nothing was pressed, meaning nothing reached `invoking`, the approval stays valid for the same idempotency key and binding until its 10-minute expiry. One retry then runs without another panel.
- When the panel opens over a frontmost Messages, it says the action runs once Messages isn't in front.
- A refusal after the bridge reached `invoking` still spends the approval, as today.

**G14. Three-valued window reads.** The new `AXMinimized`, `AXFullScreen`, `AXSubrole` and `AXSelected` reads return true, false or unknown. `attributeUnsupported` (-25205), `noValue` and any error count as unknown, and the driver's `bool(...) ?? false` pattern isn't used for them (AX.swift:305-313, 449). Every cell that depends on a read refuses when it is unknown. A window counts as not full screen only when the bounds test and `AXFullScreen` agree.

**G15. The bridge's notice.** When the bridge leaves a visible Messages on a chat the user didn't pick, it shows a non-activating notice in the approval panel's window style. That happens when G3 fails or is skipped on a visible window, when the user showed Messages mid-action, and when crash recovery can't restore. The notice names the chat Messages now shows and never takes focus. Result notes go to the agent, so without this the user wouldn't know.

**G16. Act in view.**
- Runs only when all of these hold:
  - Messages is unhidden and not frontmost
  - its one conversation window is on screen on the current Space
  - Stage Manager is off
  - the window isn't full screen, or is in Split View only after probe 4's Split View leg
  - probe 4 has passed
- The mouse gate (G1) and G2, with the scroll rule, pass first.
- Each press takes a final check, right before `AXPress` with no AX read between. The check confirms that Messages is still not frontmost, still unhidden with the same window bounds, the topmost window under the pointer isn't Messages', no button is pressed, no modifier is held, and no mouse event arrived since the gate. It is passed to `press(row:)` in the mode that replaces `requireHiddenWindow`.
- G3 restores the chat in view.
- If Messages becomes frontmost mid-action, the user clicked it. The bridge presses nothing more and shows G15's notice if the target chat is showing.

**G17. Display reconfiguration.** The bridge registers `CGDisplayRegisterReconfigurationCallback`. A reconfiguration while a plan is open counts as state 22. The bridge stops before the next press, reads the window state again, and restores only what still matches the plan. Probes 1 and 3 record whether the window frame intersects any `NSScreen`.

| Invariant | Covered by |
| --- | --- |
| No message to the wrong chat | P3 as today. G3 restores by chat.db identity with the lookalike rule and the signature check. No row press on a frontmost Messages (G5, G6). G10's chat.db check. G15 tells the user when a visible Messages is left on another chat |
| No double sends | Idempotency and P16 as today. G10 holds the key on any new from_me row after a takeover |
| Never lose or send the user's draft | G2's draft refusal until probe 6, on every path including foreground step 1 before the press. G1 never quits a Messages it hid or one that may have a window. G8 quits only a Messages the bridge launched and the user never saw. Known gap: the state 8 quit can't read a draft for a closed window until probe 6's quit leg. It is today's measured path and has no composer to read |
| User keystrokes never land where the user didn't choose | No row press on a frontmost Messages. G1, G4 and G16 never act on a frontmost Messages and watch the front app after the unhide. G5 is opt-in, presses only a bubble in the selected chat, and waits for probes 7 and 13. G10 returns focus only after a fast key. Left over: input the monitor can't see (A6) |
| Every external action stays behind its approval | G13. In allowlisted chats the hide, switch and unhide run with no panel, so the restore contract is the only protection there |
| Fail closed when a state can't be read | State 23 refuses. G14 makes unknown readings refuse. G1 refuses when AX shows 0 windows after the hide. G2 refuses when the selection can't be identified on a visible Messages. Full screen, Split View and Stage Manager refuse until their probes pass |
| Restore the user's state afterward | Section 5, G3, G4, G8, G12, G15 |

## 7. Design options

**Option 1. How to act on an unhidden Messages that isn't frontmost (states 10 to 18)**
- **(a) Hide, act, unhide everywhere.**
  - For: it reuses the only measured path, since every S3 action ran hidden.
  - Against: an on-screen window disappears for the action span, which is two row presses, two transcript waits and one named action. The code's timeouts allow about 5 s, and nobody has timed it. Unhiding may raise the window above the user's app (Reported, for an app that wasn't hidden). Hiding a Split View or Stage Manager window can break the user's layout (Apple Support, MacMost). That AX reaches a hidden window on another Space is Assumed, and three reports say AX lists only the current Space's windows.
- **(b) Act in place everywhere.**
  - For: no window ever disappears.
  - Against: a window on another Space or in a full-screen Space elsewhere can't be reached without the private `_AXUIElementCreateWithRemoteToken` (alt-tab-macos issue 1324). The in-place press is unmeasured.
- **(c) Open the target chat in a second window and act there.**
  - Against: unknown Space, focus and key-window behavior. A reported side effect leaves the main window showing "1 Conversation Selected". It also adds a second window, which the driver refuses.
- **(d) Split by state.** Act in view where the window is on the current screen (10, 13). Hide, act, unhide only where nothing of Messages is on screen (11, 12, 18, and 16 or 17 when reachable). Refuse full screen elsewhere and Stage Manager.
  - For: no on-screen window disappears or changes stacking. The user sees the action they approved. Hiding happens only where it changes nothing the user can see.
  - Against: the in-view press is unmeasured (probe 4). If it activates or raises Messages, state 10 falls back to a narrower hide flow or refuses. The reach on other Spaces is still assumed (probe 2).
- **Recommendation: (d).** It keeps the user's visible window in place, it uses the measured hidden path only where hiding is invisible, and probes 1, 2 and 4 can settle its unknowns in one session.

**Option 2. A frontmost Messages (states 19 and 20)**
- **(a) Always wait for Messages to leave the front.**
  - For: the key-routing invariant holds absolutely.
  - Against: a user who leaves Messages in front and walks away blocks every UI action.
- **(b) Act in front with row presses, under an opt-in.**
  - Against: keys typed before the restore press land in the target composer, and "ok" plus Return sends them. Input is sampled only between blocking AX calls. `press(row:)` alone does a description read, an AX window count and two CG window lists before it presses (AX.swift:454-462), and `waitForTranscript` walks the transcript every 0.1 s with 2 s messaging timeouts (Targeting.swift:295-303). The target chat's composer can't be checked before the press either.
- **(c) Act in front by default.**
  - Against: puts the same risk on every user without consent.
- **(d) Act in front only when the target chat is already selected, with the bubble action only, under a separate opt-in, after probes 7 and 13. Otherwise wait for front.**
  - For: it covers the case where the user is reading the chat the agent reacts in, with no chat switch and no row press. It leaves the default path safe.
  - Against: a user who leaves Messages in front on another chat and walks away blocks tapbacks for other chats until they leave Messages.
- **Recommendation: (d).** It matches the maintainer's choice to make foreground actions opt-in for the same kind of risk, and it never moves the user's keys to another chat.

**Option 3. After the bridge launches Messages**
- **(a) Leave it running hidden, as today.**
  - For: the next action skips the roughly 2 s launch.
  - Against: the user's "quit" state isn't restored. Their next ⌘Tab finds Messages there.
- **(b) Quit after a quiet period, if the bridge launched Messages and the user never saw it.**
  - For: restores the user's state with the measured quit.
  - Against: a timer, plus the guards in G8. With a short period, the Dock icon appears and disappears on every cycle when Messages isn't kept in the Dock, and the quit can fire as the user reaches for the icon.
- **(c) Quit right after each action.**
  - Against: a relaunch for every action in a burst, and a quit that races pending file transfers.
- **Recommendation: (b), with a 10-minute period** counted from the last bridge request of any kind, paused while a `wait` is open, and run under a queue ticket.

**Option 4. Refusals after the user clicked Allow**
- **(a) As today.** The panel shows first, and a refusal after approval spends the approval, so the agent's retry opens another panel over the user's work.
- **(b) A read-only state sample before the panel, no panel for states waiting can't fix, and the approval kept for one retry when nothing was pressed.**
  - For: no wasted clicks, and one panel per action.
  - Against: the sample can go stale before the action, so the recheck after approval has to stay.
- **Recommendation: (b).** It cuts repeated panels, which float over every Space and full-screen app.

## 8. Unknowns that need a live probe

Every probe runs with the bridge's own grants, through a probe mode in the release-test harness (section 9). The mode prints the full state sample and can hide Messages, unhide it, press one row, and press one Heart. Every press and send uses only the self chat (chat 603, "You (notes)") and the consenting test contact from release test 2, here called chat T, with no unread messages in either, except where a probe needs an unread message from that contact. Probes are ordered by how much they block.

1. **The hide and unhide round trip in each window state.** Blocks option 1 and the cells for states 10 to 15 and 18.
   - Setup: the self chat is selected, Grok Bot is in front, and Rectangle is running. Messages is unhidden in each of these states in turn:
     - on screen behind Grok Bot
     - beside it
     - minimized
     - on Space 2 while the user is on Space 1
     - full screen in its own Space
     - in Split View with Grok Bot
     - with Stage Manager turned on for the probe, on stage and in the strip
     - on a second display, if one is available
     - outside every display
   - Run: the bridge hides Messages, waits 2 s, then unhides it.
   - Measure each time:
     - the front app before, during and after
     - how long `isHidden` lags
     - the AX count while hidden
     - window bounds and `kCGWindowIsOnscreen` before and after, and whether the frame intersects an `NSScreen`
     - whether the window is still minimized afterward and its Dock tile is still there
     - whether the user's Space switched, and which Space the window comes back on
     - Space order and the window's place in Mission Control
     - the Split View partner's state, the strip order and the stage contents
     - the stacking order against Grok Bot's window
     - whether Messages came to the front, and whether a click on Grok Bot's window right after the unhide lands in Grok Bot
   - Pass: the front app is unchanged, no Space switches, the window comes back where it was with the same bounds and minimized state, and its stacking against the front app's window is unchanged. Section 6 G4 says what a failed state becomes.
2. **AX reach and hidden actions after the bridge's own hide.** Blocks states 11 and 12.
   - First question: with the window on Space 2, the bridge hides Messages, reads `AXWindows`, `AXMainWindow` and `AXFocusedWindow`, and presses the self chat's row once.
   - Then, in each state from probe 1, it hides Messages, presses chat T's row and then the self chat's row, adds and removes a Heart on a self-chat test message, and uses Undo Send on a fresh self-chat message.
   - Measure: AX counts, chat.db rows, AX errors, the front app, whether the window deminimized or moved, and the time from the hide to the unhide.
   - Fail: states 12 and 14 stay busy with `fix: quit Messages and retry`. The bridge doesn't use the private remote-token API.
3. **Window signatures before any hide.** Blocks the detection of states 11 to 17, and with probes 1 and 2 decides the live case.
   - Setup, one at a time:
     - minimized
     - on another Space
     - full screen
     - Split View
     - a window tiled by Rectangle on Space 2
     - closed with ⌘W with Messages left running
     - the Stage Manager strip
     - a second conversation window from Open in New Window
     - Settings open
   - Read:
     - the AX count, `AXMinimized` and `AXSubrole`
     - `AXFullScreen` through `AXMainWindow`
     - `AXMainWindow` and `AXFocusedWindow` on the app element
     - every listed window in the all-Spaces list at every layer, with `kCGWindowIsOnscreen` and bounds
     - the subrole again right after a bridge hide
   - Decides: whether a closed window stays listed, whether the all-Spaces filter catches full-screen and other-Space windows, and which state the live 500 x 500 window was. If Messages is in the live state again, read it before anything else.
4. **Presses on a visible window that isn't frontmost.** Blocks act in view (states 10 and 13) and foreground from view.
   - Setup: the self chat is selected and Grok Bot is in front. Messages is on screen behind Grok Bot, then beside it, then in Split View.
   - Run: press chat T's row, then the self chat's row, then add and remove a Heart on a self-chat test message.
   - Measure: the front app, Messages' stacking against Grok Bot's window, whether Messages' window became key or main, `AXFocusedUIElement`, whether Messages activated, and the time per press.
   - Pass: the front app and the stacking are unchanged and Messages never becomes key.
5. **Reading and restoring the selected chat.** Blocks G2 and G3.
   - Setup: the self chat is selected, with Messages hidden, then with Messages visible but not frontmost.
   - Read: `AXSelected` on every loaded row, `ConversationTitle`, the newest bubble's frame against the transcript's visible frame, and the scroll bar's `AXValue`.
   - Run: press chat T, then the self chat again.
   - Measure: that exactly one row reads as selected, the row descriptions before and after, whether the description rebuilt from chat.db matches, that the self chat's transcript is back, the scroll position before and after, also when scrolled back, and any change in unread state.
   - Repeat with a new message open, where no row is selected.
   - Cold-launch leg: quit Messages with the self chat selected, launch it hidden, and read the selection. Record the "Close windows when quitting an application" setting, since it changes what a relaunch restores.
6. **Drafts across a chat switch, a close and a quit.** Blocks the draft cells (state 25) and states 16 and 17, and checks the state 8 relaunch.
   - Setup: type a text draft in the self chat. In a second run, attach only an image. Hide Messages.
   - Run: press chat T, then the self chat, and read its composer. Then quit, relaunch hidden, and read it again. Also close the window with ⌘W while it holds a draft, relaunch, and read.
   - Also read: what `AXValue` shows for the attachment-only draft.
7. **Keyboard focus after a bubble press on a frontmost window.** Blocks G5 and option 2.
   - Setup: Messages is frontmost on the self chat, with the cursor in its composer.
   - Run: the bridge presses Heart on a self-chat test bubble. The maintainer then types one letter and never presses Return. The letter is cleared before the next pass. A second pass presses chat T's row instead, only to record where the letter lands.
   - Measure: `AXFocusedUIElement` after each press, and where the letter lands: the self chat's composer, chat T's composer, or type-select in the list.
8. **Read marking.** Doesn't block building, because the unread checks refuse or skip. It sets the result notes. Needs the consenting sender of chat T.
   - Setup: an unread incoming message in chat T, with Messages hidden.
   - Run: press chat T's row. Then, with T left selected and Messages hidden, have the sender send again. Repeat with Messages visible but not frontmost.
   - Restore-press leg: with chat T as the earlier chat holding an unread message, press the self chat, then T again.
   - Measure: `is_read` and `date_read` after each step, and whether a receipt appears on the sender's device.
9. **Sends while Messages is visible.** Confirms the sends column for states 19 and 25.
   - Setup: Messages is frontmost on the self chat, with a draft in it.
   - Run: the bridge sends to the self chat, then to chat T.
   - Measure: the self chat's composer value, the selected row, the scroll position and the front app.
10. **A launch in progress.** Sets the G7 timeout.
    - Setup: Messages is quit. The maintainer clicks the Dock icon while the bridge samples every 50 ms.
    - Measure: the `isFinishedLaunching` timeline, AX counts and timeouts, CG windows, `isHidden` and frontmost.
11. **A locked screen, a sleeping display, and the screen saver.** Blocks the hidden flows in states 36 and 37.
    - Legs: screen locked, display asleep but unlocked, and screen saver running before the lock.
    - Setup: Messages hidden, then in a separate run unhidden and minimized.
    - Run: Heart add and remove on a self-chat test message through act hidden, then through hide, act, unhide.
    - Measure: AX results, chat.db rows, the lock and display readings, and the window state after waking.
12. **Foreground activation after a hide, and from view.** Blocks the foreground cells for states 10, 11, 12, 13 and 18.
    - Setup: the window is minimized, on another Space, full screen, in Split View, or on screen behind Grok Bot.
    - Run: the bridge hides Messages where the flow hides, then runs `open -b`.
    - Measure: the time until Messages is frontmost, any Space switch, any deminimize, any exit from the user's full-screen Space, and whether Return can still land within 3 s of `t_front`.
    - Pass: no deminimize, no Space switch, no exit from the user's full-screen Space, and Return within the deadline. Section 6 G6 says what a fail means.
13. **Input the monitor can't see.** Decides whether the opt-in paths need more than the HID idle time.
    - Run: dictate into a text field. Type through Screen Sharing, then through Universal Control. Hold a modifier, pause a drag with the button held, and make trackpad gestures (a Space swipe, Mission Control, a pinch). Post events at the session tap from another tool.
    - Measure: whether `secondsSinceLastEventType(.hidSystemState)` resets, and what `flagsState` and `pressedMouseButtons` read.
14. **Quit later.**
    - Run: a cold-launch file send to the self chat, then the quiet period, shortened for the probe. A second run sends again while the quit is in progress.
    - Measure: transfer_state 5 before the quit, nothing on screen, a clean exit, and a send during the quit that waits and then cold starts Messages hidden.
15. **Transient UI shapes.** Blocks the detection in states 24, 26 and 30.
    - Run: open the Details popover, the emoji picker, the tapback picker, the add menu, an alert, Quick Look, a sheet, the poster editor, a search with text, a new message, and an audio recording. Do this with Messages hidden and unhidden.
    - Record: AX roles, subroles and identifiers, and CG windows at every layer.
16. **Automatic termination.** Sets state 6's handling.
    - Run: the bridge hides Messages, which is then left idle under memory pressure.
    - Sample: `activationPolicy`, the pid and the Dock presence every few seconds.
17. **Secure Event Input.** Blocks the foreground cell for state 44 and act in front.
    - Run: turn on Secure Keyboard Entry in Terminal, then run one foreground edit on a self-chat message.
    - Record: whether the Return lands, and whether the HID idle reading changes.

The earlier approval-order probe is dropped. Local files already answer it (section 1).

## 9. What changes in DESIGN.md and the code

### DESIGN.md

- **Section 4, title and design rule.** UI actions leave a visible Messages where it is when they can, hide Messages only when nothing of it is on screen, and restore the user's state afterward. Add the any-state goal.
- **Section 4, window rules.**
  - Replace the busy rules for an unhidden Messages with the decisions in section 4 of this document.
  - Replace "never hide the user's window or switch the user's chat" with the restore contract, G1, G4 and G16.
  - Add the launch wait, the window classification, the frontmost wait and the new refusals.
  - The no-window quit requires an all-Spaces count of 0, Stage Manager off, and nil `AXMainWindow` and `AXFocusedWindow`. An unhidden Messages with no window refuses until probes 3 and 6 pass.
- **Section 4, new subsection "Restore contract".** Section 5 of this document.
- **Section 4, targeting.**
  - Skip the press when the target is already selected.
  - Capture the earlier chat, resolve it to chat.db, and restore it.
  - Add the G2 preconditions to every path.
  - Every row press takes the caller's final check.
- **Section 4, foreground mode.**
  - Step 1 runs G2 and reads the selected chat's composer before `selectChat`.
  - Step 1 no longer requires Messages to be hidden. Add the starts from view, from nothing on screen, and frontmost with the target selected.
  - Step 5's takeover gets G10.
  - Step 6's finish restores the chat and returns Messages to the state it started in.
  - Add the refusals for Secure Event Input and for a full-screen front app.
  - The opt-in dialog names the screen-sharing risk.
- **Section 4, new opt-in "act in front"** with its own consent text, which names the screen-sharing risk too.
- **Section 2, policy.**
  - The read-only sample before the panel.
  - The approval kept for one retry.
  - The panel text over a frontmost Messages.
  - The "Always allow this chat" text and the README say that tapbacks in that chat may hide and show Messages and switch its chat.
- **Section 3.** Item 2: the journal flags, the Messages pid, the earlier chat's ROWID and the digest. Item 3: the idle, mouse and frontmost waits don't hold the queue. Item 4: quit later after a cold start, under a queue ticket.
- **Results.** New busy reasons:
  - `Messages is in use`
  - `several Messages windows`
  - `Messages window not reachable`
  - `Messages is minimized`
  - `Messages is on another Space`
  - `Messages is full screen`
  - `Messages is in Split View`
  - `Messages is in Stage Manager`
  - `Messages dialog open`
  - `new message in Messages`
  - `search in Messages`
  - `audio in Messages`
  - `Messages scrolled back`
  - `unread messages in Messages`
  - `Messages chat not identified`
  - `screen locked`
  - `display asleep`
  - `session not active`
  - `full-screen app in front`
  - `secure input on`

  New notes: `chat not restored`, `Messages left hidden`, `Messages came to the front` and `scroll position may have moved`. New fix lines: `quit Messages and retry` and `switch to <target> in Messages, or leave Messages`. The `Messages became visible` note gets the meaning from G11. The ⌘H fix line is dropped.
- **Release tests.**
  - Test 1 case h (no window) keeps the relaunch for a hidden Messages. With Messages unhidden, it expects `busy: Messages window not reachable` until probes 3 and 6 pass.
  - Case i (another Space) expects act and restore only after probes 1 and 2 pass, and `busy: Messages window not reachable` before that.
  - Case j (full screen) expects `busy: Messages is full screen`, no hide, no press and the same pid.
  - The `other-space-busy` and `fullscreen-space-busy` gates in scripts/release-tests/README.md change to match.
  - Add one case for each state in section 2 whose cell changed.
  - Test 5 adds a Return injected during a takeover.
  - Tests 4 and 5 add a frontmost case with the target chat already selected.
- **Spikes before feature code.** Add an any-state spike that holds probes 1 to 7.
- **docs/BUILD-PLAN.md.** Entry 49 is superseded. Entry 50's final-check rule extends to the new press mode, the hide and the unhide. New entries record each decision above.
- **research/live-tests/2026-11-07-sends.md.** Correct the "Allow once" and "allowlist stayed empty" lines against policy.json, and record the 500 x 500 window and the failed ⌘H.

### Code

- **IMCore.**
  - `MessagesAppState` (Protocols.swift) gains `isFinishedLaunching`, the activation policy, the bounds and on-screen flag of each window, the front-to-back on-screen order, the Stage Manager flag, the lock, display sleep, screen saver and console flags, and Secure Event Input. Window attributes are three-valued (G14).
  - `MessagesAppControl` gains `unhide()`.
  - A new restore plan type.
  - The `InputMonitoring` protocol moves here from IMForeground/Input.swift, with a new journal-flag protocol, so IMUI's `HiddenWindowManager` can run G1 and set `hid`. IMBridge injects the live objects.
  - New results, notes and fix lines in Results.swift.
  - New limits in Limits.swift: the 10-minute quiet period, the 10 s launch wait, the 30 s frontmost and mouse waits, the 2 s hidden-span cap, the 1 s front-app watch and the 0.5 s fast-key window.
- **IMUI/MessagesApp.swift.** Read the new signals, read the pointer with `CGEvent(source: nil)?.location`, and add the unhide.
- **IMUI/WindowRules.swift.**
  - New decision cases: act in view, hide first, wait for the mouse gate, wait for front, wait for launch, act in front, and refusals with a reason.
  - `decide` stops quitting a hidden Messages with an AX count of 0 unless the state 8 checks hold. It refuses an unhidden Messages with no window until probes 3 and 6 pass.
  - `HiddenWindowManager.prepare` returns a restore plan, and a new restore step runs G3 and G4.
  - The quit paths never quit a Messages that may have a window, or one the bridge hid.
- **IMUI/AX.swift.**
  - New reads: the selected row, the selected chat's composer value, the search field's value, sheet, popover and recording detection, the classification of every window, `AXMinimized` and `AXFullScreen` while unhidden, `AXMainWindow` and `AXFocusedWindow`, and the scroll position. All window reads are three-valued.
  - `press(row:)` gains a mode that runs the caller's final check in place of `requireHiddenWindow`. It never takes `{}` in that mode.
- **IMUI/Targeting.swift.**
  - `selectChat` takes a `finalCheck` parameter.
  - Skip the press when the target is selected.
  - Capture the earlier chat and resolve it with `RowDescriptionBuilder` and `hasLookalike`, then restore it through `selectChat`, group chats included for the restore only.
- **IMUI/Actions.swift.** The tapback and unsend runners use the plan, G2 and act in view. They hand a frontmost Messages to IMForeground when the in-front opt-in is on. IMUI sits below IMForeground in the module graph, so the in-front runner lives in IMForeground.
- **IMForeground.**
  - `ForegroundRunner.preconditions` runs G2 and reads the selected chat's composer before `selectChat` (ForegroundRunner.swift:206-226).
  - `ForegroundRunner` and `ForegroundMachine` accept the starts from view, from nothing on screen, and frontmost.
  - They gain the G10 takeover fixes.
  - A new in-front runner for the bubble action reuses the ownership check.
  - `HIDInputMonitor` adds the `flagsState` and `pressedMouseButtons` checks, and gesture event types if probe 13 shows the HID state reports them.
- **IMSend.** ColdStart.swift and MessageSender.swift report when the bridge started Messages from not running.
- **IMPolicy.**
  - Journal.swift gets the `hid` and `launched` flags, the Messages pid, the earlier chat's ROWID, the row-description digest, and their recovery.
  - PolicyStore.swift gets a separate in-front setting with a consent version. An existing `foregroundMode` that is on doesn't turn it on (PolicyStore.swift:28, 304-311).
  - Approvals.swift keeps an approval valid for the same key after a busy that reached nothing.
- **IMBridge.**
  - BridgeMain and Container run the quit-later timer under a queue ticket.
  - Pipeline.swift reads the state sample before the panel, in `run` before `proceed`.
  - Dispatch.swift routes frontmost UI actions.
  - Services.swift extends `status` and `doctor` with the full sample and the journal flags, and setup (`askAutomation`) sets the `launched` flag when it launches Messages.
  - ApprovalPanel.swift gets the frontmost text, and a new notice panel implements G15.
- **imessage CLI.** `CLI.responseTimeout` in Sources/imessage/Flows.swift adds the front wait, the launch wait, the mouse wait, the hide poll, the restore and the front-app watch, so the CLI doesn't give up while the bridge still acts.
- **Skill.** skill/imessage/SKILL.md line 21 and skill/imessage/reference.md line 56 stop telling the agent to ask for ⌘H. reference.md lists the new busy reasons and fix lines. Rerun scripts/check-skill-tokens.sh.
- **Tests.** A unit test that "Allow once" leaves policy.json unchanged, plus one live run that confirms it.
- **scripts/release-tests.** The new t1-bridge.sh cases, the t4 and t5 additions, and the probe mode that section 8 uses.

## Rejected critiques

- Letting a frontmost Messages take a row press after 60 s with no input (disruption finding on G5): a user who comes back during the action types into the target chat's composer. Revisit only if probe 7's row-press pass shows that keys don't land in a composer.
- Running G3's bubble check after the unhide (disruption finding on the hidden span): the chat-restore safety findings need that check before the unhide, so a wrong chat is never shown. The rest of that finding is applied.
- Turning an on-screen state whose unhide fails into "leave hidden" (safety finding on G4, completeness finding on the unhide gate): for states with an on-screen window, the disruption finding on "leave hidden" wins. Those cells become act in view or a refusal, decided before the hide. "Leave hidden" is kept for states with nothing on screen.
- Acting in place on a full-screen or Split View Messages in a Space the user isn't on (disruption finding on Split View): AX can't reach that window without the private remote-token API. The finding's refusal is applied there, and act in view is applied to Split View on the current Space.
- Letting the frontmost wait run as long as the remaining approval wait (completeness finding on approving from a frontmost Messages): up to 10 minutes outruns the CLI's response budget and blocks the agent. The approval kept for one retry under G13 gives the same result without a new panel. The panel-text part is applied.
