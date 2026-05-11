---
name: prompt-authoring
description: Create or improve Agent Deck/Pi prompt templates for reusable parent-session workflows.
---

# Prompt authoring

Use this skill when the user wants a reusable slash prompt, workflow shortcut, or project/global prompt template for parent Pi Agent sessions.

## Runtime facts

- Prompt templates are Markdown files that expand when the user types `/name` in a parent Pi session.
- The filename is the invocation name: `review-staged.md` becomes `/review-staged`.
- Prompt templates are user-message macros, not system prompts and not skills.
- Agent Deck scans prompt templates into a catalog.
- Agent Deck parent sessions launch with `--no-prompt-templates` and pass only assigned templates with explicit `--prompt-template <path>` flags.
- Native subagents do not receive prompt templates.

## Locations

Create reusable catalog prompts in Agent Deck's prompt library unless the user asks for a specific project-local file:

```text
~/.pi/agent/prompt-library/<name>.md
```

Project-local source prompts may live at:

```text
<project>/.pi/prompts/<name>.md
```

Global/default and project availability are Agent Deck assignments. Do not rely on ambient Pi prompt discovery.

## Format

Use Markdown with optional frontmatter:

```md
---
description: Short autocomplete description
argument-hint: "[optional-focus]"
---

Prompt body here.
```

Rules:

- Keep the description short and user-facing.
- Use `argument-hint` only when arguments are expected.
- If no arguments are needed, omit `argument-hint` and do not include placeholders.
- Make the body complete enough to be useful after expansion.
- Avoid hidden, broad, or permanent behavioral instructions; templates are one-shot user prompts.

## Arguments

Supported placeholders:

```text
$1, $2, ...        positional arguments
$@                 all arguments joined
$ARGUMENTS         all arguments joined
${@:N}             arguments from N onward, 1-indexed
${@:N:L}           L arguments starting at N
```

Examples:

```md
---
description: Review a target with an optional focus
argument-hint: "<target> [focus]"
---

Review $1.

Focus on: ${@:2}
```

No-argument template:

```md
---
description: Review staged git changes
---

Review the staged git changes with `git diff --cached`.

Focus on:
- bugs
- regressions
- missing tests
```

## Authoring workflow

1. Choose a short kebab-case filename/invocation.
2. Decide whether the prompt needs arguments.
3. Write concise frontmatter.
4. Write a clear, self-contained prompt body.
5. Save it to the requested prompt catalog/source location.
6. Tell the user the invocation, file path, whether it expects arguments, and whether it still needs Default or Project assignment in Agent Deck.
