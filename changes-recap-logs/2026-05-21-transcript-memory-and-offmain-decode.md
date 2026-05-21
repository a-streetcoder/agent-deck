# Change Recap — Transcript Memory cleanup + off-main transcript decode

- **Date:** 2026-05-21
- **Author:** Claude Code session (assisted)
- **Commits:** `c6061f3` (Change 1) and `045b58d` (Changes 2 & 3)
- **Branch:** `main`

## ⚠️ Rollback warning — read first

These changes were committed **mixed with unrelated parallel work**. Do **not**
`git revert c6061f3` or `git revert 045b58d` — that would also undo unrelated
edits (GitHub Issues UI, `ContentView`, `PiAgentSubagentViews`, retry card, etc.).

To roll back, inspect the per-file diff and reverse **only** the transcript hunks:

```sh
git show c6061f3 -- agent-deck/AppSettings.swift          # Change 1 hunks
git show 045b58d -- agent-deck/PiAgentSessionStore.swift  # Change 2 hunks
```

Every transcript hunk is identifiable by the symbol names listed below.

---

## Why these changes happened

A settings screen exposed a **"Transcript memory"** section — a "Load transcripts
on demand" checkbox and a "Loaded chats" stepper. Investigation (and comparison
with the `osaurus` reference app, which treats lazy transcript loading as an
invisible architectural default with **no** user-facing knobs) concluded these
controls were over-engineered: no user has a reason to disable lazy loading or
hand-tune the warm-cache size.

While verifying that removal, a real performance wrinkle surfaced in the lazy
loading path, which prompted Change 2.

---

## Change 1 — Removed the "Transcript memory" settings knobs

**Commit:** `c6061f3`

Deleted the two user-facing controls. Lazy transcript loading is now **always on**
with a fixed 10-item warm cache (previously the default anyway). The underlying
`PiAgentSessionStore` lazy-load + LRU-eviction machinery is unchanged and still
runs — it is just no longer user-configurable.

### Files & symbols removed

| File | Removed |
|---|---|
| `agent-deck/AppSettings.swift` | `piAgentLazyTranscriptLoadingEnabled` & `piAgentLoadedTranscriptCacheLimit` properties, their `CodingKeys` cases, and their `init(from:)` decode lines |
| `agent-deck/AppSettingsController.swift` | getters `isPiAgentLazyTranscriptLoadingEnabled` / `piAgentLoadedTranscriptCacheLimit`; setters `setPiAgentLazyTranscriptLoadingEnabled(_:)` / `setPiAgentLoadedTranscriptCacheLimit(_:)` |
| `agent-deck/AppViewModel.swift` | the matching getters & setters; `configurePiAgentTranscriptMemory()` and its two call sites (in the initializer and in `syncAppSettings()`) |
| `agent-deck/SettingsSceneContent.swift` | the "Transcript memory" `SettingsSection` (toggle + stepper) in `PerformanceSettingsTab`, plus the `piAgentLazyTranscriptLoadingEnabledBinding` / `piAgentLoadedTranscriptCacheLimitBinding` computed properties |
| `agent-deck/PiAgentSessionStore.swift` | both `init`s stopped reading `AppSettingsStore.shared.settings.piAgent…` — `lazyTranscriptLoadingEnabled` / `transcriptCacheLimit` now use inline defaults (`true` / `10`) |
| `agent-deckTests/PiAgentSessionStoreTests.swift` | the now-defunct `AppSettingsStore` setup inside `testLazyTranscriptLoadingStartsEmptyAndLoadsSelectedTranscriptAsynchronously` |

### Kept on purpose
`PiAgentSessionStore.configureTranscriptMemory(lazyLoadingEnabled:cacheLimit:)`
is retained — the unit tests use it to exercise eviction and the non-lazy path.

### Notes
- `AppSettings` decodes leniently, so old persisted JSON containing the dropped
  keys is simply ignored — **no migration needed**.
- No runtime behavior changed for any real user: lazy loading was already the
  default.

### To roll back Change 1
Reverse the hunks in the six files above (`git show c6061f3 -- <file>`). The
controls reappear in Settings → Performance once `AppSettings`,
`AppSettingsController`, `AppViewModel` and `SettingsSceneContent` are restored,
and `PiAgentSessionStore`'s `init`s read the settings again.

---

## Change 2 — Cold-switch transcript decode moved off the main thread

**Commit:** `045b58d`

### The problem
`PiAgentSessionStore` is `@MainActor`. Switching to a chat **not** in the 10-item
warm cache ran `PiAgentViews.scheduleTranscriptCacheUpdate()` →
`store.transcript(for:)` → `loadTranscriptIfNeeded` → `Data(contentsOf:)` +
`JSONDecoder.decode` **synchronously on the main thread**. For large transcripts
(heavy tool output, near the 500-entry cap) that was a ~100–200 ms UI hitch.
A background loader (`requestTranscriptLoad`) already existed but lost the race.

### The fix — size-gated hydration
New `PiAgentSessionStore.transcriptForCacheUpdate(_:)`:
- **warm** (already in `transcriptsBySessionID`) → return it instantly;
- **small** transcript file (≤ 256 KB) → synchronous decode — instant, no spinner
  (the common case keeps its instant feel);
- **large** file → hand to the background loader, return an empty snapshot so the
  existing "Loading transcript" spinner card shows; when the load finishes it
  bumps `transcriptRevisionsBySessionID`, the `.task(id: store.selectedTranscriptRevision)`
  re-fires, and the cache repopulates from the now-warm transcript.

### Files & symbols added/changed

| File | Change |
|---|---|
| `agent-deck/PiAgentSessionStore.swift` | **added** `private static let maxSyncDecodeTranscriptBytes = 256 * 1024`; **added** `transcriptFileIsSmallEnoughForSyncDecode(_:)` (a failed file-size stat counts as "large" → off-main); **added** `transcriptForCacheUpdate(_:)` (right after `transcript(for:)`) |
| `agent-deck/PiAgentViews.swift` | `scheduleTranscriptCacheUpdate()` now calls `store.transcriptForCacheUpdate(session.id)` instead of `store.transcript(for: session.id)`; comment updated |
| `agent-deckTests/PiAgentSessionStoreTests.swift` | **added** 4 tests: `testTranscriptForCacheUpdateReturnsWarmTranscriptSynchronously`, `…DecodesSmallTranscriptSynchronously`, `…DefersLargeTranscriptToBackgroundLoader`, `…ReturnsFullTranscriptWhenLazyLoadingDisabled` |

### Expected impact
- **Improves:** cold-switching to a *large* chat — no main-thread hitch, brief
  spinner instead.
- **Unchanged (intentional):** small/normal chats (still instant, no spinner),
  warm switches (still instant), memory usage, render cost after load, streaming.
- The `256 * 1024` threshold is the single tunable knob.

### To roll back Change 2
In `PiAgentSessionStore.swift` delete `maxSyncDecodeTranscriptBytes`,
`transcriptFileIsSmallEnoughForSyncDecode(_:)` and `transcriptForCacheUpdate(_:)`.
In `PiAgentViews.swift` change `scheduleTranscriptCacheUpdate()` back to
`store.transcript(for: session.id)`. Optionally delete the 4 new tests.

---

## Change 3 — Unrelated pre-existing test-target fix

**Commit:** `045b58d`

`agent-deckTests/PiExecutableResolverTests.swift:61` used
`getenv("PATH").map(String.init(cString:))`, which no longer compiles under the
macOS 26.4 SDK (`getenv` is imported as non-optional). This broke the **entire
test target**. Changed to:

```swift
let oldPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
```

Unrelated to the transcript work — fixed only so the test suite could run.

---

## Verification performed

- App target: `xcodebuild -scheme agent-deck -destination 'platform=macOS' build` → **BUILD SUCCEEDED**.
- Tests: `xcodebuild test -only-testing:agent-deckTests/PiAgentSessionStoreTests` → **TEST SUCCEEDED**, all 11 tests pass (the 4 new `testTranscriptForCacheUpdate*` plus the pre-existing lazy-loading/eviction tests).

### Not yet done (manual checks worth doing)
1. Cold-switch to a very large chat → expect a brief "Loading transcript" spinner, no freeze.
2. Switch to a small chat → expect instant content, no spinner flash.
3. Rapidly switch A → B → A → expect no blank pane, no stale content.

---

## Related planning artifact
Full design notes: `~/.claude/plans/image-1-is-this-enumerated-flame.md`
(may be session-local; this recap is the durable record).
