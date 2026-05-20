# Agent Deck — Sparkle release setup: what's left for you

Everything that can be automated is committed. This file lists the remaining steps **only you** can do (credentials, GitHub settings, the first tag push). Roughly 20 minutes end-to-end.

Work through these in order. Each section is independent — if you get interrupted, you can come back and resume at the next unchecked step.

---

## Step 1 — Generate the Sparkle EdDSA keypair

Sparkle uses its own signing key (separate from your Apple Developer ID) so existing installs verify every update came from you, even if Apple's notary service or TLS is compromised.

```bash
brew install --cask sparkle
generate_keys
```

That command:
- Stores the **private** key in your login Keychain (item name: `https://sparkle-project.org`).
- Prints the **public** key to stdout. Looks like:

  ```
  A new keypair has been generated and stored in your keychain.
  The public key is:
  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=
  ```

Now export the private key so CI can use it:

```bash
generate_keys -x ~/sparkle_private_key.txt
```

> [!IMPORTANT]
> **Back up `~/sparkle_private_key.txt` to 1Password right now.** If you lose this file, you can never ship updates to existing installs again — they'll reject every signature you make with a new key. There is no recovery path.

You'll use the public key in Step 2, and the private key file in Step 4.

---

## Step 2 — Embed the public key in the app

Open `agent-deck.xcodeproj/project.pbxproj` in any text editor (not Xcode — easier as plain text).

Search for `REPLACE_WITH_SPARKLE_PUBLIC_KEY`. You'll find it **twice** — once under the Debug build config, once under Release. Replace both with the public key string `generate_keys` printed (the base64 line ending in `=`).

Before:
```
INFOPLIST_KEY_SUPublicEDKey = "REPLACE_WITH_SPARKLE_PUBLIC_KEY";
```

After:
```
INFOPLIST_KEY_SUPublicEDKey = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx=";
```

Save. The next Xcode build will pick it up.

---

## Step 3 — App Store Connect API key

CI notarizes the DMG using an App Store Connect API key (an `.p8` file). If you already have one (you may, since `package-dmg.sh` uses `xcrun notarytool` locally) you can skip the creation steps and jump to Step 4.

To create a new one:

1. Sign in to <https://appstoreconnect.apple.com>.
2. **Users and Access** → **Integrations** → **App Store Connect API** → **Team Keys**.
3. Click **+** (Generate API Key).
4. Name: `Agent Deck CI`. Access: **Developer** (Developer is the minimum role notarytool needs).
5. Click **Generate**.
6. **Download the `.p8` file immediately.** Apple lets you download it exactly once. If you miss it, you have to revoke the key and create a new one.
7. From the same Keys page, note down:
   - **Key ID** (10 characters, displayed next to the key name).
   - **Issuer ID** (UUID at the top of the page, shared across all keys in your team).

Save the `.p8` file somewhere you'll remember — e.g. `~/Documents/AppStoreConnect-AgentDeck.p8`.

---

## Step 4 — Upload the 8 GitHub Actions secrets

CI needs 8 secrets to sign, notarize, and Sparkle-sign every release. There's an interactive helper that walks you through them so you don't have to remember names or base64-encoding rules.

```bash
cd ~/Documents/GitHub/agent-deck
gh auth status                      # must show you're logged in to gh
./scripts/upload-secrets.sh
```

The script asks for each secret one at a time and lets you skip any you've already set. You'll be asked for:

| Secret | What it is |
|---|---|
| `MACOS_CERTIFICATE` | Your Developer ID Application cert exported as `.p12` (Keychain Access → right-click cert → Export). The script base64-encodes it for you. |
| `MACOS_CERTIFICATE_PWD` | The password you chose when exporting the `.p12`. |
| `MACOS_KEYCHAIN_PASSWORD` | A **fresh** password you invent — only used inside the CI runner's temporary keychain. Doesn't need to match anything else. |
| `MACOS_SIGN_IDENTITY` | The exact signing identity string. Find yours with: `security find-identity -v -p codesigning`. Looks like: `Developer ID Application: Your Name (D37Z4S3883)` |
| `NOTARY_KEY` | Path to the `.p8` from Step 3. The script base64-encodes it. |
| `NOTARY_KEY_ID` | The 10-character Key ID from Step 3. |
| `NOTARY_ISSUER_ID` | The Issuer UUID from Step 3. |
| `SPARKLE_PRIVATE_KEY` | Path to `~/sparkle_private_key.txt` from Step 1. The script uploads it as-is. |

When the script finishes it runs `gh secret list` so you can verify all 8 are present.

---

## Step 5 — Enable GitHub Pages

Sparkle reads the appcast XML over HTTPS. Easiest hosting is the repo's `/docs` folder served via GitHub Pages.

1. Open <https://github.com/a-streetcoder/agent-deck/settings/pages>.
2. **Source**: Deploy from a branch.
3. **Branch**: `main`.
4. **Folder**: `/docs`.
5. Click **Save**.

After ~1 minute, verify in a browser:

```
https://a-streetcoder.github.io/agent-deck/appcast.xml
```

You should see the empty-channel XML we committed (`<channel>` with no `<item>` entries yet). If you get 404, the Pages deployment hasn't finished — check the **Actions** tab for the `pages build and deployment` workflow.

---

## Step 6 — Flip the repo to public (when you're ready to launch)

While the repo is private, **two things break for end users**:

- The website (`agentdeck-site`) fetches `https://api.github.com/repos/.../releases/latest` anonymously → returns 404. Site shows the "no active download" fallback.
- Sparkle on installed apps fetches `releases/latest` and downloads the DMG anonymously → also 404. Background update checks silently fail.

Both start working immediately when you flip visibility. Everything in steps 1–5 works on a private repo, so you can do those *now* and flip later.

To flip: <https://github.com/a-streetcoder/agent-deck/settings> → **Danger Zone** → **Change repository visibility** → Public.

If you need to stay private but still serve downloads, the workaround is a separate public "releases-only" repo that CI cross-publishes to — let me know and I can wire that up. Most indie Mac apps just go public when they ship.

---

## Step 7 — Cut the first release

After Steps 1–5 (Step 6 is optional for the first release if you only want to test the CI pipeline):

```bash
cd ~/Documents/GitHub/agent-deck

# Make sure all your in-flight changes are committed first.
git status

# Then tag and push.
git tag -a v0.1.0 -m "v0.1.0"
git push origin v0.1.0
```

That triggers `.github/workflows/release.yml`. Watch it run at <https://github.com/a-streetcoder/agent-deck/actions>.

The job takes **10–15 minutes** — most of it notarization, which is opaque (Apple's queue). Don't kill it if it looks stuck during the notarize step.

When it finishes you should see:

1. A release at `https://github.com/a-streetcoder/agent-deck/releases/tag/v0.1.0` with `Agent-Deck-0.1.0.dmg` attached.
2. A new commit on `main` from `github-actions[bot]`: `appcast: 0.1.0`. This updated `docs/appcast.xml` with the v0.1.0 item.
3. GitHub Pages redeploys within ~1 minute → `https://a-streetcoder.github.io/agent-deck/appcast.xml` now contains an `<item>` for v0.1.0.

If the repo is public (Step 6), `agentdeck-site` will start serving the download immediately. If still private, the GitHub release + appcast exist but nobody outside the repo can fetch them yet.

---

## Step 8 — Test the auto-update flow end-to-end

You must do this **once** before relying on the update path for real users. It's the only way to confirm your public key matches your private key and the appcast is well-formed.

1. **Install the v0.1.0 DMG you just published.** Download it from the GitHub releases page, open it, drag to Applications, launch.
2. **Quit the installed copy.**
3. **In Xcode, downgrade `MARKETING_VERSION` locally** to something lower like `0.0.9`. (Build Settings → search "marketing".)
4. **Build & run from Xcode.** This gives you a "v0.0.9" version of the app running with your real Sparkle setup pointing at the real appcast.
5. **Agent Deck menu → Check for Updates…**
   - Expected: Sparkle dialog announcing **v0.1.0 is available**, with release notes from GitHub.
   - If you get **"You're up to date"**: your appcast doesn't list a newer version yet. Check `docs/appcast.xml` on `main`.
   - If you get **"The update is improperly signed"**: the `SUPublicEDKey` you embedded in Step 2 doesn't match the private key CI signed with in Step 4. Recheck both.
   - If you get **"An error occurred while downloading the update"**: appcast `<enclosure url>` doesn't resolve. Open it in a browser. If 404, the repo is still private.
6. **Click Install Update.** Sparkle downloads the DMG, verifies the EdDSA signature, replaces the app in `/Applications`, and relaunches. The new version should report `0.1.0` in the About panel.
7. **Reset your local `MARKETING_VERSION`** back to whatever it was. Don't commit that downgrade.

If everything works on this run, your update pipeline is good for every subsequent release. From now on releasing is just:

```bash
git tag -a v0.2.0 -m "v0.2.0"
git push origin v0.2.0
```

---

## If something breaks

| Symptom | Where to look |
|---|---|
| CI workflow fails before signing | `Resolve Swift packages` or `Set marketing version` step — usually `gh secret` mismatch (re-run Step 4) or a missing file. |
| CI fails at `Notarize and staple` | Open the workflow log, find the submission ID, run `xcrun notarytool log <submission-id> --key … --key-id … --issuer …` locally. Usual culprits: cert expired, hardened runtime off, unsigned embedded binary. |
| CI fails at `Update appcast.xml` push step | Branch protection on `main` is blocking `github-actions[bot]`. Exempt the bot in repo settings → branches → main → "Allow specified actors to bypass". |
| Sparkle dialog: "improperly signed" | `INFOPLIST_KEY_SUPublicEDKey` in pbxproj doesn't match the `SPARKLE_PRIVATE_KEY` secret. Re-run Steps 1 and 2 together. |
| Sparkle dialog: "An error occurred while downloading" | Either appcast URL is 404 (Pages not deployed, Step 5), or the `<enclosure url>` doesn't resolve (repo private — Step 6), or release was deleted. |
| Website shows "no active download" | Repo is private (Step 6), or the latest release has no `.dmg` asset (CI failed silently). |
| `Check for Updates…` menu item does nothing | Likely `AgentDeckAppDelegate.shared` isn't set — but if you got here from a fresh build it should be. Check Console.app for `Sparkle:` log lines. |

For everything else, the playbook with full details lives at `~/.claude/skills/agent-deck-release/SKILL.md` (it's auto-loaded when you ask me about releases in future sessions).

---

## Checklist (tear-off version)

- [ ] **Step 1** — `generate_keys` + `generate_keys -x` + back up `~/sparkle_private_key.txt` to 1Password
- [ ] **Step 2** — Replace both `REPLACE_WITH_SPARKLE_PUBLIC_KEY` in `agent-deck.xcodeproj/project.pbxproj`
- [ ] **Step 3** — App Store Connect API key generated (or confirm existing one)
- [ ] **Step 4** — `./scripts/upload-secrets.sh` → all 8 secrets uploaded
- [ ] **Step 5** — GitHub Pages enabled, appcast.xml loads in browser
- [ ] **Step 6** — Repo flipped to public (when ready to launch)
- [ ] **Step 7** — `git tag -a v0.1.0 -m "v0.1.0" && git push origin v0.1.0`, CI green
- [ ] **Step 8** — Update flow tested end-to-end with a local downgraded build
