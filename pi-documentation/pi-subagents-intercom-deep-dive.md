# `pi-subagents` Intercom: Deep Dive

The intercom system is the **coordination layer** that lets child subagents communicate back to their parent orchestrator session. It is optional — pi-subagents works perfectly without pi-intercom installed — but when enabled, it unlocks real-time bidirectional coordination.

---

## Plain English: What Does Intercom Do?

Without intercom, communication is strictly **one-way**: the parent fires a task at the child, then blocks waiting for the child to finish and return output. That's it.

With intercom, a child can:
- **Ask the parent a question** mid-task (e.g., "should I optimize for speed or correctness?") and wait for an answer
- **Send a status update** (e.g., "I'm 80% through the test suite")
- **Stay alive** in a detached mode for long-running back-and-forth coordination (like an oracle advisor)

It also lets the parent **nudge or check on** a running child through the same channel, instead of just blindly waiting.

### What happens if pi-intercom is NOT installed?

**Nothing breaks.** Everything works exactly the same — subagents run, return results, chains execute, parallel works, control events still fire, async runs still complete.

The only things you lose:
- Children **can't ask questions back** — they have to make decisions on their own or guess
- Children **can't send mid-run updates** — the parent sees nothing until the child finishes
- The **detach flow doesn't work** — a child that wants to do extended coordination has to finish and exit before the parent can continue
- Control events (`needs_attention`, `active_long_running`) still fire, but they **only appear as in-conversation notifications** — they can't route through the intercom channel to the orchestrator

In practice: if you're just running `scout` → `planner` → `worker` → `reviewer` workflows where each agent does its job and returns, you'll never notice intercom is missing. It only matters for **interactive coordination patterns** like the oracle loop where the child needs a live conversation with the parent.

### How to activate it

Install `pi-intercom` as a pi extension (it needs to land in `~/.pi/agent/extensions/pi-intercom/`):

```bash
pi extension install pi-intercom
```

**No config needed on the pi-subagents side.** The detection chain in `resolveIntercomBridge()` automatically checks:

| # | Check | Default result |
|---|-------|----------------|
| 1 | Is mode off? | No — defaults to `"always"` ✅ |
| 2 | Is mode fork-only but context is fresh? | No — mode is `"always"` ✅ |
| 3 | Does orchestrator target exist? | Yes — auto-generated from session name/ID ✅ |
| 4 | Does `pi-intercom` extension directory exist? | **That's the one you control** ✅ |
| 5 | Is intercom config disabled? | No config file means enabled ✅ |

Once that directory exists, pi-subagents will inject the `intercom` tool and bridge instructions into every child agent automatically.

---

## Overview: The Three Intercom Functions

| Function | What it does |
|----------|-------------|
| **Bridge** (`intercom-bridge.ts`) | Detects if intercom is available, resolves the orchestrator target, and injects coordination instructions into child agent system prompts |
| **Control** (`subagent-control.ts`) | Monitors child activity (or lack thereof) and emits `needs_attention` / `active_long_running` events that the parent can act on |
| **Result delivery** (`result-intercom.ts`) | When a foreground run completes, delivers a grouped summary to the orchestrator via intercom instead of (or in addition to) the normal tool-return output |

---

## 1. The Intercom Bridge

### When does the bridge activate?

The bridge is resolved once per `subagent(...)` call, inside `createSubagentExecutor().execute()`:

```
resolveIntercomBridge({
  config: extensionConfig.intercomBridge,
  context: "fresh" | "fork" | undefined,
  orchestratorTarget: sessionName,
})
```

The resolution logic in `intercom-bridge.ts` checks **five conditions** in order. All must pass for the bridge to become `active: true`:

| # | Check | Failure reason |
|---|-------|----------------|
| 1 | `mode !== "off"` | "bridge mode is off" |
| 2 | If `mode === "fork-only"`, context must be `"fork"` | "bridge mode is fork-only and context is not fork" |
| 3 | `orchestratorTarget` is a non-empty string | "orchestrator target is not available" |
| 4 | `pi-intercom` extension directory exists on disk | "pi-intercom extension was not found" |
| 5 | Intercom config file is not explicitly disabled | "intercom config is disabled" |

### The orchestrator target

The orchestrator target is the intercom channel name that identifies the parent session. It's derived from:

```typescript
resolveIntercomSessionTarget(sessionName, sessionId)
```

- If the session has a human-readable name (set via `/name`), that becomes the target.
- Otherwise, it falls back to `subagent-chat-<first-8-chars-of-session-id>`.

### Child target naming

Each child subagent gets a deterministic intercom target:

```typescript
resolveSubagentIntercomTarget(runId, agentName, index)
// → "subagent-<agent>-<runid-prefix>-<step-number>"
```

This target is passed to the child as its `intercomSessionName` so it knows which channel to listen on.

### What gets injected into child agents

When the bridge is active, `applyIntercomBridgeToAgent()` modifies **two things** on every discovered agent:

1. **Tools**: adds `"intercom"` to the agent's tool list (if not already present)
2. **System prompt**: appends bridge instructions after the marker line `"Intercom orchestration channel:"`

The default instruction template tells the child:

```
The inherited thread is reference-only. Do not continue that conversation.

Use intercom only for coordination with the orchestrator session "<orchestratorTarget>".
- Need a decision or blocked: intercom({ action: "ask", to: "<orchestratorTarget>", message: "..." })
- Non-blocking progress update: intercom({ action: "send", to: "<orchestratorTarget>", message: "UPDATE: ..." })

Do not send routine completion handoffs through intercom. If no coordination is needed, return a focused task result.
```

You can override this template by setting `intercomBridge.instructionFile` in the extension config.

### Extension sandbox check

Even when the bridge is active, it won't inject into agents whose `extensions` list is explicitly set but doesn't include `pi-intercom`. The function `extensionSandboxAllowsIntercom()` checks that the intercom extension is in the agent's allowed extensions list.

---

## 2. The Detach Flow

One of the most important intercom features is the **detach** mechanism. When a child agent is doing long-running coordination via intercom (e.g., an oracle asking questions back and forth), the parent shouldn't block waiting for the child process to exit.

### How detach works

```
  Parent Process                        Child Process
  ─────────────                         ─────────────
  subagent({ agent: "oracle" })
      │
      ├── spawn pi child ──────────────► starts running
      │                                  ...
      │   listens for events             child calls intercom("ask", ...)
      │                                  child keeps running, waiting for reply
      │
      │   <── INTERCOM_DETACH_REQUEST ─── child requests detach via event
      │   ──► INTERCOM_DETACH_RESPONSE ── parent accepts
      │
      ├── detachForIntercom()
      │   result.detached = true
      │   result.detachedReason = "intercom coordination"
      │   resolve with exit code -2
      │
      │   (parent is now free to continue
      │    its own conversation while
      │    the child lives on)
```

In `execution.ts`, the detach is triggered when:

1. The child process is running with `allowIntercomDetach: true` (set when the agent's system prompt contains the bridge marker)
2. The child has started using intercom (`intercomStarted === true`, detected when `toolName === "intercom"` is seen in stdout events)
3. A `pi-intercom:detach-request` event is emitted on the event bus with a valid `requestId`
4. The parent responds with `pi-intercom:detach-response: { requestId, accepted: true }`
5. The parent calls `detachForIntercom()` which:
   - Sets `result.detached = true`
   - Sets `progress.status = "detached"`
   - Resolves the promise with a special exit code

The parent then returns to the caller with a `"Detached for intercom coordination"` message. The child process continues running independently.

Detach also happens automatically if the parent's abort signal fires while the child has an active intercom session — instead of killing the child, it detaches.

---

## 3. Control Events and Activity Monitoring

The control layer (`subagent-control.ts`) is **always active** regardless of intercom. It tracks child activity and emits events when the child seems stuck or is running for a long time.

### Activity state machine

```
                 ┌──────────────┐
                 │  undefined   │  (normal running)
                 │  (active)    │
                 └──────┬───────┘
                        │
           ┌────────────┼────────────────┐
           │            │                │
    idle > 60s    elapsed > 300s    tool failures ≥ 3
    no activity   OR turns ≥ 15     consecutive mutating
                  OR tokens ≥ 150k   tool failures
           │            │                │
           ▼            ▼                ▼
  ┌─────────────┐  ┌──────────────────────┐
  │ needs_      │  │ active_long_running  │
  │ attention   │  │                      │
  └─────────────┘  └──────────────────────┘
```

### Default thresholds (all configurable)

| Threshold | Default | Meaning |
|-----------|---------|---------|
| `needsAttentionAfterMs` | 60,000 (60s) | No tool calls, messages, or output for this long → `needs_attention` |
| `activeNoticeAfterMs` | 300,000 (5m) | Total elapsed time exceeds this → `active_long_running` |
| `activeNoticeAfterTurns` | 15 | Assistant turns exceed this → `active_long_running` |
| `activeNoticeAfterTokens` | 150,000 | Total tokens exceed this → `active_long_running` |
| `failedToolAttemptsBeforeAttention` | 3 | Consecutive failing edit/write/bash-mutate calls → `needs_attention` |

### Per-run overrides

```typescript
subagent({
  agent: "worker",
  task: "Run the slow migration test suite",
  control: {
    needsAttentionAfterMs: 300000,  // 5 minutes for slow tests
    notifyOn: ["needs_attention"],   // skip active_long_running
  }
})
```

### How activity is tracked

In `execution.ts`, the spawned child process streams JSON lines on stdout. Each parsed event updates `progress.lastActivityAt`:

| Event | What it tracks |
|-------|---------------|
| `tool_execution_start` | Tool name, args, current file path, timestamp |
| `tool_execution_end` | Clears current tool |
| `message_end` (assistant) | Turns, token usage, model, stop reason |
| `tool_result_end` | Tool output, failure detection |

A 1-second interval timer checks if `now - lastActivityAt > needsAttentionAfterMs` and emits state transitions.

### Mutating tool failure escalation

The `long-running-guard.ts` module specifically tracks **mutating tools** (edit, write, bash with file writes). When a mutating tool fails:

1. `recordMutatingFailure()` logs the tool, path, error, and timestamp
2. Consecutive failures within a 5-minute window are counted
3. When `consecutiveFailures >= threshold` (default 3) → emits `needs_attention` with `reason: "tool_failures"` and a `recentFailureSummary`
4. A successful mutating tool call resets the counter

### Notification channels

Control events are delivered through **three channels**:

| Channel | How | When used |
|---------|-----|-----------|
| **Event bus** | `pi.events.emit(SUBAGENT_CONTROL_EVENT, payload)` | Foreground runs — the event is picked up by the index.ts handler which sends a visible message to the conversation |
| **JSONL file** | Written to `events.jsonl` in the async run directory | Async runs — the parent tracker reads this file |
| **Intercom** | `pi.events.emit(SUBAGENT_CONTROL_INTERCOM_EVENT, { to, message, ... })` | When bridge is active — sends a structured intercom message to the orchestrator |

The notification includes concrete action hints:

```
Subagent needs attention: worker
Run: abc12345
Signal: worker needs attention (no observed activity for 75s)
Nudge: intercom({ action: "send", to: "subagent-worker-abc12345-1", message: "..." })
Status: subagent({ action: "status", id: "abc12345" })
Interrupt: subagent({ action: "interrupt", id: "abc12345" })
```

### Deduplication

Each control event type fires at most **once per child run**. The key is:

```
<childIntercomTarget>:<eventType>:<reason>
```

Once seen, subsequent events with the same key are suppressed. This prevents spamming the orchestrator.

---

## 4. Result Delivery via Intercom

When a foreground subagent run completes, `subagent-executor.ts` attempts to deliver the results through intercom before falling back to normal tool-return output.

### The flow

```
1. Run completes → collect all SingleResult[]

2. maybeBuildForegroundIntercomReceipt()
   ├── Is bridge active?  ─── No ──→ skip, return normal output
   ├── Is orchestratorTarget set?  ── No ──→ skip
   └── Yes → buildSubagentResultIntercomPayload()
       ├── For each child result:
       │   ├── agent name
       │   ├── status (completed | failed | paused | detached)
       │   ├── summary (truncated output)
       │   ├── artifactPath
       │   ├── sessionPath
       │   └── intercomTarget (for follow-up)
       ├── Grouped status (failed if any failed, etc.)
       └── Formatted message with all child summaries

3. deliverSubagentResultIntercomEvent()
   ├── Emit SUBAGENT_RESULT_INTERCOM_EVENT with payload + requestId
   ├── Wait up to 500ms for SUBAGENT_RESULT_INTERCOM_DELIVERY_EVENT acknowledgment
   └── Return true if delivered, false if timed out

4. If delivered → return compact receipt:
   "Delivered single subagent result via intercom.
    Run: abc12345
    Children: 1 completed
    Artifacts: ..."
   (Full output was sent over intercom, not duplicated in tool result)

5. If NOT delivered → return full normal output
```

### Why this matters

Without intercom delivery, a parent orchestrator that's running as a forked oracle in another session would receive the child's output as a huge tool-return string. With intercom delivery, the output is sent as a structured intercom message that the orchestrator can process incrementally, and the tool return is just a compact receipt.

---

## 5. The Full Intercom Lifecycle

Here's the complete sequence for a forked oracle subagent with intercom:

```
PARENT SESSION (orchestrator)          CHILD PROCESS (oracle)
─────────────────────────              ────────────────────────

1. resolveIntercomBridge()
   → active: true
   → orchestratorTarget: "my-session"
   → instruction: "..."

2. applyIntercomBridgeToAgent(oracle, bridge)
   → adds "intercom" to tools
   → appends bridge instructions to systemPrompt

3. Spawn child with:
   - systemPrompt includes bridge instructions
   - intercomSessionName = "subagent-oracle-abc12345-0"
   - allowIntercomDetach = true

4. [parent waits, streaming events]
                                       5. Oracle starts, calls:
                                          intercom({ action: "ask",
                                            to: "my-session",
                                            message: "Should I optimize
                                              for speed or correctness?"
                                          })

6. [parent receives intercom ask]
   Parent replies:
   intercom({ action: "reply",
     message: "Optimize for correctness."
   })

                                       7. Oracle receives reply,
                                          continues working...

8. [no activity for 60s]
   → emits needs_attention event
   → visible notification in parent:
     "Subagent needs attention: oracle"

9. Parent nudges:
   intercom({ action: "send",
     to: "subagent-oracle-abc12345-0",
     message: "What are you blocked on?"
   })

                                       10. Oracle responds via intercom,
                                           then finishes its analysis.

11. Child process exits.
    deliverSubagentResultIntercomEvent()
    → sends grouped summary to orchestrator
    → returns compact receipt
```

---

## 6. Async Runs and Intercom

For async (background) runs, the intercom flow works differently:

1. **Bridge resolution** happens at spawn time (same as foreground)
2. **Control events** are written to `events.jsonl` in the async run directory, not emitted on the event bus
3. **Control intercom messages** are included in the JSONL entries for the async tracker to process
4. **Result delivery** happens when the async run completes — the result watcher picks up the completion and delivers it via the `SUBAGENT_ASYNC_COMPLETE_EVENT`
5. **Notifications** use `pi.sendMessage()` with a custom `"subagent-notify"` message type (separate from intercom)

The `controlIntercomTarget` and `childIntercomTarget` parameters are serialized into the async runner config so the detached runner process can emit intercom events even though it's no longer connected to the parent process's event bus.

---

## 7. Configuration Reference

### Extension config (`~/.pi/agent/extensions/subagent/config.json`)

```json
{
  "intercomBridge": {
    "mode": "always",           // "always" | "fork-only" | "off"
    "instructionFile": ""        // path to custom bridge instruction template
  },
  "control": {
    "enabled": true,
    "needsAttentionAfterMs": 60000,
    "activeNoticeAfterMs": 300000,
    "activeNoticeAfterTurns": 15,
    "activeNoticeAfterTokens": 150000,
    "failedToolAttemptsBeforeAttention": 3,
    "notifyOn": ["active_long_running", "needs_attention"],
    "notifyChannels": ["event", "async", "intercom"]
  }
}
```

### Per-run overrides

```typescript
subagent({
  agent: "worker",
  task: "...",
  control: {
    needsAttentionAfterMs: 300000,
    notifyOn: ["needs_attention"],
  }
})
```

### Intercom config (`~/.pi/agent/intercom/config.json`)

```json
{
  "enabled": true  // set to false to disable intercom globally
}
```

---

## 8. Key Event Types

| Event constant | When emitted | Payload |
|----------------|-------------|---------|
| `SUBAGENT_CONTROL_EVENT` | Any control event on a foreground run | `{ event, source, childIntercomTarget, noticeText }` |
| `SUBAGENT_CONTROL_INTERCOM_EVENT` | Control event that should also go through intercom | `{ ...controlPayload, to, message }` |
| `SUBAGENT_RESULT_INTERCOM_EVENT` | Foreground run result ready for intercom delivery | Full `SubagentResultIntercomPayload` |
| `SUBAGENT_RESULT_INTERCOM_DELIVERY_EVENT` | Acknowledgment that intercom received the result | `{ requestId, delivered }` |
| `SUBAGENT_ASYNC_STARTED_EVENT` | Async run spawned | `{ id, pid, agent, asyncDir, ... }` |
| `SUBAGENT_ASYNC_COMPLETE_EVENT` | Async run finished | `{ id, agent, success, summary, ... }` |
| `pi-intercom:detach-request` | Child wants to detach for long-running intercom coordination | `{ requestId }` |
| `pi-intercom:detach-response` | Parent accepts detach | `{ requestId, accepted }` |

---

## 9. Source File Map

| File | Intercom responsibility |
|------|------------------------|
| `intercom-bridge.ts` | Bridge resolution, agent injection, target naming, diagnostics |
| `subagent-control.ts` | Activity state machine, control event building, notification formatting, deduplication |
| `result-intercom.ts` | Result payload building, delivery with acknowledgment, receipt formatting |
| `long-running-guard.ts` | Mutating tool failure tracking, escalation logic |
| `execution.ts` | Detach flow (INTERCOM_DETACH_REQUEST/RESPONSE), activity tracking via stdout events, interrupt handling |
| `subagent-executor.ts` | Bridge resolution at dispatch time, `emitForegroundResultIntercomEvent`, control event forwarding |
| `async-execution.ts` | Serializes `controlIntercomTarget` and `childIntercomTarget` into async runner config |
| `subagent-runner.ts` | Writes control events to `events.jsonl` for async runs, processes intercom pings |
| `notify.ts` | Separate notification channel for async completions (not intercom, but related) |
