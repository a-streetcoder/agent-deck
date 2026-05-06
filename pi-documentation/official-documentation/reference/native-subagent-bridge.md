# Native Subagent Bridge Reference

Pi Manager injects generated bridge extensions into Pi RPC sessions when native subagents are enabled. The generated files live under `~/Library/Application Support/Pi Manager/Native Subagent Extensions/`.

## Parent bridge tools

Parent Pi Agent sessions can request app-managed work through tools such as:

- `managed_subagent` — run one native subagent
- `managed_chain` — run a native chain graph
- `managed_parallel` — run parallel native tasks
- `list_supervisor_requests` — inspect blocking child requests
- `answer_supervisor_request` — answer a blocking child request
- `set_session_plan` — set activity-sidebar plan items
- `update_session_plan` — update activity-sidebar plan item status/text

The app owns execution after a bridge request: it creates records, launches child `pi --mode rpc` processes, streams events, writes artifacts, and updates UI state.

## Child bridge tool

Children with the `contact_supervisor` tool can send:

- `progress_update`
- `need_decision`
- `interview_request`

Blocking requests wait for a human or parent-agent answer. Non-blocking progress updates are recorded and acknowledged.

## Context modes

A child can run fresh or forked from a parent session file. If fork is requested but no parent session file is available, Pi Manager should warn and fall back safely rather than pretending the child inherited context.

## Extension isolation

Native child sessions disable ambient extension discovery and load only configured extensions plus the app child bridge when needed. This keeps child capabilities explicit.
