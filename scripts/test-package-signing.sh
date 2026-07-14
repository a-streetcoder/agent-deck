#!/usr/bin/env bash
# Static regression checks for the final main-app signing steps in both package paths.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTITLEMENTS="$REPO_ROOT/agent-deck/agent-deck.entitlements"
USAGE_DESCRIPTION='$(APP_PRODUCT_NAME) uses automation to control apps you explicitly permit through assigned Computer Use.'

fail() {
  echo "package-signing test failure: $*" >&2
  exit 1
}

[[ -f "$ENTITLEMENTS" ]] || fail "missing $ENTITLEMENTS"
/usr/libexec/PlistBuddy -c 'Print :com.apple.security.automation.apple-events' "$ENTITLEMENTS" 2>/dev/null | grep -qx 'true' \
  || fail "source entitlement must enable Apple Events automation"

for script in scripts/package-app.sh scripts/package-dmg.sh; do
  path="$REPO_ROOT/$script"
  bash -n "$path"
  grep -Fq 'APP_ENTITLEMENTS="$REPO_ROOT/agent-deck/agent-deck.entitlements"' "$path" \
    || fail "$script does not define the source entitlement path"
  grep -Fq 'Missing main-app entitlements at $APP_ENTITLEMENTS' "$path" \
    || fail "$script does not fail clearly when the entitlement file is absent"
  grep -Fq -- '--options runtime --timestamp --entitlements "$APP_ENTITLEMENTS" --sign "$DEVELOPER_ID_APPLICATION" "$APP_PATH"' "$path" \
    || fail "$script final main-app signature omits the entitlement"
  grep -Fq 'codesign --verify --deep --strict "$APP_PATH"' "$path" \
    || fail "$script does not strictly verify the signed app"
  grep -Fq 'codesign -d --entitlements :- "$APP_PATH"' "$path" \
    || fail "$script does not inspect signed app entitlements"
  grep -Fq 'Print :com.apple.security.automation.apple-events' "$path" \
    || fail "$script does not parse the signed Apple Events entitlement"
done

usage_count="$(grep -Fc "INFOPLIST_KEY_NSAppleEventsUsageDescription = \"$USAGE_DESCRIPTION\";" "$REPO_ROOT/agent-deck.xcodeproj/project.pbxproj" || true)"
[[ "$usage_count" == '2' ]] || fail "Apple Events usage description must be set in Debug and Release build settings"

echo "Package-signing static checks passed."
