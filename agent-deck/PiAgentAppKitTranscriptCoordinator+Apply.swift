import AppKit
import Combine
import Darwin
import os
import QuartzCore
import SwiftUI

// MARK: - Scroll observation, apply snapshot, benches

extension PiAgentAppKitTranscriptView.Coordinator {
    func setupScrollObservation(_ scrollView: NSScrollView) {
        // queue: nil — synchronous delivery on the posting (main) thread.
        // Required so `isProgrammaticScroll` still reads true when the
        // notification for our own scroll mutation arrives: with queue:.main
        // the block runs a runloop tick later, after the flag is cleared,
        // and our self-induced bounds change would be mis-stamped as a user
        // scroll — pinning `isUserScrollingRecently` true and killing
        // streaming auto-follow.
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let scrollView = self.scrollView else { return }
                self.profiler.measureBoundsCallback {
                if !self.isProgrammaticScroll {
                    self.forcedActiveQuestionID = nil
                    // Authoritative user-scroll timestamp — covers mouse
                    // wheels and scroller drags that post no live-scroll
                    // notification at all.
                    self.lastUserScrollTime = CACurrentMediaTime()
                    // Let the background project rescan know the transcript is
                    // being scrolled so it defers its observable-churning refresh
                    // until the gesture settles (avoids a mid-scroll itemsBuild).
                    TranscriptInteractionGate.noteInteraction()
                    self.profiler.userScrollTick()
                    // A genuine user-driven bounds change ends the auto-follow
                    // glide immediately (the glide's own scrolls set the
                    // programmatic flag, so they don't reach here).
                    self.stopFollowGlide()
                    // Re-evaluate follow intent from where the *user* left the
                    // viewport: at the bottom → keep following, scrolled away →
                    // stop. This is the ONLY place position decides intent —
                    // the auto-glide's own trailing never flips it, so a glide
                    // running a little behind the bottom can't disengage itself.
                    self.isAutoFollowing = self.isPinnedToBottom(scrollView)
                    self.pendingScrollWork?.cancel()
                    self.pendingScrollWork = nil
                    self.pendingSettleScrollWork?.cancel()
                    self.pendingSettleScrollWork = nil
                    self.pendingGlideLandingSettleWork?.cancel()
                    self.pendingGlideLandingSettleWork = nil
                    self.pendingScrollSettle = false
                }
                // Clip-view bounds change before the scrollView frame notification fires,
                // so resync column width here to avoid a one-frame horizontal overflow
                // when the inspector slides in or the window resizes.
                self.updateColumnWidthIfNeeded()
                self.updateQuestionRail()
                self.publishPinnedState(self.isAutoFollowing)
                }
            }
        }

        frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateColumnWidthIfNeeded()
                self?.updateQuestionRail()
            }
        }

        // Disabled for the top-level three-column host: predicting a target
        // width before the real viewport settles made bubble chrome and text
        // content appear to scale/move twice. The frame-change observer is the
        // single live width source; it's gated while a splitter drag is active
        // so the transcript stays frozen (no rewrap / overlap / jitter) until
        // the drag ends and it re-lays out once to the settled width.
        columnWidthAnimateObserver = nil

        // Freeze transcript sizing while the user drags a splitter (Review /
        // sidebar); thaw + re-layout when they release (`active: false`).
        columnResizeActiveObserver = NotificationCenter.default.addObserver(
            forName: .transcriptColumnResizeActive,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let active = (note.userInfo?["active"] as? Bool) ?? false
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isLiveResizing = active
                if !active {
                    // Drag ended: let the frame observer pick up the settled
                    // width and do ONE clean re-layout.
                    self.updateColumnWidthIfNeeded()
                }
            }
        }

        // Live-scroll notifications bracket trackpad gestures / scroller
        // drags. They miss discrete mouse wheels entirely — the timestamp
        // stamped in the bounds observer covers those, and the grace window
        // in `isUserScrollingRecently` covers the tail after a gesture ends.
        liveScrollStartObserver = NotificationCenter.default.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification,
            object: scrollView,
            queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isLiveScrolling = true
                self.profiler.gestureStart()
                self.stopFollowGlide()
                self.pendingGlideLandingSettleWork?.cancel()
                self.pendingGlideLandingSettleWork = nil
                // The user grabbed the scroll — drop follow intent until they
                // either land back at the bottom or jump to latest.
                self.isAutoFollowing = false
                self.publishPinnedState(false)
            }
        }
        liveScrollEndObserver = NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveScrollNotification,
            object: scrollView,
            queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isLiveScrolling = false
                self.profiler.gestureEnd()
                // Start the grace window from gesture end so a streaming
                // update arriving right after release can't snap the view.
                self.lastUserScrollTime = CACurrentMediaTime()
                TranscriptInteractionGate.noteInteraction()
            }
        }
    }

    /// Removes the four NotificationCenter observers and cancels in-flight
    /// DispatchWorkItems. SwiftUI calls `dismantleNSView(_:coordinator:)`
    /// (defined above at `:501-503`) when the representable goes away,
    /// which invokes this — that is the documented teardown contract for
    /// `NSViewRepresentable`. We can't add a defensive `deinit` here under
    /// Swift 6 because `Coordinator` is MainActor-isolated and `deinit`
    /// runs in a nonisolated context.
    func invalidate() {
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
        if let liveScrollStartObserver { NotificationCenter.default.removeObserver(liveScrollStartObserver) }
        if let liveScrollEndObserver { NotificationCenter.default.removeObserver(liveScrollEndObserver) }
        if let columnWidthAnimateObserver { NotificationCenter.default.removeObserver(columnWidthAnimateObserver) }
        if let columnResizeActiveObserver { NotificationCenter.default.removeObserver(columnResizeActiveObserver) }
        boundsObserver = nil
        frameObserver = nil
        liveScrollStartObserver = nil
        liveScrollEndObserver = nil
        columnWidthAnimateObserver = nil
        columnResizeActiveObserver = nil
        pendingHeightWork?.cancel()
        pendingScrollWork?.cancel()
        pendingSettleScrollWork?.cancel()
        pendingGlideLandingSettleWork?.cancel()
        pendingSessionSwitchSettleWork?.cancel()
        pendingRemeasureWork?.cancel()
        pendingRemeasureIDs.removeAll()
        pendingWidthWork?.cancel()
        pendingWidthAnimationCleanup?.cancel()
        pendingWidthAnimationCleanup = nil
        TranscriptLayoutAnimation.animateWidth = false
        stopFollowGlide()
    }

    func apply(
        items: [PiAgentAppKitTranscriptItem],
        sessionID: UUID?,
        itemsSessionID: UUID?,
        isTranscriptLoading: Bool,
        renderRevision: Int,
        streamingRevision: Int,
        autoScrollTurnRevision: Int,
        bottomScrollRequest: Int
    ) {
        guard let tableView, scrollView != nil else { return }
        let wasFollowing = isAutoFollowing
        let isSessionSwitch = self.sessionID != sessionID
        // A switch must apply EXACTLY ONCE, with the right content. Two
        // transition passes try to sneak in earlier and each used to render
        // as a visible step:
        //  1. The first re-render after a selection change still carries the
        //     PREVIOUS session's cache content (SwiftUI runs onChange — which
        //     publishes the new session — only after this pass). Items built
        //     from another session never apply to this one.
        //  2. The new transcript may still be decoding off disk; applying
        //     would show the loading placeholder, then the content. Hold the
        //     old rows until the decode lands (cold start, with nothing on
        //     screen yet, still shows the loading card).
        if isSessionSwitch, !orderedIDs.isEmpty {
            if let itemsSessionID, let sessionID, itemsSessionID != sessionID { return }
            if isTranscriptLoading { return }
        }
        let structuralUpdate = lastRenderRevision != renderRevision
        let streamingUpdate = lastStreamingRevision != streamingRevision
        let explicitScroll = lastAutoScrollTurnRevision != autoScrollTurnRevision || lastBottomScrollRequest != bottomScrollRequest

        let prep = TranscriptScrollProfiler.measurePhase("apply.prep") {
            var nextIDs: [String] = []
            nextIDs.reserveCapacity(items.count)
            var revisionChanged = false
            for item in items {
                nextIDs.append(item.id)
                // True iff some row's content revision moved (mirrors the
                // `changedIDs` test below). Catches updates that don't bump
                // renderRevision/streamingRevision — e.g. skill/visibility/
                // subagent context folded into per-item revisions during itemsBuild.
                if contentRevisionByID[item.id] != item.contentRevision {
                    revisionChanged = true
                }
            }
            return (nextIDs: nextIDs, idsChanged: nextIDs != orderedIDs, revisionChanged: revisionChanged)
        }
        let nextIDs = prep.nextIDs
        let idsChanged = prep.idsChanged
        let revisionChanged = prep.revisionChanged

        // SwiftUI re-runs updateNSView on every screen-body re-evaluation,
        // including ones driven by unrelated state (e.g. sidebar selection).
        // When neither the rows, their revisions, nor any scroll/structural
        // signal moved, there is nothing to do — bail before the O(N)
        // dictionary rebuilds, snapshot diff, reconfigure, scroll handling, and
        // column refit below. (Column width is handled separately in
        // updateNSView via updateColumnWidthIfNeeded.)
        if !isSessionSwitch && !idsChanged && !revisionChanged
            && !structuralUpdate && !streamingUpdate && !explicitScroll {
            return
        }

        // Stamp streaming activity up front so every profiler line emitted by
        // the builds/re-tiles below is tagged [stream] vs [static] — the shared
        // capture mixes "scrolling a finished transcript" with "live generation"
        // and they need opposite fixes.
        if streamingUpdate {
            profiler.noteStreamingActivity()
            TranscriptInteractionGate.noteStreaming()
        }
#if DEBUG
        if streamingUpdate { maybeRunStreamScrollTest() }
#endif

        self.items = items
        let dictionaries = TranscriptScrollProfiler.measurePhase("apply.dictionaries") {
            let nextItemsByID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            let nextRevisions = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.contentRevision) })
            return (itemByID: nextItemsByID, revisions: nextRevisions)
        }
        itemByID = dictionaries.itemByID
        let nextRevisions = dictionaries.revisions

#if DEBUG
        // Names what woke a real apply(). An idle session should never reach
        // this line; when it does, the trigger identifies the pulse source.
        let trigger = [
            isSessionSwitch ? "sessionSwitch" : nil,
            idsChanged ? "ids" : nil,
            revisionChanged ? "revisions" : nil,
            structuralUpdate ? "structural" : nil,
            streamingUpdate ? "streaming" : nil,
            explicitScroll ? "explicitScroll" : nil
        ].compactMap { $0 }.joined(separator: "+")
        if TranscriptScrollProfiler.verboseTrace {
            TranscriptScrollProfiler.logger.error("apply work — trigger: \(trigger, privacy: .public)")
        }
#endif

        if isSessionSwitch || idsChanged {
            let anchor = (!isSessionSwitch && !explicitScroll && !wasFollowing) ? captureScrollAnchor() : nil
#if DEBUG
            let coldT0 = isSessionSwitch ? CACurrentMediaTime() : 0
            let coldCacheBefore = isSessionSwitch ? cellCache.count : 0
#endif
            if isSessionSwitch {
                pendingHeightIDs.removeAll()
                pendingHeightWork?.cancel()
                pendingHeightWork = nil
                pendingRemeasureWork?.cancel()
                pendingRemeasureWork = nil
                pendingRemeasureIDs.removeAll()
                pendingSessionSwitchSettleWork?.cancel()
                pendingSessionSwitchSettleWork = nil
                sessionSwitchSettleGeneration &+= 1
                // A new session's rows may have completely different
                // construction costs; clear the block list so rows that
                // were too expensive in the previous session get a fresh
                // evaluation.
                prewarmBlockedIDs.removeAll()
            }
            let previousIDs = Set(orderedIDs)
            let removedIDs = previousIDs.subtracting(nextIDs)
            for id in removedIDs {
                // Measured heights and revisions are intentionally NOT dropped
                // here — they persist so a return visit to this session reuses
                // exact heights. Only the transient estimate and any in-flight
                // height work for the now-absent row are cleared.
                estimateByID.removeValue(forKey: id)
                pendingHeightIDs.remove(id)
            }
            // A changed row KEEPS its last measured height — the cell
            // re-renders and reports the new one via onMeasuredHeight.
            // heightOfRow must never drop a measured row back to the rough
            // char-count estimate, or every streaming token would jump the
            // row estimate↔measured (and a short estimate compounds the gap
            // to the bottom until auto-follow disengages). Only the
            // transient estimate is cleared, for never-measured rows.
            for id in nextIDs {
                if contentRevisionByID[id] != nil, contentRevisionByID[id] != nextRevisions[id] {
                    estimateByID.removeValue(forKey: id)
                }
            }
            orderedIDs = nextIDs
            // Release cached cells for rows the transcript no longer has (removed
            // messages, or every row on a session switch) so their views don't
            // linger pinned to absent ids.
            purgeCellCache(keeping: Set(nextIDs))
            for (id, revision) in nextRevisions { contentRevisionByID[id] = revision }
            // In-session row REMOVALS (re-run rewind, visibility toggles)
            // land as a hard cut: rows vanish, content below snaps up, the
            // follow-up rows pop in. Cover that reflow with a brief
            // crossfade. Session switches deliberately do NOT fade: the
            // swap is correct on its first frame (hold-until-loaded +
            // synchronous viewport settle), and an instant swap reads
            // cleaner than a transition — a fade can stall visibly when
            // the switch itself drops frames. Never during streaming.
            if !isSessionSwitch, !streamingUpdate, !removedIDs.isEmpty, let layer = scrollView?.layer {
                let fade = CATransition()
                fade.type = .fade
                fade.duration = 0.28
                fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                layer.add(fade, forKey: "transcript-removal-fade")
            }
            applySnapshot(ids: nextIDs, replacingSession: isSessionSwitch) { [weak self] in
                guard let self else { return }
                // Visible cells whose content changed (same id, new revision) are NOT
                // reconfigured automatically by the diffable data source — it only
                // touches cells whose ids changed. Walk the visible window and
                // reconfigure those whose item revision has shifted.
                self.reconfigureChangedVisibleCells()
                self.restoreScrollAnchorIfNeeded(anchor)
                // Rows were added/removed (or the session switched) — content
                // geometry genuinely moved, so passive follow may act on it.
                self.handleScrollAfterUpdate(isSessionSwitch: isSessionSwitch, explicitScroll: explicitScroll, wasFollowing: wasFollowing, contentAdvanced: true)
#if DEBUG
                if isSessionSwitch {
                    let ms = (CACurrentMediaTime() - coldT0) * 1000
                    let built = self.cellCache.count - coldCacheBefore
                    TranscriptScrollProfiler.fileLog("COLDSTART session=\(self.sessionID?.uuidString.prefix(8) ?? "?") rows=\(self.orderedIDs.count) builtCells=\(built) ms=\(String(format: "%.0f", ms))")
                }
#endif
                // Build off-screen cells during idle so scrolling never pays
                // the per-row construction cost (the dominant scroll hitch).
                self.schedulePrewarm()
            }
        } else {
            let changedIDs = nextIDs.filter { contentRevisionByID[$0] != nextRevisions[$0] }
            for (id, revision) in nextRevisions { contentRevisionByID[id] = revision }
            if !changedIDs.isEmpty {
                // Keep the last measured height (see the idsChanged branch):
                // the cell re-renders and reports the new height, so the
                // streaming row grows real→real with no estimate jump.
                for id in changedIDs {
                    estimateByID.removeValue(forKey: id)
                }
                let changedIDSet = Set(changedIDs)
                // The selected transcript is already paced by the runner; configure
                // each visible changed row in this incoming update rather than
                // delaying it through a second streaming reconfigure timer.
                reconfigureVisibleCellsForIDs(changedIDSet)
                // Re-tile the changed rows synchronously, in this same pass.
                // The cell was just handed taller content; if we wait for the
                // debounced async measurement (~16ms) the row stays tiled at
                // the old, shorter height in the meantime and the host —
                // pinned to the cell — renders the new content squished into
                // the old frame, then snaps when the re-tile lands. That
                // squish→snap every token is the streaming bubble's up/down
                // wobble. Measuring now and routing through the existing
                // noteHeightsChanged keeps the follow/anchor behaviour intact;
                // the later async report sees no height change and no-ops.
                //
                // BUT that forced layout is the dominant cost on screen — a
                // full `layoutSubtreeIfNeeded` of the streaming cell's subtree
                // (nested stacks + hosted SwiftUI islands → sizeThatFits),
                // tens of ms every token, on the main thread. It only earns
                // its keep while pinned to the bottom, where the squish→snap
                // would be visible under the reader. Once auto-follow is off
                // the reader is up in history: the growing bottom row is
                // offscreen or held by the anchor, so the squish is invisible.
                // There we skip the forced measure entirely and let the
                // debounced async path (reportMeasuredHeight → noteHeights
                // changed) re-tile and anchor-compensate ~16ms later — no
                // per-token main-thread storm, which is what hangs/wobbles a
                // not-following stream. `pinnedToBottom` mirrors the
                // `willAutoFollow` test noteHeightsChanged uses below.
                //
                // The forced measure is ALSO restricted to real content
                // publishes (streaming growth / structure changes). Rows can
                // report a new revision with no transcript publish at all —
                // the session-level chrome/context hash (skills, visibility,
                // subagent summary) folds into every row's contentRevision —
                // and apply() can be running inside NSHostingView.layout().
                // Forcing layoutSubtreeIfNeeded there is illegal re-entrancy
                // (_NSDetectedLayoutRecursion). Those rare chrome reconfigures
                // re-tile via the debounced async path instead; only the
                // pinned streaming row needs its height in this same pass.
                let pinnedToBottom = wasFollowing && !isUserScrollingRecently
                    && (streamingUpdate || structuralUpdate)
                if pinnedToBottom {
                    let retileIDs = profiler.measureForced {
                        measureChangedCellsSynchronously(
                            changedIDSet,
                            budgetMs: 4,
                            maxRows: 1,
                            deferUnmeasured: true
                        )
                    }
                    if !retileIDs.isEmpty {
                        flushPendingHeightWorkSynchronously()
                        noteHeightsChanged(forIDs: retileIDs)
                    }
                }
            } else if streamingUpdate || structuralUpdate {
                publishPinnedState(isAutoFollowing)
            }
            handleScrollAfterUpdate(
                isSessionSwitch: false,
                explicitScroll: explicitScroll,
                wasFollowing: wasFollowing,
                contentAdvanced: !changedIDs.isEmpty
            )
        }

        self.sessionID = sessionID
        lastRenderRevision = renderRevision
        lastStreamingRevision = streamingRevision
        lastAutoScrollTurnRevision = autoScrollTurnRevision
        lastBottomScrollRequest = bottomScrollRequest
        tableView.sizeLastColumnToFit()
        updateQuestionRail()
        maybeStartScrollBenchmark()
#if DEBUG
        if isSessionSwitch { buildBenchDone = false; scrollProbeDone = false }
        maybeRunBuildBench()
        maybeRunScrollProbe()
#endif
    }

#if DEBUG
    // Reproduces the user's actual scenario: REAL simulated scrolling (the bench
    // scroll driver scrolls the clip view without the programmatic flag, so the
    // bounds observer treats it as a genuine user scroll) WHILE StreamSim streams.
    // Measures (a) HangWatchdog hitches during the stream+scroll window and (b)
    // viewport drift after the scroll stops (glide-yank check).
    //   defaults write works.earendil.pi-deck StreamScrollTestEnabled -bool YES
    func maybeRunStreamScrollTest() {
        guard !streamScrollTestDone,
              UserDefaults.standard.bool(forKey: "StreamScrollTestEnabled"),
              scrollView != nil, orderedIDs.count > 20 else { return }
        streamScrollTestDone = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, let scrollView = self.scrollView else { return }
            // Scroll UP 600px as a genuine user scroll (no programmatic flag, so
            // the bounds observer registers it and sets isAutoFollowing=false).
            guard let tableView = self.tableView else { return }
            let clip = scrollView.contentView
            let target = max(0, clip.bounds.origin.y - 600)
            clip.scroll(to: NSPoint(x: 0, y: target)); scrollView.reflectScrolledClipView(clip)
            // Record the top-visible ROW + its offset on screen — the true "is the
            // content I'm reading holding still" signal (origin.y alone drifts as
            // the document grows above/below, which is benign).
            let topRow = tableView.row(at: NSPoint(x: 0, y: clip.bounds.origin.y + 4))
            let topID = (topRow >= 0 && topRow < self.orderedIDs.count) ? self.orderedIDs[topRow] : ""
            let topOffset0 = topRow >= 0 ? clip.bounds.origin.y - tableView.rect(ofRow: topRow).minY : 0
            let h0 = HangWatchdog.hitchCount
            HangWatchdog.worstHitchMs = 0
            let upd0 = TranscriptScrollProfiler.bodyCallCount("updateNSView")
            let rev0 = self.lastStreamingRevision
            TranscriptScrollProfiler.fileLog("STREAMSCROLL away topID=\(topID.suffix(6)) following=\(self.isAutoFollowing) — holding 4s while streaming")
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
                guard let self, let tableView = self.tableView, let clip = self.scrollView?.contentView else { return }
                let rowNow = self.orderedIDs.firstIndex(of: topID) ?? -1
                let topOffset1 = rowNow >= 0 ? clip.bounds.origin.y - tableView.rect(ofRow: rowNow).minY : -99999
                let visualShift = Int(topOffset1 - topOffset0)
                let updates = TranscriptScrollProfiler.bodyCallCount("updateNSView") - upd0
                let pulses = self.lastStreamingRevision - rev0
                TranscriptScrollProfiler.fileLog("STREAMSCROLL end updateNSView-calls=\(updates) streamPulsesSeen=\(pulses) hitches=\(HangWatchdog.hitchCount - h0) worstHitch=\(HangWatchdog.worstHitchMs)ms VISUAL-SHIFT=\(visualShift)px")
            }
        }
    }

    /// Deterministic per-session scroll probe: on each session switch, if the
    /// session is big enough to be interesting, wait for pre-warm to settle then
    /// run one scroll pass. The profiler gesture summary (with the rows= finger-
    /// print) captures hitches + hostCreate, so the SAME heavy session can be
    /// compared pre-warm ON vs OFF just by cycling sessions with Cmd-].
    ///   defaults write works.earendil.pi-deck ScrollProbeEnabled -bool YES
    func maybeRunScrollProbe() {
        guard !scrollProbeDone,
              UserDefaults.standard.bool(forKey: "ScrollProbeEnabled"),
              tableView != nil, orderedIDs.count > 25 else { return }
        scrollProbeDone = true
        probeWhenPrewarmed(attempt: 0)
    }

    func probeWhenPrewarmed(attempt: Int) {
        // Wait for the idle pre-warm to drain (ON case) so the probe scrolls a
        // fully-warmed session; OFF case has nothing pending and proceeds. Cap
        // the wait so a stuck queue can't block the probe forever.
        if !Self.prewarmDisabled, (prewarmScheduled || !prewarmQueue.isEmpty), attempt < 30 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.probeWhenPrewarmed(attempt: attempt + 1)
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.orderedIDs.count > 25 else { return }
            self.updateBenchFingerprint()
            self.profiler.setBenchTag("probe")
            self.runScrollPass(duration: 4.0, step: 40) { [weak self] in
                self?.profiler.setBenchTag(nil)
            }
        }
    }
#endif

#if DEBUG
    /// Deterministic construction microbenchmark: build EVERY row's cell of the
    /// current session once (into the cache, off the scroll path) and report
    /// total + worst construction cost. Repeatable on the same restored session,
    /// so it isolates the cell-build fix from scroll/session-order noise.
    ///   defaults write works.earendil.pi-deck BuildBenchEnabled -bool YES
    func maybeRunBuildBench() {
        guard !buildBenchDone,
              UserDefaults.standard.bool(forKey: "BuildBenchEnabled"),
              tableView != nil, orderedIDs.count > 5 else { return }
        buildBenchDone = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in self?.runBuildBench() }
    }

    func runBuildBench() {
        guard let tableView else { return }
        // Drop any cached cells so this measures cold construction of the whole
        // session, not just the rows that haven't been vended yet.
        cellCache.removeAll(); cellCacheLRU.removeAll()
        let ids = orderedIDs
        let t0 = CACurrentMediaTime()
        var total = 0.0
        var built = 0
        for (row, id) in ids.enumerated() {
            guard let item = itemByID[id] else { continue }
            let cell = cachedCell(for: id)
            let s = CACurrentMediaTime()
            configure(cell, with: item, row: row, via: "buildbench")
            total += (CACurrentMediaTime() - s) * 1000
            built += 1
        }
        let wall = (CACurrentMediaTime() - t0) * 1000
        let line = "BUILDBENCH cells=\(built) total=\(String(format: "%.0f", total))ms wall=\(String(format: "%.0f", wall))ms session=\(self.sessionID?.uuidString.prefix(8) ?? "?") rows=\(ids.count)"
        TranscriptScrollProfiler.logger.error("\(line, privacy: .public)")
        TranscriptScrollProfiler.fileLog(line)
        // Force a redisplay so the table isn't left showing stale cached cells.
        tableView.reloadData()
    }
#endif

    // MARK: - Scroll benchmark (multi-session)

    /// Entry point, called at the end of every `apply()`. Arms the run the
    /// first time a content-bearing transcript appears, and — once armed —
    /// drives the per-session continuation after each programmatic advance.
    func maybeStartScrollBenchmark() {
#if DEBUG
        guard UserDefaults.standard.bool(forKey: "ScrollBenchEnabled") else { return }
        guard let tableView else { return }

        if !benchStarted {
            guard tableView.numberOfRows > 5 else { return }   // wait for real content
            benchStarted = true
            benchActive = true
            // Target the scoped session list (not just already-loaded ones —
            // selecting a session lazy-loads its transcript). Empty drafts are
            // skipped at runtime via the row-count guard below; `benchScopedCount`
            // + the advance budget guarantee the sweep terminates after one lap.
            benchScopedCount = benchSessionCount?() ?? 1
            benchTargetSessions = min(benchMaxSessions, max(1, benchScopedCount))
            benchAdvanceBudget = benchScopedCount + benchMaxSessions + 4
            if let id = sessionID { benchSeenIDs.insert(id) }
            // .error so it shows in default console captures — this run drives
            // session switches + programmatic scrolls and MUST be unmissable
            // (an enabled flag once masqueraded as idle-session scroll glitches).
            TranscriptScrollProfiler.logger.error("SCROLLBENCH armed (ScrollBenchEnabled defaults flag) — sweeping up to \(self.benchTargetSessions) of \(self.benchScopedCount) session(s); disable: defaults delete works.earendil.pi-deck ScrollBenchEnabled")
            scheduleSessionRoutine()
            return
        }

        // Continuation: we just advanced and a new transcript settled in.
        guard benchActive, benchPhase == .advancing else { return }
        if let sessionID = self.sessionID { benchSeenIDs.insert(sessionID) }
        if let sessionID = self.sessionID,
           tableView.numberOfRows > 5,
           !benchVisitedSessionIDs.contains(sessionID) {
            scheduleSessionRoutine()
        } else {
            // Empty/draft or already-tested session — skip straight on.
            advanceOrFinish()
        }
#endif
    }

    /// Let the freshly-shown transcript settle (initial auto-scroll + first
    /// measures), then run its short+long routine.
    func scheduleSessionRoutine() {
        benchPhase = .settling
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.runSessionRoutine()
        }
    }

    func runSessionRoutine() {
        guard benchActive, let sessionID = self.sessionID, let tableView else { return }
        benchVisitedSessionIDs.insert(sessionID)
        benchSessionsTested += 1
        let label = "S\(benchSessionsTested)/\(benchTargetSessions):\(sessionID.uuidString.prefix(8))"
        updateBenchFingerprint()
        TranscriptScrollProfiler.logger.error("SCROLLBENCH \(label, privacy: .public) rows=\(tableView.numberOfRows)")

        // Short burst: small local oscillation near current position.
        benchPhase = .shortScroll
        profiler.setBenchTag("\(label) short")
        runScrollPass(duration: benchShortDuration, step: 22) { [weak self] in
            guard let self, self.benchActive else { return }
            // Then several full top↔bottom sweeps back-to-back.
            self.benchPhase = .longScroll
            self.runLongPasses(label: label, remaining: self.benchLongRepeats) { [weak self] in
                self?.profiler.setBenchTag(nil)
                self?.advanceOrFinish()
            }
        }
    }

    /// Run `remaining` full top↔bottom sweeps back-to-back, each its own
    /// profiler gesture, then call `completion`.
    func runLongPasses(label: String, remaining: Int, completion: @escaping @MainActor () -> Void) {
        guard benchActive, remaining > 0 else { completion(); return }
        let idx = benchLongRepeats - remaining + 1
        profiler.setBenchTag("\(label) long \(idx)/\(benchLongRepeats)")
        runScrollPass(duration: benchLongDuration, step: 48) { [weak self] in
            guard let self else { return }
            self.runLongPasses(label: label, remaining: remaining - 1, completion: completion)
        }
    }

    func advanceOrFinish() {
        benchAdvanceBudget -= 1
        let sweptWholeList = benchSeenIDs.count >= benchScopedCount && benchScopedCount > 0
        if benchSessionsTested >= benchTargetSessions || sweptWholeList || benchAdvanceBudget <= 0 {
            benchActive = false
            benchPhase = .idle
            TranscriptScrollProfiler.logger.info("SCROLLBENCH COMPLETE — tested \(self.benchSessionsTested) session(s); see per-gesture summaries above")
            TranscriptScrollProfiler.fileLog("SCROLLBENCH COMPLETE tested=\(benchSessionsTested)")
            return
        }
        benchPhase = .advancing
        // Hand off to SwiftUI; the next session's transcript settles into
        // `apply()`, where `maybeStartScrollBenchmark` resumes the machine.
        onBenchAdvanceSession?()
    }

    /// Drive a programmatic scroll for `duration`, stepping `step` points per
    /// frame at ~120Hz and bouncing at the ends, then call `completion`. The
    /// whole pass is bracketed as one profiler gesture (its bounds changes are
    /// non-programmatic here, so they tick the profiler exactly like a real
    /// scroll, and a full SwiftUI cell layout is forced each frame).
    func runScrollPass(duration: CFTimeInterval, step: CGFloat, completion: @escaping @MainActor () -> Void) {
        guard let scrollView, scrollView.documentView != nil else { completion(); return }
        benchTimer?.invalidate()
        benchStart = CACurrentMediaTime()
        benchDir = -1
        profiler.gestureStart()
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let sv = self.scrollView, let dv = sv.documentView else { return }
                let now = CACurrentMediaTime()
                let clip = sv.contentView
                let maxY = max(0, dv.bounds.height - clip.bounds.height)
                var y = clip.bounds.origin.y + self.benchDir * step
                if y <= 0 { y = 0; self.benchDir = 1 }
                else if y >= maxY { y = maxY; self.benchDir = -1 }
                clip.scroll(to: NSPoint(x: 0, y: y))
                sv.reflectScrolledClipView(clip)
                // Live scroll re-lays-out visible cells each frame; emulate that
                // so the per-frame measure path is exercised, not just a reposition.
                self.tableView?.layoutSubtreeIfNeeded()
                if now - self.benchStart > duration {
                    self.benchTimer?.invalidate()
                    self.benchTimer = nil
                    self.profiler.gestureEnd()
                    completion()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        benchTimer = timer
    }

    /// Feed the profiler a coarse content fingerprint for the current session
    /// so each gesture summary records what was on screen (row count + how many
    /// rows are tall markdown/code) — the "why is *this* chat slow" signal.
    func updateBenchFingerprint() {
        let width = currentViewportWidth()
        var tall = 0
        var totalEst: CGFloat = 0
        for item in items {
            let h = item.estimatedHeight(width)
            totalEst += h
            if h > 200 { tall += 1 }
        }
        profiler.setContentFingerprint(rows: items.count, tallRows: tall, totalEstHeight: totalEst)
    }

    func applySnapshot(
        ids: [String],
        replacingSession: Bool = false,
        completion: @escaping () -> Void
    ) {
        let snapshot = TranscriptScrollProfiler.measurePhase("apply.snapshotBuild") {
            var snapshot = NSDiffableDataSourceSnapshot<PiAgentTranscriptTableSection, String>()
            snapshot.appendSections([.main])
            snapshot.appendItems(ids, toSection: .main)
            return snapshot
        }
        TranscriptScrollProfiler.measurePhase("apply.snapshotSubmit") {
            if replacingSession, let tableView {
                // AppKit does not expose UIKit's
                // `applySnapshotUsingReloadData`. Start a fresh data source
                // instead, so this wholesale session replacement has an empty
                // snapshot baseline rather than diffing unrelated old IDs.
                dataSource = makeDataSource(for: tableView)
                dataSource?.apply(snapshot, animatingDifferences: false, completion: completion)
            } else {
                // Current-session changes stay incremental so their existing
                // visible-cell reconciliation and follow behavior are intact.
                dataSource?.apply(snapshot, animatingDifferences: false, completion: completion)
            }
        }
    }
}
