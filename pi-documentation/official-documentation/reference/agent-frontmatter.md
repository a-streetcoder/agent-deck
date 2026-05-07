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
| `description` | Human-readable summary |
| `model` | Preferred model |
| `fallbackModels` | Fallback model list |
| `thinking` | Preferred thinking level |
| `systemPromptMode` | Replace/append behavior where supported |
| `inheritProjectContext` | Whether child keeps Pi context-file discovery |
| `inheritSkills` | Whether child keeps ambient skill discovery |
| `defaultContext` | `fresh` or `fork` default context mode |
| `tools` | Tool names available to the child |
| `mcpDirectTools` | Pi Manager/native integration direct-tool hint |
| `extensions` | Extensions to load for the run |
| `skills` | Explicit skill names to inject if visible |
| `output` | Advisory default output path/name |
| `defaultReads` | Read-first path defaults |
| `defaultProgress` | Whether progress tracking is expected |
| `interactive` | Whether the agent expects interaction |
| `maxSubagentDepth` | Compatibility/delegation depth metadata |

Pi Manager preserves unknown frontmatter fields where possible.

## Native subagent guidance

- Use `contact_supervisor` in `tools` only when the child may need progress updates, decisions, or interviews. When present, Pi Manager injects native boundary instructions for blocker/progress/interview routing and normal final-result return.
- Do not rely on `output` to write project files. In Pi Manager native runs, the expected outcome controls whether project writes are allowed.
- Keep explicit `skills` references stable and ensure the skills are active in the intended project/global scope.
