# Agent Deck Native Subagents

Agent Deck now runs app-managed native subagents with app-owned child RPC sessions. The app owns child Pi RPC processes, run records, transcripts, artifacts, supervisor requests, worktrees, chains, and parallel graphs.

## What is replaced

| Capability | Native status |
|---|---|
| Single subagent runs | Replaced by native Run Subagent sheets and `managed_subagent` |
| Chains | Replaced by native graph runs and `managed_chain` |
| Parallel runs | Replaced by native graph runs and `managed_parallel` |
| Parent/child supervisor bridge | Replaced for app-managed children via `contact_supervisor` |
| Artifacts/transcripts | Replaced with app-persisted records and UI |

General arbitrary terminal session messaging is not part of native subagents. If Agent Deck later needs that, use the separate Session Relay plan.

## Bundled starter agents

Agent Deck includes a small native starter pack in the app bundle. These are global builtins: they are available to projects by default, can be replaced by same-name global/project custom agents, and can be disabled with Agent Deck's builtin override controls.

| Agent | Purpose |
|---|---|
| `scout` | Fast codebase reconnaissance and compact handoff context. |
| `planner` | Turns requirements and context into an implementation plan without editing files. |
| `worker` | Makes approved, scoped implementation changes with native worktree/direct-write policy. |
| `reviewer` | Reviews diffs/plans/implementations and reports evidence-backed findings. |

The bundled agents use Agent Deck-native jargon and `contact_supervisor(kind, message, title?)` instead of package-specific coordination wording.

## Run model

Every native run has:

- a parent Pi Agent session
- a child Pi RPC process per subagent step/task
- app artifacts under `~/Library/Application Support/Agent Deck/Subagent Runs/<run-id>/`
- `input.md`, `system-prompt.md`, and usually `output.md`
- persisted run/child metadata and transcript entries

Chains and parallel runs are persisted as graph records with child nodes. Child nodes keep their own execution run id, status, output path, worktree path, summary/error, and duration.

## Expected outcome policy

The Run Subagent sheet makes the expected result explicit:

| Outcome | Meaning |
|---|---|
| Report only | Final answer goes to app artifacts. Child must not edit project files. |
| Edit files in worktree | Child may edit files only in the isolated worktree. Agent Deck reviews/applies/discards the patch. |
| Write/update project file | Child writes one explicit project-relative path, usually in a worktree. Existing files require overwrite approval. |
| Direct project writes | Child may edit the main checkout only after explicit approval. |

Agent `output` frontmatter such as `plan.md` is advisory only. Agent Deck does not automatically write it into the project. To produce a project file, the caller must choose the write/update outcome and provide a project-relative path.

## Read-first files

Callers can pass files the child should read first. Manual runs expose a “Files to read first” field; `managed_subagent` accepts an optional `reads` array and an optional `continueSubagentID` for direct follow-ups.

Rules:

- caller-provided reads override agent `defaultReads`
- agent `defaultReads` are used only when the caller provides no reads
- paths must be project-relative
- absolute paths and `..` are rejected
- file contents are not injected into prompts
- the child is instructed to read current project files if relevant

This avoids stale context problems such as an old `plan.md` from a previous session misleading a new child run.

## Fresh runs and continuation

Native subagents start fresh by default: a normal `managed_subagent` call creates a new child Pi session and does not receive parent chat history or prior child history. For a direct follow-up, the parent can pass the previous card's Subagent ID as `continueSubagentID`; Agent Deck resumes that child Pi session with `--session <child-session-file>` and updates the same native subagent card.

Use fresh runs for independent work. Use continuation for direct refinement, re-review, debugging, or child-specific follow-up questions. If starting fresh for follow-up work, pass a compact continuity packet with prior findings, changed files, relevant artifacts, and expected output.

## System prompt construction

Pi docs state:

- `--system-prompt <text>` replaces Pi's default system prompt
- context files and skills are still appended unless disabled
- `--append-system-prompt <text>` appends to the system prompt
- `--no-context-files` disables `AGENTS.md` / `CLAUDE.md` discovery
- `--no-skills` disables skill discovery

Agent Deck follows that model:

1. Native boundary instructions + agent system prompt are passed as system prompt content.
2. Expected outcome, read-first files, artifact directory, and the concrete task are sent as the user task prompt.
3. Native child sessions use normal Pi project context-file discovery.
4. Agent Deck always passes `--no-skills` and then explicit `--skill <path>` arguments for skills assigned to that agent.
5. Ambient extension discovery is disabled with `--no-extensions`; only configured extensions and app bridge extensions are loaded.

Keep system instructions compact. Do not put run-specific file contents or stale plans into the system prompt.

## Activity sidebar visibility

The Pi Agent Activity sidebar is a summary-first execution view. It keeps the noisy tool log out of the main chat while making current work inspectable:

- **Current Plan**: parent agents can set a short checklist with `set_session_plan(items)` and update it with `update_session_plan(updates)`. Plan item ids are stable and updates should happen only on meaningful transitions.
- **Native Subagents**: active/blocked/recent native child runs are shown from Agent Deck's structured run state, including agent, task, status, and worktree indicator.
- **Activity Feed**: focused tool evidence such as edit diffs, bounded write previews, shell output, compact web/source summaries, and errors.

The plan is explicit bridge state, not parsed from markdown chat text. This keeps updates stable and avoids jumpy UI or expensive transcript scraping.

## Supervisor routing

Children that explicitly include `contact_supervisor` can send:

- `progress_update` — non-blocking, auto-acknowledged
- `need_decision` — blocking
- `interview_request` — blocking, supports structured JSON question forms

When `contact_supervisor` is present in agent `tools`, Agent Deck also injects native boundary instructions telling the child to use it only for blockers, structured interviews, or meaningful progress, and to return final results normally.

Blocking requests create app supervisor cards. Humans can answer in the UI. The parent Pi Agent can also answer using:

- `list_supervisor_requests()`
- `answer_supervisor_request(requestID, response)`

Parent-agent answers route through Agent Deck to the waiting child.

## Worktrees

Worktree isolation is an advanced safety path, not the default editing model. Normal approved worker subagents should edit the current project like Pi normally does. Use isolated worktrees only for risky, experimental, or parallel writer work where Agent Deck should review/apply/discard a patch afterward.

For isolated worktrees, Agent Deck can:

- generate/open `worktree.patch`
- apply after `git apply --check --3way --binary`
- discard via `git worktree remove --force` and prune

## Artifacts and cleanup

Native run artifacts live under:

```text
~/Library/Application Support/Agent Deck/Subagent Runs/<run-id>/
```

Agent Deck keeps artifacts referenced by persisted run records. Old orphaned run directories are cleaned up after the retention window.

## Session enablement

The composer footer subagent icon controls native subagents for the current Pi Agent session and the default for newly created sessions. Disabling a session hides manual native launches and makes parent bridge calls return a disabled message.

## Remaining known limitation

Fallback model retry is tracked separately: https://github.com/a-streetcoder/agent-deck/issues/8
