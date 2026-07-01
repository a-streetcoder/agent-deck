#!/usr/bin/env bash
# Injects Sparkle's SU* keys into the built app's Info.plist.
#
# Why this exists:
#   Xcode's `INFOPLIST_KEY_*` build settings only emit Info.plist entries
#   for keys Apple's tooling recognises. Custom keys like SUFeedURL,
#   SUPublicEDKey, etc. are silently dropped — confirmed empirically against
#   Xcode 26 / macOS Tahoe. This script PlistBuddy-injects them after the
#   plist is generated, before code signing runs.
#
# How to wire it up (one-time, in Xcode UI):
#   1. Select the `agent-deck` target → Build Phases tab.
#   2. Click "+" → New Run Script Phase.
#   3. Drag the phase to sit AFTER "Copy Bundle Resources" and BEFORE
#      anything related to signing. (Default insertion at the bottom is
#      usually fine — code signing happens after all build phases.)
#   4. Paste this as the script body:
#         "${SRCROOT}/scripts/inject-sparkle-info.sh"
#   5. Uncheck "Based on dependency analysis" so it runs every build.
#   6. Optional: name the phase "Inject Sparkle Info.plist keys" for clarity.
#
# After that, every Debug + Release build will end up with SU* keys baked
# into the Info.plist. Sparkle's "Check for Updates…" will then work.

set -euo pipefail

PLIST="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"

if [[ ! -f "$PLIST" ]]; then
  echo "warning: Info.plist not found at $PLIST — skipping Sparkle key injection" >&2
  exit 0
fi

# Keep this list in sync with the in-app Sparkle setup. Update the public
# key if you ever rotate the Sparkle EdDSA keypair.
SU_FEED_URL="${SU_FEED_URL:-https://agentdeck.site/appcast.xml}"
SU_PUBLIC_ED_KEY="CWncStYBPVugWOxjexH1nhbtMiUedfr62Zq/Colmf6U="
SU_AUTOMATIC_CHECKS="YES"
SU_CHECK_INTERVAL=86400   # once a day

set_or_add() {
  local key="$1" type="$2" value="$3"
  if /usr/libexec/PlistBuddy -c "Print :$key" "$PLIST" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Set :$key $value" "$PLIST"
  else
    /usr/libexec/PlistBuddy -c "Add :$key $type $value" "$PLIST"
  fi
}

set_or_add "SUFeedURL"                string  "$SU_FEED_URL"
set_or_add "SUPublicEDKey"            string  "$SU_PUBLIC_ED_KEY"
set_or_add "SUEnableAutomaticChecks"  bool    "$SU_AUTOMATIC_CHECKS"
set_or_add "SUScheduledCheckInterval" integer "$SU_CHECK_INTERVAL"

echo "Injected Sparkle Info.plist keys → $PLIST"
