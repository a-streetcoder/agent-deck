# AppKit chat transcript port

## Current chat UI functionality inventory

- Two-column Pi Agent screen with session list and active chat transcript.
- Session list: project/global scoping, search, attention-only filtering, multi-select, shift range select, command-click toggle, selected row sync, active/attention styling, pin/unpin, rename, delete selected, clear scoped/all sessions, empty/search states, add-session menu.
- Header/context: selected session status/kind/date, editable title, last error, startup resources, final system prompt audit card.
- Transcript normalization: hides raw/noisy events, sanitizes leaked tool-name assistant messages, coalesces compaction/status/tool errors, groups entries into turn threads.
- Transcript rendering: user questions, steering messages, thinking disclosure, assistant markdown, status/error rows, web activity summary and links, tool activity chips, inline edit/write diff summaries, current plan cards, native subagent cards, pending supervisor request cards, processing indicator.
- Transcript archives: pre-compaction history can still be hidden with Load Earlier/Hide, but the former latest-10 visible-turn safety window is removed so users can review the full post-compaction transcript inline.
- Scrolling UX: initial selected session opens at bottom, new user turn scrolls to bottom, streaming content tracks the bottom while pinned, user scrolling away suppresses streaming auto-scroll for the current turn, explicit send/request scrolls back to bottom, processing indicator participates in bottom scrolling.
- Composer: draft persistence per session, prompt vs steering mode, stop/send, image/file/folder attachment chips, paste compaction markers, drag/drop and paste, slash-command/skill suggestions, @file suggestions, model/thinking/context footer, create-session-from-composer state, UI request inline notice/sheet.
- Inspector compact chat: separate compact transcript in the right inspector with composer and Open Full/Stop controls.

## Implemented branch: `app-kit-hybrid`

`agent-deck/PiAgentViews.swift` replaces the main transcript `ScrollViewReader` + SwiftUI `ScrollView` + `LazyVStack` with `PiAgentAppKitTranscriptView`, an `NSViewRepresentable` backed by:

- `NSScrollView` for deterministic AppKit scrolling and bottom-position detection.
- `NSTableView` for AppKit row virtualization/reuse.
- `NSHostingView<AnyView>` inside recycled table cells, preserving the existing SwiftUI transcript cards 1:1.
- Existing transcript item ids, archive controls, processing rows, subagent cards, markdown cards, tool summaries, and composer interactions.

An earlier AppKit prototype used `NSStackView` and mounted every row. Profiling showed that was not good enough for unlimited transcripts. The final implementation uses `NSTableView` virtualization instead.

## Documentation/research notes

- Apple `NSScrollView`, `NSTableView`, and related AppKit documentation was checked through Sosumi. The final design uses `NSScrollView` + `NSTableView` because it gives deterministic scroll control plus row reuse.
- Web research confirmed common SwiftUI LazyVStack/List pathologies for large/streaming chat views on macOS, including delayed/blank row rendering, and supported using AppKit-backed virtualization for deterministic chat/log UIs.

## Stress validation

Build command passed after the final implementation:

```bash
xcodebuildmcp macos build --project-path agent-deck.xcodeproj --scheme agent-deck --configuration Debug
```

Stress test data was generated against `/Users/andrea/Documents/GitHub/little-lane`, then the user Application Support data was restored from `/tmp/AgentDeck-AppSupport-backup-before-appkit-stress`.

### Scenarios exercised

1. Real chat creation smoke test in the little-lane project composer.
2. Eight long synthetic little-lane sessions, each with hundreds of transcript entries including user, assistant markdown, thinking, tool calls, web/fetch summaries, status rows, and errors.
3. Session switching between long sessions while profiling.
4. Page up/down/home/end scrolling while profiling.
5. Huge single transcript: 1,200 turns / 2,800 raw entries / full inline transcript, with the latest-10 safety window removed.
6. Visual screenshots confirmed the transcript opened at the bottom and did not render blank in the tested AppKit builds.

### Time Profiler sample counts

These are exported `time-sample` row counts from equivalent scripted stress runs. Lower is better for CPU sampling over the same capture window.

| Build | Transcript mode | Capture | Samples | Notes |
|---|---:|---:|---:|---|
| `main` | latest-10 window | 70s | 2,195 | Existing safety window, not full transcript. |
| SwiftUI `LazyVStack` with latest-10 removed | full 8-session stress | 70s | 3,075 | Full transcript in SwiftUI. |
| AppKit `NSStackView` prototype | full 8-session stress | 70s | 8,210 | Rejected: mounted too much. |
| Final AppKit `NSTableView` | full 8-session stress | 70s | 3,054 | Equivalent to SwiftUI CPU on moderate long sessions, with deterministic AppKit scrolling. |
| SwiftUI `LazyVStack` with latest-10 removed | huge 1,200-turn transcript | 45s | 1,275 | Full huge transcript. |
| Final AppKit `NSTableView` | huge 1,200-turn transcript | 45s | 81 | ~94% fewer samples than SwiftUI in the huge-full-transcript stress case. |

Trace artifacts:

- `/tmp/AgentDeck-main-stress.trace`
- `/tmp/AgentDeck-main-nolimit-stress.trace`
- `/tmp/AgentDeck-appkit-stress2.trace`
- `/tmp/AgentDeck-appkit-table-stress.trace`
- `/tmp/AgentDeck-swiftui-huge.trace`
- `/tmp/AgentDeck-appkit-huge.trace`

## Conclusion

The final AppKit hybrid is the best-performing and safest implementation tested:

- It preserves the existing row UI/UX by keeping SwiftUI transcript cards.
- It removes SwiftUI as the scroll container, which is the source of the blank/lazy rendering instability.
- It uses `NSTableView` row virtualization, so removing the latest-10 transcript limit is viable.
- It performs dramatically better than full SwiftUI on very large full-transcript workloads.

Recommendation: merge the final `app-kit-hybrid` implementation, not the earlier `app-kit` stack prototype.
