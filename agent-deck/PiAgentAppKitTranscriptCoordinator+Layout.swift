import AppKit
import Combine
import Darwin
import os
import QuartzCore
import SwiftUI

// MARK: - Column width, height measure, scroll anchors

extension PiAgentAppKitTranscriptView.Coordinator {
    func updateColumnWidthIfNeeded() {
        guard let tableView else { return }
        let width = currentViewportWidth()
        let delta = abs(width - contentWidth)
        guard delta > 0.5 else { return }

        // While a splitter drag (or panel-open/close animation freeze)
        // is active, keep the table column width in lock-step with the
        // viewport so the unpack on thaw is ~0 — eliminating the second
        // visible reflow flash. We only update the column + card widths,
        // not the height bucketing; that resolves naturally on settle.
        if isLiveResizing {
            contentWidth = width
            lastWidthChangeTime = CACurrentMediaTime()
            lastWidthDelta = delta
            tableView.tableColumns.first?.width = width
            tableView.sizeLastColumnToFit()
            applyWidthOnlyToVisibleCells(width: width, animated: false, duration: 0)
            return
        }

        lastWidthDelta = delta
        contentWidth = width
        lastWidthChangeTime = CACurrentMediaTime()
        prewarmQueue.removeAll()
        // Width changes can alter which rows are expensive to build (text
        // reflow changes block count), so clear the block list and let
        // rows be re-evaluated at the new width.
        prewarmBlockedIDs.removeAll()
        tableView.tableColumns.first?.width = width
        // Re-fit the table to the clip view so the document view shrinks
        // with it. Setting only the column width leaves the table's own
        // frame stale and wider than the visible area, which lets the
        // transcript be panned/cropped horizontally after a resize.
        tableView.sizeLastColumnToFit()

        // Heights are width-specific, but `measuredHeightByID` is keyed by
        // width bucket — the new width simply selects (or starts) its own
        // bucket, so nothing is wiped. This is the fix for the scroll shake:
        // this method runs from the bounds observer on every scroll, and the
        // old `measuredHeightByID.removeAll()` meant any width recompute
        // (panel toggle, sub-pixel jitter) nuked every measured height and
        // forced a full estimate→measure→re-tile cascade. Only the transient
        // char-count estimates (not bucketed) are dropped.
        estimateByID.removeAll()

        scheduleVisibleWidthReconfigure()
    }

    func scheduleVisibleWidthReconfigure() {
        pendingWidthWork?.cancel()
        widthReconfigureGeneration += 1
        let generation = widthReconfigureGeneration
        let scheduledWidth = contentWidth
        let scheduledChangeTime = lastWidthChangeTime
        // Continuous motion (Review sidebar / window resize): live-track with
        // width-only constraint updates (cheap). Tiny jitter still settles.
        let trackLive = lastWidthDelta > 2
        let delay: CFTimeInterval
        if trackLive {
            delay = max(0, widthTrackInterval - (CACurrentMediaTime() - lastWidthTrackApplyTime))
        } else {
            delay = max(0, widthChangeSettleWindow - (CACurrentMediaTime() - scheduledChangeTime))
        }
#if DEBUG
        if TranscriptScrollProfiler.verboseTrace {
            TranscriptScrollProfiler.fileLog("WIDTH reconfig scheduled width=\(String(format: "%.0f", scheduledWidth)) delay=\(String(format: "%.0f", delay * 1000))ms track=\(trackLive)")
        }
#endif
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard generation == self.widthReconfigureGeneration else { return }
            self.pendingWidthWork = nil

            if trackLive {
                self.lastWidthTrackApplyTime = CACurrentMediaTime()
                // Only card width constraints — no markdown rebuild.
                self.applyWidthOnlyToVisibleCells()
                let quietFor = CACurrentMediaTime() - self.lastWidthChangeTime
                let widthMoved = abs(self.contentWidth - scheduledWidth) > 0.5
                    || self.lastWidthChangeTime != scheduledChangeTime
                if widthMoved || quietFor < self.widthTrackInterval * 2 {
                    self.scheduleVisibleWidthReconfigure()
                } else {
                    // Final settle: applyRowWidth already re-wrapped each
                    // cell's markdown in place, so heights are already correct.
                    // Sync the table column and let cells report new heights
                    // naturally — avoid reconfigureAllVisibleCells which
                    // rebuilds markdown from scratch and causes a visible flash.
                    TranscriptLayoutAnimation.animateWidth = false
                    self.syncTableColumnAfterWidthSettle()
                }
                return
            }

            let widthChangedAgain = abs(self.contentWidth - scheduledWidth) > 0.5 || self.lastWidthChangeTime != scheduledChangeTime
            let quietFor = CACurrentMediaTime() - self.lastWidthChangeTime
            guard !widthChangedAgain, quietFor >= self.widthChangeSettleWindow else {
#if DEBUG
                if TranscriptScrollProfiler.verboseTrace {
                    TranscriptScrollProfiler.fileLog("WIDTH reconfig reschedule quietFor=\(String(format: "%.0f", quietFor * 1000))ms")
                }
#endif
                self.scheduleVisibleWidthReconfigure()
                return
            }
#if DEBUG
            if TranscriptScrollProfiler.verboseTrace {
                TranscriptScrollProfiler.fileLog("WIDTH reconfig visible width=\(String(format: "%.0f", self.contentWidth))")
            }
#endif
            // Prefer immediate width apply + short ease only when not streaming.
            let allowEase = !self.profiler.isStreamingRecently
            TranscriptLayoutAnimation.animateWidth = allowEase
            // Gentle settle: nudge card widths in place, then sync table
            // column + heights without a full markdown rebuild (no flash).
            self.applyWidthOnlyToVisibleCells(width: self.contentWidth, animated: allowEase, duration: TranscriptLayoutAnimation.duration)
            self.syncTableColumnAfterWidthSettle()
            if allowEase {
                let clearAfter = TranscriptLayoutAnimation.duration + 0.05
                DispatchQueue.main.asyncAfter(deadline: .now() + clearAfter) {
                    if CACurrentMediaTime() - self.lastWidthReconfigTime >= clearAfter - 0.02 {
                        TranscriptLayoutAnimation.animateWidth = false
                    }
                }
            } else {
                TranscriptLayoutAnimation.animateWidth = false
            }
        }
        pendingWidthWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Live sidebar tracking: only nudge bubble/question card widths.
    func applyWidthOnlyToVisibleCells() {
        applyWidthOnlyToVisibleCells(width: contentWidth, animated: false, duration: 0)
    }

    func applyWidthOnlyToVisibleCells(width: CGFloat, animated: Bool, duration: TimeInterval) {
        guard let tableView else { return }
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.length > 0 else { return }
        for row in visible.location ..< visible.location + visible.length where row < orderedIDs.count {
            guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? PiAgentAppKitTranscriptView.TranscriptTableCellView,
                  let native = cell.nativeRow else { continue }
            if let bubble = native as? PiAgentNativeBubbleView {
                bubble.applyRowWidth(width, animated: animated, duration: duration)
            } else if let question = native as? PiAgentNativeQuestionView {
                question.applyRowWidth(width, animated: animated, duration: duration)
            }
        }
        tableView.needsLayout = true
    }

    /// Walk visible rows and reconfigure cells whose content has changed since
    /// they were last configured. Used after a snapshot apply (diffable data
    /// source only reconfigures rows whose ids changed).
    func reconfigureChangedVisibleCells() {
        guard let tableView else { return }
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.length > 0 else { return }
        for row in visible.location ..< visible.location + visible.length where row < orderedIDs.count {
            let id = orderedIDs[row]
            guard let item = itemByID[id],
                  let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? PiAgentAppKitTranscriptView.TranscriptTableCellView else { continue }
            // configure() is a no-op when nothing's changed; otherwise the cell
            // measures itself and reports a new height via onHeightChanged.
            configure(cell, with: item, row: row, via: "snapshot-reconfig")
        }
    }

    func reconfigureVisibleCellsForIDs(_ ids: Set<String>) {
        guard let tableView, !ids.isEmpty else { return }
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.length > 0 else { return }
        // Streaming must never inherit a leftover width-ease flag.
        TranscriptLayoutAnimation.animateWidth = false
        for row in visible.location ..< visible.location + visible.length where row < orderedIDs.count {
            let id = orderedIDs[row]
            guard ids.contains(id),
                  let item = itemByID[id],
                  let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? PiAgentAppKitTranscriptView.TranscriptTableCellView else { continue }
            configure(cell, with: item, row: row, via: "stream-reconfig")
        }
    }

    func canPerformSynchronousTranscriptLayout() -> Bool {
        guard tableView?.window?.inLiveResize != true else { return false }
        // Only suppress forced layout in states known to be unsafe/re-entrant.
        // Active scrolling/streaming still need same-turn anchor compensation;
        // skipping it causes visible jumps when rows above the viewport settle.
        return !isInsideNSViewUpdate
    }

    /// Force-lay-out freshly-reconfigured visible cells for `ids` and write
    /// their true heights into `measuredHeightByID` synchronously, so a re-tile
    /// issued in this same pass uses the new content height. The pinned
    /// streaming path passes a tiny budget and bottom-first ordering: measure
    /// the newest visible changed row to preserve anti-wobble, then let any
    /// remaining rows settle through the normal async height-report path.
    /// Returns the ids whose tiled height actually needs to change.
    func measureChangedCellsSynchronously(
        _ ids: Set<String>,
        budgetMs: Double? = nil,
        maxRows: Int? = nil,
        deferUnmeasured: Bool = false
    ) -> Set<String> {
        guard let tableView, !ids.isEmpty else { return [] }
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.length > 0 else { return [] }
        let visibleRows = (visible.location ..< visible.location + visible.length)
            .filter { $0 < orderedIDs.count && ids.contains(orderedIDs[$0]) }
            .sorted(by: >)
        guard !visibleRows.isEmpty else { return [] }

        var needRetile = Set<String>()
        var deferredIDs = Set<String>()
        let streaming = profiler.isStreamingRecently
        let start = CACurrentMediaTime()
        var measuredCount = 0

        for row in visibleRows {
            let id = orderedIDs[row]
            if let maxRows, measuredCount >= maxRows {
                deferredIDs.insert(id)
                continue
            }
            if measuredCount > 0, let budgetMs,
               (CACurrentMediaTime() - start) * 1000 >= budgetMs {
                deferredIDs.insert(id)
                continue
            }
            guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? PiAgentAppKitTranscriptView.TranscriptTableCellView else { continue }
            let h = cell.forcedIntrinsicHeight()
            measuredCount += 1
            guard h > 0 else { continue }
            let priorMeasured = measuredHeightByID[id]?[widthBucket]
            let height = TranscriptMeasuredHeightResolver.resolvedHeight(
                ceil(h),
                priorMeasuredHeight: priorMeasured,
                isStreaming: streaming
            )
            // `lastNotedHeight` tracks AppKit's current tile exclusively for
            // deciding whether this fresh measurement requires a re-tile.
            let previousTiled = lastNotedHeight[id] ?? -1
#if DEBUG
            // Smoking-gun: the streaming row's tiled height per token, folded
            // with the measure path that produced it (set inside forcedIntrinsic
            // → markdown measureHeight just above). A Δ<0 here = visible wobble.
            TranscriptStreamWobbleProbe.shared.noteTile(
                id: id, height: height, previousTiled: previousTiled,
                width: contentWidth, pinned: true, gliding: followGlideTimer != nil, source: "sync")
#endif
            measuredHeightByID[id, default: [:]][widthBucket] = height
            if abs(previousTiled - height) > heightChangeEpsilon {
                needRetile.insert(id)
            }
        }

        if deferUnmeasured, !deferredIDs.isEmpty {
            scheduleVisibleHeightRemeasure(forIDs: deferredIDs)
        }
        return needRetile
    }

    func scheduleVisibleHeightRemeasure(forIDs ids: Set<String>) {
        guard !ids.isEmpty else { return }
        pendingRemeasureIDs.formUnion(ids)
        guard pendingRemeasureWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let ids = self.pendingRemeasureIDs
            self.pendingRemeasureIDs.removeAll()
            self.pendingRemeasureWork = nil
            guard !self.isUserScrollingRecently else {
                self.scheduleVisibleHeightRemeasure(forIDs: ids)
                return
            }
            let retileIDs = self.measureChangedCellsSynchronously(ids, budgetMs: 5, deferUnmeasured: true)
            guard !retileIDs.isEmpty else { return }
            self.flushPendingHeightWorkSynchronously()
            self.noteHeightsChanged(forIDs: retileIDs)
        }
        pendingRemeasureWork = work
        let delay = isUserScrollingRecently ? 0.05 : heightReportInterval
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Gentle post-track settle: sync the table column width and let
    /// cells that already re-wrapped via applyRowWidth report their new
    /// heights naturally. Avoids the full markdown rebuild (flash) that
    /// reconfigureAllVisibleCells would cause.
    func syncTableColumnAfterWidthSettle() {
        guard let tableView else { return }
        let width = currentViewportWidth()
        let delta = abs(width - contentWidth)
        if delta > 0.5 {
            contentWidth = width
            tableView.tableColumns.first?.width = width
            tableView.sizeLastColumnToFit()
        }
        estimateByID.removeAll()
        lastWidthReconfigTime = CACurrentMediaTime()
        // Let visible cells report their re-wrapped heights. Cells were
        // already nudged to the new width by applyRowWidth; we just trigger
        // a height report for any cell whose height changed.
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.length > 0 else { return }
        var retileIDs: Set<String> = []
        let bucket = Int(width.rounded())
        for row in visible.location ..< visible.location + visible.length where row < orderedIDs.count {
            let id = orderedIDs[row]
            guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? PiAgentAppKitTranscriptView.TranscriptTableCellView else { continue }
            let h = cell.forcedIntrinsicHeight()
            let prior = measuredHeightByID[id]?[bucket] ?? lastNotedHeight[id] ?? estimatedRowHeight
            if h > 0 && abs(h - prior) > heightChangeEpsilon {
                measuredHeightByID[id, default: [:]][bucket] = h
                lastNotedHeight[id] = h
                retileIDs.insert(id)
            }
        }
        if !retileIDs.isEmpty {
            noteHeightsChanged(forIDs: retileIDs)
        }
    }

    func reconfigureAllVisibleCells() {
        guard let tableView else { return }
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.length > 0 else { return }
        lastWidthReconfigTime = CACurrentMediaTime()
        // `TranscriptLayoutAnimation.animateWidth` is set by the caller:
        // live sidebar tracking → false (pixel-follow); quiet settle → true.
        for row in visible.location ..< visible.location + visible.length where row < orderedIDs.count {
            let id = orderedIDs[row]
            guard let item = itemByID[id],
                  let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? PiAgentAppKitTranscriptView.TranscriptTableCellView else { continue }
            // Don't drop the measured height — it's width-bucketed, so the
            // new width's bucket fills in on its own as the cell re-measures
            // and reports. Only the transient estimate is cleared.
            estimateByID.removeValue(forKey: id)
            configure(cell, with: item, row: row, via: "width-reconfig")
        }
    }

    func configure(_ cell: PiAgentAppKitTranscriptView.TranscriptTableCellView, with item: PiAgentAppKitTranscriptItem, row: Int, via: String = "scroll-vend") {
        let width = currentViewportWidth()
        // Each cell owns its own NSHostingView for its lifetime. Recycling
        // a cell for a new item just swaps the host's rootView — never
        // detaches the host. That's what keeps multiple visible cells from
        // ever contending for a single shared host (the bug fixed here).
        profiler.noteConfigure()
        let deferWidthOnlySettle = CACurrentMediaTime() - lastWidthChangeTime < widthChangeSettleWindow
        cell.installRootView(item: item, width: width, profiler: profiler, via: via, deferWidthOnlySettle: deferWidthOnlySettle)
        // No measurement here — the cell reports its real height via
        // `onMeasuredHeight` once it lays out. Until then `heightOfRow`
        // serves the char-count estimate (or a cached real height).
    }

    func currentViewportWidth() -> CGFloat {
        let viewportCandidates = [
            scrollView?.bounds.width,
            scrollView?.contentView.bounds.width,
            tableView?.enclosingScrollView?.bounds.width,
            tableView?.enclosingScrollView?.contentView.bounds.width
        ].compactMap { $0 }.filter { $0.isFinite && $0 > 1 }
        if let width = viewportCandidates.max() {
            return max(200, width)
        }

        let tableCandidates = [
            tableView?.visibleRect.width,
            tableView?.bounds.width,
            tableView?.tableColumns.first?.width
        ].compactMap { $0 }.filter { $0.isFinite && $0 > 1 }
        return max(200, tableCandidates.max() ?? contentWidth)
    }

    /// Called by a live cell once it has laid out, with the SwiftUI
    /// content's intrinsic height. Updates the cache and (debounced) tells
    /// the table to re-tile the row when the height actually changed.
    func reportMeasuredHeight(_ rawHeight: CGFloat, forItemID itemID: String) {
        // Reports can land from cells queued before a session switch or a
        // structural apply — for an item the transcript no longer has. Caching
        // that height would poison the entry for the id's NEXT appearance
        // (captured: a transient status-row report under a subagent card's id
        // wrote ~56 over the card's real 157 during a switch). Drop them; the
        // id's next live cell re-reports through this same path.
        guard itemByID[itemID] != nil else { return }
        var height = ceil(rawHeight)
        let bucket = widthBucket
        let priorMeasured = measuredHeightByID[itemID]?[bucket]
        // Re-tile only when AppKit's *laid-out* height is genuinely stale.
        // The baseline is what the table currently has tiled (lastNotedHeight),
        // not the cache — falling back to the prior measurement, then the
        // rough row estimate. Comparing against the cache would fire a
        // spurious noteHeightOfRows whenever the cache shifted without the
        // laid-out height actually changing.
        let baseline = lastNotedHeight[itemID] ?? priorMeasured ?? estimatedRowHeight
        // Streaming content only grows; clamp only to a prior real measurement
        // at this width. `lastNotedHeight` may be an initial tiled estimate, so
        // it must not prevent the first real measurement from shrinking to fit.
        height = TranscriptMeasuredHeightResolver.resolvedHeight(
            height,
            priorMeasuredHeight: priorMeasured,
            isStreaming: profiler.isStreamingRecently
        )
        measuredHeightByID[itemID, default: [:]][bucket] = height
        estimateByID.removeValue(forKey: itemID)
#if DEBUG
        // Same smoking-gun line for the debounced async path (rows that aren't
        // force-measured while pinned, e.g. when not auto-following).
        TranscriptStreamWobbleProbe.shared.noteTile(
            id: itemID, height: height, previousTiled: baseline,
            width: contentWidth, pinned: isAutoFollowing, gliding: followGlideTimer != nil, source: "async")
#endif
        let delta = abs(baseline - height)
        guard delta > heightChangeEpsilon else { return }
        pendingHeightIDs.insert(itemID)
        guard pendingHeightWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let ids = self.pendingHeightIDs
            self.pendingHeightIDs.removeAll()
            self.pendingHeightWork = nil
            self.noteHeightsChanged(forIDs: ids)
        }
        pendingHeightWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + heightReportInterval, execute: work)
    }

    func noteHeightsChanged(forIDs ids: Set<String>) {
        guard let tableView, scrollView != nil, !ids.isEmpty else { return }
        let wasFollowing = isAutoFollowing
        var rows = IndexSet()
        for id in ids {
            if let row = orderedIDs.firstIndex(of: id), row < tableView.numberOfRows {
                rows.insert(row)
                // Record what AppKit is about to lay this row out at — the
                // baseline future measurements are compared against.
                // reportMeasuredHeight already wrote the fresh height into
                // measuredHeightByID before scheduling this call.
                if let h = measuredHeightByID[id]?[widthBucket] { lastNotedHeight[id] = h }
            }
        }
        guard !rows.isEmpty else { return }
        // A row re-tiling to its true height shifts everything below it.
        // NSTableView pins row 0 to the document top, so a correction to any
        // row above the viewport yanks visible content out from under the
        // reader. Capture the top-visible row and restore its on-screen
        // offset right after the re-tile so the shift is absorbed silently.
        //
        // Preserve the anchor whenever we're not pinned — INCLUDING while the
        // user is actively scrolling. Scrolling up through history is exactly
        // when never-measured rows above the viewport first resolve from their
        // rough estimate to a real height (a +1000pt correction is common for a
        // long reply), and leaving those uncompensated is what makes the
        // transcript lurch under the reader. Restoring the top-visible row's
        // on-screen offset does NOT fight the gesture: capture and restore run
        // synchronously around `noteHeightOfRows` here (no stale anchor), and
        // `restoreScrollAnchor` self-guards — when the changed rows are at or
        // below the anchor row its minY is unchanged, so the target equals the
        // current origin and no scroll happens. The viewport only moves when a
        // row *above* the anchor reflowed, which is precisely the shift we want
        // to absorb. (Was previously gated on `!isUserScrollingRecently`, which
        // disabled compensation during the one gesture that needs it most.)
        // Every re-tile must compensate one way or the other: follow to the
        // bottom when auto-following, otherwise hold the top-visible anchor. The
        // one case that must NOT be left bare is "following but the user just
        // started scrolling" (wasFollowing && isUserScrollingRecently): autoFollow
        // is off (we don't yank a scrolling user to the bottom) so the anchor must
        // carry it, or the streaming row grows with nothing holding position.
        let willAutoFollow = wasFollowing && !isUserScrollingRecently
        let preserveAnchor = !willAutoFollow
        let anchor = preserveAnchor ? captureScrollAnchor() : nil
        profiler.measureRetile(rows: rows.count) {
        NSAnimationContext.beginGrouping()
        // Width reflow (sidebar open/close) may ease heights — but NEVER during
        // streaming. Animating noteHeightOfRows per token kills the stream feel
        // (looks buffered / non-streaming). Also never use a time-window after
        // lastWidthReconfigTime: that kept poisoning stream retiles for ~0.4s.
        let easeWidthReflow = TranscriptLayoutAnimation.animateWidth
            && !profiler.isStreamingRecently
        NSAnimationContext.current.duration = easeWidthReflow ? TranscriptLayoutAnimation.duration : 0
        // Suppress implicit Core Animation actions so a streaming row's
        // height change re-tiles instantly with no per-token animation.
        CATransaction.begin()
        CATransaction.setDisableActions(!easeWidthReflow)
        // Flag the whole re-tile as programmatic. `noteHeightOfRows` /
        // `layoutSubtreeIfNeeded` can nudge the clip origin by a sub-pixel as
        // AppKit re-lays the rows; that nudge posts a boundsDidChange, and if
        // the flag isn't set the observer mistakes it for a *user* scroll. On a
        // streaming row that fires every token, re-stamping `lastUserScrollTime`
        // continuously — which pins `isUserScrollingRecently` true and the
        // auto-follow off until the stream ends (a stray touch could leave the
        // view parked below the latest content for the rest of the response).
        let wasProgrammatic = isProgrammaticScroll
        isProgrammaticScroll = true
        tableView.noteHeightOfRows(withIndexesChanged: rows)
        let safeToForceTableLayout = canPerformSynchronousTranscriptLayout()
        if let anchor, let changedRowAboveAnchor = rows.min(), changedRowAboveAnchor < anchor.rowIndex {
            // rect(ofRow:) must see the new heights before we re-anchor. If
            // every changed row is at/below the anchor, the anchor's minY is
            // unchanged, so avoid the synchronous full subtree layout entirely.
            if safeToForceTableLayout {
                tableView.layoutSubtreeIfNeeded()
                restoreScrollAnchor(anchor)
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.restoreScrollAnchorIfNeeded(anchor)
                }
            }
        } else if willAutoFollow, let scrollView,
                  let bottomMostChangedRow = rows.max(),
                  tableView.rect(ofRow: bottomMostChangedRow).maxY < scrollView.contentView.bounds.minY + 1 {
            // Pinned to the bottom while rows ABOVE the viewport corrected
            // (estimate → real heights after a session switch into a large
            // transcript). The re-tile just shifted the content under the
            // viewport; prefer a deferred re-pin when layout/stream/scroll
            // state makes synchronous full-table layout unsafe.
            if safeToForceTableLayout {
                tableView.layoutSubtreeIfNeeded()
                if let documentView = scrollView.documentView {
                    let clipView = scrollView.contentView
                    let maxY = max(0, documentView.bounds.height - clipView.bounds.height)
                    clipView.scroll(to: NSPoint(x: 0, y: maxY))
                    scrollView.reflectScrolledClipView(clipView)
                }
            } else {
                scrollToBottom(settle: false)
            }
        }
        isProgrammaticScroll = wasProgrammatic
        CATransaction.commit()
        NSAnimationContext.endGrouping()
        }
        if willAutoFollow {
            scrollToBottom(settle: false)
        }
    }

    func flushPendingHeightWorkSynchronously() {
        guard let work = pendingHeightWork else { return }
        work.cancel()
        pendingHeightWork = nil
        let ids = pendingHeightIDs
        pendingHeightIDs.removeAll()
        noteHeightsChanged(forIDs: ids)
    }

    /// A session switch pins to a bottom computed from estimate heights. The
    /// old path immediately forced table layout, measured every newly visible
    /// row, re-tiled them, then forced another bottom layout in the same main-
    /// thread turn. Cold-start samples showed that synchronous settle as the
    /// session-switch hang signature (`layoutSubtreeIfNeeded` +
    /// `noteHeightOfRowsWithIndexesChanged` + anchor/bottom restore). Keep the
    /// same eventual geometry, but slice the visible-row settle over run-loop
    /// turns: one already-vended row per turn, then a cheap bottom re-pin that
    /// does not force a full document layout. Cells that are not live yet settle
    /// through their normal async height report path.
    func scheduleVisibleRowsSettleAfterSessionSwitch() {
        pendingSessionSwitchSettleWork?.cancel()
        let generation = sessionSwitchSettleGeneration
        scheduleVisibleRowsSettleAfterSessionSwitch(generation: generation, remainingPasses: 8, delay: 0)
    }

    func scheduleVisibleRowsSettleAfterSessionSwitch(
        generation: Int,
        remainingPasses: Int,
        delay: TimeInterval
    ) {
        guard remainingPasses > 0 else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, generation == self.sessionSwitchSettleGeneration else { return }
            self.pendingSessionSwitchSettleWork = nil
            guard let tableView = self.tableView, let scrollView = self.scrollView else { return }
            let visible = tableView.rows(in: tableView.visibleRect)
            guard visible.length > 0 else { return }
            var ids = Set<String>()
            for row in visible.location ..< visible.location + visible.length where row < self.orderedIDs.count {
                let id = self.orderedIDs[row]
                if self.measuredHeightByID[id]?[self.widthBucket] == nil {
                    ids.insert(id)
                }
            }
            guard !ids.isEmpty else { return }
            let retileIDs = self.measureChangedCellsSynchronously(
                ids,
                budgetMs: 4,
                maxRows: 1,
                deferUnmeasured: true
            )
            if !retileIDs.isEmpty {
                self.flushPendingHeightWorkSynchronously()
                self.noteHeightsChanged(forIDs: retileIDs)
                self.performScrollToBottom(scrollView, animated: false, forceLayout: false)
            }
            self.scheduleVisibleRowsSettleAfterSessionSwitch(
                generation: generation,
                remainingPasses: remainingPasses - 1,
                delay: self.heightReportInterval
            )
        }
        pendingSessionSwitchSettleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func captureScrollAnchor() -> ScrollAnchor? {
        guard let tableView, let scrollView else { return nil }
        let originY = scrollView.contentView.bounds.origin.y
        let row = tableView.row(at: NSPoint(x: 0, y: originY))
        guard row >= 0, row < orderedIDs.count else { return nil }
        let rowRect = tableView.rect(ofRow: row)
        return ScrollAnchor(id: orderedIDs[row], rowIndex: row, offsetFromRowTop: originY - rowRect.minY)
    }

    func restoreScrollAnchorIfNeeded(_ anchor: ScrollAnchor?) {
        // Don't restore over a live user gesture — let their scroll stand.
        // (The height-change compensation path uses `restoreScrollAnchor`
        // directly, since there it must run *during* the gesture.)
        guard !isUserScrollingRecently, let anchor else { return }
        restoreScrollAnchor(anchor)
    }

    /// Re-scroll so `anchor`'s row sits at the same on-screen offset it had
    /// when the anchor was captured. Unlike `restoreScrollAnchorIfNeeded`,
    /// this runs even mid-gesture — it is the height-change compensation
    /// that keeps a row re-tile from shifting content under the user.
    func restoreScrollAnchor(_ anchor: ScrollAnchor) {
        guard let tableView, let scrollView,
              let row = orderedIDs.firstIndex(of: anchor.id),
              row >= 0, row < tableView.numberOfRows,
              let documentView = scrollView.documentView else { return }
        let rowRect = tableView.rect(ofRow: row)
        let maxY = max(0, documentView.bounds.height - scrollView.contentView.bounds.height)
        let targetY = min(max(0, rowRect.minY + anchor.offsetFromRowTop), maxY)
        let originY = scrollView.contentView.bounds.origin.y
        guard abs(originY - targetY) > 0.5 else { return }
        // Save/restore rather than force-false: this runs nested inside the
        // `noteHeightsChanged` re-tile, which holds the flag true around the
        // whole transaction. Clearing it here would unflag the rest of that
        // transaction's AppKit-driven origin nudges.
        let wasProgrammatic = isProgrammaticScroll
        isProgrammaticScroll = true
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        isProgrammaticScroll = wasProgrammatic
    }
}
