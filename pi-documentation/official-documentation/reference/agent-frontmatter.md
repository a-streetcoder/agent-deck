# Agent Frontmatter Reference

Agents are Markdown files with YAML frontmatter and a body used as the agent system prompt.

## Minimal example

```md
---
name: reviewer
description: Reviews diffs and plans for correctness issues.
---

You are a review-only agent. Inspect the requested evidence and report findings with file paths.
```

## Common fields

| Field | Meaning |
|---|---|
| `name` | Runtime agent name |
| `description` | Human-readable summary for UI and lists |
| `whenToUse` | Concise parent-session routing rule; Agent Deck uses this before falling back to `description` |
| `model` | Preferred model |
| `fallbackModels` | Fallback model list |
| `thinking` | Preferred thinking level |
| `systemPromptMode` | Replace/append behavior where supported |
| `inheritSkills` | Compatibility metadata; current Agent Deck native runs use explicit agent skills instead of ambient skill discovery |
| `tools` | Tool names available to the child |
| `mcpDirectTools` | Agent Deck/native integration direct-tool hint |
| `extensions` | Extensions to load for the run |
| `skills` | Explicit skill names to inject if visible |
| `output` | Advisory default output path/name |
| `defaultExpectedOutcome` | Default run output policy: `reportOnly`, `editFilesInWorktree`, `writeProjectFile`, or `directProjectWrites` |
| `defaultReads` | Read-first path defaults |
| `defaultProgress` | Whether progress tracking is expected |
| `interactive` | Whether the agent expects interaction |
| `maxSubagentDepth` | Compatibility/delegation depth metadata |

Agent Deck preserves unknown frontmatter fields where possible.

## Native subagent guidance

- Set `whenToUse` to one concise sentence that tells the parent exactly when to delegate to this agent. Keep it distinct from the human-facing `description`.
- Use `contact_supervisor` in `tools` only when the child may need progress updates, decisions, or interviews. When present, Agent Deck injects native boundary instructions for blocker/progress/interview routing and normal final-result return.
- Set `defaultExpectedOutcome` to match the role: `reportOnly` for research/planning/review agents, `directProjectWrites` only for trusted implementation agents with write tools, and worktree/project-file outcomes for specialized flows.
- Do not rely on `output` to write project files. In Agent Deck native runs, the expected outcome controls whether project writes are allowed.
- Native subagents start fresh by default. The parent can explicitly continue a previous child by Subagent ID for direct follow-ups; this is bridge/runtime state, not agent frontmatter.
- Keep explicit `skills` references stable and ensure the skills are visible in the Agent Deck skill catalog. Native runs receive those skills as explicit Pi `--skill` paths.
