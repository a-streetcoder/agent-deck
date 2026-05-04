---
head: 584345607c26d3a527e4e190a6222b7aaa6c5b29
dirty: true
generatedAt: 2026-05-04T21:55:53Z
taskScope: agent cards, project assignment UI, warning surfaces, and skill/project visibility data model
changeSummarySincePrevious: previous cache scope unrelated; refreshed despite dirty tree because requested files are currently dirty/relevant
reusedCache: false
---

# Code Context

## Scope
Implement detection/UI for library/global agents assigned to projects while explicitly listing skills that are not visible in those projects.

## Files Retrieved
1. `pi-manager/Models.swift` (lines 55-64, 73-118, 121-143, 166-209, 212-219, 295-302, 337-361) - scopes, agent/skill/warning/snapshot data.
2. `pi-manager/PiScanner.swift` (lines 1-122, 852-899) - scanner sources and existing warning generation.
3. `pi-manager/AppViewModel.swift` (lines 1711-1779, 1871-1876, 2120-2137, 2612-2634, 2636-2668, 2821-2838) - displayed agents, available skills, project assignment helpers, skill visibility helper.
4. `pi-manager/ContentView.swift` (lines 2404-2630, 2677-2760, 3129-3278, 5827-5908) - agent cards, agent detail tabs, skills UI, project assignment UI, warnings UI.

## Key Code
- `AgentConfig.skills` / `inheritSkills` live in `Models.swift:73-118`; `EffectiveAgentRecord.projectRoot` and `resolved` are in `Models.swift:166-209`; `SkillRecord.source/filePath` in `Models.swift:212-219`; warnings are only `{id,message}` at `Models.swift:295-302`.
- Scanner builds project-scoped snapshots from global + project resources, including project skills (`PiScanner.swift:1-122`). Existing warnings only check missing skill name globally within that snapshot, not per-assigned-project visibility (`PiScanner.swift:876-888`).
- Assignment: `AppViewModel.agent(_:isEnabledFor:)`, `assignedProjects(for:)`, `setAgent(_:enabled:for:)` use `allProjectSnapshots[project.path]?.projectAgents` (`AppViewModel.swift:2120-2137`).
- Available skill picker is scope-based: `availableSkillNames(for:)` uses `scopeSnapshot(for:)` (`AppViewModel.swift:1871-1876`), so project-local skills are only selectable when editing in project scope.
- Existing visibility logic: `skillVisible(to:skill:)` returns true for global/package/etc.; for `.project`/`.legacyProject`, compares project name parsed from skill path to `agent.projectRoot` last path component (`AppViewModel.swift:2821-2838`). This is private and name-based, so risky for cross-project assignment checks.
- Agent cards add a generic Warning pill when `viewModel.warnings(for: agent)` is non-empty (`ContentView.swift:2610-2624`). No warning popover exists on agent cards today.
- Agent detail Skills tab has read-only explicit skill list and pi-subagents warning (`ContentView.swift:3129-3225`). Project assignment card toggles all `projects` for `managedAgent` (`ContentView.swift:3237-3278`). Warnings page/card is generic in `ContentView.swift:5827-5908`.

## Architecture
`PiScanner.scan(projectRoot:)` produces one snapshot per selected/global project; `AppViewModel` keeps `globalSnapshot`, `allProjectSnapshots`, and aggregate `snapshot`. Library agents are assigned by symlinking/copying into each project (`setAgent`). To detect the target issue, compare a managed agent’s explicit `resolved.skills` against each assigned project’s `ScanSnapshot.skills` names (plus globally visible skills included in that project snapshot). A skill missing from the assigned project snapshot is not visible there.

## Start Here
Start in `AppViewModel.swift` near `assignedProjects(for agent:)` (`2124`) and `skillVisible(to:)` (`2821`). Add a small typed helper like `invisibleExplicitSkills(for agent: AgentRecord, in project: DiscoveredProject) -> [String]` using `allProjectSnapshots[project.path]?.skills.map(\.name)`.

## Constraints And Risks
- Do not rely on `skillVisible(to:)` project-name parsing for this feature; project paths are available through `DiscoveredProject.path` and `allProjectSnapshots`.
- Existing `DiagnosticWarning` lacks structured fields; for popovers prefer a dedicated view-model helper instead of parsing warning text.
- Existing `warnings(for:)` only reads current aggregate/selected snapshot; assigned-project warnings should consider all assigned projects.
- UI touch points: add per-agent warning popover/state in `AgentLibraryPane.agentTile/capabilityStrip`; add inline warnings in `AgentDetailView.skillsTab` and/or `agentVisibilityManagementCards` project rows.

## Pi-intercom handoff
No safe orchestrator target named by task; no intercom handoff sent.

## Concise Implementation Plan
1. Add AppViewModel helpers beside `assignedProjects(for agent:)`:
   - `explicitSkillVisibilityIssues(for agent: AgentRecord) -> [(project: DiscoveredProject, missingSkills: [String])]`.
   - For each assigned project, build `visible = Set(allProjectSnapshots[project.path]?.skills.map(\.name) ?? [])`; `missing = agent.parsed.skills.filter { !visible.contains($0) }`, ignoring `pi-subagents` if handled separately.
2. Pass helper output from `AgentsScreen` into `AgentDetailView` and/or expose closure to `AgentLibraryPane`.
3. Agent cards (`ContentView.swift:2560-2630`): show orange pill/popover when helper has issues; popover text: project name + missing skill names.
4. Project Assignment card (`ContentView.swift:3256-3278`): under each checked row or above list, show warning if that project lacks explicit skills. This is the highest-value placement because assignment creates the problem.
5. Skills tab (`ContentView.swift:3129-3225`): annotate explicit skill list with projects where not visible, or add a compact warning card above the list.
6. Optional scanner-level warnings (`PiScanner.swift:876-888`) are harder because a single scan only knows one project; aggregate check belongs in `AppViewModel` unless `DiagnosticWarning` is extended with structured project/agent fields.
