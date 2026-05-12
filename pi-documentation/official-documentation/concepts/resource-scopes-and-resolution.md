# Resource Scopes and Resolution

Agent Deck's UI is built around scope and resolution: where a resource lives, whether Pi can see it, and which definition wins.

## Scopes

| Scope | Meaning |
|---|---|
| Builtin | App-bundled native agents and other read-only builtins. Agent Deck currently loads agent builtins from the app bundle; packages may still contribute non-agent resources such as skills, prompts, and extensions. |
| Global | Discovered from global locations; assignment state decides whether agents/skills/prompts are used everywhere |
| Project | Discovered from one project; assignment state decides whether agents/skills/prompts are used there |
| Legacy Project | Compatibility resource from `.agents` paths |
| Override | Settings-based patch to a builtin |
| Package | Resource contributed by an installed Pi package |
| Library | Agent Deck storage, not automatically active |

## Catalog vs assignment

Library resources are reusable storage. Global/project files are catalog sources. For agents, skills, and prompts, Agent Deck stores default/project assignments separately from the files themselves; assigning them does not create symlinks or move files.

## Agent precedence

For agent names that appear in multiple places, the native-subagent winning definition is:

1. project-assigned custom agent
2. default-assigned custom agent
3. builtin agent

For same-name assigned catalog records, project assignment prefers project files before library/global files; default assignment prefers library/global files.

Builtin overrides are different from custom replacements: they patch supported fields only when the builtin remains the winner. Project overrides beat global overrides. Builtin-disable flags can hide builtins entirely.

## Skill references

Skill names in agent frontmatter are references. Assigning an agent to a project does not automatically assign its referenced skills.

## Prompt and command collisions

Prompt template names become slash names. Extension commands, skill commands, and built-in commands may share the same slash-shaped namespace. Runtime Pi behavior is authoritative; Agent Deck separately shows file-backed prompt templates and runtime extension commands.
