import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Shared `JSONDecoder` for view-layer payload decoding. Reused so SwiftUI
/// computed properties don't allocate a fresh decoder on every `body` eval.
private let subagentJSONDecoder = JSONDecoder()

fileprivate struct PiSubagentInjectedMemory: Identifiable, Hashable {
    var id: String
    var title: String
}

struct PiAgentFileAttachment: Identifiable, Hashable {
    let id = UUID()
    let url: URL

    init?(url: URL) {
        // Prefer FileManager over `hasDirectoryPath`: Finder pasteboard URLs often
        // omit the trailing slash, so directory URLs would incorrectly pass as files
        // and folders would fail `PiAgentFolderAttachment` — attach nothing.
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if exists {
            guard !isDirectory.boolValue else { return nil }
        } else if url.hasDirectoryPath {
            return nil
        }
        self.url = url
    }
}

struct PiAgentFolderAttachment: Identifiable, Hashable {
    let id = UUID()
    let url: URL

    init?(url: URL) {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { return nil }
            self.url = url
            return
        }
        // Fallback for not-yet-resolved / permission-edge paths that still look like dirs.
        guard url.hasDirectoryPath else { return nil }
        self.url = url
    }
}

struct PiSubagentSupervisorRequestInlineNotice: View {
    let request: PiSubagentSupervisorRequest
    let onRespond: () -> Void
    let onCancel: () -> Void
    @ObservedObject private var languageStore = LanguageStore.shared

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "questionmark.bubble.fill")
                .font(AppTheme.Font.headline)
                .foregroundStyle(AppTheme.brandAccent)
                .frame(width: 24, alignment: .center)
            VStack(alignment: .leading, spacing: 3) {
                Text(languageStore.t("sub.supervisorQuestion"))
                    .font(AppTheme.Font.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.mutedText)
                Text(request.title)
                    .font(AppTheme.Font.subheadline.weight(.semibold))
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Button(languageStore.t("common.cancel"), action: onCancel)
                .appSecondaryButton()
            Button(languageStore.t("sub.respond"), action: onRespond)
                .appPrimaryButton()
        }
        .padding(12)
        .background(AppTheme.contentSubtleFill, in: RoundedRectangle(cornerRadius: AppTheme.Chat.suggestionCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Chat.suggestionCornerRadius, style: .continuous)
                .strokeBorder(AppTheme.contentStroke, lineWidth: 0.5)
        )
    }
}

struct PiSubagentSupervisorRequestSheet: View {
    let request: PiSubagentSupervisorRequest
    let onRespond: (String) -> Void
    let onCancel: () -> Void
    @ObservedObject private var languageStore = LanguageStore.shared

    var body: some View {
        PiAgentUIRequestSheet(
            request: askUserRequest,
            onSubmitValue: { onRespond($0.trimmingCharacters(in: .whitespacesAndNewlines)) },
            onSubmitFreeform: { _, value in onRespond(value.trimmingCharacters(in: .whitespacesAndNewlines)) },
            onConfirm: { _ in },
            onCancel: onCancel
        )
    }

    private var askUserRequest: PiAgentUIRequest {
        PiAgentUIRequest(
            id: "supervisor-\(request.id)",
            sessionID: request.parentSessionID,
            method: .editor,
            title: request.title,
            message: supervisorMessage,
            options: [],
            optionDescriptions: [:],
            placeholder: languageStore.t("sub.responsePlaceholder"),
            prefill: nil,
            allowsFreeform: false,
            allowsComment: false,
            responseFormat: .plain
        )
    }

    private var supervisorMessage: String? {
        guard request.kind == .interviewRequest,
              let interview = structuredInterview else {
            return request.message
        }
        let intro = interview.prompt ?? interview.message ?? ""
        let questions = interview.questions.map { question -> String in
            let suffix = question.required == false ? languageStore.t("sub.optionalSuffix") : ""
            if question.type == "info" {
                return "• \(question.labelText): \(question.placeholder ?? languageStore.t("sub.noResponseRequired"))"
            }
            return "• \(question.labelText)\(suffix)"
        }
        return ([intro.trimmingCharacters(in: .whitespacesAndNewlines)] + questions)
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private var structuredInterview: SupervisorInterviewPayload? {
        let trimmed = request.message.trimmingCharacters(in: .whitespacesAndNewlines)
        return JSONParseMemo.value("structuredInterview\(JSONParseMemo.separator)\(trimmed)") {
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
                  let payload = try? subagentJSONDecoder.decode(SupervisorInterviewPayload.self, from: data),
                  !payload.questions.isEmpty else { return nil }
            return payload
        }
    }

    private struct SupervisorInterviewPayload: Codable {
        var prompt: String?
        var message: String?
        var questions: [SupervisorInterviewQuestion]
    }

    private struct SupervisorInterviewQuestion: Codable {
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
    let onOpenChildTranscript: (UUID) -> Void
    let onStopChild: (UUID) -> Void
    @ObservedObject var imageStore: AgentImageStore
    @ObservedObject private var languageStore = LanguageStore.shared
    @State private var isDetailsPresented = false
    @State private var promptPopover: PromptPopover?
    @State private var memoryPopover: MemoryPopover?
    @State private var displayedStatus: PiSubagentRunStatus?
    @State private var statusLingerTask: Task<Void, Never>?
    /// Cached `fileExists` for the run's final-system-prompt artifact and
    /// each child's. Refreshed via `.task(id: run.artifactDirectory)` +
    /// `.onChange(of: run.status)` (artifacts appear when the run completes).
    /// The previous per-render `FileManager.default.fileExists` inside
    /// `.disabled(...)` did a stat() per body eval on every row.
    @State private var rootArtifactExists: Bool = false
    @State private var childArtifactExists: [UUID: Bool] = [:]

    private struct PromptPopover: Identifiable {
        let id = UUID()
        var title: String
        var text: String
    }

    private struct MemoryPopover: Identifiable {
        let id = UUID()
        var title: String
        var memories: [PiSubagentInjectedMemory]
    }

    var body: some View {
        AppRowCard {
            VStack(alignment: .leading, spacing: 12) {
                if run.mode == .parallel, let children = run.children, !children.isEmpty {
                    parallelHeader(children: children)
                    childSummary(children)
                } else {
                    header
                    taskPreview
                }

                if !compactMetadata.isEmpty {
                    HStack(spacing: 10) {
                        ForEach(compactMetadata) { item in
                            compactMetric(item)
                        }
                    }
                    .font(AppTheme.Font.caption)
                    .foregroundStyle(AppTheme.mutedText)
                }
            }
        }
        .popover(item: $promptPopover, arrowEdge: .bottom) { prompt in
            PiAgentPromptAuditPopover(title: prompt.title, text: prompt.text)
        }
        .popover(item: $memoryPopover, arrowEdge: .bottom) { popover in
            PiSubagentInjectedMemoryPopover(title: popover.title, memories: popover.memories)
        }
        .onAppear { displayedStatus = run.status }
        .onChange(of: run.status) { oldStatus, newStatus in
            updateDisplayedStatus(from: oldStatus, to: newStatus)
            refreshArtifactExistence()
        }
        .task(id: run.artifactDirectory) { refreshArtifactExistence() }
        .onDisappear {
            statusLingerTask?.cancel()
            statusLingerTask = nil
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            PiSubagentActivityGlyph(color: statusColor, isActive: effectiveStatus.isActive, imageURL: imageStore.imageURL(for: run.agentName))
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(run.agentName)
                        .font(AppTheme.Font.headline)
                    Text(shortRunID)
                        .font(AppTheme.Font.code.weight(.medium))
                        .foregroundStyle(AppTheme.mutedText)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .appGlassCapsule()
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

    private func parallelHeader(children: [PiSubagentChildRecord]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(languageStore.t("sub.parallelAgents"))
                .font(AppTheme.Font.headline)
            Text("\(children.count)")
                .font(AppTheme.Font.caption2.monospaced().weight(.bold))
                .foregroundStyle(AppTheme.mutedText)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .appGlassCapsule()
            PiSubagentStatusText(status: effectiveStatus, color: statusColor)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        Button {
            isDetailsPresented.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(AppTheme.Font.body.weight(.semibold))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(AppTheme.mutedText)
        .help(languageStore.t("sub.runDetails"))
        .popover(isPresented: $isDetailsPresented, arrowEdge: .trailing) {
            detailsPopover
        }
        if run.children?.isEmpty == false {
            Button(languageStore.t("sub.graph"), action: onOpenGraph)
                .appSecondaryButton()
                .controlSize(.small)
        }
        if !rootInjectedMemories.isEmpty {
            Button {
                memoryPopover = .init(title: languageStore.t("sub.injectedMemories"), memories: rootInjectedMemories)
            } label: {
                Label(languageStore.t("sub.memory"), systemImage: "brain")
            }
            .appSecondaryButton()
            .controlSize(.small)
            .help(languageStore.t("sub.memoryHelp"))
        }
        Button(languageStore.t("sub.systemPrompt")) {
            promptPopover = .init(
                title: languageStore.t("sub.finalRuntimePrompt"),
                text: promptFileText(path: artifactURL(named: "final-system-prompt.md").path)
            )
        }
        .appSecondaryButton()
        .controlSize(.small)
        .disabled(!canOpenArtifact(named: "final-system-prompt.md"))
        .help(languageStore.t("sub.finalRuntimePromptHelp"))
        Button(languageStore.t("sub.transcript"), action: onOpenTranscript)
            .appSecondaryButton()
            .controlSize(.small)
        if run.status.isActive {
            Button(languageStore.t("sub.stop"), action: onStop)
                .buttonStyle(.glass)
                .controlSize(.small)
                .tint(.red)
        }
    }

    private var taskPreview: some View {
        PiSubagentTaskPreview(task: run.task)
    }

    private var detailRows: [(String, String)] {
        var rows: [(String, String)] = []
        if let turnIndex = run.child?.index, turnIndex > 0 {
            rows.append((languageStore.t("sub.continuation"), languageStore.t("sub.turnN", turnIndex + 1)))
        }
        if let duration = latestDurationMs {
            rows.append((languageStore.t("sub.duration"), formattedDuration(duration)))
        }
        if let totalTokens {
            rows.append((languageStore.t("sub.tokens"), compactNumber(totalTokens)))
        }
        if let totalCost {
            rows.append((languageStore.t("sub.cost"), String(format: "$%.2f", totalCost)))
        }
        if let toolCount {
            rows.append((languageStore.t("sub.tools"), "\(toolCount)"))
        }
        if let modelName {
            rows.append((languageStore.t("sub.model"), modelName))
        }
        if let thinkingLevel {
            rows.append((languageStore.t("sub.thinking"), thinkingLevel))
        }
        if let expectedOutcome = run.expectedOutcome {
            rows.append((languageStore.t("sub.outcome"), expectedOutcome.displayName + (run.requestedOutputPath.map { " · \($0)" } ?? "")))
        }
        if let reads = run.readFirstPaths, !reads.isEmpty {
            rows.append((languageStore.t("sub.readFirst"), reads.joined(separator: ", ")))
        }
        if run.isWorktreeIsolated == true {
            rows.append((languageStore.t("sub.worktreeStatus"), (run.worktreeStatus ?? .active).rawValue))
        }
        return rows
    }

    private var detailsPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(languageStore.t("sub.runDetails"), systemImage: "info.circle")
                .font(AppTheme.Font.headline)

            AppKeyValueList(rows: detailRows)

            if hasDetailActions {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text(languageStore.t("sub.actions"))
                        .font(AppTheme.Font.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.mutedText)

                    if !run.artifactDirectory.isEmpty {
                        Button(languageStore.t("sub.revealRunFolder"), action: onReveal)
                    }
                }
                .appSecondaryButton()
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

    private var totalCost: Double? {
        if let cost = run.child?.cost { return cost }
        let costs = run.children?.compactMap(\.cost) ?? []
        guard !costs.isEmpty else { return nil }
        return costs.reduce(0, +)
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
                .font(AppTheme.Font.caption2.weight(.semibold))
            Text(item.text)
                .lineLimit(1)
        }
    }

    private func childSummary(_ children: [PiSubagentChildRecord]) -> some View {
        LazyVGrid(columns: parallelChildColumns, alignment: .leading, spacing: 12) {
            ForEach(children) { child in
                parallelChildTile(child)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Chat.panelCornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [AppTheme.contentSubtleFill.opacity(0.82), AppTheme.contentFill.opacity(0.58)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .stroke(AppTheme.contentStroke, lineWidth: 1)
        )
    }

    private var parallelChildColumns: [GridItem] {
        [
            GridItem(.flexible(minimum: 210), spacing: 8, alignment: .topLeading),
            GridItem(.flexible(minimum: 210), spacing: 8, alignment: .topLeading)
        ]
    }

    private func parallelChildTile(_ child: PiSubagentChildRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            parallelChildHeader(child)
            parallelChildTaskPreview(child)

            let metadata = childCompactMetadata(child)
            if !metadata.isEmpty {
                HStack(spacing: 10) {
                    ForEach(metadata) { item in
                        compactMetric(item)
                    }
                }
                .font(AppTheme.Font.caption)
                .foregroundStyle(AppTheme.mutedText)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .appContentSurface(cornerRadius: AppTheme.Chat.panelCornerRadius)
    }

    private func parallelChildHeader(_ child: PiSubagentChildRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                PiSubagentActivityGlyph(color: color(for: child.status), isActive: child.status.isActive, imageURL: imageStore.imageURL(for: child.agentName))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(child.agentName)
                            .font(AppTheme.Font.headline)
                            .lineLimit(1)
                            .layoutPriority(1)
                        if let outcome = child.expectedOutcome {
                            Text(outcome.displayName)
                                .font(AppTheme.Font.caption2.weight(.medium))
                                .foregroundStyle(AppTheme.mutedText)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .appGlassCapsule()
                                .help(LanguageStore.shared.t("sub.expectedOutcome", outcome.displayName))
                        }
                    }
                    PiSubagentStatusText(status: child.status, color: color(for: child.status))
                }
                Spacer(minLength: 0)
            }
            parallelChildActions(child)
        }
    }

    @ViewBuilder
    private func parallelChildActions(_ child: PiSubagentChildRecord) -> some View {
        HStack(spacing: 8) {
            let memories = injectedMemories(for: child)
            if !memories.isEmpty {
                Button {
                    memoryPopover = .init(title: "\(languageStore.t("sub.injectedMemories")) · \(child.agentName)", memories: memories)
                } label: {
                    Label(languageStore.t("sub.memory"), systemImage: "brain")
                }
                .appSecondaryButton()
                .controlSize(.small)
                .fixedSize(horizontal: true, vertical: false)
                .help(languageStore.t("sub.memoryHelp"))
            }

            Button(languageStore.t("sub.systemPrompt")) {
                promptPopover = .init(
                    title: languageStore.t("sub.finalRuntimePrompt"),
                    text: promptFileText(path: childArtifactURL(child, named: "final-system-prompt.md").path)
                )
            }
            .appSecondaryButton()
            .controlSize(.small)
            .fixedSize(horizontal: true, vertical: false)
            .disabled(!canOpenChildArtifact(child, named: "final-system-prompt.md"))
            .help(languageStore.t("sub.finalRuntimePromptHelp"))

            if let executionRunID = child.executionRunID {
                Button(languageStore.t("sub.transcript")) {
                    onOpenChildTranscript(executionRunID)
                }
                .appSecondaryButton()
                .controlSize(.small)
                .fixedSize(horizontal: true, vertical: false)

                if child.status.isActive {
                    Button(languageStore.t("sub.stop")) {
                        onStopChild(executionRunID)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .tint(.red)
                    .fixedSize(horizontal: true, vertical: false)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func parallelChildTaskPreview(_ child: PiSubagentChildRecord) -> some View {
        let task = nonEmpty(child.task) ?? nonEmpty(child.summary ?? child.error) ?? LanguageStore.shared.t("sub.noTaskCaptured")
        // fillsHeight: stretch the box to the equal-height grid tile so both siblings match.
        return PiSubagentTaskPreview(task: task, fillsHeight: true)
    }

    private func childArtifactURL(_ child: PiSubagentChildRecord, named fileName: String) -> URL {
        URL(fileURLWithPath: child.artifactDirectory ?? "").appendingPathComponent(fileName)
    }

    private func canOpenChildArtifact(_ child: PiSubagentChildRecord, named fileName: String) -> Bool {
        // For final-system-prompt.md (the only consumer at present), read the
        // cached @State refreshed by `.task(id:)` + `.onChange(of:)` below.
        // Fall back to a live `fileExists` for any other filename to keep this
        // helper general.
        if fileName == "final-system-prompt.md" {
            return childArtifactExists[child.id] ?? false
        }
        guard child.artifactDirectory?.isEmpty == false else { return false }
        return FileManager.default.fileExists(atPath: childArtifactURL(child, named: fileName).path)
    }

    private var rootInjectedMemories: [PiSubagentInjectedMemory] {
        injectedMemories(ids: run.injectedMemoryIDs ?? run.child?.injectedMemoryIDs, titles: run.injectedMemoryTitles ?? run.child?.injectedMemoryTitles)
    }

    private func injectedMemories(for child: PiSubagentChildRecord) -> [PiSubagentInjectedMemory] {
        injectedMemories(ids: child.injectedMemoryIDs, titles: child.injectedMemoryTitles)
    }

    private func injectedMemories(ids: [String]?, titles: [String]?) -> [PiSubagentInjectedMemory] {
        let ids = ids ?? []
        guard !ids.isEmpty else { return [] }
        return ids.enumerated().map { index, id in
            let title = titles?.indices.contains(index) == true ? (titles?[index] ?? "") : ""
            return PiSubagentInjectedMemory(id: id, title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? id : title)
        }
    }

    private func childCompactMetadata(_ child: PiSubagentChildRecord) -> [CompactMetadataItem] {
        var items: [CompactMetadataItem] = []
        if let duration = child.durationMs {
            items.append(.init(text: formattedDuration(duration), icon: "timer"))
        }
        if let totalTokens = child.totalTokens {
            items.append(.init(text: compactNumber(totalTokens), icon: "tugriksign.circle"))
        }
        if let toolCount = child.toolCount {
            items.append(.init(text: "\(toolCount)", icon: "wrench.and.screwdriver"))
        }
        if let model = nonEmpty(child.model) {
            items.append(.init(text: model, icon: "cpu"))
        }
        return items
    }

    private func artifactURL(named fileName: String) -> URL {
        URL(fileURLWithPath: run.child?.artifactDirectory ?? run.artifactDirectory).appendingPathComponent(fileName)
    }

    private func canOpenArtifact(named fileName: String) -> Bool {
        if fileName == "final-system-prompt.md" {
            return rootArtifactExists
        }
        return FileManager.default.fileExists(atPath: artifactURL(named: fileName).path)
    }

    /// Recompute the cached `*ArtifactExists` flags. Called from a `.task`
    /// keyed on `run.artifactDirectory` and on `.onChange(of: run.status)`
    /// (artifacts appear when the run terminates).
    private func refreshArtifactExistence() {
        rootArtifactExists = FileManager.default.fileExists(atPath: artifactURL(named: "final-system-prompt.md").path)
        var byChild: [UUID: Bool] = [:]
        for child in (run.children ?? []) {
            guard child.artifactDirectory?.isEmpty == false else { continue }
            byChild[child.id] = FileManager.default.fileExists(atPath: childArtifactURL(child, named: "final-system-prompt.md").path)
        }
        if let single = run.child {
            byChild[single.id] = FileManager.default.fileExists(atPath: childArtifactURL(single, named: "final-system-prompt.md").path)
        }
        childArtifactExists = byChild
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

    private var statusColor: Color { effectiveStatus.themedColor }
}

private struct PiSubagentInjectedMemoryPopover: View {
    let title: String
    let memories: [PiSubagentInjectedMemory]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: "brain")
                .font(AppTheme.Font.headline)
                .foregroundStyle(AppTheme.brandAccent)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(memories) { memory in
                    Button {
                        NotificationCenter.default.post(
                            name: .agentDeckOpenMemoryRequested,
                            object: nil,
                            userInfo: ["id": memory.id]
                        )
                    } label: {
                        HStack(spacing: 6) {
                            Text(memory.title.isEmpty ? LanguageStore.shared.t("sub.untitledMemory") : memory.title)
                                .font(AppTheme.Font.caption.weight(.medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Image(systemName: "chevron.right")
                                .font(AppTheme.Font.caption2.weight(.semibold))
                                .foregroundStyle(AppTheme.mutedText)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(memory.id)
                }
            }
        }
        .padding(16)
        .frame(width: 360, alignment: .leading)
    }
}

/// Task preview shared by the single-run and parallel-child subagent cards.
///
/// Renders the full task — no truncation. In parallel mode `fillsHeight` stretches the
/// box to its equal-height grid tile so a shorter task's box matches its taller sibling
/// instead of floating short.
private struct PiSubagentTaskPreview: View {
    let task: String
    /// When true, the box fills the available height (the equal-height parallel tile).
    var fillsHeight: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(LanguageStore.shared.t("sub.task"), systemImage: "list.clipboard")
                .font(AppTheme.Font.caption.weight(.semibold))
                .fontWidth(.expanded)
                .foregroundStyle(AppTheme.mutedText)

            MarkdownTextView(source: task)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Chat.panelCornerRadius, style: .continuous)
                .fill(AppTheme.contentSubtleFill.opacity(0.65))
                .stroke(AppTheme.contentStroke, lineWidth: 1)
        )
        .help(task)
    }
}

extension PiSubagentRunStatus {
    /// The one themed status→color mapping, shared by the native cards and every
    /// SwiftUI surface (fallback card, run/transcript sheets). Active states take
    /// the theme accent (the app's "activity" color), blocked the tool amber,
    /// completed the diff-added green, failed the error red — so run status
    /// follows the active theme instead of fixed system colors.
    @MainActor var themedColor: Color {
        switch self {
        case .queued, .starting, .running: return AppTheme.brandAccent
        case .blocked: return AppTheme.roleTool
        case .completed: return AppTheme.diffAdded
        case .failed: return AppTheme.roleError
        case .stopped, .disconnected: return AppTheme.mutedText
        }
    }
}

struct PiSubagentStatusText: View {
    let status: PiSubagentRunStatus
    let color: Color
    var font: Font = .caption.weight(.semibold)

    var body: some View {
        Text(status.rawValue.capitalized)
            .font(font)
            .foregroundStyle(color)
            .contentTransition(.opacity)
    }
}

struct PiSubagentActivityGlyph: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let color: Color
    let isActive: Bool
    var imageURL: URL? = nil

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(isActive ? 0.10 : 0.06))

            Circle()
                .stroke(color.opacity(isActive ? 0.22 : 0.12), lineWidth: 1)

            if isActive {
                if reduceMotion {
                    activityRing(rotation: .degrees(-90))
                } else {
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                        activityRing(rotation: rotation(at: context.date))
                    }
                }
            }

            if let nsImage = AgentImageLoader.image(at: imageURL) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 28, height: 28)
                    .clipShape(Circle())
                    .transaction { transaction in
                        transaction.animation = nil
                    }
            } else {
                Image(systemName: "paperplane")
                    .imageScale(.large)
                    .fontWeight(.medium)
                    .foregroundStyle(color)
                    .transaction { transaction in
                        transaction.animation = nil
                    }
            }
        }
        .frame(width: 34, height: 34)
        .accessibilityHidden(true)
    }

    private func rotation(at date: Date) -> Angle {
        .degrees(date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 6) * 60 - 90)
    }

    private func activityRing(rotation: Angle) -> some View {
        Circle()
            .trim(from: 0.07, to: 0.34)
            .stroke(
                AngularGradient(
                    colors: [color.opacity(0.2), color.opacity(0.95), color.opacity(0.2)],
                    center: .center
                ),
                style: StrokeStyle(lineWidth: 1.7, lineCap: .round)
            )
            .rotationEffect(rotation)
            .padding(1.5)
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
                    Text(LanguageStore.shared.t("sub.deckAgentGraph", run.agentName))
                        .font(.title3.bold())
                    Text("\(run.mode.rawValue.capitalized) · \(run.status.rawValue.capitalized) · \(run.children?.count ?? 0) child runs")
                        .font(AppTheme.Font.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if run.status.isActive {
                    Button(LanguageStore.shared.t("sub.stopGraph"), role: .destructive, action: onStopGraph)
                        .appSecondaryButton()
                }
            }
            Divider()
            ScrollView(showsIndicators: false) {
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
                    .font(AppTheme.Font.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(5)
            }
        }
        .padding(20)
        .frame(width: 760, height: 620)
    }

    private func graphChildCard(_ child: PiSubagentChildRecord) -> some View {
        AppRowCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Circle().fill(color(for: child.status)).frame(width: 9, height: 9)
                    Text("\(child.index + 1). \(child.agentName)")
                        .font(AppTheme.Font.headline)
                    AppLabelTag(text: child.status.rawValue, color: color(for: child.status))
                    Spacer()
                    if child.status.isActive {
                        Button(LanguageStore.shared.t("sub.stop")) { onStopChild(child) }
                            .controlSize(.small)
                    }
                    if [.failed, .stopped, .disconnected].contains(child.status) {
                        Button(LanguageStore.shared.t("sub.retry")) { onRetryChild(child) }
                            .controlSize(.small)
                            .appPrimaryButton()
                    }
                    Button(LanguageStore.shared.t("sub.artifacts")) { onOpenChildArtifacts(child) }
                        .controlSize(.small)
                        .disabled(child.artifactDirectory == nil)
                }
                if let task = child.task, !task.isEmpty {
                    Text(task)
                        .font(AppTheme.Font.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                if let summary = child.summary, !summary.isEmpty {
                    Text(summary)
                        .font(AppTheme.Font.caption)
                        .lineLimit(4)
                } else if let error = child.error, !error.isEmpty {
                    Text(error)
                        .font(AppTheme.Font.caption)
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
                .font(AppTheme.Font.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value ?? "—")
                .font(AppTheme.Font.caption2.monospaced())
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

    private func color(for status: PiSubagentRunStatus) -> Color { status.themedColor }
}

struct PiNativeSubagentTranscriptSheet: View {
    let run: PiSubagentRunRecord
    let store: PiAgentSessionStore
    let visibility: PiAgentTranscriptVisibilitySettings
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        let transcriptState = currentTranscriptState
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(LanguageStore.shared.t("sub.deckAgentTranscript"))
                        .font(.title3.bold())
                    Text("\(run.agentName) · \(run.status.rawValue.capitalized)")
                        .font(AppTheme.Font.caption.weight(.semibold))
                        .foregroundStyle(statusColor)
                }
                Spacer()
                Button(LanguageStore.shared.t("common.close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(AppTheme.mutedText)
                AppTextField(text: $query, placeholder: LanguageStore.shared.t("sub.searchTranscript"))
            }

            Divider()

            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if transcriptState.isLoading {
                        transcriptStatusView("Loading transcript…")
                    }
                    ForEach(transcriptState.entries) { entry in
                        transcriptEntryView(entry)
                            .id(entry.id)
                    }
                    if !transcriptState.isLoading, transcriptState.entries.isEmpty {
                        transcriptStatusView("No matching transcript entries.")
                    } else if !transcriptState.isLoading, !transcriptState.hasTranscriptEntries, query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        transcriptStatusView("No transcript entries yet.")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(22)
        .frame(width: 820, height: 620)
    }

    private var currentTranscriptState: (entries: [PiAgentTranscriptEntry], hasTranscriptEntries: Bool, isLoading: Bool) {
        let entries = store.cachedSubagentTranscript(for: run.id)
        let hasCachedTranscript = store.hasCachedSubagentTranscript(for: run.id)
        let isLoading = store.isSubagentTranscriptLoadPending(for: run.id)
            || (!hasCachedTranscript && store.hasPersistedSubagentTranscript(for: run.id))
        let displayEntries = [taskEntry] + visibleTranscriptEntries(from: entries)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filteredEntries = needle.isEmpty
            ? displayEntries
            : displayEntries.filter { "\($0.title)\n\($0.text)".lowercased().contains(needle) }
        return (filteredEntries, !entries.isEmpty, isLoading)
    }

    private func visibleTranscriptEntries(from entries: [PiAgentTranscriptEntry]) -> [PiAgentTranscriptEntry] {
        entries.filter { entry in
            switch entry.role {
            case .tool:
                // Non-web tool calls are no longer surfaced in transcripts (recapped
                // in the Session resources popover instead); web activity still honors
                // its own toggle.
                return isWebActivity(entry) ? visibility.showWebActivity : false
            case .status, .raw:
                return false
            case .error, .stderr: return visibility.showErrors
            case .thinking: return visibility.showThinking
            case .assistant: return true
            case .user: return false
            }
        }
    }

    private var taskEntry: PiAgentTranscriptEntry {
        PiAgentTranscriptEntry(
            id: run.id,
            sessionID: run.parentSessionID,
            role: .user,
            title: LanguageStore.shared.t("sub.task"),
            text: run.task,
            timestamp: run.createdAt
        )
    }

    private func isWebActivity(_ entry: PiAgentTranscriptEntry) -> Bool {
        let name = entry.title.hasPrefix("Tool: ")
            ? entry.title.replacingOccurrences(of: "Tool: ", with: "")
            : entry.title
        switch name.lowercased() {
        case "web_search", "fetch_content", "get_search_content", "web_fetch":
            return true
        default:
            return false
        }
    }

    private func transcriptStatusView(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(AppTheme.mutedText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(AppTheme.contentSubtleFill, in: RoundedRectangle(cornerRadius: AppTheme.Chat.panelCornerRadius, style: .continuous))
    }

    @ViewBuilder
    private func transcriptEntryView(_ entry: PiAgentTranscriptEntry) -> some View {
        switch entry.role {
        case .status, .stderr, .raw, .error:
            PiAgentStatusTranscriptRow(entry: entry)
        case .user:
            PiAgentTranscriptCard(entry: entry, style: .question, showInlineImagePreviews: visibility.showImages)
        default:
            PiAgentTranscriptCard(entry: entry, style: .threadChild, showInlineImagePreviews: visibility.showImages)
        }
    }

    private var statusColor: Color { run.status.themedColor }
}

struct PiNativeSubagentRunSheet: View {
    struct AgentInfo: Hashable {
        let description: String
        let model: String?
        let thinking: String?
        let tools: [String]
        let skills: [String]
        let output: String?
        let defaultExpectedOutcome: PiSubagentExpectedOutcome?

        init(agent: EffectiveAgentRecord) {
            description = agent.resolved.description
            model = agent.resolved.model
            thinking = agent.resolved.thinking
            tools = agent.resolved.tools ?? []
            skills = agent.resolved.skills
            output = agent.resolved.output
            defaultExpectedOutcome = agent.resolved.defaultExpectedOutcome
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
                Image(systemName: "paperplane")
                    .foregroundStyle(AppTheme.brandAccent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(LanguageStore.shared.t("sub.runDeckAgent"))
                        .font(.title3.bold())
                    Text(LanguageStore.shared.t("sub.launchSeparateChild", AppBrand.displayName))
                        .font(AppTheme.Font.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Picker(LanguageStore.shared.t("sub.agentPicker"), selection: $selectedAgentName) {
                ForEach(agentNames, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .appMenuPicker()
            .disabled(agentNames.isEmpty)

            if let selectedInfo {
                VStack(alignment: .leading, spacing: 8) {
                    Text(selectedInfo.description.isEmpty ? "No description" : selectedInfo.description)
                        .font(AppTheme.Font.subheadline)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 6) {
                        subagentInfoLine("Model", selectedInfo.model ?? "Default")
                        subagentInfoLine("Thinking", selectedInfo.thinking ?? "Default")
                        subagentInfoLine("Assigned Skills", selectedInfo.skills.isEmpty ? "None" : selectedInfo.skills.joined(separator: ", "))
                        subagentInfoLine("Tools", selectedInfo.tools.isEmpty ? "Default" : selectedInfo.tools.joined(separator: ", "))
                        subagentInfoLine("Output", selectedInfo.output ?? "App artifact")
                        subagentInfoLine("Default Outcome", selectedInfo.defaultExpectedOutcome?.displayName ?? "Report only")
                    }
                    if selectedInfo.output != nil {
                        Label(LanguageStore.shared.t("sub.artifactsDefaultHint"), systemImage: "exclamationmark.triangle")
                            .font(AppTheme.Font.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(10)
                .appContentSurface(cornerRadius: AppTheme.Chat.cardCornerRadius)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(LanguageStore.shared.t("sub.task"))
                    .font(AppTheme.Font.headline)
                TextEditor(text: $task)
                    .font(AppTheme.Font.body)
                    .frame(minHeight: 140)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: AppTheme.Chat.subCardCornerRadius))
            }

            VStack(alignment: .leading, spacing: 8) {
                Label(LanguageStore.shared.t("sub.filesReadFirst"), systemImage: "doc.text.magnifyingglass")
                    .font(AppTheme.Font.subheadline.weight(.semibold))
                HStack(alignment: .top, spacing: 8) {
                    AppTextField(text: $readFirstPathsText, placeholder: LanguageStore.shared.t("sub.filesReadFirstPlaceholder"), axis: .vertical)
                        .lineLimit(1...4)
                    Button(action: addReadFirstPathsFromOpenPanel) {
                        Image(systemName: "paperclip")
                    }
                    .help(LanguageStore.shared.t("sub.addProjectFiles"))
                    .accessibilityLabel(LanguageStore.shared.t("sub.addProjectFiles"))
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
                            .font(AppTheme.Font.caption)
                        }
                    }
                    .padding(.horizontal, 6)
                    if readFirstFileSuggestions.count > 8 {
                        Text(LanguageStore.shared.t("sub.showingTop8"))
                            .font(AppTheme.Font.caption2)
                            .italic()
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                    }
                }
                Text(LanguageStore.shared.t("sub.useReadFirstHint"))
                    .font(AppTheme.Font.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .appContentSurface(cornerRadius: AppTheme.Chat.cardCornerRadius)
            .overlay {
                if isReadFirstDropTargeted {
                    RoundedRectangle(cornerRadius: AppTheme.Chat.cardCornerRadius)
                        .stroke(AppTheme.brandAccent, lineWidth: 2)
                        .background(AppTheme.brandAccent.opacity(0.08), in: RoundedRectangle(cornerRadius: AppTheme.Chat.cardCornerRadius))
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $isReadFirstDropTargeted) { providers in
                // Defer NSItemProvider work off the drop callback so AppKit
                // finishes drag-IPC teardown before loadItem triggers more IPC.
                DispatchQueue.main.async {
                    loadReadFirstDroppedFiles(from: providers)
                }
                return true
            }

            VStack(alignment: .leading, spacing: 8) {
                Label(LanguageStore.shared.t("sub.deckAgentRun"), systemImage: "checkmark.seal")
                    .font(AppTheme.Font.subheadline.weight(.semibold))
                Text("\(AppBrand.displayName) starts and tracks the child session directly, records artifacts under Application Support, and posts a status/result entry back to the parent transcript.")
                    .font(AppTheme.Font.caption)
                    .foregroundStyle(.secondary)
                Picker(LanguageStore.shared.t("sub.expectedOutcomePicker"), selection: $expectedOutcome) {
                    ForEach(PiSubagentExpectedOutcome.allCases) { outcome in
                        Text(outcome.displayName).tag(outcome)
                    }
                }
                .appMenuPicker()
                Toggle(LanguageStore.shared.t("sub.useGitWorktree"), isOn: $useWorktreeIsolation)
                    .font(AppTheme.Font.caption)
                Text(LanguageStore.shared.t("sub.worktreeIsolationHint"))
                    .font(AppTheme.Font.caption2)
                    .foregroundStyle(.secondary)
                if expectedOutcome == .writeProjectFile {
                    AppTextField(text: $requestedOutputPath, placeholder: LanguageStore.shared.t("sub.outputPathHint"))
                    Toggle(LanguageStore.shared.t("sub.allowOverwrite"), isOn: $allowOverwrite)
                        .font(AppTheme.Font.caption)
                }
                Toggle(LanguageStore.shared.t("sub.allowDirectWrites"), isOn: $allowDirectProjectWrites)
                    .font(AppTheme.Font.caption)
                    .disabled(useWorktreeIsolation || expectedOutcome != .directProjectWrites)
                if let outputPolicyError {
                    Label(outputPolicyError, systemImage: "lock.shield")
                        .font(AppTheme.Font.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(10)
            .appContentSurface(cornerRadius: AppTheme.Chat.cardCornerRadius)

            HStack {
                Spacer()
                Button(LanguageStore.shared.t("common.cancel"), action: onCancel)
                    .appSecondaryButton()
                    .keyboardShortcut(.cancelAction)
                Button(LanguageStore.shared.t("sub.run")) {
                    let trimmedOutputPath = requestedOutputPath.trimmingCharacters(in: .whitespacesAndNewlines)
                    onRun(selectedAgentName, task, useWorktreeIsolation, allowDirectProjectWrites, expectedOutcome, trimmedOutputPath.isEmpty ? nil : trimmedOutputPath, allowOverwrite, parsedReadFirstPaths)
                }
                .appPrimaryButton()
                .keyboardShortcut(.defaultAction)
                .disabled(!canRun)
            }
        }
        .padding(22)
        .frame(width: 600)
        .onAppear {
            if selectedAgentName.isEmpty {
                selectedAgentName = agentNames.first ?? ""
                applySelectedAgentDefaultOutcome()
            }
        }
        .onChange(of: useWorktreeIsolation) { _, enabled in
            if enabled { allowDirectProjectWrites = false }
            syncOutcomeSafetyDefaults()
        }
        .onChange(of: expectedOutcome) { _, _ in syncOutcomeSafetyDefaults() }
        .onChange(of: selectedAgentName) { _, _ in applySelectedAgentDefaultOutcome() }
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

    private func applySelectedAgentDefaultOutcome() {
        expectedOutcome = selectedInfo?.defaultExpectedOutcome ?? .reportOnly
        syncOutcomeSafetyDefaults()
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
                .font(AppTheme.Font.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(AppTheme.Font.caption)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}
