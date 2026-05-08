# Prompts and Commands

Pi has several slash-prefixed resource types. They look similar in the UI, but they do different things.

## Built-in commands

Built-in commands are Pi application actions, such as session management, settings, model switching, reload, compact, quit, and export. Agent Deck does not treat these as editable prompt templates.

## Extension commands

Extensions can register commands. Agent Deck discovers runtime extension commands through Pi RPC `get_commands` and displays them in the Prompts/Commands area.

## Prompt templates

Prompt templates are Markdown files that expand into prompt text. A file named `review.md` becomes `/review`.

Locations:

- global: `~/.pi/agent/prompts/*.md`
- project: `PROJECT/.pi/prompts/*.md`
- library: `~/.pi/agent/prompt-library/*.md`
- packages: `prompts/` or package manifest entries
- settings: `settings.json -> prompts`
- CLI: `--prompt-template <path>`
- disabled at runtime with `--no-prompt-templates`

Standard `prompts/` directories are non-recursive unless additional paths are configured. Agent Deck can scan configured/runtime-known prompt locations, but it cannot infer one-off CLI-only choices such as a `--prompt-template` path or `--no-prompt-templates` flag used outside the app.

## Prompt template frontmatter

Common fields:

```yaml
---
description: Review staged git changes
argument-hint: "<focus>"
---
```

The body can use Pi prompt-template argument syntax such as `$1`, `$@`, `$ARGUMENTS`, and slice forms.

## Skill commands

If Pi skill commands are enabled, skills may also be invokable from slash syntax. Agent Deck keeps skills primarily in the Skills section to avoid duplicating resource ownership.
