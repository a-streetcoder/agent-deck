# Agents

Agents define reusable roles for Pi and for Agent Deck native subagents.

An agent is usually a Markdown file with YAML frontmatter plus a system prompt body.

## Types of agents

Agent Deck may show agents from these scopes:

- **Builtin** — app-bundled starter agents; read-only. Pi packages can contribute other resource types, but Agent Deck currently loads agent builtins from the app bundle.
- **Global** — active everywhere
- **Project** — active only inside the selected project
- **Library** — stored centrally by Agent Deck, not active until linked or assigned
- **Override** — settings-based changes applied to a builtin
- **Legacy** — compatibility locations such as `.agents`

## Bundled native starter agents

Agent Deck ships four native starter agents:

| Agent | Purpose |
|---|---|
| `explorer` | Fast codebase reconnaissance and compact context handoff |
| `planner` | Creates implementation plans without editing files |
| `coder` | Makes approved scoped changes |
| `reviewer` | Reviews diffs, plans, or implementations with evidence-backed findings |

These are treated as builtin agents in the effective list. Same-name global/project agents can replace them, and builtin override controls can patch supported fields.

## Replacement vs override

- A **custom replacement** is a same-name global/project agent that wins over a builtin.
- A **builtin override** writes only changed fields into settings under `subagents.agentOverrides`.

Agent Deck should never edit read-only builtin files directly.

## Effective agent view

The effective view answers: “What will run for this agent name in this project?” Project custom agents win over global custom agents, and global custom agents win over builtins. Builtin overrides patch supported fields only when the builtin remains the winner. The view combines:

- builtin definition
- global custom definition
- project custom definition
- global/project override records
- disable-builtin flags

## Skills on agents

An agent can list explicit skills:

```yaml
skills: axiom-ai, axiom-swiftui
```

These are name references. The skill must be visible globally, visible in the selected project, or supplied by a scanned package/settings source. A skill that exists only in Agent Deck's library is not active until linked.
