import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

private let piAgentLeakedToolNames: Set<String> = ["bash", "read", "edit", "write", "find", "grep", "subagent", "web_search", "fetch_content", "code_search"]

@MainActor
private enum PiAgentRPCEventRenderCache {
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
private final class PiAgentTranscriptRenderCache: ObservableObject {
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
            return entry.title == "Compaction" || entry.title == "Retry"
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
    @State private var composerImages: [PiAgentImageAttachment] = []
    @State private var composerFiles: [PiAgentFileAttachment] = []
    @State private var composerAttachmentError: String?
    @State private var isNativeSubagentRunSheetPresented = false
    @State private var nativeSubagentAgentName = ""
    @State private var nativeSubagentTask = ""
    @State private var nativeSubagentUseWorktreeIsolation = false
    @State private var nativeSubagentAllowDirectProjectWrites = false
    @State private var nativeSubagentExpectedOutcome: PiSubagentExpectedOutcome = .reportOnly
    @State private var nativeSubagentRequestedOutputPath = ""
    @State private var nativeSubagentAllowOverwrite = false
    @State private var nativeSubagentReadFirstPaths = ""
    @State private var selectedSubagentTranscriptRunID: UUID?
    @State private var selectedSubagentGraphRunID: UUID?
    @StateObject private var transcriptCache = PiAgentTranscriptRenderCache()
    @State private var lastStreamingScrollAt: Date = .distantPast
    @State private var transcriptBottomScrollRequest = 0
    @State private var cachedVisibleSessions: [PiAgentSessionRecord] = []

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
            loadComposerDraft(for: newID)
            scheduleTranscriptCacheUpdate()
        }
        .onChange(of: store.selectedSession?.title) { _, _ in syncSelectedSessionTitleDraft() }
        .onChange(of: visibleSessionIDs) { _, _ in syncVisibleSessionSelection() }
        .onChange(of: viewModel.selectedProjectPath) { _, _ in
            rebuildVisibleSessions()
            syncVisibleSessionSelection()
            viewModel.acknowledgeVisibleSelectedPiAgentSession()
        }
        .onChange(of: store.selectedTranscriptRevision) { _, _ in scheduleTranscriptCacheUpdate() }
        .sheet(item: selectedSubagentTranscriptBinding) { run in
            PiNativeSubagentTranscriptSheet(run: run, entries: store.subagentTranscript(for: run.id))
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
        .sheet(isPresented: $isNativeSubagentRunSheetPresented) {
            PiNativeSubagentRunSheet(
                agentNames: runnableSubagentNames,
                agentInfos: nativeSubagentSheetInfos,
                selectedAgentName: $nativeSubagentAgentName,
                task: $nativeSubagentTask,
                useWorktreeIsolation: $nativeSubagentUseWorktreeIsolation,
                allowDirectProjectWrites: $nativeSubagentAllowDirectProjectWrites,
                expectedOutcome: $nativeSubagentExpectedOutcome,
                requestedOutputPath: $nativeSubagentRequestedOutputPath,
                allowOverwrite: $nativeSubagentAllowOverwrite,
                readFirstPathsText: $nativeSubagentReadFirstPaths,
                projectRootPath: store.selectedSession.map { $0.worktreePath ?? $0.projectPath },
                onCancel: { isNativeSubagentRunSheetPresented = false },
                onRun: { agentName, task, useWorktreeIsolation, allowDirectProjectWrites, expectedOutcome, requestedOutputPath, allowOverwrite, readFirstPaths in
                    viewModel.runNativeSubagent(agentName: agentName, task: task, useWorktreeIsolation: useWorktreeIsolation, allowDirectProjectWrites: allowDirectProjectWrites, expectedOutcome: expectedOutcome, requestedOutputPath: requestedOutputPath, allowOverwrite: allowOverwrite, readFirstPaths: readFirstPaths)
                    if composerText.trimmingCharacters(in: .whitespacesAndNewlines) == task.trimmingCharacters(in: .whitespacesAndNewlines) {
                        clearComposerInput()
                    }
                    isNativeSubagentRunSheetPresented = false
                }
            )
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
        cachedVisibleSessions
    }

    private func rebuildVisibleSessions() {
        let query = sessionSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = viewModel.showPiAgentAttentionOnly ? scopedSessions.filter(\.needsAttention) : scopedSessions
        cachedVisibleSessions = query.isEmpty ? source : source.filter { sessionMatchesSearch($0, query: query) }
    }

    private var visibleSessionIDs: [UUID] {
        visibleSessions.map(\.id)
    }

    private var sessionsColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sessions")
                        .font(.title2.bold())
                        .fontWidth(.expanded)
                    Text("\(scopedSessions.count) saved · \(runningCount) active")
                        .font(.footnote)
                        .foregroundStyle(AppTheme.mutedText)
                }
                Spacer()
                Button {
                    viewModel.showPiAgentAttentionOnly.toggle()
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: viewModel.showPiAgentAttentionOnly ? "bell.fill" : "bell")
                            .font(.system(size: 13, weight: .semibold))
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
                                        isSelected: store.selectedSession?.id == session.id,
                                        isRunning: viewModel.isPiAgentSessionRunning(session.id),
                                        isRenaming: renamingSessionID == session.id,
                                        onSelect: {
                                            renamingSessionID = nil
                                            withAnimation(.snappy(duration: 0.22)) {
                                                viewModel.selectPiAgentSession(session.id)
                                            }
                                        },
                                        onBeginRename: {
                                            withAnimation(.snappy(duration: 0.22)) {
                                                viewModel.selectPiAgentSession(session.id)
                                            }
                                            renamingSessionID = session.id
                                        },
                                        onEndRename: { renamingSessionID = nil },
                                        onRename: { viewModel.renamePiAgentSession(session.id, title: $0) },
                                        onTogglePinned: { viewModel.togglePiAgentSessionPinned(session.id) },
                                        onDelete: { viewModel.deletePiAgentSession(session.id) }
                                    )
                                    .contextMenu {
                                        Button {
                                            viewModel.togglePiAgentSessionPinned(session.id)
                                        } label: {
                                            Label(session.isPinned ? "Unpin Session" : "Pin Session", systemImage: session.isPinned ? "pin.slash" : "pin")
                                        }
                                        Button(role: .destructive) {
                                            viewModel.deletePiAgentSession(session.id)
                                        } label: {
                                            Label("Delete Session", systemImage: "trash")
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
        .appGlassPanel(cornerRadius: 0)
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
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let session = store.selectedSession {
                        PiAgentStartupResourcesCard(viewModel: viewModel, session: session)
                        ForEach(store.supervisorRequests(for: session.id).filter { $0.status == .pending }) { request in
                            PiSubagentSupervisorRequestCard(
                                request: request,
                                onRespond: { response in viewModel.respondToSubagentSupervisorRequest(request.id, parentSessionID: session.id, response: response) },
                                onCancel: { viewModel.cancelSubagentSupervisorRequest(request.id, parentSessionID: session.id) }
                            )
                        }
                        ForEach(store.subagentRuns(for: session.id).prefix(5)) { run in
                            PiNativeSubagentRunCard(
                                run: run,
                                onStop: { viewModel.stopNativeSubagent(runID: run.id, parentSessionID: session.id) },
                                onOpenTranscript: { selectedSubagentTranscriptRunID = run.id },
                                onReveal: { revealSubagentRun(run) },
                                onOpenGraph: { selectedSubagentGraphRunID = run.id },
                                onOpenWorktreePatch: { viewModel.openNativeSubagentWorktreePatch(runID: run.id, parentSessionID: session.id) },
                                onApplyWorktreePatch: { viewModel.applyNativeSubagentWorktreePatch(runID: run.id, parentSessionID: session.id) },
                                onDiscardWorktree: { viewModel.discardNativeSubagentWorktree(runID: run.id, parentSessionID: session.id) }
                            )
                        }
                    }

                    if store.selectedTranscript.isEmpty {
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
                        ForEach(transcriptCache.threads) { thread in
                            PiAgentTranscriptThreadCard(
                                thread: thread,
                                thinkingDisplayMode: viewModel.appSettings.piAgentThinkingDisplayMode,
                                visibility: viewModel.appSettings.piAgentTranscriptVisibility,
                                skills: visibleSkillsForSelectedSession
                            )
                            .id(thread.id)
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
        withTransaction(Transaction(animation: animated ? .easeOut(duration: 0.18) : nil)) {
            proxy.scrollTo("pi-agent-bottom-anchor", anchor: .bottom)
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
                subagentNames: runnableSubagentNames,
                subagentsEnabled: store.selectedSession?.subagentsEnabled == true,
                subagentsEnabledForNewSessions: viewModel.areSubagentsEnabledForNewSessions,
                onSetSessionSubagentsEnabled: viewModel.setSubagentsEnabledForSelectedSession,
                onSetNewSessionSubagentsEnabled: viewModel.setSubagentsEnabledForNewSessions,
                onSelectSubagent: presentNativeSubagentRun,
                footer: store.selectedSession.map { session in
                    AnyView(PiAgentComposerFooterBar(
                        session: session,
                        viewModel: viewModel,
                        supportedThinkingLevels: supportedThinkingLevels(for: session)
                    ))
                },
                metricsFooter: store.selectedSession.map { AnyView(PiAgentRuntimeFooter(session: $0)) },
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

    private var runnableSubagentNames: [String] {
        guard let session = store.selectedSession, session.subagentsEnabled else { return [] }
        let snapshot = viewModel.startupSnapshot(forProjectPath: session.projectPath)
        return snapshot.effectiveAgents
            .filter { $0.resolved.disabled != true }
            .map(\.name)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var nativeSubagentSheetInfos: [String: PiNativeSubagentRunSheet.AgentInfo] {
        guard let session = store.selectedSession else { return [:] }
        let snapshot = viewModel.startupSnapshot(forProjectPath: session.projectPath)
        return Dictionary(uniqueKeysWithValues: snapshot.effectiveAgents.map { agent in
            (agent.name, PiNativeSubagentRunSheet.AgentInfo(agent: agent))
        })
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

    private func presentNativeSubagentRun(for agentName: String) {
        nativeSubagentAgentName = agentName
        nativeSubagentTask = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        isNativeSubagentRunSheetPresented = true
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
        let provider = session.modelOverrideProvider ?? session.modelProvider
        let modelID = session.modelOverrideID ?? session.model
        if let provider, let modelID {
            if let runtimeModel = session.availableModels?.first(where: { $0.provider == provider && $0.id == modelID }) {
                return runtimeModel.supportedThinkingLevels ?? (runtimeModel.supportsThinking == false ? ["off"] : defaultThinkingLevels(provider: provider, modelID: modelID))
            }
            if let cached = viewModel.availableModels.first(where: { $0.provider == provider && $0.model == modelID }) {
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

private struct PiStartupResourceItem: Identifiable, Hashable {
    enum Kind: Hashable {
        case agent(String)
        case skill(String)
        case command(String)
        case prompt(String)
        case extensions
        case environment
        case file(URL)
        case none
    }

    let title: String
    var detail: String?
    let kind: Kind

    var id: String { "\(title)-\(String(describing: kind))" }
    var isClickable: Bool {
        if case .none = kind { return false }
        return true
    }
}

private extension Array where Element == PiStartupResourceItem {
    func uniqueByTitleAndDetail() -> [PiStartupResourceItem] {
        reduce(into: [PiStartupResourceItem]()) { result, item in
            if !result.contains(where: { $0.title == item.title && $0.detail == item.detail }) {
                result.append(item)
            }
        }
    }
}

private struct PiAgentStartupResourcesCard: View {
    @ObservedObject var viewModel: AppViewModel
    let session: PiAgentSessionRecord
    @State private var isExpanded = false

    var body: some View {
        AppRowCard {
            VStack(alignment: .leading, spacing: 16) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                } label: {
                    header
                }
                .buttonStyle(.plain)

                if isExpanded {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top, spacing: 10) {
                            resourceSection("Context", count: contextItems.count, icon: "doc.text", color: .blue, items: contextItems, columns: 2)
                            resourceSection("Environment", count: envItems.count, icon: "key", color: .green, items: envItems, columns: 2)
                        }
                        resourceSection("Agents", count: effectiveResourceCount(agentItems), icon: "rectangle.connected.to.line.below", color: .teal, items: agentItems, columns: 3, showsDetails: true)
                        resourceSection("Skills", count: effectiveResourceCount(skillItems), icon: "wand.and.stars", color: .purple, items: skillItems)
                        resourceSection("Prompts", count: effectiveResourceCount(promptItems), icon: "text.badge.star", color: .indigo, items: promptItems)
                        resourceSection("Extensions", count: extensionItems.count, icon: "puzzlepiece.extension", color: .orange, items: extensionItems)
                    }
                    .transition(.opacity)
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image("pi")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: 24, height: 24)
                .foregroundStyle(Color.accentColor)
                .padding(9)
                .background(Circle().fill(Color.accentColor.opacity(0.12)))

            VStack(alignment: .leading, spacing: 8) {
                Text("Pi startup resources")
                    .font(.title3.bold())
                    .fontWidth(.expanded)
                HStack(spacing: 6) {
                    hintChip("↩", "send / steer")
                    hintChip("⇧/⌘/⌥ ↩", "newline")
                    hintChip("Esc", "stop running turn")
                    hintChip("Esc Esc", "clear input")
                    hintChip("/", "commands")
                    hintChip("@", "file suggestions")
                }
            }
            Spacer()
            Image(systemName: "chevron.down")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(AppTheme.mutedText)
                .frame(width: 28, height: 28)
                .background(Circle().fill(AppTheme.contentSubtleFill))
                .rotationEffect(.degrees(isExpanded ? 180 : 0))
        }
        .contentShape(Rectangle())
    }

    private var contextItems: [PiStartupResourceItem] {
        let agents = URL(fileURLWithPath: session.projectPath).appendingPathComponent("AGENTS.md")
        if FileManager.default.fileExists(atPath: agents.path) {
            return [.init(title: "AGENTS.md", detail: agents.path, kind: .file(agents))]
        }
        return [.init(title: "No AGENTS.md detected", kind: .none)]
    }

    private var startupSnapshot: ScanSnapshot {
        viewModel.startupSnapshot(forProjectPath: session.projectPath)
    }

    private var agentItems: [PiStartupResourceItem] {
        guard session.subagentsEnabled else {
            return [.init(title: "This session started with subagents disabled", detail: "Re-enable subagents before creating a new session if you want agent discovery again.", kind: .none)]
        }

        let enabled = startupSnapshot.effectiveAgents
            .filter { $0.resolved.disabled != true }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return enabled.isEmpty
            ? [.init(title: "No enabled agents", kind: .none)]
            : enabled.map { agent in
                let description = agent.resolved.description.trimmingCharacters(in: .whitespacesAndNewlines)
                let modelSuffix = agent.resolved.model.map { " · \($0)" } ?? ""
                let source = agent.resolutionKind.rawValue
                let detail = [description, source + modelSuffix]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                return .init(title: agent.name, detail: detail, kind: .agent(agent.id))
            }
    }

    private var skillItems: [PiStartupResourceItem] {
        return startupSnapshot.skills
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { skill in
                let scope = skill.source.kind == .project ? "Project" : skill.source.kind.rawValue
                let detail = [scope, skill.description].compactMap { $0 }.joined(separator: " · ")
                return .init(title: skill.name, detail: detail, kind: .skill(skill.id))
            }
    }

    private var promptItems: [PiStartupResourceItem] {
        let commands = startupSnapshot.commands.map { PiStartupResourceItem(title: $0.invocation, detail: $0.description, kind: .command($0.id)) }
        let prompts = startupSnapshot.promptTemplates.map { PiStartupResourceItem(title: $0.invocation, detail: $0.description, kind: .prompt($0.id)) }
        return (commands + prompts).sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private var extensionItems: [PiStartupResourceItem] {
        let packageItems = Array(Set(startupSnapshot.settings.flatMap(\.packages)))
            .compactMap(extensionPackageItem)
        let fileItems = discoveredExtensionEntries().map { entry in
            PiStartupResourceItem(title: entry.title, detail: shortPath(entry.url.path), kind: .file(entry.url))
        }
        return (packageItems + fileItems)
            .uniqueByTitleAndDetail()
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private var envItems: [PiStartupResourceItem] {
        startupSnapshot.envKeys.map { env in
            let scope = env.source.kind.rawValue.lowercased()
            let title: String
            if let value = env.value, !value.isEmpty {
                title = "\(env.key) = \(masked(value)) · \(scope)"
            } else {
                title = "\(env.key) · \(scope)"
            }
            return .init(title: title, detail: env.source.path, kind: .environment)
        }
    }

    private func resourceSection(_ title: String, count: Int, icon: String, color: Color, items: [PiStartupResourceItem], columns: Int = 5, showsDetails: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .frame(width: 18)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }

            Grid(horizontalSpacing: 8, verticalSpacing: 7) {
                ForEach(Array(chunk(items, size: columns).enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(row) { item in
                            resourceChip(item, showsDetail: showsDetails)
                        }
                        ForEach(0..<max(columns - row.count, 0), id: \.self) { _ in
                            Color.clear.frame(height: 1)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AppTheme.contentSubtleFill.opacity(0.65))
                .stroke(AppTheme.contentStroke.opacity(0.8), lineWidth: 1)
        )
    }

    private func effectiveResourceCount(_ items: [PiStartupResourceItem]) -> Int {
        guard items.count == 1, let first = items.first else { return items.count }
        if case PiStartupResourceItem.Kind.none = first.kind {
            return 0
        }
        return items.count
    }

    private func chunk(_ items: [PiStartupResourceItem], size: Int) -> [[PiStartupResourceItem]] {
        stride(from: 0, to: items.count, by: max(size, 1)).map { start in
            Array(items[start..<min(start + max(size, 1), items.count)])
        }
    }

    private func hintChip(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.caption.monospaced().weight(.bold))
                .lineLimit(1)
                .foregroundStyle(.primary)
            Text(label)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(AppTheme.mutedText)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(minHeight: 26)
        .background(Capsule(style: .continuous).fill(AppTheme.contentSubtleFill))
    }

    private func resourceChip(_ item: PiStartupResourceItem, isOverflow: Bool = false, showsDetail: Bool = false) -> some View {
        Button {
            openResource(item)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.caption.monospaced().weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(isOverflow ? Color.accentColor : .primary)
                if showsDetail, let detail = item.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(AppTheme.mutedText)
                        .lineLimit(3)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, showsDetail ? 7 : 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isOverflow ? Color.accentColor.opacity(0.10) : AppTheme.contentFill.opacity(0.75))
            )
        }
        .buttonStyle(.plain)
        .disabled(!item.isClickable)
        .help(item.detail ?? item.title)
    }

    private func openResource(_ item: PiStartupResourceItem) {
        switch item.kind {
        case .agent(let id):
            viewModel.selectedAgentID = id
            viewModel.selectedSidebarItem = .agents
        case .skill(let id):
            viewModel.selectedSkillID = id
            viewModel.selectedSidebarItem = .skills
        case .command(let id), .prompt(let id):
            viewModel.selectedCommandItemID = id
            viewModel.selectedSidebarItem = .commandsAndPrompts
        case .extensions:
            viewModel.selectedSidebarItem = .settings
        case .environment:
            viewModel.selectedSidebarItem = .environment
        case .file(let url):
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .none:
            break
        }
    }

    private func shortExtensionName(_ value: String) -> String {
        if value.hasPrefix("npm:") { return String(value.dropFirst(4)) }
        if value.contains("/") { return URL(fileURLWithPath: value).lastPathComponent }
        return value
    }

    private func extensionPackageItem(_ package: String) -> PiStartupResourceItem? {
        let resolved = resolvePackageURL(package)
        if let resolved, !packageDeclaresExtensions(at: resolved) {
            return nil
        }
        let title = extensionPackageTitle(package, resolvedURL: resolved)
        return PiStartupResourceItem(title: title, detail: package, kind: .extensions)
    }

    private func extensionPackageTitle(_ package: String, resolvedURL: URL?) -> String {
        if let resolvedURL, let manifest = readPackageManifest(at: resolvedURL), let pi = manifest["pi"] as? [String: Any], let extensions = pi["extensions"] as? [String], extensions.count == 1 {
            return "\(shortExtensionName(package)):\(extensions[0].replacingOccurrences(of: "./", with: ""))"
        }
        return shortExtensionName(package)
    }

    private func packageDeclaresExtensions(at url: URL) -> Bool {
        guard let manifest = readPackageManifest(at: url) else { return false }
        if let pi = manifest["pi"] as? [String: Any], let extensions = pi["extensions"] as? [String], !extensions.isEmpty {
            return true
        }
        return extensionFiles(in: url.appendingPathComponent("extensions", isDirectory: true)).isEmpty == false
    }

    private func readPackageManifest(at url: URL) -> [String: Any]? {
        let manifestURL = url.appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: manifestURL) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func resolvePackageURL(_ package: String) -> URL? {
        let raw = package.hasPrefix("npm:") ? String(package.dropFirst(4)) : package
        if raw.hasPrefix("/") { return URL(fileURLWithPath: raw) }
        let candidates = [
            URL(fileURLWithPath: "/opt/homebrew/lib/node_modules").appendingPathComponent(raw),
            URL(fileURLWithPath: "/usr/local/lib/node_modules").appendingPathComponent(raw),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/npm/node_modules").appendingPathComponent(raw),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/git").appendingPathComponent(raw)
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private struct ExtensionEntry: Hashable {
        let title: String
        let url: URL
    }

    private func discoveredExtensionEntries() -> [ExtensionEntry] {
        let global = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/extensions", isDirectory: true)
        let project = URL(fileURLWithPath: session.projectPath).appendingPathComponent(".pi/extensions", isDirectory: true)
        return [global, project]
            .flatMap { extensionEntries(in: $0) }
            .reduce(into: [ExtensionEntry]()) { result, entry in
                if !result.contains(where: { $0.title == entry.title && $0.url.path == entry.url.path }) {
                    result.append(entry)
                }
            }
    }

    private func extensionEntries(in directory: URL) -> [ExtensionEntry] {
        guard let contents = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        return contents.compactMap { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values?.isRegularFile == true, isExtensionSourceFile(url) {
                return ExtensionEntry(title: url.lastPathComponent, url: url)
            }
            if values?.isDirectory == true, directoryContainsExtension(url) {
                return ExtensionEntry(title: url.lastPathComponent, url: url)
            }
            return nil
        }
    }

    private func directoryContainsExtension(_ directory: URL) -> Bool {
        if packageDeclaresExtensions(at: directory) { return true }
        return extensionFiles(in: directory).isEmpty == false
    }

    private func extensionFiles(in directory: URL) -> [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        return contents.filter(isExtensionSourceFile)
    }

    private func isExtensionSourceFile(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
        return values?.isRegularFile == true && ["ts", "js", "mjs", "cjs"].contains(url.pathExtension.lowercased())
    }

    private func shortPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    private func masked(_ value: String) -> String {
        guard value.count > 8 else { return "••••" }
        return String(value.prefix(4)) + "••••"
    }
}

private struct PiAgentFileSuggestion: Identifiable, Hashable {
    private static let maxScanResults = 40

    let id: String
    let relativePath: String
    let isDirectory: Bool

    static func scan(rootPath: String, query: String) -> [PiAgentFileSuggestion] {
        let rootURL = URL(fileURLWithPath: rootPath)
        let skippedDirectories: Set<String> = [".git", "node_modules", ".build", "DerivedData", ".swiftpm", ".venv"]
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var results: [PiAgentFileSuggestion] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if skippedDirectories.contains(name) {
                enumerator.skipDescendants()
                continue
            }

            let relative = url.path.replacingOccurrences(of: rootURL.path + "/", with: "")
            guard query.isEmpty || relative.lowercased().contains(query) else { continue }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            results.append(.init(id: url.path, relativePath: relative, isDirectory: values?.isDirectory == true))
            if results.count >= maxScanResults { break }
        }
        return results
    }
}

private struct PiAgentCommandSuggestions: View {
    let commands: [String]
    let skills: [String]
    let fileSuggestions: [PiAgentFileSuggestion]
    let onSelectFile: (PiAgentFileSuggestion) -> Void
    let onSelectCommand: (String) -> Void

    var body: some View {
        if !fileSuggestions.isEmpty {
            suggestionPanel(title: fileSuggestions.count >= 10 ? "Files — showing top 10, keep typing to refine" : "Files", icon: "paperclip", scrollable: true) {
                ForEach(fileSuggestions.prefix(10)) { suggestion in
                    Button { onSelectFile(suggestion) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: suggestion.isDirectory ? "folder" : "doc.text")
                                .frame(width: 14)
                            Text(suggestion.relativePath)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        } else if !commands.isEmpty || !skills.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if !commands.isEmpty {
                    suggestionPanel(title: "Slash commands", icon: "terminal") {
                        commandRows(commands)
                    }
                }
                if !skills.isEmpty {
                    suggestionPanel(title: "Skills", icon: "sparkles") {
                        skillRows(skills)
                    }
                }
            }
        }
    }

    private func commandRows(_ items: [String]) -> some View {
        ForEach(items, id: \.self) { command in
            Button { onSelectCommand(command) } label: {
                Text(command)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
    }

    private func skillRows(_ items: [String]) -> some View {
        ForEach(items, id: \.self) { command in
            Button { onSelectCommand(command) } label: {
                Text(command.replacingOccurrences(of: "/skill:", with: ""))
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
    }

    private func suggestionPanel<Content: View>(title: String, icon: String, scrollable: Bool = false, @ViewBuilder content: @escaping () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.mutedText)
            if scrollable {
                ScrollView {
                    suggestionRows(content: content)
                }
                .frame(maxHeight: 260)
            } else {
                suggestionRows(content: content)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppTheme.contentFill)
                .stroke(AppTheme.contentStroke, lineWidth: 1)
        )
    }

    private func suggestionRows<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            content()
                .font(.caption)
                .foregroundStyle(.primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(AppTheme.contentSubtleFill))
        }
    }
}

private struct PiAgentSkillUsePill: View {
    let skill: SkillRecord?
    let invocation: String
    @State private var isPreviewPresented = false

    var body: some View {
        Button {
            isPreviewPresented.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Color.purple)
                Text(skill?.name ?? invocation)
                    .font(.callout.weight(.semibold))
                Text("skill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(AppTheme.mutedText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(AppTheme.contentSubtleFill))
                Spacer(minLength: 0)
                Image(systemName: "info.circle")
                    .foregroundStyle(AppTheme.mutedText)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.purple.opacity(0.08)).stroke(Color.purple.opacity(0.18), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPreviewPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(skill?.name ?? invocation)
                    .font(.headline)
                if let description = skill?.description, !description.isEmpty {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Divider()
                ScrollView {
                    Text(skill?.body.isEmpty == false ? skill!.body : (skill?.filePath ?? "Skill details are not available in Pi Manager's current scan snapshot."))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 320)
            }
            .padding(14)
            .frame(width: 520, alignment: .leading)
        }
    }
}

private struct ShortcutComboHint: View {
    let symbols: [String]
    let text: String

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(symbols.enumerated()), id: \.offset) { index, symbol in
                if index > 0 {
                    Image(systemName: "plus")
                        .font(.system(size: 7, weight: .bold))
                }
                Image(systemName: symbol)
                    .font(.caption2.weight(.semibold))
            }
            Text(text)
                .font(.caption.weight(.medium))
                .fontWidth(.condensed)
        }
        .foregroundStyle(AppTheme.mutedText)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Capsule(style: .continuous).fill(AppTheme.contentSubtleFill))
    }
}

private struct PiAgentUIRequestCard: View {
    private let freeformSentinel = "✏️ Type custom response..."

    let request: PiAgentUIRequest
    let onSubmitValue: (String) -> Void
    let onSubmitFreeform: (String, String) -> Void
    let onConfirm: (Bool) -> Void
    let onCancel: () -> Void

    @State private var draft = ""
    @State private var isComposingFreeform = false
    @State private var selectedOptions: Set<String> = []

    var body: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 12) {
                header

                switch request.method {
                case .select:
                    isComposingFreeform ? AnyView(freeformComposer) : AnyView(selectOptions)
                case .multiSelect:
                    multiSelectOptions
                case .confirm:
                    HStack(spacing: 10) {
                        Button("No") { onConfirm(false) }
                        Button("Yes") { onConfirm(true) }
                            .buttonStyle(.borderedProminent)
                    }
                case .input, .editor:
                    textInput(submitTitle: "Submit", cancelTitle: "Cancel", cancelAction: onCancel) { onSubmitValue(draft) }
                }
            }
        }
        .onAppear {
            if draft.isEmpty, let prefill = request.prefill {
                draft = prefill
            }
        }
        .onChange(of: request.id) { _, _ in
            draft = request.prefill ?? ""
            isComposingFreeform = false
            selectedOptions = []
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "questionmark.bubble.fill")
                .foregroundStyle(Color.accentColor)
                .font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text(request.title)
                    .font(.headline)
                    .fontWidth(.expanded)
                if let message = request.message, !message.isEmpty, message != request.title {
                    Text(message)
                        .foregroundStyle(AppTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if request.method != .input && request.method != .editor && !isComposingFreeform {
                Button("Cancel", action: onCancel)
            }
        }
    }

    private var selectOptions: some View {
        Group {
            if request.options.isEmpty {
                emptyOptions
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(request.options, id: \.self) { option in
                        Button {
                            if option == freeformSentinel {
                                isComposingFreeform = true
                            } else {
                                onSubmitValue(option)
                            }
                        } label: {
                            HStack {
                                Text(option)
                                    .fontWeight(.semibold)
                                Spacer()
                                Image(systemName: option == freeformSentinel ? "square.and.pencil" : "arrow.right.circle.fill")
                                    .foregroundStyle(Color.accentColor)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(AppTheme.contentSubtleFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var freeformComposer: some View {
        textInput(submitTitle: "Submit", cancelTitle: "Back", cancelAction: {
            draft = ""
            isComposingFreeform = false
        }) {
            onSubmitFreeform(freeformSentinel, draft)
        }
    }

    private var multiSelectOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(request.options, id: \.self) { option in
                Button {
                    if selectedOptions.contains(option) {
                        selectedOptions.remove(option)
                    } else {
                        selectedOptions.insert(option)
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: selectedOptions.contains(option) ? "checkmark.square.fill" : "square")
                            .foregroundStyle(selectedOptions.contains(option) ? Color.accentColor : AppTheme.mutedText)
                        Text(option)
                            .fontWeight(.semibold)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(AppTheme.contentSubtleFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 10) {
                Spacer()
                Button("Submit") { onSubmitValue(request.options.filter { selectedOptions.contains($0) }.joined(separator: ", ")) }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedOptions.isEmpty)
            }
        }
    }

    private func textInput(submitTitle: String, cancelTitle: String, cancelAction: @escaping () -> Void, submitAction: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(request.placeholder ?? "Response", text: $draft, axis: request.method == .editor ? .vertical : .horizontal)
                .textFieldStyle(.roundedBorder)
                .lineLimit(request.method == .editor ? 4...10 : 1...3)
            HStack(spacing: 10) {
                Spacer()
                Button(cancelTitle, action: cancelAction)
                Button(submitTitle, action: submitAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var emptyOptions: some View {
        Text("Pi requested a selection, but no options were provided.")
            .foregroundStyle(AppTheme.mutedText)
    }
}

private struct PiAgentFileAttachment: Identifiable, Hashable {
    let id = UUID()
    let url: URL

    init?(url: URL) {
        guard !url.hasDirectoryPath else { return nil }
        self.url = url
    }
}

private struct PiSubagentSupervisorRequestCard: View {
    let request: PiSubagentSupervisorRequest
    let onRespond: (String) -> Void
    let onCancel: () -> Void
    @State private var response = ""
    @State private var structuredResponses: [String: String] = [:]

    var body: some View {
        AppRowCard {
            VStack(alignment: .leading, spacing: 10) {
                Label(request.title, systemImage: "questionmark.bubble")
                    .font(.headline)
                    .foregroundStyle(.orange)
                if let interview = structuredInterview {
                    if let intro = interview.prompt ?? interview.message, !intro.isEmpty {
                        Text(intro).font(.subheadline)
                    }
                    ForEach(interview.questions) { question in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(question.labelText)
                                .font(.caption.weight(.semibold))
                            if question.type == "info" {
                                Text(question.placeholder ?? "No response required.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                TextField(question.placeholder ?? "Response", text: binding(for: question.id), axis: .vertical)
                                    .textFieldStyle(.roundedBorder)
                                    .lineLimit(1...4)
                            }
                        }
                    }
                } else {
                    Text(request.message)
                        .font(.subheadline)
                    TextEditor(text: $response)
                        .frame(minHeight: 76)
                        .padding(6)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                }
                HStack {
                    Spacer()
                    Button("Cancel", action: onCancel)
                    Button("Send Response") { onRespond(responsePayload) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canRespond)
                }
            }
        }
    }

    private var structuredInterview: SupervisorInterviewPayload? {
        guard request.kind == .interviewRequest else { return nil }
        let trimmed = request.message.trimmingCharacters(in: .whitespacesAndNewlines)
        let jsonText: String
        if trimmed.hasPrefix("```") {
            jsonText = trimmed
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            jsonText = trimmed
        }
        guard let data = jsonText.data(using: .utf8),
              let payload = try? JSONDecoder().decode(SupervisorInterviewPayload.self, from: data),
              !payload.questions.isEmpty else { return nil }
        return payload
    }

    private var canRespond: Bool {
        if let interview = structuredInterview {
            return interview.questions.filter { $0.type != "info" && $0.required != false }.allSatisfy { !(structuredResponses[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        return !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var responsePayload: String {
        guard let interview = structuredInterview else { return response.trimmingCharacters(in: .whitespacesAndNewlines) }
        let responses = interview.questions
            .filter { $0.type != "info" }
            .map { ["id": $0.id, "value": (structuredResponses[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)] }
        let object: [String: Any] = ["responses": responses]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{\"responses\":[]}" }
        return text
    }

    private func binding(for id: String) -> Binding<String> {
        Binding(
            get: { structuredResponses[id] ?? "" },
            set: { structuredResponses[id] = $0 }
        )
    }

    private struct SupervisorInterviewPayload: Codable {
        var prompt: String?
        var message: String?
        var questions: [SupervisorInterviewQuestion]
    }

    private struct SupervisorInterviewQuestion: Codable, Identifiable {
        var id: String
        var label: String?
        var question: String?
        var type: String?
        var required: Bool?
        var placeholder: String?

        var labelText: String { label ?? question ?? id }
    }
}

private struct PiNativeSubagentRunCard: View {
    let run: PiSubagentRunRecord
    let onStop: () -> Void
    let onOpenTranscript: () -> Void
    let onReveal: () -> Void
    let onOpenGraph: () -> Void
    let onOpenWorktreePatch: () -> Void
    let onApplyWorktreePatch: () -> Void
    let onDiscardWorktree: () -> Void
    @State private var isDetailsPresented = false

    var body: some View {
        AppRowCard {
            VStack(alignment: .leading, spacing: 12) {
                header

                taskPreview

                if let summaryText {
                    answerPreview(summaryText)
                }

                if let children = run.children, !children.isEmpty {
                    childSummary(children)
                }

                if !compactMetadata.isEmpty {
                    HStack(spacing: 10) {
                        ForEach(compactMetadata) { item in
                            compactMetric(item)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.connected.to.line.below")
                .foregroundStyle(statusColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(run.agentName)
                    .font(.headline)
                Text(run.status.rawValue.capitalized)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor)
            }
            Spacer(minLength: 0)
            actionButtons
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        if run.children?.isEmpty == false {
            Button("Graph", action: onOpenGraph)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        Button("Transcript", action: onOpenTranscript)
            .buttonStyle(.bordered)
            .controlSize(.small)
        Button {
            isDetailsPresented.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(AppTheme.mutedText)
        .help("Run details")
        .popover(isPresented: $isDetailsPresented, arrowEdge: .trailing) {
            detailsPopover
        }
        if run.status.isActive {
            Button("Stop", action: onStop)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private var taskPreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Task", systemImage: "arrowshape.turn.up.forward.circle")
                .font(.caption.weight(.semibold))
                .fontWidth(.expanded)
                .foregroundStyle(Color.accentColor)

            MarkdownTextView(source: run.task)
                .lineLimit(3)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.accentColor.opacity(0.08))
                .stroke(Color.accentColor.opacity(0.18), lineWidth: 1)
        )
        .help(run.task)
    }

    @ViewBuilder
    private func answerPreview(_ text: String) -> some View {
        if run.status == .failed {
            Text(text)
                .font(.callout)
                .lineLimit(4)
                .truncationMode(.tail)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        } else if run.child?.currentTool != nil {
            Label(text, systemImage: "hammer")
                .font(.callout.weight(.medium))
                .foregroundStyle(AppTheme.mutedText)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Label("Answer", systemImage: "sparkles")
                    .font(.caption.weight(.semibold))
                    .fontWidth(.expanded)
                    .foregroundStyle(.purple)

                MarkdownTextView(source: text)
                    .lineLimit(5)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.purple.opacity(0.06))
                    .stroke(Color.purple.opacity(0.18), lineWidth: 1)
            )
        }
    }

    private var summaryText: String? {
        if let currentTool = run.child?.currentTool {
            return "Running tool: \(currentTool)"
        }
        if let error = run.error, !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return error
        }
        guard let summary = run.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty else { return nil }
        return summary == "Completed without a text summary." ? nil : summary
    }

    private var detailRows: [(String, String)] {
        var rows: [(String, String)] = [
            ("Started", run.createdAt.formatted(date: .abbreviated, time: .shortened)),
            ("Context", "requested \(run.requestedContext.rawValue), resolved \(run.resolvedContext.rawValue)")
        ]
        if let completedAt = run.completedAt {
            rows.append(("Completed", completedAt.formatted(date: .abbreviated, time: .shortened)))
        }
        if let duration = run.durationMs {
            rows.append(("Duration", formattedDuration(duration)))
        }
        if let totalTokens {
            rows.append(("Tokens", compactNumber(totalTokens)))
        }
        if let toolCount {
            rows.append(("Tools", "\(toolCount)"))
        }
        if let modelName {
            rows.append(("Model", modelName))
        }
        if let thinkingLevel {
            rows.append(("Thinking", thinkingLevel))
        }
        if let expectedOutcome = run.expectedOutcome {
            rows.append(("Outcome", expectedOutcome.displayName + (run.requestedOutputPath.map { " · \($0)" } ?? "")))
        }
        if let reads = run.readFirstPaths, !reads.isEmpty {
            rows.append(("Read first", reads.joined(separator: ", ")))
        }
        if run.isWorktreeIsolated == true {
            rows.append(("Worktree status", (run.worktreeStatus ?? .active).rawValue))
        }
        appendPath("Worktree", run.worktreePath, to: &rows)
        appendPath("Patch", run.worktreePatchPath, to: &rows)
        appendPath("Output", run.outputPath, to: &rows)
        appendPath("Run folder", run.artifactDirectory, to: &rows)
        appendPath("Child session", run.childPiSessionFile, to: &rows)
        return rows
    }

    private func appendPath(_ label: String, _ value: String?, to rows: inout [(String, String)]) {
        guard let value, !value.isEmpty else { return }
        rows.append((label, value))
    }

    private var detailsPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Run details", systemImage: "info.circle")
                .font(.headline)

            AppKeyValueList(rows: detailRows)

            if hasDetailActions {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Actions")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.mutedText)

                    if !run.artifactDirectory.isEmpty {
                        Button("Reveal Run Folder", action: onReveal)
                        Button("Open Output", action: { openArtifact(named: "output.md") })
                            .disabled(!canOpenArtifact(named: "output.md"))
                        Button("Open Input", action: { openArtifact(named: "input.md") })
                            .disabled(!canOpenArtifact(named: "input.md"))
                        Button("Open System Prompt", action: { openArtifact(named: "system-prompt.md") })
                            .disabled(!canOpenArtifact(named: "system-prompt.md"))
                    }
                    if canReviewWorktree {
                        Button("Generate/Open Worktree Patch", action: onOpenWorktreePatch)
                        Button("Apply Worktree Patch", action: onApplyWorktreePatch)
                    }
                    if canDiscardWorktree {
                        Button("Discard Worktree", role: .destructive, action: onDiscardWorktree)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(16)
        .frame(width: 430, alignment: .leading)
    }

    private var hasDetailActions: Bool {
        !run.artifactDirectory.isEmpty || canReviewWorktree || canDiscardWorktree
    }

    private struct CompactMetadataItem: Identifiable {
        let id = UUID()
        let text: String
        let icon: String
    }

    private var compactMetadata: [CompactMetadataItem] {
        var items: [CompactMetadataItem] = []
        if let duration = run.durationMs {
            items.append(.init(text: formattedDuration(duration), icon: "timer"))
        }
        if let totalTokens {
            items.append(.init(text: compactNumber(totalTokens), icon: "tugriksign.circle"))
        }
        if let toolCount {
            items.append(.init(text: "\(toolCount)", icon: "wrench.and.screwdriver"))
        }
        items.append(.init(text: run.resolvedContext.rawValue, icon: "viewfinder"))
        if let expectedOutcome = run.expectedOutcome {
            items.append(.init(text: shortOutcomeName(expectedOutcome), icon: "target"))
        }
        if let modelName {
            items.append(.init(text: modelName, icon: "cpu"))
        }
        if let thinkingLevel {
            items.append(.init(text: thinkingLevel, icon: "brain.head.profile"))
        }
        return items
    }

    private var totalTokens: Int? {
        if let total = run.child?.totalTokens { return total }
        let totals = run.children?.compactMap(\.totalTokens) ?? []
        guard !totals.isEmpty else { return nil }
        return totals.reduce(0, +)
    }

    private var toolCount: Int? {
        if let count = run.child?.toolCount { return count }
        let counts = run.children?.compactMap(\.toolCount) ?? []
        guard !counts.isEmpty else { return nil }
        return counts.reduce(0, +)
    }

    private var modelName: String? {
        let value = run.model ?? run.child?.model ?? run.children?.compactMap(\.model).first
        return nonEmpty(value)
    }

    private var thinkingLevel: String? {
        nonEmpty(run.thinking)
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func compactMetric(_ item: CompactMetadataItem) -> some View {
        HStack(spacing: 3) {
            Image(systemName: item.icon)
                .font(.caption2.weight(.semibold))
            Text(item.text)
                .lineLimit(1)
        }
    }

    private func shortOutcomeName(_ outcome: PiSubagentExpectedOutcome) -> String {
        switch outcome {
        case .reportOnly: return "report"
        case .editFilesInWorktree: return "worktree"
        case .writeProjectFile: return "file write"
        case .directProjectWrites: return "direct edit"
        }
    }

    private func childSummary(_ children: [PiSubagentChildRecord]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(children.sorted { $0.index < $1.index }) { child in
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(color(for: child.status))
                        .frame(width: 7, height: 7)
                        .padding(.top, 5)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(child.index + 1). \(child.agentName) · \(child.status.rawValue)")
                            .font(.caption.weight(.semibold))
                        if let summary = child.summary ?? child.error, !summary.isEmpty {
                            Text(summary)
                                .font(.caption2)
                                .lineLimit(2)
                                .foregroundStyle(AppTheme.mutedText)
                        }
                    }
                }
            }
        }
        .padding(8)
        .background(AppTheme.contentSubtleFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func artifactURL(named fileName: String) -> URL {
        URL(fileURLWithPath: run.artifactDirectory).appendingPathComponent(fileName)
    }

    private func canOpenArtifact(named fileName: String) -> Bool {
        FileManager.default.fileExists(atPath: artifactURL(named: fileName).path)
    }

    private func openArtifact(named fileName: String) {
        NSWorkspace.shared.open(artifactURL(named: fileName))
    }

    private var canReviewWorktree: Bool {
        run.isWorktreeIsolated == true && !run.status.isActive && run.worktreeStatus != .discarded
    }

    private var canDiscardWorktree: Bool {
        run.isWorktreeIsolated == true && run.worktreeStatus != .discarded
    }

    private func formattedDuration(_ milliseconds: Int) -> String {
        let seconds = max(0, milliseconds) / 1000
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        let remainder = seconds % 60
        if minutes < 60 { return "\(minutes)m \(remainder)s" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    private func compactNumber(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return "\(value / 1_000)k" }
        return "\(value)"
    }

    private func color(for status: PiSubagentRunStatus) -> Color {
        switch status {
        case .queued, .starting, .running:
            return .blue
        case .blocked:
            return .orange
        case .completed:
            return .green
        case .failed:
            return .red
        case .stopped, .disconnected:
            return .secondary
        }
    }

    private var statusColor: Color {
        switch run.status {
        case .queued, .starting, .running:
            return .blue
        case .blocked:
            return .orange
        case .completed:
            return .green
        case .failed:
            return .red
        case .stopped, .disconnected:
            return .secondary
        }
    }
}

private struct PiNativeSubagentGraphSheet: View {
    let run: PiSubagentRunRecord
    let onStopGraph: () -> Void
    let onStopChild: (PiSubagentChildRecord) -> Void
    let onRetryChild: (PiSubagentChildRecord) -> Void
    let onOpenChildArtifacts: (PiSubagentChildRecord) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Native Graph · \(run.agentName)")
                        .font(.title3.bold())
                    Text("\(run.mode.rawValue.capitalized) · \(run.status.rawValue.capitalized) · \(run.children?.count ?? 0) child runs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if run.status.isActive {
                    Button("Stop Graph", role: .destructive, action: onStopGraph)
                        .buttonStyle(.bordered)
                }
            }
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach((run.children ?? []).sorted { $0.index < $1.index }) { child in
                        graphChildCard(child)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let summary = run.aggregateSummary ?? run.summary, !summary.isEmpty {
                Divider()
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(5)
            }
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 520)
    }

    private func graphChildCard(_ child: PiSubagentChildRecord) -> some View {
        AppRowCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Circle().fill(color(for: child.status)).frame(width: 9, height: 9)
                    Text("\(child.index + 1). \(child.agentName)")
                        .font(.headline)
                    AppLabelTag(text: child.status.rawValue, color: color(for: child.status))
                    Spacer()
                    if child.status.isActive {
                        Button("Stop") { onStopChild(child) }
                            .controlSize(.small)
                    }
                    if [.failed, .stopped, .disconnected].contains(child.status) {
                        Button("Retry") { onRetryChild(child) }
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                    }
                    Button("Artifacts") { onOpenChildArtifacts(child) }
                        .controlSize(.small)
                        .disabled(child.artifactDirectory == nil)
                }
                if let task = child.task, !task.isEmpty {
                    Text(task)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                if let summary = child.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.caption)
                        .lineLimit(4)
                } else if let error = child.error, !error.isEmpty {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(4)
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 4) {
                    graphMeta("Output", child.outputPath)
                    graphMeta("Worktree", child.worktreePath)
                    graphMeta("Execution", child.executionRunID?.uuidString)
                    graphMeta("Duration", child.durationMs.map(formattedDuration))
                }
            }
        }
    }

    private func graphMeta(_ title: String, _ value: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("\(title):")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value ?? "—")
                .font(.caption2.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(AppTheme.mutedText)
        }
    }

    private func formattedDuration(_ milliseconds: Int) -> String {
        let seconds = max(0, milliseconds) / 1000
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m \(seconds % 60)s"
    }

    private func color(for status: PiSubagentRunStatus) -> Color {
        switch status {
        case .queued, .starting, .running: return .blue
        case .blocked: return .orange
        case .completed: return .green
        case .failed: return .red
        case .stopped, .disconnected: return .secondary
        }
    }
}

private struct PiNativeSubagentTranscriptSheet: View {
    let run: PiSubagentRunRecord
    let entries: [PiAgentTranscriptEntry]
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var showExecutionLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Subagent transcript")
                        .font(.title3.bold())
                    Text("\(run.agentName) · \(run.status.rawValue.capitalized)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(statusColor)
                }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(AppTheme.mutedText)
                TextField("Search task, answer, or execution log", text: $query)
                    .textFieldStyle(.roundedBorder)
            }

            Divider()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    transcriptSection(title: "Task", systemImage: "person.crop.circle", color: .blue) {
                        Text(run.task)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    transcriptSection(title: "Answer", systemImage: "sparkles", color: .green) {
                        if let answer = finalAnswer {
                            Text(answer)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text("No final answer was captured for this run. Older runs may have completed before final-answer capture was fixed.")
                                .foregroundStyle(AppTheme.mutedText)
                        }
                    }

                    DisclosureGroup(isExpanded: $showExecutionLog) {
                        VStack(alignment: .leading, spacing: 8) {
                            if filteredActivityEntries.isEmpty {
                                Text("No matching execution events.")
                                    .foregroundStyle(AppTheme.mutedText)
                            } else {
                                ForEach(filteredActivityEntries) { entry in
                                    executionRow(entry)
                                }
                            }
                        }
                        .padding(.top, 8)
                    } label: {
                        Label("Execution log", systemImage: "terminal")
                            .font(.headline)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(22)
        .frame(width: 820, height: 620)
    }

    private var finalAnswer: String? {
        let summary = run.summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let summary, !summary.isEmpty, summary != "Completed without a text summary." { return summary }
        return entries.reversed().first { $0.role == .assistant && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?.text
    }

    private var filteredActivityEntries: [PiAgentTranscriptEntry] {
        let activity = entries.filter { entry in
            switch entry.role {
            case .tool, .status, .error, .stderr, .raw: return true
            case .assistant: return entry.text != finalAnswer
            case .user, .thinking: return false
            }
        }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return activity }
        return activity.filter { "\($0.title)\n\($0.text)".lowercased().contains(needle) }
    }

    private func transcriptSection<Content: View>(title: String, systemImage: String, color: Color, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(color)
            content()
        }
        .padding(14)
        .background(AppTheme.contentSubtleFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func executionRow(_ entry: PiAgentTranscriptEntry) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                AppLabelTag(text: label(for: entry.role), color: color(for: entry.role))
                Text(entry.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.mutedText)
                Spacer(minLength: 0)
                Text(entry.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(AppTheme.mutedText)
            }
            if !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(entry.text)
                    .font(.caption)
                    .textSelection(.enabled)
                    .lineLimit(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .background(AppTheme.contentFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func label(for role: PiAgentTranscriptRole) -> String {
        switch role {
        case .assistant: return "answer"
        case .tool: return "tool"
        case .status: return "status"
        case .error: return "error"
        case .stderr: return "stderr"
        case .raw: return "raw"
        case .user: return "task"
        case .thinking: return "thinking"
        }
    }

    private func color(for role: PiAgentTranscriptRole) -> Color {
        switch role {
        case .assistant: return .green
        case .tool: return .purple
        case .status: return .blue
        case .error, .stderr: return .red
        case .raw, .thinking, .user: return AppTheme.mutedText
        }
    }

    private var statusColor: Color {
        switch run.status {
        case .queued, .starting, .running: return .blue
        case .blocked: return .orange
        case .completed: return .green
        case .failed: return .red
        case .stopped, .disconnected: return AppTheme.mutedText
        }
    }
}

private struct PiNativeSubagentRunSheet: View {
    struct AgentInfo: Hashable {
        let description: String
        let model: String?
        let thinking: String?
        let defaultContext: String?
        let inheritProjectContext: Bool
        let inheritSkills: Bool
        let tools: [String]
        let skills: [String]
        let output: String?

        init(agent: EffectiveAgentRecord) {
            description = agent.resolved.description
            model = agent.resolved.model
            thinking = agent.resolved.thinking
            defaultContext = agent.resolved.defaultContext
            inheritProjectContext = agent.resolved.inheritProjectContext == true
            inheritSkills = agent.resolved.inheritSkills == true
            tools = agent.resolved.tools ?? []
            skills = agent.resolved.skills
            output = agent.resolved.output
        }
    }

    let agentNames: [String]
    let agentInfos: [String: AgentInfo]
    @Binding var selectedAgentName: String
    @Binding var task: String
    @Binding var useWorktreeIsolation: Bool
    @Binding var allowDirectProjectWrites: Bool
    @Binding var expectedOutcome: PiSubagentExpectedOutcome
    @Binding var requestedOutputPath: String
    @Binding var allowOverwrite: Bool
    @Binding var readFirstPathsText: String
    let projectRootPath: String?
    let onCancel: () -> Void
    let onRun: (String, String, Bool, Bool, PiSubagentExpectedOutcome, String?, Bool, [String]) -> Void
    @State private var isReadFirstDropTargeted = false

    private var canRun: Bool {
        !selectedAgentName.isEmpty && !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && outputPolicyError == nil
    }

    private var selectedInfo: AgentInfo? {
        agentInfos[selectedAgentName]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.connected.to.line.below")
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Run Subagent")
                        .font(.title3.bold())
                    Text("Launches a separate Pi RPC child session managed by Pi Manager. This does not insert or send a raw /run command.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Picker("Agent", selection: $selectedAgentName) {
                ForEach(agentNames, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .pickerStyle(.menu)
            .disabled(agentNames.isEmpty)

            if let selectedInfo {
                VStack(alignment: .leading, spacing: 8) {
                    Text(selectedInfo.description.isEmpty ? "No description" : selectedInfo.description)
                        .font(.subheadline)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 6) {
                        subagentInfoLine("Model", selectedInfo.model ?? "Default")
                        subagentInfoLine("Thinking", selectedInfo.thinking ?? "Default")
                        subagentInfoLine("Context", selectedInfo.defaultContext ?? "fresh")
                        subagentInfoLine("Project Context", selectedInfo.inheritProjectContext ? "Inherited" : "Off")
                        subagentInfoLine("Ambient Skills", selectedInfo.inheritSkills ? "Inherited" : "Off")
                        subagentInfoLine("Private Skills", selectedInfo.skills.isEmpty ? "None" : selectedInfo.skills.joined(separator: ", "))
                        subagentInfoLine("Tools", selectedInfo.tools.isEmpty ? "Default" : selectedInfo.tools.joined(separator: ", "))
                        subagentInfoLine("Output", selectedInfo.output ?? "App artifact")
                    }
                    if selectedInfo.output != nil {
                        Label("Native runs save the final response to app artifacts by default. Project-file output should be explicit in the task.", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(10)
                .appContentSurface(cornerRadius: 12)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Task")
                    .font(.headline)
                TextEditor(text: $task)
                    .font(.body)
                    .frame(minHeight: 140)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("Files to read first", systemImage: "doc.text.magnifyingglass")
                    .font(.subheadline.weight(.semibold))
                HStack(alignment: .top, spacing: 8) {
                    TextField("Optional project-relative paths, comma or newline separated", text: $readFirstPathsText, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                    Button(action: addReadFirstPathsFromOpenPanel) {
                        Image(systemName: "paperclip")
                    }
                    .help("Add project files to read first")
                    .accessibilityLabel("Add project files to read first")
                    .disabled(projectRootPath == nil)
                }
                if !readFirstFileSuggestions.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(readFirstFileSuggestions.prefix(8)) { suggestion in
                            Button {
                                insertReadFirstSuggestion(suggestion)
                            } label: {
                                Label(suggestion.relativePath, systemImage: "doc.text")
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .font(.caption)
                        }
                    }
                    .padding(.horizontal, 6)
                    if readFirstFileSuggestions.count > 8 {
                        Text("Showing top 8 — keep typing to refine")
                            .font(.caption2)
                            .italic()
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                    }
                }
                Text("Use this for files the caller knows are relevant now. Type @ to search project files, use the paperclip, or drag files here. Defaults from the agent are treated as hints only; Pi Manager does not inject stale file contents.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .appContentSurface(cornerRadius: 12)
            .overlay {
                if isReadFirstDropTargeted {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.accentColor, lineWidth: 2)
                        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $isReadFirstDropTargeted) { providers in
                loadReadFirstDroppedFiles(from: providers)
                return true
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("Native run", systemImage: "checkmark.seal")
                    .font(.subheadline.weight(.semibold))
                Text("Pi Manager starts and tracks the child session directly, records artifacts under Application Support, and posts a status/result entry back to the parent transcript.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Expected outcome", selection: $expectedOutcome) {
                    ForEach(PiSubagentExpectedOutcome.allCases) { outcome in
                        Text(outcome.displayName).tag(outcome)
                    }
                }
                .pickerStyle(.menu)
                Toggle("Use git worktree isolation", isOn: $useWorktreeIsolation)
                    .font(.caption)
                Text("Creates a detached git worktree inside the run artifacts so child file edits are isolated from the main checkout.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if expectedOutcome == .writeProjectFile {
                    TextField("Project-relative output path, e.g. docs/plan.md", text: $requestedOutputPath)
                        .textFieldStyle(.roundedBorder)
                    Toggle("Allow overwrite if the file exists", isOn: $allowOverwrite)
                        .font(.caption)
                }
                Toggle("Allow direct project writes without a worktree", isOn: $allowDirectProjectWrites)
                    .font(.caption)
                    .disabled(useWorktreeIsolation || expectedOutcome != .directProjectWrites)
                if let outputPolicyError {
                    Label(outputPolicyError, systemImage: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(10)
            .appContentSurface(cornerRadius: 12)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Run") {
                    let trimmedOutputPath = requestedOutputPath.trimmingCharacters(in: .whitespacesAndNewlines)
                    onRun(selectedAgentName, task, useWorktreeIsolation, allowDirectProjectWrites, expectedOutcome, trimmedOutputPath.isEmpty ? nil : trimmedOutputPath, allowOverwrite, parsedReadFirstPaths)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canRun)
            }
        }
        .padding(22)
        .frame(width: 600)
        .onAppear {
            if selectedAgentName.isEmpty {
                selectedAgentName = agentNames.first ?? ""
            }
        }
        .onChange(of: useWorktreeIsolation) { _, enabled in
            if enabled { allowDirectProjectWrites = false }
            syncOutcomeSafetyDefaults()
        }
        .onChange(of: expectedOutcome) { _, _ in syncOutcomeSafetyDefaults() }
    }

    private var readFirstSuggestionToken: (query: String, range: Range<String.Index>)? {
        let nsText = readFirstPathsText as NSString
        let tokenRange = nsText.range(of: "(^|[,\\n\\s])@[^,\\n\\s]*$", options: .regularExpression)
        guard tokenRange.location != NSNotFound,
              let range = Range(tokenRange, in: readFirstPathsText) else { return nil }
        let token = String(readFirstPathsText[range])
        guard let atIndex = token.lastIndex(of: "@") else { return nil }
        return (String(token[token.index(after: atIndex)...]).lowercased(), range)
    }

    private var readFirstFileSuggestions: [PiAgentFileSuggestion] {
        guard let projectRootPath, let token = readFirstSuggestionToken else { return [] }
        return PiAgentFileSuggestion.scan(rootPath: projectRootPath, query: token.query)
    }

    private func insertReadFirstSuggestion(_ suggestion: PiAgentFileSuggestion) {
        guard let token = readFirstSuggestionToken else { return }
        let prefix = readFirstPathsText[token.range].prefix { $0 != "@" }
        readFirstPathsText.replaceSubrange(token.range, with: "\(prefix)\(suggestion.relativePath)")
        if !readFirstPathsText.hasSuffix("\n") { readFirstPathsText += "\n" }
    }

    private func addReadFirstPathsFromOpenPanel() {
        guard let projectRootPath else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.item]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = URL(fileURLWithPath: projectRootPath)
        guard panel.runModal() == .OK else { return }
        appendReadFirstURLs(panel.urls)
    }

    private func loadReadFirstDroppedFiles(from providers: [NSItemProvider]) {
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                guard let url else { return }
                DispatchQueue.main.async { appendReadFirstURLs([url]) }
            }
        }
    }

    private func appendReadFirstURLs(_ urls: [URL]) {
        guard let projectRootPath else { return }
        let rootURL = URL(fileURLWithPath: projectRootPath).standardizedFileURL
        let rootPath = rootURL.path
        let relatives = urls.filter { !$0.hasDirectoryPath }.compactMap { url -> String? in
            let standardized = url.standardizedFileURL.path
            guard standardized.hasPrefix(rootPath + "/") else { return nil }
            return String(standardized.dropFirst(rootPath.count + 1))
        }
        guard !relatives.isEmpty else { return }
        var current = parsedReadFirstPaths
        for relative in relatives where !current.contains(relative) { current.append(relative) }
        readFirstPathsText = current.joined(separator: "\n")
    }

    private var parsedReadFirstPaths: [String] {
        readFirstPathsText
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var outputPolicyError: String? {
        switch expectedOutcome {
        case .reportOnly:
            return nil
        case .editFilesInWorktree:
            return useWorktreeIsolation ? nil : "Editing files should use worktree isolation."
        case .writeProjectFile:
            return requestedOutputPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Choose the project-relative file to write or update." : nil
        case .directProjectWrites:
            return allowDirectProjectWrites ? nil : "Direct project writes require explicit approval."
        }
    }

    private func syncOutcomeSafetyDefaults() {
        switch expectedOutcome {
        case .editFilesInWorktree, .writeProjectFile:
            useWorktreeIsolation = true
            allowDirectProjectWrites = false
        case .directProjectWrites:
            useWorktreeIsolation = false
        case .reportOnly:
            allowDirectProjectWrites = false
        }
    }

    private func subagentInfoLine(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(title):")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

private struct PiAgentComposerBox: View {
    private let maxImages = 8

    @Binding var text: String
    @Binding var images: [PiAgentImageAttachment]
    @Binding var files: [PiAgentFileAttachment]
    @Binding var attachmentError: String?
    @Binding var inputMode: PiAgentInputMode
    let isRunning: Bool
    let isDisabled: Bool
    let placeholder: String
    let canSend: Bool
    let path: String?
    let onFiles: ([URL]) -> Void
    let subagentNames: [String]
    let subagentsEnabled: Bool
    let subagentsEnabledForNewSessions: Bool
    let onSetSessionSubagentsEnabled: (Bool) -> Void
    let onSetNewSessionSubagentsEnabled: (Bool) -> Void
    let onSelectSubagent: (String) -> Void
    let footer: AnyView?
    let metricsFooter: AnyView?
    let onSend: () -> Void
    let onStop: () -> Void
    let onClear: () -> Void
    @State private var isDropTargeted = false
    @State private var isSubagentPopoverPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !images.isEmpty || !files.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(images) { image in
                            PiAgentImageAttachmentThumbnail(image: image) {
                                images.removeAll { $0.id == image.id }
                            }
                        }
                        ForEach(files) { file in
                            PiAgentFileAttachmentChip(file: file) {
                                files.removeAll { $0.id == file.id }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                }
            }

            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.body)
                        .foregroundStyle(AppTheme.mutedText.opacity(0.72))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .allowsHitTesting(false)
                }
                PiAgentDropSafeTextEditor(
                    text: $text,
                    onDropTargeted: { isDropTargeted = $0 },
                    onImages: addImages,
                    onFiles: onFiles,
                    onUnsupportedDrop: { attachmentError = "Drop images or UTF-8 text files." },
                    onSend: onSend,
                    onClear: onClear,
                    isDisabled: isDisabled
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(minHeight: 92, maxHeight: 132)
            }

            if let attachmentError {
                Label(attachmentError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }

            VStack(spacing: 10) {
                if let footer {
                    HStack(spacing: 10) {
                        footer
                        composerActionControls

                        Spacer(minLength: 18)
                        PiAgentSendButton(isRunning: isRunning, canSend: canSend && !isDisabled, sendAction: onSend, stopAction: onStop)
                            .keyboardShortcut(.return, modifiers: [])
                    }
                }

                HStack(alignment: .center, spacing: 10) {
                    if let path {
                        HStack(spacing: 6) {
                            Image(systemName: "folder")
                            Text(shortPath(path))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedText)
                        .help(path)
                    }

                    if let metricsFooter {
                        metricsFooter
                    }

                    Spacer(minLength: 8)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .appContentSurface(cornerRadius: 20)
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(isDropTargeted ? Color.accentColor.opacity(0.7) : Color.clear, lineWidth: isDropTargeted ? 2 : 1)
        )
        .overlay {
            if isDropTargeted {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.accentColor.opacity(0.10))
                        .allowsHitTesting(false)
            }
            if isDisabled {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(AppTheme.contentFill.opacity(0.35))
                    .allowsHitTesting(false)
            }
        }
        .shadow(color: .black.opacity(0.05), radius: 14, x: 0, y: 7)
        .onPasteCommand(of: [.png, .jpeg, .tiff, .gif, .webP, .fileURL]) { _ in
            addImages(PiAgentComposerImageLoader.imagesFromPasteboard())
        }
        .onDrop(of: [.fileURL, .png, .jpeg, .tiff, .gif, .webP, .image, .plainText, .utf8PlainText], isTargeted: $isDropTargeted) { providers in
            PiAgentComposerImageLoader.loadDropItems(from: providers) { attachments, files in
                if attachments.isEmpty && files.isEmpty {
                    attachmentError = "Drop images or UTF-8 text files."
                } else {
                    addImages(attachments)
                    onFiles(files)
                }
            }
            return true
        }
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var composerActionControls: some View {
        AppGlassControlGroup(spacing: 6) {
            Button(action: attachImagesFromOpenPanel) {
                Image(systemName: "paperclip")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppTheme.mutedText)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .appGlassControl(cornerRadius: 15)
            .help("Attach images or UTF-8 text files")
            .accessibilityLabel("Attach files")
            .accessibilityHint("Attach images or UTF-8 text files")

            Button {
                isSubagentPopoverPresented.toggle()
            } label: {
                Image(systemName: "rectangle.connected.to.line.below")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(subagentsEnabled ? Color.accentColor : AppTheme.mutedText)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .appGlassControl(cornerRadius: 15)
            .help(subagentsEnabled ? "Run or disable native subagents" : "Native subagents are disabled")
            .accessibilityLabel("Native subagents")
            .accessibilityHint(subagentsEnabled ? "Run or disable native subagents" : "Native subagents are disabled")
            .popover(isPresented: $isSubagentPopoverPresented, arrowEdge: .bottom) {
                PiAgentSubagentPopover(
                    agentNames: subagentNames,
                    isEnabled: Binding(
                        get: { subagentsEnabled },
                        set: { isEnabled in
                            onSetSessionSubagentsEnabled(isEnabled)
                            onSetNewSessionSubagentsEnabled(isEnabled)
                        }
                    ),
                    onSelectAgent: { agentName in
                        isSubagentPopoverPresented = false
                        onSelectSubagent(agentName)
                    }
                )
            }
        }
    }

    private func attachImagesFromOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.item]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK else { return }
        let imageAttachments = panel.urls.compactMap { PiAgentComposerImageLoader.imageAttachment(fromFileURL: $0) }
        let files = panel.urls.filter { PiAgentComposerImageLoader.imageAttachment(fromFileURL: $0) == nil }
        addImages(imageAttachments)
        onFiles(files)
    }

    private func shortPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    private func addImages(_ newImages: [PiAgentImageAttachment]) {
        guard !newImages.isEmpty else { return }
        attachmentError = nil
        var next = images
        for image in newImages {
            if next.count >= maxImages {
                attachmentError = "Pi supports up to \(maxImages) images per message."
                break
            }
            if !next.contains(where: { $0.data == image.data }) {
                next.append(image)
            }
        }
        images = next
    }
}

private struct PiAgentDropSafeTextEditor: NSViewRepresentable {
    @Binding var text: String
    var onDropTargeted: (Bool) -> Void
    var onImages: ([PiAgentImageAttachment]) -> Void
    var onFiles: ([URL]) -> Void
    var onUnsupportedDrop: () -> Void
    var onSend: () -> Void
    var onClear: () -> Void
    var isDisabled: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder

        let textView = DropSafeNSTextView()
        textView.delegate = context.coordinator
        textView.string = text
        textView.font = NSFont.preferredFont(forTextStyle: .body)
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isEditable = !isDisabled
        textView.importsGraphics = false
        textView.allowsImageEditing = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.dropHandler = context.coordinator
        textView.keyHandler = context.coordinator

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? DropSafeNSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        textView.isEditable = !isDisabled
        textView.dropHandler = context.coordinator
        textView.keyHandler = context.coordinator
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, DropSafeNSTextViewDropHandler, DropSafeNSTextViewKeyHandler {
        var parent: PiAgentDropSafeTextEditor

        init(parent: PiAgentDropSafeTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func setDropTargeted(_ targeted: Bool) {
            parent.onDropTargeted(targeted)
        }

        func handleDrop(_ pasteboard: NSPasteboard) -> Bool {
            let images = PiAgentComposerImageLoader.imagesFromPasteboard(pasteboard)
            let files = PiAgentComposerImageLoader.fileURLs(from: pasteboard).filter { url in
                PiAgentComposerImageLoader.imageAttachment(fromFileURL: url) == nil
            }
            if images.isEmpty && files.isEmpty {
                parent.onUnsupportedDrop()
                return false
            }
            parent.onImages(images)
            parent.onFiles(files)
            return true
        }

        func send() {
            guard !parent.isDisabled else { return }
            parent.onSend()
        }

        func clear() {
            guard !parent.isDisabled else { return }
            parent.onClear()
        }
    }
}

@MainActor
private protocol DropSafeNSTextViewDropHandler: AnyObject {
    func setDropTargeted(_ targeted: Bool)
    func handleDrop(_ pasteboard: NSPasteboard) -> Bool
}

@MainActor
private protocol DropSafeNSTextViewKeyHandler: AnyObject {
    func send()
    func clear()
}

private final class DropSafeNSTextView: NSTextView {
    weak var dropHandler: DropSafeNSTextViewDropHandler?
    weak var keyHandler: DropSafeNSTextViewKeyHandler?
    private var lastEscapeAt: TimeInterval?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard acceptsDrop(sender.draggingPasteboard) else {
            return super.draggingEntered(sender)
        }
        dropHandler?.setDropTargeted(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard acceptsDrop(sender.draggingPasteboard) else {
            return super.draggingUpdated(sender)
        }
        dropHandler?.setDropTargeted(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropHandler?.setDropTargeted(false)
        super.draggingExited(sender)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        dropHandler?.setDropTargeted(false)
        super.draggingEnded(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard acceptsDrop(sender.draggingPasteboard) else {
            return super.performDragOperation(sender)
        }
        dropHandler?.setDropTargeted(false)
        return dropHandler?.handleDrop(sender.draggingPasteboard) ?? false
    }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.charactersIgnoringModifiers == "\r" || event.charactersIgnoringModifiers == "\n"
        let modifiers = event.modifierFlags.intersection([.shift, .command, .option, .control])
        if isReturn && modifiers.isEmpty {
            keyHandler?.send()
            return
        }
        if isReturn && (modifiers.contains(.shift) || modifiers.contains(.command) || modifiers.contains(.option)) {
            insertNewlineIgnoringFieldEditor(self)
            return
        }
        if event.keyCode == 53 {
            let now = event.timestamp
            if let lastEscapeAt, now - lastEscapeAt < 0.6 {
                keyHandler?.clear()
                self.lastEscapeAt = nil
                return
            }
            self.lastEscapeAt = now
            super.keyDown(with: event)
            return
        }
        super.keyDown(with: event)
    }

    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        if acceptsDrop(pasteboard), dropHandler?.handleDrop(pasteboard) == true {
            return
        }
        super.paste(sender)
    }

    private func acceptsDrop(_ pasteboard: NSPasteboard) -> Bool {
        !PiAgentComposerImageLoader.imagesFromPasteboard(pasteboard).isEmpty || !PiAgentComposerImageLoader.fileURLs(from: pasteboard).isEmpty
    }
}

private struct PiAgentSubagentPopover: View {
    let agentNames: [String]
    @Binding var isEnabled: Bool
    let onSelectAgent: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isEnabled {
                if agentNames.isEmpty {
                    Text("No enabled agents found.")
                        .font(.callout)
                        .foregroundStyle(AppTheme.mutedText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                } else {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(agentNames, id: \.self) { agentName in
                            Button {
                                onSelectAgent(agentName)
                            } label: {
                                HStack(spacing: 10) {
                                    Text(agentName)
                                        .font(.body.weight(.medium))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer(minLength: 8)
                                    Image(systemName: "arrow.right.circle")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(Color.accentColor)
                                }
                                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(AppTheme.contentSubtleFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } else {
                Label("Subagents disabled", systemImage: "nosign")
                    .font(.callout)
                    .foregroundStyle(AppTheme.mutedText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            }

            Divider()

            HStack(spacing: 12) {
                Text("Subagents")
                    .font(.body.weight(.medium))
                Spacer(minLength: 24)
                Toggle("Subagents", isOn: $isEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
    }
}

private struct PiAgentFileAttachmentChip: View {
    let file: PiAgentFileAttachment
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .foregroundStyle(Color.accentColor)
            Text(file.url.lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(AppTheme.mutedText)
            }
            .buttonStyle(.plain)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Capsule(style: .continuous).fill(AppTheme.contentSubtleFill))
        .help(file.url.path)
    }
}

private struct PiAgentImageAttachmentThumbnail: View {
    let image: PiAgentImageAttachment
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let nsImage = PiAgentComposerImageLoader.previewImage(for: image) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo")
                        .font(.title2)
                        .foregroundStyle(AppTheme.mutedText)
                }
            }
            .frame(width: 68, height: 68)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(AppTheme.contentStroke, lineWidth: 1)
            )

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(.black.opacity(0.7)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove image attachment")
            .offset(x: 6, y: -6)
        }
        .help("\(image.name) · \(ByteCountFormatter.string(fromByteCount: Int64(image.sizeBytes), countStyle: .file))")
    }
}

private enum PiAgentComposerImageLoader {
    nonisolated private static let maxDimension: CGFloat = 2_000
    nonisolated private static let maxEncodedBytes = Int(4.5 * 1024 * 1024)

    nonisolated static func imagesFromPasteboard(_ pasteboard: NSPasteboard = .general) -> [PiAgentImageAttachment] {
        var attachments: [PiAgentImageAttachment] = []
        let urls = fileURLs(from: pasteboard)
        attachments.append(contentsOf: urls.compactMap(imageAttachment(fromFileURL:)))
        if let data = pasteboard.data(forType: .png), let attachment = imageAttachment(data: data, name: "pasted-image.png", mimeType: "image/png", fileReference: "pasted-image.png") {
            attachments.append(attachment)
        } else if let data = pasteboard.data(forType: .tiff), let pngData = pngData(fromImageData: data), let attachment = imageAttachment(data: pngData, name: "pasted-image.png", mimeType: "image/png", fileReference: "pasted-image.png") {
            attachments.append(attachment)
        }
        return attachments
    }

    nonisolated static func loadImages(from providers: [NSItemProvider], completion: @escaping ([PiAgentImageAttachment]) -> Void) {
        loadDropItems(from: providers) { attachments, _ in completion(attachments) }
    }

    nonisolated static func loadDropItems(from providers: [NSItemProvider], completion: @escaping ([PiAgentImageAttachment], [URL]) -> Void) {
        let group = DispatchGroup()
        let accumulator = DropItemAccumulator()

        for provider in providers {
            var didScheduleFile = false
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                didScheduleFile = true
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    defer { group.leave() }
                    let url: URL?
                    if let data = item as? Data {
                        url = URL(dataRepresentation: data, relativeTo: nil)
                    } else {
                        url = item as? URL
                    }
                    if let url, let image = imageAttachment(fromFileURL: url) {
                        accumulator.appendImage(image)
                    } else {
                        accumulator.appendFile(url)
                    }
                }
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) && !didScheduleFile {
                group.enter()
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    defer { group.leave() }
                    guard let data else { return }
                    let png = pngData(fromImageData: data) ?? data
                    accumulator.appendImage(imageAttachment(data: png, name: "dropped-image.png", mimeType: "image/png", fileReference: "dropped-image.png"))
                }
            }
        }

        group.notify(queue: .main) {
            let result = accumulator.result()
            completion(result.attachments, result.files)
        }
    }

    private final class DropItemAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        private var attachments: [PiAgentImageAttachment] = []
        private var files: [URL] = []

        func appendImage(_ attachment: PiAgentImageAttachment?) {
            guard let attachment else { return }
            lock.lock()
            attachments.append(attachment)
            lock.unlock()
        }

        func appendFile(_ url: URL?) {
            guard let url, !url.hasDirectoryPath else { return }
            lock.lock()
            files.append(url)
            lock.unlock()
        }

        func result() -> (attachments: [PiAgentImageAttachment], files: [URL]) {
            lock.lock()
            let attachments = attachments
            let files = files
            lock.unlock()

            var seen = Set<String>()
            return (attachments, files.filter { seen.insert($0.path).inserted })
        }
    }

    nonisolated static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        var urls: [URL] = []
        if let read = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            urls.append(contentsOf: read)
        }
        let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        if let paths = pasteboard.propertyList(forType: filenamesType) as? [String] {
            urls.append(contentsOf: paths.map(URL.init(fileURLWithPath:)))
        }
        for item in pasteboard.pasteboardItems ?? [] {
            if let value = item.string(forType: .fileURL), let url = URL(string: value) {
                urls.append(url)
            }
        }
        var seen = Set<String>()
        return urls.filter { seen.insert($0.path).inserted }
    }

    nonisolated static func imageAttachment(fromFileURL url: URL) -> PiAgentImageAttachment? {
        guard let mimeType = mimeType(for: url), let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return imageAttachment(data: data, name: url.lastPathComponent, mimeType: mimeType, fileReference: url.path)
    }

    nonisolated static func imageAttachment(data: Data, name: String, mimeType: String, fileReference: String? = nil) -> PiAgentImageAttachment? {
        guard let processed = processLikePiCLI(data: data, mimeType: mimeType) else { return nil }
        return PiAgentImageAttachment(
            name: name,
            mimeType: processed.mimeType,
            data: processed.data.base64EncodedString(),
            sizeBytes: processed.data.count,
            fileReference: fileReference ?? name,
            dimensionNote: processed.dimensionNote
        )
    }

    nonisolated static func previewImage(for attachment: PiAgentImageAttachment) -> NSImage? {
        guard let data = Data(base64Encoded: attachment.data) else { return nil }
        return NSImage(data: data)
    }

    nonisolated private static func mimeType(for url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        default: return nil
        }
    }

    nonisolated private static func processLikePiCLI(data: Data, mimeType: String) -> (data: Data, mimeType: String, dimensionNote: String?)? {
        let encodedSize = data.base64EncodedString().utf8.count
        guard let image = NSImage(data: data) else { return nil }
        let originalSize = image.pixelSize
        if originalSize.width <= maxDimension,
           originalSize.height <= maxDimension,
           encodedSize < maxEncodedBytes,
           ["image/png", "image/jpeg", "image/gif", "image/webp"].contains(mimeType) {
            return (data, mimeType, nil)
        }

        let scale = min(maxDimension / max(originalSize.width, 1), maxDimension / max(originalSize.height, 1), 1)
        var targetSize = CGSize(width: max(1, floor(originalSize.width * scale)), height: max(1, floor(originalSize.height * scale)))
        while targetSize.width >= 1 && targetSize.height >= 1 {
            if let resized = resizedBitmap(from: image, targetSize: targetSize) {
                let candidates = encodedCandidates(from: resized)
                if let candidate = candidates.first(where: { $0.data.base64EncodedString().utf8.count < maxEncodedBytes }) {
                    let dimensionNote = formatDimensionNote(original: originalSize, displayed: targetSize)
                    return (candidate.data, candidate.mimeType, dimensionNote)
                }
            }
            if targetSize.width == 1 && targetSize.height == 1 { break }
            targetSize = CGSize(width: max(1, floor(targetSize.width * 0.75)), height: max(1, floor(targetSize.height * 0.75)))
        }
        return nil
    }

    nonisolated private static func encodedCandidates(from rep: NSBitmapImageRep) -> [(data: Data, mimeType: String)] {
        var candidates: [(Data, String)] = []
        if let png = rep.representation(using: .png, properties: [:]) { candidates.append((png, "image/png")) }
        for quality in [0.80, 0.85, 0.70, 0.55, 0.40] {
            if let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: quality]) {
                candidates.append((jpeg, "image/jpeg"))
            }
        }
        return candidates.sorted(by: { (lhs: (data: Data, mimeType: String), rhs: (data: Data, mimeType: String)) in
            lhs.data.count < rhs.data.count
        })
    }

    nonisolated private static func resizedBitmap(from image: NSImage, targetSize: CGSize) -> NSBitmapImageRep? {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(targetSize.width), pixelsHigh: Int(targetSize.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        guard let rep else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: CGRect(origin: .zero, size: targetSize), from: CGRect(origin: .zero, size: image.size), operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    nonisolated private static func formatDimensionNote(original: CGSize, displayed: CGSize) -> String? {
        guard original != displayed else { return nil }
        let scale = original.width / max(displayed.width, 1)
        return "[Image: original \(Int(original.width))x\(Int(original.height)), displayed at \(Int(displayed.width))x\(Int(displayed.height)). Multiply coordinates by \(String(format: "%.2f", scale)) to map to original image.]"
    }

    nonisolated private static func pngData(fromImageData data: Data) -> Data? {
        guard let image = NSImage(data: data), let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

private extension NSImage {
    nonisolated var pixelSize: CGSize {
        if let rep = representations.max(by: { ($0.pixelsWide * $0.pixelsHigh) < ($1.pixelsWide * $1.pixelsHigh) }) {
            return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        return size
    }
}

private struct PiAgentSendButton: View {
    let isRunning: Bool
    let canSend: Bool
    let sendAction: () -> Void
    let stopAction: () -> Void

    var body: some View {
        Button(action: isRunning ? stopAction : sendAction) {
            Image(systemName: isRunning ? "stop.fill" : "arrow.up")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 34, height: 34)
                .background(
                    Circle()
                        .fill(backgroundColor)
                        .animation(.snappy(duration: 0.22), value: isRunning)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isRunning && !canSend)
        .help(isRunning ? "Stop Pi Agent" : "Send message")
        .accessibilityLabel(isRunning ? "Stop Pi Agent" : "Send message")
        .background {
            Button("Stop Pi Agent", action: stopAction)
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(!isRunning)
                .hidden()
        }
        .animation(.snappy(duration: 0.22), value: isRunning)
    }

    private var backgroundColor: Color {
        if isRunning { return .red.opacity(0.88) }
        return canSend ? Color.accentColor : AppTheme.mutedText.opacity(0.28)
    }
}

private struct PiAgentModelSelection {
    let provider: String
    let modelID: String
}

private struct PiAgentComposerFooterBar: View {
    let session: PiAgentSessionRecord
    @ObservedObject var viewModel: AppViewModel
    let supportedThinkingLevels: [String]

    var body: some View {
        HStack(spacing: 10) {
            PiAgentContextUsageMeter(session: session, onCompact: { viewModel.compactSelectedPiAgentSession() })
            PiAgentModelPicker(
                session: session,
                fallbackModels: viewModel.availableModels,
                isRunning: viewModel.isPiAgentSessionRunning(session.id),
                onRefresh: { viewModel.refreshPiAgentControlsForSelectedSession() },
                onCycle: { viewModel.cyclePiAgentModelForSelectedSession() },
                onSelect: { selection in
                    if let selection {
                        viewModel.setPiAgentModelForSelectedSession(provider: selection.provider, modelID: selection.modelID)
                    } else {
                        viewModel.setPiAgentModelForSelectedSession(provider: nil, modelID: nil)
                    }
                }
            )
            PiAgentThinkingPicker(
                level: session.thinkingLevel,
                supportedLevels: supportedThinkingLevels,
                isRunning: viewModel.isPiAgentSessionRunning(session.id),
                onCycle: { viewModel.cyclePiAgentThinkingLevelForSelectedSession() },
                onSelect: { viewModel.setPiAgentThinkingLevelForSelectedSession($0) }
            )
        }
    }
}

private struct PiAgentContextUsageMeter: View {
    let session: PiAgentSessionRecord
    let onCompact: () -> Void
    @State private var isConfirmingCompaction = false

    var body: some View {
        if session.isCompacting {
            HStack(spacing: 7) {
                ProgressView()
                    .controlSize(.small)
                Text("Compacting context")
                    .font(.caption.weight(.semibold))
                if let tokens = session.contextTokens {
                    Text("\(compact(tokens)) tokens")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(AppTheme.mutedText)
                }
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule(style: .continuous).fill(AppTheme.contentSubtleFill).stroke(AppTheme.contentStroke, lineWidth: 1))
            .fixedSize(horizontal: true, vertical: false)
            .help("Pi is compacting this conversation. Input is disabled until compaction finishes.")
        } else if let percent = session.contextPercent, let tokens = session.contextTokens, let window = session.contextWindow {
            HStack(spacing: 6) {
                HStack(spacing: 7) {
                    Text("Context")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .fixedSize()
                    ZStack(alignment: .leading) {
                        Capsule(style: .continuous)
                            .fill(AppTheme.contentFill.opacity(0.75))
                        Capsule(style: .continuous)
                            .fill(percent > 85 ? Color.orange : Color.accentColor)
                            .frame(width: 92 * min(max(percent, 0), 100) / 100)
                    }
                    .frame(width: 92, height: 10)
                    Text("\(Int(percent))%")
                        .font(.caption.monospacedDigit().weight(.bold))
                        .lineLimit(1)
                    Text("\(compact(tokens))/\(compact(window))")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(AppTheme.mutedText)
                        .lineLimit(1)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Capsule(style: .continuous).fill(AppTheme.contentSubtleFill).stroke(AppTheme.contentStroke, lineWidth: 1))
                .fixedSize(horizontal: true, vertical: false)

                Button {
                    isConfirmingCompaction = true
                } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.mutedText)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(AppTheme.contentSubtleFill).stroke(AppTheme.contentStroke, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Compact context")
            }
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
            .alert("Compact context?", isPresented: $isConfirmingCompaction) {
                Button("Cancel", role: .cancel) {}
                Button("Compact") { onCompact() }
            } message: {
                Text("Pi will summarize older conversation history to free context. This keeps the session usable for longer prompts.")
            }
        }
    }

    private func compact(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return "\(value / 1_000)k" }
        return "\(value)"
    }
}

private struct PiAgentModelStatus: View {
    let session: PiAgentSessionRecord

    var body: some View {
        Label(modelLabel, systemImage: "cpu")
            .font(.footnote.weight(.semibold))
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Capsule(style: .continuous).fill(AppTheme.contentSubtleFill).stroke(AppTheme.contentStroke, lineWidth: 1))
    }

    private var modelLabel: String {
        if let provider = session.modelOverrideProvider ?? session.modelProvider,
           let model = session.modelOverrideID ?? session.model {
            return "\(provider)/\(model)"
        }
        return "Pi default model"
    }
}

private struct PiAgentThinkingStatus: View {
    let level: String?

    var body: some View {
        Label("Thinking: \(displayLevel)", systemImage: "brain.head.profile")
            .font(.footnote.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Capsule(style: .continuous).fill(AppTheme.contentSubtleFill).stroke(AppTheme.contentStroke, lineWidth: 1))
    }

    private var displayLevel: String {
        guard let level, !level.isEmpty else { return "default" }
        return (level == "none" ? "off" : level).capitalized
    }
}

private struct PiAgentShortcutChip: View {
    let symbol: String
    let key: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            Text(key)
                .font(.caption2.monospaced().weight(.bold))
            Text(label)
                .fontWidth(.condensed)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(AppTheme.mutedText)
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(Capsule(style: .continuous).fill(AppTheme.contentSubtleFill))
    }
}

private struct PiAgentRuntimeFooter: View {
    let session: PiAgentSessionRecord

    var body: some View {
        HStack(spacing: 7) {
            if let total = session.totalTokens {
                metric("total \(compact(total))", icon: "tugriksign.circle")
            }
            if let input = session.inputTokens {
                metric("in \(compact(input))", icon: "arrow.down.left")
            }
            if let output = session.outputTokens {
                metric("out \(compact(output))", icon: "arrow.up.right")
            }
            if let cacheRead = session.cacheReadTokens, cacheRead > 0 {
                metric("cache \(compact(cacheRead))", icon: "memorychip")
            }
            if let toolCalls = session.toolCalls {
                metric("\(toolCalls) tools", icon: "wrench.and.screwdriver")
            }
            if let cost = session.cost {
                metric(String(format: "$%.2f", cost), icon: "dollarsign.circle")
            }
        }
        .font(.caption)
        .foregroundStyle(AppTheme.mutedText)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metric(_ text: String, icon: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.caption2.weight(.semibold))
            Text(text)
        }
        .lineLimit(1)
    }

    private func compact(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return "\(value / 1_000)k" }
        return "\(value)"
    }
}

private struct PiAgentModelPicker: View {
    let session: PiAgentSessionRecord
    let fallbackModels: [AvailableModel]
    let isRunning: Bool
    let onRefresh: () -> Void
    let onCycle: () -> Void
    let onSelect: (PiAgentModelSelection?) -> Void

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "cpu")
                Text(modelLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(AppTheme.mutedText)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .frame(maxWidth: 220, alignment: .leading)
            .background(Capsule(style: .continuous).fill(AppTheme.contentSubtleFill).stroke(AppTheme.contentStroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Model", systemImage: "cpu")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.mutedText)
                    Spacer()
                    Button {
                        onRefresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .help("Refresh models")
                    .accessibilityLabel("Refresh models")
                }

                Button {
                    onSelect(nil)
                    isPresented = false
                } label: {
                    modelRow(title: "Pi Default", subtitle: "Use Pi CLI defaults", isSelected: isUsingPiDefault)
                }
                .buttonStyle(.plain)

                Divider()

                ScrollView(showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(modelOptions) { model in
                            Button {
                                onSelect(.init(provider: model.provider, modelID: model.id))
                                isPresented = false
                            } label: {
                                modelRow(
                                    title: model.id,
                                    subtitle: model.provider,
                                    isSelected: !isUsingPiDefault && model.provider == effectiveProvider && model.id == effectiveModelID
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
            .padding(12)
            .frame(width: 360)
        }
        .help(isRunning ? "Change this Pi session's model" : "Choose a model override for this session before launch")
    }

    private func modelRow(title: String, subtitle: String, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : AppTheme.mutedText)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.mutedText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isSelected ? Color.accentColor.opacity(0.10) : AppTheme.contentSubtleFill))
    }

    private var modelOptions: [PiAgentModelOption] {
        if let models = session.availableModels, !models.isEmpty { return models }
        return fallbackModels.map { model in
            PiAgentModelOption(
                provider: model.provider,
                id: model.model,
                name: nil,
                contextWindow: Int(model.contextWindow),
                supportsThinking: model.supportsThinking,
                supportedThinkingLevels: model.supportedThinkingLevels,
                supportsImages: model.supportsImages
            )
        }
    }

    private var isUsingPiDefault: Bool { session.modelOverrideProvider == nil && session.modelOverrideID == nil }
    private var effectiveProvider: String? { session.modelOverrideProvider ?? session.modelProvider }
    private var effectiveModelID: String? { session.modelOverrideID ?? session.model }

    private var modelLabel: String {
        if let provider = effectiveProvider, let model = effectiveModelID {
            return isUsingPiDefault ? "Default \(provider)/\(model)" : "\(provider)/\(model)"
        }
        return "Pi Default"
    }
}

private struct PiAgentThinkingPicker: View {
    let level: String?
    let supportedLevels: [String]
    let isRunning: Bool
    let onCycle: () -> Void
    let onSelect: (String) -> Void

    @State private var isPresented = false

    private var levels: [String] { supportedLevels.isEmpty ? ["off"] : supportedLevels }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "brain.head.profile")
                Text("Thinking: \(displayLevel.capitalized)")
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(AppTheme.mutedText)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule(style: .continuous).fill(AppTheme.contentSubtleFill).stroke(AppTheme.contentStroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Thinking", systemImage: "brain.head.profile")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.mutedText)

                ForEach(levels, id: \.self) { candidate in
                    Button {
                        onSelect(candidate)
                        isPresented = false
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: candidate == normalizedLevel ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(candidate == normalizedLevel ? Color.accentColor : AppTheme.mutedText)
                                .frame(width: 16)
                            Text(candidate.capitalized)
                                .font(.caption.weight(.semibold))
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(candidate == normalizedLevel ? Color.accentColor.opacity(0.10) : AppTheme.contentSubtleFill))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
            .frame(width: 220)
        }
        .help(isRunning ? "Change thinking level" : "Choose thinking level for this session before launch")
    }

    private var normalizedLevel: String? {
        guard let level else { return nil }
        return level == "none" ? "off" : level
    }

    private var displayLevel: String {
        guard let normalizedLevel else { return "default" }
        return levels.contains(normalizedLevel) ? normalizedLevel : "\(normalizedLevel) unavailable"
    }
}

private struct PiAgentSessionSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(AppTheme.mutedText)
            TextField("Search all sessions", text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(AppTheme.mutedText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppTheme.contentFill)
                .stroke(AppTheme.contentStroke, lineWidth: 1)
        )
    }
}

private struct PiAgentAddSessionButton: View {
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(isEnabled ? .white : AppTheme.mutedText.opacity(0.55))
                .frame(width: 30, height: 30)
                .background(
                    Circle()
                        .fill(isEnabled ? Color.accentColor : AppTheme.contentStroke.opacity(0.45))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New Pi Agent session")
    }
}

private struct PiAgentSessionRow: View {
    let session: PiAgentSessionRecord
    let project: DiscoveredProject?
    let isSelected: Bool
    let isRunning: Bool
    let isRenaming: Bool
    let onSelect: () -> Void
    let onBeginRename: () -> Void
    let onEndRename: () -> Void
    let onRename: (String) -> Void
    let onTogglePinned: () -> Void
    let onDelete: () -> Void

    @State private var draftTitle = ""
    @State private var isTitleHovered = false
    @FocusState private var isTitleFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            PiAgentProjectIcon(project: project, session: session)

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle()
                        .fill(session.needsAttention ? Color.accentColor : (isRunning ? .green : statusColor))
                        .frame(width: session.needsAttention ? 10 : 8, height: session.needsAttention ? 10 : 8)
                    titleView
                    Spacer(minLength: 0)
                    Button(action: onTogglePinned) {
                        Image(systemName: session.isPinned ? "pin.fill" : "pin")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(session.isPinned ? Color.accentColor : AppTheme.mutedText.opacity(0.75))
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(session.isPinned ? Color.accentColor.opacity(0.12) : Color.clear))
                    }
                    .buttonStyle(.plain)
                    .help(session.isPinned ? "Unpin session" : "Pin session")
                    if session.needsAttention {
                        Image(systemName: "bell.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .help("Pi Agent finished and needs review")
                    }
                }

                HStack(spacing: 6) {
                    Image("github")
                        .resizable()
                        .renderingMode(.template)
                        .scaledToFit()
                        .frame(width: 13, height: 13)
                    Text(subtitle)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .font(.footnote)
                .foregroundStyle(AppTheme.mutedText)

                Text(session.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.14) : AppTheme.contentFill)
                .stroke(isSelected ? Color.accentColor.opacity(0.35) : AppTheme.contentStroke, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .help(statusHelp)
        .onAppear { draftTitle = sessionTitle }
        .onChange(of: session.id) { _, _ in resetRenameState() }
        .onChange(of: session.title) { _, _ in draftTitle = sessionTitle }
        .onChange(of: isRenaming) { _, renaming in
            if renaming {
                draftTitle = sessionTitle
                isTitleFocused = true
            } else {
                isTitleFocused = false
            }
        }
        .onChange(of: isTitleFocused) { _, focused in
            if !focused && isRenaming { commitRename() }
        }
        .onDisappear(perform: commitRename)
    }

    @ViewBuilder
    private var titleView: some View {
        if isRenaming {
            TextField("Session name", text: $draftTitle)
                .textFieldStyle(.plain)
                .font(.subheadline.weight(.semibold))
                .fontWidth(.expanded)
                .lineLimit(1)
                .focused($isTitleFocused)
                .onSubmit(commitRename)
                .onExitCommand { resetRenameState() }
                .onAppear {
                    draftTitle = sessionTitle
                    isTitleFocused = true
                }
        } else {
            HStack(spacing: 5) {
                Text(sessionTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "pencil")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(AppTheme.mutedText)
                    .opacity(isTitleHovered ? 1 : 0)
            }
            .font(.subheadline.weight(.semibold))
            .fontWidth(.expanded)
            .foregroundStyle(.primary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isTitleHovered ? Color.primary.opacity(0.06) : Color.clear)
            )
            .contentShape(Rectangle())
            .onHover { isTitleHovered = $0 }
            .onTapGesture(perform: onBeginRename)
            .help("Rename session")
        }
    }

    private func resetRenameState() {
        draftTitle = sessionTitle
        onEndRename()
        isTitleFocused = false
    }

    private func commitRename() {
        let trimmedTitle = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTitle.isEmpty {
            draftTitle = sessionTitle
        } else if trimmedTitle != session.title {
            onRename(trimmedTitle)
        }
        onEndRename()
        isTitleFocused = false
    }

    private var sessionTitle: String {
        if session.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return session.issueNumber.map { "#\($0)" } ?? "Project agent"
        }
        return session.title
    }

    private var subtitle: String {
        if let repository = session.repository {
            return repository
        }
        return session.projectName
    }

    private var statusHelp: String {
        if isRunning { return "Active" }
        return session.status.rawValue
    }

    private var statusColor: Color {
        switch session.status {
        case .running, .starting: return .green
        case .idle, .completed: return .blue
        case .failed: return .red
        case .stopped: return .orange
        case .draft: return .secondary
        }
    }
}

private struct PiAgentProjectIcon: View {
    let project: DiscoveredProject?
    let session: PiAgentSessionRecord

    var body: some View {
        Group {
            if let url = project?.iconFileURL {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    fallback
                }
            } else {
                fallback
            }
        }
        .frame(width: 34, height: 34)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var fallback: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color.accentColor.opacity(0.14))
            .overlay {
                Image(session.kind == .issue ? "github" : "pi")
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .padding(8)
                    .foregroundStyle(Color.accentColor)
            }
    }
}

private struct PiAgentProcessingIndicatorCard: View {
    let message: String

    var body: some View {
        AppRowCard {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Color.purple)
                Text(message)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                PiAgentTypingIndicator()
                Spacer()
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
    }
}

private struct PiAgentTypingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = 0

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { index in
                let isActive = phase == index
                Circle()
                    .fill(Color.secondary.opacity(isActive ? 0.78 : 0.22))
                    .frame(width: 6, height: 6)
                    .scaleEffect(reduceMotion ? 1 : (isActive ? 1.18 : 0.86))
                    .offset(y: reduceMotion ? 0 : (isActive ? -2 : 0))
            }
        }
        .padding(.vertical, 5)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(620))
                guard !Task.isCancelled else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.42)) {
                    phase = (phase + 1) % 3
                }
            }
        }
        .accessibilityLabel("Pi is typing")
    }
}

private struct PiAgentTranscriptThread: Identifiable, Hashable {
    var id: UUID
    var question: PiAgentTranscriptEntry?
    var steeringMessages: [PiAgentTranscriptEntry]
    var thinking: PiAgentTranscriptEntry?
    var assistantMessages: [PiAgentTranscriptEntry]
    var activities: [PiAgentTranscriptActivity]
    var statuses: [PiAgentTranscriptEntry]
    var errors: [PiAgentTranscriptEntry]

    @MainActor
    static func make(from entries: [PiAgentTranscriptEntry]) -> [PiAgentTranscriptThread] {
        var threads: [PiAgentTranscriptThread] = []
        var builder = Builder()

        func flush() {
            guard let thread = builder.makeThread() else { return }
            threads.append(thread)
            builder = Builder()
        }

        for entry in entries {
            if entry.role == .status && entry.title == "Compaction" {
                flush()
                builder.add(entry)
                flush()
            } else if entry.role == .user && entry.title != "Steering" {
                flush()
                builder.question = entry
            } else {
                builder.add(entry)
            }
        }
        flush()
        return threads
    }

    private struct Builder {
        var question: PiAgentTranscriptEntry?
        var steeringMessages: [PiAgentTranscriptEntry] = []
        var thinkingParts: [PiAgentTranscriptEntry] = []
        var assistantMessages: [PiAgentTranscriptEntry] = []
        var toolEntries: [PiAgentTranscriptEntry] = []
        var statuses: [PiAgentTranscriptEntry] = []
        var errors: [PiAgentTranscriptEntry] = []

        mutating func add(_ entry: PiAgentTranscriptEntry) {
            switch entry.role {
            case .user where entry.title == "Steering":
                steeringMessages.append(entry)
            case .thinking:
                thinkingParts.append(entry)
            case .assistant:
                assistantMessages.append(entry)
            case .tool:
                toolEntries.append(entry)
            case .status, .stderr:
                statuses.append(entry)
            case .error:
                errors.append(entry)
            case .user, .raw:
                statuses.append(entry)
            }
        }

        @MainActor
        func makeThread() -> PiAgentTranscriptThread? {
            let activities = PiAgentTranscriptActivity.make(from: toolEntries)
            guard question != nil || !steeringMessages.isEmpty || !thinkingParts.isEmpty || !assistantMessages.isEmpty || !activities.isEmpty || !statuses.isEmpty || !errors.isEmpty else {
                return nil
            }
            let first = question ?? steeringMessages.first ?? thinkingParts.first ?? assistantMessages.first ?? activities.first?.representativeEntry ?? statuses.first ?? errors.first
            let thinking = PiAgentTranscriptEntry.mergedThinking(from: thinkingParts)
            return PiAgentTranscriptThread(
                id: question?.id ?? first?.id ?? UUID(),
                question: question,
                steeringMessages: steeringMessages,
                thinking: thinking,
                assistantMessages: assistantMessages,
                activities: activities,
                statuses: coalescedStatuses(statuses),
                errors: coalescedErrors(errors)
            )
        }

        private func coalescedStatuses(_ entries: [PiAgentTranscriptEntry]) -> [PiAgentTranscriptEntry] {
            var output: [PiAgentTranscriptEntry] = []
            var latestCompaction: PiAgentTranscriptEntry?
            for entry in entries {
                if entry.title == "Compaction" {
                    latestCompaction = entry
                } else {
                    output.append(entry)
                }
            }
            if let latestCompaction {
                output.append(normalizedCompaction(latestCompaction))
            }
            return output.sorted { $0.timestamp < $1.timestamp }
        }

        private func normalizedCompaction(_ entry: PiAgentTranscriptEntry) -> PiAgentTranscriptEntry {
            var copy = entry
            let text = entry.text
            if text.localizedCaseInsensitiveContains("nothing to compact") {
                copy.text = "Nothing to compact."
            } else if text.localizedCaseInsensitiveContains("compaction finished") || text.localizedCaseInsensitiveContains("compaction complete") {
                copy.text = text.localizedCaseInsensitiveContains("retrying turn") ? "Context compacted · retrying turn" : "Context compacted."
            } else if text.localizedCaseInsensitiveContains("is compacting") || text.localizedCaseInsensitiveContains("compacting conversation context") {
                copy.text = "Compacting context…"
            }
            return copy
        }

        private func coalescedErrors(_ entries: [PiAgentTranscriptEntry]) -> [PiAgentTranscriptEntry] {
            var output: [PiAgentTranscriptEntry] = []
            var latestByTool: [String: PiAgentTranscriptEntry] = [:]
            var toolOrder: [String] = []
            for entry in entries {
                let key = PiAgentTranscriptActivity.toolName(for: entry)
                if entry.title.hasPrefix("Tool: ") {
                    if latestByTool[key] == nil { toolOrder.append(key) }
                    latestByTool[key] = normalizedToolError(entry)
                } else {
                    output.append(entry)
                }
            }
            output.append(contentsOf: toolOrder.compactMap { latestByTool[$0] })
            return output.sorted { $0.timestamp < $1.timestamp }
        }

        private func normalizedToolError(_ entry: PiAgentTranscriptEntry) -> PiAgentTranscriptEntry {
            var copy = entry
            copy.text = entry.text
                .replacingOccurrences(of: "\n\nCommand exited with code", with: " · exit")
                .replacingOccurrences(of: "Validation failed for tool", with: "Validation failed")
            return copy
        }
    }
}

private struct PiAgentWebLink: Identifiable, Hashable {
    let id = UUID()
    var title: String
    var url: String

    var domain: String {
        URL(string: url)?.host(percentEncoded: false)?.replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression) ?? url
    }
}

private struct PiAgentTranscriptActivity: Identifiable, Hashable {
    var id: UUID
    var name: String
    var entries: [PiAgentTranscriptEntry]
    var isError: Bool
    var compactDetail: String?
    var webLinks: [PiAgentWebLink]
    var subagentSummary: PiAgentSubagentSummary?

    var representativeEntry: PiAgentTranscriptEntry? { entries.first }
    nonisolated var count: Int { entries.count }
    nonisolated var isWebActivity: Bool {
        switch name.lowercased() {
        case "web_search", "fetch_content", "get_search_content", "code_search": return true
        default: return false
        }
    }

    @MainActor
    static func make(from entries: [PiAgentTranscriptEntry]) -> [PiAgentTranscriptActivity] {
        var orderedNames: [String] = []
        var grouped: [String: [PiAgentTranscriptEntry]] = [:]
        for entry in entries {
            let name = toolName(for: entry)
            if grouped[name] == nil { orderedNames.append(name) }
            grouped[name, default: []].append(entry)
        }
        return orderedNames.compactMap { name in
            guard let entries = grouped[name], !entries.isEmpty else { return nil }
            let subagentSummary = entries.lazy.compactMap(PiAgentSubagentSummary.init(entry:)).first { $0.total > 0 }
            return PiAgentTranscriptActivity(
                id: entries.first?.id ?? UUID(),
                name: name,
                entries: entries,
                isError: entries.contains { $0.role == .error },
                compactDetail: compactDetail(for: name, entries: entries),
                webLinks: webLinks(for: name, entries: entries),
                subagentSummary: subagentSummary
            )
        }
    }

    static func toolName(for entry: PiAgentTranscriptEntry) -> String {
        if entry.title.hasPrefix("Tool: ") {
            return entry.title.replacingOccurrences(of: "Tool: ", with: "")
        }
        return entry.title
    }

    @MainActor
    private static func webLinks(for name: String, entries: [PiAgentTranscriptEntry]) -> [PiAgentWebLink] {
        switch name.lowercased() {
        case "web_search":
            let details = entries.lazy.compactMap(toolDetails).last
            let curated = curatedSourceLinks(from: details)
            if !curated.isEmpty { return Array(curated.prefix(20)) }
            return parseSourceLinks(from: entries.last?.text ?? "")
        case "fetch_content":
            let details = entries.lazy.compactMap(toolDetails).last
            let args = entries.lazy.compactMap(toolArgs).last
            let title = details?["title"]?.stringValue
            let urls = stringArray(details?["urls"]) ?? stringArray(args?["urls"]) ?? args?["url"]?.stringValue.map { [$0] } ?? []
            return urls.prefix(20).map { PiAgentWebLink(title: title?.isEmpty == false ? title! : (domain(from: $0) ?? $0), url: $0) }
        case "get_search_content":
            let details = entries.lazy.compactMap(toolDetails).last
            guard let url = details?["url"]?.stringValue else { return [] }
            return [PiAgentWebLink(title: details?["title"]?.stringValue ?? domain(from: url) ?? url, url: url)]
        default:
            return []
        }
    }

    @MainActor
    private static func compactDetail(for name: String, entries: [PiAgentTranscriptEntry]) -> String? {
        switch name.lowercased() {
        case "web_search":
            return webSearchDetail(from: entries)
        case "fetch_content":
            return fetchContentDetail(from: entries)
        case "get_search_content":
            return retrievedContentDetail(from: entries)
        default:
            return nil
        }
    }

    @MainActor
    private static func webSearchDetail(from entries: [PiAgentTranscriptEntry]) -> String? {
        let details = entries.lazy.compactMap(toolDetails).last
        let args = entries.lazy.compactMap(toolArgs).last
        let queries = stringArray(details?["queries"]) ?? stringArray(args?["queries"]) ?? args?["query"]?.stringValue.map { [$0] } ?? []
        let resultCount = intValue(details?["totalResults"])

        var parts: [String] = []
        if queries.count == 1, let query = queries.first {
            parts.append("“\(query.truncatedMiddle(max: 56))”")
        } else if queries.count > 1 {
            parts.append("\(queries.count) queries")
        }
        if let resultCount {
            parts.append(resultCount == 1 ? "1 result" : "\(resultCount) results")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @MainActor
    private static func fetchContentDetail(from entries: [PiAgentTranscriptEntry]) -> String? {
        let details = entries.lazy.compactMap(toolDetails).last
        let args = entries.lazy.compactMap(toolArgs).last
        let urls = stringArray(details?["urls"]) ?? stringArray(args?["urls"]) ?? args?["url"]?.stringValue.map { [$0] } ?? []
        let title = details?["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let successful = intValue(details?["successful"])
        let urlCount = intValue(details?["urlCount"]) ?? urls.count
        let domains = domains(from: urls)

        var parts: [String] = []
        if let title, !title.isEmpty, urlCount <= 1 {
            parts.append(title.truncatedMiddle(max: 44))
        } else if urlCount > 0 {
            parts.append(urlCount == 1 ? "1 page" : "\(urlCount) pages")
        }
        if let successful, urlCount > 1, successful != urlCount {
            parts.append("\(successful)/\(urlCount) fetched")
        }
        if !domains.isEmpty {
            parts.append(domains.prefix(3).joined(separator: ", "))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @MainActor
    private static func retrievedContentDetail(from entries: [PiAgentTranscriptEntry]) -> String? {
        let details = entries.lazy.compactMap(toolDetails).last
        let title = details?["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = details?["url"]?.stringValue
        let query = details?["query"]?.stringValue
        let resultCount = intValue(details?["resultCount"])

        var parts: [String] = []
        if let title, !title.isEmpty {
            parts.append(title.truncatedMiddle(max: 44))
        } else if let url, let domain = domain(from: url) {
            parts.append(domain)
        } else if let query, !query.isEmpty {
            parts.append("“\(query.truncatedMiddle(max: 44))”")
        }
        if let resultCount {
            parts.append(resultCount == 1 ? "1 source" : "\(resultCount) sources")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @MainActor
    private static func toolDetails(from entry: PiAgentTranscriptEntry) -> JSONValue? {
        toolEvent(from: entry)?.result?["details"]
    }

    @MainActor
    private static func toolArgs(from entry: PiAgentTranscriptEntry) -> JSONValue? {
        toolEvent(from: entry)?.args
    }

    @MainActor
    private static func toolEvent(from entry: PiAgentTranscriptEntry) -> PiAgentRPCEvent? {
        PiAgentRPCEventRenderCache.event(from: entry.rawJSON)
    }

    nonisolated private static func stringArray(_ value: JSONValue?) -> [String]? {
        guard case let .array(items)? = value else { return nil }
        let strings = items.compactMap(\.stringValue).filter { !$0.isEmpty }
        return strings.isEmpty ? nil : strings
    }

    nonisolated private static func intValue(_ value: JSONValue?) -> Int? {
        value?.numberValue.map(Int.init)
    }

    nonisolated private static func curatedSourceURLs(from details: JSONValue?) -> [String] {
        curatedSourceLinks(from: details).map(\.url)
    }

    nonisolated private static func curatedSourceLinks(from details: JSONValue?) -> [PiAgentWebLink] {
        guard case let .array(queries)? = details?["curatedQueries"] else { return [] }
        return queries.flatMap { query -> [PiAgentWebLink] in
            guard case let .array(sources)? = query["sources"] else { return [] }
            return sources.compactMap { source in
                guard let url = source["url"]?.stringValue else { return nil }
                return PiAgentWebLink(title: source["title"]?.stringValue ?? domain(from: url) ?? url, url: url)
            }
        }
    }

    nonisolated private static func parseSourceLinks(from text: String) -> [PiAgentWebLink] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var output: [PiAgentWebLink] = []
        var pendingTitle: String?
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let match = trimmed.firstMatch(of: /^\d+\.\s+(.+)$/) {
                pendingTitle = String(match.1).trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }
            guard trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") else { continue }
            output.append(PiAgentWebLink(title: pendingTitle ?? domain(from: trimmed) ?? trimmed, url: trimmed))
            pendingTitle = nil
            if output.count >= 20 { break }
        }
        return output
    }

    nonisolated private static func domains(from urls: [String]) -> [String] {
        var seen = Set<String>()
        return urls.compactMap(domain).filter { seen.insert($0).inserted }
    }

    nonisolated private static func domain(from url: String) -> String? {
        guard let host = URL(string: url)?.host(percentEncoded: false) else { return nil }
        return host.replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression)
    }
}

private extension String {
    nonisolated func truncatedMiddle(max: Int) -> String {
        guard count > max, max > 1 else { return self }
        let headCount = max / 2
        let tailCount = max - headCount - 1
        return String(prefix(headCount)) + "…" + String(suffix(tailCount))
    }
}

private extension PiAgentTranscriptEntry {
    static func mergedThinking(from entries: [PiAgentTranscriptEntry]) -> PiAgentTranscriptEntry? {
        guard let first = entries.first else { return nil }
        var seen = Set<String>()
        let text = entries.compactMap { entry -> String? in
            let trimmed = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
            return trimmed
        }.joined(separator: "\n\n")
        return PiAgentTranscriptEntry(
            id: first.id,
            sessionID: first.sessionID,
            role: .thinking,
            title: first.title,
            text: text,
            rawJSON: first.rawJSON,
            timestamp: first.timestamp
        )
    }
}

private struct PiAgentTranscriptThreadCard: View {
    let thread: PiAgentTranscriptThread
    let thinkingDisplayMode: PiAgentThinkingDisplayMode
    let visibility: PiAgentTranscriptVisibilitySettings
    let skills: [SkillRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let question = thread.question {
                PiAgentTranscriptCard(entry: question, thinkingDisplayMode: thinkingDisplayMode, style: .question, skills: skills)
                    .id(question.id)
            }

            if hasChildren {
                HStack(alignment: .top, spacing: 12) {
                    if thread.question != nil {
                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .fill(AppTheme.contentStroke)
                            .frame(width: 2)
                            .padding(.leading, 16)
                    }
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(thread.steeringMessages) { entry in
                            PiAgentTranscriptCard(entry: entry, thinkingDisplayMode: thinkingDisplayMode, style: childStyle, skills: skills)
                                .id(entry.id)
                        }
                        if let thinking = thread.thinking, effectiveThinkingDisplayMode != .hidden {
                            PiAgentTranscriptCard(entry: thinking, thinkingDisplayMode: effectiveThinkingDisplayMode, style: childStyle, skills: skills)
                                .id(thinking.id)
                        }
                        ForEach(thread.assistantMessages) { entry in
                            PiAgentTranscriptCard(entry: entry, thinkingDisplayMode: thinkingDisplayMode, style: childStyle, skills: skills)
                                .id(entry.id)
                        }
                        if visibility.showWebActivity && !webActivities.isEmpty {
                            PiAgentWebActivitySummaryView(activities: webActivities)
                        }
                        if visibility.showToolCalls && !toolActivities.isEmpty {
                            PiAgentActivitySummaryView(activities: toolActivities)
                        }
                        ForEach(thread.statuses) { entry in
                            PiAgentStatusTranscriptRow(entry: entry)
                                .id(entry.id)
                        }
                        if visibility.showErrors {
                            ForEach(thread.errors) { entry in
                                PiAgentStatusTranscriptRow(entry: entry)
                                    .id(entry.id)
                            }
                        }
                    }
                }
            }
        }
    }

    private var childStyle: PiAgentTranscriptCardStyle {
        thread.question == nil ? .standalone : .threadChild
    }

    private var hasChildren: Bool {
        !thread.steeringMessages.isEmpty || (effectiveThinkingDisplayMode != .hidden && thread.thinking != nil) || !thread.assistantMessages.isEmpty || (visibility.showWebActivity && !webActivities.isEmpty) || (visibility.showToolCalls && !toolActivities.isEmpty) || !thread.statuses.isEmpty || (visibility.showErrors && !thread.errors.isEmpty)
    }

    private var effectiveThinkingDisplayMode: PiAgentThinkingDisplayMode {
        visibility.showThinking ? thinkingDisplayMode : .hidden
    }

    private var webActivities: [PiAgentTranscriptActivity] {
        thread.activities.filter(\.isWebActivity)
    }

    private var toolActivities: [PiAgentTranscriptActivity] {
        thread.activities.filter { !$0.isWebActivity }
    }
}

private struct PiAgentWebActivitySummaryView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let activities: [PiAgentTranscriptActivity]
    @State private var expandedRows: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(hasErrors ? .red : AppTheme.mutedText)
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(callCountText)
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(displayRows) { row in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Image(systemName: row.icon)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(row.isError ? .red : AppTheme.mutedText)
                                .frame(width: 14)
                            Text(row.title)
                                .font(.caption.weight(.semibold))
                            if let detail = row.detail {
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.mutedText)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer(minLength: 0)
                            if row.count > 1 {
                                Text("×\(row.count)")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(AppTheme.mutedText)
                                    .monospacedDigit()
                            }
                        }

                        if !row.links.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(visibleLinks(for: row)) { link in
                                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                                        Text("•")
                                            .foregroundStyle(AppTheme.mutedText)
                                        Text(link.title)
                                            .font(.caption2.weight(.semibold))
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                        Text(link.domain)
                                            .font(.caption2)
                                            .foregroundStyle(AppTheme.mutedText)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                                if row.links.count > inlineLinkLimit {
                                    Button {
                                        withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) { toggleExpanded(row.id) }
                                    } label: {
                                        Text(expandedRows.contains(row.id) ? "Show fewer results" : "+\(row.links.count - inlineLinkLimit) more results")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(Color.accentColor)
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.top, 1)
                                }
                            }
                            .padding(.leading, 21)
                        }
                    }
                }
                if hiddenCount > 0 {
                    Text("\(hiddenCount) older web update\(hiddenCount == 1 ? "" : "s") hidden")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.mutedText)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AppTheme.contentSubtleFill.opacity(0.65)).stroke(AppTheme.contentStroke, lineWidth: 1))
    }

    private let inlineLinkLimit = 5

    private func visibleLinks(for row: Row) -> [PiAgentWebLink] {
        expandedRows.contains(row.id) ? row.links : Array(row.links.prefix(inlineLinkLimit))
    }

    private func toggleExpanded(_ id: UUID) {
        if expandedRows.contains(id) {
            expandedRows.remove(id)
        } else {
            expandedRows.insert(id)
        }
    }

    private var displayRows: [Row] {
        activities.map(Row.init(activity:)).prefix(4).map { $0 }
    }

    private var hiddenCount: Int {
        max(0, activities.count - displayRows.count)
    }

    private var title: String {
        let names = Set(activities.map { $0.name.lowercased() })
        if names.count == 1, let name = names.first {
            switch name {
            case "web_search": return "Web search"
            case "fetch_content": return "Fetch content"
            case "get_search_content": return "Read web content"
            case "code_search": return "Code search"
            default: break
            }
        }
        return "Web"
    }

    private var hasErrors: Bool {
        activities.contains(where: \.isError)
    }

    private var callCountText: String {
        let count = activities.reduce(0) { $0 + $1.count }
        return count == 1 ? "1 call" : "\(count) calls"
    }

    private struct Row: Identifiable {
        let id: UUID
        let title: String
        let detail: String?
        let icon: String
        let count: Int
        let isError: Bool
        let links: [PiAgentWebLink]

        nonisolated init(activity: PiAgentTranscriptActivity) {
            id = activity.id
            title = Self.title(for: activity.name)
            detail = activity.compactDetail
            icon = Self.icon(for: activity.name)
            count = activity.count
            isError = activity.isError
            links = activity.webLinks
        }

        nonisolated private static func title(for name: String) -> String {
            switch name.lowercased() {
            case "web_search": return "Search"
            case "fetch_content": return "Fetched"
            case "get_search_content": return "Read content"
            case "code_search": return "Code search"
            default: return name.replacingOccurrences(of: "_", with: " ").capitalized
            }
        }

        nonisolated private static func icon(for name: String) -> String {
            switch name.lowercased() {
            case "web_search": return "magnifyingglass"
            case "fetch_content", "get_search_content": return "doc.text.magnifyingglass"
            case "code_search": return "curlybraces.square"
            default: return "globe"
            }
        }
    }
}

private struct PiAgentActivitySummaryView: View {
    let activities: [PiAgentTranscriptActivity]

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: hasErrors ? "exclamationmark.triangle" : "wrench.and.screwdriver")
                .font(.caption.weight(.semibold))
                .foregroundStyle(hasErrors ? .red : AppTheme.mutedText)
            Text("Tools")
                .font(.caption.weight(.semibold))
            Text(callCountText)
                .font(.caption)
                .foregroundStyle(AppTheme.mutedText)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(activities) { activity in
                        activityChip(activity)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AppTheme.contentSubtleFill.opacity(0.65)).stroke(AppTheme.contentStroke, lineWidth: 1))
    }

    private var hasErrors: Bool {
        activities.contains(where: \.isError)
    }

    private var callCountText: String {
        let count = activities.reduce(0) { $0 + $1.count }
        return count == 1 ? "1 call" : "\(count) calls"
    }

    private func activityChip(_ activity: PiAgentTranscriptActivity) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon(for: activity.name))
                .font(.caption2.weight(.semibold))
            Text(displayName(for: activity.name, count: activity.count))
                .font(.caption)
            Text("\(activity.count)")
                .font(.caption2.weight(.bold))
                .monospacedDigit()
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule(style: .continuous).fill(AppTheme.contentStroke.opacity(0.55)))
        }
        .foregroundStyle(activity.isError ? .red : AppTheme.mutedText)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule(style: .continuous).fill((activity.isError ? Color.red : AppTheme.contentStroke).opacity(0.12)))
    }

    private func displayName(for name: String, count: Int) -> String {
        switch name.lowercased() {
        case "bash": return "Shell"
        case "read": return "File read"
        case "edit": return "Edit"
        case "write": return "Write"
        case "subagent": return count == 1 ? "Subagent" : "Subagents"
        case "web_search": return "Web search"
        case "fetch_content", "get_search_content": return "Web content"
        case "code_search": return "Code search"
        case "intercom": return "Intercom"
        default:
            return name
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
                .split(separator: " ")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }

    private func icon(for name: String) -> String {
        switch name.lowercased() {
        case "bash": return "terminal"
        case "read": return "doc.text.magnifyingglass"
        case "edit", "write": return "pencil.and.outline"
        case "subagent": return "person.2.wave.2"
        case "web_search", "fetch_content", "get_search_content": return "globe"
        case "code_search": return "curlybraces.square"
        case "intercom": return "bubble.left.and.bubble.right"
        default: return "wrench.and.screwdriver"
        }
    }
}

private struct PiAgentActivityDetailView: View {
    let activity: PiAgentTranscriptActivity

    var body: some View {
        if let summary = activity.subagentSummary {
            PiAgentSubagentTranscriptView(summary: summary)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AppTheme.contentSubtleFill.opacity(0.65)))
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .foregroundStyle(activity.isError ? .red : AppTheme.mutedText)
                    Text(activity.name)
                        .font(.caption.weight(.semibold))
                    if activity.count > 1 {
                        Text("×\(activity.count)")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(AppTheme.mutedText)
                    }
                    Spacer()
                }
                ForEach(activity.entries.suffix(3)) { entry in
                    PiAgentToolTranscriptView(entry: entry, startsExpanded: false)
                }
                if activity.entries.count > 3 {
                    Text("\(activity.entries.count - 3) older updates hidden")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.mutedText)
                }
            }
        }
    }

    private var icon: String {
        switch activity.name.lowercased() {
        case "bash": return "terminal"
        case "read": return "doc.text.magnifyingglass"
        case "edit", "write": return "pencil.and.outline"
        case "subagent": return "person.2.wave.2"
        default: return "wrench.and.screwdriver"
        }
    }
}

private struct PiAgentStatusTranscriptRow: View {
    let entry: PiAgentTranscriptEntry

    var body: some View {
        if entry.title == "Compaction" {
            compactionDivider
        } else {
            compactStatusRow
        }
    }

    private var compactionDivider: some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(AppTheme.contentStroke.opacity(0.9))
                .frame(height: 1)
            HStack(spacing: 7) {
                if isCompacting {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.mutedText)
                }
                Text(detail)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.mutedText)
                    .lineLimit(1)
                Text(entry.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(AppTheme.mutedText)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule(style: .continuous).fill(AppTheme.contentSubtleFill.opacity(0.75)).stroke(AppTheme.contentStroke, lineWidth: 1))
            Rectangle()
                .fill(AppTheme.contentStroke.opacity(0.9))
                .frame(height: 1)
        }
        .padding(.vertical, 4)
    }

    private var compactStatusRow: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
            Text(title)
                .font(.caption.weight(.semibold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(AppTheme.mutedText)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Text(entry.timestamp.formatted(date: .omitted, time: .shortened))
                .font(.caption2)
                .foregroundStyle(AppTheme.mutedText)
            if isCopyableToolError {
                Button {
                    copyToPasteboard(errorClipboardText)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption.weight(.semibold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .help("Copy tool error")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(color.opacity(0.08)).stroke(color.opacity(0.16), lineWidth: 1))
    }

    private var title: String {
        if entry.title == "Compaction" { return "Context" }
        if entry.title.hasPrefix("Tool: ") { return "Tool failed" }
        return entry.title
    }

    private var isCopyableToolError: Bool {
        entry.role == .error && entry.title.hasPrefix("Tool: ")
    }

    private var errorClipboardText: String {
        let toolName = entry.title.replacingOccurrences(of: "Tool: ", with: "")
        return "Tool failed: \(toolName)\n\n\(entry.text)"
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private var detail: String {
        let normalized = entry.text
            .replacingOccurrences(of: "Context compacted.", with: "compacted")
            .replacingOccurrences(of: "Context compacted", with: "compacted")
            .replacingOccurrences(of: "Compacting conversation context (context)…", with: "compacting…")
            .replacingOccurrences(of: "Compacting context…", with: "compacting…")
            .replacingOccurrences(of: "\n", with: " ")
        if entry.title.hasPrefix("Tool: ") {
            let toolName = entry.title.replacingOccurrences(of: "Tool: ", with: "")
            return "\(toolName): \(normalized)"
        }
        return normalized
    }

    private var isCompacting: Bool {
        detail.localizedCaseInsensitiveContains("compacting") && !detail.localizedCaseInsensitiveContains("compacted")
    }

    private var icon: String {
        if entry.title == "Compaction" { return "arrow.triangle.2.circlepath" }
        if entry.role == .error { return "exclamationmark.triangle" }
        return "info.circle"
    }

    private var color: Color {
        if entry.title == "Compaction" { return .secondary }
        if entry.role == .error { return .red }
        return .secondary
    }
}

private enum PiAgentTranscriptCardStyle {
    case standalone
    case question
    case threadChild
}

private struct PiAgentTranscriptCard: View {
    let entry: PiAgentTranscriptEntry
    let thinkingDisplayMode: PiAgentThinkingDisplayMode
    var style: PiAgentTranscriptCardStyle = .standalone
    var skills: [SkillRecord] = []
    @State private var isThinkingExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .frame(width: 16)
                Text(headerTitle)
                    .font(.caption.weight(.semibold))
                    .fontWidth(.expanded)
                    .foregroundStyle(headerColor)
                Spacer(minLength: 8)
                Text(entry.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(AppTheme.mutedText)
            }

            content
        }
        .padding(.horizontal, style == .threadChild ? 12 : 14)
        .padding(.vertical, style == .threadChild ? 9 : 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(backgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(strokeColor, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var content: some View {
        if let subagentSummary = PiAgentSubagentSummary(entry: entry) {
            PiAgentSubagentTranscriptView(summary: subagentSummary)
        } else if entry.role == .tool {
            PiAgentToolTranscriptView(entry: entry)
        } else if entry.role == .thinking {
            thinkingContent
        } else if entry.role == .assistant && entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            HStack(spacing: 10) {
                Text("Pi is thinking")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                PiAgentTypingIndicator()
            }
        } else if entry.role == .user, let skillUse = skillUse {
            VStack(alignment: .leading, spacing: 8) {
                PiAgentSkillUsePill(skill: skillUse.skill, invocation: skillUse.invocation)
                if !skillUse.remainingText.isEmpty {
                    MarkdownTextView(source: skillUse.remainingText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else if entry.role == .assistant || entry.role == .user {
            MarkdownTextView(source: entry.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(entry.text)
                .font(entry.role == .tool || entry.role == .stderr || entry.role == .raw ? .system(.body, design: .monospaced) : .body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var thinkingContent: some View {
        switch thinkingDisplayMode {
        case .full:
            reasoningDisclosure(source: entry.text, defaultExpanded: true)
        case .compact:
            reasoningDisclosure(source: entry.text, defaultExpanded: false)
        case .hidden:
            Text("Thinking…")
                .font(.body.italic())
                .foregroundStyle(AppTheme.mutedText)
        }
    }

    private func reasoningDisclosure(source: String, defaultExpanded: Bool) -> some View {
        let displayText = source.trimmingCharacters(in: .whitespacesAndNewlines)
        return DisclosureGroup(isExpanded: $isThinkingExpanded) {
            MarkdownTextView(source: displayText.isEmpty ? "Pi has not emitted reasoning text yet." : displayText)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack(spacing: 6) {
                Text("Reasoning")
                    .font(.caption.weight(.semibold))
                if thinkingDisplayMode == .compact && !isThinkingExpanded {
                    Text(compactPreview(displayText))
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedText)
                        .lineLimit(3)
                }
            }
        }
        .onAppear {
            isThinkingExpanded = defaultExpanded
        }
    }

    private func compactPreview(_ text: String) -> String {
        let allLines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let preview = allLines.prefix(3).joined(separator: "\n")
        return allLines.count > 3 ? preview + "…" : preview
    }

    private var skillUse: (skill: SkillRecord?, invocation: String, remainingText: String)? {
        let trimmed = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/skill:") else { return nil }
        let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let invocationPart = parts.first else { return nil }
        let invocation = String(invocationPart)
        let name = String(invocation.dropFirst("/skill:".count))
        let skill = skills.first { $0.name == name }
        let remaining = parts.count > 1 ? String(parts[1]) : ""
        return (skill, invocation, remaining)
    }

    private var headerTitle: String {
        if entry.title == "Steering" { return "Steering" }
        switch entry.role {
        case .user: return "You"
        case .assistant: return "Pi"
        case .tool: return toolHeaderTitle
        default: return entry.title
        }
    }

    private var toolHeaderTitle: String {
        if entry.title.localizedCaseInsensitiveContains("subagent") || entry.text.localizedCaseInsensitiveContains("subagent") {
            return "Subagents"
        }
        if entry.title.hasPrefix("Tool: ") {
            return "Tool · " + entry.title.replacingOccurrences(of: "Tool: ", with: "")
        }
        return entry.title
    }

    private var headerColor: Color {
        entry.role == .user ? Color.accentColor : .primary
    }

    private var backgroundColor: Color {
        switch entry.role {
        case .user: return style == .question ? Color.accentColor.opacity(0.10) : Color.accentColor.opacity(0.08)
        case .assistant: return Color.purple.opacity(0.06)
        case .thinking: return Color.indigo.opacity(0.07)
        case .tool: return style == .threadChild ? Color.orange.opacity(0.05) : Color.orange.opacity(0.08)
        case .status: return AppTheme.contentSubtleFill.opacity(0.7)
        case .error: return Color.red.opacity(0.08)
        case .stderr: return Color.pink.opacity(0.08)
        case .raw: return AppTheme.contentSubtleFill
        }
    }

    private var strokeColor: Color {
        switch entry.role {
        case .user: return Color.accentColor.opacity(0.2)
        case .assistant: return Color.purple.opacity(0.18)
        case .thinking: return Color.indigo.opacity(0.18)
        case .tool: return Color.orange.opacity(0.2)
        case .error: return Color.red.opacity(0.22)
        case .stderr: return Color.pink.opacity(0.2)
        case .status: return AppTheme.contentStroke
        case .raw: return AppTheme.contentStroke
        }
    }

    private var icon: String {
        switch entry.role {
        case .user: return entry.title == "Steering" ? "arrowshape.turn.up.forward.circle" : "person.crop.circle"
        case .assistant: return "sparkles"
        case .thinking: return "brain.head.profile"
        case .tool: return entry.title.localizedCaseInsensitiveContains("subagent") ? "person.2.wave.2" : "hammer"
        case .status: return "info.circle"
        case .error: return "exclamationmark.triangle"
        case .stderr: return "terminal"
        case .raw: return "curlybraces"
        }
    }

    private var color: Color {
        switch entry.role {
        case .user: return .blue
        case .assistant: return .purple
        case .thinking: return .indigo
        case .tool: return .orange
        case .status: return .secondary
        case .error: return .red
        case .stderr: return .pink
        case .raw: return .secondary
        }
    }
}

private struct PiAgentToolTranscriptView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let entry: PiAgentTranscriptEntry
    @State private var isExpanded: Bool

    init(entry: PiAgentTranscriptEntry, startsExpanded: Bool = false) {
        self.entry = entry
        _isExpanded = State(initialValue: startsExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(toolName, systemImage: icon)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(color)
                Text(phaseLabel)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule(style: .continuous).fill(color.opacity(0.12)))
                    .foregroundStyle(color)
                Spacer(minLength: 0)
                if isLong {
                    Button(isExpanded ? "Show less" : "Show details") {
                        withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) { isExpanded.toggle() }
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                }
            }

            Text(displayText)
                .font(.caption.monospaced())
                .foregroundStyle(.primary.opacity(0.82))
                .lineLimit(isExpanded ? nil : 6)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AppTheme.contentSubtleFill.opacity(0.7)))
        }
    }

    private var toolName: String {
        entry.title.replacingOccurrences(of: "Tool: ", with: "")
    }

    private var phaseLabel: String {
        let lower = entry.text.lowercased()
        if lower.contains("starting") || lower.contains("preparing") { return "starting" }
        if lower.contains("running") || lower.contains("0/1 done") { return "running" }
        if entry.role == .error { return "failed" }
        return "result"
    }

    private var displayText: String {
        let trimmed = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "No details emitted yet." : trimmed
    }

    private var isLong: Bool {
        displayText.count > 600 || displayText.split(separator: "\n").count > 8
    }

    private var icon: String {
        switch toolName.lowercased() {
        case "bash": return "terminal"
        case "read": return "doc.text.magnifyingglass"
        case "edit", "write": return "pencil.and.outline"
        case "subagent": return "person.2.wave.2"
        default: return "wrench.and.screwdriver"
        }
    }

    private var color: Color {
        entry.role == .error ? .red : .orange
    }
}

struct PiAgentActivityPanel: View {
    @ObservedObject var store: PiAgentSessionStore
    @Binding var isPresented: Bool
    @State private var filter: PiAgentActivityFilter = .all
    @State private var selectedID: UUID?

    private var items: [PiAgentActivityItem] {
        PiAgentActivityItem.items(from: store.selectedTranscript)
            .filter { filter.includes($0) }
    }

    private var selectedItem: PiAgentActivityItem? {
        if let selectedID, let item = items.first(where: { $0.id == selectedID }) { return item }
        return items.first(where: { $0.kind.isFileMutation }) ?? items.first
    }

    var body: some View {
        AppSidebarPane(title: "Activity", subtitle: subtitle) {
            VStack(alignment: .leading, spacing: 0) {
                activityHeader
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    if store.selectedSession == nil {
                        compactEmptyState(title: "No session selected", message: "Select a Pi Agent session to inspect tool activity.", icon: "wrench.and.screwdriver")
                    } else {
                        stickyContext
                        filterBar
                        if items.isEmpty {
                            compactEmptyState(title: "No activity", message: filter.emptyMessage, icon: filter.emptyIcon)
                        } else {
                            ScrollView(showsIndicators: false) {
                                LazyVStack(alignment: .leading, spacing: 10) {
                                    ForEach(items) { item in
                                        PiAgentActivityRow(
                                            item: item,
                                            isSelected: selectedItem?.id == item.id,
                                            rootPath: selectedRootPath,
                                            onSelect: { selectedID = item.id }
                                        )
                                    }
                                }
                                .padding(.bottom, 18)
                            }
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .onChange(of: store.selectedSession?.id) { _, _ in selectedID = nil }
        .onChange(of: items.map(\.id)) { _, ids in
            guard let selectedID, !ids.contains(selectedID) else { return }
            self.selectedID = nil
        }
    }

    private var activityHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppTheme.mutedText)
                .frame(width: 28, height: 28)
                .background(Circle().fill(AppTheme.contentFill).stroke(AppTheme.contentStroke, lineWidth: 1))
            VStack(alignment: .leading, spacing: 2) {
                Text("Activity")
                    .font(.headline.weight(.semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedText)
                }
            }
            Spacer(minLength: 0)
            Button {
                isPresented = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppTheme.mutedText)
            .help("Close activity sidebar")
            .accessibilityLabel("Close activity sidebar")
        }
    }

    private var subtitle: String? {
        guard store.selectedSession != nil else { return nil }
        let count = items.count
        return count == 1 ? "1 event" : "\(count) events"
    }

    private var selectedRootPath: String? {
        store.selectedSession.map { $0.worktreePath ?? $0.projectPath }
    }

    @ViewBuilder
    private var stickyContext: some View {
        if let session = store.selectedSession {
            if let plan = store.sessionPlan(for: session.id), !plan.items.isEmpty {
                PiAgentCurrentPlanCard(plan: plan)
            }
            let runs = stickySubagentRuns(for: session.id)
            if !runs.isEmpty {
                PiAgentActivitySubagentsCard(runs: runs)
            }
        }
    }

    private func stickySubagentRuns(for sessionID: UUID) -> [PiSubagentRunRecord] {
        // The activity sidebar is for current work. Completed subagents already
        // have transcript cards, so repeating them here makes the UI noisy.
        Array(store.subagentRuns(for: sessionID).filter(\.status.isActive).prefix(4))
    }

    private var filterBar: some View {
        Picker("Activity filter", selection: $filter) {
            ForEach(PiAgentActivityFilter.allCases) { filter in
                Text(filter.label).tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private func compactEmptyState(title: String, message: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(AppTheme.mutedText)
            Text(title)
                .font(.headline.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(AppTheme.mutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(AppTheme.contentFill).stroke(AppTheme.contentStroke, lineWidth: 1))
    }
}

private struct PiAgentCurrentPlanCard: View {
    let plan: PiSessionPlanRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "checklist")
                    .foregroundStyle(AppTheme.mutedText)
                Text("Current Plan")
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 0)
                Text(progressText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(AppTheme.mutedText)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(plan.items) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: icon(for: item.status))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(color(for: item.status))
                            .frame(width: 16)
                        Text(item.title)
                            .font(.caption)
                            .foregroundStyle(item.status == .done || item.status == .skipped ? AppTheme.mutedText : .primary)
                            .strikethrough(item.status == .skipped, color: AppTheme.mutedText)
                            .lineLimit(2)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AppTheme.contentSubtleFill.opacity(0.82)).stroke(AppTheme.contentStroke, lineWidth: 1))
    }

    private var progressText: String {
        let done = plan.items.filter { $0.status == .done || $0.status == .skipped }.count
        return "\(done)/\(plan.items.count)"
    }

    private func icon(for status: PiSessionPlanItemStatus) -> String {
        switch status {
        case .todo: return "circle"
        case .inProgress: return "smallcircle.filled.circle"
        case .done: return "checkmark.circle.fill"
        case .blocked: return "exclamationmark.circle.fill"
        case .skipped: return "minus.circle"
        }
    }

    private func color(for status: PiSessionPlanItemStatus) -> Color {
        switch status {
        case .todo: return AppTheme.mutedText
        case .inProgress: return .blue
        case .done: return .green
        case .blocked: return .orange
        case .skipped: return AppTheme.mutedText
        }
    }
}

private struct PiAgentActivitySubagentsCard: View {
    let runs: [PiSubagentRunRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "rectangle.connected.to.line.below")
                    .foregroundStyle(AppTheme.mutedText)
                Text("Native Subagents")
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 0)
                Text("\(runs.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(AppTheme.mutedText)
            }
            VStack(alignment: .leading, spacing: 7) {
                ForEach(runs) { run in
                    PiAgentActivitySubagentRow(run: run)
                    if run.id != runs.last?.id { Divider().opacity(0.5) }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AppTheme.contentSubtleFill.opacity(0.82)).stroke(AppTheme.contentStroke, lineWidth: 1))
    }
}

private struct PiAgentActivitySubagentRow: View {
    let run: PiSubagentRunRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Circle()
                    .fill(color(for: run.status))
                    .frame(width: 7, height: 7)
                Text(run.agentName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(run.status.rawValue)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(color(for: run.status))
                Spacer(minLength: 0)
                if run.isWorktreeIsolated == true {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.caption2)
                        .foregroundStyle(AppTheme.mutedText)
                        .help("Isolated worktree")
                }
            }
            Text(run.task)
                .font(.caption2)
                .foregroundStyle(AppTheme.mutedText)
                .lineLimit(2)
            if let children = run.children, !children.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(children.sorted { $0.index < $1.index }.prefix(4)) { child in
                        HStack(spacing: 5) {
                            Circle().fill(color(for: child.status)).frame(width: 5, height: 5)
                            Text("\(child.index + 1). \(child.agentName)")
                                .font(.caption2.weight(.semibold))
                                .lineLimit(1)
                            Text(child.status.rawValue)
                                .font(.caption2)
                                .foregroundStyle(AppTheme.mutedText)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(.leading, 12)
            }
        }
    }

    private func color(for status: PiSubagentRunStatus) -> Color {
        switch status {
        case .queued, .starting, .running: return .blue
        case .blocked: return .orange
        case .completed: return .green
        case .failed: return .red
        case .stopped, .disconnected: return AppTheme.mutedText
        }
    }
}

private enum PiAgentActivityFilter: String, CaseIterable, Identifiable {
    case all
    case files
    case shell
    case web
    case errors

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All"
        case .files: return "Files"
        case .shell: return "Shell"
        case .web: return "Web"
        case .errors: return "Errors"
        }
    }

    var emptyMessage: String {
        switch self {
        case .all: return "Tool calls will appear here while the agent works."
        case .files: return "File reads, writes, and edits will appear here."
        case .shell: return "Shell commands will appear here."
        case .web: return "Web activity will appear here."
        case .errors: return "Tool failures will appear here."
        }
    }

    var emptyIcon: String {
        switch self {
        case .all: return "wrench.and.screwdriver"
        case .files: return "doc.text.magnifyingglass"
        case .shell: return "terminal"
        case .web: return "globe"
        case .errors: return "exclamationmark.triangle"
        }
    }

    func includes(_ item: PiAgentActivityItem) -> Bool {
        switch self {
        case .all: return true
        case .files: return item.kind.isFileActivity
        case .shell: return item.kind == .bash
        case .web: return item.kind.isWebActivity
        case .errors: return item.status == .failed
        }
    }
}

private enum PiAgentActivityKind: String, Hashable {
    case edit
    case write
    case read
    case bash
    case web
    case subagent
    case supervisor
    case tool
    case error

    var isFileMutation: Bool { self == .edit || self == .write }
    var isFileActivity: Bool { self == .edit || self == .write || self == .read }
    var isWebActivity: Bool { self == .web }

    var displayName: String {
        switch self {
        case .edit: return "Edit"
        case .write: return "Write"
        case .read: return "Read"
        case .bash: return "Shell"
        case .web: return "Web"
        case .subagent: return "Subagent"
        case .supervisor: return "Supervisor"
        case .tool: return "Tool"
        case .error: return "Error"
        }
    }

    var icon: String {
        switch self {
        case .edit, .write: return "pencil.and.outline"
        case .read: return "doc.text.magnifyingglass"
        case .bash: return "terminal"
        case .web: return "globe"
        case .subagent: return "person.2.wave.2"
        case .supervisor: return "person.crop.circle.badge.questionmark"
        case .tool: return "wrench.and.screwdriver"
        case .error: return "exclamationmark.triangle"
        }
    }
}

private enum PiAgentActivityStatus: Hashable {
    case running
    case completed
    case failed

    var label: String {
        switch self {
        case .running: return "running"
        case .completed: return "done"
        case .failed: return "failed"
        }
    }

    var color: Color {
        switch self {
        case .running: return .blue
        case .completed: return .green
        case .failed: return .red
        }
    }
}

private struct PiAgentActivityItem: Identifiable, Hashable {
    let id: UUID
    let entry: PiAgentTranscriptEntry
    let kind: PiAgentActivityKind
    let status: PiAgentActivityStatus
    let toolName: String
    let path: String?
    let command: String?
    let contentPreview: String?
    let diff: String?
    let detailText: String

    @MainActor
    static func items(from entries: [PiAgentTranscriptEntry]) -> [PiAgentActivityItem] {
        entries.compactMap(PiAgentActivityItem.init(entry:)).reversed()
    }

    init?(entry: PiAgentTranscriptEntry) {
        guard entry.role == .tool || entry.role == .error || (entry.role == .status && entry.title.localizedCaseInsensitiveContains("Supervisor")) else { return nil }
        let event = Self.event(from: entry.rawJSON)
        let rawToolName = event?.toolName ?? entry.title.replacingOccurrences(of: "Tool: ", with: "")
        let toolName = rawToolName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? entry.title : rawToolName
        let lower = toolName.lowercased()
        let kind: PiAgentActivityKind
        if entry.role == .error {
            kind = lower.hasPrefix("tool:") ? .tool : .error
        } else if lower == "edit" {
            kind = .edit
        } else if lower == "write" {
            kind = .write
        } else if lower == "read" {
            kind = .read
        } else if lower == "bash" {
            kind = .bash
        } else if ["web_search", "fetch_content", "get_search_content", "code_search"].contains(lower) {
            kind = .web
        } else if lower.contains("subagent") || lower.hasPrefix("managed_") {
            kind = .subagent
        } else if entry.title.localizedCaseInsensitiveContains("Supervisor") || lower.contains("supervisor") {
            kind = .supervisor
        } else {
            kind = .tool
        }

        let status: PiAgentActivityStatus
        if entry.role == .error || event?.isError == true {
            status = .failed
        } else if event?.type == "tool_execution_start" || event?.type == "tool_execution_update" {
            status = .running
        } else {
            status = .completed
        }

        let args = event?.args
        let path = args?["path"]?.stringValue ?? args?["file_path"]?.stringValue ?? Self.pathFromText(entry.text)
        let command = args?["command"]?.stringValue ?? args?["cmd"]?.stringValue ?? (kind == .bash ? entry.text.components(separatedBy: "\n").first : nil)
        let contentPreview = args?["content"]?.stringValue
        let diff = event?.result?["details"]?["diff"]?.stringValue ?? Self.syntheticDiff(from: args)
        let detailText = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)

        self.id = entry.id
        self.entry = entry
        self.kind = kind
        self.status = status
        self.toolName = toolName
        self.path = path
        self.command = command
        self.contentPreview = contentPreview
        self.diff = diff
        self.detailText = detailText.isEmpty ? "No details emitted yet." : detailText
    }

    var title: String {
        switch kind {
        case .edit, .write, .read:
            return path?.truncatedMiddle(max: 48) ?? kind.displayName
        case .bash:
            return command?.truncatedMiddle(max: 48) ?? "Shell command"
        default:
            return kind.displayName == "Tool" ? toolName : kind.displayName
        }
    }

    var subtitle: String {
        switch kind {
        case .edit:
            return diff == nil ? "edit · \(status.label)" : "edit diff · \(status.label)"
        case .write:
            return contentPreview == nil ? "write · \(status.label)" : "write preview · \(status.label)"
        case .read:
            return "file read · \(status.label)"
        case .bash:
            return "shell · \(status.label)"
        case .web:
            return "web · \(status.label)"
        case .subagent:
            return "native delegation · \(status.label)"
        case .supervisor:
            return "routing · \(status.label)"
        case .tool:
            return "\(toolName) · \(status.label)"
        case .error:
            return "error"
        }
    }

    private static func event(from rawJSON: String?) -> PiAgentRPCEvent? {
        guard let rawJSON, let data = rawJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PiAgentRPCEvent.self, from: data)
    }

    private static func pathFromText(_ text: String) -> String? {
        let patterns = [#"in ([^\n]+)$"#, #"to ([^\n]+)$"#, #"from ([^\n]+)$"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: text) else { continue }
            return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }
        return nil
    }

    private static func syntheticDiff(from args: JSONValue?) -> String? {
        guard let editsValue = args?["edits"] else {
            if let oldText = args?["oldText"]?.stringValue, let newText = args?["newText"]?.stringValue {
                return syntheticDiff(edits: [(oldText, newText)])
            }
            return nil
        }
        let edits: [(String, String)]
        switch editsValue {
        case let .array(values):
            edits = values.compactMap { value in
                guard let old = value["oldText"]?.stringValue,
                      let new = value["newText"]?.stringValue else { return nil }
                return (old, new)
            }
        case let .string(raw):
            guard let data = raw.data(using: .utf8),
                  let decoded = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
            edits = decoded.compactMap { dict in
                guard let old = dict["oldText"] as? String,
                      let new = dict["newText"] as? String else { return nil }
                return (old, new)
            }
        default:
            edits = []
        }
        return syntheticDiff(edits: edits)
    }

    private static func syntheticDiff(edits: [(String, String)]) -> String? {
        guard !edits.isEmpty else { return nil }
        var lines: [String] = []
        for (index, edit) in edits.enumerated() {
            if index > 0 { lines.append("  ...") }
            lines.append(contentsOf: edit.0.split(separator: "\n", omittingEmptySubsequences: false).map { "-  \($0)" })
            lines.append(contentsOf: edit.1.split(separator: "\n", omittingEmptySubsequences: false).map { "+  \($0)" })
        }
        return lines.joined(separator: "\n")
    }
}

private struct PiAgentActivityRow: View {
    let item: PiAgentActivityItem
    let isSelected: Bool
    let rootPath: String?
    let onSelect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onSelect) {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: item.kind.icon)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(item.status == .failed ? .red : AppTheme.mutedText)
                        .frame(width: 18, height: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(item.title)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                            Text(item.entry.timestamp.formatted(date: .omitted, time: .shortened))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(AppTheme.mutedText)
                        }
                        HStack(spacing: 6) {
                            Text(item.subtitle)
                                .font(.caption2)
                                .foregroundStyle(AppTheme.mutedText)
                                .lineLimit(1)
                            Circle()
                                .fill(item.status.color)
                                .frame(width: 6, height: 6)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isSelected {
                PiAgentActivityDetail(item: item, rootPath: rootPath)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(isSelected ? AppTheme.contentSubtleFill.opacity(0.9) : AppTheme.contentSubtleFill.opacity(0.55)).stroke(isSelected ? Color.accentColor.opacity(0.35) : AppTheme.contentStroke, lineWidth: 1))
    }
}

private struct PiAgentActivityDetail: View {
    let item: PiAgentActivityItem
    let rootPath: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if item.kind.isFileActivity, let path = item.path {
                fileActions(path: path)
            }

            switch item.kind {
            case .edit:
                if let diff = item.diff, !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    PiAgentDiffView(diffText: diff)
                } else {
                    quietNote("No diff payload was emitted for this edit.")
                }
            case .write:
                if let preview = item.contentPreview {
                    PiAgentCodePreview(title: "Content preview", text: preview, maxHeight: 180, lineLimit: 24)
                } else {
                    quietNote(item.detailText)
                }
            case .bash:
                if let command = item.command, !command.isEmpty {
                    PiAgentCodePreview(title: "Command", text: command, maxHeight: 80, lineLimit: 8)
                }
                PiAgentCodePreview(title: "Output", text: item.detailText, maxHeight: 180, lineLimit: 32)
            case .web:
                PiAgentWebActivitySnippet(entry: item.entry)
            default:
                quietNote(item.detailText)
            }
        }
    }

    private func fileActions(path: String) -> some View {
        HStack(spacing: 8) {
            Text(path)
                .font(.caption2.monospaced())
                .foregroundStyle(AppTheme.mutedText)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Button("Open") { if let url = resolvedURL(for: path) { NSWorkspace.shared.open(url) } }
                .font(.caption.weight(.semibold))
                .buttonStyle(.plain)
                .disabled(resolvedURL(for: path) == nil)
            Button("Reveal") { if let url = resolvedURL(for: path) { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
                .font(.caption.weight(.semibold))
                .buttonStyle(.plain)
                .disabled(resolvedURL(for: path) == nil)
            if let diff = item.diff {
                Button("Copy Diff") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(diff, forType: .string) }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
            }
        }
    }

    private func quietNote(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(AppTheme.mutedText)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(9)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(AppTheme.contentSubtleFill.opacity(0.6)))
    }

    private func resolvedURL(for path: String) -> URL? {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded) }
        guard let rootPath else { return nil }
        return URL(fileURLWithPath: rootPath).appendingPathComponent(path)
    }
}

private struct PiAgentWebActivitySnippet: View {
    let entry: PiAgentTranscriptEntry

    var body: some View {
        if let activity = PiAgentTranscriptActivity.make(from: [entry]).first {
            PiAgentWebActivitySummaryView(activities: [activity])
        } else {
            Text("Web activity details are unavailable for this event.")
                .font(.caption)
                .foregroundStyle(AppTheme.mutedText)
        }
    }
}

private struct PiAgentCodePreview: View {
    let title: String?
    let text: String
    var maxHeight: CGFloat = 240
    var lineLimit: Int = 80
    @State private var cachedDisplayText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AppTheme.mutedText)
            }
            ScrollView([.horizontal, .vertical]) {
                Text(cachedDisplayText.isEmpty ? displayText : cachedDisplayText)
                    .font(.caption.monospaced())
                    .foregroundStyle(.primary.opacity(0.82))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(9)
            }
            .frame(maxHeight: maxHeight)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.04)))
        }
        .onAppear(perform: rebuildDisplayText)
        .onChange(of: text) { _, _ in rebuildDisplayText() }
    }

    private var displayText: String {
        Self.displayText(for: text, lineLimit: lineLimit)
    }

    private func rebuildDisplayText() {
        cachedDisplayText = Self.displayText(for: text, lineLimit: lineLimit)
    }

    private static func displayText(for text: String, lineLimit: Int) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count > lineLimit else { return text }
        return lines.prefix(lineLimit).joined(separator: "\n") + "\n… \(lines.count - lineLimit) more lines"
    }
}

private struct PiAgentDiffView: View {
    let diffText: String
    @State private var lines: [PiAgentDiffLine] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Diff")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AppTheme.mutedText)
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines.indices, id: \.self) { index in
                        let line = lines[index]
                        HStack(alignment: .top, spacing: 8) {
                            Text(line.gutter)
                                .font(.caption.monospaced())
                                .foregroundStyle(line.gutterColor)
                                .frame(width: 52, alignment: .trailing)
                            Text(line.content.isEmpty ? " " : line.content)
                                .font(.caption.monospaced())
                                .foregroundStyle(line.textColor)
                                .textSelection(.enabled)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .frame(minWidth: 620, alignment: .leading)
                        .background(line.background)
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 320)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.04)))
        }
        .onAppear(perform: rebuildLines)
        .onChange(of: diffText) { _, _ in rebuildLines() }
    }

    private func rebuildLines() {
        lines = diffText.split(separator: "\n", omittingEmptySubsequences: false).map { PiAgentDiffLine(raw: String($0)) }
    }
}

private struct PiAgentDiffLine: Hashable {
    let prefix: String
    let lineNumber: String
    let content: String

    init(raw: String) {
        let pattern = #"^([+\-\s])(\s*\d*)\s(.*)$"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
           match.numberOfRanges == 4,
           let prefixRange = Range(match.range(at: 1), in: raw),
           let lineRange = Range(match.range(at: 2), in: raw),
           let contentRange = Range(match.range(at: 3), in: raw) {
            prefix = String(raw[prefixRange])
            lineNumber = String(raw[lineRange]).trimmingCharacters(in: .whitespaces)
            content = String(raw[contentRange]).replacingOccurrences(of: "\t", with: "   ")
        } else {
            prefix = " "
            lineNumber = ""
            content = raw.replacingOccurrences(of: "\t", with: "   ")
        }
    }

    var gutter: String {
        let number = lineNumber.isEmpty ? "" : lineNumber
        return "\(prefix)\(number)"
    }

    var background: Color {
        switch prefix {
        case "+": return Color.green.opacity(0.14)
        case "-": return Color.red.opacity(0.14)
        default: return Color.clear
        }
    }

    var textColor: Color {
        switch prefix {
        case "+": return .green
        case "-": return .red
        default: return AppTheme.mutedText
        }
    }

    var gutterColor: Color { textColor.opacity(prefix == " " ? 0.75 : 1) }
}

struct PiAgentRepoChangesPanel: View {
    @ObservedObject var viewModel: AppViewModel
    @Binding var isPresented: Bool
    @State private var filterText = ""

    private var snapshot: RepositoryChangesSnapshot? { viewModel.githubRepositoryChanges }

    private var items: [PiAgentGitChangeListItem] {
        guard let snapshot else { return [] }
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        return PiAgentGitChangeListItem.items(from: snapshot).filter { item in
            query.isEmpty || item.path.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        AppSidebarPane(title: "Repo Changes", subtitle: snapshot.map { "\($0.totalChangeCount) changes" }) {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)

                Divider()

                panelContent
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .task { viewModel.prepareRepoChangesForSelectedPiAgentSession() }
    }

    @ViewBuilder
    private var panelContent: some View {
        if let error = viewModel.githubLastError {
            VStack(alignment: .leading, spacing: 12) {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                repositoryState
            }
        } else {
            repositoryState
        }
    }

    @ViewBuilder
    private var repositoryState: some View {
        if viewModel.githubIsLoadingRepositoryChanges {
            ProgressView("Loading repository changes…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let snapshot {
            if snapshot.totalChangeCount == 0 {
                cleanRepositoryState(snapshot)
            } else {
                changesContent(snapshot)
            }
        } else {
            ContentUnavailableView("No repository data", systemImage: "arrow.triangle.branch", description: Text("Refresh to inspect changes for this Pi Agent session."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image("github")
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(AppTheme.mutedText)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(repositoryDisplayName)
                    .font(.title3.weight(.bold))
                    .fontWidth(.expanded)
                    .lineLimit(1)
                if let branchName = snapshot?.branchName {
                    Label(branchName, systemImage: "arrow.trianglehead.branch")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.mutedText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                Button {
                    viewModel.prepareRepoChangesForSelectedPiAgentSession()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .help("Refresh changes")
                .accessibilityLabel("Refresh changes")

                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .help("Close repo changes")
                .accessibilityLabel("Close repo changes")
            }
        }
    }

    private var repositoryDisplayName: String {
        viewModel.piAgentSessionStore.selectedSession?.projectName ?? viewModel.selectedDiscoveredProject?.name ?? "Pi Agent repository"
    }

    private func cleanRepositoryState(_ snapshot: RepositoryChangesSnapshot) -> some View {
        VStack(spacing: 16) {
            Image(systemName: snapshot.canPush ? "arrow.up.circle" : "checkmark.circle")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(snapshot.canPush ? Color.accentColor : AppTheme.mutedText)
            Text(snapshot.canPush ? "Ready to push" : "No local changes")
                .font(.title2.weight(.bold))
            Text(snapshot.canPush ? "Your branch is ahead of \(snapshot.upstreamBranch ?? "the upstream branch")." : "The selected Pi Agent repository is clean.")
                .font(.callout)
                .foregroundStyle(AppTheme.mutedText)
                .multilineTextAlignment(.center)
            if snapshot.canPush {
                Button(viewModel.githubIsPushing ? "Pushing…" : "Push \(snapshot.aheadCount) commit\(snapshot.aheadCount == 1 ? "" : "s")") {
                    viewModel.pushCurrentBranch()
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.githubIsPushing)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func changesContent(_ snapshot: RepositoryChangesSnapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Button("Include All") { viewModel.stageAllChanges() }
                        .disabled(!snapshot.canStageAll)
                    Button("Exclude All") { viewModel.unstageAllChanges() }
                        .disabled(!snapshot.canUnstageAll)
                    Spacer()
                    Text("\(snapshot.staged.count)/\(snapshot.totalChangeCount) included")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.mutedText)
                }

                TextField("Filter files", text: $filterText)
                    .textFieldStyle(.roundedBorder)

                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(items) { item in
                        PiAgentGitChangeRow(
                            item: item,
                            onToggleIncluded: { toggleIncluded(item) }
                        )
                    }
                }

                Divider()
                    .padding(.top, 8)

                commitBox(snapshot)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func branchSummary(_ snapshot: RepositoryChangesSnapshot) -> some View {
        HStack(spacing: 7) {
            gitTag(snapshot.branchName, systemImage: "arrow.trianglehead.branch", color: .blue)
            if let upstream = snapshot.upstreamBranch {
                gitTag(upstream, systemImage: "arrow.up.right", color: .gray)
            }
            if snapshot.aheadCount > 0 {
                gitTag("\(snapshot.aheadCount)", systemImage: "arrow.up", color: .green)
            }
            if snapshot.behindCount > 0 {
                gitTag("\(snapshot.behindCount)", systemImage: "arrow.down", color: .orange)
            }
            Spacer()
        }
    }

    private func gitTag(_ text: String, systemImage: String, color: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .fontWidth(.expanded)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .foregroundStyle(color)
    }

    private func commitBox(_ snapshot: RepositoryChangesSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Commit")
                .font(.headline)
            Text("Write a title, optionally add a description, then commit the included files.")
                .font(.footnote)
                .foregroundStyle(AppTheme.mutedText)

            TextField("Commit title", text: $viewModel.githubCommitMessage)
                .textFieldStyle(.roundedBorder)

            Text("Description")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.mutedText)
            TextEditor(text: $viewModel.githubCommitDescription)
                .font(.body)
                .frame(minHeight: 72, maxHeight: 100)
                .padding(6)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(AppTheme.contentStroke, lineWidth: 1))
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(AppTheme.contentFill))

            HStack {
                Button(viewModel.githubIsCommitting ? "Committing…" : "Commit \(snapshot.staged.count) file\(snapshot.staged.count == 1 ? "" : "s")") { viewModel.commitChanges() }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.githubIsCommitting || !snapshot.canCommit || viewModel.githubCommitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if snapshot.canPush {
                    Button(viewModel.githubIsPushing ? "Pushing…" : "Push \(snapshot.aheadCount)") { viewModel.pushCurrentBranch() }
                        .disabled(viewModel.githubIsPushing)
                }
                Spacer()
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(AppTheme.contentSubtleFill.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(AppTheme.contentStroke, lineWidth: 1))
    }

    private func toggleIncluded(_ item: PiAgentGitChangeListItem) {
        if item.isIncluded {
            viewModel.unstage(item.path)
        } else {
            viewModel.stage(item.path)
        }
    }
}

private struct PiAgentGitChangeListItem: Identifiable, Hashable {
    let path: String
    let staged: RepositoryFileChange?
    let unstaged: RepositoryFileChange?
    let untracked: RepositoryFileChange?
    let conflicted: RepositoryFileChange?

    var id: String { path }
    var isIncluded: Bool { staged != nil }
    var badgeText: String {
        if conflicted != nil { return "Conflict" }
        if untracked != nil { return "Added" }
        if staged != nil && unstaged != nil { return "Mixed" }
        let change = staged ?? unstaged
        switch change?.indexStatus == " " ? change?.worktreeStatus : change?.indexStatus {
        case "A": return "Added"
        case "D": return "Deleted"
        case "R": return "Renamed"
        case "M": return "Modified"
        default: return change?.statusSummary.trimmingCharacters(in: .whitespaces) ?? "Changed"
        }
    }
    var badgeColor: Color {
        switch badgeText {
        case "Added": return .green
        case "Deleted": return .red
        case "Renamed": return .purple
        case "Conflict": return .orange
        default: return .blue
        }
    }

    static func items(from snapshot: RepositoryChangesSnapshot) -> [PiAgentGitChangeListItem] {
        let paths = Set(snapshot.staged.map(\.path) + snapshot.unstaged.map(\.path) + snapshot.untracked.map(\.path) + snapshot.conflicted.map(\.path))
        return paths.sorted().map { path in
            PiAgentGitChangeListItem(
                path: path,
                staged: snapshot.staged.first(where: { $0.path == path }),
                unstaged: snapshot.unstaged.first(where: { $0.path == path }),
                untracked: snapshot.untracked.first(where: { $0.path == path }),
                conflicted: snapshot.conflicted.first(where: { $0.path == path })
            )
        }
    }
}

private struct PiAgentGitChangeRow: View {
    let item: PiAgentGitChangeListItem
    let onToggleIncluded: () -> Void

    var body: some View {
        Button(action: onToggleIncluded) {
            HStack(spacing: 9) {
                Image(systemName: item.isIncluded ? "checkmark.square.fill" : "square")
                    .foregroundStyle(item.isIncluded ? Color.accentColor : AppTheme.mutedText)
                Image(systemName: "doc.text")
                    .foregroundStyle(AppTheme.mutedText)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.primary)
                    Text(item.badgeText)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(item.badgeColor)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(item.isIncluded ? Color.accentColor.opacity(0.10) : Color.clear))
        }
        .buttonStyle(.plain)
        .help(item.isIncluded ? "Exclude from commit" : "Include in commit")
    }
}

struct PiAgentInspectorPanel: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var store: PiAgentSessionStore
    @State private var composerText = ""
    @State private var inputMode: PiAgentInputMode = .steer
    @State private var composerImages: [PiAgentImageAttachment] = []
    @State private var composerFiles: [PiAgentFileAttachment] = []
    @State private var composerAttachmentError: String?
    @State private var isNativeSubagentRunSheetPresented = false
    @State private var nativeSubagentAgentName = ""
    @State private var nativeSubagentTask = ""
    @State private var nativeSubagentUseWorktreeIsolation = false
    @State private var nativeSubagentAllowDirectProjectWrites = false
    @State private var nativeSubagentExpectedOutcome: PiSubagentExpectedOutcome = .reportOnly
    @State private var nativeSubagentRequestedOutputPath = ""
    @State private var nativeSubagentAllowOverwrite = false
    @State private var nativeSubagentReadFirstPaths = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(store.selectedSession?.displayTitle ?? "No active session")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    viewModel.isPiAgentInspectorPresented = false
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .buttonStyle(.plain)
            }

            if let session = store.selectedSession {
                HStack(spacing: 8) {
                    AppLabelTag(text: session.status.rawValue, color: session.status.isActive ? .green : .blue)
                    if let issue = session.issueNumber {
                        AppLabelTag(text: "#\(issue)", color: .purple)
                    }
                    Spacer()
                    Button("Open Full") {
                        viewModel.openPiAgentScreen()
                    }
                    Button("Stop") {
                        viewModel.stopSelectedPiAgentSession()
                    }
                    .keyboardShortcut(.escape, modifiers: [])
                    .disabled(!viewModel.isPiAgentSessionRunning(session.id))
                }

                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(store.selectedTranscript.filter(isCompactTranscriptEntry).suffix(80)) { entry in
                                PiAgentCompactTranscriptCard(entry: entry)
                                    .id(entry.id)
                            }
                        }
                    }
                    .onChange(of: store.selectedTranscript.count) { _, _ in
                        if let last = store.selectedTranscript.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                .frame(maxHeight: .infinity)

                let isRunning = viewModel.isPiAgentSessionRunning(session.id)
                let isCompacting = session.isCompacting
                PiAgentComposerBox(
                    text: $composerText,
                    images: $composerImages,
                    files: $composerFiles,
                    attachmentError: $composerAttachmentError,
                    inputMode: $inputMode,
                    isRunning: isRunning,
                    isDisabled: isCompacting,
                    placeholder: isCompacting ? "Compacting context…" : (isRunning ? "Steer the current turn…" : "Message Pi…"),
                    canSend: !isCompacting && (!composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !composerImages.isEmpty || !composerFiles.isEmpty),
                    path: session.worktreePath ?? session.projectPath,
                    onFiles: { urls in
                        let attachments = urls.compactMap { PiAgentFileAttachment(url: $0) }
                        for attachment in attachments where !composerFiles.contains(where: { $0.url == attachment.url }) {
                            composerFiles.append(attachment)
                        }
                    },
                    subagentNames: runnableSubagentNames(for: session),
                    subagentsEnabled: session.subagentsEnabled,
                    subagentsEnabledForNewSessions: viewModel.areSubagentsEnabledForNewSessions,
                    onSetSessionSubagentsEnabled: viewModel.setSubagentsEnabledForSelectedSession,
                    onSetNewSessionSubagentsEnabled: viewModel.setSubagentsEnabledForNewSessions,
                    onSelectSubagent: presentNativeSubagentRun,
                    footer: AnyView(PiAgentComposerFooterBar(
                        session: session,
                        viewModel: viewModel,
                        supportedThinkingLevels: ["off", "minimal", "low", "medium", "high", "xhigh"]
                    )),
                    metricsFooter: AnyView(PiAgentRuntimeFooter(session: session)),
                    onSend: {
                        let message = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !message.isEmpty || !composerImages.isEmpty || !composerFiles.isEmpty else { return }
                        guard !isCompacting else { return }
                        let filePayload = composerFiles.compactMap { file -> String? in
                            guard let content = try? String(contentsOf: file.url, encoding: .utf8) else { return nil }
                            return "<file name=\"\(file.url.path)\">\n\(content)\n</file>"
                        }.joined(separator: "\n")
                        if !composerFiles.isEmpty && filePayload.isEmpty {
                            composerAttachmentError = "Only images and UTF-8 text files are supported."
                            return
                        }
                        let combined = [message, filePayload].filter { !$0.isEmpty }.joined(separator: "\n\n")
                        viewModel.sendPiAgentMessage(combined, mode: isRunning ? .steer : .prompt, images: composerImages)
                        composerText = ""
                        composerImages = []
                        composerFiles = []
                        composerAttachmentError = nil
                    },
                    onStop: { viewModel.stopSelectedPiAgentSession() },
                    onClear: {
                        composerText = ""
                        composerImages = []
                        composerFiles = []
                        composerAttachmentError = nil
                    }
                )
            } else {
                Text("Start a project session from the sidebar project card, the Agent screen, or a GitHub issue.")
                    .foregroundStyle(AppTheme.mutedText)
                Button("Open Agent Screen") {
                    viewModel.openPiAgentScreen()
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $isNativeSubagentRunSheetPresented) {
            PiNativeSubagentRunSheet(
                agentNames: store.selectedSession.map { runnableSubagentNames(for: $0) } ?? [],
                agentInfos: nativeSubagentSheetInfos,
                selectedAgentName: $nativeSubagentAgentName,
                task: $nativeSubagentTask,
                useWorktreeIsolation: $nativeSubagentUseWorktreeIsolation,
                allowDirectProjectWrites: $nativeSubagentAllowDirectProjectWrites,
                expectedOutcome: $nativeSubagentExpectedOutcome,
                requestedOutputPath: $nativeSubagentRequestedOutputPath,
                allowOverwrite: $nativeSubagentAllowOverwrite,
                readFirstPathsText: $nativeSubagentReadFirstPaths,
                projectRootPath: store.selectedSession.map { $0.worktreePath ?? $0.projectPath },
                onCancel: { isNativeSubagentRunSheetPresented = false },
                onRun: { agentName, task, useWorktreeIsolation, allowDirectProjectWrites, expectedOutcome, requestedOutputPath, allowOverwrite, readFirstPaths in
                    viewModel.runNativeSubagent(agentName: agentName, task: task, useWorktreeIsolation: useWorktreeIsolation, allowDirectProjectWrites: allowDirectProjectWrites, expectedOutcome: expectedOutcome, requestedOutputPath: requestedOutputPath, allowOverwrite: allowOverwrite, readFirstPaths: readFirstPaths)
                    if composerText.trimmingCharacters(in: .whitespacesAndNewlines) == task.trimmingCharacters(in: .whitespacesAndNewlines) {
                        composerText = ""
                    }
                    isNativeSubagentRunSheetPresented = false
                }
            )
        }
    }

    private func runnableSubagentNames(for session: PiAgentSessionRecord) -> [String] {
        guard session.subagentsEnabled else { return [] }
        let snapshot = viewModel.startupSnapshot(forProjectPath: session.projectPath)
        return snapshot.effectiveAgents
            .filter { $0.resolved.disabled != true }
            .map(\.name)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var nativeSubagentSheetInfos: [String: PiNativeSubagentRunSheet.AgentInfo] {
        guard let session = store.selectedSession else { return [:] }
        let snapshot = viewModel.startupSnapshot(forProjectPath: session.projectPath)
        return Dictionary(uniqueKeysWithValues: snapshot.effectiveAgents.map { agent in
            (agent.name, PiNativeSubagentRunSheet.AgentInfo(agent: agent))
        })
    }

    private func presentNativeSubagentRun(for agentName: String) {
        nativeSubagentAgentName = agentName
        nativeSubagentTask = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        isNativeSubagentRunSheetPresented = true
    }

    private func isCompactTranscriptEntry(_ entry: PiAgentTranscriptEntry) -> Bool {
        switch entry.role {
        case .raw:
            return false
        case .status:
            return entry.title == "Compaction" || entry.title == "Retry" || entry.title == "Stopped"
        case .tool:
            return !(entry.title == "Tool Call" && entry.text.localizedCaseInsensitiveContains("preparing tool call"))
        case .stderr:
            return !entry.text.localizedCaseInsensitiveContains("ready for input") && !entry.text.contains(";notify;Pi;")
        default:
            return true
        }
    }
}

private struct PiAgentSubagentSummary: Hashable {
    struct Agent: Identifiable, Hashable {
        let id = UUID()
        var name: String
        var status: String
        var task: String?
        var toolCount: Int?
        var tokens: Int?
        var durationMs: Int?
        var context: String?
        var outputPath: String?
        var sessionFile: String?
        var exitCode: Int?
    }

    var mode: String
    var total: Int
    var completed: Int
    var running: Int
    var failed: Int
    var agents: [Agent]

    init?(entry: PiAgentTranscriptEntry) {
        guard entry.role == .tool,
              entry.title.localizedCaseInsensitiveContains("subagent") || entry.text.localizedCaseInsensitiveContains("subagent")
        else { return nil }

        var root: [String: Any] = [:]
        if let raw = entry.rawJSON,
           let data = raw.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = object
        }
        let result = root["result"] as? [String: Any]
        let partial = root["partialResult"] as? [String: Any]
        let details = (result?["details"] as? [String: Any]) ?? (partial?["details"] as? [String: Any]) ?? [:]
        let results = details["results"] as? [[String: Any]] ?? []
        let progress = details["progress"] as? [[String: Any]] ?? []

        mode = (details["mode"] as? String) ?? "subagent"
        let parsedAgents = Self.parseAgents(results: results, progress: progress)
        agents = parsedAgents
        total = max(parsedAgents.count, details["total"] as? Int ?? 0)
        completed = parsedAgents.filter { $0.status == "completed" || $0.status == "ok" }.count
        running = parsedAgents.filter { $0.status == "running" || $0.status == "active" || $0.status == "starting" }.count
        failed = parsedAgents.filter { $0.status == "failed" || (($0.exitCode ?? 0) != 0 && $0.status != "running") }.count

        if root.isEmpty && parsedAgents.isEmpty {
            agents = [Agent(name: "subagent", status: "running", task: entry.text, toolCount: nil, tokens: nil, durationMs: nil, context: nil, outputPath: nil, sessionFile: nil, exitCode: nil)]
            total = 1
            completed = 0
            running = 1
            failed = 0
        }
    }

    private static func parseAgents(results: [[String: Any]], progress: [[String: Any]]) -> [Agent] {
        let resultAgents = results.enumerated().map { index, result in
            makeAgent(index: index, result: result, progress: result["progress"] as? [String: Any] ?? result["progressSummary"] as? [String: Any])
        }
        if !resultAgents.isEmpty { return resultAgents }
        return progress.enumerated().map { index, progress in
            makeAgent(index: index, result: [:], progress: progress)
        }
    }

    private static func makeAgent(index: Int, result: [String: Any], progress: [String: Any]?) -> Agent {
        let status = (progress?["status"] as? String)
            ?? ((result["exitCode"] as? Int) == 0 ? "completed" : result["exitCode"] == nil ? "running" : "failed")
        let artifacts = result["artifactPaths"] as? [String: Any]
        return Agent(
            name: result["agent"] as? String ?? progress?["agent"] as? String ?? "Agent \(index + 1)",
            status: status,
            task: result["task"] as? String ?? progress?["task"] as? String,
            toolCount: progress?["toolCount"] as? Int ?? result["toolCount"] as? Int,
            tokens: progress?["tokens"] as? Int ?? result["tokens"] as? Int,
            durationMs: progress?["durationMs"] as? Int ?? result["durationMs"] as? Int,
            context: result["context"] as? String ?? progress?["context"] as? String ?? result["contextMode"] as? String ?? progress?["contextMode"] as? String,
            outputPath: artifacts?["outputPath"] as? String ?? result["output"] as? String ?? progress?["outputPath"] as? String,
            sessionFile: result["sessionFile"] as? String ?? progress?["sessionFile"] as? String,
            exitCode: result["exitCode"] as? Int
        )
    }
}

private struct PiAgentSubagentTranscriptView: View {
    let summary: PiAgentSubagentSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Label("Subagent run", systemImage: "person.2.wave.2")
                    .font(.headline)
                    .foregroundStyle(.cyan)
                Text(title)
                    .font(.headline.weight(.semibold))
                Spacer()
                if summary.running > 0 {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            HStack(spacing: 8) {
                metric("\(summary.completed)/\(summary.total) done", color: .green)
                if summary.running > 0 { metric("\(summary.running) running", color: .orange) }
                if summary.failed > 0 { metric("\(summary.failed) failed", color: .red) }
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(summary.agents) { agent in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: icon(for: agent.status))
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(color(for: agent.status))
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(agent.name)
                                    .font(.callout.weight(.semibold))
                                Text(agentMeta(agent))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(AppTheme.mutedText)
                            }
                            if let output = agent.outputPath ?? agent.sessionFile {
                                Text(output)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(AppTheme.mutedText)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                            } else if let task = agent.task, !task.isEmpty {
                                Text(task)
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.mutedText)
                                    .lineLimit(2)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AppTheme.contentSubtleFill.opacity(0.65)))
                }
            }
        }
    }

    private var title: String {
        let count = summary.total == 1 ? "1 agent" : "\(summary.total) agents"
        return "\(summary.mode) · \(count)"
    }

    private func metric(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule(style: .continuous).fill(color.opacity(0.12)))
            .foregroundStyle(color)
    }

    private func agentMeta(_ agent: PiAgentSubagentSummary.Agent) -> String {
        [
            agent.context.map { "[\($0)]" },
            agent.toolCount.map { "\($0) tools" },
            agent.tokens.map { "\(formatTokens($0)) token" },
            agent.durationMs.map { formatDuration($0) }
        ].compactMap { $0 }.joined(separator: " · ")
    }

    private func icon(for status: String) -> String {
        switch status {
        case "completed", "ok": return "checkmark"
        case "failed": return "xmark"
        case "paused", "needs_attention": return "exclamationmark"
        default: return "ellipsis"
        }
    }

    private func color(for status: String) -> Color {
        switch status {
        case "completed", "ok": return .green
        case "failed": return .red
        case "paused", "needs_attention": return .orange
        default: return .cyan
        }
    }

    private func formatTokens(_ tokens: Int) -> String {
        tokens >= 1000 ? "\(tokens / 1000)k" : "\(tokens)"
    }

    private func formatDuration(_ ms: Int) -> String {
        let seconds = ms / 1000
        if seconds >= 60 { return "\(seconds / 60)m\(seconds % 60)s" }
        return "\(seconds)s"
    }
}

private struct PiAgentCompactTranscriptCard: View {
    let entry: PiAgentTranscriptEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                Text(entry.title)
                    .font(.caption.weight(.semibold))
                    .fontWidth(.expanded)
                Spacer()
            }
            Text(entry.text)
                .font(entry.role == .tool || entry.role == .stderr || entry.role == .raw ? .caption.monospaced() : .callout)
                .foregroundStyle(entry.role == .thinking ? AppTheme.mutedText : .primary)
                .lineLimit(entry.role == .assistant ? 8 : 5)
                .textSelection(.enabled)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppTheme.contentFill)
                .stroke(AppTheme.contentStroke, lineWidth: 1)
        )
    }

    private var icon: String {
        switch entry.role {
        case .user: return "person.crop.circle"
        case .assistant: return "sparkles"
        case .thinking: return "brain.head.profile"
        case .tool: return "hammer"
        case .status: return "info.circle"
        case .error: return "exclamationmark.triangle"
        case .stderr: return "terminal"
        case .raw: return "curlybraces"
        }
    }

    private var color: Color {
        switch entry.role {
        case .user: return .blue
        case .assistant: return .purple
        case .thinking: return .indigo
        case .tool: return .orange
        case .status: return .secondary
        case .error: return .red
        case .stderr: return .pink
        case .raw: return .secondary
        }
    }
}
