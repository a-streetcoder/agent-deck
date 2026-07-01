import SwiftUI

/// Runtime → MCP. Native Model Context Protocol support: a master toggle plus the
/// configured servers (read from mcp.json), each with a connection test and
/// project assignment. Server discovery runs OFF the main thread and is cached in
/// `@State`; the SwiftUI body performs no filesystem I/O (mirrors ExtensionsScreen).
struct MCPServersScreen: View {
    var viewModel: AppViewModel

    /// All configured servers (merged across mcp.json locations), loaded off-main and
    /// cached. Never read via a body-time load.
    @State private var servers: [MCPServerEntry] = []
    @State private var isLoading = false
    @State private var statusByServer: [String: ProbeStatus] = [:]
    /// OAuth connected state per remote server (has stored tokens).
    @State private var connectedByServer: [String: Bool] = [:]
    @State private var connectingServers: Set<String> = []
    /// Bumped by the Refresh button to force a reload + reconnect.
    @State private var reloadTick = 0
    /// Presented add/edit sheet (nil = closed).
    @State private var editorModel: MCPServerEditorModel?
    /// Name pending delete confirmation.
    @State private var pendingDeleteName: String?

    /// Selected server in the master list.
    @State private var selectedServerID: MCPServerEntry.ID?

    enum ProbeStatus: Equatable {
        case probing
        case ok([MCPProbeTool])
        case failed(String)

        var tools: [MCPProbeTool] { if case let .ok(tools) = self { return tools }; return [] }
    }

    private var mcpEnabled: Bool { viewModel.appSettings.mcpEnabled }
    private var selectedServer: MCPServerEntry? {
        guard let id = selectedServerID else { return nil }
        return servers.first { $0.id == id }
    }

    var body: some View {
        Group {
            // With no servers there's nothing to put in two panes — collapse the
            // split into one centered empty state (matching the app's other
            // "nothing here" screens) instead of two half-empty messages.
            if servers.isEmpty {
                emptyState
            } else {
                SplitView {
                    listPane
                } detail: {
                    detailPane
                }
            }
        }
        // Reload on project switch, enable toggle, and manual Refresh. Off-main.
        .task(id: "\(viewModel.projectRootURL?.path ?? "")#\(mcpEnabled)#\(reloadTick)") {
            await loadServers()
        }
        // Window-toolbar actions (the toolbar lives in ContentView).
        .onChange(of: viewModel.mcpAddRequestToken) { _, _ in editorModel = .add }
        .onChange(of: viewModel.mcpRefreshRequestToken) { _, _ in reloadTick += 1 }
        .sheet(item: $editorModel) { model in
            MCPServerEditorSheet(model: model, existingNames: Set(servers.map(\.name)), projectRoot: viewModel.projectRootURL) { name, config in
                do {
                    try viewModel.upsertMCPServer(name: name, config: config)
                    reloadTick += 1
                } catch { NSSound.beep() }
            }
        }
        .alert("Remove MCP server?", isPresented: Binding(get: { pendingDeleteName != nil }, set: { if !$0 { pendingDeleteName = nil } })) {
            Button("Cancel", role: .cancel) { pendingDeleteName = nil }
            Button("Remove", role: .destructive) {
                if let name = pendingDeleteName {
                    if selectedServerID == name { selectedServerID = nil }
                    do { try viewModel.removeMCPServer(named: name); reloadTick += 1 }
                    catch { NSSound.beep() }
                }
                pendingDeleteName = nil
            }
        } message: {
            Text("This removes “\(pendingDeleteName ?? "")” from ~/.pi/agent/mcp.json and clears it from any project and agent assignments.")
        }
    }

    // MARK: - List pane

    private var listPane: some View {
        // Enable/disable lives in the window toolbar (mirrors Memory); the title
        // shows "MCP: On/Off". The empty case is handled before the split, so the
        // list always has servers here.
        AppList(
            sections: serverListSections,
            selection: .single($selectedServerID)
        ) { entry in
            listRow(entry)
        }
    }

    private var serverListSections: [AppListSection<MCPServerEntry>] {
        let defaultServers = servers.filter { viewModel.isMcpServerEnabledForAllProjects($0.name) }
        let catalogServers = servers.filter { !viewModel.isMcpServerEnabledForAllProjects($0.name) }
        var sections: [AppListSection<MCPServerEntry>] = [
            AppListSection(
                id: "default",
                title: "Default MCP Servers",
                info: "Available to every project when MCP is on.",
                items: defaultServers,
                emptyMessage: "No default MCP servers."
            )
        ]
        if !catalogServers.isEmpty {
            sections.append(AppListSection(
                id: "catalog",
                title: "Catalog",
                info: "Configured servers. Dimmed only when not enabled for All Projects and not assigned to any project.",
                items: catalogServers
            ))
        }
        return sections
    }

    /// Single centered empty state shown in place of the split view when no servers
    /// are configured. Uses `ContentUnavailableView` for consistent system fonts and
    /// centering, matching the app's other empty screens.
    private var emptyState: some View {
        ContentUnavailableView {
            Label(isLoading ? "Loading MCP servers…" : "No MCP servers", systemImage: SidebarItem.mcp.systemImage)
        } description: {
            Text("Add a server from the toolbar — paste a config or fill the form. Servers are read from mcp.json in ~/.config/mcp, ~/.pi/agent, and the project's .mcp.json / .pi/mcp.json.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func listRow(_ entry: MCPServerEntry) -> some View {
        MCPServerListRowView(
            entry: entry,
            subtitle: transportLabel(entry),
            iconName: serverIcon(entry),
            iconColor: serverColor(entry),
            isInactive: !serverIsAssignedSomewhere(entry),
            canEdit: viewModel.mcpServerIsEditable(entry),
            status: { rowStatus(entry) },
            onEdit: { editorModel = .edit(entry) }
        )
        // Fill the row and give it a hit-testable shape so a right-click anywhere on the
        // row (not just on the name text) opens the context menu.
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .contextMenu { serverContextMenu(entry) }
    }

    /// Right-click actions for a server row, mirroring the Skills row menu. Edit/Remove
    /// appear only for app-owned servers (`~/.pi/agent/mcp.json`); read-only servers
    /// still get Test and Reveal so the defining file can be opened by hand.
    @ViewBuilder
    private func serverContextMenu(_ entry: MCPServerEntry) -> some View {
        Button {
            Task { await probe(entry) }
        } label: {
            Label(isServerConnected(entry) ? "Refresh Tools" : "Connect", systemImage: "bolt.horizontal")
        }
        .disabled(statusByServer[entry.name] == .probing)

        Button {
            revealInFinder(entry)
        } label: {
            Label("Reveal Config in Finder", systemImage: "finder")
        }

        if viewModel.mcpServerIsEditable(entry) {
            Divider()
            Button {
                editorModel = .edit(entry)
            } label: {
                Label("Edit Server", systemImage: "square.and.pencil")
            }
            Button(role: .destructive) {
                pendingDeleteName = entry.name
            } label: {
                Label("Remove Server", systemImage: "trash")
            }
        }
    }

    private func revealInFinder(_ entry: MCPServerEntry) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.sourcePath)])
    }

    @ViewBuilder
    private func rowStatus(_ entry: MCPServerEntry) -> some View {
        switch statusByServer[entry.name] {
        case .probing: AppSpinner().controlSize(.small)
        case .ok: EmptyView()
        case .failed: Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
        case nil: EmptyView()
        }
    }

    // MARK: - Detail pane

    @ViewBuilder
    private var detailPane: some View {
        if let entry = selectedServer {
            AppPage(entry.name, subtitle: transportLabel(entry)) {
                VStack(alignment: .leading, spacing: 20) {
                    connectionCard(entry)
                    toolsCard(entry)
                    projectAssignmentCard(entry)
                    removeCard(entry)
                }
            }
        } else {
            AppPage("MCP", subtitle: "Connect Model Context Protocol servers and assign them to projects and agents") {
                detailPlaceholder
            }
        }
    }

    private var detailPlaceholder: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Select a server")
                .font(.title3.weight(.semibold))
            Text("Pick a server on the left to see its tools, test the connection, and assign it to projects.")
                .font(.callout).foregroundStyle(AppTheme.mutedText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func connectionCard(_ entry: MCPServerEntry) -> some View {
        AppCard(title: "Connection") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    detailStatusTag(entry)
                    Spacer(minLength: 8)
                    if entry.config.resolvedTransport == .stdio {
                        // Local servers connect directly; once connected the same button
                        // re-lists tools over the live connection.
                        probeButton(entry)
                    } else if connectingServers.contains(entry.name) {
                        AppSpinner().controlSize(.small)
                    } else if connectedByServer[entry.name] ?? false {
                        // Remote servers authorize via OAuth first; offer a Refresh once
                        // signed in, plus Sign out.
                        Button("Sign out") { Task { await signOut(entry) } }.controlSize(.small)
                        probeButton(entry)
                    } else {
                        Button("Connect") { Task { await connect(entry) } }.controlSize(.small)
                    }
                    if viewModel.mcpServerIsEditable(entry) {
                        Button("Edit") { editorModel = .edit(entry) }.controlSize(.small)
                    }
                }
                detailRow(icon: entry.config.resolvedTransport == .stdio ? "terminal" : "globe", text: transportLabel(entry))
                detailRow(icon: "doc", text: sourceLabel(entry))
                if case let .failed(message) = statusByServer[entry.name] {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Connect-or-refresh button: "Connect" when the server isn't connected yet, "Refresh"
    /// once it is (re-lists tools over the live connection).
    private func probeButton(_ entry: MCPServerEntry) -> some View {
        Button(isServerConnected(entry) ? "Refresh" : "Connect") { Task { await probe(entry) } }
            .controlSize(.small)
            .disabled(statusByServer[entry.name] == .probing)
    }

    private func detailRow(icon: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.caption).foregroundStyle(.secondary).frame(width: 16)
            Text(text)
                .font(.caption.monospaced()).foregroundStyle(.secondary)
                .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
        }
    }

    @ViewBuilder
    private func detailStatusTag(_ entry: MCPServerEntry) -> some View {
        switch statusByServer[entry.name] {
        case .probing:
            HStack(spacing: 6) { AppSpinner().controlSize(.small); Text("Connecting…").font(.caption).foregroundStyle(.secondary) }
        case let .ok(tools):
            AppLabelTag(text: "Connected · \(tools.count) tool\(tools.count == 1 ? "" : "s")", color: .green)
        case .failed:
            AppLabelTag(text: "Not reachable", color: .orange)
        case nil:
            AppLabelTag(text: "Not connected", color: .secondary)
        }
    }

    /// True when this server currently has a successful (connected) status.
    private func isServerConnected(_ entry: MCPServerEntry) -> Bool {
        if case .ok = statusByServer[entry.name] { return true }
        return false
    }

    private func toolsCard(_ entry: MCPServerEntry) -> some View {
        let tools = statusByServer[entry.name]?.tools ?? []
        return AppCard(title: tools.isEmpty ? "Tools" : "Tools (\(tools.count))") {
            if tools.isEmpty {
                Text(statusByServer[entry.name] == .probing
                     ? "Loading tools…"
                     : "Connect this server to load its tools.")
                    .font(.caption).foregroundStyle(AppTheme.mutedText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(tools.enumerated()), id: \.element.id) { index, tool in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(tool.name).font(.callout.monospaced().weight(.medium))
                            if let description = tool.description, !description.isEmpty {
                                Text(description).font(.caption).foregroundStyle(AppTheme.mutedText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                        if index < tools.count - 1 { Divider().opacity(0.5) }
                    }
                }
            }
        }
    }

    private func projectAssignmentCard(_ entry: MCPServerEntry) -> some View {
        let name = entry.name
        let isGlobal = viewModel.isMcpServerEnabledForAllProjects(name)
        return AppCard(title: "Project assignment") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Enable this server for every project, or pick specific ones. A session only gets a server assigned to its project (or to a Deck agent's `mcpServers`).")
                    .font(.caption).foregroundStyle(AppTheme.mutedText).fixedSize(horizontal: false, vertical: true)
                LazyVStack(alignment: .leading, spacing: 0) {
                    AllProjectsAssignmentRow(
                        isOn: Binding(
                            get: { isGlobal },
                            set: { viewModel.setMcpServerEnabledForAllProjects(name, enabled: $0) }
                        ),
                        subtitle: "Enable this server for every project"
                    )
                    Divider()
                    ForEach(viewModel.enabledProjects) { project in
                        ProjectAssignmentToggleRow(
                            project: project,
                            isOn: Binding(
                                get: { isGlobal ? true : viewModel.mcpServer(name, isEnabledFor: project) },
                                set: { viewModel.setMcpServer(name, enabled: $0, for: project) }
                            )
                        )
                        .opacity(isGlobal ? 0.4 : 1)
                        .allowsHitTesting(!isGlobal)
                        if project.id != viewModel.enabledProjects.last?.id { Divider() }
                    }
                }
            }
        }
    }

    /// Delete affordance, mirroring the Skills "Delete Skill" card. App-owned servers
    /// get a destructive Remove button; read-only ones explain where they're defined so
    /// the user knows to edit that file (we can't rewrite a config we don't own).
    @ViewBuilder
    private func removeCard(_ entry: MCPServerEntry) -> some View {
        if viewModel.mcpServerIsEditable(entry) {
            AppCard(title: "Remove Server") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Remove “\(entry.name)” from ~/.pi/agent/mcp.json and clear it from every project and agent assignment.")
                        .font(.callout)
                        .foregroundStyle(AppTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button("Remove Server", role: .destructive) {
                        pendingDeleteName = entry.name
                    }
                    .appDestructiveButton()
                }
            }
        } else {
            AppCard(title: "Read-only") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("This server is defined in a file Agent Deck doesn't own, so it can't be edited or removed here. Open the file to change or delete it.")
                        .font(.callout)
                        .foregroundStyle(AppTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    detailRow(icon: "doc", text: URL(fileURLWithPath: entry.sourcePath).path)
                    Button("Reveal in Finder") { revealInFinder(entry) }
                        .appSecondaryButton()
                }
            }
        }
    }

    private func serverIsAssignedSomewhere(_ entry: MCPServerEntry) -> Bool {
        viewModel.isMcpServerEnabledForAllProjects(entry.name)
            || viewModel.enabledProjects.contains { viewModel.mcpServer(entry.name, isEnabledFor: $0) }
    }

    private func serverIcon(_ entry: MCPServerEntry) -> String {
        entry.config.resolvedTransport == .stdio ? "terminal" : "globe"
    }

    private func serverColor(_ entry: MCPServerEntry) -> Color {
        switch entry.config.resolvedTransport {
        case .stdio: return AppTheme.brandAccent
        case .http, .sse: return AppTheme.sourceLibrary
        }
    }

    private func transportLabel(_ entry: MCPServerEntry) -> String {
        switch entry.config.resolvedTransport {
        case .stdio: return entry.config.command ?? "stdio"
        case .http, .sse: return entry.config.url ?? entry.config.resolvedTransport.rawValue
        }
    }

    private func sourceLabel(_ entry: MCPServerEntry) -> String {
        viewModel.mcpServerIsEditable(entry) ? "~/.pi/agent/mcp.json" : URL(fileURLWithPath: entry.sourcePath).lastPathComponent + " (read-only)"
    }

    // MARK: - Off-main loading

    private func loadServers() async {
        let root = viewModel.projectRootURL
        isLoading = true
        let loaded = await Task.detached(priority: .utility) {
            MCPConfigLoader().load(projectRoot: root).servers
        }.value
        servers = loaded
        statusByServer = statusByServer.filter { key, _ in loaded.contains { $0.name == key } }
        isLoading = false

        // Refresh OAuth connected-state for remote servers.
        for entry in loaded where entry.config.resolvedTransport != .stdio {
            connectedByServer[entry.name] = await viewModel.mcpServerIsConnected(entry.name)
        }
        // Reflect what's already known instead of reconnecting: show a health pill from
        // the cached tool list for servers already discovered, and only re-list over an
        // EXISTING live connection. Servers with no live connection are left "Untested"
        // so merely opening this view never spawns a process or re-triggers a permission
        // prompt — the explicit Test button handles those.
        for entry in loaded {
            if let cached = await viewModel.cachedMCPTools(entry.name) {
                statusByServer[entry.name] = .ok(cached)
            } else if await viewModel.mcpServerHasLiveConnection(entry.name) {
                Task { await probe(entry) }
            }
        }
    }

    private func probe(_ entry: MCPServerEntry) async {
        statusByServer[entry.name] = .probing
        switch await viewModel.probeMCPServer(entry) {
        case let .ok(tools): statusByServer[entry.name] = .ok(tools)
        case let .failure(message): statusByServer[entry.name] = .failed(message)
        }
    }

    private func connect(_ entry: MCPServerEntry) async {
        connectingServers.insert(entry.name)
        defer { connectingServers.remove(entry.name) }
        if let error = await viewModel.connectMCPServer(entry) {
            statusByServer[entry.name] = .failed(error)
        } else {
            connectedByServer[entry.name] = true
            await probe(entry)
        }
    }

    private func signOut(_ entry: MCPServerEntry) async {
        await viewModel.disconnectMCPServer(entry.name)
        connectedByServer[entry.name] = false
        statusByServer[entry.name] = nil
    }
}

/// MCP server catalog row. Mirrors the Agents/Skills/Prompts list density and
/// inactive treatment: dim only when the server is not assigned anywhere.
private struct MCPServerListRowView<Status: View>: View {
    let entry: MCPServerEntry
    let subtitle: String
    let iconName: String
    let iconColor: Color
    let isInactive: Bool
    let canEdit: Bool
    @ViewBuilder let status: () -> Status
    let onEdit: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.name)
                    .font(.headline)
                    .fontWidth(.expanded)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 6)

            if canEdit {
                Button(action: onEdit) {
                    Text("Edit")
                        .font(.caption.weight(.semibold))
                }
                .appSmallSecondaryButton()
                .opacity(isHovered ? 1 : 0)
                .help("Edit MCP server")
                .animation(.easeInOut(duration: 0.15), value: isHovered)
            }

            status()
        }
        .onHover { isHovered = $0 }
        .padding(.vertical, 6)
        .opacity(isInactive ? 0.62 : 1)
        .saturation(isInactive ? 0.25 : 1)
    }
}

// MARK: - Editor

enum MCPServerEditorModel: Identifiable {
    case add
    case edit(MCPServerEntry)

    var id: String {
        switch self {
        case .add: return "__add__"
        case let .edit(entry): return "edit:\(entry.name)"
        }
    }

    var existingEntry: MCPServerEntry? {
        if case let .edit(entry) = self { return entry }
        return nil
    }
}

/// Add/edit form for an MCP server, writing to ~/.pi/agent/mcp.json on Save. Supports a
/// smart paste box (mcp.json / `claude mcp add` / `codex mcp add`) plus a Local/Remote
/// transport picker. Follows the app's modal sheet chrome.
private struct MCPServerEditorSheet: View {
    let model: MCPServerEditorModel
    let existingNames: Set<String>
    let projectRoot: URL?
    let onSave: (String, MCPServerConfig) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var isRemote: Bool
    @State private var command: String
    @State private var argsText: String
    @State private var envText: String
    @State private var url: String
    @State private var headersText: String
    @State private var pasteText: String = ""
    @State private var inputMode: InputMode = .manual
    @State private var importCandidates: [MCPForeignConfigScanner.Candidate] = []
    @State private var selectedImportIDs: Set<MCPForeignConfigScanner.Candidate.ID> = []
    @State private var isScanningImports = false
    @FocusState private var focusedField: Field?

    private enum Field { case name, command, args, env, url, headers, paste }
    private enum InputMode: String, Hashable, CaseIterable, Identifiable {
        case manual, paste, importServers

        var id: String { rawValue }
        var label: String {
            switch self {
            case .manual: return "Manual"
            case .paste: return "Paste"
            case .importServers: return "Import"
            }
        }
    }

    /// True when the paste tab is the active input (add only).
    private var isPasting: Bool { !isEditing && inputMode == .paste }
    private var isImportingServers: Bool { !isEditing && inputMode == .importServers }

    init(model: MCPServerEditorModel, existingNames: Set<String>, projectRoot: URL?, onSave: @escaping (String, MCPServerConfig) -> Void) {
        self.model = model
        self.existingNames = existingNames
        self.projectRoot = projectRoot
        self.onSave = onSave
        let entry = model.existingEntry
        let config = entry?.config ?? MCPServerConfig()
        _name = State(initialValue: entry?.name ?? "")
        _isRemote = State(initialValue: config.resolvedTransport != .stdio && config.url != nil)
        _command = State(initialValue: config.command ?? "")
        _argsText = State(initialValue: (config.args ?? []).joined(separator: "\n"))
        _envText = State(initialValue: (config.env ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n"))
        _url = State(initialValue: config.url ?? "")
        _headersText = State(initialValue: (config.headers ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n"))
    }

    private var isEditing: Bool { model.existingEntry != nil }

    private var canSave: Bool {
        if isPasting { return !MCPConfigParser.parse(pasteText).isEmpty }
        if isImportingServers { return !selectedImportIDs.isEmpty }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return false }
        if isRemote {
            guard !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        } else {
            guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        }
        if !isEditing && existingNames.contains(trimmedName) { return false }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(isEditing ? "Edit MCP server" : "Add MCP server")
                        .font(.headline)
                        .fontWidth(.expanded)
                    Text("Written to ~/.pi/agent/mcp.json")
                        .font(.caption.monospaced())
                        .foregroundStyle(AppTheme.mutedText)
                }
                Spacer()
            }
            .padding(18)

            Divider()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    if !isEditing {
                        Picker("Input", selection: $inputMode) {
                            ForEach(InputMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .appSegmentedPicker()
                        .labelsHidden()
                    }

                    if isPasting {
                        pasteSection
                    } else if isImportingServers {
                        importSection
                    } else {
                        manualSection
                    }

                    Text("Assign this server to your projects or agents after saving.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedText)
                }
                .padding(20)
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .appSecondaryButton()
                Button(isImportingServers ? "Import" : (isEditing ? "Save" : "Add")) { save() }
                    .appPrimaryButton()
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding(16)
        }
        .frame(width: 560, height: 620)
        .background(AppTheme.windowBackground)
        .task(id: inputMode) {
            guard isImportingServers else { return }
            await scanImportCandidates()
        }
    }

    @ViewBuilder
    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppTheme.mutedText)
            content()
        }
    }

    private func editorBox(_ text: Binding<String>, field: Field, placeholder: String) -> some View {
        TextEditor(text: text)
            .font(.callout.monospaced())
            .scrollContentBackground(.hidden)
            .focused($focusedField, equals: field)
            .frame(height: 72)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(AppTheme.contentSubtleFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(alignment: .topLeading) {
                if text.wrappedValue.isEmpty && focusedField != field {
                    Text(placeholder)
                        .font(.callout.monospaced())
                        .foregroundStyle(AppTheme.mutedText)
                        .lineLimit(2)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
            }
    }

    @ViewBuilder
    private var pasteSection: some View {
        field("Paste a server's config, or a `claude mcp add` / `codex mcp add` command") {
            editorBox($pasteText, field: .paste, placeholder: "{ \"mcpServers\": { \"Amplitude\": { \"url\": \"https://mcp.amplitude.com/mcp\" } } }")
        }
        Text("We parse the config and add the server(s). Switch to Manual to fill the fields yourself.")
            .font(.caption)
            .foregroundStyle(AppTheme.mutedText)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var manualSection: some View {
        field("Name") {
            AppTextField(text: $name, placeholder: "amplitude")
                .focused($focusedField, equals: .name)
                .disabled(isEditing)
        }
        field("Type") {
            Picker("Type", selection: $isRemote) {
                Text("Local (stdio)").tag(false)
                Text("Remote (HTTP)").tag(true)
            }
            .appSegmentedPicker()
            .labelsHidden()
        }
        if isRemote {
            field("URL") {
                AppTextField(text: $url, placeholder: "https://mcp.amplitude.com/mcp")
                    .focused($focusedField, equals: .url)
            }
            field("Headers (KEY: VALUE per line, optional)") {
                editorBox($headersText, field: .headers, placeholder: "Authorization: Bearer …")
            }
            Text("After saving, use Connect on the server to authorize with OAuth. For token servers, add an Authorization header instead.")
                .font(.caption)
                .foregroundStyle(AppTheme.mutedText)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            field("Command") {
                AppTextField(text: $command, placeholder: "npx")
                    .focused($focusedField, equals: .command)
            }
            field("Arguments (one per line)") {
                editorBox($argsText, field: .args, placeholder: "-y\n@modelcontextprotocol/server-everything")
            }
            field("Environment (KEY=VALUE per line)") {
                editorBox($envText, field: .env, placeholder: "GITHUB_TOKEN=…")
            }
        }
    }

    @ViewBuilder
    private var importSection: some View {
        AppCard(title: "Available MCP Servers") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Scans Claude Desktop, Claude Code, and Codex config files read-only. Selected servers are copied into ~/.pi/agent/mcp.json.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)

                if isScanningImports {
                    HStack(spacing: 8) {
                        AppSpinner().controlSize(.small)
                        Text("Scanning known config files…")
                            .font(.callout)
                            .foregroundStyle(AppTheme.mutedText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                } else if importCandidates.isEmpty {
                    ContentUnavailableView("No importable servers", systemImage: "tray", description: Text("No Claude or Codex MCP servers were found that are not already in Agent Deck."))
                        .frame(maxWidth: .infinity, minHeight: 160)
                } else {
                    VStack(spacing: 0) {
                        ForEach(importCandidates) { candidate in
                            importRow(candidate)
                            if candidate.id != importCandidates.last?.id { Divider() }
                        }
                    }
                    .background(AppTheme.contentSubtleFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(AppTheme.contentStroke.opacity(0.8), lineWidth: 1)
                    )
                }
            }
        }
    }

    private func importRow(_ candidate: MCPForeignConfigScanner.Candidate) -> some View {
        let isSelected = Binding(
            get: { selectedImportIDs.contains(candidate.id) },
            set: { isSelected in
                if isSelected { selectedImportIDs.insert(candidate.id) }
                else { selectedImportIDs.remove(candidate.id) }
            }
        )

        return HStack(alignment: .center, spacing: 12) {
            Toggle("", isOn: isSelected)
                .appCheckbox()
                .labelsHidden()
                .frame(width: 18)
                .allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(candidate.name)
                        .font(.callout.weight(.semibold))
                    Text(candidate.config.resolvedTransport == .stdio ? "Local" : "Remote")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AppTheme.mutedText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(AppTheme.contentFill, in: Capsule())
                }
                Text("\(candidate.sourceName) · \(candidate.sourcePath)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(AppTheme.mutedText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { isSelected.wrappedValue.toggle() }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// A name for a pasted server when the source didn't carry one.
    private func derivedName(_ parsed: MCPParsedServer) -> String {
        if let parsedName = parsed.name?.trimmingCharacters(in: .whitespacesAndNewlines), !parsedName.isEmpty {
            return parsedName
        }
        if let urlString = parsed.config.url, let host = URL(string: urlString)?.host {
            let labels = host.split(separator: ".").map(String.init)
            return labels.first { !["api", "www", "mcp", "app"].contains($0) } ?? host
        }
        if let command = parsed.config.command { return (command as NSString).lastPathComponent }
        return "mcp-server"
    }

    private func save() {
        if isPasting {
            for parsed in MCPConfigParser.parse(pasteText) {
                onSave(derivedName(parsed), parsed.config)
            }
            dismiss()
            return
        }
        if isImportingServers {
            for candidate in importCandidates where selectedImportIDs.contains(candidate.id) {
                onSave(candidate.name, candidate.config)
            }
            dismiss()
            return
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var config = MCPServerConfig()
        if isRemote {
            config.url = url.trimmingCharacters(in: .whitespacesAndNewlines)
            config.transport = .http
            config.headers = parsePairs(headersText, separator: ":")
        } else {
            config.command = command.trimmingCharacters(in: .whitespacesAndNewlines)
            let args = argsText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            config.args = args.isEmpty ? nil : args
            config.env = parsePairs(envText, separator: "=")
            config.transport = .stdio
        }
        onSave(trimmedName, config)
        dismiss()
    }

    @MainActor
    private func scanImportCandidates() async {
        isScanningImports = true
        let names = existingNames
        let candidates = await Task.detached(priority: .userInitiated) {
            MCPForeignConfigScanner().scan(excluding: names, projectRoot: projectRoot)
        }.value
        importCandidates = candidates
        selectedImportIDs = Set(candidates.map(\.id))
        isScanningImports = false
    }

    private func parsePairs(_ text: String, separator: Character) -> [String: String]? {
        var result: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: separator, maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { result[key] = parts[1].trimmingCharacters(in: .whitespaces) }
        }
        return result.isEmpty ? nil : result
    }
}

