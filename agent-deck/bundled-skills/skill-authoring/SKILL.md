---
name: skill-authoring
description: Create or improve Agent Deck/Pi skills, including where to save them, SKILL.md frontmatter, simple vs modular structure, and validation.
---

# Skill authoring

Use this skill when the user wants to create, convert, review, or validate an Agent Deck/Pi skill.

## Choose the save location

First decide whether the skill is project-specific or global. If the user's intent is unclear, ask before creating files.

Use a global personal skill when the skill should be reusable across projects:

```text
~/.pi/agent/skills/<skill-name>/SKILL.md
```

Use a project skill when the skill is specific to one repository, codebase, team convention, or local workflow:

```text
<project>/.pi/skills/<skill-name>/SKILL.md
```

Use a non-standard path only when the user explicitly asks for one. Warn that Agent Deck will not discover that skill unless the path is also configured/imported as an external skill:

```text
/path/to/skills/<skill-name>/SKILL.md
```

Read compatibility locations such as `.agents/skills/<skill-name>/SKILL.md` when reviewing existing skills, but do not create new skills there unless the user explicitly asks for legacy compatibility.

After creating a skill, tell the user where it was saved and whether it still needs Default, Project, or Agent assignment in Agent Deck before it is injected into a runtime session.

Ask the user when any of these are unclear:

- whether the skill should be global or project-specific
- the target project when creating a project skill
- whether the user really wants a non-standard path, with a warning that Agent Deck will not discover it unless configured/imported as an external skill
- the skill's scope, activation trigger, or expected workflow
- whether a complex skill should be modular or kept simple

## Basic format

Use a directory named exactly like the skill, containing `SKILL.md`:

```text
<skill-name>/
  SKILL.md
```

Every `SKILL.md` needs frontmatter at the top. Keep the description specific enough that the model knows when to use the skill:

```md
---
name: my-skill
description: Use when creating or validating Foo configuration for Bar projects.
---

# My Skill

Use this skill when the user asks for Foo configuration help.
```

Rules:

- `name` is required.
- `description` is required and should explain when to use the skill, not just what it is.
- The directory name must match `name`.
- Use lowercase letters, numbers, and hyphens for the skill name.
- Keep the skill focused on one domain or workflow.
- Do not put permanent project instructions in a skill when `AGENTS.md` or project documentation is the right home.

## Simple skill pattern

Use a single-file skill when the instructions are short and likely to fit comfortably in context:

```text
my-skill/
  SKILL.md
```

Good contents:

- when to use the skill
- required inputs or files
- concise workflow
- one or two examples
- validation checklist

## Modular skill pattern

Use a modular skill when the guidance is broad, reference-heavy, or split across domains. Keep `SKILL.md` as a router and put detailed guidance in sibling files or subdirectories:

```text
domain-expert/
  SKILL.md
  workflows/
    create.md
    review.md
  references/
    concepts.md
    examples.md
  checklists/
    validation.md
    release.md
```

The top-level `SKILL.md` should:

- explain activation criteria
- list available modules
- tell the model which files to read for each user need
- avoid copying all module content into the top-level file

Use relative paths in module lists so the model can read only the relevant files:

```md
## Available Modules

Read relevant module files based on the user's request:

### workflows/
- `create.md` - Creation workflow and required decisions
- `review.md` - Review workflow and common issues

### references/
- `concepts.md` - Background concepts and terminology
- `examples.md` - Representative examples

### checklists/
- `validation.md` - Validation steps before completion
- `release.md` - Release or handoff checklist
```

This keeps the initial skill small and delegates token-heavy reference material to files the model reads only when needed.

## Authoring workflow

1. Choose a short, stable kebab-case skill name.
2. Decide whether it is a global skill or a project skill; ask if unclear.
3. Write frontmatter with a specific use-triggering description.
4. Decide whether the skill should be simple or modular.
5. For simple skills, keep the workflow in `SKILL.md`.
6. For modular skills, keep `SKILL.md` as a router and create focused reference files.
7. Validate the directory name, frontmatter name, description, and Markdown structure.
8. Tell the user where the skill was created and whether it still needs Default, Project, or Agent assignment in Agent Deck.

## Agent Deck assignment notes

Do not over-explain runtime internals in ordinary user-facing skills. Only mention assignment when it affects what the user must do next:

- Bundled or external catalog skills are not injected until assigned.
- Default assignment makes the skill available to parent sessions across projects.
- Project assignment makes it available to parent sessions for one project.
- Agent assignment makes it available to one native subagent.
- Native subagents with assigned skills need `read` in their tool allowlist so the skill file can be loaded.

## Validation checklist

- The file is named `SKILL.md`.
- The parent directory matches `name:`.
- Frontmatter is the first content in the file.
- `description:` is present, specific, and use-oriented.
- Simple skills are not over-engineered.
- Modular skills list their modules clearly and use relative paths.
- Large reference content is delegated to focused files instead of pasted into `SKILL.md`.
- The final response states the file path and any needed Agent Deck assignment.
