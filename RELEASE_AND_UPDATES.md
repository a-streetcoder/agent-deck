# Agent Deck — Releases & Auto-Update Setup

End-to-end guide to publishing Agent Deck on GitHub with automated builds and Sparkle-powered in-app updates.

This guide is tailored to the current repo state:

- Bundle ID: `streetcoding.agent-deck`
- Team: `D37Z4S3883`
- Hardened Runtime: **on** (good — required for Sparkle)
- App Sandbox: **off** (only `com.apple.security.automation.apple-events` is set) — means we use **standard Sparkle**, no XPC services bundle needed. If you ever turn on the App Sandbox, you must switch to the XPC services integration; revisit this guide first.
- GitHub repo: `a-streetcoder/agent-deck`
- Existing helper: `scripts/package-dmg.sh` (signed + notarized DMG locally)
- Existing CI: `.github/workflows/macos-build.yml` (Debug build only)
- No tags yet → first tagged release will be `v0.1.0` (suggested; pick what you like)

The end result:

1. You push a tag like `v0.1.0`. GitHub Actions builds, signs, notarizes, packages the DMG, creates a GitHub Release, updates the Sparkle appcast, and publishes it to GitHub Pages.
2. Users running an older Agent Deck see a native update dialog (the one you saw in osaurus), click **Install Update**, and the app relaunches as the new version.

---

## Phase 0 — One-time prerequisites

You only do these once, ever.

### 0.1 Apple credentials

You should already have these for `package-dmg.sh`. If not:

- **Developer ID Application** certificate installed in your local Keychain. Verify: `security find-identity -v -p codesigning` should list `Developer ID Application: ... (D37Z4S3883)`.
- **Notary credentials**. Either:
  - An **App Store Connect API key** (recommended for CI — `.p8` file + Key ID + Issuer ID), or
  - An app-specific password tied to your Apple ID.

### 0.2 GitHub CLI

Used for issuing releases and pushing secrets:

```bash
brew install gh
gh auth login
```

### 0.3 GitHub Pages bucket for the appcast

The appcast XML must be reachable over HTTPS at a stable URL. Easiest option: serve `docs/` from this repo via GitHub Pages.

1. In the repo settings → **Pages** → set **Source** to *Deploy from a branch*, branch `main`, folder `/docs`.
2. After enabling, your appcast will live at:
   ```
   https://a-streetcoder.github.io/agent-deck/appcast.xml
   ```
   (We'll create the file in Phase 3.)

If you prefer a separate public repo for hosting (osaurus does this so the main repo can stay quiet), you can — but a single repo is simpler and works fine. Stick with single-repo unless you have a reason.

---

## Phase 1 — Sparkle keys

Sparkle uses **EdDSA** signatures so the app can verify downloaded updates came from you, even if GitHub Releases is compromised. You generate the keypair once and keep the private key secret forever.

### 1.1 Get the Sparkle tooling

```bash
brew install --cask sparkle
# OR download the Sparkle 2.x release zip from https://github.com/sparkle-project/Sparkle/releases
# and extract `bin/generate_keys`, `bin/sign_update`, `bin/generate_appcast` somewhere on PATH.
```

(If you use the cask, the tools end up at `/opt/homebrew/Caskroom/sparkle/<version>/bin/`. Add that to PATH or alias the binaries.)

### 1.2 Generate the keypair

```bash
generate_keys
```

This stores the **private** key in your login Keychain (item name: `https://sparkle-project.org`) and prints the **public** key to stdout. Looks like:

```
A new keypair has been generated and stored in your keychain.
The public key is:
xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
```

**Save the public key** — you'll embed it in the app.
**Export the private key** for CI:

```bash
generate_keys -x sparkle_private_key.txt
```

This writes the raw base64 private key. Treat it like a signing cert: never commit it, store it in 1Password or similar. We'll upload it to GitHub Actions as a secret in Phase 4.

> If you lose the private key, you can never ship updates to existing installs again — they'll reject the new signature. Back it up.

---

## Phase 2 — Wire Sparkle into the app

### 2.1 Add the SwiftPM dependency

In Xcode: **File → Add Package Dependencies…** → URL `https://github.com/sparkle-project/Sparkle` → version rule **Up to Next Major** from `2.7.0` → add product `Sparkle` to the `agent-deck` target.

### 2.2 Add the Info.plist keys

Easiest path: set them as Xcode build settings (they get injected as `INFOPLIST_KEY_*`).

In Xcode → `agent-deck` target → **Build Settings** → **+** → Add User-Defined Setting, or just paste these into the target Info tab directly:

| Key | Value |
|---|---|
| `SUFeedURL` | `https://a-streetcoder.github.io/agent-deck/appcast.xml` |
| `SUPublicEDKey` | the public key from Phase 1.2 |
| `SUEnableAutomaticChecks` | `YES` |
| `SUScheduledCheckInterval` | `86400` (once per day; optional, this is the default) |

If you'd rather keep these out of the Xcode UI, add them via the pbxproj as `INFOPLIST_KEY_SUFeedURL`, `INFOPLIST_KEY_SUPublicEDKey`, `INFOPLIST_KEY_SUEnableAutomaticChecks`. Osaurus's `App/osaurus.xcodeproj/project.pbxproj:470-472` is a working reference.

### 2.3 Add the updater service

Create `agent-deck/UpdaterService.swift`:

```swift
import Foundation
import Sparkle

@MainActor
final class UpdaterViewModel: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published var updateAvailable: Bool = false
    @Published var availableVersion: String? = nil

    lazy var updaterController: SPUStandardUpdaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: self,
        userDriverDelegate: nil
    )

    /// User-initiated check. Shows the Sparkle dialog (the one with "Install Update",
    /// "Remind Me Later", "Skip This Version").
    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    /// Silent background check. Sparkle pops the dialog only if there's something new.
    func checkForUpdatesInBackground() {
        updaterController.updater.checkForUpdatesInBackground()
    }

    // MARK: - SPUUpdaterDelegate

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        Task { @MainActor in
            self.updateAvailable = true
            self.availableVersion = version
        }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in
            self.updateAvailable = false
            self.availableVersion = nil
        }
    }
}
```

That's the whole integration. The published flags are only needed if you want to show a custom "Update available" badge somewhere in your UI; the actual update dialog is owned by Sparkle's standard user driver and doesn't need any wiring.

### 2.4 Hold the updater at app scope

In `agent-deck/agent_deckApp.swift`, add an updater to the app delegate so its lifetime matches the app:

```swift
// In AgentDeckAppDelegate
let updater = UpdaterViewModel()
```

Then inject it as an environment object in `agent_deckApp.body`:

```swift
var body: some Scene {
    WindowGroup {
        ContentView()
            .environmentObject(viewModel)
            .environmentObject(appDelegate.updater)
            .preferredColorScheme(viewModel.appSettings.appearanceMode.preferredColorScheme)
    }
    // …
    Settings {
        SettingsSceneContent()
            .environmentObject(viewModel)
            .environmentObject(appDelegate.updater)
            .preferredColorScheme(viewModel.appSettings.appearanceMode.preferredColorScheme)
    }
    // …
}
```

### 2.5 Add a "Check for Updates…" menu item

In `AgentDeckCommands`, add a command:

```swift
CommandGroup(after: .appInfo) {
    Button("Check for Updates…") {
        AgentDeckAppDelegate.shared?.updater.checkForUpdates()
    }
}
```

You'll need a `static weak var shared` on `AgentDeckAppDelegate` that gets set in `applicationDidFinishLaunching` — or pull the updater from somewhere else accessible to the command builder. (Commands run outside the SwiftUI environment, so a static reference is the path of least resistance.)

### 2.6 Trigger a background check on launch

In `AgentDeckAppDelegate.applicationDidFinishLaunching` (or wherever you have first-run setup), add:

```swift
updater.checkForUpdatesInBackground()
```

Sparkle will then check on its own schedule (`SUScheduledCheckInterval`) thereafter.

### 2.7 (Optional) In-app "update available" pill

If you want the same "Update Available v0.2.0" pill osaurus shows in its sidebar, read `updater.updateAvailable` / `updater.availableVersion` from any view that has the updater in its environment, and call `updater.checkForUpdates()` on tap. Skip this for v1 — the menu item is enough.

### 2.8 Verify locally

Build and run. From the **agent-deck** menu, click **Check for Updates…**. You should get a Sparkle dialog saying "You're up to date" (or an error about the appcast URL not existing yet — fine, that means Sparkle is wired correctly).

---

## Phase 3 — Bootstrap the appcast

Create `docs/appcast.xml` with an **empty channel**. It needs to exist before the first release so Sparkle can fetch *something* without erroring:

```xml
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Agent Deck</title>
    <link>https://a-streetcoder.github.io/agent-deck/appcast.xml</link>
    <description>Agent Deck updates</description>
    <language>en</language>
  </channel>
</rss>
```

Commit, push, wait ~1 minute for GitHub Pages to deploy, then verify in a browser:

```
https://a-streetcoder.github.io/agent-deck/appcast.xml
```

If you get 404, Pages isn't deployed yet — check the **Actions** tab for the `pages build and deployment` workflow.

---

## Phase 4 — GitHub Actions secrets

Set these via `gh secret set <NAME>` from the repo root, or via the GitHub web UI (**Settings → Secrets and variables → Actions**).

### 4.1 Code-signing identity

Export your Developer ID Application cert as a `.p12` from Keychain Access (right-click → Export, set a password):

```bash
base64 -i DeveloperIDApplication.p12 | pbcopy
gh secret set MACOS_CERTIFICATE          # paste base64
gh secret set MACOS_CERTIFICATE_PWD      # the .p12 password you chose
gh secret set MACOS_KEYCHAIN_PASSWORD    # invent a fresh password, used for the runner's temporary keychain
gh secret set MACOS_SIGN_IDENTITY        # e.g. "Developer ID Application: Your Name (D37Z4S3883)"
```

### 4.2 Notarization (App Store Connect API key — preferred)

In App Store Connect → **Users and Access** → **Keys** → generate an API key with role **Developer**. Download the `.p8` file (one chance only).

```bash
base64 -i AuthKey_XXXXXXXX.p8 | pbcopy
gh secret set NOTARY_KEY                 # paste base64
gh secret set NOTARY_KEY_ID              # the 10-character Key ID
gh secret set NOTARY_ISSUER_ID           # the issuer UUID
```

### 4.3 Sparkle private key

```bash
cat sparkle_private_key.txt | pbcopy     # from Phase 1.2
gh secret set SPARKLE_PRIVATE_KEY        # paste it
```

### 4.4 Verify

```bash
gh secret list
```

Should show all 7 secrets.

---

## Phase 5 — Release workflow

Replace `.github/workflows/macos-build.yml` (or add a new file `.github/workflows/release.yml` — keeping them separate is cleaner so PR builds stay fast).

Create `.github/workflows/release.yml`:

```yaml
name: Release

on:
  push:
    tags: ['v*.*.*']
  workflow_dispatch:
    inputs:
      tag:
        description: 'Version tag (e.g. v0.1.0)'
        required: true

permissions:
  contents: write   # needed for `gh release create` and pushing the appcast commit

jobs:
  release:
    name: Build, sign, notarize, publish
    runs-on: macos-26

    steps:
      - name: Resolve tag
        id: tag
        run: |
          if [ "${{ github.event_name }}" = "workflow_dispatch" ]; then
            echo "tag=${{ github.event.inputs.tag }}" >> "$GITHUB_OUTPUT"
          else
            echo "tag=${GITHUB_REF_NAME}" >> "$GITHUB_OUTPUT"
          fi

      - name: Derive version (strip leading v)
        id: ver
        run: echo "version=${TAG#v}" >> "$GITHUB_OUTPUT"
        env:
          TAG: ${{ steps.tag.outputs.tag }}

      - name: Check out repository
        uses: actions/checkout@v4
        with:
          fetch-depth: 0   # we need full history for the appcast commit

      - name: Select Xcode
        run: |
          set -euo pipefail
          for app in /Applications/Xcode_26.5.app /Applications/Xcode_26.4.1.app /Applications/Xcode_26.4.app; do
            if [ -d "$app" ]; then
              echo "DEVELOPER_DIR=$app/Contents/Developer" >> "$GITHUB_ENV"
              exit 0
            fi
          done
          echo "No Xcode 26.4+ found" >&2; exit 1

      - name: Import signing certificate
        env:
          MACOS_CERTIFICATE: ${{ secrets.MACOS_CERTIFICATE }}
          MACOS_CERTIFICATE_PWD: ${{ secrets.MACOS_CERTIFICATE_PWD }}
          MACOS_KEYCHAIN_PASSWORD: ${{ secrets.MACOS_KEYCHAIN_PASSWORD }}
        run: |
          set -euo pipefail
          KEYCHAIN="$RUNNER_TEMP/build.keychain"
          echo "$MACOS_CERTIFICATE" | base64 -d > "$RUNNER_TEMP/cert.p12"
          security create-keychain -p "$MACOS_KEYCHAIN_PASSWORD" "$KEYCHAIN"
          security set-keychain-settings -lut 21600 "$KEYCHAIN"
          security unlock-keychain -p "$MACOS_KEYCHAIN_PASSWORD" "$KEYCHAIN"
          security import "$RUNNER_TEMP/cert.p12" -k "$KEYCHAIN" -P "$MACOS_CERTIFICATE_PWD" -T /usr/bin/codesign
          security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | xargs)
          security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$MACOS_KEYCHAIN_PASSWORD" "$KEYCHAIN"

      - name: Set marketing version
        env:
          VERSION: ${{ steps.ver.outputs.version }}
        run: |
          /usr/libexec/PlistBuddy -c "Print" agent-deck.xcodeproj/project.pbxproj >/dev/null || true
          xcrun agvtool new-marketing-version "$VERSION"
          xcrun agvtool new-version -all "${GITHUB_RUN_NUMBER:-1}"

      - name: Archive
        env:
          SIGN_IDENTITY: ${{ secrets.MACOS_SIGN_IDENTITY }}
        run: |
          set -o pipefail
          xcodebuild archive \
            -project agent-deck.xcodeproj \
            -scheme agent-deck \
            -configuration Release \
            -archivePath build/agent-deck.xcarchive \
            CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
            CODE_SIGN_STYLE=Manual \
            DEVELOPMENT_TEAM=D37Z4S3883 \
            ENABLE_HARDENED_RUNTIME=YES \
            OTHER_CODE_SIGN_FLAGS="--timestamp" 2>&1 | tee build/archive.log

      - name: Export .app
        run: |
          cat > build/ExportOptions.plist <<'PLIST'
          <?xml version="1.0" encoding="UTF-8"?>
          <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
          <plist version="1.0"><dict>
            <key>method</key><string>developer-id</string>
            <key>signingStyle</key><string>manual</string>
            <key>teamID</key><string>D37Z4S3883</string>
            <key>stripSwiftSymbols</key><true/>
          </dict></plist>
          PLIST
          xcodebuild -exportArchive \
            -archivePath build/agent-deck.xcarchive \
            -exportPath build/export \
            -exportOptionsPlist build/ExportOptions.plist

      - name: Create DMG
        env:
          VERSION: ${{ steps.ver.outputs.version }}
        run: |
          mkdir -p build/dist
          hdiutil create \
            -volname "Agent Deck" \
            -srcfolder "build/export/Agent Deck.app" \
            -ov -format UDZO \
            "build/dist/Agent-Deck-${VERSION}.dmg"

      - name: Sign DMG
        env:
          SIGN_IDENTITY: ${{ secrets.MACOS_SIGN_IDENTITY }}
          VERSION: ${{ steps.ver.outputs.version }}
        run: |
          codesign --force --timestamp --sign "$SIGN_IDENTITY" \
            "build/dist/Agent-Deck-${VERSION}.dmg"

      - name: Notarize and staple
        env:
          NOTARY_KEY: ${{ secrets.NOTARY_KEY }}
          NOTARY_KEY_ID: ${{ secrets.NOTARY_KEY_ID }}
          NOTARY_ISSUER_ID: ${{ secrets.NOTARY_ISSUER_ID }}
          VERSION: ${{ steps.ver.outputs.version }}
        run: |
          set -euo pipefail
          echo "$NOTARY_KEY" | base64 -d > "$RUNNER_TEMP/AuthKey.p8"
          xcrun notarytool submit "build/dist/Agent-Deck-${VERSION}.dmg" \
            --key "$RUNNER_TEMP/AuthKey.p8" \
            --key-id "$NOTARY_KEY_ID" \
            --issuer "$NOTARY_ISSUER_ID" \
            --wait
          xcrun stapler staple "build/dist/Agent-Deck-${VERSION}.dmg"
          spctl --assess --type open --context context:primary-signature -v \
            "build/dist/Agent-Deck-${VERSION}.dmg"

      - name: Install Sparkle tools
        run: |
          brew install --cask sparkle
          ln -sf /opt/homebrew/Caskroom/sparkle/*/bin/sign_update /usr/local/bin/sign_update
          ln -sf /opt/homebrew/Caskroom/sparkle/*/bin/generate_appcast /usr/local/bin/generate_appcast

      - name: Sign update with Sparkle EdDSA key
        id: edsig
        env:
          SPARKLE_PRIVATE_KEY: ${{ secrets.SPARKLE_PRIVATE_KEY }}
          VERSION: ${{ steps.ver.outputs.version }}
        run: |
          set -euo pipefail
          SIG=$(sign_update --ed-key-file <(printf '%s' "$SPARKLE_PRIVATE_KEY") \
                "build/dist/Agent-Deck-${VERSION}.dmg")
          # sign_update prints something like:  sparkle:edSignature="…" length="…"
          echo "fragment=$SIG" >> "$GITHUB_OUTPUT"

      - name: Create GitHub Release
        env:
          GH_TOKEN: ${{ github.token }}
          TAG: ${{ steps.tag.outputs.tag }}
          VERSION: ${{ steps.ver.outputs.version }}
        run: |
          gh release create "$TAG" \
            --title "Agent Deck $VERSION" \
            --generate-notes \
            "build/dist/Agent-Deck-${VERSION}.dmg"

      - name: Update appcast.xml
        env:
          TAG: ${{ steps.tag.outputs.tag }}
          VERSION: ${{ steps.ver.outputs.version }}
          ED_FRAGMENT: ${{ steps.edsig.outputs.fragment }}
        run: |
          set -euo pipefail
          PUBDATE=$(LC_ALL=en_US.UTF-8 date -u "+%a, %d %b %Y %H:%M:%S +0000")
          NOTES=$(gh release view "$TAG" --json body --jq '.body' | sed 's/]]>/]]]]><![CDATA[>/g')
          URL="https://github.com/a-streetcoder/agent-deck/releases/download/${TAG}/Agent-Deck-${VERSION}.dmg"

          ITEM=$(cat <<EOF
              <item>
                <title>${VERSION}</title>
                <pubDate>${PUBDATE}</pubDate>
                <sparkle:version>${VERSION}</sparkle:version>
                <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
                <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
                <enclosure url="${URL}" type="application/octet-stream" ${ED_FRAGMENT}/>
                <description><![CDATA[
          ${NOTES}
                ]]></description>
              </item>
          EOF
          )

          python3 - "$ITEM" <<'PY'
          import sys, re, pathlib
          item = sys.argv[1]
          path = pathlib.Path("docs/appcast.xml")
          xml = path.read_text()
          xml = re.sub(r"(<channel>(?:.|\n)*?<description>[^<]*</description>\s*<language>[^<]*</language>\s*)",
                       r"\1\n" + item + "\n", xml, count=1)
          path.write_text(xml)
          PY

          git config user.name  "github-actions[bot]"
          git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
          git add docs/appcast.xml
          git commit -m "appcast: ${VERSION}"
          git push origin HEAD:main
        env:
          GH_TOKEN: ${{ github.token }}
          TAG: ${{ steps.tag.outputs.tag }}
          VERSION: ${{ steps.ver.outputs.version }}
          ED_FRAGMENT: ${{ steps.edsig.outputs.fragment }}
```

A few notes on what the workflow is doing:

- **Tag-driven**: pushing `v0.2.0` triggers a release. `workflow_dispatch` lets you re-run from the UI if needed.
- **Marketing version is rewritten** from the tag, so you never edit `MARKETING_VERSION` in Xcode by hand. Build number = workflow run number (monotonically increasing, satisfies notarization).
- **`agvtool` writes both** `CFBundleShortVersionString` and `CFBundleVersion` into the project before archiving.
- **The appcast update step uses Python** to splice the new `<item>` right after the channel header. The first release will produce a clean appcast; later releases prepend.
- **`gh release --generate-notes`** auto-builds release notes from PR titles since the previous tag. Those same notes get mirrored into the appcast `<description>` and render as the "What's Changed" markdown block in the update dialog.

> If your repo doesn't yet have a previous tag, `--generate-notes` will produce empty/minimal notes. Add a manual `--notes "First public release"` for v0.1.0.

---

## Phase 6 — Cut the first release

```bash
# from main, with everything committed
git tag -a v0.1.0 -m "v0.1.0"
git push origin v0.1.0
```

Watch the **Actions** tab. The job takes ~8–15 minutes (most of it notarization). When it finishes:

- A release appears at `https://github.com/a-streetcoder/agent-deck/releases/tag/v0.1.0` with the DMG attached.
- A commit `appcast: 0.1.0` lands on `main` from the bot, updating `docs/appcast.xml`.
- GitHub Pages redeploys within ~1 minute.

To prove the update flow end-to-end:

1. Install the v0.1.0 DMG, then quit the app.
2. Bump local Xcode `MARKETING_VERSION` to something **lower** like `0.0.9`, build & run from Xcode.
3. **agent-deck → Check for Updates…** — you should see the dialog announcing 0.1.0.
4. Reset the Xcode marketing version back, don't commit the temporary downgrade.

---

## Phase 7 — Day-to-day release flow

After all of the above, releasing a new version is:

```bash
git tag -a v0.2.0 -m "v0.2.0"
git push origin v0.2.0
```

That's it. Everything else is automatic.

For pre-release tagging (beta channel) you'd add `sparkle:channel` support — out of scope for v1; add it when you actually want it.

---

## Phase 8 — Troubleshooting

| Symptom | Likely cause |
|---|---|
| Sparkle says "An error occurred while downloading the update" | Appcast URL 404, or `<enclosure url>` doesn't match the actual GitHub Releases download URL. Open both in a browser. |
| "The update is improperly signed and could not be validated" | `SUPublicEDKey` in Info.plist doesn't match the private key used by `sign_update`. Re-run Phase 1 if you've lost track. |
| Notarization fails with `Invalid` status | Run `xcrun notarytool log <submission-id> --key … --key-id … --issuer …` for the detailed report. Common causes: missing `--timestamp`, hardened runtime off, unsigned embedded binary (rare with pure SwiftUI). |
| "Check for Updates" menu item does nothing | `AgentDeckAppDelegate.shared` isn't being set, or the updater isn't being kept alive. Confirm in the debugger that `updater.updaterController.updater.canCheckForUpdates` is `true`. |
| App refuses to install update silently | macOS Gatekeeper rejected the DMG. `spctl --assess` it locally; if that fails, notarization didn't actually staple. |
| Appcast commits failing to push | Branch protection on `main` blocking the bot. Either exempt `github-actions[bot]`, or push the appcast to a `gh-pages` branch and have Pages serve from there instead. |

---

## What this doesn't cover (yet)

- **Beta channel** — add `sparkle:channel` to appcast items + a `UserDefaults`-backed toggle in Settings, like osaurus `UpdaterService.swift:71-74`.
- **Delta updates** — switching from per-release `sign_update` to driving `generate_appcast` against an `updates/` directory of recent DMGs. Worth it when the app gets large; skip until then.
- **Universal vs arm64-only** — your current build is implicitly arm64 since the workflow only specifies macOS. If you want Intel support, add `ARCHS="x86_64 arm64"` to the `xcodebuild archive` step and add `<sparkle:hardwareRequirements>` in appcast items.
- **Sparkle for sandboxed apps** — if you ever enable App Sandbox (you'd need to for Mac App Store, never for direct distribution), switch to Sparkle's XPC services integration. See <https://sparkle-project.org/documentation/sandboxing/>.

---

## Reference: files this guide touches

- `agent-deck/UpdaterService.swift` *(new)*
- `agent-deck/agent_deckApp.swift` *(env injection + commands)*
- `agent-deck/Info.plist` build settings *(SUFeedURL, SUPublicEDKey, SUEnableAutomaticChecks)*
- `docs/appcast.xml` *(new, hosted via GitHub Pages)*
- `.github/workflows/release.yml` *(new)*
- 7 GitHub Actions secrets *(see Phase 4)*

The existing `scripts/package-dmg.sh` stays as-is for local one-off builds; the workflow does the same thing in CI.
