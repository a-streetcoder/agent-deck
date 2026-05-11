# Agents, Chains, Skills, and Prompts

Agent Deck's resource screens expose the files and settings that shape Pi behavior.

## Agents

Agents are Markdown files with frontmatter and a system prompt body. Agent Deck shows raw agent records and an effective resolved agent view that accounts for builtin agents, custom replacements, and settings overrides.

See [Agents](agents.md) and [Agent frontmatter](../reference/agent-frontmatter.md).

## Chains

Chains are `.chain.md` files that describe multi-step workflows. Agent Deck manages global, project, and library chain locations and can run native chains as app-owned graph executions.

See [Chains](chains.md).

## Skills

Skills are named instruction bundles, normally a directory containing `SKILL.md`. Agents can reference skills by name. Agent Deck injects only assigned skills into parent sessions or native subagents; an agent reference does not automatically copy the skill file.

See [Skills](skills.md).

## Prompts and commands

Pi uses slash-prefixed entries for several different things: built-in commands, extension commands, prompt templates, and skill invocations. Agent Deck surfaces extension commands and file-backed prompt templates in the Prompts screen.

See [Prompts and commands](prompts-and-commands.md).
