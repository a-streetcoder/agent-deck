# Customizing pi-subagents

This document summarizes what you can customize in `pi-subagents`, where each customization lives, and which parts would make sense to expose in Pi Manager.

If you want the **actual Pi Manager app storage model** — especially the split between active global resources, library resources, project resources, and app-managed symlinks — read `pi-manager-resource-management.md` alongside this file.

`pi-subagents` has four main customization layers:

1. **Builtin agent behavior** via settings overrides
2. **Custom agents and chains** via markdown files
3. **Skills and packaged skill discovery** via files, settings, and packages
4. **Runtime and extension behavior** via `subagent()` parameters and extension config

---

## 1. Settings locations

| Scope | Path |
|---|---|
| User settings | `~/.pi/agent/settings.json` |
| Project settings | `.pi/settings.json` |
| Extension config | `~/.pi/agent/extensions/subagent/config.json` |

Project settings beat user settings when both apply.

---

## 2. Builtin agents

Builtins are discovered at the lowest priority. A custom agent with the same name replaces the builtin.

Builtin package/installed locations:

- `~/.pi/agent/extensions/subagent/agents/`
- packaged copy inside the installed `pi-subagents` extension

Builtin agents include:

- `scout`
- `worker`
- `oracle`
- `planner`
- `reviewer`
- `researcher`
- `context-builder`
- `delegate`

### Disable all builtins

```json
{
  "subagents": {
    "disableBuiltins": true
  }
}
```

### Disable specific builtins

```json
{
  "subagents": {
    "agentOverrides": {
      "oracle": { "disabled": true },
      "planner": { "disabled": true }
    }
  }
}
```

### Override builtin fields without copying the agent

```json
{
  "subagents": {
    "agentOverrides": {
      "worker": {
        "model": "anthropic/claude-sonnet-4",
        "thinking": "high",
        "defaultContext": "fresh",
        "inheritProjectContext": false,
        "systemPrompt": "You are a focused implementation agent."
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
- `defaultContext`
- `disabled`
- `skills`
- `tools`
- `systemPrompt`

Notes:

- `defaultContext: false` clears an inherited builtin context default.
- Project overrides beat user overrides.
- `disabled: true` hides the builtin from runtime discovery and `subagent({ action: "list" })`.

---

## 3. Custom agents

Custom agents are markdown files with YAML frontmatter and a prompt body.

### Agent discovery order

Lowest to highest priority:

| Scope | Path |
|---|---|
| Builtin | `~/.pi/agent/extensions/subagent/agents/` |
| User | `~/.pi/agent/agents/{name}.md` |
| Project | `.pi/agents/{name}.md` |
| Legacy project | `.agents/{name}.md` |

If both `.agents/` and `.pi/agents/` define the same project agent, `.pi/agents/` wins.

### Example agent

```yaml
---
name: scout
description: Fast codebase recon
tools: read, bash, mcp:chrome-devtools
extensions:
model: anthropic/claude-haiku-4-5
fallbackModels: openai/gpt-5-mini, anthropic/claude-sonnet-4
thinking: high
systemPromptMode: replace
inheritProjectContext: false
inheritSkills: false
defaultContext: fork
skills: safe-bash, chrome-devtools
output: context.md
defaultReads: context.md
defaultProgress: true
interactive: true
maxSubagentDepth: 1
---

Analyze the codebase and return a compressed implementation brief.
```

### Agent frontmatter fields

| Field | Meaning |
|---|---|
| `name` | Agent name |
| `description` | Human-readable description |
| `tools` | Builtin tool allowlist; also supports `mcp:` direct tools and path-like extension entries |
| `extensions` | Extension loading mode: omitted = normal, empty = none, value = allowlist |
| `model` | Default model |
| `fallbackModels` | Ordered backup models |
| `thinking` | Reasoning level |
| `systemPromptMode` | `replace` or `append` |
| `inheritProjectContext` | Include project instruction files like `AGENTS.md` |
| `inheritSkills` | Include Pi’s discovered skill catalog |
| `defaultContext` | `fresh` or `fork` default for launches that omit `context` |
| `skills` | Directly inject named skills |
| `output` | Default single-agent output file |
| `defaultReads` | Files to read before execution |
| `defaultProgress` | Maintain `progress.md` |
| `interactive` | Parsed for compatibility; not enforced in v1 |
| `maxSubagentDepth` | Tighten nested delegation depth |

### Prompt assembly behavior

Custom agents are narrow by default. They do **not** automatically inherit:

- Pi’s whole base prompt
- project instruction files
- the discovered skills catalog

Use these fields to opt in:

- `systemPromptMode: append`
- `inheritProjectContext: true`
- `inheritSkills: true`
- `defaultContext: fork`

Notes:

- Builtins opt into project instruction inheritance by default.
- Packaged `planner`, `worker`, and `oracle` default to `fork` context.

---

## 4. Tool and extension customization

### `tools`

If `tools` is omitted, the child gets Pi’s normal builtin tools.

If `tools` is present:

- normal names become a builtin allowlist
- `mcp:...` entries become direct MCP tool selections
- path-like values can be treated as extension/tool-extension paths

Examples:

```yaml
# normal builtin tools
# tools omitted

# builtin allowlist + direct MCP tools
tools: read, bash, mcp:chrome-devtools

# direct MCP only, while keeping normal builtins
tools: mcp:chrome-devtools
```

### `extensions`

```yaml
# omitted = normal extensions load

# empty = no extensions
extensions:

# allowlist
extensions: /abs/path/to/ext-a.ts, /abs/path/to/ext-b.ts
```

If `extensions` is present, it takes precedence over extension paths implied by `tools`.

### Direct MCP tools

Direct MCP tools require `pi-mcp-adapter`.

Subagents only receive direct MCP tools when `mcp:` entries are explicitly listed. Global MCP config alone is not enough.

---

## 5. Chains

Chains are reusable `.chain.md` workflows stored beside agent files.

### Chain locations

| Scope | Path |
|---|---|
| User | `~/.pi/agent/agents/{name}.chain.md` |
| Project | `.pi/agents/{name}.chain.md` |
| Legacy project | `.agents/{name}.chain.md` |

### Example chain

```md
---
name: scout-planner
description: Gather context then plan
---

## scout
output: context.md

Analyze the codebase for {task}

## planner
reads: context.md
model: anthropic/claude-sonnet-4-5:high
progress: true

Create an implementation plan based on {previous}
```

### Step config fields

Directly under each `## agent-name` header you can use:

- `output`
- `reads`
- `model`
- `skill` / `skills`
- `progress`

Behavior is three-state:

- omitted = inherit agent default
- value = override
- `false` = disable

### Chain variables

- `{task}` — original task
- `{previous}` — previous step output
- `{chain_dir}` — chain artifact directory

Parallel chain steps also support aggregation of parallel outputs into `{previous}` for the next step.

---

## 6. Skills

Skills are `SKILL.md` files injected into an agent prompt.

### Skill discovery

Common high-priority sources:

1. `.pi/skills/{name}/SKILL.md`
2. project packages via `package.json -> pi.skills`
3. current cwd package via `package.json -> pi.skills`
4. `.pi/settings.json -> skills`
5. `~/.pi/agent/skills/{name}/SKILL.md`
6. user packages via `package.json -> pi.skills`
7. `~/.pi/agent/settings.json -> skills`

Also supported by discovery:

- legacy `.agents/skills/...`
- legacy `~/.agents/skills/...`
- settings-declared packages
- installed package skill directories from Pi-managed npm locations and global npm roots

### Overriding the bundled `pi-subagents` skill

Builtin orchestration skill name:

- `pi-subagents`

Override locations:

- project: `.pi/skills/pi-subagents/SKILL.md`
- user: `~/.pi/agent/skills/pi-subagents/SKILL.md`

The `pi-subagents` skill is **special**:

- it is intended for the parent/orchestrator only
- child subagents never inherit it
- replacing it with the same name preserves that behavior

### Runtime skill overrides

```ts
{ agent: "scout", task: "..." }
{ agent: "scout", task: "...", skill: "safe-bash, tmux" }
{ agent: "scout", task: "...", skill: false }
```

For chains:

- top-level `skill` is additive
- step-level `skill` overrides that step
- `false` disables skills for that step

---

## 7. Runtime `subagent()` customization

Not all customization requires editing files. A lot is available at call time.

### Single-agent overrides

```ts
{ agent: "worker", task: "refactor auth", model: "anthropic/claude-sonnet-4" }
{ agent: "scout", task: "find todos", output: false }
{ agent: "scout", task: "investigate", skill: false }
```

### Parallel mode

```ts
{
  tasks: [
    { agent: "scout", task: "audit frontend" },
    { agent: "reviewer", task: "audit backend" }
  ],
  concurrency: 2,
  worktree: true
}
```

Parallel task fields:

- `agent`
- `task`
- `cwd`
- `count`
- `output`
- `reads`
- `progress`
- `skill`
- `model`

### Chain mode

```ts
{
  chain: [
    { agent: "scout", task: "Gather context for {task}" },
    {
      parallel: [
        { agent: "worker", task: "Implement A from {previous}" },
        { agent: "worker", task: "Implement B from {previous}" }
      ],
      concurrency: 2,
      failFast: true,
      worktree: true
    },
    { agent: "reviewer", task: "Review {previous}" }
  ]
}
```

Chain step fields:

- `agent`
- `task`
- `cwd`
- `output`
- `reads`
- `progress`
- `skill`
- `model`

Parallel chain-group fields:

- `parallel`
- `concurrency`
- `failFast`
- `worktree`

### Execution-wide runtime fields

- `context: "fresh" | "fork"`
- `chainDir`
- `async`
- `agentScope: "user" | "project" | "both"`
- `cwd`
- `artifacts`
- `includeProgress`
- `share`
- `sessionDir`
- `clarify`
- `control`
- single-agent `output`
- single-agent `skill`
- single-agent `model`

### Management and control actions

`subagent()` also supports runtime management:

- `list`
- `get`
- `create`
- `update`
- `delete`
- `status`
- `interrupt`
- `resume`
- `doctor`

These let you manage agents and chains programmatically without editing files manually.

---

## 8. Control / attention customization

The `control` config is broader than just `needsAttentionAfterMs`.

Supported control fields:

- `enabled`
- `needsAttentionAfterMs`
- `activeNoticeAfterMs`
- `activeNoticeAfterTurns`
- `activeNoticeAfterTokens`
- `failedToolAttemptsBeforeAttention`
- `notifyOn`
- `notifyChannels`

These can be used:

- in extension config defaults
- in per-run `subagent()` overrides

Example:

```ts
{
  agent: "worker",
  task: "implement auth",
  control: {
    needsAttentionAfterMs: 60000,
    activeNoticeAfterMs: 240000,
    notifyOn: ["active_long_running", "needs_attention"],
    notifyChannels: ["event", "async", "intercom"]
  }
}
```

---

## 9. Extension config (`config.json`)

Path:

- `~/.pi/agent/extensions/subagent/config.json`

Supported fields:

- `asyncByDefault`
- `forceTopLevelAsync`
- `defaultSessionDir`
- `maxSubagentDepth`
- `control`
- `parallel.maxTasks`
- `parallel.concurrency`
- `agentManager.newShortcut`
- `worktreeSetupHook`
- `worktreeSetupHookTimeoutMs`
- `intercomBridge.mode`
- `intercomBridge.instructionFile`

Example:

```json
{
  "asyncByDefault": true,
  "parallel": {
    "maxTasks": 12,
    "concurrency": 6
  },
  "control": {
    "needsAttentionAfterMs": 60000
  },
  "agentManager": {
    "newShortcut": "shift+ctrl+n"
  },
  "intercomBridge": {
    "mode": "fork-only"
  }
}
```

---

## 10. Worktree customization

`worktree: true` gives parallel children isolated git worktrees.

Important related knobs:

- top-level `worktree`
- chain parallel-step `worktree`
- extension `worktreeSetupHook`
- extension `worktreeSetupHookTimeoutMs`

Requirements:

- must run inside a git repo
- working tree must be clean
- configured setup hook must succeed before timeout

This is mainly for safe parallel editing.

---

## 11. Outputs, artifacts, and observability

Customizable runtime/output behavior includes:

- `output`
- `reads`
- `progress`
- `chainDir`
- `artifacts`
- `includeProgress`
- `sessionDir`
- `share`

Useful package behaviors to know:

- chain runs use a temp chain directory by default
- old chain temp directories are cleaned up automatically
- async runs persist status and event files
- artifact metadata records timing/model/fallback info
- final output is truncated by package defaults unless otherwise configured

---

## 12. Precedence summary

### Agents

```text
Project .pi/agents/*.md
  > legacy project .agents/*.md
  > user ~/.pi/agent/agents/*.md
  > builtins
```

### Chains

```text
Project .pi/agents/*.chain.md
  > legacy project .agents/*.chain.md
  > user ~/.pi/agent/agents/*.chain.md
```

### Skills

```text
Project skill files / project package-declared skills
  > project settings skills/packages
  > user skill files / user package-declared skills
  > user settings skills/packages
  > builtins
```

### Settings

```text
Project .pi/settings.json
  > user ~/.pi/agent/settings.json
```

---

## 13. What child agents do *not* inherit automatically

By design, child agents do not automatically receive everything from the parent.

Notable constraints:

- the parent-only `pi-subagents` orchestration skill is filtered out
- children are meant to stay narrow unless you opt into broader inheritance
- forked context is a real branched session, not just a pasted summary

That distinction matters when deciding whether to use:

- `inheritProjectContext`
- `inheritSkills`
- `systemPromptMode: append`
- `context: "fork"`

---

## 14. What this means for Pi Manager

The customization surface that exists today falls into these buckets:

### Good candidates for Pi Manager UI

- builtin enable/disable
- builtin field overrides
- custom agent editing
- custom chain editing
- skill discovery visibility
- extension config editing
- runtime defaults like async / concurrency / control

### Better kept as documentation or advanced JSON

- package-declared skill resolution details
- worktree setup hook stdin/stdout contract
- low-level async artifact/session file behavior
- direct MCP extension-path edge cases

Pi Manager can still expose those advanced areas later, but they are lower priority than the common override/configuration flows.
