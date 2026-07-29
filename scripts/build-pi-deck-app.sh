#!/usr/bin/env bash
# Local unsigned (or ad-hoc) Release build of Pi Deck.app for sideload testing.
# Does not notarize. For Developer ID export use package-app.sh with credentials.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIGURATION="${CONFIGURATION:-Release}"
BUILD_DIR="${BUILD_DIR:-$ROOT/build}"
DERIVED="${DERIVED:-$BUILD_DIR/DerivedData}"
OUT_APP="${OUT_APP:-$BUILD_DIR/Pi-Deck.app}"

mkdir -p "$BUILD_DIR"

echo "==> Building agent-deck ($CONFIGURATION)…"
xcodebuild \
  -project agent-deck.xcodeproj \
  -scheme agent-deck \
  -configuration "$CONFIGURATION" \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}" \
  CODE_SIGNING_ALLOWED="${CODE_SIGNING_ALLOWED:-NO}" \
  build

SRC_APP="$(find "$DERIVED/Build/Products/$CONFIGURATION" -maxdepth 1 -name '*.app' | head -1)"
if [[ -z "$SRC_APP" || ! -d "$SRC_APP" ]]; then
  echo "Could not find built .app under $DERIVED/Build/Products/$CONFIGURATION" >&2
  exit 1
fi

rm -rf "$OUT_APP"
ditto "$SRC_APP" "$OUT_APP"
echo "==> Packaged: $OUT_APP"
ls -la "$OUT_APP/Contents/MacOS" | head -5
