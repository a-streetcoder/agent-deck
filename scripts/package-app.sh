#!/usr/bin/env bash
# Builds an exported Developer ID-signed Agent Deck .app without creating a DMG.
# Intended for local install/testing. Release packaging still uses the GitHub
# workflow and scripts/package-dmg.sh.
#
# Required env:
#   DEVELOPER_ID_APPLICATION  - signing identity, e.g. "Developer ID Application: Name (D37Z4S3883)"
#
# Optional env (defaults shown):
#   PROJECT=agent-deck.xcodeproj
#   SCHEME=agent-deck
#   CONFIGURATION=Release
#   BUILD_DIR=build/local-app
#   VERSION=<from MARKETING_VERSION in pbxproj>
#   APP_NAME="Agent Deck"
#   DEVELOPMENT_TEAM=<parsed from signing identity when possible>
#   BUILD_NUMBER=<current project build number>
#   SU_FEED_URL=  # empty disables Sparkle (Pi Deck default)
#   ALLOW_NON_PRODUCTION_FEED=0
#
# Output: $BUILD_DIR/export/Agent Deck.app (path printed on stdout)

set -euo pipefail

PROJECT="${PROJECT:-agent-deck.xcodeproj}"
SCHEME="${SCHEME:-agent-deck}"
CONFIGURATION="${CONFIGURATION:-Release}"
BUILD_DIR="${BUILD_DIR:-build/local-app}"
ARCHIVE_PATH="${ARCHIVE_PATH:-$BUILD_DIR/$SCHEME.xcarchive}"
EXPORT_PATH="${EXPORT_PATH:-$BUILD_DIR/export}"
APP_NAME="${APP_NAME:-Agent Deck}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_ENTITLEMENTS="$REPO_ROOT/agent-deck/agent-deck.entitlements"

if [[ ! -f "$APP_ENTITLEMENTS" ]]; then
  echo "Missing main-app entitlements at $APP_ENTITLEMENTS. Restore agent-deck/agent-deck.entitlements before packaging." >&2
  exit 2
fi

if [[ -z "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  echo "Set DEVELOPER_ID_APPLICATION to your Developer ID Application signing identity." >&2
  exit 2
fi

if [[ -z "${VERSION:-}" ]]; then
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print' "$PROJECT/project.pbxproj" 2>/dev/null \
    | awk -F'= ' '/MARKETING_VERSION/ {gsub(/[";]/,"",$2); print $2; exit}')"
fi
if [[ -z "${VERSION:-}" ]]; then
  echo "Could not resolve VERSION. Set VERSION=x.y.z and rerun." >&2
  exit 2
fi

DEFAULT_SU_FEED_URL=""
if [[ -z "${DEVELOPMENT_TEAM:-}" ]]; then
  DEVELOPMENT_TEAM="$(printf '%s' "$DEVELOPER_ID_APPLICATION" | sed -n 's/.*(\([A-Z0-9][A-Z0-9]*\)).*/\1/p')"
fi

FEED_CANDIDATE="${SU_FEED_URL:-$DEFAULT_SU_FEED_URL}"
# Pi Deck must never follow upstream Agent Deck Sparkle releases.
if [[ "$FEED_CANDIDATE" == *"agentdeck.site"* ]]; then
  echo "Refusing to package with upstream Agent Deck SU_FEED_URL=$FEED_CANDIDATE." >&2
  echo "Leave SU_FEED_URL empty (disable Sparkle) or use a Pi Deck first-party feed." >&2
  exit 2
fi
if [[ -n "$FEED_CANDIDATE" && "${ALLOW_NON_PRODUCTION_FEED:-0}" != "1" ]]; then
  echo "Non-empty SU_FEED_URL requires ALLOW_NON_PRODUCTION_FEED=1 until Pi Deck production feed is defined." >&2
  exit 2
fi

XCODEBUILD_OVERRIDES=(
  "MARKETING_VERSION=$VERSION"
  "CODE_SIGN_IDENTITY=$DEVELOPER_ID_APPLICATION"
  "CODE_SIGN_STYLE=Manual"
  "ENABLE_HARDENED_RUNTIME=YES"
  "OTHER_CODE_SIGN_FLAGS=--timestamp"
)
if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
  XCODEBUILD_OVERRIDES+=("DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM")
fi
if [[ -n "${BUILD_NUMBER:-}" ]]; then
  XCODEBUILD_OVERRIDES+=("CURRENT_PROJECT_VERSION=$BUILD_NUMBER")
fi

mkdir -p "$BUILD_DIR"
rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH"

xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -archivePath "$ARCHIVE_PATH" \
  "${XCODEBUILD_OVERRIDES[@]}"

EXPORT_OPTIONS="$BUILD_DIR/ExportOptions.plist"
cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>developer-id</string>
  <key>signingStyle</key>
  <string>manual</string>
PLIST
if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
  cat >> "$EXPORT_OPTIONS" <<PLIST
  <key>teamID</key>
  <string>$DEVELOPMENT_TEAM</string>
PLIST
fi
cat >> "$EXPORT_OPTIONS" <<PLIST
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

PLIST="$APP_PATH/Contents/Info.plist"
EXPECTED_SU_FEED_URL="${SU_FEED_URL:-$DEFAULT_SU_FEED_URL}"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" "$PLIST"
if [[ -n "${BUILD_NUMBER:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $BUILD_NUMBER" "$PLIST"
fi
TARGET_BUILD_DIR="$APP_PATH/Contents" \
  INFOPLIST_PATH="Info.plist" \
  SU_FEED_URL="$EXPECTED_SU_FEED_URL" \
  bash "$SCRIPT_DIR/inject-sparkle-info.sh"
# The main app is signed last after Info.plist mutation. Do not pass these
# app-specific entitlements to nested frameworks, helpers, or services.
codesign --force --options runtime --timestamp --entitlements "$APP_ENTITLEMENTS" --sign "$DEVELOPER_ID_APPLICATION" "$APP_PATH"

ACTUAL_SU_FEED_URL="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$PLIST" 2>/dev/null || true)"
if [[ "$ACTUAL_SU_FEED_URL" != "$EXPECTED_SU_FEED_URL" ]]; then
  echo "Expected SUFeedURL=$EXPECTED_SU_FEED_URL, found ${ACTUAL_SU_FEED_URL:-<missing>} in $APP_PATH." >&2
  exit 2
fi
codesign --verify --deep --strict "$APP_PATH"
SIGNED_ENTITLEMENTS="$(mktemp "${TMPDIR:-/tmp}/agent-deck-entitlements.XXXXXX")"
if ! codesign -d --entitlements :- "$APP_PATH" > "$SIGNED_ENTITLEMENTS" 2>/dev/null; then
  rm -f "$SIGNED_ENTITLEMENTS"
  echo "Could not inspect signed entitlements for $APP_PATH." >&2
  exit 2
fi
SIGNED_APPLE_EVENTS="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.automation.apple-events' "$SIGNED_ENTITLEMENTS" 2>/dev/null || true)"
rm -f "$SIGNED_ENTITLEMENTS"
if [[ "$SIGNED_APPLE_EVENTS" != "true" ]]; then
  echo "Signed app is missing com.apple.security.automation.apple-events=true: $APP_PATH" >&2
  exit 2
fi

echo "$APP_PATH"
