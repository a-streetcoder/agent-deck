import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers


let piAgentLeakedToolNames: Set<String> = ["bash", "read", "edit", "write", "find", "grep", "subagent", "web_search", "fetch_content", "get_search_content"]

@MainActor
enum PiAgentRPCEventRenderCache {
    private static var cache: [String: PiAgentRPCEvent] = [:]
    private static var order: [String] = []
    private static let limit = 512

    static func event(from rawJSON: String?) -> PiAgentRPCEvent? {
        guard let rawJSON else { return nil }
        let key = cacheKey(for: rawJSON)
        if let cached = cache[key] { return cached }
        guard let data = rawJSON.data(using: .utf8),
              let event = try? JSONDecoder().decode(PiAgentRPCEvent.self, from: data) else {
            return nil
        }
        cache[key] = event
        order.append(key)
        if order.count > limit {
            let overflow = order.count - limit
            for oldKey in order.prefix(overflow) {
                cache[oldKey] = nil
            }
            order.removeFirst(overflow)
        }
        return event
    }

    private static func cacheKey(for rawJSON: String) -> String {
        var hasher = Hasher()
        hasher.combine(rawJSON)
        return "\(rawJSON.count):\(hasher.finalize())"
    }
}

struct PiAgentTranscriptStack<Content: View>: View {
    let alignment: HorizontalAlignment
    let spacing: CGFloat?
    @ViewBuilder let content: () -> Content

    init(alignment: HorizontalAlignment = .leading, spacing: CGFloat? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.alignment = alignment
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        VStack(alignment: alignment, spacing: spacing) {
            content()
        }
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

private enum PiAgentSessionSortOrder: String {
    case created
    case updated

    var systemImage: String {
        switch self {
        case .created: return "calendar"
        case .updated: return "clock"
        }
    }

    var help: String {
        switch self {
        case .created: return "Currently sorted by creation time. Switch to last edited."
        case .updated: return "Currently sorted by last edit. Switch to creation time."
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .created: return "Sort sessions by creation time"
        case .updated: return "Sort sessions by last edit"
        }
    }

    mutating func toggle() {
        self = self == .created ? .updated : .created
    }
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
    @State private var transcriptIsPinnedToBottom = true
    @State private var transcriptAutoScrollSuppressed = false
    @State private var showArchivedPreCompactionTranscript = false
    @State private var cachedVisibleSessions: [PiAgentSessionRecord] = []
    @State private var hasBuiltVisibleSessions = false
    @AppStorage("piAgentSessionSortOrder") private var sessionSortOrder: PiAgentSessionSortOrder = .created
    @State private var isUIRequestSheetPresented = false
    @State private var frozenRuntimeFooterSession: PiAgentSessionRecord?

    var body: some View {
        HStack(spacing: 0) {
            HSplitView {
                sessionsColumn
                    .frame(minWidth: 190, idealWidth: 250, maxWidth: 360)

                activeSessionColumn
                    .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            syncVisibleSessionSelection()
            syncMultiSelectionToSelectedSession()
            syncRuntimeFooterSnapshot()
            viewModel.acknowledgeVisibleSelectedPiAgentSession()
            syncSelectedSessionTitleDraft()
            loadComposerDraft(for: store.selectedSession?.id)
            isUIRequestSheetPresented = store.selectedUIRequest != nil
            rebuildVisibleSessions()
            scheduleTranscriptCacheUpdate()
        }
        .onReceive(store.$sessions) { _ in rebuildVisibleSessions() }
        .onChange(of: sessionSearchText) { _, _ in rebuildVisibleSessions() }
        .onChange(of: viewModel.showPiAgentAttentionOnly) { _, _ in rebuildVisibleSessions() }
        .onChange(of: sessionSortOrder) { _, _ in rebuildVisibleSessions() }
        .onDisappear {
            saveComposerDraft(for: store.selectedSession?.id)
        }
        .sheet(isPresented: uiRequestSheetBinding) {
            if let request = store.selectedUIRequest {
                PiAgentUIRequestSheet(
                    request: request,
                    onSubmitValue: { value in viewModel.respondToPiAgentUIRequest(request, value: value) },
                    onSubmitFreeform: { sentinel, value in viewModel.respondToPiAgentFreeformUIRequest(request, sentinel: sentinel, value: value) },
                    onConfirm: { confirmed in viewModel.confirmPiAgentUIRequest(request, confirmed: confirmed) },
                    onCancel: { viewModel.cancelPiAgentUIRequest(request) }
                )
            }
        }
        .onChange(of: store.selectedUIRequest?.id) { _, newID in
            isUIRequestSheetPresented = newID != nil
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
            transcriptIsPinnedToBottom = true
            transcriptAutoScrollSuppressed = false
            showArchivedPreCompactionTranscript = false
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
        .onChange(of: store.selectedTranscriptRevision) { _, _ in
            Task { @MainActor in
                await Task.yield()
                scheduleTranscriptCacheUpdate()
            }
        }
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
        let filtered = query.isEmpty ? source : source.filter { sessionMatchesSearch($0, query: query) }
        return sortedSessions(filtered)
    }

    private var visibleSessionIDs: [UUID] {
        visibleSessions.map(\.id)
    }

    private var deleteSessionsAlertTitle: String {
        pendingDeleteSessionIDs.count == 1 ? "Delete Pi Agent session?" : "Delete \(pendingDeleteSessionIDs.count) Pi Agent sessions?"
    }

    private var deleteSessionsAlertMessage: String {
        pendingDeleteSessionIDs.count == 1
            ? "This removes the selected Pi Agent session and its local transcript from \(AppBrand.displayName)."
            : "This removes the selected Pi Agent sessions and their local transcripts from \(AppBrand.displayName)."
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

    private var uiRequestSheetBinding: Binding<Bool> {
        Binding(
            get: { isUIRequestSheetPresented && store.selectedUIRequest != nil },
            set: { isPresented in
                if isPresented {
                    isUIRequestSheetPresented = true
                } else {
                    isUIRequestSheetPresented = false
                }
            }
        )
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
                if selectedSessionIDs.count > 1 {
                    Button(role: .destructive) {
                        requestDeleteSessions(selectedSessionIDs)
                    } label: {
                        Image(systemName: "trash.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.red)
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(Color.red.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .help("Delete selected sessions")
                    .accessibilityLabel("Delete selected sessions")
                }
                Button {
                    withAnimation(.snappy(duration: 0.18)) {
                        sessionSortOrder.toggle()
                    }
                } label: {
                    Image(systemName: sessionSortOrder.systemImage)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppTheme.brandAccent)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(AppTheme.brandAccent.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .help(sessionSortOrder.help)
                .accessibilityLabel(sessionSortOrder.accessibilityLabel)
                PiAgentAddSessionButton {
                    viewModel.createPiAgentDraftForSelectedProject()
                }
                .help(viewModel.selectedDiscoveredProject == nil ? "New Pi Agent session in \(viewModel.configuredProjectsRootPath)" : "New Pi Agent session")
            }
            .padding(.vertical, 18)
            .padding(.horizontal, 18)

            if scopedSessions.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Image("pi")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(AppTheme.mutedText)
                        .frame(width: 24, height: 24)
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
                        .padding(.horizontal, 18)

                    if visibleSessions.isEmpty {
                        ContentUnavailableView("No sessions found", systemImage: "magnifyingglass", description: Text("Try another search."))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List(selection: $selectedSessionIDs) {
                            ForEach(visibleSessions) { session in
                                sessionListRow(session)
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                        .animation(.snappy(duration: 0.24), value: visibleSessionIDs)
                    }
                }
            }
        }
        .background(Color.clear)
    }

    @ViewBuilder
    private func sessionListRow(_ session: PiAgentSessionRecord) -> some View {
        PiAgentSessionRow(
            session: session,
            project: viewModel.discoveredProjects.first(where: { $0.path == session.projectPath }),
            isSelected: selectedSessionIDs.contains(session.id),
            isRunning: session.status.isActive,
            isRenaming: renamingSessionID == session.id,
            isGeneratingTitle: viewModel.piAgentTitleGeneratingSessionIDs.contains(session.id),
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
        .tag(session.id)
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        .listRowSeparator(.automatic)
        .listRowBackground(activeSessionListRowBackground(isActive: session.status.isActive))
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                viewModel.togglePiAgentSessionPinned(session.id)
            } label: {
                Label(session.isPinned ? "Unpin" : "Pin", systemImage: session.isPinned ? "pin.slash" : "pin")
            }
            .tint(AppTheme.brandAccent)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                requestDeleteSessions(selectedSessionIDs.contains(session.id) && selectedSessionIDs.count > 1 ? selectedSessionIDs : [session.id])
            } label: {
                Label(selectedSessionIDs.contains(session.id) && selectedSessionIDs.count > 1 ? "Delete Selected" : "Delete", systemImage: "trash")
            }
        }
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

    @ViewBuilder
    private func activeSessionListRowBackground(isActive: Bool) -> some View {
        if isActive {
            LinearGradient(
                colors: [
                    AppTheme.brandAccentBright.opacity(0.10),
                    AppTheme.brandAccent.opacity(0.045),
                    AppTheme.brandAccentDeep.opacity(0.08)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            Color.clear
        }
    }

    private var activeSessionColumn: some View {
        VStack(spacing: 0) {
            transcript
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(18)

            Divider()

            VStack(spacing: 12) {
                if let request = store.selectedUIRequest {
                    PiAgentUIRequestInlineNotice(
                        request: request,
                        onRespond: { isUIRequestSheetPresented = true },
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
                PiAgentTranscriptStack(alignment: .leading, spacing: 12) {
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

                    let timelineItems = visibleTranscriptTimelineItems
                    if let archive = preCompactionArchiveNotice {
                        preCompactionArchiveCard(archive)
                    }
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
                                    projectPath: store.selectedSession.map { $0.worktreePath ?? $0.projectPath },
                                    planEvents: planEvents(for: thread, in: timelineItems),
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
            .background {
                PiAgentScrollPositionObserver(
                    onPinnedToBottomChange: { isPinnedToBottom in
                        transcriptIsPinnedToBottom = isPinnedToBottom
                    },
                    onUserScrollIntent: {
                        transcriptAutoScrollSuppressed = true
                    },
                    onUserScrolledAwayFromBottom: {
                        transcriptAutoScrollSuppressed = true
                    }
                )
            }
            .onChange(of: transcriptCache.renderRevision) { _, _ in
                guard transcriptIsPinnedToBottom, !transcriptAutoScrollSuppressed else { return }
                Task { @MainActor in
                    await Task.yield()
                    scrollToLatestThread(proxy: proxy)
                }
            }
            .onChange(of: transcriptCache.streamingRevision) { _, _ in
                guard transcriptIsPinnedToBottom, !transcriptAutoScrollSuppressed else { return }
                Task { @MainActor in
                    await Task.yield()
                    throttleStreamingScroll(proxy: proxy)
                }
            }
            .onChange(of: selectedSessionProcessingMessage) { _, message in
                guard message != nil, transcriptIsPinnedToBottom, !transcriptAutoScrollSuppressed else { return }
                scrollToProcessingIndicator(proxy: proxy)
            }
            .onChange(of: transcriptBottomScrollRequest) { _, _ in
                Task { @MainActor in
                    await Task.yield()
                    scrollToRequestedBottom(proxy: proxy)
                }
            }
        }
    }

    private var transcriptTimelineItems: [PiAgentTranscriptTimelineItem] {
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

    private var visibleTranscriptTimelineItems: [PiAgentTranscriptTimelineItem] {
        let items = transcriptTimelineItems
        guard !showArchivedPreCompactionTranscript,
              let archive = preCompactionArchiveRange(in: items) else { return items }
        return Array(items[archive.visibleStartIndex...])
    }

    private var preCompactionArchiveNotice: (hiddenCount: Int, compactedAt: Date)? {
        let items = transcriptTimelineItems
        guard let archive = preCompactionArchiveRange(in: items), archive.visibleStartIndex > 0 else { return nil }
        return (archive.visibleStartIndex, archive.compactedAt)
    }

    private func preCompactionArchiveRange(in items: [PiAgentTranscriptTimelineItem]) -> (visibleStartIndex: Int, compactedAt: Date)? {
        guard let index = items.indices.last(where: { index in
            guard case let .thread(thread) = items[index].kind else { return false }
            return thread.statuses.contains(where: isCompletedCompactionEntry)
        }) else { return nil }
        return (index, items[index].timestamp)
    }

    private func isCompletedCompactionEntry(_ entry: PiAgentTranscriptEntry) -> Bool {
        guard entry.title == "Compaction" else { return false }
        let text = entry.text.localizedLowercase
        return (text.contains("context compacted") || text.contains("compaction complete") || text.contains("compaction finished"))
            && !text.contains("nothing to compact")
            && !text.contains("compacting")
    }

    @ViewBuilder
    private func preCompactionArchiveCard(_ archive: (hiddenCount: Int, compactedAt: Date)) -> some View {
        HStack(spacing: 10) {
            Image(systemName: showArchivedPreCompactionTranscript ? "tray.and.arrow.up" : "archivebox")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.mutedText)
            Text(showArchivedPreCompactionTranscript ? "Showing pre-compaction transcript" : "Pre-compaction transcript hidden")
                .font(.caption.weight(.semibold))
            Text("\(archive.hiddenCount) earlier item\(archive.hiddenCount == 1 ? "" : "s") before \(archive.compactedAt.formatted(date: .omitted, time: .shortened))")
                .font(.caption)
                .foregroundStyle(AppTheme.mutedText)
            Spacer(minLength: 0)
            Button(showArchivedPreCompactionTranscript ? "Hide" : "Load Earlier") {
                withAnimation(.snappy(duration: 0.18)) {
                    showArchivedPreCompactionTranscript.toggle()
                }
            }
            .buttonStyle(.borderless)
            .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AppTheme.contentSubtleFill.opacity(0.8)).stroke(AppTheme.contentStroke, lineWidth: 1))
    }

    private func planEvents(for thread: PiAgentTranscriptThread, in timelineItems: [PiAgentTranscriptTimelineItem]) -> [PiSessionPlanEventRecord] {
        guard viewModel.appSettings.piAgentTranscriptVisibility.showPlans,
              let sessionID = store.selectedSession?.id else { return [] }
        let threadStart = thread.timelineTimestamp
        let nextThreadStart = timelineItems.compactMap { item -> Date? in
            guard case let .thread(candidate) = item.kind,
                  candidate.id != thread.id,
                  candidate.timelineTimestamp > threadStart else { return nil }
            return candidate.timelineTimestamp
        }.min() ?? .distantFuture
        return store.sessionPlanEvents(for: sessionID).filter { event in
            event.timestamp >= threadStart && event.timestamp < nextThreadStart
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
        scrollToConversationBottom(proxy: proxy, animated: false, respectSuppression: true)
    }

    private func scrollToProcessingIndicator(proxy: ScrollViewProxy) {
        scrollToConversationBottom(proxy: proxy, animated: false, respectSuppression: true)
    }

    private func requestTranscriptBottomScroll() {
        transcriptBottomScrollRequest &+= 1
    }

    private func scrollToRequestedBottom(proxy: ScrollViewProxy) {
        transcriptIsPinnedToBottom = true
        transcriptAutoScrollSuppressed = false
        scrollToConversationBottom(proxy: proxy, animated: true, respectSuppression: false)
    }

    private func scrollToConversationBottom(proxy: ScrollViewProxy, animated: Bool, respectSuppression: Bool) {
        lastStreamingScrollAt = Date()
        Task { @MainActor in
            await Task.yield()
            guard !respectSuppression || !transcriptAutoScrollSuppressed else { return }
            withTransaction(Transaction(animation: animated ? .easeOut(duration: 0.18) : nil)) {
                proxy.scrollTo("pi-agent-bottom-anchor", anchor: .bottom)
            }
        }
    }

    private func throttleStreamingScroll(proxy: ScrollViewProxy) {
        guard Date().timeIntervalSince(lastStreamingScrollAt) > 0.14 else { return }
        scrollToLatestThread(proxy: proxy)
    }

    @ViewBuilder
    private var composer: some View {
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
        .popover(
            isPresented: Binding(
                get: { hasComposerSuggestions },
                set: { _ in }
            ),
            arrowEdge: .bottom
        ) {
            PiAgentCommandSuggestions(
                commands: slashSuggestions,
                skills: skillSlashSuggestions,
                fileSuggestions: fileSuggestions,
                onSelectFile: insertFileSuggestion,
                onSelectCommand: insertSlashSuggestion
            )
            .padding(6)
        }
        .zIndex(hasComposerSuggestions ? 20 : 0)
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

    private var hasComposerSuggestions: Bool {
        !slashSuggestions.isEmpty || !skillSlashSuggestions.isEmpty || !fileSuggestions.isEmpty
    }

    private var slashSuggestions: [String] {
        guard case let .slash(query) = composerSuggestionTrigger else { return [] }
        guard !query.hasPrefix("skill:") else { return [] }
        let all = Array(Set(viewModel.snapshot.promptTemplates.map(\.invocation) + ["/compact"])).sorted()
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
        let draft = store.composerDraft(for: sessionID)
        composerText = draft.text
        composerImages = draft.images
        composerFiles = draft.files
        composerAttachmentError = nil
    }

    private func saveComposerDraft(for sessionID: UUID?) {
        guard let sessionID else { return }
        store.saveComposerDraft(text: composerText, images: composerImages, files: composerFiles, for: sessionID)
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
            store.clearComposerDraft(for: sentSessionID)
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
                return fileTag(for: url)
            }
            .joined(separator: " ")
    }

    private func attachedFilePayload() -> String? {
        var tags: [String] = []
        for file in composerFiles {
            tags.append(fileTag(for: file.url))
        }
        return tags.joined(separator: "\n")
    }

    private func fileTag(for url: URL) -> String {
        "<file name=\"\(url.path)\"></file>"
    }

    private var runningCount: Int {
        scopedSessions.filter { $0.status.isActive }.count
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
                return runtimeModel.supportedThinkingLevels ?? (runtimeModel.supportsThinking == false ? ["off"] : [])
            }
            if let cached = viewModel.enabledAvailableModels.first(where: { $0.provider == provider && $0.model == modelID }) {
                return cached.supportedThinkingLevels.isEmpty ? (cached.supportsThinking ? [] : ["off"]) : cached.supportedThinkingLevels
            }
        }
        return []
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

    private func sortedSessions(_ sessions: [PiAgentSessionRecord]) -> [PiAgentSessionRecord] {
        sessions.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
            switch sessionSortOrder {
            case .created:
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            case .updated:
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            }
            return lhs.id.uuidString < rhs.id.uuidString
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

private struct PiAgentScrollPositionObserver: NSViewRepresentable {
    let onPinnedToBottomChange: (Bool) -> Void
    let onUserScrollIntent: () -> Void
    let onUserScrolledAwayFromBottom: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onPinnedToBottomChange: onPinnedToBottomChange,
            onUserScrollIntent: onUserScrollIntent,
            onUserScrolledAwayFromBottom: onUserScrolledAwayFromBottom
        )
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            context.coordinator.attach(to: view.enclosingScrollView)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.onPinnedToBottomChange = onPinnedToBottomChange
        context.coordinator.onUserScrollIntent = onUserScrollIntent
        context.coordinator.onUserScrolledAwayFromBottom = onUserScrolledAwayFromBottom
        DispatchQueue.main.async {
            context.coordinator.attach(to: view.enclosingScrollView)
            context.coordinator.reportPinnedState()
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var onPinnedToBottomChange: (Bool) -> Void
        var onUserScrollIntent: () -> Void
        var onUserScrolledAwayFromBottom: () -> Void
        private weak var scrollView: NSScrollView?
        private var lastPinnedState: Bool?
        private nonisolated(unsafe) var scrollWheelMonitor: Any?
        private let bottomTolerance: CGFloat = 56

        init(
            onPinnedToBottomChange: @escaping (Bool) -> Void,
            onUserScrollIntent: @escaping () -> Void,
            onUserScrolledAwayFromBottom: @escaping () -> Void
        ) {
            self.onPinnedToBottomChange = onPinnedToBottomChange
            self.onUserScrollIntent = onUserScrollIntent
            self.onUserScrolledAwayFromBottom = onUserScrolledAwayFromBottom
        }

        deinit {
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
            if let scrollWheelMonitor {
                NSEvent.removeMonitor(scrollWheelMonitor)
            }
        }

        func attach(to newScrollView: NSScrollView?) {
            guard scrollView !== newScrollView else { return }
            if let scrollView {
                NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
            }
            scrollView = newScrollView
            installScrollWheelMonitorIfNeeded()
            newScrollView?.contentView.postsBoundsChangedNotifications = true
            if let contentView = newScrollView?.contentView {
                NotificationCenter.default.addObserver(self, selector: #selector(boundsDidChange), name: NSView.boundsDidChangeNotification, object: contentView)
            }
            reportPinnedState()
        }

        @objc private func boundsDidChange() {
            reportPinnedState()
        }

        func reportPinnedState() {
            publish(computePinnedState())
        }

        private func installScrollWheelMonitorIfNeeded() {
            guard scrollWheelMonitor == nil else { return }
            scrollWheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handleScrollWheel(event)
                return event
            }
        }

        private func handleScrollWheel(_ event: NSEvent) {
            guard let scrollView,
                  event.deltaY != 0 || event.scrollingDeltaY != 0,
                  let window = scrollView.window,
                  event.window === window else { return }

            let location = scrollView.convert(event.locationInWindow, from: nil)
            guard scrollView.bounds.contains(location) else { return }

            onUserScrollIntent()

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.reportPinnedState()
                if !self.computePinnedState() {
                    self.onUserScrolledAwayFromBottom()
                }
            }
        }

        private func computePinnedState() -> Bool {
            guard let scrollView, let documentView = scrollView.documentView else {
                return true
            }

            let visibleMaxY = scrollView.contentView.bounds.maxY
            let documentHeight = documentView.bounds.height
            let distanceFromBottom = max(0, documentHeight - visibleMaxY)
            return distanceFromBottom <= bottomTolerance || documentHeight <= scrollView.contentView.bounds.height + bottomTolerance
        }

        private func publish(_ isPinned: Bool) {
            guard lastPinnedState != isPinned else { return }
            lastPinnedState = isPinned
            DispatchQueue.main.async { [onPinnedToBottomChange] in
                onPinnedToBottomChange(isPinned)
            }
        }
    }
}
