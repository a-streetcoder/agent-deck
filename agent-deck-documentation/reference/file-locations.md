# File Locations Reference

This page lists the important paths Agent Deck scans or writes.

`PROJECT` means the selected project root.

## Pi and app data

| Purpose | Path |
|---|---|
| Pi global config | `~/.pi/agent/` |
| Pi global settings | `~/.pi/agent/settings.json` |
| Pi project settings | `PROJECT/.pi/settings.json` |
| Pi global env | `~/.pi/agent/.env` |
| Pi project env | `PROJECT/.pi/.env` (not managed, scanned, watched, or injected by Agent Deck) |
| Agent Deck app data | `~/Library/Application Support/Agent Deck/` |
| Agent Deck session index | `~/Library/Application Support/Agent Deck/agent-sessions.json` |
| Last-known-good session index | `~/Library/Application Support/Agent Deck/agent-sessions.backup.json` |
| Pi parent session history | `~/.pi/agent/sessions/**/<session>.jsonl` |
| Agent Deck transcript records | `~/Library/Application Support/Agent Deck/agent-session-transcripts/parent-<session-id>.json` |
| Session-owned transcript and MCP images | `~/Library/Application Support/Agent Deck/agent-session-transcripts/<parent-session-id>/images/` |
| Native subagent artifacts and child Pi sessions | `~/Library/Application Support/Agent Deck/Subagent Runs/<run-id>/` |

The session index and transcript files are app-managed. Agent Deck writes the index atomically, preserves the previously decoded generation as the last-known-good backup, and automatically uses that backup when the primary index is missing or cannot be decoded. During launch, existing project-backed sessions retain their project grouping while project discovery finishes.

## Agents

| Scope | Path |
|---|---|
| App-bundled native builtins | app bundle `bundled-agents/` |
| Global user catalog | `~/.pi/agent/agents/*.md` |
| Legacy global catalog | `~/.agents/*.md` |
| Library/catalog | `~/.pi/agent/agent-library/agents/*.md` |
| Assignment state | Agent Deck app settings/project preferences |
| Builtin overrides | Global `~/.pi/agent/settings.json -> subagents.agentOverrides` (Agent Deck does not read or write project `subagents` settings) |

Project-specific availability is controlled by Agent Deck assignment state. Agent Deck does not discover project-local `.pi/agents` or legacy project `.agents` folders as resource catalog sources.

## Skills

| Scope | Path |
|---|---|
| App-bundled skills | app bundle `bundled-skills/` |
| Global user catalog | `~/.pi/agent/skills/<skill>/SKILL.md` or root `.md` |
| Legacy global catalog | recursive `~/.agents/skills/**/SKILL.md`; root `.md` files are ignored |
| Imported/catalog references | Explicit paths stored in Agent Deck settings; imports are by reference, not copy |
| Package skills | Globally resolved package-declared `pi.skills` or conventional package `skills/` folders |
| Assignment state | Agent Deck app settings/project preferences |

Project-specific availability is controlled by Agent Deck assignment state. Agent Deck does not discover project-local `.pi/skills` or legacy project `.agents/skills` folders as resource catalog sources.

## Prompt templates

| Scope | Path |
|---|---|
| App-bundled prompts | app bundle `bundled-prompts/` |
| Global catalog | `~/.pi/agent/prompts/*.md` |
| Library/catalog | `~/.pi/agent/prompt-library/*.md` |
| Imported/catalog references | Explicit paths stored in Agent Deck settings; imports are by reference, not copy |
| Global settings/package catalog | Global `settings.json -> prompts` and globally resolved package prompt folders |
| Assignment state | Agent Deck app settings/project preferences; parent launch uses explicit `--prompt-template` arguments |

Project-specific availability is controlled by Agent Deck assignment state. Agent Deck does not discover project-local `.pi/prompts`, project settings `prompts`, or project package prompt folders as resource catalog sources.

## MCP servers

| Purpose | Path |
|---|---|
| Community/global MCP config (read-only in Agent Deck) | `~/.config/mcp/mcp.json` |
| Agent Deck writable MCP config | `~/.pi/agent/mcp.json` |
| MCP OAuth tokens, dynamic registrations, and pre-registered client settings | `~/.pi/agent/mcp-auth.json` |
| Project MCP config (read-only in Agent Deck) | `PROJECT/.mcp.json` |
| Pi project MCP config (read-only in Agent Deck) | `PROJECT/.pi/mcp.json` |
| Explicit `+` sheet import sources (read-only scan, selected servers copied into `~/.pi/agent/mcp.json`) | Claude Desktop, Claude Code, and Codex config files |

Agent Deck does not treat Claude or Codex MCP files as live discovery sources. They are scanned only when the user explicitly chooses Import in the Add MCP server sheet. Remote servers may use configured HTTP headers or OAuth; a non-empty static `Authorization` header takes precedence, while OAuth remains available when static authorization is absent. For remote servers that require a pre-registered OAuth client, the optional client ID, client secret, and scopes entered in the Add/Edit sheet are stored in `mcp-auth.json`, not `mcp.json`.

Stdio MCP servers inherit Agent Deck's process environment, with the server's configured `env` values applied as overrides. Argument strings are passed literally so the child (for example, `mcp-remote`) can expand placeholders itself. Transport diagnostics include bounded stderr when useful and redact configured authorization and secret-like environment values.

## Extensions and packages

| Purpose | Path / setting |
|---|---|
| Global auto extensions | `~/.pi/agent/extensions/*.ts`, `~/.pi/agent/extensions/*/index.ts` |
| Project auto extensions | `PROJECT/.pi/extensions/*.ts`, `PROJECT/.pi/extensions/*/index.ts` |
| Settings extensions | `settings.json -> extensions` |
| Packages | global `settings.json -> packages`; project settings packages are preserved for runtime/config uses but not used as Agent Deck skill/prompt catalog sources |
| Native bridge extensions | `~/Library/Application Support/Agent Deck/Native Subagent Extensions/managed-subagent-bridge.ts` and `contact-supervisor-bridge.ts` |
