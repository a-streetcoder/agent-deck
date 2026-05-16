---
name: agent-authoring
description: Use when creating or reviewing Agent Deck agents, including frontmatter, tools, supervisor behavior, continuation behavior, and skill assignment.
---

# Agent Deck Agent Authoring

Use this skill when creating or reviewing Agent Deck agent markdown files.

## Agent file shape

Agents are Markdown files with YAML frontmatter and a compact role prompt body:

```markdown
---
name: example-agent
description: Short human/UI summary of what this agent does
whenToUse: Use for the precise delegation condition that should make the parent choose this agent.
tools: read, grep, find, ls, bash, contact_supervisor
thinking: high
systemPromptMode: replace
defaultExpectedOutcome: reportOnly
skills: agent-authoring
---

You are `example-agent`, an Agent Deck specialist agent.

Describe the role-specific workflow, validation expectations, and return format here.
```

## Prompt composition

Agent Deck composes the runtime system prompt as the agent body followed by common child-session rules. The appended common rules cover completing only the assigned task, preserving parent/user decision authority, avoiding further delegation, supervisor-contact behavior, and final-result handling. Do not repeat those generic boundaries in the agent body unless the role needs a specific variation.

Keep the agent body focused on:

- role identity and scope
- role-specific workflow
- validation or evidence expectations
- output/return format
- role-specific supervisor or progress-update cases, if any

This applies equally to bundled, project, global, and library agents.

## Required decisions

When creating an agent, decide:

1. Scope: project-local, user-global, library/catalog, builtin override, or builtin replacement. Ask the user before writing files when the intended scope is not explicit.
2. Role: explorer, planner, coder, reviewer, tester, docs writer, release helper, etc.
3. Routing: write `whenToUse` as one concise sentence that tells the parent exactly when to delegate to this agent; keep it distinct from the human-facing `description`.
4. Tool boundary: prefer `read`, `grep`, `find`, `ls`; add `bash`, `edit`, `write` only when needed.
5. Default outcome: set `defaultExpectedOutcome` to `reportOnly`, `editFilesInWorktree`, `writeProjectFile`, or `directProjectWrites`. Use `directProjectWrites` only for trusted implementation agents with `edit`/`write`; use `reportOnly` for explorer/planner/reviewer agents.
6. Supervisor behavior: include `contact_supervisor` only when the child should ask for decisions or meaningful blockers.
7. Continuation behavior: native subagents start fresh by default; the parent can explicitly continue a prior Subagent ID for direct follow-ups.
8. Skills: assign explicit skill names in `skills:`. Agent Deck passes them through Pi native `--skill` injection. Do not use `inheritSkills`.
9. Validation: specify what files, commands, or evidence the agent should inspect before completion.

## Scope rules

Do not assume project-local scope just because the current working directory is a project. If the user asks to create an agent and does not specify where it should live, ask one focused question before writing:

- project-local: `.pi/agents/<name>.md`, only for the current project
- user-global: `~/.pi/agent/agents/<name>.md`, available across the user's projects
- library/catalog: `~/.pi/agent/agent-library/agents/<name>.md`, reusable but not automatically active
If the agent references skills, also verify the skill is visible in the target scope or warn before completion.

## Routing metadata rules

- `description` is for humans and UI lists; keep it short but descriptive.
- `whenToUse` is for parent-session delegation; make it a direct routing rule beginning with "Use for..." or "Use when...".
- Keep `whenToUse` to one sentence and avoid repeating long descriptions.
- Include scope/approval constraints in `whenToUse` when they matter, such as "approved implementation", "review-only", or "reconnaissance before planning".
- Parent sessions use `whenToUse` first and fall back to `description` only when `whenToUse` is missing.

## Skill rules

- Parent sessions receive Default + current Project skill assignments.
- Agent Deck delegated agents receive only skills explicitly listed in their `skills:` frontmatter or builtin override.
- Skills are passed to Pi as native `--skill <path>` entries.
- Agents with assigned skills need the `read` tool so Pi can load the full skill file.
- Do not paste full skill bodies into agent prompts.

## Supervisor guidance

If the agent has `contact_supervisor`, Agent Deck injects the generic supervisor protocol automatically. Add supervisor instructions to the agent body only for role-specific cases, such as when an explorer agent should send progress updates for discoveries that materially change the handoff.

## Good defaults

- `systemPromptMode: replace` for focused specialists.
- `defaultExpectedOutcome: reportOnly` for research, planning, review, and advisory agents.
- `defaultExpectedOutcome: directProjectWrites` for approved implementation agents that include `edit`/`write`.
- Native delegated runs use normal project context-file discovery; do not add context-inheritance frontmatter.
- Read-only tools for explorer/planner/reviewer; add write tools only for implementation agents.
