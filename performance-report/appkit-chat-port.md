# AppKit chat transcript port

## Current chat UI functionality inventory

- Two-column Pi Agent screen with session list and active chat transcript.
- Session list: project/global scoping, search, attention-only filtering, multi-select, shift range select, command-click toggle, selected row sync, active/attention styling, pin/unpin, rename, delete selected, clear scoped/all sessions, empty/search states, add-session menu.
- Header/context: selected session status/kind/date, editable title, last error, startup resources, final system prompt audit card.
- Transcript normalization: hides raw/noisy events, sanitizes leaked tool-name assistant messages, coalesces compaction/status/tool errors, groups entries into turn threads.
- Transcript rendering: user questions, steering messages, thinking disclosure, assistant markdown, status/error rows, web activity summary and links, tool activity chips, inline edit/write diff summaries, current plan cards, native subagent cards, pending supervisor request cards, processing indicator.
- Transcript archives: hides pre-compaction history with Load Earlier/Hide, keeps the newest 10 visible items and exposes older items in a sheet.
- Scrolling UX: initial selected session opens at bottom, new user turn scrolls to bottom, streaming content tracks the bottom while pinned, user scrolling away suppresses streaming auto-scroll for the current turn, explicit send/request scrolls back to bottom, processing indicator participates in bottom scrolling.
- Composer: draft persistence per session, prompt vs steering mode, stop/send, image/file/folder attachment chips, paste compaction markers, drag/drop and paste, slash-command/skill suggestions, @file suggestions, model/thinking/context footer, create-session-from-composer state, UI request inline notice/sheet.
- Inspector compact chat: separate compact transcript in the right inspector with composer and Open Full/Stop controls.

## Implemented branch: `app-kit`

`agent-deck/PiAgentViews.swift` now replaces the main transcript `ScrollViewReader` + SwiftUI `ScrollView` + `LazyVStack` with `PiAgentAppKitTranscriptView`, an `NSViewRepresentable` backed by:

- `NSScrollView` for deterministic AppKit scrolling.
- A flipped document view so top-to-bottom layout remains natural.
- `NSStackView` for vertical transcript layout.
- Reused `NSHostingView<AnyView>` per stable transcript item id, so the existing row/card SwiftUI rendering is retained 1:1 while the slow/blank SwiftUI scroll container is removed.

This preserves the existing transcript information architecture and row rendering while moving the problematic scrolling/layout container to AppKit.

## Documentation/research notes

- Apple `NSScrollView`/`NSTextView`/`NSTableView` documentation was checked via Sosumi. The relevant AppKit primitive here is `NSScrollView`: it exposes direct clip-view bounds control, avoids `ScrollViewReader.scrollTo` identity churn, and gives reliable bottom-position detection.
- Web research confirmed frequent macOS SwiftUI list/lazy-stack pathologies for large/streaming chat views and common AppKit mitigations: batch/reuse rendered views, use `NSScrollView` directly, and throttle bottom scrolling.

## Validation

- Build: `xcodebuildmcp macos build --project-path agent-deck.xcodeproj --scheme agent-deck --configuration Debug` ✅
- Time Profiler smoke trace: `/tmp/AgentDeck-appkit.trace` recorded for 15s launch with `xcrun xctrace`.
- Exported samples: `/tmp/agentdeck-appkit-time-sample.xml`.

## Performance expectation

This is the highest-impact/lowest-risk AppKit port: it removes the SwiftUI lazy scroll container and its `scrollTo`/blank-row failure mode, but keeps all existing transcript cards, markdown, popovers, native subagent cards, and composer behavior intact. A pure AppKit rewrite of every card would be much larger and high-risk because the current UI contains many custom SwiftUI components and interactions.

## Follow-up benchmark plan

For a strict A/B report, run the same scripted workload on `main` and `app-kit`:

1. Open a long Pi Agent session with streaming active.
2. Record 60-90s Time Profiler traces while streaming and scrolling.
3. Compare main-thread samples in SwiftUI layout/rendering, blank-chat incidence, and scroll responsiveness.
4. If needed, create `app-kit-hybrid` for further row-level changes (for example native AppKit markdown/status rows) only where profiler evidence shows row rendering, not scrolling, is the bottleneck.
