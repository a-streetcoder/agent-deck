# Agent Deck Official Documentation

Agent Deck is a native macOS app for browsing, understanding, editing, and running the real resources used by the Pi coding agent. It is designed for Pi users, project maintainers, and LLM agents that need a reliable map of how the app works.

This documentation is intentionally modular. Start with [`index.md`](index.md), then follow the user guide, concepts, reference, or contributor sections depending on what you need.

## What Agent Deck manages

Agent Deck helps you work with:

- local projects and GitHub issues
- Pi agents, chains, skills, prompt templates, commands, extensions, models, settings, and environment files
- in-app Pi Agent sessions through Pi's JSONL RPC mode
- app-managed native subagents, chains, parallel runs, artifacts, worktrees, and supervisor requests

Agent Deck is **not** a replacement for Pi itself. It launches the installed `pi` CLI and manages the files, settings, and run metadata around it.

## Documentation map

- [`getting-started/build-from-source.md`](getting-started/build-from-source.md) — build and run the app from source
- [`user-guide/overview.md`](user-guide/overview.md) — app tour and first mental model
- [`concepts/resource-scopes-and-resolution.md`](concepts/resource-scopes-and-resolution.md) — global/project/library/builtin behavior
- [`user-guide/native-subagents.md`](user-guide/native-subagents.md) — app-managed native subagents
- [`reference/file-locations.md`](reference/file-locations.md) — exact files and directories Agent Deck scans/writes
- [`contributors/architecture.md`](contributors/architecture.md) — source architecture and data flow
- [`contributors/llm-contributor-guide.md`](contributors/llm-contributor-guide.md) — instructions for LLM agents modifying this repo

## Safety principle

Agent Deck should make write targets explicit. Read-only builtin files are not edited in place. Native subagent runs default to app artifacts unless a project-file or worktree/direct-write outcome is explicitly selected.
