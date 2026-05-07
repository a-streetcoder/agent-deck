import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers


let piAgentLeakedToolNames: Set<String> = ["bash", "read", "edit", "write", "find", "grep", "subagent", "web_search", "fetch_content", "code_search"]

@MainActor
enum PiAgentRPCEventRenderCache {
    private static var cache: [String: PiAgentRPCEvent] = [:]
    private static var order: [String] = []
    private static let limit = 512

    static func event(from rawJSON: String?) -> PiAgentRPCEvent? {
        guard let rawJSON else { return nil }
        if let cached = cache[rawJSON] { return cached }
        guard let data = rawJSON.data(using: .utf8),
              let event = try? JSONDecoder().decode(PiAgentRPCEvent.self, from: data) else {
            return nil
        }
        cache[rawJSON] = event
        order.append(rawJSON)
        if order.count > limit {
            let overflow = order.count - limit
            for oldKey in order.prefix(overflow) {
                cache[oldKey] = nil
            }
            order.removeFirst(overflow)
        }
        return event
    }
}
@MainActor
final class PiAgentTranscriptRenderCache: ObservableObject {
    @Published private(set) var entries: [PiAgentTranscriptEntry] = []
    @Published private(set) var threads: [PiAgentTranscriptThread] = []
    @Published private(set) var renderRevision = 0
    @Published private(set) var streamingRevision = 0
    @Published private(set) var lastThreadID: UUID?

    private var updateTask: Task<Void, Never>?
    private var lastSessionID: UUID?
    private var lastRevision = -1
    private var lastThreadSignature: [UUID] = []

    func scheduleUpdate(sessionID: UUID?, revision: Int, rawEntries: [PiAgentTranscriptEntry]) {
        guard let sessionID else {
            updateTask?.cancel()
            entries = []
            threads = []
            lastThreadID = nil
            lastSessionID = nil
            lastRevision = -1
            lastThreadSignature = []
            renderRevision += 1
            return
        }
        guard sessionID != lastSessionID || revision != lastRevision else { return }
        lastSessionID = sessionID
        lastRevision = revision
        updateTask?.cancel()
        updateTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 33_000_000)
            guard !Task.isCancelled else { return }
            self?.publish(rawEntries)
        }
    }

    private func publish(_ rawEntries: [PiAgentTranscriptEntry]) {
        let normalized = normalizeThinkingOrder(
            coalescedCompactionEntries(
                rawEntries.compactMap(normalizedTranscriptEntry).filter(isValuableTranscriptEntry)
            )
        )
        let nextThreads = PiAgentTranscriptThread.make(from: normalized)
        let signature = nextThreads.map(\.id)
        let structurallyChanged = signature != lastThreadSignature
        entries = normalized
        threads = nextThreads
        lastThreadID = nextThreads.last?.id
        lastThreadSignature = signature
        if structurallyChanged {
            renderRevision += 1
        } else {
            streamingRevision += 1
        }
    }

    private enum AssistantContentInterpretation {
        case assistant(String)
        case thinking(String)
        case drop
    }

    private func normalizedTranscriptEntry(_ entry: PiAgentTranscriptEntry) -> PiAgentTranscriptEntry? {
        var copy = entry
        if copy.role == .assistant {
            if let interpretation = assistantContentInterpretation(fromRawJSON: copy.rawJSON) {
                switch interpretation {
                case let .assistant(text):
                    copy.text = sanitizedAssistantText(text)
                case let .thinking(text):
                    copy.role = .thinking
                    copy.title = "Thinking"
                    copy.text = sanitizedAssistantText(text)
                case .drop:
                    return nil
                }
            } else {
                copy.text = sanitizedAssistantText(copy.text)
            }
            if copy.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return nil
            }
        }
        return copy
    }

    private func assistantContentInterpretation(fromRawJSON rawJSON: String?) -> AssistantContentInterpretation? {
        guard let event = PiAgentRPCEventRenderCache.event(from: rawJSON),
              event.type == "message_end",
              let message = event.message,
              message["role"]?.stringValue == "assistant",
              let content = message["content"] else {
            return nil
        }

        switch content {
        case let .string(value):
            return .assistant(value)
        case let .array(blocks):
            let textParts = blocks.compactMap { block -> String? in
                let blockType = block["type"]?.stringValue
                guard blockType == nil || blockType == "text" || blockType == "output_text" || blockType == "message" else { return nil }
                return block["text"]?.stringValue
            }
            if !textParts.isEmpty { return .assistant(textParts.joined(separator: "\n")) }

            let thinkingParts = blocks.compactMap { block -> String? in
                guard block["type"]?.stringValue == "thinking" else { return nil }
                return block["thinking"]?.stringValue
            }
            if !thinkingParts.isEmpty { return .thinking(thinkingParts.joined(separator: "\n\n")) }

            let hasToolCall = blocks.contains { block in
                let blockType = block["type"]?.stringValue
                return blockType == "toolCall" || blockType == "tool_call" || block["name"]?.stringValue != nil
            }
            return hasToolCall ? .drop : nil
        default:
            return .drop
        }
    }

    private func sanitizedAssistantText(_ text: String) -> String {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !piAgentLeakedToolNames.contains($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func coalescedCompactionEntries(_ entries: [PiAgentTranscriptEntry]) -> [PiAgentTranscriptEntry] {
        var output: [PiAgentTranscriptEntry] = []
        for entry in entries {
            guard entry.role == .status && entry.title == "Compaction" else {
                output.append(entry)
                continue
            }
            if let last = output.last,
               last.role == .status,
               last.title == "Compaction",
               abs(entry.timestamp.timeIntervalSince(last.timestamp)) < 600 {
                output[output.count - 1] = entry
            } else {
                output.append(entry)
            }
        }
        return output
    }

    private func normalizeThinkingOrder(_ entries: [PiAgentTranscriptEntry]) -> [PiAgentTranscriptEntry] {
        var normalized: [PiAgentTranscriptEntry] = []
        for entry in entries {
            if entry.role == .thinking,
               let previous = normalized.last,
               previous.role == .assistant,
               abs(entry.timestamp.timeIntervalSince(previous.timestamp)) < 180 {
                normalized.removeLast()
                normalized.append(entry)
                normalized.append(previous)
            } else {
                normalized.append(entry)
            }
        }
        return normalized
    }

    private func isValuableTranscriptEntry(_ entry: PiAgentTranscriptEntry) -> Bool {
        switch entry.role {
        case .raw:
            return false
        case .assistant:
            return isMeaningfulAssistantEntry(entry)
        case .status:
            return entry.title == "Compaction" || entry.title == "Retry" || entry.title == "Subagent Started"
        case .tool:
            return !(entry.title == "Tool Call" && entry.text.localizedCaseInsensitiveContains("preparing tool call"))
        case .stderr:
            return !entry.text.localizedCaseInsensitiveContains("ready for input") && !entry.text.contains(";notify;Pi;")
        default:
            return true
        }
    }

    private func isMeaningfulAssistantEntry(_ entry: PiAgentTranscriptEntry) -> Bool {
        let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return true }
        return !piAgentLeakedToolNames.contains(text.lowercased())
    }
}

private struct PiAgentTranscriptTimelineItem: Identifiable {
    enum Kind {
        case thread(PiAgentTranscriptThread)
        case plan(PiSessionPlanEventRecord)
    }

    let id: String
    let timestamp: Date
    let kind: Kind
}

private extension PiAgentTranscriptThread {
    var timelineTimestamp: Date {
        let activityEntries = activities.compactMap(\.representativeEntry)
        let candidates = [question].compactMap { $0 }
            + steeringMessages
            + [thinking].compactMap { $0 }
            + assistantMessages
            + activityEntries
            + statuses
            + errors
        return candidates.map(\.timestamp).min() ?? .distantPast
    }
}

struct PiAgentScreen: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var store: PiAgentSessionStore
    @State private var composerText = ""
    @State private var composerTextBySessionID: [UUID: String] = [:]
    @State private var composerImagesBySessionID: [UUID: [PiAgentImageAttachment]] = [:]
    @State private var composerFilesBySessionID: [UUID: [PiAgentFileAttachment]] = [:]
    @State private var inputMode: PiAgentInputMode = .steer
    @State private var sessionSearchText = ""
    @State private var selectedSessionTitleDraft = ""
    @State private var renamingSessionID: UUID?
    @State private var selectedSessionIDs: Set<UUID> = []
    @State private var lastSelectedSessionID: UUID?
    @State private var pendingDeleteSessionIDs: Set<UUID> = []
    @State private var isDeleteSessionsAlertPresented = false
    @State private var composerImages: [PiAgentImageAttachment] = []
    @State private var composerFiles: [PiAgentFileAttachment] = []
    @State private var composerAttachmentError: String?
    @State private var selectedSubagentTranscriptRunID: UUID?
    @State private var selectedSubagentGraphRunID: UUID?
    @StateObject private var transcriptCache = PiAgentTranscriptRenderCache()
    @State private var lastStreamingScrollAt: Date = .distantPast
    @State private var transcriptBottomScrollRequest = 0
    @State private var cachedVisibleSessions: [PiAgentSessionRecord] = []
    @State private var hasBuiltVisibleSessions = false
    @State private var frozenRuntimeFooterSession: PiAgentSessionRecord?

    var body: some View {
        HSplitView {
            sessionsColumn
                .frame(minWidth: 190, idealWidth: 250, maxWidth: 360)

            activeSessionColumn
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            syncVisibleSessionSelection()
            syncMultiSelectionToSelectedSession()
            syncRuntimeFooterSnapshot()
            viewModel.acknowledgeVisibleSelectedPiAgentSession()
            syncSelectedSessionTitleDraft()
            loadComposerDraft(for: store.selectedSession?.id)
            rebuildVisibleSessions()
            scheduleTranscriptCacheUpdate()
        }
        .onReceive(store.$sessions) { _ in rebuildVisibleSessions() }
        .onChange(of: sessionSearchText) { _, _ in rebuildVisibleSessions() }
        .onChange(of: viewModel.showPiAgentAttentionOnly) { _, _ in rebuildVisibleSessions() }
        .onDisappear {
            saveComposerDraft(for: store.selectedSession?.id)
        }
        .onChange(of: store.selectedSession?.id) { oldID, newID in
            saveComposerDraft(for: oldID)
            renamingSessionID = nil
            syncSelectedSessionTitleDraft()
            if let newID, !selectedSessionIDs.contains(newID) {
                syncMultiSelectionToSelectedSession()
            } else if newID == nil {
                selectedSessionIDs = []
                lastSelectedSessionID = nil
            }
            loadComposerDraft(for: newID)
            syncRuntimeFooterSnapshot()
            scheduleTranscriptCacheUpdate()
        }
        .onChange(of: store.selectedSession?.status.isActive) { _, _ in
            syncRuntimeFooterSnapshot()
        }
        .onChange(of: store.selectedSession?.title) { _, _ in syncSelectedSessionTitleDraft() }
        .onChange(of: visibleSessionIDs) { _, _ in
            syncVisibleSessionSelection()
            pruneMultiSelectionToVisibleSessions()
        }
        .onChange(of: viewModel.selectedProjectPath) { _, _ in
            rebuildVisibleSessions()
            syncVisibleSessionSelection()
            viewModel.acknowledgeVisibleSelectedPiAgentSession()
        }
        .onChange(of: store.selectedTranscriptRevision) { _, _ in scheduleTranscriptCacheUpdate() }
        .sheet(item: selectedSubagentTranscriptBinding) { run in
            PiNativeSubagentTranscriptSheet(
                run: run,
                entries: store.subagentTranscript(for: run.id),
                thinkingDisplayMode: viewModel.appSettings.piAgentThinkingDisplayMode,
                visibility: viewModel.appSettings.piAgentTranscriptVisibility
            )
        }
        .sheet(item: selectedSubagentGraphBinding) { run in
            PiNativeSubagentGraphSheet(
                run: run,
                onStopGraph: { viewModel.stopNativeSubagentGraph(runID: run.id, parentSessionID: run.parentSessionID) },
                onStopChild: { child in viewModel.stopNativeSubagentGraphChild(graphRunID: run.id, childID: child.id, parentSessionID: run.parentSessionID) },
                onRetryChild: { child in viewModel.retryNativeSubagentGraphChild(graphRunID: run.id, childID: child.id, parentSessionID: run.parentSessionID) },
                onOpenChildArtifacts: { child in if let path = child.artifactDirectory { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } }
            )
        }
        .alert(deleteSessionsAlertTitle, isPresented: $isDeleteSessionsAlertPresented) {
            Button("Delete", role: .destructive, action: deletePendingSessions)
            Button("Cancel", role: .cancel) { pendingDeleteSessionIDs = [] }
        } message: {
            Text(deleteSessionsAlertMessage)
        }
    }

    private var sessionScopePath: String? {
        viewModel.selectedProjectPath
    }

    private var scopedSessions: [PiAgentSessionRecord] {
        guard let sessionScopePath else { return store.sessions }
        return store.sessions.filter { $0.projectPath == sessionScopePath }
    }

    private var visibleSessions: [PiAgentSessionRecord] {
        hasBuiltVisibleSessions ? cachedVisibleSessions : computedVisibleSessions()
    }

    private func rebuildVisibleSessions() {
        cachedVisibleSessions = computedVisibleSessions()
        hasBuiltVisibleSessions = true
    }

    private func computedVisibleSessions() -> [PiAgentSessionRecord] {
        let query = sessionSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = viewModel.showPiAgentAttentionOnly ? scopedSessions.filter(\.needsAttention) : scopedSessions
        return query.isEmpty ? source : source.filter { sessionMatchesSearch($0, query: query) }
    }

    private var visibleSessionIDs: [UUID] {
        visibleSessions.map(\.id)
    }

    private var deleteSessionsAlertTitle: String {
        pendingDeleteSessionIDs.count == 1 ? "Delete Pi Agent session?" : "Delete \(pendingDeleteSessionIDs.count) Pi Agent sessions?"
    }

    private var deleteSessionsAlertMessage: String {
        pendingDeleteSessionIDs.count == 1
            ? "This removes the selected Pi Agent session and its local transcript from Pi Manager."
            : "This removes the selected Pi Agent sessions and their local transcripts from Pi Manager."
    }

    private var sessionDeleteTargets: Set<UUID> {
        if !selectedSessionIDs.isEmpty {
            return selectedSessionIDs
        }
        if let selectedID = store.selectedSession?.id {
            return [selectedID]
        }
        return []
    }

    private var sessionsColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sessions")
                        .font(.title2.bold())
                        .fontWidth(.expanded)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Text("\(scopedSessions.count) saved · \(runningCount) active")
                        .font(.footnote)
                        .foregroundStyle(AppTheme.mutedText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
                .layoutPriority(1)
                Spacer()
                Button(role: .destructive) {
                    requestDeleteSessions(sessionDeleteTargets)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(sessionDeleteTargets.isEmpty ? AppTheme.mutedText.opacity(0.45) : AppTheme.mutedText)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(AppTheme.contentSubtleFill.opacity(0.85)))
                }
                .buttonStyle(.plain)
                .disabled(sessionDeleteTargets.isEmpty)
                .help(sessionDeleteTargets.count > 1 ? "Delete selected sessions" : "Delete selected session")
                .accessibilityLabel(sessionDeleteTargets.count > 1 ? "Delete selected sessions" : "Delete selected session")
                Button {
                    viewModel.showPiAgentAttentionOnly.toggle()
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: viewModel.showPiAgentAttentionOnly ? "bell.fill" : "bell")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(viewModel.showPiAgentAttentionOnly ? .white : Color.accentColor)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(viewModel.showPiAgentAttentionOnly ? Color.accentColor : Color.accentColor.opacity(0.12)))
                        if viewModel.piAgentNeedsAttentionCount > 0 {
                            Text("\(viewModel.piAgentNeedsAttentionCount)")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule(style: .continuous).fill(Color.red))
                                .offset(x: 4, y: -3)
                        }
                    }
                }
                .buttonStyle(.plain)
                .help(viewModel.showPiAgentAttentionOnly ? "Show all sessions" : "Show unread Pi Agent updates")
                PiAgentAddSessionButton {
                    viewModel.createPiAgentDraftForSelectedProject()
                }
                .help(viewModel.selectedDiscoveredProject == nil ? "New Pi Agent session in \(viewModel.configuredProjectsRootPath)" : "New Pi Agent session")
            }
            .padding(18)

            if scopedSessions.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "sparkles.rectangle.stack")
                        .font(.title2)
                        .foregroundStyle(AppTheme.mutedText)
                    Text("No sessions yet")
                        .font(.headline)
                    Text(emptySessionsMessage)
                        .foregroundStyle(AppTheme.mutedText)
                }
                .padding(18)
                Spacer()
            } else {
                VStack(spacing: 10) {
                    PiAgentSessionSearchField(text: $sessionSearchText)
                        .padding(.horizontal, 14)

                    if visibleSessions.isEmpty {
                        ContentUnavailableView("No sessions found", systemImage: "magnifyingglass", description: Text("Try another search."))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView(showsIndicators: false) {
                            LazyVStack(alignment: .leading, spacing: 10) {
                                ForEach(visibleSessions) { session in
                                    PiAgentSessionRow(
                                        session: session,
                                        project: viewModel.discoveredProjects.first(where: { $0.path == session.projectPath }),
                                        isSelected: selectedSessionIDs.contains(session.id),
                                        isRunning: viewModel.isPiAgentSessionRunning(session.id),
                                        isRenaming: renamingSessionID == session.id,
                                        onSelect: {
                                            renamingSessionID = nil
                                            withAnimation(.snappy(duration: 0.22)) {
                                                selectSessionFromList(session)
                                            }
                                        },
                                        onBeginRename: {
                                            withAnimation(.snappy(duration: 0.22)) {
                                                selectSessionFromList(session, forceSingle: true)
                                            }
                                            renamingSessionID = session.id
                                        },
                                        onEndRename: { renamingSessionID = nil },
                                        onRename: { viewModel.renamePiAgentSession(session.id, title: $0) },
                                        onTogglePinned: { viewModel.togglePiAgentSessionPinned(session.id) }
                                    )
                                    .contextMenu {
                                        Button {
                                            viewModel.togglePiAgentSessionPinned(session.id)
                                        } label: {
                                            Label(session.isPinned ? "Unpin Session" : "Pin Session", systemImage: session.isPinned ? "pin.slash" : "pin")
                                        }
                                        Button(role: .destructive) {
                                            requestDeleteSessions(selectedSessionIDs.contains(session.id) && selectedSessionIDs.count > 1 ? selectedSessionIDs : [session.id])
                                        } label: {
                                            Label(selectedSessionIDs.contains(session.id) && selectedSessionIDs.count > 1 ? "Delete Selected Sessions" : "Delete Session", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.bottom, 18)
                            .animation(.snappy(duration: 0.24), value: visibleSessionIDs)
                        }
                    }
                }
            }
        }
        .appPanelSurface(cornerRadius: 0)
    }

    private var activeSessionColumn: some View {
        VStack(spacing: 0) {
            transcript
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(18)

            Divider()

            VStack(spacing: 12) {
                if let request = store.selectedUIRequest {
                    PiAgentUIRequestCard(
                        request: request,
                        onSubmitValue: { viewModel.respondToPiAgentUIRequest(request, value: $0) },
                        onSubmitFreeform: { sentinel, value in viewModel.respondToPiAgentFreeformUIRequest(request, sentinel: sentinel, value: value) },
                        onConfirm: { viewModel.confirmPiAgentUIRequest(request, confirmed: $0) },
                        onCancel: { viewModel.cancelPiAgentUIRequest(request) }
                    )
                }

                composer
            }
            .padding(18)
        }
    }

    @ViewBuilder
    private var sessionHeader: some View {
        if let session = store.selectedSession {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    AppLabelTag(text: session.kind.rawValue, color: session.kind == .issue ? .purple : .blue)
                    AppLabelTag(text: effectiveStatus(for: session), color: effectiveStatusColor(for: session))
                    Text(session.updatedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.footnote)
                        .foregroundStyle(AppTheme.mutedText)
                    Spacer(minLength: 0)
                }
                TextField("Session name", text: $selectedSessionTitleDraft)
                    .textFieldStyle(.plain)
                    .font(.title3.bold())
                    .fontWidth(.expanded)
                    .lineLimit(1)
                    .onSubmit(commitSelectedSessionRename)
                    .onDisappear(perform: commitSelectedSessionRename)

                if let error = session.lastError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        } else {
            AppCard(title: "No Session Selected") {
                Text("Select a session from the left, or create a new draft for the selected project.")
                    .foregroundStyle(AppTheme.mutedText)
            }
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    if let session = store.selectedSession {
                        PiAgentStartupResourcesCard(viewModel: viewModel, session: session)
                        if let finalSystemPrompt = session.finalSystemPrompt {
                            PiAgentSystemPromptAuditCard(
                                title: "Final System Prompt",
                                subtitle: "",
                                prompt: finalSystemPrompt
                            )
                        }
                        ForEach(store.supervisorRequests(for: session.id).filter { $0.status == .pending }) { request in
                            PiSubagentSupervisorRequestCard(
                                request: request,
                                onRespond: { response in viewModel.respondToSubagentSupervisorRequest(request.id, parentSessionID: session.id, response: response) },
                                onCancel: { viewModel.cancelSubagentSupervisorRequest(request.id, parentSessionID: session.id) }
                            )
                        }
                    }

                    let timelineItems = transcriptTimelineItems
                    if timelineItems.isEmpty {
                        AppRowCard {
                            HStack(spacing: 12) {
                                Image(systemName: "text.bubble")
                                    .font(.title2)
                                    .foregroundStyle(AppTheme.mutedText)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("No transcript yet")
                                        .font(.headline)
                                    Text("Send a message below to launch Pi Agent for this session.")
                                        .foregroundStyle(AppTheme.mutedText)
                                }
                                Spacer()
                            }
                        }
                    } else {
                        ForEach(timelineItems) { item in
                            switch item.kind {
                            case let .thread(thread):
                                PiAgentTranscriptThreadCard(
                                    thread: thread,
                                    thinkingDisplayMode: viewModel.appSettings.piAgentThinkingDisplayMode,
                                    visibility: viewModel.appSettings.piAgentTranscriptVisibility,
                                    skills: visibleSkillsForSelectedSession,
                                    nativeSubagentRunsByID: nativeSubagentRunsByID,
                                    nativeSubagentCard: nativeSubagentCard
                                )
                                .id(thread.id)
                            case let .plan(event):
                                PiAgentCurrentPlanCard(event: event)
                                    .id(event.id)
                            }
                        }
                        if let processingMessage = selectedSessionProcessingMessage {
                            PiAgentProcessingIndicatorCard(message: processingMessage)
                                .id("pi-agent-processing")
                        }
                    }

                    Color.clear
                        .frame(height: 1)
                        .id("pi-agent-bottom-anchor")
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .onChange(of: transcriptCache.renderRevision) { _, _ in
                scrollToLatestThread(proxy: proxy)
            }
            .onChange(of: transcriptCache.streamingRevision) { _, _ in
                throttleStreamingScroll(proxy: proxy)
            }
            .onChange(of: selectedSessionProcessingMessage) { _, message in
                guard message != nil else { return }
                scrollToProcessingIndicator(proxy: proxy)
            }
            .onChange(of: transcriptBottomScrollRequest) { _, _ in
                scrollToRequestedBottom(proxy: proxy)
            }
        }
    }

    private var transcriptTimelineItems: [PiAgentTranscriptTimelineItem] {
        var items = transcriptCache.threads.map { thread in
            PiAgentTranscriptTimelineItem(
                id: "thread-\(thread.id.uuidString)",
                timestamp: thread.timelineTimestamp,
                kind: .thread(thread)
            )
        }
        if viewModel.appSettings.piAgentTranscriptVisibility.showPlans,
           let sessionID = store.selectedSession?.id {
            items += store.sessionPlanEvents(for: sessionID).map { event in
                PiAgentTranscriptTimelineItem(
                    id: "plan-\(event.id.uuidString)",
                    timestamp: event.timestamp,
                    kind: .plan(event)
                )
            }
        }
        return items.sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
            return lhs.id < rhs.id
        }
    }

    private var selectedSessionProcessingMessage: String? {
        guard let session = store.selectedSession,
              session.status.isActive,
              store.selectedUIRequest == nil else { return nil }

        if session.status == .starting { return "Starting Pi" }
        if session.isCompacting { return "Compacting context" }

        if let lastEntry = store.selectedTranscript.last {
            if lastEntry.role == .assistant && !lastEntry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return nil
            }
            if lastEntry.role == .error || lastEntry.role == .stderr {
                return nil
            }
            if lastEntry.role == .tool {
                return lastEntry.text.localizedCaseInsensitiveContains("waiting for user input") ? nil : "Running tool"
            }
            if lastEntry.role == .status {
                if lastEntry.title == "Input Sent" { return "Processing your response" }
                if lastEntry.title == "Retry" { return "Retrying request" }
                if lastEntry.title == "Compaction" { return "Compacting context" }
            }
            if lastEntry.role == .user {
                switch lastEntry.title {
                case "Steering": return "Applying your steering"
                case "Queued follow-up": return "Queued follow-up"
                default: return "Thinking about your message"
                }
            }
            if lastEntry.role == .thinking { return "Reasoning" }
        }
        return "Pi is thinking"
    }

    private func scheduleTranscriptCacheUpdate() {
        transcriptCache.scheduleUpdate(
            sessionID: store.selectedSession?.id,
            revision: store.selectedTranscriptRevision,
            rawEntries: store.selectedTranscript
        )
    }

    private func scrollToLatestThread(proxy: ScrollViewProxy) {
        scrollToConversationBottom(proxy: proxy, animated: false)
    }

    private func scrollToProcessingIndicator(proxy: ScrollViewProxy) {
        scrollToConversationBottom(proxy: proxy, animated: false)
    }

    private func requestTranscriptBottomScroll() {
        transcriptBottomScrollRequest &+= 1
    }

    private func scrollToRequestedBottom(proxy: ScrollViewProxy) {
        scrollToConversationBottom(proxy: proxy, animated: true)
    }

    private func scrollToConversationBottom(proxy: ScrollViewProxy, animated: Bool) {
        lastStreamingScrollAt = Date()
        Task { @MainActor in
            await Task.yield()
            withTransaction(Transaction(animation: animated ? .easeOut(duration: 0.18) : nil)) {
                proxy.scrollTo("pi-agent-bottom-anchor", anchor: .bottom)
            }
        }
    }

    private func throttleStreamingScroll(proxy: ScrollViewProxy) {
        guard Date().timeIntervalSince(lastStreamingScrollAt) > 0.14 else { return }
        scrollToLatestThread(proxy: proxy)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            PiAgentCommandSuggestions(
                commands: slashSuggestions,
                skills: skillSlashSuggestions,
                fileSuggestions: fileSuggestions,
                onSelectFile: insertFileSuggestion,
                onSelectCommand: insertSlashSuggestion
            )

            let isRunning = store.selectedSession?.status.isActive == true
            let isCompacting = store.selectedSession?.isCompacting == true
            let hasSelectedSession = store.selectedSession != nil
            PiAgentComposerBox(
                text: $composerText,
                images: $composerImages,
                files: $composerFiles,
                attachmentError: $composerAttachmentError,
                inputMode: $inputMode,
                isRunning: isRunning,
                isDisabled: isCompacting || !hasSelectedSession,
                placeholder: !hasSelectedSession ? "Select or start a Pi Agent session to send a message…" : (isCompacting ? "Compacting context…" : (isRunning ? "Steer the current turn…" : "Ask Pi to implement, inspect, explain, or fix…")),
                canSend: !isCompacting && store.selectedSession != nil && (!composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !composerImages.isEmpty || !composerFiles.isEmpty),
                path: store.selectedSession.map { $0.worktreePath ?? $0.projectPath },
                onFiles: addFileAttachments,
                viewModel: viewModel,
                footerSession: store.selectedSession,
                transcript: store.selectedTranscript,
                supportedThinkingLevels: store.selectedSession.map(supportedThinkingLevels(for:)) ?? [],
                metricsSession: runtimeFooterSession(isRunning: isRunning),
                onSend: sendComposerMessage,
                onStop: { viewModel.stopSelectedPiAgentSession() },
                onClear: clearComposerInput
            )
        }
    }

    private var activeSuggestionToken: (token: String, range: Range<String.Index>)? {
        guard !composerText.isEmpty else { return nil }
        let nsText = composerText as NSString
        let tokenRange = nsText.range(of: "[^\\s]+$", options: .regularExpression)
        guard tokenRange.location != NSNotFound,
              let range = Range(tokenRange, in: composerText) else {
            return nil
        }
        let token = String(composerText[range])
        guard !token.isEmpty else { return nil }
        return (token: token, range: range)
    }

    private enum ComposerSuggestionTrigger {
        case slash(query: String)
        case file(query: String)
    }

    private var composerSuggestionTrigger: ComposerSuggestionTrigger? {
        guard let active = activeSuggestionToken,
              let first = active.token.first else { return nil }

        switch first {
        case "/":
            // Pi only dispatches slash commands/templates when the prompt starts with `/`.
            // Keep file mentions available anywhere, but only suggest/action slash commands
            // when this token is the first non-whitespace content in the composer.
            let prefix = composerText[..<active.range.lowerBound]
            guard prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return .slash(query: String(active.token.dropFirst()).lowercased())
        case "@":
            return .file(query: String(active.token.dropFirst()).lowercased())
        default:
            return nil
        }
    }

    private var slashSuggestions: [String] {
        guard case let .slash(query) = composerSuggestionTrigger else { return [] }
        guard !query.hasPrefix("skill:") else { return [] }
        let all = Array(Set(viewModel.snapshot.commands.map(\.invocation) + viewModel.snapshot.promptTemplates.map(\.invocation) + ["/compact"])).sorted()
        return all.filter { query.isEmpty || $0.dropFirst().lowercased().hasPrefix(query) }.prefix(8).map { $0 }
    }

    private var skillSlashSuggestions: [String] {
        guard case let .slash(query) = composerSuggestionTrigger else { return [] }
        let normalizedQuery = query.hasPrefix("skill:") ? String(query.dropFirst("skill:".count)) : query
        return visibleSkillsForSelectedSession
            .filter { normalizedQuery.isEmpty || $0.name.lowercased().hasPrefix(normalizedQuery) }
            .map { "/skill:\($0.name)" }
            .prefix(8)
            .map { $0 }
    }

    private var visibleSkillsForSelectedSession: [SkillRecord] {
        let projectPath = store.selectedSession?.projectPath ?? viewModel.selectedProjectPath
        let snapshot = projectPath.map { viewModel.startupSnapshot(forProjectPath: $0) } ?? viewModel.snapshot
        var seen = Set<String>()
        return (snapshot.skills + snapshot.librarySkills)
            .filter { seen.insert($0.name).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var fileSuggestions: [PiAgentFileSuggestion] {
        guard let session = store.selectedSession else { return [] }
        guard case let .file(query) = composerSuggestionTrigger else { return [] }
        return PiAgentFileSuggestion.scan(rootPath: session.worktreePath ?? session.projectPath, query: query)
    }

    private func insertFileSuggestion(_ suggestion: PiAgentFileSuggestion) {
        replaceCurrentSuggestionToken(with: "@\(suggestion.relativePath)")
    }

    private func insertSlashSuggestion(_ command: String) {
        replaceCurrentSuggestionToken(with: command)
    }

    private var nativeSubagentRunsByID: [UUID: PiSubagentRunRecord] {
        guard let session = store.selectedSession else { return [:] }
        return Dictionary(uniqueKeysWithValues: store.subagentRuns(for: session.id).map { ($0.id, $0) })
    }

    private func nativeSubagentCard(for run: PiSubagentRunRecord) -> PiNativeSubagentRunCard {
        PiNativeSubagentRunCard(
            run: run,
            onStop: { viewModel.stopNativeSubagent(runID: run.id, parentSessionID: run.parentSessionID) },
            onOpenTranscript: { selectedSubagentTranscriptRunID = run.id },
            onReveal: { revealSubagentRun(run) },
            onOpenGraph: { selectedSubagentGraphRunID = run.id }
        )
    }

    private var selectedSubagentTranscriptBinding: Binding<PiSubagentRunRecord?> {
        Binding(
            get: {
                guard let runID = selectedSubagentTranscriptRunID,
                      let session = store.selectedSession else { return nil }
                return store.subagentRuns(for: session.id).first(where: { $0.id == runID })
            },
            set: { newValue in selectedSubagentTranscriptRunID = newValue?.id }
        )
    }

    private var selectedSubagentGraphBinding: Binding<PiSubagentRunRecord?> {
        Binding(
            get: {
                guard let runID = selectedSubagentGraphRunID,
                      let session = store.selectedSession else { return nil }
                return store.subagentRuns(for: session.id).first(where: { $0.id == runID })
            },
            set: { newValue in selectedSubagentGraphRunID = newValue?.id }
        )
    }

    private func revealSubagentRun(_ run: PiSubagentRunRecord) {
        let target = run.outputPath ?? run.artifactDirectory
        guard !target.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: target)])
    }

    private func replaceCurrentSuggestionToken(with replacement: String) {
        guard let active = activeSuggestionToken else { return }
        composerText.replaceSubrange(active.range, with: replacement)
        composerText += " "
    }

    private func addFileAttachments(_ urls: [URL]) {
        let attachments = urls.filter { !$0.hasDirectoryPath }.compactMap { PiAgentFileAttachment(url: $0) }
        guard !attachments.isEmpty else { return }
        composerAttachmentError = nil
        for attachment in attachments where !composerFiles.contains(where: { $0.url == attachment.url }) {
            composerFiles.append(attachment)
        }
    }

    private func loadComposerDraft(for sessionID: UUID?) {
        if let pending = viewModel.consumePendingPiAgentComposerText() {
            composerText = pending
            composerImages = []
            composerFiles = []
            composerAttachmentError = nil
            saveComposerDraft(for: sessionID)
            return
        }

        guard let sessionID else {
            clearComposerInput()
            return
        }
        composerText = composerTextBySessionID[sessionID] ?? ""
        composerImages = composerImagesBySessionID[sessionID] ?? []
        composerFiles = composerFilesBySessionID[sessionID] ?? []
        composerAttachmentError = nil
    }

    private func saveComposerDraft(for sessionID: UUID?) {
        guard let sessionID else { return }
        if composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && composerImages.isEmpty && composerFiles.isEmpty {
            composerTextBySessionID.removeValue(forKey: sessionID)
            composerImagesBySessionID.removeValue(forKey: sessionID)
            composerFilesBySessionID.removeValue(forKey: sessionID)
        } else {
            composerTextBySessionID[sessionID] = composerText
            composerImagesBySessionID[sessionID] = composerImages
            composerFilesBySessionID[sessionID] = composerFiles
        }
    }

    private func clearComposerInput() {
        composerText = ""
        composerImages = []
        composerFiles = []
        composerAttachmentError = nil
    }

    private func sendComposerMessage() {
        let message = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty || !composerImages.isEmpty || !composerFiles.isEmpty else { return }
        guard store.selectedSession?.isCompacting != true else { return }
        guard let payload = attachedFilePayload() else { return }
        let combined = [expandFileReferences(in: message), payload].filter { !$0.isEmpty }.joined(separator: "\n\n")
        let isRunning = store.selectedSession?.status.isActive == true
        let sentSessionID = store.selectedSession?.id
        viewModel.sendPiAgentMessage(combined, mode: isRunning ? .steer : .prompt, images: composerImages)
        requestTranscriptBottomScroll()
        clearComposerInput()
        if let sentSessionID {
            composerTextBySessionID.removeValue(forKey: sentSessionID)
            composerImagesBySessionID.removeValue(forKey: sentSessionID)
            composerFilesBySessionID.removeValue(forKey: sentSessionID)
        }
    }

    private func expandFileReferences(in message: String) -> String {
        guard let session = store.selectedSession else { return message }
        let rootURL = URL(fileURLWithPath: session.worktreePath ?? session.projectPath)
        return message
            .split(separator: " ", omittingEmptySubsequences: false)
            .map { part in
                guard part.hasPrefix("@"), part.count > 1 else { return String(part) }
                let relative = String(part.dropFirst())
                let url = rootURL.appendingPathComponent(relative)
                guard FileManager.default.fileExists(atPath: url.path) else { return String(part) }
                return fileTag(for: url) ?? String(part)
            }
            .joined(separator: " ")
    }

    private func attachedFilePayload() -> String? {
        var tags: [String] = []
        for file in composerFiles {
            guard let tag = fileTag(for: file.url) else {
                composerAttachmentError = "Only images and UTF-8 text files are supported. \(file.url.lastPathComponent) is not readable as text."
                return nil
            }
            tags.append(tag)
        }
        return tags.joined(separator: "\n")
    }

    private func fileTag(for url: URL) -> String? {
        if PiAgentComposerImageLoader.imageAttachment(fromFileURL: url) != nil {
            return "<file name=\"\(url.path)\"></file>"
        }
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return "<file name=\"\(url.path)\">\n\(content)\n</file>"
    }

    private var runningCount: Int {
        scopedSessions.filter { viewModel.isPiAgentSessionRunning($0.id) }.count
    }

    private var emptySessionsMessage: String {
        if let project = viewModel.selectedDiscoveredProject {
            return "Use + to create a draft for \(project.name), or Open from a GitHub issue."
        }
        return "Use + to create a draft in \(viewModel.configuredProjectsRootPath), or select a project to narrow the list."
    }

    private func supportedThinkingLevels(for session: PiAgentSessionRecord) -> [String] {
        let defaultModel = viewModel.defaultPiAgentModel()
        let provider = session.modelOverrideProvider ?? session.modelProvider ?? defaultModel?.provider
        let modelID = session.modelOverrideID ?? session.model ?? defaultModel?.model
        if let provider, let modelID {
            if let runtimeModel = session.availableModels?.first(where: { $0.provider == provider && $0.id == modelID }) {
                return runtimeModel.supportedThinkingLevels ?? (runtimeModel.supportsThinking == false ? ["off"] : defaultThinkingLevels(provider: provider, modelID: modelID))
            }
            if let cached = viewModel.enabledAvailableModels.first(where: { $0.provider == provider && $0.model == modelID }) {
                return cached.supportedThinkingLevels.isEmpty ? (cached.supportsThinking ? defaultThinkingLevels(provider: provider, modelID: modelID) : ["off"]) : cached.supportedThinkingLevels
            }
        }
        // Unknown/default model: keep the conservative standard Pi levels, but do not offer xhigh unless a model confirms it.
        return ["off", "minimal", "low", "medium", "high"]
    }

    private func defaultThinkingLevels(provider: String, modelID: String) -> [String] {
        PiModelCapability.supportsXhigh(modelID: modelID)
            ? ["off", "minimal", "low", "medium", "high", "xhigh"]
            : ["off", "minimal", "low", "medium", "high"]
    }

    private func syncVisibleSessionSelection() {
        if let selectedID = store.selectedSession?.id,
           visibleSessions.contains(where: { $0.id == selectedID }) {
            return
        }

        if let firstVisible = visibleSessions.first {
            store.select(firstVisible.id)
        } else {
            store.clearSelection()
        }
    }

    private func syncMultiSelectionToSelectedSession() {
        if let selectedID = store.selectedSession?.id {
            selectedSessionIDs = [selectedID]
        } else {
            selectedSessionIDs = []
        }
        lastSelectedSessionID = store.selectedSession?.id
    }

    private func pruneMultiSelectionToVisibleSessions() {
        let visibleIDs = Set(visibleSessionIDs)
        selectedSessionIDs.formIntersection(visibleIDs)
        if let selectedID = store.selectedSession?.id, visibleIDs.contains(selectedID) {
            selectedSessionIDs.insert(selectedID)
        }
        if let lastSelectedSessionID, !visibleIDs.contains(lastSelectedSessionID) {
            self.lastSelectedSessionID = store.selectedSession?.id
        }
    }

    private func selectSessionFromList(_ session: PiAgentSessionRecord, forceSingle: Bool = false) {
        let modifiers = NSEvent.modifierFlags.intersection([.command, .shift])
        if forceSingle || modifiers.isEmpty {
            selectedSessionIDs = [session.id]
        } else if modifiers.contains(.shift), let anchorID = lastSelectedSessionID, let anchorIndex = visibleSessionIDs.firstIndex(of: anchorID), let targetIndex = visibleSessionIDs.firstIndex(of: session.id) {
            let range = min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)
            selectedSessionIDs.formUnion(visibleSessionIDs[range])
        } else if modifiers.contains(.command) {
            if selectedSessionIDs.contains(session.id), selectedSessionIDs.count > 1 {
                selectedSessionIDs.remove(session.id)
            } else {
                selectedSessionIDs.insert(session.id)
            }
        }
        lastSelectedSessionID = session.id
        viewModel.selectPiAgentSession(session.id)
    }

    private func requestDeleteSessions(_ ids: Set<UUID>) {
        let existing = Set(store.sessions.map(\.id))
        pendingDeleteSessionIDs = ids.intersection(existing)
        guard !pendingDeleteSessionIDs.isEmpty else { return }
        isDeleteSessionsAlertPresented = true
    }

    private func deletePendingSessions() {
        let ids = pendingDeleteSessionIDs
        pendingDeleteSessionIDs = []
        selectedSessionIDs.subtract(ids)
        withAnimation(.snappy(duration: 0.18)) {
            cachedVisibleSessions.removeAll { ids.contains($0.id) }
            hasBuiltVisibleSessions = true
        }
        viewModel.deletePiAgentSessions(ids)
        rebuildVisibleSessions()
        syncMultiSelectionToSelectedSession()
        syncRuntimeFooterSnapshot()
    }

    private func runtimeFooterSession(isRunning: Bool) -> PiAgentSessionRecord? {
        isRunning ? frozenRuntimeFooterSession ?? store.selectedSession : store.selectedSession
    }

    private func syncRuntimeFooterSnapshot() {
        frozenRuntimeFooterSession = store.selectedSession
    }

    private func syncSelectedSessionTitleDraft() {
        selectedSessionTitleDraft = store.selectedSession?.title ?? ""
    }

    private func commitSelectedSessionRename() {
        guard let session = store.selectedSession else { return }
        let trimmedTitle = selectedSessionTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTitle.isEmpty {
            selectedSessionTitleDraft = session.title
        } else if trimmedTitle != session.title {
            viewModel.renamePiAgentSession(session.id, title: trimmedTitle)
            selectedSessionTitleDraft = trimmedTitle
        }
    }

    private func sessionMatchesSearch(_ session: PiAgentSessionRecord, query: String) -> Bool {
        let haystack = [
            session.title,
            session.projectName,
            session.projectPath,
            session.repository ?? "",
            session.issueNumber.map(String.init) ?? "",
            session.lastSummary ?? "",
            (store.transcriptsBySessionID[session.id] ?? []).map { "\($0.title) \($0.text)" }.joined(separator: " ")
        ].joined(separator: " ")
        return haystack.localizedCaseInsensitiveContains(query)
    }

    private func effectiveStatus(for session: PiAgentSessionRecord) -> String {
        session.status.rawValue
    }

    private func effectiveStatusColor(for session: PiAgentSessionRecord) -> Color {
        switch session.status {
        case .running, .starting: return .orange
        case .idle, .completed: return .blue
        case .failed: return .red
        case .stopped: return .orange
        case .draft: return .secondary
        }
    }
}
