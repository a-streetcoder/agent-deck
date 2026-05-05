# pi-subagents architecture brief for a simplified app-oriented subagent system

Scope: current installed package at `/opt/homebrew/lib/node_modules/pi-subagents` version `0.24.0`, plus local docs in `pi-documentation/`. This is an implementation-facing brief, not a source change.

## 1. Core mental model

`pi-subagents` is a Pi extension that gives the parent session one `subagent` tool plus optional slash commands. A child subagent is a separate Pi process/session launched with a shaped system prompt, task text, tools/extensions, cwd, sessions, and optional forked history. The README states the model plainly: parent Pi starts focused child sessions, foreground runs stream in conversation, background runs keep working and can be checked later (`README.md:41-47`).

Main runtime map from package docs (`README.md:967-985`):
- `src/extension/index.ts`: extension registration, tool/message/render wiring.
- `src/agents/agents.ts`: agent/chain discovery and frontmatter parsing.
- `src/runs/foreground/subagent-executor.ts`: routing for execution, management, status, interrupt, resume, doctor.
- `src/runs/foreground/execution.ts`: foreground child process execution.
- `src/runs/background/async-execution.ts` + `subagent-runner.ts`: detached/background execution.
- `src/shared/settings.ts`: chain behavior, reads/output/progress instruction injection.
- `src/intercom/intercom-bridge.ts`: intercom bridge detection/injection.

## 2. Discovery and resource precedence

Agent discovery is filesystem-first and scope-aware:
- Project root is the nearest ancestor containing `.pi` or `.agents`, not necessarily git root (`agents.ts:206-214`).
- Builtins live under the package `agents/` dir (`agents.ts:723-735`).
- User agents load from both `~/.pi/agent/agents` and legacy `~/.agents` (`agents.ts:725-743`).
- Project agents load from nearest project `.agents` and `.pi/agents` (`agents.ts:697-709`, `agents.ts:746`).
- Merge precedence is builtin first, then user, then project for `scope: both`; user-only and project-only exclude the other custom scope (`agent-selection.ts:3-22`).
- Builtin behavior can be patched through `~/.pi/agent/settings.json` and nearest `.pi/settings.json` under `subagents.agentOverrides`; project override/bulk-disable wins over user (`agents.ts:341-435`).
- Chains are `.chain.md` files; user chains live in `~/.pi/agent/chains`, project chains in `.pi/chains` (`agents.ts:713-799`). Chain parser supports step-level `output`, `outputMode`, `reads`, `model`, `skills`, `progress` (`chain-serializer.ts:3-56`).

Agent frontmatter fields parsed by runtime include `name`, optional `package` (runtime name becomes `package.localName`), `description`, `tools` including `mcp:`, `model`, `fallbackModels`, `thinking`, `systemPromptMode`, `inheritProjectContext`, `inheritSkills`, `defaultContext`, `skills`, `extensions`, `output`, `defaultReads`, `defaultProgress`, `interactive`, `maxSubagentDepth`, and unknown `extraFields` (`agents.ts:544-656`; docs example `README.md:408-456`).

## 3. Tool API and management surface

The extension registers one ToolDefinition named `subagent` (`extension/index.ts:398-475`) using TypeBox schema `SubagentParams` (`schemas.ts:101-177`). The tool has three execution modes and management/control actions:
- Single: `{ agent, task? }`.
- Parallel: `{ tasks: [{ agent, task, count?, output?, outputMode?, reads?, progress?, model?, skill? }], concurrency?, worktree? }`.
- Chain: `{ chain: [{ agent, task?, ... } | { parallel: [...] }], task?, chainDir? }`.
- Context: `context: "fresh" | "fork"`; omitted context becomes fork if any requested agent has `defaultContext: "fork"` (`schemas.ts:141-143`, `subagent-executor.ts:691-700`).
- Management/control: `action: list|get|create|update|delete|status|interrupt|resume|doctor` (`types.ts:597`, `extension/index.ts:414-429`).

The tool description explicitly instructs the parent to list before executing and names the available execution/management/control patterns (`extension/index.ts:398-429`). Management create/update serializes agents/chains and validates known fields in `agent-management.ts` (notably config parsing begins at `agent-management.ts:28-88` and chain/agent config validation at `agent-management.ts:137-280`).

## 4. Slash commands and prompt-template bridge

Slash commands are a thin event/RPC wrapper over the same executor:
- Registered commands: `/run`, `/chain`, `/run-chain`, `/parallel`, `/subagents-doctor` (`slash-commands.ts:407-517`; docs `README.md:234-246`).
- Slash args support inline config like `agent[output=file,skill=a+b,progress]`, `--bg`, and `--fork` (`slash-commands.ts:24-83`, `slash-commands.ts:407-509`).
- Slash command flow sends a custom `subagent-slash-result` message, emits `subagent:slash:request`, waits for `started/update/response`, supports Escape cancellation, and persists a session snapshot for export (`slash-commands.ts:141-218`, `slash-commands.ts:271-316`).
- `registerSlashSubagentBridge` listens for request/cancel events, invokes the executor, and emits progress/status/result events (`slash-bridge.ts:49-175`).
- `prompt-template-bridge.ts` exposes a similar event bridge (`prompt-template:subagent:*`) for external prompt-template packages, translating progress/results into message payloads.

For a native app, these are best treated as presentation adapters. The real API surface is the `SubagentParamsLike` executor shape plus event updates.

## 5. Foreground execution model

`createSubagentExecutor` is the primary router (`subagent-executor.ts:2027-2207`):
1. Handles management/status/resume/interrupt/doctor before execution (`subagent-executor.ts:2038-2068`).
2. Enforces nesting depth via env/config (`subagent-executor.ts:2070-2082`; depth helpers `types.ts:658-676`).
3. Expands `count`, resolves async forcing, discovery scope, cwd, current session id, agent defaults, and intercom bridge (`subagent-executor.ts:2084-2119`).
4. Validates exactly one execution mode and known agents (`subagent-executor.ts:593-681`).
5. Creates fork session resolver if needed, session root, artifact dir, and foreground control state (`subagent-executor.ts:2126-2191`).
6. Routes to async, chain, parallel, or single path (`subagent-executor.ts:2193-2207`).

Foreground child execution is by spawning Pi in JSON mode:
- `runSync` resolves skills, builds final system prompt, model candidates/fallbacks, artifacts, then calls `runSingleAttempt` (`execution.ts:719-810`).
- `runSingleAttempt` calls `buildPiArgs` and `spawn`s the Pi CLI with `stdio: [ignore, pipe, pipe]` (`execution.ts:121-170`).
- It parses JSON stdout events (`tool_execution_start/end`, `message_end`, `tool_result_end`) to update progress, usage, current tool/path, recent output, completion/error, and control notices (`execution.ts:392-527`).
- It has final-message drain/kill guards and interrupt handling (`execution.ts:214-260`, `execution.ts:532-623`).
- It returns `SingleResult` with messages, usage, model attempts, progress, artifacts, saved output, final output, and session file (`execution.ts:625-903`).

`buildPiArgs` is central to child isolation (`pi-args.ts:51-148`): it sets session flags, model, builtin tool allowlist, extension allowlist/disablement, prompt file, task file for long tasks, child env, MCP direct tools, intercom session name, run id, child agent/index, and always injects the internal `subagent-prompt-runtime.ts` extension.

## 6. Async/background execution model

Async is a detached runner, not just a nonblocking foreground process:
- Availability requires `jiti` (`async-execution.ts:33-61`, `async-execution.ts:129-137`).
- `executeAsyncChain`/`executeAsyncSingle` pre-resolve agents, skills, system prompts, models, output paths, sessions, intercom targets, and write an async config JSON under a temp root (`async-execution.ts:191-429`, `async-execution.ts:451-579`).
- `spawnRunner` launches `node <jiti-cli> subagent-runner.ts <config>` detached with ignored stdio (`async-execution.ts:140-171`).
- Start events are emitted on `subagent:async-started` with pid/session/mode/agents/asyncDir metadata (`async-execution.ts:393-421`, `async-execution.ts:551-562`).
- Runtime temp dirs are user-scoped: `RESULTS_DIR`, `ASYNC_DIR`, `CHAIN_RUNS_DIR`, `TEMP_ARTIFACTS_DIR` under `${tmp}/pi-subagents-<scope>` (`types.ts:583-586`).

`subagent-runner.ts` is an independent runner that streams child Pi output to files/status/result JSON and supports sequential/parallel groups, interrupts, worktrees, output capture, artifacts, and control events. This is a large surface area; a simplified app should avoid reusing its file-protocol wholesale unless it needs background survival outside the app process.

## 7. Context and child-safety handling

There are two separate concepts:
- Prompt inheritance: `systemPromptMode`, `inheritProjectContext`, `inheritSkills`, explicit `skills`, `tools`, `extensions` (`README.md:395-456`).
- Session context: `context: fresh|fork` (`README.md:701-725`). Fork fails fast if parent session/leaf cannot be branched (`fork-context.ts:21-55`; docs `README.md:721`).

Runtime safety boundaries:
- Parent extension returns early in child processes when `PI_SUBAGENT_CHILD=1`, so children do not register the `subagent` tool (`extension/index.ts:220-221`; env set in `pi-args.ts:129-148`).
- Child prompt runtime strips project context and/or inherited skills based on env, removes the `pi-subagents` skill, and prepends boundary instructions that the child is not the orchestrator and must not propose/run subagents (`subagent-prompt-runtime.ts:7-16`, `subagent-prompt-runtime.ts:45-81`).
- It also filters parent-only custom messages, previous `subagent` tool results, and assistant `subagent` tool-call blocks from forked/inherited history (`subagent-prompt-runtime.ts:19-125`).
- Fork task text is wrapped with a “reference-only context” preamble (`types.ts:599-633`; applied in `subagent-executor.ts:819-835`, `subagent-executor.ts:1801-1803`).
- Official skill docs emphasize parent-only orchestration and child filtering (`pi-documentation/pi-subagent-official-skill.md:535`).

Risk: context stripping is partly string-pattern based (`# Project Context`, skill section markers, custom message types), so it is sensitive to Pi core prompt/message format changes.

## 8. Skills handling

Explicit subagent skills are resolved by `pi-subagents`, not Pi core’s entire possible skill graph:
- Search paths include project `.pi/skills`, project `.agents/skills`, user `~/.pi/agent/skills`, user `~/.agents/skills`, package skill paths discovered from installed packages/settings, current package root, and explicit settings skill paths (`skills.ts:318-345`).
- Sources have precedence project > project settings/packages > user > user settings/packages > extension/builtin (`skills.ts:30-42`, `skills.ts:445-485`).
- `resolveSkillsWithFallback` tries primary child cwd then parent/runtime cwd (`skills.ts:561-574`).
- `pi-subagents` skill is intentionally blocked as missing (`skills.ts:529-559`), and discoverable skills list filters it out (`skills.ts:611-624`).
- Resolved skill contents are injected into child system prompt as `<skill name="...">...</skill>` blocks (`skills.ts:577-584`; used in foreground `execution.ts:754-768` and async `async-execution.ts:267-276`, `async-execution.ts:477-484`).

For an app-oriented system, prefer explicit skill references with validation and preview; do not silently inherit all ambient skill discovery unless matching Pi behavior is a requirement.

## 9. Reads, output, progress, and chain data flow

Reads/output/progress are instruction injection plus post-run validation, not hard guarantees:
- `resolveStepBehavior` picks step override > agent default > disabled for `output`, `reads`, `progress`, `skills`, and model (`settings.ts:179-230`).
- `buildChainInstructions` prepends `[Read from: ...]` and `[Write to: ...]`, appends progress instructions and prior summary (`settings.ts:261-302`).
- Single/parallel output paths resolve relative to requested child cwd and are appended to the task as `**Output:** Write your findings to: <path>` (`single-output.ts:10-24`; used in `subagent-executor.ts:1273-1277`, `subagent-executor.ts:1804-1811`).
- If the child wrote the output file, runtime reads it back; otherwise it persists fallback final text to the output path (`single-output.ts:66-122`, `execution.ts:684-694`).
- `outputMode: file-only` requires output path and returns only a compact saved-file reference (`single-output.ts:59-64`, `single-output.ts:124-151`; docs `README.md:723`).
- Chains template `{task}`, `{previous}`, `{chain_dir}`; sequential steps set `prev` to prior output (`chain-execution.ts:721-745`, `chain-execution.ts:919-920`), and parallel groups aggregate outputs (`parallel-utils.ts` via `settings.ts:398`).
- Chain step expected output file existence is checked after success, but only emits a warning in result error field; it does not enforce write semantics before child completion (`chain-execution.ts:883-905`).
- Progress is a file convention (`progress.md`) and is suppressed for read-only/no-edit tasks by regex heuristics (`settings.ts:232-252`).

Implication: a simplified app can make output/read behavior stronger by mounting explicit input files and collecting output artifacts through app-side contracts, instead of depending only on prompt instructions.

## 10. Intercom bridge and RPC interactions

There are two intercom layers:

### Child-to-parent bridge
- Bridge is optional; docs say `pi-subagents` works without `pi-intercom` (`README.md:196-230`; official skill `pi-subagent-official-skill.md:321-336`).
- `resolveIntercomBridge` activates only if mode is not off/fork-only mismatch, orchestrator target exists, pi-intercom package/extension dir exists, and intercom config is enabled (`intercom-bridge.ts:311-354`).
- Session target defaults to current Pi session name or `subagent-chat-<session-id>` (`intercom-bridge.ts:73-82`); child target is `subagent-<agent>-<runId>-<index>` (`intercom-bridge.ts:84-87`).
- `applyIntercomBridgeToAgent` adds `intercom` and `contact_supervisor` to an existing tool allowlist if present, appends bridge instructions to the system prompt, but only when extension sandbox permits intercom (`intercom-bridge.ts:357-380`). If `agent.tools` is omitted, it leaves tools omitted so Pi’s normal tools apply; if tools is an allowlist, it adds bridge tools.
- Foreground execution can detach instead of killing when a child starts intercom/contact_supervisor and parent aborts/interrupts (`execution.ts:230-260`, `execution.ts:587-600`).

### Parent-side grouped result delivery
- Foreground success tries to send grouped completion through intercom; if delivered, parent tool result becomes a compact receipt and details are stripped of full outputs (`subagent-executor.ts:536-589`, `subagent-executor.ts:1880-1897`).
- Result delivery emits `subagent:result-intercom` and waits briefly for `subagent:result-intercom-delivery` ack (`result-intercom.ts:167-216`).
- Payload includes mode, status, children, summaries, artifact/session paths, async ids, and child intercom targets (`result-intercom.ts:138-165`, `result-intercom.ts:226-276`).

Risk: this is event-bus-coupled to `pi-intercom` and depends on both extension loading and tool availability inside children. For an app, model it as first-class run messages in an app database/WebSocket channel rather than a prompt-injected ad hoc bridge unless Pi compatibility is required.

## 11. Controls, status, interrupts, and observability

- Foreground controls are kept in memory (`SubagentState.foregroundControls`) and expose `status`/`interrupt` (`types.ts:367-393`, `subagent-executor.ts:211-230`, `subagent-executor.ts:2049-2068`).
- Async status persists under `ASYNC_DIR`; result watcher and async tracker are initialized at extension startup (`extension/index.ts:235-286`).
- Control events classify long-running/needs-attention states based on idle time, turns/tokens, and mutating tool failures; foreground and async both propagate notices through Pi events and optionally intercom (`execution.ts:318-390`, `subagent-control.ts`).
- Artifacts default on: input, output, metadata, optional JSONL, cleanup 7 days (`types.ts:518-525`; extension cleanup `extension/index.ts:242`, `extension/index.ts:525`).

For an app, prefer persisted run records with child process pid, status, current tool, cwd/path, stdout JSON events, session file, artifacts, and cancellation state. In-memory-only foreground controls are insufficient for app restart or multi-window control.

## 12. Key simplification opportunities for Pi Manager / app-oriented design

1. **Use one explicit run model.** Represent `single`, `parallel`, and `chain` as a run with child tasks and dependency edges. Avoid separate slash/tool/async file protocols in the app core.
2. **Make discovery deterministic and user-visible.** Implement a scanner with explicit roots and precedence, but expose editable app-managed resources separately from read-only package builtins.
3. **Replace prompt-only output contracts with app-enforced artifacts.** Give every child a run artifact directory and expected output file; treat missing output as structured status, not a free-form warning.
4. **Make context mode explicit.** `fresh` vs `fork` should be a visible run option. Forking depends on Pi session-manager internals, so the app may need either a stable Pi API or its own transcript copy/branch model.
5. **Use a stable child launcher abstraction.** Current package builds CLI args and parses JSON stdout. An app should wrap this behind `ChildAgentRunner` so it can later switch from CLI spawn to direct Pi core API if available.
6. **Treat intercom as app messaging.** Native app can route child questions/progress to parent UI directly, with typed `needs_decision` / `progress_update` messages, instead of injecting target strings and waiting for package event acks.
7. **Keep child-safety boundaries.** Preserve “child cannot delegate” by not loading the subagent extension/tool in children and by filtering parent-only artifacts from forked context.

## 13. Main implementation risks

- **Pi core API coupling:** process launch relies on CLI flags (`--mode json`, `--system-prompt`, `--append-system-prompt`, `--tools`, `--extension`, `--no-skills`, sessions). Flag changes could break a clone (`pi-args.ts:51-148`).
- **Fork context fragility:** `createForkContextResolver` uses `sessionManager.constructor.open(...).createBranchedSession(leafId)` (`fork-context.ts:21-55`), which may be internal/unstable.
- **Context filtering fragility:** prompt/message stripping uses literal section headers and custom message types (`subagent-prompt-runtime.ts:19-81`, `subagent-prompt-runtime.ts:83-125`).
- **Discovery compatibility surface:** package supports legacy `.agents`, new `.pi`, package npm/git skill paths, settings overrides, and package namespaces. A simplified app must choose whether to be compatible or opinionated.
- **Output contract is best-effort:** children can ignore `[Write to:]`/`**Output:**`; runtime recovers by saving final text, but workflows expecting files may still be wrong (`single-output.ts:87-122`, `chain-execution.ts:883-905`).
- **Parallel filesystem conflicts:** current system adds duplicate-output checks and optional git worktrees; without isolation, concurrent writers can clobber each other (`subagent-executor.ts:1246-1258`, docs `README.md:742-768`).
- **Async complexity:** detached TypeScript runner requires `jiti`, temp config/result files, watchers, status reconciliation, and cleanup (`async-execution.ts:129-171`, `types.ts:583-586`). Reimplement only if app needs child runs to survive app/parent turn lifecycle.
- **Intercom availability matrix:** bridge activation depends on package installation, config, extension sandbox, session name/id, and child tools allowlist (`intercom-bridge.ts:273-354`, `intercom-bridge.ts:357-380`).
- **Model fallback semantics:** fallback should trigger only provider/model failures, not task failures; app needs to preserve or simplify this policy (`execution.ts:779-840`).
- **Depth and parent-only skill guard:** nested delegation is prevented by env/depth and child extension non-registration. App must enforce this structurally, not rely only on prompt text (`types.ts:658-676`, `extension/index.ts:220-221`).
