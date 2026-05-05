# Converting `pi-subagents` Agents to Pi Manager Native Subagents

Pi Manager native subagents intentionally reuse the same agent markdown/frontmatter shape as `pi-subagents`. In most cases, converting an existing agent means **moving or enabling the same `.md` file in a Pi Manager-scanned location**, then reviewing a few runtime semantics.

Native subagents are not a second CLI package runtime. Pi Manager owns the child Pi RPC process, transcript, artifacts, supervisor cards, chains/parallel graphs, and optional worktrees.

## Quick answer

If your old `pi-subagents` agent is already a markdown file like this:

```md
---
name: reviewer
description: Review a diff and report evidence-backed findings
tools: read, grep, find, ls, bash
thinking: high
systemPromptMode: replace
inheritProjectContext: true
inheritSkills: false
defaultContext: fresh
defaultReads: plan.md, progress.md
---

You are a disciplined reviewer...
```

then it is already close to native-compatible. Put it in one of the scanned locations below, refresh Pi Manager, and run it from the native Run Subagent sheet or through `managed_subagent`.

## Where to put agents

Pi Manager scans these agent locations:

| Scope | Directory |
|---|---|
| Global user agents | `~/.pi/agent/agents/*.md` |
| Legacy global agents | `~/.agents/*.md` |
| Project agents | `<project>/.pi/agents/*.md` |
| Legacy project agents | `<project>/.agents/*.md` |
| Library agents | `~/.pi/agent/agent-library/agents/*.md` |

Library agents are reusable inventory. Enable or assign them to projects from Pi Manager before expecting them in a project/session runtime list.

## Supported frontmatter

Pi Manager native subagents support the commonly used `pi-subagents` agent fields:

| Field | Native behavior |
|---|---|
| `name` | Agent name used by the UI and `managed_subagent(agent: ...)`. |
| `description` | Displayed in Pi Manager and advertised to the parent agent. |
| `model` | Passed to child Pi with `--model` when set. |
| `fallbackModels` | Parsed, but fallback retry is not implemented yet. Tracked separately. |
| `thinking` | Passed to child Pi when set. |
| `systemPromptMode` | `replace` or `append` behavior for the agent prompt. |
| `inheritProjectContext` | If false, Pi Manager passes `--no-context-files`. |
| `inheritSkills` | If false, Pi Manager passes `--no-skills`; explicit private skill blocks can still be injected. |
| `defaultContext` | `fresh` or `fork`; parent calls can override with `context`. |
| `disabled` | Hidden from native runtime if true. |
| `tools` | Passed as the child tool list. Add `contact_supervisor` if the child may need app supervisor routing. |
| `mcpDirectTools` | Passed through native direct MCP tool isolation. |
| `extensions` | Loaded explicitly; ambient extension discovery is disabled. |
| `skills` | Resolved from visible project/global/package skills and Pi Manager's skill library. |
| `output` | Advisory only in native runs; does not automatically write to the project. |
| `defaultReads` | Soft read-first hints, used only when the caller did not provide `reads`. |
| `defaultProgress` | Parsed and displayed; progress should use `contact_supervisor` sparingly when available. |
| `interactive` | Parsed for compatibility; native supervisor routing uses `contact_supervisor`. |
| `maxSubagentDepth` | Parsed for compatibility; native app runs do not allow child-launched subagents. |

Unknown fields are preserved by the parser where possible, but native execution only acts on the fields above.

## Runtime differences to review

### 1. Replace `intercom`-centric coordination with `contact_supervisor`

Old package agents often mention `intercom` or parent/child coordination through package-specific behavior. For Pi Manager native app-managed children, use the native supervisor tool instead.

Add `contact_supervisor` to `tools` if the agent may need a decision:

```yaml
tools: read, grep, find, ls, bash, edit, write, contact_supervisor
```

Prompt the agent with Pi Manager's native request kinds:

```md
If blocked on a product, architecture, or scope decision, call `contact_supervisor` with:

- `kind: "need_decision"` for a blocking decision
- `kind: "interview_request"` for structured questions
- `kind: "progress_update"` only for meaningful non-blocking updates

Return routine final results normally. Do not send completion handoffs through supervisor tools.
```

Avoid old wording that says `reason: "need_decision"`; native Pi Manager uses `kind`.

`intercom` can still be useful for arbitrary external Pi session messaging, but it is not required for native parent/child supervisor routing.

### 2. Treat `output` as advisory

In old `pi-subagents`, an agent with:

```yaml
output: plan.md
```

may have been expected to write a named artifact. In Pi Manager native runs, final output is app-managed by default under:

```text
~/Library/Application Support/Pi Manager/Subagent Runs/<run-id>/output.md
```

The frontmatter `output` value is shown as a hint/warning only. Pi Manager does **not** automatically write `plan.md` into the project.

To write a project file, the caller must choose an explicit expected outcome in the Run Subagent sheet or parent bridge:

- report only
- edit files in worktree
- write/update one project-relative file
- direct project writes with explicit approval

### 3. Keep `defaultReads` as hints, not injected stale context

`defaultReads` remains useful:

```yaml
defaultReads: context.md, plan.md
```

Native behavior:

- caller-provided `reads` override `defaultReads`
- paths must be project-relative
- absolute paths and `..` are rejected
- file contents are not injected into the prompt
- the child is told to read current files if relevant

This prevents stale previous-run artifacts from silently becoming authoritative context.

### 4. Decide fresh vs forked context intentionally

Old agents can keep:

```yaml
defaultContext: fresh
```

or:

```yaml
defaultContext: fork
```

Native behavior:

- `fresh`: starts a separate child session without inherited parent conversation.
- `fork`: asks Pi to fork from the parent session file when available.
- If `fork` is requested but the parent session file is unavailable, Pi Manager records a clear fallback warning and runs safely.

Good defaults:

- reviewers, scouts, researchers: usually `fresh`
- planners/workers/oracles that rely on approved conversation state: often `fork`

### 5. Make writer agents safe

If an old agent can edit files, keep edit/write tools only when needed:

```yaml
tools: read, grep, find, ls, bash, edit, write, contact_supervisor
```

Native Pi Manager adds safety around writer-like runs:

- manual writer-looking runs require worktree isolation or explicit direct-write approval
- parent bridge writer-looking single runs are auto-isolated
- writer-like chain/parallel runs require isolated worktrees
- isolated worktrees can generate/apply/discard patches from the app

Prefer prompts like:

```md
Make narrow edits only. If running in a worktree, edit only the worktree checkout. Do not broaden scope without supervisor approval.
```

### 6. Recheck extension assumptions

Native child runs start with ambient extension discovery disabled:

```text
--no-extensions
```

Pi Manager then loads only:

- app bridge extensions needed for native supervisor routing
- extensions explicitly configured on the agent

If an old agent relies on an extension, add it explicitly:

```yaml
extensions: exa-search, ask-user
```

Also review tool names. If the old prompt says to use `web_search`, the agent must have a tool or extension that actually provides `web_search` in the native child process.

## Conversion checklist

For each old agent:

1. Copy the `.md` file into `~/.pi/agent/agents/` or `<project>/.pi/agents/`.
2. Confirm `name` is unique or intentionally replaces another agent of the same name.
3. Confirm `description` is short and useful; it is shown in the UI and parent catalog.
4. Confirm `tools` are minimal and include `contact_supervisor` only when needed.
5. Replace old supervisor/intercom instructions with native `contact_supervisor(kind, message, title?)` wording.
6. Keep or remove `output` knowing it is advisory only.
7. Review `defaultReads` and remove stale artifact names that should not be read by default.
8. Set `defaultContext` to `fresh` or `fork` intentionally.
9. Move file-writing agents to worktree-first wording.
10. Add required `extensions` explicitly because ambient discovery is disabled.
11. Refresh Pi Manager and verify the agent appears in the native Run Subagent picker.
12. Run a harmless report-only smoke task before enabling writer workflows.

## Example conversion

Old package-style agent:

```md
---
name: planner
description: Creates implementation plans from context and requirements
tools: read, grep, find, ls, write, intercom
thinking: high
systemPromptMode: replace
inheritProjectContext: true
inheritSkills: false
output: plan.md
defaultReads: context.md
defaultContext: fork
---

You are a planning subagent. Read context.md and write plan.md.
If you need clarification, use intercom to ask the parent.
```

Native-adjusted version:

```md
---
name: planner
description: Creates implementation plans from context and requirements
tools: read, grep, find, ls, contact_supervisor
thinking: high
systemPromptMode: replace
inheritProjectContext: true
inheritSkills: false
output: plan.md
defaultReads: context.md
defaultContext: fork
---

You are a planning subagent. Produce a concrete implementation plan. Do not edit project files unless the caller explicitly selected a project-file or worktree outcome.

Read current `context.md` first if it exists and is relevant. Treat it as a hint, not stale injected truth.

If blocked on a product, architecture, or scope decision, call `contact_supervisor` with `kind: "need_decision"`. Return routine final plans normally. Do not send completion handoffs through supervisor tools.
```

Notes:

- `output: plan.md` is retained as an advisory hint for humans, but the native final answer still goes to app artifacts unless the caller explicitly chooses project-file output.
- `write` was removed because this planner should normally report, not mutate files. Keep `write` only if the expected native workflow really allows file writing.

## Chains and parallel workflows

Existing chain files are conceptually portable if their steps reference agent names that Pi Manager can resolve. Pi Manager native chains run as app-managed graph records. Writer-like chain/parallel tasks should use isolated worktrees.

Parent agents can launch native workflows with:

- `managed_subagent(agent, task, context?, reads?)`
- `managed_chain(chain, task, worktree?)`
- `managed_parallel(tasks, concurrency?, worktree?)`

For large agent catalogs, Pi Manager advertises the full discovered native catalog to the parent agent so user-created agents are not silently hidden.

## Pi Manager bundled starter agents

Pi Manager ships its own small native starter pack in the app bundle:

- `scout`
- `planner`
- `worker`
- `reviewer`

They are intentionally inspired by common `pi-subagents` roles, but rewritten for Pi Manager-native execution, native supervisor routing, app artifacts, and worktree/direct-write policy.

These bundled agents are global builtins. They can be disabled with Pi Manager's builtin override controls, or replaced by same-name global/project custom agents.

The broader `pi-subagents` package starter set is compatible in shape, but package execution semantics are different. To use an old package agent as a native agent, copy or adapt it into a Pi Manager-scanned global/project/library location and review the checklist above.

## Related docs

- `pi-documentation/native-subagents.md`
- `pi-documentation/pi-manager-resource-management.md`
- `pi-documentation/pi-subagents-customization.md`
