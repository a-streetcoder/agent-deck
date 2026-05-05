# Pi Manager Native Subagents Remaining Work

Checklist after the current native subagent implementation pass.

Legend:
- [x] implemented in code
- [ ] still missing or needs manual validation

## Immediate manual validation

Manual app validation is intentionally deferred until Pi Manager can be launched interactively on a Mac with Xcode/app runtime access. Use a harmless task such as: `Say hello and report your working directory. Do not edit files.`

### Launch paths

- [ ] Main composer: open a Pi Agent project session, click the native subagent button, pick an enabled agent, and run the harmless task.
- [ ] Inspector composer: open the Pi Agent inspector for a session, click the native subagent button, pick an enabled agent, and run the harmless task.
- [ ] Confirm neither path inserts raw `/run ...` text into the composer.
- [ ] Confirm neither path sends raw `/run ...` text to the parent Pi session.

### Parent transcript behavior

- [ ] Confirm the parent transcript receives exactly one native start/status flow for the run.
- [ ] Confirm the parent transcript receives exactly one native completion/failure result flow.
- [ ] Confirm there are no duplicate parent replies caused by both parent and child answering the same task.
- [ ] Confirm the run card shows status, requested/resolved context, timestamps/duration, artifact directory, output path, child session file when available, and worktree path when enabled.

### Artifacts and output safety

- [ ] Confirm app artifacts are written under `~/Library/Application Support/Pi Manager/Subagent Runs/<run-id>/`.
- [ ] Confirm `input.md`, `system-prompt.md`, and `output.md` are created for a completed run.
- [ ] Confirm run-card artifact actions open/reveal the expected files/folder.
- [ ] Confirm a harmless native run does not create accidental project files such as `plan.md`.
- [ ] Confirm an agent with an `output` field shows an output warning and still defaults final response storage to app artifacts unless project-file edits are explicitly requested.

### Agent picker/config fidelity

- [ ] Confirm disabled agents do not appear in the native picker.
- [ ] Confirm agent `model`, `thinking`, `tools`, configured `extensions`, `inheritSkills`, `inheritProjectContext`, `defaultContext`, and `defaultReads` are reflected in launch behavior/UI.
- [ ] Confirm `defaultReads` is only a soft “read first if relevant” instruction, not forced project-file injection.
- [ ] Confirm agents with private library skills receive those skill contents even when the skills are not globally/project enabled.
- [ ] Confirm resolved skill source diagnostics distinguish project/global/library/package/builtin skills in child prompt artifacts.

### Parent bridge and supervisor bridge

- [ ] Ask the parent Pi Agent to call `managed_subagent(agent, task, context: "fresh")`; confirm native run launches fresh and returns a compact tool result.
- [ ] Ask the parent Pi Agent to call `managed_subagent(agent, task, context: "fork")` after a parent session file exists; confirm native run launches with forked context or records a clear fallback warning if no session file exists.
- [ ] Run a child agent with `contact_supervisor` and confirm a non-blocking `progress_update` appears as a parent/app status update and auto-acknowledges.
- [ ] Run a child agent with `contact_supervisor` and confirm blocking `need_decision` / `interview_request` creates a supervisor request card, blocks the child, accepts a human response, and resumes the child.
- [ ] Confirm stopping a blocked child cancels/clears the pending bridge request and returns a stopped result to any waiting parent tool call.

### Restart recovery

- [ ] Start a native child run, quit/relaunch Pi Manager while it is active, and confirm the run is marked `disconnected` rather than active forever.
- [ ] Quit/relaunch while a child is blocked on a supervisor request and confirm stale pending request cards are cancelled/hidden.

### Worktree isolation

- [ ] Run a harmless native subagent with worktree isolation enabled.
- [ ] Confirm the child Pi RPC process launches in the isolated worktree under the run artifact directory.
- [ ] Confirm project checkout files are not modified by isolated child edits unless later merge/apply workflows are explicitly used.

## Run records and restart recovery

- [x] Add richer persisted restart recovery for active child runs.
- [x] On app restart, detect previously active runs and mark them as `disconnected` instead of leaving them active forever.
- [x] Cancel stale pending supervisor requests whose child run is no longer active after restart recovery.
- [x] Persist child session metadata, artifact directory, output path, launch command, and child transcripts.
- [x] Add duration fields and clearer timestamps to run/child records.
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
- [ ] Optionally route parent-agent responses, not only human responses, back to the child.

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
- [ ] Audit `mcpServers` parity against old `pi-subagents` behavior.
- [x] Keep `defaultReads` as a soft "read first if relevant" instruction instead of forced file injection.
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

- [ ] Update `pi-documentation/` to describe Pi Manager native app-managed subagents.
- [ ] Document that native subagents are visible in Pi Manager, not first-class CLI/TUI `/run` features.
- [ ] Document the distinction between old package-managed `pi-subagents` and app-managed native subagents.
- [ ] Document artifact locations and cleanup policy.
- [ ] Document private skill resolution from `~/.pi/agent/skill-library`.
- [ ] Document current limitations and future CLI/TUI parity options.

## Later CLI/TUI parity options

Intentionally deferred per current product direction.
