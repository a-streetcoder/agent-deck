# User Guide: Overview

Agent Deck is a native macOS control center for Pi resources and Pi Agent workflows.

It scans the same kinds of files that Pi uses — agents, skills, prompt templates, settings, environment files, extensions, and packages — and presents them in a safer, more understandable UI.

## Main areas

The app sidebar is organized around these concepts:

### Workspace

- **Projects** — discovered local repositories and manually added project paths
- **GitHub** — issue boards, issue details, repository changes, commit/push workflows
- **Pi Agent** — native SwiftUI transcript UI backed by `pi --mode rpc`

### Pi Resources

- **Agents** — builtin, global, project, library, and overridden agents
- **Chains** — app-managed `.chain.md` workflows
- **Skills** — active and library skills, including project assignment
- **Prompts** — prompt templates and extension slash commands
- **Subagents** — subagent configuration and native-run behavior

### Runtime

- **Extensions** — local/package extensions and enable/disable state
- **Models** — available Pi models and capabilities
- **Settings** — app settings and selected Pi-related preferences
- **Environment** — global/project `.env` keys, with secret values hidden by default
- **Diagnostics** — warnings, missing tools, malformed files, package checks

### Reference

- **Docs** — in-app explanatory reference

## Core mental model

Agent Deck distinguishes between:

- **Builtin resources** shipped with the app, plus package-provided non-agent resources such as skills/prompts/extensions
- **Active global resources** visible to Pi everywhere
- **Active project resources** visible only inside a repository
- **Library resources** stored centrally by Agent Deck and activated when needed
- **Overrides** that patch builtin behavior without editing package files

See [Resource scopes and resolution](../concepts/resource-scopes-and-resolution.md) for details.

## Native Pi Agent sessions

The Pi Agent screen launches the installed `pi` CLI in RPC mode and renders the session as native SwiftUI UI. The app sends prompts, model changes, thinking controls, and extension UI responses through Pi's JSONL RPC protocol.

## Native subagents

Agent Deck has its own app-managed native subagent runner. Parent Pi Agent sessions can request child subagents, chains, or parallel runs through generated bridge tools. Agent Deck owns the child processes, artifacts, transcripts, supervisor requests, and optional worktrees.

See [Native subagents](native-subagents.md).
