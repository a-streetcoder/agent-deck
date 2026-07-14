# Build, Test & Verification

## Build

```bash
xcodebuild -project agent-deck.xcodeproj -scheme agent-deck \
  -configuration Debug -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO build
```

For CI-like builds (arm64 target):

```bash
xcodebuild -project agent-deck.xcodeproj -scheme agent-deck \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO build
```

## Focused Packaging Checks

After changing release signing, entitlements, or generated Info.plist settings, run:

```bash
bash scripts/test-package-signing.sh
```

## Run Tests

```bash
xcodebuild -project agent-deck.xcodeproj -scheme agent-deck \
  -destination 'platform=macOS' test
```

For specific test targets:

```bash
# Session store tests
xcodebuild -project agent-deck.xcodeproj -scheme agent-deck \
  -destination 'platform=macOS' \
  -only-testing:agent-deckTests/PiAgentSessionStoreTests \
  test

# Transcript render tests
xcodebuild -project agent-deck.xcodeproj -scheme agent-deck \
  -destination 'platform=macOS' \
  -only-testing:agent-deckTests/PiAgentTranscriptRenderSmokeTests \
  test
```

## Test Architecture

Three validation layers:

1. **Unit tests** — deterministic, no real `pi` dependency.
2. **Harnessed smoke tests** — use a fake `pi` executable (in `agent-deckTests/PiTestSupport.swift`).
3. **Real integration tests** — opt-in only (`PiSubagentRuntimeSmokeTests`, `PiNativeBundledSubagentRealRPCEvalTests`); not in CI.

## CI

- GitHub Actions workflow: `.github/workflows/release.yml`
- Runner: `macos-26` with Xcode 26.4+
- Current CI is release-oriented: it builds, signs, notarizes, and publishes tagged releases.
- There is no separate general build-or-test workflow in this repository today.

## Verification Matrix

When editing behavior, verify these areas:

- **Scanning**: global/project resources detected; malformed files produce warnings, not crashes; effective agent resolution matches precedence rules.
- **Persistence**: builtin edits write settings overrides (not read-only bundled files); custom agents write to the correct scope; env updates preserve unrelated lines and hide secrets.
- **Pi Agent**: `pi --mode rpc` launches; prompts stream; model/thinking/session controls work.
- **Native subagents**: report-only runs write artifacts without modifying project files; worktree runs create and patch correctly; blocking supervisor requests appear in UI and can be answered; sequential/parallel graph status updates propagate.
- **GitHub/Git**: auth detection works; issue boards load; git status/diff/stage/commit/push behaves correctly.

## Documentation Update Policy

When behavior changes, update:
1. The official docs page explaining user-visible behavior.
2. The contributor/source-map page if files or architecture changed.

For full verification details, see `agent-deck-documentation/contributors/development-and-verification.md`.