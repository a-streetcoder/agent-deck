# Native Subagent Bridge Reference

Agent Deck injects generated bridge extensions into Pi RPC sessions when native subagents are enabled. The generated files live under `~/Library/Application Support/Agent Deck/Native Subagent Extensions/`.

## Parent bridge tools

Parent Pi Agent sessions can request app-managed work through tools such as:

- `managed_subagent` — run one native subagent, or continue one with `continueSubagentID`
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

## Fresh runs and continuation

Native subagents start fresh by default and do not receive parent conversation history. Direct follow-ups can pass a previous Subagent ID as `continueSubagentID`; Agent Deck resumes that child session and updates the same parent chat card. Agent Deck does not use forked parent context for native subagents.

## Extension isolation

Native child sessions disable ambient extension discovery and load only configured extensions plus the app child bridge when needed. This keeps child capabilities explicit.
