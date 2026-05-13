# VStack vs LazyVStack decision for Pi Agent transcript (superseded)

Date: 2026-05-13

## Why this was revisited

`LazyVStack` improved long-transcript materialization, but it can reintroduce the older SwiftUI first-paint/autoscroll blank transcript bug. The user reported that this older bug returned after the lazy stack change.

## Documentation consulted

- Apple/Sosumi `ScrollViewReader`: `ScrollViewProxy.scrollTo(_:anchor:)` must be called from actions/modifiers, not during the content builder. It scrolls to child IDs inside contained scroll views.
- Apple/Sosumi `defaultScrollAnchor(_:)`: available macOS 14+, can start vertical scroll views at `.bottom` and can also affect content-size-change repositioning.
- Apple/Sosumi `scrollPosition(_:anchor:)`: macOS 15+, supports identity/edge/offset based scrolling via `ScrollPosition` plus `scrollTargetLayout()`.
- Apple/Sosumi `scrollTargetLayout(isEnabled:)`: marks the main repeating layout as scroll targets.
- Local pidgeon scroll docs: `ScrollViewReader` is older and limited; modern alternatives are `defaultScrollAnchor`, `scrollPosition`, `onScrollPhaseChange`, `onScrollGeometryChange`, and scroll target layouts.

## Experiment

I reverted `PiAgentTranscriptStack` from `LazyVStack` back to `VStack`, rebuilt, ran the required native-app-performance flow, and profiled session switching/input:

- Trace: `/tmp/AgentDeck-vstack-switch.trace`
- Extracted samples: `/tmp/agentdeck-vstack-switch-time-sample.xml`
- Hotspots: `performance-report/vstack-switch-hotspots.txt`
- Load address: `performance-report/vstack-switch-vmmap-text.txt`

## Result

The `VStack` profile was acceptable. In this run, transcript rendering was not the dominant hotspot; the remaining work was mostly `ContentView` / sidebar derived properties and background file-watch scanning.

Compared with the final lazy-stack profile, total app-frame sample counts were in the same rough range for this session-switch/input scenario. `VStack` is expected to use more memory/work for truly huge visible transcripts, but the other fixes from this pass (composer isolation, attachment caches, plan-event map, reduced refresh churn) removed enough pressure that the lazy stack is no longer worth the correctness risk.

## Decision

Superseded by `05-lazyvstack-scrollposition-final.md`. The final implementation uses `LazyVStack` with `ScrollPosition`-based autoscroll.

Original interim decision was: keep `VStack` for now.

Reason: preserving transcript correctness and avoiding the known blank first-paint/autoscroll regression is more important than the incremental lazy materialization win. If long-chat switching is still too slow with `VStack`, the next safer design is not simply `LazyVStack`; it should be one of:

1. `VStack` plus explicit transcript windowing around the post-compaction/current region.
2. macOS 14+ `defaultScrollAnchor(.bottom)` to reduce imperative initial-scroll hacks.
3. macOS 15+ `ScrollPosition` + `scrollTargetLayout()` gated by availability for newer systems.
4. An AppKit-backed transcript scroller if SwiftUI lazy/autoscroll correctness remains unreliable.

## Regression check

After reverting to `VStack`, the full macOS test suite passed:

- `81 passed, 0 failed`
