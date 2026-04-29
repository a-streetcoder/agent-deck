# Parity checks

`pi-manager` includes a fixture-based parity harness against the installed `pi-subagents` package.

## Run

```bash
bun scripts/parity-check.mjs
```

## What it checks

- agent discovery and effective resolution
- builtin override payload generation
- custom agent serialization
- chain parsing
- chain serialization

## Fixtures

Fixtures live in `scripts/parity/fixtures/` and model:

- global legacy + modern agent directories
- project legacy + modern agent directories
- user + project builtin overrides
- chain extra fields and `false` step semantics

When a check fails, the script writes expected/actual output into a temp failure directory for diffing.
