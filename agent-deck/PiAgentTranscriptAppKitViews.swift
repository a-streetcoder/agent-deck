import AppKit
import Combine
import Darwin
import os
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

struct PiAgentAppKitTranscriptView: NSViewRepresentable {
    let items: [PiAgentAppKitTranscriptItem]
    let sessionID: UUID?
    /// Which session the render cache's content belonged to when `items` were
    /// built. Differs from `sessionID` during the switch transition passes.
    let itemsSessionID: UUID?
    let isTranscriptLoading: Bool
    let renderRevision: Int
    let streamingRevision: Int
    let autoScrollTurnRevision: Int
    let bottomScrollRequest: Int
    let onPinnedToBottomChange: (Bool) -> Void
    /// Called as the user starts/stops scrolling history; the cache uses it to
    /// defer streaming pulses (and the scaffold relayout they cause) until settle.
    let onScrollingChange: (Bool) -> Void
    /// Advance selection to the next session (the ⌘] action). Used only by the
    /// scroll benchmark to sweep multiple chats; nil disables multi-session.
    var onBenchAdvanceSession: (() -> Void)?
    var benchSessionCount: (() -> Int)?

    func makeCoordinator() -> Coordinator {
        Coordinator(onPinnedToBottomChange: onPinnedToBottomChange)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = PiAgentTranscriptTableView()
        tableView.headerView = nil
        tableView.backgroundColor = .clear
        tableView.gridStyleMask = []
        tableView.selectionHighlightStyle = .none
        tableView.allowsColumnSelection = false
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.usesAlternatingRowBackgroundColors = false
        // Rows are block-granular; inter-row spacing varies (question↔reply,
        // sibling, thread↔thread), so it's baked into each row as padding
        // rather than this uniform value. See `PiAgentAppKitTranscriptItem`.
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.rowHeight = 120
        tableView.usesAutomaticRowHeights = false
        // The default `.automatic` style resolves to `.inset`, which adds a
        // system horizontal margin (~16pt) to every cell. That pushed all rows
        // inboard of the composer (which lives outside the table). `.plain`
        // removes the inset so a cell pinned at x=0 lines up with the composer's
        // container edge. Row-internal padding is handled per-block instead.
        tableView.style = .plain

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("TranscriptColumn"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle

        let scrollView = PiAgentTranscriptScrollView()
        // Layer-backed so row-removal reflows (re-run rewind, visibility toggles)
        // can crossfade via a CATransition on this layer.
        scrollView.wantsLayer = true
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay
        scrollView.horizontalScrollElasticity = .none
        scrollView.usesPredominantAxisScrolling = true
        // Pin the clip view to x = 0 so the transcript can never be panned
        // horizontally, even if a width desync transiently makes the document
        // view wider than the clip view during a resize or split-divider drag.
        let clipView = TranscriptClipView()
        clipView.drawsBackground = false
        scrollView.contentView = clipView
        scrollView.documentView = tableView
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.postsFrameChangedNotifications = true
        // Keep AppKit insets at zero. The top fade compensation is a real table
        // spacer row, so the first visible row starts in the same precise place
        // on the initial layout, before any scroll event reconciles NSScrollView
        // contentInsets.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        let coordinator = context.coordinator
        let questionRailModel = QuestionRailModel()
        let questionRail = UserQuestionNavigationRailHostView(
            rootView: UserQuestionNavigationRail(model: questionRailModel) { [weak coordinator] id in
                coordinator?.scrollToUserQuestion(id: id)
            }
        )
        questionRail.translatesAutoresizingMaskIntoConstraints = true
        questionRail.autoresizingMask = [.minXMargin, .height]
        questionRail.setFrameSize(.zero)
        // The rail floats over the transcript. Its frame is fixed at the expanded
        // width; transparent regions pass clicks through to the transcript because
        // the SwiftUI content has no hit shape there.
        scrollView.addSubview(questionRail)

        tableView.questionNavigationHandler = context.coordinator
        scrollView.questionNavigationHandler = context.coordinator
        context.coordinator.scrollView = scrollView
        context.coordinator.tableView = tableView
        context.coordinator.questionRail = questionRail
        context.coordinator.questionRailModel = questionRailModel
        context.coordinator.onBenchAdvanceSession = onBenchAdvanceSession
        context.coordinator.benchSessionCount = benchSessionCount
        context.coordinator.onScrollingChange = onScrollingChange
        context.coordinator.setupDataSource(for: tableView)
        context.coordinator.setupScrollObservation(scrollView)
        context.coordinator.updateColumnWidthIfNeeded()
        do {
            // The initial apply can publish rail state through its hosted SwiftUI
            // view, just like updateNSView; defer those model writes until this
            // representable lifecycle pass has completed.
            context.coordinator.isInsideNSViewUpdate = true
            defer { context.coordinator.isInsideNSViewUpdate = false }
            context.coordinator.apply(
                items: items,
                sessionID: sessionID,
                itemsSessionID: itemsSessionID,
                isTranscriptLoading: isTranscriptLoading,
                renderRevision: renderRevision,
                streamingRevision: streamingRevision,
                autoScrollTurnRevision: autoScrollTurnRevision,
                bottomScrollRequest: bottomScrollRequest
            )
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        TranscriptScrollProfiler.measureBody("updateNSView") {
            let coordinator = context.coordinator
            TranscriptScrollProfiler.measurePhase("updateNSView.prep") {
                coordinator.onPinnedToBottomChange = onPinnedToBottomChange
                coordinator.onBenchAdvanceSession = onBenchAdvanceSession
                coordinator.benchSessionCount = benchSessionCount
                coordinator.onScrollingChange = onScrollingChange
                coordinator.updateColumnWidthIfNeeded()
            }
            coordinator.isInsideNSViewUpdate = true
            defer { coordinator.isInsideNSViewUpdate = false }
            coordinator.apply(
                items: items,
                sessionID: sessionID,
                itemsSessionID: itemsSessionID,
                isTranscriptLoading: isTranscriptLoading,
                renderRevision: renderRevision,
                streamingRevision: streamingRevision,
                autoScrollTurnRevision: autoScrollTurnRevision,
                bottomScrollRequest: bottomScrollRequest
            )
        }
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.invalidate()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDelegate, QuestionRailKeyboardNavigationHandling {
        weak var scrollView: NSScrollView?
        weak var tableView: NSTableView?
        weak var questionRail: UserQuestionNavigationRailHostView?
        var questionRailModel: QuestionRailModel?
        var dataSource: NSTableViewDiffableDataSource<PiAgentTranscriptTableSection, String>?

        // Render-product cache: one persistent cell per item id, returned to the
        // diffable data source instead of recycling an arbitrary pooled cell. The
        // expensive part of a vend is building the cell's content (markdown blocks,
        // tool sections); `measuredHeightByID` already caches the *height*, but the
        // built *views* were rebuilt every time a recycled cell took on a new item.
        // Pinning a cell to its item means scrolling back re-hosts the finished cell
        // and `configure(...)` is a no-op (same id/revision/width) — no rebuild — and
        // a cell only ever renders one item, so there is no content bleed. Bounded
        // LRU (offscreen entries evicted; re-vending just rebuilds them) and purged
        // for items dropped from the transcript in `apply(...)`.
        var cellCache: [String: TranscriptTableCellView] = [:]
        var cellCacheLRU: [String] = []        // least-recent first, MRU at end
        // A cache miss is a full native rebuild (view tree + markdown parse +
        // text layout, 5-60ms per row) landing synchronously in a scroll-time
        // vend — the dominant dropped-frame cost when sweeping a long session
        // (sampled: AutoSizingMarkdownTextView.intrinsicContentSize + fullRebuild
        // dominate the hitch stacks). LRU order is vend order, so the cap is the
        // span of rows that scroll up-and-down without thrashing; 160 sat just
        // under a real reading session's working set. Worst case adds memory for
        // ~224 more retained rows, traded deliberately for hitch-free reversal.
        let cellCacheLimit = 384

        let profiler = TranscriptScrollProfiler()

        // MARK: Scroll benchmark (autonomous, multi-session validation)
        // Gated by `defaults write works.earendil.pi-deck ScrollBenchEnabled -bool YES`.
        // When on, it sweeps several content-bearing chats in turn — for each it
        // runs a SHORT scroll burst (local up/down) then a LONG full top↔bottom
        // sweep, then advances to the next session via the same path as the ⌘]
        // shortcut. Each pass is bracketed as a profiler "gesture" tagged with the
        // session + phase, so one run produces a comparable per-session report you
        // can diff across builds to see when the jank fix actually lands. Programmatic
        // scrolls exercise the real cell-vend + sizeThatFits + layout path (synthetic
        // OS scroll events are blocked by TCC).
        var benchTimer: Timer?
        var benchStart: CFTimeInterval = 0
        var benchDir: CGFloat = -1
        let benchStepPoints: CGFloat = 36

        /// Switch selection to the next session (wired by the screen to
        /// `viewModel.selectNextPiAgentSession()` — the ⌘] action). Returns
        /// selection control to SwiftUI, which re-vends the transcript and lands
        /// back in `apply()`, where the bench state machine resumes.
        var onBenchAdvanceSession: (() -> Void)?
        /// Total sessions in the current project's scope — sizes the run.
        var benchSessionCount: (() -> Int)?

        enum BenchPhase { case idle, settling, shortScroll, longScroll, advancing }
        var benchActive = false
        var benchStarted = false
        var benchPhase: BenchPhase = .idle
        var benchTargetSessions = 0
        var benchScopedCount = 0
        var benchSessionsTested = 0
        var benchVisitedSessionIDs: Set<UUID> = []
        /// Every session the sweep has landed on (tested or skipped) — lets the
        /// run stop after one full lap of the list even if some are empty drafts.
        var benchSeenIDs: Set<UUID> = []
        /// Hard stop on advances so a project with fewer content-bearing sessions
        /// than the target can never loop forever wrapping the list.
        var benchAdvanceBudget = 0
        let benchMaxSessions = 6
        let benchShortDuration: CFTimeInterval = UserDefaults.standard.object(forKey: "BenchShortSec") as? Double ?? 2.5
        let benchLongDuration: CFTimeInterval = UserDefaults.standard.object(forKey: "BenchLongSec") as? Double ?? 7
        /// Long full-sweeps run back-to-back per session: repeated traversals are
        /// far more likely to surface a hang/hitch than a single pass (the first
        /// pass warms caches; a stall that survives into passes 2–3 is the real
        /// jank). Each pass is its own profiler gesture, so each gets a summary
        /// and can trip the hitch backtrace independently.
        let benchLongRepeats = UserDefaults.standard.object(forKey: "BenchLongRepeats") as? Int ?? 3

        var sessionID: UUID?
        var lastRenderRevision = -1
        var lastStreamingRevision = -1
        var lastAutoScrollTurnRevision = -1
        var lastBottomScrollRequest = -1
        var onPinnedToBottomChange: (Bool) -> Void

        var items: [PiAgentAppKitTranscriptItem] = []
        var itemByID: [String: PiAgentAppKitTranscriptItem] = [:]
        var orderedIDs: [String] = []
        // Persisted across session switches. Item IDs (thread UUIDs etc.) are
        // globally unique, so a revision recorded for one session never collides
        // with another. Keeping this means a revisited session detects content
        // that changed while it was off-screen and re-measures only those rows.
        var contentRevisionByID: [String: Int] = [:]
        // Heights live in two caches:
        //  1. `measuredHeightByID` — precise heights reported by a live cell once
        //     it has laid out, keyed [block id → width bucket → height]. The
        //     width key means a width change just
        //     selects a different bucket instead of wiping every height — so a
        //     row measured once at a given width keeps its exact height forever,
        //     across width changes and session switches. A single block's entry
        //     is dropped when its content revision changes.
        //  2. `estimateByID` — fast char-count estimates, used only until a row
        //     has a real measurement. Transient: dropped freely.
        // `noteHeightOfRows` runs debounced ~16ms when a measured height differs.
        var measuredHeightByID: [String: [Int: CGFloat]] = [:]
        var estimateByID: [String: CGFloat] = [:]
        // What AppKit currently has each row laid out at — the baseline a fresh
        // measurement is compared against to decide whether a re-tile is needed.
        // Tracked separately from `measuredHeightByID` so a cache change that
        // doesn't actually change the laid-out height can't trigger a spurious
        var lastNotedHeight: [String: CGFloat] = [:]
        var pendingHeightIDs = Set<String>()
        var pendingHeightWork: DispatchWorkItem?
        var pendingScrollWork: DispatchWorkItem?
        var pendingSettleScrollWork: DispatchWorkItem?
        var pendingGlideLandingSettleWork: DispatchWorkItem?
        var pendingSessionSwitchSettleWork: DispatchWorkItem?
        var sessionSwitchSettleGeneration = 0
        var pendingRemeasureWork: DispatchWorkItem?
        var pendingRemeasureIDs = Set<String>()
        var pendingScrollSettle = false
        var pendingWidthWork: DispatchWorkItem?
        /// Cleanup after proactive bubble-width animation (must not share cancel
        /// with `pendingWidthWork` or the flag/settle can be stranded).
        var pendingWidthAnimationCleanup: DispatchWorkItem?
        var widthReconfigureGeneration = 0
        var lastWidthChangeTime: CFTimeInterval = 0
        /// Quiet period before applying a width reconfig. Large jumps (sidebar
        /// open/close) settle briefly then ease bubble widths once — smoother than
        /// per-frame live tracking (which felt choppy).
        let widthChangeSettleWindow: CFTimeInterval = 0.12
        /// Live width tracking while the Review column animates open/close.
        /// 60fps minimum so bubbles stay in lockstep with the panel spring.
        let widthTrackInterval: CFTimeInterval = 1.0 / 60.0
        var lastWidthDelta: CGFloat = 0
        var lastWidthReconfigTime: CFTimeInterval = 0
        var lastWidthTrackApplyTime: CFTimeInterval = 0
        /// True while a splitter drag is active. The transcript column width is
        /// FROZEN at its pre-drag value so content doesn't rewrap mid-drag (which
        /// overlaps rows when narrowed) and doesn't reflow every frame (jitter).
        /// On drag end the flag clears and one clean re-layout happens to settle.
        var isLiveResizing = false
        // (legacy name kept out — large-delta uses trackLive instead of settle)
        // Smooth auto-follow. The streaming follow doesn't snap to the bottom each
        // batch (that reads as a step every ~130ms); instead a 60fps timer eases
        // the clip origin toward the *current* bottom each frame, continuously
        // chasing the growing document so the motion is a glide. It disengages the
        // instant the user scrolls (checked per tick + on live-scroll start + on
        // any user-driven bounds change). Explicit scrolls (send, jump-to-latest,
        // session switch) still snap — see `performScrollToBottom(_:animated:forceLayout:)`.
        var followGlideTimer: Timer?
        // Fraction of the remaining gap consumed per frame. Higher = snappier /
        // smaller trailing gap during fast streaming; lower = softer glide.
        let followGlideFactor: CGFloat = 0.5
        var boundsObserver: NSObjectProtocol?
        var frameObserver: NSObjectProtocol?
        var liveScrollStartObserver: NSObjectProtocol?
        var liveScrollEndObserver: NSObjectProtocol?
        var columnWidthAnimateObserver: NSObjectProtocol?
        var columnResizeActiveObserver: NSObjectProtocol?
        var lastPinnedState = true
        // Auto-follow *intent*, distinct from the position-based `isPinnedToBottom`.
        // True = stick to the bottom as content streams. Only a user scroll changes
        // it (set from the resulting position) or an explicit jump/send/session
        // switch (set true). The follow decisions read this, NOT the live position,
        // so the smooth-glide trailing a little behind the bottom never causes the
        // follow to give up and leave the view parked below the latest content.
        var isAutoFollowing = true {
            didSet {
                guard isAutoFollowing != oldValue else { return }
                // Scrolled away from the bottom → tell the cache to DEFER streaming
                // pulses (the off-screen growing row would otherwise force a full
                // SwiftUI scaffold relayout — up to ~166ms — every token). Returned
                // to the bottom → resume + flush. This is what makes scrolling /
                // reading history during a live stream smooth.
                onScrollingChange?(!isAutoFollowing)
            }
        }
        var isProgrammaticScroll = false
        var forcedActiveQuestionID: String?
        /// True only while SwiftUI's `NSViewRepresentable.makeNSView` or
        /// `updateNSView` lifecycle pass is on the stack. Mutating the rail's
        /// `ObservableObject` during either pass emits "Publishing changes from
        /// within view updates is not allowed", so model writes are deferred to
        /// the next runloop when this is set.
        var isInsideNSViewUpdate = false
        /// Increments for every rail state calculation, so a queued lifecycle
        /// write cannot replace a newer synchronous scroll update.
        var railModelUpdateGeneration = 0
        // True between willStartLiveScroll / didEndLiveScroll — an authoritative
        // "user is driving the scroll" signal, but it only fires for trackpad
        // gestures and scroller-knob drags, not discrete mouse wheels.
        var isLiveScrolling = false
        // CACurrentMediaTime of the most recent *user-driven* clip-bounds change,
        // stamped on every non-programmatic boundsDidChange. Bridges the gap left
        // by devices that post no live-scroll notification (mouse wheels) and
        // covers debounced cell measurements that land just after a gesture ends.
        var lastUserScrollTime: CFTimeInterval = 0
        let userScrollGraceWindow: CFTimeInterval = 0.35
        // True while the user is actively scrolling — or did within the grace
        // window. Passive auto-follow and anchor restoration stay out of the way
        // while this holds, so a streaming update can't yank the viewport out
        // from under a user gesture.
        var isUserScrollingRecently: Bool {
            if isLiveScrolling { return true }
            return CACurrentMediaTime() - lastUserScrollTime < userScrollGraceWindow
        }
        var contentWidth: CGFloat = 0
        // Bucket key for `measuredHeightByID`. Rounding to a whole point keeps
        // sub-pixel width jitter during a scroll from spilling into a new bucket.
        var widthBucket: Int { Int(contentWidth.rounded()) }

        let estimatedRowHeight: CGFloat = 120
        let heightChangeEpsilon: CGFloat = 0.5
        // One-frame debounce so a burst of cell measurements during a single
        // layout pass coalesces into one noteHeightOfRows call.
        let heightReportInterval: TimeInterval = 0.016

        struct ScrollAnchor {
            let id: String
            let rowIndex: Int
            let offsetFromRowTop: CGFloat
        }

        init(onPinnedToBottomChange: @escaping (Bool) -> Void) {
            self.onPinnedToBottomChange = onPinnedToBottomChange
        }

        /// Forwarded to the render cache (via the host) to gate streaming pulses
        /// while the reader is scrolled away from the bottom. Set in `updateNSView`.
        /// Driven entirely by the `isAutoFollowing` didSet, so every transition
        /// (user scroll away, return to bottom, send, session switch) is covered.
        var onScrollingChange: ((Bool) -> Void)?



        var prewarmQueue: [String] = []
        var prewarmScheduled = false
        var prewarmBlockedIDs: Set<String> = []
        let prewarmPerRowCostCapMs: Double = 8.0
        let prewarmSliceBudgetMs: Double = 4.0
        let prewarmWidthChangeCooldown: CFTimeInterval = 0.35
        let prewarmUserScrollGraceWindow: CFTimeInterval = 0.9
        let prewarmExtendedIdleWindow: CFTimeInterval = 2.5
        let prewarmRetryDelay: CFTimeInterval = 0.25
        let prewarmInterSliceDelay: CFTimeInterval = 0.05
        let prewarmMaxEstimatedHeight: CGFloat = 340
        var lastPrewarmBlockingActivityTime: CFTimeInterval = CACurrentMediaTime()
        var streamScrollTestDone = false
        var scrollProbeDone = false
        var buildBenchDone = false

    }


    /// Clip view for the transcript scroll view. The transcript never scrolls
    /// horizontally, so the bounds origin is pinned to x = 0 — this guarantees
    /// the content can't be panned sideways even if the document view is
    /// transiently wider than the clip view during a resize or divider drag.
    final class TranscriptClipView: NSClipView {
        override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
            var rect = super.constrainBoundsRect(proposedBounds)
            rect.origin.x = 0
            return rect
        }
    }

    final class TranscriptTableRowView: NSTableRowView {
        override var isEmphasized: Bool {
            get { false }
            set { }
        }

        override func drawSelection(in dirtyRect: NSRect) { }
        override func drawBackground(in dirtyRect: NSRect) { }
    }

    final class TranscriptTableCellView: NSTableCellView {
        static let reuseIdentifier = NSUserInterfaceItemIdentifier("PiAgentTranscriptTableCell")
        // Native render path (no SwiftUI / NSHostingView). `nativeRow` is the
        // concrete view; `nativeRowTypeID`/`nativeRowSpec` track which kind it is
        // so a recycled cell reuses a same-typed view and reads the row height
        // through the spec's measure closure.
        var nativeRow: NSView?
        private var nativeRowTypeID: ObjectIdentifier?
        private var nativeRowSpec: NativeRowSpec?
        private var nativeTopC: NSLayoutConstraint?
        private var nativeBottomC: NSLayoutConstraint?
        private var configuredTopInset: CGFloat = 0
        private var configuredBottomInset: CGFloat = 0
        var configuredItemID: String?
        private var configuredRevision: Int?
        var configuredWidth: CGFloat = 0
        var lastIntrinsicHeight: CGFloat = -1
        weak var profiler: TranscriptScrollProfiler?

        /// Wired by the coordinator at cell-vend time. Reports this row's true
        /// height — the hosted SwiftUI content's intrinsic size — whenever it
        /// changes. The cell already laid out to display, so reading its size
        /// is essentially free; there is no second offscreen render.
        var onMeasuredHeight: ((String, CGFloat) -> Void)?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.backgroundColor = NSColor.clear.cgColor
        }

        required init?(coder: NSCoder) { fatalError() }

        /// Configure the cell for an item. Every row is native; the spec's view is
        /// built/reused and pinned to the cell with the row insets.
        func installRootView(
            item: PiAgentAppKitTranscriptItem,
            width: CGFloat,
            profiler: TranscriptScrollProfiler? = nil,
            via: String = "scroll-vend",
            deferWidthOnlySettle: Bool = false
        ) {
            self.profiler = profiler
            guard case .native(let spec) = item.kind else { return }
            installNativeRow(spec: spec, item: item, width: width, via: via, deferWidthOnlySettle: deferWidthOnlySettle)
        }

        /// Tear down the native row view (when a recycled cell switches to a
        /// different native view type).
        private func teardownNativeRow() {
            guard let row = nativeRow else { return }
            nativeRowSpec?.reset(row)
            row.removeFromSuperview()
            nativeRow = nil
            nativeRowTypeID = nil
            nativeRowSpec = nil
            nativeTopC = nil
            nativeBottomC = nil
            lastIntrinsicHeight = -1
        }

        /// Native render path: build/configure the spec's view pinned to the cell
        /// with the row insets, rebuilding if the recycled cell held a different
        /// view type.
        private func installNativeRow(
            spec: NativeRowSpec,
            item: PiAgentAppKitTranscriptItem,
            width: CGFloat,
            via: String = "scroll-vend",
            deferWidthOnlySettle: Bool = false
        ) {
            // A recycled cell holding a different native view type must rebuild it.
            if let existingType = nativeRowTypeID, existingType != spec.typeID {
                teardownNativeRow()
            }
            let row: NSView
            let createdNow: Bool
#if DEBUG
            var makeMs = 0.0
#endif
            if let existing = nativeRow {
                row = existing
                createdNow = false
            } else {
                createdNow = true
#if DEBUG
                let t0 = CACurrentMediaTime()
                row = spec.make()
                makeMs = (CACurrentMediaTime() - t0) * 1000
#else
                row = spec.make()
#endif
                row.translatesAutoresizingMaskIntoConstraints = false
                addSubview(row)
                // Full-width row; the view sizes/positions its own content.
                let top = row.topAnchor.constraint(equalTo: topAnchor, constant: item.topInset)
                let bottom = row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -item.bottomInset)
                // During a diffable `apply`, AppKit briefly sets each row to its
                // default 17pt height (its `NSView-Encapsulated-Layout-Height`)
                // before it consults `heightOfRow`. A row whose content has firm
                // internal pins — e.g. a tool-group card pinned top+bottom — can't
                // fit 17pt, so a REQUIRED bottom pin makes AppKit break-and-log a
                // constraint every apply. Drop the bottom pin just below required so
                // it silently yields during that transient and is satisfied exactly
                // once the real row height lands (measurement is unaffected — height
                // comes from `spec.measure`, not these pins).
                bottom.priority = .required - 1
                NSLayoutConstraint.activate([
                    row.leadingAnchor.constraint(equalTo: leadingAnchor),
                    row.trailingAnchor.constraint(equalTo: trailingAnchor),
                    top, bottom
                ])
                nativeTopC = top
                nativeBottomC = bottom
                nativeRow = row
                nativeRowTypeID = spec.typeID
                lastIntrinsicHeight = -1
            }
            nativeRowSpec = spec
            // Let an interactive native row (e.g. expanding a list) ask the cell to
            // re-measure and the table to re-tile when its content height changes.
            spec.setHeightCallback(row) { [weak self] in
                guard let self, let itemID = self.configuredItemID, self.configuredWidth > 1 else { return }
                let h = self.forcedIntrinsicHeight()
                if h > 0 { self.onMeasuredHeight?(itemID, h) }
            }
            let insetChanged = configuredTopInset != item.topInset || configuredBottomInset != item.bottomInset
            if insetChanged {
                nativeTopC?.constant = item.topInset
                nativeBottomC?.constant = -item.bottomInset
            }

            let itemChanged = configuredItemID != item.id
            let revisionChanged = itemChanged || configuredRevision != item.contentRevision
            let widthChanged = abs(configuredWidth - width) > 0.5
            if revisionChanged || widthChanged {
#if DEBUG
                // DEBUG-only attribution of the build cost — fresh-view construction
                // + the markdown configure (reconcile vs full rebuild). This is the
                // scroll/stream hitch the other profiler hooks never wrapped (it runs
                // inside the table's cell-provider closure). Compiled out of release.
                if let profiler {
                    profiler.measureCellBuild(id: item.id, fresh: createdNow, makeMs: makeMs, via: via) {
                        let seqBefore = NativeMarkdownTextContainer.configureSeq
                        spec.configure(row, width)
                        // Only trust the markdown attribution if a build actually
                        // ran this vend (seq advanced) — a non-markdown row leaves
                        // the statics stale, so report nil instead of mislabeling.
                        guard NativeMarkdownTextContainer.configureSeq != seqBefore else { return nil }
                        return (NativeMarkdownTextContainer.lastConfigureWasRebuild,
                                NativeMarkdownTextContainer.lastConfigureBlockCount)
                    }
                } else {
                    spec.configure(row, width)
                }
#else
                spec.configure(row, width)
#endif
                lastIntrinsicHeight = -1
            }
            // `settle` is the immediate layout pass that stops a recycled,
            // layer-backed row from painting its prior geometry. A freshly-created
            // non-markdown row has no presentation state to correct, and AppKit's
            // normal cell layout immediately follows installation; forcing a second
            // subtree layout here was redundant in the sampled fresh card vends.
            // Keep the initial settle for markdown-bearing bubbles/questions, whose
            // first paint includes a richer nested content tree. Spacers have no
            // visible geometry to correct.
            // Skip for offscreen prewarm: the row is not on screen so there is no
            // stale paint to correct, and the layout cost (up to 60ms for heavy rows)
            // is wasted work that stalls the main thread during idle pre-warm slices.
            // The cell will lay out naturally when it scrolls into view.
            let hasVisibleNativeGeometry = spec.typeID != ObjectIdentifier(PiAgentNativeSpacerView.self)
            let isMarkdownBearingRow = spec.typeID == ObjectIdentifier(PiAgentNativeBubbleView.self)
                || spec.typeID == ObjectIdentifier(PiAgentNativeQuestionView.self)
            let needsInitialSettle = hasVisibleNativeGeometry && ((!createdNow && itemChanged) || (createdNow && isMarkdownBearingRow))
            let isWidthOnlySettle = !createdNow && !needsInitialSettle && widthChanged && !insetChanged
            if via != "prewarm", needsInitialSettle || (!createdNow && (widthChanged || insetChanged)) {
                if deferWidthOnlySettle && isWidthOnlySettle {
#if DEBUG
                    if TranscriptScrollProfiler.verboseTrace {
                        TranscriptScrollProfiler.fileLog("WIDTH settle skipped row=\(row) via=\(via)")
                    }
#endif
                } else {
                    spec.settle(row)
                }
            }
            configuredItemID = item.id
            configuredRevision = item.contentRevision
            configuredWidth = width
            configuredTopInset = item.topInset
            configuredBottomInset = item.bottomInset
        }

        private var pendingLayoutHeightReport = false

        /// AppKit's per-pass layout hook, and where the row reports height drift.
        override func layout() {
            if let profiler {
                profiler.measureCellLayout { super.layout() }
            } else {
                super.layout()
            }
            guard nativeRow != nil, nativeRowSpec != nil, configuredItemID != nil, configuredWidth > 1 else { return }
            // Reporting height means MEASURING the row, which forces its subtree to
            // lay out. AppKit recurses into that subtree only AFTER this `layout()`
            // returns, so forcing it here is illegal re-entrancy — it logs
            // `_NSDetectedLayoutRecursion` (captured: cell.layout → spec.measure →
            // NativeMarkdownTextContainer.measureHeight → stackView.layoutSubtreeIfNeeded
            // inside `_layoutSubtreeWithOldSize`). Hop out of the pass and measure
            // once it has completed; coalesced so streaming's many passes don't
            // stack up. Until it lands, `heightOfRow` keeps the row's estimate, and
            // freshly-streamed rows already report synchronously via
            // `forcedIntrinsicHeight()` — this path only catches later drift.
            scheduleLayoutHeightReport()
        }

        private func scheduleLayoutHeightReport() {
            guard !pendingLayoutHeightReport else { return }
            pendingLayoutHeightReport = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pendingLayoutHeightReport = false
                guard let row = self.nativeRow, let spec = self.nativeRowSpec,
                      let itemID = self.configuredItemID, self.configuredWidth > 1 else { return }
                let h = self.configuredTopInset + spec.measure(row, self.configuredWidth) + self.configuredBottomInset
                guard h > 0, h.isFinite, abs(h - self.lastIntrinsicHeight) > 0.5 else { return }
                self.lastIntrinsicHeight = h
                self.onMeasuredHeight?(itemID, h)
            }
        }

        /// Force the native row to lay out *now* and return its height, instead of
        /// waiting for AppKit's async `layout()` pass to report it. Used right after
        /// installing new streaming content so the coordinator can re-tile the row
        /// in the same pass. Records `lastIntrinsicHeight` so the subsequent async
        /// `layout()` sees no change and doesn't redundantly re-report.
        func forcedIntrinsicHeight() -> CGFloat {
            guard let row = nativeRow, let spec = nativeRowSpec, configuredWidth > 1 else { return -1 }
            row.layoutSubtreeIfNeeded()
            let h = configuredTopInset + spec.measure(row, configuredWidth) + configuredBottomInset
            guard h > 0, h.isFinite else { return -1 }
            lastIntrinsicHeight = h
            return h
        }
    }
}

extension PiAgentTranscriptThread {
    var timelineTimestamp: Date {
        let activityEntries = activities.compactMap(\.representativeEntry)
        let candidates = [question].compactMap { $0 }
            + steeringMessages
            + thinkingParts
            + assistantMessages
            + activityEntries
            + statuses
            + errors
        return candidates.map(\.timestamp).min() ?? .distantPast
    }
}
