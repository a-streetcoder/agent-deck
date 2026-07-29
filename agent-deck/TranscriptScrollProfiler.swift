import Foundation
import QuartzCore
import os

/// Lightweight, in-place scroll profiler for the Pi Agent transcript.
///
/// The transcript is an `NSTableView` of `NSHostingView`-backed cells (see
/// `PiAgentAppKitTranscriptView.Coordinator`). Scroll jank in that design comes
/// from main-thread work that lands *between* scroll frames: building a SwiftUI
/// root when a cell is vended, a row re-tile (`noteHeightOfRows` +
/// `layoutSubtreeIfNeeded` + anchor restore) when a never-measured row first
/// resolves its real height, or anything synchronous in the bounds observer.
///
/// This profiler frames each scroll gesture, watches the gap between
/// user-driven bounds ticks (a stalled main thread shows up as a long gap = a
/// dropped frame), and attributes time to each suspect op. On gesture end (or
/// after the scroll goes idle) it emits one summary line so you can see, per
/// gesture: how many frames hitched, the worst gap, and where the time went.
///
/// ## Reading the logs
/// No sandbox, so `os.Logger` is visible system-wide. After scrolling:
/// ```
/// log show --last 2m --predicate 'subsystem == "works.earendil.pi-deck" AND category == "ScrollPerf"' --info
/// ```
/// or live:
/// ```
/// log stream --predicate 'subsystem == "works.earendil.pi-deck" AND category == "ScrollPerf"' --info
/// ```
///
/// Toggle off via `defaults write works.earendil.pi-deck ScrollPerfEnabled -bool NO`
/// (defaults ON while we hunt this down — it is cheap: a couple of timestamp
/// reads per scroll frame, all threshold-gated so nothing logs when smooth).
@MainActor
final class TranscriptScrollProfiler {
    static let logger = Logger(subsystem: "works.earendil.pi-deck", category: "ScrollPerf")
    static let signposter = OSSignposter(subsystem: "works.earendil.pi-deck", category: "ScrollPerf")

    /// Mirror key perf lines to a file. `os.Logger` is invisible to `log
    /// stream`/`log show` in some headless/automation contexts (no unified-log
    /// access), so the perf harness also appends its summaries here where any
    /// process can read them. DEBUG-only writes are ordered on a background queue,
    /// never synchronously on a scroll or heartbeat path.
    /// File: `/tmp/agentdeck-perf.txt` (truncate between runs with the harness).
    static func fileLog(_ line: String) {
#if DEBUG
        guard isEnabled else { return }
        DebugArtifactWriter.perfLog.append(line: line)
#endif
    }

    /// Drains DEBUG artifact writes before a consumer reads the perf log.
    static func flushFileLog(completion: @escaping @MainActor @Sendable () -> Void) {
#if DEBUG
        DebugArtifactWriter.perfLog.flush(completion: completion)
#else
        completion()
#endif
    }

    /// Master switch. DEBUG builds only (defaults ON, toggleable); release builds
    /// compile it to a constant `false`, so every `measure*` is a pass-through and
    /// nothing logs in production.
    static let isEnabled: Bool = {
        #if DEBUG
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "ScrollPerfEnabled") == nil { return true }
        return defaults.bool(forKey: "ScrollPerfEnabled")
        #else
        return false
        #endif
    }()

    /// Extra-chatty per-pulse attribution traces (itemsBuild/apply-work trigger
    /// lines, session-list re-eval). OFF by default — they fire every streaming tick
    /// and drown the console. Opt in while chasing a specific churn bug:
    /// `defaults write works.earendil.pi-deck TranscriptVerboseTrace -bool YES`.
    /// The hitch/hang signal (gesture summaries, dropped-frame samples) is never
    /// gated by this, so the console stays useful for jank hunting when it's off.
    static let verboseTrace: Bool = {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "TranscriptVerboseTrace")
        #else
        return false
        #endif
    }()

    // A 60 Hz frame is 16.67 ms. Treat a gap between consecutive user-driven
    // bounds ticks above this as a dropped frame ("hitch") — the main thread
    // couldn't service the scroll in time.
    private let hitchThresholdMs: Double = 24
    // Per-op single-event log threshold. An individual op slower than this is
    // worth surfacing on its own line, not just in the gesture aggregate.
    private let opLogThresholdMs: Double = 4
    // Idle gap that ends a gesture for devices that post no live-scroll
    // notifications (discrete mouse wheel). Trackpad/scroller use start/end.
    private let idleFlushMs: Double = 300
    // A hitch at or above this gap triggers a one-shot external backtrace via
    // HangWatchdog — the decisive capture for sustained "feels slow" jank that
    // never reaches the 150ms hang threshold. HangWatchdog throttles the
    // captures, so this can fire freely. Disable with
    // `defaults write works.earendil.pi-deck ScrollPerfBacktrace -bool NO`.
    private let backtraceThresholdMs: Double = 45
    private static let backtraceOnHitch: Bool = {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "ScrollPerfBacktrace") == nil { return true }
        return defaults.bool(forKey: "ScrollPerfBacktrace")
    }()

    /// Optional label stamped onto every gesture summary + hitch line — set by
    /// the scroll benchmark to "S2/4 long abc123" so each gesture is attributable
    /// to a specific session + phase across an automated multi-session run.
    var benchTag: String?
    /// Coarse description of what's on screen, set at gesture/bench start, so a
    /// slow gesture is correlated with content shape ("why these sessions").
    var contentFingerprint: String?

    // MARK: Streaming-vs-static mode
    //
    // The same hitch means opposite things depending on what the transcript is
    // doing: scrolling a finished transcript (cells evicted + rebuilt on
    // scroll-back) vs live generation (rows appended + reconciled while the
    // follow-glide runs). The coordinator stamps streaming activity here so every
    // line says which regime it happened in — without it, a shared log mixing both
    // can't be read. `static` = no streaming update in the last ~600ms.
    private var lastStreamingActivity: CFTimeInterval = 0
    /// Call once per `apply()` that carried a streaming update.
    func noteStreamingActivity() { lastStreamingActivity = CACurrentMediaTime() }
    var isStreamingRecently: Bool { CACurrentMediaTime() - lastStreamingActivity < 0.6 }
    /// True while a transcript scroll gesture/bench window is active or waiting
    /// for its idle flush. Used to keep speculative work off the scroll path.
    var isScrollWindowActive: Bool { window != nil }
    /// Compact regime tag stamped on every line: `stream` / `static`, plus
    /// `+scroll` when a user scroll gesture is in flight (so "scrolling WHILE
    /// streaming" is distinct from either alone).
    var modeTag: String {
        (isStreamingRecently ? "stream" : "static") + (window != nil ? "+scroll" : "")
    }

    func setBenchTag(_ tag: String?) { benchTag = tag }
    func setContentFingerprint(rows: Int, tallRows: Int, totalEstHeight: CGFloat) {
        contentFingerprint = "rows=\(rows) tall=\(tallRows) estH=\(Int(totalEstHeight))"
    }

    // MARK: Body-side instrumentation (static)
    //
    // The `PiAgentAppKitTranscriptView` representable is a SwiftUI value type
    // with no handle on the coordinator's profiler instance. These static
    // hooks measure the work that happens in the SwiftUI body / representable
    // update path: rebuilding the `items` array (an AnyView per row) and the
    // `updateNSView` apply. Both log every call over a low threshold AND every
    // Nth call regardless, so the per-second call frequency is visible — that
    // distinguishes "body re-evaluates every scroll frame" from "rare rebuild".
    private static var bodyCounters: [String: Int] = [:]

#if DEBUG
    /// Total times `measureBody(label:)` has been entered — used by perf tests to
    /// prove a SwiftUI body/representable update did (or didn't) run over a window.
    static func bodyCallCount(_ label: String) -> Int { bodyCounters[label] ?? 0 }
#endif

    static func measureBody<T>(_ label: String, _ body: () -> T) -> T {
        guard isEnabled else { return body() }
        let t = CACurrentMediaTime()
        let r = body()
        let dt = (CACurrentMediaTime() - t) * 1000
        let n = (bodyCounters[label] ?? 0) + 1
        bodyCounters[label] = n
        // Only surface calls slow enough to plausibly drop a frame (a 60Hz frame is
        // 16.7ms). The old "every 20th call" cadence + 2ms floor logged routine
        // sub-frame work every streaming tick, which buried the real hitches. Cheap
        // calls stay silent unless `verboseTrace` is on.
        if dt > 8 || (verboseTrace && dt > 2) {
            logger.info("\(label, privacy: .public) \(dt, format: .fixed(precision: 1))ms (call #\(n))")
        }
        return r
    }

    /// Lightweight phase timing for sub-steps inside a measured body/apply call.
    /// Kept separate from `measureBody` so perf tests that count SwiftUI body
    /// entries do not see nested implementation phases as additional body calls.
    static func measurePhase<T>(_ label: String, _ body: () -> T) -> T {
#if DEBUG
        guard isEnabled else { return body() }
        let t = CACurrentMediaTime()
        let r = body()
        let dt = (CACurrentMediaTime() - t) * 1000
        if dt > 4 || (verboseTrace && dt > 0.5) {
            logger.info("phase \(label, privacy: .public) \(dt, format: .fixed(precision: 1))ms")
        }
        return r
#else
        return body()
#endif
    }

    // MARK: Per-gesture accumulator
    private struct Window {
        var startTime: CFTimeInterval
        var lastTickTime: CFTimeInterval
        var tickCount = 0
        var hitchCount = 0
        var maxGapMs: Double = 0
        var sumGapMs: Double = 0

        var configures = 0
        var rootSwaps = 0
        var rootSwapMs: Double = 0
        var maxRootSwapMs: Double = 0
        var hostCreates = 0
        var hostCreateMs: Double = 0

        var retiles = 0
        var retiledRows = 0
        var retileMs: Double = 0
        var maxRetileMs: Double = 0

        var forcedMeasures = 0
        var forcedMeasureMs: Double = 0

        // The deferred SwiftUI layout/draw of a hosting view, captured in the
        // cell's AppKit layout() pass — the work that actually lands *after* a
        // cheap rootView swap.
        var cellLayouts = 0
        var cellLayoutMs: Double = 0
        var maxCellLayoutMs: Double = 0

        // Synchronous time spent inside the bounds observer itself (our own
        // per-tick code: width resync, pinned-state publish, follow decisions).
        var boundsTicks = 0
        var boundsMs: Double = 0
        var maxBoundsMs: Double = 0
    }

    private var window: Window?
    private var idleFlush: DispatchWorkItem?
    private var gestureSeq = 0
    /// Live os_signpost interval for the current gesture — lets Instruments'
    /// timeline (Time Profiler / os_signpost lanes) align CPU samples and the
    /// deferred CoreAnimation/TextKit work to the exact gesture that hitched,
    /// covering the work this profiler can't measure synchronously in-process.
    private var gestureSignpost: OSSignpostIntervalState?

    private func now() -> CFTimeInterval { CACurrentMediaTime() }

    private func ms(_ a: CFTimeInterval, _ b: CFTimeInterval) -> Double { (a - b) * 1000 }

    // MARK: Gesture framing

    /// A trackpad gesture / scroller drag began (`willStartLiveScroll`).
    func gestureStart() {
        guard Self.isEnabled else { return }
        flush(reason: "newGesture")
        beginWindow()
    }

    /// A trackpad gesture / scroller drag ended (`didEndLiveScroll`).
    func gestureEnd() {
        guard Self.isEnabled else { return }
        scheduleIdleFlush()
    }

    private func beginWindow() {
        let t = now()
        gestureSeq += 1
        window = Window(startTime: t, lastTickTime: t)
        let id = Self.signposter.makeSignpostID()
        gestureSignpost = Self.signposter.beginInterval("scrollGesture", id: id)
    }

    /// One user-driven (non-programmatic) clip-bounds change. Called from the
    /// bounds observer. Measures the gap to the previous tick to spot dropped
    /// frames, and lazily opens a window for wheel scrolls that never sent a
    /// live-scroll start.
    func userScrollTick() {
        guard Self.isEnabled else { return }
        let t = now()
        if window == nil { beginWindow() }
        guard var w = window else { return }
        if w.tickCount > 0 {
            let gap = ms(t, w.lastTickTime)
            w.sumGapMs += gap
            if gap > w.maxGapMs { w.maxGapMs = gap }
            if gap > hitchThresholdMs {
                w.hitchCount += 1
                Self.logger.info("hitch Δ=\(gap, format: .fixed(precision: 1))ms [\(self.modeTag, privacy: .public)] (gesture #\(self.gestureSeq)) \(self.benchTag ?? "", privacy: .public)")
                Self.signposter.emitEvent("hitch", "gap=\(Int(gap))ms")
                // The decisive capture: a real backtrace of whatever blocked the
                // frame, for jank too brief to trip the hang watchdog.
                if Self.backtraceOnHitch, gap >= backtraceThresholdMs {
                    HangWatchdog.shared.captureHitch(gapMs: Int(gap))
                }
            }
        }
        w.tickCount += 1
        w.lastTickTime = t
        window = w
        scheduleIdleFlush()
    }

    private func scheduleIdleFlush() {
        idleFlush?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.flush(reason: "idle")
        }
        idleFlush = work
        DispatchQueue.main.asyncAfter(deadline: .now() + idleFlushMs / 1000, execute: work)
    }

    private func flush(reason: String) {
        idleFlush?.cancel()
        idleFlush = nil
        guard let w = window, w.tickCount > 0 else {
            window = nil
            if let s = gestureSignpost { Self.signposter.endInterval("scrollGesture", s); gestureSignpost = nil }
            return
        }
        window = nil
        if let s = gestureSignpost {
            Self.signposter.endInterval("scrollGesture", s, "hitches=\(w.hitchCount) maxGap=\(Int(w.maxGapMs))ms")
            gestureSignpost = nil
        }
        let durMs = ms(w.lastTickTime, w.startTime)
        let avgGap = w.tickCount > 1 ? w.sumGapMs / Double(w.tickCount - 1) : 0
#if DEBUG
        Self.fileLog("gesture #\(gestureSeq) [\(reason)] [\(modeTag)] \(benchTag ?? "") \(contentFingerprint ?? "") "
            + "\(w.tickCount)ticks/\(Int(durMs))ms hitches=\(w.hitchCount) maxGap=\(String(format: "%.0f", w.maxGapMs)) "
            + "avgGap=\(String(format: "%.1f", avgGap)) configures=\(w.configures) hostCreate=\(w.hostCreates)(\(String(format: "%.0f", w.hostCreateMs))ms) "
            + "retiles=\(w.retiles)/rows\(w.retiledRows)(\(String(format: "%.0f", w.retileMs))ms,max\(String(format: "%.1f", w.maxRetileMs)))")
#endif
        Self.logger.info("""
        gesture #\(self.gestureSeq) [\(reason, privacy: .public)] [\(self.modeTag, privacy: .public)] \(self.benchTag ?? "", privacy: .public) \(self.contentFingerprint ?? "", privacy: .public) \
        \(w.tickCount) ticks / \(durMs, format: .fixed(precision: 0))ms · \
        hitches=\(w.hitchCount) maxGap=\(w.maxGapMs, format: .fixed(precision: 1))ms avgGap=\(avgGap, format: .fixed(precision: 1))ms │ \
        configures=\(w.configures) rootSwaps=\(w.rootSwaps)(\(w.rootSwapMs, format: .fixed(precision: 1))ms,max \(w.maxRootSwapMs, format: .fixed(precision: 1))) \
        hostCreate=\(w.hostCreates)(\(w.hostCreateMs, format: .fixed(precision: 1))ms) │ \
        retiles=\(w.retiles)/rows \(w.retiledRows)(\(w.retileMs, format: .fixed(precision: 1))ms,max \(w.maxRetileMs, format: .fixed(precision: 1))) \
        forced=\(w.forcedMeasures)(\(w.forcedMeasureMs, format: .fixed(precision: 1))ms) │ \
        cellLayout=\(w.cellLayouts)(\(w.cellLayoutMs, format: .fixed(precision: 1))ms,max \(w.maxCellLayoutMs, format: .fixed(precision: 1))) \
        boundsCb=\(w.boundsTicks)(\(w.boundsMs, format: .fixed(precision: 1))ms,max \(w.maxBoundsMs, format: .fixed(precision: 1)))
        """)
    }

    // MARK: Op timers — call around the suspected hot paths.

    /// Wrap the SwiftUI root swap in `installRootView` (existing host gets a new
    /// `rootView`). This forces a SwiftUI build/layout for the cell.
    func measureRootSwap<T>(_ body: () -> T) -> T {
        guard Self.isEnabled else { return body() }
        let t = now()
        let r = Self.signposter.withIntervalSignpost("rootSwap") { body() }
        let dt = ms(now(), t)
        if window != nil {
            window!.rootSwaps += 1
            window!.rootSwapMs += dt
            if dt > window!.maxRootSwapMs { window!.maxRootSwapMs = dt }
        }
        if dt > opLogThresholdMs {
            Self.logger.info("rootSwap \(dt, format: .fixed(precision: 1))ms")
        }
        return r
    }

    /// Wrap the first-time `NSHostingView` creation in `installRootView`.
    func measureHostCreate<T>(_ body: () -> T) -> T {
        guard Self.isEnabled else { return body() }
        let t = now()
        let r = body()
        let dt = ms(now(), t)
        if window != nil {
            window!.hostCreates += 1
            window!.hostCreateMs += dt
        }
        if dt > opLogThresholdMs {
            Self.logger.info("hostCreate \(dt, format: .fixed(precision: 1))ms")
        }
        return r
    }

    /// Count a cell configure (cheap; just a counter to gauge churn per gesture).
    func noteConfigure() {
        guard Self.isEnabled, window != nil else { return }
        window!.configures += 1
    }

    /// Wrap the whole `noteHeightsChanged` re-tile (noteHeightOfRows +
    /// layoutSubtreeIfNeeded + anchor restore) — the row-resolve lurch suspect.
    func measureRetile<T>(rows: Int, _ body: () -> T) -> T {
        guard Self.isEnabled else { return body() }
        let t = now()
        let r = Self.signposter.withIntervalSignpost("retile") { body() }
        let dt = ms(now(), t)
        if window != nil {
            window!.retiles += 1
            window!.retiledRows += rows
            window!.retileMs += dt
            if dt > window!.maxRetileMs { window!.maxRetileMs = dt }
        }
        if dt > opLogThresholdMs {
            Self.logger.info("retile rows=\(rows) \(dt, format: .fixed(precision: 1))ms")
        }
        return r
    }

    /// Wrap the cell's `layout()` pass — this is where the deferred SwiftUI
    /// layout/draw of a freshly-swapped `rootView` actually lands.
    func measureCellLayout<T>(_ body: () -> T) -> T {
        guard Self.isEnabled else { return body() }
        let t = now()
        let r = Self.signposter.withIntervalSignpost("cellLayout") { body() }
        let dt = ms(now(), t)
        if window != nil {
            window!.cellLayouts += 1
            window!.cellLayoutMs += dt
            if dt > window!.maxCellLayoutMs { window!.maxCellLayoutMs = dt }
        }
        if dt > opLogThresholdMs {
            Self.logger.info("cellLayout \(dt, format: .fixed(precision: 1))ms")
        }
        return r
    }

    /// Wrap the bounds-observer body — our own synchronous per-scroll-tick work.
    func measureBoundsCallback<T>(_ body: () -> T) -> T {
        guard Self.isEnabled else { return body() }
        let t = now()
        let r = body()
        let dt = ms(now(), t)
        if window != nil {
            window!.boundsTicks += 1
            window!.boundsMs += dt
            if dt > window!.maxBoundsMs { window!.maxBoundsMs = dt }
        }
        if dt > opLogThresholdMs {
            Self.logger.info("boundsCb \(dt, format: .fixed(precision: 1))ms")
        }
        return r
    }

    /// Attribute a single cell-provider vend / `installNativeRow` — the path that
    /// builds (or reuses) a row's view when the table asks for it during scroll or
    /// a streaming snapshot apply. This is the hitch the gesture summary kept
    /// missing: it runs inside the diffable data source's cell-provider closure and
    /// the apply's reconfigure, neither of which any other `measure*` wraps, so a
    /// fresh-build hitch showed up as "nothing attributed". Logs only over a frame
    /// budget so steady cache-hit reuse (the common case) stays silent.
    ///
    /// `fresh` = a brand-new view was constructed (cache miss / evicted row /
    /// type swap); `rebuilt` = the markdown subtree did a full teardown+rebuild
    /// (vs a cheap in-place reconcile). Both being true on a scroll frame is the
    /// smoking gun for "scrolling a long transcript rebuilds evicted cells".
    /// `body` performs the build and returns its own attribution — evaluated AFTER
    /// the build so it reflects this vend, not the previous one. A `nil` return
    /// means the row isn't a markdown row (tool group, subagent card, …), so the
    /// rebuild/block-count detail is omitted rather than guessed.
    /// `via` names the call path that triggered the build, so the log separates
    /// the two regimes a shared capture mixes:
    ///   • `scroll-vend` — AppKit asked the data source for a row's view (the row
    ///     scrolled on screen, or a snapshot inserted it). With `[static]` this is
    ///     a cell evicted + rebuilt on scroll-back — the scrolling-cost story.
    ///   • `stream-reconfig` / `width-reconfig` / `chrome-reconfig` — the
    ///     coordinator re-ran a visible cell because its content/width changed.
    ///     With `[stream]` this is the live-generation-cost story.
#if DEBUG
    func measureCellBuild(id: String, fresh: Bool, makeMs: Double = 0, via: String, _ body: () -> (rebuilt: Bool, blocks: Int)?) {
        guard Self.isEnabled else { _ = body(); return }
        let t = now()
        let attribution = Self.signposter.withIntervalSignpost("cellBuild") { body() }
        let dt = ms(now(), t) + makeMs
        if window != nil {
            // Fold into the per-gesture host-create tally so the summary's cost
            // accounting reflects build-dominated scroll.
            window!.hostCreateMs += dt
            window!.hostCreates += 1
        }
        // 8ms ≈ half a 120Hz frame: a single cell build over this plausibly drops a
        // frame on its own. Fresh builds and full rebuilds are the expensive kind;
        // surface them by name so the console says WHY the row was costly.
        if dt > 8 {
            let detail = attribution.map { "\($0.rebuilt ? "FULL-REBUILD" : "reconcile") blocks=\($0.blocks)" } ?? "non-markdown-row"
            Self.logger.error("""
            cellBuild \(dt, format: .fixed(precision: 1))ms [\(self.modeTag, privacy: .public)] via=\(via, privacy: .public) \
            id=\(String(id.suffix(6)), privacy: .public) \(fresh ? "FRESH-VIEW" : "reuse", privacy: .public) \(detail, privacy: .public)
            """)
            Self.fileLog("cellBuild \(String(format: "%.1f", dt))ms (make=\(String(format: "%.1f", makeMs)) cfg=\(String(format: "%.1f", dt - makeMs))) [\(modeTag)] via=\(via) id=\(String(id.suffix(6))) "
                + "\(fresh ? "FRESH-VIEW" : "reuse") \(detail)")
        }
    }
#endif

    /// Wrap a synchronous forced measurement (`forcedIntrinsicHeight` batches).
    func measureForced<T>(_ body: () -> T) -> T {
        guard Self.isEnabled else { return body() }
        let t = now()
        let r = Self.signposter.withIntervalSignpost("forcedMeasure") { body() }
        let dt = ms(now(), t)
        if window != nil {
            window!.forcedMeasures += 1
            window!.forcedMeasureMs += dt
        }
        if dt > opLogThresholdMs {
            Self.logger.info("forcedMeasure \(dt, format: .fixed(precision: 1))ms")
        }
        return r
    }
}
