import AppKit
import SwiftUI

// MARK: - Timeline chrome, processing bar, scroll/cache

extension PiAgentScreen {
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
