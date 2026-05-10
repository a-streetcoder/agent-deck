# Prompts and Commands

Pi uses `/...` for several different things. They share a slash-shaped namespace, but they do different work.

## What Pi means by “command”

Pi's own documentation uses **command** for more than one concept:

1. **Built-in interactive commands** — terminal UI actions such as `/settings`, `/model`, `/tree`, `/reload`, and `/quit`.
2. **Extension commands** — TypeScript/JavaScript handlers registered by extensions with `pi.registerCommand(...)`.
3. **Prompt templates** — Markdown files such as `review.md` that expand when invoked as `/review`.
4. **Skill commands** — skill invocations such as `/skill:apple-documentation`.
5. **RPC commands** — JSON protocol operations such as `{ "type": "get_commands" }`; these are API calls, not slash commands.

Pi RPC `get_commands` only returns slash entries that can be invoked through RPC `prompt`: extension commands, prompt templates, and skill commands. It does **not** return built-in interactive commands.

## Built-in Pi commands

Built-in commands are Pi app actions such as settings, model switching, reload, compact, tree/session navigation, quit, and export.

Agent Deck does not show these as editable resources. Pi RPC `get_commands` does not list built-in commands.

## Extension commands

Extensions and packages can register runtime slash commands. These are real actions handled by extension code, not Markdown prompt text.

When a prompt starts with `/`, Pi first checks whether it matches a registered extension command. If it does, Pi runs the command handler inside the current session and does not send the slash text as a normal model prompt. This applies in RPC sessions too because RPC `prompt` calls go through the same `AgentSession.prompt` path.

Agent Deck discovers these with Pi RPC `get_commands` entries whose source is `extension`. They are best treated as runtime actions provided by extensions/packages.

Agent Deck also ships selected app-bundled extension commands in Settings → Commands, such as `/optimize-agents-md` for creating or replacing a concise optimized `AGENTS.md` and `/create-agent-deck-command` for creating Agent Deck slash command extensions. Enabled bundled or imported commands are passed to parent Pi sessions as explicit `--extension` arguments while ambient extension discovery remains disabled.

Because extension commands are code, their usefulness depends on what the handler does:

- commands that send messages, inspect state, reload resources, or start workflows can work well in RPC
- commands that mainly open terminal UI, custom TUI components, or editor interactions may be useless or only partially useful in Agent Deck
- Agent Deck ignores these commands in the main resource sidebar and avoids loading discovered extensions in managed/background RPC sessions by launching Pi with `--no-extensions`

## Prompt templates

Prompt templates are Markdown files that expand into prompt text. A file named `review.md` becomes `/review`.

Locations:

- global: `~/.pi/agent/prompts/*.md`
- project: `PROJECT/.pi/prompts/*.md`
- packages: `prompts/` or package manifest entries
- settings: `settings.json -> prompts`
- CLI: `--prompt-template <path>`
- disabled at runtime with `--no-prompt-templates`

Agent Deck also has a prompt library at `~/.pi/agent/prompt-library/*.md` for reusable templates it can manage. Library prompts are an Agent Deck resource-management layer; Pi only uses prompt locations that are active through standard directories, settings, packages, or CLI flags.

Standard `prompts/` directories are non-recursive unless additional paths are configured. Agent Deck can scan configured/runtime-known prompt locations, but it cannot infer one-off CLI-only choices such as a `--prompt-template` path or `--no-prompt-templates` flag used outside the app.

## Prompt template frontmatter

Common fields:

```yaml
---
description: Review staged git changes
argument-hint: "<focus>"
---
```

The body can use Pi prompt-template argument syntax:

- `$1`, `$2`, ... for positional arguments
- `$@` or `$ARGUMENTS` for all arguments
- `${@:N}` for arguments from position `N`
- `${@:N:L}` for `L` arguments from position `N`

## Skill commands

If Pi skill commands are enabled, skills can be invoked as `/skill:name`. Pi expands the skill content into the prompt. Agent Deck keeps skills primarily in the Skills section to avoid duplicating resource ownership.

## Resolution order

For a slash-prefixed input, Pi's session path handles resources in this practical order:

1. extension command, if one matches
2. extension input hooks
3. skill command expansion, such as `/skill:name`
4. prompt template expansion, such as `/review`
5. otherwise, the text remains a normal prompt

This means an extension command with the same name as a prompt template wins.

## Agent Deck sidebar meaning

In Agent Deck:

- **Prompts** are file-backed Markdown prompt templates.
- **Skills** are shown in the Skills section, even though Pi can expose them as `/skill:name`.
- Extension slash commands are managed in Settings → Commands when bundled with or imported into Agent Deck; ambient discovered extensions stay disabled in managed sessions.
- macOS menu commands such as New Session, Refresh, and Push Branch are Agent Deck app commands, not Pi slash commands.
