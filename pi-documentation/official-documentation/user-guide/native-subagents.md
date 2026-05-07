# Native Subagents

Pi Manager runs app-managed native subagents. The app owns child process launch and tracking directly.

## What Pi Manager owns

For native subagents, the app owns:

- child Pi RPC processes
- run records and graph metadata
- child transcripts
- artifacts
- supervisor requests
- optional worktrees
- chain and parallel execution graphs

Native subagents are tied to a parent Pi Agent session.

## Bundled agents

Pi Manager includes four starter agents:

- `scout` — reconnaissance and compact context
- `planner` — implementation planning
- `worker` — scoped implementation
- `reviewer` — evidence-backed review

## Run model

Every native run creates app artifacts under:

```text
~/Library/Application Support/Pi Manager/Subagent Runs/<run-id>/
```

Common files:

- `input.md`
- `system-prompt.md`
- `output.md`
- optional `worktree.patch`

Each child is a separate `pi --mode rpc` process. Pi Manager builds the child system prompt from native boundary instructions, the agent prompt, and explicit private skill blocks; expected outcome, read-first files, artifact directory, and task are sent as the user prompt. See [Pi core prompt assembly](../reference/pi-core-prompt-assembly.md).

## Expected outcomes

| Outcome | Meaning |
|---|---|
| Report only | Child is instructed to write the final result to app artifacts and not edit project files |
| Edit files in worktree | Child edits only an isolated worktree; Pi Manager can apply/discard the patch |
| Write/update project file | Child writes one explicit project-relative path |
| Direct project writes | Child edits the main checkout only after explicit approval |

Agent `output` frontmatter is advisory. Pi Manager does not automatically write it into the project.

Important caveat: report-only is a prompt-level safety contract, not a filesystem sandbox. The child still runs in a project/worktree working directory with its configured tools. Use trusted agents and inspect Git status when safety matters.

## Read-first files

Run requests may include files to read first. These are hints, not injected stale contents. Paths must be project-relative; absolute paths and `..` are rejected.

## Supervisor requests

Children that include `contact_supervisor` can send:

- `progress_update` — non-blocking
- `need_decision` — blocking
- `interview_request` — blocking, may include structured question JSON

Humans can answer in the UI. Parent Pi Agent sessions can also list and answer requests through bridge tools.

## Worktrees

Worktrees are for risky, experimental, or parallel writer work. Pi Manager can create a worktree, collect a patch, apply it after validation, or discard it.

Normal approved worker runs may edit the main checkout only when that outcome is explicit.

## Activity, cleanup, and session enablement

Native runs appear in Pi Manager activity UI as structured run state rather than as plain chat text. Parent sessions can maintain a short activity plan through bridge tools. The app stores run artifacts referenced by persisted run records and can clean up old orphaned run directories after the retention window. Native subagents can be enabled or disabled per Pi Agent session; when disabled, manual native launches are hidden and bridge calls return a disabled response.
