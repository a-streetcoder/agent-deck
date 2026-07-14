![Agent Deck hero artwork](docs/readme-images/hero.jpg)

<p align="center">
  <strong>The native Mac app for running Pi coding agents with clarity and control.</strong><br>
  Agent Deck uses your installed <a href="https://github.com/earendil-works/pi">Pi</a> CLI and gives its sessions, resources, and parallel work a calm, visible home.
</p>

<p align="center">
  <a href="https://github.com/a-streetcoder/agent-deck/releases/latest"><img src="https://img.shields.io/github/v/release/a-streetcoder/agent-deck?sort=semver" alt="Release"></a>
  <a href="https://github.com/a-streetcoder/agent-deck/releases"><img src="https://img.shields.io/github/downloads/a-streetcoder/agent-deck/total" alt="Downloads"></a>
  <a href="https://github.com/a-streetcoder/agent-deck/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-MIT-green" alt="License"></a>
  <img src="https://img.shields.io/badge/macOS-26%20Tahoe-black?logo=apple" alt="macOS 26 Tahoe">
  <img src="https://img.shields.io/badge/Built%20with-Swift%206-orange?logo=swift" alt="Swift">
</p>

<p align="center">
  <a href="https://github.com/a-streetcoder/agent-deck/releases/latest">Download for Mac</a> ·
  <a href="agent-deck-documentation/">Documentation</a> ·
  <a href="https://github.com/a-streetcoder/agent-deck/issues">Issues</a>
</p>

---

## Why Agent Deck is different

Pi is the coding agent. Agent Deck is the native macOS workspace around it — not a replacement runtime and not a web wrapper. It launches the Pi you already have in JSONL RPC mode and makes the surrounding work easier to understand and safer to manage.

- **You can see what is active.** Agents, skills, prompts, and commands show their scope and are assigned deliberately. A file sitting on disk does not silently become part of a session.
- **You can see what will change.** Built-in resources stay read-only, customizations use overrides, and write targets are shown before work begins. Report-only subagents write to their own artifacts, not your project.
- **Parallel work stays organized.** Give sessions and subagents isolated git worktrees, follow their status in one place, and merge work back when you choose.
- **It feels like a Mac app.** SwiftUI windows, keyboard shortcuts, native decision prompts, signed and notarized releases — with no Electron or embedded web UI.

![Agent Deck session workspace](docs/readme-images/cheese.png)

## What you can do

- Run Pi sessions with a live transcript, tool calls, plans, file previews, steering messages, attachments, and terminal handoff.
- Organize agents, skills, reusable prompts, and slash commands for a project or across projects.
- Delegate research, planning, implementation, or review to app-managed subagents and track their results.
- Start from a GitHub issue, work in an isolated branch and worktree, then review, commit, push, or merge the result.
- Browse available models and providers, set session or agent preferences, and manage scoped environment files with secret masking.
- Keep project-specific Markdown memory for decisions and runbooks, with secret scanning on memory writes.
- Use Doctor and onboarding to find, install, and update Pi.

## Install

Install Pi if needed, then download, verify, and copy Agent Deck to `/Applications`:

```bash
curl -fsSL https://raw.githubusercontent.com/a-streetcoder/agent-deck/main/install.sh | bash
```

The script is [`install.sh`](install.sh); read it and its history before piping it to your shell.

Or [download the latest signed and notarized DMG](https://github.com/a-streetcoder/agent-deck/releases/latest) and drag Agent Deck to `/Applications`. If Pi is not installed, onboarding can install it for you. App updates use Sparkle and appear as normal macOS update dialogs.

> Requires macOS 26 (Tahoe) and Apple Silicon.

## Screenshots

### Models and providers

![Agent Deck models view](docs/readme-images/models.png)

### Skills and subagent assignment

![Agent Deck skills view](docs/readme-images/skills.png)

### Agent definitions

![Agent Deck agents view](docs/readme-images/agents.png)

## Documentation

The detailed reference is in [`agent-deck-documentation/`](agent-deck-documentation/):

- [What Pi provides and what Agent Deck adds](agent-deck-documentation/concepts/pi-runtime-vs-agent-deck.md)
- [Resource scopes and assignment](agent-deck-documentation/concepts/resource-scopes-and-resolution.md)
- [Safety, write targets, and artifacts](agent-deck-documentation/concepts/safety-and-artifacts.md)
- [System prompt and Pi launch logic](agent-deck-documentation/agent-deck-system-prompt-logic.md)
- [Skills](agent-deck-documentation/skills-logic.md), [memory](agent-deck-documentation/memory.md), and [model & thinking settings](agent-deck-documentation/model-and-thinking-logic.md)

## Build from source

```bash
git clone https://github.com/a-streetcoder/agent-deck.git
cd agent-deck
open agent-deck.xcodeproj
```

Build the `agent-deck` scheme with Xcode 26.4+, or run:

```bash
xcodebuild -project agent-deck.xcodeproj -scheme agent-deck \
  -configuration Debug -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO build
```

## License

MIT License. See [`LICENSE`](LICENSE).
