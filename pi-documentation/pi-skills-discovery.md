# Pi Skills Discovery Reference

This document captures where Pi discovers skills, how global vs project scope works, and the key discovery rules that matter when debugging collisions with other resource types.

---

## Main discovery locations

Pi loads skills from five categories of sources:

1. built-in global locations
2. built-in project locations
3. installed packages
4. settings-defined paths
5. CLI-provided paths

---

## Global skill locations

Pi discovers global/user skills from:

- `~/.pi/agent/skills/`
- `~/.agents/skills/`

### Global discovery rules

#### `~/.pi/agent/skills/`
Pi supports both:
- root `*.md` files as individual skills
- nested directories containing `SKILL.md`

#### `~/.agents/skills/`
Pi supports:
- recursive discovery of directories containing `SKILL.md`
- **does not** treat root `*.md` files as skills here

This distinction matters because `~/.agents/skills/` is treated more strictly than `~/.pi/agent/skills/`.

---

## Project skill locations

Pi discovers project skills from:

- `.pi/skills/`
- `.agents/skills/` in the current working directory and ancestor directories

### Project discovery rules

#### `.pi/skills/`
Pi supports both:
- root `*.md` files as individual skills
- nested directories containing `SKILL.md`

#### `.agents/skills/`
Pi searches:
- the current directory
- parent directories above it
- up to the git repo root when inside a git repo
- or up to filesystem root when not in a repo

For project `.agents/skills/`, Pi:
- recursively discovers directories containing `SKILL.md`
- **ignores** root `*.md` files

---

## Package-based skill discovery

Installed Pi packages can contribute skills via:

- a conventional `skills/` directory
- `package.json -> pi.skills`

### Package rules

If a package has no explicit `pi.skills` manifest entry, Pi can auto-discover from the conventional `skills/` directory.

In package skill directories, Pi:
- recursively finds directories containing `SKILL.md`
- also loads top-level `.md` files as skills

---

## Settings-based skill discovery

Pi can also load custom skill paths from settings files:

- global settings: `~/.pi/agent/settings.json`
- project settings: `.pi/settings.json`

Example:

```json
{
  "skills": [
    "./skills",
    "../shared-skills",
    "~/.claude/skills",
    "~/.codex/skills"
  ]
}
```

These entries can point to either:
- a skill file
- a directory of skills

Paths in global settings resolve relative to `~/.pi/agent`.
Paths in project settings resolve relative to `.pi/`.
Absolute paths and `~` are also supported.

---

## CLI-based skill discovery

Pi can load skills directly from the command line with:

- `--skill <path>`

This flag is:
- repeatable
- additive
- still honored even when `--no-skills` is used

So `--no-skills` disables normal discovery, but explicit `--skill` paths still load.

---

## Important discovery rules

### 1. `SKILL.md` is the main skill-root convention
A skill is normally a directory containing `SKILL.md`.

### 2. Root markdown behavior depends on location
Root `*.md` files are supported in:
- `~/.pi/agent/skills/`
- `.pi/skills/`
- package `skills/` directories

Root `*.md` files are ignored in:
- `~/.agents/skills/`
- project `.agents/skills/`

### 3. Recursive discovery stops at skill roots
When Pi finds a directory containing `SKILL.md`, that directory is treated as the skill root. Pi should not keep recursing past it looking for nested child skills inside the same skill.

### 4. Name collisions keep the first discovered skill
If the same skill name is found in multiple places, Pi warns and keeps the first one it discovered.

### 5. Discovery can be disabled
Use:

```bash
pi --no-skills
```

But explicit `--skill` paths still work.

---

## Precedence and mental model

Useful mental model:

- Pi has its own native skill locations under `.pi`
- Pi also supports legacy/shared `.agents/skills` locations
- packages, settings, and CLI flags can all add more sources

The biggest practical difference is:

- `.pi/skills/` is a Pi-native skill area
- `.agents/skills/` is a compatibility/shared skill area

That distinction matters because some third-party packages may also scan `.agents/` for non-skill resources, which can create collisions.

---

## Explicit skills on native subagents

Pi Manager native agents can declare explicit skills in agent frontmatter:

```yaml
skills: axiom-ai
```

or receive skills from a native subagent/chain task override.

This is a **name reference**, not a file dependency. At execution time, Pi Manager resolves the name against the current scan snapshot for the selected project/session.

Therefore:

| Case | Result |
|---|---|
| Skill is enabled globally | works everywhere |
| Skill is assigned to the same project | works in that project |
| Skill is assigned only to a different project | missing outside that project |
| Skill exists only in Pi Manager's `skill-library` | missing until linked globally or into the project |
| Agent is assigned to a project | the agent moves/links, but its referenced skills do not automatically move with it |

Important distinction:

- `skills: axiom-ai` tells the child run to inject the full `axiom-ai` skill content, if resolvable.
- `inheritSkills: true` only controls whether the child keeps Pi's ambient discovered skills catalog in its prompt.
- Neither setting makes an inactive library skill visible.

For Pi Manager specifically, reusable library skills live in:

```text
~/.pi/agent/skill-library/<skill>
```

That folder is storage only. A library skill becomes runtime-visible only when Pi Manager symlinks it into:

```text
~/.pi/agent/skills/<skill>
PROJECT/.pi/skills/<skill>
```

---

## Collision note for legacy `.agents` paths

Pi core skill discovery looks in:
- `~/.agents/skills/`
- project `.agents/skills/`

Pi Manager also scans legacy `.agents/*.md` agent files. A repository or home-directory layout using `.agents` for multiple resource types should keep skills under `.agents/skills/` and agents at `.agents/*.md` to avoid ambiguous discovery.

---

## Recommended safe layout

If you want the lowest confusion:

### Skills
Use:
- `~/.pi/agent/skills/`
- `.pi/skills/`

### Subagents
Use:
- `~/.pi/agent/agents/`
- `.pi/agents/`

### Legacy/shared compatibility
Only use these when you intentionally want compatibility behavior:
- `~/.agents/skills/`
- project `.agents/skills/`
- `~/.agents/`
- project `.agents/`

---

## Short reference table

| Type | Global | Project | Notes |
|---|---|---|---|
| Pi-native skills | `~/.pi/agent/skills/` | `.pi/skills/` | supports root `.md` and `SKILL.md` directories |
| Legacy/shared skills | `~/.agents/skills/` | `.agents/skills/` in cwd + ancestors | ignores root `.md`, uses recursive `SKILL.md` discovery |
| Package skills | package `skills/` or `pi.skills` | package `skills/` or `pi.skills` | package-provided |
| Settings paths | `~/.pi/agent/settings.json -> skills` | `.pi/settings.json -> skills` | custom file/dir sources |
| CLI paths | `--skill <path>` | `--skill <path>` | explicit, additive |

---

## Source basis

This document is based on Pi documentation in:
- `docs/skills.md`
- `docs/packages.md`
- `docs/settings.md`
- `docs/sdk.md`
- relevant Pi changelog notes about skill discovery behavior
