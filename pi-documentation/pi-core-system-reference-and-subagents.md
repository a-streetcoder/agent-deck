# Pi core and Pi Manager native subagents

This is a concise reference for how Pi Manager relates to normal Pi sessions and native subagent child sessions.

## Layers

1. **Pi core runtime**
   - Builds the system prompt from built-in defaults, context files, explicit prompt flags, skills, tools, extensions, and user messages.
   - Owns normal CLI/RPC session behavior.

2. **Pi Manager app**
   - Scans and manages agents, chains, skills, prompt templates, settings, and environment files.
   - Provides UI for editing app-managed resources and for launching Pi Agent sessions.

3. **Pi Manager native subagents**
   - Launch app-owned child Pi RPC sessions for bounded work.
   - Persist run records, transcripts, artifacts, supervisor requests, graph metadata, and optional worktrees.
   - Use app-generated bridge tools such as `managed_subagent`, `managed_chain`, `managed_parallel`, and `contact_supervisor`.

## Normal Pi sessions

A normal Pi session runs in a selected working directory and receives the effective runtime context Pi builds from:

- built-in Pi system behavior
- user/global/project context files such as `AGENTS.md` or other configured files
- explicit `--system-prompt` or `--append-system-prompt` arguments
- enabled skills
- enabled extensions and tools
- prompt templates and slash commands that are available to that runtime

Pi Manager does not replace Pi core prompt assembly. It manages files and launches Pi through RPC with explicit arguments.

## Native subagent sessions

A native subagent is a separate child Pi RPC session launched and tracked by Pi Manager.

For each native run, Pi Manager builds:

- an app artifact directory under `~/Library/Application Support/Pi Manager/Subagent Runs/<run-id>/`
- a child system prompt made from native boundary instructions, the agent prompt, and any explicit private skill blocks
- an input file containing the task and optional read-first hints
- child runtime arguments for model, thinking, context inheritance, skills inheritance, tools, extensions, and direct MCP isolation
- run records and transcript routing in the app session store

Native subagents are not raw slash-command text inserted into the parent chat. The app owns the child lifecycle directly.

## Native boundary rules

Pi Manager injects native boundary instructions into every child run:

- complete only the assigned task
- do not launch additional subagents
- treat forked context as read-only background
- keep parent/user decision authority
- return final results normally
- prefer narrow, correct changes

When the agent frontmatter includes `contact_supervisor` in `tools`, Pi Manager also injects supervisor routing rules:

- use `kind: "need_decision"` for blocking product, architecture, scope, approval, or ambiguity decisions
- use `kind: "interview_request"` only for structured question sets
- use `kind: "progress_update"` sparingly for meaningful non-blocking updates
- do not use `contact_supervisor` for routine completion

## Agent frontmatter fields

Pi Manager native agents are markdown files with YAML frontmatter. Important fields include:

- `name`
- `description`
- `model`
- `fallbackModels`
- `thinking`
- `systemPromptMode`
- `inheritProjectContext`
- `inheritSkills`
- `defaultContext`
- `disabled`
- `tools`
- `mcpDirectTools`
- `extensions`
- `skills`
- `output`
- `defaultReads`
- `defaultProgress`
- `interactive`
- `maxSubagentDepth`

`output` is advisory for native runs. Project writes require an explicit expected outcome selected by the caller.

## Expected outcomes

Native subagent runs have explicit outcome modes:

- report only
- edit files in an isolated worktree
- write or update one project-relative file
- direct project writes with explicit approval

Writer-like runs should prefer worktree isolation unless direct writes are explicitly approved.

## Read-first hints

`defaultReads` and caller-provided `reads` are project-relative hints. Pi Manager validates them and tells the child to read current files if relevant. They are not injected as stale authoritative content.

## Related docs

- `native-subagents.md`
- `pi-manager-resource-management.md`
- `pi-skills-discovery.md`
- `official-documentation/reference/agent-frontmatter.md`
- `official-documentation/reference/native-subagent-bridge.md`
