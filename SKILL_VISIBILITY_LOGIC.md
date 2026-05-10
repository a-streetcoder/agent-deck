# Skill Visibility and Injection Logic

This document maps how Agent Deck and Pi handle skills in parent sessions, native subagents, and resource management.

## Resource states

| State | Path / source | Runtime meaning |
|---|---|---|
| Global active skill | `~/.pi/agent/skills/<name>/SKILL.md` or root `.md` | Pi loads it in every parent session. |
| Project active skill | `PROJECT/.pi/skills/<name>/SKILL.md` or root `.md` | Pi loads it only for sessions launched in that project. |
| Legacy active skill | `~/.agents/skills/**/SKILL.md`, `PROJECT/.agents/skills/**/SKILL.md` | Pi compatibility discovery. Root `.md` files are ignored there. |
| Package/settings skill | package or `settings.json -> skills` | Pi loads according to package/settings discovery. |
| Library skill | `~/.pi/agent/skill-library/<name>/SKILL.md` | Agent Deck storage only. Pi does not load it until linked or explicitly injected by Agent Deck native subagent logic. |

## Parent Pi Agent sessions

Parent sessions are normal Pi RPC sessions. Agent Deck does not build a private skill prompt for the parent.

Principles:

- Global active skills are visible in every parent session through Pi runtime discovery.
- Project active skills are visible only in parent sessions launched for that project.
- Library-only skills are not parent-runtime-visible by themselves.
- Agent Deck does not pass library skills to parent sessions as `--skill` arguments.
- Composer `/skill:*` suggestions use Pi RPC `get_commands` as the source of truth when available.
- Before RPC commands arrive, Agent Deck uses a conservative fallback from active skills only, not library-only skills.
- If a skill is enabled or disabled after a parent session is already running, restart/resume the Pi RPC session to get a fresh runtime command catalog.

## Native subagent sessions

Native subagents are separate child Pi RPC sessions launched by Agent Deck.

There are two skill paths:

1. **Explicit private skill blocks** from agent frontmatter `skills:`.
2. **Ambient Pi skill discovery** controlled by `inheritSkills`.

### Explicit `skills:`

Agent Deck resolves explicit skill names from the selected run snapshot:

```text
snapshot.librarySkills + snapshot.skills
```

That means explicit native subagent skills can come from:

- project active skills
- global active skills
- package/settings active skills present in the snapshot
- library skills

Agent Deck writes resolved skill Markdown into the child system prompt as private skill blocks.

If an explicit skill name cannot be resolved:

- the native run still launches
- the private skill block is omitted
- run diagnostics include `Skill not found: <name>`

### `inheritSkills`

`inheritSkills` controls Pi's ambient skill catalog in the child process:

| Agent setting | Child launch behavior |
|---|---|
| `inheritSkills: true` | Agent Deck does not pass `--no-skills`; Pi may discover ambient global/project/package skills. |
| `inheritSkills: false` or omitted | Agent Deck passes `--no-skills`; normal Pi skill discovery is disabled. Explicit private skill blocks are still injected by Agent Deck. |

Important: `inheritSkills: true` does not copy library-only skills into Pi discovery. Library-only skills are available to native subagents only when listed explicitly in `skills:` and resolvable by Agent Deck.

## Assignment and warnings

Agent Deck assignment is represented by predictable links/files:

| Resource | Project assignment path |
|---|---|
| Agent | `PROJECT/.pi/agents/<name>.md` |
| Chain | `PROJECT/.pi/chains/<name>.chain.md` |
| Skill | `PROJECT/.pi/skills/<name>` or `PROJECT/.pi/skills/<name>.md` |
| Prompt | `PROJECT/.pi/prompts/<name>.md` |

Assignment checks use these paths directly, so they do not require scanning every project.

Warnings:

- Agents warn when explicit `skills:` are not visible in assigned projects.
- Skills screen shows missing-skill reference warnings with the agent and project that need attention.
- Chains and prompts expose their own scanner warnings in their screens.
- Sidebar warning badges indicate sections with actionable warnings.

## No-project view

When no project is selected, Agent Deck shows a global/library management view:

- global resources
- library resources
- builtins where applicable

It does not merge project-local resources from every project. Project-local resources appear when that project is selected.

This avoids continuous all-project scanning. Selecting a project scans/refreshes that project; global/library folders are watched independently.

## Smoke test coverage

`agent-deckTests/PiSkillVisibilitySmokeTests.swift` verifies:

- Parent sessions accept runtime skill commands from Pi RPC `get_commands`.
- Parent launch does not inject library skills as `--skill` or `skill-library` arguments.
- Native subagents inject explicit library skill blocks into the child system prompt.
- Native subagents with `inheritSkills: true` do not pass `--no-skills`.
- Native subagents with `inheritSkills: false` pass `--no-skills`.
- Missing explicit native subagent skills produce diagnostics but do not block launch.
