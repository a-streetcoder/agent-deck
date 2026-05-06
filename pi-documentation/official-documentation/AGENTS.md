# AGENTS.md for Pi Manager Documentation

This file is for LLM agents and agentic coding tools working on Pi Manager.

## Project purpose

Pi Manager is a native macOS SwiftUI app for managing the real resources used by the Pi coding agent and for running Pi Agent/native subagent workflows through Pi RPC.

## Required mental models

- Pi Manager launches the installed `pi` CLI; it is not Pi core.
- Native subagents are app-managed child Pi RPC sessions, not the old package `/run` flow.
- Library resources are storage only until linked/assigned into active global or project paths.
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
xcodebuild -project pi-manager.xcodeproj -target pi-manager -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```
