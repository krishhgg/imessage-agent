# iMessage Agent

iMessage Agent lets an agent read, search and send iMessage and SMS on your Mac, and add tapbacks, unsend and edit, through one command, `imessage`. It was built for Grok Bot and also works with grok CLI, Codex and Claude Code.

It runs on your Mac with no server, relay or paid service. The text the CLI prints goes to whatever model your agent uses, the same as any other shell output.

## How it works

- `~/Applications/iMessage Agent.app` is a background app with no Dock icon, called the bridge. It is the only process that gets permissions: Full Disk Access to read `chat.db`, Automation for Messages to send, and Accessibility for tapbacks, unsend and edit. A LaunchAgent starts it when the CLI connects.
- `~/.local/bin/imessage` holds no permissions. It sends named requests to the bridge over a Unix socket and prints one short line per message. No SQL crosses the socket.
- The bridge opens `chat.db` read-only and runs fixed queries with bound parameters.
- The `imessage` skill tells the agent how to call the CLI. Its body is 400 tokens.

Sends to a chat you haven't allowed open a native dialog on the Mac with Deny, Allow once and Always allow this chat. Unsend, edit and threaded reply always ask. Sends are limited to 1 per 20 s per chat, 30 per chat per day, 100 per day, and 3 in a row to a chat that hasn't replied.

## Install

Requires macOS 14 or later.

No release is published yet. Until the first one is, the install steps below stop at the download, so build from source instead (see [Building from source](#building-from-source)).

In Grok Bot, turn on local execution for your Mac and say "Set up iMessage from https://github.com/krishhgg/imessage-agent". Grok Bot follows [INSTALL.md](INSTALL.md). It asks before installing, checks the download against the SHA-256 pinned in INSTALL.md, and walks you through the permission prompts.

For grok CLI, Codex or Claude Code, follow the same file. Step 3 adds `--skill-dir ~/.agents/skills` (grok CLI and Codex) or `--skill-dir ~/.claude/skills` (Claude Code) so install.sh copies the skill there.

install.sh puts the app in `~/Applications`, the CLI in `~/.local/bin` and the LaunchAgent in `~/Library/LaunchAgents`. It needs no admin password and doesn't use git, Homebrew, Xcode or Python.

## What works

Reading, search, `wait`, `changes`, text sends and non-image file sends have no release-test gate and are on for macOS 14 or later.

Tapbacks, unsend, edit, threaded reply, image sends, HEIC to JPEG conversion in `att` and group sends each turn on for a macOS version only after their release test passes on that version, keyed on major.minor (for example 26.2). On any other version `imessage caps` shows them as `untested` and they stay off. Edit and threaded reply also need foreground mode, which is off by default. In that mode Messages comes to the front for a few seconds and then hides again.

Tapbacks, unsend, edit and threaded reply can't reach a pinned chat in v1 and return `not_loaded`, because Messages shows a pinned chat by name only and the bridge needs the preview text and time to find the right row. Unpinning the chat in Messages makes them work.

Tested macOS versions: none yet. No release-test run has happened, so every gated action above is off in this release.

## Token use

These are measured counts, made with tiktoken's `o200k_base` encoding as a stand-in for the host's tokenizer.

The skill, checked on every build by `scripts/check-skill-tokens.sh`:

| Part | Tokens | Cap |
| --- | ---: | ---: |
| Listing description | 36 | 40 |
| Body | 400 | 400 |
| Whole SKILL.md file | 445 | |

`reference.md` (1,467 tokens) loads only when the agent opens it.

Skill files of other iMessage projects for Grok Bot, counted the same way in [bench/results.md](bench/results.md):

| Project | Tokens |
| --- | ---: |
| jeffhuber/grokbot-imessage-skill | 4,627 |
| openclaw/imsg | 1,906 |
| steve228uk/grok-bot-imessage | 1,341 |
| jimmyliu03 apple-messages-reminders | 826 skill, plus 1,153 for its MCP tool list rebuilt from source |
| RyanNewsom/grokbot-imessage-reader | 618 |
| cmer | 175 custom instructions plus 591 tool listing, both rebuilt from source |

Output format, for one synthetic 50-message group chat ([research/tokens.md](research/tokens.md)):

| Format | Tokens |
| --- | ---: |
| Raw chat.db rows as pretty JSON | 17,773 |
| Compact JSON | 6,858 |
| The line format this CLI prints | 1,163 |

The line-format sample came from a research renderer, not the built CLI.

Per-task totals aren't stated here. The bench in `bench/` estimated them from a renderer and a placeholder skill before the CLI existed, so they are projections. This README will give them after the bench runs against the built CLI and the shipped skill.

## Security and its limit

The allowed chats, the approval dialog and the rate limits stop a confused or prompt-injected agent that goes through the CLI. They don't stop a hostile program running as your user, including an agent with unrestricted shell access. Such a program can go around the bridge, for example by asking macOS for its own Messages permissions or by pressing the dialog's buttons through Accessibility. The bridge keeps a hash of the allowlist in the Keychain, so an edit to the allowlist file outside the bridge turns every allowed chat off until you approve them again. That detects tampering. It doesn't prevent it.

Grok Bot's "always allow" for Shell is one grant for every command. Grok Bot's permission for running commands is global, not per command, so "always" lets Grok Bot run any shell command on your Mac without a card, not only `imessage`. With it on, Grok Bot is an agent with unrestricted shell access in the sense above. The dialog still guards everything sent through `imessage`, but nothing stops another shell command from going around it. With "ask", every shell call shows a card, which is why the skill tells the agent to combine steps into one call.

Private Messages APIs exist, and some tools call them with System Integrity Protection turned off. This repo doesn't call them and never asks you to turn SIP off. It uses the Messages AppleScript dictionary to send, named Accessibility actions for tapbacks, unsend and edit, and read-only SQLite for `chat.db`. Its one private call is outside Messages and read-only: it looks up `CGSCopySpacesForWindows` at run time to count the Messages windows on a Space, and counts every window instead on a macOS without it.

Releases are signed with a self-signed certificate and aren't notarized. install.sh downloads the tarball with curl and checks its pinned SHA-256, so macOS shows no Gatekeeper prompt. Check the hash in INSTALL.md against the release page if you want to confirm what you run.

## Uninstall

```
/bin/bash "$HOME/Library/Application Support/iMessage Agent/install.sh" --uninstall
```

It stops the bridge and removes the app, the CLI, the LaunchAgent, the skill copies install.sh made, the Keychain item and the bridge's data, cache and staging folders. If macOS refuses the Keychain delete, it says so, prints the command to run and exits 1. It then prints three `tccutil reset` commands that clear the bridge's permissions if you run them. In Grok Bot, also delete the `imessage` skill.

## Building from source

You need macOS 14 or later and Xcode 16 or later, which has the Swift 6.0 toolchain.

```
swift build
swift test
```

The tests use the synthetic database in `Tests/Fixtures/`. They never touch Messages, your real `chat.db` or a TCC database. The shell tests in `scripts/tests/` cover install.sh, the build script's keychain step, the skill token check and the release-test helpers.

`scripts/build.sh` makes a signed universal release in `out/`. It holds the app, the CLI, the tarball, a standalone install.sh with the tarball's SHA-256 pinned, and `SHA256SUMS`. The script refuses to build unsigned. Set these first:

- `SIGN_IDENTITY`, the SHA-1 hash of a code-signing identity. A self-signed code-signing certificate made in Keychain Access works.
- `SIGN_KEYCHAIN`, the keychain file that holds that identity.
- `SIGN_KEYCHAIN_PW_FILE`, a file that holds that keychain's password. Keep it outside the repo.

The build also checks the skill's token caps. That needs Python 3 with tiktoken at `bench/.venv/bin/python`, or another Python named in `TOKEN_PYTHON`:

```
python3 -m venv bench/.venv && bench/.venv/bin/pip install tiktoken==0.14.0
```

To install your build, run `IMESSAGE_AGENT_TARBALL="$PWD/out/imessage-agent-<version>.tar.gz" bash out/install.sh` from the repo root. macOS treats a build signed with your own certificate as a different app from a release, even with the same bundle id, so permissions and the Keychain item don't carry over. Uninstall any release first and run the three `tccutil reset` commands the uninstaller prints.

The build also rewrites the pins in INSTALL.md. Commit that change only when you tag a release.

`scripts/build.sh --release-tests` builds the maintainer-only test build in `out/release-tests/`. That build turns every gated action on and never goes into a release. [scripts/release-tests/README.md](scripts/release-tests/README.md) explains how to run the release tests and record their results.
