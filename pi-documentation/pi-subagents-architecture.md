# `pi-subagents` Package: Architecture Deep-Dive

Here's how the package handles **context**, **communication**, **handling**, and **triggering** of subagents.

---

## 1. TRIGGERING — How Subagents Are Launched

There are **four entry points** that can trigger a subagent:

| Entry | How |
|-------|-----|
| **Tool call** | The LLM calls `subagent({ agent, task, ... })` as a tool. The tool definition is registered in `index.ts` → `pi.registerTool(tool)`. |
| **Slash commands** | Humans type `/run`, `/chain`, `/parallel`, `/agents`, `/subagents-status`, `/run-chain`, etc. These are wired through `slash-commands.ts` and routed via `slash-bridge.ts` to the same executor. |
| **Prompt templates** | Packaged workflows like `/parallel-review`, `/parallel-research`, etc. bridge through `prompt-template-bridge.ts` into the executor. |
| **Extension events** | `pi.events` emit/subscribe pattern. E.g. `SUBAGENT_ASYNC_STARTED_EVENT` triggers the job tracker. |

**The central execution orchestrator is `subagent-executor.ts`** — it receives all requests and dispatches based on mode:

```
params.agent?      → SINGLE mode (one agent, one task)
params.tasks?      → PARALLEL mode (concurrent agents)
params.chain?      → CHAIN mode (sequential pipeline with {previous} templating)
```

**Execution modes:**

- **Foreground (sync)**: `execution.ts` → `runSync()` spawns a child `pi` process via `child_process.spawn()` in `--mode json` mode. It parses JSON-lines events from stdout (`tool_execution_start`, `message_end`, `tool_result_end`) to track progress in real-time.
- **Background (async)**: `subagent-runner.ts` → `runSubagent()` does the same spawn but in a detached async runner process. Status is written to `status.json`, events to `events.jsonl`. The parent tracks async jobs via `async-job-tracker.ts` and receives completions through file watcher (`result-watcher.ts`).

---

## 2. CONTEXT — Fresh vs Fork

The `context` parameter controls what conversation history the child agent inherits.

### Fresh context (`context: "fresh"`, the default)

- The child starts with a **blank slate** — no parent conversation history.
- Gets its own system prompt, skills, and task only.
- Used for adversarial reviews, research, etc.

### Forked context (`context: "fork"`)

- **Requires a persisted parent session file**. The `fork-context.ts` module uses `sessionManager.createBranchedSession(leafId)` to create a branched copy of the parent session.
- The child inherits **the full parent conversation history** as read-only reference.
- The task is wrapped with a preamble (from `DEFAULT_FORK_PREAMBLE` in `types.ts`):

  > *"You are a delegated subagent running from a fork of the parent session. Treat the inherited conversation as reference-only context..."*

- Used for `oracle` (decision review), `worker` (implementation), `planner`.

**Auto-detection** in `subagent-executor.ts` via `applyAgentDefaultContext()`: if any requested agent has `defaultContext: "fork"` in its config, the entire invocation is upgraded to fork mode.

**Recursion guard**: `checkSubagentDepth()` enforces a max nesting depth (default: 2). Each child gets `PI_SUBAGENT_DEPTH` incremented in its environment. The `index.ts` `registerSubagentExtension` exits early if the process is itself a child (`SUBAGENT_CHILD_ENV === "1"`).

---

## 3. COMMUNICATION — Between Parent and Children

There are **three communication layers**:

### 3a. Intercom Bridge (`intercom-bridge.ts`)

When `pi-intercom` is installed, the bridge gives children a private coordination channel:

1. **Bridge resolution** (`resolveIntercomBridge()`): checks mode (`always` | `fork-only` | `off`), orchestrator target availability, pi-intercom extension presence, and config enabled status.
2. **Agent injection** (`applyIntercomBridgeToAgent()`): appends bridge instructions to the agent's system prompt and adds `"intercom"` to its tool list.
3. **Target naming**: `resolveSubagentIntercomTarget()` creates targets like `subagent-<agent>-<runId>-<step>`. The orchestrator target is resolved from the session name/ID.

Children use:

```
intercom({ action: "ask", to: "<target>", message: "..." })    // blocking question
intercom({ action: "send", to: "<target>", message: "..." })   // non-blocking update
```

### 3b. Subagent Control (`subagent-control.ts`)

This is the **runtime visibility and intervention layer**:

- **Activity tracking**: Every 1 second, an interval checks if activity (tool calls, messages) has been observed. States: `undefined` → `active_long_running` → `needs_attention`.
- **Thresholds** (configurable):
  - `needsAttentionAfterMs`: 60s idle → `needs_attention` event
  - `activeNoticeAfterMs`: 300s elapsed → `active_long_running` event
  - `failedToolAttemptsBeforeAttention`: 3 consecutive mutating tool failures
- **Notification channels**: events, async persistence, intercom messages.
- **Soft interrupt**: `subagent({ action: "interrupt" })` sends SIGINT → SIGTERM to the child process, leaving the run paused (not failed).

### 3c. Result Delivery (`result-intercom.ts`)

When a foreground run completes:

1. `emitForegroundResultIntercom()` builds a grouped payload with all child summaries
2. Delivers via `pi.events.emit(SUBAGENT_RESULT_INTERCOM_EVENT, ...)`
3. If acknowledged, returns a compact receipt; otherwise preserves full output

---

## 4. HANDLING — How Each Step Is Executed

The core execution path in `execution.ts` → `runSync()`:

```
1. Resolve agent config (frontmatter + overrides)
2. Resolve skills → inject into system prompt
3. Build model candidates (primary + fallbacks)
4. For each candidate model:
   a. Build CLI args via buildPiArgs():
      - "--mode json -p" for streaming JSON
      - Session file/dir for context
      - Model, thinking, tools, extensions flags
      - System prompt (temp file or inline)
   b. Spawn child process
   c. Stream stdout → parse JSON lines:
      - tool_execution_start → track current tool
      - message_end → accumulate messages, usage
      - tool_result_end → detect failures
   d. Track activity for control events
   e. On exit: extract final output, evaluate completion guard
   f. If model fails with retryable error → try next candidate
5. Save artifacts (input, output, metadata, JSONL)
6. Return SingleResult with full details
```

### Chain execution (`chain-execution.ts`)

- Sequential steps: each step's output becomes `{previous}` for the next
- Parallel steps within chains: `mapConcurrent()` with configurable concurrency
- Chain directory: shared temp dir for inter-step file passing (`chain_dir`)
- Template variables: `{task}`, `{previous}`, `{chain_dir}`

### Parallel execution (`subagent-executor.ts` → `runForegroundParallelTasks()`)

- `mapConcurrent()` from `parallel-utils.ts` — a worker-pool pattern with bounded concurrency
- Optional **worktree isolation** (`worktree.ts`): each task gets its own git worktree to prevent filesystem conflicts

---

## Summary Architecture Diagram

```
┌──────────────────────────────────────────────────────┐
│                   PARENT SESSION                      │
│                                                       │
│  pi.registerTool("subagent") ◄── LLM tool calls      │
│  Slash commands ◄── Human input                       │
│  Prompt templates ◄── Workflow shortcuts              │
│           │                                           │
│           ▼                                           │
│  subagent-executor.ts (central dispatcher)            │
│    ├── validate → resolve agents, context, models     │
│    ├── fork-context.ts → branch session for "fork"    │
│    ├── intercom-bridge.ts → inject coord channel      │
│    └── subagent-control.ts → track activity/state     │
│           │                                           │
│     ┌─────┼──────────┐                                │
│     ▼     ▼          ▼                                │
│   Single  Parallel  Chain                             │
│     │     │          │                                │
│     ▼     ▼          ▼                                │
│  execution.ts   chain-execution.ts                    │
│  (spawn pi child processes)                           │
│     │                                                │
│     ▼                                                │
│  ┌─────────────────────────────────┐                 │
│  │ CHILD PROCESS (pi --mode json)  │                 │
│  │  - isolated session             │                 │
│  │  - system prompt + skills       │                 │
│  │  - stdout JSON lines → parent   │                 │
│  │  - intercom (if bridge active)  │                 │
│  └─────────────────────────────────┘                 │
│                                                       │
│  async runs: subagent-runner.ts (detached process)    │
│  tracked via async-job-tracker.ts + result-watcher.ts │
└──────────────────────────────────────────────────────┘
```

---

## Key Design Principles

- **Single-writer by default** (only one agent should edit files at a time)
- **Children don't recurse** (depth limit + `pi-subagents` skill is stripped from children)
- **Parent owns orchestration** (children receive concrete tasks, not orchestration responsibilities)
- **Conservative control** (interrupt only on clear signals, not brief silence)

---

## Key Source Files

| File | Responsibility |
|------|---------------|
| `index.ts` | Extension entry point, registers tool, slash commands, event handlers |
| `subagent-executor.ts` | Central dispatcher: validates input, resolves context, routes to single/parallel/chain/async paths |
| `execution.ts` | Foreground `runSync()`: spawns child pi process, streams JSON events, tracks progress |
| `subagent-runner.ts` | Async `runSubagent()`: detached runner with status.json/events.jsonl persistence |
| `fork-context.ts` | Session branching for forked context via `sessionManager.createBranchedSession()` |
| `intercom-bridge.ts` | Resolves and injects intercom coordination channel into child agents |
| `subagent-control.ts` | Activity state machine, control events (needs_attention, active_long_running), interrupt handling |
| `chain-execution.ts` | Chain orchestration: sequential steps with {previous} templating, parallel steps within chains |
| `settings.ts` | Chain behavior resolution, template variables, progress file management |
| `parallel-utils.ts` | Worker pool (`mapConcurrent`), result aggregation |
| `model-fallback.ts` | Model candidate resolution, retryable failure detection, fallback chain |
| `long-running-guard.ts` | Mutating tool failure detection, escalation to needs_attention |
| `types.ts` | All type definitions, constants, defaults, depth guards |
| `worktree.ts` | Git worktree creation/cleanup/diffing for parallel write isolation |
| `agents.ts` | Agent discovery from user/project/builtin scopes, frontmatter parsing |
| `agent-selection.ts` | Agent scope merging (project > user > builtin) |
| `agent-management.ts` | CRUD operations for agent definitions |
