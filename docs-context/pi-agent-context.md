# Upstream Pi Coding Agent context for pi-manager integration

Upstream inspected: `/Users/andrea.corvi/.nvm/versions/node/v22.16.0/lib/node_modules/@mariozechner/pi-coding-agent` (`@mariozechner/pi-coding-agent` v0.73.0; `package.json`). This is a Node ESM package exposing CLI bin `pi -> dist/cli.js` and types through `dist/index.d.ts`.

## High-value architecture map

### Config roots and project/global split

- Upstream config dir is derived from `piConfig.configDir` (`.pi`) and defaults to `~/.pi/agent` unless `PI_CODING_AGENT_DIR` is set: `dist/config.js:312-339`.
- Important global files/dirs are hard-coded helpers: `models.json`, `auth.json`, `settings.json`, `prompts/`, `sessions/`, `themes/` under agent dir: `dist/config.js:346-371`.
- Project settings live at `.pi/settings.json`; docs say project settings override global settings and nested objects merge: `docs/settings.md`.
- pi-manager currently scans many matching paths in `PiScanner.swift:6-27`, including `~/.pi/agent/settings.json`, `.pi/settings.json`, global/project prompts/skills, and `~/.pi/agent/extensions/subagent/config.json`.

### CLI modes and options relevant to embedding

- CLI parsing is in `dist/cli/args.js:10+`. Relevant accepted flags include:
  - modes: `--mode text|json|rpc`, `--print/-p`, `--export`
  - sessions: `--continue/-c`, `--resume/-r`, `--session`, `--fork`, `--session-dir`, `--no-session`
  - models: `--provider`, `--model`, `--api-key`, `--thinking`, `--models`, `--list-models`
  - resources: `--extension/-e`, `--no-extensions/-ne`, `--skill`, `--prompt-template`, `--theme`, `--no-*`
  - tools: `--tools/-t`, `--no-builtin-tools/-nbt`, `--no-tools/-nt`
- `docs/usage.md` has the user-facing CLI reference and slash command list.
- pi-manager embeds via RPC: `PiRPCClient.swift:16-51` launches `pi --mode rpc` plus optional `--session`, provider/model args, and extra args.
- pi-manager resolves `pi` via env (`PI_MANAGER_PI_PATH`/`PI_CLI_PATH`), shell `command -v pi`, then common candidates including NVM versions: `PiAgentProcess.swift:117-184`.

### RPC mode: best integration surface for UI

- RPC protocol is JSONL over stdin/stdout; strict LF framing is documented in `docs/rpc.md`.
- pi-manager already sends RPC commands for state/messages/stats/models, abort, session name, model/thinking switches, compact, prompt/steer/follow_up, and extension UI responses: `PiRPCClient.swift:53-108`.
- Key RPC commands from docs:
  - `get_state` returns model, thinking level, session file/id/name, streaming/compaction status, message counts: `docs/rpc.md` State section.
  - `get_messages` returns `AgentMessage[]`.
  - `set_model`, `cycle_model`, `get_available_models`: `docs/rpc.md:216-270`.
  - `get_commands` returns extension commands, prompt templates, and skills invokable via `/...`: `docs/rpc.md:701-715`.
  - Extension UI emits `extension_ui_request` and expects `extension_ui_response` for dialogs: `docs/rpc.md:988-1173`.
- pi-manager command discovery probes `pi --mode rpc`, sends `get_commands`, and filters to `source == "extension"`: `PiScanner.swift:320-405`.

## Sessions

- Default storage: `~/.pi/agent/sessions/--<cwd-with-separators-replaced>--/<timestamp>_<uuid>.jsonl`; docs: `docs/sessions.md`, `docs/session-format.md`.
- Session files are JSONL. First line is `{type:"session", version:3, id, timestamp, cwd, parentSession?}`. Entries form a tree using `id` and `parentId`.
- Current session version is 3. v1/v2 are auto-migrated; v3 renamed extension `hookMessage` role to `custom`: `dist/core/session-manager.d.ts:1-103`, implementation in `dist/core/session-manager.js:1-80`.
- Important entry/message types in `dist/core/session-manager.d.ts`:
  - `SessionMessageEntry` (`type:"message"`, `message: AgentMessage`)
  - `thinking_level_change`, `model_change`
  - `compaction`, `branch_summary`
  - extension persistence: `custom` and `custom_message`
  - labels (`label`) and display name (`session_info`)
- `buildSessionContext()` walks the tree from leaf to root and handles compaction/branch summaries: `dist/core/session-manager.d.ts:111-121`, implementation `dist/core/session-manager.js:88-185`.
- Session commands: `/resume`, `/new`, `/name`, `/session`, `/tree`, `/fork`, `/clone`, `/compact`, `/export`, `/share`: `docs/sessions.md` and `dist/core/slash-commands.js:2-25`.

Integration implications:
- Prefer RPC `get_state`/`get_messages` for live UI instead of parsing raw files, but raw JSONL parsing is feasible with the documented v3 format.
- `--session-dir` is a supported override; pi-manager subagent runs already pass an artifact session dir in `PiSubagentRunService.swift:49`.
- For deletion/renaming UI, upstream supports file deletion and `session_info` entries; deleting `.jsonl` files is documented.

## Settings

- Settings type is defined in `dist/core/settings-manager.d.ts:57-94`.
- Main user-facing settings are documented in `docs/settings.md`:
  - model/thinking: `defaultProvider`, `defaultModel`, `defaultThinkingLevel`, `thinkingBudgets`, `hideThinkingBlock`
  - UI: `theme`, `quietStartup`, `doubleEscapeAction`, `treeFilterMode`, editor/autocomplete/cursor settings
  - sessions: `sessionDir`; precedence is `--session-dir`, `PI_CODING_AGENT_SESSION_DIR`, then `sessionDir`
  - resources: `packages`, `extensions`, `skills`, `prompts`, `themes`, `enableSkillCommands`
  - retry, compaction, branch summary, terminal/images, shell/npm command, telemetry/update checks
- Paths in global settings resolve relative to `~/.pi/agent`; paths in project settings resolve relative to `.pi`; absolute and `~` supported: `docs/settings.md` Resources section.
- Arrays support globs/exclusions and special exact modifiers `+path` and `-path`; `!pattern` excludes: `docs/settings.md` Resources section.
- pi-manager currently parses only packages/prompts and custom `subagents` override fields from settings: `PiScanner.swift:696-721`. This means many upstream settings (theme, enabledModels, sessionDir, extensions/skills/themes arrays) may not be represented in scanner snapshots unless separately handled.

## Providers and models

- Auth:
  - Subscription OAuth and API-key login use `/login`; credentials stored in `~/.pi/agent/auth.json`: `docs/providers.md`.
  - API key env var/auth-file mapping is documented in `docs/providers.md`.
  - Auth-file credentials take priority over env vars; auth file mode is `0600`.
- Custom models:
  - Custom provider/model config lives in `~/.pi/agent/models.json`: `docs/models.md`.
  - Schema and validation live in `dist/core/model-registry.js:101-148`; `ModelRegistry.create()` defaults to `join(getAgentDir(), "models.json")`: `dist/core/model-registry.js:241`.
  - Supported custom APIs: `openai-completions`, `openai-responses`, `anthropic-messages`, `google-generative-ai`.
  - Provider config fields: `baseUrl`, `api`, `apiKey`, `headers`, `authHeader`, `models`, `modelOverrides`; model config includes `id`, `name`, `reasoning`, `input`, `contextWindow`, `maxTokens`, `cost`, `compat`, `thinkingLevelMap`.
  - `apiKey`/headers support literal, env var name, or shell command starting with `!`.
- Resolution:
  - Defaults per built-in provider are in `dist/core/model-resolver.js:10-45`.
  - `--model` supports exact `provider/model`, bare ID (only if unambiguous), fuzzy/partial matching, and optional `:thinking` suffix: `dist/core/model-resolver.js:48-185`.
  - Scoped model patterns for Ctrl+P can use globs and `:thinking`: `dist/core/model-resolver.js:186+`.
- pi-manager model discovery currently calls `pi --list-models` and parses tabular stdout; it also runs a Node script importing pi-ai models from `/opt/homebrew/...`, which is not the inspected NVM install path and is brittle if Homebrew does not provide the package: `PiModelDiscoveryService.swift:10-80`.
- Better integration option: RPC `get_available_models` returns configured models and avoids stdout table parsing: documented in `docs/rpc.md:258-270`; pi-manager already has `PiRPCClient.getAvailableModels()`.

## Extensions, packages, and MCP note

- Upstream extensions are TypeScript/JavaScript modules loaded with jiti; they can register tools, commands, shortcuts, flags, providers, event handlers, custom UI, and persist session entries: `docs/extensions.md`, `dist/core/extensions/types.d.ts`.
- Auto-discovery locations:
  - Global: `~/.pi/agent/extensions/*.ts`, `~/.pi/agent/extensions/*/index.ts`
  - Project: `.pi/extensions/*.ts`, `.pi/extensions/*/index.ts`
  - Additional paths via `settings.json` `extensions` array or `--extension/-e`: `docs/extensions.md`.
- Extension API high-value types:
  - UI context (select/confirm/input/notify/status/widgets/custom components/theme/editor): `dist/core/extensions/types.d.ts:67-205`.
  - Event context with cwd, session manager, model registry/current model, abort/shutdown, context usage, compaction, system prompt: `dist/core/extensions/types.d.ts:207-239`.
  - Command context can start/fork/navigate sessions: `dist/core/extensions/types.d.ts:241+`.
  - Tool execute signature and command registration types are in the same file (`registerTool`, `registerCommand`).
- Packages bundle extensions, skills, prompts, and themes via `package.json` `pi` manifest or conventional dirs (`extensions/`, `skills/`, `prompts/`, `themes/`): `docs/packages.md`.
- Package installation sources: npm, git, local paths. Global installs write `~/.pi/agent/settings.json`; project installs write `.pi/settings.json`; project packages may be installed automatically on startup: `docs/packages.md`.
- pi-manager extension UI/management scans package resources and top-level extension dirs, and writes `extensions` or package filter entries using `+`/`-` modifiers: `ExtensionManagement.swift:47-143`.
- Important MCP fact: upstream Pi intentionally has **no built-in MCP**. `docs/usage.md:273-275` states MCP, sub-agents, permission popups, plan mode, todos, and background bash are intentionally not built-in and should be implemented as extensions/packages or external tools. pi-manager’s `mcpDirectTools` and `~/.pi/agent/extensions/subagent/config.json` are therefore pi-manager/subagent-extension concepts, not upstream core MCP facilities.

## Prompts/templates, skills, and commands

- Prompt templates are Markdown files; filename becomes slash command name (`review.md` -> `/review`): `docs/prompt-templates.md`.
- Prompt locations:
  - global `~/.pi/agent/prompts/*.md`
  - project `.pi/prompts/*.md`
  - packages (`prompts/` or `pi.prompts`)
  - settings `prompts` array
  - CLI `--prompt-template <path>`
- Frontmatter supports `description` and `argument-hint`; body supports `$1`, `$@`, `$ARGUMENTS`, `${@:N}`, `${@:N:L}` substitution: `docs/prompt-templates.md`.
- Discovery in `prompts/` is non-recursive unless paths are explicitly added.
- pi-manager scans global/project prompt dirs, settings prompt paths, package prompt locations, library prompts, dedupes duplicate names, and records warnings: `PiScanner.swift:454-550` and duplicate warning around `PiScanner.swift:924`.
- Built-in slash commands are listed in `dist/core/slash-commands.js:2-25` and docs `docs/usage.md`. Extensions add commands via `pi.registerCommand`; skills become `/skill:name` if `enableSkillCommands` is true; prompt templates expand as slash commands.
- RPC `get_commands` is the authoritative runtime inventory for extension commands, prompt templates, and skills: `docs/rpc.md:701-715`.

## Themes and TUI concepts

- Themes are JSON files defining all required color tokens; built-ins are `dark` and `light`: `docs/themes.md`.
- Theme locations:
  - built-in `dark`, `light`
  - global `~/.pi/agent/themes/*.json`
  - project `.pi/themes/*.json`
  - packages (`themes/` or `pi.themes`)
  - settings `themes` array
  - CLI `--theme <path>`
- `settings.json` key `theme` selects active theme. Custom active theme hot-reloads when edited: `docs/themes.md`.
- TUI layout: startup header, messages, editor, footer; editor can be replaced by `/settings` or extension UI: `docs/usage.md` Interactive Mode.
- TUI component interface is `render(width): string[]`, optional `handleInput`, optional key release, `invalidate`; line length must not exceed width: `docs/tui.md`.
- Keybindings are configurable in `~/.pi/agent/keybindings.json`; ids are namespaced and `/reload` applies changes: `docs/keybindings.md`.

## Source path quick reference

Upstream docs:
- `docs/usage.md` — interactive UI, slash commands, CLI options, explicit no-MCP statement.
- `docs/rpc.md` — JSONL protocol and command/event schemas for embedding.
- `docs/sessions.md`, `docs/session-format.md` — session storage, tree behavior, JSONL format.
- `docs/settings.md` — global/project settings, resource arrays, path semantics.
- `docs/providers.md`, `docs/models.md`, `docs/custom-provider.md` — auth, providers, custom model config.
- `docs/extensions.md`, `docs/packages.md` — extension/package architecture and discovery.
- `docs/prompt-templates.md`, `docs/themes.md`, `docs/tui.md`, `docs/keybindings.md`.

Upstream code/types:
- `dist/config.js:312-371` — config dir/env/files.
- `dist/cli/args.js:10+` — CLI option parser.
- `dist/core/session-manager.d.ts`, `dist/core/session-manager.js` — session entries/API/context building.
- `dist/core/settings-manager.d.ts:57-94` — settings schema.
- `dist/core/model-registry.js:101-148,241` — `models.json` schema and load path.
- `dist/core/model-resolver.js:10-185` — built-in provider defaults and model pattern resolution.
- `dist/core/resource-loader.d.ts:24-150` — resource loader shape and override knobs.
- `dist/core/extensions/types.d.ts` — extension UI/context/tool/command/provider APIs.
- `dist/core/slash-commands.js:2-25` — built-in slash command inventory.

pi-manager references:
- `PiScanner.swift:6-75` — project/global scan roots and runtime command scan call.
- `PiScanner.swift:320-405` — RPC `get_commands` probe.
- `PiScanner.swift:454-550` — prompt template scanning.
- `PiScanner.swift:696-721` — subset of settings parsed.
- `PiRPCClient.swift:16-108` — RPC launch and commands sent.
- `PiAgentProcess.swift:117-184` — executable resolution.
- `PiModelDiscoveryService.swift:10-80` — current `--list-models` parsing and brittle hard-coded Homebrew import.
- `ExtensionManagement.swift:47-143` — extension/package scan and enable/disable settings writes.

## Risks and integration notes

- Do not assume MCP exists upstream; model it as extension/package capability if needed.
- For runtime capabilities, prefer RPC (`get_state`, `get_messages`, `get_available_models`, `get_commands`) over parsing human CLI output or scanning partial settings.
- If pi-manager continues direct model introspection, avoid hard-coded `/opt/homebrew/lib/node_modules/...`; resolve relative to the selected `pi` executable or use RPC.
- Settings parsing in pi-manager is incomplete versus upstream `Settings`; adding UI for themes/extensions/models/sessionDir should use upstream field names and path-resolution rules.
- Resource discovery order and deduping can be subtle because packages, settings arrays, auto dirs, and CLI flags all contribute. RPC `get_commands` and ResourceLoader behavior are the best truth for live resources.
