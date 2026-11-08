#!/bin/bash
# Builds, signs and packages imessage-agent (docs/BUILD-PLAN.md, Packaging; DESIGN.md section 1, Signing).
#
# Usage: scripts/build.sh [--release-tests]
#
# Required environment. Without all three, or without the identity in that keychain, nothing is built:
#   SIGN_IDENTITY          SHA-1 hash of the code-signing identity
#   SIGN_KEYCHAIN          keychain file that holds the identity
#   SIGN_KEYCHAIN_PW_FILE  file that holds the keychain password
# Optional:
#   SCRATCH_PATH           SwiftPM scratch path. Defaults to .build-release, or .build-release-tests with
#                          --release-tests, so the two builds never share compiled objects.
#   TOKEN_PYTHON           Python with tiktoken, passed to scripts/check-skill-tokens.sh.
#
# A normal build writes to out/:
#   iMessage Agent.app, imessage, imessage-agent-<version>.tar.gz, install.sh and SHA256SUMS,
#   and pins the release tag and the install.sh SHA-256 in INSTALL.md.
#
# --release-tests compiles with -DIMESSAGE_RELEASE_TESTS (docs/BUILD-PLAN.md, item 10) and writes only
# out/release-tests/iMessage Agent.app and out/release-tests/imessage. It signs them with the same identity and
# identifiers so grants carry over. That build never goes into the tarball, SHA256SUMS or INSTALL.md.
#
# The pin cycle: the tarball holds install.sh, and install.sh pins the tarball's SHA-256, so one file can't hold
# both. The repo's install.sh keeps an empty pin. That copy goes into the tarball, and the installed copy in the
# app-support folder serves `install.sh --uninstall`. Once the tarball exists, this script writes out/install.sh,
# the same script with the version and the tarball SHA-256 filled in. That standalone file is the release asset
# users download, and INSTALL.md pins its SHA-256. INSTALL.md isn't in the tarball, so the chain ends there.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BUNDLE_ID="io.github.krishhgg.imessage-agent"
CLI_ID="io.github.krishhgg.imessage-agent.cli"
APP_NAME="iMessage Agent"
EXECUTABLE="IMessageAgent"
LABEL="io.github.krishhgg.imessage-agent"

RELEASE_TESTS=0
for arg in "$@"; do
    case "$arg" in
        --release-tests) RELEASE_TESTS=1 ;;
        -h|--help) sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "error: unknown argument $arg fix: scripts/build.sh [--release-tests]" >&2; exit 2 ;;
    esac
done

die() { echo "error: $*" >&2; exit 1; }
step() { echo "==> $*"; }

# Signing inputs come first, so a missing identity stops the script before anything is built.
for var in SIGN_IDENTITY SIGN_KEYCHAIN SIGN_KEYCHAIN_PW_FILE; do
    [[ -n "${!var:-}" ]] || die "$var is not set; nothing was built fix: set SIGN_IDENTITY, SIGN_KEYCHAIN and SIGN_KEYCHAIN_PW_FILE"
done
[[ -f "$SIGN_KEYCHAIN" ]] || die "SIGN_KEYCHAIN $SIGN_KEYCHAIN does not exist; nothing was built"
[[ -f "$SIGN_KEYCHAIN_PW_FILE" ]] || die "SIGN_KEYCHAIN_PW_FILE $SIGN_KEYCHAIN_PW_FILE does not exist; nothing was built"

VERSION="$(sed -n 's/^ *public static let version = "\([^"]*\)".*/\1/p' Sources/IMCore/Identity.swift)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "could not read AppIdentity.version from Sources/IMCore/Identity.swift"

if [[ $RELEASE_TESTS -eq 1 ]]; then
    OUT="$ROOT/out/release-tests"
    SCRATCH="${SCRATCH_PATH:-.build-release-tests}"
    SWIFT_FLAGS=(-Xswiftc -DIMESSAGE_RELEASE_TESTS)
else
    OUT="$ROOT/out"
    SCRATCH="${SCRATCH_PATH:-.build-release}"
    SWIFT_FLAGS=()
fi
[[ "$SCRATCH" == /* ]] || SCRATCH="$ROOT/$SCRATCH"
APP="$OUT/$APP_NAME.app"
CLI="$OUT/imessage"

step "checking skill token caps"
scripts/check-skill-tokens.sh

# A release-evidence.json the bridge can't read would turn every gated capability off without an error.
if [[ -f packaging/release-evidence.json ]]; then
    step "checking packaging/release-evidence.json"
    scripts/check-evidence.sh packaging/release-evidence.json
fi

# The keychain is unlocked from the password file and checked for the identity before the build starts. The
# password reaches `security -i` on stdin from bash builtins, so no process has it in its arguments, and it is
# never echoed. `security -i` reads backslash escapes inside double quotes, so backslashes and double quotes are
# escaped, and a control character, which could end the command line early, is refused. show-keychain-info then
# confirms the unlock. The EXIT trap locks the keychain again and puts back the search list changed for signing.
step "checking the signing identity"
KEYCHAIN_LIST_CHANGED=0
on_exit() {
    local rc=$?
    if ((KEYCHAIN_LIST_CHANGED)); then
        restore_keychains || echo "warning: could not restore the keychain search list" >&2
    fi
    security lock-keychain "$SIGN_KEYCHAIN" || echo "warning: could not lock $SIGN_KEYCHAIN" >&2
    exit "$rc"
}
[[ "$SIGN_KEYCHAIN" != *[[:cntrl:]]* ]] || die "SIGN_KEYCHAIN has a control character; nothing was built"
pw="$(<"$SIGN_KEYCHAIN_PW_FILE")"
if [[ "$pw" == *[[:cntrl:]]* ]]; then
    unset pw
    die "the password in SIGN_KEYCHAIN_PW_FILE has a control character, which security -i can't read; nothing was built"
fi
pw="${pw//\\/\\\\}"
pw="${pw//\"/\\\"}"
kc="${SIGN_KEYCHAIN//\\/\\\\}"
kc="${kc//\"/\\\"}"
trap on_exit EXIT
if ! printf 'unlock-keychain -p "%s" "%s"\n' "$pw" "$kc" | security -i >/dev/null; then
    unset pw
    die "could not unlock $SIGN_KEYCHAIN; nothing was built"
fi
unset pw kc
security show-keychain-info "$SIGN_KEYCHAIN" >/dev/null 2>&1 || die "$SIGN_KEYCHAIN is still locked; nothing was built"
IDENTITIES="$(security find-identity -p codesigning "$SIGN_KEYCHAIN")"
grep -q -F "$SIGN_IDENTITY" <<<"$IDENTITIES" || die "identity $SIGN_IDENTITY is not in $SIGN_KEYCHAIN; nothing was built"

# Builds one product for arm64 and x86_64 and prints the path of the universal binary. One swift build call with
# both arches is the normal path. If the toolchain can't do that, each arch gets its own scratch path and lipo
# joins them.
build_universal() {
    local product="$1" bin
    if swift build -c release --arch arm64 --arch x86_64 --scratch-path "$SCRATCH" ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"} \
        --product "$product" >&2; then
        bin="$(swift build -c release --arch arm64 --arch x86_64 --scratch-path "$SCRATCH" --show-bin-path)/$product"
        [[ -f "$bin" ]] || die "swift build reported success but $bin is missing"
        echo "$bin"
        return
    fi
    echo "note: a two-arch swift build failed, building each arch on its own" >&2
    local parts=() arch
    for arch in arm64 x86_64; do
        swift build -c release --arch "$arch" --scratch-path "$SCRATCH-$arch" ${SWIFT_FLAGS[@]+"${SWIFT_FLAGS[@]}"} \
            --product "$product" >&2 || die "swift build failed for $product on $arch"
        parts+=("$(swift build -c release --arch "$arch" --scratch-path "$SCRATCH-$arch" --show-bin-path)/$product")
    done
    mkdir -p "$SCRATCH/universal"
    lipo -create "${parts[@]}" -output "$SCRATCH/universal/$product"
    echo "$SCRATCH/universal/$product"
}

check_archs() {
    local archs
    archs="$(lipo -archs "$1")"
    [[ " $archs " == *" arm64 "* && " $archs " == *" x86_64 "* ]] || die "$1 has archs '$archs', need arm64 and x86_64"
    echo "    $(basename "$1"): $archs"
}

step "building $EXECUTABLE and imessage $VERSION (release, arm64 and x86_64)${SWIFT_FLAGS[*]+ with ${SWIFT_FLAGS[*]}}"
AGENT_BIN="$(build_universal IMessageAgent)"
CLI_BIN="$(build_universal imessage)"
check_archs "$AGENT_BIN"
check_archs "$CLI_BIN"

step "assembling $APP"
rm -rf "$APP" "$CLI"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$AGENT_BIN" "$APP/Contents/MacOS/$EXECUTABLE"
cp packaging/Info.plist "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$VERSION" "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
# Release evidence (docs/BUILD-PLAN.md, Release-test harness). scripts/release-tests/run.sh appends passing records
# to packaging/release-evidence.json. With no file yet, the bundle gets an empty list and every gated capability
# stays untested. The file was checked at the start.
if [[ -f packaging/release-evidence.json ]]; then
    cp packaging/release-evidence.json "$APP/Contents/Resources/release-evidence.json"
else
    printf '[]\n' > "$APP/Contents/Resources/release-evidence.json"
fi
cp "$CLI_BIN" "$CLI"
chmod 755 "$APP/Contents/MacOS/$EXECUTABLE" "$CLI"

# codesign finds identities only through the user keychain search list, so the signing keychain joins it for the
# signing step. The EXIT trap puts the earlier list back if the script stops before that.
ORIGINAL_KEYCHAINS=()
while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line#\"}"
    line="${line%\"}"
    [[ -n "$line" ]] && ORIGINAL_KEYCHAINS+=("$line")
done < <(security list-keychains -d user)
restore_keychains() {
    security list-keychains -d user -s ${ORIGINAL_KEYCHAINS[@]+"${ORIGINAL_KEYCHAINS[@]}"}
}
KEYCHAIN_LIST_CHANGED=1
security list-keychains -d user -s ${ORIGINAL_KEYCHAINS[@]+"${ORIGINAL_KEYCHAINS[@]}"} "$SIGN_KEYCHAIN"

step "signing"
codesign --force --options runtime --timestamp=none --keychain "$SIGN_KEYCHAIN" --sign "$SIGN_IDENTITY" \
    --entitlements packaging/entitlements.plist --identifier "$BUNDLE_ID" "$APP"
codesign --force --options runtime --timestamp=none --keychain "$SIGN_KEYCHAIN" --sign "$SIGN_IDENTITY" \
    --identifier "$CLI_ID" "$CLI"
restore_keychains
KEYCHAIN_LIST_CHANGED=0

step "verifying signatures"
codesign --verify --strict --deep --verbose=2 "$APP"
codesign --verify --strict --verbose=2 "$CLI"

# Identifier and hardened runtime, from the code directory.
check_code() {
    local path="$1" id="$2" info
    info="$(codesign -d --verbose=2 "$path" 2>&1)"
    grep -q -x "Identifier=$id" <<<"$info" || die "$path is not signed with identifier $id"
    grep -q -E '^CodeDirectory .*flags=0x[0-9a-f]+\([^)]*runtime' <<<"$info" || die "$path lacks the hardened runtime flag"
}
check_code "$APP" "$BUNDLE_ID"
check_code "$CLI" "$CLI_ID"

# Entitlements: the app has exactly com.apple.security.automation.apple-events, the CLI has none.
entitlement_keys() {
    codesign -d --entitlements - --xml "$1" 2>/dev/null | grep -o '<key>[^<]*</key>' | sed 's/<\/*key>//g' || true
}
echo "    app entitlements:"
codesign -d --entitlements - "$APP" 2>/dev/null | sed 's/^/      /'
APP_KEYS="$(entitlement_keys "$APP")"
[[ "$APP_KEYS" == "com.apple.security.automation.apple-events" ]] \
    || die "app entitlements must be only com.apple.security.automation.apple-events, got: ${APP_KEYS//$'\n'/ }"
CLI_KEYS="$(entitlement_keys "$CLI")"
[[ -z "$CLI_KEYS" ]] || die "the CLI must have no entitlements, got: ${CLI_KEYS//$'\n'/ }"

# The designated requirement must be the identifier plus the certificate root, never a cdhash, so grants survive
# re-signed builds (DESIGN.md section 1, S1).
check_requirement() {
    local path="$1" id="$2" dr
    dr="$(codesign -d -r- "$path" 2>&1 | sed -n 's/^designated => //p')"
    echo "    $(basename "$path") designated requirement: $dr"
    [[ -n "$dr" ]] || die "no designated requirement on $path"
    [[ "$dr" != *cdhash* ]] || die "the designated requirement of $path contains a cdhash"
    [[ "$dr" == *"identifier \"$id\""* ]] || die "the designated requirement of $path doesn't name $id"
    [[ "$dr" == *"certificate root"* ]] || die "the designated requirement of $path doesn't name the certificate root"
}
step "checking designated requirements"
check_requirement "$APP" "$BUNDLE_ID"
check_requirement "$CLI" "$CLI_ID"

if [[ $RELEASE_TESTS -eq 1 ]]; then
    step "release-test build ready (not packaged)"
    echo "    $APP"
    echo "    $CLI"
    exit 0
fi

PKG_NAME="imessage-agent-$VERSION"
TARBALL="$OUT/$PKG_NAME.tar.gz"
STAGE="$OUT/pkg"

step "packaging $TARBALL"
rm -rf "$STAGE" "$TARBALL" "$OUT/install.sh" "$OUT/SHA256SUMS"
mkdir -p "$STAGE/$PKG_NAME/skill"
ditto "$APP" "$STAGE/$PKG_NAME/$APP_NAME.app"
cp "$CLI" "$STAGE/$PKG_NAME/imessage"
cp "packaging/$LABEL.plist" "$STAGE/$PKG_NAME/$LABEL.plist"
cp -R skill/imessage "$STAGE/$PKG_NAME/skill/imessage"
cp install.sh "$STAGE/$PKG_NAME/install.sh"
chmod 755 "$STAGE/$PKG_NAME/install.sh"
codesign --verify --strict --deep "$STAGE/$PKG_NAME/$APP_NAME.app"
COPYFILE_DISABLE=1 tar --no-mac-metadata --no-xattrs --no-acls --no-fflags \
    --uid 0 --gid 0 --uname root --gname wheel -czf "$TARBALL" -C "$STAGE" "$PKG_NAME"
rm -rf "$STAGE"
TARBALL_SHA="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"

step "writing the standalone install.sh with the tarball pinned"
pin_line() {
    # Replaces the single line `<name>=""` in $3 with `<name>="<value>"`, and fails unless exactly one line matched.
    local name="$1" value="$2" file="$3"
    [[ "$(grep -c -x "$name=\"\"" "$file")" == 1 ]] || die "$file must have exactly one line $name=\"\""
    sed -i '' "s|^$name=\"\"\$|$name=\"$value\"|" "$file"
}
cp install.sh "$OUT/install.sh"
pin_line PINNED_VERSION "$VERSION" "$OUT/install.sh"
pin_line PINNED_TARBALL_SHA256 "$TARBALL_SHA" "$OUT/install.sh"
chmod 755 "$OUT/install.sh"
bash -n "$OUT/install.sh"
INSTALL_SHA="$(shasum -a 256 "$OUT/install.sh" | awk '{print $1}')"

(cd "$OUT" && shasum -a 256 "$PKG_NAME.tar.gz" install.sh > SHA256SUMS)

step "pinning INSTALL.md to v$VERSION"
pin_doc() {
    # Replaces the single line `<name>="…"` in INSTALL.md with the new value.
    local name="$1" value="$2"
    [[ "$(grep -c -E "^$name=\"[^\"]*\"\$" INSTALL.md)" == 1 ]] || die "INSTALL.md must have exactly one line $name=\"...\""
    sed -i '' -E "s|^$name=\"[^\"]*\"\$|$name=\"$value\"|" INSTALL.md
}
pin_doc TAG "v$VERSION"
pin_doc SHA256 "$INSTALL_SHA"

step "done"
echo "    $TARBALL"
echo "    $OUT/install.sh"
echo "    $OUT/SHA256SUMS"
sed 's/^/      /' "$OUT/SHA256SUMS"
echo "    INSTALL.md now pins v$VERSION and install.sh $INSTALL_SHA. Commit it with the tag, then upload the"
echo "    tarball, install.sh and SHA256SUMS from out/ as the release assets."
