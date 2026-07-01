#!/usr/bin/env bash
# Build a local signed/notarized Agent Deck DMG, generate a local Sparkle
# appcast for it, and serve both from localhost without publishing to GitHub.
#
# Required env:
#   DEVELOPER_ID_APPLICATION  Developer ID Application signing identity
#   NOTARY_PROFILE            xcrun notarytool keychain profile name
#   SPARKLE_PRIVATE_KEY        Sparkle EdDSA private key (base64)
#
# Optional env:
#   VERSION=<project MARKETING_VERSION>
#   BUILD_NUMBER=<project CURRENT_PROJECT_VERSION>
#   PORT=8765
#   BUILD_DIR=build/local-update-test
#   RELEASE_NOTES="..."
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

for var in DEVELOPER_ID_APPLICATION NOTARY_PROFILE SPARKLE_PRIVATE_KEY; do
  if [[ -z "${!var:-}" ]]; then
    echo "Set $var before running this script." >&2
    exit 2
  fi
done

if ! command -v sign_update >/dev/null 2>&1; then
  echo "Sparkle's sign_update tool is not on PATH." >&2
  echo "Install/expose Sparkle tools first, then rerun." >&2
  exit 2
fi

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
Building local update candidate:
  Version:      $VERSION
  Build number: $BUILD_NUMBER
  Local feed:   $FEED_URL
EOF

DMG_PATH="$(ALLOW_NON_PRODUCTION_FEED=1 \
  SU_FEED_URL="$FEED_URL" \
  VERSION="$VERSION" \
  BUILD_NUMBER="$BUILD_NUMBER" \
  BUILD_DIR="$BUILD_DIR" \
  bash scripts/package-dmg.sh | tail -n 1)"

if [[ ! -f "$DMG_PATH" ]]; then
  echo "Expected DMG at $DMG_PATH" >&2
  exit 1
fi

DMG_NAME="$(basename "$DMG_PATH")"
cp "$DMG_PATH" "$SERVE_DIR/$DMG_NAME"

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
