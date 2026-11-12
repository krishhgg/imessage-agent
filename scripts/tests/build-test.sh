#!/bin/bash
# Tests for the keychain unlock in scripts/build.sh, against a stub `security` on PATH. Every case stops at the
# identity check, before swift build, so nothing is built or signed and no real keychain is opened.
#
# Usage: scripts/tests/build-test.sh   (TOKEN_PYTHON as for check-skill-tokens.sh, which build.sh runs first)
#
# The stub records each call's arguments, and the stdin of `security -i`, to files in a temporary folder.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/imessage-build-test.XXXXXX")"
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
not() { ! "$@"; }

# STUB_UNLOCK_RC and STUB_INFO_RC set the exit codes of `security -i` and show-keychain-info. find-identity
# prints nothing, so build.sh stops with "is not in".
STUBS="$T/stubs"
mkdir -p "$STUBS"
cat >"$STUBS/security" <<EOF
#!/bin/bash
printf '%s\n' "security \$*" >>"$T/argv"
case "\${1:-}" in
    -i) cat >>"$T/stdin"; exit "\${STUB_UNLOCK_RC:-0}" ;;
    show-keychain-info) exit "\${STUB_INFO_RC:-0}" ;;
esac
exit 0
EOF
chmod 755 "$STUBS/security"
if [[ "$(env PATH="$STUBS:/usr/bin:/bin:/usr/sbin:/sbin" /bin/bash -c 'command -v security')" != "$STUBS/security" ]]; then
    echo "error: PATH doesn't find the stub security first, so the tests can't run safely" >&2
    exit 2
fi

# A keychain path and a password with a space, a double quote, a backslash and a $, which `security -i` must get
# back exactly.
KC_DIR="$T/kc dir"
mkdir -p "$KC_DIR"
KC="$KC_DIR/sign\"ing\\x.keychain-db"
: >"$KC"
PW_FILE="$T/pw"
PW='pa"ss\word $HOME x'
printf '%s\n' "$PW" >"$PW_FILE"

# build <password file> [env...]: runs build.sh with the stub first on PATH.
build() {
    local pw_file="$1"
    shift
    rm -f "$T/argv" "$T/stdin"
    env PATH="$STUBS:/usr/bin:/bin:/usr/sbin:/sbin" SIGN_IDENTITY=0000000000000000000000000000000000000000 \
        SIGN_KEYCHAIN="$KC" SIGN_KEYCHAIN_PW_FILE="$pw_file" "$@" \
        /bin/bash "$ROOT/scripts/build.sh" >"$T/out" 2>&1
    RC=$?
}
out_has() { grep -q -F -- "$1" "$T/out"; }
argv_has() { grep -q -x -F -- "$1" "$T/argv" 2>/dev/null; }
no_password_in_argv() { ! grep -q -F -- 'pa"ss' "$T/argv"; }
last_call_is() { [[ "$(tail -n 1 "$T/argv" 2>/dev/null)" == "$1" ]]; }

build "$PW_FILE"
check "a build with a stubbed keychain stops at the identity check" out_has "is not in $KC; nothing was built"
check "the build exits 1" test "$RC" = 1
check "the unlock reads its command from stdin" argv_has "security -i"
check "security -i gets the password and path with quotes and backslashes escaped" \
    test "$(cat "$T/stdin" 2>/dev/null)" = 'unlock-keychain -p "pa\"ss\\word $HOME x" "'"$KC_DIR"'/sign\"ing\\x.keychain-db"'
check "no security call has the password in its arguments" no_password_in_argv
check "the password never reaches the output" not grep -q -F 'pa"ss' "$T/out"
check "show-keychain-info confirms the unlock" argv_has "security show-keychain-info $KC"
check "the keychain is locked again on exit" last_call_is "security lock-keychain $KC"

build "$PW_FILE" STUB_UNLOCK_RC=51
check "a failed unlock stops the build" out_has "could not unlock $KC; nothing was built"
check "a failed unlock still locks the keychain on exit" last_call_is "security lock-keychain $KC"
check "a failed unlock skips show-keychain-info" not argv_has "security show-keychain-info $KC"

build "$PW_FILE" STUB_INFO_RC=36
check "a keychain that stays locked stops the build" out_has "$KC is still locked; nothing was built"
check "a keychain that stays locked is locked again on exit" last_call_is "security lock-keychain $KC"

printf 'pass\tword\n' >"$T/pw-tab"
build "$T/pw-tab"
check "a password with a control character is refused" out_has "has a control character, which security -i can't read"
check "a refused password never reaches security" test ! -e "$T/stdin"

echo "build tests: $PASSED passed, $FAILED failed"
((FAILED == 0))
