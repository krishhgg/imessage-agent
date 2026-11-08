#!/bin/bash
# Installs or removes imessage-agent for the current user (DESIGN.md "Install flow for Grok Bot",
# docs/BUILD-PLAN.md install.sh).
#
# Usage:
#   install.sh [--skill-dir DIR]...   install the bridge app, the CLI and the LaunchAgent, and copy the skill
#                                     into DIR/imessage (for example ~/.agents/skills or ~/.claude/skills)
#   install.sh --uninstall            remove everything the install manifest lists and the bridge's data
#
# It never sends Apple Events and uses no git, Homebrew, Xcode or Python. Its only network action is fetching the
# release tarball for the pinned version.
#
# Pinning: scripts/build.sh fills PINNED_VERSION and PINNED_TARBALL_SHA256 in the install.sh it publishes next to
# the tarball. This file in the repo, and the copy inside the tarball, keep both empty because the tarball can't
# pin its own hash. The copy inside the tarball is kept in the app-support folder and is there for --uninstall.
#
# Test hooks, for a dry run under a fake HOME:
#   IMESSAGE_AGENT_TARBALL=PATH  read the tarball from PATH instead of downloading it. The pin still applies.
#   IMESSAGE_AGENT_NO_SYSTEM=1   print the launchctl, lsregister and Keychain commands instead of running them.
set -euo pipefail

PINNED_VERSION=""
PINNED_TARBALL_SHA256=""

REPO_URL="https://github.com/krishhgg/imessage-agent"
LABEL="io.github.krishhgg.imessage-agent"
BUNDLE_ID="io.github.krishhgg.imessage-agent"
APP_NAME="iMessage Agent"
KEYCHAIN_SERVICE="io.github.krishhgg.imessage-agent.policy"
KEYCHAIN_ACCOUNT="allowlist-hash"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
MAX_SOCKET_PATH_BYTES=104

die() { echo "error: $*" >&2; exit 1; }
say() { echo "$*"; }

[[ -n "${HOME:-}" && "$HOME" == /* && -d "$HOME" ]] || die "HOME must be an existing absolute path"
HOME="${HOME%/}"
HOME_REAL="$(cd "$HOME" && pwd -P)" || die "can't read HOME"

APP="$HOME/Applications/$APP_NAME.app"
CLI="$HOME/.local/bin/imessage"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
APP_SUPPORT="$HOME/Library/Application Support/$APP_NAME"
MANIFEST="$APP_SUPPORT/install-manifest.txt"
INSTALLED_SCRIPT="$APP_SUPPORT/install.sh"
CACHE_DIR="$HOME/Library/Caches/$BUNDLE_ID"
STAGING_DIR="$HOME/Pictures/$APP_NAME"
FALLBACK_SOCKET_DIR="$HOME/.imessage-agent"
SERVICE_TARGET="gui/$(id -u)/$LABEL"

# Runs a command that changes launchd, Launch Services or the Keychain, or only prints it in a dry run.
# With -q the command's own output is dropped, but a dry run still prints the note.
system() {
    local quiet=0
    if [[ "${1:-}" == -q ]]; then quiet=1; shift; fi
    if [[ "${IMESSAGE_AGENT_NO_SYSTEM:-}" == 1 ]]; then
        say "dry run, skipped: $*"
        return 0
    fi
    if (( quiet )); then "$@" >/dev/null 2>&1; else "$@"; fi
}

usage() { sed -n '5,9p' "$0" | sed 's/^# \{0,1\}//'; }

# Same rule as Paths.resolvedSocketPath() in Sources/IMCore/Paths.swift: the primary path if it fits in sun_path
# with its terminating NUL, else the fallback, else an error.
resolve_socket_path() {
    local primary="$APP_SUPPORT/bridge.sock" fallback="$FALLBACK_SOCKET_DIR/bridge.sock" bytes
    bytes="$(printf '%s' "$primary" | LC_ALL=C wc -c | tr -d ' ')"
    if (( bytes + 1 <= MAX_SOCKET_PATH_BYTES )); then echo "$primary"; return; fi
    bytes="$(printf '%s' "$fallback" | LC_ALL=C wc -c | tr -d ' ')"
    if (( bytes + 1 <= MAX_SOCKET_PATH_BYTES )); then echo "$fallback"; return; fi
    die "the socket path $primary is too long for a Unix socket"
}

# Turns ~/x and relative paths into absolute ones, without following symlinks.
absolute_dir() {
    local d="$1"
    # shellcheck disable=SC2088  # the patterns match a literal ~ the shell didn't expand
    case "$d" in
        "~") d="$HOME" ;;
        "~/"*) d="$HOME/${d#"~/"}" ;;
        /*) ;;
        *) d="$PWD/$d" ;;
    esac
    while [[ "$d" == */ && "$d" != / ]]; do d="${d%/}"; done
    echo "$d"
}

# True when the path is HOME or inside it and has no `..` part. --uninstall removes skill copies only under HOME.
inside_home() {
    case "/$1/" in */../*) return 1 ;; esac
    case "$1" in "$HOME"|"$HOME"/*) return 0 ;; *) return 1 ;; esac
}

# True when the deepest folder of the path that exists, with symlinks followed, is HOME or inside it. Skill folders
# get this check as well as inside_home, so a skills folder that links out of HOME is never written or removed.
resolves_inside_home() {
    local d="$1" real
    # A symlink that leads nowhere could point out of HOME once its target exists, so it counts as outside.
    while [[ ! -d "$d" ]]; do [[ -L "$d" ]] && return 1; d="$(dirname "$d")"; done
    real="$(cd "$d" && pwd -P)" || return 1
    case "$real" in "$HOME_REAL"|"$HOME_REAL"/*) return 0 ;; *) return 1 ;; esac
}

manifest_lines() { [[ -f "$MANIFEST" ]] && grep -v '^[[:space:]]*$' "$MANIFEST" || true; }
in_manifest() { [[ -f "$MANIFEST" ]] && grep -q -x -F -- "$1" "$MANIFEST"; }
# Adds paths to the manifest, each once.
add_to_manifest() {
    { manifest_lines; printf '%s\n' "$@"; } | awk '!seen[$0]++' > "$MANIFEST.tmp"
    mv "$MANIFEST.tmp" "$MANIFEST"
    chmod 600 "$MANIFEST"
}

# A skill copy is a folder named imessage that holds SKILL.md.
is_skill_copy() { [[ "$(basename "$1")" == imessage && -f "$1/SKILL.md" ]]; }

# Removes one path from the manifest, but only if it is one of the shapes this script creates, under HOME.
safe_remove() {
    local p="$1"
    if [[ "$p" == "$HOME" ]] || ! inside_home "$p"; then
        say "left in place (outside HOME): $p"
        return
    fi
    case "$p" in
        "$APP"|"$CLI"|"$PLIST"|"$INSTALLED_SCRIPT"|"$FALLBACK_SOCKET_DIR") ;;
        *)
            if ! is_skill_copy "$p"; then
                if [[ -e "$p" ]]; then say "left in place (not a path this script creates): $p"; fi
                return 0
            fi
            if ! resolves_inside_home "$(dirname "$p")"; then
                say "left in place (outside HOME through a symlink): $p"
                return 0
            fi
            ;;
    esac
    if [[ -e "$p" || -L "$p" ]]; then
        rm -rf "$p"
        say "removed $p"
    fi
}

do_uninstall() {
    system launchctl bootout "$SERVICE_TARGET" 2>/dev/null || true
    local p
    while IFS= read -r p; do safe_remove "$p"; done < <({ manifest_lines; printf '%s\n' "$APP" "$CLI" "$PLIST"; } | awk '!seen[$0]++')
    # -q keeps the item's attributes off the screen. Exit 44 means there was no item. Any other failure, such as a
    # refused Keychain prompt, is reported, because a hash left behind makes a reinstall distrust its allowlist.
    local keychain_left=0 rc
    if system -q security delete-generic-password -s "$KEYCHAIN_SERVICE" -a "$KEYCHAIN_ACCOUNT"; then
        [[ "${IMESSAGE_AGENT_NO_SYSTEM:-}" == 1 ]] || say "removed Keychain item $KEYCHAIN_SERVICE"
    else
        rc=$?
        if (( rc != 44 )); then
            keychain_left=1
            echo "error: couldn't delete Keychain item $KEYCHAIN_SERVICE (security exit $rc) fix: security delete-generic-password -s $KEYCHAIN_SERVICE -a $KEYCHAIN_ACCOUNT" >&2
        fi
    fi
    for p in "$APP_SUPPORT" "$CACHE_DIR" "$STAGING_DIR" "$FALLBACK_SOCKET_DIR"; do
        if [[ -e "$p" ]]; then rm -rf "$p"; say "removed $p"; fi
    done
    say ""
    if (( keychain_left )); then
        say "iMessage Agent is removed except its Keychain item. Run the fix command above and allow it if macOS asks. To clear its permissions too, run:"
    else
        say "iMessage Agent is removed. To clear its permissions too, run:"
    fi
    say "  tccutil reset SystemPolicyAllFiles $BUNDLE_ID"
    say "  tccutil reset AppleEvents $BUNDLE_ID"
    say "  tccutil reset Accessibility $BUNDLE_ID"
    if (( keychain_left )); then exit 1; fi
}

# A --skill-dir must be inside HOME, so --uninstall can remove the copy, and one line long, because the manifest
# holds one path per line.
check_skill_dir() {
    local arg="$1" dir="$2"
    [[ "$dir" != *$'\n'* ]] || die "--skill-dir has a newline in it. Nothing was installed"
    inside_home "$dir" \
        || die "--skill-dir $arg is outside $HOME or has a .. part. Nothing was installed fix: pass a folder inside $HOME, such as ~/.agents/skills"
    resolves_inside_home "$dir" \
        || die "--skill-dir $arg leads outside $HOME through a symlink. Nothing was installed fix: pass a folder inside $HOME, such as ~/.agents/skills"
}

# A skill folder this script didn't create is never replaced.
check_skill_dest() {
    local dest="$1/imessage"
    if [[ -e "$dest" || -L "$dest" ]] && ! in_manifest "$dest"; then
        die "$dest already exists and this script didn't create it. Nothing was installed fix: remove it or pick another --skill-dir"
    fi
}

install_skill() {
    local src="$1" dir="$2" dest="$2/imessage"
    mkdir -p "$dir"
    rm -rf "$dest"
    cp -R "$src" "$dest"
    say "skill copied to $dest"
}

do_install() {
    local skill_dirs=("$@")
    [[ "$(uname -s)" == Darwin ]] || die "this needs macOS"
    local major
    major="$(sw_vers -productVersion | cut -d. -f1)"
    (( major >= 14 )) || die "this needs macOS 14 or later"
    if [[ -z "$PINNED_VERSION" || -z "$PINNED_TARBALL_SHA256" ]]; then
        die "this install.sh has no pinned release fix: download install.sh from $REPO_URL/releases and check it against INSTALL.md"
    fi

    WORK="$(mktemp -d "${TMPDIR:-/tmp}/imessage-agent.XXXXXX")"
    trap 'rm -rf "$WORK"' EXIT
    local work="$WORK"
    local name="imessage-agent-$PINNED_VERSION"
    local tarball="$work/$name.tar.gz"
    if [[ -n "${IMESSAGE_AGENT_TARBALL:-}" ]]; then
        cp "$IMESSAGE_AGENT_TARBALL" "$tarball"
    else
        /usr/bin/curl -fsSL --proto '=https' --tlsv1.2 -o "$tarball" \
            "$REPO_URL/releases/download/v$PINNED_VERSION/$name.tar.gz" \
            || die "could not download $name.tar.gz"
    fi
    local actual
    actual="$(/usr/bin/shasum -a 256 "$tarball" | awk '{print $1}')"
    [[ "$actual" == "$PINNED_TARBALL_SHA256" ]] \
        || die "tarball SHA-256 is $actual, expected $PINNED_TARBALL_SHA256. Nothing was installed"
    say "tarball SHA-256 matches the pin"

    tar -xzf "$tarball" -C "$work"
    local src="$work/$name"
    local f
    for f in "$APP_NAME.app/Contents/MacOS/IMessageAgent" imessage "$LABEL.plist" skill/imessage/SKILL.md install.sh; do
        [[ -e "$src/$f" ]] || die "the tarball has no $f. Nothing was installed"
    done

    local sock
    sock="$(resolve_socket_path)"

    # Skill copies from an earlier install are refreshed, so they match the new CLI. Every target is checked
    # before anything changes.
    local d dirs=() skill_targets=()
    while IFS= read -r d; do
        if is_skill_copy "$d" && inside_home "$d" && resolves_inside_home "$(dirname "$d")"; then
            dirs+=("$(dirname "$d")")
        fi
    done < <(manifest_lines)
    local arg
    for arg in ${skill_dirs[@]+"${skill_dirs[@]}"}; do
        d="$(absolute_dir "$arg")"
        check_skill_dir "$arg" "$d"
        dirs+=("$d")
    done
    while IFS= read -r d; do
        [[ -n "$d" ]] || continue
        check_skill_dest "$d"
        skill_targets+=("$d")
    done < <(printf '%s\n' ${dirs[@]+"${dirs[@]}"} | awk 'NF && !seen[$0]++')

    # The old job stops before its bundle is replaced.
    system launchctl bootout "$SERVICE_TARGET" 2>/dev/null || true

    mkdir -p "$HOME/Applications" "$HOME/.local/bin" "$HOME/Library/LaunchAgents" "$APP_SUPPORT"
    chmod 700 "$APP_SUPPORT"
    local created=()

    rm -rf "$APP"
    ditto "$src/$APP_NAME.app" "$APP"
    created+=("$APP")
    say "installed $APP"

    /usr/bin/install -m 0755 "$src/imessage" "$CLI"
    created+=("$CLI")
    say "installed $CLI"

    if [[ "$sock" == "$FALLBACK_SOCKET_DIR/"* ]]; then
        mkdir -p "$FALLBACK_SOCKET_DIR"
        chmod 700 "$FALLBACK_SOCKET_DIR"
        created+=("$FALLBACK_SOCKET_DIR")
    fi

    local plist_tmp="$work/$LABEL.plist"
    cp "$src/$LABEL.plist" "$plist_tmp"
    plutil -replace Program -string "$APP/Contents/MacOS/IMessageAgent" "$plist_tmp"
    plutil -replace Sockets.Listener.SockPathName -string "$sock" "$plist_tmp"
    plutil -replace StandardErrorPath -string "$APP_SUPPORT/bridge.log" "$plist_tmp"
    plutil -lint "$plist_tmp" >/dev/null
    /usr/bin/install -m 0644 "$plist_tmp" "$PLIST"
    created+=("$PLIST")
    say "installed $PLIST (socket $sock)"

    /usr/bin/install -m 0755 "$src/install.sh" "$INSTALLED_SCRIPT"
    created+=("$INSTALLED_SCRIPT")

    add_to_manifest "${created[@]}"
    # Each skill copy goes into the manifest as soon as it is made, so a later copy that fails doesn't leave it
    # unlisted, where a retry would refuse it and --uninstall would miss it.
    for d in ${skill_targets[@]+"${skill_targets[@]}"}; do
        install_skill "$src/skill/imessage" "$d"
        add_to_manifest "$d/imessage"
    done
    say "wrote $MANIFEST"

    system "$LSREGISTER" -f "$APP"
    # launchd can refuse a bootstrap for a moment after the bootout above, so it gets three tries.
    local tries=1
    until system launchctl bootstrap "gui/$(id -u)" "$PLIST"; do
        (( tries < 3 )) || die "launchctl could not load $PLIST fix: log out and back in, which loads it, then run $CLI doctor"
        tries=$((tries + 1))
        sleep 1
    done

    say ""
    say "iMessage Agent $PINNED_VERSION is installed. Next: $CLI setup"
}

UNINSTALL=0
SKILL_DIRS=()
while (( $# > 0 )); do
    case "$1" in
        --uninstall) UNINSTALL=1; shift ;;
        --skill-dir)
            (( $# >= 2 )) && [[ -n "$2" ]] || die "--skill-dir needs a folder"
            SKILL_DIRS+=("$2"); shift 2 ;;
        --skill-dir=*) SKILL_DIRS+=("${1#--skill-dir=}"); shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown argument $1" ;;
    esac
done

if (( UNINSTALL )); then
    (( ${#SKILL_DIRS[@]} == 0 )) || die "--uninstall takes no other arguments"
    do_uninstall
else
    do_install ${SKILL_DIRS[@]+"${SKILL_DIRS[@]}"}
fi
