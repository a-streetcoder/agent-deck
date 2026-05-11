---
name: agent-authoring
description: Use when creating or reviewing Agent Deck native agents, including frontmatter, tools, supervisor behavior, context, and skill assignment.
---

# Agent Deck Agent Authoring

Use this skill when creating or reviewing Agent Deck native agent markdown files.

## Agent file shape

Agents are Markdown files with YAML frontmatter and a compact role prompt body:

```markdown
---
name: example-agent
description: Short description of what this agent does
whenToUse: Use when the parent should delegate this kind of bounded work.
tools: read, grep, find, ls, bash, contact_supervisor
thinking: high
systemPromptMode: replace
inheritProjectContext: true
defaultContext: fresh
skills: agent-authoring
---

You are `example-agent`, an Agent Deck native subagent.

Complete only the assigned task. Do not launch other agents.
```

## Required decisions

When creating an agent, decide:

1. Scope: project, global, library/catalog, builtin override, or builtin replacement.
2. Role: scout, planner, worker, reviewer, tester, docs writer, release helper, etc.
3. Tool boundary: prefer `read`, `grep`, `find`, `ls`; add `bash`, `edit`, `write` only when needed.
4. Supervisor behavior: include `contact_supervisor` only when the child should ask for decisions or meaningful blockers.
5. Context: `fresh` by default; `fork` only when parent history is useful and safe to disclose.
6. Project context: use `inheritProjectContext: true` when project conventions such as `AGENTS.md` matter.
7. Skills: assign explicit skill names in `skills:`. Agent Deck passes them through Pi native `--skill` injection. Do not use `inheritSkills`.
8. Validation: specify what files, commands, or evidence the agent should inspect before completion.

## Skill rules

- Parent sessions receive Default + current Project skill assignments.
- Native agents receive only skills explicitly listed in their `skills:` frontmatter or builtin override.
- Skills are passed to Pi as native `--skill <path>` entries.
- Agents with assigned skills need the `read` tool so Pi can load the full skill file.
- Do not paste full skill bodies into agent prompts.

## Supervisor guidance

If the agent has `contact_supervisor`, include focused instructions such as:

- Use `contact_supervisor` with `kind: "need_decision"` for product, architecture, scope, approval, or ambiguity blockers.
- Use `kind: "interview_request"` only when a structured set of questions is needed.
- Use `kind: "progress_update"` sparingly for meaningful non-blocking updates.
- Return final results normally; do not use supervisor contact for routine completion.

## Good defaults

- `systemPromptMode: replace` for focused specialists.
- `inheritProjectContext: true` when project conventions matter.
- `defaultContext: fresh` for reviewers/scouts; `fork` for workers/planners that benefit from parent context.
- Read-only tools for scout/planner/reviewer; add write tools only for implementation agents.
