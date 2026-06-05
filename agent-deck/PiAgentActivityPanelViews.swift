import AppKit
import Combine
import SwiftUI

/// Shared `JSONDecoder` for view-layer payload decoding. Reused so SwiftUI
/// computed properties don't allocate a fresh decoder on every `body` eval.
private let activityPanelJSONDecoder = JSONDecoder()

struct PiAgentActivityPanel: View {
    var store: PiAgentSessionStore
    @Binding var isPresented: Bool
    @StateObject private var activityCache = PiAgentActivityCache()
    @State private var filter: PiAgentActivityFilter = .files
    @State private var selectedID: UUID?

    private var items: [PiAgentActivityItem] {
        activityCache.items(for: filter)
    }

    private var selectedItem: PiAgentActivityItem? {
        if let selectedID, let item = items.first(where: { $0.id == selectedID }) { return item }
        return nil
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
                        filterBar
                        if items.isEmpty {
                            compactEmptyState(title: "No activity", message: filter.emptyMessage, icon: filter.emptyIcon)
                        } else {
                            ScrollView(showsIndicators: false) {
                                LazyVStack(alignment: .leading, spacing: 10) {
                                    ForEach(items) { item in
                                        PiAgentActivityRow(
                                            item: item,
                                            isSelected: selectedID == item.id,
                                            rootPath: item.rootPath ?? selectedRootPath,
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
        .onAppear {
            requestSelectedSubagentTranscriptLoadsAfterViewUpdate()
            Task { @MainActor in
                await Task.yield()
                rebuildActivityCache()
            }
        }
        .onChange(of: store.selectedSession?.id) { _, _ in
            selectedID = nil
            requestSelectedSubagentTranscriptLoadsAfterViewUpdate()
            Task { @MainActor in
                await Task.yield()
                rebuildActivityCache()
            }
        }
        .onChange(of: store.selectedTranscriptRevision) { _, _ in
            Task { @MainActor in
                await Task.yield()
                rebuildActivityCache()
            }
        }
        .onChange(of: store.subagentRunsBySessionID) { _, _ in
            requestSelectedSubagentTranscriptLoadsAfterViewUpdate()
            Task { @MainActor in
                await Task.yield()
                rebuildActivityCache()
            }
        }
        .onChange(of: store.subagentTranscriptsByRunID) { _, _ in
            Task { @MainActor in
                await Task.yield()
                rebuildActivityCache()
            }
        }
        .onReceive(activityCache.$changes) { changes in
            let diffs = changes.compactMap(\.diff)
            Task { await piAgentDiffRenderCache.prewarm(diffs) }
        }
        .onReceive(activityCache.$visibleIDsByFilter) { visibleIDsByFilter in
            guard let selectedID, !visibleIDsByFilter[filter, default: []].contains(selectedID) else { return }
            self.selectedID = nil
        }
    }

    private var activityHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "wrench.and.screwdriver")
                .font(AppTheme.Font.body.weight(.semibold))
                .foregroundStyle(AppTheme.mutedText)
                .frame(width: 28, height: 28)
                .background(Circle().fill(AppTheme.contentFill).stroke(AppTheme.contentStroke, lineWidth: 1))
            VStack(alignment: .leading, spacing: 2) {
                Text("Activity")
                    .font(AppTheme.Font.headline.weight(.semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(AppTheme.Font.caption)
                        .foregroundStyle(AppTheme.mutedText)
                }
            }
            Spacer(minLength: 0)
            Button {
                isPresented = false
            } label: {
                Image(systemName: "xmark")
                    .font(AppTheme.Font.footnote.weight(.semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppTheme.mutedText)
            .help("Close activity panel")
            .accessibilityLabel("Close activity panel")
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

    private var selectedSubagentRuns: [PiSubagentRunRecord] {
        guard let session = store.selectedSession else { return [] }
        return store.subagentRuns(for: session.id)
    }

    private var selectedSubagentTranscripts: [UUID: [PiAgentTranscriptEntry]] {
        Dictionary(uniqueKeysWithValues: selectedSubagentRuns.map { run in
            (run.id, store.cachedSubagentTranscript(for: run.id))
        })
    }

    private func rebuildActivityCache() {
        activityCache.rebuild(
            sessionID: store.selectedSession?.id,
            parentEntries: store.selectedTranscript,
            subagentRuns: selectedSubagentRuns,
            subagentTranscripts: selectedSubagentTranscripts
        )
    }

    private func requestSelectedSubagentTranscriptLoadsAfterViewUpdate() {
        let runIDs = selectedSubagentRuns.map(\.id)
        guard !runIDs.isEmpty else { return }
        Task { @MainActor in
            await Task.yield()
            for runID in runIDs {
                store.requestSubagentTranscriptLoad(for: runID)
            }
        }
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
        // The activity panel is for current work. Completed subagents already
        // have transcript cards, so repeating them here makes the UI noisy.
        Array(store.subagentRuns(for: sessionID).filter(\.status.isActive).prefix(4))
    }

    private var filterBar: some View {
        Picker("Activity filter", selection: $filter) {
            ForEach(PiAgentActivityFilter.allCases) { filter in
                Text(filter.label).tag(filter)
            }
        }
        .appSegmentedPicker()
        .labelsHidden()
    }

    private func compactEmptyState(title: String, message: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(AppTheme.Font.title.weight(.semibold))
                .foregroundStyle(AppTheme.mutedText)
            Text(title)
                .font(AppTheme.Font.headline.weight(.semibold))
            Text(message)
                .font(AppTheme.Font.callout)
                .foregroundStyle(AppTheme.mutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: AppTheme.Chat.panelCornerRadius, style: .continuous).fill(AppTheme.contentFill).stroke(AppTheme.contentStroke, lineWidth: 1))
    }
}

struct PiAgentCurrentPlanCard: View {
    let title: String
    let subtitle: String
    let isSubtitleIdentifier: Bool
    let items: [PiSessionPlanItemRecord]
    /// When false, the card drops its own rounded surface so it can sit directly
    /// inside another container (e.g. a popover) without a card-in-card look.
    let showsSurface: Bool

    init(plan: PiSessionPlanRecord, showsSurface: Bool = true) {
        self.title = "Current plan"
        self.subtitle = String(plan.id.uuidString.prefix(8))
        self.isSubtitleIdentifier = true
        self.items = plan.items
        self.showsSurface = showsSurface
    }

    var body: some View {
        if showsSurface {
            content
                .padding(12)
                .appContentSurface(cornerRadius: AppTheme.Chat.panelCornerRadius)
        } else {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: "checklist")
                    .font(AppTheme.Font.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.brandAccent)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(AppTheme.brandAccent.opacity(0.13)))
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title)
                        .font(AppTheme.Font.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(isSubtitleIdentifier ? AppTheme.Font.code.weight(.medium) : AppTheme.Font.caption2.weight(.medium))
                        .foregroundStyle(AppTheme.mutedText)
                        .padding(.horizontal, isSubtitleIdentifier ? 5 : 0)
                        .padding(.vertical, isSubtitleIdentifier ? 2 : 0)
                        .background {
                            if isSubtitleIdentifier {
                                Capsule(style: .continuous)
                                    .fill(AppTheme.contentSubtleFill.opacity(0.72))
                            }
                        }
                }
                Spacer(minLength: 0)
                progressBadge
            }

            if items.isEmpty {
                Text("No active plan items")
                    .font(AppTheme.Font.callout)
                    .foregroundStyle(AppTheme.mutedText)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider().opacity(0.45).padding(.leading, 30) }
                    HStack(alignment: .center, spacing: 9) {
                        ZStack {
                            Circle()
                                .fill(color(for: item.status).opacity(item.status == .todo ? 0.08 : 0.14))
                                .frame(width: 20, height: 20)
                            Image(systemName: icon(for: item.status))
                                .font(AppTheme.Font.caption2.weight(.bold))
                                .foregroundStyle(color(for: item.status))
                        }
                        Text(item.title)
                            .font(AppTheme.Font.callout)
                            .foregroundStyle(item.status == .done || item.status == .skipped ? AppTheme.mutedText : .primary)
                            .strikethrough(item.status == .done || item.status == .skipped, color: AppTheme.mutedText)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                        .padding(.vertical, 7)
                    }
                }
            }
        }
    }

    /// A small progress ring + count. Neutral chrome (not tinted) so it reads as
    /// quiet text on the glass and stays legible against any background. The ring
    /// fills and the count morphs with a numeric transition as items complete.
    private var progressBadge: some View {
        HStack(spacing: 5) {
            ZStack {
                Circle()
                    .stroke(AppTheme.mutedText.opacity(0.3), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: progressFraction)
                    .stroke(AppTheme.mutedText, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 13, height: 13)
            Text(progressText)
                .font(AppTheme.Font.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(AppTheme.mutedText)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        // Untinted native glass to match the other popovers.
        .glassEffect(.regular, in: Capsule(style: .continuous))
        .animation(.snappy(duration: 0.3), value: progressFraction)
    }

    private var doneCount: Int {
        items.count(where: { $0.status == .done || $0.status == .skipped })
    }

    private var progressText: String {
        "\(doneCount)/\(items.count)"
    }

    private var progressFraction: Double {
        items.isEmpty ? 0 : Double(doneCount) / Double(items.count)
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
        case .inProgress: return AppTheme.brandAccent
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
                Image(systemName: "paperplane")
                    .foregroundStyle(AppTheme.mutedText)
                Text("Deck Agents")
                    .font(AppTheme.Font.caption.weight(.semibold))
                Spacer(minLength: 0)
                Text("\(runs.count)")
                    .font(AppTheme.Font.caption2.monospacedDigit())
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
        .background(RoundedRectangle(cornerRadius: AppTheme.Chat.cardCornerRadius, style: .continuous).fill(AppTheme.contentSubtleFill.opacity(0.82)).stroke(AppTheme.contentStroke, lineWidth: 1))
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
                    .font(AppTheme.Font.caption.weight(.semibold))
                    .lineLimit(1)
                PiSubagentStatusText(status: run.status, color: color(for: run.status), font: .caption2.weight(.semibold))
                Spacer(minLength: 0)
                if run.isWorktreeIsolated == true {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(AppTheme.Font.caption2)
                        .foregroundStyle(AppTheme.mutedText)
                        .help("Isolated worktree")
                }
            }
            Text(run.task)
                .font(AppTheme.Font.caption2)
                .foregroundStyle(AppTheme.mutedText)
                .lineLimit(2)
            if let children = run.children, !children.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(children.prefix(4)) { child in
                        HStack(spacing: 5) {
                            Circle().fill(color(for: child.status)).frame(width: 5, height: 5)
                            Text("\(child.index + 1). \(child.agentName)")
                                .font(AppTheme.Font.caption2.weight(.semibold))
                                .lineLimit(1)
                            PiSubagentStatusText(status: child.status, color: color(for: child.status), font: .caption2)
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

@MainActor
private final class PiAgentActivityCache: ObservableObject {
    @Published private(set) var changes: [PiAgentActivityItem] = []
    @Published private(set) var web: [PiAgentActivityItem] = []
    @Published private(set) var errors: [PiAgentActivityItem] = []
    @Published private(set) var visibleIDsByFilter: [PiAgentActivityFilter: Set<UUID>] = [:]

    private var signature = ""
    private var parsedItemsByEntryID: [UUID: PiAgentActivityItem] = [:]
    private let visibleLimit = 80

    func items(for filter: PiAgentActivityFilter) -> [PiAgentActivityItem] {
        switch filter {
        case .files: return changes
        case .web: return web
        case .errors: return errors
        }
    }

    func rebuild(sessionID: UUID?, parentEntries: [PiAgentTranscriptEntry], subagentRuns: [PiSubagentRunRecord], subagentTranscripts: [UUID: [PiAgentTranscriptEntry]]) {
        let nextSignature = Self.signature(sessionID: sessionID, parentEntries: parentEntries, subagentRuns: subagentRuns, subagentTranscripts: subagentTranscripts)
        guard nextSignature != signature else { return }
        signature = nextSignature

        guard sessionID != nil else {
            parsedItemsByEntryID = [:]
            publish(changes: [], web: [], errors: [])
            return
        }

        let allEntries: [(entry: PiAgentTranscriptEntry, sourceName: String?, rootPath: String?)] =
            parentEntries.map { ($0, nil, nil) } +
            subagentRuns.flatMap { run in
                let rootPath = run.worktreePath ?? run.parentRepoPath
                return (subagentTranscripts[run.id] ?? []).map { ($0, run.agentName, rootPath) }
            }

        let liveEntryIDs = Set(allEntries.map(\.entry.id))
        parsedItemsByEntryID = parsedItemsByEntryID.filter { liveEntryIDs.contains($0.key) }

        var nextChanges: [PiAgentActivityItem] = []
        var nextWeb: [PiAgentActivityItem] = []
        var nextErrors: [PiAgentActivityItem] = []

        for source in allEntries {
            let item: PiAgentActivityItem?
            if let cached = parsedItemsByEntryID[source.entry.id], cached.entry.rawJSON == source.entry.rawJSON, cached.entry.text == source.entry.text {
                item = cached
            } else {
                item = PiAgentActivityItem(entry: source.entry, sourceName: source.sourceName, rootPath: source.rootPath)
                if let item {
                    parsedItemsByEntryID[source.entry.id] = item
                }
            }
            guard let item else { continue }
            if item.kind.isFileMutation { nextChanges.append(item) }
            if item.kind.isWebActivity { nextWeb.append(item) }
            if item.status == .failed { nextErrors.append(item) }
        }

        let newestFirst: (PiAgentActivityItem, PiAgentActivityItem) -> Bool = { $0.entry.timestamp > $1.entry.timestamp }
        publish(
            changes: Array(nextChanges.sorted(by: newestFirst).prefix(visibleLimit)),
            web: Array(nextWeb.sorted(by: newestFirst).prefix(visibleLimit)),
            errors: Array(nextErrors.sorted(by: newestFirst).prefix(visibleLimit))
        )
    }

    private func publish(changes: [PiAgentActivityItem], web: [PiAgentActivityItem], errors: [PiAgentActivityItem]) {
        self.changes = changes
        self.web = web
        self.errors = errors
        visibleIDsByFilter = [
            .files: Set(changes.map(\.id)),
            .web: Set(web.map(\.id)),
            .errors: Set(errors.map(\.id))
        ]
    }

    private static func signature(sessionID: UUID?, parentEntries: [PiAgentTranscriptEntry], subagentRuns: [PiSubagentRunRecord], subagentTranscripts: [UUID: [PiAgentTranscriptEntry]]) -> String {
        let parentTail = parentEntries.last.map { "\($0.id.uuidString):\($0.text.count):\($0.rawJSON?.count ?? 0)" } ?? "none"
        let runTail = subagentRuns.map { "\($0.id.uuidString):\($0.status.rawValue):\($0.updatedAt.timeIntervalSince1970)" }.joined(separator: "|")
        let childTail = subagentTranscripts
            .sorted { $0.key.uuidString < $1.key.uuidString }
            .map { runID, entries in
                let last = entries.last.map { "\($0.id.uuidString):\($0.text.count):\($0.rawJSON?.count ?? 0)" } ?? "none"
                return "\(runID.uuidString):\(entries.count):\(last)"
            }
            .joined(separator: "|")
        return "\(sessionID?.uuidString ?? "none")#p\(parentEntries.count):\(parentTail)#r\(subagentRuns.count):\(runTail)#c\(childTail)"
    }
}

private enum PiAgentActivityFilter: String, CaseIterable, Identifiable {
    case files
    case web
    case errors

    var id: String { rawValue }

    var label: String {
        switch self {
        case .files: return "Changes"
        case .web: return "Web"
        case .errors: return "Errors"
        }
    }

    var emptyMessage: String {
        switch self {
        case .files: return "File changes will appear here."
        case .web: return "Web activity will appear here."
        case .errors: return "Tool failures will appear here."
        }
    }

    var emptyIcon: String {
        switch self {
        case .files: return "doc.text.magnifyingglass"
        case .web: return "globe"
        case .errors: return "exclamationmark.triangle"
        }
    }

    func includes(_ item: PiAgentActivityItem) -> Bool {
        switch self {
        case .files: return item.kind.isFileMutation
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
        case .subagent: return "Deck agent"
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
    let sourceName: String?
    let rootPath: String?
    let kind: PiAgentActivityKind
    let status: PiAgentActivityStatus
    let toolName: String
    let path: String?
    let command: String?
    let contentPreview: String?
    let diff: String?
    let detailText: String

    @MainActor
    static func items(parentEntries: [PiAgentTranscriptEntry], subagentRuns: [PiSubagentRunRecord], subagentTranscripts: [UUID: [PiAgentTranscriptEntry]]) -> [PiAgentActivityItem] {
        let parentItems = parentEntries.compactMap { PiAgentActivityItem(entry: $0, sourceName: nil, rootPath: nil) }
        let childItems = subagentRuns.flatMap { run in
            let rootPath = run.worktreePath ?? run.parentRepoPath
            return (subagentTranscripts[run.id] ?? []).compactMap { entry in
                PiAgentActivityItem(entry: entry, sourceName: run.agentName, rootPath: rootPath)
            }
        }
        return (parentItems + childItems).sorted { $0.entry.timestamp > $1.entry.timestamp }
    }

    init?(entry: PiAgentTranscriptEntry, sourceName: String?, rootPath: String?) {
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
        } else if ["web_search", "fetch_content", "get_search_content", "web_fetch"].contains(lower) {
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
        self.sourceName = sourceName
        self.rootPath = rootPath
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
        let prefix = sourceName.map { "\($0) · " } ?? ""
        switch kind {
        case .edit:
            return prefix + (diff == nil ? "edit · \(status.label)" : "edit diff · \(status.label)")
        case .write:
            return prefix + (contentPreview == nil ? "write · \(status.label)" : "write preview · \(status.label)")
        case .read:
            return "\(prefix)file read · \(status.label)"
        case .bash:
            return "\(prefix)shell · \(status.label)"
        case .web:
            return "\(prefix)web · \(status.label)"
        case .subagent:
            return "\(prefix)Deck agent delegation · \(status.label)"
        case .supervisor:
            return "\(prefix)routing · \(status.label)"
        case .tool:
            return "\(prefix)\(toolName) · \(status.label)"
        case .error:
            return "\(prefix)error"
        }
    }

    private static func event(from rawJSON: String?) -> PiAgentRPCEvent? {
        guard let rawJSON, let data = rawJSON.data(using: .utf8) else { return nil }
        return try? activityPanelJSONDecoder.decode(PiAgentRPCEvent.self, from: data)
    }

    private static let pathTextRegexes = [#"in ([^\n]+)$"#, #"to ([^\n]+)$"#, #"from ([^\n]+)$"#]
        .compactMap { try? NSRegularExpression(pattern: $0) }

    private static func pathFromText(_ text: String) -> String? {
        for regex in pathTextRegexes {
            guard let match = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
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
                        .font(AppTheme.Font.caption.weight(.semibold))
                        .foregroundStyle(item.status == .failed ? .red : AppTheme.mutedText)
                        .frame(width: 18, height: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(item.title)
                                .font(AppTheme.Font.caption.weight(.semibold))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                            Text(item.entry.timestamp.formatted(date: .omitted, time: .shortened))
                                .font(AppTheme.Font.caption2.monospacedDigit())
                                .foregroundStyle(AppTheme.mutedText)
                        }
                        HStack(spacing: 6) {
                            Text(item.subtitle)
                                .font(AppTheme.Font.caption2)
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
        .background(RoundedRectangle(cornerRadius: AppTheme.Chat.cardCornerRadius, style: .continuous).fill(isSelected ? AppTheme.selectionFill : AppTheme.contentSubtleFill.opacity(0.55)).stroke(isSelected ? AppTheme.selectionStroke : AppTheme.contentStroke, lineWidth: 1))
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
            case .subagent:
                quietNote("Deck agent details are shown in the inline Deck agent card. Open Transcript there for the full child run.")
            default:
                quietNote(item.detailText)
            }
        }
    }

    private func fileActions(path: String) -> some View {
        HStack(spacing: 8) {
            Text(path)
                .font(AppTheme.Font.caption2.monospaced())
                .foregroundStyle(AppTheme.mutedText)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Button("Open") { if let url = resolvedURL(for: path) { NSWorkspace.shared.open(url) } }
                .font(AppTheme.Font.caption.weight(.semibold))
                .buttonStyle(.plain)
                .disabled(resolvedURL(for: path) == nil)
            Button("Reveal") { if let url = resolvedURL(for: path) { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
                .font(AppTheme.Font.caption.weight(.semibold))
                .buttonStyle(.plain)
                .disabled(resolvedURL(for: path) == nil)
            if let diff = item.diff {
                AppCopyTextButton(title: "Copy Diff", text: diff)
                    .font(AppTheme.Font.caption.weight(.semibold))
                    .buttonStyle(.plain)
            }
        }
    }

    private func quietNote(_ text: String) -> some View {
        Text(text)
            .font(AppTheme.Font.caption)
            .foregroundStyle(AppTheme.mutedText)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(9)
            .background(RoundedRectangle(cornerRadius: AppTheme.Chat.subCardCornerRadius, style: .continuous).fill(AppTheme.contentSubtleFill.opacity(0.6)))
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
                .font(AppTheme.Font.caption)
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

    init(title: String?, text: String, maxHeight: CGFloat = 240, lineLimit: Int = 80) {
        self.title = title
        self.text = text
        self.maxHeight = maxHeight
        self.lineLimit = lineLimit
        _cachedDisplayText = State(initialValue: Self.displayText(for: text, lineLimit: lineLimit))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(AppTheme.Font.caption2.weight(.semibold))
                    .foregroundStyle(AppTheme.mutedText)
            }
            ScrollView([.horizontal, .vertical], showsIndicators: false) {
                Text(cachedDisplayText.isEmpty ? displayText : cachedDisplayText)
                    .font(AppTheme.Font.code)
                    .foregroundStyle(.primary.opacity(0.82))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(9)
            }
            .frame(maxHeight: maxHeight)
            .background(RoundedRectangle(cornerRadius: AppTheme.Chat.subCardCornerRadius, style: .continuous).fill(AppTheme.textContentFill))
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

private let piAgentDiffRenderCache = PiAgentDiffRenderCache()

private actor PiAgentDiffRenderCache {
    private var cache: [String: PiAgentRenderedDiff] = [:]
    private var cacheOrder: [String] = []
    private let maxRenderedLines = 500
    private let prewarmLimit = 20
    private let cacheLimit = 64

    func prewarm(_ diffTexts: [String]) async {
        for diffText in diffTexts.prefix(prewarmLimit) {
            guard cache[diffText] == nil else { continue }
            store(Self.render(diffText, maxRenderedLines: maxRenderedLines), for: diffText)
            if Task.isCancelled { return }
        }
    }

    func renderedDiff(for diffText: String) async -> PiAgentRenderedDiff {
        if let cached = cache[diffText] {
            markUsed(diffText)
            return cached
        }
        let rendered = Self.render(diffText, maxRenderedLines: maxRenderedLines)
        store(rendered, for: diffText)
        return rendered
    }

    private func store(_ rendered: PiAgentRenderedDiff, for diffText: String) {
        cache[diffText] = rendered
        markUsed(diffText)
        while cacheOrder.count > cacheLimit, let oldest = cacheOrder.first {
            cacheOrder.removeFirst()
            cache[oldest] = nil
        }
    }

    private func markUsed(_ diffText: String) {
        cacheOrder.removeAll { $0 == diffText }
        cacheOrder.append(diffText)
    }

    private static func render(_ diffText: String, maxRenderedLines: Int) -> PiAgentRenderedDiff {
        let rawLines = diffText.split(separator: "\n", omittingEmptySubsequences: false)
        let lines = rawLines.prefix(maxRenderedLines).map { PiAgentDiffLine(raw: String($0)) }
        return PiAgentRenderedDiff(lines: lines, omittedLineCount: max(rawLines.count - maxRenderedLines, 0))
    }
}

private nonisolated struct PiAgentRenderedDiff: Sendable, Hashable {
    let lines: [PiAgentDiffLine]
    let omittedLineCount: Int
}

private struct PiAgentDiffView: View {
    let diffText: String
    @State private var lines: [PiAgentDiffLine] = []
    @State private var omittedLineCount = 0
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Diff")
                .font(AppTheme.Font.caption2.weight(.semibold))
                .foregroundStyle(AppTheme.mutedText)
            ScrollView([.horizontal, .vertical], showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if isLoading && lines.isEmpty {
                        HStack(spacing: 8) {
                            AppSpinner()
                                .controlSize(.small)
                            Text("Preparing diff...")
                                .font(AppTheme.Font.code)
                                .foregroundStyle(AppTheme.mutedText)
                        }
                        .frame(minWidth: 620, alignment: .leading)
                        .padding(8)
                    } else {
                        ForEach(lines.indices, id: \.self) { index in
                            let line = lines[index]
                            HStack(alignment: .top, spacing: 8) {
                                Text(line.gutter)
                                    .font(AppTheme.Font.code)
                                    .foregroundStyle(line.gutterColor)
                                    .frame(width: 52, alignment: .trailing)
                                Text(line.content.isEmpty ? " " : line.content)
                                    .font(AppTheme.Font.code)
                                    .foregroundStyle(line.textColor)
                                    .textSelection(.enabled)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .frame(minWidth: 620, alignment: .leading)
                            .background(line.background)
                        }
                        if omittedLineCount > 0 {
                            Text("... \(omittedLineCount) more diff lines hidden for performance. Use Copy Diff for the full diff.")
                                .font(AppTheme.Font.code)
                                .foregroundStyle(AppTheme.mutedText)
                                .padding(8)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 320)
            .background(RoundedRectangle(cornerRadius: AppTheme.Chat.subCardCornerRadius, style: .continuous).fill(AppTheme.textContentFill))
        }
        .task(id: diffText) {
            isLoading = true
            let rendered = await piAgentDiffRenderCache.renderedDiff(for: diffText)
            guard !Task.isCancelled else { return }
            lines = rendered.lines
            omittedLineCount = rendered.omittedLineCount
            isLoading = false
        }
    }
}

private nonisolated struct PiAgentDiffLine: Hashable, Sendable {
    let prefix: String
    let lineNumber: String
    let content: String

    init(raw: String) {
        guard let first = raw.first, first == "+" || first == "-" || first == " " else {
            prefix = " "
            lineNumber = ""
            content = raw.replacingOccurrences(of: "\t", with: "   ")
            return
        }

        prefix = String(first)
        let remainder = raw.dropFirst()
        let trimmedLeading = remainder.drop(while: { $0 == " " })
        let numberPart = trimmedLeading.prefix(while: { $0.isNumber })
        if numberPart.isEmpty {
            lineNumber = ""
            content = String(remainder.drop(while: { $0 == " " })).replacingOccurrences(of: "\t", with: "   ")
        } else {
            lineNumber = String(numberPart)
            let afterNumber = trimmedLeading.dropFirst(numberPart.count)
            content = String(afterNumber.drop(while: { $0 == " " })).replacingOccurrences(of: "\t", with: "   ")
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
        default: return .secondary
        }
    }

    var gutterColor: Color { textColor.opacity(prefix == " " ? 0.75 : 1) }
}
