# Architecture

Agent Deck is a SwiftUI macOS app organized around a central app model, scanning services, persistence services, Pi RPC runners, and feature views.

## High-level flow

```text
filesystem/settings/packages/projects
        ↓
   PiScanner + AppRefreshService
        ↓
     ScanSnapshot
        ↓
     AppViewModel
        ↓
 SwiftUI screens + persistence/actions
        ↓
 Pi RPC sessions / native subagent runs / git / GitHub API
```

## App shell

- `agent_deckApp.swift` defines the macOS app entry point, window, settings scene, and app commands.
- `ContentView.swift` owns the main navigation, toolbar actions, sheets, selected screen routing, and many resource screens.
- `DesignSystem.swift` provides shared UI components and styling.

## Central state

`AppViewModel` is the central `@MainActor ObservableObject`. It owns published UI state and orchestrates services including scanning, persistence, GitHub, Git, Pi Agent runner, worktree handling, and native subagent runs.

## Scan pipeline

`AppViewModel.refresh()` calls `AppRefreshService.loadSnapshot`, which discovers projects, scans global/project resources with `PiScanner`, and computes file-watch fingerprints. `PiScanner` parses agents, chains, skills, prompts, settings, env keys, runtime commands, packages, and warnings into `ScanSnapshot`.

Resource refresh is event-driven while the app is active: `FileWatchEventMonitor` listens for macOS FSEvents on the current watched roots, debounces change bursts, then runs the existing fingerprint check before refreshing. A slow fallback fingerprint check remains as a safety net. See `agent-deck-documentation/resource-refresh-and-file-watching.md`.

## Pi Agent sessions

- `PiAgentProcess` resolves and launches the `pi` executable.
- `PiRPCClient` implements JSONL RPC over stdin/stdout.
- `PiAgentRunnerService` maps RPC events to session transcript, status, model/tool state, native bridge callbacks, and UI state.

## Native subagents

- `PiNativeSubagentBridgeExtensions` writes generated TypeScript bridge extensions.
- `PiSubagentRunService` creates child runs, artifacts, prompts, worktrees, Pi RPC clients, transcripts, and supervisor request routing.
- `PiSubagentWorktreeService` handles worktree create/apply/discard logic.

## Persistence

- `AgentPersistence` writes custom agents and builtin overrides.
- `ChainPersistence` writes `.chain.md` files.
- `EnvPersistence` updates `.env` files without exposing existing secret values by default.
- `SubagentConfigPersistence` writes subagent extension/config JSON.
- `PiAgentSessionStore` persists app-owned session, transcript, run, request, and plan state.
