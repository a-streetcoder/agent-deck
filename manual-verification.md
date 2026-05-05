# Manual Verification Checklist — Native Subagents Replacement

Use this checklist to validate the changes from today's native subagents work, including the app-managed replacement for old `pi-subagents` / `pi-intercom` flows, right-sidebar activity, repo changes, graph/worktree behavior, and recent UI polish.

When you finish items, tell me the item IDs that passed/failed and any notes/screenshots. I will update this file by ticking completed items and recording failures.

## Scope reviewed

This checklist covers the current working tree plus today's committed changes:

- Native single subagent execution and transcripts
- Main and inspector composer native launch paths
- App artifact files/actions and no accidental project output
- Agent config/private skill fidelity and skill source diagnostics
- Parent bridge tools: `managed_subagent`, `managed_chain`, `managed_parallel`
- Parent plan tools: `set_session_plan`, `update_session_plan`
- Supervisor routing: child `contact_supervisor`, parent `list_supervisor_requests`, `answer_supervisor_request`
- Native graph controls for chains/parallel runs
- Worktree patch/apply/discard paths
- Explicit output policy and read-first files
- Activity sidebar: Current Plan, Native Subagents, tool activity, diffs
- Repo Changes sidebar: changed files, staging, commit UI, push state
- Startup resources, subagent footer popover, run-card polish, autoscroll
- Scanner fix for skills not appearing as agents
- `.gitignore` noise suppression

## Test setup

- App: `/tmp/pi-manager-build/pi-manager.app`
- Test project: `/Users/andrea/Documents/GitHub/claude-code-meter`
- Drive the app manually. Do not let the coding agent open or control the app.
- Before destructive tests, ensure the test repo has no valuable uncommitted work.
- Prefer throwaway files under `tmp/` for edit/write tests.

---

## A. Launch, project, and clean UI baseline

- [x] **MV-A1 — Launch latest build manually**
  1. Quit any older Pi Manager instances.
  2. Open `/tmp/pi-manager-build/pi-manager.app` manually.
  3. Select `/Users/andrea/Documents/GitHub/claude-code-meter`.
  Expected:
  - You are using the latest build, not the Xcode DerivedData app.
  - Pi Agent screen loads without stale warnings or broken layout.

- [x] **MV-A2 — Startup resources collapsed by default**
  1. Open/create a Pi Agent session.
  2. Inspect the `Pi startup resources` card.
  Expected:
  - Header and shortcut chips are visible.
  - Resource lists are hidden by default.
  - Chevron expands/collapses smoothly.
  - Skills do not dominate the chat.

- [x] **MV-A3 — Agent scanner does not show skills as agents**
  1. Expand startup resources.
  2. Inspect Agents list.
  Expected:
  - Builtins/custom agents appear.
  - `.agents/skills/*/SKILL.md` entries do **not** appear as agents.

- [x] **MV-A4 — Autoscroll baseline**
  1. Scroll upward in the transcript.
  2. Paste/type into the composer.
  3. Send a simple message and wait for the reply.
  Expected:
  - The transcript scrolls to the latest message/reply.
  - No jittery per-keystroke scrolling.
  - Composer remains responsive.

---

## B. Composer subagent popover and enablement

- [x] **MV-B1 — Footer subagent popover layout**
  1. Click the subagent icon in the composer footer.
  Expected:
  - The same popover opens every time.
  - Agent rows are full-width clickable.
  - Each row has a right-side action icon.
  - The `Subagents` toggle is at the bottom, label left and switch far right.

- [x] **MV-B2 — Toggle disables manual native launches**
  1. In the footer popover, turn Subagents off.
  2. Reopen the popover.
  Expected:
  - Disabled state is clear.
  - Agent list is hidden/disabled.
  - Turn Subagents back on before continuing.

- [x] **MV-B3 — Toggle persists as default for new sessions**
  1. Turn Subagents off.
  2. Create a new Pi Agent session.
  3. Check the footer popover state.
  4. Turn Subagents back on and create another new session.
  Expected:
  - New sessions follow the last toggle state.
  - Current session and future default stay in sync.

- [ ] **MV-B4 — Main and inspector composer launch paths**
  1. From the main composer footer, open the native subagent picker and run a harmless no-edit task.
  2. Open the Pi Agent inspector for the same session.
  3. From the inspector composer, open the native subagent picker and run the same harmless no-edit task.
  Expected:
  - Both launch paths open native Run Subagent UI, not raw text insertion.
  - Neither path inserts `/run ...` into the composer.
  - Neither path sends `/run ...` to the parent Pi session.
  - Disabled agents do not appear in either native picker.

---

## C. Manual native subagent runs

- [ ] **MV-C1 — Manual scout report-only run**
  Run manual subagent:
  - Agent: `scout`
  - Outcome: `Report only`
  - Worktree: off
  - Task:

  ```text
  Use bash to run `pwd`. Then answer normally with exactly these three lines:

  Hello from scout.
  cwd: <the pwd output>
  files edited: no

  Do not inspect or edit any files.
  ```

  Expected:
  - Run starts and completes.
  - No heuristic blocks the task.
  - Card shows `scout` + `Completed`.
  - Parent transcript receives exactly one native start/status flow and exactly one completion/failure result flow.
  - There are no duplicate parent replies caused by both parent and child answering the task.
  - Task renders as a compact markdown Task message.
  - Answer renders as an assistant-style Answer message.
  - Metadata line uses icons, no pills/dot separators.
  - Total tokens/model/thinking appear when available.

- [ ] **MV-C2 — Run card Transcript sheet**
  1. Click `Transcript` on the completed scout card.
  Expected:
  - Sheet has an explicit Close button.
  - Task and Answer are visible first.
  - Execution log/details are collapsed or visually secondary.
  - Full long task is visible in the transcript even if card preview is truncated.

- [ ] **MV-C3 — Run card info popover**
  1. Click the `info.circle` button on the subagent card.
  Expected:
  - Popover opens near the card.
  - Advanced details are there: status, requested/resolved context, timestamps/duration, model/thinking, artifact directory, output path, child session file, and worktree path when available.
  - Advanced actions are in the popover, not cluttering the main card.

- [ ] **MV-C4 — Long task truncation**
  Run `scout` with a deliberately long multi-paragraph no-edit task.
  Expected:
  - Task preview is capped and ellipsized.
  - Card does not become huge.
  - Full task remains visible through Transcript/tooltip.

- [ ] **MV-C5 — Read-first file hint**
  Run `scout` with:
  - Files to read first: `AGENTS.md` if present, or another small project-relative file.
  - Task asks scout to mention whether the read-first hint was provided and to avoid edits.
  Expected:
  - Absolute paths and `..` are rejected if attempted.
  - Project-relative read hints are accepted.
  - The child is instructed to read current project files first if relevant; files are not injected as stale forced content.

- [ ] **MV-C6 — App artifact files and actions**
  1. Complete any harmless manual subagent run.
  2. Open the run info popover and Transcript sheet.
  3. Use available artifact Open/Reveal actions.
  Expected:
  - Artifacts are under `~/Library/Application Support/Pi Manager/Subagent Runs/<run-id>/`.
  - `input.md`, `system-prompt.md`, and `output.md` exist for a completed run.
  - Artifact actions open/reveal the expected files or folder.
  - A harmless report-only run does not create accidental project files such as `plan.md`.

- [ ] **MV-C7 — Agent config and private skill fidelity**
  1. Pick an enabled agent with visible non-default config if available.
  2. Run a harmless no-edit task.
  3. Inspect run details and `system-prompt.md`.
  Expected:
  - Agent `model`, `thinking`, `tools`, configured `extensions`, `inheritSkills`, `inheritProjectContext`, `defaultContext`, and `defaultReads` are reflected in launch behavior/UI where configured.
  - Agents with private library skills receive those skill contents even when the skills are not globally/project enabled.
  - Skill source diagnostics distinguish project/global/library/package/builtin skills.

---

## D. Parent bridge replacement for old `pi-subagents`

- [ ] **MV-D1 — Parent `managed_subagent` tool path**
  Send to parent chat:

  ```text
  Use the native managed_subagent tool.

  Call managed_subagent with:
  - agent: scout
  - context: fresh
  - task: Use bash to run `pwd`. Then answer exactly:
    parent bridge scout ok
    cwd: <pwd output>
    files edited: no

  After the tool returns, briefly summarize the result.
  ```

  Expected:
  - Parent uses `managed_subagent`, not old `/run` text.
  - Native run card appears.
  - Tool result returned to parent is compact.
  - No old `pi-subagents` / `pi-intercom` broker wording appears.

- [ ] **MV-D2 — Parent bridge disabled guard**
  1. Turn Subagents off in the footer popover.
  2. Send:

  ```text
  Try to use managed_subagent with agent scout and task "say disabled smoke ok".
  ```

  Expected:
  - Parent receives a clean disabled message.
  - No child run starts.
  - No partial/broken cards appear.
  - Turn Subagents back on afterward.

- [ ] **MV-D3 — Parent bridge `reads` and context override**
  Send:

  ```text
  Use managed_subagent with agent scout, context fresh, reads ["AGENTS.md"], and task:
  Report the current working directory and say whether you were given a read-first hint. Do not edit files.
  ```

  Expected:
  - Run metadata shows requested/resolved context clearly.
  - Read-first file is captured in advanced details.
  - Result is returned compactly to parent.

- [ ] **MV-D4 — Parent bridge fork context override**
  After the parent session has a Pi session file, send:

  ```text
  Use managed_subagent with agent scout, context fork, and task:
  Say whether you were launched with forked context if that is visible to you. Then answer "fork context smoke completed". Do not edit files.
  ```

  Expected:
  - Native run launches with requested context `fork` when possible.
  - If no parent session file is available, the run records a clear fallback warning instead of silently changing behavior.
  - Parent receives a compact result.

---

## E. Supervisor routing replacement for `pi-intercom`

- [ ] **MV-E1 — Child progress update**
  Manual `scout` task:

  ```text
  Use contact_supervisor with kind "progress_update", title "Progress smoke", and message "progress update smoke ok".
  Then answer exactly:
  progress update completed
  files edited: no
  ```

  Expected:
  - Progress update appears in parent/session activity without blocking.
  - Child continues and completes.
  - No raw extension bridge noise dominates the transcript.

- [ ] **MV-E2 — Blocking child decision, human response**
  Manual `scout` task:

  ```text
  Use contact_supervisor with kind "need_decision", title "Supervisor smoke", and message "Reply with APPROVED to continue."

  After the supervisor replies, answer exactly:
  supervisor result: <the supervisor response>
  files edited: no
  ```

  Expected:
  - Run becomes `Blocked`.
  - Supervisor request card appears in parent transcript.
  - Type `APPROVED` and send response.
  - Child resumes and final answer includes `APPROVED`.

- [ ] **MV-E3 — Blocking child decision, parent-agent response**
  1. Start a `scout` run that asks `contact_supervisor(kind: "need_decision")`.
  2. In parent chat, send:

  ```text
  Use list_supervisor_requests. If there is a pending supervisor request, answer it with answer_supervisor_request using response "APPROVED_BY_PARENT".
  ```

  Expected:
  - Parent lists pending request.
  - Parent answers it through native bridge.
  - Child resumes and final answer includes `APPROVED_BY_PARENT`.

- [ ] **MV-E4 — Structured interview request**
  Manual `scout` task:

  ```text
  Use contact_supervisor with kind "interview_request", title "Interview smoke", and this exact JSON as the message:
  {"prompt":"Fill the smoke fields.","questions":[{"id":"decision","label":"Decision","type":"text","required":true,"placeholder":"approved/rejected"},{"id":"note","label":"Note","type":"text","required":false,"placeholder":"optional note"}]}

  After the supervisor responds, answer with the raw response you received and say files edited: no.
  ```

  Expected:
  - Supervisor card renders structured fields, not a plain text area.
  - Required field gates the Send Response button.
  - Child receives JSON response and completes.

- [ ] **MV-E5 — Stopping a blocked child clears supervisor state**
  1. Start a manual `scout` task that calls `contact_supervisor(kind: "need_decision")` and waits.
  2. When the run is blocked, stop the child/run from the card.
  Expected:
  - Pending supervisor request is cancelled/cleared.
  - Child/run status becomes stopped/disconnected/failed clearly, not permanently blocked.
  - Any waiting parent bridge call receives a stopped result if applicable.

---

## F. Parent plan tools and Activity sidebar

- [ ] **MV-F1 — Current Plan appears in Activity sidebar**
  1. Open the Agent toolbar `Activity` sidebar.
  2. Send parent prompt:

  ```text
  Use set_session_plan with three items:
  - id inspect, title "Inspect smoke", status in_progress
  - id delegate, title "Run native subagent smoke", status todo
  - id finish, title "Summarize result", status todo
  Then reply briefly.
  ```

  Expected:
  - Activity sidebar shows `Current Plan`.
  - Plan progress shows correct count.
  - Items use clear status icons/colors.

- [ ] **MV-F2 — Current Plan updates meaningfully**
  Send:

  ```text
  Use update_session_plan to mark inspect done and delegate in_progress. Then reply briefly.
  ```

  Expected:
  - Existing plan updates in place.
  - No duplicate plan cards.
  - Sidebar remains stable and not jumpy.

- [ ] **MV-F3 — Native Subagents sticky area**
  1. With Activity sidebar open, start a slow manual `scout` task:

  ```text
  Use bash to run `sleep 20 && echo sidebar-subagent-ok`, then answer exactly "sidebar subagent ok".
  ```

  Expected:
  - While running, `Native Subagents` appears in Activity sidebar.
  - It shows active status and task summary.
  - After completion, it no longer repeats completed runs noisily in the sticky current-work area.

- [ ] **MV-F4 — Activity sidebar filter basics**
  1. Run a parent task that uses shell and file read tools, e.g. asks Pi to run `pwd` and read a small file.
  2. Switch Activity filters: All, Files, Shell, Web, Errors.
  Expected:
  - Each filter shows relevant events only.
  - Empty filters show friendly empty state.
  - Rows are compact and selectable.

- [ ] **MV-F5 — Activity file diff/detail rendering**
  Ask parent Pi to make a tiny edit to a throwaway file, or use a manual worker direct-write test from section H.
  Expected in Activity sidebar:
  - File mutation row appears.
  - Selecting it shows diff or content preview.
  - Open/Reveal buttons resolve paths correctly.
  - Copy Diff works when diff is available.

- [ ] **MV-F6 — Activity shell output rendering**
  Ask parent Pi to run:

  ```text
  Use bash to run `printf 'activity-shell-ok\n'` and then answer briefly.
  ```

  Expected:
  - Shell activity row appears.
  - Detail shows Command and Output.
  - Output is selectable and clipped if long.

---

## G. Native graph flows: chain and parallel

- [ ] **MV-G1 — Managed parallel no-worktree advisory run**
  Send parent prompt:

  ```text
  Use managed_parallel with worktree false and concurrency 2.

  Run these native tasks:
  1. agent scout, task: Use bash to run `pwd`. Answer exactly "parallel scout cwd: <pwd>". Do not edit files.
  2. agent reviewer, task: Use bash to run `pwd`. Answer exactly "parallel reviewer cwd: <pwd>". Do not edit files.

  After the parallel run finishes, summarize both results.
  ```

  Expected:
  - One native parallel/graph card appears.
  - Child rows run concurrently up to concurrency 2.
  - Graph button/detail view works.
  - Parent receives aggregate summary.
  - No worktree is created unless requested.

- [ ] **MV-G2 — Managed chain graceful missing-chain error**
  Send:

  ```text
  Use managed_chain with chain "missing-smoke-chain", worktree false, and task "test graceful missing chain error".
  ```

  Expected:
  - Parent receives clean chain-not-found message.
  - No broken graph UI.

- [ ] **MV-G3 — Managed chain real chain if available**
  If a real chain is visible in the app, send:

  ```text
  Use managed_chain with chain "<CHAIN_NAME>", worktree false, and task "Chain smoke: produce a short no-edit report."
  ```

  Expected:
  - Chain graph appears.
  - Steps run sequentially.
  - Child summaries feed into next steps.
  - Final aggregate summary appears.

- [ ] **MV-G4 — Graph stop control**
  Start a slow `managed_parallel` run with two `sleep 45` tasks, then use graph/card stop controls.
  Expected:
  - Stop control stops active child/graph cleanly.
  - Status becomes stopped/disconnected/failed clearly, not permanently running.
  - No stale spinner remains.

---

## H. Output policy, direct edits, worktrees, and git diffs

- [ ] **MV-H1 — Invalid project output path is blocked**
  Manual Run Subagent:
  - Agent: `worker`
  - Outcome: `Write/update project file`
  - Output path: `../bad.md`
  - Task: `Write a short smoke file.`
  Expected:
  - Run is blocked before launch with clear validation.
  - No child process starts.

- [ ] **MV-H2 — Valid project output path works with overwrite gating**
  Manual Run Subagent:
  - Agent: `worker`
  - Outcome: `Write/update project file`
  - Output path: `tmp/native-subagent-output.md`
  - Task:

  ```text
  Write exactly "native output path smoke ok" to the requested output file. Do not edit anything else.
  ```

  Expected:
  - Valid project-relative output is accepted.
  - Existing file requires overwrite approval.
  - Artifact/details show requested output path.

- [ ] **MV-H3 — Direct project write path**
  Manual Run Subagent:
  - Agent: `worker`
  - Outcome: `Direct project writes`
  - Worktree: off
  - Task:

  ```text
  Create tmp/pi-manager-native-direct-smoke.txt with exactly:
  native direct smoke ok

  Do not edit anything else.
  ```

  Expected:
  - No heuristic blocks it.
  - Worker edits main checkout directly.
  - Git diff shows only that file.
  - Activity sidebar file mutation appears if parent transcript captures tool event.

- [ ] **MV-H4 — Repo Changes sidebar sees direct edit**
  1. After MV-H3, click the Agent toolbar GitHub/repo-changes icon.
  Expected:
  - `Repo Changes` sidebar opens.
  - New/modified file appears.
  - Include/exclude toggles stage/unstage the file.
  - Filter field narrows file list.
  - Commit button is disabled until a commit title is entered.
  - Do **not** push unless intentionally testing push.

- [ ] **MV-H5 — Worktree isolated edit path**
  Manual Run Subagent:
  - Agent: `worker`
  - Outcome: `Edit files in worktree`
  - Worktree: on
  - Task:

  ```text
  Create tmp/pi-manager-native-worktree-smoke.txt with exactly:
  native worktree smoke ok

  Do not edit anything else.
  ```

  Expected:
  - Run uses an isolated worktree.
  - Child Pi RPC process launches in the isolated worktree under the run artifact directory.
  - Card/info popover shows worktree metadata.
  - Main checkout files are not modified by isolated child edits before apply.
  - Worktree patch/open/apply/discard actions are available.

- [ ] **MV-H6 — Worktree patch apply/discard**
  Continue from MV-H5.
  Expected:
  - Generate/Open Patch creates or opens a readable patch.
  - Apply Patch applies cleanly to main checkout after validation.
  - Discard Worktree removes/prunes isolated worktree.
  - Repo Changes sidebar then reflects the applied main-checkout change.

- [ ] **MV-H7 — Cleanup smoke files**
  Remove/revert these files when testing is done:

  ```text
  tmp/native-subagent-output.md
  tmp/pi-manager-native-direct-smoke.txt
  tmp/pi-manager-native-worktree-smoke.txt
  ```

  Expected:
  - Test repo returns to expected clean/known state.

- [ ] **MV-H8 — Agent-configured output remains advisory**
  If an enabled agent has a configured `output` field such as `plan.md`, run a harmless report-only task with that agent.
  Expected:
  - Run Subagent UI shows an output warning.
  - Final response is stored in app artifacts by default.
  - No project file from the agent-configured output path is overwritten unless project-file edits are explicitly requested and approved.

---

## I. Repo Changes sidebar commit/push behavior

Use a throwaway test file only. Avoid pushing unless you explicitly want to validate push.

- [ ] **MV-I1 — Include/exclude and commit box**
  1. Create or modify a throwaway file manually or via worker.
  2. Open Repo Changes sidebar.
  3. Toggle include/exclude.
  4. Enter commit title `manual verification smoke`.
  Expected:
  - Included count updates.
  - Commit button enables only with staged files and title.
  - Description field is usable.

- [ ] **MV-I2 — Commit optional smoke**
  Optional: commit the throwaway file if acceptable for the repo.
  Expected:
  - Commit completes.
  - Sidebar refreshes.
  - If branch is ahead, clean state shows `Ready to push` and push count.

- [ ] **MV-I3 — Push optional smoke**
  Optional and only if safe: click Push.
  Expected:
  - Push button shows progress.
  - Branch ahead count clears on success.
  - Errors are shown clearly if push fails.

---

## J. Session restart and stale state

- [ ] **MV-J1 — Active subagent app restart behavior**
  1. Start a slow manual `scout` task:

  ```text
  Use bash to run `sleep 45 && echo restart-smoke-ok`.
  Then answer "restart smoke completed".
  ```

  2. Quit Pi Manager while the child is running.
  3. Relaunch manually.
  Expected:
  - Old active run does not remain falsely running forever.
  - It is marked disconnected/stopped/failed cleanly.

- [ ] **MV-J2 — Session list/run ordering stability**
  1. Create multiple native runs in one session.
  2. Switch sessions and back.
  Expected:
  - Run ordering is stable by creation time.
  - Cards do not jump/reorder unexpectedly.

- [ ] **MV-J3 — Blocked supervisor request app restart behavior**
  1. Start a manual `scout` task that blocks on `contact_supervisor(kind: "need_decision")`.
  2. Quit Pi Manager while the request is pending.
  3. Relaunch manually.
  Expected:
  - Stale pending supervisor request cards are cancelled/hidden.
  - The child run is not shown as active or blocked forever.

---

## K. Transcript and primary chat display

- [ ] **MV-K1 — Transcript display options still work**
  1. Use toolbar Transcript Display popover.
  2. Toggle tool calls, web activity, errors, thinking visibility.
  Expected:
  - Transcript updates without layout glitches.
  - Primary path remains summary-first.

- [ ] **MV-K2 — Native run card does not leak debug output**
  Inspect several completed subagent cards.
  Expected:
  - Card shows Task, Answer, compact metadata.
  - Raw tool/debug output is not in the primary card.
  - Full logs remain available in Transcript/details.

- [ ] **MV-K3 — Markdown rendering in task and answer previews**
  Run a subagent task that includes inline code, bullets, and a fenced block.
  Expected:
  - Task preview renders markdown consistently.
  - Answer preview renders markdown consistently.
  - Previews are capped; full content is available in transcript.

---

## L. Git/noise checks

- [ ] **MV-L1 — Generated files are ignored**
  In terminal, from repo root:

  ```bash
  git status --short --ignored | sed -n '1,80p'
  ```

  Expected:
  - `.DS_Store`, Xcode `xcuserdata`, build outputs, logs are ignored.
  - Source/doc changes are still visible.

- [ ] **MV-L2 — No accidental build folder in repo root**
  In terminal:

  ```bash
  find . -maxdepth 2 \( -name build -o -name DerivedData -o -name '*.xcresult' \) -print
  ```

  Expected:
  - No noisy generated build folders need to be committed.

---

## M. Final acceptance sweep

- [ ] **MV-M1 — No old package UX in primary native flows**
  Across manual, parent bridge, chain, parallel, and supervisor tests:
  Expected:
  - No `/run` slash text UX.
  - No old `pi-subagents` broker cards.
  - No `pi-intercom` terminology for app-managed child supervision.
  - Native cards/graphs/transcripts are the visible source of truth.

- [ ] **MV-M2 — Summary-first UI**
  Expected:
  - Primary chat remains clean.
  - Detailed/debug/action-heavy controls live behind Transcript, info popover, graph detail, Activity sidebar, or Repo Changes sidebar.

- [ ] **MV-M3 — Known limitation remains acceptable**
  Expected:
  - Fallback model retry is still a known limitation and should not block this validation unless it regresses normal model selection.

## Results log

Add notes here or send them to the coding agent to update.

| Item | Result | Notes |
|---|---|---|
| MV-A2 | Passed | User verified collapsed-by-default behavior. Startup resources expansion animation was too slide-like; simplified to opacity-only content transition in `PiAgentViews.swift`. |
