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

## Computer Use prerequisites and permissions

Agent Deck does not bundle the independent `codex-computer-use-mcp` package or OpenAI components. Live release validation requires the exact supported broker version in the documented Application Support location and the official ChatGPT app with its signed Codex app-server/Computer Use components installed.

Computer Use calls run through those signed OpenAI components, not directly from Agent Deck or Pi. If macOS blocks access, do not reset or request TCC permissions automatically. Ask the user to review **System Settings → Privacy & Security** for the installed ChatGPT/Codex Computer Use component:

1. **Automation** for app control.
2. **Accessibility** for Accessibility-tree access and actions.
3. **Screen & System Audio Recording** for screenshots.

A new Agent Deck signature does not own these grants. Updating or reinstalling the responsible OpenAI component can require the user to review them again.

Before publishing, run the focused static regression checks in addition to the normal signing/notarization flow:

```bash
bash scripts/test-package-signing.sh
```
