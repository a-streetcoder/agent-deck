import AppKit
import Combine
import Darwin
import os
import QuartzCore
import SwiftUI

// MARK: - Follow glide, pin state, table delegate heights

extension PiAgentAppKitTranscriptView.Coordinator {
    func handleScrollAfterUpdate(isSessionSwitch: Bool, explicitScroll: Bool, wasFollowing: Bool, contentAdvanced: Bool) {
        guard let scrollView else { return }
        if isSessionSwitch {
            // Session selection should open already pinned to the latest row,
            // not visibly animate from the top after the table appears.
            isAutoFollowing = true
            pendingScrollWork?.cancel()
            pendingScrollWork = nil
            pendingGlideLandingSettleWork?.cancel()
            pendingGlideLandingSettleWork = nil
            pendingScrollSettle = false
            performScrollToBottom(scrollView, animated: false)
            scheduleVisibleRowsSettleAfterSessionSwitch()
        } else if explicitScroll {
            // User-requested jumps (send, jump-to-latest) re-arm follow intent.
            isAutoFollowing = true
            scrollToBottom(settle: true)
        } else if wasFollowing && !isUserScrollingRecently && contentAdvanced {
            // Passive streaming follow — but never while the user is
            // actively scrolling, or it would yank the viewport. And only
            // when this update actually changed row content/geometry: an
            // update can reach here with nothing changed on screen (e.g. a
            // revision pulse), and gliding on it both yanks an idle session
            // the user is reading and pays performScrollToBottom's
            // full-document layout for nothing.
            scrollToBottom(settle: false)
        } else {
            publishPinnedState(isAutoFollowing)
        }
    }

    func scrollToBottom(settle: Bool) {
        if settle {
            pendingGlideLandingSettleWork?.cancel()
            pendingGlideLandingSettleWork = nil
        }
        pendingScrollSettle = pendingScrollSettle || settle
        // While the passive streaming glide is already following, additional
        // non-settle requests do not need even a runloop-hop work item. The
        // timer re-reads the current document height each frame, so new tokens
        // are naturally coalesced into that in-flight glide. Explicit settle
        // requests still pierce through and snap to the authoritative bottom.
        if !settle, followGlideTimer != nil { return }
        guard pendingScrollWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, let scrollView = self.scrollView else { return }
            let shouldSettle = self.pendingScrollSettle
            self.pendingScrollWork = nil
            self.pendingScrollSettle = false
            // Re-check at fire time: this item runs a runloop hop after it
            // was scheduled, and the user may have grabbed the scroll in
            // between. Explicit jumps (settle) still win; the passive follow
            // yields without paying a synchronous height flush or full-document
            // layout mid-gesture.
            if !shouldSettle, self.isUserScrollingRecently { return }
            // Streaming follow (settle == false) glides using current geometry;
            // explicit settle/session-switch paths snap after an authoritative
            // height flush + layout.
            self.performScrollToBottom(scrollView, animated: !shouldSettle, forceLayout: shouldSettle)
            guard shouldSettle else { return }
            self.pendingSettleScrollWork?.cancel()
            let settleWork = DispatchWorkItem { [weak self] in
                guard let self, let scrollView = self.scrollView else { return }
                self.pendingSettleScrollWork = nil
                // The delayed settle is explicit: pay the synchronous flush once
                // here so jump-to-latest/send lands on the true bottom after any
                // pending cell measurements have arrived.
                self.performScrollToBottom(scrollView, animated: false, forceLayout: true)
            }
            self.pendingSettleScrollWork = settleWork
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: settleWork)
        }
        pendingScrollWork = work
        DispatchQueue.main.async(execute: work)
    }

    func performScrollToBottom(_ scrollView: NSScrollView, animated: Bool, forceLayout: Bool = true) {
        guard let documentView = scrollView.documentView else { return }
        // An auto-follow glide already eases toward the (growing) bottom every
        // frame and re-reads the document height as it goes, so repeated
        // streaming requests should collapse into that in-flight timer instead
        // of flushing heights or forcing full-document layout.
        if animated, followGlideTimer != nil { return }
        let clipView = scrollView.contentView
        if forceLayout {
            // Explicit settle/session-switch paths need authoritative geometry.
            // Keep this synchronous work out of normal streaming auto-follow,
            // where samples showed it repeatedly forcing full document layout.
            flushPendingHeightWorkSynchronously()
            documentView.layoutSubtreeIfNeeded()
        }
        let maxY = max(0, documentView.bounds.height - clipView.bounds.height)
        guard abs(clipView.bounds.origin.y - maxY) > 1 else {
            if !animated { stopFollowGlide() }
            publishPinnedState(true)
            return
        }
        // Streaming follow: hand off to the glide timer, which eases toward the
        // current bottom and picks up future height changes on later ticks.
        if animated {
            startFollowGlide()
            return
        }
        // Explicit / settle: snap immediately.
        stopFollowGlide()
        isProgrammaticScroll = true
        clipView.scroll(to: NSPoint(x: 0, y: maxY))
        scrollView.reflectScrolledClipView(clipView)
        isProgrammaticScroll = false
        publishPinnedState(true)
    }

    /// Begin (or keep) easing the clip origin toward the document bottom each
    /// frame. Idempotent — if a glide is already running it simply continues
    /// and naturally picks up the new, larger bottom on its next tick.
    func startFollowGlide() {
        // Never start a glide when auto-follow is disengaged — the caller's
        // intent check and this guard together ensure the glide can only run
        // while the reader is actually pinned to the bottom.
        guard followGlideTimer == nil, isAutoFollowing else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                // self is nil only after the coordinator tore down, which
                // invalidates this timer in `invalidate()`; nothing to do here.
                self?.stepFollowGlide()
            }
        }
        // .common so the glide keeps ticking during resize / tracking runloop modes.
        RunLoop.main.add(timer, forMode: .common)
        followGlideTimer = timer
    }

    func stepFollowGlide() {
        guard let scrollView, let documentView = scrollView.documentView else {
            stopFollowGlide()
            return
        }
        // The user's scroll is authoritative — disengage and let it stand.
        if isUserScrollingRecently {
            stopFollowGlide()
            return
        }
        // Auto-follow is disengaged (the user scrolled away from the bottom) —
        // the glide must NEVER move the viewport, even if a stale timer is still
        // ticking or the user paused long enough for the scroll grace window to
        // lapse. Without this, a streaming re-tile lets the glide ease back to
        // the bottom and yanks the reader down: the "scroll against the stream
        // makes it jump" bug.
        guard isAutoFollowing else {
            stopFollowGlide()
            return
        }
        let clipView = scrollView.contentView
        // Cheap path: ease using the current (possibly slightly stale during a
        // streaming re-tile) document height. The authoritative confirm below
        // only runs once, at the moment the glide believes it has arrived.
        let maxY = max(0, documentView.bounds.height - clipView.bounds.height)
        let current = clipView.bounds.origin.y
        let gap = maxY - current
        if abs(gap) > 0.5 {
            let nextY = current + gap * followGlideFactor
            isProgrammaticScroll = true
            clipView.scroll(to: NSPoint(x: 0, y: nextY))
            scrollView.reflectScrolledClipView(clipView)
            isProgrammaticScroll = false
            return
        }
        // Looks settled against the geometry AppKit has already produced.
        // Do not force pending height work or document layout here: during
        // streaming this landing check can happen for every token batch, and
        // samples showed that synchronous full-document layout dominating the
        // main thread. If height work is still pending, schedule one deferred
        // authoritative snap after streaming goes quiet so the glide cannot
        // remain permanently short of the final measured bottom.
#if DEBUG
        TranscriptStreamWobbleProbe.shared.noteGlideLanding(
            trueGap: gap, docHeight: documentView.bounds.height, clipHeight: clipView.bounds.height)
#endif
        scheduleGlideLandingSettleIfNeeded()
        stopFollowGlide()
        publishPinnedState(true)
        return
    }

    func scheduleGlideLandingSettleIfNeeded(
        delay: TimeInterval = 0.12,
        requirePendingHeightWork: Bool = true
    ) {
        guard pendingGlideLandingSettleWork == nil,
              !requirePendingHeightWork || pendingHeightWork != nil || !pendingHeightIDs.isEmpty else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingGlideLandingSettleWork = nil
            guard self.isAutoFollowing, !self.isUserScrollingRecently else { return }
            // While tokens are still arriving, keep deferring instead of
            // turning the landing check back into a per-token forced layout.
            // Preserve the one requested settle even if the original pending
            // height work drained meanwhile; the point is to confirm the final
            // measured bottom after the stream goes quiet.
            if self.profiler.isStreamingRecently {
                self.scheduleGlideLandingSettleIfNeeded(delay: 0.2, requirePendingHeightWork: false)
                return
            }
            guard let scrollView = self.scrollView else { return }
            self.performScrollToBottom(scrollView, animated: false, forceLayout: true)
        }
        pendingGlideLandingSettleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func stopFollowGlide() {
        followGlideTimer?.invalidate()
        followGlideTimer = nil
    }

    func isPinnedToBottom(_ scrollView: NSScrollView) -> Bool {
        guard let documentView = scrollView.documentView else { return true }
        let maxY = max(0, documentView.bounds.height - scrollView.contentView.bounds.height)
        return maxY - scrollView.contentView.bounds.origin.y < 80
    }

    func publishPinnedState(_ pinned: Bool) {
        guard pinned != lastPinnedState else { return }
        lastPinnedState = pinned
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.001) { [weak self] in
            self?.onPinnedToBottomChange(pinned)
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        PiAgentAppKitTranscriptView.TranscriptTableRowView()
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < orderedIDs.count else { return estimatedRowHeight }
        let id = orderedIDs[row]
        // Whatever this method returns IS what AppKit tiles the row at, so it
        // is the one true baseline for "does a fresh measurement need a
        // re-tile". Recording it here keeps `lastNotedHeight` honest across
        // session switches and snapshot applies, where AppKit re-tiles every
        // row through this path without going near `noteHeightsChanged`.
        // (Captured failure: switch away + back left lastNotedHeight at the
        // old 157 while the table re-tiled from a poisoned 56 cache entry —
        // the cell's correct 157 report then matched the stale baseline and
        // was swallowed, leaving the subagent card cropped for the whole run.)
        // Prefer a real measurement for the current width — it survives
        // width changes and session switches, so a revisited row lays out at
        // its exact height with no reflow.
        if let measured = measuredHeightByID[id]?[widthBucket] {
            lastNotedHeight[id] = measured
            return measured
        }
        if let estimate = estimateByID[id] {
            lastNotedHeight[id] = estimate
            return estimate
        }
        // No measurement yet — use the item's fast estimator so the table can lay
        // the row out close to its natural size without triggering a SwiftUI pass.
        // The cell measures precisely as it renders and reports back via
        // reportMeasuredHeight, at which point this row gets re-tiled.
        if let item = itemByID[id] {
            let est = item.estimatedHeight(contentWidth)
            estimateByID[id] = est
            lastNotedHeight[id] = est
            return est
        }
        return estimatedRowHeight
    }
}
