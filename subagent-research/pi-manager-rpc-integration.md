# Pi Manager RPC Integration & Subagent API Research

Date: 2026-05-05  
Scope: current `pi-manager` source, local Pi RPC docs, and installed `pi-subagents` package. No app/source files were changed.

## Executive summary

Pi Manager already embeds Pi through a native Swift JSONL RPC subprocess stack:

- `PiAgentProcess` owns process launch, stdout/stderr line streaming, stdin writes, executable discovery, PATH repair, and termination.
- `PiRPCClient` wraps `pi --mode rpc` commands and decodes raw JSONL events.
- `PiAgentRunnerService` maps RPC events to app session records, transcript entries, model controls, extension UI prompts, and process lifecycle.
- `PiAgentSessionStore` persists app-side session metadata and a bounded transcript cache in Application Support.
- Resource discovery is separate: `PiScanner` scans agents/chains/skills/prompts/env/settings and `AppViewModel` keeps global/project `ScanSnapshot`s for UI and startup-resource previews.

A direct subagent run/talk API would fit best at the `PiRPCClient` + `PiAgentRunnerService` seam, but the current Pi RPC protocol does **not** expose a first-class `run_subagent` command. Today Pi Manager can only trigger subagents indirectly by sending `/run ...` or another slash prompt through `prompt`. The installed `pi-subagents` package exposes a rich `subagent(...)` tool schema internally (`agent`, `task`, `tasks`, `chain`, `async`, `action: status|interrupt|resume`, etc.), but that tool is normally invoked by the LLM or slash bridge, not directly by the host app. A clean app API likely needs either:

1. a new Pi/Pi Subagents RPC command that invokes the registered `subagent` tool/extension directly, or
2. an app-side Node host that imports Pi SDK / `pi-subagents` internals and runs subagents outside the Pi RPC process, or
3. a smaller interim UI that keeps using `/run` and `/subagent` slash commands but improves app-side models around subagent runs and replies.

## Current Pi Agent RPC integration

### Process layer: `PiAgentProcess`

Relevant file: `pi-manager/PiAgentProcess.swift`

Key behavior:

- Resolves the `pi` executable via env vars and common install paths (`resolvePiExecutable`, line 126).
- Launches `Process` with configured arguments/cwd/environment and creates stdin/stdout/stderr pipes (lines 35-53).
- Builds a diagnostic `launchCommand` (line 50).
- Streams stdout/stderr by reading `availableData`, splitting on LF, stripping optional CR, and ignoring empty lines (lines 99-124). This matches Pi RPC JSONL framing requirements.
- Serializes stdin writes on a private dispatch queue via `writeJSONLine` (line 68).
- Termination is graceful-ish at the process layer: close stdin, terminate, then interrupt after 1.5s if still running (lines 79-93).
- PATH repair is handled in `processEnvironment`, which prepends the executable directory and common macOS bins (line 196).

Implication for direct subagents:

- Any direct API that still rides over `pi --mode rpc` should reuse this process layer unchanged.
- If a separate `pi-subagents` helper process is introduced, either reuse this process abstraction or split it into a generic JSONL process wrapper so launch/discovery/termination semantics stay consistent.

### RPC client layer: `PiRPCClient`

Relevant file: `pi-manager/PiRPCClient.swift`

Current launch and commands:

- Spawns `pi --mode rpc` (`args = ["--mode", "rpc"]`, line 17).
- Optionally appends `--session`, `--provider`, and `--model` (lines 18-29).
- Decodes each stdout line as `PiAgentRPCEvent`, preserving raw line if decode fails (lines 32-36).
- Implements state/session/model/message commands:
  - `get_state`, `get_messages`, `get_session_stats`, `get_available_models` (lines 40-43)
  - `abort`, `set_session_name`, `set_model`, thinking-level controls, `compact` (lines 44-56)
  - `prompt`, `steer`, `follow_up` wrappers (lines 57-63)
  - extension UI responses (lines 64-65, 89-92)
- `send(type:fields:)` is generic and can already send arbitrary RPC command types (line 77).

Important limitation:

- There is no typed app method for `get_commands`, `new_session`, `switch_session`, `fork`, `clone`, `bash`, or any direct tool/subagent command, although generic `send` can technically transmit them.
- Pi RPC docs list `get_commands` for slash commands and note extension commands can be invoked by sending a prompt that starts with `/`; they do not describe an `execute_tool`/`run_subagent` host command.

Plug-in point:

- Add methods here if Pi adds direct subagent commands, e.g. `runSubagent(_ request)`, `subagentStatus(id:)`, `subagentInterrupt(id:)`, `subagentResume(id:message:index:)`.
- If using the current protocol only, add safer wrappers for slash prompts (`/run`, `/chain`, `/parallel`, `/subagents-doctor`) rather than embedding string construction in views.

### Runner/orchestration layer: `PiAgentRunnerService`

Relevant file: `pi-manager/PiAgentRunnerService.swift`

Current responsibilities:

- Owns one `PiRPCClient` per app session: `clientsBySessionID: [UUID: PiRPCClient]` (line 6). The old MVP “one process” constraint no longer applies; multiple sessions can have clients.
- Creates project and issue sessions, then starts Pi in the project cwd (`startProjectSession`, line 26; `startIssueSession`, line 38).
- Resumes a Pi session if `piSessionFile` exists (line 56). This is important for context continuity.
- Sends user messages and maps in-run messages to `prompt` with `streamingBehavior: steer|followUp` if needed (lines 60-79).
- Starts by stopping any existing client for the session, appending initial user transcript, creating `PiRPCClient`, storing launch command/status, then sending `getState`, `getAvailableModels`, title/model/thinking setup, and either `prompt`, pending compact, or `getMessages` (lines 189-238).
- Updates session `piSessionFile` and `piSessionId` from `get_state` data (lines 490-493).
- Handles RPC lifecycle/events:
  - `agent_start`/`turn_start`, `agent_end`/`turn_end` (lines 376-390)
  - `message_update` and `message_end` (lines 392-394, 558-653)
  - tool execution start/update/end (lines 396, 655-675)
  - extension UI request/response (lines 398, 724-818)
  - queue, compaction, retry (lines 400-405, 677-721)
- Appends user-edited session names into Pi JSONL session file via a `session_info` entry when not running (lines 241-279).

Plug-in point:

- Direct subagent commands should be exposed at this layer as app-intent methods, not from SwiftUI views directly. Suggested methods:
  - `runSubagent(session:agent:task:options:)`
  - `runSubagentChain(session:chainName/request:)`
  - `refreshSubagentRunStatus(sessionID:runID:)`
  - `talkToSubagent(sessionID:runID:index:message:)` or `resumeSubagent(...)`
  - `interruptSubagent(sessionID:runID:index:)`
- This layer should translate direct subagent result/progress events into app transcripts and new subagent run models.
- Existing `handleToolExecution` already recognizes `toolName == "subagent"` indirectly and stores raw JSON; this is the first place to enrich parsing without changing lower layers.

## Sessions, transcripts, and persistence

### App-side session model

Relevant file: `pi-manager/PiAgentSessionModels.swift`

`PiAgentSessionRecord` stores app metadata:

- identity/kind/title/project/repository/issue (`id`, `kind`, `title`, `projectPath`, `repository`, `issueNumber`, etc.)
- Pi runtime linkage: `piSessionFile`, `piSessionId` (line 81)
- model and thinking fields
- launch/runtime/status/error fields
- token/cost/context metrics
- pending steering/follow-up queues
- `subagentsEnabled` (line 111)
- timestamps and UX flags

`PiAgentTranscriptEntry` is intentionally simple: `id`, `sessionID`, `role`, `title`, `text`, optional `rawJSON`, timestamp (lines 302-327). Roles are `user`, `assistant`, `thinking`, `tool`, `status`, `error`, `stderr`, `raw` (lines 272-281).

`PiAgentRPCEvent` is a tolerant decoder for known event fields (line 330 onward) and `JSONValue` preserves arbitrary nested payloads.

Implication:

- This is enough for generic subagent tool result rendering but not enough for first-class subagent run management. Direct run/talk needs app-side entities that survive restarts and can be selected/replied to independently of parent transcript rows.

### Store persistence

Relevant file: `pi-manager/PiAgentSessionStore.swift`

- Persists to `~/Library/Application Support/Pi Manager/agent-sessions.json` (line 23).
- Stores sessions and transcripts, selected session id, and transient UI requests (lines 6-12, 293-301).
- New sessions get `subagentsEnabled = newSessionSubagentsEnabled` (line 89), derived from package enablement at app refresh time.
- Transcript entries are capped at 500 per session (`maxTranscriptEntriesPerSession`, line 14).
- On app load, active sessions are marked `stopped` and `isCompacting` is reset (lines 219-231).
- Save is debounced by 450ms and writes pretty JSON atomically (lines 262-288).

Implications:

- Current transcripts are a UI cache, not the source of truth for Pi conversation. The true Pi session is the JSONL `piSessionFile`; the app resumes that file on future prompts.
- A direct subagent model should probably be persisted alongside sessions, not inferred from old transcript entries, because transcript capping/raw-shape changes can lose subagent run state.

### Pi session file behavior

- Pi Manager learns `sessionFile` and `sessionId` from `get_state` and stores them (`PiAgentRunnerService.applyState`, lines 490-493).
- Resume uses `--session <session.piSessionFile>` only when the app has a Pi session file (`PiAgentRunnerService.resume`, lines 51-57; start passes it at line 201).
- Initial prompt on a resumed session is sent after launch, so follow-up context is preserved.
- Rename while stopped appends a `session_info` JSONL entry into the Pi session file if a session header exists (`appendSessionInfo`, lines 241-279). This is a direct file mutation and should remain scoped to metadata only.

Implications for direct subagents:

- If subagents create child session files, those paths should be captured explicitly. Installed `pi-subagents` result details include `sessionFile` on each child result/status.
- Forked-context subagents depend on a parent session file. Direct run UI should ensure the parent `piSessionFile` is known before offering `context: fork`, likely by starting/resuming and calling `get_state` first.

## Startup snapshots and resource management

### Scanner/source-of-truth

Relevant file: `pi-manager/PiScanner.swift`

`scan(projectRoot:)` builds a `ScanSnapshot` from local Pi resource locations:

- builtin subagent agents: `/opt/homebrew/lib/node_modules/pi-subagents/agents` (line 5)
- global agents/chains/settings/env/skills/prompts/libraries under `~/.pi/agent` and legacy `~/.agents` (lines 8-20)
- project agents/chains/settings/env/skills/prompts under `.pi/...` and legacy `.agents` (lines 22-28)
- subagent extension config: `~/.pi/agent/extensions/subagent/config.json` (line 20; parsed at line 64)
- runtime extension commands via a non-main-thread `pi --mode rpc` probe and `get_commands` (line 76; implementation line 305)

The snapshot includes effective agents after resolving precedence and builtin overrides (lines 78-89), plus settings/env/prompts/commands/warnings.

Model for snapshots: `pi-manager/Models.swift`

- `ScanSnapshot` fields include agents/chains/skills/commands/prompt templates/settings/env/subagentConfig/warnings (lines 344-383).
- `SettingsSummary` includes packages/prompts/subagent builtin disables/overrides (lines 307-313).
- `SubagentConfigRecord` wraps parsed extension config (lines 322-326).

### App snapshot lifecycle

Relevant file: `pi-manager/AppViewModel.swift`

- `refresh()` scans global and all enabled project snapshots (`globalSnapshot`, `allProjectSnapshots`) and sets either selected project snapshot or an aggregate snapshot (lines 126-144).
- New-session subagent enablement is synchronized from the current settings package list (`areSubagentsEnabledForNewSessions`) at init and refresh (lines 96, 155, 1756-1774).
- `startupSnapshot(forProjectPath:)` currently returns the project snapshot unchanged (lines 1924-1927). It is the hook used by Pi Agent UI to describe what resources are available at session startup.
- Auto-refresh watches `~/.pi/agent`, `~/.agents`, project `.pi`, project `.agents`, prompt templates/settings prompt paths, and `.md/.json/.env/SKILL.md` changes (lines 2988-3030).

### UI startup-resource usage

Relevant file: `pi-manager/PiAgentViews.swift`

- Composer subagent menu uses `session.subagentsEnabled` plus `startupSnapshot(forProjectPath:)` effective agents to build `/run <agent>` commands (lines 675-690 and duplicated in compact inspector at lines 4625-4640).
- `PiAgentStartupResourcesCard` uses the startup snapshot for display of effective agents, skills, prompts, extensions, and env (lines 926-1179). If `subagentsEnabled` is false, it shows a disabled message instead of agent items (lines 989-1008).
- `PiAgentSubagentSummary` parses existing raw `tool_execution_*` transcript JSON for subagent result details such as `mode`, `results`, `progress`, `agent`, `status`, `tokens`, `durationMs`, `outputPath`, `sessionFile`, and `exitCode` (lines 4663-4745). This is the current app-side recognition of subagent activity.

Implications:

- Direct subagent run UI can reuse `startupSnapshot` for agent/chain pickers and config preview.
- The current “startup snapshot” is dynamic, not frozen per session. The `subagentsEnabled` bool records only whether subagents were enabled when the session was created. If reproducibility matters, a future model should persist a per-session snapshot summary or resource fingerprint.

## Installed `pi-subagents` package facts relevant to direct run/talk

Local package: `/opt/homebrew/lib/node_modules/pi-subagents`, version `0.24.0` (`package.json`). It registers Pi extension `./src/extension/index.ts`.

Key facts from package sources:

- The extension registers a `subagent` tool with execution and management/control modes (`src/extension/index.ts`, tool definition around lines 397-465).
- Tool execution modes:
  - single: `{ agent, task? }`
  - parallel: `{ tasks: [...] }`
  - chain: `{ chain: [...] }`
  - async/background: `async: true`
  - context: `fresh | fork`
- Management/control actions from schema/types: `list`, `get`, `create`, `update`, `delete`, `status`, `interrupt`, `resume`, `doctor` (`src/shared/types.ts`, line 597; schema fields in `src/extension/schemas.ts`).
- “Talk” to a child maps most closely to action `resume` with `id`/`runId`, optional `index`, and `message` (`src/extension/schemas.ts`, action/id/message fields).
- Child results/status carry `sessionFile`, tokens, tool count, progress, `asyncId`, `asyncDir`, and per-child status (`src/shared/types.ts`, `SingleResult`, `Details`, `AsyncStatus`, `AsyncJobState`).
- The extension derives subagent session roots from the parent Pi session file: if parent is `~/.pi/agent/sessions/abc123.jsonl`, subagents use `~/.pi/agent/sessions/abc123/<runId>/...` (`src/extension/index.ts`, `getSubagentSessionRoot`, lines 49-60).
- Extension UI is functional in Pi RPC mode; current Pi Manager already handles dialog methods via `extension_ui_request`/`extension_ui_response`.

## Where a direct API could plug in

### Best in-app seam

Add a focused service above `PiRPCClient` and below `AppViewModel`, either inside `PiAgentRunnerService` or as a sibling helper that has access to it:

```text
SwiftUI Views
  -> AppViewModel methods (user intent)
    -> PiAgentRunnerService / PiSubagentRunService (session-bound orchestration)
      -> PiRPCClient typed commands
        -> PiAgentProcess JSONL
```

Reasons:

- Session/cwd/model/lifecycle context already lives in `PiAgentRunnerService`.
- It can ensure the parent Pi process is running/resumed and has a `piSessionFile` before forked subagent runs.
- It already owns transcript insertion, status, and completion notifications.
- It can update store models and call `getState`/`getSessionStats` after subagent completion.

### Three implementation strategies

#### Strategy A — First-class Pi RPC command (preferred if Pi/Pi Subagents can add it)

Add Pi/Pi Subagents RPC commands such as:

- `subagent_run` with payload matching `SubagentParams`
- `subagent_status`
- `subagent_interrupt`
- `subagent_resume`
- perhaps `subagent_list` / `subagent_get`

App work:

- Add typed request/response models in Swift.
- Add `PiRPCClient` methods using `send(type:fields:)`.
- Extend `PiAgentRPCEvent` for subagent events/results if new event names are introduced.
- Add `PiAgentRunnerService` APIs that create/update app-side subagent run records.

Benefits:

- Avoids prompt string injection/quoting bugs.
- Avoids requiring an LLM turn to choose a tool call.
- Can work while the parent agent is idle or streaming, with explicit command semantics.
- Lets the UI offer reliable “talk to child” and “interrupt child” actions.

Open requirement:

- Current RPC docs do not expose direct host tool execution; this requires upstream API support or extension-added RPC command support.

#### Strategy B — Use current slash-command bridge as an interim direct-ish API

Use `PiRPCClient.prompt` with generated slash commands:

- `/run <agent> "task"`
- `/chain ...`
- `/run-chain <chain>`
- `/subagents-doctor`

Current app already does this for the composer menu (`insertRunCommand`, `PiAgentViews.swift` lines 684-690).

Benefits:

- No Pi/Pi Subagents changes needed.
- Existing transcript parsing already recognizes subagent tool results.

Limitations:

- It is still text command injection, not structured API.
- Quoting/escaping and multi-field options are fragile.
- Status/resume/interrupt are not exposed as slash commands for every tool action unless package commands exist; the tool schema itself has those actions, but direct host invocation is absent.
- Hard to produce a stable run id before the slash command returns a result/progress event.

#### Strategy C — App-side Node helper using Pi SDK / pi-subagents internals

Bundle/run a Node helper that imports `@mariozechner/pi-coding-agent`/`pi-subagents` and exposes JSONL IPC to Swift.

Benefits:

- Could call internal subagent executor directly and get typed data.
- Avoids waiting for Pi RPC additions.

Costs/risks:

- New runtime/package management burden in a native Swift app.
- More version coupling to `pi-subagents` internals (not public API in `package.json`; package exports only extension files, no library export contract).
- Duplicate session/process ownership unless carefully integrated with Pi parent session.

## App-side model changes likely needed

### 1. Persist first-class subagent run records

Add a new model, probably in `PiAgentSessionModels.swift`, persisted by `PiAgentSessionStore`:

```swift
struct PiSubagentRunRecord: Identifiable, Codable, Hashable {
    var id: String                 // subagent runId/asyncId if available
    var sessionID: UUID            // parent Pi Manager session
    var mode: String               // single/parallel/chain/management
    var status: PiSubagentRunStatus
    var agent: String?
    var agents: [String]
    var task: String?
    var context: String?           // fresh/fork
    var asyncID: String?
    var asyncDir: String?
    var startedAt: Date?
    var updatedAt: Date?
    var endedAt: Date?
    var children: [PiSubagentChildRecord]
    var rawDetailsJSON: String?
}
```

Child model should include `index`, `agent`, `status`, `task`, `sessionFile`, `outputPath`, `tokens`, `toolCount`, `durationMs`, `exitCode`, `error`, and last activity/tool fields. These fields mirror installed `pi-subagents` `SingleResult`, `AsyncStatus.steps`, and current `PiAgentSubagentSummary.Agent` parsing.

### 2. Extend session records with subagent state summaries

Options:

- Keep runs in `subagentRunsBySessionID` in the store, analogous to transcripts.
- Add counters/flags on `PiAgentSessionRecord`: active subagent count, needs-attention count, last subagent status, maybe `subagentResourceSnapshotID`.

Avoid overloading `PiAgentTranscriptEntry.rawJSON` as the only durable state.

### 3. Add typed request models

For UI/API safety:

```swift
struct PiSubagentRunRequest: Codable, Hashable {
    var agent: String?
    var task: String?
    var tasks: [PiSubagentTaskRequest]?
    var chain: [PiSubagentChainStepRequest]?
    var chainName: String?
    var context: String?
    var async: Bool?
    var cwd: String?
    var model: String?
    var output: String?
    var outputMode: String?
    var includeProgress: Bool?
    var sessionDir: String?
}
```

A separate `PiSubagentControlRequest` should cover status/interrupt/resume.

### 4. Store/freeze startup resource context if needed

Current `startupSnapshot(forProjectPath:)` is live. If the UI should display “what this session started with,” add either:

- a lightweight `PiAgentStartupResourceSnapshot` to `PiAgentSessionRecord`, or
- a resource fingerprint + denormalized names for agents/chains/skills/prompts/env/settings at creation time.

At minimum, for direct run/talk, persist the agent/chain identity selected at launch so the run remains explainable even if files are later renamed.

### 5. Extend transcript roles or metadata

Today subagent rendering is inferred from `role == .tool` and raw JSON. A first-class direct API would benefit from either:

- new `PiAgentTranscriptRole.subagent`, or
- a metadata enum on transcript entries (`kind: tool|subagent|system|...`) while keeping roles stable.

If compatibility is a concern, keep role `.tool` but add a `metadata` object or persist `PiSubagentRunRecord` and link transcript entries by `runID`.

### 6. Add UI request routing for subagent child talks

“Talk”/resume to a child needs target selection:

- run id / async id
- child index for parallel/chain runs
- message text
- whether it resumes a live async child or revives a completed foreground child from `sessionFile`

Current `PiAgentUIRequest` handles extension dialogs but not app-initiated subagent replies. Add explicit AppViewModel methods rather than reusing extension UI request state.

## Implementation risks and constraints

- **Upstream protocol gap:** Pi RPC currently lacks direct host tool execution. Without a new RPC command, any “direct” run is slash-text based.
- **Session prerequisites:** Forked subagents need parent session file continuity. Ensure `get_state` has populated `piSessionFile` before forked runs.
- **Transcript cap:** Current 500-entry cap can drop old subagent result details. Persist run state separately if users need history/status after long sessions.
- **Dynamic resource snapshots:** UI “startup resources” are live scans; persist a snapshot/fingerprint if exact historical resources matter.
- **Multiple active processes:** `clientsBySessionID` supports multiple parent Pi sessions. Direct subagent APIs must scope every command/event to the parent app session id.
- **Event schema drift:** Current `JSONValue` tolerance is good; keep direct subagent parsers permissive and preserve raw details.
- **Extension UI:** Subagent clarification or controls can emit `extension_ui_request`; Pi Manager already supports select/confirm/input/editor, including a custom multi-select parser, but direct API flows must still surface/cancel those requests.
- **Quoting/security:** If Strategy B is used, centralize slash command building and quoting. Do not let views concatenate arbitrary commands.
- **Resource enablement:** `subagentsEnabled` only says the package was enabled for the session; direct API should also verify `pi-subagents` package is installed/enabled in the current effective settings.

## Suggested validation path

No tests are present in the repo. Targeted checks for a future implementation:

1. Build: `xcodebuild -project pi-manager.xcodeproj -scheme pi-manager -configuration Debug build`.
2. Manual RPC smoke:
   - start a project session
   - verify `get_state` populates `piSessionFile`
   - run `/run reviewer "Review this repo without edits"` as the current baseline
   - confirm `tool_execution_*` events create a subagent summary card
3. Resume/session continuity:
   - stop app/run, relaunch, resume same session, send prompt, verify old Pi context still exists.
4. Direct API (if added):
   - run single subagent, async subagent, status, interrupt, resume/talk with child index
   - verify app records `sessionFile`, output path, tokens, and child status
   - verify extension UI requests can be answered/cancelled
5. Resource snapshot:
   - toggle `npm:pi-subagents` in `~/.pi/agent/settings.json`, refresh, confirm new sessions get the correct `subagentsEnabled` and runnable agent list.

## Concrete next-step recommendation

For planning, split work into two tracks:

1. **Low-risk app prep:** add first-class `PiSubagentRunRecord` models/store parsing from current `tool_execution_*` raw JSON. This improves current `/run` behavior and creates the UI/data foundation.
2. **Protocol/API decision:** decide whether to request/implement upstream Pi RPC support for direct subagent commands. If approved, add typed `PiRPCClient` wrappers and route them through `PiAgentRunnerService`. If not approved, keep a centralized slash-command adapter and treat it as an interim compatibility layer.
