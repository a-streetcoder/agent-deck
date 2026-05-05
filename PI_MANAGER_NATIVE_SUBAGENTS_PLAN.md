# Pi Manager Native Subagents Plan

Status: Native single-run execution is implemented beyond the original Phase 1 foundation, and native graph foundations are now in place. Pi Manager now has persisted native subagent run records, app-owned child Pi RPC sessions, private skill injection from snapshots/library skills with source diagnostics, native Run Subagent sheets with explicit Expected Outcome policy and caller-provided read-first files, parent transcript status entries, visible run/graph cards and graph detail sheets, full threaded/searchable child transcript navigation, parent-facing `managed_subagent(...)`, `managed_chain(...)`, `managed_parallel(...)`, `list_supervisor_requests(...)`, and `answer_supervisor_request(...)`, child-facing `contact_supervisor(...)`, TypeBox/StringEnum bridge schemas validated with Pi RPC smoke tests, compact parent-visible native subagent/chain catalog prompt, parent tool-call timeout handling, blocked supervisor timeout handling, structured interview forms for JSON question payloads, parent-agent and human supervisor responses, restart disconnection recovery, stale supervisor-request cancellation, child extension-discovery isolation, graph stop/retry controls, direct MCP tool env isolation, heuristic writer safety requiring isolated worktrees or explicit direct-write approval, explicit project-file output path validation/overwrite gating, orphaned artifact cleanup, artifact reveal/open actions, run duration/timestamp/context/displayed outcome, honored `managed_subagent` context overrides, optional git worktree isolation, and safe isolated-worktree patch/apply/discard workflows. Native subagent execution now replaces Pi Manager's dependency on `pi-subagents` for app-managed single, chain, and parallel flows. Remaining major work is fallback model retry (tracked in issue #8), native Session Relay for arbitrary opted-in Pi sessions, true background process survival across app restarts, and manual end-to-end app validation.

## Goals

- Keep Pi Manager's current resource management model for agents, chains, skills, prompts, and library/global/project visibility.
- Keep the existing agent discovery folders and precedence model; do not introduce new user-facing storage locations for agent definitions.
- Let the app launch subagents directly through app-owned Pi RPC child sessions, instead of sending `/run ...` slash text into the parent chat.
- Let the parent Pi session know it has subagents and delegate to them through a small app bridge/tool, without loading the full old `pi-subagents` package.
- Let a human open a native Run Subagent UI from the composer, select an agent, and run a task without transcript pollution or duplicate parent replies.
- Preserve separate runtime isolation: every subagent has its own Pi process, session file, transcript, model, tools, skills, context window, and lifecycle.
- Preserve key config behavior: `model`, `fallbackModels` where possible, `thinking`, `systemPromptMode`, `inheritProjectContext`, `inheritSkills`, `defaultContext`, `tools`, `extensions`, `skills`, `output`, `defaultReads`, `defaultProgress`, and disabled agents.
- Let agents use private assigned skills from the skill library even when those skills are not enabled globally or assigned to the current project.
- Replace package broker semantics for native subagents with app-native parent/child routing and the native `contact_supervisor` tool for child decision escalation.
- Make output safe by default: app artifacts first; writing to project paths should be explicit and visible.
- Keep UI and docs consistent with the app's native model.

## Non-goals for the first implementation pass

- Running arbitrary parallel writer children in the same worktree without user confirmation or worktree isolation.
- Reimplementing arbitrary external session-to-session messaging as part of native subagent execution; that belongs to the separate Session Relay plan.
- Relying on slash commands as the main app UX.
- Making old `pi-subagents` package-managed runs disappear from historical transcripts.

## Current package behavior to port or improve

### Discovery

Current `pi-subagents` discovers:

- builtins from the package's `agents/` directory
- user agents from `~/.pi/agent/agents/**/*.md` and legacy `~/.agents/**/*.md`
- project agents from `.pi/agents/**/*.md` and legacy `.agents/**/*.md`
- chains from `~/.pi/agent/chains/**/*.chain.md` and `.pi/chains/**/*.chain.md`
- builtin overrides from `~/.pi/agent/settings.json` and `.pi/settings.json`

Pi Manager already scans most of this. The native runtime should reuse `PiScanner` and `ScanSnapshot` instead of invoking `pi-subagents` discovery.

### Execution

Current `pi-subagents` launches children by spawning Pi in JSON mode with custom args, parsing child stdout, and saving artifacts. Pi Manager should launch children with `pi --mode rpc`, because the app already has an RPC process abstraction and native transcript rendering.

### Context

Port these semantics:

- `defaultContext: fork` means the child should use a branched or referenced copy of the parent session context by default.
- `context: fresh` means no parent conversation history.
- `inheritProjectContext: true` means project instruction files such as `AGENTS.md`/`CLAUDE.md` remain available to the child; native runs pass `--no-context-files` when this is false.
- `inheritSkills: true` means Pi's ambient skill catalog is available to the child. Explicit `skills` remain separate and should be injected by the app.

The Phase 1 implementation launches child sessions with a native child prompt and `--system-prompt` / `--append-system-prompt`. When an agent defaults to `fork` and the parent session has a Pi session file, the child is launched with Pi's `--fork <parent-session-file>` so it receives a branched copy of parent history. Otherwise the child falls back to a fresh app-artifact session directory.

### Skills

Current `pi-subagents` resolves explicit child skills from user/project/package paths. Pi Manager should improve this:

- explicit agent `skills` resolve from active project/global skills first
- then reusable `~/.pi/agent/skill-library`
- then package-discovered skills where visible
- inject only those skill contents into the child system prompt
- do not require skills to be globally enabled or assigned to the project

### Intercom/contact supervisor

Port the `contact_supervisor` semantics, not the broker:

- `progress_update`: non-blocking update to parent/app
- `need_decision`: blocking decision request
- `interview_request`: blocking structured question request

The app routes these as typed records/cards between child run and parent session. The current implementation uses an app-written child Pi extension loaded only for native child runs that explicitly include `contact_supervisor`; blocking requests pause the run as `blocked` until the app sends a response or cancellation through the RPC extension UI bridge.

### Output

Current `pi-subagents` injects prompt text like `Write your findings to plan.md`. This can overwrite files accidentally. Native default should be:

- write final child transcript/result into an app artifact directory
- only write project files when the agent config explicitly requests it and the user/parent approves or the run UI shows it clearly
- never silently overwrite `plan.md` from a casual test task

## Native architecture

```text
Pi Manager App
  ├─ AppViewModel
  │   ├─ PiScanner / resource snapshots
  │   ├─ PiAgentRunnerService for parent sessions
  │   └─ PiSubagentRunService for child sessions
  │
  ├─ Parent Pi RPC session
  │   ├─ normal chat/tool/runtime state
  │   └─ future app bridge tool: managed_subagent(...)
  │
  ├─ PiSubagentRunStore
  │   ├─ run records
  │   ├─ child records
  │   ├─ artifacts
  │   └─ supervisor requests
  │
  └─ Child Pi RPC sessions
      ├─ one process/session per subagent child
      ├─ child-specific system prompt
      ├─ child-specific model/thinking/tools/extensions
      ├─ explicit private skills
      ├─ optional project context inheritance
      └─ future contact_supervisor tool
```

## App data model

Add app-persisted records:

```swift
PiSubagentRunRecord
- id
- parentSessionID
- title
- mode: single | chain | parallel
- status: queued | starting | running | blocked | completed | failed | stopped
- agentName
- task
- contextMode
- model
- thinking
- artifactDirectory
- outputPath
- childSessionID
- childPiSessionFile
- launchCommand
- error
- createdAt / updatedAt / completedAt

PiSubagentChildRecord
- id
- runID
- index
- agentName
- status
- currentTool
- tokens
- durationMs
- sessionFile
- outputPath
- error

PiSubagentSupervisorRequest
- id
- runID
- childID
- reason
- message
- expectsReply
- response
- status
```

## App service responsibilities

### `PiSubagentRunService`

- create run records
- resolve effective agent config from current snapshot
- resolve private skills and build child system prompt
- choose model/thinking/tools/extensions
- create artifact directory
- launch `PiRPCClient` child
- send initial task prompt
- stream child events into child transcript/run state
- append compact run cards to parent transcript
- stop/interrupt child
- open/focus child transcript in UI

### `PiSubagentPromptBuilder`

Builds the child system prompt from:

- agent prompt body / override prompt
- child boundary instructions
- resolved explicit skill blocks
- project context policy note
- output/artifact policy
- supervisor contract

### `PiSubagentSkillResolver`

Resolve explicit agent skill names from:

1. selected project active skills
2. global active skills
3. skill library
4. package-discovered skills in the snapshot

Returns skill contents and diagnostics.

## UI plan

### Composer

- Keep the subagent icon next to the paperclip.
- Show it when the selected session has subagents enabled and at least one enabled effective agent.
- Clicking opens a Run Subagent sheet/popover, not raw `/run` insertion.
- If composer text exists, use it to prefill the task.

### Run Subagent sheet

Fields:

- Agent picker
- Task editor
- Agent summary: description, model, thinking, tools, skills
- Context: shows agent default (`fresh`/`fork`) and whether project context is inherited
- Output behavior: app artifact by default; show warning if agent config has `output`
- Run button

### Transcript

Parent transcript gets structured status cards:

- `Subagent started: apple-engineer`
- progress/current tool updates
- `Subagent completed` with compact summary and artifact/session links
- `Subagent failed` with error and logs

Child transcript can be opened separately.

### Agent detail views

- Show whether an agent is runnable natively.
- Show private skill resolution: active/project/global/library/package.
- Explain that assigned skills do not need global/project enablement for native runs.

## Implementation phases

### Phase 1: native single-run foundation

- [x] Add plan document.
- [x] Add run record models and store persistence.
- [x] Add `PiRPCClient` support for child launch args/environment.
- [x] Add `PiSubagentRunService` for single child runs.
- [x] Add private skill resolver.
- [x] Add child prompt builder.
- [x] Change composer subagent button to show Run Subagent sheet.
- [x] Run selected agent tasks through app-owned child RPC path.
- [x] Render parent transcript status/result entries and native run cards.
- [x] Validate with repeated Debug builds.

### Phase 2: child transcript and controls

- [x] Add UI to open child transcript.
- [x] Add stop control for active child.
- [ ] Add resume/talk-to-child using child session file.
- [x] Persist run status across app restart by marking active child runs `disconnected` and cancelling stale pending supervisor requests.

### Phase 3: parent tool bridge

- [x] Bundle/write a small app extension exposing `managed_subagent` to the parent Pi session.
- [x] Forward structured requests to Pi Manager via the RPC extension UI sub-protocol.
- [x] Return compact child results as tool output, not full child transcript.
- [x] Honor parent-requested `context` overrides for `fresh` and `fork` native child runs.
- [ ] Add richer subagent catalog/context to the parent prompt.
- [x] Add timeout behavior for long-running parent tool calls.
- [x] Complete waiting parent tool calls when their native child run is stopped.

### Phase 4: native `contact_supervisor`

- [x] Bundle/write a child extension exposing `contact_supervisor`.
- [x] Route child decision/progress/interview requests into parent cards.
- [x] Let the human answer explicitly and route the answer back to the child.
- [ ] Add structured interview UI beyond freeform response.
- [x] Add timeout behavior for blocked child runs.

### Phase 5: chains, parallel, worktrees

- [x] Model chain/parallel as a run graph.
- [x] Add output dependencies and artifact passing.
- [x] Enforce one writer per worktree for heuristic writer-like parallel runs.
- [x] Add optional git worktree isolation for single native child runs.
- [x] Add diff/apply/discard workflows for isolated child worktrees.

## Validation checklist

- Build Pi Manager after every implementation slice.
- Start a project session with subagents disabled from old packages and confirm native button still works from app data.
- Run a harmless child task with `planner` and confirm no project `plan.md` overwrite unless explicitly allowed.
- Run `apple-engineer` in a Swift/macOS repo and confirm separate child Pi session/process is created.
- Confirm parent transcript gets one structured result card and no duplicate parent chat answer.
- Confirm assigned skill from library is injected even if not active globally/project.
- Confirm disabled agents do not appear in the native run picker.
- Confirm no raw `/run` text is required.

## Open risks

- Pi's stable public API does not yet expose direct host-side subagent tool execution; the app-owned child RPC design avoids relying on that.
- Forked child sessions use Pi's current `--fork <session-file>` support; if Pi changes this behavior, the app runner must be updated.
- Parent/child bridge tools currently use the RPC extension UI sub-protocol as an app-private transport. A dedicated localhost/Unix-socket IPC bridge may be cleaner later.
- Parallel writers require worktree isolation or explicit confirmation.
- Existing historical package-managed runs remain in old transcripts and should be displayed as external/package-managed runs.
