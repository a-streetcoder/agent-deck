# Pi RPC Launch Flags and Subprocess Context

This document maps every Agent Deck launch of `pi --mode rpc`, the Pi CLI flags that are relevant to those launches, and the runtime context each subprocess can receive.

For the canonical explanation of how these launches resolve into final Pi system prompts, see [Agent Deck system prompt logic](agent-deck-system-prompt-logic.md).

Verified against:

- `agent-deck/PiRPCClient.swift`
- `agent-deck/PiAgentRunnerService.swift`
- `agent-deck/PiSubagentRunService.swift`
- `agent-deck/PiSubagentLaunchPlanner.swift`
- `agent-deck/PiSessionTitleGenerationService.swift`
- `agent-deck/PiAgentShipService.swift`
- `agent-deck/GitRepositoryService.swift`
- Pi docs: `docs/rpc.md`, `docs/usage.md`
- Pi parser/runtime: `dist/cli/args.js`, `dist/main.js`

Last checked: 2026-05-11.

## Summary

Agent Deck launches Pi RPC subprocesses from exactly four production call sites:

| Launch path | File | Purpose | Isolation posture |
|---|---|---|---|
| Parent Pi Agent session | `agent-deck/PiAgentRunnerService.swift` | Main app chat session | Normal Pi runtime with Agent Deck bridge extensions explicitly loaded. |
| Native subagent child session | `agent-deck/PiSubagentRunService.swift` | App-owned child Pi process for bounded subagent work | Mostly isolated by default; explicit extensions/tools/context/skills are controlled by agent settings. |
| Session title helper | `agent-deck/PiSessionTitleGenerationService.swift` | Generate a short title from the first user message | Highly isolated: no session, tools, extensions, skills, context files, or prompt templates. |
| Commit-message helper | `agent-deck/PiAgentShipService.swift` | Generate commit title/body from staged git status/diff | Highly isolated: no session, tools, extensions, skills, context files, or prompt templates. |

`PiRPCClient.launchArguments` always prepends:

```text
--mode rpc
```

Then it appends caller-provided `extraArguments`, followed by optional `--session`, `--provider`, `--model`, and `--thinking` arguments.

## Pi RPC-compatible CLI flag surface

The following table describes Pi CLI flags that are accepted by the Pi parser and relevant to RPC launch decisions. Some flags are valid CLI flags but are not useful for an app-owned RPC subprocess.

### Mode and session selection

| Flag | Pi meaning | Agent Deck usage |
|---|---|---|
| `--mode rpc` | Start Pi in JSONL RPC mode over stdin/stdout. | Always present via `PiRPCClient.launchArguments`. |
| `--no-session` | Use in-memory ephemeral session storage. | Used by title and commit-message helpers. |
| `--session <path\|id>` | Open a specific existing session file or matching id. | Used for parent session resume and explicit native subagent continuation. |
| `--fork <path\|id>` | Fork an existing session into a new session file. Cannot combine with `--session`, `--continue`, `--resume`, or `--no-session`. | Not used by Agent Deck native subagents. |
| `--session-dir <dir>` | Override session storage and lookup directory. | Used by fresh native subagent child sessions so child session files live under the run artifact directory. |
| `--continue`, `-c` | Continue the most recent session. | Parser supports it. Agent Deck does not use it for RPC launches. |
| `--resume`, `-r` | Browse/select a previous session. | Parser supports it. Agent Deck does not use it because it is interactive/headless-hostile. |

### Model and reasoning

| Flag | Pi meaning | Agent Deck usage |
|---|---|---|
| `--provider <name>` | Select provider. | Used for parent sessions, subagents, title helper, and commit helper when known. |
| `--model <pattern>` | Select model; supports `provider/model` and optional `:<thinking>` suffix. | Used broadly. Subagents may pass an inherited or explicit model with a thinking suffix. Helpers force `:off`. |
| `--thinking <level>` | Set thinking level: `off`, `minimal`, `low`, `medium`, `high`, `xhigh`. | Used by parent sessions. Subagents generally encode thinking in `--model <model>:<thinking>`. |
| `--models <patterns>` | Scoped model list for model cycling. | Parser supports it. Agent Deck does not use it for app sessions. |
| `--api-key <key>` | Runtime API-key override for selected provider. | Parser supports it. Agent Deck does not pass API keys as CLI args; credentials come from environment/settings. |

### Tools

| Flag | Pi meaning | Agent Deck usage |
|---|---|---|
| `--tools <list>`, `-t <list>` | Allowlist specific built-in, extension, and custom tools. | Used by native subagents when agent frontmatter declares a non-empty tools list. |
| `--no-tools`, `-nt` | Disable all tools. | Used by title helper and commit helper. Used by native subagents when the configured tools list exists but resolves empty. |
| `--no-builtin-tools`, `-nbt` | Disable built-in tools while keeping extension/custom tools enabled. | Parser supports it. Agent Deck does not currently use it. |

Pi built-in tool names from current docs: `read`, `bash`, `edit`, `write`, `grep`, `find`, `ls`.

### Resources and prompt composition

| Flag | Pi meaning | Agent Deck usage |
|---|---|---|
| `--extension <source>`, `-e <source>` | Load an explicit extension path/package/git source. Repeatable. | Used for Agent Deck bridge extensions, web extension, audit extension, enabled command extensions, configured native subagent extensions, and optional `contact_supervisor`. |
| `--no-extensions`, `-ne` | Disable extension discovery. Explicit `--extension` paths still load. | Used by all four launch paths. This is the basis of Agent Deck's explicit extension allowlist behavior. |
| `--skill <path>` | Load explicit skill file/directory. Repeatable. Still honored when `--no-skills` is present. | Used by parent sessions for Default + current Project skill assignments and by native subagents for agent-assigned skills. |
| `--no-skills`, `-ns` | Disable normal skill discovery/loading. Explicit `--skill` paths still load. | Used by all Agent Deck RPC launches. Parent and native subagent sessions combine it with explicit app-selected `--skill` paths. |
| `--prompt-template <path>` | Load explicit prompt template file/directory. Repeatable. | Used by parent sessions for Default + current Project prompt-template assignments. |
| `--no-prompt-templates`, `-np` | Disable prompt-template discovery/loading. Explicit `--prompt-template` paths still load. | Used by all Agent Deck RPC launches. Parent sessions combine it with explicit app-selected `--prompt-template` paths. |
| `--theme <path>` | Load explicit theme file/directory. Repeatable. | Parser supports it. Agent Deck does not pass explicit themes. |
| `--no-themes` | Disable theme discovery/loading. | Used by all Agent Deck RPC launches. Themes are UI-only and unnecessary for app-owned Pi subprocesses. |
| `--no-context-files`, `-nc` | Disable `AGENTS.md` / `CLAUDE.md` context discovery. | Used by title/commit helpers. Parent and native subagent sessions intentionally omit it. |
| `--system-prompt <text-or-existing-file-path>` | Replace Pi's default system prompt. Context files and skills can still append unless disabled. | Used by title helper, commit helper, and native subagents with `systemPromptMode` absent/`replace`. |
| `--append-system-prompt <text-or-existing-file-path>` | Append text or file contents to the system prompt. Repeatable. Explicit values suppress Pi's automatic `APPEND_SYSTEM.md` discovery. | Used by parent sessions to preserve the active append file before injecting the native subagent catalog. Used by native subagents when `systemPromptMode: append`. Passed as an empty value for replace-mode native subagents and isolated helpers to suppress `APPEND_SYSTEM.md`. |

### Miscellaneous / exiting flags

| Flag | Pi meaning | Agent Deck usage |
|---|---|---|
| `--verbose` | Force verbose startup. | Parser supports it. Agent Deck does not use it. |
| `--offline` | Disable startup network operations and set `PI_OFFLINE=1` plus `PI_SKIP_VERSION_CHECK=1`. | Parser supports it. Agent Deck does not currently pass it or set those env vars for child/helper launches. |
| `--help`, `-h` | Print help and exit. | Not useful for RPC sessions. |
| `--version`, `-v` | Print version and exit. | Not useful for RPC sessions. |
| `--list-models [search]` | List models and exit. | Not an RPC session. Agent Deck has separate model discovery behavior. |
| `--export <in> [out]` | Export session HTML and exit. | Not an RPC session. |
| `--print`, `-p` | Print mode, not RPC. | Not used by Agent Deck RPC launches. |
| `@file` args | Include files in initial CLI prompt. | Pi rejects `@file` args in RPC mode. Agent Deck sends images/files through RPC payloads or prompts instead. |
| Positional messages | Initial CLI messages. | Avoided by Agent Deck; messages are sent through RPC commands. |
| Unknown `--flag`s | Collected by parser and passed to extensions as extension-defined flags. | Agent Deck does not rely on this for generated bridge extensions. |

## Launch path details

### 1. Parent Pi Agent session

Source: `agent-deck/PiAgentRunnerService.swift`

Current launch shape:

```text
--mode rpc
--no-extensions
--extension <system-prompt-audit-bridge.ts>
--extension <agent-deck-ask-user-bridge.ts>
--extension <agent-deck-web-access.ts>
--extension <enabled Agent Deck command extension>...
[--extension <managed-subagent-bridge.ts>]
[--append-system-prompt <project .pi/APPEND_SYSTEM.md if present, else global ~/.pi/agent/APPEND_SYSTEM.md if present>]
[--append-system-prompt <native subagent catalog prompt>]
--no-skills
[--skill <default-or-project-skill-path>]...
--no-prompt-templates
[--prompt-template <default-or-project-prompt-path>]...
--no-themes
[--session <existing Pi session file>]
[--provider <provider>]
[--model <model>]
[--thinking <level>]
```

Runtime context/resources:

- Working directory is the session project/worktree path.
- Environment is produced by `EnvRuntimeEnvironment().environment(projectRoot:extra:)` and includes merged global/project `.env` values plus `AGENT_DECK_PARENT_SESSION_ID=<uuid>`.
- Ambient extension discovery is disabled.
- Explicit Agent Deck extensions are loaded:
  - system-prompt audit extension, which captures the final Pi prompt back into Agent Deck;
  - `ask_user` bridge for native app prompt cards;
  - web access extension backed by Agent Deck/Exa environment credentials;
  - enabled Agent Deck command extensions;
  - native subagent parent bridge when subagents are enabled.
- Parent sessions intentionally omit `--system-prompt`; Pi still owns base prompt selection from project `.pi/SYSTEM.md`, global `~/.pi/agent/SYSTEM.md`, or its built-in default prompt.
- When native subagents are enabled, Agent Deck appends a generated native subagent catalog prompt with `--append-system-prompt`.
- Because Pi skips automatic `APPEND_SYSTEM.md` discovery whenever any explicit `--append-system-prompt` is present, Agent Deck first explicitly preserves the same active append file Pi would have discovered: project `.pi/APPEND_SYSTEM.md`, otherwise global `~/.pi/agent/APPEND_SYSTEM.md`, otherwise no file append.
- Multiple explicit parent `--append-system-prompt` values stack, so the effective parent append order is active `APPEND_SYSTEM.md` first, then Agent Deck's native subagent catalog.
- Parent sessions pass `--no-skills` and then explicit `--skill <path>` arguments for Agent Deck Default + current Project skill assignments.
- Parent sessions pass `--no-prompt-templates` and then explicit `--prompt-template <path>` arguments for Agent Deck Default + current Project prompt assignments.
- Parent sessions pass `--no-themes`; Agent Deck does not load themes for app-owned Pi subprocesses.
- Parent sessions do **not** pass `--no-tools` or `--no-context-files`.

Privacy/context implications:

- Parent sessions intentionally behave like normal Pi sessions except for ambient extension, skill, and prompt-template discovery being disabled and Agent Deck resources being explicit.
- Pi may load project/global context files, system prompt files, append prompt files, and built-in tools according to normal Pi runtime rules.
- Catalog-only skills and prompt templates are not injected into parent sessions by Agent Deck.
- Model/thinking changes are applied by relaunching the process with CLI args, not by relying on Pi model cycling defaults.

### 2. Native subagent child session

Sources:

- `agent-deck/PiSubagentRunService.swift`
- `agent-deck/PiSubagentLaunchPlanner.swift`
- `agent-deck/PiNativeSubagentBridgeExtensions.swift`

Fresh launch shape:

```text
--mode rpc
--session-dir <artifact-dir>/sessions
--system-prompt <agent prompt + common child-session boundary>
# plus --append-system-prompt "" to suppress APPEND_SYSTEM.md discovery
# or only --append-system-prompt <agent prompt + common child-session boundary> when systemPromptMode == append
[--extension <contact-supervisor-bridge.ts>]
[--tools <agent tool allowlist>]
[--no-tools]                         # when tools are configured but empty after filtering
--no-extensions
[--extension <agent-configured extension>]...
--extension <agent-deck-web-access.ts>
--extension <system-prompt-audit-bridge.ts>
--no-skills
[--skill <agent-assigned-skill-path>]...
--no-prompt-templates
--no-themes
[--provider <provider>]
[--model <model[:thinking]>]
```

Continuation launch shape:

```text
--mode rpc
--session <prior-child-session-file>
# same prompt/tool/extension/skill flags as a fresh native subagent
```

Runtime context/resources:

- Each subagent has a stable run/Subagent ID and an artifact directory under `~/Library/Application Support/Agent Deck/Subagent Runs/<run-id>/`.
- Fresh runs write `system-prompt.md`, `input.md`, and `output.md` in the run artifact directory.
- Continuations write per-turn artifacts under `<artifact-dir>/turns/<turn-id>/`, resume the prior child Pi session, and update the same parent chat card.
- Child session files for fresh runs are stored under `<artifact-dir>/sessions`.
- The user prompt sent over RPC includes the concrete task, expected outcome, artifact directory, and optional read-first path hints. Continuation prompts say the prior child session is available but the new task is authoritative.
- Environment includes merged `.env` values plus:
  - `AGENT_DECK_NATIVE_SUBAGENT=1`
  - `AGENT_DECK_SUBAGENT_RUN_ID=<uuid>`
  - `AGENT_DECK_SUBAGENT_AGENT=<agent name>`
  - `MCP_DIRECT_TOOLS=<comma-list>` or `__none__`
- If worktree isolation is requested, the child cwd is the isolated worktree. Otherwise it is the parent session's worktree/project path.

Context/continuation behavior:

- Native subagents start fresh by default and do not receive parent conversation history.
- Agent Deck does not use `--fork` for native subagents.
- Direct follow-ups can continue a prior child by passing its Subagent ID through `managed_subagent(..., continueSubagentID)`. Agent Deck resumes the saved child session file with `--session`.
- If a parent starts a fresh child for follow-up work, it should pass a compact continuity packet in the task.

Skills/context behavior:

- Explicit native subagent `skills:` are resolved by name from the Agent Deck skill catalog and passed to Pi as explicit `--skill <path>` arguments.
- Agent Deck no longer pastes full skill bodies into the child system prompt.
- Native subagents always pass `--no-skills`; there is no ambient skill inheritance in the target runtime model.
- Native subagents use normal Pi project context-file discovery; Agent Deck does not pass `--no-context-files` for child sessions.
- Replace-mode native subagents pass `--append-system-prompt ""` so Pi does not append project/global `APPEND_SYSTEM.md`.
- Native subagents always pass `--no-prompt-templates`; prompt templates are parent-session shortcuts and are not assigned to child runs.
- Native subagents always pass `--no-themes`.

Privacy/context implications:

- Fresh subagents are isolated from parent conversation history.
- Continued subagents receive their own prior child conversation history, not the parent transcript.
- The child system prompt is currently passed as a raw process argument, even though the same text is also written to `system-prompt.md`.
- Explicit configured extensions and Agent Deck bridge extensions still load even with `--no-extensions`.

### 3. Session title helper

Source: `agent-deck/PiSessionTitleGenerationService.swift`

Current launch shape:

```text
--mode rpc
--no-session
--no-extensions
--no-skills
--no-tools
--no-context-files
--no-prompt-templates
--no-themes
--system-prompt <title-generation-only prompt>
--append-system-prompt ""
--provider <selected provider>
--model <selected model>:off
```

Runtime context/resources:

- Working directory is the project URL supplied by the caller.
- Environment is supplied by the caller.
- No persistent Pi session file is created.
- No tools, extensions, skills, prompt templates, context files, or `APPEND_SYSTEM.md` content are available.
- Initial title generation prompt includes only the first user message, trimmed and capped at 2,000 characters.
- Optional title refresh uses the same isolated helper shape and includes only the current title, latest user message capped at 2,000 characters, and up to 12 current plan items. The helper returns either `KEEP` or a replacement title.
- Timeout is 20 seconds.

Privacy/context implications:

- This is the most isolated Agent Deck Pi subprocess path.
- It still sends the first user message to the selected model/provider.
- Agent Deck passes `--no-themes` but does not currently pass `--offline` here.

### 4. Commit-message helper

Sources:

- `agent-deck/PiAgentShipService.swift`
- `agent-deck/AppViewModel.swift`
- `agent-deck/GitRepositoryService.swift`

Current launch shape:

```text
--mode rpc
--no-session
--no-extensions
--no-skills
--no-tools
--no-context-files
--no-prompt-templates
--no-themes
--system-prompt <commit-message-only prompt>
--append-system-prompt ""
--provider <selected provider>
--model <selected model>:off
```

Runtime context/resources:

- Working directory is the project URL supplied by the caller.
- Environment is supplied by the caller.
- No persistent Pi session file is created.
- No tools, extensions, skills, prompt templates, context files, or `APPEND_SYSTEM.md` content are available.
- Before this helper runs, `AppViewModel.shipSelectedPiAgentSession` stages changes with `git add -A`.
- `GitRepositoryService` supplies `git status --short --branch` and staged diff/stat content.
- The prompt includes status and staged diff/stat capped at 12,000 characters.
- Timeout is 30 seconds.

Privacy/context implications:

- This is highly isolated from Pi runtime resources.
- It still sends staged diff/status content to the selected model/provider.
- The user-facing ship confirmation should be explicit that staged diff content is sent to the selected AI model for commit-message generation.
- Agent Deck passes `--no-themes` but does not currently pass `--offline` here.

## Launch flag matrix

Legend: ✅ always used, ◐ conditionally used, ❌ not used.

| Flag | Parent session | Native subagent | Title helper | Commit helper |
|---|---:|---:|---:|---:|
| `--mode rpc` | ✅ | ✅ | ✅ | ✅ |
| `--no-session` | ❌ | ❌ | ✅ | ✅ |
| `--session <path\|id>` | ◐ resume existing Pi session | ◐ explicit continuation | ❌ | ❌ |
| `--fork <path\|id>` | ❌ | ❌ | ❌ | ❌ |
| `--session-dir <dir>` | ❌ | ✅ fresh runs | ❌ | ❌ |
| `--continue`, `-c` | ❌ | ❌ | ❌ | ❌ |
| `--resume`, `-r` | ❌ | ❌ | ❌ | ❌ |
| `--provider <name>` | ◐ selected/known provider | ◐ selected/inherited provider | ✅ selected provider | ✅ selected provider |
| `--model <pattern>` | ◐ selected/known model | ◐ selected/inherited model, often with thinking suffix | ✅ selected model with `:off` | ✅ selected model with `:off` |
| `--thinking <level>` | ◐ selected parent thinking level | ❌ uses model suffix instead | ❌ | ❌ |
| `--models <patterns>` | ❌ | ❌ | ❌ | ❌ |
| `--api-key <key>` | ❌ | ❌ | ❌ | ❌ |
| `--tools <list>`, `-t` | ❌ | ◐ when agent declares non-empty tools | ❌ | ❌ |
| `--no-tools`, `-nt` | ❌ | ◐ when agent declares tools but effective list is empty | ✅ | ✅ |
| `--no-builtin-tools`, `-nbt` | ❌ | ❌ | ❌ | ❌ |
| `--extension <source>`, `-e` | ✅ Agent Deck bridges/commands | ✅ Agent Deck bridges; ◐ agent/supervisor extensions | ❌ | ❌ |
| `--no-extensions`, `-ne` | ✅ | ✅ | ✅ | ✅ |
| `--skill <path>` | ◐ Default + current Project skill assignments | ◐ agent-assigned skills | ❌ | ❌ |
| `--no-skills`, `-ns` | ✅ | ✅ | ✅ | ✅ |
| `--prompt-template <path>` | ◐ Default + current Project prompt assignments | ❌ | ❌ | ❌ |
| `--no-prompt-templates`, `-np` | ✅ | ✅ | ✅ | ✅ |
| `--theme <path>` | ❌ | ❌ | ❌ | ❌ |
| `--no-themes` | ✅ | ✅ | ✅ | ✅ |
| `--no-context-files`, `-nc` | ❌ | ❌ | ✅ | ✅ |
| `--system-prompt <text-or-path>` | ❌ | ◐ default/replace prompt mode | ✅ | ✅ |
| `--append-system-prompt <text-or-path>` | ◐ native subagent catalog when enabled | ◐ when `systemPromptMode == append` | ❌ | ❌ |
| `--verbose` | ❌ | ❌ | ❌ | ❌ |
| `--offline` | ❌ | ❌ | ❌ | ❌ |
| `--help`, `-h` | ❌ | ❌ | ❌ | ❌ |
| `--version`, `-v` | ❌ | ❌ | ❌ | ❌ |
| `--list-models [search]` | ❌ | ❌ | ❌ | ❌ |
| `--export <in> [out]` | ❌ | ❌ | ❌ | ❌ |
| `--print`, `-p` | ❌ | ❌ | ❌ | ❌ |
| `@file` args | ❌ | ❌ | ❌ | ❌ |
| Positional initial messages | ❌ | ❌ | ❌ | ❌ |
| Extension-defined unknown flags | ❌ | ❌ | ❌ | ❌ |

## What each subprocess can receive

| Resource/context | Parent session | Native subagent | Title helper | Commit helper |
|---|---|---|---|---|
| User prompt content | Yes, via RPC prompt/steer/follow-up | Yes, concrete task via RPC prompt | First message only, capped at 2,000 chars | Git status + staged diff/stat, diff capped at 12,000 chars |
| Images | Yes, via RPC payload | No dedicated launch-path image handling currently | No | No |
| Parent conversation history | Yes, when resuming `--session` | No; continuations receive only prior child-session history | No | No |
| Persistent Pi session | Yes unless not yet created/resumed | Yes, under run artifact session dir; continuations resume by `--session` | No, `--no-session` | No, `--no-session` |
| Built-in tools | Yes, normal Pi behavior | Yes unless `tools:` absent? If `tools:` is absent, Pi default tools apply; if present, allowlist or `--no-tools` applies. | No | No |
| Extension tools/commands | Explicit Agent Deck extensions only | Explicit child/agent/Agent Deck extensions only | No | No |
| Ambient extension discovery | No | No | No | No |
| Project/global context files | Yes | Yes | No | No |
| Ambient skills | No; disabled with `--no-skills` | No; disabled with `--no-skills` | No | No |
| Native explicit skills | Default + current Project assignments via `--skill` | Agent-assigned skills via `--skill` | No | No |
| Prompt templates | Default + current Project assignments via `--prompt-template` | No | No | No |
| Themes | No, disabled with `--no-themes` | No, disabled with `--no-themes` | No, disabled with `--no-themes` | No, disabled with `--no-themes` |
| Agent Deck `.env` values | Yes | Yes | Caller-supplied | Caller-supplied |
| Raw generated system prompt in process args | Native catalog append may be raw text | Yes for child system prompt | Yes | Yes |

## Findings and recommendations

1. **Documented current behavior is mostly coherent.** Parent sessions are intentionally normal Pi sessions with explicit Agent Deck extensions; helper sessions are intentionally isolated; native subagents are stricter but configurable.
2. **Native subagent continuation is explicit.** Fresh runs do not receive parent history; direct follow-ups resume the prior child session by Subagent ID and update the same card.
3. **Native subagent prompt text is exposed in process arguments.** Since Agent Deck already writes `system-prompt.md`, prefer passing `--system-prompt <path-to-system-prompt.md>` / `--append-system-prompt <path>` if Pi's path detection semantics are acceptable for all generated prompts.
4. **Helper and child launches do not set offline/version-check behavior.** Consider `--offline` or env vars `PI_OFFLINE=1`, `PI_SKIP_VERSION_CHECK=1` for privacy-sensitive helper/child subprocesses, while checking whether this changes extension/package behavior.
5. **Commit-message helper disclosure should be clearer.** Shipping UI should state that staged status/diff content is sent to the selected model to generate the commit message.
6. **Skill and prompt-template injection are app-controlled.** Parent sessions disable ambient discovery and pass only assigned skills/templates through native `--skill` and `--prompt-template` arguments. Native subagents receive assigned skills only and always disable prompt templates.
7. **Theme loading is disabled everywhere.** All Agent Deck RPC launches pass `--no-themes` because terminal themes are not needed in app-owned Pi subprocesses.

## Verification checklist

This map was checked three ways:

1. **Call-site scan:** `rg "PiRPCClient\\(" agent-deck` returns exactly the four production launch sites listed above.
2. **Argument assembly scan:** `PiRPCClient.launchArguments` was checked to confirm global `--mode rpc` and ordering of `extraArguments`, `--session`, `--provider`, `--model`, and `--thinking`.
3. **Pi parser/runtime scan:** Pi `dist/cli/args.js`, `dist/main.js`, `docs/rpc.md`, and `docs/usage.md` were checked for accepted flags, fork conflicts, RPC `@file` rejection, and `--offline` behavior.
