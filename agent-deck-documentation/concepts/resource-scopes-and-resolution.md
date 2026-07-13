# Resource Scopes and Resolution

Agent Deck's UI is built around scope and resolution: where a resource lives, whether Pi can see it, and which definition wins.

## Scopes

| Scope | Meaning |
|---|---|
| Builtin | App-bundled native agents and other read-only builtins. Agent Deck currently loads agent builtins from the app bundle; packages may still contribute non-agent resources such as skills, prompts, and extensions. |
| Global | Discovered from global locations; assignment state decides whether agents/skills/prompts are used everywhere |
| Override | Settings-based patch to a builtin |
| Package | Resource contributed by an installed Pi package |
| Library / imported catalog | Agent Deck storage or explicit by-reference imports, not automatically active |

## Catalog vs assignment

Global, package, library, and imported resources are catalog sources. Project-specific availability is assignment metadata on those catalog resources. Agent Deck does not discover project-local `.pi/agents`, `.pi/skills`, `.pi/prompts`, or legacy project `.agents` folders as resource catalog sources. Importing an existing local file adds it by reference; assigning it does not create symlinks, move files, or copy files.

## Agent precedence

For agent names that appear in multiple places, the native-subagent winning definition is:

1. project-assigned custom catalog agent
2. default-assigned custom catalog agent
3. builtin agent

For same-name assigned catalog records, Agent Deck prefers library/global catalog records; project assignment controls where the selected catalog record is available, not which local file wins.

Builtin overrides are different from custom replacements: Agent Deck writes and applies supported builtin patches only in global settings when the builtin remains the winner. It ignores project `.pi/settings.json` `subagents` configuration (including overrides and `disableBuiltins`) and never rewrites those project settings. Builtin-disable flags are global-only.

## Skill references

Skill names in agent frontmatter are references. Assigning an agent to a project does not automatically assign its referenced skills.

## Prompt and command collisions

Prompt template names become slash names. Extension commands, skill commands, and built-in commands may share the same slash-shaped namespace. Runtime Pi behavior is authoritative; Agent Deck separately shows file-backed prompt templates and runtime extension commands.
