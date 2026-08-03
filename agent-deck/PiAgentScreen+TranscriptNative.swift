import AppKit
import os
import OSLog
import SwiftUI

// MARK: - Native cell kinds, payloads, revision hashing

extension PiAgentScreen {
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
    static let nativeEmptyKind: PiAgentTranscriptCellKind =
        .native(.of(PiAgentNativeSpacerView.self) { view, _ in view.spacerHeight = 0 })

#if DEBUG
    static let nativeToolGroupLog = Logger(subsystem: "works.earendil.pi-deck", category: "NativeToolGroup")
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
}
