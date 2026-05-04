# Pi Manager resource management: active vs library vs project

This is the app-specific reference for how **Pi Manager actually manages** agents, chains, skills, and prompt templates.

It is intentionally different from the broader Pi / `pi-subagents` runtime docs.

Those runtime docs explain everything Pi *can* discover.
This file explains the narrower model Pi Manager uses to keep things understandable:

1. **Builtin** resources shipped by packages
2. **Active global** resources Pi sees everywhere
3. **Library** resources stored centrally by Pi Manager and activated with symlinks
4. **Ad-hoc project** resources that only exist for one repo

If you want to understand the current app UX, start here.

---

## The mental model

Pi Manager treats reusable resources and active resources as different things.

- **Library** = central storage managed by the app
- **Active global** = visible to Pi everywhere
- **Active project** = visible only inside one project
- **Builtin** = package-owned, read-only

For reusable resources, the app usually wants this flow:

1. store the canonical copy in a **library** folder under `~/.pi/agent/`
2. expose it globally or per-project by creating a **symlink** into Pi's active discovery paths

That gives you one canonical file plus explicit visibility.

---

## The three practical buckets

### 1. Builtins

These come from installed packages and are read-only.

- Agents: `/opt/homebrew/lib/node_modules/pi-subagents/agents/`
- Package skills/prompts: discovered from packages listed in settings

Pi Manager never edits builtin package files directly.
For builtin agents it writes overrides to settings, or creates custom replacements.

### 2. Global active resources

These are the things Pi sees without selecting a project.

They may be:
- regular files/directories created directly in a global path
- or symlinks that point back into a Pi Manager library folder

### 3. Project-only resources

These are repo-scoped files or symlinks under that project's `.pi/` folder.

They are intentionally ad-hoc.
They are the right place for one-off experiments, repo-specific specialists, and local workflow helpers.

---

## Exact paths Pi Manager uses

## Agents

### Builtin
- `/opt/homebrew/lib/node_modules/pi-subagents/agents/*.md`

### Active global
- preferred write target: `~/.agents/*.md` **if `~/.agents` exists**
- fallback write target: `~/.pi/agent/agents/*.md`

### Library
- `~/.pi/agent/agent-library/agents/*.md`

### Project
- `PROJECT/.pi/agents/*.md`
- app also scans legacy project agents in `PROJECT/.agents/*.md`

### Important nuance
On this machine, `~/.agents` exists, so Pi Manager currently prefers it for new global agents and global agent symlinks.

---

## Chains

### Active global
- `~/.pi/agent/chains/*.chain.md`

### Library
- `~/.pi/agent/agent-library/chains/*.chain.md`

### Project
- `PROJECT/.pi/chains/*.chain.md`

### Important nuance
This is an **app-level choice**.
Pi Manager manages chains in `~/.pi/agent/chains` and `PROJECT/.pi/chains`.
That is clearer than mixing them into agent folders.

Also important: the current app scanner does **not** actively discover legacy chain files in `.agents/`, even though some older docs talk about those runtime locations.

---

## Skills

### Active global
- `~/.pi/agent/skills/<skill>/SKILL.md`
- legacy global skills are also scanned from `~/.agents/skills/`

### Library
- `~/.pi/agent/skill-library/<skill>/SKILL.md`

### Project
- `PROJECT/.pi/skills/<skill>/SKILL.md`
- root `PROJECT/.pi/skills/<name>.md` also scans as a standalone skill

### Important nuance
Pi Manager's reusable-skill model is directory-based.
When it activates a library skill globally or for a project, it creates a symlink for the **skill directory**, not just the markdown file.

---

## Prompt templates

### Active global
- `~/.pi/agent/prompts/*.md`

### Library
- `~/.pi/agent/prompt-library/*.md`

### Project
- `PROJECT/.pi/prompts/*.md`

### Package/settings discovery
For prompts, Pi Manager also scans:
- package prompt folders from packages listed in settings
- explicit prompt paths from `settings.json -> prompts`

---

## What “move to library” actually does

Pi Manager uses different behavior depending on where the resource started.

## Agents / chains / prompts

When importing a resource into the library:

- if it started as a **global** resource, Pi Manager usually **moves** it into the library
- if it started as a **project** resource, Pi Manager usually **copies** it into the library
- if it is already a **library** resource, Pi Manager keeps it there

Then global/project visibility is controlled with symlinks.

Why:
- global resources are usually being promoted into a reusable canonical copy
- project resources usually need to keep their local copy unless you deliberately replace them

## Skills

Skills follow the same idea, but at the skill-root level:
- directory skill: move/copy the whole directory
- standalone `.md` skill: wrap it into a library folder as `SKILL.md`

---

## What “enable globally” or “assign to project” means

For library-managed resources, Pi Manager treats **global visibility** and **project visibility** as mutually exclusive, but project assignment itself is **not** exclusive.

- **Enable globally**
  - creates a global symlink into the library
  - removes managed project-level visibility for that same resource from currently enabled projects

- **Assign to project**
  - creates a project symlink into the library
  - removes managed global visibility for that same resource
  - can be repeated for multiple projects at once

So the real rule is:
- one reusable resource is either globally active or project-assigned
- but it may be assigned to multiple projects simultaneously

---

## Symlink targets by resource type

### Agents
- global link -> `~/.agents/<name>.md` or `~/.pi/agent/agents/<name>.md`
- project link -> `PROJECT/.pi/agents/<name>.md`
- target -> `~/.pi/agent/agent-library/agents/<name>.md`

### Chains
- global link -> `~/.pi/agent/chains/<name>.chain.md`
- project link -> `PROJECT/.pi/chains/<name>.chain.md`
- target -> `~/.pi/agent/agent-library/chains/<name>.chain.md`

### Skills
- global link -> `~/.pi/agent/skills/<name>`
- project link -> `PROJECT/.pi/skills/<name>`
- target -> `~/.pi/agent/skill-library/<name>`

### Prompts
- global link -> `~/.pi/agent/prompts/<name>.md`
- project link -> `PROJECT/.pi/prompts/<name>.md`
- target -> `~/.pi/agent/prompt-library/<name>.md`

---

## Precedence inside Pi Manager

## Agents

Effective precedence is:

1. project custom agent
2. global custom agent
3. builtin agent
4. then builtin overrides patch the builtin when the builtin is still the winner

Within the same scope:
- global agent precedence is `~/.agents` before `~/.pi/agent/agents`
- project precedence is `.pi/agents` before legacy `.agents`

Builtin overrides come from:
- `~/.pi/agent/settings.json`
- `PROJECT/.pi/settings.json`

Project overrides beat global overrides.

## Chains

The app currently uses this precedence for the chain sources it actually scans:

1. project chain
2. global chain
3. library chain

Important: unlike agents, the current scanner does **not** discover legacy `.agents/*.chain.md` chain files.
So older runtime docs may mention more chain locations than the app currently models.

## Skills

The visible list is the union of:
- active global skills
- active project skills
- package skills discovered from packages in settings
- library skills

Library skills are shown separately because they are stored-but-not-active until linked.

---

## The most important distinction: runtime discovery vs app management

Pi and `pi-subagents` can discover more things than Pi Manager currently models.

Pi Manager is opinionated.
It intentionally narrows the surface area.

## Pi Manager actively models well today

### Agents
- builtin agents
- global agents in `~/.agents` and `~/.pi/agent/agents`
- project agents in `.pi/agents` and legacy `.agents`
- builtin overrides from settings
- app-managed agent library

### Chains
- global chains in `~/.pi/agent/chains`
- project chains in `.pi/chains`
- app-managed chain library

### Skills
- global skills in `~/.pi/agent/skills`
- legacy global skills in `~/.agents/skills`
- project skills in `.pi/skills`
- package skills from packages listed in settings
- app-managed skill library

### Prompts
- global prompts in `~/.pi/agent/prompts`
- project prompts in `.pi/prompts`
- settings-provided prompt paths
- package prompts from packages listed in settings
- app-managed prompt library

## Important gaps vs full Pi runtime

Today Pi Manager does **not** fully model every runtime source Pi itself can use.
The main gaps are:

- skills from `settings.json -> skills`
- CLI-only skill injection
- some legacy chain locations discussed in older docs
- broader extension-contributed dynamic resource paths

So when in doubt:
- use this file for **how the app manages things**
- use the runtime docs for **what Pi itself may still discover**

---

## Recommended workflow in this repo / on this machine

### Use the library when the resource is reusable

Good candidates:
- a specialist agent you want in multiple repos
- a shared chain
- a generally useful skill
- a reusable prompt template

Store it in:
- `~/.pi/agent/agent-library/...`
- `~/.pi/agent/skill-library/...`
- `~/.pi/agent/prompt-library/...`

Then activate it globally or by project.

### Use global active files for simple always-on behavior

Good candidates:
- one or two personal global agents
- skills you always want visible
- prompts you always want available

### Use project `.pi/...` for ad-hoc local behavior

Good candidates:
- a repo-specific worker/reviewer/scout variant
- a one-off chain for that repo only
- a temporary project skill or prompt

---

## Current machine snapshot

Right now this machine already reflects the split above:

- `~/.agents/` exists and is the preferred global agent location
- `~/.pi/agent/agent-library/` exists for reusable agents/chains
- `~/.pi/agent/skill-library/` exists for reusable skills
- `~/.pi/agent/prompt-library/` exists for reusable prompts
- `~/.pi/agent/skills/` contains active skills, including some symlinks back to `skill-library`
- `~/.pi/agent/chains/` exists as the active global chain location

So the real model in use is:

- **builtin** for package defaults
- **library** for reusable canonical resources
- **global active** for always-on visibility
- **project `.pi`** for local/ad-hoc visibility

---

## Source of truth in the code

If this document ever drifts, check these files:

- `pi-manager/PiScanner.swift`
- `pi-manager/AppViewModel.swift`
- `pi-manager/AgentPersistence.swift`
- `pi-manager/ChainPersistence.swift`
- `pi-manager/CommandsAndPromptsViews.swift`
- `pi-manager/ContentView.swift`

Those files define the current app behavior more accurately than older generic `pi-subagents` docs.
