on piWindow()
  tell application "System Events"
    tell process "agent-deck"
      return window 1
    end tell
  end tell
end piWindow

on piWindowRect()
  tell application "System Events"
    tell process "agent-deck"
      set w to window 1
      set p to position of w
      set s to size of w
      return ((item 1 of p) as text) & "," & ((item 2 of p) as text) & "," & ((item 1 of s) as text) & "," & ((item 2 of s) as text)
    end tell
  end tell
end piWindowRect

on activatePi()
  tell application "System Events"
    if exists process "iTerm2" then set visible of process "iTerm2" to false
  end tell
  tell application "agent-deck" to activate
  delay 0.5
end activatePi
