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
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(AppTheme.textContentFill))
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
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(AppTheme.textContentFill))
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
