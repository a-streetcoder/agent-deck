# Pi Manager Native Subagents Remaining Work

Checklist after the current native subagent implementation pass.

Legend:
- [x] implemented in code
- [ ] still missing or needs manual validation

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

- [x] Add richer persisted restart recovery for active child runs.
- [x] On app restart, detect previously active runs and mark them as `disconnected` instead of leaving them active forever.
- [x] Persist child session metadata, artifact directory, output path, launch command, and child transcripts.
- [ ] Add duration fields and clearer timestamps to run/child records.
- [x] Add artifact open/reveal buttons on run cards.
- [ ] Add cleanup policy for old app-managed subagent artifacts.

## Full child transcript navigation

- [x] Store child transcript entries separately from compact parent transcript status entries.
- [x] Add “Open Child Transcript” from native run cards.
- [x] Render child messages, tools, stderr, raw events, and errors in a child transcript sheet.
- [x] Show child Pi session file and app artifact directory in the run UI/transcript sheet.
- [ ] Improve child transcript rendering to use the full threaded transcript UI instead of compact cards.
- [ ] Add child transcript search/filtering later if needed.

## Parent-facing delegation tool bridge

- [x] Build the parent-facing `managed_subagent(...)` tool bridge as an app-written Pi extension loaded explicitly for app parent sessions.
- [x] Let the parent call `managed_subagent(agent, task, context?)` without relying on `/run` or `pi-subagents`.
- [x] Route the tool call into `PiSubagentRunService`.
- [x] Return compact child results as tool output through the extension UI bridge.
- [x] Render parent transcript status entries for native subagent requests and results.
- [x] Decide bridge mechanism for now: bundled/generated Pi extension using the RPC extension UI sub-protocol as a private app bridge.
- [ ] Let the parent Pi Agent see a richer compact catalog of available native subagents beyond the tool description/prompt snippet.
- [ ] Add timeouts/cancellation semantics for parent tool calls waiting on long-running children.

## Native child `contact_supervisor(...)`

- [x] Build the child-facing native `contact_supervisor(...)` bridge as an app-written Pi extension loaded for child runs that request the tool.
- [x] Support non-blocking `progress_update` messages from child to app/parent.
- [x] Support blocking `need_decision` requests.
- [x] Support blocking `interview_request` / structured question flows at the text-response level.
- [x] Add supervisor request cards in the parent/app UI.
- [x] Route human responses back to the child.
- [x] Add cancel behavior for blocked child runs.
- [x] Make `contact_supervisor` available only to native child runs that explicitly include it.
- [ ] Add timeout behavior for blocked child runs.
- [ ] Add richer structured interview UI beyond a freeform text response.
- [ ] Optionally route parent-agent responses, not only human responses, back to the child.

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

- [x] Add optional git worktree creation for native single-subagent runs.
- [x] Add a Run Subagent sheet toggle for worktree isolation.
- [x] Launch child Pi RPC sessions in the isolated worktree when enabled.
- [ ] Require worktree isolation for parallel writer children when parallel runs exist.
- [ ] Prevent multiple writer children from editing the same worktree unless explicitly allowed.
- [ ] Show each child worktree path more prominently in the run UI.
- [ ] Surface diffs from each child worktree.
- [ ] Add merge/apply/discard workflows for child worktree changes.
- [ ] Clean up temporary worktrees safely.

## Output safety

- [x] Keep app artifact output as the default for native runs.
- [x] Show warnings in the Run Subagent sheet when an agent has an `output` field.
- [x] Avoid injecting old `pi-subagents`-style “write to plan.md” output instructions by default.
- [ ] Confirm before writing agent-configured outputs into project files such as `plan.md`.
- [ ] Add per-run output policy controls: app artifact only, allow explicit project writes, or use configured output.
- [ ] Prevent silent overwrites of existing project artifacts.
- [ ] Add artifact previews for `output.md`, logs, and prompt/input files.

## Skill/config fidelity

- [x] Resolve explicit private skills from active skills plus reusable library skills.
- [x] Add diagnostics for missing private skills.
- [x] Preserve `model`, `thinking`, `tools`, `extensions`, `inheritSkills`, `inheritProjectContext`, `defaultContext`, `defaultReads`, and app artifact output behavior for single runs.
- [x] Support `fork` default context by passing `--fork <parent-session-file>` when available.
- [ ] Show where each resolved skill came from: project, global, library, or package/builtin.
- [ ] Support more complete fallback model behavior for child runs.
- [ ] Audit `mcpServers` parity against old `pi-subagents` behavior.
- [ ] Confirm `defaultReads` behavior is safe and does not reintroduce stale file footguns.
- [ ] Add clearer UI explaining when a child is launched fresh vs forked.

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

- [ ] Update `pi-documentation/` to describe Pi Manager native app-managed subagents.
- [ ] Document that native subagents are visible in Pi Manager, not first-class CLI/TUI `/run` features.
- [ ] Document the distinction between old package-managed `pi-subagents` and app-managed native subagents.
- [ ] Document artifact locations and cleanup policy.
- [ ] Document private skill resolution from `~/.pi/agent/skill-library`.
- [ ] Document current limitations and future CLI/TUI parity options.

## Later CLI/TUI parity options

Intentionally deferred per current product direction.
