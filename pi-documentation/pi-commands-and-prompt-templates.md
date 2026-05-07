# Pi Commands and Prompt Templates

This document explains how slash-based invocation works in Pi, especially the difference between:
- built-in commands
- extension commands
- prompt templates
- skill commands

It also explains where prompt templates are stored, how they are loaded, and what they are for.

In Pi Manager, these concepts are surfaced in a dedicated **Prompts** sidebar section:
- extension commands are discovered from Pi's runtime slash-command inventory
- prompt templates are scanned from Pi discovery locations and shown as file-backed resources
- built-in interactive commands are not shown there
- skills remain primarily in the **Skills** section rather than being duplicated here

---

## 1. The important mental model

In Pi, many things start with `/`, but they are not all the same.

A slash entry may be:
- a built-in command
- an extension-provided command
- a prompt template
- a skill invocation

So `/something` does **not** automatically mean “a command” in the traditional sense.

---

## 2. Built-in commands

These are real Pi commands that perform app actions.

Examples:
- `/settings`
- `/model`
- `/reload`
- `/resume`
- `/session`
- `/tree`
- `/fork`
- `/clone`
- `/compact`
- `/quit`

### What they do
Built-in commands typically:
- open UI
- change settings
- switch models
- inspect session state
- create/fork/clone sessions
- reload resources
- quit Pi

### Mental model
Built-in commands are:
- actual application actions
- not just text expansion

---

## 3. Extension-provided commands

Extensions can also register slash commands.

Examples from installed packages may include:
- `/agents`
- `/subagents-status`
- `/websearch`

### What they do
Extension commands can:
- open custom UI
- inspect extension state
- launch workflows
- manage extension resources
- call tools or package logic

### Mental model
These are also real commands/actions, but they are added by extensions rather than Pi core.

---

## 4. Prompt templates

Prompt templates are Markdown snippets that expand into full prompts.

This is an official Pi feature.

### What they are for
Use prompt templates when you want:
- reusable prompt workflows
- common review prompts
- standard task scaffolds
- fast repeatable prompt entry

They are not primarily app commands.
They are reusable prompt content.

### How they are invoked
If you have a file:

`review.md`

then Pi exposes it as:

`/review`

When invoked, Pi expands the file into prompt text.

---

## 5. Prompt template locations

From the Pi docs, prompt templates are loaded from:

### Global
- `~/.pi/agent/prompts/*.md`

### Project
- `.pi/prompts/*.md`

### Packages
- `prompts/` directories inside packages
- or `pi.prompts` entries in `package.json`

### Settings
- `prompts` array with files or directories

### CLI
- `--prompt-template <path>`

### Disable discovery
- `--no-prompt-templates`

---

## 6. Prompt template loading rules

### Non-recursive by default
Prompt discovery in the standard `prompts/` directories is non-recursive.

That means:
- `~/.pi/agent/prompts/review.md` is discovered
- `.pi/prompts/pr.md` is discovered
- nested subfolders inside those directories are **not** auto-discovered by default

If you want nested prompt directories, you must add them explicitly through:
- settings
- or a package manifest

---

## 7. Prompt template format

A prompt template is a Markdown file.

Example:

```md
---
description: Review staged git changes
---
Review the staged changes (`git diff --cached`). Focus on:
- Bugs and logic errors
- Security issues
- Error handling gaps
```

### Frontmatter fields
Common prompt-template frontmatter:
- `description` — optional human-facing description
- `argument-hint` — optional hint shown in autocomplete

If `description` is missing, Pi uses the first non-empty line.

### Filename behavior
The filename becomes the slash name.

Examples:
- `review.md` → `/review`
- `component.md` → `/component`

---

## 8. Prompt template arguments

Prompt templates support simple argument substitution.

Available placeholders include:
- `$1`, `$2`, ... for positional arguments
- `$@` or `$ARGUMENTS` for all arguments joined together
- `${@:N}` for arguments starting at position `N`
- `${@:N:L}` for slices

Example template:

```md
---
description: Create a component
---
Create a React component named $1 with features: $@
```

Usage:

```text
/component Button "onClick handler" "disabled support"
```

---

## 9. `argument-hint`

This helps autocomplete show expected arguments.

Example:

```md
---
description: Review PRs from URLs
argument-hint: "<PR-URL>"
---
Review the PR at $1.
```

Pi can then show a more helpful slash suggestion in the dropdown.

---

## 10. Skills and `/skill:name`

Skills also appear slash-invokable, but they are not the same as prompt templates.

Example:

```text
/skill:apple-documentation
```

### What a skill invocation does
A skill invocation tells Pi to:
- load that skill's content
- make its workflow/instructions available now
- use that capability explicitly

### What a skill is not
A skill invocation is not primarily:
- a UI action
- a settings mutation
- a normal app command

It is a capability/workflow injection.

---

## 11. Commands vs prompt templates vs skills

| Type | Invoked with `/...` | Main purpose | What happens |
|---|---|---|---|
| Built-in command | Yes | App action | Pi performs a built-in operation |
| Extension command | Yes | Extension action | Extension code runs an action/UI/workflow |
| Prompt template | Yes | Reusable prompt text | Markdown template expands into prompt content |
| Skill command | Yes, usually `/skill:name` | Force-load capability/workflow | Skill instructions are loaded for the model |

---

## 12. Concrete examples

### Built-in command
```text
/settings
```
Opens Pi settings UI.

### Extension command
```text
/websearch
```
Runs an extension-provided web search workflow when that extension is enabled.

### Prompt template
If file exists:

`~/.pi/agent/prompts/review.md`

then:

```text
/review
```
expands the template into prompt text.

### Skill command
```text
/skill:apple-documentation
```
loads the Apple documentation skill for immediate use.

---

## 13. Packages and prompt templates

Pi packages can ship prompt templates.

### Package manifest form
A package can declare:

```json
{
  "pi": {
    "prompts": ["./prompts"]
  }
}
```

### Convention form
If a package has a `prompts/` directory, Pi can load `.md` files from there.

This is why some packages include prompts: they are distributing reusable slash-invokable prompt workflows.

---

## 14. What prompt templates are best for

Prompt templates are best for:
- standard code review prompts
- standard research prompts
- repeated task scaffolds
- domain-specific reusable instructions
- lightweight workflow launchers

They are a good fit when you want:
- convenience
- consistency
- repeatability

They are **not** the best fit when you need:
- rich app logic
- interactive UI
- live state changes
- custom runtime orchestration

That is where extension commands are usually better.

---

## 15. Best-practice distinction

### Use a command when you need:
- a real app action
- UI
- state mutation
- package/extension behavior

### Use a prompt template when you need:
- reusable prompt text
- reusable workflow wording
- argument-driven prompt expansion

### Use a skill when you need:
- a reusable capability package
- reference docs/scripts/assets
- domain-specific operating doctrine

---

## 16. Short version

In Pi, slash entries are a family of mechanisms, not one thing.

### Commands
Do something.

### Prompt templates
Expand into reusable prompt text.

### Skills
Load a reusable capability/workflow package.

## Pi Manager notes

The app currently treats slash discovery in two tiers:
- extension commands: queried from Pi runtime command discovery via `get_commands`
- prompt templates: scanned from filesystem/package/settings discovery paths

The app can scan prompt templates from:
- `~/.pi/agent/prompts/`
- `.pi/prompts/`
- settings-defined `prompts` paths
- package prompt locations from `prompts/` and `package.json -> pi.prompts`

The app does **not** infer CLI-only runtime choices like:
- `--prompt-template`
- `--no-prompt-templates`

Prompt templates live in:
- `~/.pi/agent/prompts/`
- `.pi/prompts/`
- package `prompts/`
- settings-defined prompt paths

They are Markdown files, usually with optional frontmatter, and the filename becomes the slash name.
