# Diagnostics and Troubleshooting

The Diagnostics screen is the first place to check when Agent Deck behavior does not match expectations.

## What diagnostics surface

- missing Pi CLI, Git, GitHub CLI, or package dependencies
- malformed frontmatter or JSON files
- duplicate resource names
- missing or unresolved skills
- broken chains or extension/tool mismatches
- package checks for relevant Pi packages
- scanner warnings from global and selected project resources

## Common issues

### Pi Agent sessions cannot start

Verify `pi` is installed and discoverable. If launching the app from Finder hides your shell PATH, set `AGENT_DECK_PI_PATH` to the exact executable path before launching from Terminal.

### A skill is listed in an agent but not injected

The agent stores only the skill name. Make sure the skill exists once in the Agent Deck skill catalog and is assigned globally, assigned to the project, or supplied by a scanned package/settings source.

### Builtin agent changes disappear

Do not edit read-only builtin files. Use Agent Deck's builtin override controls or create a same-name global/project replacement.

### A native subagent did not write a project file

Check the expected outcome. Report-only runs write to app artifacts, not project files. Agent `output` frontmatter is advisory only.

### Extension command list looks stale

Runtime commands come from Pi RPC and loaded extensions. Start a new Pi session or reload Pi after changing extension settings.

### Context breakdown rows are labelled estimated

Agent Deck prefers exact `contextBreakdown` rows when Pi RPC provides them. Current Pi RPC commonly exposes only aggregate context totals and token accounting, so Agent Deck's native popover derives fallback rows from RPC input/output/cache totals and only falls back to visible transcript estimates when token totals are unavailable. When Agent Deck has captured the runtime system prompt, the popover also shows an estimated prompt composition breakdown for core instructions, tool descriptions, project context, and skills. Estimated rows should not be treated as exact prompt, tool, or message category observability.
