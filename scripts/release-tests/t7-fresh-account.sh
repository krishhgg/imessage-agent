#!/bin/bash
# Release test 7: fresh account (DESIGN.md "Release tests" item 7). On a fresh macOS user account, the grants appear
# only under the bridge.
#
# Usage, logged in as a fresh macOS user that has never had iMessage Agent:
#   IMSG_TEST_HANDLE=<your Apple ID> t7-fresh-account.sh [--share FILE]
#
# Install iMessage Agent in that account first (README.md in this folder). The test walks through `imessage setup`
# and `imessage doctor --ui`, then asks you to check three panes in System Settings, Privacy & Security. It reads no
# privacy database. It sends nothing.
#
# The outcome goes to a results folder in this account's home (IMSG_RT_RESULTS overrides it), because the copy of
# this folder in /Users/Shared belongs to your own account. It also goes to --share FILE (default
# /Users/Shared/imessage-agent-t7.txt), which holds only the outcome lines. Back in your own account, pass that file
# to run.sh with --with-t7. A failure blocks the tag.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(dirname "$0")/lib.sh"
SHARE=/Users/Shared/imessage-agent-t7.txt
while (($#)); do
    case "$1" in
        --share) [[ $# -ge 2 ]] || die "--share needs a file"; SHARE="$2"; shift 2 ;;
        *) die "usage: t7-fresh-account.sh [--share FILE]" ;;
    esac
done
IMSG_RT_RESULTS="${IMSG_RT_RESULTS:-$HOME/imessage-agent-release-tests/$(macos_major_minor)-$(date +%Y%m%d-%H%M%S)-t7}"
rt_init 7 manual

PROBLEMS=""
problem() { PROBLEMS="$PROBLEMS; $*"; msg "   problem: $*"; }

[[ -d "$APP" ]] || die "no app at $APP fix: install iMessage Agent in this account first"
yes_no "Is this a macOS user account that never had iMessage Agent, its grants, or a Terminal or Grok Bot grant?" \
    || die "run this on a fresh macOS user account"
ask "Open Messages once, sign in to iMessage if it asks, then quit Messages." || die "Messages setup skipped"

tell "Next, imessage setup opens the Full Disk Access pane. Turn on iMessage Agent there, then come back."
im setup
msg "   setup exit $IM_RC"
ask "Turn on iMessage Agent in Full Disk Access." || problem "Full Disk Access step skipped"

tell "Next, imessage doctor --ui raises the Automation and Accessibility prompts. Allow both for iMessage Agent."
im doctor --ui
msg "   doctor --ui exit $IM_RC"
ask "If Accessibility asked you to open System Settings, turn on iMessage Agent there." || problem "Accessibility step skipped"

im doctor
[[ "$IM_RC" == 0 ]] || problem "imessage doctor exited $IM_RC"
im chats -n 1
[[ "$IM_RC" == 0 ]] || problem "imessage chats -n 1 exited $IM_RC"

yes_no "Open System Settings, Privacy & Security, Full Disk Access. Is iMessage Agent listed and on, with no Terminal, Grok Bot or other app added during this test?" \
    || problem "Full Disk Access pane"
yes_no "Open Privacy & Security, Automation. Is iMessage Agent listed with Messages under it, and no Terminal or Grok Bot entry?" \
    || problem "Automation pane"
yes_no "Open Privacy & Security, Accessibility. Is iMessage Agent listed and on, with no Terminal or Grok Bot entry?" \
    || problem "Accessibility pane"

MM="$(macos_major_minor)"
echo "env macos $MM bridge $(bridge_version)" >>"$OUTCOMES"
if [[ -z "$PROBLEMS" ]]; then
    gate pass fresh-account 7 "macOS $MM: grants only under iMessage Agent, doctor and chats ran"
else
    gate fail fresh-account 7 "macOS $MM:${PROBLEMS#;}"
fi
if grep -E '^(env|gate) ' "$OUTCOMES" 2>/dev/null >"$SHARE" && chmod 644 "$SHARE"; then
    msg "outcome copied to $SHARE. In your own account, run run.sh --with-t7 $SHARE"
else
    msg "error: couldn't write $SHARE fix: delete the old file from your own account, or pass --share with another path"
    msg "The outcome is also in $OUTCOMES."
    exit 1
fi
msg "== release test 7 done"
