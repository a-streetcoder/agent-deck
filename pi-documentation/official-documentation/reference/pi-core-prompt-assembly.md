# Pi Core Prompt Assembly Reference

Agent Deck is a companion app around Pi. Native sessions and native subagents still run through Pi, so Pi's normal prompt assembly rules matter.

This page summarizes the stable parts of `../pi-core-system-reference-and-subagents.md` from the supporting documentation set and connects them to Agent Deck behavior.

## Normal Pi session order

A normal Pi session builds its effective instruction context in this broad order:

1. **Base prompt source**
   - `--system-prompt <text>` or SDK override, if supplied
   - else `cwd/.pi/SYSTEM.md`
   - else global `~/.pi/agent/SYSTEM.md`
   - else Pi's built-in default prompt
2. **Tool-aware guidance**
   - active tools may add guidance when Pi is using its built-in default prompt
3. **Append system prompt text**
   - `--append-system-prompt <text>` or SDK append(s), if supplied
   - else `cwd/.pi/APPEND_SYSTEM.md`
   - else global `~/.pi/agent/APPEND_SYSTEM.md`
4. **Context files**
   - global `~/.pi/agent/AGENTS.md` or `CLAUDE.md`
   - then ancestor directories and current directory
   - within the same directory, Pi prefers `AGENTS.md` over `CLAUDE.md`
5. **Skills listing**
   - appended when skills are enabled and the `read` tool is available
6. **Date and working directory**

## `SYSTEM.md` vs `AGENTS.md`

- `SYSTEM.md` replaces the base system prompt for a directory.
- `APPEND_SYSTEM.md` appends system-level instructions.
- `AGENTS.md` and `CLAUDE.md` are context files discovered globally and through parent/current directories.

Pi does not walk ancestors for `SYSTEM.md` or `APPEND_SYSTEM.md`; it does walk ancestors for `AGENTS.md`/`CLAUDE.md`.

## Disable flags

Important CLI flags:

- `--no-context-files` disables `AGENTS.md`/`CLAUDE.md` context discovery.
- `--no-skills` disables normal skill discovery, but explicit `--skill <path>` arguments can still load skills.
- `--no-prompt-templates` disables normal prompt-template discovery.

## Agent Deck native subagents

Agent Deck native children follow Pi's model, but the app controls the child launch:

1. Agent Deck creates native boundary instructions, the agent system prompt, and explicit private skill blocks.
2. That content is passed as system prompt content for the child.
3. Expected outcome, read-first paths, artifact directory, and the concrete task are sent as the user task prompt.
4. If `inheritProjectContext` is false, Agent Deck passes `--no-context-files`.
5. If `inheritSkills` is false, Agent Deck passes `--no-skills`.
6. Native child sessions disable ambient extension discovery and load only configured extensions plus app bridge extensions when needed.

## Why this matters

When debugging “why did Pi behave this way?”, separate:

- Pi core instruction assembly
- Agent Deck's scanned resource model
- Agent Deck native subagent run construction
- native child-session behavior
