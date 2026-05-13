# Source Map

Use this file to quickly find the source of a behavior.

## Core models

- `agent-deck/Models.swift` — resource records, agent configs, effective agents, chains, skills, prompts, settings summaries, env keys, snapshots
- `agent-deck/PiAgentSessionModels.swift` — Pi Agent session state, native subagent records, bridge request payloads, supervisor request models
- `agent-deck/GitHubModels.swift` — GitHub auth, issue, board, and repository change models

## Scanning and refresh

- `agent-deck/PiScanner.swift` — resource discovery, parsing, baseline resolution, warnings, runtime command scan
- `agent-deck/PiAgentLaunchResolver.swift` — app assignment-based native agent resolution
- `agent-deck/AppRefreshService.swift` — project/global snapshot orchestration, watch fingerprinting, and FSEvents monitor
- `agent-deck/ProjectDiscovery.swift` — local project discovery and GitHub remote extraction
- `agent-deck-documentation/resource-refresh-and-file-watching.md` — refresh/watch lifecycle, debounce, and fallback polling behavior

## Persistence and editing

- `agent-deck/AgentPersistence.swift` — custom agents and builtin overrides
- `agent-deck/ChainPersistence.swift` — chain serialization and writes
- `agent-deck/EnvPersistence.swift` — `.env` key updates
- `agent-deck/SubagentConfigPersistence.swift` — native/subagent config JSON
- `agent-deck/ExtensionManagement.swift` — extension/package scanning and settings toggles

## Pi runtime integration

- `agent-deck/PiAgentProcess.swift` — process launch, Pi executable resolution, stdout/stderr streaming
- `agent-deck/PiRPCClient.swift` — JSONL RPC client and commands
- `agent-deck/PiAgentRunnerService.swift` — parent session orchestration
- `agent-deck/PiModelDiscoveryService.swift` — model catalog parsing/probing

## Native subagents

- `agent-deck/PiSubagentRunService.swift` — child run construction and event handling
- `agent-deck/PiNativeSubagentBridgeExtensions.swift` — generated parent/child bridge tools
- `agent-deck/PiSubagentWorktreeService.swift` — worktree isolation and patch application
- `agent-deck/bundled-agents/*.md` — bundled native starter agents

## UI

- `agent-deck/ContentView.swift` — main navigation, toolbar commands, sheets, and screen routing
- `agent-deck/AgentManagementViews.swift`, `ChainManagementViews.swift`, `SkillManagementViews.swift` — resource management screens
- `agent-deck/PiAgentViews.swift` — Pi Agent screen shell and transcript cache
- `agent-deck/PiAgentComposerViews.swift`, `PiAgentTranscriptViews.swift`, `PiAgentSubagentViews.swift` — Pi Agent composer, transcript, and native subagent UI
- `agent-deck/PiAgentActivityPanelViews.swift`, `PiAgentInspectorPanelViews.swift`, `PiAgentRepoChangesPanelViews.swift` — activity, inspector, and repo change panels
- `agent-deck/CommandsAndPromptsViews.swift` — prompts/commands screen
- `agent-deck/GitHubViews.swift`, `GitHubIssuesViews.swift`, `GitHubRepoChangesViews.swift`, `GitHubConnectionViews.swift` — GitHub screen and feature sections
- `agent-deck/SettingsAndCatalogViews.swift` — settings, extensions, models, subagent config screens
- `agent-deck/MarkdownViews.swift` — markdown rendering

## GitHub and Git

- `agent-deck/GitHubCLIAuthService.swift` — `gh` auth/token lookup
- `agent-deck/GitHubAPIClient.swift` — REST client
- `agent-deck/GitHubSearchService.swift` — issue board search
- `agent-deck/GitHubIssueService.swift` — issue details/comments/relationships/actions
- `agent-deck/GitRepositoryService.swift` — git status/diff/stage/commit/push
