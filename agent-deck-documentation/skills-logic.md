# Skills in Agent Deck

Agent Deck treats skills as an explicit assignment system.

Core rule:

> A skill being discovered by Agent Deck does not mean it is injected into Pi. Agent Deck launches app-owned Pi RPC sessions with `--no-skills` and passes only assigned skills with explicit `--skill <path>` arguments.

This makes Agent Deck the source of truth for which skills are available to each parent session and native subagent.

## Skill catalog

The skill catalog is the list of skills Agent Deck can see on the user's machine or in the app bundle.

Agent Deck can discover skills from multiple sources, including:

| Source | Examples |
|---|---|
| Bundled skills | Skills shipped with Agent Deck, such as `agent-authoring`, `prompt-authoring`, and `skill-authoring`. |
| User skills | `~/.pi/agent/skills/<name>/SKILL.md`, `~/.pi/agent/skills/<name>.md`. |
| Project skills | `PROJECT/.pi/skills/<name>/SKILL.md`, `PROJECT/.pi/skills/<name>.md`. |
| Compatibility skills | `.agents/skills/<name>/SKILL.md` locations. |
| Package skills | Package-declared `pi.skills` or conventional package `skills/` folders. |
| Imported/catalog skills | Any existing imported skill folders Agent Deck scans. |

A catalog skill keeps its original path. Agent Deck does not need to move, copy, or link a skill before using it. Runtime injection is controlled by assignment, not by the folder where the skill lives.

## Importing external skills

The Skills view import sheet lets a user choose either a skill root or a broader source folder. Agent Deck searches the chosen folder recursively for directories containing `SKILL.md`, stopping recursion when it reaches a skill root. This lets a user point at a repository or collection folder, review the discovered skill roots, and select only the skills they want.

Importing selected skills stores the selected skill root paths in Agent Deck settings. It does not store the broad search folder, copy files, or automatically assign the skills. The selected roots become catalog entries and are injected only when assigned as Default, Project, or Agent skills.

## Bundled authoring skills

Agent Deck ships focused authoring skills for common resource creation workflows:

| Skill | Purpose |
|---|---|
| `agent-authoring` | Create or review Agent Deck native agent markdown files. |
| `prompt-authoring` | Create or improve reusable prompt templates for parent sessions. |
| `skill-authoring` | Create or improve Agent Deck/Pi skills and explain assignment behavior. |

These bundled skills are catalog resources. They follow the same assignment rules as other skills: they are not injected into a parent session or native subagent unless assigned.

## Assignment types

A discovered skill can be assigned in three ways.

| Assignment | Meaning | Runtime effect |
|---|---|---|
| Default | The skill is available to every parent Pi Agent session. | Parent sessions receive `--skill <path>`. |
| Project | The skill is available to parent Pi Agent sessions for one project. | Parent sessions for that project receive `--skill <path>`. |
| Agent | The skill is available to one native subagent. | That child process receives `--skill <path>` when the agent runs. |

Unassigned skills are visible in the catalog but are not injected anywhere.

Default skills are not automatically assigned to agents. Native agents receive only skills explicitly assigned to that agent.

## Parent Pi Agent sessions

Parent sessions receive:

```text
Default skills
+ skills assigned to the current project
```

Agent Deck launches parent Pi RPC sessions with:

```text
--no-skills
--skill <default-skill-path>
--skill <project-skill-path>
```

Parent sessions do not receive:

- unassigned skills,
- skills assigned only to another project,
- skills assigned only to native agents,
- package/user/project skills merely because Pi could discover them on disk.

Example:

```text
pi --mode rpc \
  --no-skills \
  --skill /Users/me/.pi/agent/skills/default-review/SKILL.md \
  --skill /Users/me/projects/app/.pi/skills/app-patterns/SKILL.md
```

## Native subagents

Native subagents receive only their own assigned skills.

Agent skills are stored on the agent as `skills:` names:

```yaml
---
name: reviewer
description: Reviews diffs and implementation plans
tools: read, grep, find, ls, bash, contact_supervisor
skills: review-guidelines, app-patterns
systemPromptMode: replace
---
```

When that agent runs, Agent Deck resolves the skill names to catalog entries and launches the child with:

```text
--no-skills
--skill <review-guidelines-path>
--skill <app-patterns-path>
```

Native subagents do not inherit Default skills or Project skills automatically. If a subagent needs a skill, assign that skill to the agent.

The `inheritSkills` frontmatter field is preserved for compatibility, but current Agent Deck child launches always use `--no-skills` plus explicit agent-assigned `--skill` arguments. Ambient skill discovery is not used for native subagents.

## Native Pi skill behavior

Agent Deck uses Pi's native skill mechanism.

Explicit `--skill <path>` arguments are honored even when `--no-skills` is present:

```text
--no-skills
--skill /path/to/SKILL.md
```

Pi adds the skill to its native skill catalog in the system prompt, similar to:

```xml
<available_skills>
  <skill>
    <name>agent-authoring</name>
    <description>Use when creating or reviewing Agent Deck native agents.</description>
    <location>/path/to/agent-authoring/SKILL.md</location>
  </skill>
</available_skills>
```

Pi does not paste the full skill body into the initial system prompt. The model uses the `read` tool to load the full skill file when the skill is relevant.

This also applies to native subagents whose `systemPromptMode` is `replace`: `--system-prompt` replaces Pi's base prompt, and Pi still appends the explicit skill catalog after that prompt.

## Read tool requirement

Because Pi's native skill system points the model at a skill file, any runtime with assigned skills must be able to use the `read` tool.

Parent sessions normally have `read` available.

For native subagents:

- If tools are omitted, Pi's normal tool behavior applies and skills can be loaded.
- If tools are explicitly allowlisted, the list must include `read` when the agent has assigned skills.
- If `tools: []` or an allowlist without `read` is used with assigned skills, Agent Deck blocks the launch and shows an error.

Example error:

```text
Agent `reviewer` has assigned skills but cannot load them because its tool allowlist does not include `read`. Add `read` to the agent tools or remove the assigned skills.
```

Agent Deck does not silently add `read`, because that would change the agent's declared tool boundary.

## Duplicate skill names

Skill assignments are resolved by skill name.

If two catalog entries have the same name, Agent Deck treats that as ambiguous.

Behavior:

- The sidebar and Skills UI show a warning.
- Any launch that would need the ambiguous skill is blocked.
- Agent Deck does not pick a winner silently.

Example:

```text
Cannot launch Pi session because skill `agent-authoring` is ambiguous.

Matching skills:
- Bundled: /Applications/Agent Deck.app/.../bundled-skills/agent-authoring/SKILL.md
- User: /Users/me/.pi/agent/skills/agent-authoring/SKILL.md

Rename one skill or remove one assignment, then try again.
```

## Helpers

Session title generation and commit-message generation remain isolated helper sessions.

They launch with:

```text
--no-skills
--no-tools
--no-session
```

They never receive assigned skills.

## Runtime matrix

| Runtime | Skill behavior |
|---|---|
| Parent Pi Agent session | `--no-skills` + `--skill` for Default and current Project assignments. |
| Native subagent child | `--no-skills` + `--skill` for that agent's assigned skills only. |
| Session title helper | `--no-skills`, no `--skill`. |
| Commit-message helper | `--no-skills`, no `--skill`. |
