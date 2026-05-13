# Baseline performance profile — Pi Agent view

Date: 2026-05-13

## Required profiling workflow used

Following `/Users/andrea/Documents/GitHub/skill-sources/agent-scripts/skills/native-app-performance`:

1. Built the local Debug app with `xcodebuildmcp macos build`.
2. Launched the local built app from `/tmp/agent-deck-derived/Build/Products/Debug/Agent Deck.app`.
3. Attached Time Profiler with:
   `xcrun xctrace record --template 'Time Profiler' --time-limit 30s --output /tmp/AgentDeck-baseline.trace --attach 58932`
4. Exported samples with:
   `scripts/extract_time_samples.py --trace /tmp/AgentDeck-baseline.trace --output /tmp/agentdeck-baseline-time-sample.xml`
5. Got the runtime `__TEXT` address with `vmmap 58932`.
6. Symbolicated/ranked with:
   `scripts/top_hotspots.py --samples /tmp/agentdeck-baseline-time-sample.xml --binary '/tmp/agent-deck-derived/Build/Products/Debug/Agent Deck.app/Contents/MacOS/Agent Deck.debug.dylib' --load-address 0x105008000 --top 60`

Raw ranked hotspots: `performance-report/baseline-hotspots.txt`.

## Observed app-frame hotspots relevant to long Pi Agent chats

- `PiAgentScreen.body` / `activeSessionColumn` / `transcript` are present in samples while interacting with the app.
- `PiAgentScreen.planEvents(for:in:)` appears as a transcript rendering hotspot. It scans timeline items for every rendered thread, which becomes O(threadCount²) during long chats.
- `DropSafeNSTextView.keyDown(with:)` appears while typing; because composer text state currently lives in `PiAgentScreen`, each keystroke can invalidate the large parent view containing the transcript.
- `PiAgentComposerBox.body` and image preview decoding (`PiAgentComposerImageLoader.previewImage(for:)`) appear in samples; preview images are decoded repeatedly instead of cached.
- Transcript persistence and JSON decoding appear in samples during active sessions; these are secondary and should be handled carefully to avoid data-loss regressions.

## Bugs/issues to fix

1. **Typing invalidates too much UI**: composer text/attachments are state in `PiAgentScreen`, so keystrokes can trigger recomputation of the transcript and session list.
2. **O(n²) plan event association**: `planEvents(for:in:)` repeatedly scans all timeline items for every thread.
3. **Repeated image preview decoding**: image attachment thumbnails decode base64 into `NSImage` during body evaluation.
4. **Transcript view is non-lazy**: the stack intentionally uses `VStack` due a first-paint regression test, but long transcripts still need isolation/windowing/lazy-safe improvements after preserving the first-paint behavior.

## Initial regression status

- Clean Debug build: passed.
- Full test suite before changes: 80 passed, 1 failed with a pre-existing crash in `PiAgentTranscriptRenderSmokeTests.testTranscriptStackFirstPaintIsNotBlankAfterInitialBottomScroll()` during `runMainLoop`. This was captured before any code edits in this performance pass.
