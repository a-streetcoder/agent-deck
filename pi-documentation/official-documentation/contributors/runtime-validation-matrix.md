# Runtime Validation Matrix

Issue 23 tracks the Agent Deck runtime validation suite. The goal is to keep unit tests fast and deterministic while adding smoke coverage for every app-owned Pi Agent and native subagent behavior.

## Test Layers

| Layer | Purpose | Runs real `pi`? | Examples |
|---|---|---:|---|
| Unit tests | Validate deterministic state, parsing, planning, and persistence logic. | No | model parsing, session plans, context estimates, path sanitization |
| Harnessed smoke tests | Simulate Pi RPC events with a fake `pi` executable and verify app behavior. | No | bridge routing, supervisor requests, artifact creation |
| Real integration tests | Optional validation against an installed Pi runtime and real shell/git state. | Yes | end-to-end manual or opt-in CI checks |

Normal CI should run unit tests and harnessed smoke tests. Real integration tests should be opt-in because they depend on local credentials, installed Pi versions, shell tools, and real repositories.

## Latest Validation

Validated on May 7, 2026 with Xcode 26.4.1 selected at `/Applications/Xcode.app/Contents/Developer`.

| Command | Result |
|---|---|
| `xcodebuild test -scheme agent-deck -destination "platform=macOS"` | Passed |
| `xcrun swiftc -parse -enable-bare-slash-regex agent-deck/*.swift agent-deckTests/*.swift` | Passed |
| `git diff --check` | Passed |
| `plutil -lint agent-deck.xcodeproj/project.pbxproj` | Passed |

## Current Test Layout

| File | Responsibility |
|---|---|
| `PiTestSupport.swift` | Temporary projects, fake Pi executable, RPC harness, shared factories. |
| `PiRPCBridgeFixtures.swift` | Canonical bridge event fixtures for parent and child bridge tests. |
| `PiAgentSessionStoreTests.swift` | Session persistence, selection recovery, session plans, supervisor request state. |
| `PiAgentBridgeSmokeTests.swift` | Parent bridge extension injection, native catalog prompt injection, parent bridge routing for managed subagent/chain/parallel, supervisor list/answer, plan set/update, malformed bridge traffic, regular editor UI. |
| `PiNativeBridgeExtensionSourceTests.swift` | Generated TypeScript bridge extension source for parent and child Pi tools. |
| `PiSubagentRuntimeSmokeTests.swift` | Launch planner, pre-event run metadata, artifact files, read-first sanitization, fork-context sanitization, child launch isolation flags, expected-outcome prompts, child supervisor progress/decision/interview flow. |
| `PiSubagentWorktreeServiceTests.swift` | Worktree patch capture safety, changed-file parsing, parent dirty-state guard, unsafe path guard, non-isolated run guard. |
| `PiAgentContextAndModelTests.swift` | Context estimate rows and Pi model discovery parsing. |

## Required Coverage

| Functionality | Coverage Type | Current Status |
|---|---|---|
| Pi Agent session creation, selected-session persistence, invalid selection recovery | Unit | Covered |
| Session plan set/update from app store APIs | Unit | Covered |
| Session plan set/update from parent bridge | Harnessed smoke | Covered |
| Parent `managed_subagent` bridge routing | Harnessed smoke | Covered |
| Parent `managed_chain` bridge routing | Harnessed smoke | Covered |
| Parent `managed_parallel` bridge routing | Harnessed smoke | Covered |
| Parent `list_supervisor_requests` bridge routing | Harnessed smoke | Covered |
| Parent `answer_supervisor_request` bridge routing | Harnessed smoke | Covered |
| Parent native bridge extension and catalog prompt are injected only when session subagents are enabled | Harnessed smoke | Covered |
| Generated parent bridge extension registers only app-handled bridge tools with strict schemas | Unit | Covered |
| Generated child `contact_supervisor` extension carries blocking kinds and run/agent environment identity | Unit | Covered |
| Malformed bridge payload response | Harnessed smoke | Covered |
| Regular extension editor request remains interactive UI | Harnessed smoke | Covered |
| Native subagent run record and model metadata before process events | Harnessed smoke | Covered |
| Native subagent artifact files: `input.md`, `system-prompt.md`, `output.md` | Harnessed smoke | Covered |
| Read-first path sanitization | Unit/smoke | Covered |
| Forked context fallback and sanitized fork file | Unit/smoke | Covered |
| Child `progress_update` supervisor request | Harnessed smoke | Covered |
| Child blocking `need_decision` supervisor request and answer routing | Harnessed smoke | Covered |
| Child `interview_request` supervisor request | Harnessed smoke | Covered |
| Expected outcome prompt text for report-only/worktree/single-file/direct writes | Harnessed smoke | Covered |
| Worktree patch capture and changed-file parsing | Unit with fake git | Covered |
| Worktree patch apply parent dirty guard | Unit with fake git | Covered |
| Worktree patch unsafe path and non-isolated guards | Unit with fake git | Covered |
| Worktree patch successful apply/discard against a real isolated repository | Real integration | Add next |
| Chain graph execution order and previous-output handoff | Harnessed smoke | Add next |
| Parallel graph concurrency and failure aggregation | Harnessed smoke | Add next |
| Extension isolation for child runs | Unit/smoke | Covered |
| App settings affecting runtime defaults | Unit | Add next |

## Harness Contract

Harnessed smoke tests set `AGENT_DECK_PI_PATH` to a temporary executable. The fake executable emits one or more JSON RPC events and records every line written by Agent Deck to stdin. Tests then assert on:

- app store state
- persisted run/session records
- transcript entries
- artifact files
- `extension_ui_response` lines written back to the fake process

This gives deterministic coverage of the app-owned runtime logic without requiring a real Pi installation.

## Adding A New Smoke Test

1. Add or reuse a fixture in `PiRPCBridgeFixtures.swift`.
2. Create a fake Pi harness with `PiTestSupport.makeBridgeHarness`.
3. Create a temporary `PiAgentSessionStore` using `PiTestSupport.temporaryStateFile`.
4. Start the relevant runner/service.
5. Wait with `PiTestSupport.waitUntil`.
6. Assert both the returned bridge response and the app-owned state transition.

Prefer this pattern over tests that sleep for a fixed time and inspect only console output.
