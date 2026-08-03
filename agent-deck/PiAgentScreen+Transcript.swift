import AppKit
import os
import OSLog
import Combine
import SwiftUI

// MARK: - Transcript items, native payloads, processing bar

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
    func threadBlockCard(
        thread: PiAgentTranscriptThread,
        visibility: PiAgentTranscriptVisibilitySettings,
        skills: [SkillRecord],
        commandSlashNames: Set<String>,
        projectPath: String?,
        subagentRuns: [UUID: PiSubagentRunRecord],
        renderMode: PiAgentTranscriptThreadCard.RenderMode,
        blockID: String
    ) -> some View {
        let viewModel = viewModel
        return PiAgentTranscriptThreadCard(
            thread: thread,
            visibility: visibility,
            skills: skills,
            commandSlashNames: commandSlashNames,
            projectPath: projectPath,
            nativeSubagentRunsByID: subagentRuns,
            nativeSubagentCard: nativeSubagentCard,
            renderMode: renderMode,
            onFork: { entry in viewModel.forkPiAgentSession(from: entry) },
            forkAgentChoices: forkAgentChoicesForSelectedSession,
            onForkAsAgentChat: { entry, agent in
                viewModel.forkPiAgentSessionAsAgentChat(from: entry, agent: agent)
            }
        )
        .id(blockID)
    }

    /// Native payload for a plain-text user question (no attachment chips):
    /// hugged-width right-aligned bubble with leading copy + fork affordance.
    /// Instance method because the fork actions capture `viewModel`.
    /// The fork affordance for a user-question row (Pi session + per-agent chat).
    func questionForkModel(_ question: PiAgentTranscriptEntry) -> ForkModel {
        let agentOptions: [ForkAgentOption] = (forkAgentChoicesForSelectedSession ?? []).map { agent in
            ForkAgentOption(
                title: agent.name,
                isDisabled: agent.resolved.disabled == true,
                action: { [viewModel] in viewModel.forkPiAgentSessionAsAgentChat(from: question, agent: agent) }
            )
        }
        return ForkModel(
            onForkSession: { [viewModel] in viewModel.forkPiAgentSession(from: question) },
            onRerun: { [viewModel] in viewModel.rerunPiAgentSession(from: question) },
            agentOptions: agentOptions
        )
    }

    /// Native render kind for a chip-bearing user question (skill/command/
    /// attachment chips) — the dedicated chip-aware question card.
    func nativeChipQuestionKind(
        _ question: PiAgentTranscriptEntry,
        skills: [SkillRecord],
        commandSlashNames: Set<String>
    ) -> PiAgentTranscriptCellKind {
        // The ForkModel is cheap (it just wraps closures), so build it eagerly.
        // The payload parse (message text + chip extraction regex + folder
        // existence checks) is deferred into the configure closure so it runs only
        // when a cell actually configures — i.e. for visible rows — instead of for
        // every question on every `itemsBuild` pulse.
        let fork = questionForkModel(question)
        let userTitle = viewModel.resolvedUserDisplayName
        let userAvatar = UserAvatarStore.loadImage(fileName: viewModel.appSettings.userAvatarFileName)
        return .native(.of(PiAgentNativeQuestionView.self) { view, width in
            var payload = NativeQuestionPayload.make(
                entry: question, skills: skills, commandSlashNames: commandSlashNames, fork: fork)
            payload.headerTitle = userTitle
            payload.headerAvatarImage = userAvatar
            view.configure(payload: payload, width: width)
        })
    }

    func nativeQuestionKind(
        _ question: PiAgentTranscriptEntry,
        skills: [SkillRecord],
        commandSlashNames: Set<String>,
        showImages: Bool
    ) -> PiAgentTranscriptCellKind {
        let text = PiAgentUserMessageContent.displayMessageText(
            for: question, skills: skills, commandSlashNames: commandSlashNames)
        let fork = questionForkModel(question)
        return .bubble(NativeBubblePayload(
            role: .user,
            headerTitle: viewModel.resolvedUserDisplayName,
            iconSymbol: "person.crop.circle",
            headerAvatarImage: UserAvatarStore.loadImage(fileName: viewModel.appSettings.userAvatarFileName),
            markdownSource: text,
            imageReferences: question.imageReferences,
            showInlineImagePreviews: showImages,
            bodyPrefix: nil,
            copyText: question.text,
            copySide: .leading,
            isThreadChild: false,
            isUserHugged: true,
            fork: fork
        ))
    }

    static func questionNavigationTitle(for entry: PiAgentTranscriptEntry) -> String {
        let collapsed = entry.text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return "User message" }
        return collapsed
    }

    /// Per-block height estimators — character-count math, no SwiftUI pass.
    /// Mirror the heights the old per-thread estimator summed per child.
    static func estimatedQuestionHeight(_ entry: PiAgentTranscriptEntry, width: CGFloat) -> CGFloat {
        let cardWidth = max(width - 32, 200)
        let charsPerLine = max(Int(cardWidth / 7), 20)
        let lines = max(1, (entry.text.count + charsPerLine - 1) / charsPerLine)
        return CGFloat(lines) * 18 + 56
    }

    /// Native render kind for a thread child, or nil to fall back to the hosted
    /// SwiftUI path. Tool groups and subagent/memory status cards stay hosted
    /// (later stages); everything else renders natively.
    /// A native 0-height empty row — the safety fallback now that every descriptor
    /// is native (no `.hosted` path remains).
    private static let nativeEmptyKind: PiAgentTranscriptCellKind =
        .native(.of(PiAgentNativeSpacerView.self) { view, _ in view.spacerHeight = 0 })

#if DEBUG
    private static let nativeToolGroupLog = Logger(subsystem: "works.earendil.pi-deck", category: "NativeToolGroup")
#endif

    func nativeChildKind(
        for child: PiAgentThreadChild,
        visibility: PiAgentTranscriptVisibilitySettings,
        skills: [SkillRecord],
        commandSlashNames: Set<String>,
        subagentRuns: [UUID: PiSubagentRunRecord],
        agentProfilesByName: [String: EffectiveAgentRecord]
    ) -> PiAgentTranscriptCellKind? {
        switch child {
        case .assistant:
            return nativeReplyPayload(for: child, showImages: visibility.showImages).map { .bubble($0) }
        case .thinking:
            return nativeReplyPayload(for: child, showImages: visibility.showImages).map { .bubble($0) }
        case .steering(let entry):
            // Steering messages and structured Ask User answers remain
            // right-aligned user-authored content, but have distinct labels.
            let headerTitle = entry.isNativeAskResponse ? "Answer" : "Steering"
            let headerIcon = entry.isNativeAskResponse
                ? "questionmark.bubble.fill"
                : "arrowshape.turn.up.forward.circle"
            let hasChips = PiAgentUserMessageContent.displayChipsNaturalWidth(
                for: entry, skills: skills, commandSlashNames: commandSlashNames) > 0
            if hasChips {
                var payload = NativeQuestionPayload.make(
                    entry: entry, skills: skills, commandSlashNames: commandSlashNames, fork: nil)
                payload.headerTitle = headerTitle
                payload.headerIcon = headerIcon
                return .native(.of(PiAgentNativeQuestionView.self) { view, width in
                    view.configure(payload: payload, width: width)
                })
            }
            let text = PiAgentUserMessageContent.displayMessageText(
                for: entry, skills: skills, commandSlashNames: commandSlashNames)
            return .bubble(NativeBubblePayload(
                role: .user,
                headerTitle: headerTitle,
                iconSymbol: headerIcon,
                markdownSource: text,
                imageReferences: entry.imageReferences,
                showInlineImagePreviews: visibility.showImages,
                bodyPrefix: nil,
                copyText: entry.text,
                copySide: .leading,
                isThreadChild: false,
                isUserHugged: true
            ))
        case .status(let entry):
            if let recapMarker = LoopRunRecapCodec.decode(from: entry) {
                let payload = NativeLoopRecapPayload.make(entry: entry, marker: recapMarker)
                return .native(.of(PiAgentNativeLoopRecapCardView.self) { view, width in
                    view.configure(payload: payload, width: width)
                })
            }
            if LoopRunTranscriptCodec.decode(from: entry) != nil {
                return Self.nativeEmptyKind
            }
            if let memoryEvent = entry.agentMemoryEvent {
                let payload = NativeMemoryCardPayload.make(event: memoryEvent)
                return .native(.of(PiAgentNativeMemoryCardView.self) { view, width in
                    view.configure(payload: payload, width: width)
                })
            }
            if let runID = entry.nativeSubagentRunID, let run = subagentRuns[runID] {
                if NativeSubagentFactory.isParallel(run) {
                    let payload = NativeSubagentParallelPayload.make(
                        run: run,
                        agentsByName: agentProfilesByName,
                        imageStore: viewModel.agentImageStore,
                        onOpenChildTranscript: { [self] in selectedSubagentTranscriptRunID = $0 },
                        onStopChild: { [viewModel] in viewModel.stopNativeSubagent(runID: $0, parentSessionID: run.parentSessionID) }
                    )
                    return .native(.of(PiAgentNativeSubagentParallelCardView.self) { view, width in
                        view.configure(payload: payload, width: width)
                    })
                }
                let payload = NativeAgentBlockPayload.makeSingle(
                    run: run,
                    agent: agentProfilesByName[run.agentName],
                    imageStore: viewModel.agentImageStore,
                    onStop: { [viewModel] in viewModel.stopNativeSubagent(runID: run.id, parentSessionID: run.parentSessionID) },
                    onTranscript: { [self] in selectedSubagentTranscriptRunID = run.id },
                    onReveal: { [self] in revealSubagentRun(run) }
                )
                return .native(.of(PiAgentNativeSubagentRunCardView.self) { view, width in
                    view.configure(payload: payload, width: width)
                })
            }
            // Soft system notices (extension notify / compaction) — separate muted cards.
            if let notice = NativeSystemNoticePayload.make(for: entry) {
                return .native(.of(PiAgentNativeSystemNoticeView.self) { view, width in
                    view.configure(payload: notice, width: width)
                })
            }
            // "System Prompt Captured" / "Subagent Started" render as a native
            // status row with prompt-audit buttons (computed in make(for:)).
            if entry.isDividerStatus {
                let payload = NativeDividerPayload.make(for: entry)
                return .native(.of(PiAgentNativeStatusDividerView.self) { view, width in
                    view.configure(payload: payload, width: width)
                })
            }
            let payload = NativeStatusPayload.make(for: entry)
            return .native(.of(PiAgentNativeStatusRowView.self) { view, width in
                view.configure(payload: payload, width: width)
            })
        case .error(let entry):
            // Fatal model/provider errors get the richer error row (fixed "Error"
            // headline + full message as the detail body); per-tool failures keep
            // the compact row.
            if entry.isModelError {
                let payload = NativeErrorPayload.make(for: entry)
                return .native(.of(PiAgentNativeErrorRowView.self) { view, width in
                    view.configure(payload: payload, width: width)
                })
            }
            let payload = NativeStatusPayload.make(for: entry)
            return .native(.of(PiAgentNativeStatusRowView.self) { view, width in
                view.configure(payload: payload, width: width)
            })
        case .retry(let entry, let info):
            let payload = NativeRetryPayload.make(info: info, timestamp: entry.timestamp)
            return .native(.of(PiAgentNativeRetryRowView.self) { view, width in
                view.configure(payload: payload, width: width)
            })
        case .toolGroup(let group):
            guard let model = NativeToolGroupModel.make(
                group: group,
                visibility: visibility,
                projectPath: store.selectedSession.map { $0.worktreePath ?? $0.projectPath }
            ) else {
#if DEBUG
                assertionFailure("Visible native tool group produced no display model: \(group.id)")
                Self.nativeToolGroupLog.error("Visible native tool group produced no display model: \(group.id.uuidString)")
#endif
                return Self.nativeEmptyKind
            }
            return .native(.of(PiAgentNativeToolGroupView.self) { view, width in
                view.configure(model: model, width: width)
            })
        }
    }

    /// Maps a thread child to a native bubble payload for the plain-text reply
    /// rows (assistant / thinking). Returns nil for anything that still renders
    /// through the hosted SwiftUI path (subagent summaries, tool groups, status,
    /// errors, retries, steering — handled in later stages).
    func nativeReplyPayload(for child: PiAgentThreadChild, showImages: Bool) -> NativeBubblePayload? {
        switch child {
        case .assistant(let entry):
            let text = TextSanitizer.sanitizeAnswer(entry.text)
            return NativeBubblePayload(
                role: .assistant,
                headerTitle: "Coding Agent",
                iconSymbol: nil,
                markdownSource: text,
                imageReferences: entry.imageReferences,
                showInlineImagePreviews: showImages,
                bodyPrefix: nil,
                copyText: text.trimmingCharacters(in: .whitespacesAndNewlines),
                copySide: .trailing,
                isThreadChild: true
            )
        case .thinking(let entry):
            let display = TextSanitizer.sanitizeThinking(entry.text)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return NativeBubblePayload(
                role: .thinking,
                headerTitle: entry.title,
                iconSymbol: "brain.head.profile",
                markdownSource: display.isEmpty ? "Pi has not emitted reasoning text yet." : display,
                imageReferences: entry.imageReferences,
                showInlineImagePreviews: showImages,
                bodyPrefix: nil,
                copyText: display,
                copySide: .trailing,
                isThreadChild: true
            )
        default:
            return nil
        }
    }

    static func estimatedChildHeight(_ child: PiAgentThreadChild, width: CGFloat, toolGroupModel: NativeToolGroupModel? = nil) -> CGFloat {
        let cardWidth = max(width - 32, 200)
        let charsPerLine = max(Int(cardWidth / 7), 20)
        switch child {
        case let .assistant(entry), let .steering(entry), let .thinking(entry):
            let lines = max(1, (entry.text.count + charsPerLine - 1) / charsPerLine)
            return CGFloat(min(lines, 40)) * 18 + 48
        case .toolGroup:
            // Estimate from the same capped display model the native tool card
            // renders, not from raw activity count. MCP/web/diff groups can contain
            // many underlying updates while displaying only a compact card.
            return toolGroupModel?.estimatedContentHeight(forWidth: width) ?? 1
        case .status, .error, .retry:
            return 56
        }
    }

    /// Content revision for a question block — only that entry + context.
    func appKitQuestionBlockRevision(_ entry: PiAgentTranscriptEntry, contextRevision: Int) -> Int {
        var hasher = Hasher()
        hasher.combine(contextRevision)
        hashEntryRevision(entry, into: &hasher)
        return hasher.finalize()
    }

    /// Content revision for a child block — only that child's entry/entries +
    /// context. A sibling streaming does not bump this, so only the streaming
    /// block's row reconfigures.
    func appKitChildBlockRevision(
        _ child: PiAgentThreadChild,
        contextRevision: Int,
        subagentRuns: [UUID: PiSubagentRunRecord]
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(contextRevision)
        switch child {
        case let .steering(entry), let .thinking(entry), let .assistant(entry),
             let .error(entry):
            hashEntryRevision(entry, into: &hasher)
        case let .status(entry):
            hashEntryRevision(entry, into: &hasher)
            // A status child fronting a Deck agent run renders the whole run
            // record (status, children, durations, results) — fold exactly that
            // run in so ONLY this row re-renders as the run streams. This is the
            // narrow replacement for the all-rows run hash that used to live in
            // the shared context revision above.
            if let runID = entry.nativeSubagentRunID, let run = subagentRuns[runID] {
                hasher.combine(run)
            }
        case let .retry(entry, _):
            hashEntryRevision(entry, into: &hasher)
        case let .toolGroup(group):
            hasher.combine(group.id)
            for entry in group.entries { hashEntryRevision(entry, into: &hasher) }
            for activity in group.activities {
                hasher.combine(activity.id)
                hasher.combine(activity.entries.count)
                hashEntryRevision(activity.representativeEntry, into: &hasher)
            }
        }
        return hasher.finalize()
    }

    func appKitTranscriptChromeRevision(snapshot: PiAgentTranscriptTimelineSnapshot) -> Int {
        var hasher = Hasher()
        hasher.combine(store.selectedSession?.id)
        hasher.combine(String(describing: store.selectedSession?.status))
        hasher.combine(store.isSelectedTranscriptLoading)
        hasher.combine(String(describing: viewModel.appSettings.piAgentTranscriptVisibility))
        hasher.combine(visibleSkillsForSelectedSession.map(\.name))
        hasher.combine(viewModel.appSettings.userDisplayName)
        hasher.combine(viewModel.appSettings.userAvatarFileName)
        return hasher.finalize()
    }

    func appKitTranscriptThreadContextRevision(snapshot: PiAgentTranscriptTimelineSnapshot) -> Int {
        var hasher = Hasher()
        hasher.combine(String(describing: viewModel.appSettings.piAgentTranscriptVisibility))
        hasher.combine(visibleSkillsForSelectedSession.map(\.name))
        hasher.combine(viewModel.displayAgentsRevision)
        hasher.combine(store.selectedSession.map { $0.worktreePath ?? $0.projectPath })
        // Deliberately NO subagent-run state here: this revision folds into EVERY
        // row, and run records update on every subagent event — hashing them here
        // invalidated the whole transcript (full itemsBuild + visible reconfigure)
        // several times a second for the entire run (steady 40-80ms hitches). The
        // one row that renders a run folds its own record in via
        // `appKitChildBlockRevision`; the itemsBuild memo signature still hashes
        // all runs, so the descriptor list itself can never go stale.
        return hasher.finalize()
    }

    func appKitTranscriptContentRevision(
        for item: PiAgentTranscriptTimelineItem,
        snapshot: PiAgentTranscriptTimelineSnapshot,
        contextRevision: Int
    ) -> Int {
        switch item.kind {
        case let .thread(thread):
            let signature = cheapThreadSignature(thread, contextRevision: contextRevision)
            return transcriptCache.cachedThreadRevision(for: thread.id, signature: signature) {
                var hasher = Hasher()
                hasher.combine(contextRevision)
                hashThreadRevision(thread, into: &hasher)
                return hasher.finalize()
            }
        }
    }

    // Cache key for a thread's content revision. Hashes only (id, text.count) per entry —
    // about 3× cheaper than the full revision hash. Covers any mutation upsert/updateEntry
    // can make to a known entry, not just append-only streaming growth, so reusing the
    // cached full hash is safe whenever this signature is unchanged.
    func cheapThreadSignature(
        _ thread: PiAgentTranscriptThread,
        contextRevision: Int
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(contextRevision)
        hasher.combine(thread.id)
        inlineEntrySignature(thread.question, into: &hasher)
        hasher.combine(thread.steeringMessages.count)
        for entry in thread.steeringMessages { inlineEntrySignature(entry, into: &hasher) }
        hasher.combine(thread.thinkingParts.count)
        for entry in thread.thinkingParts { inlineEntrySignature(entry, into: &hasher) }
        hasher.combine(thread.assistantMessages.count)
        for entry in thread.assistantMessages { inlineEntrySignature(entry, into: &hasher) }
        hasher.combine(thread.activities.count)
        for activity in thread.activities {
            hasher.combine(activity.id)
            hasher.combine(activity.entries.count)
            inlineEntrySignature(activity.representativeEntry, into: &hasher)
        }
        hasher.combine(thread.statuses.count)
        for entry in thread.statuses { inlineEntrySignature(entry, into: &hasher) }
        hasher.combine(thread.errors.count)
        for entry in thread.errors { inlineEntrySignature(entry, into: &hasher) }
        return hasher.finalize()
    }

    func inlineEntrySignature(_ entry: PiAgentTranscriptEntry?, into hasher: inout Hasher) {
        guard let entry else { return }
        hasher.combine(entry.id)
        hasher.combine(entry.role)
        hasher.combine(entry.text.count)
        hasher.combine(entry.rawJSON?.count ?? 0)
        hasher.combine(entry.imageReferences)
    }

    func hashThreadRevision(_ thread: PiAgentTranscriptThread, into hasher: inout Hasher) {
        hasher.combine(thread.id)
        hashEntryRevision(thread.question, into: &hasher)
        thread.steeringMessages.forEach { hashEntryRevision($0, into: &hasher) }
        thread.thinkingParts.forEach { hashEntryRevision($0, into: &hasher) }
        thread.assistantMessages.forEach { hashEntryRevision($0, into: &hasher) }
        thread.activities.forEach { activity in
            hasher.combine(activity.id)
            hasher.combine(activity.entries.count)
            hashEntryRevision(activity.representativeEntry, into: &hasher)
        }
        thread.statuses.forEach { hashEntryRevision($0, into: &hasher) }
        thread.errors.forEach { hashEntryRevision($0, into: &hasher) }
    }

    func hashEntryRevision(_ entry: PiAgentTranscriptEntry?, into hasher: inout Hasher) {
        guard let entry else { return }
        hasher.combine(entry.id)
        hasher.combine(entry.role)
        hasher.combine(entry.title)
        hasher.combine(entry.text.count)
        hasher.combine(entry.rawJSON?.count ?? 0)
        hasher.combine(entry.imageReferences)
        hasher.combine(entry.timestamp)
    }


    var loadingTranscriptCard: some View {
        AppRowCard {
            HStack(spacing: 12) {
                AppSpinner()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 4) {
                    Text(LanguageStore.shared.t("agent.loadingTranscript"))
                        .font(AppTheme.Font.headline)
                    Text(LanguageStore.shared.t("agent.loadingTranscriptBody"))
                        .foregroundStyle(AppTheme.mutedText)
                }
                Spacer()
            }
        }
    }

    var emptyTranscriptCard: some View {
        AppRowCard {
            HStack(spacing: 12) {
                Image(systemName: "text.bubble")
                    .font(.title2)
                    .foregroundStyle(AppTheme.mutedText)
                VStack(alignment: .leading, spacing: 4) {
                    Text(LanguageStore.shared.t("agent.noTranscriptTitle"))
                        .font(AppTheme.Font.headline)
                    Text(LanguageStore.shared.t("agent.noTranscriptBody"))
                        .foregroundStyle(AppTheme.mutedText)
                }
                Spacer()
            }
        }
    }

    var transcriptTimelineSnapshot: PiAgentTranscriptTimelineSnapshot {
        let items = transcriptTimelineItems
        let archiveRange = preCompactionArchiveRange(in: items)
        let archiveNotice = archiveRange.flatMap { archive -> (hiddenCount: Int, compactedAt: Date)? in
            archive.visibleStartIndex > 0 ? (archive.visibleStartIndex, archive.compactedAt) : nil
        }
        let visibleItems: [PiAgentTranscriptTimelineItem]
        if !showArchivedPreCompactionTranscript, let archiveRange {
            visibleItems = Array(items[archiveRange.visibleStartIndex...])
        } else {
            visibleItems = items
        }
        let earlierVisibleItems: [PiAgentTranscriptTimelineItem]
        let mainVisibleItems: [PiAgentTranscriptTimelineItem]
        if !showArchivedPreCompactionTranscript && visibleItems.count > recentTranscriptTimelineItemLimit {
            earlierVisibleItems = Array(visibleItems.dropLast(recentTranscriptTimelineItemLimit))
            mainVisibleItems = Array(visibleItems.suffix(recentTranscriptTimelineItemLimit))
        } else {
            earlierVisibleItems = []
            mainVisibleItems = visibleItems
        }
        let recentWindowArchive = earlierVisibleItems.isEmpty
            ? nil
            : (hiddenCount: earlierVisibleItems.count, limit: recentTranscriptTimelineItemLimit)
        return PiAgentTranscriptTimelineSnapshot(
            allItems: items,
            visibleItems: visibleItems,
            mainVisibleItems: mainVisibleItems,
            earlierVisibleItems: earlierVisibleItems,
            preCompactionArchive: archiveNotice,
            recentWindowArchive: recentWindowArchive
        )
    }

    var transcriptTimelineItems: [PiAgentTranscriptTimelineItem] {
        let items = transcriptCache.threads.map { thread in
            PiAgentTranscriptTimelineItem(
                id: "thread-\(thread.id.uuidString)",
                timestamp: thread.timelineTimestamp,
                kind: .thread(thread)
            )
        }
        return items.sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
            return lhs.id < rhs.id
        }
    }

    var visibleTranscriptTimelineItems: [PiAgentTranscriptTimelineItem] {
        transcriptTimelineSnapshot.mainVisibleItems
    }

    var preCompactionArchiveNotice: (hiddenCount: Int, compactedAt: Date)? {
        transcriptTimelineSnapshot.preCompactionArchive
    }

    func preCompactionArchiveRange(in items: [PiAgentTranscriptTimelineItem]) -> (visibleStartIndex: Int, compactedAt: Date)? {
        guard let index = items.indices.last(where: { index in
            guard case let .thread(thread) = items[index].kind else { return false }
            return thread.statuses.contains(where: isCompletedCompactionEntry)
        }) else { return nil }
        return (index, items[index].timestamp)
    }

    func isCompletedCompactionEntry(_ entry: PiAgentTranscriptEntry) -> Bool {
        guard entry.title == "Compaction" else { return false }
        let text = entry.text.localizedLowercase
        return (text.contains("context compacted") || text.contains("compaction complete") || text.contains("compaction finished"))
            && !text.contains("nothing to compact")
            && !text.contains("compacting")
    }

    @ViewBuilder
    func preCompactionArchiveCard(_ archive: (hiddenCount: Int, compactedAt: Date)) -> some View {
        HStack(spacing: 10) {
            Image(systemName: showArchivedPreCompactionTranscript ? "tray.and.arrow.up" : "archivebox")
                .font(AppTheme.Font.caption.weight(.semibold))
                .foregroundStyle(AppTheme.mutedText)
            Text(showArchivedPreCompactionTranscript ? "Showing pre-compaction transcript" : "Pre-compaction transcript hidden")
                .font(AppTheme.Font.caption.weight(.semibold))
            Text("\(archive.hiddenCount) earlier item\(archive.hiddenCount == 1 ? "" : "s") before \(archive.compactedAt.formatted(date: .omitted, time: .shortened))")
                .font(AppTheme.Font.caption)
                .foregroundStyle(AppTheme.mutedText)
            Spacer(minLength: 0)
            Button(showArchivedPreCompactionTranscript ? LanguageStore.shared.t("agent.hide") : LanguageStore.shared.t("agent.loadEarlier")) {
                withAnimation(.snappy(duration: 0.18)) {
                    showArchivedPreCompactionTranscript.toggle()
                }
            }
            .buttonStyle(.borderless)
            .font(AppTheme.Font.caption.weight(.semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: AppTheme.Chat.cardCornerRadius, style: .continuous).fill(AppTheme.contentSubtleFill.opacity(0.8)).stroke(AppTheme.contentStroke, lineWidth: 1))
    }

    @ViewBuilder
    func recentWindowArchiveCard(_ archive: (hiddenCount: Int, limit: Int)) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(AppTheme.Font.caption.weight(.semibold))
                .foregroundStyle(AppTheme.mutedText)
            VStack(alignment: .leading, spacing: 2) {
                Text(LanguageStore.shared.t("agent.earlierHidden"))
                    .font(AppTheme.Font.caption.weight(.semibold))
                Text(LanguageStore.shared.t("agent.showingLatestFmt2", archive.limit, archive.hiddenCount))
                    .font(AppTheme.Font.caption)
                    .foregroundStyle(AppTheme.mutedText)
            }
            Spacer(minLength: 0)
            Button(LanguageStore.shared.t("agent.openEarlier")) {
                isEarlierTranscriptSheetPresented = true
            }
            .buttonStyle(.borderless)
            .font(AppTheme.Font.caption.weight(.semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: AppTheme.Chat.cardCornerRadius, style: .continuous).fill(AppTheme.contentSubtleFill.opacity(0.8)).stroke(AppTheme.contentStroke, lineWidth: 1))
    }

    var earlierTranscriptSheet: some View {
        let snapshot = transcriptTimelineSnapshot
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(LanguageStore.shared.t("agent.earlierTitle"))
                        .font(.title2.bold())
                        .fontWidth(.expanded)
                    Text(LanguageStore.shared.t("agent.earlierBody", recentTranscriptTimelineItemLimit))
                        .foregroundStyle(AppTheme.mutedText)
                }
                Spacer()
                Button(LanguageStore.shared.t("common.done")) {
                    isEarlierTranscriptSheetPresented = false
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(20)

            Divider()

            ScrollView(showsIndicators: false) {
                PiAgentTranscriptStack(alignment: .leading, spacing: 12) {
                    ForEach(snapshot.earlierVisibleItems) { item in
                        transcriptTimelineItemView(item, snapshot: snapshot)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(minWidth: 720, idealWidth: 900, minHeight: 520, idealHeight: 720)
        .background(AppTheme.windowBackground)
    }

    @ViewBuilder
    func transcriptTimelineItemView(_ item: PiAgentTranscriptTimelineItem, snapshot: PiAgentTranscriptTimelineSnapshot) -> some View {
        switch item.kind {
        case let .thread(thread):
            PiAgentTranscriptThreadCard(
                thread: thread,
                visibility: viewModel.appSettings.piAgentTranscriptVisibility,
                skills: visibleSkillsForSelectedSession,
                commandSlashNames: Set((store.selectedSession?.commandInvocations ?? []).map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 }),
                projectPath: store.selectedSession.map { $0.worktreePath ?? $0.projectPath },
                nativeSubagentRunsByID: nativeSubagentRunsByID,
                nativeSubagentCard: nativeSubagentCard
            )
            .id(item.id)
        }
    }

    func updateStabilizedProcessingMessage(_ message: String?) {
        processingMessageUpdateTask?.cancel()
        processingMessageUpdateTask = nil

        guard let message else {
            stabilizedProcessingMessage = nil
            return
        }

        guard stabilizedProcessingMessage != nil else {
            stabilizedProcessingMessage = message
            return
        }

        processingMessageUpdateTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            stabilizedProcessingMessage = message
            processingMessageUpdateTask = nil
        }
    }

    var selectedSessionProcessingMessage: String? {
        guard let session = store.selectedSession,
              session.status.isActive,
              store.selectedUIRequest == nil else { return nil }

        if session.status == .starting { return "Starting Pi" }
        if session.isCompacting { return "Compacting context" }
        if let subagentMessage = runningSubagentsProcessingMessage(for: session) {
            return subagentMessage
        }

        // The RPC-derived activity knows exactly what Pi is doing this instant —
        // it distinguishes a running tool from a finished one and reasoning from
        // an empty turn-start placeholder, neither of which the transcript can.
        if let activity = store.processingActivity(for: session.id) {
            return processingMessage(for: activity)
        }

        // Fallback for a session that is active but has no live activity yet
        // (e.g. just reattached): infer from the last transcript entry.
        if let lastEntry = store.selectedTranscript.last {
            return processingMessage(after: lastEntry)
        }
        return "Working"
    }

    func processingMessage(for activity: PiAgentProcessingActivity) -> String {
        switch activity {
        case .preparing: return "Preparing response"
        case .reasoning: return "Reasoning"
        case .responding: return "Writing response"
        case let .runningTool(toolName, detail): return toolProcessingMessage(forToolName: toolName, detail: detail)
        case .awaitingModel: return "Working"
        case let .applyingConfigurationChange(summary): return "Changing \(summary)"
        }
    }

    func processingMessage(after entry: PiAgentTranscriptEntry) -> String? {
        switch entry.role {
        case .assistant:
            return entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Preparing response" : "Writing response"
        case .error, .stderr:
            return "Working"
        case .tool:
            if entry.text.localizedCaseInsensitiveContains("waiting for user input") { return nil }
            return toolProcessingMessage(for: entry)
        case .status:
            return statusProcessingMessage(for: entry)
        case .user:
            switch entry.title {
            case "Steering": return "Applying your steering"
            case "Queued follow-up": return "Queued follow-up"
            default: return "Processing your message"
            }
        case .thinking:
            return "Reasoning"
        case .raw:
            return "Working"
        }
    }

    func statusProcessingMessage(for entry: PiAgentTranscriptEntry) -> String? {
        // Soft system-notice cards (notify / setStatus / setWidget / compaction)
        // are terminal chrome, not an in-flight turn — never keep the processing bar.
        if entry.isSystemNoticeStatus { return nil }
        switch entry.title {
        case "Input Sent": return "Processing your response"
        case "Input Needed": return nil
        case "Retry": return "Retrying request"
        case "Compaction": return "Compacting context"
        case "Deck Agent Requested": return "Starting Deck agent"
        case "Parallel Deck Agents Requested": return "Starting parallel run"
        case "Supervisor Response Routed": return "Routing response"
        case "System Prompt Captured": return "Preparing context"
        case "Process Ended", "Stopped": return nil
        case "Notify", "Notify Warning", "Notify Error",
             "Extension Status", "Extension Widget":
            return nil
        default: return "Processing update"
        }
    }

    func toolProcessingMessage(for entry: PiAgentTranscriptEntry) -> String {
        let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.hasPrefix("Tool:") else { return "Running tool" }
        let toolName = title.dropFirst("Tool:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = mcpToolAddress(from: entry.rawJSON)
        return toolProcessingMessage(forToolName: toolName, detail: detail)
    }

    /// Resolves the `server/tool` address from an MCP proxy entry's raw JSON,
    /// so the live status row can say "Running MCP xcode/ListWindows" instead of
    /// the generic "Running mcp".
    func mcpToolAddress(from rawJSON: String?) -> String? {
        guard let event = PiAgentRPCEventRenderCache.event(from: rawJSON),
              let args = event.args,
              let rawTool = args["tool"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawTool.isEmpty,
              let address = MCPConnectionManager.resolveAddress(rawTool, serverHint: args["server"]?.stringValue)
        else { return nil }
        return "\(address.server)/\(address.tool)"
    }

    /// Turns a raw Pi tool name (and, when available, its target) into a
    /// human phrase: `edit` + `PiAgentViews.swift` → "Editing PiAgentViews.swift".
    /// Unknown tools fall back to their de-underscored name so a new Pi tool
    /// still reads acceptably without a code change.
    func toolProcessingMessage(forToolName toolName: String, detail: String? = nil) -> String {
        let name = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDetail = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = (trimmedDetail?.isEmpty == false) ? trimmedDetail : nil
        switch name {
        case "bash": return target.map { "Running \($0)" } ?? "Running a command"
        case "read": return target.map { "Reading \($0)" } ?? "Reading a file"
        case "edit": return target.map { "Editing \($0)" } ?? "Editing a file"
        case "write": return target.map { "Writing \($0)" } ?? "Writing a file"
        case "web_search": return target.map { "Searching the web for \($0)" } ?? "Searching the web"
        case "code_search": return target.map { "Searching the code for \($0)" } ?? "Searching the code"
        case "get_search_content", "fetch_content": return "Fetching a page"
        case "update_session_plan", "set_session_plan": return "Updating the plan"
        case "managed_subagent": return "Starting Deck agent"
        case "managed_parallel": return "Starting parallel agents"
        case "ask_user": return "Waiting for your input"
        case "agent_deck_memory_write", "agent_deck_memory_mark_stale": return "Updating memory"
        case "list_supervisor_requests", "answer_supervisor_request": return "Coordinating Deck agents"
        case "mcp": return target.map { "Running MCP \($0)" } ?? "Running MCP tool"
        case "": return "Running tool"
        default: return "Running \(name.replacingOccurrences(of: "_", with: " "))"
        }
    }

    func runningSubagentsProcessingMessage(for session: PiAgentSessionRecord) -> String? {
        let agentNames = runningSubagentNames(for: session)
        guard !agentNames.isEmpty else { return nil }
        let prefix = agentNames.count == 1 ? "Running agent" : "Running agents"
        return "\(prefix): \(formattedRunningAgentList(agentNames))"
    }

    func runningSubagentNames(for session: PiAgentSessionRecord) -> [String] {
        var names: [String] = []
        for run in store.subagentRuns(for: session.id) where run.status.isActive {
            if run.mode == .parallel, let children = run.children, !children.isEmpty {
                names.append(contentsOf: children
                    .filter { $0.status.isActive }
                    .sorted { $0.index < $1.index }
                    .map(\.agentName))
            } else if let child = run.child, child.status.isActive {
                names.append(child.agentName)
            } else {
                names.append(run.agentName)
            }
        }
        return names.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    func formattedRunningAgentList(_ names: [String]) -> String {
        let uniqueNames = names.reduce(into: [String]()) { result, name in
            if !result.contains(name) { result.append(name) }
        }
        guard uniqueNames.count > 3 else { return uniqueNames.joined(separator: ", ") }
        return uniqueNames.prefix(3).joined(separator: ", ") + " +\(uniqueNames.count - 3) more"
    }

    func scheduleTranscriptCacheUpdate() {
        guard let session = store.selectedSession else {
            transcriptCache.scheduleUpdate(sessionID: nil, revision: 0, rawEntries: [])
            return
        }

        // Hydrate the selected transcript before updating the render cache. Small
        // transcripts decode synchronously here (instant, no spinner); large ones are
        // handed to the background loader and return an empty snapshot so the
        // "Loading transcript" card shows instead of hitching the main thread.
        let entries = store.transcriptForCacheUpdate(session.id)
        transcriptCache.scheduleUpdate(
            sessionID: session.id,
            revision: store.selectedTranscriptRevision,
            rawEntries: entries
        )
    }

    func requestSelectedTranscriptLoadAfterViewUpdate(for sessionID: UUID?) {
        Task { @MainActor in
            await Task.yield()
            // A newer selection may have arrived while this view update settled.
            // Never hydrate or publish for an obsolete session.
            guard store.selectedSession?.id == sessionID else { return }
            store.requestSelectedTranscriptLoad()
            scheduleTranscriptCacheUpdate()
            viewModel.rehydratePiAgentTranscriptIfNeeded(sessionID)
        }
    }

    func requestSubagentTranscriptLoadAfterViewUpdate(runID: UUID) {
        Task { @MainActor in
            await Task.yield()
            store.requestSubagentTranscriptLoad(for: runID)
        }
    }

    func resetTranscriptAutoScroll() {
        if !transcriptPinnedState.isPinned {
            transcriptPinnedState.isPinned = true
        }
    }

    func beginTranscriptAutoScrollTurn() {
        resetTranscriptAutoScroll()
    }

    func requestTranscriptBottomScroll() {
        transcriptBottomScrollRequest &+= 1
    }

}
