# Skills

Skills are reusable instruction bundles. The normal convention is a directory with a `SKILL.md` file.

## Active vs library skills

- **Active global skills** are visible to Pi everywhere.
- **Active project skills** are visible only inside a selected project.
- **Library skills** are centrally stored by Agent Deck and become active only when linked globally or into a project.

Library storage:

```text
~/.pi/agent/skill-library/<skill>/SKILL.md
```

Active targets:

```text
~/.pi/agent/skills/<skill>/SKILL.md
PROJECT/.pi/skills/<skill>/SKILL.md
```

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

means “inject the visible skill named `axiom-ai` when this agent runs.” It does not bundle or copy the skill when the agent is assigned to a project. See [Pi core prompt assembly](../reference/pi-core-prompt-assembly.md) for how `--no-skills` and explicit `--skill` paths interact.
