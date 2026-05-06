# Chains

Chains are reusable multi-step workflows stored as `.chain.md` files.

## Managed locations

Pi Manager manages chains in:

- global: `~/.pi/agent/chains/*.chain.md`
- library: `~/.pi/agent/agent-library/chains/*.chain.md`
- project: `PROJECT/.pi/chains/*.chain.md`

This is an app-level choice intended to keep chains separate from agents.

## Native chain execution

When run through Pi Manager, a chain becomes an app-owned graph run. Each step is tracked as a child node with status, transcript, artifact path, optional worktree path, summary/error, and duration.

## Safety

Chain steps follow the same expected-outcome and write-target rules as single native subagent runs. Parallel writer steps should use worktree isolation unless direct writes are explicitly approved.

## Legacy note

Older docs may mention chain files inside `.agents/`. The current Pi Manager scanner does not actively discover legacy `.agents` chain files as managed chains.
