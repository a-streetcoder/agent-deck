import SwiftUI

struct MemoryScreen: View {
    var viewModel: AppViewModel
    @ObservedObject var memoryStore: AgentMemoryStore
    @ObservedObject private var languageStore = LanguageStore.shared
    @Binding var searchText: String
    @State private var selectedRecordID: String?
    @State private var isNewMemoryPresented = false
    @State private var recordPendingDeletion: AgentMemoryRecord?
    @State private var isStaleCleanupPresented = false
    /// Cached derivations of `memoryStore.records(projectPath:)`. Re-computed
    /// only when one of the input drivers changes — not on every body eval.
    /// Without this, every observable read of `memoryStore` would re-walk the
    /// full records array. Mirrors `PromptsScreen.cachedLayout`.
    @State private var cachedLayout: (
        sections: [AppListSection<AgentMemoryRecord>],
        visible: [AgentMemoryRecord],
        hasAny: Bool
    ) = ([], [], false)

    var body: some View {
        SplitView {
            libraryPane
        } detail: {
            detailPane
        }
        // Toolbar buttons live in ContentView's central switch (memoryPrimaryToolbarContent)
        // so the island doesn't jump when switching views. "New Memory" arrives here
        // via notification because this screen owns the editor sheet.
        .onReceive(NotificationCenter.default.publisher(for: .agentDeckNewMemoryRequested)) { _ in
            isNewMemoryPresented = true
        }
        .sheet(isPresented: $isNewMemoryPresented) {
            MemoryEditorSheet(
                title: languageStore.t("memory.new"),
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
        .alert(languageStore.t("memory.deleteConfirmTitle"), isPresented: Binding(
            get: { recordPendingDeletion != nil },
            set: { if !$0 { recordPendingDeletion = nil } }
        ), presenting: recordPendingDeletion) { record in
            Button(languageStore.t("common.delete"), role: .destructive) {
                deleteMemory(record)
            }
            Button(languageStore.t("common.cancel"), role: .cancel) {
                recordPendingDeletion = nil
            }
        } message: { record in
            let name = record.title.isEmpty ? languageStore.t("memory.untitled") : record.title
            Text(languageStore.t("memory.deleteConfirmBody", name))
        }
        .alert(languageStore.t("memory.deleteStaleTitle"), isPresented: $isStaleCleanupPresented) {
            Button(languageStore.t("common.delete"), role: .destructive) {
                deleteStaleMemories()
            }
            Button(languageStore.t("common.cancel"), role: .cancel) {}
        } message: {
            let count = staleVisibleCount
            if count == 1 {
                Text(languageStore.t("memory.deleteStaleBodyOne"))
            } else {
                Text(languageStore.t("memory.deleteStaleBody", count))
            }
        }
        .task(id: cacheKey) { recomputeCachedLayout() }
        .task {
            if viewModel.appSettings.agentMemoryEnabled { memoryStore.warmEmbedder() }
        }
        // Select a record requested from a transcript recall card. `.onChange`
        // covers the case where this screen is already showing; `.onAppear`
        // covers a fresh switch to the Memory tab (the id was set before we existed).
        .onAppear { consumePendingMemorySelection() }
        .onChange(of: viewModel.selectedMemoryID) { _, _ in consumePendingMemorySelection() }
    }

    // MARK: Cached layout

    private var cacheKey: String {
        // Stable signature for `.task(id:)`. `revision` bumps once per write,
        // far cheaper than diffing the full records array.
        "\(memoryStore.revision)|\(viewModel.selectedProjectPath ?? "")|\(searchText)"
    }

    private func recomputeCachedLayout() {
        let current = memoryStore.records(projectPath: viewModel.selectedProjectPath)

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let visible: [AgentMemoryRecord]
        if query.isEmpty {
            visible = current
        } else {
            visible = current.filter { record in
                ([record.title, record.summary,
                  record.kind.displayName, record.kind.localizedDisplayName,
                  record.status.displayName, record.status.localizedDisplayName,
                  record.scope.displayName, languageStore.t("memory.scope.project"),
                  record.filePath] + record.tags)
                    .contains { $0.lowercased().contains(query) }
            }
        }

        var sections: [AppListSection<AgentMemoryRecord>] = []
        // Pinned leads: it is the strongest signal, then the working set, then
        // the two not-recalled tiers.
        for status in [AgentMemoryStatus.pinned, .active, .stale, .archived] {
            let items = visible.filter { $0.status == status }
            if !items.isEmpty {
                sections.append(AppListSection(
                    id: status.rawValue,
                    title: status.localizedDisplayName,
                    info: status.sectionInfo,
                    accessory: status == .stale ? AnyView(staleCleanupButton) : nil,
                    items: items
                ))
            }
        }
        if sections.isEmpty {
            sections.append(AppListSection(
                id: "empty",
                title: languageStore.t("memory.sectionMemories"),
                items: [],
                emptyMessage: current.isEmpty ? emptyLibraryMessage : languageStore.t("memory.noMatch")
            ))
        }

        cachedLayout = (sections, visible, !current.isEmpty)
        ensureSelection()
    }

    /// Trailing control on the Stale section header: deletes every visible
    /// stale memory after confirmation. Mirrors `AppHelpButton`'s quiet inline
    /// affordance so the header stays calm.
    private var staleCleanupButton: some View {
        Button {
            isStaleCleanupPresented = true
        } label: {
            Image(systemName: "trash")
                .imageScale(.small)
                .foregroundStyle(AppTheme.mutedText)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(languageStore.t("memory.deleteAllStale"))
        .help(languageStore.t("memory.deleteAllStale"))
    }

    private var staleVisibleCount: Int {
        cachedLayout.visible.count { $0.status == .stale }
    }

    private func deleteStaleMemories() {
        for record in cachedLayout.visible where record.status == .stale {
            if selectedRecordID == record.id {
                selectedRecordID = nil
            }
            viewModel.deleteAgentMemory(record.id)
        }
    }

    private var emptyLibraryMessage: String {
        viewModel.selectedProjectPath == nil
            ? languageStore.t("memory.emptySelectProject")
            : languageStore.t("memory.emptyNone")
    }

    private func ensureSelection() {
        guard selectedRecordID == nil
            || !cachedLayout.visible.contains(where: { $0.id == selectedRecordID }) else { return }
        selectedRecordID = cachedLayout.visible.first?.id
    }

    private var selectedRecord: AgentMemoryRecord? {
        guard let selectedRecordID else { return cachedLayout.visible.first }
        return cachedLayout.visible.first(where: { $0.id == selectedRecordID }) ?? cachedLayout.visible.first
    }

    /// Apply a memory selection queued by `AppViewModel.openMemory(byID:)`. Clears
    /// search so the target lands in the visible set, then consumes the id.
    private func consumePendingMemorySelection() {
        guard let id = viewModel.selectedMemoryID else { return }
        if !searchText.isEmpty { searchText = "" }
        selectedRecordID = id
        viewModel.selectedMemoryID = nil
    }

    // MARK: Library pane

    private var libraryPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            embeddingStatusRow
            AppList(
                sections: cachedLayout.sections,
                selection: .single($selectedRecordID)
            ) { record in
                memoryListRow(record)
            }
        }
    }

    /// Recall is semantic, on-device, and fallback-free, so it fails silently when
    /// the model can't run. This surfaces a strip above the list only in those
    /// problem states; when recall is working there's nothing to show (the model
    /// ships with macOS and is effectively always ready), so the panes stay aligned.
    @ViewBuilder
    private var embeddingStatusRow: some View {
        switch memoryStore.embeddingStatus {
        case .unavailable:
            statusLine("exclamationmark.triangle.fill", .orange, languageStore.t("memory.embedUnavailable"))
        case .unsupported:
            statusLine("xmark.circle", .secondary, languageStore.t("memory.embedUnsupported"))
        case .unknown, .ready:
            EmptyView()
        }
    }

    private func statusLine(_ systemImage: String, _ tint: Color, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(text)
        }
        .font(.caption)
        .foregroundStyle(AppTheme.mutedText)
        .padding(.horizontal, 18)
        .padding(.top, AppTheme.Split.contentTopInset + 2)
        .padding(.bottom, 4)
    }

    private func memoryListRow(_ record: AgentMemoryRecord) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: record.kind.systemImage)
                .foregroundStyle(record.status.tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 5) {
                Text(record.title.isEmpty ? languageStore.t("memory.untitled") : record.title)
                    .font(AppTheme.Font.sectionTitle)
                    .fontWidth(.expanded)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(record.summary.isEmpty ? languageStore.t("memory.noSummary") : record.summary)
                    .font(AppTheme.Font.metadata)
                    .foregroundStyle(AppTheme.mutedText)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        // Fill the row and give it a hit-testable shape so a right-click anywhere on the
        // row (not just on the title text) opens the context menu.
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .contextMenu {
            ForEach(AgentMemoryStatus.allCases) { status in
                if status != record.status {
                    Button {
                        viewModel.setAgentMemoryStatus(record.id, status: status)
                    } label: {
                        Label(status.actionTitle, systemImage: status.systemImage)
                    }
                }
            }
            Divider()
            Button(role: .destructive) {
                recordPendingDeletion = record
            } label: {
                Label(languageStore.t("memory.delete"), systemImage: "trash")
            }
        }
    }

    // MARK: Detail pane

    @ViewBuilder
    private var detailPane: some View {
        if let record = selectedRecord {
            MemoryDetailView(
                record: record,
                memoryStore: memoryStore,
                viewModel: viewModel,
                onDelete: { recordPendingDeletion = $0 }
            )
        } else if !cachedLayout.hasAny {
            AppEmptyState(
                languageStore.t("memory.emptyTitle"),
                systemImage: "brain",
                description: viewModel.selectedProjectPath == nil
                    ? languageStore.t("memory.emptySelectProject")
                    : languageStore.t("memory.emptyBody"),
                layout: .fill
            )
        } else {
            AppEmptyState(
                languageStore.t("memory.noMatchTitle"),
                systemImage: "line.3.horizontal.decrease.circle",
                description: languageStore.t("memory.noMatchBody"),
                layout: .fill
            )
        }
    }

    private func deleteMemory(_ record: AgentMemoryRecord) {
        if selectedRecordID == record.id {
            selectedRecordID = nil
        }
        recordPendingDeletion = nil
        viewModel.deleteAgentMemory(record.id)
    }
}


struct MemoryInfoPopover: View {
    @ObservedObject private var languageStore = LanguageStore.shared
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
                Text(languageStore.t("memory.infoTitle", AppBrand.displayName))
                    .font(.headline)
                    .fontWidth(.expanded)
            }

            VStack(alignment: .leading, spacing: 10) {
                infoRow(languageStore.t("memory.info.what"), languageStore.t("memory.info.whatBody"))
                infoRow(languageStore.t("memory.info.when"), languageStore.t("memory.info.whenBody"))
                infoRow(languageStore.t("memory.info.project"), projectName)
            }

            Divider()

            HStack(spacing: 10) {
                stat(languageStore.t("memory.stat.status"), enabled ? languageStore.t("memory.enabled") : languageStore.t("memory.paused"), color: enabled ? .green : .orange)
                stat(languageStore.t("memory.stat.memories"), "\(recordCount)", color: AppTheme.brandAccent)
                stat(languageStore.t("memory.stat.eligible"), "\(injectableCount)", color: .green)
                stat(languageStore.t("memory.stat.stale"), "\(staleCount)", color: .yellow)
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
                .font(AppTheme.Font.micro)
                .foregroundStyle(AppTheme.mutedText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}


private struct MemoryDetailView: View {
    let record: AgentMemoryRecord
    @ObservedObject var memoryStore: AgentMemoryStore
    @ObservedObject private var languageStore = LanguageStore.shared
    var viewModel: AppViewModel
    let onDelete: (AgentMemoryRecord) -> Void
    @State private var isEditing = false
    /// Body markdown loaded off the render path. `document(for:)` reads the
    /// file from disk, so it runs in `.task(id:)` rather than in `body`.
    @State private var bodyText = ""

    var body: some View {
        AppPage(record.title.isEmpty ? languageStore.t("memory.untitled") : record.title, lazy: true) {
            AppCard(title: record.title.isEmpty ? languageStore.t("memory.untitled") : record.title, trailing: { statusPicker }) {
                if !record.summary.isEmpty {
                    Text(record.summary)
                        .foregroundStyle(AppTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                AppKeyValueList(rows: metadataRows)
            }

            LazyMarkdownCard(
                title: languageStore.t("memory.body"),
                source: bodyText.isEmpty ? languageStore.t("memory.noBody") : bodyText,
                minimumHeight: 120,
                trailing: {
                    Button {
                        isEditing = true
                    } label: {
                        Label(languageStore.t("common.edit"), systemImage: "square.and.pencil")
                            .font(.caption.weight(.semibold))
                            .labelStyle(.titleAndIcon)
                    }
                    .appSmallSecondaryButton()
                    .help(languageStore.t("memory.editHelp"))
                }
            )

            AppCard(title: languageStore.t("memory.delete")) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(languageStore.t("memory.deleteBody"))
                        .font(.callout)
                        .foregroundStyle(AppTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button(languageStore.t("memory.delete"), role: .destructive) {
                        onDelete(record)
                    }
                    .appDestructiveButton()
                }
            }
        }
        .task(id: "\(record.id)|\(record.updatedAt.timeIntervalSinceReferenceDate)") {
            bodyText = memoryStore.document(for: record).body
        }
        .sheet(isPresented: $isEditing) {
            MemoryEditorSheet(
                title: languageStore.t("memory.edit"),
                initialTitle: record.title,
                initialSummary: record.summary,
                initialBody: bodyText,
                initialKind: record.kind,
                initialTags: record.tags.joined(separator: ", "),
                onSave: { title, summary, body, kind, tags in
                    _ = kind
                    viewModel.updateAgentMemory(id: record.id, title: title, summary: summary, body: body, tags: tags)
                }
            )
        }
    }

    private var statusPicker: some View {
        Picker(languageStore.t("memory.stat.status"), selection: Binding(
            get: { record.status },
            set: { viewModel.setAgentMemoryStatus(record.id, status: $0) }
        )) {
            ForEach(AgentMemoryStatus.allCases) { status in
                Label(status.localizedDisplayName, systemImage: status.systemImage).tag(status)
            }
        }
        .labelsHidden()
        .appMenuPicker()
        .fixedSize()
    }

    private var metadataRows: [(String, String)] {
        var rows: [(String, String)] = [
            (languageStore.t("memory.meta.type"), record.kind.localizedDisplayName),
            (languageStore.t("memory.meta.scope"), languageStore.t("memory.scope.project")),
            (languageStore.t("memory.meta.created"), record.createdAt.formatted(date: .abbreviated, time: .shortened)),
            (languageStore.t("memory.meta.updated"), record.updatedAt.formatted(date: .abbreviated, time: .shortened))
        ]
        if let sourceAgentName = record.sourceAgentName, !sourceAgentName.isEmpty {
            rows.append((languageStore.t("memory.meta.source"), sourceAgentName))
        }
        rows.append((languageStore.t("memory.meta.file"), record.filePath))
        return rows
    }
}

private struct MemoryEditorSheet: View {
    @ObservedObject private var languageStore = LanguageStore.shared
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
        // Mirrors the `MarkdownFileEditorSheet` chrome: compact headline header
        // (18pt) + Divider, bare monospaced editor, Divider, 16pt footer.
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .fontWidth(.expanded)
                    Text(languageStore.t("memory.editorHint"))
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(18)

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow {
                    Text(languageStore.t("memory.field.title")).foregroundStyle(AppTheme.mutedText)
                    AppTextField(text: $memoryTitle, placeholder: languageStore.t("memory.placeholder.title"))
                }
                GridRow {
                    Text(languageStore.t("memory.field.summary")).foregroundStyle(AppTheme.mutedText)
                    AppTextField(text: $summary, placeholder: languageStore.t("memory.placeholder.summary"))
                }
                GridRow {
                    Text(languageStore.t("memory.field.type")).foregroundStyle(AppTheme.mutedText)
                    Picker(languageStore.t("memory.field.type"), selection: $kind) {
                        ForEach(AgentMemoryKind.allCases) { kind in
                            Label(kind.localizedDisplayName, systemImage: kind.systemImage).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .appMenuPicker()
                    .frame(maxWidth: 260, alignment: .leading)
                }
                GridRow {
                    Text(languageStore.t("memory.field.tags")).foregroundStyle(AppTheme.mutedText)
                    AppTextField(text: $tags, placeholder: languageStore.t("memory.placeholder.tags"))
                }
            }
            .padding(18)

            Divider()

            TextEditor(text: $bodyText)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(12)
                .frame(maxHeight: .infinity)

            Divider()

            HStack {
                Spacer()
                Button(languageStore.t("common.cancel")) { dismiss() }
                    .appSecondaryButton()
                Button(languageStore.t("common.save")) {
                    onSave(memoryTitle.trimmedForMemory, summary.trimmedForMemory, bodyText, kind, parsedTags)
                    dismiss()
                }
                .appPrimaryButton()
                .keyboardShortcut(.defaultAction)
                .disabled(memoryTitle.trimmedForMemory.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 760, height: 620)
    }

    private var parsedTags: [String] {
        tags.split(separator: ",")
            .map { String($0).trimmedForMemory }
            .filter { !$0.isEmpty }
    }
}

struct PiAgentMemoryActivityCard: View {
    @ObservedObject private var languageStore = LanguageStore.shared
    let event: AgentMemoryTranscriptEvent

    var body: some View {
        AppRowCard {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: event.event.systemImage)
                    .font(AppTheme.Font.footnote.weight(.semibold))
                    .foregroundStyle(event.event == .blocked ? .red : AppTheme.brandAccent)
                    .frame(width: 16, height: 16)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 0) {
                    Text(event.title)
                        .font(AppTheme.Font.footnote.weight(.semibold))
                        .fontWidth(.expanded)
                    if hasTitledRows {
                        memoryRows
                            .padding(.top, 6)
                    } else {
                        Text(event.summary)
                            .font(AppTheme.Font.caption.weight(.medium))
                            .foregroundStyle(AppTheme.mutedText)
                            .padding(.top, 3)
                        if !event.memoryIDs.isEmpty {
                            Text(event.memoryIDs.count == 1
                                 ? languageStore.t("memory.countOne")
                                 : languageStore.t("memory.countMany", event.memoryIDs.count))
                                .font(AppTheme.Font.caption.weight(.medium))
                                .foregroundStyle(AppTheme.mutedText)
                                .padding(.top, 6)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var hasTitledRows: Bool {
        event.memoryTitles?.isEmpty == false
    }

    private var memoryRows: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(zip(event.memoryIDs, event.memoryTitles ?? []).enumerated()), id: \.offset) { _, pair in
                injectedMemoryRow(id: pair.0, title: pair.1)
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
                Text(title.isEmpty ? languageStore.t("memory.untitled") : title)
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

    var localizedDisplayName: String {
        LanguageStore.shared.t("memory.kind.\(rawValue)")
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

    var localizedDisplayName: String {
        LanguageStore.shared.t("memory.status.\(rawValue)")
    }

    /// Context-menu verb for moving a record into this status.
    var actionTitle: String {
        LanguageStore.shared.t("memory.action.\(rawValue)")
    }

    /// Help-popover copy for the status section headers in the library list.
    var sectionInfo: String {
        LanguageStore.shared.t("memory.sectionInfo.\(rawValue)")
    }
}

private extension String {
    var trimmedForMemory: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
