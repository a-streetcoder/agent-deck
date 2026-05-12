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
| Global catalog | `~/.pi/agent/agents/*.md` |
| Legacy global catalog | `~/.agents/*.md` |
| Library/catalog | `~/.pi/agent/agent-library/agents/*.md` |
| Project catalog | `PROJECT/.pi/agents/*.md` |
| Legacy project catalog | `PROJECT/.agents/*.md` |
| Assignment state | Agent Deck app settings/project preferences |
| Builtin overrides | `settings.json -> subagents.agentOverrides` |

## Chains

| Scope | Path |
|---|---|
| Global active | `~/.pi/agent/chains/*.chain.md` |
| Library | `~/.pi/agent/agent-library/chains/*.chain.md` |
| Project active | `PROJECT/.pi/chains/*.chain.md` |

## Skills

| Scope | Path |
|---|---|
| Global active | `~/.pi/agent/skills/<skill>/SKILL.md` or root `.md` |
| Legacy global | recursive `~/.agents/skills/**/SKILL.md`; root `.md` files are ignored |
| Project active | `PROJECT/.pi/skills/<skill>/SKILL.md` or root `.md` |
| Legacy project | recursive `PROJECT/.agents/skills/**/SKILL.md` from cwd/ancestors; root `.md` files are ignored |
| Package/settings | package manifest/conventional paths and `settings.json -> skills` |

## Prompt templates

| Scope | Path |
|---|---|
| Global catalog | `~/.pi/agent/prompts/*.md` |
| Library/catalog | `~/.pi/agent/prompt-library/*.md` |
| Project catalog | `PROJECT/.pi/prompts/*.md` |
| Package/settings catalog | package prompt folders and `settings.json -> prompts` |
| Assignment state | Agent Deck app settings/project preferences; parent launch uses explicit `--prompt-template` arguments |

## Extensions and packages

| Purpose | Path / setting |
|---|---|
| Global auto extensions | `~/.pi/agent/extensions/*.ts`, `~/.pi/agent/extensions/*/index.ts` |
| Project auto extensions | `PROJECT/.pi/extensions/*.ts`, `PROJECT/.pi/extensions/*/index.ts` |
| Settings extensions | `settings.json -> extensions` |
| Packages | `settings.json -> packages` |
| Native bridge extensions | `~/Library/Application Support/Agent Deck/Native Subagent Extensions/managed-subagent-bridge.ts` and `contact-supervisor-bridge.ts` |
