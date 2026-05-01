---
head: e6a059a225d9541c2bd1f86151461bc9bf873f55
dirty: true
generatedAt: 2026-05-01T00:09:43Z
taskScope: navigation/sidebar, AppViewModel state/services, GitHub issue detail actions, GitRepositoryService APIs, Xcode file-add patterns for adding an Agent screen/services
changeSummarySincePrevious: HEAD changed 7 files (+2145/-299); relevant ContentView/AppViewModel changed, so refreshed targeted context
reusedCache: false
---

# Code Context

## Scope
Implementation guidance for adding an Agent screen plus supporting Swift services in the current SwiftUI macOS app.

## Files Retrieved
1. `pi-manager/ContentView.swift` (lines 1-220) - app root, sidebar list, detail switch, sheets.
2. `pi-manager/AppViewModel.swift` (lines 1-110, 800-930, 1657-1715) - main state/services/init, issue actions, sidebar enums.
3. `pi-manager/GitHubViews.swift` (lines 272-431) - issue detail UI/actions.
4. `pi-manager/GitHubIssueService.swift` (lines 1-145) - issue detail/comment APIs.
5. `pi-manager/GitRepositoryService.swift` (lines 1-191) - git service public API and parsing.
6. `pi-manager/CommandRunner.swift` (lines 1-80) - process-running primitive for new services.
7. `pi-manager.xcodeproj/project.pbxproj` (lines 9-19, 63-65, 117-124) - Xcode synchronized group pattern.

## Key Code
- Root UI: `ContentView` owns `@StateObject private var viewModel = AppViewModel()` and `NavigationSplitView`; sidebar is `List(selection: $viewModel.selectedSidebarItem)` over `SidebarSection.allCases` / `section.items`; GitHub uses custom `Image("github")`, others use `item.systemImage`. Detail routes via `switch viewModel.selectedSidebarItem` to screens (`GitHubScreen`, `AgentsScreen`, etc.) in `ContentView.swift:4-73, 143-215`.
- Sidebar enum in `AppViewModel.swift:1657-1715`:
  - `SidebarItem`: `.overview`, `.projects`, `.github`, `.agents`, `.chains`, `.skills`, `.commandsAndPrompts`, `.subagents`, `.models`, `.settings`, `.environment`, `.mcp`, `.diagnostics` with `rawValue` labels and `systemImage` switch.
  - `SidebarSection.items`: Workspace = overview/projects/github; Pi Resources = agents/chains/skills/prompts; Runtime = models/settings/environment/mcp/diagnostics. To add an Agent screen, add a case, image, section membership, then handle it in `ContentView.detailView`.
- `AppViewModel` initial state/services in `AppViewModel.swift:8-80`: many `@Published` properties; key ones for new screen are `selectedSidebarItem`, `selectedProjectPath`, `discoveredProjects`, `snapshot`, GitHub state, and `appSettings`. Services are private lets: `PiScanner`, `ProjectDiscovery`, `AgentPersistence`, `ChainPersistence`, `EnvPersistence`, `SubagentConfigPersistence`, stores, `GitHubCLIAuthService`, `GitRepositoryService`. `init()` loads settings/last selected project, calls `refresh(includeModels: true)`, starts auto refresh, then checks/connects GitHub (`AppViewModel.swift:76-89`).
- Existing process/service pattern: `CommandRunner.run(command,args,currentDirectoryURL,timeout,environment)` returns `CommandResult(stdout, stderr, exitCode)` and resolves executables (`CommandRunner.swift:1-80`). Use this for a Pi/Agent service rather than duplicating `Process` handling.
- GitHub issue detail actions: selecting an issue sets `githubSelectedWorkItem`, clears detail/comment, calls `loadIssueDetail`; selecting a relationship may switch project then selects/fabricates a `GitHubWorkItem`; submitting comment validates selection/body, posts, clears draft, invalidates board caches, reloads detail (`AppViewModel.swift:800-930`).
- Issue detail UI only supports opening in browser, clicking relationship groups, viewing comments, and `Post Comment` (`GitHubViews.swift:272-431`). No create/edit/close issue action exists.
- `GitHubIssueService` public API: `fetchDetail(for:)` GETs issue, comments, parent, sub_issues, dependencies blocked_by/blocking in parallel; `postComment(body:for:)` POSTs to issue comments (`GitHubIssueService.swift:3-72`).
- `GitRepositoryService` public API (`GitRepositoryService.swift:3-58`): `loadChanges(in:)`, `loadDiff(for:kind:in:)`, `stage`, `unstage`, `stageAll`, `unstageAll`, `commit(message:in:)`, `pushCurrentBranch(in:)`. It shells out to git via `CommandRunning`; untracked diff returns a text preview; `parseStatus` builds staged/unstaged/untracked/conflicted snapshots (`GitRepositoryService.swift:61-191`).
- Xcode project uses file-system synchronized root group for `pi-manager` (`PBXFileSystemSynchronizedRootGroup`, target `fileSystemSynchronizedGroups`). `PBXSourcesBuildPhase.files` is empty. Pattern means adding a `.swift` under `pi-manager/` should be picked up without adding PBXBuildFile/PBXSources entries (`pi-manager.xcodeproj/project.pbxproj:9-19,63-65,117-124`).

## Architecture
SwiftUI views bind directly to one `@MainActor AppViewModel`. AppViewModel owns persistent config services and transient async service calls. Existing services are value structs with dependency injection where needed (`GitRepositoryService(commandRunner:)`, `GitHubIssueService(apiClient:)`). New Agent runtime services should follow this: create a `*Service.swift` using `CommandRunning`, add `@Published` runtime state plus a private service in `AppViewModel`, and expose intent methods that update state on MainActor.

## Start Here
Open `pi-manager/AppViewModel.swift:1657` and `pi-manager/ContentView.swift:143`. Add the sidebar case/section first, then route it to a new `AgentScreen(viewModel:)` or similarly named SwiftUI view.

## Constraints And Risks
- `SidebarItem.github` has a custom image special case; a new case must have a SF Symbol or similar special handling.
- AppViewModel init immediately refreshes and starts watchers; avoid starting long-running agent processes in `init()` unless explicitly gated.
- GitHub issue APIs are read/comment-only today.
- Repo is dirty (`progress.md` modified by scout); cache is refreshed against dirty worktree.

## Pi-intercom handoff
No safe orchestrator target was specified; not sent.
