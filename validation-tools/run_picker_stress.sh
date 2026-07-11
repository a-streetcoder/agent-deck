#!/usr/bin/env bash
set -euo pipefail

app_path="${1:-$HOME/Library/Developer/Xcode/DerivedData/agent-deck-gwxndsmwmuaowndfdfmmfhfwhtxb/Build/Products/Debug/Agent Deck.app}"
log_path="${2:-/tmp/agentdeck-picker-stress-$(date +%s).log}"

if [[ ! -x "$app_path/Contents/MacOS/Agent Deck" ]]; then
  echo "Missing Debug app: $app_path" >&2
  exit 64
fi

set +e
AGENTDECK_PICKER_STRESS=1 HangWatchdogEnabled=YES \
  "$app_path/Contents/MacOS/Agent Deck" >"$log_path" 2>&1
status=$?
set -e

cat "$log_path"
if (( status != 0 )); then
  echo "PICKER_STRESS_RUNNER FAIL app exit=$status log=$log_path" >&2
  exit "$status"
fi

if ! grep -q 'PICKER_STRESS COMPLETE' "$log_path"; then
  echo "PICKER_STRESS_RUNNER FAIL missing completion marker log=$log_path" >&2
  exit 1
fi

if grep -Eqi 'Publishing changes from within view updates|Update Constraints|NSGenericException|PICKER_STRESS FAIL' "$log_path"; then
  echo "PICKER_STRESS_RUNNER FAIL diagnostic found log=$log_path" >&2
  exit 1
fi

echo "PICKER_STRESS_RUNNER PASS log=$log_path"
