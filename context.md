---
head: 7055c7cada4ad1e24682180773449ca83ab16419
dirty: false
generatedAt: 2026-05-01T21:43:47Z
taskScope: Pi CLI busy-submit behavior and pi-manager transcript/tool rendering noise
changeSummarySincePrevious: previous cache unrelated/stale; refreshed targeted context
reusedCache: false
---

# Code Context

## Scope
Answer whether Pi CLI sends steering or follow-up when user presses Enter while the LLM is replying, and identify minimal pi-manager changes to reduce noisy transcript entries.

## Files Retrieved
1. `/opt/homebrew/lib/node_modules/@mariozechner/pi-coding-agent/dist/modes/interactive/interactive-mode.js` (lines 2078-2111, 2690-2721, 2914-2926) - CLI Enter vs Alt+Enter behavior and queued-message display.
2. `/opt/homebrew/lib/node_modules/@mariozechner/pi-coding-agent/dist/core/agent-session.js` (lines 720-745, 905-934) - `prompt(...streamingBehavior)` dispatches to steer/follow-up queues.
3. `pi-manager/PiAgentRunnerService.swift` (lines 60-70, 176-182, 380-515) - current app sends follow-up by default while active and renders tool events.
4. `pi-manager/PiRPCClient.swift` (lines 50-60) - RPC prompt includes optional `streamingBehavior`.
5. `pi-manager/PiAgentViews.swift` (lines 250-305, 326-334, 898-908, 1982-2040) - current composer mode UI and transcript visibility/rendering.

## Key Code
Pi CLI normal Enter while streaming is steering:
```js
// interactive-mode.js 2092-2098
if (this.session.isStreaming) {
  this.editor.addToHistory?.(text);
  this.editor.setText("");
  await this.session.prompt(text, { streamingBehavior: "steer" });
  this.updatePendingMessagesDisplay();
  this.ui.requestRender();
  return;
}
```

Pi CLI follow-up is explicit Alt+Enter only:
```js
// interactive-mode.js 2706-2712
if (this.session.isStreaming) {
  this.editor.addToHistory?.(text);
  this.editor.setText("");
  await this.session.prompt(text, { streamingBehavior: "followUp" });
  this.updatePendingMessagesDisplay();
  this.ui.requestRender();
}
```

Core RPC/session behavior requires an explicit streaming behavior while active:
```js
// agent-session.js 726-737
if (this.isStreaming) {
  if (!options?.streamingBehavior) throw new Error(...);
  if (options.streamingBehavior === "followUp") await this._queueFollowUp(...);
  else await this._queueSteer(...);
  return;
}
```

Current pi-manager diverges: `PiAgentRunnerService.send` converts `.prompt` during active streaming to `.followUp` and sends `streamingBehavior: "followUp"` (`PiAgentRunnerService.swift` lines 60-70). UI also defaults `inputMode` to `.followUp` and shows follow-up placeholder/toggle (`PiAgentViews.swift` lines 9, 254, 305, 898-908).

Noisy tool source:
```swift
// PiAgentRunnerService.swift 395-396
case "toolcall_start":
    store.append(.init(... role: .tool, title: "Tool Call", text: "Preparing tool call…" ...))
```
This creates low-value “Preparing tool call…” cards. `handleToolExecution` then upserts richer `Tool: <toolName>` entries for `tool_execution_start/update/end` (lines 425-444). `transcriptEntry(from:)` also falls back to rendering any `type.contains("tool")` event as a tool card (lines 507-508), which can duplicate/proliferate raw tool protocol noise.

Current visible transcript filter only hides `.raw` and non Compaction/Retry statuses; it shows all `.tool` entries (`PiAgentViews.swift` lines 326-334).

## Architecture
- CLI Enter -> `InteractiveMode` -> `session.prompt(..., streamingBehavior: "steer")` when `session.isStreaming`.
- CLI Alt+Enter -> `handleFollowUp()` -> `streamingBehavior: "followUp"`.
- `AgentSession.prompt()` maps `streamingBehavior` to `_queueSteer`/`_queueFollowUp`, emits `queue_update`, and later the agent emits user-message events when delivered.
- pi-manager sends RPC JSON via `PiRPCClient.prompt(message, streamingBehavior:)`.
- pi-manager currently appends a local user transcript entry immediately in `PiAgentRunnerService.send`, with titles “Queued steering” or “Queued follow-up”. Pi echoes delivered user messages later, but app ignores echoed role `user`.

## Start Here
Start with `PiAgentRunnerService.swift` lines 60-70. Change active `.prompt` behavior from follow-up to steering, then remove follow-up toggle UI in `PiAgentViews.swift`.

## Constraints And Risks
- To match CLI: busy Return should send `streamingBehavior: "steer"`; explicit follow-up UI should be removed/hidden unless reintroduced as an Alt+Enter advanced shortcut.
- Since send button becomes Stop while running, active-turn message submission must rely on Return. The AppKit text editor already calls `onSend` for Return; ensure placeholder says “Steer the current turn…” while active.
- Local transcript should title active submits as “Queued steering” (or simply “Steering”) and not “Queued follow-up”. Queue counts/footer should stop emphasizing follow-up if UI no longer exposes it.
- Minimal tool-noise filter: do not append `toolcall_start` “Preparing tool call…”. Let `tool_execution_*` produce/update the meaningful tool card.
- Also consider returning `nil` for fallback `type.contains("tool")` in `transcriptEntry(from:)` unless it is an error or has a meaningful result; otherwise protocol events can leak as cards.
- Keep subagent handling: `PiAgentSubagentSummary(entry:)` detects tool entries whose title/text contains “subagent” and renders a summarized view. Preserve tool entries for actual subagent results; filter only preparation/start/protocol noise.
- Local stored Pi Manager session list has only one recent session (`claude-code-meter`), not `claude-code-manager`, so no useful historical transcript was available locally to inspect.

## Pi-intercom handoff
No safe orchestrator target was provided.