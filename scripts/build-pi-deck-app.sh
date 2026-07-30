#!/usr/bin/env bash
# Local unsigned (or ad-hoc) Release build of Pi Deck.app + install-layout DMG.
# Does not notarize. For Developer ID export use package-app.sh with credentials.
#
# Env:
#   SKIP_BUILD=1     — reuse existing OUT_APP, only rebuild zip/dmg
#   SKIP_DMG=1       — app (+ zip) only
#   VERSION          — default from app Info.plist or 0.0.1
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIGURATION="${CONFIGURATION:-Release}"
BUILD_DIR="${BUILD_DIR:-$ROOT/build}"
DERIVED="${DERIVED:-$BUILD_DIR/DerivedData}"
OUT_APP="${OUT_APP:-$BUILD_DIR/Pi-Deck.app}"
APP_DISPLAY_NAME="${APP_DISPLAY_NAME:-Pi Deck}"
DMG_BG="${DMG_BG:-$ROOT/scripts/dmg/background.png}"

mkdir -p "$BUILD_DIR"

# ---------------------------------------------------------------------------
# Disk image cleanup (create-dmg often leaves RW images mounted → "资源忙")
# ---------------------------------------------------------------------------

# Detach any volume whose mount point or image path looks like our Pi Deck DMG work.
detach_pi_deck_volumes() {
  local max_rounds="${1:-8}"
  local round image mountpoint
  for ((round = 1; round <= max_rounds; round++)); do
    local busy=0
    # Mounted volumes under /Volumes that we created
    while IFS= read -r mountpoint; do
      [[ -z "$mountpoint" ]] && continue
      if hdiutil detach "$mountpoint" -force >/dev/null 2>&1; then
        echo "==> Detached volume: $mountpoint"
      else
        busy=1
      fi
    done < <(mount | awk '
      $3 ~ /^\/Volumes\/(Pi Deck|dmg\.|Pi-Deck)/ { print $3 }
    ')

    # Images attached from build/ (read-only final or rw.* temps)
    while IFS= read -r image; do
      [[ -z "$image" ]] && continue
      if hdiutil detach "$image" -force >/dev/null 2>&1; then
        echo "==> Detached image: $image"
      else
        # Also try by device node if listed
        busy=1
      fi
    done < <(hdiutil info 2>/dev/null | awk -v root="$BUILD_DIR" '
      /^image-path/ {
        sub(/^image-path[[:space:]]*:[[:space:]]*/, "")
        path = $0
      }
      /^\/dev\// {
        dev = $1
        if (path != "" && index(path, root) == 1) {
          print path
          path = ""
        }
      }
    ')

    # Leftover create-dmg temp RW images in build/
    rm -f "$BUILD_DIR"/rw.*.dmg 2>/dev/null || true

    if [[ $busy -eq 0 ]]; then
      # Confirm no Pi Deck / dmg.* volumes remain
      if mount | awk '$3 ~ /^\/Volumes\/(Pi Deck|dmg\.|Pi-Deck)/ { found=1 } END { exit found ? 0 : 1 }'; then
        sleep 1
        continue
      fi
      return 0
    fi
    sleep 1
  done
  echo "warning: some disk images may still be busy" >&2
  return 0
}

# Manual install-layout DMG if create-dmg cannot finish (still has Applications drop target).
make_dmg_fallback() {
  local version="$1"
  local dmg_path="$2"
  local stage="$BUILD_DIR/dmg-stage-fallback"
  local tmp_dmg="$BUILD_DIR/.Pi-Deck-${version}-rw.dmg"

  echo "==> Fallback DMG with Applications symlink..."
  rm -rf "$stage"
  mkdir -p "$stage"
  ditto "$OUT_APP" "$stage/${APP_DISPLAY_NAME}.app"
  ln -s /Applications "$stage/Applications"

  rm -f "$tmp_dmg" "$dmg_path"
  hdiutil create \
    -volname "Pi Deck ${version}" \
    -srcfolder "$stage" \
    -ov \
    -format UDRW \
    -fs HFS+ \
    "$tmp_dmg" >/dev/null

  # Compress to final UDZO
  hdiutil convert "$tmp_dmg" -format UDZO -imagekey zlib-level=9 -o "$dmg_path" >/dev/null
  rm -f "$tmp_dmg"
  rm -rf "$stage"
  detach_pi_deck_volumes 3
}

make_dmg_create_dmg() {
  local version="$1"
  local dmg_path="$2"
  local stage="$BUILD_DIR/dmg-stage"
  local attempt status

  if ! command -v create-dmg >/dev/null 2>&1; then
    echo "create-dmg not found; using fallback layout" >&2
    make_dmg_fallback "$version" "$dmg_path"
    return
  fi

  rm -rf "$stage"
  mkdir -p "$stage"
  ditto "$OUT_APP" "$stage/${APP_DISPLAY_NAME}.app"

  local args=(
    --volname "Pi Deck ${version}"
    --window-pos 200 120
    --window-size 800 400
    --icon-size 96
    --icon "${APP_DISPLAY_NAME}.app" 180 160
    --hide-extension "${APP_DISPLAY_NAME}.app"
    --app-drop-link 620 160
    --no-internet-enable
  )
  if [[ -f "$DMG_BG" ]]; then
    args+=(--background "$DMG_BG")
  fi

  for attempt in 1 2 3; do
    detach_pi_deck_volumes 6
    rm -f "$dmg_path" "$BUILD_DIR"/rw.*.dmg
    echo "==> create-dmg attempt ${attempt}..."
    set +e
    # Run from BUILD_DIR so create-dmg temp rw.*.dmg lands next to final output (easy cleanup)
    (
      cd "$BUILD_DIR"
      create-dmg "${args[@]}" "$dmg_path" "$stage"
    )
    status=$?
    set -e
    detach_pi_deck_volumes 6
    rm -f "$BUILD_DIR"/rw.*.dmg

    if [[ $status -eq 0 && -f "$dmg_path" ]]; then
      rm -rf "$stage"
      return 0
    fi
    echo "==> create-dmg attempt $attempt failed (status=$status)"
    sleep 2
  done

  rm -rf "$stage"
  echo "==> create-dmg exhausted retries; fallback..."
  make_dmg_fallback "$version" "$dmg_path"
}

# ---------------------------------------------------------------------------
# Build app
# ---------------------------------------------------------------------------

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
  echo "==> Building agent-deck ($CONFIGURATION)..."
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
else
  if [[ ! -d "$OUT_APP" ]]; then
    echo "SKIP_BUILD=1 but missing $OUT_APP" >&2
    exit 1
  fi
  echo "==> Reusing $OUT_APP"
fi

VERSION="${VERSION:-}"
if [[ -z "$VERSION" ]]; then
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$OUT_APP/Contents/Info.plist" 2>/dev/null || true)"
fi
VERSION="${VERSION:-0.0.1}"

ZIP_PATH="$BUILD_DIR/Pi-Deck-${VERSION}.zip"
DMG_PATH="$BUILD_DIR/Pi-Deck-${VERSION}.dmg"

rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$OUT_APP" "$ZIP_PATH"
echo "==> Zip: $ZIP_PATH"

if [[ "${SKIP_DMG:-0}" == "1" ]]; then
  ls -lh "$OUT_APP" "$ZIP_PATH"
  exit 0
fi

# Prefer polished create-dmg (App + Applications shortcut + background).
make_dmg_create_dmg "$VERSION" "$DMG_PATH"

if [[ ! -f "$DMG_PATH" ]]; then
  echo "DMG was not created: $DMG_PATH" >&2
  exit 1
fi

echo "==> DMG (drag Pi Deck → Applications): $DMG_PATH"
ls -lh "$OUT_APP" "$ZIP_PATH" "$DMG_PATH"
shasum -a 256 "$ZIP_PATH" "$DMG_PATH"
