# Implementation Plan

## Goal
Add an end-to-end in-app Pi Agent MVP that can start `pi --mode rpc` for the selected project or GitHub issue, stream transcript events into SwiftUI, persist session metadata, and refresh repo changes after the agent runs.

## Tasks
1. **Define MVP models for sessions, transcripts, and RPC JSON**
   - File: `pi-manager/PiAgentSessionModels.swift`
   - Changes: Add `PiAgentSessionKind`, `PiAgentRunStatus`, `PiAgentSessionRecord`, `PiAgentTranscriptEntry`, `PiAgentInputMode`, `PiAgentRPCMessage`, and a small `JSONValue` enum for preserving arbitrary RPC payloads. Include fields for project path/name, GitHub repo/issue metadata, Pi `sessionFile`, Pi `sessionId`, launch command, timestamps, status, last error, and raw event text.
   - Acceptance: Models compile with `Codable`, `Identifiable`, `Hashable` where needed; unknown RPC event JSON can be stored without losing raw text.

2. **Add a persistent session store**
   - File: `pi-manager/PiAgentSessionStore.swift`
   - Changes: Create a `@MainActor ObservableObject` that loads/saves JSON at `~/Library/Application Support/Pi Manager/agent-sessions.json`; persists session records and bounded transcript entries per session; exposes helpers to create/update/select sessions, append/update transcript entries, mark status, and resolve the active session.
   - Acceptance: Creating a session writes the JSON file; relaunching the app restores session list and recent transcript entries; corrupt store files fail gracefully with an empty store and a diagnostic error.

3. **Implement a streaming Pi process wrapper**
   - File: `pi-manager/PiAgentProcess.swift`
   - Changes: Add a low-level process wrapper for long-running `Process` with stdout/stderr incremental callbacks, serialized stdin writes, and graceful shutdown. Resolve `pi` via `PI_MANAGER_PI_PATH`, `PI_CLI_PATH`, user shell `command -v pi`, `/opt/homebrew/bin/pi`, `/usr/local/bin/pi`, and npm/Homebrew global candidates. Repair GUI-launched `PATH` by prepending common bin paths.
   - Acceptance: Can launch `pi --mode rpc` in a selected repo cwd, emit stdout lines split only on LF with optional trailing CR stripped, surface stderr as diagnostics, write JSONL to stdin, and terminate without orphaned processes.

4. **Implement the Pi RPC client**
   - File: `pi-manager/PiRPCClient.swift`
   - Changes: Build on `PiAgentProcess` to send JSONL commands with request IDs and parse stdout into responses/events. Add helpers for `get_state`, `set_session_name`, `prompt`, `steer`, `follow_up`, `abort`, `get_session_stats`, and `get_last_assistant_text`. Preserve unknown events as raw JSON and never crash on schema changes.
   - Acceptance: A smoke run can send `get_state`, receive a `response`, send `prompt`, stream `message_update` / tool events, and send `abort` successfully.

5. **Create deterministic prompt builders**
   - File: `pi-manager/PiIssuePromptBuilder.swift`
   - Changes: Add prompt builders for GitHub issue sessions and blank project sessions. Issue prompts should include repo path, issue title/number/url, labels, assignees, body, relationship summaries, recent comments, and completion rules: make code changes only as needed, respect existing design/system style, do not commit/push/close automatically, summarize changed files and validation steps.
   - Acceptance: Prompt output is stable, readable, and does not include empty sections; issue prompt can be copied/logged for debugging.

6. **Add an agent runner service**
   - File: `pi-manager/PiAgentRunnerService.swift`
   - Changes: Orchestrate one active RPC process for MVP. Start `pi --mode rpc --session-dir <Application Support/Pi Manager/PiSessions>` in the session project cwd, send `set_session_name`, `get_state`, and the initial `prompt`; map known RPC events into transcript entries; update session status on `agent_start`, `agent_end`, errors, and termination; on stop send `abort` first, then terminate after a short timeout.
   - Acceptance: Starting a run creates a session, streams user/assistant/tool/status entries, records Pi session path/id from `get_state`, and transitions to completed/failed/stopped accurately.

7. **Expose Pi Agent state/actions through `AppViewModel`**
   - File: `pi-manager/AppViewModel.swift`
   - Changes: Add a `PiAgentSessionStore` property and runner service. Add methods `openPiAgentForSelectedProject()`, `startPiAgentForSelectedProject(initialPrompt:)`, `startPiAgentForIssue(_:)`, `selectPiAgentSession(_:)`, `sendPiAgentMessage(_:mode:)`, `stopActivePiAgent()`, and cleanup in `deinit`. After `agent_end` or stop, call `refreshRepositoryChanges(preservingDiffSelection: true)` for the session project if it is still selected.
   - Acceptance: ViewModel can start a project or issue session, navigate to the Agent screen, stop a run, send steer/follow-up messages, and refresh repo status when the run finishes.

8. **Add the Agent screen and sidebar navigation**
   - Files: `pi-manager/PiAgentViews.swift`, `pi-manager/AppViewModel.swift`, `pi-manager/ContentView.swift`
   - Changes: Add `SidebarItem.agent` and include it in the Workspace section. Add `PiAgentScreen` using existing `AppPage`, `AppCard`, `AppSidebarPane`, `AppRowCard`, and `AppLabelTag`: left session list, center transcript, bottom composer, top controls for New Project Session, Stop, copy launch command, and View Repo Changes. Show raw/unknown events in collapsible diagnostics cards.
   - Acceptance: Sidebar has an Agent item; selecting it shows session list/transcript; a selected project can start a new session from this screen; transcript auto-scrolls enough for MVP and remains usable with long output.

9. **Add GitHub issue entry point**
   - File: `pi-manager/GitHubViews.swift`
   - Changes: In `GitHubIssueDetailCard`, add a primary `Run with Pi Agent` button near the issue header. It calls `viewModel.startPiAgentForIssue(detail)` and switches to the Agent screen. Disable or show an inline error when no selected local project/repo is available.
   - Acceptance: From GitHub Project Board, selecting an issue and pressing the button starts a Pi Agent session in the selected repo with the generated issue prompt.

10. **Add project-first entry points**
   - Files: `pi-manager/PiAgentViews.swift`, `pi-manager/ContentView.swift`
   - Changes: Add a New Project Session flow on the Agent screen for the currently selected project. Optionally add a compact `Agent` button to project rows/cards if it fits without disrupting the existing UI; otherwise the Agent sidebar entry is the MVP project entry point.
   - Acceptance: User can select a project from the sidebar/project list, open Agent, enter an initial instruction, and start a session without GitHub.

11. **Integrate with existing repo workflow**
   - Files: `pi-manager/PiAgentViews.swift`, `pi-manager/AppViewModel.swift`, `pi-manager/GitHubViews.swift`
   - Changes: In the Agent screen, show a `View Repo Changes` action that switches to `.github` and `.repoChanges` for the active session project. Reuse existing commit/push UI instead of duplicating it in the Agent MVP.
   - Acceptance: After agent completion, changed files are visible via the existing Repo Changes screen and can be staged/committed/pushed there.

12. **Build integration and validation**
   - File: `pi-manager.xcodeproj/project.pbxproj`
   - Changes: No edit should be needed because the project uses `PBXFileSystemSynchronizedRootGroup` for `pi-manager/`. If Xcode does not compile new Swift files, update the project file to include them in the app target sources.
   - Acceptance: `xcodebuild -project pi-manager.xcodeproj -scheme pi-manager -configuration Debug build` succeeds; app launches; no new files are excluded from the target.

13. **Manual end-to-end validation**
   - Files: all changed files
   - Changes: Validate these flows manually: project session start/stop; issue session start from GitHub detail; streaming text/tool events; steer/follow-up composer; repo changes refresh after completion; relaunch restores session metadata; quit/stop leaves no running `pi --mode rpc` child.
   - Acceptance: Record any RPC schema mismatches or UI blockers before calling the MVP complete.

## Files to Modify
- `pi-manager/AppViewModel.swift` - add Agent state/actions, runner/store ownership, sidebar enum case, repo refresh integration.
- `pi-manager/ContentView.swift` - add Agent detail routing and workspace sidebar item; optionally add project-card project session entry.
- `pi-manager/GitHubViews.swift` - add `Run with Pi Agent` issue action and link Agent completion to existing repo changes workflow.
- `pi-manager.xcodeproj/project.pbxproj` - only if file-system synchronized groups do not include the new Swift files automatically.

## New Files
- `pi-manager/PiAgentSessionModels.swift` - session, transcript, status, input mode, and JSON payload models.
- `pi-manager/PiAgentSessionStore.swift` - persistent in-app session metadata/transcript store.
- `pi-manager/PiAgentProcess.swift` - streaming process/stdin/stdout/stderr wrapper for `pi`.
- `pi-manager/PiRPCClient.swift` - JSONL RPC command/event client.
- `pi-manager/PiIssuePromptBuilder.swift` - GitHub issue and project prompt generation.
- `pi-manager/PiAgentRunnerService.swift` - higher-level start/stop/send/event orchestration.
- `pi-manager/PiAgentViews.swift` - Agent screen, session list, transcript cards, controls, and composer.

## Dependencies
- Tasks 1-2 must land before runner/view integration.
- Tasks 3-4 must land before any real Agent run can work.
- Task 5 is required before GitHub issue runs.
- Task 6 depends on Tasks 1-5.
- Tasks 7-11 depend on Task 6.
- Task 12 depends on all new files being present.
- Task 13 depends on a successful Debug build.

## Risks
- The project uses default main-actor isolation; keep process/RPC work off the main actor and only publish UI updates back on `MainActor` to avoid UI freezes and concurrency compile errors.
- RPC schemas can evolve; decode only the fields needed for MVP and preserve raw JSON for unknown events.
- `CommandRunner` is not suitable for streaming because it buffers until exit; do not reuse it for Agent runtime except as inspiration for executable resolution.
- Long transcripts can cause SwiftUI redraw pressure; cap persisted transcript entries for MVP and avoid publishing every raw byte separately.
- Running agents in the current working tree can modify dirty repos; MVP should at least show current repo status and never auto-commit, auto-push, or close issues.
- Only one active process is planned tonight. Parallel sessions/worktrees should be deferred.
- If Pi extension UI requests appear, MVP should show a diagnostic unsupported card rather than blocking silently.
- Build may depend on the installed `pi` CLI and local model credentials; validation needs a machine where `pi --mode rpc` works from Terminal.