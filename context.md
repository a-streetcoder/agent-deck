# Code Context

## Files Retrieved
1. `pi-manager/pi_managerApp.swift` (lines 1-17) - app entry; shows this is a single-window SwiftUI macOS app.
2. `pi-manager/ContentView.swift` (lines 4-120) - root shell, project selector, refresh action, and editor sheet wiring.
3. `pi-manager/ContentView.swift` (lines 211-390) - Overview + Models screens; includes the only current GitHub-branded project list UI.
4. `pi-manager/ContentView.swift` (lines 408-1026) - Agents screen, agent detail tabs, and the main resolution/comparison UI.
5. `pi-manager/ContentView.swift` (lines 1028-1290) - Chains and Skills screens.
6. `pi-manager/ContentView.swift` (lines 1293-1610) - Environment and MCP screens.
7. `pi-manager/ContentView.swift` (lines 1612-1970) - Diagnostics screen, editor sheets, and helper functions.
8. `pi-manager/AppViewModel.swift` (lines 5-65, 91-189, 221-525) - central state, refresh flow, derived data, persistence hooks, timers, sidebar enums.
9. `pi-manager/Models.swift` (lines 3-216) - canonical domain model and `ScanSnapshot`.
10. `pi-manager/PiScanner.swift` (lines 7-98, 104-520) - filesystem scan, markdown/JSON parsing, effective-agent resolution, warnings.
11. `pi-manager/ProjectDiscovery.swift` (lines 13-79) - repo discovery under `~/Documents/GitHub` and `.git/config` remote normalization.
12. `pi-manager/AgentPersistence.swift` (lines 6-260) - save-path logic for custom agents and builtin override patches.
13. `pi-manager/ChainPersistence.swift` (lines 3-126) - chain serialization and save-path rules.
14. `pi-manager/EnvPersistence.swift` (lines 3-97) - `.env` editing and write safety.
15. `pi-manager/MarkdownViews.swift` (lines 5-179) - markdown rendering via `WKWebView` + embedded `marked.js`.
16. `pi-manager/DesignSystem.swift` (lines 3-180) - shared cards, pages, tags, and layout primitives.
17. `pi-manager/Assets.xcassets/github.imageset/Contents.json` (lines 1-12) - local GitHub icon used in Overview.

## Key Code
- App shell/navigation: `ContentView.swift:4-120`
  ```swift
  NavigationSplitView { ... List(SidebarItem.allCases, selection: $viewModel.selectedSidebarItem) ... }
  detail: { switch viewModel.selectedSidebarItem { ... } }
  ```
- Current top-level sections live in `SidebarItem`: `AppViewModel.swift:501-524`
  ```swift
  enum SidebarItem: String, CaseIterable, Identifiable {
      case overview, agents, chains, skills, models, environment, mcp, diagnostics
  }
  ```
- App state and refresh flow: `AppViewModel.swift:36-65`
  ```swift
  discoveredProjects = projectDiscovery.discoverProjects()
  globalSnapshot = scanner.scan(projectRoot: nil)
  allProjectSnapshots = ...
  snapshot = makeAggregateSnapshot() / per-project snapshot
  ```
- GitHub-related behavior today is local-only:
  - `ProjectDiscovery.swift:16-31` scans `~/Documents/GitHub`
  - `ProjectDiscovery.swift:35-63` reads `.git/config` to derive a display name
  - `ContentView.swift:227-267` shows discovered projects + warning counts with `Image("github")`
- The read model is `ScanSnapshot`: `Models.swift:204-216`.
- The core scanner/resolver is `PiScanner.scan(projectRoot:)` + `resolveAgents(...)`: `PiScanner.swift:7-98, 238-391`.
- Markdown rendering is centralized in `MarkdownDocumentView`: `MarkdownViews.swift:5-179`.

## Architecture
- Single macOS SwiftUI app target: `@main -> ContentView`.
- MVVM-ish structure: `ContentView` owns one `@StateObject AppViewModel`; most feature views are nested in `ContentView.swift`.
- `AppViewModel` is the coordination layer: project discovery, filesystem scans, selection state, model catalog lookup, and save actions.
- `PiScanner` is the read side of the app. It scans builtin/global/project resources, parses markdown/JSON, resolves precedence, and emits warnings.
- Persistence is split into small services (`AgentPersistence`, `ChainPersistence`, `EnvPersistence`) rather than being embedded in views.
- Shared UI patterns live in `DesignSystem.swift`; markdown preview uses `MarkdownViews.swift`.
- GitHub support currently means “discover local repos under a GitHub folder and display them.” There is no GitHub API/network layer, no issue/PR data model, and no kanban state.

## Start Here
`pi-manager/ContentView.swift` — it defines the app shell, the sidebar switch, and the existing screen patterns. For a GitHub dashboard/kanban feature, this is where a new sidebar item and screen slot would be added first; then wire state in `AppViewModel.swift`.
