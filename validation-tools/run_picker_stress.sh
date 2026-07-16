#!/usr/bin/env bash
set -euo pipefail

app_path="${1:-$HOME/Library/Developer/Xcode/DerivedData/agent-deck-gwxndsmwmuaowndfdfmmfhfwhtxb/Build/Products/Debug/Agent Deck.app}"
log_path="${2:-/tmp/agentdeck-picker-stress-$(date +%s).log}"
script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd -- "$script_directory/.." && pwd -P)"
project_candidate="${AGENTDECK_PICKER_STRESS_PROJECT_PATH:-$repo_root}"

if [[ ! -d "$repo_root/.git" ]]; then
  echo "Missing repository root: $repo_root" >&2
  exit 64
fi
if ! project_path="$(cd -- "$project_candidate" && pwd -P)"; then
  echo "Missing stress project: $project_candidate" >&2
  exit 64
fi

if [[ ! -x "$app_path/Contents/MacOS/Agent Deck" ]]; then
  echo "Missing Debug app: $app_path" >&2
  exit 64
fi

debug_executable="$app_path/Contents/MacOS/Agent Deck"
startup_timeout_seconds=15
journey_timeout_seconds=90

# `open -n` launches a distinct WindowGroup even when the installed app uses
# the same bundle ID. Match only this exact Debug executable, never the user's
# installed app.
debug_pids() {
  ps -ax -o pid= -o command= | while read -r pid command; do
    if [[ "$command" == "$debug_executable"* ]]; then
      printf '%s\n' "$pid"
    fi
  done
}

pid_is_debug_app() {
  local pid="$1"
  debug_pids | grep -qx "$pid"
}

cleanup_debug_pid() {
  local pid="$1"
  if ! pid_is_debug_app "$pid"; then return; fi
  echo "PICKER_STRESS_RUNNER cleanup Debug pid=$pid" >&2
  kill "$pid" 2>/dev/null || true
  local deadline=$((SECONDS + 5))
  while pid_is_debug_app "$pid" && (( SECONDS < deadline )); do sleep 0.1; done
  if pid_is_debug_app "$pid"; then
    kill -KILL "$pid" 2>/dev/null || true
  fi
}

session_directory="$(mktemp -d "${TMPDIR:-/tmp}/agentdeck-picker-stress.XXXXXX")"
launched_pid=""
cleanup() {
  local status=$?
  if [[ -n "$launched_pid" ]]; then cleanup_debug_pid "$launched_pid"; fi
  rm -rf -- "$session_directory"
  exit "$status"
}
trap cleanup EXIT INT TERM

existing_pids="$(debug_pids)"
: >"$log_path"

# `open` provides the launched process's environment and file descriptors;
# its own exit only confirms LaunchServices accepted the request.
open -n -F \
  --stdout "$log_path" \
  --stderr "$log_path" \
  --env AGENTDECK_PICKER_STRESS=1 \
  --env AGENTDECK_PICKER_STRESS_PROJECT_PATH="$project_path" \
  --env AGENTDECK_PICKER_STRESS_SESSION_DIR="$session_directory" \
  --env HangWatchdogEnabled=YES \
  "$app_path"
startup_deadline=$((SECONDS + startup_timeout_seconds))
while (( SECONDS < startup_deadline )); do
  while read -r pid; do
    if ! grep -qx "$pid" <<<"$existing_pids"; then
      launched_pid="$pid"
      break 2
    fi
  done < <(debug_pids)
  sleep 0.1
done

if [[ -z "$launched_pid" ]]; then
  cat "$log_path"
  echo "PICKER_STRESS_RUNNER FAIL Debug app process not detected within ${startup_timeout_seconds}s log=$log_path" >&2
  exit 1
fi

echo "PICKER_STRESS_RUNNER launched Debug pid=$launched_pid log=$log_path"
journey_deadline=$((SECONDS + journey_timeout_seconds))
while pid_is_debug_app "$launched_pid"; do
  if (( SECONDS >= journey_deadline )); then
    sample_path="${log_path}.timeout.sample.txt"
    /usr/bin/sample "$launched_pid" 10 -file "$sample_path" >/dev/null 2>&1 || true
    cleanup_debug_pid "$launched_pid"
    cat "$log_path"
    echo "PICKER_STRESS_RUNNER FAIL timed out after ${journey_timeout_seconds}s log=$log_path sample=$sample_path" >&2
    exit 124
  fi
  sleep 0.1
done

cat "$log_path"
if ! grep -q 'PICKER_STRESS COMPLETE' "$log_path"; then
  echo "PICKER_STRESS_RUNNER FAIL Debug app exited without completion marker log=$log_path" >&2
  exit 1
fi

if ! grep -q 'PICKER_STRESS TRANSITION synthetic rows=12 ' "$log_path" \
    || ! grep -q 'PICKER_STRESS TRANSITION resolved rows=4 ' "$log_path"; then
  echo "PICKER_STRESS_RUNNER FAIL required catalog transition markers missing log=$log_path" >&2
  exit 1
fi

if grep -Eqi 'Publishing changes from within view updates|Update Constraints|NSGenericException|PICKER_STRESS FAIL' "$log_path"; then
  echo "PICKER_STRESS_RUNNER FAIL diagnostic found log=$log_path" >&2
  exit 1
fi

echo "PICKER_STRESS_RUNNER PASS log=$log_path"
