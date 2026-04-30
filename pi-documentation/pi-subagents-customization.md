# Customizing pi-subagents: Replacing Skills, Agents, and Builtins

pi-subagents has three layers you can customize independently:

1. **The SKILL.md** — orchestration instructions loaded into the parent LLM (teaches pi *how to use* the `subagent()` tool)
2. **The builtin agents** — scout, worker, oracle, planner, reviewer, researcher, context-builder, delegate
3. **Your own agents** — custom agent definitions that coexist with or replace builtins

---

## Disabling All Builtin Agents

In `~/.pi/agent/settings.json` (user scope) or `.pi/settings.json` (project scope):

```json
{
  "subagents": {
    "disableBuiltins": true
  }
}
```

This marks every builtin agent as `disabled: true`. They won't show up in `subagent({ action: "list" })`, won't be discoverable by the LLM, and can't be launched.

Then write your own agents in `~/.pi/agent/agents/` (user scope) or `.pi/agents/` (project scope):

```
~/.pi/agent/agents/
  my-finder.md
  my-worker.md
  my-oracle.md
```

These will be discovered instead.

---

## Disabling Specific Builtins Only

```json
{
  "subagents": {
    "agentOverrides": {
      "oracle": { "disabled": true },
      "planner": { "disabled": true },
      "worker": { "disabled": true }
    }
  }
}
```

Or disable per-project in `.pi/settings.json`:

```json
{
  "subagents": {
    "agentOverrides": {
      "reviewer": { "disabled": true }
    }
  }
}
```

---

## Overriding Builtins Without Disabling Them

You don't need to copy the full agent file just to change a field:

```json
{
  "subagents": {
    "agentOverrides": {
      "worker": {
        "model": "anthropic/claude-sonnet-4",
        "defaultContext": "fresh",
        "systemPrompt": "You are a focused implementation agent..."
      }
    }
  }
}
```

Supported override fields: `model`, `fallbackModels`, `thinking`, `systemPromptMode`, `inheritProjectContext`, `inheritSkills`, `defaultContext`, `disabled`, `skills`, `tools`, `systemPrompt`.

---

## Replacing the SKILL.md (Orchestration Instructions)

The skill file lives inside the package at:

```
pi-subagents/skills/pi-subagents/SKILL.md
```

Discovery priority (highest wins):

| Priority | Source | Path |
|----------|--------|------|
| 700 | Project | `.pi/skills/pi-subagents/SKILL.md` |
| 300 | User | `~/.pi/agent/skills/pi-subagents/SKILL.md` |
| 100 | Builtin | Inside the pi-subagents package |

To override it, create a file at either:

```bash
# User scope (applies to all projects)
mkdir -p ~/.pi/agent/skills/pi-subagents
# Put your SKILL.md there

# Project scope (wins over user, project-specific)
mkdir -p .pi/skills/pi-subagents
# Put your SKILL.md there
```

Your file will be discovered **instead of** the builtin one because project > user > builtin in the priority chain. The skill name `pi-subagents` is resolved by directory name + `SKILL.md` filename.

You can also add it to settings:

```json
{
  "skills": [
    "~/.pi/agent/skills/pi-subagents/SKILL.md"
  ]
}
```

---

## Completely Replacing Everything

The nuclear option — all builtins gone, only your agents and instructions:

```json
// ~/.pi/agent/settings.json
{
  "subagents": {
    "disableBuiltins": true,
    "agentOverrides": {}
  },
  "skills": [
    "~/.pi/agent/skills/pi-subagents/SKILL.md"
  ]
}
```

Then create your custom files:

```bash
# Your custom skill
~/.pi/agent/skills/pi-subagents/SKILL.md

# Your custom agents
~/.pi/agent/agents/my-finder.md
~/.pi/agent/agents/my-worker.md
~/.pi/agent/agents/my-oracle.md
~/.pi/agent/agents/my-manager.md
```

All builtins gone. Your agents and your orchestration instructions only. The `subagent()` tool itself still works — you're just changing what agents exist and what instructions the parent LLM gets about how to use them.

---

## Important: The `pi-subagents` Skill Name Is Special

From the source code (`skills.ts`):

```typescript
const SUBAGENT_ORCHESTRATION_SKILL = "pi-subagents";

// In resolveSkills():
if (trimmed === SUBAGENT_ORCHESTRATION_SKILL) {
    missing.push(trimmed);  // intentionally marks itself as "missing"
    continue;               // so children never inherit it
}
```

This means children never get the `pi-subagents` skill injected — it's parent-only. Your replacement skill with the same name gets the same treatment automatically.

---

## Precedence Summary

### Agents

```
Project agents (.pi/agents/*.md)
  > User agents (~/.pi/agent/agents/*.md)
    > Builtin agents (inside pi-subagents package)
```

Project overrides beat user overrides beat builtins. Same name = override.

### Skills

```
Project skills (.pi/skills/pi-subagents/SKILL.md)
  > User skills (~/.pi/agent/skills/pi-subagents/SKILL.md)
    > Builtin skill (pi-subagents/skills/pi-subagents/SKILL.md)
```

### Settings

```
Project settings (.pi/settings.json)
  > User settings (~/.pi/agent/settings.json)
```

Project `disableBuiltins` and `agentOverrides` win over user settings when both exist.

---

## Settings File Locations

| Scope | Path |
|-------|------|
| User settings | `~/.pi/agent/settings.json` |
| Project settings | `.pi/settings.json` |
| Extension config | `~/.pi/agent/extensions/subagent/config.json` |

The extension config (`config.json`) controls runtime behavior like `asyncByDefault`, `forceTopLevelAsync`, `maxSubagentDepth`, `control`, `intercomBridge`, and `worktreeSetupHook`. Agent overrides and skill replacement go in the settings files instead.
