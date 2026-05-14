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
        AppPage("Memory", subtitle: "Review project and global memories used by Agent Deck") {
            overviewCard
            controlsCard
            contentCard
        }
        .sheet(isPresented: $isNewMemoryPresented) {
            MemoryEditorSheet(
                title: "New Memory",
                initialTitle: "",
                initialSummary: "",
                initialBody: "",
                initialKind: .observation,
                initialTags: "",
                onSave: { title, summary, body, kind, tags in
                    viewModel.createAgentMemory(title: title, summary: summary, body: body, kind: kind, tags: tags)
                }
            )
        }
    }

    private var filteredRecords: [AgentMemoryRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return memoryStore.records(projectPath: viewModel.selectedProjectPath).filter { record in
            if let selectedStatus, record.status != selectedStatus { return false }
            if let selectedKind, record.kind != selectedKind { return false }
            guard !query.isEmpty else { return true }
            let haystack = ([record.title, record.summary, record.kind.displayName, record.status.displayName] + record.tags)
                .joined(separator: " ")
                .lowercased()
            return haystack.contains(query)
        }
    }

    private var selectedRecord: AgentMemoryRecord? {
        guard let selectedRecordID else { return filteredRecords.first }
        return memoryStore.records.first(where: { $0.id == selectedRecordID }) ?? filteredRecords.first
    }

    private var overviewCard: some View {
        AppCard(title: "Memory Status") {
            HStack(spacing: 10) {
                MemoryMetricTile(title: "Active", value: "\(memoryStore.activeRecords.count)", systemImage: "brain")
                MemoryMetricTile(title: "Pending", value: "\(memoryStore.pendingRecords.count)", systemImage: "text.badge.plus")
                MemoryMetricTile(title: "Project", value: viewModel.selectedProjectPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "All", systemImage: "folder")
                Spacer(minLength: 0)
                Toggle("Enabled", isOn: Binding(
                    get: { viewModel.appSettings.agentMemoryEnabled },
                    set: { viewModel.setAgentMemoryEnabled($0) }
                ))
                .toggleStyle(.switch)
            }
        }
    }

    private var controlsCard: some View {
        AppCard(title: "Browse") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    TextField("Search memories", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        isNewMemoryPresented = true
                    } label: {
                        Label("New", systemImage: "plus")
                    }
                }
                HStack(spacing: 8) {
                    Picker("Status", selection: Binding(
                        get: { selectedStatus?.rawValue ?? "all" },
                        set: { selectedStatus = $0 == "all" ? nil : AgentMemoryStatus(rawValue: $0) }
                    )) {
                        Text("All Statuses").tag("all")
                        ForEach(AgentMemoryStatus.allCases) { status in
                            Text(status.displayName).tag(status.rawValue)
                        }
                    }
                    .frame(width: 180)
                    Picker("Kind", selection: Binding(
                        get: { selectedKind?.rawValue ?? "all" },
                        set: { selectedKind = $0 == "all" ? nil : AgentMemoryKind(rawValue: $0) }
                    )) {
                        Text("All Types").tag("all")
                        ForEach(AgentMemoryKind.allCases) { kind in
                            Text(kind.displayName).tag(kind.rawValue)
                        }
                    }
                    .frame(width: 210)
                }
                .labelsHidden()
            }
        }
    }

    private var contentCard: some View {
        AppCard(title: "Memory Files") {
            HStack(alignment: .top, spacing: 14) {
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
                .frame(minWidth: 280, idealWidth: 340, maxWidth: 420, minHeight: 360)

                Divider()

                if let selectedRecord {
                    MemoryDetailView(record: selectedRecord, memoryStore: memoryStore, viewModel: viewModel)
                        .frame(maxWidth: .infinity, minHeight: 360, alignment: .topLeading)
                } else {
                    ContentUnavailableView("No Memories", systemImage: "brain", description: Text("Create a memory or approve pending memories to make them available to sessions."))
                        .frame(maxWidth: .infinity, minHeight: 360)
                }
            }
        }
    }
}

private struct MemoryMetricTile: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(AppTheme.brandAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.headline)
                    .lineLimit(1)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)
            }
        }
        .padding(10)
        .frame(minWidth: 112, alignment: .leading)
        .background(AppTheme.contentSubtleFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct MemoryRecordRow: View {
    let record: AgentMemoryRecord
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(record.title.isEmpty ? "Untitled Memory" : record.title)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    Text(record.status.displayName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(statusColor)
                }
                Text(record.summary)
                    .font(.callout)
                    .foregroundStyle(AppTheme.mutedText)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(record.kind.displayName)
                    Text(record.scope.displayName)
                    if record.useCount > 0 { Text("Used \(record.useCount)x") }
                }
                .font(.caption)
                .foregroundStyle(AppTheme.mutedText)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? AppTheme.contentSubtleFill : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? AppTheme.selectionStroke : AppTheme.contentStroke.opacity(0.5), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private var statusColor: Color {
        switch record.status {
        case .pending: return .orange
        case .active, .pinned: return .green
        case .stale: return .yellow
        case .archived, .rejected: return AppTheme.mutedText
        }
    }
}

private struct MemoryDetailView: View {
    let record: AgentMemoryRecord
    @ObservedObject var memoryStore: AgentMemoryStore
    @ObservedObject var viewModel: AppViewModel
    @State private var isEditing = false

    var body: some View {
        let document = memoryStore.document(for: record)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.title)
                        .font(.title3.weight(.semibold))
                    Text(record.summary)
                        .foregroundStyle(AppTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Menu {
                    Button("Approve") { viewModel.setAgentMemoryStatus(record.id, status: .active) }
                    Button("Pin") { viewModel.setAgentMemoryStatus(record.id, status: .pinned) }
                    Button("Mark Stale") { viewModel.setAgentMemoryStatus(record.id, status: .stale) }
                    Button("Archive") { viewModel.setAgentMemoryStatus(record.id, status: .archived) }
                    Button("Reject") { viewModel.setAgentMemoryStatus(record.id, status: .rejected) }
                    Divider()
                    Button("Delete", role: .destructive) { viewModel.deleteAgentMemory(record.id) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                Button("Edit") { isEditing = true }
            }

            AppKeyValueList(rows: [
                ("Type", record.kind.displayName),
                ("Status", record.status.displayName),
                ("Scope", record.scope.displayName),
                ("Path", record.filePath)
            ])

            ScrollView {
                MarkdownTextView(source: document.body.isEmpty ? "_No body._" : document.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.vertical, 6)
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
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title2.weight(.semibold))
            TextField("Title", text: $memoryTitle)
            TextField("Summary", text: $summary)
            Picker("Type", selection: $kind) {
                ForEach(AgentMemoryKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            TextField("Tags", text: $tags)
            TextEditor(text: $bodyText)
                .font(.body.monospaced())
                .frame(minHeight: 240)
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(AppTheme.contentStroke, lineWidth: 1)
                }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    onSave(memoryTitle, summary, bodyText, kind, tags.split(separator: ",").map { String($0) })
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(memoryTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 680, height: 520)
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
                        Text(event.memoryIDs.prefix(4).joined(separator: ", "))
                            .font(.caption.monospaced())
                            .foregroundStyle(AppTheme.mutedText)
                            .textSelection(.enabled)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}
