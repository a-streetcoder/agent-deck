# Release Packaging

Use the existing signed-notarized DMG flow; do not invent a parallel release process.

## Local release script

`scripts/package-dmg.sh` archives the app, exports a Developer ID-signed `.app`, builds the branded DMG, notarizes it, staples it, and verifies it.

Required environment variables:

- `DEVELOPER_ID_APPLICATION`
- `NOTARY_PROFILE`

Prerequisites:

- `create-dmg` installed via Homebrew
- `scripts/dmg/background.png` present

Example:

```bash
DEVELOPER_ID_APPLICATION='Developer ID Application: ...' \
NOTARY_PROFILE='your-notary-profile' \
bash scripts/package-dmg.sh
```

## GitHub release workflow

`.github/workflows/release.yml` is the canonical CI release flow.

- Runs on tag pushes matching `v*.*` or manual dispatch.
- Version tags may be two-part feature releases (`v1.8`, `v2.0`) or three-part patch releases (`v1.7.1`).
- Patch and minor releases are published to the same Sparkle appcast with a one-day phased rollout interval; manual "Check for Updates..." sees them immediately, while scheduled checks roll out across Sparkle's update groups. Major releases, such as `v2.0`, are not phased.
- Requires signing, notarization, and Sparkle secrets from GitHub Actions.
- Attaches the Sparkle `<item>` as `appcast-item.xml` to the GitHub release; `agentdeck.site` stitches these fragments into `/appcast.xml` dynamically.
- Patch-release appcast descriptions include the cumulative changelog for the whole minor series (e.g. 2.7 + 2.7.1 + 2.7.2 for a 2.7.2 update), because Sparkle only shows the current item's notes and would otherwise hide skipped patches.

If release behavior changes, update both the script and the workflow.

## Computer Use permissions

After installing or reinstalling a newly signed Agent Deck build, Computer Use may need macOS permissions again. Do not reset or request TCC permissions automatically. Ask the user to grant them manually:

1. In **System Settings → Privacy & Security → Automation**, allow **Agent Deck** to control the installed Computer Use/Codex component.
2. If screenshots are needed, in **System Settings → Privacy & Security → Screen & System Audio Recording**, allow the **Codex Computer Use service**.

Accessibility is a separate permission gate when the service needs it. These permissions belong to the signed installed components, not Pi; changing a signature or reinstalling can require the user to review them again.

Before publishing, run the focused static regression checks in addition to the normal signing/notarization flow:

```bash
bash scripts/test-package-signing.sh
```
