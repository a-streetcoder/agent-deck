# Resource Scopes and Resolution

Agent Deck's UI is built around scope and resolution: where a resource lives, whether Pi can see it, and which definition wins.

## Scopes

| Scope | Meaning |
|---|---|
| Builtin | App-bundled native agents and other read-only builtins. Agent Deck currently loads agent builtins from the app bundle; packages may still contribute non-agent resources such as skills, prompts, and extensions. |
| Global | Active for all projects |
| Project | Active only inside one project |
| Legacy Project | Compatibility resource from `.agents` paths |
| Override | Settings-based patch to a builtin |
| Package | Resource contributed by an installed Pi package |
| Library | Agent Deck storage, not automatically active |

## Active vs library

Library resources are reusable storage. Active resources are visible to Pi at runtime.

Agent Deck commonly stores a canonical resource in a library folder under `~/.pi/agent/` and then creates symlinks into global or project active locations.

## Agent precedence

For agent names that appear in multiple places, the winning definition is:

1. project custom agent
2. global custom agent
3. builtin agent

Within a scope, Agent Deck treats `.pi` project agents before legacy project `.agents`, and `~/.agents` before `~/.pi/agent/agents` for global agents.

Builtin overrides are different from custom replacements: they patch supported fields only when the builtin remains the winner. Project overrides beat global overrides. Builtin-disable flags can hide builtins entirely.

## Skill references

Skill names in agent frontmatter are references. Assigning an agent to a project does not automatically assign its referenced skills.

## Prompt and command collisions

Prompt template names become slash names. Extension commands, skill commands, and built-in commands may share the same slash-shaped namespace. Runtime Pi behavior is authoritative; Agent Deck separately shows file-backed prompt templates and runtime extension commands.
