# imessage reference

Details the skill body leaves out. The CLI is `$HOME/.local/bin/imessage`.

## Targets

- `<who>` takes a name, phone, email, chat id or chat number. A contact's iMessage and SMS chats count as one conversation.
- A group's name matches from the start of any word in it, so `Fam` finds `Family`. A chat number never matches a group name.
- A phone number or email with no chat yet works too. The first send starts the chat on iMessage, or on SMS when Messages has seen that number only on SMS.
- A target that matches more than one contact or conversation returns `error: several matches` with the candidates, and nothing runs.
- `who <name>` lists a contact's handles and chats.

## Reading

- `chats [-n 20] [--unread]`: recent chats with unread counts and the newest message.
- `unread [-c 2]`: unread messages across all chats, with `-c` lines of context before each run.
- `read <who> [-n 30] [--before <msg>|--after <msg>|--around <msg>] [--since T]`.
- `show <msg>`: one message in full, up to 8 KB per page. Bodies in lists are cut at 400 characters with a `show` pointer.
- `T` is `30m`, `12h`, `7d`, `2w`, `today`, `yesterday`, `YYYY-MM-DD` or `YYYY-MM-DDTHH:MM`.
- Each message is one line: `<rowid> <HH:MM> <Sender>: [↩<rowid>] <text> [attachments] [(edited)|(unsent)] [reactions]`. Tapbacks fold into the line they react to.
- Attachments print as `[photo a9901 2.2MB]`. `att 9901` prints the path of a viewable copy. A file still in iCloud returns `not_downloaded`. HEIC converts to JPEG only where `caps` lists that conversion as supported.
- Each call prints at most 200 lines and about 12 KB. The footer gives the next page.
- `--json` prints NDJSON instead of text.

## Search

- `search <text> [--in <who>] [--since T] [--cursor C] [-n 20]` searches decoded bodies, newest first, within the last year by default.
- Matching ignores case for ASCII letters only. A case difference outside ASCII (for example `É` and `é`) can miss, so retry with the exact case.
- Each page says how far back it scanned and gives a cursor for the next page.

## Sending

- `send <who> <text>`, `send <who> --file <path>`, or both. Files are at most 100 MB. Text and file parts get separate results.
- Results: `submitted` (the row exists), `delivered`, `failed <error>`, `ghost`, `ambiguous: two rows matched`, `may_have_completed`. SMS stays at `submitted`. `chat unconfirmed` means the chat join hadn't appeared yet.
- Never resend after `may_have_completed`, `submitted` or `ghost`. Read the chat first.
- Group sends and image file sends work only where `caps` lists them as supported.
- RCS chats send on the iMessage account and may fail.
- Rate limits: 1 send per 20 s per chat, 30 per chat per day, 100 per day, and at most 3 sends in a row to a chat with no reply. Past a limit the send asks for approval.

## Approvals and allowed chats

- Sends to allowed chats within the limits go through without asking. Anything else opens a dialog on the Mac with Deny, Allow once and Always allow this chat.
- The CLI waits 120 s for the dialog, then prints `pending <id>`. `pending <id>` collects the result later. An approval unanswered for 10 minutes gives `denied: approval expired`.
- `allow <who> [--files]` and `revoke <who>` change the allowed chats. Each change opens the dialog. `--files` also allows attachments.
- `unsend`, `edit` and `send --thread` always ask.
- `--again` repeats an action that would otherwise return the first result, for example sending the same text twice on purpose. It never skips the dialog.
- `denied` also comes back for 10 minutes when the same action runs again, without a new dialog. If the user changes their mind and asks to retry, add `--again`. `denied: approval expired` doesn't come back.

## UI actions

- `react <msg> <kind> [--remove]`: kinds are heart, like, dislike, laugh, emphasize, question, or one recent emoji. `already` means nothing would change.
- `unsend <msg>` works within 2 minutes of sending. `edit <msg> <text>` works within 15 minutes. After that the result is `expired`.
- They work on 1:1 chats and single-part text messages that Messages has loaded. Others return `unsupported_target` or `not_loaded`.
- They can't reach pinned chats in v1 and return `not_loaded`. Unpinning the chat in Messages makes them work.
- `ambiguous` means the target couldn't be told apart from another chat or message, so nothing was pressed.
- `busy: Messages is open` means the user has Messages open. Ask them to hide it (⌘H) and retry. Sends still work.
- `busy: chat not open in Messages` means the target chat isn't the one chat selected in Messages. On Messages 26 the bridge can't switch chats while Messages is in the background, so nothing was pressed. Tell the user the fix line: open that chat in Messages, hide it (⌘H), then retry.
- `busy: screen locked` means the Mac is locked, and the bridge leaves Messages alone until it is unlocked. Retry after the user unlocks it. Sends still work.
- Results after a press add `chat opened, may be marked read`.

## Foreground mode

- `edit` and `send --thread` need foreground mode, which is off by default. `allow --foreground` turns it on through the dialog and `revoke --foreground` turns it off.
- In foreground mode Messages comes to the front for a few seconds, then hides, and the earlier app returns.
- `send <who> <text> --thread` replies in a thread to the chat's newest incoming message. It can't be combined with `--file`.
- `busy: user active` means the user kept typing or clicking for 30 s. `aborted: user took over` means the user acted during the action. `agent text may still be in the field` means the user should check the Messages composer.

## Incoming messages

- `wait [--from <who>] [--timeout 300]` blocks until a new inbound message arrives, or prints `timeout`. Messages the bridge sent never count.
- `changes [--since <cursor>]` lists new messages, edits, unsends, reads and deliveries since a cursor. With no `--since` it prints the current cursor only.

## Health

- `caps` shows what works on this macOS version. `untested` and `unsupported` actions are off.
- `doctor` checks permissions and the bridge. `doctor --ui` also asks for Accessibility, which UI actions need.
- Exit codes: 0 success, 1 an `error:` line or a failed action, 2 a usage error, 3 the bridge isn't reachable.
