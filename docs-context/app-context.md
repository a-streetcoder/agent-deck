# pi-manager app context

Generated from repository inspection on 2026-05-06. This is evidence-backed documentation context for the macOS app in `/Users/andrea.corvi/Documents/GitHub/pi-manager`.

## App purpose

`pi-manager` is a native macOS SwiftUI app for managing the real files/settings that Pi and Pi subagent workflows read. It is not a generic prompt manager or full Pi runtime replacement.

Evidence:

- `pi-manager-spec.md:5` says the app is “a native macOS app for browsing, understanding, editing, and creating the resources used by Pi and `pi-subagents`.”
- `pi-manager-spec.md:12` says it is “Pi-native manager for the actual files and settings Pi reads,” not a generic LLM prompt manager.
- `pi-manager-spec.md:16-24` lists primary product goals: show available agents across builtin/global/project scope, show effective resolved agents, make builtin overrides and skill inheritance understandable, show precedence, improve chain authoring, and be safe about write targets.
- `pi-manager/pi_managerApp.swift:35-51` defines the macOS app entry point, a single `WindowGroup` with `ContentView`, a settings scene, and app commands.

## Main user-facing capabilities

### Resource management for Pi assets

Pi Manager scans, displays, and edits Pi resources:

- Agents and effective resolution across builtin/global/project/library/legacy scopes.
- Builtin overrides written to settings instead of editing package files.
- Chains as `.chain.md` files.
- Skills and skill-library visibility/assignment.
- Prompt templates and extension slash commands.
- Environment `.env` keys with hidden secret values.
- Extensions, models, settings, diagnostics, and docs.

Evidence:

- `pi-manager/AppViewModel.swift:3850-3883` defines sidebar items: Projects, GitHub, Pi Agent, Agents, Chains, Skills, Prompts, Subagents, Extensions, Models, Settings, Environment, Diagnostics, Docs.
- `pi-manager/AppViewModel.swift:3888-3904` groups those into Workspace, Pi Resources, Runtime, and Reference sections.
- `pi-manager/ContentView.swift:715-782` routes sidebar selection to `ProjectsScreen`, `AgentsScreen`, `ChainsScreen`, `SkillsScreen`, `CommandsAndPromptsScreen`, `GitHubScreen`, `PiAgentScreen`, `ExtensionsScreen`, `ModelsScreen`, `SettingsScreen`, `SubagentsScreen`, `EnvironmentScreen`, `DiagnosticsScreen`, and `PiDocsScreen`.
- `pi-manager/PiScanner.swift:6-91` is the central scanner for agents, chains, skills, prompts, settings, env, commands, and subagent config.
- `pi-documentation/pi-manager-resource-management.md:1-23` documents the app-specific model: builtin, active global, library, and project resources.

### Project and GitHub workspace

The app discovers local projects, maps them to GitHub remotes, shows issue boards and repo changes, and can run Pi Agent from a GitHub issue context.

Evidence:

- `pi-manager/ProjectDiscovery.swift:22-80` discovers projects under a root directory and additional manually configured paths, skipping hidden projects and extracting GitHub remotes from `.git/config`.
- `pi-manager/ProjectDiscovery.swift:4-19` models a discovered project with URL, GitHub remote, git-repo flag, icon, search index, and repository display name.
- `pi-manager/GitHubViews.swift:4-40` has a segmented GitHub screen with Project Board, Repo Changes, and Connection sections.
- `pi-manager/GitHubSearchService.swift:5-31` fetches aggregate or repository issue boards through GitHub search queries.
- `pi-manager/GitHubIssueService.swift:7-64` fetches issue detail, comments, parent/sub-issue/dependency references.
- `pi-manager/GitHubIssueService.swift:66-82` posts issue comments and closes issues.
- `pi-manager/GitRepositoryService.swift:7-68` loads git status/diffs and performs stage, unstage, commit, and push operations.
- `PI_AGENT_IN_APP_PLAN.md:5-16` describes the intended “killer workflow”: pick a GitHub issue, run Pi Agent, review changes, commit/push, comment, and optionally close the issue.

### In-app Pi Agent session runner

The app embeds Pi by launching the local `pi` CLI in RPC mode and rendering the session as native SwiftUI transcript/session UI.

Evidence:

- `PI_AGENT_IN_APP_PLAN.md:9-16` recommends a native SwiftUI agent workspace backed by `pi --mode rpc` JSONL.
- `pi-manager/PiRPCClient.swift:20-51` launches `pi --mode rpc`, optionally with session/provider/model/extra args, and decodes each stdout JSON line as `PiAgentRPCEvent`.
- `pi-manager/PiRPCClient.swift:53-83` sends RPC commands including `get_state`, `get_messages`, `get_session_stats`, `get_available_models`, `abort`, `set_session_name`, `set_model`, thinking controls, compaction, `prompt`, `steer`, and `follow_up`.
- `pi-manager/PiAgentProcess.swift:26-58` wraps `Process`, pipes stdin/stdout/stderr, records the launch command, and streams output line-by-line.
- `pi-manager/PiAgentProcess.swift:99-142` resolves the `pi` executable from `PI_MANAGER_PI_PATH`, `PI_CLI_PATH`, shell `command -v pi`, and common install locations.
- `pi-manager/PiAgentRunnerService.swift:4-35` is the main app-owned Pi session runner with callbacks for native managed subagents/chains/parallel, supervisor requests, and session plan bridge calls.
- `pi-manager/PiAgentRunnerService.swift:37-65` creates project and issue sessions; issue sessions use `PiIssuePromptBuilder.issuePrompt`.
- `pi-manager/PiAgentViews.swift:225-345` defines `PiAgentScreen`, including session list, transcript area, composer state, native subagent sheets, transcript/graph sheets, and selection behavior.
- `pi-manager/PiAgentSessionStore.swift:4-24` persists sessions, transcripts, UI requests, subagent runs/transcripts, supervisor requests, and session plans under Application Support.

### Native subagents integrated with Pi Agent

Pi Manager has an app-native subagent runtime that replaces package-managed `/run` for app-owned subagent work. Parent Pi sessions receive bridge tools; child subagents run as separate Pi RPC processes with app-managed artifacts, transcripts, supervisor requests, and optional worktrees.

Evidence:

- `PI_MANAGER_NATIVE_SUBAGENTS_PLAN.md:1-8` states native single-run execution and graph foundations are implemented; remaining work includes fallback model retry and session relay.
- `pi-documentation/native-subagents.md:1-13` says Pi Manager runs app-managed native subagents without relying on old package-managed `/run`.
- `pi-documentation/native-subagents.md:27-38` defines every native run as a parent Pi Agent session, child Pi RPC process per subagent step/task, app artifacts under `~/Library/Application Support/Pi Manager/Subagent Runs/<run-id>/`, and persisted metadata/transcript entries.
- `pi-manager/PiSubagentRunService.swift:4-18` owns child Pi RPC clients and final text/completion/supervisor timeout state.
- `pi-manager/PiSubagentRunService.swift:20-153` builds a single native subagent run: validates task/disabled agent, creates artifact directory, resolves skill blocks, optionally creates a worktree, writes `system-prompt.md` and `input.md`, configures fork/fresh context, context/skill inheritance flags, child bridge extension, tools/extensions, model, expected outcome, read-first paths, and run records.
- `pi-manager/PiSubagentRunService.swift:154-210` launches the child via `PiRPCClient`, sets child environment variables (`PI_MANAGER_NATIVE_SUBAGENT`, run id, agent name, `MCP_DIRECT_TOOLS`), streams child events into app state, and prompts the child.
- `pi-manager/PiNativeSubagentBridgeExtensions.swift:3-20` writes generated parent/child bridge extension TypeScript into Application Support.
- `pi-manager/PiNativeSubagentBridgeExtensions.swift:22-139` defines parent bridge tools including `managed_subagent`, `managed_chain`, `managed_parallel`, `list_supervisor_requests`, `set_session_plan`, and `update_session_plan`.
- `pi-documentation/native-subagents.md:84-96` explains system prompt construction: native boundary + agent prompt + explicit skill blocks as system prompt; task/outcome/read-first/artifact info as user prompt; uses `--no-context-files` and `--no-skills` when inheritance is false.
- `pi-documentation/native-subagents.md:117-129` documents supervisor routing: child `contact_supervisor` can send `progress_update`, `need_decision`, or `interview_request`; parent/human can answer via UI or `list_supervisor_requests`/`answer_supervisor_request`.
- `pi-manager/bundled-agents/scout.md:1-20`, `planner.md:1-18`, `worker.md:1-24`, and `reviewer.md:1-18` are bundled native starter agents, each with Pi Manager-native instructions and `contact_supervisor` availability.

### Native safety and artifacts

The app is designed to make write targets explicit, favor app artifacts, and gate risky project writes/worktree application.

Evidence:

- `pi-manager-spec.md:21-24` includes “Be safe: never hide what file will actually be written.”
- `pi-documentation/native-subagents.md:40-58` defines explicit expected outcomes: Report only, Edit files in worktree, Write/update project file, Direct project writes.
- `pi-documentation/native-subagents.md:53-58` says agent `output` frontmatter is advisory only; project-file output requires caller choice and project-relative path.
- `pi-documentation/native-subagents.md:60-72` defines read-first path rules: caller reads override agent defaults, paths must be project-relative, absolute paths and `..` rejected, contents are not injected.
- `PI_MANAGER_NATIVE_SUBAGENTS_PLAN.md:65-72` says native default should write final child results into app artifacts and only write project files when explicitly requested/approved.

## Architecture overview

### SwiftUI app shell

- `pi-manager/pi_managerApp.swift` creates the app, delegate, window, commands, and settings scene.
- `pi-manager/ContentView.swift` owns the sidebar, selected screen routing, toolbar actions, sheets/editors, project selector card, and Pi Agent panels.
- `pi-manager/DesignSystem.swift` defines the visual style (`AppPage`, `AppCard`, `AppSidebarPane`, glass/content surfaces, metric tiles, tags).
- `pi-manager/MarkdownViews.swift` renders markdown via SwiftUI/WebKit-backed components.

Evidence:

- `pi-manager/pi_managerApp.swift:35-51`; `pi-manager/ContentView.swift:82-161`; `pi-manager/DesignSystem.swift:1-44`; `pi-manager/DesignSystem.swift:83-149`; `pi-manager/MarkdownViews.swift:1-40`.

### Central state and orchestration

`AppViewModel` is the central `@MainActor ObservableObject` for UI state and service orchestration.

Evidence:

- `pi-manager/AppViewModel.swift:28-87` declares published app state for snapshots, sidebar selection, selected resources, discovered projects, GitHub state, repo diffs, Pi Agent inspector/activity flags, and settings.
- `pi-manager/AppViewModel.swift:89-101` owns core services: `AgentPersistence`, `ChainPersistence`, `EnvPersistence`, `SubagentConfigPersistence`, `PiExtensionManagementService`, project/settings stores, GitHub auth, git service, worktree service, Pi Agent runner, and native subagent runner.
- `pi-manager/AppViewModel.swift:116-149` wires Pi Agent runner callbacks to native subagent/chain/parallel execution, supervisor request listing/answers, session plan bridge updates, and native subagent catalog prompt generation.
- `pi-manager/AppViewModel.swift:194-238` refreshes snapshots asynchronously through `AppRefreshService` and reapplies selected IDs.

### Scan/refresh pipeline

1. `AppViewModel.refresh()` calls `AppRefreshService.loadSnapshot` on a detached task.
2. `AppRefreshService` discovers projects, filters enabled projects, scans global and project resources with `PiScanner`, and creates a file-watch fingerprint.
3. `PiScanner` reads actual Pi resource files and settings, resolves effective agents, and returns `ScanSnapshot`.

Evidence:

- `pi-manager/AppViewModel.swift:194-218` starts refresh and calls `AppRefreshService().loadSnapshot(...)`.
- `pi-manager/AppRefreshService.swift:16-57` discovers projects, scans global snapshot, scans selected/all enabled project snapshots, and computes `watchFingerprint`.
- `pi-manager/AppRefreshService.swift:59-91` watches `~/.pi/agent`, `~/.agents`, each enabled project `.pi`/`.agents`, prompt templates, and settings prompt paths.
- `pi-manager/PiScanner.swift:6-91` scans global/project resource directories and settings.
- `pi-manager/Models.swift:344-388` defines `ScanSnapshot` with resource arrays and warnings.

### Pi RPC process architecture

- `PiAgentProcess` is the low-level process wrapper and executable resolver.
- `PiRPCClient` adds JSONL command/event protocol on top of `PiAgentProcess`.
- `PiAgentRunnerService` maps Pi RPC events to parent session transcript/status/model/tool/UI state.
- `PiSubagentRunService` maps child Pi RPC events to native subagent run records, child transcripts, artifacts, supervisor requests, and parent status entries.

Evidence:

- `pi-manager/PiAgentProcess.swift:1-88`; `pi-manager/PiRPCClient.swift:3-114`; `pi-manager/PiAgentRunnerService.swift:4-210`; `pi-manager/PiSubagentRunService.swift:4-210`.

## Important modules/files

### Models and data records

- `pi-manager/Models.swift`
  - `ResourceScopeKind`, `ScopeID`: scope taxonomy including builtin, global, project, legacy project, override, package, library (`Models.swift:37-54`).
  - `AgentConfig`: parsed agent frontmatter/body model with model, fallback models, thinking, prompt mode, context/skills inheritance, tools, MCP direct tools, extensions, explicit skills, output, default reads/progress, interactive, max depth, system prompt, unknown fields (`Models.swift:56-92`).
  - `AgentRecord`, `BuiltinOverrideRecord`, `EffectiveAgentRecord`: raw and resolved agent records (`Models.swift:94-157`).
  - `ChainStepRecord`, `ChainRecord`, `SkillRecord`: chain/skill models (`Models.swift:159-193`).
  - `PromptTemplateRecord`, `CommandRecord`, `SettingsSummary`, `EnvKeyRecord`, `SubagentConfigRecord`, `AvailableModel`, `ScanSnapshot` (`Models.swift:253-388`).
- `pi-manager/PiAgentSessionModels.swift`
  - Parent session kinds/status/input modes (`PiAgentSessionModels.swift:3-29`).
  - Native subagent statuses and supervisor request kinds/statuses (`PiAgentSessionModels.swift:31-59`).
  - Bridge request payloads for managed subagent/chain/parallel, supervisor answers, and session plans (`PiAgentSessionModels.swift:76-124`).
  - Native run mode, worktree status, context mode, expected outcome, child/run records (`PiAgentSessionModels.swift:136-220+`).
- `pi-manager/GitHubModels.swift`
  - GitHub auth/session/remotes/connection state, issue board models, issue detail models, repository changes and diff models (`GitHubModels.swift:3-238`).

### Persistence/editing

- `pi-manager/AgentPersistence.swift`
  - Creates drafts for custom agents or builtin overrides (`AgentPersistence.swift:5-41`).
  - Saves custom agents or settings-based builtin overrides (`AgentPersistence.swift:43-56`, `AgentPersistence.swift:118-149`).
  - Applies override fields and serializes only differences from builtin base (`AgentPersistence.swift:70-116`, `AgentPersistence.swift:151-180`).
- `pi-manager/ChainPersistence.swift`
  - Serializes/saves/duplicates/converts `.chain.md` files (`ChainPersistence.swift:3-115`).
  - Writes global chains to `~/.pi/agent/chains`, library chains to `~/.pi/agent/agent-library/chains`, project chains to `PROJECT/.pi/chains` (`ChainPersistence.swift:117-125`).
- `pi-manager/EnvPersistence.swift`
  - Writes global `.pi/agent/.env` or project `.pi/.env`; updates/de-duplicates key lines without revealing by default (`EnvPersistence.swift:1-113`).
- `pi-manager/SubagentConfigPersistence.swift`
  - Writes `~/.pi/agent/extensions/subagent/config.json`-style config with async/control/parallel/worktree/intercom fields (`SubagentConfigPersistence.swift:1-55`).
- `pi-manager/PiAgentSessionStore.swift`
  - Persists app session state to `~/Library/Application Support/Pi Manager/agent-sessions.json` (`PiAgentSessionStore.swift:25-36`).
  - Stores sessions, transcripts, UI requests, native subagent runs/transcripts, supervisor requests, and session plans (`PiAgentSessionStore.swift:4-19`).

### Services

- `pi-manager/CommandRunner.swift`: async short-lived command runner with executable resolution, timeout, stdout/stderr capture, and safe executable name checks (`CommandRunner.swift:24-126`). Used by GitHub CLI, Git, and model discovery.
- `pi-manager/GitHubCLIAuthService.swift`: checks `gh auth status --json hosts` and obtains token via `gh auth token` (`GitHubCLIAuthService.swift:7-60`).
- `pi-manager/GitHubAPIClient.swift`: authenticated REST client for `GET`, `POST`, `PATCH` with GitHub API headers (`GitHubAPIClient.swift:3-68`).
- `pi-manager/GitHubSearchService.swift`: issue search board construction (`GitHubSearchService.swift:5-121`).
- `pi-manager/GitHubIssueService.swift`: issue detail/comments/relationships/comment/close (`GitHubIssueService.swift:7-110`).
- `pi-manager/GitRepositoryService.swift`: `git status`, diffs, stage/unstage, commit, push (`GitRepositoryService.swift:3-169`).
- `pi-manager/PiModelDiscoveryService.swift`: runs `pi --list-models`, parses provider/model/context/output/thinking/images, probes node module for exact thinking levels (`PiModelDiscoveryService.swift:3-91`).
- `pi-manager/ExtensionManagement.swift`: scans auto/settings/package extensions and writes explicit `+`/`-` settings entries to enable/disable without deleting files (`ExtensionManagement.swift:3-180`).
- `pi-manager/PiSubagentWorktreeService.swift`: handles native subagent worktree isolation/apply/discard (not deeply inspected here; referenced by `AppViewModel.swift:97`).

### UI screens

- `pi-manager/AgentManagementViews.swift` `AgentsScreen`: agent library pane plus selected agent detail, editing, builtin disable controls, library/global/project enablement, assigned project/skill visibility warnings.
- `pi-manager/ChainManagementViews.swift` `ChainsScreen`: chain list, create/duplicate/convert, run native chain, open/reveal/edit.
- `pi-manager/SkillManagementViews.swift` `SkillsScreen`: active project skills, global skills, library skills, package skills, detail panel, import sheet.
- `pi-manager/CommandsAndPromptsViews.swift:4-23` `CommandsAndPromptsScreen`: prompt templates and runtime slash/extension commands.
- `pi-manager/GitHubViews.swift:4-40` `GitHubScreen`: project board, repo changes, connection.
- `pi-manager/PiAgentViews.swift:225-345` `PiAgentScreen`: sessions, transcript, composer, native subagent run/graph/transcript sheets.
- `pi-manager/PiAgentActivityPanelViews.swift` activity panel; `PiAgentRepoChangesPanelViews.swift` repo changes panel; `PiAgentInspectorPanelViews.swift` inspector panel.
- `pi-manager/SettingsAndCatalogViews.swift:4-120` `SettingsScreen`: project root, skill imports, GitHub cache, Pi Agent settings.
- `pi-manager/SettingsAndCatalogViews.swift:222-312` `ExtensionsScreen`: extension safety and package/local extension listing/toggles.
- `pi-manager/SettingsAndCatalogViews.swift:383-448` `ModelsScreen`: model catalog display.
- `pi-manager/SettingsAndCatalogViews.swift:484-612` `SubagentsScreen`: subagent config UI.
- `pi-manager/EnvironmentDiagnosticsViews.swift` `EnvironmentScreen`: effective env keys with secret reveal behavior.
- `pi-manager/EnvironmentDiagnosticsViews.swift` `DiagnosticsScreen`: doctor screen for package/helper/settings/warnings.

## Resource paths and resolution rules

### Paths scanned by the app

`PiScanner.scan(projectRoot:)` uses these app paths:

- Agents:
  - Bundled app agents from `Bundle.main.resourceURL/bundled-agents` or source `pi-manager/bundled-agents` (`PiScanner.swift:125-137`).
  - Global: `~/.pi/agent/agents`, legacy `~/.agents` (`PiScanner.swift:7-8`, `PiScanner.swift:33-35`).
  - Project: `PROJECT/.pi/agents`, legacy `PROJECT/.agents` (`PiScanner.swift:20-22`, `PiScanner.swift:36-37`).
  - Library: `~/.pi/agent/agent-library/agents` (`PiScanner.swift:10`, `PiScanner.swift:47`).
- Chains:
  - Global `~/.pi/agent/chains`, project `PROJECT/.pi/chains`, library `~/.pi/agent/agent-library/chains` (`PiScanner.swift:9`, `PiScanner.swift:21`, `PiScanner.swift:11`, `PiScanner.swift:43-48`).
- Settings:
  - Global `~/.pi/agent/settings.json`, project `PROJECT/.pi/settings.json` (`PiScanner.swift:12`, `PiScanner.swift:23`, `PiScanner.swift:39-42`).
- Environment:
  - Global `~/.pi/agent/.env`, project `PROJECT/.pi/.env` (`PiScanner.swift:13`, `PiScanner.swift:24`, `PiScanner.swift:61-63`).
- Skills:
  - Global `~/.pi/agent/skills`, legacy global `~/.agents/skills`, project `PROJECT/.pi/skills`, package-discovered skills, library `~/.pi/agent/skill-library` (`PiScanner.swift:14-16`, `PiScanner.swift:25`, `PiScanner.swift:51-59`).
- Prompt templates:
  - Global `~/.pi/agent/prompts`, project `PROJECT/.pi/prompts`, library `~/.pi/agent/prompt-library`, plus settings/package prompt paths (`PiScanner.swift:17-18`, `PiScanner.swift:26`, `PiScanner.swift:69-74`).
- Subagent extension config:
  - `~/.pi/agent/extensions/subagent/config.json` (`PiScanner.swift:19`, `PiScanner.swift:65`).

### Agent resolution/precedence

The app constructs effective agents from builtin, legacy/global/project records and global/project overrides.

Evidence:

- `pi-manager/PiScanner.swift:76-87` calls `resolveAgents` with builtin, legacy global, global, legacy project, project, user/project overrides, and user/project disable-builtins flags.
- `pi-manager/Models.swift:131-157` `EffectiveAgentRecord` tracks builtin, global custom, project custom, user/project overrides, resolved config, resolution kind, winning record, and source path.
- `pi-manager/Models.swift:117-129` defines resolution kinds: Builtin, Builtin + Override, Global, Project, Global Replacement, Project Replacement, Library.
- `pi-manager/AgentPersistence.swift:118-149` writes builtin override diffs under `subagents.agentOverrides` in the target settings JSON.

### Settings/env parsing

- `pi-manager/PiScanner.swift:696-727` parses settings JSON for `packages`, `prompts`, `subagents.disableBuiltins`, and `subagents.agentOverrides`.
- `pi-manager/PiScanner.swift:730-746` parses `.env` lines into `EnvKeyRecord`s, ignoring blank/comment lines.
- `pi-manager/ContentView.swift:4426-4430` explains effective env behavior in UI: project `.env` wins over global/user values for the same key.

## Pi integration details

### Parent Pi Agent sessions

- Run with `pi --mode rpc` through `PiRPCClient`.
- May include a generated parent bridge extension when native subagents are enabled.
- May include an appended system prompt catalog listing available native agents/chains.
- Session state is rendered as native transcript cards, not a terminal.

Evidence:

- `pi-manager/PiAgentRunnerService.swift:159-168` adds the parent bridge extension and native subagent catalog to `extraArguments` when `session.subagentsEnabled`.
- `pi-manager/PiAgentRunnerService.swift:169-191` constructs `PiRPCClient` with cwd, optional session file, provider/model override, env `PI_MANAGER_PARENT_SESSION_ID`, and event/stderr/termination handlers.
- `pi-manager/PiAgentRunnerService.swift:198-210` initializes state/models/session name/thinking level and sends initial prompt or gets messages.

### Child native subagent sessions

- Run as separate `PiRPCClient` processes.
- Use optional `--fork <parent-session-file>` or fresh `--session-dir`.
- Pass `--no-context-files` when agent `inheritProjectContext` is not true.
- Pass `--no-skills` when agent `inheritSkills` is not true.
- Load app child bridge extension only when agent tools include `contact_supervisor`.
- Explicit agent skills are resolved by the app and injected privately into the child system prompt.

Evidence:

- `pi-manager/PiSubagentRunService.swift:46-61` resolves context to `--fork` or `--session-dir` and records warnings when fork requested but unavailable.
- `pi-manager/PiSubagentRunService.swift:64-66` applies `--no-context-files` based on `inheritProjectContext`.
- `pi-manager/PiSubagentRunService.swift:67-76` loads child bridge extension when `contact_supervisor` is requested.
- `pi-manager/PiSubagentRunService.swift:80-82` applies `--no-skills` based on `inheritSkills`.
- `pi-documentation/pi-core-system-reference-and-subagents.md:55-67` describes native child sessions as app-owned child Pi RPC sessions with private skill blocks, expected outcome, read-first paths, artifacts, and streamed events.

### Prompt building from GitHub issues

- `pi-manager/PiIssuePromptBuilder.swift:4-7` uses the raw project instruction for project sessions.
- `pi-manager/PiIssuePromptBuilder.swift:9-31` builds an issue prompt with issue number/title/url/body, relationship lines, and the last three comments.

### External dependencies/tools

- Pi CLI (`pi`) is required for agent sessions, model listing, and RPC integration.
- GitHub CLI (`gh`) is used for auth/token discovery; GitHub API is called directly after token retrieval.
- Git CLI (`git`) is used for repo status/diff/stage/commit/push.
- Node is used by `PiModelDiscoveryService` to inspect Pi AI model reasoning support.
- App integrates with macOS AppKit/SwiftUI/UserNotifications/WebKit.

Evidence:

- `pi-manager/PiAgentProcess.swift:99-142` Pi CLI resolution and install error.
- `pi-manager/GitHubCLIAuthService.swift:7-60` `gh` usage.
- `pi-manager/GitRepositoryService.swift:7-68` `git` usage.
- `pi-manager/PiModelDiscoveryService.swift:10-62` `pi --list-models` and `node --input-type=module --eval` usage.
- `pi-manager/pi_managerApp.swift:8-30` notification delegate handles Pi Agent notification responses.

## Settings and user preferences

`AppSettings` persists to `UserDefaults` key `piManagerAppSettings`.

Settings include:

- `gitHubBoardCacheLifetimeMinutes` default 15.
- `piAgentNotificationDelayMinutes` default 3.
- `piAgentThinkingDisplayMode` default full.
- `piAgentTranscriptVisibility` flags for thinking/web/tool/errors.
- `piAgentTerminalApplicationPath`.
- `projectsRootPath` default from `ProjectDiscovery.defaultRootDirectoryURL()`.
- `defaultSkillsImportRootPath`.
- `nativeSubagentsEnabledForNewSessions` default true.

Evidence:

- `pi-manager/AppViewModel.swift:3779-3815` defines `AppSettings` and decoding defaults.
- `pi-manager/AppViewModel.swift:3827-3848` defines `AppSettingsStore` backed by `UserDefaults`.
- `pi-manager/SettingsAndCatalogViews.swift:4-120` exposes projects root, skill import folder, GitHub cache lifetime, Pi Agent reasoning display and notification delay in UI.

## Diagnostics and package awareness

Diagnostics surface relevant packages and warnings.

Evidence:

- `pi-manager/ContentView.swift:4951-5039` lists package checks for `pi-subagents`, `pi-web-access`, `pi-intercom`, and `pi-ask-user`, including install commands and installed-version detection.
- `pi-manager/PiScanner.swift:88-99` builds warnings from effective agents, raw agents, chains, skills, prompt templates, env keys, malformed resource warnings, package-skill warnings, and prompt-scan warnings.
- `pi-manager-spec.md:74-89` calls for overview/diagnostics warnings for duplicate agents, malformed frontmatter, broken chain references, unresolved skills, missing env keys, and extension/tool mismatches.

## Important documentation already in repo

- `pi-manager-spec.md`: product spec and screen/resource model.
- `PI_AGENT_IN_APP_PLAN.md`: architecture for in-app Pi Agent via RPC and GitHub issue flow.
- `PI_MANAGER_NATIVE_SUBAGENTS_PLAN.md`: implementation status and native subagent architecture.
- `pi-documentation/native-subagents.md`: current native subagent runtime behavior, expected outcomes, artifacts, supervisor routing, worktrees.
- `pi-documentation/pi-core-system-reference-and-subagents.md`: Pi runtime discovery/system-prompt/subagent context reference.
- `pi-documentation/pi-manager-resource-management.md`: app-specific resource management paths, library-vs-active model, bundled native agents.
- `pi-documentation/pi-commands-and-prompt-templates.md`: slash commands vs prompt templates and how Pi Manager surfaces them.
- `pi-documentation/pi-skills-discovery.md`: skill discovery rules and collision behavior.
- `PI_MANAGER_RPC_SMOKE_TESTS.md`: command-line validation recipes for Pi RPC and bridge mechanics.

## Validation / tests context

- Test target currently has at least `pi-managerTests/PiModelDiscoveryServiceTests.swift`, focused on model parsing/capability behavior.
- RPC validation docs are in `PI_MANAGER_RPC_SMOKE_TESTS.md`; they show baseline `pi --mode rpc` checks, tool event checks, and bridge extension load checks.
- No app build/test command was run for this documentation task.

## Key constraints and risks

- The app intentionally manages real Pi files; documentation and code should distinguish Pi runtime discovery from Pi Manager’s app-specific active/library model.
- Builtin resources should not be edited directly; overrides/replacements/settings are the safe path (`pi-documentation/pi-manager-resource-management.md:30-42`; `AgentPersistence.swift:118-149`).
- Native subagent `output` frontmatter is advisory; project writes require explicit expected outcome and path (`native-subagents.md:53-58`).
- GUI-launched macOS PATH can miss CLI tools; `PiAgentProcess` and `CommandRunner` contain explicit shell/candidate resolution logic.
- Existing app sessions do not automatically pick up extension setting changes; `ExtensionsScreen` warns new sessions or CLI reload are needed (`SettingsAndCatalogViews.swift:222-234`).
- Native subagents depend on Pi RPC schema and generated TypeScript bridge extension behavior; smoke tests should be used after bridge/protocol changes.
