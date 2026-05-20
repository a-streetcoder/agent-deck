#!/usr/bin/env bash
# Builds a signed, notarized, branded DMG for Agent Deck.
#
# Required env:
#   DEVELOPER_ID_APPLICATION  - signing identity, e.g. "Developer ID Application: Name (D37Z4S3883)"
#   NOTARY_PROFILE            - xcrun notarytool keychain profile name
#
# Optional env (defaults shown):
#   PROJECT=agent-deck.xcodeproj
#   SCHEME=agent-deck
#   CONFIGURATION=Release
#   BUILD_DIR=build/release
#   VERSION=<from MARKETING_VERSION in pbxproj>
#   APP_NAME="Agent Deck"
#   VOLUME_NAME="Agent Deck"
#
# Output: $BUILD_DIR/Agent-Deck-<VERSION>.dmg (path printed on stdout)
#
# Requires: create-dmg (brew install create-dmg).

set -euo pipefail

PROJECT="${PROJECT:-agent-deck.xcodeproj}"
SCHEME="${SCHEME:-agent-deck}"
CONFIGURATION="${CONFIGURATION:-Release}"
BUILD_DIR="${BUILD_DIR:-build/release}"
ARCHIVE_PATH="${ARCHIVE_PATH:-$BUILD_DIR/$SCHEME.xcarchive}"
EXPORT_PATH="${EXPORT_PATH:-$BUILD_DIR/export}"
APP_NAME="${APP_NAME:-Agent Deck}"
VOLUME_NAME="${VOLUME_NAME:-Agent Deck}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DMG_BG="$SCRIPT_DIR/dmg/background.png"

if [[ -z "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  echo "Set DEVELOPER_ID_APPLICATION to your Developer ID Application signing identity." >&2
  exit 2
fi

if [[ -z "${NOTARY_PROFILE:-}" ]]; then
  echo "Set NOTARY_PROFILE to an xcrun notarytool keychain profile." >&2
  exit 2
fi

if ! command -v create-dmg >/dev/null 2>&1; then
  echo "create-dmg is not installed. Install it with:  brew install create-dmg" >&2
  exit 2
fi

if [[ ! -f "$DMG_BG" ]]; then
  echo "Missing DMG background at $DMG_BG. Run:  swift scripts/dmg/generate-background.swift" >&2
  exit 2
fi

# Resolve version: explicit env > MARKETING_VERSION from the project.
if [[ -z "${VERSION:-}" ]]; then
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print' "$PROJECT/project.pbxproj" 2>/dev/null \
    | awk -F'= ' '/MARKETING_VERSION/ {gsub(/[";]/,"",$2); print $2; exit}')"
fi
if [[ -z "${VERSION:-}" ]]; then
  echo "Could not resolve VERSION. Set VERSION=x.y.z and rerun." >&2
  exit 2
fi

DMG_PATH="$BUILD_DIR/Agent-Deck-${VERSION}.dmg"

mkdir -p "$BUILD_DIR"
rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH" "$DMG_PATH"

xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -archivePath "$ARCHIVE_PATH" \
  CODE_SIGN_IDENTITY="$DEVELOPER_ID_APPLICATION" \
  ENABLE_HARDENED_RUNTIME=YES \
  OTHER_CODE_SIGN_FLAGS="--timestamp"

EXPORT_OPTIONS="$BUILD_DIR/ExportOptions.plist"
cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>developer-id</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>stripSwiftSymbols</key>
  <true/>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS"

APP_PATH="$EXPORT_PATH/$APP_NAME.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Expected exported app at $APP_PATH" >&2
  exit 2
fi

# Build the polished DMG via create-dmg. Window/icon coordinates match the
# layout that scripts/dmg/generate-background.swift draws (app at x=180,
# Applications shortcut at x=620, on an 800x400 background).
create-dmg \
  --volname "$VOLUME_NAME" \
  --background "$DMG_BG" \
  --window-pos 200 120 \
  --window-size 800 400 \
  --icon-size 96 \
  --icon "$APP_NAME.app" 180 160 \
  --hide-extension "$APP_NAME.app" \
  --app-drop-link 620 160 \
  --no-internet-enable \
  "$DMG_PATH" \
  "$APP_PATH"

codesign --force --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$DMG_PATH"
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG_PATH"
spctl --assess --type open --context context:primary-signature --verbose "$DMG_PATH"

echo "$DMG_PATH"
