---
head: 3ccdf9adfacbce1ac179ff743bb950a3dbbae1a9
dirty: true
generatedAt: 2026-05-03T06:31:52Z
taskScope: Agents view, global/project/user agents, builtin overrides, toolbar/actions for creating local/global override from selected builtin/global agent
changeSummarySincePrevious: previous cache was unrelated and stale; dirty files are docs/untracked planning docs, not Swift app code
reusedCache: false
---

# Code Context

## Scope
Map Pi Manager code for the Agents view and persistence/scanning of builtin/global/project agents and overrides. Supports adding a toolbar/action to create a local/global override from a selected builtin/global agent.

## Files Retrieved
1. `pi-manager/ContentView.swift` (lines 1343-1476, 1504-1548, 2178-2205, 2332-2388, 3662-3790) - Agents UI, toolbar, detail Actions menu, inline edit flow, full editor sheet.
2. `pi-manager/AppViewModel.swift` (lines 1328-1354, 1452-1496, 1560-1589, 2029-2040) - filtered/selected agent state, draft/save methods, builtin disable actions/filter enum.
3. `pi-manager/AgentPersistence.swift` (lines 6-45, 79-195, 198-244, 305-324) - creates builtin override drafts and writes `subagents.agentOverrides` to settings.
4. `pi-manager/PiScanner.swift` (lines 5-34, 635-653, 720-784, 788-815) - discovers builtin/global/project agents/settings and resolves effective agents with overrides.
5. `pi-manager/Models.swift` (lines 58-174, 258-320) - agent/override/effective record/snapshot types.
6. `pi-manager/EditingModels.swift` (lines 3-34) - `AgentEditingTarget` and `AgentEditorDraft`.

## Key Code
- `AgentsScreen` (`ContentView.swift:1343`) owns the Agents split view. Sidebar `List(selection: $viewModel.selectedAgentID)` renders `viewModel.filteredAgents` and state badges. Toolbar (`1416-1461`) currently has menus: `New` (global/project custom agents), filter, and `Builtins` disable-all globally.
- Detail is `AgentDetailView` (`ContentView.swift:1504`). Its top `Menu("Actions")` (`1524-1532`) currently has Open/Reveal and `Disable/Enable Globally` for `isPlainBuiltin`.
- `AgentDetailView` edit path: `makeDraft` closure is supplied by `AgentsScreen` as `viewModel.makeAgentDraft(for: agent, preferredOverrideScope: .global)` (`1472`), so inline Edit always creates/edits a global builtin override for plain builtins. `reloadInlineDraft(preferredOverrideScope:)` supports scope, but closure ignores the parameter.
- `isPlainBuiltin` = `agent.builtin != nil && agent.globalCustom == nil && agent.projectCustom == nil` (`ContentView.swift:2194-2196`). `hasOverride` checks `userOverride || projectOverride` (`2190-2192`). `writeTargetSummary` for builtins points to `~/.pi/agent/settings.json` (`2202-2205`).
- `AgentEditorSheet` (`ContentView.swift:3662`) supports `AgentEditorDraft.target == .builtinOverride(scope: .global/.project)` and labels it “Edit Builtin Override · scope”. Existing sheet state is wired in `ContentView.swift:157-177` via `agentDraft` + `editingAgent`.
- View model selection/helpers: `selectedAgentID`, `selectedAgentFilter` (`AppViewModel.swift:12,16`); `filteredAgents` (`1328-1350`); `selectedAgent` (`1353-1354`); `makeAgentDraft(for:preferredOverrideScope:)` (`1452-1454`); `saveAgentDraft` refreshes after persistence (`1456-1459`).
- Persistence draft logic (`AgentPersistence.swift:6-34`): custom project wins, then custom global; otherwise builtin creates `AgentEditorDraft(target: .builtinOverride(scope: preferredOverrideScope ?? .global), originalName: agent.name, config: seededBuiltinOverrideConfig(...), sourcePath: agent.sourcePath)`.
- Override seeding (`AgentPersistence.swift:79-85`): global seed = builtin + userOverride; project seed = builtin + userOverride + projectOverride.
- Override saving (`AgentPersistence.swift:133-162`): diffs edited config vs builtin via `buildBuiltinOverride` and writes/removes `root["subagents"]["agentOverrides"][original.name]` in global `~/.pi/agent/settings.json` or project `.pi/settings.json` (`318-324`).

## Architecture
`PiScanner.scan(projectRoot:)` reads builtins from `/opt/homebrew/lib/node_modules/pi-subagents/agents`, global custom agents from `~/.pi/agent/agents` and `~/.agents`, project custom agents from `<project>/.pi/agents` and legacy `<project>/.agents`, and settings from global/project JSON. `scanSettings` extracts `subagents.disableBuiltins` and `subagents.agentOverrides`. `resolveAgents` combines records by name: project custom > global custom > builtin; overrides only apply when winner is builtin. UI works with `EffectiveAgentRecord` from `snapshot.effectiveAgents`.

## Start Here
Open `pi-manager/ContentView.swift` at `AgentsScreen` lines 1416-1461 and `AgentDetailView` lines 1524-1535. Likely change: add an Actions/toolbar menu item based on `viewModel.selectedAgent`, then set `editingAgent = selectedAgent` and `agentDraft = viewModel.makeAgentDraft(for:selectedAgent, preferredOverrideScope: .project/.global)`.

## Constraints And Risks
- Existing `AgentsScreen` has `onEditAgent` prop but does not use it; parent `ContentView` wires it to global override only (`225-227`). For local/project override, pass scope explicitly or add a new closure.
- Project/local override should only be enabled when `viewModel.selectedProjectPath != nil`; persistence writes project overrides to `<project>/.pi/settings.json`.
- “global agent” can mean custom global replacement (`agent.globalCustom != nil`). `AgentPersistence.makeDraft` will edit that markdown directly, not create an override. Builtin overrides require `agent.builtin != nil` and no custom replacement (`isPlainBuiltin`) unless product wants overriding replaced builtins, which current resolution does not support.
- Current inline detail `makeDraft` closure ignores requested scope; fix if using inline edit for project overrides.
