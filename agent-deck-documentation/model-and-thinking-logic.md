# Model and Thinking Level Logic

This document explains how Agent Deck selects, stores, and applies Pi model and thinking-level settings.

## Key principle

Agent Deck treats model and thinking level as **launch configuration** for Pi sessions.

That means Agent Deck prefers starting Pi with:

```text
--provider <provider> --model <model> --thinking <level>
```

instead of mutating a running Pi process with RPC commands like `set_model`, `cycle_model`, `set_thinking_level`, or `cycle_thinking_level`.

Reason: launch-time configuration is more predictable and avoids accidentally changing Pi global/runtime defaults.

## Stored session fields

Each `PiAgentSessionRecord` can contain:

| Field | Meaning |
|---|---|
| `modelProvider` | Provider reported by Pi for the current/resumed session. |
| `model` | Model reported by Pi for the current/resumed session. |
| `modelOverrideProvider` | Agent Deck's explicit provider selection for this session. |
| `modelOverrideID` | Agent Deck's explicit model selection for this session. |
| `thinkingLevel` | Agent Deck's selected thinking level for this session. |

Override fields win over reported fields when launching.

## Launch resolution

`PiAgentRunnerService.launchConfiguration(for:)` resolves launch values as:

```text
provider = first non-empty(modelOverrideProvider, modelProvider)
model    = first non-empty(modelOverrideID, model)
thinking = normalizedThinkingLevel(thinkingLevel)
```

`normalizedThinkingLevel` maps Pi's legacy/alternate `none` value to `off`.

The resolved values are passed to `PiRPCClient`, which appends `--provider`, `--model`, and `--thinking` to the Pi process arguments when non-empty.

## Native subagent model and thinking values

Native subagents use persistent per-agent `model` and `thinking` defaults managed in the **Models** view. Builtin overrides are global-only; Agent Deck ignores project `.pi/settings.json` `subagents` configuration.

Resolution order for child launches:

1. A parent-session picker override wins when present. `Pi default` bypasses the persistent per-agent field and inherits parent/Pi.
2. Otherwise use the persistent Models value.
3. If no model is set, inherit the parent session's selected/reported model.
4. If no thinking level is set, inherit the parent session thinking level.

Native subagents usually encode the resolved thinking level as a `:<thinking>` suffix on the child `--model` argument, including `:off` when the agent is explicitly configured with Thinking Off.

## Default model and thinking values

`AppViewModel` reads Pi runtime defaults from:

```text
~/.pi/agent/settings.json
```

Relevant keys:

| Key | Meaning |
|---|---|
| `defaultProvider` | Default Pi provider. |
| `defaultModel` | Default Pi model. Can also be `provider/model`. |
| `defaultThinkingLevel` | Default thinking level. `none` is normalized to `off`. |

Default model lookup prefers an enabled model matching the runtime defaults, then falls back to the first enabled model.

Default thinking level:

1. uses `defaultThinkingLevel` if supported,
2. otherwise uses `medium` if supported,
3. otherwise uses the first supported level,
4. otherwise falls back to `off`.

## Model option sources

Model picker options come from the app-level model catalog loaded by:

```text
pi --list-models
```

Agent Deck stores this in `AppViewModel.availableModels`. The Models screen, Pi Agent footer picker, agent editor picker, title-generation model selection, and thinking validation all use this same app-level catalog.

Disabled models from app settings are filtered out.

The **Add Provider** picker is separate from the authorized model catalog. It asks the installed Pi `ModelRuntime` for every registered provider, its display name, and its advertised API-key and OAuth capabilities. Agent Deck does not maintain a provider allowlist, so providers added by a Pi update appear automatically. If runtime metadata cannot be loaded, the picker shows an error and retry action rather than a potentially stale fallback list.

## OpenAI Fast mode

For the `openai-codex` provider, the Models header has a provider-wide **Fast** control. When enabled, Agent Deck applies OpenAI's `priority` service tier to each eligible ChatGPT OAuth Codex request from parent chats and managed Deck agents. The setting is one global preference, remains effective for subsequent requests from already-running sessions, and does not affect one-shot automation/helper Pi calls.

The runtime extension applies the tier only when the active request is an `openai-codex` / `openai-codex-responses` ChatGPT OAuth request, its request model matches the active model, and the request did not already provide `service_tier`.

## Thinking-level validation

Before applying a thinking level, Agent Deck checks whether the selected model supports it.

Supported levels come from the app's enabled discovered model catalog.

`pi --list-models` reports whether each model supports thinking. Agent Deck then probes Pi's installed model metadata to fill exact supported thinking levels when available.

If a model explicitly does not support thinking, the supported level list is `off` only.

If the requested level is unsupported, Agent Deck does not apply it and records a session error.

## What happens when the user changes model/thinking

### Idle or non-streaming running session

If a Pi client exists and the session is not actively streaming, Agent Deck immediately restarts the Pi process with the updated launch configuration.

The restart uses the existing Pi session file when available, so conversation context is preserved.

### Active streaming session

If the session is currently active/streaming, Agent Deck does **not** interrupt the current turn.

Instead it records a pending configuration restart. The next normal prompt relaunches Pi with the updated config and sends that prompt into the relaunched session.

Steering messages during an active turn still go to the existing running process.

### Stopped, parked, or not-yet-running session

If no Pi client exists, Agent Deck only updates the stored session configuration. The next resume/start uses the new model and thinking level.

## Why cycle is handled in Agent Deck

Pi has RPC commands for cycling model/thinking, but Agent Deck intentionally does not use them.

Instead:

- `AppViewModel.cyclePiAgentModelForSelectedSession()` picks the next model from Agent Deck's known options.
- `AppViewModel.cyclePiAgentThinkingLevelForSelectedSession()` picks the next supported thinking level.
- The selected value is stored on the session.
- `PiAgentRunnerService` applies it through relaunch logic.

This keeps cycling session-local and avoids mutating Pi defaults unexpectedly.

## State refresh from Pi

After launch, Agent Deck asks Pi for runtime state.

`applyState` updates:

- `piSessionFile`
- `piSessionId`
- reported model/provider fields
- reported thinking level, unless Agent Deck has a pending explicit thinking selection
- run status (`running` vs `idle`)

Agent Deck preserves explicit user choices when Pi's state response is stale or does not echo a recently selected thinking level.

Agent Deck intentionally does not ask the running RPC session for a second model catalog. The global `pi --list-models` catalog is the model/thinking source of truth for UI choices.

## Title generation

Session-title generation also uses launch-time model configuration. It passes model/provider/thinking as process arguments and does not send model/thinking mutation RPCs.

## Important files

| File | Responsibility |
|---|---|
| `AppViewModel.swift` | Chooses/cycles models and thinking levels; reads Pi defaults; validates supported levels. |
| `PiAgentRunnerService.swift` | Stores changes, decides whether to relaunch now or later, builds launch configuration. |
| `PiRPCClient.swift` | Converts launch configuration into Pi CLI arguments. |
| `PiSubagentLaunchPlanner.swift` | Resolves native subagent model/thinking, including agent thinking with inherited model. |
| `PiAgentSessionModels.swift` | Persists per-parent-session child launch overrides. |
| `PiAgentSessionListViews.swift` / `PiAgentViews.swift` | UI surfaces for model/thinking controls and session state. |
| `PiAgentBridgeSmokeTests.swift` / `PiSubagentRuntimeSmokeTests.swift` | Smoke tests ensuring launch arguments are used and mutation RPCs are not sent. |

## Behavior summary

| Situation | Behavior |
|---|---|
| Change model/thinking while idle | Relaunch immediately with new args. |
| Change model/thinking while active | Queue relaunch; apply on next normal prompt. |
| Change model/thinking while stopped | Store config; apply on next launch. |
| Cycle model/thinking | Resolve in Agent Deck, then use same relaunch logic. |
| Unsupported thinking level | Reject and store a session error. |
| `none` thinking value | Normalize to `off`. |
