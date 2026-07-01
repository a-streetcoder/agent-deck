#!/usr/bin/env bash
# Build a local production-style Agent Deck .app and replace /Applications.
# No GitHub release, no DMG, no notarization.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

BUILD_DIR="${BUILD_DIR:-build/local-app-install}"
APP_NAME="Agent Deck"
INSTALL_PATH="/Applications/${APP_NAME}.app"
RELAUNCH_AFTER_INSTALL="${RELAUNCH_AFTER_INSTALL:-1}"

if [[ -z "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  DEVELOPER_ID_APPLICATION="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
fi
if [[ -z "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  echo "Set DEVELOPER_ID_APPLICATION before running this script." >&2
  exit 2
fi
export DEVELOPER_ID_APPLICATION

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

cat <<EOF
Building and installing local production candidate:
  Version:      $VERSION
  Build number: $BUILD_NUMBER
  Install to:   $INSTALL_PATH
  Feed:         production appcast
EOF

PACKAGE_LOG="$BUILD_DIR/package-app.log"
mkdir -p "$BUILD_DIR"
set +e
env \
  VERSION="$VERSION" \
  BUILD_NUMBER="$BUILD_NUMBER" \
  BUILD_DIR="$BUILD_DIR" \
  bash scripts/package-app.sh 2>&1 | tee "$PACKAGE_LOG"
PACKAGE_STATUS=${PIPESTATUS[0]}
set -e
if [[ "$PACKAGE_STATUS" -ne 0 ]]; then
  echo "" >&2
  echo "Build failed. Full log: $PACKAGE_LOG" >&2
  exit "$PACKAGE_STATUS"
fi

EXPORTED_APP="$(tail -n 1 "$PACKAGE_LOG")"
if [[ ! -d "$EXPORTED_APP" ]]; then
  echo "Expected exported app at $EXPORTED_APP" >&2
  exit 1
fi

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

cat <<EOF

Done. Local app build installed.
EOF
