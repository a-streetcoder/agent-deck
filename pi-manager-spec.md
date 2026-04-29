# pi-manager Spec

## Purpose

`pi-manager` is a native macOS app for browsing, understanding, editing, and creating the resources used by Pi and `pi-subagents`.

It should feel like a much better visual version of Pi's `/agents` experience, with first-class support for:
- builtin agents
- builtin overrides
- global custom agents
- project custom agents
- saved chains
- skills
- effective precedence and resolution
- project/global environment and MCP context

The app is not a generic LLM prompt manager. It is a Pi-native manager for the actual files and settings Pi reads.

---

## Product goals

### Primary goals
1. Show all available agents clearly across builtin, global, and project scope.
2. Show the **effective resolved agent**, not just raw files.
3. Make builtin overrides understandable and safe.
4. Make skill assignment and inheritance understandable.
5. Make project-vs-global precedence obvious.
6. Make chain authoring and inspection much better than raw markdown editing.
7. Be safe: never hide what file will actually be written.

### Secondary goals
1. Make Pi filesystem concepts approachable for non-experts.
2. Help users avoid overbuilt agents and accidental prompt bloat.
3. Surface missing dependencies early: tools, extensions, skills, env keys, MCP config.
4. Make it easy to compare builtin agent vs override vs custom replacement.

### Non-goals for v1
1. Not a full Pi runtime replacement.
2. Not a chat client.
3. Not a live orchestration monitor for running subagents.
4. Not a full package manager for all Pi packages.
5. Not a general markdown editor for arbitrary repo docs.

---

## Core user problems

### Problem 1: users cannot easily tell what Pi will actually use
Pi resources come from multiple scopes:
- builtin package files
- global user files
- project files
- settings-based overrides
- package-provided skills

Users need one visual place to answer:
- which agent wins?
- is this builtin patched or replaced?
- where is this skill coming from?
- does this project override my global config?

### Problem 2: raw markdown and JSON are too low-level
Today, understanding and editing requires jumping between:
- `~/.pi/agent/agents/`
- `.pi/agents/`
- `~/.pi/agent/settings.json`
- `.pi/settings.json`
- `~/.pi/agent/skills/`
- `~/.agents/skills/`
- `.pi/skills/`
- package agent folders

### Problem 3: users do not understand inheritance and resolution
Confusing concepts include:
- builtin override vs custom replacement
- `systemPromptMode`
- `inheritProjectContext`
- `inheritSkills`
- `tools` vs `extensions`
- explicit skills vs inherited skills

---

## Target users

### Primary user
A Pi power user who:
- installs `pi-subagents`
- has both global and project agents
- uses custom skills
- wants to tune builtin agents
- wants a better agent and chain manager

### Secondary user
A developer on a repo who wants to:
- inspect project-local agents/chains/skills
- safely create a custom specialist
- understand what the team config is doing

---

## Information architecture

The app should be organized around **resources** and **scope**.

### Top-level navigation
Recommended sidebar sections:

1. **Overview**
2. **Agents**
3. **Chains**
4. **Skills**
5. **Environment**
6. **MCP**
7. **Settings / Diagnostics**

Optional later:
8. **Packages**
9. **Templates**

---

## Core concepts the UI must model

### Scope
Every resource should show scope badges:
- Builtin
- Global
- Project
- Legacy Project
- Override
- Package-provided

### Resolution
Every agent should support at least these views:
- Raw source
- Override patch
- Effective resolved view
- Diff vs builtin

### Resource types
The app should model these resource classes separately:
- Agent definition
- Builtin override patch
- Chain definition
- Skill definition
- Settings file
- Environment file
- MCP config file

---

## Screen spec

## 1. Overview screen

### Goal
Provide a quick health/summary dashboard.

### Show
- Current selected project root
- Installed relevant packages detected
  - `pi-subagents`
  - `pi-web-access`
  - `pi-dotenv`
  - `ask-user`
- Counts:
  - builtin agents
  - global custom agents
  - project custom agents
  - builtin overrides
  - global chains
  - project chains
  - global skills
  - project skills
- Warnings:
  - duplicate agent names across scopes
  - malformed frontmatter
  - broken chain references
  - explicit skills that do not resolve
  - missing env keys for installed tooling
  - extension/tool mismatches

### Actions
- Open project selector
- Refresh scan
- Open diagnostics

---

## 2. Agents screen

### Goal
Main management surface.

### Layout
Three-pane preferred layout:
- left sidebar: filters + groups
- center list: agents
- right detail/editor panel

### Left sidebar filters
- All
- Builtin
- Global
- Project
- Overridden builtins
- Replaced builtins
- Custom only
- Disabled
- Needs attention

### List row contents
Each agent row should show:
- name
- description
- scope badge(s)
- whether it is builtin/custom/override/replacement
- model summary
- thinking summary
- key indicators:
  - has explicit skills
  - inherits skills
  - has explicit tools
  - has extension sandbox
  - writes output file

### Agent detail tabs
Recommended tabs:
1. Summary
2. Prompt
3. Tools & Extensions
4. Skills
5. Resolution
6. Source Files
7. Advanced

### Summary tab
Show:
- effective name
- effective description
- effective source winner
- model
- fallback models
- thinking
- prompt mode
- inherit project context
- inherit skills
- disabled status
- output/defaultReads/defaultProgress
- maxSubagentDepth

### Prompt tab
Show:
- system prompt body
- raw markdown
- rendered preview
- optional diff against builtin source

### Tools & Extensions tab
Show clearly:
- `tools` omitted vs explicit allowlist
- direct MCP tools found via `mcp:` entries
- `extensions` mode:
  - inherited/default
  - none
  - allowlist
- warnings if a tool appears unavailable in current setup

### Skills tab
Show clearly:
- `inheritSkills` on/off
- explicit `skills:` assigned
- resolved skill sources for each explicit skill
- warning if skill name does not resolve
- optional “recommended skills from available library” panel

### Resolution tab
Show:
- builtin source file, if applicable
- applied override values, if any
- custom replacement source, if any
- effective resolved frontmatter
- precedence explanation in plain English

### Source Files tab
Show concrete paths:
- builtin file path
- global file path if present
- project file path if present
- settings file path for override

### Advanced tab
Show:
- raw frontmatter JSON/YAML-like view
- unknown extra fields
- parsed validation warnings

### Agent actions
- Create new agent
- Duplicate agent
- Create project copy from builtin
- Create global copy from builtin
- Add/edit builtin override
- Disable builtin
- Delete custom agent
- Reveal in Finder
- Open raw file

---

## 3. Chains screen

### Goal
Visual chain browsing and editing.

### List contents
Each chain row should show:
- name
- scope badge
- number of steps
- whether any step references missing agents
- whether it is global or project

### Chain detail
Show:
- description
- source file path
- step sequence as cards or nodes
- per-step fields:
  - agent
  - task template
  - output override
  - reads override
  - model override
  - skills override
  - progress override

### Special UX requirement
A chain should be viewable both as:
- visual flow
- raw `.chain.md`

### Chain validation
Warn for:
- missing referenced agent
- unresolved reads/output expectations
- malformed step block
- obvious cyclic or invalid structure

### Chain actions
- Create chain
- Duplicate chain
- Convert to project/global scope
- Open raw file
- Reveal in Finder

---

## 4. Skills screen

### Goal
Make the skill surface understandable.

### List grouping
Group by source:
- Project direct skills
- Project package skills
- Global direct skills
- Global package skills
- Extra user libraries (`~/.agents/skills`)

### Skill row contents
- name
- description
- source badge
- path
- whether used by any visible agent

### Skill detail
Show:
- name
- description
- full `SKILL.md`
- source path
- referenced subfiles if discoverable
- which agents explicitly assign it
- whether any agent only sees it through `inheritSkills`

### Actions
- Reveal in Finder
- Open raw skill
- Copy skill name/path
- Find agents using this skill

### Important app behavior
The app should clearly distinguish:
- “skill exists in the discoverable universe”
- “skill is explicitly assigned to this agent”
- “skill is only ambiently visible if inheritSkills is on”

---

## 5. Environment screen

### Goal
Show env relevant to Pi/subagents.

### Sections
- Global env file: `~/.pi/agent/.env`
- Project env file: `.pi/.env`
- Effective merged env preview (keys only, values masked)

### Show
- key names
- scope source
- whether project overrides global
- quick validation for known integrations:
  - `EXA_API_KEY`
  - `GEMINI_API_KEY`
  - `PERPLEXITY_API_KEY`

### Important rule
Never show secret values in clear text by default.
Use masked rendering with explicit reveal action.

---

## 6. MCP screen

### Goal
Explain what MCP config exists and where.

### Show
- `~/.pi/agent/mcp.json`
- `.mcp.json`
- `.pi/mcp.json`

### Include
- which file exists
- which servers are configured
- whether direct tool names likely matter for agents
- explanation that agent MCP access still depends on tools/frontmatter

---

## 7. Settings / Diagnostics screen

### Goal
Surface global and project Pi settings relevant to subagents.

### Show
- `~/.pi/agent/settings.json`
- `.pi/settings.json`
- parsed `subagents.agentOverrides`
- package list
- extension list if inferable
- diagnostics/warnings

---

## Data model

Recommended Swift models:

```swift
struct ScopeID: Hashable {
    enum Kind { case builtin, global, project, legacyProject, override, package }
    let kind: Kind
    let path: String
}

struct AgentRecord: Identifiable {
    let id: String
    let name: String
    let description: String
    let source: ScopeID
    let filePath: String
    let rawFrontmatter: [String: String]
    let promptBody: String
    let parsed: AgentConfig
}

struct BuiltinOverrideRecord {
    let agentName: String
    let scope: ScopeID
    let settingsPath: String
    let values: BuiltinOverrideValues
}

struct EffectiveAgentRecord: Identifiable {
    let id: String
    let name: String
    let builtin: AgentRecord?
    let globalCustom: AgentRecord?
    let projectCustom: AgentRecord?
    let userOverride: BuiltinOverrideRecord?
    let projectOverride: BuiltinOverrideRecord?
    let resolved: AgentConfig
    let resolutionKind: ResolutionKind
}

struct ChainRecord: Identifiable {
    let id: String
    let name: String
    let source: ScopeID
    let filePath: String
    let description: String
    let steps: [ChainStepRecord]
}

struct SkillRecord: Identifiable {
    let id: String
    let name: String
    let description: String?
    let source: ScopeID
    let filePath: String
}
```

### Key derived models
The app should derive:
- `EffectiveAgentRecord`
- `AgentUsageSummary`
- `SkillUsageSummary`
- `ResolutionWarning`

---

## File IO rules

### Read behavior
The app must scan:
- builtin package agents
- global agent dir
- project agent dir
- legacy project dir
- settings JSON files
- skill directories
- env files
- MCP files

### Write behavior
The app should write only to:
- `~/.pi/agent/agents/`
- `.pi/agents/`
- `~/.pi/agent/settings.json`
- `.pi/settings.json`
- optionally env/settings/MCP files only if that feature is explicitly enabled

### Never write to builtin package files
Do not edit:
- `/opt/homebrew/lib/node_modules/pi-subagents/agents/*.md`

If the user edits a builtin agent, the app should offer:
- create override patch
- create global replacement
- create project replacement

---

## Editing flows

## Flow A: tweak builtin agent safely
1. user opens builtin agent
2. clicks Edit
3. app asks:
   - create override patch?
   - create global replacement?
   - create project replacement?
4. default recommendation: override patch for small changes
5. app writes to settings.json if override chosen

## Flow B: create custom agent
1. choose scope: global or project
2. choose starting point:
   - blank
   - clone builtin
   - clone custom agent
3. fill core fields:
   - name
   - description
   - model
   - thinking
   - prompt mode
   - project context
   - inherit skills
   - tools
   - skills
4. edit prompt body
5. write markdown file to chosen scope

## Flow C: edit chain visually
1. select or create chain
2. edit steps as cards
3. pick agent per step from effective available agents
4. edit task template and overrides
5. save back to `.chain.md`

---

## UX rules

### Rule 1: always show scope
Every resource and every editable field must make scope obvious.

### Rule 2: always show write target
Before save, make clear which concrete file will be modified.

### Rule 3: explain precedence visually
For an effective agent, visually show:
- builtin base
- override patch
- global replacement if any
- project replacement if any
- final winner

### Rule 4: separate explicit from inherited
Especially for:
- tools vs extensions
- explicit skills vs inherited skills
- raw source vs effective resolved config

### Rule 5: expose warnings early
Examples:
- missing skill reference
- chain references missing agent
- builtin override exists but builtin disabled
- explicit web tool but `pi-web-access` not installed
- `inheritSkills: true` on a narrowly scoped specialist

---

## Suggested native macOS architecture

## UI technology
- SwiftUI for most UI
- AppKit bridging only where needed for:
  - advanced text editing
  - diff view
  - Finder/file integrations

## App structure
Recommended layers:
1. **Scanner layer**
   - reads filesystem and parses raw resources
2. **Resolver layer**
   - computes precedence and effective resources
3. **View model layer**
   - prepares grouped/filterable UI state
4. **Editor layer**
   - writes user/project files and settings patches safely

## Main modules
- `PiEnvironmentScanner`
- `AgentScanner`
- `ChainScanner`
- `SkillScanner`
- `SettingsScanner`
- `ResolutionEngine`
- `AgentEditorService`
- `ChainEditorService`
- `DiagnosticsService`

## File watching
Use filesystem observation to auto-refresh when files change outside the app.
Likely candidates:
- `DispatchSourceFileSystemObject`
- FSEvents wrapper
- or simple debounce polling for v1 if needed

---

## Parsing strategy

### Agent parser
Need to parse:
- markdown frontmatter
- prompt body
- known fields
- unknown extra fields

### Chain parser
Need to parse `.chain.md` sections:
- frontmatter
- `## agent-name` steps
- step config block
- task body

### Skill parser
Need to parse:
- `SKILL.md` frontmatter
- description
- path
- maybe linked reference files later

### Settings parser
Need to parse safely:
- `subagents.agentOverrides`
- package lists
- relevant project/global keys

---

## MVP scope

### MVP includes
- project picker
- overview screen
- agents browser
- builtin override editing
- custom agent creation/editing
- chain browser + basic editing
- skills browser
- env browser (masked)
- diagnostics panel

### MVP excludes
- rich drag-and-drop flow builder for chains
- live run monitoring
- integrated prompt test harness
- package installation UI
- visual MCP tool browser
- AI-assisted agent authoring

---

## Phase 2 ideas
- diff view for builtin vs effective agent
- prompt testing sandbox
- “recommend skills/tools” assistant
- chain simulation / dry-run validation
- visual dependency graph: agents ↔ skills ↔ chains
- import/export templates
- package browser for installed Pi packages
- compare global vs project environment

---

## Recommended first implementation order

1. Build scanner + data model
2. Build overview screen
3. Build agents list + detail
4. Add effective resolution engine
5. Add builtin override editing
6. Add custom agent create/edit flow
7. Add skills browser
8. Add chain browser
9. Add diagnostics and warnings
10. Add filesystem watching

---

## Concrete first milestone

### Milestone 1: read-only inspector
The first useful version should already let the user:
- choose a project root
- see builtin/global/project agents
- see which one wins
- inspect effective config
- inspect chains and skills
- inspect env/settings/MCP files read-only

This alone would already be valuable.

### Milestone 2: safe editing
Then add:
- builtin override editing
- global/project custom agent editing
- chain editing

---

## Definition of success

`pi-manager` is successful if a user can answer these questions in under 10 seconds:
- Which agent will Pi actually use?
- Is this builtin patched or replaced?
- Where does this skill come from?
- Is this agent inheriting all skills or only specific ones?
- What file do I need to edit to change this behavior?
- Is this setting global or project-only?

And can do these tasks without manually editing raw files:
- tweak a builtin agent safely
- create a custom agent
- inspect and edit a saved chain
- understand skill availability and assignment
- understand the effective Pi/subagent environment for a project
