# Architecture

## Overview

Agent Deck is a native macOS SwiftUI app that manages resources for the Pi coding agent and runs Pi Agent sessions through Pi's JSONL RPC mode. It does NOT embed Pi — it launches the installed `pi` CLI as a child process.

## Data Flow

```
Filesystem / Settings
    ↓
PiScanner + AppRefreshService
    ↓ (FSEvents + fingerprint gating)
ScanSnapshot
    ↓
AppViewModel (@MainActor ObservableObject)
    ↓
SwiftUI Views + Services
    ↙           ↘
Pi Agent RPC     Subagents / Git / GitHub
```

## Central State

`AppViewModel` owns all published UI state and orchestrates scanning, persistence, GitHub, Git, Pi Agent sessions, worktrees, and native subagent services. It is the single source of truth for UI state.

## Scan Pipeline

`AppViewModel.refresh()` → `AppRefreshService.loadSnapshot()` → `PiScanner` → `ScanSnapshot`. This is the only supported refresh path.

File watching uses `FileWatchEventMonitor` (macOS FSEvents) with a 1-second debounce and a 5-minute safety poll fallback. A lightweight fingerprint check gates every refresh — unchanged fingerprints skip the refresh entirely.

## Key Services

| Service | Responsibility |
|---|---|
| `PiAgentProcess` | Resolve and launch the `pi` executable |
| `PiRPCClient` | JSONL RPC protocol over stdin/stdout |
| `PiAgentRunnerService` | Map RPC events to UI state |
| `PiSubagentRunService` | Manage native subagent child runs, artifacts, worktrees |
| `PiSubagentWorktreeService` | Git worktree isolation and patching |
| `PiNativeSubagentBridgeExtensions` | Generated TypeScript bridge extensions |
| `AppRefreshService` | Orchestrate scan/poll, manage FSEvents watchers |
| `PiScanner` | Discover and parse agents, skills, prompts, settings, env, and resource warnings |
| `AgentPersistence` | Write custom agents and builtin overrides |
| `EnvPersistence` | Write `.env` files; hides secret values by default |
| `SubagentConfigPersistence` | Subagent configuration JSON |
| `PiAgentSessionStore` | Session file persistence |
| `MCPConnectionManager` | Scoped MCP catalogs, connections, policy, and calls |
| `CodexComputerUseBrokerDiscovery` | Resolve the exact external Computer Use app-server broker and Node runtime |

## Read-Only Builtins

Bundled resources (agents, skills, prompts) inside the app bundle are read-only. When a user edits a builtin, the app writes an override file — it never modifies the bundled original. Code must never write directly to builtin paths.

## Persistence

Persistence is fragmented by domain — each service owns its own file format and write semantics. All file I/O goes through the appropriate persistence service.

## Native Subagents

Native subagents are app-managed child Pi RPC sessions, not raw slash-command delegation. They get their own `--session-dir`, system prompt, tool allowlists, and extension lists. Fresh runs start blank; continuations receive only their own child history.

## Where to Look

Use the source map as an entry point, but always inspect actual files before editing:
- Scanner/resources: `PiScanner.swift`, `Models.swift`
- Native subagents: `PiSubagentRunService.swift`, `PiNativeSubagentBridgeExtensions.swift`, `bundled-agents/*.md`
- Pi Agent RPC: `PiRPCClient.swift`, `PiAgentRunnerService.swift`
- MCP and Computer Use: `MCP/`, `CodexPluginMCPDiscovery.swift`, `CodexComputerUseBrokerDiscovery.swift`, `ComputerUseCapability.swift`
- Persistence: `*Persistence.swift`, `PiAgentSessionStore.swift`
- UI: relevant view file + `AppViewModel.swift`

For full architecture details, see `agent-deck-documentation/contributors/architecture.md`.