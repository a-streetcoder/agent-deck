# Diagnostics and Troubleshooting

The Diagnostics screen is the first place to check when Pi Manager behavior does not match expectations.

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

Verify `pi` is installed and discoverable. If launching the app from Finder hides your shell PATH, set `PI_MANAGER_PI_PATH` to the exact executable path before launching from Terminal.

### A skill is listed in an agent but not injected

The agent stores only the skill name. Make sure the skill is active globally, active in the project, or supplied by a scanned package/settings source. A skill in the library folder alone is not active.

### Builtin agent changes disappear

Do not edit read-only builtin files. Use Pi Manager's builtin override controls or create a same-name global/project replacement.

### A native subagent did not write a project file

Check the expected outcome. Report-only runs write to app artifacts, not project files. Agent `output` frontmatter is advisory only.

### Extension command list looks stale

Runtime commands come from Pi RPC and loaded extensions. Start a new Pi session or reload Pi after changing extension settings.

### Context breakdown rows are labelled estimated

Pi Manager prefers exact `contextBreakdown` rows when Pi RPC provides them. Current Pi RPC commonly exposes only aggregate context totals and token accounting, so Pi Manager's native popover derives fallback rows from RPC input/output/cache totals and only falls back to visible transcript estimates when token totals are unavailable. Those rows are intentionally labelled estimated and should not be treated as exact prompt, tool, or message category observability.
