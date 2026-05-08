# Development and Verification

## Build

```bash
xcodebuild \
  -project agent-deck.xcodeproj \
  -target agent-deck \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## Tests

```bash
xcodebuild \
  -project agent-deck.xcodeproj \
  -scheme agent-deck \
  -destination 'platform=macOS' \
  test
```

## Manual verification matrix

For behavior-changing PRs, verify the relevant areas:

### Scanning

- global resources are detected
- project resources are detected for the selected project
- malformed files produce warnings instead of crashes
- effective agent resolution matches expected precedence

### Persistence

- builtin edits write settings overrides, not read-only bundled files
- custom agents/chains/prompts write to the selected active/library/project target
- env updates preserve unrelated lines and hide secret values by default

### Pi Agent

- `pi --mode rpc` launches
- prompts stream into the transcript
- model/thinking/session controls work
- extension UI requests can be answered

### Native subagents

- report-only run writes artifacts and does not modify project files
- worktree run creates a worktree and patch
- blocking supervisor requests appear in UI and can be answered
- chain/parallel graph status updates correctly

### GitHub/Git

- GitHub auth detection works through `gh`
- issue boards load for a selected repo
- git status/diff/stage/commit/push actions behave as expected

## Documentation update policy

When behavior changes, update the official docs page that explains the user-facing behavior and the contributor/source-map page if files or architecture changed.
