# GitHub DMG Pickup

This site reads Agent Deck download metadata from the GitHub repository:

- Repo: `https://github.com/a-streetcoder/agent-deck`
- API endpoint used by the site: `https://api.github.com/repos/a-streetcoder/agent-deck/releases/latest`

## How the site picks the download

The homepage code is in:

- [src/lib/github.ts](/Users/andrea/Documents/GitHub/agentdeck-site/src/lib/github.ts)

Current behavior:

1. The site requests the repo's `latest` GitHub release.
2. It reads the release version from `tag_name`.
3. It scans the release assets for the first file whose name ends with `.dmg`.
4. If a `.dmg` asset is found, the `Download for macOS` button links to that asset's `browser_download_url`.
5. If no latest release exists, or no `.dmg` asset exists on that release, the page falls back to a non-active download state and links users to the repo's releases page instead.

## Where the DMG must be

The DMG must be attached as an asset on the GitHub release itself.

That means:

- It is not enough to have the DMG somewhere in the repository files.
- It is not enough to have the DMG in GitHub Actions artifacts.
- It must appear under the release asset list for the latest published GitHub release.

Correct location:

- `GitHub repo`
- `Releases`
- `Latest release`
- `Assets`
- `your-file.dmg`

## File naming requirements

The current site code accepts any asset name ending in `.dmg`.

Examples that will work:

- `Agent-Deck-1.0.dmg`
- `Agent Deck.dmg`
- `agent-deck-v1.0.dmg`

Examples that will not be used:

- `Agent-Deck-1.0.zip`
- `Agent-Deck.pkg`
- `agent-deck.dmg.sha256`

Recommended naming:

- `Agent-Deck-<version>.dmg`

Example:

- `Agent-Deck-1.0.0.dmg`

## How to publish it so the site can use it

### Option 1: GitHub web UI

1. Open the repo's Releases page.
2. Create a new release, or edit an existing draft release.
3. Set the tag, for example `v1.0.0`.
4. Upload the DMG file into the release asset area.
5. Publish the release.

Once that release becomes the latest published release, the site can pick it up.

### Option 2: GitHub CLI

Example:

```bash
gh release create v1.0.0 \
  --title "Agent Deck 1.0.0" \
  --notes "First public release." \
  /path/to/Agent-Deck-1.0.0.dmg
```

## Version shown on the site

The site displays the version from the release `tag_name`.

Examples:

- tag `v1.0.0` -> site shows `v1.0.0`
- tag `1.0.0` -> site shows `v1.0.0`

## Important limitation

The site currently uses GitHub's `releases/latest` endpoint.

That means:

- GitHub chooses which release is "latest"
- draft releases are ignored
- prereleases may not behave the way you want for the public download button

For the public site, publish a normal release with the DMG attached.

## Current fallback behavior

If the repo has:

- no published release, or
- a published release with no `.dmg` asset

then the site:

- does not expose a real DMG download URL
- shows fallback release info
- links to `https://github.com/a-streetcoder/agent-deck/releases`

## If you want stricter matching later

Right now the logic is intentionally simple: first asset ending in `.dmg`.

If needed, this can be tightened later to require:

- a specific filename pattern
- notarized-only naming conventions
- stable asset names
- separate stable/beta channels
