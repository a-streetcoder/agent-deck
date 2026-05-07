---
head: 22db3f46d1527c2373d7da232ebf6d2480f257bf
dirty: false
generatedAt: 2026-05-05T07:20:05Z
taskScope: native subagent Phase 1 integration points for transcripts, recovery, managed_subagent, contact_supervisor
changeSummarySincePrevious: none
reusedCache: false
---

# Code Context

## Scope
Minimum map for continuing Pi Manager native subagents after Phase 1, focused on child transcript storage/navigation, run lifecycle recovery, parent-facing `managed_subagent(...)`, and child `contact_supervisor(...)` extension/IPC.

## Files Retrieved
1. `pi-manager/PiSubagentRunService.swift` (lines 1-380) - child RPC launch, event handling, artifacts, prompt/skill/tool argument building.
2. `pi-manager/PiAgentSessionModels.swift` (lines 35-107, 357-390) - native run records and reusable transcript/UI request types.
3. `pi-manager/PiAgentSessionStore.swift` (lines 159-337) - subagent run persistence and existing transcript persistence.
4. `pi-manager/PiAgentViews.swift` (lines 240-540, 1433-1565, 1606-1785, 4840-4910) - native run sheet/card placement and existing UI request card.
5. `pi-manager/AppViewModel.swift` (lines 1282-1304) - app API for run/stop native subagent.
6. `pi-manager/PiRPCClient.swift` (lines 1-115) - RPC launch args/env and extension UI response methods.
7. `pi-manager/PiAgentRunnerService.swift` (lines 360-750) - parent transcript/event pipeline and extension UI request handling to mirror for child runs.
8. `pi-manager/Models.swift` (lines 1-49) and `pi-manager/PiScanner.swift` (lines 700-724) - old subagent extension config fields already scanned.

## Key Code

### Native run foundation
`PiSubagentRunService.runSingle(...)` creates artifacts, resolves skills, builds child args, starts `PiRPCClient`, appends parent status, and sends initial task (`pi-manager/PiSubagentRunService.swift:19-128`). It already handles:
- `--fork` when parent `piSessionFile` exists and agent default is `fork` (`39-44`).
- `--no-context-files`, tools, extensions, `--no-skills` (`46-54`).
- child env: `PI_MANAGER_NATIVE_SUBAGENT`, run id, agent name (`107-111`).

Current child event handling is summary-only (`PiSubagentRunService.swift:137-243`): `get_state` records session file, tool events update current tool, assistant `message_end` writes final text to `output.md`, `turn_end/agent_end` completes the run. There is no persisted child transcript stream.

### Existing models
`PiSubagentRunRecord` and `PiSubagentChildRecord` are persisted but compact (`PiAgentSessionModels.swift:35-107`). They lack child transcript entries, supervisor request records, duration, disconnected/unknown status, and graph edges.

`PiAgentTranscriptEntry` is reusable for child transcripts (`PiAgentSessionModels.swift:372-390`). `PiAgentUIRequest` is reusable or extensible for supervisor decisions (`357-370`).

### Store/persistence
`PiAgentSessionStore` stores `subagentRunsBySessionID` and persists it in `PersistedState` (`PiAgentSessionStore.swift:159-181`, `260-337`). Parent sessions are marked stopped on restart, but subagent runs are loaded unchanged (`248-263`), so active runs can remain stuck active after restart.

Existing transcript methods `append`, `upsert`, `updateEntry` can be mirrored for child transcripts (`PiAgentSessionStore.swift:183-225`).

### UI
Native run cards are rendered above the parent transcript in both empty and non-empty states (`PiAgentViews.swift:467-510`). `PiNativeSubagentRunCard` displays status/task/current tool/summary/error/output path and Stop only (`1606-1666`); no open transcript/artifact actions.

`PiNativeSubagentRunSheet` previews agent config and launches via closure (`1668-1785`). Main and inspector call `viewModel.runNativeSubagent(...)` (`PiAgentViews.swift:259-271`, `4866-4881`).

`PiAgentUIRequestCard` already provides select/multi-select/confirm/input/editor UI and response callbacks (`PiAgentViews.swift:1433-1565`). This is the easiest UI to reuse for `contact_supervisor` blocking requests.

### Parent event/tool bridge hooks
`PiAgentRunnerService.handle(rawLine:event:sessionID:)` routes parent RPC events, including `extension_ui_request`, into store/UI (`PiAgentRunnerService.swift:360-405`). `handleExtensionUIRequest` parses extension requests into `PiAgentUIRequest` and responds through `PiRPCClient` (`724-750+`).

`PiRPCClient` already supports extra launch args/env and generic `send(type:fields:)`, plus extension UI responses (`PiRPCClient.swift:14-48`, `76-105`). This is enough for a parent extension that emits UI/tool requests, or for an app-local IPC extension that sends JSON to Pi Manager.

## Architecture
Native Phase 1 path is:
`PiAgentViews` Run Subagent sheet -> `AppViewModel.runNativeSubagent` -> `PiSubagentRunService.runSingle` -> child `PiRPCClient` process -> child events mutate `PiAgentSessionStore.subagentRunsBySessionID` and append compact parent status entries.

The parent and child runtime paths are currently separate. Parent sessions use `PiAgentRunnerService`, which has full transcript streaming and extension UI handling. Child sessions use `PiSubagentRunService`, which only captures run metadata/final summary. The smallest robust approach is to extract/reuse parent transcript event handling patterns for child transcripts rather than trying to shoehorn children into parent session records.

## Start Here
Start in `pi-manager/PiSubagentRunService.swift`. It is the single choke point for child launch, child event handling, output writing, and future `contact_supervisor` routing. Then update `PiAgentSessionModels.swift`/`PiAgentSessionStore.swift` before UI.

## Constraints And Risks
- Do not make native runs depend on raw slash-command delegation.
- `contact_supervisor` is filtered out of child tools today (`PiSubagentRunService.swift:56`, `271-274`); enabling it requires a real extension/tool bridge first.
- Active subagent runs are not fixed on app restart; add recovery before long-lived runs.
- Parent-facing `managed_subagent(...)` requires a callable Pi tool/extension. Current app only handles extension UI requests, not arbitrary host tool calls.
- Avoid writing configured `output` into project files by default; current service writes app artifact `output.md`.

## Recommended Smallest Implementable Slices

### Slice 1: child transcript persistence/navigation
1. Add `childTranscriptsByRunID: [UUID: [PiAgentTranscriptEntry]]` to `PiAgentSessionStore` and persist it, or add `transcript: [PiAgentTranscriptEntry]` to `PiSubagentRunRecord` if acceptable for small transcripts.
2. Add `appendChildTranscript(runID:parentSessionID:_:)` / `upsertChildTranscript(...)` store methods modeled on parent transcript methods (`PiAgentSessionStore.swift:183-225`).
3. In `PiSubagentRunService.handle(...)`, persist child events:
   - non-decodable raw lines -> `.raw`
   - `message_update` -> streaming assistant/thinking entries, copied/simplified from `PiAgentRunnerService.swift:557-621`
   - `message_end` -> final assistant/thinking/user/raw entries, copied from `622-654`
   - tool events -> `.tool` entries, copied from `656-676`
   - stderr -> `.stderr`
4. Add `selectedSubagentRunID` / sheet or navigation state in `PiAgentViews.swift` and an “Open Transcript” button to `PiNativeSubagentRunCard`.
5. Render a child transcript sheet using `PiAgentTranscriptThreadCard`/`PiAgentTranscriptRenderCache` if possible.

### Slice 2: restart recovery
1. In `PiAgentSessionStore.load()` after loading `subagentRunsBySessionID`, map every active `PiSubagentRunRecord.status.isActive` to `.stopped` or add `.disconnected` status.
2. Set `completedAt` if nil, set `error = "Stopped because Pi Manager was restarted."` if nil, and update child status similarly.
3. Optional: append a parent `.status` entry lazily on first display, not during load, to avoid save side effects.
4. Add `PiSubagentRunStatus.disconnected` only if UI needs to distinguish recoverable/reconnectable; otherwise `.stopped` is the smallest change.

### Slice 3: artifact actions and diagnostics
1. Add “Reveal Artifact” / “Reveal Run Folder” buttons to `PiNativeSubagentRunCard` using `NSWorkspace.shared.activateFileViewerSelecting`.
2. Add missing-skill diagnostics to `PiSubagentRunRecord` or `error`/`summary` when `resolveSkillBlocks` drops names (`PiSubagentRunService.swift:344-355`).
3. Show `childPiSessionFile` and `artifactDirectory` in expanded card/details.

### Slice 4: parent-facing `managed_subagent(...)` MVP
Smallest viable design: bundled/local extension emits an `extension_ui_request` or custom RPC event that the app recognizes.
1. Add a Pi extension file/package that defines `managed_subagent` for parent sessions. It should send a structured JSON request to Pi Manager local IPC or emit a recognizable extension UI request.
2. Add a handler in `PiAgentRunnerService.handle(...)` for a custom event/request method like `managed_subagent` before generic `handleExtensionUIRequest`.
3. Handler should parse `{agent, task, context?}`, call `AppViewModel`/a closure into `PiSubagentRunService`, await or poll completion, then respond through `PiRPCClient.respondToExtensionUI` or a tool-result channel.
4. If Pi extension UI cannot return arbitrary tool output cleanly, first MVP can show an app card and return a short “native subagent run started: <id>” response.
5. Longer-term: implement app-local HTTP/Unix socket IPC so the extension can call Pi Manager directly and block until result.

### Slice 5: native child `contact_supervisor(...)` MVP
1. Define `PiSubagentSupervisorRequest` with fields: id, runID, childID, reason, message, status, response, createdAt, updatedAt.
2. Persist requests in store keyed by parent session/run.
3. Ship/enable a child extension named `contact_supervisor` only for native child runs that request that tool. Stop filtering it out once the extension exists.
4. Extension sends JSON to app IPC with run id from env `PI_MANAGER_SUBAGENT_RUN_ID` and blocks for response when reason is `need_decision`/`interview_request`.
5. In `PiSubagentRunService.handle(...)` or IPC server, create supervisor request records and set run status `.blocked` for blocking requests.
6. Reuse/adapt `PiAgentUIRequestCard` for response UI in the parent session pane.
7. On response, app sends answer back through IPC; run status returns `.running`.
8. First MVP can support only `progress_update` (non-blocking) and `need_decision` text input; add structured interviews later.

### Slice 6: chains/parallel graph after transcript/recovery
1. Add `PiSubagentRunMode.chain/parallel` fields already exist; add child array/edges or `PiSubagentGraphNode` records.
2. Implement sequential chain as orchestration inside `PiSubagentRunService` using existing `runSingle` internals refactored into `launchChild(...)`.
3. Add parallel read-only fanout with a concurrency limit from `SubagentExtensionConfig.parallel` (`Models.swift:13-17`, scanner at `PiScanner.swift:700-724`).
4. Defer writer parallelism until worktree isolation.

### Slice 7: worktree isolation
1. Add worktree policy fields to run request/UI.
2. Use `GitRepositoryService`/shell `git worktree add` from the parent project path before launching child.
3. Pass child cwd as worktree path in `PiRPCClient` launch (`PiSubagentRunService.swift:102`).
4. Track worktree path on child record and add reveal/diff/apply/discard UI.

## Handoff
No supervisor handoff was needed for this scout task.
