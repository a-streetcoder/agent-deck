# Running Pi Agent inside Pi Manager

_Last updated: 2026-05-01_

## Executive summary

Pi Manager can support the killer workflow — pick a GitHub issue, run Pi Agent against the selected project, review the resulting changes, commit/push, comment on the issue, and optionally close it — without turning the app into a generic terminal clone.

The recommended architecture is a **native SwiftUI agent workspace backed by Pi's `--mode rpc` JSONL protocol**. This keeps the app beautiful, native, structured, and aligned with the existing design system. A terminal can still be added as an optional secondary surface later, but it should not be the primary integration because terminal embedding is harder to make native, harder to control safely, and duplicates UI Pi already exposes through RPC.

Recommended MVP:

1. Add a new **Agent** workspace/screen in the app.
2. Add a **Run with Pi Agent** action to GitHub issue detail cards.
3. Launch `pi --mode rpc` in the selected repository directory.
4. Send a generated issue prompt containing issue title, body, labels, comments/relationships summary, repo path, and desired completion criteria.
5. Render the live session as native SwiftUI transcript cards: user messages, assistant text, tool calls, tool results, status, token/cost/session info.
6. Provide controls for **Stop**, **Steer**, **Follow up**, **Open session**, **View changes**, **Commit/push**, **Post summary comment**, and **Close issue**.
7. Keep all dangerous actions explicit and user-confirmed.

## Current Pi Manager context

Relevant existing files:

- `pi-manager/pi_managerApp.swift` creates the main native macOS window.
- `pi-manager/ContentView.swift` owns the navigation/sidebar and screen switching.
- `pi-manager/DesignSystem.swift` defines the visual language: `AppPage`, `AppCard`, `AppSidebarPane`, `AppRowCard`, `AppLabelTag`, expanded headings, rounded cards, subtle fills.
- `pi-manager/AppViewModel.swift` is the central `@MainActor` app state holder.
- `pi-manager/CommandRunner.swift` resolves and runs short-lived commands, but only returns output after the process exits.
- `pi-manager/GitHubViews.swift` already has issue board/list/detail UI.
- `pi-manager/GitHubIssueService.swift` can fetch issue details and post comments.
- `pi-manager/GitRepositoryService.swift` can read status/diff, stage, commit, and push.
- `pi-manager/ProjectDiscovery.swift` maps selected projects to local git repos and GitHub remotes.

Current gaps:

- No long-running streaming process abstraction.
- No stdin writer for interactive agent messages.
- No Pi RPC client/parser.
- No issue close/reopen/edit endpoint yet.
- No dedicated agent session state in `AppViewModel`.
- No terminal/PTY component.

## Pi capabilities that matter

Pi supports an embedding protocol:

```bash
pi --mode rpc [options]
```

From Pi's `docs/rpc.md`:

- Protocol is JSONL over stdin/stdout.
- Send one JSON object per line to stdin.
- Receive responses and streamed agent events as JSON lines from stdout.
- `prompt` sends a user prompt.
- `steer` and `follow_up` support mid-run interaction.
- `abort` stops the current operation.
- `get_state`, `get_messages`, `get_session_stats`, `set_session_name`, `new_session`, `switch_session`, and `export_html` expose session state.
- Framing must split only on LF (`\n`), stripping optional `\r`.

That is exactly the right foundation for a native desktop integration.

## Research from pi-desktop repositories

The three referenced projects converge on the same core idea: **run the local `pi` CLI as a managed child process and communicate through `--mode rpc`**.

### `gustavonline/pi-desktop`

Useful ideas:

- Tauri app spawns `pi --mode rpc` as a child process.
- One process handle per RPC instance/session.
- Stores child process, stdin writer, and generation ID.
- Reads stdout/stderr on background threads and emits frontend events.
- Strong `pi` executable discovery:
  - manual configured path
  - dev path
  - env vars
  - sidecar
  - `PATH`
  - common npm/Homebrew paths
- Repairs GUI-launched macOS `PATH` by prepending the Pi binary directory.

Takeaway for Pi Manager: copy the process lifecycle and executable discovery principles, not the web UI.

### `StarkInternationalAI/pi-desktop`

Useful ideas:

- Uses `pi --mode rpc --session <file>` per session.
- Passes project/model/provider/extension/skill options at spawn time.
- Emits native app events for agent output.
- Provides a launch-command diagnostic string.
- Shutdown is graceful-first: send RPC `abort`, then drop stdin/terminate if needed.
- Indexes session output for later browsing.

Takeaway for Pi Manager: expose launch diagnostics, session file paths, and graceful abort. Session persistence should be first-class.

### `tanRdev/pi-desktop`

Useful ideas:

- Has the most sophisticated runtime split: renderer, main process, agent-host child process, Unix sockets.
- Supports `pi --mode rpc --continue` for CLI runtime.
- Separates agent runtime from terminal runtime.
- Terminal manager uses `node-pty` when available and falls back to normal child process.
- Enforces ownership, cwd allowlists, write size caps, scrollback caps, and cleanup.

Takeaway for Pi Manager: separate agent execution from optional terminal execution. If a terminal is added, build it with strict ownership/cwd/input limits.


## UI/UX principles from the inspiration apps

The referenced apps are useful less for their visual style and more for their product principles:

- **Session-first, not terminal-first.** Even when a terminal exists, the primary object is a session/thread with history, status, metadata, and resumability.
- **Calm UI.** `gustavonline/pi-desktop` explicitly calls out minimal visuals, neutral colors, low noise, predictable controls, and a chat-centered timeline. Pi Manager should translate this into native SwiftUI cards, not copy a web terminal aesthetic.
- **Host boundary.** The desktop app hosts windows, panes, files, tabs, notifications, project/session navigation, and native controls; Pi remains the runtime.
- **Tool activity visualization.** Stark's UI emphasizes streaming messages, collapsible messages, tool execution visualization, and a session outline sidebar. Pi Manager should show tool calls/results as structured cards and make noisy output collapsible.
- **Session browser/history.** Both Tauri-style apps treat sessions as browsable, searchable, renameable, exportable units. Pi Manager should add an issue-centric session browser.
- **Debuggability.** Stark exposes the exact launch command in an error modal. Pi Manager should expose this in diagnostics.
- **Integrated terminal as secondary surface.** Gustav includes a docked terminal; tanRdev includes a stronger node-pty terminal. But both still separate terminal/runtime concerns from session state. For Pi Manager, terminal should be an escape hatch, not the main issue workflow.
- **Isolation for parallel work.** tanRdev's UX explicitly includes repository management and Git worktree isolation for parallel branches. This is the clearest precedent for multiple simultaneous issue sessions.

For Pi Manager's design system, the equivalent UX should be:

- left: issue/session list with status badges
- center: native transcript timeline
- right/bottom: repo diff/review/finish panel
- secondary: external or embedded terminal only when the user asks for raw shell

## Integration options

### Option A — Native SwiftUI Pi RPC workspace (recommended)

Build a Swift service that spawns `pi --mode rpc` and renders the stream as native UI.

Pros:

- Best fit for Pi Manager's native macOS design.
- No terminal emulator dependency.
- Structured data: messages, tool calls, state, sessions, costs, errors.
- Can integrate deeply with issue details, repo diff, commit/push, comments, and close flow.
- Easier to add guardrails and confirmations.
- More accessible and testable than terminal text scraping.

Cons:

- Requires implementing JSONL process management and event decoding.
- Extension UI events from Pi RPC may need additional UI mapping over time.
- Need to keep pace with Pi RPC schema changes.

Decision: **use this as the primary implementation.**

### Option B — Embedded terminal inside Pi Manager

Build or embed a terminal emulator and run interactive `pi` normally.

Possible implementations:

- Swift native PTY via `forkpty` + a terminal view library such as SwiftTerm.
- WebView + xterm.js + local PTY bridge.
- External terminal launch with iTerm2/Terminal.app via AppleScript.

Pros:

- Closest to current CLI behavior.
- Lower semantic parsing burden.
- Useful as an escape hatch for users who want a shell.

Cons:

- AppKit/SwiftUI do not provide a terminal emulator.
- PTY lifecycle, resize, keyboard, paste, ANSI rendering, scrollback, and accessibility are non-trivial.
- Interactive TUI inside a GUI card will feel less native.
- Harder to safely detect task completion, tool calls, or issue-ready status.
- Harder to integrate with GitHub closing/commenting.

Decision: **do not make this the primary feature. Consider it Phase 3 as an optional “Open Terminal” utility.**

### Option C — Launch external iTerm2/Terminal/tmux session

Open a shell outside the app and run `pi` there.

Pros:

- Fastest fallback.
- Leverages users' existing terminal setup.
- Avoids embedding complexity.

Cons:

- Not actually “inside the app.”
- Poor state tracking.
- Hard to know when work is done.
- Requires iTerm2/Terminal automation permissions if automated.
- `tmux` multiplexes a shell session but does not render terminal UI inside SwiftUI.

Decision: **use only as a fallback/debug action: “Open in External Terminal”.**

### Option D — Node/TypeScript agent host using Pi SDK

Bundle a small Node helper using `@mariozechner/pi-coding-agent` SDK directly instead of spawning `pi --mode rpc`.

Pros:

- Rich API and no stdio protocol parsing in Swift.
- Could adapt existing TypeScript clients.

Cons:

- Adds a Node runtime/helper packaging problem to a native Swift app.
- More moving parts and version coupling.
- Less aligned with current app architecture.

Decision: **defer. RPC subprocess is simpler and closer to the referenced apps.**

## Recommended product workflow

### 1. Select project

The user selects a project in Pi Manager's sidebar. Requirements:

- Project must be a local git repository.
- For issue workflow, project should have a GitHub remote.
- Show readiness checks:
  - `pi` executable found
  - GitHub connected via `gh`
  - repo clean or user explicitly accepts dirty state
  - selected model/provider available

### 2. Select issue

Existing GitHub screen already supports:

- Issue board/list.
- Issue detail.
- Body, labels, comments, relationships.
- Posting comments.

Add primary action in `GitHubIssueDetailCard`:

- **Run with Pi Agent**
- Secondary menu:
  - Copy generated prompt
  - Open in external terminal
  - Start in new branch/worktree (future)

### 3. Prepare issue prompt

Generate a prompt like:

```text
You are working in this repository: /path/to/repo

GitHub issue: owner/repo#123
Title: ...
State: open
Labels: bug, ui
Author: ...
URL: ...

Issue description:
...

Relevant comments:
- user at date: ...

Relationships:
- Parent: ...
- Blocked by: ...

Task:
Implement the issue in this repository. Follow the existing design system and code style. Keep changes minimal and maintainable. Run appropriate checks if available. When finished, summarize what changed, tests run, and any follow-up needed. Do not close the issue or push without explicit user confirmation.
```

Important prompt constraints:

- Include “respect the existing native macOS design system.”
- Include selected issue acceptance criteria.
- Include repo path and branch state.
- Explicitly forbid autonomous close/push unless user opted in.
- If the repo is dirty, include current changed files or require user confirmation first.

### 4. Start Pi RPC session

Spawn from selected repo cwd:

```bash
pi --mode rpc
```

Potential options:

- `--session-dir <path>` if Pi Manager wants app-scoped sessions.
- `--session <path|id>` for continuing a previous issue session.
- `--model <pattern>` from Pi Manager's model selection.
- `--provider <name>` if exposed later.
- `--skill`, `--extension`, `--models` if chosen in advanced UI.

After process start:

1. Send `set_session_name` with `owner/repo#123 issue title`.
2. Send `prompt` with the generated issue prompt.
3. Listen for events until idle.
4. Periodically or after important events call `get_state` / `get_session_stats`.

### 5. Native agent workspace UI

Add a top-level navigation item, likely `Agent` or `Run Agent`.

Suggested layout using the existing design system:

- `AppPage("Agent", subtitle: selected project / active issue)`
- Header card:
  - selected project
  - active branch
  - issue tag
  - model
  - status: Ready / Running / Waiting / Needs input / Completed / Failed
- Main split view:
  - left sidebar: issue/session list
  - center: transcript
  - right or bottom inspector: repo changes, session info, actions
- Transcript cards:
  - User prompt card
  - Assistant response card
  - Tool call card with icon/status
  - Tool result card collapsible
  - Error card
- Composer:
  - Follow-up input when idle
  - Steer input while running
  - Stop button
  - Send button

Design rules:

- Use `AppCard`, `AppRowCard`, `AppLabelTag`, `AppTheme` colors and spacing.
- Avoid terminal-black panels as the default.
- Use monospaced text only for commands, paths, diffs, and logs.
- Keep the issue context visually linked with GitHub cards.
- Make long tool output collapsible.

### 6. Review changes

After the agent becomes idle or user stops it:

- Refresh `GitRepositoryService` state.
- Show changed files and diffs using the existing repo changes flow.
- Offer:
  - Stage selected
  - Restore selected
  - Commit
  - Push
  - Continue agent with feedback

This can reuse existing `githubRepositoryChanges` state and methods, but the Agent screen should provide a focused review panel.

### 7. Finish issue

Once user is satisfied:

- Generate/post a GitHub comment:

```md
Implemented in <branch/commit/PR>.

Summary:
- ...

Validation:
- ...

Notes:
- ...
```

- Optional close issue:
  - Add `GitHubIssueService.closeIssue(item:)` using REST PATCH `/repos/{owner}/{repo}/issues/{number}` with `{ "state": "closed" }`.
  - Consider `state_reason: "completed"` for GitHub.com where supported.
  - Always confirm before closing.


## Session handling model

This needs to be designed as a **multi-session workspace**, not as one global running agent. The mental model should be:

- A **Pi Manager Agent Session** is the app-level record the user sees.
- A **Pi session file** is Pi's persisted JSONL conversation on disk.
- A **Pi RPC process** is only the currently running runtime attached to one app session.
- A **work context** is the local repository path, branch/worktree, GitHub issue, model, and prompt metadata.

These should be separate so a user can have ten issue sessions saved, three visible in the app, and only one or two actively running processes.

### Recommended MVP behavior

For MVP, support multiple saved sessions but keep process concurrency conservative:

1. User can start a session from any GitHub issue.
2. Each issue run creates an app session record with:
   - app session UUID
   - project path
   - GitHub remote owner/repo
   - issue number/title/url/state
   - Pi session file path once known from `get_state`
   - current status: `draft`, `starting`, `running`, `idle`, `stopped`, `failed`, `completed`
   - model/provider/thinking settings
   - branch/worktree info
   - created/updated timestamps
   - last summary / last error
3. User can switch between sessions in the UI.
4. If a session is idle/stopped, switching just shows saved transcript/session metadata.
5. If a session is running, switching away keeps the process alive and shows an activity badge.
6. User can explicitly stop a running session.
7. On app quit, gracefully abort/stop running sessions unless we later add a background-agent mode.

Initial concurrency policy:

- Allow multiple session records.
- Allow multiple running processes only if each has an isolated branch/worktree or the user explicitly confirms risk.
- In the same working tree, default to **one active running agent at a time** to avoid conflicting file edits.

### Why one process per active session

This follows the strongest pattern in the inspiration apps:

- `gustavonline/pi-desktop` keeps a `HashMap<String, RpcProcessHandle>` keyed by `instance_id`; each handle owns a child process, stdin writer, and generation. Starting an instance kills/replaces the prior process for that instance.
- `StarkInternationalAI/pi-desktop` keeps `HashMap<String, ManagedProcess>` keyed by `session_id`; each process is launched with `pi --mode rpc --session <session_file>`, owns stdin/stdout tasks, and records a launch command.
- `tanRdev/pi-desktop` manages per-thread runtimes; each thread has a runtime process tied to a worktree and command signature, and an existing runtime is reused only when the worktree and command match.

Pi Manager should do the same conceptually:

```text
PiAgentSessionRecord 1 ── optional running PiRPCProcess 1 ── Pi JSONL session file 1
PiAgentSessionRecord 2 ── optional running PiRPCProcess 2 ── Pi JSONL session file 2
PiAgentSessionRecord 3 ── no process right now ───────────── Pi JSONL session file 3
```

The app session record survives process death. The process can be reattached by launching `pi --mode rpc --session <sessionFile>` when the user resumes.

### Session persistence source of truth

Use two layers:

#### 1. Pi's own JSONL session file

Pi already persists conversations under:

```text
~/.pi/agent/sessions/--<cwd>--/<timestamp>_<uuid>.jsonl
```

These files contain tree-structured entries, message history, model changes, compactions, branch summaries, labels, and `session_info` names. We should not duplicate full transcript storage unless needed for indexing/performance.

Use RPC commands to manage this:

- `get_state` to retrieve `sessionFile`, `sessionId`, `sessionName`, streaming status.
- `set_session_name` to name sessions like `owner/repo#123 — Fix crash on launch`.
- `get_messages` to hydrate transcript if needed.
- `get_session_stats` for token/cost.
- `switch_session` or launch with `--session <path>` for resume.
- `new_session` for a new issue thread.

#### 2. Pi Manager's app metadata index

Store lightweight metadata in app preferences/Application Support, for example:

```json
{
  "id": "app-session-uuid",
  "projectPath": "/Users/andrea/Documents/GitHub/app",
  "repository": "owner/repo",
  "issueNumber": 123,
  "issueTitle": "Fix crash on launch",
  "issueURL": "https://github.com/owner/repo/issues/123",
  "piSessionFile": "/Users/andrea/.pi/agent/sessions/...jsonl",
  "piSessionId": "...",
  "status": "idle",
  "branch": "main",
  "worktreePath": null,
  "model": "anthropic/claude-sonnet-4-5",
  "createdAt": "...",
  "updatedAt": "..."
}
```

This lets Pi Manager show issue-centric sessions even if Pi's native session list is cwd-centric.

### Multiple issues at the same time

There are three levels of support:

#### Level 1 — multiple issue sessions, one active writer per repo/worktree

Best MVP. Users can create/switch/resume many issue sessions, but Pi Manager prevents two agents from writing to the same working tree concurrently.

If issue #10 is running in `/repo`, starting issue #11 in `/repo` should offer:

- Stop/pause #10 and start #11.
- Open #11 as a saved draft only.
- Start #11 anyway after explicit warning.
- Start #11 in a new worktree if worktree support exists.

#### Level 2 — multiple concurrent sessions across different repos

Safe and useful. If the cwd/project paths differ, allow concurrent processes with badges in the session sidebar.

#### Level 3 — multiple concurrent sessions in one repo via worktrees

Ideal final state. Each issue gets an isolated worktree:

```text
main repo:     /Users/andrea/Documents/GitHub/my-app
issue #10:     /Users/andrea/Documents/GitHub/.pi-manager-worktrees/my-app/issue-10
issue #11:     /Users/andrea/Documents/GitHub/.pi-manager-worktrees/my-app/issue-11
```

Then concurrent agents are safe because they operate in separate directories/branches. This mirrors tanRdev's thread/worktree runtime idea.

### Resuming sessions

A saved session should be resumable even if no process is running:

1. User selects an old Agent session.
2. App checks `piSessionFile` exists.
3. App launches:

```bash
pi --mode rpc --session /path/to/session.jsonl
```

4. App sends `get_state`, `get_messages`, `get_session_stats`.
5. UI hydrates transcript and becomes ready for follow-up.

If the session file is missing, show a recoverable error and offer to start a new session from the same issue.

### Session sidebar UI

The Agent screen should have a session sidebar grouped by project/repository:

- Running
- Idle / recently updated
- Completed
- Failed / needs attention

Each row should show:

- Issue number and title
- Project/repo
- status dot
- branch/worktree tag
- last updated
- small changed-files indicator if dirty

Actions per session:

- Open
- Resume
- Stop
- Rename
- Reveal Pi session file
- Export/share session
- Archive/remove from Pi Manager
- Delete Pi session file, only with strong confirmation

### Completion state

Do not infer “completed” only from the Pi process exiting. Track completion as a user/app workflow state:

- `running`: Pi is processing.
- `idle`: Pi is waiting, repo may have changes.
- `reviewing`: user is reviewing diff.
- `committed`: commit created.
- `pushed`: branch pushed.
- `commented`: GitHub comment posted.
- `closed`: issue closed.
- `completed`: user marks session done.

This allows users to stop/resume/continue without losing the issue workflow.

### Important implementation details copied from the inspiration apps

- Use a process map keyed by app session ID / Pi session ID.
- Add a generation number per process so late stdout from killed processes is ignored.
- Store stdin writer separately and serialize writes.
- Capture stderr as diagnostics, not transcript.
- Store/display the shell-escaped launch command.
- On stop: send RPC `abort`, wait briefly, close stdin/drop writer, then terminate.
- Reuse a process only if session ID, cwd/worktree, command/model signature still match.
- Never allow two uncontrolled agents to write to the same cwd without warning.

## Technical architecture

### New types/services

Add a dedicated service layer rather than bloating `AppViewModel`.

Suggested files:

- `pi-manager/PiAgentProcess.swift`
  - low-level `Process` wrapper
  - executable resolution
  - stdout/stderr streaming
  - stdin writes
  - termination/abort
- `pi-manager/PiRPCClient.swift`
  - JSONL framing
  - command IDs
  - typed command send methods
  - event stream callbacks / `AsyncStream`
- `pi-manager/PiAgentSessionModels.swift`
  - `PiAgentSessionState`
  - `PiAgentTranscriptEntry`
  - `PiAgentRunStatus`
  - `PiAgentToolCall`
  - `PiAgentIssueContext`
- `pi-manager/PiIssuePromptBuilder.swift`
  - builds deterministic prompts from `GitHubIssueDetail`
- `pi-manager/PiAgentRunnerService.swift`
  - higher-level orchestration for issue runs
- `pi-manager/PiAgentViews.swift`
  - Agent screen and transcript UI

### Process management requirements

`CommandRunner` should not be reused directly because it buffers output until process exit. Instead, create a streaming process runner with:

- executable discovery equivalent to `CommandRunner`, plus robust Homebrew/npm paths:
  - user configured path
  - `PI_MANAGER_PI_PATH`
  - `PI_CLI_PATH`
  - shell `command -v pi`
  - `/opt/homebrew/bin/pi`
  - `/usr/local/bin/pi`
  - npm global bin paths if known
- `currentDirectoryURL` set to selected project root.
- Environment merge from `ProcessInfo.processInfo.environment`.
- PATH repair for GUI-launched apps.
- Incremental stdout parsing by LF only.
- stderr surfaced as diagnostics/logs.
- stdin write queue serialized on a background queue/actor.
- graceful stop:
  1. send RPC `abort`
  2. close stdin if needed
  3. `terminate()`
  4. kill escalation only if still running after timeout
- generation/session ID guard to ignore late events from killed processes.

### State management

Add to `AppViewModel` or a child `@StateObject`:

- `agentSessions: [PiAgentSessionSummary]`
- `activeAgentSessionID: UUID?`
- `activeAgentTranscript: [PiAgentTranscriptEntry]`
- `activeAgentStatus: PiAgentRunStatus`
- `activeAgentIssue: GitHubIssueDetail?`
- `activeAgentError: String?`
- `agentComposerText: String`
- `agentIsStarting`, `agentIsStopping`

Keep long transcript storage outside the main view model if possible to avoid giant `@Published` redraws. A dedicated `PiAgentSessionStore` or `ObservableObject` per session would scale better.

### Mapping RPC events to UI

Start with a tolerant decoder:

- Decode top-level `type`.
- Preserve raw JSON for unknown events.
- Map known message/tool/status events as they are encountered.
- Never crash on unknown schema.

UI event categories:

- session/state events
- assistant text deltas or message updates
- tool start/update/end
- command responses
- extension UI requests
- errors/stderr

Unknown events should appear in a collapsible diagnostics section during development.

### Extension UI events

Pi extensions can ask the host UI for interaction. The app should handle these progressively:

MVP:

- Detect extension UI request events.
- Show a clear unsupported/diagnostic card if not yet implemented.
- Let user open the same session in external terminal if blocked.

Later:

- Map confirmation prompts to native alert/sheet.
- Map selection prompts to SwiftUI pickers.
- Map text prompts to modal text input.

## GitHub issue integration details

### Existing capabilities

`GitHubIssueService` can:

- fetch detail
- fetch comments
- fetch relationships
- post comments

Add:

- close issue
- reopen issue, optional
- assign/label, optional later

### Closing issue

Implement with API client PATCH support if not present:

```http
PATCH /repos/{owner}/{repo}/issues/{issue_number}
Content-Type: application/json

{
  "state": "closed",
  "state_reason": "completed"
}
```

Fallback if `state_reason` fails: retry with only `state`.

UI must require explicit confirmation:

- Show issue number/title.
- Show branch/commit state.
- Warn if unpushed commits or uncommitted changes remain.

### Commenting from agent result

Options:

1. Manual: Pi Manager drafts comment; user edits/posts.
2. Assisted: ask agent to produce final summary, then draft comment.
3. Automatic: post after commit/push if user enabled an explicit checkbox.

Decision: **default to manual draft with one-click post.**

## Branch/worktree decisions

This is important because an agent can modify many files.

### MVP: current working tree with dirty-state warning

Pros:

- Simple.
- Matches current app model.
- Easy to reuse existing repo changes UI.

Cons:

- Agent can mix with user changes.
- Harder to isolate multiple issues.

Require confirmation if repo has uncommitted changes.

### Better: issue branch

Before starting:

```bash
git checkout -b pi/issue-123-short-title
```

Pros:

- Clear history.
- Easier push/PR/comment.

Cons:

- Branch creation failure cases.
- Users may not want branch switching.

Add as Phase 2 option.

### Best isolation: git worktree per issue

Create `.pi-manager/worktrees/issue-123` or sibling directory.

Pros:

- Safe parallel issue work.
- Keeps main working tree untouched.
- Great for multiple agent sessions.

Cons:

- More UI complexity.
- Cleanup management.
- Project discovery/sidebar needs to understand worktrees.

Add as Phase 3 for power users.

## Terminal/iTerm2/tmux/cmux analysis

### iTerm2 inside the app

Not a good primary route. iTerm2 is an application, not an embeddable SwiftUI control. Pi Manager can automate or launch iTerm2 externally, but embedding iTerm2's terminal view inside Pi Manager is not a supported clean integration.

Use case: fallback action:

- “Open this issue prompt in iTerm2”
- Creates a temp prompt file
- Opens iTerm2 at repo cwd
- Runs `pi < prompt` or copies prompt to clipboard

### Terminal.app

Same story as iTerm2: useful external fallback, not in-app embedding.

### tmux

`tmux` can preserve/multiplex shell sessions, but it does not solve rendering in SwiftUI. It can be useful behind an external terminal or an embedded PTY, but it adds dependency and complexity.

### cmux / similar multiplexers

If the intent is a terminal multiplexer, the same limitation applies: multiplexers manage terminal sessions; they do not provide a native macOS UI surface. Not recommended for MVP.

### Native PTY terminal

If Pi Manager later needs a shell:

- Use a proven macOS terminal view if possible.
- Use `forkpty` or a library wrapper.
- Enforce allowed cwd roots.
- Cap paste/write size.
- Cap scrollback memory.
- Track owning window/session.
- Destroy child process on window/session close.

But this should be separate from the Pi RPC agent workspace.

## Security and safety

Pi Agent can execute tools and edit files. Pi Manager should add guardrails:

- Only run in selected/discovered project roots unless user manually confirms another path.
- Warn when repo is dirty before starting.
- Show generated prompt before first run or offer preview.
- Never auto-push or auto-close by default.
- Show destructive tool calls prominently if RPC events expose them.
- Add Stop/Abort always visible.
- Keep launch command diagnostics visible.
- Capture stderr and process exit code.
- Do not store tokens; rely on existing Pi/GitHub auth.
- Avoid logging full secrets from env/stderr.

## UX details that protect the design system

Avoid making the main screen look like a terminal. The feature should feel like a native Pi Manager workflow:

- Header card: clear status and issue/project context.
- Transcript cards: readable assistant/tool activity.
- Compact tags for issue, branch, model, status.
- Collapsible tool output.
- Dedicated review panel for diffs.
- Clear primary actions:
  - Start
  - Stop
  - Continue
  - Review Changes
  - Commit
  - Push
  - Draft Comment
  - Close Issue
- Use external terminal only as a secondary utility.

## Implementation phases

### Phase 0 — Spike/proof of protocol

Goal: prove Swift can spawn Pi RPC and stream events.

Tasks:

- Add a temporary command-line or internal service spike.
- Resolve `pi` path.
- Spawn `pi --mode rpc --no-session` in a test repo.
- Send `get_state` and a small `prompt`.
- Parse JSONL stdout incrementally.
- Abort and terminate cleanly.

Exit criteria:

- Can see streamed events in Xcode logs.
- Can stop process without orphaning it.
- Unknown events do not crash parser.

### Phase 1 — Native agent MVP

Tasks:

- Add `PiAgentProcess`, `PiRPCClient`, session models.
- Add `PiIssuePromptBuilder`.
- Add Agent screen.
- Add `Run with Pi Agent` button in GitHub issue detail.
- Show transcript and status.
- Support stop, follow-up, steer.
- Refresh repo changes after idle.

Exit criteria:

- User can select issue, start agent, watch output, stop/continue, and see changed files.

### Phase 2 — Completion workflow

Tasks:

- Add close issue API.
- Add draft summary/comment flow.
- Add commit/push integration from Agent screen.
- Add session name and session file display.
- Add reopen/refresh issue state after close.

Exit criteria:

- User can complete the issue loop inside Pi Manager with explicit confirmations.

### Phase 3 — Isolation and persistence

Tasks:

- Add issue branches.
- Add optional worktree-per-issue mode.
- Add session list/history per project/issue.
- Add continue previous issue session.
- Add exported session link/comment attachment if desired.

Exit criteria:

- Multiple issue sessions can be managed safely.

### Phase 4 — Optional terminal

Tasks:

- Add external terminal fallback first.
- Evaluate native PTY terminal only if there is still a real need.
- Keep terminal separate from structured Agent workspace.

Exit criteria:

- Power users can drop into shell without weakening the main workflow.

## Key decisions to make

### Decision 1: Primary interface

Recommendation: **Native RPC workspace**.

Alternative: embedded terminal. Not recommended for primary feature.

### Decision 2: Working tree strategy for MVP

Recommendation: **current working tree with dirty-state warning**.

Alternative: branch/worktree from day one. Safer but slower to ship.

### Decision 3: Session storage

Recommendation: use Pi's default sessions initially, but set a native session name tied to issue number.

Later: app-scoped session directory or metadata index if needed.

### Decision 4: Issue close behavior

Recommendation: explicit user confirmation only, after review/commit/push state is visible.

### Decision 5: Terminal support

Recommendation: external terminal fallback first; embedded terminal only after RPC workspace proves insufficient.

## Open questions

- Should the Agent screen be a top-level sidebar item or live under GitHub? Recommended: top-level `Agent`, with GitHub issue action deep-linking into it.
- Should Pi Manager create branches automatically? Recommended: no for MVP, yes as an opt-in setting later.
- Should comments be agent-generated automatically? Recommended: draft automatically, post manually.
- Should close happen after commit, push, or PR creation? Recommended: user-configurable later; MVP just confirms current repo state.
- How much of Pi extension UI protocol is required for real-world sessions? Start with diagnostics and implement native prompts as usage reveals needs.

## Suggested first implementation slice

Smallest useful vertical slice:

1. Create `PiRPCClient` that can spawn, send `prompt`, receive raw JSON events, abort.
2. Add `PiAgentViews.swift` with a simple native transcript showing raw/known events.
3. Add `Run with Pi Agent` in `GitHubIssueDetailCard`.
4. Generated issue prompt from title/body/comments.
5. On idle/stop, call `refreshRepositoryChanges()`.

This proves the product loop without committing to terminal complexity.

## Final recommendation

Build the feature as a **native issue-to-agent-to-diff workflow**, not an embedded terminal. Use Pi RPC for structured control, preserve Pi Manager's design system, and keep terminal/iTerm/tmux as fallback utilities. The winning experience is not “Pi CLI in a box”; it is “Pi Manager understands my repo and issue, runs Pi safely, shows me what happened, and helps me finish the GitHub loop.”
