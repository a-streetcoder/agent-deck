# pi-subagents System Reference

This document explains how `pi-subagents` works in practice for this machine and how Pi discovers agents, chains, skills, tools, extensions, and related configuration. It is intended as a build/reference document for a future agent-manager app.

## Installed packages in this setup

Current relevant packages/extensions:
- `npm:pi-subagents`
- `npm:pi-web-access`
- local extension: `/Users/andrea/.pi/agent/extensions/ask-user`
- local extension: `/Users/andrea/.pi/agent/extensions/pi-dotenv`

## Global vs project map

This is the most important filesystem map for understanding what Pi and `pi-subagents` can discover.

### Agents
- builtin package agents:
  - `/opt/homebrew/lib/node_modules/pi-subagents/agents/`
- global/user custom agents:
  - `~/.pi/agent/agents/`
- project custom agents:
  - `.pi/agents/`
- legacy project agents:
  - `.agents/`

### Chains
- global/user chains:
  - `~/.pi/agent/agents/*.chain.md`
- project chains:
  - `.pi/agents/*.chain.md`
- legacy project chains:
  - `.agents/*.chain.md`

### Builtin override settings
- global/user override settings:
  - `~/.pi/agent/settings.json`
- project override settings:
  - `.pi/settings.json`

### Skills
- global/user skills:
  - `~/.pi/agent/skills/`
  - `~/.agents/skills/`
- project skills:
  - `.pi/skills/`

### Environment files
- global/user env:
  - `~/.pi/agent/.env`
- project env:
  - `.pi/.env`

### MCP configuration
- global/user Pi MCP config:
  - `~/.pi/agent/mcp.json`
- project-local shared MCP config:
  - `.mcp.json`
- project-local Pi MCP config:
  - `.pi/mcp.json`

### Package settings / package-provided resources
- global/user Pi settings:
  - `~/.pi/agent/settings.json`
- project Pi settings:
  - `.pi/settings.json`
- package-provided resources may also come from installed packages via `package.json -> pi.*`

## Core mental model

`pi-subagents` gives the main Pi session a `subagent` tool.

The main Pi session is the parent/orchestrator. It can:
- run one child agent
- run a sequential chain
- run parallel tasks
- run jobs in foreground or background
- manage agent and chain definitions

Builtin agents ship with `pi-subagents`, but user and project agents can override or replace them.

## Two different kinds of context

These are easy to confuse.

### Prompt context inheritance
Controlled by agent fields such as:
- `inheritProjectContext`
- `inheritSkills`

This changes what prompt sections the child receives before it starts.

### Session forking
Controlled at run time with:
- `context: "fork"`

This creates a branched child session from the parent session history.
It is **not** the same thing as inheriting project instruction files.

Short version:
- `inheritProjectContext` = keep project instruction text like `AGENTS.md`
- `context: "fork"` = keep branched conversation history

## Builtin agents

Builtin agent files live here:

`/opt/homebrew/lib/node_modules/pi-subagents/agents/`

Current builtin agents:
- `scout.md`
- `researcher.md`
- `planner.md`
- `worker.md`
- `reviewer.md`
- `context-builder.md`
- `oracle.md`
- `delegate.md`

These files are the source of truth for builtin frontmatter and prompts.

## Agent discovery

Agents are markdown files with YAML frontmatter plus a prompt body.

### Agent scope map

| Scope | Purpose | Path |
|---|---|---|
| Builtin | Package-shipped defaults | `/opt/homebrew/lib/node_modules/pi-subagents/agents/` |
| Global / user | Available everywhere for this user | `~/.pi/agent/agents/` |
| Project | Available only in the current repo/project | `.pi/agents/` |
| Legacy project | Older compatibility path | `.agents/` |

Discovery paths, lowest to highest priority:

1. Builtin
   - `~/.pi/agent/extensions/subagent/agents/` in docs
   - on this machine the installed builtin files are under:
     - `/opt/homebrew/lib/node_modules/pi-subagents/agents/`
2. User
   - `~/.pi/agent/agents/{name}.md`
3. Project
   - `.pi/agents/{name}.md`
4. Legacy project path also supported
   - `.agents/{name}.md`

If both `.agents/` and `.pi/agents/` define the same project agent, `.pi/agents/` wins.

### Effective priority
- builtin < user < project

That means:
- a user agent can replace a builtin by using the same `name`
- a project agent can replace a user or builtin agent by using the same `name`

## Chain discovery

Saved chains are `.chain.md` files.

### Chain scope map

| Scope | Path |
|---|---|
| Global / user | `~/.pi/agent/agents/{name}.chain.md` |
| Project | `.pi/agents/{name}.chain.md` |
| Legacy project | `.agents/{name}.chain.md` |

Discovery paths:
- `~/.pi/agent/agents/{name}.chain.md`
- `.pi/agents/{name}.chain.md`
- legacy: `.agents/{name}.chain.md`

Project chains win over user chains on name collision.

## Chain step behavior

Each chain step can override some of the agent's defaults.

Important rules:
- `output`: step override wins over agent default output
- `reads`: step override wins over agent `defaultReads`
- `progress`: step override wins over agent `defaultProgress`
- `skills`: step override wins over agent skills for that step
- `model`: step override wins over agent model for that step

Important `false` semantics:
- `output: false` = explicitly disable output for that step
- `reads: false` = explicitly disable reads for that step
- `skills: false` = explicitly disable skills for that step

Relative chain read/write paths resolve from the chain working directory.

## Builtin overrides

Builtin agents can also be patched without replacing their files.

Override locations:
- user scope: `~/.pi/agent/settings.json`
- project scope: `.pi/settings.json`

JSON shape:

```json
{
  "subagents": {
    "agentOverrides": {
      "reviewer": {
        "model": "anthropic/claude-sonnet-4",
        "thinking": "high",
        "inheritProjectContext": true
      }
    }
  }
}
```

Supported builtin override fields:
- `model`
- `fallbackModels`
- `thinking`
- `systemPromptMode`
- `inheritProjectContext`
- `inheritSkills`
- `disabled`
- `skills`
- `tools`
- `systemPrompt`

Important:
- a builtin override is a settings patch, not a new agent file
- package updates overwrite builtin files, but not overrides in settings

## Agent file format

Agents are markdown files with frontmatter like:

```md
---
name: scout
description: Fast codebase recon
tools: read, grep, find, ls, bash
model: anthropic/claude-sonnet-4-5
fallbackModels: openai/gpt-5-mini
thinking: medium
systemPromptMode: replace
inheritProjectContext: true
inheritSkills: false
skills: apple-documentation
extensions:
output: context.md
defaultReads: context.md
defaultProgress: true
maxSubagentDepth: 1
---
You are a scouting subagent...
```

## Meaning of important agent fields

### `name`
The agent identifier.

### `description`
Short human-facing summary.

### `tools`
Builtin tool allowlist.

Rules:
- if omitted, the child gets Pi's normal builtin tools
- if present, it becomes an explicit builtin tool allowlist
- entries like `mcp:chrome-devtools` select direct MCP tools
- path-like tool entries can be interpreted as extension/tool paths

Plain English:
- omitted `tools` means "normal Pi defaults"
- specified `tools` means "only these regular tools"
- `mcp:` entries are separate direct MCP tool names and only make sense if that MCP server exists

### `model`
Default model for this agent.

### `fallbackModels`
Backup models for provider/model failures such as quota/auth/unavailable model.

### `thinking`
Default reasoning level.

### `systemPromptMode`
How the child prompt is assembled:
- `replace` = use the agent prompt instead of Pi's usual base system prompt
- `append` = keep Pi's base prompt and append the agent prompt

Plain English:
- `replace` makes a tighter specialist
- `append` makes the child behave more like normal Pi plus extra instructions
- builtin `delegate` defaults to `append`; most other builtins default to `replace`

### `inheritProjectContext`
Whether to keep Pi's **project-context prompt section** in the child.

Plain English:
- this keeps instructions loaded from files like `AGENTS.md` or `CLAUDE.md`
- this is **prompt context**, not the full parent session history
- turning it off strips that project-instructions section before the child starts

### `inheritSkills`
Whether to keep Pi's discovered skills catalog in the child prompt.

Plain English:
- this keeps the generated skills section in the child prompt
- it does **not** mean "give the child every skill on disk regardless of scope"
- global skills stay global; project skills are still only visible inside their project

### `skills`
Explicitly inject specific skills into the child prompt.

### `extensions`
Controls extension loading for the child.

Semantics:
- field omitted = normal extensions load
- empty field = no extensions
- comma-separated values = explicit allowlist

### `output`
Default output file for the agent.

### `defaultReads`
Files the child should read before execution in chain/parallel behavior.

### `defaultProgress`
Whether to maintain `progress.md`.

### `interactive`
Parsed for compatibility but not meaningfully enforced in v1.

### `maxSubagentDepth`
Restricts nested delegation depth.

## Prompt assembly defaults

For custom agents, the important defaults are:
- `systemPromptMode`: usually `replace`
- `inheritProjectContext`: usually `false` unless explicitly set
- `inheritSkills`: usually `false`

Builtin agents are different:
- they generally opt into `inheritProjectContext: true`
- `delegate` also uses `systemPromptMode: append`

## Skills: discovery and loading

Skills are separate from agents.

A skill is typically a folder containing `SKILL.md`.

### Skill scope map

| Scope | Purpose | Path |
|---|---|---|
| Global / user | User-owned Pi skill directory | `~/.pi/agent/skills/{name}/SKILL.md` |
| Global / user | Additional user skill library used on this machine | `~/.agents/skills/{name}/SKILL.md` |
| Project | Project-local skills | `.pi/skills/{name}/SKILL.md` |

### Direct skill folder patterns
Common locations:
- global/user skills:
  - `~/.pi/agent/skills/{name}/SKILL.md`
  - `~/.agents/skills/{name}/SKILL.md`
- project skills:
  - `.pi/skills/{name}/SKILL.md`

### Discovery precedence from pi-subagents docs
Skills are discovered with project-first precedence through a combination of direct folders, packages, and settings. The documented order is:

1. `.pi/skills/{name}/SKILL.md`
2. Project packages and project settings packages via `package.json -> pi.skills`
3. Current task cwd package via `package.json -> pi.skills`
4. `.pi/settings.json -> skills`
5. `~/.pi/agent/skills/{name}/SKILL.md`
6. User packages and user settings packages via `package.json -> pi.skills`
7. `~/.pi/agent/settings.json -> skills`

On this machine there is also a heavily used extra user skill library under:
- `~/.agents/skills/`

For app design, it is safest to model skill sources as these categories:
- project direct skills
- project package-provided skills
- global direct skills
- global package-provided skills
- extra user skill libraries such as `~/.agents/skills/`

### How skills are used by agents
A child agent can receive skills in two ways:

1. Explicit `skills:` in the agent frontmatter
2. Ambient skill catalog inheritance via `inheritSkills: true`

Recommended design rule:
- narrow specialist agents should usually use `inheritSkills: false`
- assign only the specific skills they truly need

## Extensions: inheritance and restriction

Subagents are child Pi processes.

Extension behavior:
- if `extensions` is omitted, the child gets the normal extension set
- if `extensions:` is empty, the child gets no extensions
- if `extensions:` is an allowlist, only those extensions load

Important distinction:
- `extensions` controls what extension code is loaded
- `tools` controls what tools are allowed/visible

## Environment inheritance

Subagents are spawned from the parent Pi process and inherit the parent environment.

Practical consequences:
- `PATH` is inherited
- CLI availability is usually inherited
- environment variables are usually inherited

There is no standard normal per-agent `env:` frontmatter field.

So if a child agent needs a CLI or credential:
- it must already be available in the parent Pi environment
- or be loaded by something like `pi-dotenv`

## pi-dotenv in this setup

Local extension:
- `/Users/andrea/.pi/agent/extensions/pi-dotenv`

It loads env files into the running Pi process from:
- global: `~/.pi/agent/.env`
- project: `.pi/.env`

Project values override global values.

Because subagents inherit the parent environment, env vars loaded by `pi-dotenv` are generally visible to subagents too.

## Web tools in this setup

`pi-web-access` is installed.

Installed package:
- `/opt/homebrew/lib/node_modules/pi-web-access`

It provides tools such as:
- `web_search`
- `fetch_content`
- `get_search_content`
- `code_search`

### Provider behavior
`web_search` defaults to `provider: "auto"`.

Search fallback order in auto mode:
1. Exa
   - direct API if `EXA_API_KEY` or config key exists
   - otherwise Exa MCP if available
2. Perplexity
3. Gemini API
4. Gemini Web

### Important env names used by pi-web-access
It reads these env vars directly:
- `EXA_API_KEY`
- `GEMINI_API_KEY`
- `PERPLEXITY_API_KEY`

In this setup, these can be supplied by `pi-dotenv`.

## MCP behavior

Subagents do not magically get all MCP power without configuration.

In practice:
- direct MCP tools are usually selected with `mcp:...` entries in `tools`
- MCP access depends on installed MCP-related extensions and configuration
- child behavior can also be constrained by the `extensions` field

## Foreground, background, chain, parallel

The `subagent` tool supports:
- single agent runs
- sequential chains
- parallel runs
- background/async runs

### Chains
Chain task templates can use:
- `{task}` = original task
- `{previous}` = previous step output
- `{chain_dir}` = shared artifacts directory

### Parallel runs
Parallel runs can execute multiple agents/tasks.

If editing agents run in parallel, `worktree: true` can isolate them in separate git worktrees.

## Where users can browse/edit agents today

### Builtin and custom agents UI
Pi command:
- `/agents`

This is the current built-in manager surface for browsing agents and chains and editing builtin overrides.

### Filesystem editing
Agents and chains can also be edited directly in the discovery paths above.

## Which pieces are best treated as source of truth for an app

For a native agent-manager app, the most important sources of truth are:

### Global/user scope
- agents: `~/.pi/agent/agents/`
- chains: `~/.pi/agent/agents/*.chain.md`
- skill directories: `~/.pi/agent/skills/`, `~/.agents/skills/`
- settings: `~/.pi/agent/settings.json`
- env: `~/.pi/agent/.env`
- MCP config: `~/.pi/agent/mcp.json`

### Project scope
- agents: `.pi/agents/`
- legacy agents: `.agents/`
- chains: `.pi/agents/*.chain.md`, legacy `.agents/*.chain.md`
- skills: `.pi/skills/`
- settings: `.pi/settings.json`
- env: `.pi/.env`
- MCP config: `.pi/mcp.json`, plus shared `.mcp.json`

### Builtin/package scope
- builtin agents: `/opt/homebrew/lib/node_modules/pi-subagents/agents/*.md`
- installed package resources exposed through package manifests (`package.json -> pi.*`)

### Builtin definitions
- `/opt/homebrew/lib/node_modules/pi-subagents/agents/*.md`

### User custom agents and chains
- `~/.pi/agent/agents/`

### Project custom agents and chains
- `.pi/agents/`
- legacy `.agents/`

### Builtin overrides
- `~/.pi/agent/settings.json`
- `.pi/settings.json`

### Skills
- `.pi/skills/`
- `~/.pi/agent/skills/`
- `~/.agents/skills/`
- package-exposed skills from `package.json -> pi.skills`

### Global env used by Pi/subagents
- `~/.pi/agent/.env`

### Project env used by Pi/subagents
- `.pi/.env`

## Practical recommendations for an agent-manager app

The app should probably distinguish clearly between:
- builtin agent file
- effective builtin agent after override patch
- custom user agent
- custom project agent
- saved chain
- skill catalog entries
- explicit agent-assigned skills vs inherited skills
- loaded extensions vs allowed tools

It should also expose precedence clearly:
- builtin < user < project
- builtin + override patch for effective builtin state
- project overrides beat user overrides in settings

## Summary

`pi-subagents` is a layered system:
- builtin agents from the package
- user/project agent files that can override them by name
- builtin overrides from settings for lightweight patching
- saved chains beside agents
- skills discovered from project/user/package locations
- optional extension loading and tool allowlists
- parent-process env inheritance for CLIs and credentials

Those are the core filesystem and runtime concepts an agent-manager app should model.