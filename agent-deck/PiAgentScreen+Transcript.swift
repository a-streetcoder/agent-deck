import AppKit
import Combine
import os
import OSLog
import SwiftUI

// MARK: - AppKit transcript item assembly

extension PiAgentScreen {
    var appKitTranscriptItems: [PiAgentAppKitTranscriptItem] {
        // Hidden tab: don't rebuild on streaming pulses. The screen stays mounted
        // (so the table is never torn down), but returning the last-built rows means
        // a backgrounded streaming session does no per-tick transcript work. The
        // next pulse after becoming active rebuilds to current content.
        if !isActive { return transcriptCache.memoizedTranscriptItems }
        return TranscriptScrollProfiler.measureBody("itemsBuild") {
            // `makeItems` is re-run on every host body pass — cache pulses, but also
            // scroll-time re-evaluations that don't change the transcript at all.
            // Skip the O(N) rebuild when no input changed: compute a cheap signature
            // and reuse the last array on a match. The signature reads every input the
            // build does, so it can never serve stale content.
            let signature = appKitTranscriptItemsSignature
            if transcriptCache.memoizedTranscriptItemsSignature == signature {
                return transcriptCache.memoizedTranscriptItems
            }
#if DEBUG
            debugLogItemsBuildTrigger()
#endif
            let items = appKitTranscriptItemsBuild
            transcriptCache.memoizedTranscriptItems = items
            transcriptCache.memoizedTranscriptItemsSignature = signature
            return items
        }
    }

    /// COMPLETE signature of every input `appKitTranscriptItemsBuild` reads.
    /// `renderRevision`/`streamingRevision` cover all transcript content (threads).
    /// `appKitTranscript{Chrome,ThreadContext}Revision` are the SAME hashes the build
    /// folds into each row's `contentRevision`, so reusing them here captures the
    /// session-level inputs (status, worktree/project, loading, visibility, skills,
    /// subagent summary) without re-listing them — and can't drift if those helpers
    /// gain a read. The tail adds the few inputs those revisions don't cover.
    var appKitTranscriptItemsSignature: Int {
        let snapshot = transcriptTimelineSnapshot
        var hasher = Hasher()
        hasher.combine(transcriptCache.renderRevision)
        hasher.combine(transcriptCache.streamingRevision)
        hasher.combine(appKitTranscriptChromeRevision(snapshot: snapshot))
        hasher.combine(appKitTranscriptThreadContextRevision(snapshot: snapshot))
        hasher.combine(showArchivedPreCompactionTranscript)
        if let session = store.selectedSession {
            hasher.combine(viewModel.displayAgentsRevision)
            hasher.combine(session.commandInvocations)         // slash-command chrome
            hasher.combine(session.forkedFromParentTitle)      // fork-origin card
            hasher.combine(session.forkedFromSessionID)
            hasher.combine(session.forkedFromTranscriptSnapshot)
            // Full run/request records can be large (nested child records, output,
            // timestamps). Hashing them on every SwiftUI body pass showed up in
            // itemsBuild hitch stacks. The store revisions are bumped on every
            // mutation, so they keep descriptor memoization correct without the
            // per-pass deep Hashable walk.
            hasher.combine(store.subagentRunsRevision)
            hasher.combine(store.supervisorRequestsRevision)
        }
        return hasher.finalize()
    }

#if DEBUG
    /// Names which memo input invalidated `appKitTranscriptItems` — the labels
    /// mirror `appKitTranscriptItemsSignature` (with the chrome/context hashes
    /// split into their fields) so an unexplained rebuild on an idle session can
    /// be attributed straight from the console. Runs only on a memo miss.
    func debugLogItemsBuildTrigger() {
        var components: [String: Int] = [
            "render": transcriptCache.renderRevision,
            "streaming": transcriptCache.streamingRevision,
            "archived": showArchivedPreCompactionTranscript ? 1 : 0,
            "visibility": String(describing: viewModel.appSettings.piAgentTranscriptVisibility).hashValue,
            "skills": visibleSkillsForSelectedSession.map(\.name).hashValue,
            "agents": viewModel.displayAgentsRevision,
            "userProfile": viewModel.appSettings.userDisplayName.hashValue ^ (viewModel.appSettings.userAvatarFileName?.hashValue ?? 0)
        ]
        if let session = store.selectedSession {
            components["sessionID"] = session.id.hashValue
            components["status"] = String(describing: session.status).hashValue
            components["loading"] = store.isSelectedTranscriptLoading ? 1 : 0
            components["path"] = (session.worktreePath ?? session.projectPath).hashValue
            components["command"] = session.commandInvocations.hashValue
            var forkHasher = Hasher()
            forkHasher.combine(session.forkedFromParentTitle)
            forkHasher.combine(session.forkedFromSessionID)
            forkHasher.combine(session.forkedFromTranscriptSnapshot)
            components["fork"] = forkHasher.finalize()
            components["runs"] = store.subagentRunsRevision
            components["requests"] = store.supervisorRequestsRevision
        }
        let previous = transcriptCache.lastItemsBuildComponents
        transcriptCache.lastItemsBuildComponents = components
        guard !previous.isEmpty else { return }
        let changed = Set(components.keys).union(previous.keys).filter { components[$0] != previous[$0] }.sorted()
        guard !changed.isEmpty else { return }
        guard TranscriptScrollProfiler.verboseTrace else { return }
        TranscriptScrollProfiler.logger.error("itemsBuild trigger — changed inputs: \(changed.joined(separator: ","), privacy: .public)")
    }
#endif

    var appKitTranscriptItemsBuild: [PiAgentAppKitTranscriptItem] {
        let timelineSnapshot = transcriptTimelineSnapshot
        let timelineItems = timelineSnapshot.mainVisibleItems
        let chromeRevision = appKitTranscriptChromeRevision(snapshot: timelineSnapshot)
        let contextRevision = appKitTranscriptThreadContextRevision(snapshot: timelineSnapshot)
        let visibility = viewModel.appSettings.piAgentTranscriptVisibility
        let skills = visibleSkillsForSelectedSession
        let commandSlashNames = Set((store.selectedSession?.commandInvocations ?? []).map { name in
            name.hasPrefix("/") ? String(name.dropFirst()) : name
        })
        let subagentRuns = nativeSubagentRunsByID
        var agentProfilesByName: [String: EffectiveAgentRecord] = [:]
        for agent in viewModel.cachedAllDisplayAgents {
            agentProfilesByName[agent.name] = agent
        }
        if let session = store.selectedSession {
            for agent in viewModel.catalogAgents(for: session) {
                agentProfilesByName[agent.name] = agent
            }
        }

        var descriptors: [PiAgentTranscriptBlockDescriptor] = []
        // Block ids whose render kind we memoize this pass (the per-N timeline
        // rows). Used to prune the kind cache to the visible transcript below.
        var memoizedBlockIDs: Set<String> = []

        // --- Chrome rows (each its own revision) ---
        if let session = store.selectedSession {
            if visibility.showShortcutsStrip {
                descriptors.append(PiAgentTranscriptBlockDescriptor(
                    id: "shortcuts-strip-\(session.id.uuidString)",
                    view: nil,
                    kind: .native(.of(PiAgentNativeShortcutsStripView.self) { view, width in view.configure(width: width) }),
                    baseRevision: 0,
                    estimatedContentHeight: { _ in 40 },
                    threadID: nil,
                    isThreadQuestion: false
                ))
            }
            if let parentTitle = session.forkedFromParentTitle, !parentTitle.isEmpty {
                let parentID = session.forkedFromSessionID
                let snapshot = session.forkedFromTranscriptSnapshot
                let onSelect: (UUID) -> Void = { parentSessionID in
                    viewModel.selectPiAgentSession(parentSessionID)
                }
                var hasher = Hasher()
                hasher.combine(parentTitle)
                hasher.combine(parentID)
                hasher.combine(snapshot)
                let forkPayload = NativeForkOriginPayload.make(
                    parentTitle: parentTitle, parentSessionID: parentID,
                    transcriptSnapshot: snapshot, onSelectParent: onSelect)
                descriptors.append(PiAgentTranscriptBlockDescriptor(
                    id: "fork-origin-\(session.id.uuidString)",
                    view: nil,
                    kind: .native(.of(PiAgentNativeForkOriginCardView.self) { view, width in
                        view.configure(payload: forkPayload, width: width)
                    }),
                    baseRevision: hasher.finalize(),
                    estimatedContentHeight: { _ in 70 },
                    threadID: nil,
                    isThreadQuestion: false
                ))
            }
            // The final system prompt is no longer a transcript card — it's a
            // toolbar button (next to Plan / Session Resources / Transcript Display)
            // that opens the same text popover. See `piAgentPrimaryToolbarContent`.
        }

        if let archive = timelineSnapshot.preCompactionArchive {
            var hasher = Hasher()
            hasher.combine(archive.hiddenCount)
            hasher.combine(archive.compactedAt)
            let isShowing = showArchivedPreCompactionTranscript
            let archivePayload = NativeArchiveNoticePayload.preCompaction(
                hiddenCount: archive.hiddenCount, compactedAt: archive.compactedAt,
                isShowing: isShowing, onToggle: { showArchivedPreCompactionTranscript.toggle() })
            hasher.combine(isShowing)
            descriptors.append(PiAgentTranscriptBlockDescriptor(
                id: "pre-compaction-archive",
                view: nil,
                kind: .native(.of(PiAgentNativeArchiveNoticeView.self) { view, width in
                    view.configure(payload: archivePayload, width: width)
                }),
                baseRevision: hasher.finalize(),
                estimatedContentHeight: { _ in 60 },
                threadID: nil,
                isThreadQuestion: false
            ))
        }
        if let archive = timelineSnapshot.recentWindowArchive {
            var hasher = Hasher()
            hasher.combine(archive.hiddenCount)
            hasher.combine(archive.limit)
            let recentPayload = NativeArchiveNoticePayload.recentWindow(
                hiddenCount: archive.hiddenCount, limit: archive.limit,
                onOpen: { isEarlierTranscriptSheetPresented = true })
            descriptors.append(PiAgentTranscriptBlockDescriptor(
                id: "recent-window-archive",
                view: nil,
                kind: .native(.of(PiAgentNativeArchiveNoticeView.self) { view, width in
                    view.configure(payload: recentPayload, width: width)
                }),
                baseRevision: hasher.finalize(),
                estimatedContentHeight: { _ in 60 },
                threadID: nil,
                isThreadQuestion: false
            ))
        }

        // --- Timeline rows: each thread flattens into one row per block ---
        if store.isSelectedTranscriptLoading && timelineItems.isEmpty {
            descriptors.append(PiAgentTranscriptBlockDescriptor(
                id: "pi-agent-transcript-state-card",
                view: nil,
                kind: .native(.of(PiAgentNativeStateCardView.self) { view, width in
                    view.configure(payload: .loading(), width: width)
                }),
                baseRevision: chromeRevision,
                estimatedContentHeight: { _ in 80 },
                threadID: nil,
                isThreadQuestion: false
            ))
        } else if timelineItems.isEmpty && descriptors.isEmpty {
            descriptors.append(PiAgentTranscriptBlockDescriptor(
                id: "pi-agent-transcript-state-card",
                view: nil,
                kind: .native(.of(PiAgentNativeStateCardView.self) { view, width in
                    view.configure(payload: .empty(), width: width)
                }),
                baseRevision: chromeRevision,
                estimatedContentHeight: { _ in 120 },
                threadID: nil,
                isThreadQuestion: false
            ))
        } else {
            for item in timelineItems {
                switch item.kind {
                case let .thread(thread):
                    if let question = thread.question {
                        let blockID = "q-\(item.id)"
                        let revision = appKitQuestionBlockRevision(question, contextRevision: contextRevision)
                        memoizedBlockIDs.insert(blockID)
                        // Native fast path for plain-text questions (no attachment
                        // Chip-bearing questions use the dedicated chip-aware card;
                        // plain questions use the lighter bubble.
                        let questionKind = transcriptCache.cachedBlockKind(id: blockID, revision: revision) {
                            let hasChips = PiAgentUserMessageContent.displayChipsNaturalWidth(
                                for: question, skills: skills, commandSlashNames: commandSlashNames) > 0
                            return hasChips
                                ? nativeChipQuestionKind(question, skills: skills, commandSlashNames: commandSlashNames)
                                : nativeQuestionKind(question, skills: skills, commandSlashNames: commandSlashNames, showImages: visibility.showImages)
                        }
                        descriptors.append(PiAgentTranscriptBlockDescriptor(
                            id: blockID,
                            view: nil,
                            kind: questionKind,
                            baseRevision: revision,
                            estimatedContentHeight: { Self.estimatedQuestionHeight(question, width: $0) },
                            threadID: item.id,
                            questionNavigationTitle: Self.questionNavigationTitle(for: question),
                            isThreadQuestion: true
                        ))
                    }
                    let projectPath = store.selectedSession.map { $0.worktreePath ?? $0.projectPath }
                    for child in PiAgentTranscriptThreadCard.visibleChildren(
                        of: thread, visibility: visibility, nativeSubagentRunsByID: subagentRuns,
                        projectPath: projectPath
                    ) {
                        // Native rendering for the supported child types; the
                        // rest (tool groups, subagent/memory cards) still hosted.
                        let revision = appKitChildBlockRevision(child, contextRevision: contextRevision, subagentRuns: subagentRuns)
                        let toolGroupEstimateModel: NativeToolGroupModel? = {
                            guard case let .toolGroup(group) = child else { return nil }
                            return NativeToolGroupModel.make(group: group, visibility: visibility, projectPath: projectPath)
                        }()
                        memoizedBlockIDs.insert(child.id)
                        let nativeKind = transcriptCache.cachedBlockKind(id: child.id, revision: revision) {
                            nativeChildKind(
                                for: child, visibility: visibility, skills: skills,
                                commandSlashNames: commandSlashNames,
                                subagentRuns: subagentRuns,
                                agentProfilesByName: agentProfilesByName
                            ) ?? Self.nativeEmptyKind
                        }
                        descriptors.append(PiAgentTranscriptBlockDescriptor(
                            id: child.id,
                            view: nil,
                            kind: nativeKind,
                            baseRevision: revision,
                            estimatedContentHeight: { Self.estimatedChildHeight(child, width: $0, toolGroupModel: toolGroupEstimateModel) },
                            threadID: item.id,
                            isThreadQuestion: false
                        ))
                    }
                }
            }
        }

        // Bottom anchor — a 1pt row scrollToBottom can always land on.
        descriptors.append(PiAgentTranscriptBlockDescriptor(
            id: "pi-agent-bottom-anchor",
            view: nil,
            kind: .native(.of(PiAgentNativeSpacerView.self) { _, _ in }),
            baseRevision: 0,
            estimatedContentHeight: { _ in 1 },
            threadID: nil,
            isThreadQuestion: false
        ))

        // --- Inset pass: NSTableView intercell spacing is uniform, so split
        // each inter-row gap in half across the two adjacent rows. Gaps come from
        // the design system: question↔reply (threadSpacing), sibling children
        // (childSpacing), everything else (rowSpacing). ---
        if descriptors.count > 1 {
            for i in 0 ..< descriptors.count - 1 {
                let gap: CGFloat
                if let tid = descriptors[i].threadID, tid == descriptors[i + 1].threadID {
                    gap = descriptors[i].isThreadQuestion ? AppTheme.Chat.threadSpacing : AppTheme.Chat.childSpacing
                } else {
                    gap = AppTheme.Chat.rowSpacing
                }
                descriptors[i].bottomInset += gap / 2
                descriptors[i + 1].topInset += gap / 2
            }
        }

        // Match the old NSScrollView top inset as an actual row so new/small
        // transcripts do not start inside the SwiftUI top fade before scrolling.
        // Insert after the inter-row gap pass so this adds exactly 18pt and no
        // extra row spacing before the shortcuts/first message.
        descriptors.insert(PiAgentTranscriptBlockDescriptor(
            id: "pi-agent-top-fade-spacer",
            view: nil,
            kind: .native(.of(PiAgentNativeSpacerView.self) { view, _ in view.spacerHeight = 18 }),
            baseRevision: 0,
            estimatedContentHeight: { _ in 18 },
            threadID: nil,
            isThreadQuestion: false
        ), at: 0)

        transcriptCache.pruneBlockKindCache(keeping: memoizedBlockIDs)

        // --- Materialize: fold insets into the revision (so an inset change
        // re-tiles the row) and into the height estimate. ---
        return descriptors.map { descriptor in
            var revisionHasher = Hasher()
            revisionHasher.combine(descriptor.baseRevision)
            revisionHasher.combine(descriptor.topInset)
            revisionHasher.combine(descriptor.bottomInset)
            let topInset = descriptor.topInset
            let bottomInset = descriptor.bottomInset
            let contentEstimate = descriptor.estimatedContentHeight
            let kind = descriptor.kind ?? Self.nativeEmptyKind
            return PiAgentAppKitTranscriptItem(
                id: descriptor.id,
                kind: kind,
                contentRevision: revisionHasher.finalize(),
                questionNavigationTitle: descriptor.questionNavigationTitle,
                topInset: topInset,
                bottomInset: bottomInset,
                estimatedHeight: { width in contentEstimate(width) + topInset + bottomInset }
            )
        }
    }

    /// Builds one block of a thread (question or a single child) as its own
    /// row view, via `PiAgentTranscriptThreadCard`'s `renderMode` — the card
    /// view is byte-identical to the full-thread rendering, just sliced to one
    /// `ThreadMessageRow`.
}
