# Switching chats on Messages 26

Scope: macOS 26.2, Messages 26.0 build 1450.300.41.1.4 (Mac Catalyst). This revises how research/messages-states.md switches chats. Where the two disagree, this document wins, and section 8 lists every state map item it changes. Evidence labels are the same as there: Measured, Reported, Code and Assumed. T is the target chat. E is the chat the user had selected.

## 1. Summary

A tapback or Undo Send has to find its bubble in T's transcript, so T has to be the selected chat. The bridge selects it by pressing T's row in the conversation list. On this Messages that press does nothing while Messages is hidden or minimized, which is the only state the bridge presses in today. So today a hidden tapback works only when T is already selected. For any other chat it ends in `wrong_chat` after the 2 s transcript wait, with nothing else pressed. It fails closed, but it doesn't work.

The proposal:
- **Act in place when T is already selected.** No switch, no hide, no unhide and nothing to restore. On a hidden Messages this works today (Measured). On an unhidden one it waits for the probe for that window state.
- **Switch with a selection driver** that presses, reads the selection and presses again until only T is selected. It presses only T, E, or a row the bridge itself just added to the selection. It handles both a press that toggles a row in a multi-selection, as Messages 26 does, and a press that selects a row alone.
- **Switch parked for a hidden Messages.** Move the window past every display while Messages is hidden, unhide it there, switch, act, switch back, hide it and move it back. The user sees nothing. This waits for probes P1, P2 and P7.
- **Switch in view** when the window is already on screen and Messages isn't frontmost. The user sees the chat change and change back. Row presses there don't raise or activate Messages (Measured). The bubble action there waits for probe P4.
- **Refuse everything else** with `busy: chat not open in Messages` and a fix line that leads to a state the bridge can act in. Until P4 passes, that is `fix: open <target> in Messages, hide it (⌘H), then retry`, because a hidden Messages with T selected is the one measured path. After P4 it is `fix: open <target> in Messages, then retry`.

Hiding Messages no longer helps with anything, since a hidden press does nothing. So the state map's "hide, act, unhide" and "hide, foreground, unhide" flows go away, and the bridge never hides a window the user can see.

Foreground edits and threaded replies keep today's step 1, so on Messages 26 they run only when T is already selected and otherwise return the same busy line. A parked switch for them is left for later.

## 2. What was measured

From research/live-tests/2026-11-07-sends.md (chat switch probes). Only the self chat's row and the user's own selected row were pressed.

| Messages state | Press | Selection after | Transcript | Messages frontmost |
| --- | --- | --- | --- | --- |
| hidden | the other row | unchanged | unchanged | no |
| minimized, then unhidden | both rows | unchanged | unchanged | no |
| on screen behind the front app | the target row | earlier and target both selected | none | no |
| on screen behind the front app | the target row, then the earlier row | the target alone | the target chat, 12 bubbles | no |

Also measured:
- On a hidden or minimized window, the press returns success and changes nothing.
- On screen, a press adds the row to the selection or takes it out. With two rows selected, no transcript shows. Messages stayed behind the front app and kept its place in the window order.
- `AXSelected` on the rows reads correctly while hidden. Neither it nor `AXSelectedChildren` on the list is settable.
- The rows' custom actions (Pin, Mark as Unread, Hide Alerts, Open in New Window, Delete) and the bubbles' tapback actions run while hidden.
- Open in New Window, run hidden, opened a 1024 x 768 window for the chat and unhid Messages without making it frontmost.
- `unhide()` kept the earlier app frontmost, kept a minimized window minimized and kept the window on its Space. It returned false each time while `isHidden` read false right after, so only the polled value counts.
- Hidden, the chat window's AX tree is the same as on screen (71 of 72 nodes), so the checks of the state map's G2 can run on a hidden window.
- While the screen was locked, AX listed no Messages window, hidden or not.

Not measured yet: everything in section 6. In particular a press on a window that is unhidden but outside every display (P1), any bubble action on an unhidden window (P2, P4, P5), whether an unhidden window marks the chat it shows as read (P1's unread leg), and anything with a second display.

## 3. The selection driver

`selectChat` becomes a loop that leaves exactly one row selected. The forward leg goes from E to T. The restore leg goes from T back to E.

**Starting point.** The leg starts only when exactly one row reads `AXSelected` and the transcript matches that row's chat (the state map's G2 and G3 capture). The one exception is right after the bridge's own launch or relaunch (states 1 and 8): if no row is selected, no To: field shows and no transcript bubble is loaded, the forward leg presses T once and there is nothing to restore. Any other start with no selected row refuses as state 26 or 33. A transcript with no selected row means the reader is missing the selection, for example a pinned chat shown as a tile.

**The opening press.** The row to open, T going forward and E in the restore, is found by its row description rebuilt from chat.db at that moment, with the lookalike rule (Targeting.swift:270). It must match exactly one loaded row, or the leg stops before pressing. A row without Messages' English row actions isn't pressed, as today (Targeting.swift:182-184). No index or element is reused from an earlier read, because rows move when messages arrive. The press runs the path's final check right before `AXPress`, with no AX read between them (BUILD-PLAN entry 50).

**After the press**, the driver reads the selection every 0.1 s for up to 1 s:
- Only the opened row selected: go to the transcript check below.
- The opened row and the earlier row selected: make the collapse press, then read again.
- No change: stop and don't press again. A slow press that lands later is caught by the last check below.
- Anything else, including a third row selected or an unknown `AXSelected` read (G14): stop.

**Done means the transcript matches.** One selected row isn't enough, because the selection can move to T while the transcript still shows E. The leg is done only when the opened row is the one selected row and the loaded bubbles match that chat's signature, waited for with today's `settleTimeout` (2 s, Targeting.swift:142 and 295). A mismatch stops the leg: going forward the result is `error: wrong chat`, and on the restore leg it adds G3's `chat not restored: an unknown chat is selected`. The bubble action runs only after the forward leg is done. A forward leg that stops for any reason, here, on a failed check or on overrun, skips the bubble action and goes to the exit order: the restore leg if a press was made, then the two-row check, then step 7 when parked.

**The collapse press** takes the earlier row out of the selection. That row is identified by `AXSelected` as the selected row that isn't the one just opened, and needs no text match. A press on a selected row only takes it out, so it can't open a third chat. On Messages 26 every switch is an opening press plus a collapse press. Where a press selects a row alone, there is no collapse press. A collapse press runs under the landing checks listed under "No two-row state is left behind" below.

**Read receipts.** The only rows pressed are T, E, and the selected row a collapse takes out. On a toggle list the press that shows E's transcript again is the restore leg's collapse press. Where a press selects a row alone, it is the restore leg's opening press. So the state map's G3 unread check, for incoming rows in E above the journaled highest ROWID, runs inside the final check of both. If E has new unread rows before the opening press, the restore leg doesn't start and T stays shown. If they arrive before the collapse press, the collapse goes the other way: it takes E out again and T stays shown. Either way the result adds `chat not restored: new messages in <E>`.

**No two-row state is left behind.** A stop, a failed check or an overrun can leave T and E both selected, with no transcript. Before any end hide and before the result, the bridge reads the selection once more. If exactly T and E are selected, found as in this operation, it makes one collapse press toward E when the unread check allows it, otherwise toward T. Any other selection gets no press. That press is exempt from the time caps and runs under the landing checks only:
- Messages isn't frontmost and has the same pid
- it is unhidden, and still parked or, in view, the pointer isn't over its window
- no mouse button is held
- no modifier key is held. The probes showed Control and Fn had no effect, but Shift wasn't tested, and a held Shift could extend the selection across rows
- in view, no mouse event since the gate, as G16 requires

If even that press can't run, the result adds `chat not restored: two chats selected in Messages`. In view, the state map's G15 notice says no chat is open in Messages.

**Never on a frontmost Messages.** The driver never presses while Messages is frontmost (the state map's G5 and G6).

**Errors.** A path check that stops a press means that press wasn't made. If no press of the operation was made, the result says nothing was pressed, with no `may have marked read` note, and the approval stays valid for one retry (the state map's G13). If an earlier press was made, the result keeps the note and the approval is spent. Today any error that isn't an `AXDriveError` maps to `not_loaded` with that note (Targeting.swift:189-192, 352-357).

## 4. Where the switch runs

The bridge picks one flow from its state sample, in this order. Every flow first passes the state map's G9 (lock, display and console), its G13 approval rules and, for a frontmost Messages, its wait for front.

**Act in place.** T is already selected. The bubble action runs on the window where it is, with no row press and nothing to restore:
- hidden with one window (state 7): today's path, Measured. State 9 keeps its refusal, because the transcript and bubble lookups read a single window (`singleWindow()` in AX.swift) and today's window rules refuse several
- unhidden, on screen, not frontmost (state 10): after P4, behind the state map's G16 gate and final check
- unhidden and minimized (state 11): after P5
- unhidden on another Space (state 12): after P6
- unhidden and outside every display (state 18): after P2

Until a window state's probe passes, that cell keeps today's busy line. A frontmost Messages still needs the separate in-front opt-in (the state map's G5).

**Switch in view.** Messages is unhidden and not frontmost. Its one conversation window is on screen on the current Space and isn't minimized, full screen or in Split View, and Stage Manager is off. There is one active display until P4 has a second-display leg. The driver runs on the visible window under G16: the mouse gate, the pointer check and the final check before each opening press. Then the action, under the same check. Then the restore leg. The user sees the transcript go blank, show T, go blank and show E. That takes about 2 s when the presses land at once. The caps are the same as parked: 5 s for the forward leg and the action, then 2.5 s for the restore leg. Waits for P4, which adds the bubble action to the row presses already measured.

**Switch parked.** Messages is hidden with exactly one Messages window at any layer that is on a Space (state 7, strictly, so state 9 refuses even with Settings open), including right after the bridge's own hidden launch (state 1) or relaunch (state 8). The window is on the current Space, read with `CGSCopySpacesForWindows` (BUILD-PLAN entry 51), so a hidden window on another Space refuses. Stage Manager is off, read three-valued, and there is one active display until P1 has a second-display leg. Waits for P1, P2 and P7. States 1 and 8 also wait for P1's launch leg, because a window launched hidden has never been ordered in, and its first order-in is where AppKit is most likely to pull it back on screen. Until that leg passes, states 1 and 8 act in place when T is selected and otherwise refuse. Steps:
1. **Checks on the hidden window.** Run G2 on it, including state 24's check for dialogs at any layer. G2's unread rule applies as for an unhidden start, because the unhide shows E: if E has unread incoming rows, refuse with `busy: unread messages in Messages`. P1's unread leg can lift this. Resolve T, check that its row is found exactly once, and capture E (G3).
2. **Gate.** Run the mouse gate (the state map's G1). Read the window's frame through `AXPosition` and `AXSize`, and its CG bounds.
3. **Park.** Journal the `parked` record (section 5). Pick the parking point: 3000 points to the right of the largest right edge among the active displays, at the window's own y. Set `AXPosition` there with `setWindowPosition(_:finalCheck:)`. The final check confirms that Messages is hidden, has the same pid and isn't frontmost, with frontmost sampled last. Read the position back. If it didn't move there, or the AX frame or the CG bounds touch any display, move it back and refuse. From here on, "still parked" means both: the AX frame is at the parking point, and the CG bounds touch no display. If the two disagree, the window doesn't count as parked.
4. **Unhide.** The final check runs the gate's instant checks (buttons, modifiers, pointer), then G2's unread rule on E again, then confirms that Messages is hidden, not frontmost and has the same pid. Then unhide. Poll `isHidden` and the CG bounds together every 1/64 s for up to 1 s. If the bounds touch any display at any poll, the user can see the window: hide at once (the hide's final check is the same pid and not frontmost), move it back once hidden, and refuse with `busy: chat not open in Messages`.
5. **Check the unhidden window.** Messages isn't frontmost, the front app is the one recorded in step 2, `AXMinimized` reads false, the AX frame is still parked, and no other Messages window is ordered in at bounds that touch a display. Otherwise hide, move back and refuse.
6. **Switch, act, switch back.** Run the forward leg, the action and the restore leg. The final check of each opening press and of the bubble press confirms that Messages is unhidden, still parked and has the same pid, and that no Dock overlay shows (below). It reads frontmost last, after the AX read for "still parked", and confirms Messages isn't frontmost. Collapse presses use the landing checks from section 3.
7. **Hide and move back.** The hide's final check confirms the same pid, the frame still at the parking point and Messages not frontmost. If Messages is frontmost, take the takeover branch below. If the frame moved, the user or macOS moved the window: leave it, delete the record, and add `Messages window moved` to the result. Otherwise hide and poll `isHidden` for up to 1 s. The move back runs only once Messages reads hidden. Its final check confirms the same pid, Messages hidden and the frame still at the parking point. Read the position back, then delete the `parked` record. If the hide or the move back fails, the record stays, the result adds `Messages window off screen`, and recovery retries (section 5).

Every exit after step 3, refusals and AX errors included, runs three things in order. First the restore leg, if the forward leg made a press, as the state map's G3 requires. That covers a refusal after the forward leg, such as a bubble that isn't loaded. Then the section 3 two-row check. Then step 7. The forward leg and the action must finish within 5 s of the unhide. On overrun the bridge skips the bubble press, as the state map's G1 skips the effect, and makes no new opening press except the restore leg's. The restore leg has its own 2.5 s, and collapse presses are never cut off.

**Watching the front app.** For the whole parked span, an `NSWorkspace` activation observer on the main run loop, away from the AX worker, watches for Messages coming to the front, because the AX calls block and a check before each press could come seconds late. The span owns the `parked` record while it runs, so these notifications go to the span, not to recovery. The observer sets a takeover flag that every final check reads, so no new press starts after it. It makes the move itself on its own AX element for the window, without waiting for the worker's call to return. A row press already inside `AXPress` can still land. The two-row check runs after it, on the worker. When Messages activates:
- inside the state map's G4 1 s watch, with no input since the unhide: G4's focus restore reopens the recorded front app, and Messages stays parked
- otherwise the user switched to it with ⌘Tab or the Dock and can't see its window: the bridge presses nothing more, moves the window back at once without hiding it, and shows the G15 notice naming the chat Messages shows. The result says `user took over`.

**Display changes.** A display reconfiguration during the span (G17) hides Messages at once. The bridge then moves the window back and decides again.

**Mission Control and App Exposé.** Either one, opened during the span, may show the parked window with T's transcript (Assumed). The final checks in steps 4 to 7 read the on-screen CG list for a Dock window above the normal layers. If one shows, the bridge presses nothing more, hides Messages and runs step 7. P7's third run measures what the Dock lists then.

**Refuse.** Every other state where T isn't selected:
- minimized (11), on another Space (12) and outside every display (18)
- several windows (9), Split View (13), full screen (14) and Stage Manager (15)
- no reachable window (16 and 17)
- a hidden window on another Space
- locked, display asleep or off the console (36 to 38)
- any switch flow whose probes haven't passed

The result is `busy: chat not open in Messages`, except where the state map already has a more specific busy line, such as `Messages is in Stage Manager`. The fix line depends on the probes that have passed, so that following it leads to a state the bridge acts in. Until P4, it is `fix: open <target> in Messages, hide it (⌘H), then retry`, which leaves Messages hidden with T selected (state 7), where act in place is measured. After P4, it is `fix: open <target> in Messages, then retry`, since act in place then covers a window left on screen behind the front app (state 10). Nothing was pressed, so the approval stays valid for one retry (the state map's G13).

If P1 fails, switch parked becomes a refusal too. Section 7 lists what could replace it.

## 5. Restore and crash recovery

New item in the restore contract (state map section 5):

| Item | Recorded from | Restored by | Restorable |
| --- | --- | --- | --- |
| Window position while parked | `AXPosition` and `AXSize`, and CG bounds | `AXPosition` set back while hidden, then read back | Assumed. P1 and P3 |

The order becomes: the chat, then hide, then the window position, then the front app, then later the quit.

**The `parked` record** is its own journal record, apart from the action's entry. It holds the Messages pid, the origin, the size and the parking point, as numbers only. It is written before the park and deleted only after a read-back confirms the move back. Finishing or pruning an action's entry leaves it alone.

**Recovery moves the window and never presses a row.** It runs only on a record that no live span owns: at bridge start, at the top of every UI request before the state sample, and on `com.apple.screenIsUnlocked`, on Messages' NSWorkspace activate and unhide notifications, and on a display reconfiguration. `imessage uninstall` and turning the bridge off run it first, so removing the bridge mid-span doesn't strand the window. A record is owned while the span that wrote it runs, so the bridge's own parked unhide never triggers recovery. Recovery and spans run on the same UI queue, one at a time. Each move and hide in recovery takes the same final checks as step 7:
- If the window's frame isn't at the parking point any more and touches a display, the user or macOS moved it. Recovery deletes the record and changes nothing. If it moved but still touches no display, recovery treats it as parked and applies the rules below.
- If Messages has the journaled pid, isn't frontmost and is still parked, recovery hides it if it is unhidden, which shows the user nothing because the window is off screen. It moves the window back and leaves Messages hidden.
- If Messages is frontmost, the user is in it and sees no window. Recovery moves the window back without hiding it, and shows the G15 notice naming the chat Messages shows, since the crash may have left T or no chat selected.
- If the pid changed and the new window touches no display, recovery moves it to the journaled origin, with a final check of the new pid. P3 shows whether Messages keeps the parked frame across a relaunch.
- The chat stays as recovery finds it. `doctor` keeps its line that Messages may be hidden and showing another chat.

The state map's G12 drops its hidden G3 restore press, since a hidden press does nothing.

`doctor` checks the window's frame against the active displays in every case, journal or not, and reports `Messages window off screen`. Until P3 passes, the line says the fix is unmeasured and gives no steps. After P3, the fix line is `quit Messages and open it again` if a relaunch brings the window back on a display, otherwise the Window menu's Move & Resize commands if Messages has them (Assumed).

**Coordinates.** Every frame test uses the display rectangles from `CGDisplayBounds` over `CGGetActiveDisplayList`. They share their coordinate space with `AXPosition` and `kCGWindowBounds`: origin at the top left of the main display, y growing down. `NSScreen` frames use a flipped y axis and aren't used for these tests.

## 6. Probes

P1 is built as a standalone probe that presses only the self chat's row and the user's own earlier row, and it runs while the Mac is unlocked and idle. The others run with the bridge's grants through the probe mode of state map section 9, on the self chat and the consenting test contact's chat only. Every tapback in them goes through the bridge and its approval panel.

1. **P1, a press while parked.** Messages hidden on the self chat, with the user's chat to restore. Set `AXPosition` past every display while hidden, unhide, and run the driver to the user's chat.
   - Safety: P1 refuses if chat.db shows unread incoming messages in any chat but the self chat since the probes moved the user's selection, and checks again before each press on the user's row. If the park's read-back touches a display, it moves the window back and doesn't unhide. After the unhide it polls the CG bounds every 1/64 s for 1 s, as step 4 does, and hides at once if they touch a display. Before each press it checks that Messages isn't frontmost and that no modifier or mouse button is held.
   - Measure: the set's error and the position read back, whether the unhide keeps the parked frame, whether the parked window is in the on-screen CG list, the selection, the transcript title and its bubble count after each press, the front app, whether Messages became active, and the time from the unhide to the hide. The sampler runs for the whole run.
   - Also measure, in every run and for the in-view press measured on 2026-11-07: how much of the window the windows above cover, and its place in the front-to-back list. This tells whether a covered window counts as occluded and ignores presses the way a hidden one does, which decides whether option (b) can work.
   - Pass: the window stays parked by the 1/64 s poll's `CGDisplayBounds` test, the driver reaches the target, the transcript loads with the target's bubbles, the sampler never sees a Messages window touch a display, the front app never changes, and the window moves back while hidden with a matching read-back. Any activation of Messages during the parked span fails the run, whatever the input state. P1 makes one forward leg, from the self chat to the user's chat. The round trip, with its restore leg, is P2.
   - P1 ends by putting the user's chat back. If the parked leg didn't do that, P1 does it with the window on screen at its own frame, behind the front app, with the same unread check. That fallback is a restore, not part of the run, and a run that needs it doesn't pass.
   - Launch leg: the same run right after the bridge's own `open -g -j` launch. States 1 and 8 wait for it.
   - Later legs: with a second display to the right and one above when one is available, and an unread leg (an unread message from the test contact in E, with `is_read` and `date_read` read before the unhide, after each press and after the hide). Only that leg can lift step 1's unread refusal.
2. **P2, a Heart and Undo Send while parked.** The bridge adds and removes a Heart on a self-chat test message, and uses Undo Send on a fresh self-chat message, through switch parked, starting from another chat. A second leg covers act in place in state 18: the window left unhidden outside every display with T already selected, and the same Heart and Undo Send.
3. **P3, the parked quit leg.** Quit Messages while parked, relaunch it hidden, and read the window frame.
4. **P4, a Heart and Undo Send in view.** The same two actions through switch in view and through act in place, with Messages on screen behind the front app. Pass, as in the state map's probe 4: after each press the front app, the stacking order, the key window and `AXFocusedUIElement` are unchanged.
5. **P5, a minimized window.** A Heart and Undo Send on the selected self chat with the window minimized and Messages unhidden.
6. **P6, another Space.** A plain window on Space 2 while the user is on Space 1: what AX lists, and whether a Heart and Undo Send work there.
7. **P7, switching to Messages while parked.** A probe span held open for 10 s. The tester presses ⌘Tab to Messages during it and types at once, then clicks the Dock icon in a second run. A third run opens Mission Control during the span and records what the Dock lists and whether the overlay check fires. Pass: the window is back on a display within 0.25 s of the activation and before the first typed key lands, where each key landed is recorded, no press runs after the activation, and nothing the tester types lands in a chat the tester can't see.

Every probe that claims the user saw nothing runs the release tests' window sampler alongside it. The sampler reads the on-screen CG list every 1/64 s and records any Messages window whose bounds touch a display and any change of the frontmost window's owner. P1's own reads are snapshots and don't establish that alone.

The state map's probes 5, 6 and 8 make their presses through the driver, in view and parked. Probe 6 adds a draft held in E across the two-row state. Probe 8 adds the restore leg's collapse press on an unread E. Probe 11 drops "hide, act, unhide".

## 7. Options considered

**For a hidden Messages:**
- **(a) Park the window off screen (chosen, if P1, P2 and P7 pass).**
  - For: the user sees nothing change, and the front app doesn't change (Measured for `unhide()`).
  - Against: AppKit may pull a titled window back on screen when it is ordered in. Tiling tools that hide windows by moving them, AeroSpace among them, park windows in a display's bottom-right corner, reportedly because macOS keeps part of a window on a display when it is moved by a program (Reported, not checked here). If that holds, the clamp happens at the AX set, before any order-in. Step 3's read-back catches it and P1 measures it, but P1 may well fail for this reason. A crash while parked leaves the window off screen until recovery runs. Mission Control opened during the span may show the window.
- **(b) Unhide only when the front app's windows cover Messages' frame.**
  - For: no frame change.
  - Against: where an unhidden window lands in the window order is unmeasured. Translucent toolbars and sidebars on macOS 26 show the change through the blur. A window the user moves during the span shows Messages.
  - Kept as the fallback if P1 shows the pull back and P1's cover reading shows the window comes back fully covered.
- **(c) Open in New Window, act there, close it.**
  - For: the main window's selection never changes.
  - Against: it unhides Messages with a new window wherever Messages puts it, so the user sees it every time (Measured). The second window trips the several-windows refusal, and Messages may reopen it at the next launch.
  - Rejected.
- **(d) An `imessage://` or `sms:` URL through `open -g`.**
  - Against: S3 shows it unhides Messages. For a handle that doesn't match an existing chat's exact form it opens a new message. It can't name a group chat, and the restore would need a URL for the earlier chat.
  - Rejected.
- **(e) Arrow keys posted to Messages' pid.**
  - Against: it sends keys to an app that isn't frontmost, depends on which element has focus in the list, and is unmeasured on Catalyst.
  - Rejected.
- **(f) Show Messages briefly at its own frame behind the front app.**
  - For: the press is measured there.
  - Against: the user sees Messages appear, switch, switch back and disappear, for about 2 s each time.
  - Not in v1. If P1 fails, it is a question for the maintainer, as a separate opt-in like foreground mode.
- **(g) Refuse unless T is selected.**
  - For: safe, and true today with a better result line.
  - It is the fallback for every state the other flows don't cover.

**For a Messages that isn't hidden:** hiding it to switch is useless now, so the choice is between switching in view and refusing. Switching in view is chosen for a window on screen. Every other unhidden state refuses unless T is selected.

**For foreground mode:** a parked switch in step 1 would need E kept across the runner's retake loop (ForegroundRunner.swift:127-152), a parked restore after the finish, and one on every early exit. Foreground mode is opt-in and its actions aren't the goal of this change, so it stays at "T already selected" for now.

## 8. Changes to the state map, DESIGN.md and the code

### research/messages-states.md

- **Section 1 and section 4's flows.** "Act hidden" becomes "act in place" when T is selected, and "switch parked" otherwise. "Hide, act, unhide" and "Hide, foreground, unhide" are removed. "Act in view" becomes "switch in view", or "act in place" when T is selected.
- **Matrix cells for tapback and unsend:**
  - 7: act in place, otherwise switch parked after P1, P2 and P7.
  - 1 and 8: act in place, otherwise switch parked after P1, P2, P7 and P1's launch leg.
  - 9: unchanged refusal, even with Settings open and T selected.
  - 10: act in place or switch in view, both after P4. Until then, today's busy.
  - 11, 12 and 18: act in place after P5, P6 and P2. Otherwise refuse.
  - 13 to 17 and 36 to 38: unchanged refusals.
  - 33: a hidden start refuses when E's row isn't found exactly once, except right after the bridge's own launch as section 3 says.
- **Cells for edit and threaded reply:** only when T is selected, in every state. Otherwise `busy: chat not open in Messages`.
- **G1** keeps the mouse gate and the pointer check, for the parking unhide. The hide of an unhidden window is removed. For switch parked and switch in view, section 4's caps (5 s for the forward leg and the action, 2.5 s for the restore leg) replace G1's 2 s cap from the hide to the press.
- **G2's** unread rule counts switch parked as an unhidden start.
- **G3's** capture is unchanged. The restore runs through the driver. G3's final check "the selected row still resolves to the target" applies before the restore leg's opening press. The unread check moves into the collapse press's final check.
- **G4** applies to the parking unhide and the end hide.
- **G6** keeps only the frontmost start and the hidden start with T selected. The starts from view and from nothing on screen are removed.
- **G8** ignores unhide notifications and unhidden samples while a `parked` record exists. In that span only an activation of Messages counts as a show. Otherwise G8 is unchanged: state 1 still launches Messages hidden and quits it later under G8, and state 8 still relaunches into one hidden window, which switch parked then parks.
- **G12** drops the hidden restore press and gains the `parked` recovery of section 5.
- **G16's** final check also guards the bubble press in act in place on an on-screen window.
- **Coordinates.** States 10 and 18, G17 and probe 1 test frames against `NSScreen`. They move to section 5's coordinates rule: `CGDisplayBounds` over the active displays.
- **Busy and fix lines.** Every `busy: chat not open in Messages` takes the probe-dependent fix line of section 4.
- **Section 8.** Probes 1 and 2 are replaced by P1, P2 and P6. Probe 4 is replaced by P4, and only its behind-the-front-app row leg is marked passed. Probes 5, 6, 8 and 11 change as section 6 says.

### DESIGN.md and docs/BUILD-PLAN.md

- **DESIGN.md section 4, targeting.** Add the one AX write on Messages' window: `AXPosition` for the park and the move back. The list of allowed AX writes is otherwise unchanged.
- **DESIGN.md release test 1.** "A hidden chat switch" becomes switch parked, with a sampler that accepts the parked frame outside every display and fails on a window that touches a display, a new window or a front-app change. A switch-in-view case accepts the window that was already on screen and fails on a raise, a new window or a front-app change. "A failed chat switch turns off all UI actions" becomes "turns off the switching cells".
- **BUILD-PLAN entry 50.** The final-check rule covers `setWindowPosition(_:finalCheck:)`, the opening and collapse presses, and the bubble press in each flow. A new entry records this document.

### Code

- **IMUI/Targeting.swift.** `selectChat` becomes the driver of section 3. It takes the caller's final check for opening presses and the landing check for collapse presses, and returns the presses it made. A `restoreChat` runs the restore leg. A path-check stop returns nothing pressed with no mark-read note.
- **IMUI/AX.swift.**
  - `conversationRows()` reads `AXSelected` three-valued, in place of `bool(...) ?? false` (AX.swift:449).
  - `press(row:)` gains parked and in-view modes, which run the caller's path check in place of `requireHiddenWindow`. No call passes `{}` in those modes.
  - `windowFrame()`, and `setWindowPosition(_:finalCheck:)`, which reads the position back. `MessagesAXDriving` and its doc comment list the new write.
- **IMUI/Actions.swift.** `HiddenActionFlow` takes the chosen flow. `reachBubble` uses the flow's path check in place of `windows.prepare`, and `perform` uses it as the bubble press's final check in place of `windows.recheck()`. That is today's check when hidden, step 6's check when parked, and G16's check on an on-screen window. The restore leg and step 7 run right after the bubble press, before the chat.db verification wait. The 1 s `visibilityCheck` right after the bubble press (Actions.swift:482-483) stays only for act in place on a hidden window. In switch parked it would add 1 s of unhidden time and read the bridge's own unhide as `Messages became visible`, so there the sampler-style checks of steps 4 to 7 replace it. In view the window was visible from the start. The `Messages became visible` note follows the state map's G11.
- **IMForeground/ForegroundRunner.swift.** Today step 1 calls `selectChat` without checking whether T is already selected (ForegroundRunner.swift:213), so on Messages 26 a T that isn't selected returns `error: wrong chat`. `preconditions` reads `AXSelected` first and returns `busy: chat not open in Messages` with the fix line of section 4 when T isn't the one selected row.
- **IMUI/WindowRules.swift.** The decision gains act in place, switch in view, switch parked and refuse with a reason. A parked span returns its plan, so every exit runs step 7.
- **IMUI/MessagesApp.swift.** `unhide()`, the active displays' bounds, the Stage Manager read, and the activation observer for the parked span.
- **IMUI/Capabilities.swift.** Act in place requires `.targeting` only. The switching cells require a new switch capability for each flow, with evidence from release test 1's new cases, in place of `.hiddenChatSwitch` (Capabilities.swift:108-112). The `prerequisites` for edit and threaded reply (Capabilities.swift:110) drop `.hiddenChatSwitch` too, since those run only when T is selected.
- **Install and uninstall.** `imessage uninstall`, and turning the bridge off, run the `parked` recovery before they stop the bridge.
- **IMPolicy/Journal.swift.** The `parked` record and its recovery. IMBridge's Pipeline reads it before the state sample of every UI request, and BridgeMain runs it at start and on the notifications in section 5.
- **IMCore/Results.swift.** `busy: chat not open in Messages`, `fix: open <target> in Messages, then retry`, the notes `chat not restored: two chats selected in Messages` and `chat not restored: new messages in <chat>`, and `doctor`'s `Messages window off screen`.
- **Tests.**
  - The driver against a fake list with toggle presses, with select-alone presses, and with presses that do nothing or land late, including a press that lands after the 1 s poll and after the last two-row read. S3 measured presses at about 31 ms, so this is unlikely. If it happens, the next request's starting point sees two selected rows and refuses.
  - A held modifier stopping a collapse press.
  - Every stop condition, and the two-row check on every exit.
  - The unread check on the restore leg's collapse press.
  - Every exit of switch parked running step 7, and the takeover branch.
  - Recovery with the frame still parked, moved by the user, after a relaunch, and with Messages frontmost.
- **Skill.** skill/imessage/reference.md gains the new busy and fix lines.
