# Agent Deck resource management: active vs library vs project

This is the app-specific reference for how **Agent Deck actually manages** agents, chains, skills, and prompt templates.

It is intentionally different from broader Pi runtime docs, which explain everything Pi *can* discover.
Agent Deck also has a **native subagent runtime**: the app launches and tracks child Pi RPC sessions directly. The same agent/skill/resource records described here feed that native runtime, but run execution, artifacts, supervisor requests, worktrees, chains, and parallel graphs are app-managed. See `native-subagents.md` for the execution model.

This file explains the narrower model Agent Deck uses to keep things understandable:

1. **Builtin** resources shipped by packages
2. **Active global** resources Pi sees everywhere
3. **Imported/catalog** resources Agent Deck remembers by path
4. **Ad-hoc project** resources that only exist for one repo

If you want to understand the current app UX, start here.

---

## The mental model

Agent Deck treats discovered resources and assigned resources as different things.

- **Catalog** = resources Agent Deck can see
- **Default assignment** = passed to every parent Pi Agent session
- **Project assignment** = passed to parent sessions for one project
- **Builtin** = package-owned, read-only

For skills, the app does not need to copy or symlink files into Pi discovery locations. It stores skill names/paths in its catalog and launches Pi with explicit skill arguments:

```text
--no-skills
--skill /path/to/skill/SKILL.md
```

Agents, chains, and prompts may still use library storage and symlink-based activation where noted below.

---

## The three practical buckets

### 1. Builtins

These come from the app bundle or installed packages and are read-only.

- App-bundled native agents: `agent-deck/bundled-agents/`
- Package skills/prompts: discovered from packages listed in settings

Agent Deck never edits builtin package files directly.
For builtin agents it writes overrides to settings, or creates custom replacements.

### 2. Global active resources

These are the things Pi sees without selecting a project.

They may be:
- regular files/directories created directly in a global path
- or symlinks that point back into a Agent Deck library folder

### 3. Project-only resources

These are repo-scoped files or symlinks under that project's `.pi/` folder.

They are intentionally ad-hoc.
They are the right place for one-off experiments, repo-specific specialists, and local workflow helpers.

---

## Exact paths Agent Deck uses

## Agents

### Builtin
- app bundle resources under `bundled-agents/*.md`

### Active global
- preferred write target: `~/.agents/*.md` **if `~/.agents` exists**
- fallback write target: `~/.pi/agent/agents/*.md`

### Library
- `~/.pi/agent/agent-library/agents/*.md`

### Project
- `PROJECT/.pi/agents/*.md`
- app also scans legacy project agents in `PROJECT/.agents/*.md`

### Important nuance
On this machine, `~/.agents` exists, so Agent Deck currently prefers it for new global agents and global agent symlinks.

### Agent Deck bundled native agents
Agent Deck also ships a small app-bundled native starter pack:

- `scout`
- `planner`
- `worker`
- `reviewer`

These are treated as builtins in the app's effective agent list. Same-name global/project custom agents can replace them, and builtin override controls can disable or patch supported fields. They are written for Agent Deck's native RPC runner and use the `contact_supervisor` communication tool vocabulary when available.

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
Agent Deck manages chains in `~/.pi/agent/chains` and `PROJECT/.pi/chains`.
That is clearer than mixing them into agent folders.

Also important: the current app scanner does **not** actively discover legacy chain files in `.agents/`, even though some older docs talk about those runtime locations.

---

## Skills

### Active global
- `~/.pi/agent/skills/<skill>/SKILL.md`
- legacy global skills are also scanned from `~/.agents/skills/`

### Imported/catalog
- external skill roots remembered in Agent Deck app settings
- legacy imported skills may still be scanned from `~/.pi/agent/skill-library/<skill>/SKILL.md`

### Project
- `PROJECT/.pi/skills/<skill>/SKILL.md`
- root `PROJECT/.pi/skills/<name>.md` also scans as a standalone skill

### Important nuance
Agent Deck's skill assignment model is name-based and launch-time explicit. A discovered skill is not injected until it is marked Default, assigned to a project, or assigned to a native agent.

### Agent-assigned skills are references, not bundled files

An agent can explicitly list skills in its frontmatter:

```yaml
skills: axiom-ai
```

That means: "when this agent runs, inject the skill named `axiom-ai` into that child session."

For Agent Deck native subagents, the app resolves these explicit skills from the current scan snapshot and passes them through Pi's native `--skill <path>` support.

It does **not** mean Agent Deck copies, bundles, or carries the skill directory together with the agent.
The agent stores only the skill name.

For the skill to actually be injected at runtime, the skill must be visible in the Agent Deck skill catalog:

- bundled with Agent Deck
- discovered from Pi global/project skill locations
- remembered as an imported external skill path
- provided by an installed package/settings source that Agent Deck scans

So if an `ios-engineer` agent has `skills: axiom-ai` and you assign that agent to a project, the skill does **not** automatically follow the agent as a copied file. The skill name must resolve to exactly one catalog entry at launch time.

---

## Prompt templates

### Active global
- `~/.pi/agent/prompts/*.md`

### Library
- `~/.pi/agent/prompt-library/*.md`

### Project
- `PROJECT/.pi/prompts/*.md`

### Package/settings discovery
For prompts, Agent Deck also scans:
- package prompt folders from packages listed in settings
- explicit prompt paths from `settings.json -> prompts`

---

## What “move to library” actually does

Agent Deck uses different behavior depending on where the resource started.

## Agents / chains / prompts

When importing a resource into the library:

- if it started as a **global** resource, Agent Deck usually **moves** it into the library
- if it started as a **project** resource, Agent Deck usually **copies** it into the library
- if it is already a **library** resource, Agent Deck keeps it there

Then global/project visibility is controlled with symlinks.

Why:
- global resources are usually being promoted into a reusable canonical copy
- project resources usually need to keep their local copy unless you deliberately replace them

## Skills

Skills are different from agents/chains/prompts. Importing an external skill records its existing skill root path in Agent Deck settings. Agent Deck keeps the source file in place and passes that path to Pi at launch.

---

## What “enable globally” or “assign to project” means

For agents, chains, and prompts, Agent Deck treats **global visibility** and **project visibility** as mutually exclusive, but project assignment itself is **not** exclusive.

For skills, these controls are assignments, not filesystem activation:

- **Enable globally**
  - stores the skill name as a Default skill
  - parent sessions receive `--skill <path>` after resolving that name

- **Assign to project**
  - stores the skill name in that project's Agent Deck preferences
  - parent sessions for that project receive `--skill <path>` after resolving that name
  - can be repeated for multiple projects at once

Native agent skill assignment writes the skill name into the agent frontmatter. That child run receives its own explicit `--skill <path>` arguments.

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
- no managed global/project symlink is created
- default/project/agent assignments store skill names
- launch resolves names to catalog paths and emits `--skill <path>`

### Prompts
- global link -> `~/.pi/agent/prompts/<name>.md`
- project link -> `PROJECT/.pi/prompts/<name>.md`
- target -> `~/.pi/agent/prompt-library/<name>.md`

---

## Precedence inside Agent Deck

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
- imported external skill paths
- legacy library skills

Unassigned skills are visible in the catalog but are not injected.

---

## The most important distinction: runtime discovery vs app management

Pi can discover more things than Agent Deck currently models.

Agent Deck is opinionated.
It intentionally narrows the surface area.

## Agent Deck actively models well today

### Agents
- app-bundled native starter agents (`scout`, `planner`, `worker`, `reviewer`)
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

Today Agent Deck does **not** fully model every runtime source Pi itself can use.
The main gaps are:

- skills from `settings.json -> skills`
- CLI-only skill injection
- some legacy chain locations discussed in older docs
- broader extension-contributed dynamic resource paths

Native subagent bridge tools are not managed resources in these folders. Agent Deck writes temporary/local bridge extensions for parent-managed calls (`managed_subagent`, `managed_chain`, `managed_parallel`, plan tools, supervisor-answer tools) and child-to-parent communication (`contact_supervisor`) as part of the app runtime.

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
- `~/.pi/agent/prompt-library/...`

Then activate it globally or by project.

For external skill sources such as Axiom, Agent Deck imports selected top-level skill folders by remembering their existing paths. The upstream repo remains the source of truth, and assignment controls only decide whether Agent Deck passes those paths to Pi.

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
- external skill paths are remembered in Agent Deck app settings
- `~/.pi/agent/prompt-library/` exists for reusable prompts
- `~/.pi/agent/skills/` may contain Pi-native active skills from older/manual workflows
- `~/.pi/agent/chains/` exists as the active global chain location

So the real model in use is:

- **builtin** for package defaults
- **library** for reusable canonical resources
- **global active** for always-on visibility
- **project `.pi`** for local/ad-hoc visibility

---

## Source of truth in the code

If this document ever drifts, check these files:

- `agent-deck/PiScanner.swift`
- `agent-deck/AppViewModel.swift`
- `agent-deck/AgentPersistence.swift`
- `agent-deck/ChainPersistence.swift`
- `agent-deck/CommandsAndPromptsViews.swift`
- `agent-deck/ContentView.swift`

Those files define the current app behavior more accurately than older generic runtime notes.
