import SwiftUI

struct MemoryScreen: View {
    var viewModel: AppViewModel
    @ObservedObject var memoryStore: AgentMemoryStore
    @Binding var searchText: String
    @State private var selectedStatus: AgentMemoryStatus?
    @State private var selectedKind: AgentMemoryKind?
    @State private var selectedRecordID: String?
    @State private var isNewMemoryPresented = false
    /// Cached derivations of `memoryStore.records(projectPath:)`. Re-computed
    /// only when one of the input drivers changes — not on every body eval.
    /// Without this, every observable read of `memoryStore` would re-walk the
    /// full records array.
    @State private var cachedCurrent: [AgentMemoryRecord] = []
    @State private var cachedFiltered: [AgentMemoryRecord] = []

    var body: some View {
        AppPage("Memory", subtitle: "Review project memories used by Agent Deck") {

            overviewCard
            libraryCard
        }
        // Toolbar buttons live in ContentView's central switch (memoryPrimaryToolbarContent)
        // so the island doesn't jump when switching views. "New Memory" arrives here
        // via notification because this screen owns the editor sheet.
        .onReceive(NotificationCenter.default.publisher(for: .agentDeckNewMemoryRequested)) { _ in
            isNewMemoryPresented = true
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
        .task(id: cacheKey) { recomputeCachedLayout() }
        // Select a record requested from a transcript recall card. `.onChange`
        // covers the case where this screen is already showing; `.onAppear`
        // covers a fresh switch to the Memory tab (the id was set before we existed).
        .onAppear { consumePendingMemorySelection() }
        .onChange(of: viewModel.selectedMemoryID) { _, _ in consumePendingMemorySelection() }
    }

    /// Apply a memory selection queued by `AppViewModel.openMemory(byID:)`. Clears
    /// filters/search so the target lands in the visible set, then consumes the id.
    private func consumePendingMemorySelection() {
        guard let id = viewModel.selectedMemoryID else { return }
        selectedStatus = nil
        selectedKind = nil
        if !searchText.isEmpty { searchText = "" }
        selectedRecordID = id
        viewModel.selectedMemoryID = nil
    }

    private var cacheKey: String {
        // Stable signature for `.task(id:)`. `revision` bumps once per write,
        // far cheaper than diffing the full records array.
        "\(memoryStore.revision)|\(viewModel.selectedProjectPath ?? "")|\(searchText)|\(selectedStatus?.rawValue ?? "")|\(selectedKind?.rawValue ?? "")"
    }

    private func recomputeCachedLayout() {
        let current = memoryStore.records(projectPath: viewModel.selectedProjectPath)
        cachedCurrent = current

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        cachedFiltered = current.filter { record in
            if let selectedStatus, record.status != selectedStatus { return false }
            if let selectedKind, record.kind != selectedKind { return false }
            guard !query.isEmpty else { return true }
            let haystack = ([record.title, record.summary, record.kind.displayName, record.status.displayName, record.scope.displayName, record.filePath] + record.tags)
                .joined(separator: " ")
                .lowercased()
            return haystack.contains(query)
        }
    }

    private var currentRecords: [AgentMemoryRecord] { cachedCurrent }
    private var filteredRecords: [AgentMemoryRecord] { cachedFiltered }

    private var selectedRecord: AgentMemoryRecord? {
        guard let selectedRecordID else { return filteredRecords.first }
        return filteredRecords.first(where: { $0.id == selectedRecordID }) ?? filteredRecords.first
    }

    private var overviewCard: some View {
        AppCard(title: "Project Memory", trailing: {
            Toggle("Memory", isOn: Binding(
                get: { viewModel.appSettings.agentMemoryEnabled },
                set: { viewModel.setAgentMemoryEnabled($0) }
            ))
            .appSwitch()
        }) {
            Text("Durable project context that agents can recall: architecture notes, decisions, preferences, runbooks, and recurring failures.")
                .foregroundStyle(AppTheme.mutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var libraryCard: some View {
        AppCard(title: "Memory Library") {
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
            .appSecondaryButton()
            .disabled(searchText.isEmpty && selectedStatus == nil && selectedKind == nil)
        }
    }

    private var memoryList: some View {
        List {
            ForEach(filteredRecords) { record in
                MemoryRecordRow(record: record, isSelected: record.id == selectedRecord?.id) {
                    selectedRecordID = record.id
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        deleteMemory(record)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .tint(.red)
                }
                .contextMenu {
                    Button { viewModel.setAgentMemoryStatus(record.id, status: .active) } label: {
                        Label("Mark Active", systemImage: AgentMemoryStatus.active.systemImage)
                    }
                    Button { viewModel.setAgentMemoryStatus(record.id, status: .pinned) } label: {
                        Label("Pin", systemImage: AgentMemoryStatus.pinned.systemImage)
                    }
                    Button { viewModel.setAgentMemoryStatus(record.id, status: .stale) } label: {
                        Label("Mark Stale", systemImage: AgentMemoryStatus.stale.systemImage)
                    }
                    Button { viewModel.setAgentMemoryStatus(record.id, status: .archived) } label: {
                        Label("Archive", systemImage: AgentMemoryStatus.archived.systemImage)
                    }
                    Divider()
                    Button(role: .destructive) {
                        deleteMemory(record)
                    } label: {
                        Label("Delete Memory", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollIndicators(.hidden)
        .hideNativeScrollers()
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .frame(minWidth: 310, idealWidth: 360, maxWidth: 440, minHeight: 430)
    }

    private func deleteMemory(_ record: AgentMemoryRecord) {
        if selectedRecordID == record.id {
            selectedRecordID = nil
        }
        viewModel.deleteAgentMemory(record.id)
    }
}


struct MemoryInfoPopover: View {
    let enabled: Bool
    let projectName: String
    let recordCount: Int
    let injectableCount: Int
    let staleCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: SidebarItem.memory.systemImage)
                    .foregroundStyle(AppTheme.brandAccent)
                Text("Agent Deck Memory")
                    .font(.headline)
                    .fontWidth(.expanded)
            }

            VStack(alignment: .leading, spacing: 10) {
                infoRow("What is stored", "Project-scoped, durable facts: architecture notes, decisions, preferences, runbooks, and recurring failures.")
                infoRow("When agents see it", "Active and pinned memories are eligible to be included in Pi sessions when relevant to the task. Stale and archived memories are not included automatically.")
                infoRow("Current project", projectName)
            }

            Divider()

            HStack(spacing: 10) {
                stat("Status", enabled ? "Enabled" : "Paused", color: enabled ? .green : .orange)
                stat("Memories", "\(recordCount)", color: AppTheme.brandAccent)
                stat("Eligible", "\(injectableCount)", color: .green)
                stat("Stale", "\(staleCount)", color: .yellow)
            }
        }
        .padding(16)
        .frame(width: 460, alignment: .leading)
    }

    private func infoRow(_ title: String, _ description: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .fontWidth(.expanded)
            Text(description)
                .font(.caption)
                .foregroundStyle(AppTheme.mutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func stat(_ title: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)
                .lineLimit(1)
            Text(title)
                .font(.caption2)
                .foregroundStyle(AppTheme.mutedText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
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
                        Text(record.status.displayName)
                            .font(.caption)
                            .foregroundStyle(AppTheme.mutedText)
                    }

                    Text(record.summary.isEmpty ? "No summary provided." : record.summary)
                        .font(.callout)
                        .foregroundStyle(AppTheme.mutedText)
                        .lineLimit(2)

                    HStack(spacing: 6) {
                        Label(record.kind.displayName, systemImage: record.kind.systemImage)
                        Label(record.scope.displayName, systemImage: record.scope.systemImage)
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
    var viewModel: AppViewModel
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
                    ScrollView(showsIndicators: false) {
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
                    Text(record.title.isEmpty ? "Untitled Memory" : record.title)
                        .font(.title3.weight(.bold))
                        .fontWidth(.expanded)
                        .lineLimit(2)
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
                .appSecondaryButton()
                .controlSize(.regular)

                Button("Edit") { isEditing = true }
                    .appSecondaryButton()
                    .controlSize(.regular)
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
            ("Updated", record.updatedAt.formatted(date: .abbreviated, time: .shortened))
        ]
        if let sourceAgentName = record.sourceAgentName, !sourceAgentName.isEmpty {
            rows.append(("Source", sourceAgentName))
        }
        rows.append(("Path", record.filePath))
        return rows
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
                    AppTextField(text: $memoryTitle, placeholder: "Short descriptive title")
                }
                GridRow {
                    Text("Summary").foregroundStyle(AppTheme.mutedText)
                    AppTextField(text: $summary, placeholder: "One sentence agents can scan")
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
                    AppTextField(text: $tags, placeholder: "Comma-separated tags")
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
                    .appSecondaryButton()
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
                    .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(event.title)
                        .font(.headline)
                    Text(event.summary)
                        .font(.callout)
                        .foregroundStyle(AppTheme.mutedText)
                    if let titles = event.memoryTitles, !titles.isEmpty {
                        // Titles snapshot taken at injection time; tapping opens
                        // that exact record in the Memory screen via notification.
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(zip(event.memoryIDs, titles).enumerated()), id: \.offset) { _, pair in
                                injectedMemoryRow(id: pair.0, title: pair.1)
                            }
                        }
                        .padding(.top, 2)
                    } else if !event.memoryIDs.isEmpty {
                        Text("\(event.memoryIDs.count) memor\(event.memoryIDs.count == 1 ? "y" : "ies")")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(AppTheme.mutedText)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func injectedMemoryRow(id: String, title: String) -> some View {
        Button {
            NotificationCenter.default.post(
                name: .agentDeckOpenMemoryRequested,
                object: nil,
                userInfo: ["id": id]
            )
        } label: {
            HStack(spacing: 6) {
                Text(title.isEmpty ? "Untitled Memory" : title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.mutedText)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
