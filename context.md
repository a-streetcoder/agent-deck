# Code Context

## Files Retrieved
1. `pi-manager/ProjectDiscovery.swift` (lines 3-43, 223-327, 329-359) - project discovery model, GitHub remote detection, and the expensive icon/symbol fallback logic.
2. `pi-manager/ContentView.swift` (lines 4-64, 229-259, 261-517) - sidebar selection UI, favorites persistence, and project row/icon rendering.
3. `pi-manager/AppViewModel.swift` (lines 5-18, 75-95, 121-132, 813-820, 952-1005, 1117-1169) - discovery/refresh flow, selected project state, aggregate snapshot, and file watch loop.
4. `pi-manager/Models.swift` (lines 60-80, 106-167, 247-324) - core agent/project data model and `ScanSnapshot`.
5. `pi-manager/PiScanner.swift` (lines 7-114, 601-713) - per-project scan inputs and agent resolution/disabled behavior.
6. `pi-manager/AgentPersistence.swift` (lines 6-108, 110-200) - project/global write paths for agents and settings overrides.
7. `pi-manager/ChainPersistence.swift` (lines 50-157) - project/global chain write paths.
8. `pi-manager/EnvPersistence.swift` (lines 53-147) - project/global env write paths.

## Key Code
- `DiscoveredProject` is currently tiny:
  ```swift
  struct DiscoveredProject {
      let url: URL
      let gitHubRemote: GitHubRemote?
      let isGitRepository: Bool
      let iconFileURL: URL?
      let fallbackSymbolName: String
  }
  ```
- `ProjectDiscovery.discoverProjects()` only scans `~/Documents/GitHub`, then computes icon/symbol metadata per repo.
- `preferredIconFileURL(for:)` is the heavy bit: it checks a long filename candidate list, then scans `.icon` composer assets, then scans `Assets.xcassets` app icon sets and picks the largest raster image.
- `AppViewModel.refresh()` rebuilds `discoveredProjects`, scans every repo into `allProjectSnapshots`, then restores `selectedProjectPath` or falls back to aggregate view.
- Sidebar favorites are not per-project metadata; they are just `@AppStorage("favoriteProjectPaths")` newline-delimited paths in `ContentView`.
- `ProjectSelectionSidebar` groups favorites + other projects and uses `ProjectIconView(imageURL:symbolName:)` for display only.
- Project-level persistence today is only repo files under `.pi`/`.agents` etc. Example paths:
  - `AgentPersistence.settingsPath(...)` -> `projectRoot/.pi/settings.json`
  - `ChainPersistence.chainPath(...)` -> `projectRoot/.pi/agents/...`
  - `EnvPersistence.makeNewDraft(...)` -> `projectRoot/.pi/.env`
- Disabled behavior already exists for agents, not projects: `AgentConfig.disabled`, `SettingsSummary.disableBuiltins`, and `PiScanner.resolveAgents(...)` drops disabled builtins/effective agents.

## Architecture
- Startup flow: `AppViewModel.init()` -> `refresh()` -> `ProjectDiscovery.discoverProjects()` + `PiScanner.scan(projectRoot:)` for global and each discovered repo.
- `selectedProjectPath` controls whether the UI shows aggregate data or one repo’s `ScanSnapshot`.
- UI state for projects is split between:
  - runtime selection (`selectedProjectPath` in `AppViewModel`)
  - ephemeral filter text (`projectFilterText` in `ContentView`)
  - persisted favorites (`@AppStorage` string in `ContentView`)
- There is no dedicated persisted project-metadata store yet; project enabled/disabled/favorite/custom-icon support would need a new persistence layer or a repo-local metadata file.
- The icon logic is duplicated in spirit: discovery tries hard to find an image; rendering just loads whatever URL it gets through `ProjectIconView` + `ProjectIconCache`.

## Start Here
`pi-manager/ProjectDiscovery.swift` — it owns the project model and the costly icon discovery path that should be simplified first.