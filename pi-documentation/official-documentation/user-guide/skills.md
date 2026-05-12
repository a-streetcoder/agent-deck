# Skills

Skills are reusable instruction bundles. The normal convention is a directory with a `SKILL.md` file.

## Active and assigned skills

- **Global catalog skills** are discovered from user-wide paths.
- **Project catalog skills** are discovered inside a selected project.
- **Bundled and external skills** can appear in Agent Deck's catalog, but they are not injected unless assigned.

Catalog targets:

```text
~/.pi/agent/skills/<skill>/SKILL.md
PROJECT/.pi/skills/<skill>/SKILL.md
```

Agent Deck also ships bundled catalog skills such as `agent-authoring`, `prompt-authoring`, and `skill-authoring`. Discovery alone does not inject them into Pi; assign them as Default, Project, or Agent skills when they should be available at runtime.

## Discovery rules that matter

- `.pi/skills/` supports root `.md` files and directories containing `SKILL.md`.
- `.agents/skills/` supports recursive `SKILL.md` directories but ignores root `.md` files.
- Package skill directories can contribute both top-level `.md` files and `SKILL.md` directories.
- Settings can add skill files or directories through `settings.json -> skills`.
- CLI `--skill <path>` can load explicit skills, and explicit skill paths are still honored even with `--no-skills`.
- Duplicate names keep the first discovered skill and produce warnings.

## Agent skill references

Agent frontmatter like this:

```yaml
skills: axiom-ai
```

means “inject the visible skill named `axiom-ai` when this agent runs.” It does not bundle or copy the skill when the agent is assigned to a project. See [Agent Deck system prompt logic](../../../agent-deck-documentation/agent-deck-system-prompt-logic.md) for how `--no-skills` and explicit `--skill` paths interact.
