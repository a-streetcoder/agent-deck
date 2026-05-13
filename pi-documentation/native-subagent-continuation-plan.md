# Native subagent continuation and context simplification plan

Status: implemented in this change set. This file remains as the saved end-to-end plan and validation checklist for the native subagent continuation work.

## Goals

- Native subagents start as clean child sessions by default.
- Remove parent-session fork behavior from native subagents.
- Remove `defaultContext` and `inheritProjectContext` from agent frontmatter, UI, docs, skills, parsing, and persistence with no backward-compatibility behavior.
- Add explicit continuation for all native subagents: the parent/orchestrator can continue a prior child session by stable subagent ID when a task is a direct follow-up.
- In the Pi Agent chat UI, continuing a child should update the same subagent card instead of creating a separate card.
- Update parent injected guidance so orchestrators choose between fresh runs and explicit continuation correctly.
- Finish with full validation, then update docs, bundled skills, and bundled/project agent frontmatter to the new format.

## Product decisions

1. **Fresh is the default and only implicit launch mode.**
   - A normal `managed_subagent` call starts a new child Pi session.
   - It does not inherit parent conversation history.
   - It does not continue any previous child run.

2. **Continuation is explicit and ID-based.**
   - Any native subagent can be continued, not only `scout` or `reviewer`.
   - The orchestrator decides whether a direct follow-up is better as a continuation or a fresh run.
   - Continuation requires a valid prior subagent ID from the same parent session.

3. **Remove fork context.**
   - Remove `context: fork` / `defaultContext: fork` behavior.
   - Remove `--fork` child launch logic.
   - Remove fork guidance from injected prompts, docs, tests, and UI.

4. **Remove `inheritProjectContext`.**
   - No compatibility path.
   - Stop parsing/persisting/serializing the field.
   - Remove it from all bundled/project agent frontmatter and the agent-authoring skill.
   - Fixed behavior: child Pi sessions should use normal project context-file discovery unless a later product decision explicitly disables it globally. In practice, remove the current `--no-context-files` insertion from native child launch.

5. **Same card for continued runs.**
   - Each subagent has a stable visible ID.
   - Continuations append work under that subagent ID and update the existing card.
   - The card should show that it has multiple turns/continuations and surface the latest status/task.

## Current code areas to change

### Runtime and storage

- `agent-deck/PiAgentSessionModels.swift`
  - `PiManagedSubagentBridgeRequest`
  - `PiSubagentContextMode`
  - `PiSubagentRunRecord`
  - `PiSubagentChildRecord`
- `agent-deck/PiSubagentRunService.swift`
  - fresh child launch
  - session file capture
  - transcript routing
  - supervisor request routing
  - artifact layout
  - run/card status updates
- `agent-deck/PiAgentSessionStore.swift`
  - run update/upsert behavior
  - transcript persistence by run ID
  - migration-safe decoding defaults
- `agent-deck/PiRPCClient.swift`
  - already supports `sessionFile`; use it for continuation.
- `agent-deck/PiSubagentLaunchPlanner.swift`
  - remove context resolution; keep model selection if still needed.

### Parent bridge and orchestration

- `agent-deck/PiNativeSubagentBridgeExtensions.swift`
  - parent bridge tool schema and prompt snippet
- `agent-deck/PiAgentRunnerService.swift`
  - parse/routing for bridge requests
- `agent-deck/AppViewModel.swift`
  - `runManagedNativeSubagent`
  - `runNativeSubagent`
  - native subagent catalog prompt/guidance
  - continue-run validation and error messages

### UI

- `agent-deck/PiAgentViews.swift`
  - native subagent run lookup/card mapping
- `agent-deck/PiAgentSubagentViews.swift`
  - card display, ID display/copy, continuation count/latest task
  - remove context/project-context display
- `agent-deck/PiAgentTranscriptViews.swift`
  - parse/dedupe native subagent card payloads by stable run ID
- `agent-deck/PiAgentActivityPanelViews.swift`
  - activity items for continued turns should group under the same run where appropriate.
- `agent-deck/AgentManagementViews.swift`
- `agent-deck/EditorSheets.swift`
- `agent-deck/EnvironmentDiagnosticsViews.swift`
  - remove `defaultContext` and `inheritProjectContext` UI/diagnostics.

### Agent config/scanning/persistence

- `agent-deck/Models.swift`
  - remove `inheritProjectContext`, `inheritSkills` if unused, and `defaultContext` if the only native use was fork/fresh.
- `agent-deck/PiScanner.swift`
  - stop parsing removed frontmatter fields.
  - do not preserve removed fields in `unknownFields`.
- `agent-deck/PiAgentLaunchResolver.swift`
  - stop applying removed fields from builtin overrides.
- `agent-deck/AgentPersistence.swift`
  - stop serializing removed fields.
  - remove default helper logic for project context.

### Bundled resources and docs

- `agent-deck/bundled-agents/*.md`
  - remove `inheritProjectContext` and `defaultContext`.
- `.pi/agents/*.md` in this repo if intentionally tracked
  - remove old fields.
- `agent-deck/bundled-skills/agent-authoring/SKILL.md`
  - remove context/fork/project-context frontmatter guidance.
  - add fresh-vs-continuation authoring guidance.
- `pi-documentation/native-subagents.md`
- `pi-documentation/official-documentation/reference/agent-frontmatter.md`
- `pi-documentation/pi-core-system-reference-and-subagents.md`
- `pi-documentation/official-documentation/user-guide/native-subagents.md`
- `pi-documentation/official-documentation/contributors/source-map.md`
- `agent-deck-documentation/*` files mentioning launch flags/context.

## Proposed data model

Add turn-level tracking while keeping one stable run/card ID:

```swift
struct PiSubagentTurnRecord: Identifiable, Codable, Hashable {
    var id: UUID
    var index: Int
    var task: String
    var status: PiSubagentRunStatus
    var artifactDirectory: String
    var outputPath: String?
    var sessionFile: String?
    var launchCommand: String?
    var summary: String?
    var error: String?
    var createdAt: Date
    var updatedAt: Date
    var completedAt: Date?
    var durationMs: Int?
}
```

Extend `PiSubagentRunRecord` with fields like:

- `displayID` or reuse `id` as the stable subagent ID shown to the user.
- `cardEntryID: UUID?` for the parent transcript card anchor.
- `turns: [PiSubagentTurnRecord]`.
- `latestTurnID: UUID?` if useful.

Fresh runs create turn `0`. Continuations append another turn to the same run.

## Bridge/tool design

Preferred tool shape:

```text
managed_subagent(agent, task, continueSubagentID?, worktree?, reads?)
```

- If `continueSubagentID` is omitted: start a fresh subagent run.
- If `continueSubagentID` is present: resume that child session and update that same subagent card.
- Remove `context` from the bridge schema.

Alternative: add a separate `continue_subagent(subagentID, task, reads?)` tool. This is clearer but adds another tool. Prefer the optional ID on `managed_subagent` unless implementation clarity argues otherwise.

The tool result should always include the stable subagent ID:

```text
Native subagent completed.
Subagent ID: <uuid>
...
```

Continuation failure messages should be direct:

- ID not found in this parent session.
- Prior run has no child session file yet.
- Prior run is still active.
- Prior child session file no longer exists.
- Prior run used a worktree that has been applied/discarded and cannot be continued safely.

## Launch behavior

### Fresh launch

- Create new run ID.
- Create artifact directory: `Subagent Runs/<run-id>/`.
- Create child session directory: `Subagent Runs/<run-id>/sessions/`.
- Launch Pi with `--session-dir <dir>`.
- Do not pass `--fork`.
- Do not pass `--no-context-files`.
- Capture `childPiSessionFile` from Pi `get_state` response.

### Continuation launch

- Locate the existing run by `continueSubagentID` in the same parent session.
- Validate it can be continued.
- Create per-turn artifact directory, for example:
  - `Subagent Runs/<run-id>/turns/<turn-id>/`
- Launch Pi with:
  - `--session <existing-child-session-file>`
  - same model/tool/extension isolation behavior as fresh runs
- Send a continuation-specific user prompt:
  - prior child messages are available in the resumed child session;
  - the new task is authoritative;
  - expected outcome and artifact path are current for this turn.
- Stream transcript entries under the same run ID.
- Update the run-level summary/status/outputPath to the latest turn.

## Chat UI card behavior

- Fresh run: append a new native subagent card to the parent transcript.
- Continuation: update the existing card entry by `cardEntryID` / run ID.
- The card should show:
  - agent name
  - stable subagent ID
  - status
  - latest task
  - turn/continuation count
  - latest summary/error
- The card details sheet should show all turns for the same subagent, newest first or timeline order.
- Transcript parsing should dedupe by run ID so old and new payload formats cannot produce duplicate cards.

## Parent injected guidance update

Replace current context-oriented guidance with:

```text
- Native subagent runs start fresh by default.
- Do not assume a later `managed_subagent` call remembers an earlier child run.
- The tool result/card shows a stable Subagent ID.
- For a direct follow-up to a previous child, pass that ID as `continueSubagentID` so Agent Deck resumes the same child session and updates the same card.
- If starting fresh for follow-up work, pass a compact continuity packet: prior findings/status, what changed since, relevant artifact paths or files to read, and exact expected output.
- Prefer fresh runs for independent work; prefer continuation for direct refinement, re-review, debugging, or answering a child-specific follow-up.
```

Remove `[context: fresh/fork]` from the available-subagents list.

Optionally add a short list of recent continuable subagents:

```text
Recent continuable subagents:
- <id> reviewer — completed — latest task: ...
```

## Tests and validation plan

### Unit/smoke tests to update or add

- `PiNativeBridgeExtensionSourceTests`
  - `managed_subagent` schema has no `context`.
  - schema includes `continueSubagentID`.
  - prompt snippet includes fresh-by-default and continuation guidance.

- `PiAgentBridgeSmokeTests`
  - bridge decodes continuation ID.
  - parent routes fresh vs continuation correctly.
  - parent response includes stable subagent ID.

- `PiSubagentRuntimeSmokeTests`
  - fresh launch does not include `--fork`.
  - fresh launch does not include `--no-context-files`.
  - continuation launch uses `--session <childPiSessionFile>`.
  - continuation keeps the same run ID and appends a turn.
  - continuation updates the same parent card entry.
  - invalid continuation ID returns a clear error.
  - active run continuation is rejected.

- `PiAgentSessionStoreTests`
  - run/turn persistence round-trips.
  - older persisted runs without turns decode safely.

- Scanner/persistence tests
  - old `defaultContext` and `inheritProjectContext` are ignored and omitted on save.
  - removed fields do not appear in new serialized agents.

- UI/render tests
  - duplicate card payloads for the same run ID render as one card.
  - continued runs show continuation count/latest task.

### Manual/command validation

Run after implementation and docs updates:

```bash
xcrun swiftc -parse -enable-bare-slash-regex agent-deck/*.swift agent-deckTests/*.swift
xcodebuild -project agent-deck.xcodeproj -scheme agent-deck -destination 'platform=macOS' test
xcodebuild -project agent-deck.xcodeproj -scheme agent-deck -destination 'platform=macOS' build
git diff --check
plutil -lint agent-deck.xcodeproj/project.pbxproj
```

### End-to-end manual scenario

1. Start a parent Pi Agent session with native subagents enabled.
2. Ask parent to launch `reviewer` fresh.
3. Confirm the parent chat shows one reviewer card with a stable ID.
4. Ask parent to continue that reviewer by ID for a direct follow-up.
5. Confirm the same card updates rather than a second card appearing.
6. Open the details sheet and verify both turns are visible.
7. Confirm the child continuation transcript includes prior child context and current task.
8. Launch a separate fresh reviewer and confirm it creates a separate card/ID.

## Implementation order

1. Runtime model changes and decoding defaults.
2. Fresh-only launch cleanup: remove fork and project-context flags.
3. Bridge schema/guidance changes.
4. Continuation runtime path using existing `childPiSessionFile`.
5. Stable card entry/upsert behavior.
6. UI updates for IDs and turns.
7. Remove frontmatter fields from parsing/persistence/UI.
8. Update tests and make them pass.
9. Run full validation.
10. Update docs, bundled skills, and agent frontmatter.
11. Final full validation and reviewer pass.

## Risks

- Persisted old runs may lack new turn/card fields; decoding must provide safe defaults.
- Parent transcript cards may already contain old payloads; parsing must remain defensive enough not to crash.
- Continuing a worktree-isolated run after applying/discarding the worktree can be unsafe; reject unless explicitly supported later.
- Removing `--no-context-files` may increase child prompt/context size, but simplifies behavior and respects repo instructions.
- Resuming a child session with changed tool/model configuration may behave differently than the first turn; record launch command and latest model per turn for traceability.

## Open implementation choice

Choose one before coding bridge details:

- **Option A:** `managed_subagent(..., continueSubagentID?)` — one tool, simpler for parent, but schema is a little broader.
- **Option B:** `continue_subagent(subagentID, task, reads?)` — clearer semantics, extra tool.

Current recommendation: Option A, because the orchestrator already thinks in terms of delegating to an agent; the optional ID turns the delegation into a continuation.
