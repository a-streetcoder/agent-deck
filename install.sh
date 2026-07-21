#!/bin/bash
# Agent Deck installer
#
#   curl -fsSL https://raw.githubusercontent.com/a-streetcoder/agent-deck/main/install.sh | bash
#
# Installs the Pi CLI if it's missing (npm -> pnpm -> Bun -> Pi's official
# curl installer), then downloads the latest notarized Agent Deck DMG, verifies its
# SHA-256 checksum, and copies the app to /Applications.
#
# Flags:
#   --force   skip all prompts (replace an existing app, skip Pi update offer)
#
# Rules this script lives by:
#   * Never installs a second Pi: an existing `pi` from any source (brew, npm,
#     pi.dev, manual) is detected and respected.
#   * Updates are method-aware: a brew-owned pi updates via brew, anything
#     else via `pi update pi`. Never mixed.
#   * Never installs through Homebrew. It uses only pi.dev's package-manager
#     methods, or Pi's own installer when no package manager is available.

set -euo pipefail

REPO="a-streetcoder/agent-deck"
APP_PATH="/Applications/Agent Deck.app"
PI_LATEST_URL="https://pi.dev/api/latest-version"

FORCE=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
  esac
done

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
note()  { printf '  %s\n' "$*"; }
die()   { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }

# When piped (curl | bash) stdin is the script itself, so prompts must read
# from the terminal. With no terminal at all, behave non-interactively.
# Probe by actually opening /dev/tty: the node exists even without a
# controlling terminal, where any real read would fail.
HAS_TTY=0
if ( : < /dev/tty ) 2>/dev/null; then HAS_TTY=1; fi

# ask "Question [y/N] " -> 0 on yes. Non-interactive: returns the default,
# which is "no" unless --force.
ask() {
  if [ "$FORCE" = 1 ]; then return 0; fi
  if [ "$HAS_TTY" != 1 ]; then return 1; fi
  local reply
  read -r -p "$1" reply < /dev/tty || return 1
  [[ "$reply" =~ ^[Yy] ]]
}

bold "Agent Deck installer"

# ── Preflight ────────────────────────────────────────────────────────────────
[ "$(uname -s)" = "Darwin" ] || die "Agent Deck is a macOS app. This installer only runs on macOS."
[ "$(uname -m)" = "arm64" ] || die "Agent Deck requires Apple Silicon (this Mac reports $(uname -m))."
MACOS_MAJOR=$(sw_vers -productVersion | cut -d. -f1)
if [ "${MACOS_MAJOR:-0}" -lt 26 ]; then
  note "Warning: Agent Deck requires macOS 26 (Tahoe); this Mac runs $(sw_vers -productVersion). Installing anyway."
fi

# ── Step 1: Pi CLI ───────────────────────────────────────────────────────────
PI_RESULT=""
if command -v pi >/dev/null 2>&1; then
  PI_BIN="$(command -v pi)"
  PI_VERSION="$(pi --version 2>/dev/null | head -1 || true)"
  PI_RESULT="already installed (${PI_VERSION:-unknown version} at ${PI_BIN})"

  # Best-effort freshness check; never block the app install on it.
  LATEST_PI="$(curl -fsSL --max-time 2 "$PI_LATEST_URL" 2>/dev/null | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' || true)"
  if [ -n "$LATEST_PI" ] && [ -n "$PI_VERSION" ] && [ "$LATEST_PI" != "$PI_VERSION" ]; then
    # Method-aware update. The path prefix can't tell brew from npm (npm's
    # global prefix often lives under /opt/homebrew via brew's node); only
    # the formula's binaries resolve into the pi-coding-agent Cellar keg.
    if [[ "$(readlink -f "$PI_BIN" 2>/dev/null)" == */Cellar/pi-coding-agent/* ]]; then
      UPDATE_CMD="brew upgrade pi-coding-agent"
    else
      UPDATE_CMD="pi update pi"
    fi
    if ask "Pi ${PI_VERSION} is installed; ${LATEST_PI} is available. Update now? [y/N] "; then
      if $UPDATE_CMD; then
        PI_RESULT="updated to $(pi --version 2>/dev/null | head -1 || echo "$LATEST_PI") (${PI_BIN})"
      else
        note "Pi update failed; keeping ${PI_VERSION}. You can run \`${UPDATE_CMD}\` later."
      fi
    else
      [ "$FORCE" = 1 ] || note "Keeping Pi ${PI_VERSION}. Update later with \`${UPDATE_CMD}\`."
    fi
  fi
elif command -v npm >/dev/null 2>&1; then
  bold "Installing the Pi CLI with npm…"
  npm install -g --ignore-scripts @earendil-works/pi-coding-agent
  PI_RESULT="installed via npm"
elif command -v pnpm >/dev/null 2>&1; then
  bold "Installing the Pi CLI with pnpm…"
  pnpm add -g --ignore-scripts @earendil-works/pi-coding-agent
  PI_RESULT="installed via pnpm"
elif command -v bun >/dev/null 2>&1; then
  bold "Installing the Pi CLI with Bun…"
  bun add -g --ignore-scripts @earendil-works/pi-coding-agent
  PI_RESULT="installed via Bun"
elif [ "$HAS_TTY" = 1 ]; then
  # No npm, pnpm, or Bun: Pi's official installer can set up Node too. It is
  # interactive, so run it from a file with stdin pointed at the terminal
  # (our own stdin may be the curl pipe).
  bold "Installing the Pi CLI with Pi's official installer…"
  PI_INSTALLER="$(mktemp -t agent-deck-pi-installer)"
  curl -fsSL https://pi.dev/install.sh -o "$PI_INSTALLER"
  if sh "$PI_INSTALLER" < /dev/tty; then
    PI_RESULT="installed via pi.dev installer"
  else
    PI_RESULT="NOT installed (pi.dev installer did not finish; Agent Deck's Doctor can install it later)"
  fi
  rm -f "$PI_INSTALLER"
else
  PI_RESULT="NOT installed (no npm, pnpm, or Bun, and no interactive terminal; Agent Deck's Doctor can install it on first run)"
fi

# ── Step 2: existing install ────────────────────────────────────────────────
LATEST_TAG="$(curl -fsSL -o /dev/null -w '%{url_effective}' "https://github.com/${REPO}/releases/latest" 2>/dev/null | sed 's|.*/tag/||' || true)"
VERSION="${LATEST_TAG#v}"
DMG_NAME="Agent-Deck-${VERSION}.dmg"
DMG_URL="https://github.com/${REPO}/releases/latest/download/${DMG_NAME}"
SHA_URL="${DMG_URL}.sha256"
if [ -z "$LATEST_TAG" ] || [ "$LATEST_TAG" = "$VERSION" ]; then
  die "Could not determine the latest Agent Deck release. Try again in a minute."
fi
if [ -d "$APP_PATH" ]; then
  INSTALLED_VERSION="$(defaults read "$APP_PATH/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "")"
  if [ -n "$INSTALLED_VERSION" ] && [ "v$INSTALLED_VERSION" = "$LATEST_TAG" ] && [ "$FORCE" != 1 ]; then
    bold "Agent Deck ${INSTALLED_VERSION} is already installed and up to date."
    note "Pi: ${PI_RESULT}"
    exit 0
  fi
  if ! ask "Agent Deck ${INSTALLED_VERSION:-unknown} is installed; ${LATEST_TAG:-latest} is available. Replace it? [y/N] "; then
    note "Keeping the existing app. Re-run with --force to replace it."
    note "Pi: ${PI_RESULT}"
    exit 0
  fi
  if pgrep -xq "Agent Deck"; then
    note "Quitting the running Agent Deck…"
    osascript -e 'quit app "Agent Deck"' >/dev/null 2>&1 || true
    sleep 2
  fi
fi

# ── Step 3: download, verify, install ───────────────────────────────────────
WORK="$(mktemp -d -t agent-deck-install)"
MOUNT="$WORK/mnt"
cleanup() {
  hdiutil detach "$MOUNT" -quiet 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

download_and_verify() {
  curl -fL --progress-bar "$DMG_URL" -o "$WORK/$DMG_NAME"
  curl -fsSL "$SHA_URL" -o "$WORK/${DMG_NAME}.sha256"
  (cd "$WORK" && shasum -a 256 -c "${DMG_NAME}.sha256" >/dev/null)
}

bold "Downloading Agent Deck…"
if ! download_and_verify; then
  # One retry covers the race where a new release published between fetches.
  note "Checksum mismatch; retrying once…"
  download_and_verify || die "Download or checksum verification failed. Try again in a minute, or download the DMG from https://github.com/${REPO}/releases/latest."
fi

bold "Installing to /Applications…"
mkdir -p "$MOUNT"
hdiutil attach "$WORK/$DMG_NAME" -nobrowse -readonly -quiet -mountpoint "$MOUNT"
rm -rf "$APP_PATH"
ditto "$MOUNT/Agent Deck.app" "$APP_PATH"
hdiutil detach "$MOUNT" -quiet
# The app is Developer ID signed, notarized, and stapled; Gatekeeper needs no
# quarantine workarounds.

INSTALLED="$(defaults read "$APP_PATH/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "?")"
echo ""
bold "Done."
note "Agent Deck ${INSTALLED} -> /Applications"
note "Pi: ${PI_RESULT}"
echo ""
if ask "Open Agent Deck now? [y/N] "; then
  open -a "Agent Deck"
fi
