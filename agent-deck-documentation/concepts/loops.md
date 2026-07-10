# Loops

Loops are app-managed orchestration around native Deck-agent runs. Agent Deck owns the iteration limit, validation, terminal outcome, artifacts, and transcript recaps; Pi continues to own each child agent's model/tool turn loop.

## Setup and success policy

A loop has a goal, a success condition, an optional validation command, an iteration cap, and an explicit write target. The recommended shape is a small **Analyze → Fix → Validate** cycle.

A loop completes successfully only when:

1. the report-only goal evaluator returns an exact `SUCCESS` decision, and
2. the configured validation command passes, if one was configured.

`CONTINUE`, malformed evaluator output, an exhausted cap, or failed required validation produces **Goal not achieved**, not a successful completion. Validation output and evaluator rationale are recorded in the run and bounded loop-progress artifact for the next worker.

## Loop types

- **Single Agent** — repeats one selected enabled agent.
- **Maker + Checker** — maker work followed by a report-only checker; evaluator policy still controls completion.
- **Agent Pipeline** — selected enabled agents run in order.
- **Parallel Agents** — selected enabled agents conduct independent, report-only investigations. Agent Deck uses conservative concurrency and does not allow a shared writable target.
- **Discovery / Triage** — one selected agent collects and classifies findings.
- **Approval Checkpoint** — records an explicit approval or rejection. It is terminal for that run; approval does not resume the same run. Start a new attempt for follow-up work.

Saved legacy parallel definitions keep their stored names, but users must select available enabled agents before launch.

## Safety and stopping

Artifact output is the safest write target. Worktree and current-checkout targets are available to sequential loop structures with explicit user choice. Parallel loops are report-only to avoid concurrent writes to the same checkout or worktree.

Stopping a live loop prevents additional worker launches and cancels in-flight validation where practical. An `ASK_HUMAN` result leaves a terminal checkpoint and offers **Start New Attempt** for follow-up; it never claims to resume the same child run. A stopped run remains in the transcript with a single final recap.
