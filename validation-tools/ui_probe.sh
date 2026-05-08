#!/usr/bin/env bash
set -euo pipefail

osascript <<'APPLESCRIPT'
on walk(e, depth)
  tell application "System Events"
    try
      set r to role of e as text
    on error
      set r to "?"
    end try
    try
      set d to description of e as text
    on error
      set d to ""
    end try
    try
      set n to name of e as text
    on error
      set n to ""
    end try
    if r is "AXButton" or r is "AXPopUpButton" or r is "AXCheckBox" or r is "AXTextArea" or r is "AXTextField" or r is "AXStaticText" then
      try
        set p to position of e as text
        set s to size of e as text
      on error
        set p to "?"
        set s to "?"
      end try
      log r & " | " & n & " | " & d & " | pos " & p & " | size " & s
    end if
    if depth < 8 then
      try
        repeat with c in UI elements of e
          my walk(c, depth + 1)
        end repeat
      end try
    end if
  end tell
end walk

tell application "System Events" to tell process "agent-deck"
  my walk(window 1, 0)
end tell
APPLESCRIPT
