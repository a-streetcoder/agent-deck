# Pi Manager Native Subagents Remaining Work

Checklist for the work still needed after the Phase 1 native single-subagent foundation.

## Immediate validation

- [ ] Launch Pi Manager and run a harmless native subagent from the main Pi Agent composer.
- [ ] Run a harmless native subagent from the Pi Agent inspector composer.
- [ ] Confirm the composer no longer inserts or sends raw `/run ...` text.
- [ ] Confirm the parent transcript gets one native status/result flow, not duplicate parent/child replies.
- [ ] Confirm app artifacts are written under `~/Library/Application Support/Pi Manager/Subagent Runs/<run-id>/`.
- [ ] Confirm native runs do not create accidental project files such as `plan.md` unless explicitly requested.
- [ ] Confirm disabled agents do not appear in the native picker.
- [ ] Confirm agents with private library skills receive those skill contents even when the skills are not globally/project enabled.

## Run records and restart recovery

- [ ] Add richer persisted restart recovery for active child runs.
- [ ] On app restart, detect previously active runs and mark them as `stopped`, `unknown`, or `disconnected` instead of leaving them active forever.
- [ ] Persist enough child process/session metadata to reconnect or clearly explain that reconnection is unavailable.
- [ ] Add duration fields and clearer timestamps to run/child records.
- [ ] Add artifact open/reveal buttons on run cards.
- [ ] Add cleanup policy for old app-managed subagent artifacts.

## Full child transcript navigation

- [ ] Store child transcript entries separately from compact parent transcript status entries.
- [ ] Add “Open Child Transcript” from native run cards.
- [ ] Render child messages, thinking, tools, stderr, and errors using the existing transcript UI components where possible.
- [ ] Show child Pi session file and app artifact directory in the child transcript view.
- [ ] Add child transcript search/filtering later if needed.

## Parent-facing delegation tool bridge

- [ ] Build the parent-facing `managed_subagent(...)` tool bridge.
- [ ] Let the parent Pi Agent see a compact catalog of available native subagents.
- [ ] Let the parent call `managed_subagent(agent, task, context?, options?)` without loading every child prompt/skill into parent context.
- [ ] Route the tool call into `PiSubagentRunService`.
- [ ] Return compact child results as tool output.
- [ ] Render parent transcript tool output cleanly, with links to native run cards/artifacts.
- [ ] Decide whether the bridge is a bundled Pi extension, local IPC helper, or app-owned RPC endpoint.

## Native child `contact_supervisor(...)`

- [ ] Build the child-facing native `contact_supervisor(...)` bridge.
- [ ] Support non-blocking `progress_update` messages from child to app/parent.
- [ ] Support blocking `need_decision` requests.
- [ ] Support blocking `interview_request` / structured question flows.
- [ ] Add supervisor request cards in the parent/app UI.
- [ ] Route human or parent-agent responses back to the child.
- [ ] Add timeout/cancel behavior for blocked child runs.
- [ ] Make `contact_supervisor` available only to native child runs that explicitly include it.

## Chains and parallel run graphs

- [ ] Add native run graph models for chains and parallel runs.
- [ ] Implement sequential chain execution first.
- [ ] Pass prior child results/artifacts into later chain steps.
- [ ] Implement parallel read-only child runs.
- [ ] Add fan-out/fan-in summary support.
- [ ] Add UI for graph status: queued, running, blocked, completed, failed.
- [ ] Add controls to stop one child or the entire graph.
- [ ] Add partial failure behavior and retry controls.

## Worktree isolation

- [ ] Add optional git worktree creation for native subagent runs.
- [ ] Require worktree isolation for parallel writer children.
- [ ] Prevent multiple writer children from editing the same worktree unless explicitly allowed.
- [ ] Show each child worktree path in the run UI.
- [ ] Surface diffs from each child worktree.
- [ ] Add merge/apply/discard workflows for child worktree changes.
- [ ] Clean up temporary worktrees safely.

## Output safety

- [ ] Keep app artifact output as the default for native runs.
- [ ] Confirm before writing agent-configured outputs into project files such as `plan.md`.
- [ ] Show prominent warnings when an agent has an `output` field.
- [ ] Add per-run output policy controls: app artifact only, allow explicit project writes, or use configured output.
- [ ] Prevent silent overwrites of existing project artifacts.
- [ ] Add artifact previews for `output.md`, logs, and prompt/input files.

## Skill/config fidelity

- [ ] Improve diagnostics for missing private skills.
- [ ] Show where each resolved skill came from: project, global, library, or package/builtin.
- [ ] Support more complete fallback model behavior for child runs.
- [ ] Audit `tools`, `extensions`, `mcpServers`, `inheritSkills`, and `inheritProjectContext` parity against old `pi-subagents` behavior.
- [ ] Confirm `defaultReads` behavior is safe and does not reintroduce stale file footguns.
- [ ] Add UI explaining when a child is launched fresh vs forked.

## App UI polish

- [ ] Improve Run Subagent sheet layout for long tool/skill lists.
- [ ] Add agent search/filtering to the subagent picker.
- [ ] Add recent/favorite agents.
- [ ] Add run history per parent session.
- [ ] Add status badges in the session list when native subagents are running.
- [ ] Add notifications for completed/failed long-running children.
- [ ] Add accessibility labels/help for native subagent controls.

## Documentation

- [ ] Update `pi-documentation/` to describe Pi Manager native app-managed subagents.
- [ ] Document that native subagents are visible in Pi Manager, not first-class CLI/TUI `/run` features.
- [ ] Document the distinction between old package-managed `pi-subagents` and app-managed native subagents.
- [ ] Document artifact locations and cleanup policy.
- [ ] Document private skill resolution from `~/.pi/agent/skill-library`.
- [ ] Document current limitations and future CLI/TUI parity options.

## Later CLI/TUI parity options

- [ ] Decide whether native subagent functionality should remain app-only or be extracted into a shared package/extension.
- [ ] If parity is desired, design a shared bridge so CLI/TUI can call the same app-managed or package-managed run logic.
- [ ] Avoid reintroducing global broker complexity unless explicitly needed.
