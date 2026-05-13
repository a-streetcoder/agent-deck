# Final LazyVStack autoscroll fix

Date: 2026-05-13

## Decision update

The `VStack` revert was correct for stability, but it felt heavier in real use. Final decision: use `LazyVStack`, but remove the fragile `ScrollViewReader`/`ScrollViewProxy.scrollTo` autoscroll path that caused blank first-paint/send states.

## Documentation basis

Apple docs and local scroll docs point to newer scroll APIs:

- `defaultScrollAnchor(.bottom)` controls initial scroll position and content-size-change behavior.
- `ScrollPosition` + `.scrollPosition($position, anchor: .bottom)` provides declarative scroll control.
- `.scrollTargetLayout()` marks the lazy layout as scroll targets for `ScrollPosition`.

This avoids repeatedly calling `proxy.scrollTo("bottom")` during lazy layout materialization.

## Implementation

- `PiAgentTranscriptStack` is back to `LazyVStack`.
- The lazy transcript stack now applies `.scrollTargetLayout()`.
- Pi Agent transcript autoscroll now uses:
  - `@State private var transcriptScrollPosition = ScrollPosition(idType: String.self, edge: .bottom)`
  - `.defaultScrollAnchor(.bottom)`
  - `.scrollPosition($transcriptScrollPosition, anchor: .bottom)`
  - `transcriptScrollPosition.scrollTo(edge: .bottom)` for requested/programmatic bottom scrolls.
- Timeline row IDs were normalized to strings (`item.id`) so they match the `ScrollPosition(idType: String.self)` setup.

## Regression coverage added

Added `testTranscriptStackDoesNotBlankAfterAppendingAndBottomScroll()` to cover the specific send-message path: append a new row and bottom-scroll without rendering blank.

Full test suite now passes:

- `82 passed, 0 failed`

## Manual/UI check

Captured the running app after a send-message attempt with the lazy + ScrollPosition implementation:

- Screenshot: `performance-report/lazy-scrollposition-after-send.png`
- Non-white sample count: `4993`, confirming the UI was not blank.

## Required native performance check

Followed the native-app-performance flow again:

- Trace: `/tmp/AgentDeck-lazy-scrollposition.trace`
- Extracted samples: `/tmp/agentdeck-lazy-scrollposition-time-sample.xml`
- Hotspots: `performance-report/lazy-scrollposition-hotspots.txt`
- Load address: `performance-report/lazy-scrollposition-vmmap-text.txt`

Result: transcript rendering is not the dominant hotspot in the final lazy + ScrollPosition profile.
