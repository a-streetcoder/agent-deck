import AppKit
import SwiftUI

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

    init(diffText: String) {
        self.diffText = diffText
        _lines = State(initialValue: Self.lines(for: diffText))
    }

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
        lines = Self.lines(for: diffText)
    }

    private static func lines(for diffText: String) -> [PiAgentDiffLine] {
        diffText.split(separator: "\n", omittingEmptySubsequences: false).map { PiAgentDiffLine(raw: String($0)) }
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
                    viewModel: viewModel,
                    footerSession: session,
                    transcript: store.selectedTranscript,
                    supportedThinkingLevels: ["off", "minimal", "low", "medium", "high", "xhigh"],
                    metricsSession: session,
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

struct PiAgentSubagentSummary: Hashable {
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

struct PiAgentSubagentTranscriptView: View {
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
