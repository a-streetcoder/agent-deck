---
name: skill-authoring
description: Create or improve Agent Deck/Pi skills, including where to save them, SKILL.md frontmatter, simple vs modular structure, and validation.
---

# Skill authoring

Use this skill when the user wants to create, convert, review, or validate an Agent Deck/Pi skill.

## Choose catalog location and assignment

Before creating a new skill, explicitly ask the user whether the skill should be enabled for all projects by default unless they already gave an unambiguous preference. Do not ask whether it is a "personal" skill: Agent Deck treats user-authored skills as catalog resources, then controls runtime use through assignment metadata.

For new user-authored skills, create the skill in the normal global Agent Deck/Pi skills catalog:

```text
~/.pi/agent/skills/<skill-name>/SKILL.md
```

Then explain or apply the requested assignment:

- Default / All Projects — the skill is injected into parent sessions for every project.
- Unassigned catalog skill — the skill is visible in the catalog but is not injected until the user manually assigns it to All Projects, a specific project, or a native agent.
- Project assignment — the skill is injected into parent sessions for one project.
- Agent assignment — the skill is injected into one native subagent.

Do not infer project-local just because the current working directory is a repository. Agent Deck no longer discovers project-local `.pi/skills` as a resource catalog source.

Use a non-standard external path only when the user explicitly asks to keep an existing skill or skill collection where it already lives. Warn that Agent Deck will not discover that skill unless the path is imported through Agent Deck’s `+` import flow; imports are catalog references, not copies:

```text
/path/to/skills/<skill-name>/SKILL.md
```

Read compatibility locations such as `.agents/skills/<skill-name>/SKILL.md` when reviewing existing skills, but do not create new project-local skills there. Create new skills in the global catalog path unless the user explicitly asks for an external imported-by-reference source.

After creating a skill, tell the user where it was saved and whether it is Default / All Projects, Project-assigned, Agent-assigned, or still unassigned in the catalog.

Ask the user when any of these are unclear:

- whether the new skill should be enabled for All Projects by default or left unassigned in the catalog for manual assignment
- whether the user really wants a non-standard external path, with a warning that Agent Deck will not discover it unless configured/imported as an external skill
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
2. Create new skills under `~/.pi/agent/skills/<skill-name>/SKILL.md` unless the user explicitly requested an external imported-by-reference source.
3. Decide whether the skill should be enabled for All Projects by default or left unassigned in the catalog; ask if unclear.
4. Write frontmatter with a specific use-triggering description.
5. Decide whether the skill should be simple or modular.
6. For simple skills, keep the workflow in `SKILL.md`.
7. For modular skills, keep `SKILL.md` as a router and create focused reference files.
8. Validate the directory name, frontmatter name, description, and Markdown structure.
9. Tell the user where the skill was created and whether it is Default / All Projects, Project-assigned, Agent-assigned, or still unassigned in Agent Deck.

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
