# Pi Manager Native Subagents

Pi Manager now runs app-managed native subagents without relying on the old package-managed `/run` path. The app owns child Pi RPC processes, run records, transcripts, artifacts, supervisor requests, worktrees, chains, and parallel graphs.

For migrating existing package-style agents, see `pi-documentation/convert-pi-subagents-agents-to-native.md`.

## What is replaced

| Capability | Native status |
|---|---|
| Single subagent runs | Replaced by native Run Subagent sheets and `managed_subagent` |
| Chains | Replaced by native graph runs and `managed_chain` |
| Parallel runs | Replaced by native graph runs and `managed_parallel` |
| Parent/child supervisor bridge | Replaced for app-managed children via `contact_supervisor` |
| Artifacts/transcripts | Replaced with app-persisted records and UI |

General arbitrary terminal session messaging is not part of native subagents. If Pi Manager later needs that, use the separate Session Relay plan.

## Bundled starter agents

Pi Manager includes a small native starter pack in the app bundle. These are global builtins: they are available to projects by default, can be replaced by same-name global/project custom agents, and can be disabled with Pi Manager's builtin override controls.

| Agent | Purpose |
|---|---|
| `scout` | Fast codebase reconnaissance and compact handoff context. |
| `planner` | Turns requirements and context into an implementation plan without editing files. |
| `worker` | Makes approved, scoped implementation changes with native worktree/direct-write policy. |
| `reviewer` | Reviews diffs/plans/implementations and reports evidence-backed findings. |

The bundled agents use Pi Manager-native jargon and `contact_supervisor(kind, message, title?)` instead of package-specific coordination wording.

## Run model

Every native run has:

- a parent Pi Agent session
- a child Pi RPC process per subagent step/task
- app artifacts under `~/Library/Application Support/Pi Manager/Subagent Runs/<run-id>/`
- `input.md`, `system-prompt.md`, and usually `output.md`
- persisted run/child metadata and transcript entries

Chains and parallel runs are persisted as graph records with child nodes. Child nodes keep their own execution run id, status, output path, worktree path, summary/error, and duration.

## Expected outcome policy

The Run Subagent sheet makes the expected result explicit:

| Outcome | Meaning |
|---|---|
| Report only | Final answer goes to app artifacts. Child must not edit project files. |
| Edit files in worktree | Child may edit files only in the isolated worktree. Pi Manager reviews/applies/discards the patch. |
| Write/update project file | Child writes one explicit project-relative path, usually in a worktree. Existing files require overwrite approval. |
| Direct project writes | Child may edit the main checkout only after explicit approval. |

Agent `output` frontmatter such as `plan.md` is advisory only. Pi Manager does not automatically write it into the project. To produce a project file, the caller must choose the write/update outcome and provide a project-relative path.

## Read-first files

Callers can pass files the child should read first. Manual runs expose a “Files to read first” field; `managed_subagent` accepts an optional `reads` array.

Rules:

- caller-provided reads override agent `defaultReads`
- agent `defaultReads` are used only when the caller provides no reads
- paths must be project-relative
- absolute paths and `..` are rejected
- file contents are not injected into prompts
- the child is instructed to read current project files if relevant

This avoids stale context problems such as an old `plan.md` from a previous session misleading a new child run.

## System prompt construction

Pi docs state:

- `--system-prompt <text>` replaces Pi's default system prompt
- context files and skills are still appended unless disabled
- `--append-system-prompt <text>` appends to the system prompt
- `--no-context-files` disables `AGENTS.md` / `CLAUDE.md` discovery
- `--no-skills` disables skill discovery

Pi Manager follows that model:

1. Native boundary instructions + agent system prompt + explicit private skill blocks are passed as system prompt content.
2. Expected outcome, read-first files, artifact directory, and the concrete task are sent as the user task prompt.
3. If `inheritProjectContext` is false, Pi Manager passes `--no-context-files`.
4. If `inheritSkills` is false, Pi Manager passes `--no-skills`.
5. Ambient extension discovery is disabled with `--no-extensions`; only configured extensions and app bridge extensions are loaded.

Keep system instructions compact. Do not put run-specific file contents or stale plans into the system prompt.

## Supervisor routing

Children that explicitly include `contact_supervisor` can send:

- `progress_update` — non-blocking, auto-acknowledged
- `need_decision` — blocking
- `interview_request` — blocking, supports structured JSON question forms

Blocking requests create app supervisor cards. Humans can answer in the UI. The parent Pi Agent can also answer using:

- `list_supervisor_requests()`
- `answer_supervisor_request(requestID, response)`

Parent-agent answers route through Pi Manager to the waiting child.

## Worktrees

Writer-like manual runs require either worktree isolation or explicit direct-write approval. Writer-like parent bridge requests are auto-isolated. Parallel writer-like runs require isolated worktrees.

For isolated worktrees, Pi Manager can:

- generate/open `worktree.patch`
- apply after `git apply --check --3way --binary`
- discard via `git worktree remove --force` and prune

## Artifacts and cleanup

Native run artifacts live under:

```text
~/Library/Application Support/Pi Manager/Subagent Runs/<run-id>/
```

Pi Manager keeps artifacts referenced by persisted run records. Old orphaned run directories are cleaned up after the retention window.

## Remaining known limitation

Fallback model retry is tracked separately: https://github.com/a-streetcoder/pi-manager/issues/8
