# AppKit Chat Port Recap

## Summary

The Pi Agent main transcript view was ported from SwiftUI scrolling (`ScrollViewReader` + `ScrollView` + `LazyVStack`) to an AppKit-backed hybrid view.

Final implementation:

- AppKit `NSScrollView` owns scrolling.
- AppKit `NSTableView` owns transcript row virtualization/reuse.
- Existing SwiftUI transcript cards are hosted inside recycled `NSHostingView` cells.
- The former latest-10 visible transcript window is removed; users can review the full post-compaction transcript inline.
- Pre-compaction archive behavior remains unchanged.

## Files changed

- `agent-deck/PiAgentViews.swift`
  - Added `PiAgentAppKitTranscriptView`.
  - Replaced main transcript `ScrollViewReader`/`LazyVStack` with AppKit `NSScrollView`/`NSTableView`.
  - Kept all existing transcript row/card rendering by wrapping row views in `NSHostingView`.
  - Preserved pinned-to-bottom detection, streaming auto-scroll suppression, explicit bottom scroll requests, and session-switch bottom positioning.
  - Removed the latest-10 visible-turn limit by setting `recentTranscriptTimelineItemLimit = Int.max`.
- `performance-report/appkit-chat-port.md`
  - Full functionality inventory, implementation notes, test scenarios, profiler results, and conclusion.
- `APPKIT_CHAT_PORT_RECAP.md`
  - This root-level merge recap.

## Functionality preserved

Verified against code and stress UI runs:

- Session list selection/switching.
- Full transcript rendering.
- User cards.
- Assistant markdown cards.
- Thinking rows/disclosures.
- Tool summaries.
- Web/fetch summaries.
- Status and error rows.
- System prompt audit card.
- Startup resources card.
- Processing indicator.
- Bottom auto-scroll behavior.
- User scroll-away suppression.
- Composer area and footer remain unchanged.

## Validation performed

Build:

```bash
xcodebuildmcp macos build --project-path agent-deck.xcodeproj --scheme agent-deck --configuration Debug
```

Stress testing used `/Users/andrea/Documents/GitHub/little-lane` as the project context. User Agent Deck support data was backed up before synthetic stress data and restored afterward.

Tested scenarios:

1. Real little-lane chat creation smoke test.
2. Eight long sessions with hundreds of transcript entries each.
3. Session switching across long sessions.
4. Page up/down/home/end transcript scrolling.
5. Huge 1,200-turn / 2,800-entry full transcript.
6. Comparison against SwiftUI with the latest-10 limit removed.
7. Comparison against an initial AppKit `NSStackView` prototype, which was rejected.

## Profiler result highlights

Lower sample count is better over the same capture window.

| Build | Scenario | Samples |
|---|---:|---:|
| SwiftUI no-limit | Huge 1,200-turn transcript, 45s | 1,275 |
| Final AppKit `NSTableView` | Huge 1,200-turn transcript, 45s | 81 |

That is approximately a 94% reduction in samples for the full huge transcript case.

The initial AppKit `NSStackView` prototype was rejected because it mounted too many row views and profiled worse than SwiftUI on moderate long transcripts. The final `NSTableView` virtualization is the version to merge.

## Conclusion

Merge the final AppKit hybrid implementation. It keeps the current UI/UX, removes the unreliable SwiftUI lazy scroll container, supports full transcript visibility, and is substantially faster on very large transcripts.
