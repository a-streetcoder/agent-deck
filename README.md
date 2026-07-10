![Agent Deck hero artwork](docs/readme-images/hero.jpg)

<p align="center">
  <strong>A native macOS platform for agentic coding workflows, powered by <a href="https://github.com/earendil-works/pi">Pi</a>.</strong><br>
  Manage agents, skills, prompts, subagents, worktrees, and GitHub work in one signed Swift app that runs the installed <code>pi</code> CLI in the background.
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

## Stop juggling terminals. Start commanding agents.

<a href="https://github.com/earendil-works/pi">Pi</a> is a powerful coding agent. It also lives in a terminal. That means scrollback for transcripts, dotfiles for configuration, and copy-paste between issues, repos, and sessions. Agent Deck turns Pi into a native macOS workspace for agentic development: every agent, skill, prompt, command, and session in one window, with explicit scope, live structured output, and the project context you'd otherwise rebuild from memory every time.

Agent Deck does not replace Pi or embed its own agent runtime. It launches the installed `pi` CLI in JSONL RPC mode, manages the surrounding resources and UI, and passes Pi exactly the flags it needs. The result is both a native control surface for Pi sessions and a platform for organizing the agents, skills, prompts, and workflows you run through it.

![Agent Deck session workspace](docs/readme-images/cheese.png)

## Install

One command installs everything on a fresh Mac — the [Pi CLI](https://github.com/earendil-works/pi) if it's missing (and Node if Pi needs it), then the app itself, with the download checksum verified and Agent Deck copied to `/Applications`:

```bash
curl -fsSL https://raw.githubusercontent.com/a-streetcoder/agent-deck/main/install.sh | bash
```

The script is [`install.sh`](install.sh) in this repository — read it (and its history) before piping it to your shell.

Or [download the latest signed and notarized DMG](https://github.com/a-streetcoder/agent-deck/releases/latest) and drag Agent Deck to `/Applications`. If Pi isn't installed yet, onboarding installs it for you with one click.

Whichever path you choose, updates ship through Sparkle — you'll see a native macOS update dialog when a new version is available.

> Requires macOS 26 (Tahoe) and Apple Silicon.

## Design guarantees

**Scope is always visible.** Every agent, skill, and prompt shows where it comes from — Builtin, Global, Library, or Project — with a colored chip, an icon, and text. No ambient discovery surprises, no "where did this come from" mystery sessions.

**Assignment is explicit.** Agent Deck launches Pi with `--no-skills`, `--no-extensions`, `--no-prompt-templates`, `--no-themes` and selectively re-enables only what you assigned. A skill being on disk doesn't mean it's loaded. A skill being assigned does.

**Built-ins are read-only.** When you customize a bundled agent, Agent Deck writes an override file. The original is never modified. You can disable overrides and snap back to the bundled defaults at any time.

**Writes are visible.** Every action that modifies a file shows you what it will write and where. Report-only subagents produce artifacts in their own directory, not edits to your project.

**Native through and through.** SwiftUI, multi-window, keyboard shortcuts for everything, signed and notarized. No Electron, no web views faking it.

## Sessions and transcripts

- **Streaming transcript** with steering messages, thinking blocks, tool calls, plans, inline diffs, file previews, and color-coded status — filterable so you see exactly the detail you want.
- **Live plan checklist** tracks the agent's todo/in-progress/done/blocked/skipped state as it works.
- **Rich composer** with paste handling, `@`-file suggestions, macOS Dictation, and attachments (files, folders, images).
- **Auto-titling** via Apple's on-device Foundation Model (or any model you pick) — no more "Session 47".
- **Idle parking** frees system resources when you walk away.
- **Terminal handoff** when you need raw CLI for one-off debugging.

## Parallel work without merge headaches

Every new session can spin up its own git branch and isolated worktree under Application Support. Run three agents on three features at the same time — no stepped-on files, no conflicting commits. A dedicated **Merge** toolbar action lands the work back to the source branch, with configurable keep-or-discard for the worktree and branch.

## GitHub, end to end

- **Issue board** with Open/Closed columns, sub-issue progress, dependency tracking, and cross-repo search.
- **Issue-to-session** in one click: title, body, labels, and comments are loaded as context, and a session starts pre-configured to work on it.
- **GitHub auth** via the `gh` CLI or native OAuth, with connection status and avatar in the toolbar.

## Subagents

Parent sessions stay orchestration-first. They delegate scoped work — exploration, planning, implementation, review — to native subagents the app launches and tracks directly.

- **Bundled starter pack:** `explorer`, `planner`, `reviewer`. Override or replace any of them.
- **Summary cards** in the transcript with per-agent status, tokens, and duration.
- **Supervisor request cards** render native macOS decision UIs when a child needs human guidance.
- **Worktree isolation** for write-capable subagents — multiple writers won't clobber each other.
- **Parallel agent graphs** via `managed_subagent` and `managed_parallel`.

## Agents, skills, prompts, and commands

Agents, skills, prompts, and slash commands — all in a sidebar, all browsable, all toggleable. Build them once, then assign them per-project or globally.

- **Skills** import from any folder, GitHub repo, or skills.sh URL via a blobless sparse clone. Agent Deck writes AI-generated summaries on import so you know what unfamiliar skills actually do before you enable them. Sync upstream and resolve conflicts with a Keep Mine / Take Remote sheet.
- **Prompts** are reusable starting points; pick one and a session opens with it preloaded.
- **Agents** carry name, description, system prompt overrides, tool restrictions, model overrides, thinking level, and a generated avatar. Importable and exportable.
- **Commands** — bundled and user-imported TypeScript slash commands injected into sessions.

## Agents that remember

Per-project memory captures decisions, runbooks, architecture, and prior failures — written by the agent during sessions via the `agent_deck_memory_write` tool, stored as Markdown, and injected back into future sessions within a budget you control. Outdated memories get marked **stale**, not deleted; you stay in audit.

Secret-scanning blocks memory writes that look like private keys, GitHub tokens, AWS keys, or `password=`/`token=`/`secret=` assignments.

## Automations powered by Apple Foundation Models

The boring parts done locally and for free:

- **Session titles** drafted as you go.
- **Commit messages** generated from staged diffs, with a one-click Commit / Push / Commit & Push toolbar.
- **Avatar prompts** for the Image Playground.
- **Skill summaries** during import.

Each automation has its own model picker — use the on-device Foundation Model where it makes sense, drop down to a cloud model when you need more.

## Models, providers, environment

Auto-discover models from configured Pi providers. Group by provider. Set defaults, per-agent, and per-session overrides. Hide noisy unused entries. Opt eligible OpenAI models into priority service tier with a bundled extension.

The **Environment** view manages `.env` files across scopes with secret masking — never modifying bundled resources.

## Health and setup

The **Doctor** runs health checks on the Pi CLI, version, path resolution, and required env keys, with auto-fix suggestions. A 6-page welcome tour and a step-by-step setup wizard get you from zero to first session in minutes.

## Screenshots

### Models and providers

![Agent Deck models view](docs/readme-images/models.png)

### Skills and subagent assignment

![Agent Deck skills view](docs/readme-images/skills.png)

### Agent definitions

![Agent Deck agents view](docs/readme-images/agents.png)

## Documentation

In-depth docs live in [`agent-deck-documentation/`](agent-deck-documentation/):

- [System prompt logic](agent-deck-documentation/agent-deck-system-prompt-logic.md) — how Agent Deck's launch flags compose with Pi's prompt assembly.
- [Pi RPC launch flags](agent-deck-documentation/pi-rpc-launch-flags.md) — the full surface of subprocess context.
- [Skills](agent-deck-documentation/skills-logic.md) and [model & thinking](agent-deck-documentation/model-and-thinking-logic.md) reference.
- [Memory](agent-deck-documentation/memory.md) design.
- [Resource refresh and file watching](agent-deck-documentation/resource-refresh-and-file-watching.md).
- Conceptual docs under [`concepts/`](agent-deck-documentation/concepts/), [`reference/`](agent-deck-documentation/reference/), and [`contributors/`](agent-deck-documentation/contributors/).

Contributor invariants and UI conventions live in [`docs/agent-guidelines/`](docs/agent-guidelines/).

## Requirements

- macOS 26 (Tahoe) on Apple Silicon
- A working install of the Pi CLI (the install script and onboarding both set it up for you)
- Xcode 26.4+ only if you build from source

## Contributing

Build from source:

```bash
git clone https://github.com/a-streetcoder/agent-deck.git
cd agent-deck
open agent-deck.xcodeproj
```

Then build the `agent-deck` scheme from Xcode 26.4+. Or from the command line:

```bash
xcodebuild -project agent-deck.xcodeproj -scheme agent-deck \
  -configuration Debug -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO build
```

Contributor invariants and UI conventions live in [`docs/agent-guidelines/`](docs/agent-guidelines/).

## License

MIT License. See [`LICENSE`](LICENSE).
