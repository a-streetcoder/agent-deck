#!/usr/bin/env bash
# Build a local signed, non-notarized Agent Deck DMG without publishing to GitHub.
# If a Sparkle private key is available, also generate and serve a local appcast.
#
# Required env/local setup:
#   DEVELOPER_ID_APPLICATION  Developer ID Application signing identity
#                             Auto-detected from Keychain when omitted.
# Optional env/local setup:
#   SPARKLE_PRIVATE_KEY        Sparkle EdDSA private key (base64), or store it
#                             in macOS Keychain under service:
#                             agent-deck-sparkle-private-key
#                             When omitted, the DMG is built with the production
#                             appcast URL and no local appcast is served.
#
# Optional env:
#   VERSION=<project MARKETING_VERSION>
#   BUILD_NUMBER=<project CURRENT_PROJECT_VERSION>
#   PORT=8765
#   BUILD_DIR=build/local-update-test
#   RELEASE_NOTES="..."
#   KEYCHAIN_SPARKLE_SERVICE=agent-deck-sparkle-private-key
#   INSTALL_TO_APPLICATIONS=1
#   RELAUNCH_AFTER_INSTALL=1
#
# Important: the app you use to check for updates must have SUFeedURL pointing
# to the localhost feed printed by this script. Production-installed builds
# point at https://agentdeck.site/appcast.xml and will not see this local feed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

PORT="${PORT:-8765}"
HOST="${HOST:-127.0.0.1}"
BUILD_DIR="${BUILD_DIR:-build/local-update-test}"
SERVE_DIR="$BUILD_DIR/serve"
FEED_URL="http://${HOST}:${PORT}/appcast.xml"
INSTALL_TO_APPLICATIONS="${INSTALL_TO_APPLICATIONS:-1}"
RELAUNCH_AFTER_INSTALL="${RELAUNCH_AFTER_INSTALL:-1}"
APP_NAME="Agent Deck"
INSTALL_PATH="/Applications/${APP_NAME}.app"

KEYCHAIN_SPARKLE_SERVICE="${KEYCHAIN_SPARKLE_SERVICE:-agent-deck-sparkle-private-key}"

if [[ -z "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  DEVELOPER_ID_APPLICATION="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
fi

if [[ -z "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  SPARKLE_PRIVATE_KEY="$(security find-generic-password \
    -a "${USER:-$(whoami)}" \
    -s "$KEYCHAIN_SPARKLE_SERVICE" \
    -w 2>/dev/null || true)"
fi

if [[ -z "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  echo "Set DEVELOPER_ID_APPLICATION before running this script." >&2
  exit 2
fi

LOCAL_APPCAST=0
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  LOCAL_APPCAST=1
  if ! command -v sign_update >/dev/null 2>&1; then
    echo "Sparkle's sign_update tool is not on PATH." >&2
    echo "Install/expose Sparkle tools first, then rerun." >&2
    exit 2
  fi
fi

export DEVELOPER_ID_APPLICATION SPARKLE_PRIVATE_KEY

if [[ -z "${VERSION:-}" ]]; then
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print' agent-deck.xcodeproj/project.pbxproj 2>/dev/null \
    | awk -F'= ' '/MARKETING_VERSION/ {gsub(/[";]/,"",$2); print $2; exit}')"
fi
if [[ -z "${VERSION:-}" ]]; then
  echo "Could not resolve VERSION. Set VERSION=x.y.z and rerun." >&2
  exit 2
fi

if [[ -z "${BUILD_NUMBER:-}" ]]; then
  BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print' agent-deck.xcodeproj/project.pbxproj 2>/dev/null \
    | awk -F'= ' '/CURRENT_PROJECT_VERSION/ {gsub(/[";]/,"",$2); print $2; exit}')"
fi
if [[ -z "${BUILD_NUMBER:-}" ]]; then
  echo "Could not resolve BUILD_NUMBER. Set BUILD_NUMBER=123 and rerun." >&2
  exit 2
fi

MIN_OS="$(awk -F'= ' '/MACOSX_DEPLOYMENT_TARGET/ {gsub(/[";]/,"",$2); print $2; exit}' agent-deck.xcodeproj/project.pbxproj)"
MIN_OS="${MIN_OS:-14.0}"
RELEASE_NOTES="${RELEASE_NOTES:-Local Agent Deck update test for ${VERSION} (${BUILD_NUMBER}).}"

mkdir -p "$SERVE_DIR"

cat <<EOF
Building local production candidate:
  Version:      $VERSION
  Build number: $BUILD_NUMBER
EOF
if [[ "$LOCAL_APPCAST" == "1" ]]; then
  echo "  Local feed:   $FEED_URL"
else
  echo "  Feed:         production appcast (no Sparkle private key found)"
fi

PACKAGE_ENV=(
  SKIP_NOTARIZATION=1
  VERSION="$VERSION"
  BUILD_NUMBER="$BUILD_NUMBER"
  BUILD_DIR="$BUILD_DIR"
)
if [[ "$LOCAL_APPCAST" == "1" ]]; then
  PACKAGE_ENV+=(ALLOW_NON_PRODUCTION_FEED=1 SU_FEED_URL="$FEED_URL")
fi

PACKAGE_LOG="$BUILD_DIR/package-dmg.log"
set +e
env "${PACKAGE_ENV[@]}" bash scripts/package-dmg.sh 2>&1 | tee "$PACKAGE_LOG"
PACKAGE_STATUS=${PIPESTATUS[0]}
set -e
if [[ "$PACKAGE_STATUS" -ne 0 ]]; then
  echo "" >&2
  echo "Build failed. Full log: $PACKAGE_LOG" >&2
  exit "$PACKAGE_STATUS"
fi
DMG_PATH="$(tail -n 1 "$PACKAGE_LOG")"

if [[ ! -f "$DMG_PATH" ]]; then
  echo "Expected DMG at $DMG_PATH" >&2
  exit 1
fi

DMG_NAME="$(basename "$DMG_PATH")"
cp "$DMG_PATH" "$SERVE_DIR/$DMG_NAME"

EXPORTED_APP="$BUILD_DIR/export/${APP_NAME}.app"
if [[ ! -d "$EXPORTED_APP" ]]; then
  echo "Expected exported app at $EXPORTED_APP" >&2
  exit 1
fi

if [[ "$INSTALL_TO_APPLICATIONS" == "1" ]]; then
  echo "Replacing $INSTALL_PATH with local build..."
  if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    echo "Quitting running $APP_NAME..."
    osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
    for _ in {1..30}; do
      pgrep -x "$APP_NAME" >/dev/null 2>&1 || break
      sleep 1
    done
    if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
      echo "$APP_NAME is still running; please quit it and rerun." >&2
      exit 1
    fi
  fi
  rm -rf "$INSTALL_PATH"
  ditto "$EXPORTED_APP" "$INSTALL_PATH"
  echo "Installed: $INSTALL_PATH"
  if [[ "$RELAUNCH_AFTER_INSTALL" == "1" ]]; then
    open "$INSTALL_PATH"
  fi
fi

if [[ "$LOCAL_APPCAST" != "1" ]]; then
  cat <<EOF

Local production build is ready and installed.
  App: $INSTALL_PATH
  DMG: $DMG_PATH

No Sparkle private key was found, so no localhost update feed was created.
The app's Check for Updates will use the normal production feed.
EOF
  exit 0
fi

ED_FRAGMENT="$(sign_update --ed-key-file <(printf '%s' "$SPARKLE_PRIVATE_KEY") "$SERVE_DIR/$DMG_NAME")"
PUBDATE="$(LC_ALL=en_US.UTF-8 date -u '+%a, %d %b %Y %H:%M:%S +0000')"

export VERSION BUILD_NUMBER MIN_OS PUBDATE ED_FRAGMENT RELEASE_NOTES DMG_NAME HOST PORT SERVE_DIR
python3 - <<'PY'
import html
import os
from pathlib import Path

version = os.environ["VERSION"]
build = os.environ["BUILD_NUMBER"]
min_os = os.environ["MIN_OS"]
pubdate = os.environ["PUBDATE"]
ed = os.environ["ED_FRAGMENT"]
notes = html.escape(os.environ["RELEASE_NOTES"])
dmg = os.environ["DMG_NAME"]
host = os.environ["HOST"]
port = os.environ["PORT"]
url = f"http://{host}:{port}/{dmg}"

xml = f'''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Agent Deck Local Updates</title>
    <link>http://{host}:{port}/appcast.xml</link>
    <description>Local Agent Deck update test feed</description>
    <language>en</language>
    <item>
      <title>{html.escape(version)} local test</title>
      <pubDate>{pubdate}</pubDate>
      <sparkle:version>{html.escape(build)}</sparkle:version>
      <sparkle:shortVersionString>{html.escape(version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{html.escape(min_os)}</sparkle:minimumSystemVersion>
      <enclosure url="{html.escape(url)}" type="application/octet-stream" {ed}/>
      <description><![CDATA[<p>{notes}</p>]]></description>
    </item>
  </channel>
</rss>
'''
Path(os.environ["SERVE_DIR"], "appcast.xml").write_text(xml)
PY

cat <<EOF

Local update feed is ready.
  DMG:     $SERVE_DIR/$DMG_NAME
  Appcast: $SERVE_DIR/appcast.xml

Keep this terminal open while testing. Press Ctrl-C to stop the local server.
EOF

cd "$SERVE_DIR"
python3 -m http.server "$PORT" --bind "$HOST"
