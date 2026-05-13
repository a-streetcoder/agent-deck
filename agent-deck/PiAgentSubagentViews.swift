import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct PiAgentFileAttachment: Identifiable, Hashable {
    let id = UUID()
    let url: URL

    init?(url: URL) {
        guard !url.hasDirectoryPath else { return nil }
        self.url = url
    }
}

struct PiAgentFolderAttachment: Identifiable, Hashable {
    let id = UUID()
    let url: URL

    init?(url: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        self.url = url
    }
}

struct PiSubagentSupervisorRequestCard: View {
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

struct PiNativeSubagentRunCard: View {
    let run: PiSubagentRunRecord
    let onStop: () -> Void
    let onOpenTranscript: () -> Void
    let onReveal: () -> Void
    let onOpenGraph: () -> Void
    @State private var isDetailsPresented = false
    @State private var promptPopover: PromptPopover?
    @State private var displayedStatus: PiSubagentRunStatus?
    @State private var statusLingerTask: Task<Void, Never>?

    private struct PromptPopover: Identifiable {
        let id = UUID()
        var title: String
        var text: String
    }

    var body: some View {
        AppRowCard {
            VStack(alignment: .leading, spacing: 12) {
                header

                taskPreview

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
        .popover(item: $promptPopover, arrowEdge: .bottom) { prompt in
            PiAgentPromptAuditPopover(title: prompt.title, text: prompt.text)
        }
        .onAppear { displayedStatus = run.status }
        .onChange(of: run.status) { oldStatus, newStatus in
            updateDisplayedStatus(from: oldStatus, to: newStatus)
        }
        .onDisappear {
            statusLingerTask?.cancel()
            statusLingerTask = nil
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            PiSubagentActivityGlyph(color: statusColor, isActive: effectiveStatus.isActive)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(run.agentName)
                        .font(.headline)
                    Text(shortRunID)
                        .font(.caption2.monospaced().weight(.medium))
                        .foregroundStyle(AppTheme.mutedText)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule(style: .continuous).fill(AppTheme.contentSubtleFill.opacity(0.72)))
                        .textSelection(.enabled)
                        .help(run.id.uuidString)
                }
                PiSubagentStatusText(status: effectiveStatus, color: statusColor)
            }
            Spacer(minLength: 0)
            actionButtons
        }
    }

    private var shortRunID: String {
        String(run.id.uuidString.prefix(8))
    }

    @ViewBuilder
    private var actionButtons: some View {
        if run.children?.isEmpty == false {
            Button("Graph", action: onOpenGraph)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        Button("System Prompt") {
            promptPopover = .init(
                title: "Final Runtime System Prompt",
                text: promptFileText(path: artifactURL(named: "final-system-prompt.md").path)
            )
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(!canOpenArtifact(named: "final-system-prompt.md"))
        .help("Show final runtime system prompt")
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
                .foregroundStyle(AppTheme.mutedText)

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
                .fill(AppTheme.contentSubtleFill.opacity(0.65))
                .stroke(AppTheme.contentStroke, lineWidth: 1)
        )
        .help(run.task)
    }

    private var detailRows: [(String, String)] {
        var rows: [(String, String)] = [
            ("Subagent ID", run.id.uuidString)
        ]
        if let turnIndex = run.child?.index, turnIndex > 0 {
            rows.append(("Continuation", "Turn \(turnIndex + 1)"))
        }
        if let duration = latestDurationMs {
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
        return rows
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
        !run.artifactDirectory.isEmpty
    }

    private struct CompactMetadataItem: Identifiable {
        let id = UUID()
        let text: String
        let icon: String
    }

    private var compactMetadata: [CompactMetadataItem] {
        var items: [CompactMetadataItem] = []
        if let duration = latestDurationMs {
            items.append(.init(text: formattedDuration(duration), icon: "timer"))
        }
        if let totalTokens {
            items.append(.init(text: compactNumber(totalTokens), icon: "tugriksign.circle"))
        }
        if let toolCount {
            items.append(.init(text: "\(toolCount)", icon: "wrench.and.screwdriver"))
        }
        if let modelName {
            items.append(.init(text: modelName, icon: "cpu"))
        }
        if let thinkingLevel {
            items.append(.init(text: thinkingLevel, icon: "brain.head.profile"))
        }
        return items
    }

    private var latestDurationMs: Int? {
        run.child?.durationMs ?? run.durationMs
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
        URL(fileURLWithPath: run.child?.artifactDirectory ?? run.artifactDirectory).appendingPathComponent(fileName)
    }

    private func canOpenArtifact(named fileName: String) -> Bool {
        FileManager.default.fileExists(atPath: artifactURL(named: fileName).path)
    }

    private func openArtifact(named fileName: String) {
        NSWorkspace.shared.open(artifactURL(named: fileName))
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

    private var effectiveStatus: PiSubagentRunStatus {
        displayedStatus ?? run.status
    }

    private func updateDisplayedStatus(from oldStatus: PiSubagentRunStatus, to newStatus: PiSubagentRunStatus) {
        statusLingerTask?.cancel()
        if oldStatus.isActive, !newStatus.isActive {
            displayedStatus = oldStatus
            statusLingerTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(550))
                guard !Task.isCancelled else { return }
                displayedStatus = newStatus
                statusLingerTask = nil
            }
        } else {
            displayedStatus = newStatus
            statusLingerTask = nil
        }
    }

    private var statusColor: Color {
        switch effectiveStatus {
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

struct PiSubagentStatusText: View {
    let status: PiSubagentRunStatus
    let color: Color
    var font: Font = .caption.weight(.semibold)
    @State private var dotCount = 1

    var body: some View {
        Text(label)
            .font(font)
            .foregroundStyle(color)
            .contentTransition(.opacity)
            .onReceive(Timer.publish(every: 0.42, on: .main, in: .common).autoconnect()) { _ in
                guard status.isActive else { return }
                dotCount = dotCount % 3 + 1
            }
    }

    private var label: String {
        let base = status.rawValue.capitalized
        guard status.isActive else { return base }
        return base + String(repeating: ".", count: dotCount)
    }
}

struct PiSubagentActivityGlyph: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let color: Color
    let isActive: Bool
    @State private var isPulsing = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(isActive ? 0.18 : 0.10), lineWidth: 1)

            if isActive && !reduceMotion {
                Circle()
                    .stroke(color.opacity(isPulsing ? 0 : 0.32), lineWidth: 1.5)
                    .scaleEffect(isPulsing ? 1.45 : 1.05)
            }

            Image(systemName: "rectangle.connected.to.line.below")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(color)
                .transaction { transaction in
                    transaction.animation = nil
                }
        }
        .frame(width: 34, height: 34)
        .accessibilityHidden(true)
        .task(id: isActive) {
            guard isActive, !reduceMotion else {
                isPulsing = false
                return
            }
            isPulsing = false
            withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) {
                isPulsing = true
            }
        }
    }
}

struct PiNativeSubagentGraphSheet: View {
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

struct PiNativeSubagentTranscriptSheet: View {
    let run: PiSubagentRunRecord
    let entries: [PiAgentTranscriptEntry]
    let thinkingDisplayMode: PiAgentThinkingDisplayMode
    let visibility: PiAgentTranscriptVisibilitySettings
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

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
                TextField("Search transcript", text: $query)
                    .textFieldStyle(.roundedBorder)
            }

            Divider()

            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if filteredTranscriptEntries.isEmpty {
                        Text("No matching transcript entries.")
                            .foregroundStyle(AppTheme.mutedText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(AppTheme.contentSubtleFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    } else {
                        ForEach(filteredTranscriptEntries) { entry in
                            transcriptEntryView(entry)
                                .id(entry.id)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(22)
        .frame(width: 820, height: 620)
    }

    private var filteredTranscriptEntries: [PiAgentTranscriptEntry] {
        let displayEntries = [taskEntry] + entries.filter { entry in
            switch entry.role {
            case .tool:
                return isWebActivity(entry) ? visibility.showWebActivity : visibility.showToolCalls
            case .status, .raw:
                return visibility.showToolCalls
            case .error, .stderr: return visibility.showErrors
            case .thinking: return visibility.showThinking
            case .assistant: return true
            case .user: return false
            }
        }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return displayEntries }
        return displayEntries.filter { "\($0.title)\n\($0.text)".lowercased().contains(needle) }
    }

    private var taskEntry: PiAgentTranscriptEntry {
        PiAgentTranscriptEntry(
            id: run.id,
            sessionID: run.parentSessionID,
            role: .user,
            title: "Task",
            text: run.task,
            timestamp: run.createdAt
        )
    }

    private func isWebActivity(_ entry: PiAgentTranscriptEntry) -> Bool {
        let name = entry.title.hasPrefix("Tool: ")
            ? entry.title.replacingOccurrences(of: "Tool: ", with: "")
            : entry.title
        switch name.lowercased() {
        case "web_search", "fetch_content", "get_search_content":
            return true
        default:
            return false
        }
    }

    @ViewBuilder
    private func transcriptEntryView(_ entry: PiAgentTranscriptEntry) -> some View {
        switch entry.role {
        case .status, .stderr, .raw, .error:
            PiAgentStatusTranscriptRow(entry: entry)
        case .user:
            PiAgentTranscriptCard(entry: entry, thinkingDisplayMode: thinkingDisplayMode, style: .question)
        default:
            PiAgentTranscriptCard(entry: entry, thinkingDisplayMode: thinkingDisplayMode, style: .threadChild)
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

struct PiNativeSubagentRunSheet: View {
    struct AgentInfo: Hashable {
        let description: String
        let model: String?
        let thinking: String?
        let tools: [String]
        let skills: [String]
        let output: String?

        init(agent: EffectiveAgentRecord) {
            description = agent.resolved.description
            model = agent.resolved.model
            thinking = agent.resolved.thinking
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
                    .foregroundStyle(AppTheme.brandAccent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Run Subagent")
                        .font(.title3.bold())
                    Text("Launches a separate Pi RPC child session managed by \(AppBrand.displayName). This does not insert or send a raw /run command.")
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
                        subagentInfoLine("Assigned Skills", selectedInfo.skills.isEmpty ? "None" : selectedInfo.skills.joined(separator: ", "))
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
                Text("Use this for files the caller knows are relevant now. Type @ to search project files, use the paperclip, or drag files here. Defaults from the agent are treated as hints only; \(AppBrand.displayName) does not inject stale file contents.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .appContentSurface(cornerRadius: 12)
            .overlay {
                if isReadFirstDropTargeted {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(AppTheme.brandAccent, lineWidth: 2)
                        .background(AppTheme.brandAccent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $isReadFirstDropTargeted) { providers in
                loadReadFirstDroppedFiles(from: providers)
                return true
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("Native run", systemImage: "checkmark.seal")
                    .font(.subheadline.weight(.semibold))
                Text("\(AppBrand.displayName) starts and tracks the child session directly, records artifacts under Application Support, and posts a status/result entry back to the parent transcript.")
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
