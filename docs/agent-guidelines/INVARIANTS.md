# Product Invariants & Contributor Rules

## Product Invariants (hard rules — never violate)

1. **Do not edit read-only builtin files directly.** When a user edits a builtin, Agent Deck writes an override file — the bundled original must never be modified.

2. **Do not make report-only native subagents write project files.** Report-only subagent runs produce artifacts in their own directory, not edits to the user's project.

3. **Do not hide write targets.** Agent Deck must make every write target explicit and visible to the user.

4. **Describe current app-managed native subagents directly.** Do not fabricate or hallucinate subagent configurations.

5. **Do not assume a library resource is active until linked globally or into a project.** Library resources exist in a catalog but are inert until explicitly assigned.

6. **Do not inject stale file contents into long-lived system prompts.** Long-lived prompts must not embed file contents that can go stale; use references or re-read at launch.

## Contributor Rules

- **Read actual source files before editing.** Never rely solely on old plans, progress notes, or exploratory docs.
- **Cite source files or current official docs** when documenting behavior. If uncertain, mark it as a gap — never invent behavior.
- **Run a focused build/test when possible.** If you cannot validate, say so and give the exact command for a maintainer to run.
- **Prefer small, focused PRs** with clear validation notes.
- **Mark unvalidated changes honestly.**
- **Write stable behavior in documentation**, not temporary implementation plans. Deprecated/package-era behavior must be labeled historical.

## Security Invariants

- `EnvPersistence` hides secret values by default. Never expose existing secret values when updating `.env` files.
- Memory secret scanning blocks writes containing private keys, GitHub tokens, API keys, AWS access keys, or password/token/secret assignments.
- Never pass API keys as CLI arguments to `pi`. Credentials come from environment variables and settings.

## Resource Scope Visibility

Every resource must show its scope (Builtin/Global/Library/Project) with color + icon + text — never color alone. See `docs/agent-guidelines/SWIFTUI.md` for the color table.

For the full contributor guide, see `pi-documentation/official-documentation/contributors/llm-contributor-guide.md`.