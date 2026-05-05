---
head: 22db3f46d1527c2373d7da232ebf6d2480f257bf
dirty: false
generatedAt: 2026-05-05T01:45:00Z
taskScope: Native subagent parent/child bridge options using Pi Manager extension/tool management and Pi core extension APIs
changeSummarySincePrevious: none
reusedCache: false
---

# Code Context

## Scope
How Pi Manager can implement bundled parent-facing `managed_subagent(...)` and child-facing `contact_supervisor(...)` bridges without relying on `pi-subagents`/`pi-intercom`.

## Files Retrieved
1. `pi-manager/ExtensionManagement.swift` (lines 1-340) - app extension discovery/enabling model.
2. `pi-manager/PiAgentRunnerService.swift` (lines 368-410, 724-789) - parent RPC event handling and extension UI request routing.
3. `pi-manager/PiAgentSessionModels.swift` (lines 404-427) - decoded RPC event fields available to app.
4. `pi-manager/PiRPCClient.swift` (lines 40-80, 100-116) - child/parent RPC command send and extension UI responses.
5. `pi-manager/PiSubagentRunService.swift` (lines 1-360) - current native child run service and launch arg shaping.
6. `/opt/homebrew/lib/node_modules/@mariozechner/pi-coding-agent/docs/extensions.md` (lines 77-88, 1217-1267, 2100-2129) - extension tool and UI APIs.
7. `/opt/homebrew/lib/node_modules/@mariozechner/pi-coding-agent/dist/main.js` (lines 404-430) - Pi loads explicit extension paths and extension factories.
8. `/opt/homebrew/lib/node_modules/@mariozechner/pi-coding-agent/examples/extensions/structured-output.ts` (lines 1-44) - terminating custom tool pattern.
9. `/opt/homebrew/lib/node_modules/@mariozechner/pi-coding-agent/examples/rpc-extension-ui.ts` (lines 1-56) - RPC `extension_ui_request` shape.

## Key Code

### Pi extension loading
- Pi Manager scans extension files in global/project `.pi/.../extensions`, package manifests, and settings `extensions` entries; records include `path`, `enabled`, `origin`, and settings path (`ExtensionManagement.swift:41-63`, `72-123`).
- Pi core accepts explicit CLI extension paths via `--extension`; `main.js:404-430` resolves `parsed.extensions` and passes them as `additionalExtensionPaths` into the resource loader. This is the simplest way for app-managed native runs to load bundled bridge extensions without writing user settings.
- `PiRPCClient` now supports `extraArguments` and `environment` for launched Pi processes, so the app can pass `--extension /path/to/bridge.ts` and env like `PI_MANAGER_BRIDGE_TOKEN` (`PiRPCClient.swift:20-52`).

### Pi extension tool API
- Extensions register LLM-callable tools with `pi.registerTool({ name, description, parameters, execute(...) })`; `execute` returns `{ content, details }` (`extensions.md:77-88`, `1217-1267`).
- Tools can stream updates with `onUpdate?.({ content: [...] })` (`extensions.md:1252-1255`).
- Returning `terminate: true` can skip the automatic follow-up LLM call when all tool results in the batch terminate; useful for `contact_supervisor` final/blocking behavior only if carefully chosen (`structured-output.ts:1-44`).

### Extension UI as an app bridge
- Extensions can call `ctx.ui.select/confirm/input/editor/notify` (`extensions.md:2100-2129`). In RPC mode, these become `extension_ui_request` JSON events; example type has `id`, `method`, `title`, `options`, `message`, `placeholder`, `prefill` (`rpc-extension-ui.ts:31-56`).
- Pi Manager already handles extension UI requests: known input/select/confirm/editor variants become `PiAgentUIRequest`; `notify` becomes a status transcript entry; noisy methods like `setTitle`, `setStatus`, `setWidget` are ignored (`PiAgentRunnerService.swift:724-755`).
- Pi Manager can answer an extension UI request by sending `extension_ui_response` (`PiRPCClient.swift:100-116`).

## Architecture

### Option A: UI-request bridge (fastest, no server)
Use `ctx.ui.input`/`ctx.ui.editor` as a private RPC tunnel between extension and Pi Manager.

Parent `managed_subagent(...)` extension flow:
1. Parent extension registers tool `managed_subagent`.
2. Tool `execute` serializes `{ kind: "managed_subagent", toolCallId, agent, task, options }`.
3. Extension calls `await ctx.ui.editor("PI_MANAGER_BRIDGE managed_subagent", jsonPayload)` or `ctx.ui.input(...)`.
4. App detects sentinel title/method in `handleExtensionUIRequest` instead of showing normal UI.
5. App starts `PiSubagentRunService.runSingle(...)`, waits for completion, responds to the request ID with JSON result via `extension_ui_response`.
6. Tool returns that JSON as tool output to parent.

Child `contact_supervisor(...)` extension flow:
1. Child extension registers tool `contact_supervisor`.
2. For `progress_update`, extension can use `ctx.ui.notify(JSON)` or bridge `input` and app auto-acks.
3. For `need_decision` / `interview_request`, extension calls `ctx.ui.editor("PI_MANAGER_BRIDGE contact_supervisor", jsonPayload)` and awaits app response.
4. App maps request to native run/supervisor card, obtains user/parent answer, responds with JSON.

Pros: no local server, works with existing RPC `extension_ui_request` plumbing, explicit request IDs, easy to load by `--extension`. Cons: uses UI API as transport; must hide sentinel requests from normal UI and ensure timeouts/cancel paths.

### Option B: localhost/Unix-socket IPC bridge (cleanest long-term)
Bundle extensions that use Node `fetch` or `net` to call a Pi Manager local endpoint. App starts a per-process/per-run local server with env vars:
- `PI_MANAGER_BRIDGE_URL`
- `PI_MANAGER_BRIDGE_TOKEN`
- `PI_MANAGER_PARENT_SESSION_ID`
- `PI_MANAGER_SUBAGENT_RUN_ID` for children

Parent tool POSTs `/managed-subagent`, child tool POSTs `/contact-supervisor`. App responds when done.

Pros: explicit protocol, not abusing UI requests, supports streaming/progress and reconnection better. Cons: implement secure local server, lifecycle, tokens, firewall/app sandbox considerations.

### Option C: generated per-run extension file
For each parent/child run, app writes a tiny extension into the artifact dir with embedded run/session IDs and loads it via `--extension <artifact>/bridge.ts`. This pairs well with A or B and avoids global extension installation.

Pros: no global settings mutation, no extension picker pollution, per-run config baked in. Cons: generated code must be carefully escaped and debugged.

## Start Here
Start in `PiAgentRunnerService.handleExtensionUIRequest` (`pi-manager/PiAgentRunnerService.swift:724-755`). Add sentinel detection for `PI_MANAGER_BRIDGE managed_subagent` / `PI_MANAGER_BRIDGE contact_supervisor`, and route to new app-native bridge handlers before normal UI request handling.

## Constraints And Risks
- Do not install bridge extensions into `~/.pi/agent/extensions` by default; pass explicit `--extension` paths from the app so CLI/TUI remains unaffected.
- `PiSubagentRunService` currently launches child extensions only from `agent.resolved.extensions`; it should append app-required bridge extension paths separately so agents cannot accidentally disable `contact_supervisor` plumbing.
- Current child runner only stores compact summary/status, not full child transcript; bridge work should not assume child transcript UI exists yet.
- `contact_supervisor` must be available only when intended. If agent tools exclude `contact_supervisor`, do not load/enable the child bridge tool.
- If using UI-request transport, sentinel requests must not create visible “Input Needed” cards unless they are actual supervisor decisions.
- For blocking parent `managed_subagent`, avoid deadlock: the parent tool execution is waiting while app runs a child process; app must remain responsive and handle child completion asynchronously before responding to parent extension UI request.
- Security: if using local IPC, require unguessable per-run tokens and bind only to loopback/Unix socket.

## Pi-intercom handoff
No intercom target used; findings written to `subagent-research/native-subagent-bridges-scout.md`.
