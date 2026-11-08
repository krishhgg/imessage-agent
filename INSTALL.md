# Set up iMessage Agent

This file is a prompt for Grok Bot. When the user asks you to set up iMessage from this repo, follow the steps below in order. Every command runs on the user's Mac through your shell tool. Combine the commands of a step into one shell call, because each call can cost the user an approval.

## Step 1: check the computer

Run:

```
uname -s
```

If the output isn't `Darwin`, stop. Tell the user this needs a Mac, and that Grok Bot's local execution setting must be on for that Mac.

## Step 2: ask before installing

Ask the user with a question widget before you install anything. Tell them:

- It installs `~/Applications/iMessage Agent.app` (a background app with no Dock icon), the `imessage` command at `~/.local/bin/imessage` and a LaunchAgent that starts the app when the command needs it.
- macOS will ask for Full Disk Access (to read messages) and Automation for Messages (to send). Tapbacks, unsend and edit also need Accessibility. Only iMessage Agent gets these permissions.
- Sends to chats the user hasn't allowed open a dialog on the Mac first.

Offer three answers: install with tapbacks, unsend and edit; install for reading and sending only; don't install. On the last one, stop.

## Step 3: download, check and run install.sh

Run this as one shell call. It downloads `install.sh` from the release, checks it against the SHA-256 pinned here, then runs it. install.sh checks the release tarball against its own pin the same way. It doesn't use git, Homebrew, Xcode or Python.

```
TAG="unreleased"
SHA256="unreleased"
t="$(mktemp -d)" && /usr/bin/curl -fsSL --proto '=https' --tlsv1.2 -o "$t/install.sh" "https://github.com/krishhgg/imessage-agent/releases/download/$TAG/install.sh" && echo "$SHA256  $t/install.sh" | /usr/bin/shasum -a 256 -c - && /bin/bash "$t/install.sh"
```

If `TAG` above is `unreleased`, there is no release yet, so stop and tell the user. If the download fails, the check fails or install.sh prints an `error:` line, stop and show the user the error. Never edit the pinned values and never run install.sh without the check.

## Step 4: Full Disk Access

Run:

```
"$HOME/.local/bin/imessage" setup
```

It opens the Full Disk Access pane in System Settings and returns at once. End your turn. Ask the user to turn on iMessage Agent in that list and then reply "done".

## Step 5: check and finish permissions

When the user says "done", run `"$HOME/.local/bin/imessage" doctor`, or `"$HOME/.local/bin/imessage" doctor --ui` if they chose tapbacks, unsend and edit in step 2.

`doctor` checks that the bridge can read messages and restarts it if it can't. Then macOS asks whether iMessage Agent may control Messages, and the user clicks OK. With `--ui`, macOS also asks for Accessibility, and the user turns on iMessage Agent in that pane.

`doctor` exits 0 even when a check fails, so read its lines. If a line starts with `fail` or `error:`, show it to the user and follow its `fix:`. When the fix is something the user does on the Mac, such as turning on iMessage Agent in a System Settings pane, end your turn and ask them to reply "done". Then run the same `doctor` command again. Go on to step 6 only when no line starts with `fail` or `error:`.

## Step 6: save the skill

Save the skill with your skill tool under the name `imessage`. Its text is `skill/imessage/SKILL.md` in this repo at the tag from step 3. If the tool takes extra files, add `skill/imessage/reference.md` next to it. Don't also copy it into `~/.agents/skills`, so the skill doesn't load twice.

## Step 7: try it

Run:

```
"$HOME/.local/bin/imessage" chats -n 3
```

Show the user the result. Then offer to send a test message to their own Apple ID. If they agree, ask for that Apple ID (their email or phone number) and run:

```
"$HOME/.local/bin/imessage" send "<their Apple ID>" "Test from iMessage Agent"
```

A dialog opens on the Mac. The user clicks Allow once, or Always allow this chat.

## Other hosts

grok CLI, Codex and Claude Code read skills from a folder. Follow the same steps, skip step 6, and in step 3 add `--skill-dir` to the last command so install.sh copies the skill folder into that host's skills folder:

- grok CLI and Codex: `/bin/bash "$t/install.sh" --skill-dir ~/.agents/skills`
- Claude Code: `/bin/bash "$t/install.sh" --skill-dir ~/.claude/skills`

## Uninstall

Run:

```
/bin/bash "$HOME/Library/Application Support/iMessage Agent/install.sh" --uninstall
```

It stops the bridge, removes the app, the command, the LaunchAgent, the skill copies install.sh made, the Keychain item and the bridge's data, cache and staging folders. If macOS refuses the Keychain delete, it removes the rest, prints an `error:` line with the command to run and exits 1. Show that command to the user. It prints three `tccutil reset` commands. Show them to the user to run if they want the permissions cleared. Then delete the `imessage` skill from your skill tool.
