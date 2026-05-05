# pi-intercom + pi-manager subagent communication research

_Date: 2026-05-05_

## Sources reviewed

- `pi-intercom` GitHub repo cloned to `/tmp/pi-intercom` at `main` HEAD (`5caa4aa…`), especially `README.md`, `index.ts`, `broker/*`, `reply-tracker.ts`, `types.ts`, and bundled `skills/pi-intercom/SKILL.md`.
- Pi Manager docs: `pi-documentation/pi-subagents-intercom-deep-dive.md`, `pi-documentation/pi-subagents-architecture.md`, `pi-documentation/pi-subagent-official-skill.md`.
- Pi Manager app/RPC context: `PI_AGENT_IN_APP_PLAN.md`, `pi-manager/PiRPCClient.swift`, `pi-manager/PiAgentRunnerService.swift`, and the current SwiftUI intercom/subagent explanatory UI in `pi-manager/ContentView.swift`.

## What pi-intercom provides today

### Core model

`pi-intercom` is a local, same-machine, direct 1:1 messaging layer between Pi sessions. Its README describes it as “Direct 1:1 messaging between pi sessions on the same machine” (`/tmp/pi-intercom/README.md:7`) and says each session connects to a small local broker that registers sessions and routes direct messages (`README.md:25-28`). The broker is local IPC only: Unix socket on macOS/Linux or named pipe on Windows (`README.md:418-423`, `broker/paths.ts:10-17`).

A session becomes visible only if it loaded the extension and registered with the broker; the session list is not a list of every open Pi process (`README.md:57`, `README.md:483`).

### Protocol and runtime pieces

- **Broker process**: auto-spawned on first use and exits after idle (`README.md:420-421`, `broker/spawn.ts:131`). It keeps a `Map<string, ConnectedSession>` and routes by session id or unique session name (`broker/broker.ts:82`, `broker/broker.ts:234-267`, `broker/broker.ts:303-311`).
- **Framing**: length-prefixed JSON, 4-byte big-endian length plus JSON payload, so fragmented socket reads are safe (`README.md:423`, `broker/framing.ts:4-43`).
- **Session metadata**: id, optional name, cwd, model, pid, timestamps, status (`types.ts:1-10`).
- **Messages**: id, timestamp, optional `replyTo`, optional `expectsReply`, text, and optional attachments (`types.ts:12-27`).
- **Delivery semantics**: broker returns `delivered` / `delivery_failed`; client validates protocol messages and correlates list requests by `requestId` (`types.ts:30-45`, `broker/client.ts:296-338`).

### Agent-facing tools

`pi-intercom` registers a general `intercom` tool with actions `list`, `send`, `ask`, `reply`, `pending`, and `status` (`index.ts:1305-1339`). Important behavior:

- `send`: fire-and-forget delivery to a named/id target; optional confirmation in interactive sessions (`README.md:209`, `index.ts:1401-1450`).
- `ask`: sends with `expectsReply: true`, creates a local waiter, and blocks up to 10 minutes for a matching reply (`README.md:211`, `index.ts:439-475`, `index.ts:1470-1547`). Only one pending outbound ask per session is allowed (`index.ts:440-442`).
- `reply`: resolves the active triggered message or a single pending inbound ask, then sends with `replyTo` (`reply-tracker.ts:34-62`, `index.ts:1550-1608`).
- `pending`: lists unresolved inbound asks (`reply-tracker.ts:64-67`, `index.ts:1610-1632`).
- Incoming messages can trigger a new Pi turn when idle; busy interactive sessions queue delivery, busy non-interactive sessions try a best-effort “cannot respond while working” reply (`index.ts:577-595`, `index.ts:637-691`).

### Subagent integration

The current package has moved beyond just injecting the generic `intercom` tool. If pi-subagents supplies child bridge metadata via environment variables, pi-intercom registers a subagent-only `contact_supervisor` tool (`README.md:219-240`, `index.ts:20-24`, `index.ts:80-96`, `index.ts:1029-1041`). Required env vars are:

- `PI_SUBAGENT_ORCHESTRATOR_TARGET`
- `PI_SUBAGENT_RUN_ID`
- `PI_SUBAGENT_CHILD_AGENT`
- `PI_SUBAGENT_CHILD_INDEX`
- optional `PI_SUBAGENT_INTERCOM_SESSION_NAME`

`contact_supervisor` supports three reasons (`README.md:231-238`, `index.ts:1037-1040`):

- `need_decision`: blocking ask to supervisor.
- `interview_request`: blocking structured multi-question ask; validates question shape and can parse a JSON reply into `details.structuredReply` (`index.ts:103-236`, `index.ts:1183-1249`).
- `progress_update`: non-blocking update to supervisor (`index.ts:1131-1169`).

The tool explicitly says not to use it for routine completion handoffs; final subagent result should return normally (`README.md:240`, `index.ts:1040`).

### pi-subagents’ documented use of intercom

Pi Manager’s docs describe pi-intercom as optional: without it, subagents still run, chains and async runs still complete, but children cannot ask questions or send mid-run updates (`pi-subagents-intercom-deep-dive.md:18-29`). The bridge activation checks mode, fork context, parent target, extension existence, and config enabled state (`pi-subagents-intercom-deep-dive.md:68-92`).

The older pi-subagents bridge model injected the generic `intercom` tool and prompt instructions telling children to `ask` or `send` to the parent target (`pi-subagents-intercom-deep-dive.md:113-126`, `pi-subagents-architecture.md:64-77`). Current pi-intercom source adds the cleaner `contact_supervisor` tool when child metadata exists.

The docs also describe adjacent pi-subagents behaviors:

- **Control**: `needs_attention` / `active_long_running` monitoring is always active and can route through event, async file, and intercom channels (`pi-subagents-intercom-deep-dive.md:183-269`).
- **Result delivery**: foreground grouped results may be delivered through intercom and acknowledged within 500ms; otherwise normal full output is preserved (`pi-subagents-intercom-deep-dive.md:284-322`).
- **Detach**: pi-subagents can detach a child that started intercom coordination so the parent is no longer blocked while the child continues (`pi-subagents-intercom-deep-dive.md:135-177`).

## Pi Manager’s relevant existing direction

Pi Manager’s plan is a native SwiftUI agent workspace backed by Pi’s `--mode rpc` JSONL protocol, not an embedded terminal (`PI_AGENT_IN_APP_PLAN.md:9-18`, `PI_AGENT_IN_APP_PLAN.md:49-58`). Current implementation already has:

- `PiRPCClient` launching `pi --mode rpc` and writing JSONL commands (`PiRPCClient.swift:14-31`, `PiRPCClient.swift:91-99`).
- Runtime commands for prompt, steer/follow-up through `streamingBehavior`, abort, state, session stats, model/thinking changes, and extension UI responses (`PiRPCClient.swift:37-64`).
- `PiAgentRunnerService` mapping RPC events into native transcript/status, including `agent_start`, `turn_start`, tool events, queue updates, and `extension_ui_request` (`PiAgentRunnerService.swift:368-409`, `PiAgentRunnerService.swift:724-819`).
- A process-per-active-session direction with saved app session records and Pi session files (`PI_AGENT_IN_APP_PLAN.md:445-501`).
- A concurrency rule: avoid multiple uncontrolled writers in one cwd unless isolated by worktree or explicit user confirmation (`PI_AGENT_IN_APP_PLAN.md:463-476`, `PI_AGENT_IN_APP_PLAN.md:630-646`).

Current SwiftUI docs still describe intercom as the optional coordination layer and expose subagent config fields like `intercomBridge.mode` and control notify channels (`ContentView.swift:5557-5594`, `ContentView.swift:2056-2096`).

## What to keep for an app-integrated direct subagent RPC design

Keep the **semantics**, not the broker architecture.

1. **Keep `contact_supervisor` as the child-facing API.** It is much safer and clearer than giving children arbitrary `intercom({ to: ... })`. Preserve the three reasons:
   - `need_decision` = blocking parent decision.
   - `interview_request` = blocking structured answers.
   - `progress_update` = non-blocking update.

2. **Keep strict parent ownership.** Children should not orchestrate, discover peers, or send routine completion handoffs. The parent/app owns the run tree; children return final results normally.

3. **Keep request IDs and threading.** Every child question/update should have `requestId`, `runId`, `childId`, `childIndex`, `agent`, `parentSessionId`, `childSessionId`, timestamps, and status. This replaces intercom’s `message.id` / `replyTo` pairing.

4. **Keep blocking ask with timeout and single outstanding ask per child.** The 10-minute timeout can be configurable, but the key invariant is that a child blocked on a supervisor decision receives the answer as the tool result in the same turn.

5. **Keep structured interview validation.** The pi-intercom local shape is useful: `{ title?, description?, questions: [{ id, type, question, options?, context? }] }`, response `{ responses: [{ id, value }] }`. Preserve option validation for `single` / `multi`.

6. **Keep control signals, but derive them directly from app-owned RPC streams.** Pi Manager already sees tool start/end, message updates, turn boundaries, and process state. It can emit `needs_attention` / `active_long_running` cards without pi-intercom’s event relay.

7. **Keep native transcript rendering of coordination.** Inbound child requests should appear as first-class cards in the parent session UI, with explicit answer controls and links to the child transcript/artifacts.

8. **Keep same-machine/local security assumptions.** Direct app routing should remain local to app-managed sessions and never become network messaging.

9. **Keep attachments or context snippets if useful.** The intercom attachment model (`file`, `snippet`, `context`) is small and reusable, but should be scoped to parent/child sessions managed by the app.

## What to drop or not carry forward

1. **Drop the standalone broker/socket process for app-managed children.** Pi Manager already owns the parent and child `PiRPCClient` processes. A separate pi-intercom broker adds discovery, naming, lifecycle, and failure modes that are unnecessary inside one app runtime.

2. **Drop global session discovery/listing.** App-managed parent/child relationships should be explicit records, not inferred by session names or cwd. No child should need `intercom({ action: "list" })`.

3. **Drop arbitrary peer-to-peer messaging for subagents.** Direct subagent RPC should not let children target any local Pi session. Keep it to child ↔ assigned parent/supervisor and app-mediated parent → child nudges.

4. **Drop Alt+M overlays and TUI UI.** Pi Manager should render native SwiftUI cards and controls; pi-intercom’s overlay is only relevant in terminal Pi.

5. **Drop name-based routing and fallback aliases.** Use app UUIDs and run tree IDs. Session names can be display labels only.

6. **Drop pi-intercom result delivery/ack path.** Since Pi Manager owns the child process, final output, artifacts, and session file are already available. The app should insert a compact child-result card in the parent transcript and preserve the full child transcript separately.

7. **Drop intercom detach protocol.** Detach exists because pi-subagents’ parent process otherwise blocks on a child it launched. In Pi Manager, every child is an app-managed process/session; “detached” is just a lifecycle state where the parent UI/agent can continue while the child remains running.

8. **Drop extension-directory detection as the gate for direct mode.** Direct mode should be gated by Pi Manager’s own capability: can it launch/manage a child RPC process and inject/provide the child supervisor tool?

9. **Do not expose the generic `intercom` tool to app-managed children by default.** If users also install pi-intercom for terminal peer sessions, keep that optional and separate from Pi Manager’s managed subagent channel.

## Recommended parent-child communication design

### Roles

- **App/router**: owns the run graph, process map, request registry, UI cards, persistence, timeouts, and repo safety policies.
- **Parent session**: the supervisor/orchestrator agent or human-visible thread. It decides what children should do and answers child escalations.
- **Child session**: a separate `pi --mode rpc` process/session launched with a concrete task and supervisor metadata.

### Launch model

For each child run, create an app record like:

```json
{
  "runId": "uuid-or-short-id",
  "parentSessionId": "app-parent-session-uuid",
  "childSessionId": "app-child-session-uuid",
  "agent": "worker",
  "childIndex": 0,
  "projectPath": "/repo-or-worktree",
  "status": "starting|running|idle|needs_attention|blocked|completed|failed|stopped",
  "createdAt": "...",
  "piSessionFile": "..."
}
```

Launch the child with a concrete prompt that includes:

- inherited/reference context policy,
- the task,
- the supervisor channel contract,
- “use `contact_supervisor` only for decisions/interviews/meaningful updates,”
- “do not send routine completion handoffs; return final result normally,”
- “do not launch subagents; parent owns orchestration.”

### Child → parent

Use one child-facing tool, ideally named `contact_supervisor`, with the same parameters as pi-intercom. Internally it should create an app-routed request:

```json
{
  "requestId": "uuid",
  "runId": "...",
  "parentSessionId": "...",
  "childSessionId": "...",
  "reason": "need_decision|interview_request|progress_update",
  "message": "...",
  "interview": { "questions": [] },
  "expectsReply": true,
  "createdAt": "..."
}
```

Behavior:

- `progress_update`: app appends a parent transcript card and returns immediately to child.
- `need_decision`: child tool blocks; app creates a parent “Decision needed” card and waits for an answer.
- `interview_request`: same, but parent answer UI should enforce or encourage the `{ responses: [...] }` JSON shape.

Implementation note: Pi Manager already supports `extension_ui_request` and `extension_ui_response` over RPC (`PiRPCClient.swift:62-64`, `PiAgentRunnerService.swift:724-819`). A minimal child-side extension could implement `contact_supervisor` by issuing a custom extension UI/input request and awaiting the app response. If Pi’s extension UI is too human-input-oriented for this, add a tiny app-specific local IPC between the child tool and Pi Manager; still avoid the global pi-intercom broker.

### Parent answering

The parent answer can come from either:

1. **Human/UI answer**: user types/selects the answer in the parent decision card; app sends it back to the blocked child tool.
2. **Parent-agent answer**: app injects the child request into the parent session as a structured follow-up/steer message, or provides a parent-side tool/action to answer a pending child request. The app should not infer an answer from arbitrary assistant prose unless there is a clear “reply to request” tool/action.

Parent replies should be recorded as:

```json
{
  "requestId": "...",
  "answeredBy": "human|parent-agent",
  "message": "...",
  "structuredReply": { "responses": [] },
  "answeredAt": "..."
}
```

Then the child tool returns a text result equivalent to pi-intercom’s “Reply from supervisor” plus `details.structuredReply` when applicable.

### Parent → child nudges/control

Parent-to-child should be app-mediated, not arbitrary intercom:

- If child is running: send `prompt(..., streamingBehavior: "steer")` through the child `PiRPCClient` (Pi Manager already does this for active sessions: `PiAgentRunnerService.swift:73-77`).
- If child is idle: send a normal prompt/follow-up to the child session.
- For stop/interruption: use RPC `abort` and then terminate if needed (`PiRPCClient.swift:43`, `PiRPCClient.swift:104-110`).
- For needs-attention: app creates a parent card with “Nudge”, “Open child transcript”, “Stop”, and “Let continue” actions.

### Results

Final child result should flow through the app-owned process, not through child `contact_supervisor`:

1. Child reaches `turn_end` / idle or process exit.
2. App captures final assistant text, tool summaries, session file, artifacts/diffs.
3. App appends a compact child result card to the parent transcript with links to full child transcript/session/artifacts.
4. Parent can decide follow-up, retry, review, or merge.

This preserves the important pi-subagents rule: children do not send routine completion handoffs via the coordination channel.

### Async/detached behavior

Because the app owns all child processes, “detach” becomes a UI/process state:

- Parent does not have to block while a child is running.
- Child can continue after parent turn ends.
- The app keeps badges and notifications for running/blocked children.
- On app quit, either stop children gracefully or, in a future background mode, persist enough state to reattach.

## Key risks / open decisions

1. **Child-side tool delivery mechanism.** Need a concrete implementation path for `contact_supervisor` in direct mode. Best first path is a small Pi extension using RPC-visible extension UI requests; fallback is a tiny app-specific local IPC. Do not depend on the global pi-intercom broker for managed children.

2. **Parent-agent autonomous replies.** If a parent LLM is expected to answer child asks without human input, Pi Manager needs an explicit parent-side reply mechanism. Otherwise answers should be human/UI driven.

3. **Busy parent or child.** Preserve pi-intercom’s idle-gating principle: do not interrupt an active parent turn unpredictably. Queue child requests as parent transcript cards and use timeout/escalation.

4. **Concurrent writes.** Direct child RPC makes it easier to run many children. Keep the existing policy: one active writer per working tree unless isolated by worktree or explicit user confirmation.

5. **Compatibility with installed pi-subagents.** If a user invokes the existing `pi-subagents` tool inside a Pi Manager parent session, that package may spawn children outside Pi Manager’s direct process map. Direct app-managed subagents should be a separate code path, or Pi Manager must explicitly detect/label package-managed runs as external.

## Bottom line

Use `pi-intercom` as the reference for communication semantics, not as the runtime substrate. For Pi Manager’s app-integrated direct subagent RPC, the app should be the broker/router because it already owns the parent and child RPC processes, transcripts, UI, safety policy, and session persistence. Preserve `contact_supervisor`, blocking decisions, structured interviews, progress updates, request threading, and parent-owned orchestration; drop global session discovery, arbitrary peer messaging, the standalone broker, TUI overlays, name-based routing, intercom result delivery, and detach protocol.
