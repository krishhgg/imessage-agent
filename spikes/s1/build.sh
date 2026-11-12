#!/bin/bash
# Builds, signs, installs and (re)loads the S1 spike bridge.
# Usage: build.sh [build-tag]   e.g. build.sh S1-BUILD-2
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TAG="${1:-S1-BUILD-1}"
NAME="iMessage Agent Spike"
EXE="imessage-agent-spike"
BID="local.imessageagent.spike"
LABEL="$BID"
APP="$HOME/Applications/$NAME.app"
SOCKDIR="$HOME/Library/Application Support/iMessageAgentSpike"
SOCK="$SOCKDIR/bridge.sock"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
KC="${SIGN_KEYCHAIN:-$HERE/signing/spike-signing.keychain-db}"
IDENTITY="${SIGN_IDENTITY:?set SIGN_IDENTITY to your signing certificate SHA-1}"
PW_FILE="${SIGN_KEYCHAIN_PW_FILE:-$HERE/signing/keychain.pw}"
OUT="$HERE/out"

rm -rf "$OUT"; mkdir -p "$OUT/$NAME.app/Contents/MacOS"
sed "s/^let buildTag = .*/let buildTag = \"$TAG\"/" "$HERE/Bridge.swift" > "$OUT/Bridge.swift"
swiftc -O -target arm64-apple-macos14 -o "$OUT/$NAME.app/Contents/MacOS/$EXE" "$OUT/Bridge.swift"

cat > "$OUT/$NAME.app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$BID</string>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>$EXE</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.0.1</string>
  <key>CFBundleVersion</key><string>$TAG</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>LSMultipleInstancesProhibited</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Sends iMessages you approve and reads Messages state for your agent.</string>
  <key>NSAccessibilityUsageDescription</key><string>Performs tapbacks, replies, edits and unsends you approve in Messages.</string>
</dict></plist>
EOF

cat > "$OUT/entitlements.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.automation.apple-events</key><true/>
</dict></plist>
EOF

# codesign only finds identities in the search list; add the spike keychain briefly.
ORIG=$(security list-keychains -d user | tr -d '"' | xargs)
restore() { security list-keychains -d user -s $ORIG; }
trap restore EXIT
printf 'unlock-keychain -p "%s" "%s"\n' "$(<"$PW_FILE")" "$KC" | security -i >/dev/null
security list-keychains -d user -s $ORIG "$KC"
codesign -f -s "$IDENTITY" -o runtime --timestamp=none \
  --entitlements "$OUT/entitlements.plist" "$OUT/$NAME.app"
restore; trap - EXIT
codesign --verify --strict --deep "$OUT/$NAME.app"

# Install: stop the job, swap the bundle, reload.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
mkdir -p "$HOME/Applications" "$(dirname "$PLIST")" "$SOCKDIR"; chmod 700 "$SOCKDIR"
rm -rf "$APP"; ditto "$OUT/$NAME.app" "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>Program</key><string>$APP/Contents/MacOS/$EXE</string>
  <key>AssociatedBundleIdentifiers</key><array><string>$BID</string></array>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>ProcessType</key><string>Interactive</string>
  <key>Sockets</key><dict>
    <key>Listener</key><dict>
      <key>SockPathName</key><string>$SOCK</string>
      <key>SockPathMode</key><integer>384</integer>
    </dict>
  </dict>
  <key>StandardErrorPath</key><string>$SOCKDIR/stderr.log</string>
</dict></plist>
EOF
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "installed $TAG"
codesign -d -r- "$APP" 2>&1 | tail -1
