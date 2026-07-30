#!/usr/bin/env bash
# Injects Info.plist keys after Xcode generates the product plist.
#
# Pi Deck fork policy:
#   Do NOT point Sparkle at upstream Agent Deck (agentdeck.site appcast).
#   In-app Sparkle is disabled until Pi Deck has its own feed + signing keys.
#   Set SU_FEED_URL / SU_PUBLIC_ED_KEY only when intentionally shipping
#   first-party updates.
#
# PostHog: preserve any already-injected token; do not force Agent Deck analytics.

set -euo pipefail

PLIST="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"

if [[ ! -f "$PLIST" ]]; then
  echo "warning: Info.plist not found at $PLIST — skipping app key injection" >&2
  exit 0
fi

# Empty feed + no automatic checks = Sparkle cannot follow Agent Deck releases.
SU_FEED_URL="${SU_FEED_URL:-}"
SU_PUBLIC_ED_KEY="${SU_PUBLIC_ED_KEY:-}"
SU_AUTOMATIC_CHECKS="${SU_AUTOMATIC_CHECKS:-NO}"
SU_CHECK_INTERVAL="${SU_CHECK_INTERVAL:-0}"

set_or_add() {
  local key="$1" type="$2" value="$3"
  if /usr/libexec/PlistBuddy -c "Print :$key" "$PLIST" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Set :$key $value" "$PLIST"
  else
    /usr/libexec/PlistBuddy -c "Add :$key $type $value" "$PLIST"
  fi
}

# Always clear / set Sparkle to non-updating defaults for this fork.
set_or_add "SUFeedURL" string "$SU_FEED_URL"
if [[ -n "$SU_PUBLIC_ED_KEY" ]]; then
  set_or_add "SUPublicEDKey" string "$SU_PUBLIC_ED_KEY"
else
  # Drop upstream Agent Deck EdDSA key if present from older builds / pbx keys.
  if /usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$PLIST" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey " "$PLIST" 2>/dev/null \
      || /usr/libexec/PlistBuddy -c "Delete :SUPublicEDKey" "$PLIST" 2>/dev/null \
      || true
  fi
fi
set_or_add "SUEnableAutomaticChecks" bool "$SU_AUTOMATIC_CHECKS"
if [[ -n "$SU_CHECK_INTERVAL" && "$SU_CHECK_INTERVAL" != "0" ]]; then
  set_or_add "SUScheduledCheckInterval" integer "$SU_CHECK_INTERVAL"
else
  if /usr/libexec/PlistBuddy -c "Print :SUScheduledCheckInterval" "$PLIST" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Set :SUScheduledCheckInterval 0" "$PLIST" 2>/dev/null || true
  fi
fi

if [[ "${POSTHOG_PROJECT_TOKEN+x}" == "x" ]]; then
  POSTHOG_TOKEN="$POSTHOG_PROJECT_TOKEN"
else
  POSTHOG_TOKEN="$(/usr/libexec/PlistBuddy -c 'Print :AgentDeckPostHogProjectToken' "$PLIST" 2>/dev/null || true)"
fi
# Prefer empty token for Pi Deck unless packaging explicitly injects one.
set_or_add "AgentDeckPostHogProjectToken" string "${POSTHOG_TOKEN:-}"

echo "Injected Pi Deck Info.plist keys (Sparkle feed disabled unless SU_FEED_URL set) → $PLIST"
