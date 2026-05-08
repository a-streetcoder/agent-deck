#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 output.png" >&2
  exit 64
fi

out="$1"
mkdir -p "$(dirname "$out")"

osascript <<'APPLESCRIPT' >/tmp/agent-deck-window-rect.txt
tell application "System Events"
  tell process "agent-deck"
    set w to window 1
    set p to position of w
    set s to size of w
    return ((item 1 of p) as text) & "," & ((item 2 of p) as text) & "," & ((item 1 of s) as text) & "," & ((item 2 of s) as text)
  end tell
end tell
APPLESCRIPT

rect="$(tr -d '\r' </tmp/agent-deck-window-rect.txt)"
screencapture -x -R"$rect" "$out"
ls -lh "$out"
