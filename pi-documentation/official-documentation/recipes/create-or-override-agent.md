# Recipe: Create or Override an Agent

## Create a project agent

Use this when the agent is specific to one repository.

1. Select the project in Agent Deck.
2. Open **Agents**.
3. Create a new project agent.
4. Give it a stable `name`, clear `description`, and compact system prompt.
5. Add explicit `skills` only if those skills are active for the project or global scope.

Project agents live in:

```text
PROJECT/.pi/agents/<name>.md
```

## Create a reusable library agent

Use the library when you want one canonical resource that can later be enabled globally or assigned to projects.

Library agents live in:

```text
~/.pi/agent/agent-library/agents/<name>.md
```

## Override a builtin

Use builtin overrides for small changes to Agent Deck's bundled builtin agents.

Agent Deck writes override fields to settings, not to the bundled source file:

```text
~/.pi/agent/settings.json
PROJECT/.pi/settings.json
```

Typical override fields include model, thinking level, tools, extensions, skills, context/skill inheritance, output, and default reads/progress.

## Replace a builtin

Create a same-name global or project custom agent when you need a substantially different prompt or behavior. The custom agent wins in the effective resolution for its scope.
