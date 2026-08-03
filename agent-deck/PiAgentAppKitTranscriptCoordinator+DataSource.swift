import AppKit
import Combine
import Darwin
import os
import QuartzCore
import SwiftUI

// MARK: - Data source, cell cache, prewarm, question rail

extension PiAgentAppKitTranscriptView.Coordinator {
    func setupDataSource(for tableView: NSTableView) {
        dataSource = makeDataSource(for: tableView)
        tableView.delegate = self
    }

    /// AppKit's table diffable data source has no
    /// `applySnapshotUsingReloadData` counterpart. Replacing the source gives
    /// a session switch a clean snapshot baseline, avoiding reconciliation of
    /// the previous session's unrelated identifiers.
    func makeDataSource(for tableView: NSTableView) -> NSTableViewDiffableDataSource<PiAgentTranscriptTableSection, String> {
        NSTableViewDiffableDataSource<PiAgentTranscriptTableSection, String>(tableView: tableView) { [weak self] _, _, row, id in
            guard let self, let item = self.itemByID[id] else { return NSView() }
            let cell = self.cachedCell(for: id)
            self.configure(cell, with: item, row: row)
            return cell
        }
    }

    /// The persistent cell for `id` — reused across vends so its built content
    /// survives scrolling off and back. Created on first use, then cached.
    func cachedCell(for id: String) -> PiAgentAppKitTranscriptView.TranscriptTableCellView {
        if let cached = cellCache[id] {
            touchCell(id)
            return cached
        }
        let cell = PiAgentAppKitTranscriptView.TranscriptTableCellView(frame: .zero)
        cell.identifier = PiAgentAppKitTranscriptView.TranscriptTableCellView.reuseIdentifier
        // The live cell reports its own height once it has laid out — the
        // coordinator caches it and re-tiles the row. No offscreen render: the
        // cell had to lay out for display anyway.
        cell.onMeasuredHeight = { [weak self] itemID, height in
            self?.reportMeasuredHeight(height, forItemID: itemID)
        }
        cellCache[id] = cell
        cellCacheLRU.append(id)
        evictCellsIfNeeded()
        return cell
    }

    func touchCell(_ id: String) {
        if let idx = cellCacheLRU.firstIndex(of: id) { cellCacheLRU.remove(at: idx) }
        cellCacheLRU.append(id)
    }

    // MARK: - Idle pre-warm
    //
    // Building a transcript cell (markdown block stack, or a tool-group /
    // subagent card) costs 10-46ms for a heavy row, and a long session has
    // dozens. Doing it lazily on the scroll path is the dominant scroll hitch
    // (a 130-row session = ~458ms of construction). Instead, after a session
    // settles, build the off-screen cells during idle in small time-budgeted
    // slices, so by the time the user scrolls the cells are already cached and
    // the vend is a no-op configure. Yields to the user: paused while a scroll
    // gesture or streaming is in flight, resumed when idle.
    /// IDs blocked from prewarm because a single build exceeded the per-row
    /// cost cap — a heavy row that eats the whole slice budget would otherwise
    /// be retried every idle tick and starve the rows behind it. Cleared on
    /// session switch and width change (geometry/content invalidate the
    /// block — the row may be cheaper to build at the new width or not exist).
    /// Hard per-row cost cap: if a single prewarm build exceeds roughly one
    /// 120Hz frame, the row is blocked from future prewarm attempts so the
    /// budget goes to cheaper rows instead.
    /// Speculative offscreen prewarm is enabled by default for cheap/medium rows:
    /// current hitch samples convict fresh visible cell vend (`FRESH-VIEW` builds)
    /// during scroll, while heavy rows and offscreen height measurement remain
    /// blocked below to avoid the old prewarm TextKit hang signature. Keep a
    /// defaults kill switch for A/B without changing visible-row rendering.
    /// Disable with: `defaults write works.earendil.pi-deck TranscriptPrewarmDisabled -bool YES`.
    static let prewarmDisabled: Bool = {
        guard let value = UserDefaults.standard.object(forKey: "TranscriptPrewarmDisabled") as? Bool else { return false }
        return value
    }()
    /// Per-runloop-slice main-thread budget. Kept under half a 120Hz frame so a
    /// slice never itself drops a frame; construction is spread across ticks.
    /// Kill switch for the old offscreen height-measurement path. Keeping this
    /// off by default avoids surprise main-thread TextKit/layout stalls while
    /// preserving visible-row rendering and measurement behavior.
    static let prewarmMeasuresHeights: Bool = {
        UserDefaults.standard.bool(forKey: "TranscriptPrewarmMeasureHeightsEnabled")
    }()
    /// Prewarm is speculative, so it stays farther behind user/display work than
    /// normal scroll handling. The regular user-scroll grace protects visible
    /// behaviors; this longer prewarm-only grace keeps idle cell construction out
    /// of the post-gesture layout/display tail that still showed up in hitch
    /// samples as `prewarmStep → configure → installNativeRow`.

    func extendedPrewarmIdleReady(now: CFTimeInterval) -> Bool {
        let lastBlockingActivity = max(lastPrewarmBlockingActivityTime, max(lastUserScrollTime, lastWidthChangeTime))
        return now - lastBlockingActivity >= prewarmExtendedIdleWindow
    }

    func isPrewarmEligible(_ item: PiAgentAppKitTranscriptItem, extendedIdleReady: Bool) -> Bool {
        guard case .native(let spec) = item.kind else { return false }
        switch spec.prewarmPolicy {
        case .immediate:
            break
        case .extendedIdle:
            guard extendedIdleReady else { return false }
        case .disabled:
            return false
        }
        return item.estimatedHeight(contentWidth) <= prewarmMaxEstimatedHeight
    }

    func schedulePrewarm() {
        guard !Self.prewarmDisabled, let tableView else { return }
        let now = CACurrentMediaTime()
        let widthSettlesIn = prewarmWidthChangeCooldown - (now - lastWidthChangeTime)
        if widthSettlesIn > 0 {
            guard !prewarmScheduled else { return }
            prewarmScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + widthSettlesIn) { [weak self] in
                guard let self else { return }
                self.prewarmScheduled = false
                self.schedulePrewarm()
            }
            return
        }
        // While scrolling, keep speculative pre-warm completely off the path:
        // an already-active profiler window covers both real gestures and the
        // autonomous programmatic scroll bench, and any fresh cell build inside
        // it shows up as scroll-vend/prewarm hitch stack contention. While
        // streaming AND still pinned to the bottom, skip too: new rows arrive
        // every pulse and the visible streaming row owns the main thread, so a
        // heavy pre-warm build would hitch what the reader is watching. But once
        // the reader has scrolled UP to read history (auto-follow off), the
        // stream is off-screen — pre-warm the history they're scrolling toward so
        // those rows are already built (no construction stutter) once idle.
        if profiler.isScrollWindowActive || (profiler.isStreamingRecently && isAutoFollowing) {
            lastPrewarmBlockingActivityTime = now
            guard !prewarmScheduled else { return }
            prewarmScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self else { return }
                self.prewarmScheduled = false
                self.schedulePrewarm()
            }
            return
        }
        // Build the work list: every row without a live cached cell, in document
        // order, capped to the cache limit (pre-warming past it would just evict
        // what we built). Streaming/following and active-scroll periods defer
        // above so the visible path takes priority.
        let extendedIdleReady = extendedPrewarmIdleReady(now: now)
        let pending = orderedIDs.filter { id in
            guard cellCache[id] == nil, !prewarmBlockedIDs.contains(id) else { return false }
            guard let item = itemByID[id] else { return false }
            return isPrewarmEligible(item, extendedIdleReady: extendedIdleReady)
        }
        guard !pending.isEmpty, cellCache.count < cellCacheLimit else {
            let hasDeferredCandidate = !extendedIdleReady && cellCache.count < cellCacheLimit && orderedIDs.contains { id in
                guard cellCache[id] == nil, !prewarmBlockedIDs.contains(id), let item = itemByID[id] else { return false }
                return isPrewarmEligible(item, extendedIdleReady: true)
            }
            guard hasDeferredCandidate, !prewarmScheduled else { return }
            prewarmScheduled = true
            let delay = max(prewarmRetryDelay, prewarmExtendedIdleWindow - (now - max(lastPrewarmBlockingActivityTime, max(lastUserScrollTime, lastWidthChangeTime))))
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.prewarmScheduled = false
                self.schedulePrewarm()
            }
            return
        }
        // Build outward from the viewport: the user scrolls away from where they
        // are (the view opens pinned to the bottom), so rows nearest the visible
        // range should be ready first. Order pending ids by row distance from the
        // current visible window's centre.
        let visible = tableView.rows(in: tableView.visibleRect)
        let anchorRow = visible.length > 0 ? visible.location + visible.length / 2 : orderedIDs.count - 1
        let indexByID = Dictionary(uniqueKeysWithValues: orderedIDs.enumerated().map { ($1, $0) })
        let ordered = pending.sorted { (indexByID[$0] ?? 0) - anchorRow == 0 ? false :
            abs((indexByID[$0] ?? 0) - anchorRow) < abs((indexByID[$1] ?? 0) - anchorRow) }
        prewarmQueue = Array(ordered.prefix(cellCacheLimit - cellCache.count))
        guard !prewarmScheduled else { return }
        prewarmScheduled = true
        DispatchQueue.main.async { [weak self] in self?.prewarmStep() }
    }

    func prewarmStep() {
        prewarmScheduled = false
        guard !Self.prewarmDisabled, tableView != nil else { prewarmQueue.removeAll(); return }
        // Don't compete with an active scroll gesture, live streaming, or a
        // settling width change — retry shortly. (Streaming re-tiles + the
        // follow glide own the main thread; width changes reconfigure visible
        // cells and can otherwise cascade into speculative offscreen work.)
        let now = CACurrentMediaTime()
        let widthSettlesIn = prewarmWidthChangeCooldown - (now - lastWidthChangeTime)
        let prewarmScrollGraceActive = isLiveScrolling || now - lastUserScrollTime < prewarmUserScrollGraceWindow
        let displayOrLayoutWorkPending = pendingHeightWork != nil
            || pendingScrollWork != nil
            || pendingSettleScrollWork != nil
            || pendingGlideLandingSettleWork != nil
            || pendingRemeasureWork != nil
        if prewarmScrollGraceActive || profiler.isScrollWindowActive || profiler.isStreamingRecently || widthSettlesIn > 0 || displayOrLayoutWorkPending {
            lastPrewarmBlockingActivityTime = now
            prewarmScheduled = true
            let delay = max(prewarmRetryDelay, widthSettlesIn)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.prewarmStep() }
            return
        }
        let extendedIdleReady = extendedPrewarmIdleReady(now: now)
        if !extendedIdleReady {
            let hasOnlyDeferredRows = prewarmQueue.contains { id in
                guard let item = itemByID[id] else { return false }
                return isPrewarmEligible(item, extendedIdleReady: true)
                    && !isPrewarmEligible(item, extendedIdleReady: false)
            }
            if hasOnlyDeferredRows {
                prewarmScheduled = true
                let delay = max(prewarmRetryDelay, prewarmExtendedIdleWindow - (now - max(lastPrewarmBlockingActivityTime, max(lastUserScrollTime, lastWidthChangeTime))))
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.prewarmStep() }
                return
            }
        }
        prewarmQueue.removeAll { id in
            guard let item = itemByID[id] else { return true }
            return !isPrewarmEligible(item, extendedIdleReady: extendedIdleReady)
        }
        let start = CACurrentMediaTime()
#if DEBUG
        var builtThisSlice = 0
#endif
        while !prewarmQueue.isEmpty {
            let id = prewarmQueue.removeFirst()
            // Skip rows that scrolled into view (already built), vanished, or
            // are not on the cheap prewarm allow-list. Native tool-group/diff
            // rows can build deep AppKit trees in one configure call, before
            // the slice budget can yield; leave them to the visible path.
            guard cellCache[id] == nil, !prewarmBlockedIDs.contains(id),
                  let item = itemByID[id], isPrewarmEligible(item, extendedIdleReady: extendedIdleReady),
                  let row = orderedIDs.firstIndex(of: id) else { continue }
            let cell = cachedCell(for: id)
            let rowStart = CACurrentMediaTime()
            configure(cell, with: item, row: row, via: "prewarm")
            // Hard per-row cap: if this single build exceeded the cost
            // threshold, block it from future prewarm so a pathological row
            // can't starve the budget every idle tick. The row will still
            // build on the scroll path when actually needed.
            let rowCostMs = (CACurrentMediaTime() - rowStart) * 1000
            if rowCostMs >= prewarmPerRowCostCapMs {
                prewarmBlockedIDs.insert(id)
#if DEBUG
                TranscriptScrollProfiler.fileLog("PREWARM blocked id=\(id.suffix(6)) cost=\(String(format: "%.1f", rowCostMs))ms")
#endif
            }
            // Do not force an offscreen layout by default. The old path called
            // `forcedIntrinsicHeight()` here, which is good for future scroll
            // stability but can spend hundreds of milliseconds in TextKit/AppKit
            // on the main thread after a sidebar/window width change. Visible
            // rows still measure themselves through the normal on-layout path.
            if Self.prewarmMeasuresHeights {
                let h = cell.forcedIntrinsicHeight()
                if h > 0 {
                    let height = ceil(h)
                    measuredHeightByID[id, default: [:]][widthBucket] = height
                    lastNotedHeight[id] = height
                }
            }
#if DEBUG
            builtThisSlice += 1
#endif
            if (CACurrentMediaTime() - start) * 1000 >= prewarmSliceBudgetMs { break }
        }
        if prewarmQueue.isEmpty {
#if DEBUG
            if builtThisSlice > 0 {
                TranscriptScrollProfiler.fileLog("PREWARM done cached=\(cellCache.count)/\(orderedIDs.count)")
            }
#endif
        } else {
            prewarmScheduled = true
            // Yield beyond one runloop turn between slices. A zero-delay async
            // chain can still monopolize the main actor during AppKit's post-
            // scroll display/layout tail; a short idle gap keeps speculative
            // construction from piling onto the same frame.
            DispatchQueue.main.asyncAfter(deadline: .now() + prewarmInterSliceDelay) { [weak self] in self?.prewarmStep() }
        }
    }

    /// Drop least-recently-vended cached cells over the cap. Never evicts a row
    /// that's currently on screen (its cell is live), so eviction only releases
    /// offscreen views — which simply rebuild when scrolled back to.
    func evictCellsIfNeeded() {
        guard cellCacheLRU.count > cellCacheLimit else { return }
        let visible = visibleIDs()
        var i = 0
        while cellCacheLRU.count > cellCacheLimit, i < cellCacheLRU.count {
            let id = cellCacheLRU[i]
            if visible.contains(id) { i += 1; continue }
            cellCacheLRU.remove(at: i)
            cellCache.removeValue(forKey: id)
        }
    }

    /// Forget cached cells for items no longer in the transcript. Called from
    /// `apply(...)` so a removed/replaced message doesn't pin its view forever.
    func purgeCellCache(keeping ids: Set<String>) {
        guard !cellCache.isEmpty else { return }
        for id in cellCache.keys where !ids.contains(id) {
            cellCache.removeValue(forKey: id)
        }
        cellCacheLRU.removeAll { !ids.contains($0) }
    }

    func visibleIDs() -> Set<String> {
        guard let tableView else { return [] }
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.length > 0 else { return [] }
        var result = Set<String>()
        for row in visible.location ..< visible.location + visible.length where row < orderedIDs.count {
            result.insert(orderedIDs[row])
        }
        return result
    }

    func updateQuestionRail() {
        guard let scrollView, let tableView, questionRailModel != nil else { return }
        let questionRows = currentQuestionRows()
        let stackedHeight = evenStackedHeight(questionCount: questionRows.count)
        let railHeight = questionRailHeight(scrollView: scrollView, questionCount: questionRows.count)
        updateQuestionRailFrame(for: scrollView, railHeight: railHeight)

        let shouldShowRail = QuestionRailVisibilityPolicy().shouldShow(
            questionCount: questionRows.count,
            evenStackedHeight: stackedHeight,
            railHeight: railHeight
        )
        guard shouldShowRail else {
            forcedActiveQuestionID = nil
            questionRail?.isHidden = true
            applyRailModel(items: [], width: scrollView.bounds.width, railHeight: railHeight, isSliding: false)
            return
        }

        questionRail?.isHidden = false
        let rowIDs = Set(questionRows.map { $0.id })
        if let forcedActiveQuestionID, !rowIDs.contains(forcedActiveQuestionID) {
            self.forcedActiveQuestionID = nil
        }
        let activeID = self.forcedActiveQuestionID ?? activeQuestionID(in: questionRows, scrollView: scrollView, tableView: tableView)

        let isOverflowing = stackedHeight > railHeight
        let items = questionRows.map { _, id, title in
            UserQuestionNavigationRailItem(id: id, title: title, isActive: id == activeID)
        }
        applyRailModel(items: items, width: scrollView.bounds.width, railHeight: railHeight, isSliding: isOverflowing)
    }

    func evenStackedHeight(questionCount: Int) -> CGFloat {
        let rowHeight = TranscriptFloatingControlGeometry.questionRailRowHeight
        let rowSpacing = TranscriptFloatingControlGeometry.questionRailRowSpacing
        let verticalPadding = TranscriptFloatingControlGeometry.questionRailVerticalPadding
        return CGFloat(questionCount) * rowHeight + CGFloat(max(0, questionCount - 1)) * rowSpacing + verticalPadding
    }

    func questionRailHeight(scrollView: NSScrollView, questionCount: Int) -> CGFloat {
        let desired = evenStackedHeight(questionCount: questionCount)
        return min(max(54, scrollView.bounds.height - 32), max(44, desired))
    }

    /// Push rail data to the hosted view. `updateQuestionRail()` runs both on
    /// scroll (synchronous is fine) and inside `makeNSView`/`updateNSView` ->
    /// `apply` (NOT fine: SwiftUI holds its view-update lock there, and mutating
    /// the `ObservableObject` synchronously emits "Publishing changes from within
    /// view updates"). Defer to the next runloop when inside either pass.
    func applyRailModel(items: [UserQuestionNavigationRailItem], width: CGFloat, railHeight: CGFloat, isSliding: Bool) {
        railModelUpdateGeneration &+= 1
        let generation = railModelUpdateGeneration
        if isInsideNSViewUpdate {
            Task { @MainActor [weak self, items] in
                guard let self,
                      self.railModelUpdateGeneration == generation,
                      let model = self.questionRailModel else { return }
                self.assignRailModel(model, items: items, width: width, railHeight: railHeight, isSliding: isSliding)
            }
        } else if let model = questionRailModel {
            assignRailModel(model, items: items, width: width, railHeight: railHeight, isSliding: isSliding)
        }
    }

    func assignRailModel(
        _ model: QuestionRailModel,
        items: [UserQuestionNavigationRailItem],
        width: CGFloat,
        railHeight: CGFloat,
        isSliding: Bool
    ) {
        if model.items != items { model.items = items }
        if model.availableWidth != width { model.availableWidth = width }
        if model.railHeight != railHeight { model.railHeight = railHeight }
        if model.isSliding != isSliding { model.isSliding = isSliding }
    }

    func updateQuestionRailFrame(for scrollView: NSScrollView, railHeight: CGFloat) {
        guard let rail = questionRail else { return }
        // Host frame is FIXED at the expanded width (trailing-aligned to the
        // scroll-to-bottom FAB). It must NOT resize on hover — resizing the
        // host while the pointer is over it is what caused the hover loop.
        let railWidth = UserQuestionNavigationRail.expandedWidth(for: scrollView.bounds.width)
        let trailingInset = TranscriptFloatingControlGeometry.questionRailTrailingInsetInsideScrollView
        let newFrame = NSRect(
            x: scrollView.bounds.width - railWidth - trailingInset,
            y: (scrollView.bounds.height - railHeight) / 2,
            width: railWidth,
            height: railHeight
        )
        // Skip the assign when unchanged: re-setting the frame every scroll
        // tick would force an NSHostingView re-layout and can stutter hover.
        if rail.frame != newFrame { rail.frame = newFrame }
    }

    func questionRailLandingOffset(for visibleHeight: CGFloat) -> CGFloat {
        TranscriptFloatingControlGeometry.questionScrollTopPadding
    }

    func activeQuestionID(
        in questionRows: [(row: Int, id: String, title: String)],
        scrollView: NSScrollView,
        tableView: NSTableView
    ) -> String? {
        guard !questionRows.isEmpty else { return nil }
        let clipBounds = scrollView.contentView.bounds
        let documentHeight = max(scrollView.documentView?.frame.height ?? tableView.bounds.height, clipBounds.height)
        let maxY = max(0, documentHeight - clipBounds.height)
        if maxY - clipBounds.origin.y < 2 {
            return questionRows.last?.id
        }

        let resolver = QuestionRailActiveQuestionResolver(
            landingOffset: questionRailLandingOffset(for: clipBounds.height),
            visibleHeight: clipBounds.height
        )
        let questions = questionRows.map { row, id, _ in
            (id: id, minY: tableView.rect(ofRow: row).minY)
        }
        return resolver.activeID(
            questions: questions,
            viewportY: clipBounds.origin.y,
            documentHeight: documentHeight
        )
    }

    func currentQuestionRows() -> [(row: Int, id: String, title: String)] {
        guard let tableView, let dataSource else { return [] }
        return (0 ..< tableView.numberOfRows).compactMap { row in
            guard let id = dataSource.itemIdentifier(forRow: row),
                  let title = itemByID[id]?.questionNavigationTitle else { return nil }
            return (row, id, title)
        }
    }

    func tableRow(forItemID id: String) -> Int? {
        guard let tableView, let dataSource else { return nil }
        return (0 ..< tableView.numberOfRows).first { row in
            dataSource.itemIdentifier(forRow: row) == id
        }
    }

    func handleQuestionRailKeyboardShortcut(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.shift, .command, .option, .control])
        guard modifiers == .shift else { return false }

        let direction: QuestionRailKeyboardDirection
        switch event.keyCode {
        case 126: direction = .previous // Shift-Up
        case 125: direction = .next     // Shift-Down
        default: return false
        }

        guard let scrollView, let tableView else { return true }
        let questionRows = currentQuestionRows()
        guard questionRows.count >= 2 else { return true }
        let activeID = forcedActiveQuestionID ?? activeQuestionID(in: questionRows, scrollView: scrollView, tableView: tableView)
        let questionIDs = questionRows.map(\.id)
        if let targetID = QuestionRailKeyboardNavigator().targetID(questionIDs: questionIDs, activeID: activeID, direction: direction) {
            scrollToUserQuestion(id: targetID)
        }
        return true
    }

    func scrollToUserQuestion(id: String) {
        guard let scrollView, let tableView, let row = tableRow(forItemID: id), row >= 0, row < tableView.numberOfRows else { return }
        stopFollowGlide()
        isAutoFollowing = false
        publishPinnedState(false)
        forcedActiveQuestionID = id
        updateQuestionRail()
        isProgrammaticScroll = true
        let clipView = scrollView.contentView
        let landingOffset = questionRailLandingOffset(for: clipView.bounds.height)
        let resolver = QuestionRailScrollLandingResolver(landingOffset: landingOffset, visibleHeight: clipView.bounds.height)
        let targetY = resolver.targetY(
            rowMinY: tableView.rect(ofRow: row).minY,
            documentHeight: max(scrollView.documentView?.frame.height ?? tableView.bounds.height, clipView.bounds.height)
        )

        // NSTableView measures row heights lazily as rows scroll into view, so
        // `rect(ofRow:)` for a far-offscreen target is computed from ESTIMATED
        // heights. A single correction was not enough when each landing revealed
        // more real row heights; users had to click the same rail item again.
        // Keep correcting until the measured row position stabilizes.
        animateQuestionRailLanding(to: targetY, row: row, resolver: resolver, correction: 0, duration: 0.32)
    }

    func animateQuestionRailLanding(
        to targetY: CGFloat,
        row: Int,
        resolver: QuestionRailScrollLandingResolver,
        correction: Int,
        duration: TimeInterval
    ) {
        guard let scrollView, let tableView else {
            isProgrammaticScroll = false
            updateQuestionRail()
            return
        }
        let clipView = scrollView.contentView
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.allowsImplicitAnimation = true
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.20, 0.0, 0.0, 1.0)
            clipView.animator().setBoundsOrigin(NSPoint(x: clipView.bounds.origin.x, y: targetY))
        } completionHandler: { [weak self, weak scrollView, weak clipView, weak tableView] in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let tableView, let clipView, let scrollView else {
                    self.isProgrammaticScroll = false
                    self.updateQuestionRail()
                    return
                }
                scrollView.reflectScrolledClipView(clipView)
                let documentHeight = max(scrollView.documentView?.frame.height ?? tableView.bounds.height, clipView.bounds.height)
                if correction < resolver.maxCorrections,
                   let correctedY = resolver.needsCorrection(
                       currentY: clipView.bounds.origin.y,
                       rowMinY: tableView.rect(ofRow: row).minY,
                       documentHeight: documentHeight
                   ) {
                    self.animateQuestionRailLanding(to: correctedY, row: row, resolver: resolver, correction: correction + 1, duration: 0.10)
                    return
                }
                self.isProgrammaticScroll = false
                self.updateQuestionRail()
            }
        }
    }
}
