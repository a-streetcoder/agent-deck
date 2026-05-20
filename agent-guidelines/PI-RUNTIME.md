# Pi Runtime Integration

## Core Principle: Explicit Allowlists

Agent Deck NEVER relies on Pi's ambient resource discovery. Every launch uses `--no-extensions`, `--no-skills`, `--no-prompt-templates`, `--no-themes` and then explicitly adds only the resources Agent Deck has vetted and assigned.

This pattern applies to ALL four launch paths: parent sessions, native subagents, title helpers, and commit helpers.

## Launch Paths

### Parent sessions
- Let Pi choose the base prompt (no `--system-prompt`).
- Load context files normally (no `--no-context-files`).
- Selectively re-enable assigned skills, extensions, prompt templates, and themes.
- Always pass `--no-skills`, `--no-prompt-templates`, `--no-extensions`, `--no-themes` first.

### Native subagents
- Use `--mode rpc` via `PiRPCClient.launchArguments`.
- `replace` mode (default): `--system-prompt` + `--append-system-prompt ""` to suppress auto-discovery.
- `append` mode: only `--append-system-prompt` with the subagent catalog.
- Preserve the active `APPEND_SYSTEM.md` file before injecting the subagent catalog, because any explicit `--append-system-prompt` suppresses Pi's automatic `APPEND_SYSTEM.md` discovery.
- Subagents do NOT receive parent conversation history. Fresh runs start blank.
- Never use `--fork`, `--continue`, or `--resume` for subagents.

### Helper sessions (title generation, commit messages)
- Maximally isolated: `--no-session --no-tools --no-extensions --no-skills --no-context-files --no-prompt-templates --no-themes --append-system-prompt ""`.

## System Prompt Assembly

Pi assembles prompts in this order: base → tool-aware guidance → append → context files (ancestor-walked) → skill catalog → runtime footer.

`SYSTEM.md` and `APPEND_SYSTEM.md` are NOT ancestor-walked — they are single-file.

Any explicit `--append-system-prompt` value (even empty string `""`) suppresses Pi's automatic `APPEND_SYSTEM.md` discovery. Agent Deck must manually re-pass the file content to preserve behavior.

## Skills

- A skill being discovered by Agent Deck does NOT mean it is injected into Pi.
- Agent Deck always uses `--no-skills` then passes only assigned skills via `--skill <path>`.
- Three assignment types: Default (all parent sessions), Project (parent sessions for one project), Agent (one specific native subagent).
- Native subagents receive only their own explicitly assigned skills — they do NOT inherit Default or Project skills.
- Helper sessions never receive skills.
- Agent Deck does NOT silently add `read` to tool allowlists. If an agent has assigned skills but its tool allowlist lacks `read`, the launch is blocked.
- Duplicate skill names are an error — Agent Deck never silently picks a winner.

## Memory

- Memory is project-scoped only — no global memory. No project path → no recall, writes rejected.
- Only `active` and `pinned` memories are injected into sessions.
- Memory is recalled at launch, not every turn.
- Injected memory is context, not instructions — prefer current repository contents over memory.
- Never store: temporary task state, speculative facts, raw logs, customer data, secrets, tokens, or private keys.
- Secret scanning blocks writes containing private keys, tokens, or credentials.
- Markdown files are the source of truth; `index.sqlite` is a derived cache that can always be rebuilt.
- Memory types: `context`, `decision`, `runbook`, `failure`, `preference`.

## Model and Thinking Configuration

- Model and thinking level are **launch configuration**, not runtime mutation. Prefer `--provider`, `--model`, `--thinking` flags over RPC commands.
- Override fields win over reported fields: `modelOverrideProvider` > `modelProvider`, `modelOverrideID` > `model`.
- `none` thinking level is normalized to `off`.
- Unsupported thinking levels are rejected (not applied, session error recorded).
- During active streaming, model/thinking changes are queued for the next prompt — never interrupt a running session.
- The global `pi --list-models` catalog is the source of truth for UI model choices, not querying running RPC sessions.
- Title generation uses launch-time config, not mutation RPCs.

For full details, see:
- `agent-deck-documentation/agent-deck-system-prompt-logic.md`
- `agent-deck-documentation/pi-rpc-launch-flags.md`
- `agent-deck-documentation/skills-logic.md`
- `agent-deck-documentation/memory.md`
- `agent-deck-documentation/model-and-thinking-logic.md`