# /deploy-local

Pull the latest changes from origin, bump the build number, archive, notarize, and deliver the app to iCloud Drive for local installation.

## Workflow

Run these steps in order from `/Users/andrea/Documents/GitHub/agent-deck`:

### 1. Pull
```bash
git pull origin main
```

### 2. Bump build number
Read `CURRENT_PROJECT_VERSION` from `agent-deck.xcodeproj/project.pbxproj`, increment by 1, then:
```bash
xcrun agvtool new-version -all <new_build>
git add agent-deck.xcodeproj/project.pbxproj
git commit -m "Bump build to <new_build>"
git push
```

### 3. Archive
```bash
xcodebuild archive \
  -project agent-deck.xcodeproj \
  -scheme agent-deck \
  -configuration Release \
  -archivePath /tmp/agent-deck-build/agent-deck.xcarchive
```

### 4. Export (direct distribution — Developer ID)
Write `/tmp/agent-deck-build/ExportOptions.plist`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>developer-id</string>
  <key>signingStyle</key>
  <string>automatic</string>
  <key>teamID</key>
  <string>D37Z4S3883</string>
</dict>
</plist>
```
Then:
```bash
xcodebuild -exportArchive \
  -archivePath /tmp/agent-deck-build/agent-deck.xcarchive \
  -exportPath /tmp/agent-deck-build/export \
  -exportOptionsPlist /tmp/agent-deck-build/ExportOptions.plist
```

### 5. Notarize & staple
```bash
ditto -c -k --keepParent \
  "/tmp/agent-deck-build/export/Agent Deck.app" \
  "/tmp/agent-deck-build/Agent Deck <new_build>.zip"

xcrun notarytool submit \
  "/tmp/agent-deck-build/Agent Deck <new_build>.zip" \
  --keychain-profile "AgentDeck" \
  --wait

xcrun stapler staple "/tmp/agent-deck-build/export/Agent Deck.app"
```

### 6. Deliver to iCloud & verify
```bash
mkdir -p ~/Library/Mobile\ Documents/com~apple~CloudDocs/Agent\ Deck

mv "/tmp/agent-deck-build/export/Agent Deck.app" \
   ~/Library/Mobile\ Documents/com~apple~CloudDocs/Agent\ Deck/"Agent Deck <new_build>.app"

spctl --assess --verbose \
  ~/Library/Mobile\ Documents/com~apple~CloudDocs/Agent\ Deck/"Agent Deck <new_build>.app"
```

### 7. Notify user
Report the build number, iCloud path, and notarization result.

## Notes
- Notarytool profile: `AgentDeck` (keychain, `dev@streetcoding.org`, team `D37Z4S3883`)
- iCloud destination: `~/Library/Mobile Documents/com~apple~CloudDocs/Agent Deck/`
- If the build fails due to Swift 6 `@MainActor` inference on new structs, mark the affected methods and static members as `nonisolated` / `nonisolated(unsafe)`
