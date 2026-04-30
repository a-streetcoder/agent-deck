---
head: 3d6d36764af109100738981bc543dac26a4fcea1
dirty: true
generatedAt: 2026-04-30T23:22:34Z
taskScope: pi-manager architecture, UI/design system, GitHub issue/repo workflows, and integration points for running Pi Agent in-app
changeSummarySincePrevious: cache lacked required metadata and covered a narrower project discovery/icon scope; refreshed for current request
reusedCache: false
---

# Code Context

## Scope
Concise map of the SwiftUI macOS app, current Pi config scanning/editing, GitHub issue/repo functionality, and likely places to add an in-app Pi Agent runner.

## Files Retrieved
1. `pi-manager/pi_managerApp.swift` (lines 8-15) - app entry point creates `ContentView` in a hidden-titlebar window.
2. `pi-manager/ContentView.swift` (lines 1-220, 724-1230, 1292-2640) - main navigation, screens, sheets, sidebar project card, settings/models/subagents/agents UI.
3. `pi-manager/DesignSystem.swift` (lines 1-270) - shared theme/card/page/row/tag/stepper primitives.
4. `pi-manager/AppViewModel.swift` (lines 5-132, 242-930, 1120-1210) - central app state, project scan flow, GitHub state/actions, agent persistence entry points.
5. `pi-manager/ProjectDiscovery.swift` (lines 3-180) - discovers projects, parses GitHub remotes, exposes `DiscoveredProject`.
6. `pi-manager/ProjectPreferences.swift` (lines 3-118) - UserDefaults-backed enabled/favorite/custom icon project prefs.
7. `pi-manager/PiScanner.swift` (lines 3-145) - scans Pi/agent files from global/project paths and builds `ScanSnapshot`.
8. `pi-manager/CommandRunner.swift` (lines 1-174) - async `Process` wrapper; best existing primitive for launching `pi`.
9. `pi-manager/GitHubModels.swift` (lines 1-220) - GitHub session, issue board/detail, repo change models.
10. `pi-manager/GitHubSearchService.swift` (lines 3-130) - REST Search API issue board fetch.
11. `pi-manager/GitHubIssueService.swift` (lines 3-145) - issue detail, comments, parent/sub-issue/dependency fetch and comment post.
12. `pi-manager/GitRepositoryService.swift` (lines 3-180) - git status/diff/stage/commit/push service.
13. `pi-manager/GitHubViews.swift` (lines 1-260+) - GitHub screen UI: segmented sections, connection card, issue list/detail/repo changes.

## Key Code
- App is SwiftUI-only: `pi_managerApp` -> `ContentView()`.
- `ContentView` owns `@StateObject private var viewModel = AppViewModel()` and switches `SidebarItem` to screens, including `.github`, `.agents`, `.subagents`, `.models`, `.settings`.
- `AppViewModel` is the hub: published scan state, selected project, GitHub boards/details, repo changes, loading flags/errors, settings. It constructs `PiScanner`, `ProjectDiscovery`, persistence services, `GitHubCLIAuthService`, and `GitRepositoryService`.
- Project flow: `refresh()` discovers projects, filters enabled ones, scans global + each enabled project, sets `snapshot` to selected project or aggregate.
- `DiscoveredProject` contains `url`, `gitHubRemote`, `isGitRepository`, custom icon URL, search index; `ProjectDiscovery` scans `~/Documents/GitHub` plus manual paths and parses `.git/config` remotes.
- Pi config paths scanned: builtins `/opt/homebrew/lib/node_modules/pi-subagents/agents`; globals `~/.pi/agent/*`, `~/.agents`; project `.pi/agents`, `.agents`, `.pi/settings.json`, `.pi/.env`, `.pi/mcp.json`, `.mcp.json`, `.pi/skills`, `.pi/prompts`.
- Existing process runner: `CommandRunner.run(command,args,currentDirectoryURL,timeout,environment)` resolves executables via user shell then `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`, `/bin`; captures stdout/stderr and supports timeout.
- GitHub auth uses `gh` CLI (`GitHubCLIAuthService`) to get token/session. API calls use `GitHubAPIClient` with bearer token.
- GitHub issue functionality: search issue board per selected repo (`GitHubSearchService.fetchRepositoryIssues`), detail with comments/relationships (`GitHubIssueService.fetchDetail`), and post comments. No issue create/edit/close APIs found.
- Repo workflow: `GitRepositoryService` wraps `git status --porcelain -z -b`, diff, add/restore, commit, push; `AppViewModel` exposes stage/unstage/commit/push methods.

## Architecture
- Single MVVM-style `AppViewModel` serves all screens; most operations mutate `@Published` state and launch async `Task`s back to main actor.
- UI is one `NavigationSplitView`: left sidebar for app sections + project selector card; detail area renders screen-specific views. Design system is lightweight SwiftUI components (`AppPage`, `AppCard`, `AppRowCard`, `AppLabelTag`) using system colors and expanded fonts.
- Persistence is split: project prefs in UserDefaults; Pi resources are written to actual global/project Pi files via persistence structs; GitHub/session data is transient except `gh` auth external state.
- GitHub is project-scoped: selected project must have a GitHub remote for board/issues; repo changes only need a git repo.

## Start Here
For Pi Agent in-app execution, start with `pi-manager/CommandRunner.swift` and `pi-manager/AppViewModel.swift`. Add a dedicated runner service using `CommandRunning`, then expose session/output state through `AppViewModel` and render it as a new screen or GitHub issue action in `ContentView.swift` / `GitHubViews.swift`.

## Constraints And Risks
- `CommandRunner` captures output only after process termination; interactive/streaming Pi Agent will need a new streaming process abstraction (stdout/stderr incremental, stdin write, cancellation) rather than reusing `run` as-is.
- App is `@MainActor`-heavy; long-running agent sessions need background tasks with careful main-actor state updates.
- Current selected-project context is `selectedProjectPath`/`projectRootURL`; agent execution should use `currentDirectoryURL` of selected repo and likely merge env from `.pi/.env`/settings if Pi CLI does not do that itself.
- GitHub issue detail has body/comments/references, making it a good prompt/context source; adding “Run Pi Agent on issue” likely hooks near `GitHubIssueDetail` UI and `AppViewModel.selectWorkItem/loadIssueDetail`.
- No terminal UI component exists; likely need a transcript view styled with `AppCard`/`AppRowCard`, plus controls for start/stop/input.
- Dirty state during scout is only untracked `progress.md` from this task.

## Pi-intercom handoff
No safe orchestrator target was provided; no intercom handoff sent.
