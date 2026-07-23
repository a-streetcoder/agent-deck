# Native Subagent Bridge Reference

Agent Deck injects generated bridge extensions into Pi RPC sessions when native subagents are enabled. The generated files live under `~/Library/Application Support/Agent Deck/Native Subagent Extensions/`.

## Parent bridge tools

Parent Pi Agent sessions can request app-managed work through tools such as:

- `managed_subagent` — run one native subagent, or continue one with `continueSubagentID`
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

Native subagents start fresh by default and cannot see the parent conversation, context window, reasoning, tool results, user decisions, or prior-agent findings. Every fresh delegation must therefore be self-contained: its task supplies the goal, relevant requirements/decisions, constraints/findings, expected output, and useful reads. Direct follow-ups can pass a previous Subagent ID as `continueSubagentID`; Agent Deck resumes only that child's own session and updates the same parent chat card. Agent Deck never restores parent context or uses forked parent context for native subagents.

In the parent transcript, hovering a Deck agent avatar opens a profile card with the resolved agent image, description, model, and `whenToUse` routing guidance. This is available for both single-agent runs and child cards in parallel runs.

## Extension isolation

Native child sessions disable ambient extension discovery and load only configured extensions plus the app child bridge when needed. This keeps child capabilities explicit.
