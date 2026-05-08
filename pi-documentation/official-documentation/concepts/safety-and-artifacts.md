# Safety and Artifacts

Agent Deck's most important product rule is: users should be able to tell what will be written and where.

## Builtins are read-only

Package-owned and app-bundled builtin resources should not be edited in place. Use:

- builtin overrides for supported field patches
- global/project custom replacements
- library copies for reusable editable resources

## Native run outcomes

Native subagent runs must have an explicit expected outcome:

- report-only artifact
- worktree edits
- one explicit project file
- direct project writes

The outcome is part of the safety contract shown to the user and passed to the child.

## Artifacts

App-owned native artifacts live under:

```text
~/Library/Application Support/Agent Deck/Subagent Runs/<run-id>/
```

Report-only runs should write their final output there. Worktree runs may additionally produce patches.

## Read-current-files policy

Read-first paths tell children which current files to inspect. Agent Deck does not inject stale file contents into the system prompt. This reduces the risk that an old `plan.md` or prior context misleads a new run.

## Worktree isolation

Use worktrees for risky experiments or parallel writers. Applying a worktree patch should be explicit and validated before touching the main checkout.
