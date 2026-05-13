# Recipe: Run a Native Subagent Safely

## Report-only review

Use this for audits, research, or planning.

1. Open Pi Agent or the native run sheet.
2. Choose an agent such as `explorer`, `planner`, or `reviewer`.
3. Set expected outcome to **Report only**.
4. Add project-relative read-first files if useful.
5. Run and inspect `output.md` in the app artifact directory.

Report-only runs are instructed not to edit project files, but this is not a hard sandbox. Inspect Git status if you need to verify no files changed.

## Coder in a worktree

Use this for risky or parallel implementation.

1. Choose `coder` or another implementation agent.
2. Set expected outcome to **Edit files in worktree**.
3. Provide a scoped task and acceptance criteria.
4. Review the resulting patch.
5. Apply only after validation, or discard the worktree.

## Direct project writes

Use direct writes only when the user explicitly approves editing the main checkout.

Good task prompts include:

- exact scope
- files or area to inspect
- non-goals
- validation expectations
- when to ask the supervisor for a decision
