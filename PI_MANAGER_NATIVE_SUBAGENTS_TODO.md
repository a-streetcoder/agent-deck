# Pi Manager Native Subagents Remaining Work

Checklist after the current native subagent implementation pass.

Legend:
- [x] implemented in code
- [ ] still missing or needs manual validation

## Immediate manual validation

Manual app validation has moved to `manual-verification.md`, which is the source of truth for native subagent verification coverage.

## Run records and restart recovery

- [x] Add richer persisted restart recovery for active child runs.
- [x] On app restart, detect previously active runs and mark them as `disconnected` instead of leaving them active forever.
- [x] Cancel stale pending supervisor requests whose child run is no longer active after restart recovery.
- [x] Persist child session metadata, artifact directory, output path, launch command, and child transcripts.
- [x] Add duration fields and clearer timestamps to run/child records.
- [x] Add artifact open/reveal buttons on run cards.
- [x] Add cleanup policy for orphaned old app-managed subagent artifacts.

## Full child transcript navigation

- [x] Store child transcript entries separately from compact parent transcript status entries.
- [x] Add “Open Child Transcript” from native run cards.
- [x] Render child messages, tools, stderr, raw events, and errors in a child transcript sheet.
- [x] Show child Pi session file and app artifact directory in the run UI/transcript sheet.
- [x] Improve child transcript rendering to use the full threaded transcript UI instead of compact cards.
- [x] Add child transcript search/filtering.

## Parent-facing delegation tool bridge

- [x] Build the parent-facing `managed_subagent(...)` tool bridge as an app-written Pi extension loaded explicitly for app parent sessions.
- [x] Define bridge tool schemas with TypeBox/StringEnum so Pi executes the extension tools reliably.
- [x] Let the parent call `managed_subagent(agent, task, context?)` without relying on `/run` or `pi-subagents`.
- [x] Route the tool call into `PiSubagentRunService`.
- [x] Return compact child results as tool output through the extension UI bridge.
- [x] Honor `managed_subagent` context overrides (`fresh` / `fork`) instead of silently falling back to agent defaults.
- [x] Render parent transcript status entries for native subagent requests and results.
- [x] Decide bridge mechanism for now: bundled/generated Pi extension using the RPC extension UI sub-protocol as a private app bridge.
- [x] Let the parent Pi Agent see a richer compact catalog of available native subagents beyond the tool description/prompt snippet.
- [x] Add timeout semantics for parent tool calls waiting on long-running children.
- [x] Return a stopped status to waiting parent `managed_subagent` tool calls when a native child run is stopped.

## Native child `contact_supervisor(...)`

- [x] Build the child-facing native `contact_supervisor(...)` bridge as an app-written Pi extension loaded for child runs that request the tool.
- [x] Validate parent/child bridge extensions with Pi RPC smoke tests using `zai/glm-4.5-air`.
- [x] Support non-blocking `progress_update` messages from child to app/parent.
- [x] Support blocking `need_decision` requests.
- [x] Support blocking `interview_request` / structured question flows at the text-response level.
- [x] Add supervisor request cards in the parent/app UI.
- [x] Route human responses back to the child.
- [x] Add cancel behavior for blocked child runs.
- [x] Make `contact_supervisor` available only to native child runs that explicitly include it.
- [x] Add timeout behavior for blocked child runs.
- [x] Add structured interview UI for JSON `questions` payloads, with freeform fallback.
- [x] Route parent-agent responses, not only human responses, back to the child via native supervisor tools.

## Chains and parallel run graphs

- [x] Add native run graph models for chains and parallel runs.
- [x] Implement sequential chain execution first.
- [x] Pass prior child results/artifacts into later chain steps.
- [x] Implement parallel read-only child runs.
- [x] Add fan-out/fan-in summary support.
- [x] Add UI for graph status: queued, running, blocked, completed, failed.
- [x] Add controls to stop one child or the entire graph.
- [x] Add basic retry controls for failed/stopped/disconnected graph children.

## Worktree isolation

- [x] Add optional git worktree creation for native single-subagent runs.
- [x] Add a Run Subagent sheet toggle for worktree isolation.
- [x] Launch child Pi RPC sessions in the isolated worktree when enabled.
- [x] Require worktree isolation for heuristic writer-like parallel children.
- [x] Prevent multiple writer children from editing the same checkout by rejecting writer-like parallel runs without isolated worktrees.
- [x] Show each child worktree path more prominently in the run UI.
- [x] Surface diffs from app-managed isolated child worktrees as generated patch artifacts.
- [x] Add apply/discard workflows for app-managed isolated child worktree changes.
- [x] Clean up temporary worktrees safely through `git worktree remove --force` plus prune.

## Output safety

- [x] Keep app artifact output as the default for native runs.
- [x] Show warnings in the Run Subagent sheet when an agent has an `output` field.
- [x] Avoid injecting old `pi-subagents`-style “write to plan.md” output instructions by default.
- [x] Add explicit Expected Outcome controls: report only, edit files in worktree, write/update project file, or direct project writes.
- [x] Require worktree isolation or explicit direct-write approval for writer-like manual native subagent tasks.
- [x] Auto-isolate writer-like parent-bridge `managed_subagent` requests.
- [x] Require isolated worktrees for writer-like native chain steps and parallel tasks.
- [x] Require a project-relative path for explicit project-file output and reject unsafe `..`/absolute paths.
- [x] Prevent accidental overwrites of explicit project-file outputs unless overwrite is enabled.
- [x] Keep agent-configured outputs such as `plan.md` as advisory text, not automatic project-file writes.
- [ ] Add deeper per-tool overwrite interception if Pi RPC exposes host-side file mutation approvals later.
- [x] Add artifact open actions for `output.md`, `input.md`, and `system-prompt.md`.

## Skill/config fidelity

- [x] Resolve explicit private skills from active skills plus reusable library skills.
- [x] Add diagnostics for missing private skills.
- [x] Preserve `model`, `thinking`, `tools`, configured `extensions`, `inheritSkills`, `inheritProjectContext`, `defaultContext`, `defaultReads`, and app artifact output behavior for single runs.
- [x] Disable ambient extension discovery for native child runs so only configured extensions plus app bridge extensions load.
- [x] Support `fork` default context by passing `--fork <parent-session-file>` when available.
- [x] Show where each resolved skill came from: project, global, library, or package/builtin.
- [ ] Support more complete fallback model behavior for child runs.
- [x] Add direct MCP tool parity by setting `MCP_DIRECT_TOOLS` per native child, with `__none__` isolation when unset.
- [x] Add caller-provided read-first files for manual and parent-bridge native subagent runs.
- [x] Let caller-provided reads override agent `defaultReads` to avoid stale default plans/context.
- [x] Keep `defaultReads` and caller reads as soft "read current project files first if relevant" instructions instead of forced file injection.
- [x] Add clearer UI explaining when a child is launched fresh vs forked.

## App UI polish

- [x] Replace `/run` insertion with native Run Subagent sheets.
- [x] Add native run cards with transcript/reveal/stop actions.
- [x] Add supervisor request cards.
- [x] Add worktree isolation toggle.
- [ ] Improve Run Subagent sheet layout for long tool/skill lists.
- [ ] Add agent search/filtering to the subagent picker.
- [ ] Add recent/favorite agents.
- [ ] Add run history per parent session beyond the latest visible cards.
- [ ] Add status badges in the session list when native subagents are running.
- [ ] Add notifications for completed/failed long-running children.
- [ ] Add accessibility labels/help for native subagent controls.

## Documentation

- [x] Update `pi-documentation/` to describe Pi Manager native app-managed subagents.
- [x] Document that native subagents are visible in Pi Manager, not first-class CLI/TUI `/run` features.
- [x] Document the distinction between old package-managed `pi-subagents` and app-managed native subagents.
- [x] Document artifact locations and cleanup policy.
- [x] Document private skill resolution from `~/.pi/agent/skill-library`.
- [x] Document current limitations and future CLI/TUI parity options.

## Later CLI/TUI parity options

Intentionally deferred per current product direction.
