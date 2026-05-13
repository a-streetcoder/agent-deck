# Agent Deck System Prompt Logic

This is the canonical Agent Deck prompt-context reference for LLMs and maintainers.

Agent Deck does not reimplement Pi's prompt builder. It launches the installed `pi` CLI in RPC mode, manages app-owned resources, and passes explicit CLI flags where the app needs deterministic behavior. The final system prompt is still assembled by Pi.

Last checked against the installed Pi CLI `0.74.0` and Agent Deck source on 2026-05-11.

Primary source files:

- `agent-deck/PiAgentRunnerService.swift` - parent Pi Agent launch flags and append preservation.
- `agent-deck/PiSubagentRunService.swift` - native subagent child prompt and launch flags.
- `agent-deck/PiRPCClient.swift` - shared `pi --mode rpc` argument construction.
- `agent-deck/ProjectViews.swift` - Projects view instruction inspector and prompt preview.
- `agent-deck/PiSkillLaunchResolver.swift` - explicit parent/child skill launch arguments.

## Pi Assembly Order

For a normal Pi session, Pi builds the effective system prompt in this order:

1. **Base system prompt**
   - `--system-prompt <text-or-existing-file-path>`, if supplied.
   - Else `<cwd>/.pi/SYSTEM.md`, if present.
   - Else `~/.pi/agent/SYSTEM.md`, if present.
   - Else Pi's built-in default system prompt.
2. **Tool-aware built-in guidance**
   - When Pi uses its built-in default prompt, the prompt includes an `Available tools` section.
   - Active tools can contribute tool-specific snippets and guidelines.
   - The built-in prompt also includes Pi documentation guidance.
   - If a custom base prompt is used, Pi does not prepend the built-in default prompt.
3. **Append system prompt text**
   - All explicit `--append-system-prompt <text-or-existing-file-path>` values, in flag order, joined by blank lines.
   - Else `<cwd>/.pi/APPEND_SYSTEM.md`, if present.
   - Else `~/.pi/agent/APPEND_SYSTEM.md`, if present.
4. **Context files**
   - First one global file from `~/.pi/agent/`: `AGENTS.md`, `AGENTS.MD`, `CLAUDE.md`, or `CLAUDE.MD`.
   - Then one file per ancestor/current directory, walking from filesystem root to `<cwd>`.
   - In each directory Pi uses the first existing candidate in this order: `AGENTS.md`, `AGENTS.MD`, `CLAUDE.md`, `CLAUDE.MD`.
   - Pi de-dupes by exact path, not by file identity.
5. **Skill catalog**
   - Appended only for loaded skills when skills are enabled and the `read` tool is available.
   - The prompt contains skill names, descriptions, and file locations. It does not paste full skill bodies.
6. **Runtime footer**
   - Current date.
   - Current working directory.

`SYSTEM.md` and `APPEND_SYSTEM.md` are not ancestor-walked. Only context files are ancestor-walked.

## Important Pi Flag Semantics

`--system-prompt` replaces the base prompt only. Context files, skills, date, and working directory can still append unless separately disabled.

`--append-system-prompt` is repeatable. If any explicit append value is supplied, Pi does not auto-discover `APPEND_SYSTEM.md`; the explicit append list becomes the append source.

`--no-context-files` disables `AGENTS.md`/`CLAUDE.md` discovery.

`--no-skills` disables ambient skill discovery, but explicit `--skill <path>` arguments are still honored by Pi.

`--no-prompt-templates` disables ambient prompt-template discovery, but explicit prompt-template arguments can still be loaded.

`--no-extensions` disables ambient extension discovery, but explicit `--extension <path>` arguments are still loaded.

## Parent Agent Deck Sessions

Parent Pi Agent sessions are the main chat sessions in Agent Deck.

Agent Deck launches them as normal Pi RPC sessions with controlled app resources:

```text
pi --mode rpc
  --no-extensions
  --extension <system-prompt-audit-bridge.ts>
  --extension <agent-deck-ask-user-bridge.ts>
  --extension <agent-deck-web-access.ts>
  --extension <agent-deck-openai-fast.ts>
  --extension <enabled command extension>...
  [--extension <managed-subagent-bridge.ts>]
  [--append-system-prompt <active APPEND_SYSTEM.md path>]
  [--append-system-prompt <native subagent catalog prompt>]
  --no-skills
  [--skill <default-or-project-assigned-skill>]...
  --no-prompt-templates
  [--prompt-template <default-or-project-assigned-template>]...
  --no-themes
  [--session <existing Pi session file>]
  [--provider <provider>]
  [--model <model>]
  [--thinking <level>]
```

Parent sessions intentionally do **not** pass `--system-prompt`. Pi still chooses the base prompt from project `.pi/SYSTEM.md`, global `SYSTEM.md`, or the built-in prompt.

Parent sessions intentionally do **not** pass `--no-context-files`. Pi still loads global, ancestor, and project `AGENTS.md`/`CLAUDE.md` context.

Parent sessions pass `--no-skills` and then only Agent Deck's assigned skills. This prevents ambient skill discovery while preserving explicit Default and current Project skill assignments.

Parent sessions pass `--no-prompt-templates` and then only Agent Deck's assigned prompt templates.

Parent sessions pass `--no-extensions` and then only Agent Deck-controlled extensions. This avoids unexpected ambient extensions while keeping app bridge tools available.

### Parent Append Preservation

When native subagents are enabled, Agent Deck adds a generated native subagent catalog to the parent prompt with `--append-system-prompt`.

Because any explicit append flag suppresses Pi's automatic `APPEND_SYSTEM.md` discovery, Agent Deck first resolves the append file Pi would have used:

1. `<project>/.pi/APPEND_SYSTEM.md`
2. else `~/.pi/agent/APPEND_SYSTEM.md`
3. else no append file

If such a file exists, Agent Deck passes it as the first explicit `--append-system-prompt`, then passes the native subagent catalog as the second explicit append. The effective append order is therefore:

```text
active APPEND_SYSTEM.md content

Agent Deck native subagent catalog
```

This preserves Pi behavior while adding Agent Deck's parent bridge instructions.

## Native Subagent Child Sessions

Native subagents are separate child `pi --mode rpc` processes owned by Agent Deck. They are not text-only slash commands inserted into the parent chat.

For each run, Agent Deck creates an artifact directory under:

```text
~/Library/Application Support/Agent Deck/Subagent Runs/<run-id>/
```

Agent Deck writes at least:

- `system-prompt.md`
- `input.md`
- `output.md`
- child session files under `sessions/`

The child prompt is split deliberately:

- **System prompt content:** agent Markdown body followed by common child-session boundary instructions. The common boundary avoids defining the agent role; role identity belongs in the agent body.
- **User task prompt:** concrete task, expected outcome, artifact directory, and read-first hints. Continuation prompts also state that prior child messages are available but the new task is authoritative.

Default child launch shape:

```text
pi --mode rpc
  --session-dir <artifact-dir>/sessions
  --system-prompt <agent prompt + common child-session boundary>
  --append-system-prompt ""
  # or only --append-system-prompt <agent prompt + common child-session boundary> when systemPromptMode: append
  [--tools <agent tool allowlist> | --no-tools]
  --no-extensions
  [--extension <agent-configured extension>]...
  [--extension <contact-supervisor-bridge.ts>]
  --extension <agent-deck-web-access.ts>
  --extension <agent-deck-openai-fast.ts>
  --extension <system-prompt-audit-bridge.ts>
  --no-skills
  [--skill <agent-assigned-skill>]...
  --no-prompt-templates
  --no-themes
  [--provider <provider>]
  [--model <model[:thinking]>]
```

If `systemPromptMode` is absent or `replace`, Agent Deck uses `--system-prompt`. This replaces Pi's base prompt, but Pi may still append context files, explicit skills, date, and cwd unless disabled.

Replace-mode native subagents also pass `--append-system-prompt ""`. This is intentional: in Pi, any explicit append value suppresses automatic `APPEND_SYSTEM.md` discovery. The empty append keeps project/global `APPEND_SYSTEM.md` out of native child prompts while preserving Pi's later context-file, explicit-skill, date, and cwd footer behavior.

If `systemPromptMode: append`, Agent Deck uses `--append-system-prompt`. In that mode Pi keeps its normal base prompt selection and appends the agent prompt.

Native subagents use normal Pi project context-file discovery. Agent Deck does not pass `--no-context-files` for child sessions.

Direct follow-ups can continue a prior native subagent by Subagent ID. Continuation launches use `--session <prior-child-session-file>` instead of `--session-dir` and update the same parent chat card.

Native subagents always pass `--no-skills` and then explicit `--skill` arguments for skills assigned to that agent. They do not inherit parent Default or Project skills automatically, and they do not use ambient skill discovery.

Native subagents always pass `--no-prompt-templates` and `--no-themes`.

Native subagents disable ambient extensions with `--no-extensions` and load only configured extensions plus required Agent Deck bridge extensions.

Read-first files are hints in the user task prompt. Agent Deck does not inject current file contents into the system prompt.

## Helper Sessions

Agent Deck helper sessions are intentionally isolated.

Session title generation and commit-message generation use `--system-prompt` with a helper-specific prompt and also pass:

```text
--no-session
--no-extensions
--no-skills
--no-tools
--no-context-files
--no-prompt-templates
--no-themes
--append-system-prompt ""
```

They do not receive project context files, skills, prompt templates, extensions, tools, or project/global `APPEND_SYSTEM.md` content.

## Projects View Preview

The Projects view instruction inspector edits file-backed prompt sources:

- project `.pi/SYSTEM.md`
- global `~/.pi/agent/SYSTEM.md`
- project `.pi/APPEND_SYSTEM.md`
- global `~/.pi/agent/APPEND_SYSTEM.md`
- global, ancestor, and project `AGENTS.md`/`CLAUDE.md` context files

Selecting a project in Projects view changes only the inspector target. It does not change the active project used for new sessions.

The preview approximates Pi's prompt from current editor drafts:

1. active base prompt file, or built-in placeholder
2. active append prompt file
3. native subagent catalog placeholder when enabled
4. active context files in Pi order
5. skill catalog placeholder
6. current date and cwd

The preview cannot know every runtime-generated string. It uses placeholders for Pi's built-in prompt, tool-aware guidance, extension prompt changes, and skill catalog where Agent Deck cannot deterministically reproduce Pi's exact runtime text.

## Debugging Rule

When explaining or debugging prompt behavior, separate these layers:

- Pi core prompt assembly.
- Agent Deck parent-session launch flags.
- Agent Deck resource assignment for skills, prompt templates, and extensions.
- Agent Deck native subagent child launch flags.
- Helper-session isolation.

Do not assume that a resource being visible in Agent Deck means Pi receives it. Runtime injection depends on the launch path and explicit flags above.
