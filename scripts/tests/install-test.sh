#!/bin/bash
# Dry-run tests for install.sh under fake HOME folders in a temporary directory.
#
# Usage: scripts/tests/install-test.sh [--built]
#
# The tests build a small fake release tarball, pin it in a copy of install.sh the way scripts/build.sh does, and run
# install, upgrade and uninstall with IMESSAGE_AGENT_NO_SYSTEM=1, so launchctl, lsregister and the Keychain are never
# touched. launchctl and security on PATH are stubs that record any call, and a recorded call fails the run.
# --built also installs the real out/ tarball through out/install.sh and checks the installed app's signature.
#
# The ~ in quoted --skill-dir values and the $1 in bash -c strings are meant literally.
# shellcheck disable=SC2016,SC2088
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUILT=0
case "${1:-}" in
    "") ;;
    --built) BUILT=1 ;;
    *) echo "usage: scripts/tests/install-test.sh [--built]" >&2; exit 2 ;;
esac

# /tmp keeps the fake HOME paths short enough for the socket-length cases below.
T="$(mktemp -d /tmp/imessage-install-test.XXXXXX)"
trap 'rm -rf "$T"' EXIT
PASSED=0
FAILED=0
pass() { PASSED=$((PASSED + 1)); echo "ok    $*"; }
fail() { FAILED=$((FAILED + 1)); echo "FAIL  $*"; }
check() {
    local name="$1"
    shift
    if "$@"; then pass "$name"; else fail "$name"; fi
}

LABEL=io.github.krishhgg.imessage-agent
APP_NAME="iMessage Agent"

# Stubs that stand in for the system tools a dry run must never reach.
STUBS="$T/stubs"
mkdir -p "$STUBS"
for tool in launchctl security tccutil; do
    printf '#!/bin/bash\necho "%s $*" >>"%s/system-calls"\nexit 1\n' "$tool" "$T" >"$STUBS/$tool"
    chmod 755 "$STUBS/$tool"
done

# A fake release: same layout as the tarball scripts/build.sh writes, with shell scripts for the two binaries.
VERSION=9.9.9
PKG="imessage-agent-$VERSION"
mkdir -p "$T/stage/$PKG/$APP_NAME.app/Contents/MacOS" "$T/stage/$PKG/skill"
printf '#!/bin/sh\nexit 0\n' >"$T/stage/$PKG/$APP_NAME.app/Contents/MacOS/IMessageAgent"
printf '#!/bin/sh\necho fake imessage\n' >"$T/stage/$PKG/imessage"
chmod 755 "$T/stage/$PKG/$APP_NAME.app/Contents/MacOS/IMessageAgent" "$T/stage/$PKG/imessage"
cp "$ROOT/packaging/$LABEL.plist" "$T/stage/$PKG/"
cp -R "$ROOT/skill/imessage" "$T/stage/$PKG/skill/imessage"
cp "$ROOT/install.sh" "$T/stage/$PKG/install.sh"
TARBALL="$T/$PKG.tar.gz"
COPYFILE_DISABLE=1 tar -czf "$TARBALL" -C "$T/stage" "$PKG"
TARBALL_SHA="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
PINNED="$T/install.sh"
sed -e "s|^PINNED_VERSION=\"\"\$|PINNED_VERSION=\"$VERSION\"|" \
    -e "s|^PINNED_TARBALL_SHA256=\"\"\$|PINNED_TARBALL_SHA256=\"$TARBALL_SHA\"|" "$ROOT/install.sh" >"$PINNED"
check "the test copy of install.sh has both pins" grep -q -x "PINNED_TARBALL_SHA256=\"$TARBALL_SHA\"" "$PINNED"

# run <home> <cwd> <tarball> <script> [args...]: runs install.sh under a fake HOME. Output goes to $OUT_FILE and
# $ERR_FILE, and $RC holds the exit code.
OUT_FILE="$T/out.txt"
ERR_FILE="$T/err.txt"
RC=0
run() {
    local home="$1" cwd="$2" tarball="$3"
    shift 3
    (cd "$cwd" && env HOME="$home" PATH="$STUBS:/usr/bin:/bin:/usr/sbin:/sbin" TMPDIR="$T" \
        IMESSAGE_AGENT_NO_SYSTEM=1 IMESSAGE_AGENT_TARBALL="$tarball" /bin/bash "$@") >"$OUT_FILE" 2>"$ERR_FILE"
    RC=$?
}
new_home() {
    local h="$T/$1"
    mkdir -p "$h"
    echo "$h"
}
untouched() {
    local h="$1"
    [[ ! -e "$h/Applications" && ! -e "$h/.local" && ! -e "$h/Library" && ! -e "$h/.imessage-agent" ]]
}
err_has() { grep -q -F -- "$1" "$ERR_FILE"; }
out_has() { grep -q -F -- "$1" "$OUT_FILE"; }
not_out_has() { ! grep -q -F -- "$1" "$OUT_FILE"; }
mode_is() { [[ "$(stat -f %Lp "$1" 2>/dev/null)" == "$2" ]]; }
plist_is() { [[ "$(plutil -extract "$2" raw -o - "$1" 2>/dev/null)" == "$3" ]]; }
same_file() { cmp -s "$1" "$2"; }

# Refusals that must leave HOME untouched.
H="$(new_home refuse)"
run "$H" "$H" "$TARBALL" "$ROOT/install.sh"
check "the unpinned repo copy refuses to install" test "$RC" = 1
check "the unpinned refusal names the missing pin" err_has "has no pinned release"
check "the unpinned refusal changes nothing" untouched "$H"

cp "$TARBALL" "$T/tampered.tar.gz"
printf 'x' >>"$T/tampered.tar.gz"
run "$H" "$H" "$T/tampered.tar.gz" "$PINNED"
check "a tarball with the wrong SHA-256 is refused" test "$RC" = 1
check "the SHA-256 refusal shows both hashes" err_has "expected $TARBALL_SHA"
check "the SHA-256 refusal changes nothing" untouched "$H"

mkdir -p "$H/.claude/skills/imessage"
echo foreign >"$H/.claude/skills/imessage/SKILL.md"
run "$H" "$H" "$TARBALL" "$PINNED" --skill-dir '~/.claude/skills'
check "a skill folder install.sh didn't create is refused" test "$RC" = 1
check "the foreign-folder refusal says nothing was installed" err_has "didn't create it. Nothing was installed"
check "the foreign-folder refusal changes nothing" untouched "$H"
check "the foreign skill folder is left as it was" grep -q -x foreign "$H/.claude/skills/imessage/SKILL.md"

run "$H" "$H" "$TARBALL" "$PINNED" --skill-dir "$T/outside-home/skills"
check "a --skill-dir outside HOME is refused" test "$RC" = 1
check "the outside-HOME refusal names the rule" err_has "is outside $H or has a .. part"
check "the outside-HOME refusal changes nothing" untouched "$H"
check "the outside-HOME refusal creates no folder there" test ! -e "$T/outside-home"

run "$H" "$H" "$TARBALL" "$PINNED" --skill-dir "$H/../refuse-escape/skills"
check "a --skill-dir with a .. part is refused" test "$RC" = 1
check "the .. refusal changes nothing" untouched "$H"

run "$H" "$H" "$TARBALL" "$PINNED" --uninstall --skill-dir x
check "--uninstall with --skill-dir is a usage error" test "$RC" = 1
run "$H" "$H" "$TARBALL" "$PINNED" --bogus
check "an unknown argument is refused" test "$RC" = 1
run "$H" "$H" "$TARBALL" "$PINNED" --skill-dir
check "--skill-dir without a folder is refused" test "$RC" = 1
check "argument errors change nothing" untouched "$H"

# A HOME so long that neither socket path fits in sun_path: the fallback path is HOME plus 28 bytes, and the limit
# is 103 bytes plus the NUL.
LONG="$T/$(printf 'h%.0s' {1..90})"
mkdir -p "$LONG"
run "$LONG" "$LONG" "$TARBALL" "$PINNED"
check "a HOME too long for either socket path is refused" test "$RC" = 1
check "the socket refusal says why" err_has "too long for a Unix socket"
check "the socket refusal changes nothing" untouched "$LONG"

# Install with a ~ skill folder and a relative one.
H="$(new_home main)"
AS="$H/Library/Application Support/$APP_NAME"
APP="$H/Applications/$APP_NAME.app"
CLI="$H/.local/bin/imessage"
PLIST="$H/Library/LaunchAgents/$LABEL.plist"
MANIFEST="$AS/install-manifest.txt"
mkdir -p "$H/work"
run "$H" "$H/work" "$TARBALL" "$PINNED" --skill-dir '~/.agents/skills' --skill-dir=rel-skills
check "install exits 0" test "$RC" = 0
[[ "$RC" == 0 ]] || sed 's/^/      /' "$ERR_FILE"
for f in "$APP/Contents/MacOS/IMessageAgent" "$CLI" "$PLIST" "$AS/install.sh" "$MANIFEST" \
    "$H/.agents/skills/imessage/SKILL.md" "$H/.agents/skills/imessage/reference.md" "$H/work/rel-skills/imessage/SKILL.md"; do
    check "install wrote ${f#"$H"/}" test -f "$f"
done
check "the app-support folder is 0700" mode_is "$AS" 700
check "the manifest is 0600" mode_is "$MANIFEST" 600
check "the CLI is 0755" mode_is "$CLI" 755
check "the LaunchAgent is 0644" mode_is "$PLIST" 644
check "the installed skill matches the repo" same_file "$H/.agents/skills/imessage/SKILL.md" "$ROOT/skill/imessage/SKILL.md"
check "the kept install.sh is the unpinned repo copy" same_file "$AS/install.sh" "$ROOT/install.sh"
check "plist Label" plist_is "$PLIST" Label "$LABEL"
check "plist Program is the installed binary" plist_is "$PLIST" Program "$APP/Contents/MacOS/IMessageAgent"
check "plist socket is the primary path" plist_is "$PLIST" Sockets.Listener.SockPathName "$AS/bridge.sock"
check "plist socket mode is 0600 (384)" plist_is "$PLIST" Sockets.Listener.SockPathMode 384
check "plist log goes to the app-support folder" plist_is "$PLIST" StandardErrorPath "$AS/bridge.log"
check "plist keeps the Aqua session limit" plist_is "$PLIST" LimitLoadToSessionType Aqua
check "plist has no ~/ path left" bash -c '! plutil -convert xml1 -o - "$1" | grep -q "<string>~/"' _ "$PLIST"
check "plist has no EnvironmentVariables" bash -c '! plutil -extract EnvironmentVariables raw -o - "$1" >/dev/null 2>&1' _ "$PLIST"
check "a short HOME gets no fallback socket folder" test ! -e "$H/.imessage-agent"
check "the dry run printed the bootout" out_has "dry run, skipped: launchctl bootout gui/"
check "the dry run printed the lsregister call" out_has "lsregister -f $APP"
check "the dry run printed the bootstrap" out_has "dry run, skipped: launchctl bootstrap gui/"
for p in "$APP" "$CLI" "$PLIST" "$AS/install.sh" "$H/.agents/skills/imessage" "$H/work/rel-skills/imessage"; do
    check "the manifest lists ${p#"$H"/}" grep -q -x -F -- "$p" "$MANIFEST"
done

# Upgrade: the stale skill copies from the manifest are refreshed without --skill-dir.
echo stale >"$H/.agents/skills/imessage/SKILL.md"
echo stale >"$H/work/rel-skills/imessage/SKILL.md"
run "$H" "$H" "$TARBALL" "$PINNED"
check "an upgrade exits 0" test "$RC" = 0
check "the upgrade refreshed the ~ skill copy" same_file "$H/.agents/skills/imessage/SKILL.md" "$ROOT/skill/imessage/SKILL.md"
check "the upgrade refreshed the relative skill copy" same_file "$H/work/rel-skills/imessage/SKILL.md" "$ROOT/skill/imessage/SKILL.md"
check "the upgrade lists each path once" test "$(sort "$MANIFEST" | uniq -d | wc -l | tr -d ' ')" = 0

# Uninstall through the kept copy, with bridge data, cache, staging and a foreign skill folder present.
mkdir -p "$H/Library/Caches/$LABEL" "$H/Pictures/$APP_NAME" "$H/.claude/skills/imessage"
echo foreign >"$H/.claude/skills/imessage/SKILL.md"
touch "$AS/policy.json" "$AS/bridge.log" "$H/Library/Caches/$LABEL/x.jpg" "$H/Pictures/$APP_NAME/staged.heic"
run "$H" "$H" "$TARBALL" "$AS/install.sh" --uninstall
check "uninstall exits 0" test "$RC" = 0
for p in "$APP" "$CLI" "$PLIST" "$AS" "$H/Library/Caches/$LABEL" "$H/Pictures/$APP_NAME" \
    "$H/.agents/skills/imessage" "$H/work/rel-skills/imessage"; do
    check "uninstall removed ${p#"$H"/}" test ! -e "$p"
done
check "uninstall kept the foreign skill folder" grep -q -x foreign "$H/.claude/skills/imessage/SKILL.md"
check "uninstall kept the parent skills folder" test -d "$H/.agents/skills"
check "the dry run printed the Keychain delete" \
    out_has "dry run, skipped: security delete-generic-password -s $LABEL.policy -a allowlist-hash"
check "the dry run doesn't claim it removed the Keychain item" not_out_has "removed Keychain item"
check "uninstall prints three tccutil lines" test "$(grep -c '^  tccutil reset ' "$OUT_FILE")" = 3
for service in SystemPolicyAllFiles AppleEvents Accessibility; do
    check "uninstall prints the $service reset" out_has "tccutil reset $service $LABEL"
done
run "$H" "$H" "$TARBALL" "$PINNED" --uninstall
check "a second uninstall exits 0" test "$RC" = 0

# Uninstall that runs the Keychain delete for real, against stubs in their own folder. STUB_SECURITY_RC sets the
# stub's exit code: 0 deleted, 44 no item, 1 refused. These stubs record to their own file, so the final check
# still proves the dry runs reached no system tool.
KC_STUBS="$T/kc-stubs"
mkdir -p "$KC_STUBS"
printf '#!/bin/bash\necho "launchctl $*" >>"%s/kc-calls"\nexit 3\n' "$T" >"$KC_STUBS/launchctl"
printf '#!/bin/bash\necho "security $*" >>"%s/kc-calls"\nexit "${STUB_SECURITY_RC:-0}"\n' "$T" >"$KC_STUBS/security"
chmod 755 "$KC_STUBS/launchctl" "$KC_STUBS/security"
KC_PATH="$KC_STUBS:/usr/bin:/bin:/usr/sbin:/sbin"
run_keychain() {
    local home="$1" code="$2"
    shift 2
    (cd "$home" && env HOME="$home" PATH="$KC_PATH" TMPDIR="$T" STUB_SECURITY_RC="$code" /bin/bash "$@") \
        >"$OUT_FILE" 2>"$ERR_FILE"
    RC=$?
}
# The real security must never run here, so the cases run only when PATH finds the stubs first.
if [[ "$(env PATH="$KC_PATH" /bin/bash -c 'command -v security; command -v launchctl')" \
    == "$KC_STUBS/security"$'\n'"$KC_STUBS/launchctl" ]]; then
    H="$(new_home kc-refused)"
    mkdir -p "$H/Library/Application Support/$APP_NAME"
    run_keychain "$H" 1 "$PINNED" --uninstall
    check "a refused Keychain delete fails the uninstall" test "$RC" = 1
    check "a refused Keychain delete prints an error with the exit code and the fix" \
        err_has "error: couldn't delete Keychain item $LABEL.policy (security exit 1) fix: security delete-generic-password -s $LABEL.policy -a allowlist-hash"
    check "a refused Keychain delete isn't reported as a clean removal" not_out_has "iMessage Agent is removed. "
    check "a refused Keychain delete says the item is left" out_has "removed except its Keychain item"
    check "the rest is still removed after a refused Keychain delete" test ! -e "$H/Library/Application Support/$APP_NAME"
    check "the stubbed security got the delete" \
        grep -q -x -F "security delete-generic-password -s $LABEL.policy -a allowlist-hash" "$T/kc-calls"
    H="$(new_home kc-missing)"
    run_keychain "$H" 44 "$PINNED" --uninstall
    check "an uninstall with no Keychain item exits 0" test "$RC" = 0
    check "a missing Keychain item prints no error" test ! -s "$ERR_FILE"
    check "a missing Keychain item still reports a clean removal" out_has "iMessage Agent is removed. "
    H="$(new_home kc-deleted)"
    run_keychain "$H" 0 "$PINNED" --uninstall
    check "an uninstall that deletes the Keychain item exits 0" test "$RC" = 0
    check "a deleted Keychain item is reported" out_has "removed Keychain item $LABEL.policy"
    check "a deleted Keychain item prints no error" test ! -s "$ERR_FILE"
else
    fail "the Keychain uninstall cases need PATH to find the stub security and launchctl first"
fi

# Uninstall with manifest lines that are gone, outside HOME, or not a shape install.sh creates.
H="$(new_home odd-manifest)"
AS="$H/Library/Application Support/$APP_NAME"
mkdir -p "$AS" "$H/Library/Caches/$LABEL" "$T/victim/imessage" "$H/notes"
echo keep >"$T/victim/imessage/SKILL.md"
echo keep >"$H/notes/todo.txt"
printf '%s\n' "$H/.claude/skills/imessage" "$T/victim/imessage" "$H/../victim/imessage" "$H/notes" "$H" >"$AS/install-manifest.txt"
run "$H" "$H" "$TARBALL" "$PINNED" --uninstall
check "uninstall goes on past a manifest entry that is already gone" test "$RC" = 0
check "uninstall still removes the cache after that entry" test ! -e "$H/Library/Caches/$LABEL"
check "uninstall leaves a skill copy outside HOME" grep -q -x keep "$T/victim/imessage/SKILL.md"
check "uninstall reports the outside-HOME entry" out_has "left in place (outside HOME): $T/victim/imessage"
check "uninstall leaves a .. entry" out_has "left in place (outside HOME): $H/../victim/imessage"
check "uninstall leaves a folder that isn't a shape it creates" grep -q -x keep "$H/notes/todo.txt"
check "uninstall never removes HOME" test -d "$H"

# A skill copy that fails after another one worked. The manifest keeps the one made, so a retry refreshes it
# instead of refusing it as a folder install.sh didn't create.
H="$(new_home partial)"
mkdir -p "$H/locked"
chmod 555 "$H/locked"
run "$H" "$H" "$TARBALL" "$PINNED" --skill-dir '~/.agents/skills' --skill-dir '~/locked/skills'
check "a skill copy into a folder that can't be written fails the install" test "$RC" != 0
check "the manifest lists the skill copy made before the failure" \
    grep -q -x -F "$H/.agents/skills/imessage" "$H/Library/Application Support/$APP_NAME/install-manifest.txt"
chmod 755 "$H/locked"
run "$H" "$H" "$TARBALL" "$PINNED" --skill-dir '~/.agents/skills' --skill-dir '~/locked/skills'
check "a retry after the failed skill copy exits 0" test "$RC" = 0
[[ "$RC" == 0 ]] || sed 's/^/      /' "$ERR_FILE"
check "the retry copied the skill into the folder that failed" test -f "$H/locked/skills/imessage/SKILL.md"

# A skills folder that became a symlink out of HOME after the install. The imessage folder behind it isn't the copy
# install.sh made, so neither an upgrade nor an uninstall touches it.
H="$(new_home relink)"
run "$H" "$H" "$TARBALL" "$PINNED" --skill-dir '~/.claude/skills'
check "the relink install exits 0" test "$RC" = 0
rm -rf "$H/.claude/skills"
mkdir -p "$T/moved/skills/imessage"
echo foreign >"$T/moved/skills/imessage/SKILL.md"
ln -s "$T/moved/skills" "$H/.claude/skills"
run "$H" "$H" "$TARBALL" "$PINNED"
check "an upgrade exits 0 with a skills folder that links out of HOME" test "$RC" = 0
check "an upgrade leaves a skill folder whose parent links out of HOME" grep -q -x foreign "$T/moved/skills/imessage/SKILL.md"
run "$H" "$H" "$TARBALL" "$H/Library/Application Support/$APP_NAME/install.sh" --uninstall
check "uninstall leaves a skill folder whose parent links out of HOME" grep -q -x foreign "$T/moved/skills/imessage/SKILL.md"
check "uninstall reports the entry that links out of HOME" \
    out_has "left in place (outside HOME through a symlink): $H/.claude/skills/imessage"

# A --skill-dir that leads out of HOME through a symlink is refused. One that links inside HOME is fine.
H="$(new_home link-refuse)"
mkdir -p "$T/link-target"
ln -s "$T/link-target" "$H/linked"
run "$H" "$H" "$TARBALL" "$PINNED" --skill-dir '~/linked/skills'
check "a --skill-dir that leads out of HOME through a symlink is refused" test "$RC" = 1
check "the symlink refusal names the rule" err_has "leads outside $H through a symlink"
check "the symlink refusal changes nothing" untouched "$H"
check "the symlink refusal creates no folder there" test ! -e "$T/link-target/skills"
# A dangling symlink could point out of HOME once its target exists, so a --skill-dir through one is refused before
# anything changes.
H2="$(new_home dangle)"
ln -s "$T/dangle-target/skills" "$H2/dangle"
run "$H2" "$H2" "$TARBALL" "$PINNED" --skill-dir '~/dangle'
check "a --skill-dir through a dangling symlink is refused" test "$RC" = 1
check "the dangling-symlink refusal names the rule" err_has "leads outside $H2 through a symlink"
check "the dangling-symlink refusal changes nothing" untouched "$H2"
check "the dangling-symlink refusal creates no folder there" test ! -e "$T/dangle-target"
mkdir -p "$H/dotfiles/skills"
ln -s "$H/dotfiles/skills" "$H/inlink"
run "$H" "$H" "$TARBALL" "$PINNED" --skill-dir '~/inlink'
check "a --skill-dir that links to a folder inside HOME installs" test "$RC" = 0
check "the skill copy behind an inside-HOME link is there" test -f "$H/dotfiles/skills/imessage/SKILL.md"

# A long HOME uses the fallback socket folder, which uninstall removes. A 60-byte HOME makes the primary path 115
# bytes and the fallback 88.
L="$T/$(printf 'l%.0s' $(seq 1 $((60 - ${#T} - 1))))"
check "the long HOME is 60 bytes" test "${#L}" = 60
mkdir -p "$L"
run "$L" "$L" "$TARBALL" "$PINNED"
check "a long-HOME install exits 0" test "$RC" = 0
check "a long HOME gets the fallback socket path" \
    plist_is "$L/Library/LaunchAgents/$LABEL.plist" Sockets.Listener.SockPathName "$L/.imessage-agent/bridge.sock"
check "the fallback socket folder is 0700" mode_is "$L/.imessage-agent" 700
check "the manifest lists the fallback folder" \
    grep -q -x -F "$L/.imessage-agent" "$L/Library/Application Support/$APP_NAME/install-manifest.txt"
run "$L" "$L" "$TARBALL" "$L/Library/Application Support/$APP_NAME/install.sh" --uninstall
check "the long-HOME uninstall exits 0" test "$RC" = 0
check "the long-HOME uninstall removed the fallback folder" test ! -e "$L/.imessage-agent"

# The real build, when asked.
if (( BUILT )); then
    OUT_DIR="$ROOT/out"
    BUILT_VERSION="$(sed -n 's/^PINNED_VERSION="\(.*\)"$/\1/p' "$OUT_DIR/install.sh" 2>/dev/null)"
    BUILT_TARBALL="$OUT_DIR/imessage-agent-$BUILT_VERSION.tar.gz"
    if [[ -z "$BUILT_VERSION" || ! -f "$BUILT_TARBALL" ]]; then
        fail "--built needs out/install.sh and its tarball from scripts/build.sh"
    else
        check "SHA256SUMS matches the built files" bash -c 'cd "$1" && shasum -a 256 -c SHA256SUMS >/dev/null' _ "$OUT_DIR"
        H="$(new_home built)"
        run "$H" "$H" "$BUILT_TARBALL" "$OUT_DIR/install.sh" --skill-dir '~/.agents/skills'
        check "the built release installs" test "$RC" = 0
        check "the installed app's signature verifies" \
            codesign --verify --strict --deep "$H/Applications/$APP_NAME.app"
        check "the installed CLI's signature verifies" codesign --verify --strict "$H/.local/bin/imessage"
        check "the installed CLI is universal" bash -c '[[ "$(lipo -archs "$1")" == *arm64* && "$(lipo -archs "$1")" == *x86_64* ]]' _ "$H/.local/bin/imessage"
        run "$H" "$H" "$BUILT_TARBALL" "$H/Library/Application Support/$APP_NAME/install.sh" --uninstall
        check "the built release uninstalls" test "$RC" = 0
        check "nothing of the built release is left" bash -c '[[ ! -e "$1/Applications/iMessage Agent.app" && ! -e "$1/.local/bin/imessage" && ! -e "$1/Library/LaunchAgents/io.github.krishhgg.imessage-agent.plist" && ! -e "$1/Library/Application Support/iMessage Agent" && ! -e "$1/.agents/skills/imessage" ]]' _ "$H"
    fi
fi

check "no launchctl, security or tccutil call reached PATH" test ! -e "$T/system-calls"
[[ -e "$T/system-calls" ]] && sed 's/^/      /' "$T/system-calls"
echo "install tests: $PASSED passed, $FAILED failed"
((FAILED == 0))
