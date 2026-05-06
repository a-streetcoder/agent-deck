# Source Map

Use this file to quickly find the source of a behavior.

## Core models

- `pi-manager/Models.swift` — resource records, agent configs, effective agents, chains, skills, prompts, settings summaries, env keys, snapshots
- `pi-manager/PiAgentSessionModels.swift` — Pi Agent session state, native subagent records, bridge request payloads, supervisor request models
- `pi-manager/GitHubModels.swift` — GitHub auth, issue, board, and repository change models

## Scanning and refresh

- `pi-manager/PiScanner.swift` — resource discovery, parsing, resolution, warnings, runtime command scan
- `pi-manager/AppRefreshService.swift` — project/global snapshot orchestration and watch fingerprinting
- `pi-manager/ProjectDiscovery.swift` — local project discovery and GitHub remote extraction

## Persistence and editing

- `pi-manager/AgentPersistence.swift` — custom agents and builtin overrides
- `pi-manager/ChainPersistence.swift` — chain serialization and writes
- `pi-manager/EnvPersistence.swift` — `.env` key updates
- `pi-manager/SubagentConfigPersistence.swift` — native/subagent config JSON
- `pi-manager/ExtensionManagement.swift` — extension/package scanning and settings toggles

## Pi runtime integration

- `pi-manager/PiAgentProcess.swift` — process launch, Pi executable resolution, stdout/stderr streaming
- `pi-manager/PiRPCClient.swift` — JSONL RPC client and commands
- `pi-manager/PiAgentRunnerService.swift` — parent session orchestration
- `pi-manager/PiModelDiscoveryService.swift` — model catalog parsing/probing

## Native subagents

- `pi-manager/PiSubagentRunService.swift` — child run construction and event handling
- `pi-manager/PiNativeSubagentBridgeExtensions.swift` — generated parent/child bridge tools
- `pi-manager/PiSubagentWorktreeService.swift` — worktree isolation and patch application
- `pi-manager/bundled-agents/*.md` — bundled native starter agents

## UI

- `pi-manager/ContentView.swift` — main navigation and many resource screens
- `pi-manager/PiAgentViews.swift` — Pi Agent session UI
- `pi-manager/PiAgentPanelViews.swift` — activity, inspector, and repo change panels
- `pi-manager/CommandsAndPromptsViews.swift` — prompts/commands screen
- `pi-manager/GitHubViews.swift` — GitHub screen
- `pi-manager/SettingsAndCatalogViews.swift` — settings, extensions, models, subagent config screens
- `pi-manager/MarkdownViews.swift` — markdown rendering

## GitHub and Git

- `pi-manager/GitHubCLIAuthService.swift` — `gh` auth/token lookup
- `pi-manager/GitHubAPIClient.swift` — REST client
- `pi-manager/GitHubSearchService.swift` — issue board search
- `pi-manager/GitHubIssueService.swift` — issue details/comments/relationships/actions
- `pi-manager/GitRepositoryService.swift` — git status/diff/stage/commit/push
