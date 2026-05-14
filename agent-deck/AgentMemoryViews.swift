import SwiftUI

struct MemoryScreen: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var memoryStore: AgentMemoryStore
    @State private var searchText = ""
    @State private var selectedStatus: AgentMemoryStatus?
    @State private var selectedKind: AgentMemoryKind?
    @State private var selectedRecordID: String?
    @State private var isNewMemoryPresented = false

    var body: some View {
        AppPage("Memory", subtitle: "Review project memories used by Agent Deck") {
            overviewCard
            libraryCard
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isNewMemoryPresented = true
                } label: {
                    Label("New Memory", systemImage: "plus")
                }
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(AppTheme.brandAccent)
                .tint(AppTheme.brandAccent)
                .help(viewModel.selectedProjectPath == nil ? "Select a project before creating memory." : "Create a project memory")
                .disabled(viewModel.selectedProjectPath == nil)
            }
        }
        .sheet(isPresented: $isNewMemoryPresented) {
            MemoryEditorSheet(
                title: "New Memory",
                initialTitle: "",
                initialSummary: "",
                initialBody: "",
                initialKind: .context,
                initialTags: "",
                onSave: { title, summary, body, kind, tags in
                    viewModel.createAgentMemory(title: title, summary: summary, body: body, kind: kind, tags: tags)
                }
            )
        }
    }

    private var currentRecords: [AgentMemoryRecord] {
        memoryStore.records(projectPath: viewModel.selectedProjectPath)
    }

    private var filteredRecords: [AgentMemoryRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return currentRecords.filter { record in
            if let selectedStatus, record.status != selectedStatus { return false }
            if let selectedKind, record.kind != selectedKind { return false }
            guard !query.isEmpty else { return true }
            let haystack = ([record.title, record.summary, record.kind.displayName, record.status.displayName, record.scope.displayName, record.filePath] + record.tags)
                .joined(separator: " ")
                .lowercased()
            return haystack.contains(query)
        }
    }

    private var selectedRecord: AgentMemoryRecord? {
        guard let selectedRecordID else { return filteredRecords.first }
        return filteredRecords.first(where: { $0.id == selectedRecordID }) ?? filteredRecords.first
    }

    private var activeCount: Int { currentRecords.filter(\.isInjectable).count }
    private var pinnedCount: Int { currentRecords.filter { $0.status == .pinned }.count }
    private var staleCount: Int { currentRecords.filter { $0.status == .stale }.count }

    private var projectLabel: String {
        viewModel.selectedProjectPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "No project selected"
    }

    private var overviewCard: some View {
        AppCard(title: "Project Memory", trailing: {
            Toggle("Memory", isOn: Binding(
                get: { viewModel.appSettings.agentMemoryEnabled },
                set: { viewModel.setAgentMemoryEnabled($0) }
            ))
            .toggleStyle(.switch)
        }) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Durable project context that agents can recall: architecture notes, decisions, preferences, runbooks, and recurring failures.")
                    .foregroundStyle(AppTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    MemoryOverviewPill(text: viewModel.appSettings.agentMemoryEnabled ? "Enabled" : "Paused", systemImage: SidebarItem.memory.systemImage, color: viewModel.appSettings.agentMemoryEnabled ? .green : .orange)
                    MemoryOverviewPill(text: projectLabel, systemImage: "folder", color: .blue)
                    MemoryOverviewPill(text: "\(activeCount) injectable", systemImage: "bolt.fill", color: AppTheme.brandAccent)
                    MemoryOverviewPill(text: "\(pinnedCount) pinned", systemImage: "pin.fill", color: .purple)
                    if staleCount > 0 {
                        MemoryOverviewPill(text: "\(staleCount) stale", systemImage: "clock.badge.exclamationmark", color: .yellow)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var libraryCard: some View {
        AppCard(title: "Memory Library", trailing: {
            Text("\(filteredRecords.count) of \(currentRecords.count)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.mutedText)
        }) {
            VStack(alignment: .leading, spacing: 14) {
                filterBar

                if currentRecords.isEmpty {
                    ContentUnavailableView("No Memories Yet", systemImage: "brain", description: Text(viewModel.selectedProjectPath == nil ? "Select a project to inspect its memory." : "Create a memory manually or let agents write durable project memories from sessions."))
                        .frame(maxWidth: .infinity, minHeight: 360)
                } else if filteredRecords.isEmpty {
                    ContentUnavailableView("No Matching Memories", systemImage: "line.3.horizontal.decrease.circle", description: Text("Try clearing search or changing the filters."))
                        .frame(maxWidth: .infinity, minHeight: 360)
                } else {
                    HStack(alignment: .top, spacing: 14) {
                        memoryList

                        Divider()

                        if let selectedRecord {
                            MemoryDetailView(record: selectedRecord, memoryStore: memoryStore, viewModel: viewModel)
                                .frame(maxWidth: .infinity, minHeight: 430, alignment: .topLeading)
                        }
                    }
                }
            }
        }
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            TextField("Search memories", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 220)

            Picker("Status", selection: Binding(
                get: { selectedStatus?.rawValue ?? "all" },
                set: { selectedStatus = $0 == "all" ? nil : AgentMemoryStatus(rawValue: $0) }
            )) {
                Text("All Statuses").tag("all")
                ForEach(AgentMemoryStatus.allCases) { status in
                    Text(status.displayName).tag(status.rawValue)
                }
            }
            .labelsHidden()
            .frame(width: 150)

            Picker("Type", selection: Binding(
                get: { selectedKind?.rawValue ?? "all" },
                set: { selectedKind = $0 == "all" ? nil : AgentMemoryKind(rawValue: $0) }
            )) {
                Text("All Types").tag("all")
                ForEach(AgentMemoryKind.allCases) { kind in
                    Text(kind.displayName).tag(kind.rawValue)
                }
            }
            .labelsHidden()
            .frame(width: 170)

            Button("Clear") {
                searchText = ""
                selectedStatus = nil
                selectedKind = nil
            }
            .disabled(searchText.isEmpty && selectedStatus == nil && selectedKind == nil)
        }
    }

    private var memoryList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(filteredRecords) { record in
                    MemoryRecordRow(record: record, isSelected: record.id == selectedRecord?.id) {
                        selectedRecordID = record.id
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .frame(minWidth: 310, idealWidth: 360, maxWidth: 440, minHeight: 430)
    }
}

private struct MemoryOverviewPill: View {
    let text: String
    let systemImage: String
    let color: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(color.opacity(0.12), in: Capsule(style: .continuous))
    }
}

private struct MemoryRecordRow: View {
    let record: AgentMemoryRecord
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: record.kind.systemImage)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(record.status.tint)
                    .frame(width: 30, height: 30)
                    .background(record.status.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(record.title.isEmpty ? "Untitled Memory" : record.title)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        MemoryStatusBadge(status: record.status)
                    }

                    Text(record.summary.isEmpty ? "No summary provided." : record.summary)
                        .font(.callout)
                        .foregroundStyle(AppTheme.mutedText)
                        .lineLimit(2)

                    HStack(spacing: 6) {
                        Label(record.kind.displayName, systemImage: record.kind.systemImage)
                        Label(record.scope.displayName, systemImage: record.scope.systemImage)
                        if record.useCount > 0 {
                            Label("\(record.useCount)x", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)
                    .lineLimit(1)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .appContentSurface(cornerRadius: 12, isSelected: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(record.title.isEmpty ? "Untitled Memory" : record.title)
    }
}

private struct MemoryDetailView: View {
    let record: AgentMemoryRecord
    @ObservedObject var memoryStore: AgentMemoryStore
    @ObservedObject var viewModel: AppViewModel
    @State private var isEditing = false

    var body: some View {
        let document = memoryStore.document(for: record)
        VStack(alignment: .leading, spacing: 16) {
            header(document: document)

            HStack(alignment: .top, spacing: 12) {
                MemoryInfoPanel(record: record)
                    .frame(width: 220)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Memory Body")
                        .font(.headline)
                        .fontWidth(.expanded)
                    ScrollView {
                        MarkdownTextView(source: document.body.isEmpty ? "_No body._" : document.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(12)
                    }
                    .frame(minHeight: 250)
                    .appContentSurface(cornerRadius: 12)
                }
            }
        }
        .sheet(isPresented: $isEditing) {
            MemoryEditorSheet(
                title: "Edit Memory",
                initialTitle: record.title,
                initialSummary: record.summary,
                initialBody: document.body,
                initialKind: record.kind,
                initialTags: record.tags.joined(separator: ", "),
                onSave: { title, summary, body, kind, tags in
                    _ = kind
                    viewModel.updateAgentMemory(id: record.id, title: title, summary: summary, body: body, tags: tags)
                }
            )
        }
    }

    private func header(document: AgentMemoryDocument) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: record.kind.systemImage)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(record.status.tint)
                    .frame(width: 44, height: 44)
                    .background(record.status.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(record.title.isEmpty ? "Untitled Memory" : record.title)
                            .font(.title3.weight(.bold))
                            .fontWidth(.expanded)
                            .lineLimit(2)
                        MemoryStatusBadge(status: record.status)
                    }
                    Text(record.summary.isEmpty ? "No summary provided." : record.summary)
                        .foregroundStyle(AppTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Menu {
                    Button("Mark Active") { viewModel.setAgentMemoryStatus(record.id, status: .active) }
                    Button("Pin") { viewModel.setAgentMemoryStatus(record.id, status: .pinned) }
                    Button("Mark Stale") { viewModel.setAgentMemoryStatus(record.id, status: .stale) }
                    Button("Archive") { viewModel.setAgentMemoryStatus(record.id, status: .archived) }
                    Divider()
                    Button("Delete", role: .destructive) { viewModel.deleteAgentMemory(record.id) }
                } label: {
                    Label("Actions", systemImage: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)

                Button("Edit") { isEditing = true }
                    .buttonStyle(AppSecondaryButtonStyle())
            }

            if !record.tags.isEmpty {
                FlowTagRow(tags: record.tags)
            }
        }
        .padding(14)
        .appContentSurface(cornerRadius: 14)
    }
}

private struct MemoryInfoPanel: View {
    let record: AgentMemoryRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Details")
                .font(.headline)
                .fontWidth(.expanded)

            AppKeyValueList(rows: rows)

            AppCopyTextButton(title: "Copy Path", text: record.filePath)
                .controlSize(.small)
        }
        .padding(12)
        .appContentSurface(cornerRadius: 12)
    }

    private var rows: [(String, String)] {
        var rows: [(String, String)] = [
            ("Type", record.kind.displayName),
            ("Status", record.status.displayName),
            ("Scope", record.scope.displayName),
            ("Created", record.createdAt.formatted(date: .abbreviated, time: .shortened)),
            ("Updated", record.updatedAt.formatted(date: .abbreviated, time: .shortened)),
            ("Used", record.useCount == 0 ? "Never" : "\(record.useCount) time\(record.useCount == 1 ? "" : "s")")
        ]
        if let lastUsedAt = record.lastUsedAt {
            rows.append(("Last Used", lastUsedAt.formatted(date: .abbreviated, time: .shortened)))
        }
        if let sourceAgentName = record.sourceAgentName, !sourceAgentName.isEmpty {
            rows.append(("Source", sourceAgentName))
        }
        rows.append(("Path", record.filePath))
        return rows
    }
}

private struct MemoryStatusBadge: View {
    let status: AgentMemoryStatus

    var body: some View {
        Label(status.displayName, systemImage: status.systemImage)
            .font(.caption2.weight(.bold))
            .fontWidth(.expanded)
            .foregroundStyle(status.tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(status.tint.opacity(0.12), in: Capsule(style: .continuous))
    }
}

private struct FlowTagRow: View {
    let tags: [String]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppTheme.mutedText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(AppTheme.contentSubtleFill, in: Capsule(style: .continuous))
            }
        }
    }
}

private struct MemoryEditorSheet: View {
    let title: String
    let initialTitle: String
    let initialSummary: String
    let initialBody: String
    let initialKind: AgentMemoryKind
    let initialTags: String
    let onSave: (String, String, String, AgentMemoryKind, [String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var memoryTitle: String
    @State private var summary: String
    @State private var bodyText: String
    @State private var kind: AgentMemoryKind
    @State private var tags: String

    init(title: String, initialTitle: String, initialSummary: String, initialBody: String, initialKind: AgentMemoryKind, initialTags: String, onSave: @escaping (String, String, String, AgentMemoryKind, [String]) -> Void) {
        self.title = title
        self.initialTitle = initialTitle
        self.initialSummary = initialSummary
        self.initialBody = initialBody
        self.initialKind = initialKind
        self.initialTags = initialTags
        self.onSave = onSave
        _memoryTitle = State(initialValue: initialTitle)
        _summary = State(initialValue: initialSummary)
        _bodyText = State(initialValue: initialBody)
        _kind = State(initialValue: initialKind)
        _tags = State(initialValue: initialTags)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.title2.weight(.bold))
                    .fontWidth(.expanded)
                Text("Give agents concise, reusable context. Good memories are specific, durable, and easy to verify.")
                    .foregroundStyle(AppTheme.mutedText)
            }

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow {
                    Text("Title").foregroundStyle(AppTheme.mutedText)
                    TextField("Short descriptive title", text: $memoryTitle)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Summary").foregroundStyle(AppTheme.mutedText)
                    TextField("One sentence agents can scan", text: $summary)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Type").foregroundStyle(AppTheme.mutedText)
                    Picker("Type", selection: $kind) {
                        ForEach(AgentMemoryKind.allCases) { kind in
                            Label(kind.displayName, systemImage: kind.systemImage).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 260)
                }
                GridRow {
                    Text("Tags").foregroundStyle(AppTheme.mutedText)
                    TextField("Comma-separated tags", text: $tags)
                        .textFieldStyle(.roundedBorder)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Body")
                    .font(.headline)
                    .fontWidth(.expanded)
                TextEditor(text: $bodyText)
                    .font(.body.monospaced())
                    .frame(minHeight: 250)
                    .padding(6)
                    .appContentSurface(cornerRadius: 10)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    onSave(memoryTitle.trimmedForMemory, summary.trimmedForMemory, bodyText, kind, parsedTags)
                    dismiss()
                }
                .buttonStyle(AppPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(memoryTitle.trimmedForMemory.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 720, height: 600)
    }

    private var parsedTags: [String] {
        tags.split(separator: ",")
            .map { String($0).trimmedForMemory }
            .filter { !$0.isEmpty }
    }
}

struct PiAgentMemoryActivityCard: View {
    let event: AgentMemoryTranscriptEvent

    var body: some View {
        AppRowCard {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: event.event.systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(event.event == .blocked ? .red : AppTheme.brandAccent)
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(event.title)
                            .font(.headline)
                        if let scope = event.scope {
                            Text(scope.displayName)
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(AppTheme.mutedText)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule(style: .continuous).fill(AppTheme.contentSubtleFill))
                        }
                    }
                    Text(event.summary)
                        .foregroundStyle(AppTheme.mutedText)
                    if !event.memoryIDs.isEmpty {
                        Text("\(event.memoryIDs.count) memor\(event.memoryIDs.count == 1 ? "y" : "ies")")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(AppTheme.mutedText)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

private extension AgentMemoryKind {
    var systemImage: String {
        switch self {
        case .context: return "doc.text.magnifyingglass"
        case .decision: return "checkmark.seal"
        case .runbook: return "list.bullet.rectangle"
        case .failure: return "exclamationmark.triangle"
        case .preference: return "slider.horizontal.3"
        }
    }
}

private extension AgentMemoryScope {
    var systemImage: String {
        switch self {
        case .project: return "folder"
        }
    }
}

private extension AgentMemoryStatus {
    var tint: Color {
        switch self {
        case .active: return .green
        case .pinned: return AppTheme.brandAccent
        case .stale: return .yellow
        case .archived: return .secondary
        }
    }

    var systemImage: String {
        switch self {
        case .active: return "checkmark.circle.fill"
        case .pinned: return "pin.fill"
        case .stale: return "clock.badge.exclamationmark"
        case .archived: return "archivebox.fill"
        }
    }
}

private extension String {
    var trimmedForMemory: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
