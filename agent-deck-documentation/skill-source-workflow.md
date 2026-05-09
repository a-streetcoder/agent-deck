# Skill Source Workflow

Agent Deck separates a skill's **source copy** from the places where Pi loads active skills.

This keeps reusable skills easy to update while still letting users decide whether a skill is active globally or only for specific projects.

## Core idea

A skill has three possible roles:

1. **Source** — the upstream or editable copy of the skill, often a cloned repository or a folder chosen during import.
2. **Library** — Agent Deck's reusable copy/reference for skills that are available to assign.
3. **Active link** — the location Pi actually scans when starting a session.

Only active links are loaded by Pi. A skill that exists only as source or only in the library is stored, but not automatically active.

## Default active locations

Pi-compatible skill locations are:

```text
~/.pi/agent/skills/<skill>/SKILL.md          # active globally
PROJECT/.pi/skills/<skill>/SKILL.md         # active for one project
```

Agent Deck also understands legacy/global compatibility locations where supported by Pi, but new managed skills should prefer the `.pi` paths above.

## Agent Deck library location

Agent Deck stores reusable library skills under:

```text
~/.pi/agent/skill-library/<skill>/SKILL.md
```

This library path is not an active Pi scan location by itself. Agent Deck makes a library skill active by creating symlinks from Pi's active locations back to the library skill directory.

Typical links:

```text
~/.pi/agent/skills/<skill>          -> ~/.pi/agent/skill-library/<skill>
PROJECT/.pi/skills/<skill>         -> ~/.pi/agent/skill-library/<skill>
```

Agent Deck links the **skill directory**, not just `SKILL.md`, so supporting files inside the skill folder continue to work.

## Source-managed skills

For skills maintained from an upstream repository, the preferred public pattern is:

```text
<chosen source folder>/<repo>/skills/<skill>/SKILL.md
~/.pi/agent/skills/<skill>          -> <chosen source folder>/<repo>/skills/<skill>
```

or, if managed through Agent Deck's library:

```text
~/.pi/agent/skill-library/<skill>   -> <chosen source folder>/<repo>/skills/<skill>
~/.pi/agent/skills/<skill>          -> ~/.pi/agent/skill-library/<skill>
```

Use this when the skill should update by pulling the upstream repository rather than by copying files again.

Agent Deck should not assume a hard-coded source folder. The user can choose a default import folder in settings. If no custom folder is set, Agent Deck falls back to the last used folder and then the user's Documents folder.

## Import vs symlink

Use a **copy/import** when:

- the user wants Agent Deck to own the editable library copy
- the source is temporary, downloaded, or not version-controlled
- the skill should remain stable even if the original folder changes

Use a **symlink** when:

- the source is a git checkout or package-managed folder
- the user expects updates via `git pull` or a package manager
- supporting files should stay in the upstream layout

## Visibility rules

A library/source skill can be made visible in two ways:

- **Enable globally**: create or keep a link in `~/.pi/agent/skills/<skill>`.
- **Assign to project**: create or keep a link in `PROJECT/.pi/skills/<skill>`.

Agents reference skills by name only:

```yaml
skills: example-skill
```

That reference does not copy, bundle, or activate the skill. The skill must be visible in the selected global or project scope at runtime.

## Updating source-managed skills

For a git-backed source skill:

```bash
cd <chosen source folder>/<repo>
git pull --ff-only
```

Then refresh Agent Deck or reload the running Pi session so the updated `SKILL.md` is discovered.

## Safety notes

- Do not create duplicate active copies of the same skill name in the same scope.
- Prefer directory skills with `SKILL.md`; this preserves references to helper files.
- When replacing an existing active skill, check whether it is a real directory or a symlink before deleting it.
- Public documentation should describe paths with `~` and `PROJECT` placeholders, not machine-specific absolute paths.
