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
| Pi project env | `PROJECT/.pi/.env` |
| Agent Deck app data | `~/Library/Application Support/Agent Deck/` |
| Native subagent artifacts | `~/Library/Application Support/Agent Deck/Subagent Runs/<run-id>/` |

## Agents

| Scope | Path |
|---|---|
| App-bundled native builtins | app bundle `bundled-agents/` |
| Global user catalog | `~/.pi/agent/agents/*.md` |
| Legacy global catalog | `~/.agents/*.md` |
| Library/catalog | `~/.pi/agent/agent-library/agents/*.md` |
| Assignment state | Agent Deck app settings/project preferences |
| Builtin overrides | `settings.json -> subagents.agentOverrides` |

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
| Project MCP config (read-only in Agent Deck) | `PROJECT/.mcp.json` |
| Pi project MCP config (read-only in Agent Deck) | `PROJECT/.pi/mcp.json` |
| Explicit `+` sheet import sources (read-only scan, selected servers copied into `~/.pi/agent/mcp.json`) | Claude Desktop, Claude Code, and Codex config files |

Agent Deck does not treat Claude or Codex MCP files as live discovery sources. They are scanned only when the user explicitly chooses Import in the Add MCP server sheet.

## Extensions and packages

| Purpose | Path / setting |
|---|---|
| Global auto extensions | `~/.pi/agent/extensions/*.ts`, `~/.pi/agent/extensions/*/index.ts` |
| Project auto extensions | `PROJECT/.pi/extensions/*.ts`, `PROJECT/.pi/extensions/*/index.ts` |
| Settings extensions | `settings.json -> extensions` |
| Packages | global `settings.json -> packages`; project settings packages are preserved for runtime/config uses but not used as Agent Deck skill/prompt catalog sources |
| Native bridge extensions | `~/Library/Application Support/Agent Deck/Native Subagent Extensions/managed-subagent-bridge.ts` and `contact-supervisor-bridge.ts` |
