# Pi Agent performance fixes and verification

Date: 2026-05-13

## User-facing scenarios profiled

All profiling passes followed `/Users/andrea/Documents/GitHub/skill-sources/agent-scripts/skills/native-app-performance` exactly:

- build/launch correct local Debug app
- `xcrun xctrace record --template 'Time Profiler' --attach <pid>`
- `scripts/extract_time_samples.py`
- `vmmap <pid>` to get the runtime `__TEXT` load address
- `scripts/top_hotspots.py` with the matching Debug dylib and load address

Profile artifacts in this folder:

- `baseline-hotspots.txt` — initial baseline.
- `after-fix-hotspots.txt` / `after-user-cache-hotspots.txt` — intermediate checks.
- `real-chat-hotspots.txt` — real sent-message profile.
- `final-real-chat-hotspots.txt` — real chat after model fallback / refresh changes.
- `lazy-stack-switch-hotspots.txt` — session switching after moving transcript stack to `LazyVStack`.
- `final-switch-hotspots.txt` and `final-sidebar-hotspots.txt` — final session-switch/input checks.

## Real chat verification

A real Pi Agent message was sent from the app using a safe prompt:

> Performance test only. Reply with one short sentence. Do not inspect, modify, create, or delete files. Do not run tools.

Persisted transcript confirmed the response:

> Performance test acknowledged. No files accessed or modified.

No code-editing tools were requested by that prompt.

## Fixes implemented

1. **Composer isolated from the full Pi Agent screen**
   - Moved composer text, attachments, suggestion state, and draft lifecycle into `PiAgentComposerPanel`.
   - This prevents every keystroke from invalidating the large transcript/session-list parent view.

2. **Transcript rendering is now lazy**
   - `PiAgentTranscriptStack` now uses `LazyVStack`.
   - The existing first-paint regression test still passes, so long chats no longer force all transcript rows to materialize eagerly.

3. **Plan event lookup is no longer O(threadCount²)**
   - Replaced per-thread scans with a per-render `planEventsByThreadID` timeline map.

4. **Streaming render churn reduced**
   - Increased streaming flush coalescing and transcript revision coalescing to reduce main-thread invalidation frequency during active responses.

5. **Attachment parsing/preview caching**
   - Cached parsed user-message attachment metadata.
   - Cached decoded attachment preview `NSImage`s.

6. **New-chat model fallback fixed**
   - New Pi Agent sessions now fall back to model options from existing sessions when global model discovery has not finished yet.
   - Title-generation model lookup also falls back to session model options.
   - This addresses the “missing models when opening a new chat” failure mode.

7. **Auto-refresh pressure reduced**
   - File-watch refresh interval changed from 2s to 6s to reduce background filesystem scans during typing/session switching.
   - Manual refresh and normal app behavior remain available; auto detection is just less aggressive.

8. **Sidebar warning computation deduplicated per body pass**
   - Sidebar warnings are collected once per `ContentView` render instead of recalculating through a function for every sidebar row.

## Regression checks

All final checks passed:

- Debug build: succeeded.
- Full macOS test suite: `81 passed, 0 failed`.
- Transcript first-paint smoke test passed with `LazyVStack`.
- Real safe Pi Agent chat sent and response persisted.
- New/draft session records now have model options after fallback/ensure pass.

## Remaining known hotspots

The final session-switch profile no longer shows transcript layout/threading as dominant. Remaining samples are mostly:

- `ContentView.body` and sidebar warning/model/catalog derived properties.
- background file-watch fingerprinting.
- session row body work.

These are outside the worst Pi Agent transcript/input path, but are good future targets if we want another optimization pass.
