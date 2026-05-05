# Pi Core System Reference

This is the unified reference for how Pi works in normal sessions and in `pi-subagents` child sessions.

It replaces the older split between:
- `pi-instructions-normal-vs-subagents.md`
- `pi-subagents-system-reference.md`

Use this file as the main source of truth for:
- Pi core prompt assembly
- normal-session behavior
- package `pi-subagents` behavior
- Pi Manager native subagent integration points
- discovery rules for agents, chains, skills, prompts, and related files
- machine-specific setup notes that affect this repository's Pi usage

Companion references:
- `pi-skills-discovery.md` for the dedicated skills discovery breakdown, including global vs project lookup rules and `.pi` vs `.agents` behavior
- `pi-manager-resource-management.md` for the app-specific library/symlink model Pi Manager uses for agents, chains, skills, and prompts

---

## Scope of this document

Important: this file is mostly about **Pi runtime behavior** and `pi-subagents` runtime behavior.
If you are asking "what does the Pi Manager app itself store, move, symlink, and surface?", read `pi-manager-resource-management.md` first.

This document separates three layers that are easy to mix together:

1. **Pi core behavior**
   - system prompt assembly
   - context files
   - skills discovery
   - prompt templates
   - extensions
   - session behavior
2. **`pi-subagents` behavior**
   - agent discovery
   - builtin overrides
   - chains
   - parallel runs
   - forked child sessions
   - worktrees
3. **Pi Manager native subagent behavior**
   - app-owned child Pi RPC sessions
   - managed parent bridge tools
   - child supervisor communication
   - app-persisted artifacts, transcripts, worktrees, chains, and parallel graphs
4. **This machine's setup**
   - installed packages
   - extra skill libraries
   - dotenv behavior
   - MCP config conventions

---

## Installed packages in this setup

Current relevant packages/extensions:
- `npm:pi-subagents`
- `npm:pi-web-access`
- local extension: `/Users/andrea/.pi/agent/extensions/ask-user`
- local extension: `/Users/andrea/.pi/agent/extensions/pi-dotenv`

---

## Fast mental model

### Normal Pi session
A normal Pi session:
1. builds a base system prompt
2. optionally appends `APPEND_SYSTEM.md`
3. appends project context and skills
4. adds date/cwd
5. lets extensions modify behavior per turn
6. persists message history in a session file

### Package `pi-subagents` child session
A package-managed subagent is a new child Pi session.
It:
1. starts a child Pi process
2. builds a Pi prompt stack for that child
3. applies agent-definition rules like `systemPromptMode`, `inheritProjectContext`, `inheritSkills`, `tools`, and `extensions`
4. optionally forks parent session history with `context: "fork"`
5. runs with its own session, output, and orchestration rules

### Pi Manager native child session
A Pi Manager native subagent is also a child Pi session, but the app owns the lifecycle directly through Pi RPC:
1. Pi Manager creates a run record and artifact directory
2. starts a child `PiRPCClient` in the parent project or isolated worktree
3. passes native boundary instructions, the agent prompt, and explicit private skill blocks as system prompt content
4. sends expected outcome, read-first paths, artifact directory, and task as the user task prompt
5. streams child events into app-persisted transcripts and status records
6. writes the final child response to app artifacts and posts a compact result back to the parent transcript

So a subagent is **not** just “the parent prompt plus one extra instruction”. Native Pi Manager runs are also not raw `/run` text inserted into the parent chat.

---

## Filesystem map: what Pi and pi-subagents can discover

### Agents
- builtin package agents:
  - `/opt/homebrew/lib/node_modules/pi-subagents/agents/`
- global/user custom agents:
  - `~/.pi/agent/agents/`
  - `~/.agents/`
- project custom agents:
  - nearest ancestor `.pi/agents/`
- legacy project agents:
  - nearest ancestor `.agents/`

### Chains
- global/user chains:
  - `~/.pi/agent/agents/*.chain.md`
  - `~/.agents/*.chain.md`
- project chains:
  - nearest ancestor `.pi/agents/*.chain.md`
- legacy project chains:
  - nearest ancestor `.agents/*.chain.md`

### Builtin override settings
- global/user override settings:
  - `~/.pi/agent/settings.json`
- project override settings:
  - nearest ancestor `.pi/settings.json`

Project-scope note for `pi-subagents`:
- for agents, chains, and `.pi/settings.json` overrides, the project root is the **nearest ancestor containing `.pi` or `.agents`**
- this is not derived from git-root detection

### Skills
- global/user skills:
  - `~/.pi/agent/skills/`
  - `~/.agents/skills/`
- project skills:
  - `.pi/skills/`
  - `.agents/skills/` in `cwd` and ancestor directories up to git repo root, or filesystem root when not in a repo
- dedicated reference:
  - `pi-skills-discovery.md`

### Prompt templates
- global:
  - `~/.pi/agent/prompts/*.md`
- project:
  - `.pi/prompts/*.md`
- packages/settings/CLI can contribute additional prompt-template paths

### Context files
- global:
  - `~/.pi/agent/AGENTS.md`
  - or `~/.pi/agent/CLAUDE.md`
- project/ancestor discovery:
  - `AGENTS.md` or `CLAUDE.md` in parent directories and `cwd`

Pi prefers `AGENTS.md` over `CLAUDE.md` within the same directory.
Discovery can be disabled with `--no-context-files`.

### System-prompt files
- `cwd/.pi/SYSTEM.md`
- `cwd/.pi/APPEND_SYSTEM.md`
- global `~/.pi/agent/SYSTEM.md`
- global `~/.pi/agent/APPEND_SYSTEM.md`

Important:
- Pi does **not** walk ancestor directories for `SYSTEM.md` or `APPEND_SYSTEM.md`
- it does walk ancestor directories for `AGENTS.md` / `CLAUDE.md`

### Environment files in this setup
These are **not** a built-in `pi-subagents` feature. They matter here because `pi-dotenv` is installed.

- global/user env:
  - `~/.pi/agent/.env`
- project env:
  - `.pi/.env`

### MCP configuration
These are Pi/MCP config locations, not special `pi-subagents` files.

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

---

## Pi core: how the base system prompt is assembled

This applies to a normal Pi session and to every subagent child session underneath.

### Base assembly order

Pi rebuilds its base system prompt from current resources/settings. The effective order is:

1. **Base prompt source**
   - `--system-prompt <text>` or SDK override, if supplied
   - else `cwd/.pi/SYSTEM.md`
   - else global `~/.pi/agent/SYSTEM.md`
   - else Pi's built-in default prompt
2. **Tool-aware guidance**
   - only when Pi is using the built-in default prompt
   - active tools can add one-line tool snippets and guideline bullets
3. **Append system prompt text**
   - `--append-system-prompt <text>` / SDK append(s), if supplied
   - else `cwd/.pi/APPEND_SYSTEM.md`
   - else global `~/.pi/agent/APPEND_SYSTEM.md`
4. **Context files**
   - global `~/.pi/agent/AGENTS.md` or `CLAUDE.md`
   - then parent dirs up to `/`
   - then `cwd`
   - in one directory Pi prefers `AGENTS.md`, else `CLAUDE.md`
5. **Skills listing**
   - appended only when the `read` tool is available
   - full `SKILL.md` contents are not inlined; only the listing is
6. **Date and working directory**

### `SYSTEM.md` vs `AGENTS.md`

This is the most important distinction.

#### `SYSTEM.md`
Use for top-level assistant behavior:
- replacing Pi's built-in system prompt
- hard behavioral rules
- tool-use policy
- style constraints
- durable operating instructions

#### `APPEND_SYSTEM.md`
Use for:
- appending extra system-level rules on top of Pi's default or custom system prompt

#### `AGENTS.md` / `CLAUDE.md`
Use for:
- repo conventions
- workflow rules
- preferred commands
- architecture notes
- team practices
- domain context

Important:
- `AGENTS.md` / `CLAUDE.md` add **project context**
- they do **not** replace the system prompt

### Real example: Pi's built-in default system instruction

This is the real built-in default prompt shape from `@mariozechner/pi-coding-agent/dist/core/system-prompt.js` when Pi is **not** using a custom `SYSTEM.md`.
The exact tool list and guideline bullets depend on active tools, but the base text is:

```text
You are an expert coding assistant operating inside pi, a coding agent harness. You help users by reading files, executing commands, editing code, and writing new files.

Available tools:
${toolsList}

In addition to the tools above, you may have access to other custom tools depending on the project.

Guidelines:
${guidelines}

Pi documentation (read only when the user asks about pi itself, its SDK, extensions, themes, skills, or TUI):
- Main documentation: ${readmePath}
- Additional docs: ${docsPath}
- Examples: ${examplesPath} (extensions, custom tools, SDK)
- When asked about: extensions (docs/extensions.md, examples/extensions/), themes (docs/themes.md), skills (docs/skills.md), prompt templates (docs/prompt-templates.md), TUI components (docs/tui.md), keybindings (docs/keybindings.md), SDK integrations (docs/sdk.md), custom providers (docs/custom-provider.md), adding models (docs/models.md), pi packages (docs/packages.md)
- When working on pi topics, read the docs and examples, and follow .md cross-references before implementing
- Always read pi .md files completely and follow links to related docs (e.g., tui.md for TUI API details)
```

When the built-in default prompt is used, Pi also injects tool-derived guidance such as:
- `Use bash for file operations like ls, rg, find`
- `Be concise in your responses`
- `Show file paths clearly when working with files`

### Practical rule of thumb

- `SYSTEM.md` = “what assistant are you?”
- `APPEND_SYSTEM.md` = “what extra top-level rules should you follow?”
- `AGENTS.md` = “what should you know about this repo/workflow?”

---

## Pi core: skills

### Discovery locations
Pi loads skills from:
- Global:
  - `~/.pi/agent/skills/`
  - `~/.agents/skills/`
- Project:
  - `.pi/skills/`
  - `.agents/skills/` in `cwd` and ancestor directories (up to git repo root, or filesystem root when not in a repo)
- Packages:
  - conventional `skills/` directories
  - or `package.json -> pi.skills`
- Extensions:
  - `resources_discover` can contribute `skillPaths`
- Settings:
  - `skills` array with files or directories
- CLI:
  - `--skill <path>`

### Important behavior
- Pi adds only a skill listing to the prompt, not full skill contents
- the model is expected to `read` the skill on demand
- the skill listing is appended only when the `read` tool is available
- `disable-model-invocation: true` hides a skill from the prompt listing; the user must invoke it with `/skill:name`
- in `~/.pi/agent/skills/` and `.pi/skills/`, direct root `.md` files can be standalone skills
- in `~/.agents/skills/` and project `.agents/skills/`, root `.md` files are ignored; directories containing `SKILL.md` are what matter there

### Skill commands
Skills are also exposed as slash commands like:
- `/skill:name`

Arguments after the command are appended as `User: <args>`.

---

## Pi core: prompt templates and slash entries

Many things in Pi start with `/`, but they are not all the same.

A slash entry may be:
- a built-in command
- an extension-provided command
- a prompt template
- a skill invocation

### Built-in commands
Examples:
- `/settings`
- `/model`
- `/reload`
- `/resume`
- `/session`
- `/tree`
- `/fork`
- `/clone`
- `/compact`
- `/quit`

These are real application actions.

### Extension commands
Examples from installed packages may include:
- `/agents`
- `/subagents-status`
- `/intercom`

These are also real commands, but extension-provided.

### Prompt templates
Prompt templates are Markdown snippets that expand into full prompts.

Locations:
- `~/.pi/agent/prompts/*.md`
- `.pi/prompts/*.md`
- packages can contribute prompt templates via conventional `prompts/` dirs or `package.json -> pi.prompts`
- settings can contribute prompt/template paths
- CLI can contribute prompt-template paths

Important:
- default discovery in `prompts/` directories is non-recursive
- `--no-prompt-templates` disables discovery

Mental model:
- built-in command = app action
- extension command = extension-defined action
- prompt template = text expansion into a prompt
- skill command = load/execute a skill

---

## Pi core: per-turn behavior

Before each LLM call, Pi can still modify behavior dynamically.

### Order of important layers
1. extension command handling for `/...`
2. `input` extension event can transform or block the user text
3. `/skill:name` and prompt-template expansion
4. `before_agent_start` extensions can modify the system prompt or inject messages
5. `context` extensions can rewrite message context before the model call
6. `before_provider_request` extensions can rewrite the final provider payload

That means the final provider request can differ from the plain assembled system prompt string.

---

## Pi core: session behavior

Pi persists message history in session files, but it does **not** persist a frozen system-prompt snapshot.
On resume or `/reload`, Pi rebuilds the base prompt from current resources/settings.

That means resumed sessions can get a different prompt if:
- `SYSTEM.md` changed
- `AGENTS.md` changed
- tools changed
- extensions changed
- skill discovery changed

This applies both to normal sessions and to subagent child sessions.

---

## Normal Pi session: practical summary

A normal Pi session usually feels like:
1. Pi builds the base prompt
2. appends `APPEND_SYSTEM.md` if any
3. appends context files (`AGENTS.md` / `CLAUDE.md`)
4. appends available skills if `read` exists
5. appends date/cwd
6. extensions can mutate things per turn

### What to use when
- Use `SYSTEM.md` to replace Pi's built-in behavior
- Use `APPEND_SYSTEM.md` to add top-level rules
- Use `AGENTS.md` for repo-specific instructions
- Use skills for specialized workflows loaded on demand
- Use prompt templates for reusable prompt text

---

## Pi Manager native subagents

Pi Manager's current integrated subagent system is native/app-managed. The package `pi-subagents` can still exist for compatibility and external Pi usage, but Pi Manager's manual Run Subagent UI and managed parent bridge tools launch child Pi RPC sessions directly.

Detailed app-specific reference: `native-subagents.md`.

### Native entry points

Native runs can start from:

- the Run Subagent sheet in the Pi Agent composer
- parent bridge tool `managed_subagent(agent, task, context?, reads?)`
- parent bridge tool `managed_chain(chain, task, worktree?)`
- parent bridge tool `managed_parallel(tasks, concurrency?, worktree?)`

The composer's subagent enablement toggle controls whether these app-managed runs are available for the selected session. When disabled, bridge calls return a disabled message instead of launching children.

### Native artifacts and parent result flow

Each native run gets an artifact directory under:

```text
~/Library/Application Support/Pi Manager/Subagent Runs/<run-id>/
```

Typical files include:

- `system-prompt.md`
- `input.md`
- `output.md`
- optional isolated `worktree/`
- optional `worktree.patch`

Pi Manager persists run/child metadata, transcripts, supervisor requests, and graph records in its session store. On completion, the app writes the final response to `output.md`, updates the run summary, and appends a compact **Subagent Completed** status/result entry to the parent transcript. Managed bridge calls also return a compact result string to the parent Pi turn.

### Native communication layer

Pi Manager writes bridge extensions for app-managed parent/child communication.

Parent-side bridge tools include:

- `set_session_plan(items)`
- `update_session_plan(updates)`
- `managed_subagent(...)`
- `managed_chain(...)`
- `managed_parallel(...)`
- `list_supervisor_requests()`
- `answer_supervisor_request(requestID, response)`

Child-side communication is opt-in through the `contact_supervisor` tool. A child receives it only when the selected agent's `tools` include `contact_supervisor` and Pi Manager can write/load the child bridge extension.

`contact_supervisor` supports:

- `progress_update` — non-blocking and auto-acknowledged
- `need_decision` — blocking until a human or parent agent answers
- `interview_request` — blocking structured question flow

Blocking requests create supervisor cards in Pi Manager and can also be answered by the parent agent through `answer_supervisor_request`.

### Native expected-outcome and read-first policy

Native runs make output policy explicit:

- `Report only` — child should not edit project files
- `Edit files in worktree` — edits stay isolated until reviewed/applied/discarded
- `Write/update project file` — one explicit project-relative output path, usually in a worktree
- `Direct project writes` — allowed only after explicit approval

Read-first paths are hints, not injected contents. They must be project-relative; absolute paths and `..` are rejected. Caller-provided reads override agent `defaultReads`; otherwise agent defaults are used.

### Native prompt construction

Pi Manager follows Pi's core prompt semantics:

- native boundary instructions + agent prompt + explicit private skill blocks are passed with `--system-prompt`
- `inheritProjectContext: false` maps to `--no-context-files`
- `inheritSkills: false` maps to `--no-skills`
- configured extension allowlists are passed explicitly
- run-specific outcome/read/task details are sent as the initial user prompt, not embedded as stale system context

## `pi-subagents`: core mental model

`pi-subagents` gives the main Pi session a `subagent` tool.

The parent/orchestrator can:
- run one child agent
- run a sequential chain
- run parallel tasks
- run jobs in foreground or background
- manage agent and chain definitions

Subagents are child Pi processes with extra orchestration around:
- prompt assembly
- tool/extension selection
- optional child session forking
- optional output files
- optional chain artifacts
- optional worktree isolation

---

## `pi-subagents`: builtin agents

Builtin agent files live here:
- `/opt/homebrew/lib/node_modules/pi-subagents/agents/`

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

Note on older docs: some older documentation referenced a builtin path like `~/.pi/agent/extensions/subagent/agents/`. On this machine, and in current packaged reality, the builtin agents are loaded from the installed package directory above.

---

## `pi-subagents`: agent discovery and precedence

### Agent scope map

| Scope | Purpose | Path |
|---|---|---|
| Builtin | Package-shipped defaults | `/opt/homebrew/lib/node_modules/pi-subagents/agents/` |
| Global / user | Available everywhere for this user | `~/.pi/agent/agents/`, `~/.agents/` |
| Project | Available in the nearest project root that contains subagent config | nearest ancestor `.pi/agents/` |
| Legacy project | Older compatibility path | nearest ancestor `.agents/` |

### Effective discovery priority
Lowest to highest priority:
1. builtin
2. user
3. project

Project discovery:
- finds the nearest ancestor containing `.pi` or `.agents`
- reads both `.agents/` and `.pi/agents/` there
- if both define the same project agent, `.pi/agents/` wins

User discovery:
- reads both `~/.pi/agent/agents/` and `~/.agents/`
- if both define the same user agent name, `~/.agents/` wins because it is loaded later

That means:
- a user agent can replace a builtin by using the same `name`
- a project agent can replace a user or builtin agent by using the same `name`
- on this machine, because `~/.agents/` exists, `/agents` will prefer creating new user agents/chains there

`agentScope: "user" | "project" | "both"` controls discovery scope at runtime. `both` is the default.

---

## `pi-subagents`: chain discovery and precedence

Saved chains are `.chain.md` files.

### Chain scope map

| Scope | Path |
|---|---|
| Global / user | `~/.pi/agent/agents/{name}.chain.md`, `~/.agents/{name}.chain.md` |
| Project | nearest ancestor `.pi/agents/{name}.chain.md` |
| Legacy project | nearest ancestor `.agents/{name}.chain.md` |

Project chains win over user chains on name collision.

Project discovery uses the same nearest-ancestor project-root rule as agents.
If both `.agents/` and `.pi/agents/` define the same project chain name there, `.pi/agents/` wins.
If both `~/.pi/agent/agents/` and `~/.agents/` define the same user chain name, `~/.agents/` wins.

---

## `pi-subagents`: builtin overrides

Builtin agents can be patched without replacing their files.

Override locations:
- user scope: `~/.pi/agent/settings.json`
- project scope: nearest ancestor `.pi/settings.json`

Example:

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
- project overrides beat user overrides
- package updates overwrite builtin files, but not overrides in settings
- `disabled: true` hides the builtin from runtime discovery while still letting `/agents` show it for management
- `subagents.disableBuiltins: true` disables builtins in bulk

Practical default split:
- custom agents are usually narrow by default: `systemPromptMode: replace`, `inheritProjectContext: false`, `inheritSkills: false`
- builtin agents generally opt into `inheritProjectContext: true`
- builtin `delegate` stays on `systemPromptMode: append`

---

## `pi-subagents`: the most important agent fields

### `systemPromptMode`
Controls how the child prompt is assembled.

- `replace` = use the agent prompt instead of Pi's usual base prompt
- `append` = keep Pi's base prompt and append the agent prompt

Plain English:
- `replace` makes a tighter specialist
- `append` makes the child behave more like normal Pi plus extra instructions
- builtin `delegate` defaults to `append`; most other builtins default to `replace`

### `inheritProjectContext`
Controls whether project context/instruction files survive into the child.

- `true` = keep inherited project-context files like `AGENTS.md` / `CLAUDE.md`
- `false` = strip those inherited project-context sections from the child prompt

This is prompt context, not full conversation history.

### `inheritSkills`
Controls whether the child sees Pi's ambient/discovered skills catalog.

- `true` = the child keeps the generated skills section
- `false` = the child does not inherit the broad skills catalog

This only matters when the child has the `read` tool, because Pi only appends the skills listing when `read` is available.

### explicit `skills`
Explicit `skills:` inject specific skills into the child system prompt regardless of `inheritSkills`.

This is stronger than ambient skill inheritance: `pi-subagents` resolves those skills and injects their full contents into the child prompt.

Important caveat:
- this explicit `skills:` injection uses `pi-subagents`' own resolver
- it covers its supported cwd/fallback-cwd sources
- it is narrower than all possible Pi-core skill sources
- extension-contributed dynamic skill paths and explicit CLI-added `--skill` entries are Pi-core capabilities that are not guaranteed to be visible to `pi-subagents`' explicit `skills:` resolver

### `tools`
Controls what tools the subagent can call.

- if omitted, the child gets Pi's normal builtin tools because `pi-subagents` does not pass `--tools`
- if present, it becomes an explicit builtin tool allowlist for normal builtins
- `mcp:...` entries request direct MCP tools
- path-like tool entries can be interpreted as extension/tool paths rather than builtin names

### `extensions`
Controls extension loading for the child.

Semantics:
- field omitted = normal discovered extensions load
- empty field = no normal discovered extensions
- comma-separated values = explicit allowlist

When `extensions` is present, `pi-subagents` disables normal extension discovery for the child and then loads the union of:
- the internal subagent runtime extension
- any path-like `tools` entries
- the explicit `extensions` allowlist

So `extensions:` empty means no normal discovered extensions, but the internal runtime extension still remains active because the subagent machinery depends on it.

### `output`
Default output file for the agent.

### `defaultReads`
Files the child should read before execution in chain/parallel behavior.

### `defaultProgress`
Whether to maintain `progress.md`.

### `interactive`
Parsed for compatibility but not meaningfully enforced in v1.

### `maxSubagentDepth`
Restricts nested delegation depth. It can tighten an inherited stricter limit, not relax it.

---

## `pi-subagents`: prompt inheritance vs session forking

These are easy to confuse.

### Prompt context inheritance
Controlled by:
- `systemPromptMode`
- `inheritProjectContext`
- `inheritSkills`
- explicit `skills:`

This changes what prompt sections the child receives.

### Session forking
Controlled by:
- `context: "fork"`

This creates a branched child session from the parent session history.
It is **not** the same thing as inheriting project instruction files.

### Important fork caveats
- `pi-subagents` wraps the delegated task with a fork preamble telling the child to treat inherited history as reference-only context, not a live conversation thread to continue
- in chains and parallel runs, each flat step/task gets its own sibling fork from the same parent leaf rather than all steps sharing one continuous child conversation history
- `context: "fork"` fails fast if the parent session is unavailable or cannot be branched; it does not silently downgrade to `fresh`

---

## `pi-subagents`: chains and parallel runs

### Chain step behavior
Each chain step can override some of the agent's defaults.

Important rules:
- `output`: step override wins over agent default output
- `reads`: step override wins over agent `defaultReads`
- `progress`: step override wins over agent `defaultProgress`
- runtime `skill`: step override wins over agent skills for that step
- `model`: step override wins over agent model for that step

Important `false` semantics:
- `output: false` = explicitly disable output for that step
- `reads: false` = explicitly disable reads for that step
- runtime `skill: false` = explicitly disable skills for that step

Terminology note:
- saved `.chain.md` files use `skills:` in step definitions
- runtime tool calls commonly use `skill`/override-style fields depending on mode

### Template variables
In foreground/sync chains, task templates can use:
- `{task}` = original task
- `{previous}` = previous step output
- `{chain_dir}` = shared artifacts directory

Current async/background chain execution is narrower:
- `{previous}` is the most portable placeholder there
- it does not carry the full foreground `chainDir` / `{task}` / `{chain_dir}` substitution surface

### Relative paths
In foreground/sync chains, relative chain read/write paths resolve from the chain directory.

### Clarify behavior
- chains default to `clarify: true`
- single and top-level parallel runs default to no clarify UI unless `clarify: true` is requested
- top-level async chain launches require `clarify: false`

### Worktree behavior
`worktree: true` applies to:
- top-level parallel `tasks`
- parallel groups inside chains
- async/background parallel workflows

Use it when concurrent children may write to the same checkout.

---

## MCP and web-tool notes for this setup

### `pi-web-access`
Installed package:
- `/opt/homebrew/lib/node_modules/pi-web-access`

It provides tools such as:
- `web_search`
- `fetch_content`
- `get_search_content`
- `code_search`

`web_search` defaults to `provider: "auto"` with fallback order:
1. Exa
2. Perplexity
3. Gemini API
4. Gemini Web

Environment variables commonly used here:
- `EXA_API_KEY`
- `GEMINI_API_KEY`
- `PERPLEXITY_API_KEY`

### MCP behavior
Subagents do not magically get all MCP power without configuration.

In practice:
- direct MCP tools are usually selected with `mcp:...` entries in `tools`
- direct MCP tool usage depends on installed MCP-related adapters/extensions and configuration
- the generic `mcp` proxy tool can still exist separately when available
- global `directTools: true` in `mcp.json` is not enough by itself; the agent must still request direct tools via `mcp:` entries

---

## `pi-dotenv` in this setup

Local extension:
- `/Users/andrea/.pi/agent/extensions/pi-dotenv`

This is **machine-specific extension behavior**, not a native `pi-subagents` feature.

It loads env files into the running Pi process from:
- global: `~/.pi/agent/.env`
- project: `.pi/.env`

Project values override global values.
Because subagents inherit the parent environment, env vars loaded by `pi-dotenv` are generally visible to subagents too.

---

## Source-of-truth files to maintain

If you are keeping this repository's Pi documentation current, these are the important docs:

### Canonical technical reference
- `pi-documentation/pi-core-system-reference-and-subagents.md`
- `pi-documentation/native-subagents.md`

### Product/app spec
- `pi-manager-spec.md`

### Feature-specific reference
- `pi-documentation/pi-commands-and-prompt-templates.md`

### Superseded by this unified file
- `pi-documentation/pi-instructions-normal-vs-subagents.md`
- `pi-documentation/pi-subagents-system-reference.md`

---

## Summary

Pi core and `pi-subagents` are layered like this:
- Pi builds a base prompt from `SYSTEM.md` or its built-in default
- Pi appends `APPEND_SYSTEM.md`
- Pi appends `AGENTS.md` / `CLAUDE.md` project context
- Pi appends a skills listing when `read` is available
- Pi appends date/cwd
- extensions can still mutate behavior per turn
- `pi-subagents` starts child Pi sessions and shapes them with agent definitions, overrides, chains, forked sessions, tool limits, extension limits, and worktree orchestration

That is the unified mental model for both normal Pi sessions and subagent child sessions.