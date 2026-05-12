# AGENTS.md for Agent Deck Documentation

This file is for LLM agents and agentic coding tools working on Agent Deck.

## Project purpose

Agent Deck is a native macOS SwiftUI app for managing the real resources used by the Pi coding agent and for running Pi Agent/native subagent workflows through Pi RPC.

## Required mental models

- Agent Deck launches the installed `pi` CLI; it is not Pi core.
- Native subagents are app-managed child Pi RPC sessions, not raw slash-command delegation.
- Agent/skill/prompt files are catalog entries; Agent Deck stores default/project assignments separately.
- Builtin resources are read-only; use overrides or replacements.
- Report-only native subagent runs write artifacts, not project files.

## Read-before-edit map

- Architecture: `contributors/architecture.md`
- Source map: `contributors/source-map.md`
- LLM guide: `contributors/llm-contributor-guide.md`
- Resource behavior: `concepts/resource-scopes-and-resolution.md`, `reference/file-locations.md`
- Native subagents: `user-guide/native-subagents.md`, `reference/native-subagent-bridge.md`

## Validation command

```bash
xcodebuild -project agent-deck.xcodeproj -target agent-deck -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```
