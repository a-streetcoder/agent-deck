---
head: 02bfbbb8ddee65563d25132768e55d1e64bdae00
dirty: true
generatedAt: 2026-05-04T20:08:07Z
taskScope: pi-web-access package presence and Pi RPC tool log display in Pi Agent chat transcript UI
changeSummarySincePrevious: previous cache was unrelated/stale; refreshed targeted context; working tree has unrelated source/doc modifications pre-existing
reusedCache: false
---

# Code Context

## Scope
Understand how `pi-web-access` is represented in Pi Manager and how Pi RPC tool events (including web-access tools) flow into the Agent chat transcript UI.

## Files Retrieved
1. `pi-manager/ContentView.swift` (lines 5179-5190) - Doctor package metadata for `pi-web-access`.
2. `pi-manager/PiRPCClient.swift` (lines 16-38, 40-90) - launches `pi --mode rpc`, decodes stdout JSONL as `PiAgentRPCEvent`, sends RPC commands.
3. `pi-manager/PiAgentRunnerService.swift` (lines 179-214, 348-390, 538-654) - starts RPC session and maps events into persisted transcript entries.
4. `pi-manager/PiAgentSessionModels.swift` (lines 269-352) - transcript entry, roles, RPC event shape, generic `JSONValue` payload storage.
5. `pi-manager/PiAgentViews.swift` (lines 1-190, 444-505, 2799-2945, 3060-3145) - transcript filtering/threading and compact tool activity display.
6. `pi-manager/PiAgentProcess.swift` (lines 28-75, 91-121, 169-181) - child process stdio JSONL plumbing and PATH/env repair.

## Key Code
- `pi-web-access` is not directly integrated with custom UI. It is listed as an essential installable Doctor package only: name `pi-web-access`, install `pi install npm:pi-web-access`, description includes web search/fetch/GitHub/PDF/video (`ContentView.swift:5179-5190`).
- Runtime access is implicit through Pi extensions/tools loaded by the `pi` CLI. Pi Manager starts the local CLI as `pi --mode rpc`, optional `--session`, `--provider`, `--model` (`PiRPCClient.swift:16-29`).
- stdout JSONL is decoded to `PiAgentRPCEvent`; undecodable lines become raw output (`PiRPCClient.swift:30-33`, `PiAgentRunnerService.swift:348-351`).
- Tool events are handled uniformly for any tool name: `tool_execution_start/update/end` -> one upserted transcript entry keyed by `toolCallId`, title `Tool: <toolName>`, text from args/partialResult/result, raw JSON preserved (`PiAgentRunnerService.swift:376-377`, `635-654`).
- Web-access tool names such as `web_search`, `fetch_content`, `get_search_content`, `code_search` get friendly labels/icons in the transcript activity summary (`PiAgentViews.swift:3115-3144`).

## Architecture
Pi Agent UI -> `PiAgentRunnerService.start` -> `PiRPCClient` -> `PiAgentProcess` child process. User prompts are also immediately appended as `.user` entries before sending RPC (`PiAgentRunnerService.swift:179-214`). Incoming RPC events update session state, stream assistant/thinking text, or append/upsert transcript entries. The view observes `store.selectedTranscriptRevision`, debounces in `PiAgentTranscriptRenderCache`, filters low-value raw/status noise, groups entries into `PiAgentTranscriptThread`s, and renders each thread in the scroll view.

## Start Here
Open `pi-manager/PiAgentRunnerService.swift` at `handleToolExecution` (lines 635-654). That is the exact point where pi-web-access RPC log events become transcript activity entries.

## Constraints And Risks
- There is no pi-web-access-specific event parser; behavior depends on Pi RPC emitting standard `tool_execution_*` events with stable `toolName`, args, partialResult/result fields.
- Normal chat hides raw RPC entries and most statuses (`PiAgentViews.swift:177-190`), so full raw JSON is preserved on entries but not generally displayed.
- Tool details are summarized as chips; only latest/suffix detail views are shown elsewhere, so verbose web fetch/search payloads may be truncated or hidden in normal transcript UI.
- Existing working tree was dirty before this scout; findings are based on current files, not a clean HEAD.

## Pi-intercom handoff
No safe orchestrator target was provided for a routine handoff; findings written to `/Users/andrea/Documents/GitHub/pi-manager/context.md`.
