import AppKit
import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = AppViewModel()
    @State private var agentDraft: AgentEditorDraft?
    @State private var editingAgent: EffectiveAgentRecord?
    @State private var chainDraft: ChainEditorDraft?
    @State private var envDraft: EnvEditorDraft?
    @State private var subagentConfigDraft: SubagentConfigDraft?
    @State private var projectFilterText = ""
    @State private var debouncedProjectFilterText = ""
    @State private var agentDetailEditCommand = 0
    @State private var agentDetailIsEditing = false
    @State private var isSkillsInfoPresented = false
    @State private var isSkillsRecapPresented = false
    @State private var isSubagentsInfoPresented = false
    @State private var isSubagentsRecapPresented = false

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image("pi")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 22, height: 22)
                        .foregroundStyle(.secondary)
                    Text("Pi Manager")
                        .font(.system(size: 15, weight: .bold, design: .default))
                        .fontWidth(.expanded)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 14)

                List(selection: $viewModel.selectedSidebarItem) {
                    ForEach(SidebarSection.allCases) { section in
                        Section(section.rawValue) {
                            ForEach(section.items) { item in
                                HStack(spacing: 8) {
                                    if item == .github || item == .agent {
                                        Image(item == .github ? "github" : "pi")
                                            .resizable()
                                            .renderingMode(.template)
                                            .aspectRatio(contentMode: .fit)
                                            .frame(width: 16, height: 16)
                                            .foregroundStyle(.secondary)
                                    } else {
                                        Image(systemName: item.systemImage)
                                            .frame(width: 16, height: 16)
                                            .foregroundStyle(.secondary)
                                    }

                                    Text(item.rawValue)
                                    if item == .agent, viewModel.piAgentNeedsAttentionCount > 0 {
                                        Text("\(viewModel.piAgentNeedsAttentionCount)")
                                            .font(.caption2.weight(.bold))
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Capsule(style: .continuous).fill(Color.accentColor))
                                    }
                                }
                                .fontWidth(.expanded)
                                .tag(item)
                            }
                        }
                    }
                }

                Spacer(minLength: 0)

                SidebarProjectGitHubCard(
                    viewModel: viewModel,
                    projects: filteredProjects,
                    selectedProject: selectedProject,
                    selectedProjectPath: viewModel.selectedProjectPath,
                    favoriteProjectPaths: Set(viewModel.favoriteProjects.map(\.path)),
                    filterText: $projectFilterText,
                    isSearchDebouncing: projectFilterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != debouncedProjectFilterText,
                    onSelectAll: { viewModel.clearProjectRoot() },
                    onSelectProject: { viewModel.setSelectedProject($0.url) },
                    onToggleFavorite: viewModel.toggleProjectFavorite,
                    onChooseProject: { viewModel.chooseProjectRoot() }
                )
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 16)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 300)
        } detail: {
            HStack(spacing: 0) {
                detailView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if viewModel.isPiAgentInspectorPresented && viewModel.selectedSidebarItem != .agent {
                    Divider()
                    PiAgentInspectorPanel(viewModel: viewModel, store: viewModel.piAgentSessionStore)
                        .frame(width: 380)

                }
            }

        }
        .frame(minWidth: 1180, minHeight: 760)
        .navigationTitle(toolbarTitle)
        .toolbar {
            if viewModel.selectedSidebarItem == .projects {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        viewModel.chooseProjectRoot()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help("Add project manually")
                }
            }

            if viewModel.selectedSidebarItem == .agents {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        isSubagentsInfoPresented.toggle()
                    } label: {
                        Label("Info", systemImage: "info.circle")
                    }
                    .help("Explain subagent library visibility")
                    .popover(isPresented: $isSubagentsInfoPresented, arrowEdge: .bottom) {
                        SubagentsInfoPopover()
                    }

                    Button {
                        isSubagentsRecapPresented.toggle()
                    } label: {
                        Label("Project Recap", systemImage: "sidebar.right")
                    }
                    .help("Show subagents available for the selected project")
                    .disabled(viewModel.selectedProjectPath == nil)

                    Divider()

                    Menu {
                        ForEach(AgentFilter.allCases) { filter in
                            Button {
                                viewModel.selectedAgentFilter = filter
                            } label: {
                                if viewModel.selectedAgentFilter == filter {
                                    Label(filter.rawValue, systemImage: "checkmark")
                                } else {
                                    Text(filter.rawValue)
                                }
                            }
                        }
                    } label: {
                        Label(viewModel.selectedAgentFilter.rawValue, systemImage: "line.3.horizontal.decrease.circle")
                    }
                    .help("Filter agents")
                }

                ToolbarItem(placement: .confirmationAction) {
                    Menu {
                        Button("New Global Agent") {
                            editingAgent = nil
                            agentDraft = viewModel.makeNewAgentDraft(scope: .global)
                        }
                        if viewModel.selectedProjectPath != nil {
                            Button("New Project Agent") {
                                editingAgent = nil
                                agentDraft = viewModel.makeNewAgentDraft(scope: .project)
                            }
                        }
                    } label: {
                        Label("New Agent", systemImage: "plus")
                    } primaryAction: {
                        editingAgent = nil
                        agentDraft = viewModel.makeNewAgentDraft(scope: viewModel.selectedProjectPath == nil ? .global : .project)
                    }
                    .buttonStyle(.borderedProminent)
                    .help("Create a new custom agent")
                }

                ToolbarItemGroup(placement: .primaryAction) {
                    Menu {
                        if let agent = viewModel.selectedAgent {
                            Button("Create Global Replacement File") {
                                editingAgent = nil
                                agentDraft = viewModel.makeReplacementAgentDraft(from: agent, scope: .global)
                            }
                            .disabled(!(agent.builtin != nil && agent.globalCustom == nil))

                            if viewModel.selectedProjectPath != nil {
                                Button("Create Project Replacement File") {
                                    editingAgent = nil
                                    agentDraft = viewModel.makeReplacementAgentDraft(from: agent, scope: .project)
                                }
                                .disabled(agent.projectCustom != nil)
                            }
                        } else {
                            Text("Select an agent first")
                        }
                    } label: {
                        Label("Replacement", systemImage: "doc.on.doc")
                    }
                    .help("Create a same-name agent file that overrides the selected agent")
                }

                if let agent = viewModel.selectedAgent {
                    ToolbarSpacer(.fixed, placement: .primaryAction)

                    ToolbarItemGroup(placement: .primaryAction) {
                        Menu {
                            Button("Open Raw File") { openSelectedAgentFile() }
                                .disabled(selectedAgentFilePath == nil)
                            Button("Reveal in Finder") { revealSelectedAgentFile() }
                                .disabled(selectedAgentFilePath == nil)
                        } label: {
                            Label("Open", systemImage: "folder")
                        }
                        .help("Open or reveal the selected agent file")

                        if agent.resolved.disabled == true {
                            Button {
                                setSelectedAgentDisabled(false)
                            } label: {
                                Label("Enable", systemImage: "checkmark.circle")
                            }
                            .help("Enable selected agent")
                        } else {
                            Button(role: .destructive) {
                                setSelectedAgentDisabled(true)
                            } label: {
                                Label("Disable", systemImage: "nosign")
                            }
                            .help("Disable selected agent")
                        }

                        Button {
                            agentDetailEditCommand += 1
                        } label: {
                            Label(agentDetailIsEditing ? "Done" : "Edit", systemImage: agentDetailIsEditing ? "checkmark" : "pencil")
                        }
                        .help(agentDetailIsEditing ? "Finish editing selected agent" : "Edit selected agent")
                    }
                }
            }

            if viewModel.selectedSidebarItem == .environment {
                ToolbarItem(placement: .confirmationAction) {
                    Menu {
                        Button("New Global Key") {
                            envDraft = viewModel.makeNewEnvDraft(scope: .global)
                        }
                        if viewModel.selectedProjectPath != nil {
                            Button("New Project Key") {
                                envDraft = viewModel.makeNewEnvDraft(scope: .project)
                            }
                        }
                    } label: {
                        Label("New Key", systemImage: "plus")
                    } primaryAction: {
                        envDraft = viewModel.makeNewEnvDraft(scope: viewModel.selectedProjectPath == nil ? .global : .project)
                    }
                    .buttonStyle(.borderedProminent)
                    .help("Create a new environment key")
                }
            }

            if viewModel.selectedSidebarItem == .chains {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        isSubagentsInfoPresented.toggle()
                    } label: {
                        Label("Info", systemImage: "info.circle")
                    }
                    .help("Explain subagent library visibility")
                    .popover(isPresented: $isSubagentsInfoPresented, arrowEdge: .bottom) {
                        SubagentsInfoPopover()
                    }

                    Button {
                        isSubagentsRecapPresented.toggle()
                    } label: {
                        Label("Project Recap", systemImage: "sidebar.right")
                    }
                    .help("Show subagents available for the selected project")
                    .disabled(viewModel.selectedProjectPath == nil)
                }
            }

            if viewModel.selectedSidebarItem == .skills {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        isSkillsInfoPresented.toggle()
                    } label: {
                        Label("Info", systemImage: "info.circle")
                    }
                    .help("Explain Pi skill visibility")
                    .popover(isPresented: $isSkillsInfoPresented, arrowEdge: .bottom) {
                        SkillsInfoPopover()
                    }

                    Button {
                        isSkillsRecapPresented.toggle()
                    } label: {
                        Label("Project Recap", systemImage: "sidebar.right")
                    }
                    .help("Show skills Pi will load for the selected project")
                    .disabled(viewModel.selectedProjectPath == nil)
                }
            }

            if viewModel.selectedSidebarItem == .agent {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        viewModel.openRepoChangesForSelectedPiAgentSession()
                    } label: {
                        Image(systemName: "arrow.triangle.branch")
                    }
                    .help("Repo changes")
                    .disabled(viewModel.piAgentSessionStore.selectedSession == nil)
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        viewModel.openTerminalForSelectedPiAgentSession()
                    } label: {
                        Image(systemName: "terminal")
                    }
                    .help("Open this session's project in Terminal")
                    .disabled(viewModel.piAgentSessionStore.selectedSession == nil)
                }

                ToolbarSpacer(.fixed, placement: .primaryAction)

                ToolbarItem(placement: .primaryAction) {
                    Button(role: .destructive) {
                        if let session = viewModel.piAgentSessionStore.selectedSession {
                            viewModel.deletePiAgentSession(session.id)
                        }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help("Delete session")
                    .disabled(viewModel.piAgentSessionStore.selectedSession == nil)
                }
            }
        }
        .task(id: projectFilterText) {
            let trimmed = projectFilterText.trimmingCharacters(in: .whitespacesAndNewlines)
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            debouncedProjectFilterText = trimmed.lowercased()
        }
        .sheet(item: $agentDraft) { draft in
            AgentEditorSheet(
                draft: draft,
                availableTools: viewModel.availableToolNames(for: draft.target),
                availableSkills: viewModel.availableSkillNames(for: draft.target),
                availableModels: viewModel.availableModels,
                modelsLastUpdatedAt: viewModel.modelsLastUpdatedAt,
                onCancel: {
                    agentDraft = nil
                    editingAgent = nil
                },
                onSave: { updated in
                    if let editingAgent {
                        try viewModel.saveAgentDraft(updated, for: editingAgent)
                    } else {
                        try viewModel.saveNewAgentDraft(updated)
                    }
                    agentDraft = nil
                    self.editingAgent = nil
                }
            )
        }
        .sheet(item: $chainDraft) { draft in
            ChainEditorSheet(
                draft: draft,
                onCancel: { chainDraft = nil },
                onSave: { updated in
                    try viewModel.saveChainDraft(updated)
                    chainDraft = nil
                }
            )
        }
        .sheet(item: $envDraft) { draft in
            EnvEditorSheet(
                draft: draft,
                onCancel: { envDraft = nil },
                onSave: { updated in
                    try viewModel.saveEnvDraft(updated)
                    envDraft = nil
                }
            )
        }
        .sheet(item: $subagentConfigDraft) { draft in
            SubagentConfigEditorSheet(
                draft: draft,
                onCancel: { subagentConfigDraft = nil },
                onSave: { updated in
                    try viewModel.saveSubagentConfigDraft(updated)
                    subagentConfigDraft = nil
                }
            )
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch viewModel.selectedSidebarItem {
        case .overview:
            OverviewScreen(viewModel: viewModel)
        case .projects:
            ProjectsScreen(viewModel: viewModel)
        case .agents:
            AgentsScreen(
                viewModel: viewModel,
                editCommand: agentDetailEditCommand,
                isEditing: $agentDetailIsEditing,
                isRecapPresented: $isSubagentsRecapPresented
            )
        case .chains:
            ChainsScreen(
                viewModel: viewModel,
                onCreateChain: { scope in
                    chainDraft = viewModel.makeNewChainDraft(scope: scope)
                },
                onDuplicateChain: { chain, scope in
                    chainDraft = viewModel.makeDuplicateChainDraft(from: chain, scope: scope)
                },
                onConvertChain: { chain, scope in
                    try viewModel.convertChain(chain, to: scope)
                },
                onEditChain: { chain in
                    chainDraft = viewModel.makeChainDraft(for: chain)
                },
                isRecapPresented: $isSubagentsRecapPresented
            )
        case .skills:
            SkillsScreen(viewModel: viewModel, isRecapPresented: $isSkillsRecapPresented)
        case .commandsAndPrompts:
            CommandsAndPromptsScreen(viewModel: viewModel)
        case .github:
            GitHubScreen(viewModel: viewModel)
        case .agent:
            PiAgentScreen(viewModel: viewModel, store: viewModel.piAgentSessionStore)
        case .models:
            ModelsScreen(viewModel: viewModel)
        case .settings:
            SettingsScreen(viewModel: viewModel)
        case .subagents:
            SubagentsScreen(
                viewModel: viewModel,
                onEditConfig: {
                    subagentConfigDraft = viewModel.makeSubagentConfigDraft()
                },
                onRestoreDefaults: {
                    viewModel.restoreDefaultSubagentConfig()
                }
            )
        case .environment:
            EnvironmentScreen(
                snapshot: viewModel.snapshot,
                onEditKey: { record in
                    envDraft = viewModel.makeEnvDraft(for: record)
                }
            )
        case .mcp:
            MCPScreen(snapshot: viewModel.snapshot)
        case .diagnostics:
            DiagnosticsScreen(snapshot: viewModel.snapshot)
        }
    }

    private var toolbarTitle: String {
        switch viewModel.selectedSidebarItem {
        case .overview:
            return viewModel.selectedDiscoveredProject?.name ?? "Overview"
        case .agents:
            return viewModel.selectedAgent?.name ?? "Agents"
        case .agent:
            return viewModel.piAgentSessionStore.selectedSession?.displayTitle ?? "Pi Agent"
        case .skills:
            return viewModel.selectedSkill?.name ?? "Skills"
        default:
            return viewModel.selectedSidebarItem.rawValue
        }
    }

    private var filteredProjects: [DiscoveredProject] {
        let query = debouncedProjectFilterText
        guard !query.isEmpty else { return viewModel.enabledProjects }

        return viewModel.enabledProjects.filter { project in
            project.searchIndex.contains(query)
        }
    }

    private var selectedProject: DiscoveredProject? {
        guard let selectedProjectPath = viewModel.selectedProjectPath else { return nil }
        return viewModel.discoveredProjects.first(where: { $0.path == selectedProjectPath })
    }

    private var selectedAgentFilePath: String? {
        guard let agent = viewModel.selectedAgent else { return nil }
        return agent.sourcePath ?? agent.projectOverride?.settingsPath ?? agent.userOverride?.settingsPath
    }

    private func openSelectedAgentFile() {
        guard let path = selectedAgentFilePath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private func revealSelectedAgentFile() {
        guard let path = selectedAgentFilePath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func openSelectedSkillFile() {
        guard let skill = viewModel.selectedSkill else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: skill.filePath))
    }

    private func revealSelectedSkillFile() {
        guard let skill = viewModel.selectedSkill else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: skill.filePath)])
    }

    private func addSelectedSkillToProject() {
        guard let skill = viewModel.selectedSkill else { return }
        do { try viewModel.addSkillToSelectedProject(skill) } catch { NSSound.beep() }
    }

    private func removeSelectedSkillFromProject() {
        guard let skill = viewModel.selectedSkill else { return }
        do { try viewModel.removeSkillFromSelectedProject(skill) } catch { NSSound.beep() }
    }

    private func enableSelectedSkillGlobally() {
        guard let skill = viewModel.selectedSkill else { return }
        do { try viewModel.enableSkillGlobally(skill) } catch { NSSound.beep() }
    }

    private func disableSelectedSkillGlobally() {
        guard let skill = viewModel.selectedSkill else { return }
        do { try viewModel.disableSkillGlobally(skill) } catch { NSSound.beep() }
    }

    private func setSelectedAgentDisabled(_ isDisabled: Bool) {
        guard let agent = viewModel.selectedAgent else { return }
        do {
            try viewModel.setAgentDisabled(isDisabled, for: agent)
        } catch {
            NSSound.beep()
        }
    }

}

private struct SidebarProjectGitHubCard: View {
    @ObservedObject var viewModel: AppViewModel
    let projects: [DiscoveredProject]
    let selectedProject: DiscoveredProject?
    let selectedProjectPath: String?
    let favoriteProjectPaths: Set<String>
    @Binding var filterText: String
    let isSearchDebouncing: Bool
    let onSelectAll: () -> Void
    let onSelectProject: (DiscoveredProject) -> Void
    let onToggleFavorite: (DiscoveredProject) -> Void
    let onChooseProject: () -> Void

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                ProjectIconView(
                    imageURL: selectedProject?.iconFileURL,
                    symbolName: selectedProject?.fallbackSymbolName ?? "folder",
                    size: 34
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(selectedProjectTitle)
                        .font(.body)
                        .fontWeight(.medium)
//                        .fontWidth(selectedProject != nil ? .expanded : .standard )
                        .lineLimit(1)
                    if selectedProject != nil {
                        Text(selectedProjectSubtitle)
                            .font(.callout)
                            .fontWeight(.regular)
                            .foregroundStyle(AppTheme.mutedText)
                            .lineLimit(1)
                            .fontWidth(.compressed)
                    }
                }

                Spacer(minLength: 8)

                Button {
                    isExpanded.toggle()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(AppTheme.subtleFill))
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .buttonStyle(.plain)
                .popover(isPresented: $isExpanded, arrowEdge: .bottom) {
                    ProjectPickerPopover(
                        projects: orderedProjects,
                        selectedProjectPath: selectedProjectPath,
                        favoriteProjectPaths: favoriteProjectPaths,
                        filterText: $filterText,
                        isSearchDebouncing: isSearchDebouncing,
                        onSelectAll: {
                            onSelectAll()
                            isExpanded = false
                        },
                        onSelectProject: { project in
                            onSelectProject(project)
                            isExpanded = false
                        },
                        onToggleFavorite: onToggleFavorite
                    )
                }
            }

            Divider()
                .opacity(0.7)

            HStack(spacing: 12) {
                SidebarGitHubAvatarView(url: avatarURL, size: 32)
                    .overlay(alignment: Alignment.bottomTrailing) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 10, height: 10)
                            .overlay(Circle().stroke(AppTheme.cardFill, lineWidth: 2))
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(accountName)
                        .fontWeight(.medium)
//                        .fontWidth(.expanded)
                        .lineLimit(1)
                    Text(statusText)
                        .font(.callout)
                        .fontWeight(.regular)
                        .foregroundStyle(AppTheme.mutedText)
                        .fontWidth(.compressed)
                }

                Spacer()

                Button {
                    viewModel.refreshEverything()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppTheme.mutedText)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(AppTheme.subtleFill))
                        .symbolEffect(.rotate.byLayer, isActive: viewModel.githubIsRefreshingEverything)
                }
                .buttonStyle(.plain)
                .help("Refresh GitHub status, project scans, and repo data")
                .disabled(viewModel.githubIsRefreshingEverything)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .animation(.easeInOut(duration: 0.16), value: isExpanded)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(AppTheme.cardFill)
                .stroke(AppTheme.cardStroke, lineWidth: 1)
        )
    }

    private var favoriteProjects: [DiscoveredProject] {
        projects.filter { favoriteProjectPaths.contains($0.path) }
    }

    private var otherProjects: [DiscoveredProject] {
        projects.filter { !favoriteProjectPaths.contains($0.path) }
    }

    private var orderedProjects: [DiscoveredProject] {
        favoriteProjects + otherProjects
    }

    private var selectedProjectTitle: String {
        if let remote = selectedProject?.gitHubRemote {
            return remote.repo
        }
        return selectedProject?.name ?? "Select project"
    }

    private var selectedProjectSubtitle: String {
        if let remote = selectedProject?.gitHubRemote {
            return remote.owner
        }
        return selectedProject != nil ? selectedProject?.path ?? "" : ""
    }

    private var accountName: String {
        viewModel.currentGitHubAccount?.login ?? "GitHub"
    }

    private var statusText: String {
        if viewModel.githubIsRefreshingEverything {
            return "Refreshing…"
        }

        switch viewModel.githubConnectionState {
        case .connected:
            return "Connected"
        case .checking:
            return "Connecting…"
        case .failed:
            return "Error"
        case .available:
            return "Ready"
        case .unavailable:
            return "Unavailable"
        case .disconnected:
            return "Inactive"
        }
    }

    private var statusColor: Color {
        switch viewModel.githubConnectionState {
        case .connected:
            return .green
        case .failed:
            return .red
        default:
            return .secondary
        }
    }

    private var avatarURL: URL? {
        guard let account = viewModel.currentGitHubAccount,
              account.host.caseInsensitiveCompare("github.com") == .orderedSame else { return nil }
        return URL(string: "https://avatars.githubusercontent.com/\(account.login)")
    }

}

private struct ProjectPickerPopover: View {
    let projects: [DiscoveredProject]
    let selectedProjectPath: String?
    let favoriteProjectPaths: Set<String>
    @Binding var filterText: String
    let isSearchDebouncing: Bool
    let onSelectAll: () -> Void
    let onSelectProject: (DiscoveredProject) -> Void
    let onToggleFavorite: (DiscoveredProject) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                TextField("Search enabled projects", text: $filterText)
                    .textFieldStyle(.roundedBorder)

                if isSearchDebouncing {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ProjectSidebarRow(
                        title: "All Projects",
                        subtitle: "No project selected",
                        symbolName: "square.grid.2x2",
                        imageURL: nil,
                        isSelected: selectedProjectPath == nil,
                        isFavorite: false,
                        showsFavoriteButton: false,
                        onToggleFavorite: nil,
                        action: onSelectAll
                    )

                    ForEach(projects) { project in
                        ProjectSidebarRow(
                            title: project.repositoryDisplayName,
                            subtitle: project.path,
                            symbolName: project.fallbackSymbolName,
                            imageURL: project.iconFileURL,
                            isSelected: selectedProjectPath == project.path,
                            isFavorite: favoriteProjectPaths.contains(project.path),
                            showsFavoriteButton: true,
                            onToggleFavorite: { onToggleFavorite(project) },
                            action: { onSelectProject(project) }
                        )
                    }
                }
            }
            .frame(width: 360, height: 220)
        }
        .padding(14)
    }
}

private struct ProjectSidebarRow: View {
    let title: String
    let subtitle: String
    let symbolName: String
    let imageURL: URL?
    let isSelected: Bool
    let isFavorite: Bool
    let showsFavoriteButton: Bool
    let onToggleFavorite: (() -> Void)?
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: action) {
                HStack(spacing: 10) {
                    ProjectIconView(imageURL: imageURL, symbolName: symbolName, size: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(AppTheme.mutedText)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isSelected ? Color.accentColor.opacity(0.12) : AppTheme.subtleFill.opacity(0.22))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(isSelected ? Color.accentColor.opacity(0.35) : AppTheme.cardStroke, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)

            if showsFavoriteButton, let onToggleFavorite {
                Button(action: onToggleFavorite) {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .font(.caption)
                        .foregroundStyle(isFavorite ? Color.yellow : AppTheme.mutedText)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(AppTheme.subtleFill.opacity(0.8)))
                }
                .buttonStyle(.plain)
                .help(isFavorite ? "Remove favorite" : "Add favorite")
            }
        }
    }
}

private struct SidebarGitHubAvatarView: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case let .success(image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        Image("github")
                            .resizable()
                            .renderingMode(.template)
                            .scaledToFit()
                            .padding(7)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Image("github")
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .padding(7)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .background(
            Circle()
                .fill(AppTheme.subtleFill)
        )
        .clipShape(Circle())
    }
}

private struct ProjectIconEditorButton: View {
    let imageURL: URL?
    let symbolName: String
    let size: CGFloat
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomTrailing) {
                ProjectIconView(imageURL: imageURL, symbolName: symbolName, size: size)

                if isHovering {
                    Image(systemName: "pencil.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .background(Circle().fill(Color.accentColor))
                        .offset(x: 4, y: 4)
                        .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .help(imageURL == nil ? "Set custom icon" : "Change custom icon")
    }
}

private struct ProjectIconView: View {
    let imageURL: URL?
    let symbolName: String
    let size: CGFloat

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: symbolName)
                    .resizable()
                    .scaledToFit()
                    .padding(6)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppTheme.subtleFill)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task(id: imageURL?.path) {
            await loadImage()
        }
    }

    private func loadImage() async {
        guard let imageURL else {
            image = nil
            return
        }

        if let cachedImage = await ProjectIconCache.shared.cachedImage(for: imageURL) {
            image = cachedImage
            return
        }

        let loadedImage = await ProjectIconCache.shared.loadImage(for: imageURL)
        guard imageURL == self.imageURL else { return }
        image = loadedImage
    }
}

private actor ProjectIconCache {
    static let shared = ProjectIconCache()

    private let cache = NSCache<NSString, NSImage>()

    func cachedImage(for url: URL) -> NSImage? {
        cache.object(forKey: url.path as NSString)
    }

    func loadImage(for url: URL) async -> NSImage? {
        if let cachedImage = cache.object(forKey: url.path as NSString) {
            return cachedImage
        }

        let image = await Task.detached(priority: .utility) {
            NSImage(contentsOf: url)
        }.value

        if let image {
            cache.setObject(image, forKey: url.path as NSString)
        }

        return image
    }
}

private struct ProjectsScreen: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case enabled = "Enabled"
        case disabled = "Disabled"
        case favorites = "Favorites"

        var id: String { rawValue }
    }

    @ObservedObject var viewModel: AppViewModel
    @State private var filter: Filter = .all
    @State private var searchText = ""
    @State private var debouncedSearchText = ""

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 16)], spacing: 16) {
                    AppMetricTile(title: "All Projects", value: viewModel.discoveredProjects.count)
                    AppMetricTile(title: "Enabled", value: viewModel.enabledProjects.count)
                    AppMetricTile(title: "Favorites", value: viewModel.favoriteProjects.count)
                    AppMetricTile(title: "GitHub Repos", value: viewModel.gitHubProjects.count)
                }

                AppCard(title: "Library", trailing: {
                    if isSearchDebouncing {
                        ProgressView()
                            .controlSize(.small)
                    }
                }) {
                    if viewModel.discoveredProjects.isEmpty {
                        ContentUnavailableView(
                            "No Projects Yet",
                            systemImage: "folder",
                            description: Text("Projects from ~/Documents/GitHub will appear here automatically.")
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    } else {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(spacing: 12) {
                                TextField("Search projects", text: $searchText)
                                    .textFieldStyle(.roundedBorder)

                                Picker("Filter", selection: $filter) {
                                    ForEach(Filter.allCases) { option in
                                        Text(option.rawValue).tag(option)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .frame(maxWidth: 340)
                            }

                            LazyVStack(alignment: .leading, spacing: 10) {
                                ForEach(visibleProjects) { project in
                                    projectCard(project)
                                }
                            }
                        }
                    }
                }
            }
            .padding(AppTheme.pagePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: searchText) {
            let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            debouncedSearchText = trimmed.lowercased()
        }
    }

    private var isSearchDebouncing: Bool {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != debouncedSearchText
    }

    private var visibleProjects: [DiscoveredProject] {
        let query = debouncedSearchText

        return viewModel.discoveredProjects.filter { project in
            let preference = viewModel.projectPreference(for: project.path)

            let matchesFilter: Bool = switch filter {
            case .all: true
            case .enabled: preference.isEnabled
            case .disabled: !preference.isEnabled
            case .favorites: preference.isFavorite
            }

            guard matchesFilter else { return false }
            guard !query.isEmpty else { return true }

            return project.searchIndex.contains(query)
        }
    }

    @ViewBuilder
    private func projectCard(_ project: DiscoveredProject) -> some View {
        let preference = viewModel.projectPreference(for: project.path)
        let isSelected = viewModel.selectedProjectPath == project.path

        AppRowCard {
            HStack(alignment: .center, spacing: 14) {
                ProjectIconEditorButton(
                    imageURL: project.iconFileURL,
                    symbolName: project.fallbackSymbolName,
                    size: 44,
                    action: { viewModel.chooseCustomIcon(for: project) }
                )

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(project.repositoryDisplayName)
                            .font(.headline)
                            .fontWidth(.expanded)

                        if project.isGitHubRepository {
                            Image("github")
                                .resizable()
                                .renderingMode(.template)
                                .foregroundStyle(.secondary)
                                .frame(width: 14, height: 14)
                        }
                    }

                    Text(project.path)
                        .font(.footnote.monospaced())
                        .foregroundStyle(AppTheme.mutedText)
                        .textSelection(.enabled)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                HStack(spacing: 8) {
                    Button(action: { viewModel.toggleProjectFavorite(project) }) {
                        Image(systemName: preference.isFavorite ? "star.fill" : "star")
                            .foregroundStyle(preference.isFavorite ? AnyShapeStyle(LinearGradient(colors: [.yellow, .orange], startPoint: .topLeading, endPoint: .bottomTrailing)) : AnyShapeStyle(AppTheme.mutedText))
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(AppTheme.subtleFill))
                    }
                    .buttonStyle(.plain)
                    .help(preference.isFavorite ? "Remove favorite" : "Add favorite")

                    if preference.customIconPath != nil {
                        Button(action: { viewModel.clearCustomIcon(for: project) }) {
                            Image(systemName: "trash")
                                .foregroundStyle(AppTheme.mutedText)
                                .frame(width: 28, height: 28)
                                .background(Circle().fill(AppTheme.subtleFill))
                        }
                        .buttonStyle(.plain)
                        .help("Remove custom icon")
                    }

                    Button(action: {
                        guard preference.isEnabled else { return }
                        if isSelected {
                            viewModel.clearProjectRoot()
                        } else {
                            viewModel.setSelectedProject(project.url)
                        }
                    }) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "checkmark.circle")
                            .foregroundStyle(preference.isEnabled ? (isSelected ? Color.accentColor : AppTheme.mutedText) : AppTheme.mutedText.opacity(0.35))
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(AppTheme.subtleFill))
                    }
                    .buttonStyle(.plain)
                    .disabled(!preference.isEnabled)
                    .help(isSelected ? "Show all projects" : "Select project")

                    Toggle("Enabled", isOn: Binding(
                        get: { preference.isEnabled },
                        set: { viewModel.setProjectEnabled($0, for: project) }
                    ))
                    .toggleStyle(.switch)
                    .tint(.accentColor)
                    .labelsHidden()
                    .help(preference.isEnabled ? "Disable project" : "Enable project")
                }
            }
            .opacity(preference.isEnabled ? 1 : 0.5)
        }
    }
}

private struct OverviewScreen: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        AppPage("Overview", subtitle: viewModel.snapshot.projectRoot ?? "Showing global resources and the selected project’s GitHub work") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 16)], spacing: 16) {
                AppMetricTile(title: "Builtin Agents", value: viewModel.snapshot.builtinAgents.count)
                AppMetricTile(title: "Global Agents", value: viewModel.snapshot.globalAgents.count)
                AppMetricTile(title: "Project Agents", value: viewModel.snapshot.projectAgents.count)
                AppMetricTile(title: "Overrides", value: viewModel.snapshot.settings.flatMap(\.agentOverrides).count)
                AppMetricTile(title: "Chains", value: viewModel.snapshot.chains.count)
                AppMetricTile(title: "Skills", value: viewModel.snapshot.skills.count)
                AppMetricTile(title: "Commands", value: viewModel.snapshot.commands.count)
                AppMetricTile(title: "Prompt Templates", value: viewModel.snapshot.promptTemplates.count)
                AppMetricTile(title: "Warnings", value: viewModel.snapshot.warnings.count)
                AppMetricTile(title: "Open Issues", value: viewModel.githubOverviewBoard?.totalCount ?? 0)
            }

            AppCard(title: "Open Issues", trailing: {
                if let board = viewModel.githubOverviewBoard {
                    Text("\(board.totalCount)")
                        .foregroundStyle(AppTheme.mutedText)
                }
            }) {
                GitHubIssuesWorkspace(
                    viewModel: viewModel,
                    board: viewModel.githubOverviewBoard,
                    isLoading: viewModel.githubIsLoadingOverviewBoard,
                    showStateFilter: false,
                    refreshAction: { viewModel.refreshOverviewBoard(force: true) }
                )
            }

            AppCard(title: "How pi-subagents Works") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("• Pi is the parent session. A subagent is a child session with a narrower job.")
                    Text("• `context: fork` keeps a branched session history. It is not the same thing as inheriting project context files.")
                    Text("• Background runs can be checked later with status/doctor tooling; foreground runs stream back into the chat.")
                    Text("• Parallel editing is safest with worktrees so children do not fight over the same files.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            AppCard(title: "Detected Packages") {
                if viewModel.packageNames.isEmpty {
                    Text("No packages found in scanned settings.")
                        .foregroundStyle(AppTheme.mutedText)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(viewModel.packageNames, id: \.self) { package in
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: "shippingbox")
                                    .foregroundStyle(AppTheme.mutedText)
                                Text(package)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }

            AppCard(title: "Warnings") {
                if viewModel.snapshot.warnings.isEmpty {
                    Label("No warnings in the current scan.", systemImage: "checkmark.circle")
                        .foregroundStyle(AppTheme.mutedText)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(viewModel.snapshot.warnings.prefix(10)) { warning in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "exclamationmark.triangle")
                                    .foregroundStyle(.orange)
                                Text(warning.message)
                            }
                        }
                    }
                }
            }
        }
        .task {
            await Task.yield()
            await viewModel.prepareGitHubScreen()
        }
        .task(id: overviewBoardRefreshKey) {
            await Task.yield()
            guard viewModel.githubConnectionState.isConnected,
                  viewModel.selectedGitHubProject?.gitHubRemote != nil else { return }
            viewModel.refreshOverviewBoard(force: false)
        }
    }

    private var overviewBoardRefreshKey: String {
        [
            viewModel.selectedGitHubProject?.path ?? "none",
            viewModel.githubConnectionState.isConnected ? "connected" : "disconnected"
        ].joined(separator: "|")
    }
}

private struct SettingsScreen: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        AppPage("Settings", subtitle: "App-level preferences for Pi Manager") {
            AppCard(title: "GitHub") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Tune how long GitHub issue data stays fresh before Pi Manager reloads it.")
                        .foregroundStyle(AppTheme.mutedText)

                    AppStepper("Issue cache lifetime",
                               value: cacheLifetimeBinding,
                               in: 1...240,
                               unit: "minutes")

                    Text("Applies to the issue lists on the Overview and GitHub pages. Use Refresh to bypass the cache at any time.")
                        .font(.footnote)
                        .foregroundStyle(AppTheme.mutedText)
                }
            }

            AppCard(title: "Pi Agent") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Reasoning", selection: piAgentThinkingDisplayBinding) {
                        ForEach(PiAgentThinkingDisplayMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text("Matches Pi's thinking visibility behavior: show full reasoning, show a compact preview, or hide thinking blocks from the transcript.")
                        .font(.footnote)
                        .foregroundStyle(AppTheme.mutedText)
                }
            }

            AppCard(title: "Subagents") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Disable all builtins globally", isOn: userDisableBuiltinsBinding)

                    Text("Per-agent quick controls in the Agents screen also apply globally for now.")
                        .font(.footnote)
                        .foregroundStyle(AppTheme.mutedText)
                }
            }

            AppCard(title: "Future Settings") {
                Text("This page is for app-wide settings so we have one clear place to grow preferences over time.")
                    .foregroundStyle(AppTheme.mutedText)
            }
        }
    }

    private var cacheLifetimeBinding: Binding<Int> {
        Binding(
            get: { viewModel.gitHubBoardCacheLifetimeMinutes },
            set: { viewModel.setGitHubBoardCacheLifetimeMinutes($0) }
        )
    }

    private var piAgentThinkingDisplayBinding: Binding<PiAgentThinkingDisplayMode> {
        Binding(
            get: { viewModel.appSettings.piAgentThinkingDisplayMode },
            set: { viewModel.setPiAgentThinkingDisplayMode($0) }
        )
    }

    private var userDisableBuiltinsBinding: Binding<Bool> {
        Binding(
            get: { viewModel.userDisableBuiltins },
            set: { viewModel.setDisableBuiltins($0, scope: .global) }
        )
    }

}

private struct ModelsScreen: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        AppPage("Models", subtitle: "Available models from `pi --list-models`") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 16)], spacing: 16) {
                AppMetricTile(title: "Models", value: viewModel.availableModels.count)
                AppMetricTile(title: "Providers", value: viewModel.availableModelProviders.count)
                AppMetricTile(title: "Thinking", value: viewModel.availableModels.filter(\.supportsThinking).count)
                AppMetricTile(title: "Images", value: viewModel.availableModels.filter(\.supportsImages).count)
            }

            if viewModel.availableModels.isEmpty {
                AppCard(title: "Catalog", trailing: catalogUpdatedLabel) {
                    Text("No models loaded yet. Use Refresh to query Pi.")
                        .foregroundStyle(AppTheme.mutedText)
                }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text("Pi’s model catalog, grouped by provider. Thinking, image input, context, and output limits come directly from `pi --list-models`.")
                        .foregroundStyle(AppTheme.mutedText)
                    Spacer()
                    catalogUpdatedLabel()
                }

                VStack(alignment: .leading, spacing: 20) {
                    ForEach(groupedModels, id: \.provider) { group in
                        providerSection(group)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func catalogUpdatedLabel() -> some View {
        if let date = viewModel.modelsLastUpdatedAt {
            Text(RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date()))
                .foregroundStyle(AppTheme.mutedText)
        }
    }

    private func providerSection(_ group: (provider: String, models: [AvailableModel])) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(group.provider)
                    .font(.title3.weight(.bold))
                    .fontWidth(.expanded)
                    .foregroundStyle(.primary)
                Spacer()
                AppLabelTag(text: "\(group.models.count)", color: .blue)
            }
            .padding(.horizontal, 2)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(group.models.enumerated()), id: \.element.id) { index, model in
                    modelRow(model)
                    if index < group.models.count - 1 {
                        Divider()
                    }
                }
            }
            .padding(.horizontal, AppTheme.cardPadding)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius, style: .continuous)
                    .fill(AppTheme.cardFill)
                    .stroke(AppTheme.cardStroke, lineWidth: 1)
            )
        }
    }

    private func modelRow(_ model: AvailableModel) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.model)
                    .font(.headline)
                    .fontWidth(.expanded)
                Text(model.identifier)
                    .font(.footnote.monospaced())
                    .foregroundStyle(AppTheme.mutedText)
                    .textSelection(.enabled)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 8) {
                    AppLabelTag(text: model.supportsThinking ? "Thinking" : "No Thinking", color: model.supportsThinking ? .green : .secondary)
                    AppLabelTag(text: model.supportsImages ? "Images" : "Text Only", color: model.supportsImages ? .purple : .secondary)
                }
                Text("ctx \(model.contextWindow) · out \(model.maxOutput)")
                    .font(.footnote.monospaced())
                    .foregroundStyle(AppTheme.mutedText)
            }
        }
        .padding(.vertical, 10)
    }

    private var groupedModels: [(provider: String, models: [AvailableModel])] {
        Dictionary(grouping: viewModel.availableModels, by: \.provider)
            .map { provider, models in
                (provider, models.sorted { $0.model.localizedCaseInsensitiveCompare($1.model) == .orderedAscending })
            }
            .sorted { $0.provider.localizedCaseInsensitiveCompare($1.provider) == .orderedAscending }
    }
}

private struct SubagentsScreen: View {
    @ObservedObject var viewModel: AppViewModel
    let onEditConfig: () -> Void
    let onRestoreDefaults: () -> Void
    @State private var showingRestoreDefaultsConfirmation = false

    var body: some View {
        AppPage("Subagents", subtitle: "Global pi-subagents runtime defaults and package behavior") {
            AppCard(title: "What You Can Edit Here") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("• These settings control default runtime behavior for pi-subagents on this machine.")
                    Text("• This is the package config file, not an agent markdown file.")
                    Text("• Things like async defaults, intercom bridge behavior, control notices, parallel limits, and worktree hooks live here.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            AppCard(title: "Config File", trailing: {
                HStack(spacing: 10) {
                    if let config = viewModel.snapshot.subagentConfig {
                        Button("Open") { openFile(config.path) }
                        Button("Reveal") { revealInFinder(config.path) }
                    }
                    Button("Restore Defaults") { showingRestoreDefaultsConfirmation = true }
                        .disabled(viewModel.snapshot.subagentConfig == nil)
                    Button("Edit Config") { onEditConfig() }
                }
            }) {
                if viewModel.snapshot.subagentConfig == nil {
                    Text("No `~/.pi/agent/extensions/subagent/config.json` file exists right now. Pi Subagents falls back to its built-in package defaults until you create one.")
                        .foregroundStyle(AppTheme.mutedText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 8)
                }

                AppKeyValueList(rows: [
                    ("Path", configPath),
                    ("Source", viewModel.snapshot.subagentConfig == nil ? "Package defaults" : "User config file"),
                    ("Async By Default", boolLabel(displayedConfig.asyncByDefault)),
                    ("Force Top-Level Async", boolLabel(displayedConfig.forceTopLevelAsync)),
                    ("Default Session Dir", displayedConfig.defaultSessionDir ?? "Derived from parent session"),
                    ("Max Subagent Depth", displayedConfig.maxSubagentDepth.map(String.init) ?? "No package limit"),
                    ("Control Enabled", boolLabel(displayedConfig.control.enabled)),
                    ("Needs Attention After", displayedConfig.control.needsAttentionAfterMs.map { "\($0) ms" } ?? "—"),
                    ("Notify Channels", displayedConfig.control.notifyChannels.isEmpty ? "—" : displayedConfig.control.notifyChannels.joined(separator: ", ")),
                    ("Parallel Max Tasks", displayedConfig.parallel.maxTasks.map(String.init) ?? "8"),
                    ("Parallel Concurrency", displayedConfig.parallel.concurrency.map(String.init) ?? "4"),
                    ("Worktree Setup Hook", displayedConfig.worktreeSetupHook ?? "—"),
                    ("Worktree Hook Timeout", displayedConfig.worktreeSetupHookTimeoutMs.map { "\($0) ms" } ?? "30000 ms"),
                    ("Intercom Bridge Mode", displayedConfig.intercomBridge.mode ?? "always"),
                    ("Intercom Instruction File", displayedConfig.intercomBridge.instructionFile ?? "Default packaged instructions")
                ])
            }

            AppCard(title: "Package Defaults When Config Is Missing") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("When `~/.pi/agent/extensions/subagent/config.json` is missing, pi-subagents uses these built-in defaults:")
                    Text("• `asyncByDefault`: `false`")
                    Text("• `forceTopLevelAsync`: `false`")
                    Text("• `defaultSessionDir`: derived from the parent session")
                    Text("• `maxSubagentDepth`: no package-level limit")
                    Text("• `control.enabled`: `true`")
                    Text("• `control.needsAttentionAfterMs`: `60000`")
                    Text("• `control.notifyChannels`: `event, async, intercom`")
                    Text("• `parallel.maxTasks`: `8`")
                    Text("• `parallel.concurrency`: `4`")
                    Text("• `intercomBridge.mode`: `always`")
                    Text("• `intercomBridge.instructionFile`: packaged default instructions")
                    Text("• `worktreeSetupHook`: unset")
                    Text("• `worktreeSetupHookTimeoutMs`: `30000`")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            AppCard(title: "How These Settings Affect Runs") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("• `asyncByDefault` makes runs go to the background unless a request says otherwise.")
                    Text("• `forceTopLevelAsync` pushes top-level runs to background and skips clarify UI for them.")
                    Text("• `control` decides whether long quiet runs raise needs-attention notices.")
                    Text("• `parallel` sets default task limits for top-level parallel runs.")
                    Text("• `intercomBridge` controls when child agents get automatic intercom coordination instructions.")
                    Text("• `worktreeSetupHook` prepares each created worktree before a parallel isolated run starts.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .alert("Restore subagent defaults?", isPresented: $showingRestoreDefaultsConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Restore Defaults", role: .destructive) {
                onRestoreDefaults()
            }
        } message: {
            Text("This will delete ~/.pi/agent/extensions/subagent/config.json and fall back to the built-in pi-subagents defaults.")
        }
    }

    private var configPath: String {
        viewModel.snapshot.subagentConfig?.path ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/extensions/subagent/config.json").path
    }

    private var displayedConfig: SubagentExtensionConfig {
        viewModel.snapshot.subagentConfig?.config ?? .packageDefaults
    }

    private func openFile(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

private struct AgentsScreen: View {
    @ObservedObject var viewModel: AppViewModel
    let editCommand: Int
    @Binding var isEditing: Bool
    @Binding var isRecapPresented: Bool

    var body: some View {
        HStack(spacing: 0) {
            HSplitView {
                AgentLibraryPane(viewModel: viewModel)
                    .frame(minWidth: 430, idealWidth: 520, maxWidth: 640)

            if let agent = viewModel.selectedAgent {
                AgentDetailView(
                    agent: agent,
                    stateBadge: viewModel.builtinStateBadge(for: agent),
                    availableModels: viewModel.availableModels,
                    availableTools: viewModel.availableToolNames(for: viewModel.makeAgentDraft(for: agent)?.target ?? .custom(scope: .global)),
                    availableSkills: viewModel.availableSkillNames(for: viewModel.makeAgentDraft(for: agent)?.target ?? .custom(scope: .global)),
                    availableExtensions: viewModel.availableExtensionNames(for: viewModel.makeAgentDraft(for: agent)?.target ?? .custom(scope: .global)),
                    makeDraft: { scope in viewModel.makeAgentDraft(for: agent, preferredOverrideScope: scope ?? .global) },
                    editCommand: editCommand,
                    isEditing: $isEditing,
                    onSaveDraft: { draft in try viewModel.saveAgentDraft(draft, for: agent) },
                    onSetBuiltinDisabled: { scope, isDisabled in
                        viewModel.setBuiltinDisabled(isDisabled, for: agent, scope: scope)
                    },
                    managedAgent: agentIsLibraryManageable(agent) ? agent.winningRecord : nil,
                    isAgentGlobal: { record in viewModel.agentIsEnabledGlobally(record) },
                    assignedAgentProjects: { record in viewModel.assignedProjects(for: record) },
                    setAgentGlobal: { record, enabled in
                        if enabled { try viewModel.enableAgentGlobally(record) } else { try viewModel.disableAgentGlobally(record) }
                    },
                    setAgentForProject: { record, project, enabled in
                        try viewModel.setAgent(record, enabled: enabled, for: project)
                    },
                    moveAgentToLibrary: { record in
                        try viewModel.moveAgentToLibrary(record)
                    },
                    projects: viewModel.enabledProjects
                )
            } else {
                ContentUnavailableView("No Agent Selected", systemImage: "sparkles.rectangle.stack")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }

            if isRecapPresented, let project = viewModel.selectedDiscoveredProject {
                Divider()
                SubagentsProjectRecapPanel(
                    project: project,
                    snapshot: viewModel.startupSnapshot(forProjectPath: project.path),
                    libraryAgents: viewModel.snapshot.libraryAgents,
                    libraryChains: viewModel.snapshot.libraryChains,
                    onClose: { isRecapPresented = false }
                )
                .frame(width: 400)
            }
        }
    }
}

private struct AgentLibraryPane: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        AppPage("Agents", subtitle: subtitle) {
            VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
                if let selectedProject = viewModel.selectedDiscoveredProject {
                    AppCard(title: "Active in \(selectedProject.name)") {
                        agentGrid(activeCustomAgents, emptyText: "No custom agents are active for this project.")
                    }

                    if !libraryAgents.isEmpty {
                        AppCard(title: "Library Agents") {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Library agents are centrally stored and only become active when assigned to this project or enabled globally.")
                                    .foregroundStyle(AppTheme.mutedText)
                                agentGrid(libraryAgents, emptyText: "No unassigned library agents.")
                            }
                        }
                    }
                } else {
                    AppCard(title: "Global Agents") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Select a project to see exactly which custom agents are active there and to manage project assignment.")
                                .foregroundStyle(AppTheme.mutedText)
                            agentGrid(globalCustomAgents, emptyText: "No global custom agents.")
                        }
                    }

                    if !libraryAgents.isEmpty {
                        AppCard(title: "Library Agents") {
                            agentGrid(libraryAgents, emptyText: "No library agents.")
                        }
                    }
                }

                AppCard(title: "Builtin Agents") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Builtins are package-managed and customized through settings overrides or replacement files.")
                            .foregroundStyle(AppTheme.mutedText)
                        agentGrid(builtinAgents, emptyText: "No builtin agents discovered.")
                    }
                }
            }
        }
    }

    private var subtitle: String {
        if let selectedProject = viewModel.selectedDiscoveredProject {
            return "Active agents for \(selectedProject.name), plus central library assignment"
        }
        return "Select a project to manage project-specific agent assignment"
    }

    private var activeCustomAgents: [EffectiveAgentRecord] {
        viewModel.filteredAgents.filter { agent in
            agent.resolutionKind != .library && !(agent.builtin != nil && agent.globalCustom == nil && agent.projectCustom == nil)
        }
    }

    private var globalCustomAgents: [EffectiveAgentRecord] {
        viewModel.filteredAgents.filter { $0.globalCustom != nil && $0.globalCustom?.source.kind != .library }
    }

    private var libraryAgents: [EffectiveAgentRecord] {
        viewModel.filteredAgents.filter { agent in
            agent.resolutionKind == .library || libraryBackedActiveAgentNames.contains(agent.name)
        }
    }

    private var libraryBackedActiveAgentNames: Set<String> {
        Set(viewModel.snapshot.libraryAgents.map(\.name))
    }

    private var builtinAgents: [EffectiveAgentRecord] {
        viewModel.filteredAgents.filter { $0.builtin != nil && $0.globalCustom == nil && $0.projectCustom == nil }
    }

    private func agentGrid(_ agents: [EffectiveAgentRecord], emptyText: String) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
            if agents.isEmpty {
                Text(emptyText)
                    .foregroundStyle(AppTheme.mutedText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(agents) { agent in
                    agentTile(agent)
                }
            }
        }
    }

    private func agentTile(_ agent: EffectiveAgentRecord) -> some View {
        Button {
            viewModel.selectedAgentID = agent.id
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: icon(for: agent))
                        .foregroundStyle(color(for: agent))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(agent.name)
                            .font(.headline)
                            .fontWidth(.expanded)
                            .foregroundStyle(.primary)
                            .strikethrough(agent.resolved.disabled == true, color: AppTheme.mutedText)
                        Text(agent.resolved.description.isEmpty ? "No description" : agent.resolved.description)
                            .font(.caption)
                            .foregroundStyle(AppTheme.mutedText)
                            .lineLimit(2)

                        capabilityStrip(for: agent)
                    }
                    Spacer()
                    AppLabelTag(text: statusLabel(agent), color: color(for: agent))
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(viewModel.selectedAgentID == agent.id ? Color.accentColor.opacity(0.10) : AppTheme.subtleFill)
                    .stroke(viewModel.selectedAgentID == agent.id ? Color.accentColor.opacity(0.45) : AppTheme.cardStroke, lineWidth: 1)
            )
            .opacity(agent.resolved.disabled == true ? 0.62 : 1)
            .saturation(agent.resolved.disabled == true ? 0.25 : 1)
        }
        .buttonStyle(.plain)
    }

    private func capabilityStrip(for agent: EffectiveAgentRecord) -> some View {
        HStack(spacing: 6) {
            if !agent.resolved.skills.isEmpty {
                capabilityPill("Skills", symbol: "sparkles", color: .green)
            }
            if agent.resolved.inheritSkills == true {
                capabilityPill("Inherits", symbol: "square.stack.3d.up", color: .mint)
            }
            if !((agent.resolved.tools ?? []).isEmpty) || !((agent.resolved.mcpDirectTools ?? []).isEmpty) {
                capabilityPill("Tools", symbol: "wrench.and.screwdriver", color: .blue)
            }
            if agent.resolved.disabled == true {
                capabilityPill("Disabled", symbol: "nosign", color: .red)
            }
            if !viewModel.warnings(for: agent).isEmpty {
                capabilityPill("Warning", symbol: "exclamationmark.triangle", color: .orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func capabilityPill(_ text: String, symbol: String, color: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(color.opacity(0.10), in: Capsule(style: .continuous))
    }

    private func statusLabel(_ agent: EffectiveAgentRecord) -> String {
        if agent.resolved.disabled == true { return "Disabled" }
        if libraryBackedActiveAgentNames.contains(agent.name) {
            if viewModel.selectedProjectPath != nil, agent.resolutionKind != .library { return "Active" }
            return "Library"
        }
        if viewModel.selectedProjectPath != nil, agent.resolutionKind != .library { return "Active" }
        return agent.resolutionKind.rawValue
    }

    private func icon(for agent: EffectiveAgentRecord) -> String {
        "rectangle.connected.to.line.below"
    }

    private func color(for agent: EffectiveAgentRecord) -> Color {
        if agent.resolved.disabled == true { return .red }
        if agent.builtin != nil && agent.globalCustom == nil && agent.projectCustom == nil { return .orange }
        if agent.resolutionKind == .library || libraryBackedActiveAgentNames.contains(agent.name) { return .purple }
        if viewModel.selectedProjectPath != nil { return .green }
        return .blue
    }
}

private func agentIsLibraryManageable(_ agent: EffectiveAgentRecord) -> Bool {
    guard let winningRecord = agent.winningRecord else { return false }
    guard winningRecord.source.kind != .builtin else { return false }
    // Same-name custom agents that replace builtins are intentional pi-subagents overrides.
    // Keep them in their chosen scope instead of offering reusable library assignment.
    if agent.builtin != nil && (agent.globalCustom != nil || agent.projectCustom != nil) { return false }
    return true
}

private func rowIndicator(_ symbol: String, color: Color) -> some View {
    Image(systemName: symbol)
        .font(.caption)
        .foregroundStyle(color)
}

private struct AgentDetailView: View {
    enum DetailTab: String, CaseIterable, Identifiable {
        case summary = "Summary"
        case prompt = "Prompt"
        case tools = "Tools & Extensions"
        case skills = "Skills"
        case sourceFiles = "Manage"
        case advanced = "Advanced"

        var id: String { rawValue }
    }

    let agent: EffectiveAgentRecord
    let stateBadge: (text: String, color: Color)?
    let availableModels: [AvailableModel]
    let availableTools: [String]
    let availableSkills: [String]
    let availableExtensions: [String]
    let makeDraft: (AgentEditingTarget.OverrideScope?) -> AgentEditorDraft?
    let editCommand: Int
    @Binding var isEditing: Bool
    let onSaveDraft: (AgentEditorDraft) throws -> Void
    let onSetBuiltinDisabled: (AgentEditingTarget.OverrideScope, Bool) -> Void
    let managedAgent: AgentRecord?
    let isAgentGlobal: (AgentRecord) -> Bool
    let assignedAgentProjects: (AgentRecord) -> [DiscoveredProject]
    let setAgentGlobal: (AgentRecord, Bool) throws -> Void
    let setAgentForProject: (AgentRecord, DiscoveredProject, Bool) throws -> Void
    let moveAgentToLibrary: (AgentRecord) throws -> Void
    let projects: [DiscoveredProject]
    @State private var selectedTab: DetailTab = .summary
    @State private var inlineDraft: AgentEditorDraft?
    @State private var baselineInlineDraft: AgentEditorDraft?
    @State private var inlineSaveMessage: String?
    @State private var pendingSaveConfirmation: SaveConfirmation?

    var body: some View {
        AppPage(agent.name, subtitle: agent.resolved.description.isEmpty ? nil : agent.resolved.description) {
            AppCard {
                VStack(alignment: .leading, spacing: 8) {
                    if let projectRoot = agent.projectRoot {
                        Text(URL(fileURLWithPath: projectRoot).lastPathComponent)
                            .font(.headline)
                            .fontWidth(.expanded)
                    }
                    if let badge = stateBadge {
                        AppLabelTag(text: badge.text, color: badge.color)
                    }
                    Text(agent.builtin != nil && agent.globalCustom == nil && agent.projectCustom == nil ? (hasOverride ? "This builtin is currently customized through a settings override, matching /agents in pi-subagents." : "Builtins are not edited directly. Use Edit for supported settings overrides, or the toolbar replacement menu for frontmatter fields such as output.") : "Custom agents are edited as markdown files in the Pi discovery paths.")
                        .foregroundStyle(AppTheme.mutedText)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(DetailTab.allCases) { tab in
                        Button {
                            selectedTab = tab
                        } label: {
                            Text(tab.rawValue)
                                .font(.subheadline.weight(.semibold))
                                .fontWidth(.expanded)
                                .foregroundStyle(selectedTab == tab ? Color.white : .primary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(selectedTab == tab ? Color.accentColor : AppTheme.subtleFill)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }

            switch selectedTab {
            case .summary:
                summaryTab
            case .prompt:
                promptTab
            case .tools:
                toolsTab
            case .skills:
                skillsTab
            case .sourceFiles:
                sourceFilesTab
            case .advanced:
                advancedTab
            }
        }
        .task(id: agent.id) {
            isEditing = false
            reloadInlineDraft()
        }
        .onChange(of: editCommand) { _, _ in
            toggleEditMode()
        }
        .alert(item: $pendingSaveConfirmation) { confirmation in
            Alert(
                title: Text("Save changes?"),
                message: Text(confirmation.summary),
                primaryButton: .default(Text("Save")) {
                    performConfirmedSave(exitEditMode: confirmation.exitEditMode)
                },
                secondaryButton: .cancel()
            )
        }
    }

    private var summaryTab: some View {
        VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
            agentVisibilityManagementCards

            AppCard(title: "Configuration", trailing: {
                if isEditing {
                    HStack(spacing: 10) {
                        if inlineHasChanges {
                            Button("Discard") {
                                discardInlineChanges(exitEditMode: true)
                            }
                            .controlSize(.small)
                        }

                        Button("Save Changes") {
                            requestSaveInlineDraft(exitEditMode: true)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(!inlineHasChanges || inlineDraft == nil)
                    }
                } else {
                    HStack(spacing: 8) {
                        if let badge = stateBadge {
                            AppLabelTag(text: badge.text, color: badge.color)
                        }
                        AppLabelTag(text: agent.resolutionKind.rawValue, color: .purple)
                    }
                }
            }) {
                if isEditing, let draft = inlineDraft {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(spacing: 10) {
                            AppLabelTag(text: agent.resolutionKind.rawValue, color: .purple)
                            Text(configurationFootnote)
                                .font(.caption)
                                .foregroundStyle(AppTheme.mutedText)
                        }

                        settingsSection("Model & Prompt") {
                            configEditorRow("Model") {
                                Picker("Model", selection: inlineModelSelectionBinding) {
                                    Text("Use Pi Default Model").tag("")
                                    ForEach(availableModels, id: \.identifier) { model in
                                        Text(model.identifier).tag(model.identifier)
                                    }
                                }
                                .pickerStyle(.menu)
                                .frame(maxWidth: 360, alignment: .leading)

                                Text(selectedInlineModelSummary)
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.mutedText)
                            }

                            configEditorRow("Thinking") {
                                Picker("Thinking", selection: inlineThinkingSelectionBinding) {
                                    ForEach(inlineAvailableThinkingLevels, id: \.self) { level in
                                        Text(level).tag(level)
                                    }
                                }
                                .pickerStyle(.menu)
                                .frame(maxWidth: 180, alignment: .leading)

                                Text("Only values supported by the selected model are shown.")
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.mutedText)
                            }

                            configEditorRow("Prompt Mode") {
                                Picker("Prompt Mode", selection: inlinePromptModeBinding) {
                                    Text("Replace").tag("replace")
                                    Text("Append").tag("append")
                                }
                                .pickerStyle(.segmented)
                                .frame(maxWidth: 260, alignment: .leading)
                            }

                            configEditorRow("Fallback Models") {
                                VStack(alignment: .leading, spacing: 10) {
                                    Menu("Add Fallback Model") {
                                        if !availableModels.isEmpty {
                                            Button("Use None") {
                                                inlineDraft?.config.fallbackModels = []
                                            }
                                            Divider()
                                        }
                                        ForEach(availableModels, id: \.identifier) { model in
                                            Button(model.identifier) {
                                                addInlineFallbackModel(model.identifier)
                                            }
                                        }
                                    }

                                    inlineTokenList(draft.config.fallbackModels, remove: removeInlineFallbackModel)
                                }
                            }
                        }

                        settingsSection("Behavior") {
                            configEditorRow("Project Context") {
                                Toggle("Inherit project context", isOn: inlineDefaultedOptionalBoolBinding(for: \.inheritProjectContext) { draft.config.name == "delegate" })
                                    .toggleStyle(.switch)
                            }

                            configEditorRow("Skills") {
                                Toggle("Inherit skills", isOn: inlineDefaultedOptionalBoolBinding(for: \.inheritSkills, default: false))
                                    .toggleStyle(.switch)
                            }

                            configEditorRow("Availability") {
                                Toggle("Disabled", isOn: inlineOptionalBoolBinding(for: \.disabled))
                                    .toggleStyle(.switch)
                            }

                            if case .custom = draft.target {
                                configEditorRow("Progress") {
                                    Toggle("Default progress", isOn: inlineOptionalBoolBinding(for: \.defaultProgress))
                                        .toggleStyle(.switch)
                                }

                                configEditorRow("Interaction") {
                                    Toggle("Interactive", isOn: inlineOptionalBoolBinding(for: \.interactive))
                                        .toggleStyle(.switch)
                                }
                            }
                        }

                        if case .custom = draft.target {
                            settingsSection("Files") {
                                configEditorRow("Output") {
                                    TextField("Output path", text: inlineOptionalStringBinding(for: \.output))
                                        .textFieldStyle(.roundedBorder)
                                        .frame(maxWidth: 360, alignment: .leading)
                                }

                                configEditorRow("Default Reads") {
                                    TextField("fileA, fileB", text: inlineStringListBinding(for: \.defaultReads))
                                        .textFieldStyle(.roundedBorder)
                                        .frame(maxWidth: 360, alignment: .leading)
                                }

                                configEditorRow("Max Depth") {
                                    Stepper(value: inlineOptionalIntBinding(for: \.maxSubagentDepth), in: 0...10) {
                                        Text(inlineDraft?.config.maxSubagentDepth.map(String.init) ?? "0")
                                    }
                                    .frame(maxWidth: 180, alignment: .leading)
                                }
                            }
                        }

                        if let inlineSaveMessage {
                            Text(inlineSaveMessage)
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    }
                } else if isEditing {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        readOnlyFieldRow("Model", value: agent.resolved.model ?? "default")
                        readOnlyFieldRow("Fallback Models", value: agent.resolved.fallbackModels.isEmpty ? "—" : agent.resolved.fallbackModels.joined(separator: ", "))
                        readOnlyFieldRow("Thinking", value: agent.resolved.thinking ?? "off")
                        readOnlyFieldRow("Prompt Mode", value: agent.resolved.systemPromptMode ?? "—")
                        readOnlyFieldRow("Inherit Project Context", value: display(agent.resolved.inheritProjectContext))
                        readOnlyFieldRow("Inherit Skills", value: display(agent.resolved.inheritSkills))
                        readOnlyFieldRow("Disabled", value: display(agent.resolved.disabled))
                        readOnlyFieldRow("Output", value: agent.resolved.output ?? "—")
                        readOnlyFieldRow("Default Reads", value: agent.resolved.defaultReads?.joined(separator: ", ") ?? "—")
                        readOnlyFieldRow("Default Progress", value: display(agent.resolved.defaultProgress))
                        readOnlyFieldRow("Interactive", value: display(agent.resolved.interactive))
                        readOnlyFieldRow("Max Subagent Depth", value: agent.resolved.maxSubagentDepth.map(String.init) ?? "—", isLast: true)
                    }
                }
            }

        }
    }

    private var promptTab: some View {
        VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
            AppCard(title: resolvedPromptDiffers ? "Resolved Prompt" : "Prompt", trailing: {
                if isEditing {
                    HStack(spacing: 10) {
                        if inlineHasChanges {
                            Button("Discard") {
                                discardInlineChanges(exitEditMode: true)
                            }
                            .controlSize(.small)
                        }

                        Button("Save Changes") {
                            requestSaveInlineDraft(exitEditMode: true)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(!inlineHasChanges || inlineDraft == nil)
                    }
                }
            }) {
                if isEditing {
                    TextEditor(text: Binding(
                        get: { inlineDraft?.config.systemPrompt ?? "" },
                        set: { inlineDraft?.config.systemPrompt = $0 }
                    ))
                    .frame(minHeight: 320)
                    .font(.system(.body, design: .monospaced))
                    .padding(8)
                    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                    .help("The system prompt is the main instruction body for this agent. Replace mode uses this as the agent’s primary prompt, while append mode adds it on top of Pi’s normal base behavior.")
                } else {
                    MarkdownDocumentView(source: agent.resolved.systemPrompt)
                        .help("The system prompt is the main instruction body for this agent.")
                }
            }

            if !isEditing, resolvedPromptDiffers {
                AppCard(title: "Raw Source Prompt") {
                    MarkdownDocumentView(source: agent.winningRecord?.promptBody ?? "")
                }
            }
        }
    }

    private var toolsTab: some View {
        VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
            AppCard(title: "Tools & Extensions", trailing: {
                if isEditing {
                    HStack(spacing: 10) {
                        if inlineHasChanges {
                            Button("Discard") {
                                discardInlineChanges(exitEditMode: true)
                            }
                            .controlSize(.small)
                        }

                        Button("Save Changes") {
                            requestSaveInlineDraft(exitEditMode: true)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(!inlineHasChanges || inlineDraft == nil)
                    }
                }
            }) {
                if isEditing, let draft = inlineDraft {
                    VStack(alignment: .leading, spacing: 18) {
                        settingsSection("Tool Access") {
                            configEditorRow("Tool Access") {
                                HStack(spacing: 10) {
                                    Button("Reset Tool Access") {
                                        resetInlineToolAccess()
                                    }
                                    .controlSize(.small)

                                    Text(selectedInlineToolValues.isEmpty ? "Currently using Pi default tool access." : "Using an explicit tool allowlist.")
                                        .font(.caption)
                                        .foregroundStyle(AppTheme.mutedText)
                                }
                            }

                            configEditorRow("Add Tool") {
                                Menu("Choose Tool") {
                                    ForEach(availableTools, id: \.self) { tool in
                                        Button(tool) {
                                            addInlineTool(tool)
                                        }
                                    }
                                }
                            }

                            configEditorRow("Selected") {
                                inlineTokenList(selectedInlineToolValues, remove: removeInlineTool)
                            }
                        }

                        if case .custom = draft.target {
                            settingsSection("Extensions") {
                                configEditorRow("Extension Mode") {
                                    HStack(spacing: 10) {
                                        Button("Use Default Extensions") {
                                            inlineDraft?.config.extensions = nil
                                        }
                                        .controlSize(.small)

                                        Text((draft.config.extensions == nil) ? "Inherits Pi’s default extension behavior." : "Using an explicit extension list.")
                                            .font(.caption)
                                            .foregroundStyle(AppTheme.mutedText)
                                    }
                                }

                                configEditorRow("Add Extension") {
                                    Menu("Choose Extension") {
                                        ForEach(availableExtensions, id: \.self) { name in
                                            Button(name) {
                                                addInlineExtension(name)
                                            }
                                        }
                                    }
                                }

                                configEditorRow("Selected") {
                                    inlineTokenList(draft.config.extensions ?? [], remove: removeInlineExtension)
                                }
                            }

                            settingsSection("Files") {
                                configEditorRow("Output") {
                                    TextField("Output path", text: inlineOptionalStringBinding(for: \.output))
                                        .textFieldStyle(.roundedBorder)
                                        .frame(maxWidth: 360, alignment: .leading)
                                }

                                configEditorRow("Default Reads") {
                                    TextField("fileA, fileB", text: inlineStringListBinding(for: \.defaultReads))
                                        .textFieldStyle(.roundedBorder)
                                        .frame(maxWidth: 360, alignment: .leading)
                                }
                            }
                        }
                    }
                } else if isEditing {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 10) {
                            readOnlyFieldRow("Extensions", value: extensionsSummary)
                            readOnlyFieldRow("Output", value: agent.resolved.output ?? "—")
                            readOnlyFieldRow("Default Reads", value: agent.resolved.defaultReads?.joined(separator: ", ") ?? "—", isLast: true)
                        }

                        if let tools = agent.resolved.tools, !tools.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Built-in Tools")
                                    .font(.headline)
                                    .fontWidth(.expanded)
                                ForEach(tools, id: \.self) { tool in
                                    HStack(spacing: 10) {
                                        Image(systemName: "wrench.and.screwdriver")
                                            .foregroundStyle(.blue)
                                        Text(tool)
                                    }
                                }
                            }
                        }

                        if let mcpTools = agent.resolved.mcpDirectTools, !mcpTools.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Direct MCP Tools")
                                    .font(.headline)
                                    .fontWidth(.expanded)
                                ForEach(mcpTools, id: \.self) { tool in
                                    HStack(spacing: 10) {
                                        Image(systemName: "cable.connector")
                                            .foregroundStyle(.purple)
                                        Text("mcp:\(tool)")
                                    }
                                }
                            }
                        }

                        if (agent.resolved.tools ?? []).isEmpty && (agent.resolved.mcpDirectTools ?? []).isEmpty {
                            Text("Default Pi tool access")
                                .foregroundStyle(AppTheme.mutedText)
                        }
                    }
                }
            }

            AppCard(title: "How Tool Access Works") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("• If `tools` is omitted, the child gets Pi’s normal default built-in tools.")
                    Text("• If `tools` is set, it acts like an allowlist for regular tool names.")
                    Text("• `mcp:name` entries are separate direct MCP tools and only make sense when that MCP server exists in config.")
                    Text("• Extensions are offered from installed package references Pi already knows about.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var skillsTab: some View {
        VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
            AppCard(title: "Skills", trailing: {
                if isEditing {
                    HStack(spacing: 10) {
                        if inlineHasChanges {
                            Button("Discard") {
                                discardInlineChanges(exitEditMode: true)
                            }
                            .controlSize(.small)
                        }

                        Button("Save Changes") {
                            requestSaveInlineDraft(exitEditMode: true)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(!inlineHasChanges || inlineDraft == nil)
                    }
                }
            }) {
                if isEditing, let draft = inlineDraft {
                    VStack(alignment: .leading, spacing: 18) {
                        settingsSection("Skill Selection") {
                            configEditorRow("Skill Catalog") {
                                Text("Only skills visible in this agent’s scope are selectable here.")
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.mutedText)
                            }

                            configEditorRow("Add Skill") {
                                Menu("Choose Skill") {
                                    ForEach(availableSkills, id: \.self) { skill in
                                        Button(skill) {
                                            addInlineSkill(skill)
                                        }
                                    }
                                }
                            }

                            configEditorRow("Selected") {
                                inlineTokenList(draft.config.skills, remove: removeInlineSkill)
                            }
                        }
                    }
                } else if isEditing {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 10) {
                            readOnlyFieldRow("Inherit Skills", value: display(agent.resolved.inheritSkills))
                            readOnlyFieldRow("Explicit Skill Count", value: "\(agent.resolved.skills.count)", isLast: true)
                        }

                        if agent.resolved.skills.isEmpty {
                            Text("No explicit skills")
                                .foregroundStyle(AppTheme.mutedText)
                        } else {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(agent.resolved.skills, id: \.self) { skill in
                                    HStack(spacing: 10) {
                                        Image(systemName: "sparkles")
                                            .foregroundStyle(.green)
                                        Text(skill)
                                    }
                                }
                            }
                        }
                    }
                }
            }

            AppCard(title: "How Skills Work") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("• Explicit skills are always attached to this agent when they are visible in scope.")
                    Text("• `inheritSkills` means the child also keeps Pi’s discovered skills catalog in its prompt.")
                    Text("• Project-local skills are only visible inside their project. Global skills are visible everywhere.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var agentVisibilityManagementCards: some View {
        VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
            if let managedAgent {
                AppCard(title: "Library & Visibility") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Move reusable custom agents into the library, then choose whether they are active globally or only in specific projects.")
                            .foregroundStyle(AppTheme.mutedText)
                            .fixedSize(horizontal: false, vertical: true)

                        AppKeyValueList(rows: [
                            ("In Library", managedAgent.source.kind == .library ? "Yes" : "No"),
                            ("Active Globally", isAgentGlobal(managedAgent) ? "Yes" : "No"),
                            ("Assigned Projects", assignedAgentProjects(managedAgent).map(\.name).joined(separator: ", ").nonEmpty ?? "—")
                        ])

                        HStack(spacing: 10) {
                            if managedAgent.source.kind != .library {
                                Button("Move to Library") { do { try moveAgentToLibrary(managedAgent) } catch { NSSound.beep() } }
                            }

                            if isAgentGlobal(managedAgent) {
                                Button("Disable Globally") { do { try setAgentGlobal(managedAgent, false) } catch { NSSound.beep() } }
                            } else {
                                Button("Enable Globally") { do { try setAgentGlobal(managedAgent, true) } catch { NSSound.beep() } }
                                    .buttonStyle(.borderedProminent)
                            }
                        }
                    }
                }

                AppCard(title: "Project Assignment") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Check each project that should load this agent. Assigning to a project removes managed global visibility, like Skills.")
                            .foregroundStyle(AppTheme.mutedText)
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(projects) { project in
                                Toggle(isOn: Binding(
                                    get: { assignedAgentProjects(managedAgent).contains(where: { $0.id == project.id }) },
                                    set: { enabled in do { try setAgentForProject(managedAgent, project, enabled) } catch { NSSound.beep() } }
                                )) {
                                    HStack(spacing: 10) {
                                        ProjectIconView(imageURL: project.iconFileURL, symbolName: project.fallbackSymbolName, size: 30)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(project.name).font(.body.weight(.semibold))
                                            Text(project.repositoryName ?? project.path).font(.caption).foregroundStyle(AppTheme.mutedText).lineLimit(1).truncationMode(.middle)
                                        }
                                    }
                                    .frame(height: 46, alignment: .center)
                                }
                                .toggleStyle(.checkbox)
                                .controlSize(.large)
                                .padding(.vertical, 8)
                                if project.id != projects.last?.id { Divider() }
                            }
                        }
                    }
                }
            } else {
                AppCard(title: unmanagedAgentTitle) {
                    Text(unmanagedAgentMessage)
                        .foregroundStyle(AppTheme.mutedText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var unmanagedAgentTitle: String {
        if agent.builtin != nil && (agent.globalCustom != nil || agent.projectCustom != nil) {
            return "Replacement Agent"
        }
        return "Builtin Agent"
    }

    private var unmanagedAgentMessage: String {
        if agent.builtin != nil && (agent.globalCustom != nil || agent.projectCustom != nil) {
            return "This custom agent intentionally replaces a builtin in its current scope. Replacements stay in that scope and are not moved into the reusable library or assigned per project."
        }
        return "Builtins are package-managed. Use settings overrides or replacement files; they are not moved into the library."
    }

    private var sourceFilesTab: some View {
        VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
            agentVisibilityManagementCards

            AppCard(title: "Source Files") {
                VStack(alignment: .leading, spacing: 16) {
                    AppKeyValueList(rows: [
                        ("Builtin File", agent.builtin?.filePath ?? "—"),
                        ("Global File", agent.globalCustom?.filePath ?? "—"),
                        ("Project File", agent.projectCustom?.filePath ?? "—"),
                        ("Global Override", agent.userOverride?.settingsPath ?? "—"),
                        ("Project Override", agent.projectOverride?.settingsPath ?? "—"),
                        ("Write Target", writeTargetSummary)
                    ])

                    HStack(spacing: 10) {
                        Button("Open Raw File") { openFile(primarySourcePath) }
                        Button("Reveal in Finder") { revealInFinder(primarySourcePath) }
                    }
                }
            }

        }
    }

    private var advancedTab: some View {
        VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
            AppCard(title: "Resolved Frontmatter") {
                Text(prettyJSONObject(resolvedFrontmatter))
                    .font(.footnote.monospaced())
                    .foregroundStyle(AppTheme.mutedText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !agent.resolved.unknownFields.isEmpty {
                AppCard(title: "Unknown Fields") {
                    Text(prettyJSONObject(agent.resolved.unknownFields.mapValues { $0 }))
                        .font(.footnote.monospaced())
                        .foregroundStyle(AppTheme.mutedText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if let rawFrontmatter = agent.winningRecord?.rawFrontmatter, !rawFrontmatter.isEmpty {
                AppCard(title: "Raw Frontmatter") {
                    Text(prettyJSONObject(rawFrontmatter.mapValues { $0 }))
                        .font(.footnote.monospaced())
                        .foregroundStyle(AppTheme.mutedText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var resolvedPromptDiffers: Bool {
        (agent.winningRecord?.promptBody ?? agent.resolved.systemPrompt) != agent.resolved.systemPrompt
    }

    private var inlineHasChanges: Bool {
        guard let inlineDraft, let baselineInlineDraft else { return false }
        return normalizedInlineDraft(inlineDraft) != normalizedInlineDraft(baselineInlineDraft)
    }

    private var selectedInlineModel: AvailableModel? {
        guard let identifier = inlineDraft?.config.model else { return nil }
        return availableModels.first(where: { $0.identifier == identifier })
    }

    private var selectedInlineModelSummary: String {
        if let model = selectedInlineModel {
            return "\(model.identifier) · ctx \(model.contextWindow) · out \(model.maxOutput)"
        }
        return "Uses Pi’s default model resolution."
    }

    private var inlineAvailableThinkingLevels: [String] {
        selectedInlineModel?.supportedThinkingLevels ?? ["off", "minimal", "low", "medium", "high", "xhigh"]
    }

    private var inlineModelSelectionBinding: Binding<String> {
        Binding(
            get: { inlineDraft?.config.model ?? "" },
            set: { newValue in
                inlineDraft?.config.model = newValue.isEmpty ? nil : newValue
                clampInlineThinkingSelection()
            }
        )
    }

    private var inlineThinkingSelectionBinding: Binding<String> {
        Binding(
            get: {
                let current = inlineDraft?.config.thinking ?? "off"
                return inlineAvailableThinkingLevels.contains(current) ? current : (inlineAvailableThinkingLevels.first ?? "off")
            },
            set: { newValue in
                inlineDraft?.config.thinking = newValue == "off" ? nil : newValue
            }
        )
    }

    private var inlinePromptModeBinding: Binding<String> {
        Binding(
            get: { inlineDraft?.config.systemPromptMode ?? "replace" },
            set: { inlineDraft?.config.systemPromptMode = $0 }
        )
    }

    private var selectedInlineToolValues: [String] {
        ((inlineDraft?.config.tools ?? []) + (inlineDraft?.config.mcpDirectTools ?? []).map { "mcp:\($0)" })
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var configurationFootnote: String {
        if isPlainBuiltin {
            if agent.projectOverride != nil {
                return "Editing here updates the global builtin override. A project override still takes precedence inside this project until you remove it."
            }
            return hasOverride
                ? "These changes update the global builtin override for this agent."
                : "Saving creates a global builtin override for this agent in ~/.pi/agent/settings.json."
        }
        return "These changes update the agent file directly."
    }

    private var hasOverride: Bool {
        agent.userOverride != nil || agent.projectOverride != nil
    }

    private var isPlainBuiltin: Bool {
        agent.builtin != nil && agent.globalCustom == nil && agent.projectCustom == nil
    }

    private var primarySourcePath: String? {
        agent.sourcePath ?? agent.projectOverride?.settingsPath ?? agent.userOverride?.settingsPath
    }

    private var writeTargetSummary: String {
        if agent.builtin != nil, agent.globalCustom == nil, agent.projectCustom == nil {
            return agent.userOverride?.settingsPath ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/settings.json").path
        }
        return agent.sourcePath ?? "—"
    }

    private var extensionsSummary: String {
        guard let extensions = agent.resolved.extensions else { return "Default / inherited" }
        return extensions.isEmpty ? "None" : extensions.joined(separator: ", ")
    }

    private var resolvedFrontmatter: [String: Any] {
        var values: [String: Any] = [
            "name": agent.resolved.name,
            "description": agent.resolved.description,
            "systemPromptMode": agent.resolved.systemPromptMode ?? "",
            "inheritProjectContext": agent.resolved.inheritProjectContext as Any,
            "inheritSkills": agent.resolved.inheritSkills as Any,
            "disabled": agent.resolved.disabled as Any,
            "skills": agent.resolved.skills
        ]
        if let model = agent.resolved.model { values["model"] = model }
        if !agent.resolved.fallbackModels.isEmpty { values["fallbackModels"] = agent.resolved.fallbackModels }
        if let thinking = agent.resolved.thinking { values["thinking"] = thinking }
        if let tools = agent.resolved.tools { values["tools"] = tools + (agent.resolved.mcpDirectTools ?? []).map { "mcp:\($0)" } }
        if let extensions = agent.resolved.extensions { values["extensions"] = extensions }
        if let output = agent.resolved.output { values["output"] = output }
        if let reads = agent.resolved.defaultReads { values["defaultReads"] = reads }
        if let defaultProgress = agent.resolved.defaultProgress { values["defaultProgress"] = defaultProgress }
        if let interactive = agent.resolved.interactive { values["interactive"] = interactive }
        if let maxSubagentDepth = agent.resolved.maxSubagentDepth { values["maxSubagentDepth"] = maxSubagentDepth }
        for (key, value) in agent.resolved.unknownFields { values[key] = value }
        return values
    }

    @ViewBuilder
    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.headline)
                .fontWidth(.expanded)

            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.subtleFill.opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    @ViewBuilder
    private func configEditorRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 18) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AppTheme.mutedText)
                if let help = fieldHelpText(for: title) {
                    helpIcon(help)
                }
            }
            .frame(width: 170, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func readOnlyFieldRow(_ title: String, value: String, isLast: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .fontWidth(.expanded)
                    .foregroundStyle(AppTheme.mutedText)
                if let help = fieldHelpText(for: title) {
                    helpIcon(help)
                }
            }
            Text(value)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        if !isLast {
            Divider()
        }
    }

    private func helpIcon(_ text: String) -> some View {
        Image(systemName: "questionmark.circle")
            .font(.caption)
            .foregroundStyle(AppTheme.mutedText)
            .help(text)
    }

    @ViewBuilder
    private func inlineTokenList(_ values: [String], remove: @escaping (String) -> Void) -> some View {
        if values.isEmpty {
            Text("None")
                .font(.caption)
                .foregroundStyle(AppTheme.mutedText)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 8)], spacing: 8) {
                ForEach(values, id: \.self) { value in
                    HStack(spacing: 8) {
                        Text(value)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Button {
                            remove(value)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(AppTheme.subtleFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
    }

    private func reloadInlineDraft(preferredOverrideScope: AgentEditingTarget.OverrideScope? = nil) {
        guard let draft = makeDraft(preferredOverrideScope) else {
            inlineDraft = nil
            baselineInlineDraft = nil
            return
        }
        inlineDraft = draft
        baselineInlineDraft = draft
        inlineSaveMessage = nil
    }

    private func toggleEditMode() {
        if isEditing {
            guard !inlineHasChanges else {
                NSSound.beep()
                inlineSaveMessage = "Save or discard your changes first."
                return
            }
            isEditing = false
        } else {
            reloadInlineDraft()
            isEditing = true
        }
    }

    private func discardInlineChanges(exitEditMode: Bool = false) {
        inlineDraft = baselineInlineDraft
        inlineSaveMessage = nil
        if exitEditMode {
            isEditing = false
        }
    }

    private func requestSaveInlineDraft(exitEditMode: Bool = false) {
        guard let inlineDraft, let baselineInlineDraft else { return }
        let summary = changedFieldsSummary(from: normalizedInlineDraft(baselineInlineDraft), to: normalizedInlineDraft(inlineDraft))
        guard !summary.isEmpty else { return }
        pendingSaveConfirmation = SaveConfirmation(summary: summary, exitEditMode: exitEditMode)
    }

    private func performConfirmedSave(exitEditMode: Bool = false) {
        guard let inlineDraft else { return }
        do {
            let normalized = normalizedInlineDraft(inlineDraft)
            try onSaveDraft(normalized)
            baselineInlineDraft = normalized
            self.inlineDraft = normalized
            inlineSaveMessage = "Saved"
            pendingSaveConfirmation = nil
            if exitEditMode {
                isEditing = false
            }
        } catch {
            NSSound.beep()
            inlineSaveMessage = nil
            pendingSaveConfirmation = nil
        }
    }

    private func clampInlineThinkingSelection() {
        let current = inlineDraft?.config.thinking ?? "off"
        guard !inlineAvailableThinkingLevels.contains(current) else { return }
        let fallback = inlineAvailableThinkingLevels.first ?? "off"
        inlineDraft?.config.thinking = fallback == "off" ? nil : fallback
    }

    private func addInlineFallbackModel(_ model: String) {
        guard inlineDraft?.config.fallbackModels.contains(model) == false else { return }
        inlineDraft?.config.fallbackModels.append(model)
    }

    private func removeInlineFallbackModel(_ model: String) {
        inlineDraft?.config.fallbackModels.removeAll { $0 == model }
    }

    private func resetInlineToolAccess() {
        if case .builtinOverride = inlineDraft?.target {
            inlineDraft?.config.tools = agent.builtin?.parsed.tools
            inlineDraft?.config.mcpDirectTools = agent.builtin?.parsed.mcpDirectTools
        } else {
            inlineDraft?.config.tools = nil
            inlineDraft?.config.mcpDirectTools = nil
        }
    }

    private func addInlineTool(_ tool: String) {
        var values = selectedInlineToolValues
        guard !values.contains(tool) else { return }
        values.append(tool)
        applyInlineToolValues(values)
    }

    private func removeInlineTool(_ tool: String) {
        applyInlineToolValues(selectedInlineToolValues.filter { $0 != tool })
    }

    private func applyInlineToolValues(_ values: [String]) {
        var tools: [String] = []
        var mcpTools: [String] = []
        for value in values {
            if value.hasPrefix("mcp:") {
                let name = String(value.dropFirst(4))
                if !name.isEmpty { mcpTools.append(name) }
            } else {
                tools.append(value)
            }
        }
        inlineDraft?.config.tools = tools.isEmpty ? nil : tools
        inlineDraft?.config.mcpDirectTools = mcpTools.isEmpty ? nil : mcpTools
    }

    private func addInlineExtension(_ name: String) {
        var values = inlineDraft?.config.extensions ?? []
        guard !values.contains(name) else { return }
        values.append(name)
        inlineDraft?.config.extensions = values
    }

    private func removeInlineExtension(_ name: String) {
        inlineDraft?.config.extensions?.removeAll { $0 == name }
    }

    private func addInlineSkill(_ skill: String) {
        guard inlineDraft?.config.skills.contains(skill) == false else { return }
        inlineDraft?.config.skills.append(skill)
    }

    private func removeInlineSkill(_ skill: String) {
        inlineDraft?.config.skills.removeAll { $0 == skill }
    }

    private func normalizedInlineDraft(_ draft: AgentEditorDraft) -> AgentEditorDraft {
        var copy = draft
        copy.config.fallbackModels = normalizedList(copy.config.fallbackModels) ?? []
        copy.config.tools = normalizedList(copy.config.tools)
        copy.config.mcpDirectTools = normalizedList(copy.config.mcpDirectTools)
        copy.config.skills = normalizedList(copy.config.skills) ?? []
        copy.config.extensions = copy.config.extensions == nil ? nil : (normalizedList(copy.config.extensions) ?? [])
        copy.config.defaultReads = copy.config.defaultReads == nil ? nil : (normalizedList(copy.config.defaultReads) ?? [])
        if let output = copy.config.output?.trimmingCharacters(in: .whitespacesAndNewlines), output.isEmpty {
            copy.config.output = nil
        }
        if copy.config.thinking == "off" {
            copy.config.thinking = nil
        }
        return copy
    }

    private func normalizedList(_ value: [String]?) -> [String]? {
        guard let value else { return nil }
        let items = value.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return items.isEmpty ? nil : items
    }

    private func changedFieldsSummary(from before: AgentEditorDraft, to after: AgentEditorDraft) -> String {
        var changes: [(String, String, String)] = []

        func add(_ field: String, _ old: String, _ new: String) {
            guard old != new else { return }
            changes.append((field, old, new))
        }

        let beforeConfig = before.config
        let afterConfig = after.config
        add("Model", beforeConfig.model ?? "default", afterConfig.model ?? "default")
        add("Fallback Models", beforeConfig.fallbackModels.isEmpty ? "—" : beforeConfig.fallbackModels.joined(separator: ", "), afterConfig.fallbackModels.isEmpty ? "—" : afterConfig.fallbackModels.joined(separator: ", "))
        add("Thinking", beforeConfig.thinking ?? "off", afterConfig.thinking ?? "off")
        add("Prompt Mode", beforeConfig.systemPromptMode ?? "—", afterConfig.systemPromptMode ?? "—")
        add("Inherit Project Context", display(beforeConfig.inheritProjectContext), display(afterConfig.inheritProjectContext))
        add("Inherit Skills", display(beforeConfig.inheritSkills), display(afterConfig.inheritSkills))
        add("Disabled", display(beforeConfig.disabled), display(afterConfig.disabled))
        add("Tools", ((beforeConfig.tools ?? []) + (beforeConfig.mcpDirectTools ?? []).map { "mcp:\($0)" }).nonEmptyJoined, ((afterConfig.tools ?? []) + (afterConfig.mcpDirectTools ?? []).map { "mcp:\($0)" }).nonEmptyJoined)
        add("Extensions", (beforeConfig.extensions ?? []).nonEmptyJoined, (afterConfig.extensions ?? []).nonEmptyJoined)
        add("Skills", beforeConfig.skills.nonEmptyJoined, afterConfig.skills.nonEmptyJoined)
        add("Output", beforeConfig.output ?? "—", afterConfig.output ?? "—")
        add("Default Reads", (beforeConfig.defaultReads ?? []).nonEmptyJoined, (afterConfig.defaultReads ?? []).nonEmptyJoined)
        add("Default Progress", display(beforeConfig.defaultProgress), display(afterConfig.defaultProgress))
        add("Interactive", display(beforeConfig.interactive), display(afterConfig.interactive))
        add("Max Subagent Depth", beforeConfig.maxSubagentDepth.map(String.init) ?? "—", afterConfig.maxSubagentDepth.map(String.init) ?? "—")
        add("Prompt", shortPromptSummary(beforeConfig.systemPrompt), shortPromptSummary(afterConfig.systemPrompt))

        return changes.map { "\($0.0): \($0.1) → \($0.2)" }.joined(separator: "\n")
    }

    private func shortPromptSummary(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "empty" }
        if trimmed.count <= 60 { return trimmed }
        return String(trimmed.prefix(57)) + "..."
    }

    private func fieldHelpText(for title: String) -> String? {
        switch title {
        case "Model":
            return "Default model for this agent. Builtin overrides can change this. Custom agents save it in frontmatter."
        case "Fallback Models":
            return "Ordered backup models Pi can use when the primary model is unavailable or unsuitable."
        case "Thinking":
            return "Reasoning effort hint for the selected model. Available options are derived from Pi’s installed model metadata."
        case "Prompt Mode":
            return "Replace makes this a focused specialist prompt. Append keeps more of Pi’s normal base behavior and adds this agent’s instructions on top."
        case "Inherit Project Context", "Project Context":
            return "When enabled, the agent keeps Pi’s project instruction context, including files like AGENTS.md or CLAUDE.md."
        case "Inherit Skills", "Skills":
            return "When enabled, the agent keeps Pi’s discovered skills catalog in its prompt. This mainly matters when the agent has the read tool. Explicit skills listed on the agent are separate."
        case "Disabled", "Availability":
            return "Disabled agents are hidden from subagent discovery and normal launches."
        case "Output", "Output File":
            return "Default output file for single-agent runs. Most useful in managed workflows such as chains and parallel runs."
        case "Default Reads":
            return "Files Pi should read before execution when this agent is launched through managed workflows."
        case "Default Progress", "Progress":
            return "When enabled, managed workflows maintain progress.md for this agent."
        case "Interactive", "Interaction":
            return "Compatibility frontmatter field for interactive behavior. Parsed and preserved, but not strongly enforced by pi-subagents v1."
        case "Max Subagent Depth", "Max Depth":
            return "Limits how many more nested subagent launches this agent can create below itself."
        case "Extensions":
            return "Extension loading mode. Omitted means normal extension loading, empty means none, and explicit values act as an allowlist."
        case "Tool Access":
            return "If tools are omitted, the agent keeps Pi’s normal tool behavior. If tools are explicitly set, they become an allowlist. Direct MCP tools use the mcp:name form."
        case "Extension Mode":
            return "If extensions are omitted, Pi uses normal extension loading. An explicit list acts as an allowlist. An empty list means no discovered extensions."
        case "Add Tool":
            return "Choose from built-in Pi tools plus direct MCP tools visible in this agent’s scope."
        case "Selected":
            return "Current explicit values for this field. Remove any item with the x button."
        case "Add Extension":
            return "Choose from installed Pi package references already visible to Pi Manager."
        case "Add Skill":
            return "Choose from skills visible in this agent’s current scope."
        case "Skill Catalog":
            return "Only skills discoverable in this scope are offered here."
        case "Explicit Skill Count":
            return "Number of skills explicitly attached to this agent."
        default:
            return nil
        }
    }

    private func inlineOptionalStringBinding(for keyPath: WritableKeyPath<AgentConfig, String?>) -> Binding<String> {
        Binding(
            get: { inlineDraft?.config[keyPath: keyPath] ?? "" },
            set: { inlineDraft?.config[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }

    private func inlineStringListBinding(for keyPath: WritableKeyPath<AgentConfig, [String]?>) -> Binding<String> {
        Binding(
            get: { (inlineDraft?.config[keyPath: keyPath] ?? []).joined(separator: ", ") },
            set: { newValue in
                let values = newValue
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                inlineDraft?.config[keyPath: keyPath] = values.isEmpty ? nil : values
            }
        )
    }

    private func inlineOptionalBoolBinding(for keyPath: WritableKeyPath<AgentConfig, Bool?>) -> Binding<Bool> {
        Binding(
            get: { inlineDraft?.config[keyPath: keyPath] ?? false },
            set: { inlineDraft?.config[keyPath: keyPath] = $0 }
        )
    }

    private func inlineDefaultedOptionalBoolBinding(for keyPath: WritableKeyPath<AgentConfig, Bool?>, default defaultValue: Bool) -> Binding<Bool> {
        Binding(
            get: { inlineDraft?.config[keyPath: keyPath] ?? defaultValue },
            set: { inlineDraft?.config[keyPath: keyPath] = $0 }
        )
    }

    private func inlineDefaultedOptionalBoolBinding(for keyPath: WritableKeyPath<AgentConfig, Bool?>, default defaultValue: @escaping () -> Bool) -> Binding<Bool> {
        Binding(
            get: { inlineDraft?.config[keyPath: keyPath] ?? defaultValue() },
            set: { inlineDraft?.config[keyPath: keyPath] = $0 }
        )
    }

    private func inlineOptionalIntBinding(for keyPath: WritableKeyPath<AgentConfig, Int?>) -> Binding<Int> {
        Binding(
            get: { inlineDraft?.config[keyPath: keyPath] ?? 0 },
            set: { inlineDraft?.config[keyPath: keyPath] = $0 }
        )
    }

    private func display(_ value: Bool?) -> String {
        guard let value else { return "—" }
        return value ? "Yes" : "No"
    }

    private func openFile(_ path: String?) {
        guard let path else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private func revealInFinder(_ path: String?) {
        guard let path else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

private struct SaveConfirmation: Identifiable {
    let id = UUID()
    let summary: String
    let exitEditMode: Bool
}

private struct ChainsScreen: View {
    @ObservedObject var viewModel: AppViewModel
    let onCreateChain: (AgentEditingTarget.CustomAgentScope) -> Void
    let onDuplicateChain: (ChainRecord, AgentEditingTarget.CustomAgentScope) -> Void
    let onConvertChain: (ChainRecord, AgentEditingTarget.CustomAgentScope) throws -> Void
    let onEditChain: (ChainRecord) -> Void
    @Binding var isRecapPresented: Bool

    var body: some View {
        HStack(spacing: 0) {
        HSplitView {
            AppSidebarPane(title: "Chains", subtitle: "\(viewModel.allVisibleChainRecords.count) total") {
                List(viewModel.allVisibleChainRecords, selection: $viewModel.selectedChainID) { chain in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(chain.name)
                            .font(.headline)
                            .fontWidth(.expanded)
                            .lineLimit(2)
                        Text(chain.description.isEmpty ? "\(chain.steps.count) steps" : chain.description)
                            .foregroundStyle(AppTheme.mutedText)
                            .lineLimit(2)
                    }
                    .padding(.vertical, 6)
                    .tag(chain.id)
                }
                .listStyle(.inset)
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Menu {
                        Button("New Global Chain") {
                            onCreateChain(.global)
                        }
                        if viewModel.selectedProjectPath != nil {
                            Button("New Project Chain") {
                                onCreateChain(.project)
                            }
                        }
                        if let selectedChain = viewModel.selectedChain {
                            Divider()
                            Button("Duplicate as Global Chain") {
                                onDuplicateChain(selectedChain, .global)
                            }
                            if viewModel.selectedProjectPath != nil {
                                Button("Duplicate as Project Chain") {
                                    onDuplicateChain(selectedChain, .project)
                                }
                            }
                            Divider()
                            if selectedChain.source.kind != .global {
                                Button("Move to Global Scope") {
                                    do {
                                        try onConvertChain(selectedChain, .global)
                                    } catch {
                                        NSSound.beep()
                                    }
                                }
                            }
                            if viewModel.selectedProjectPath != nil, selectedChain.source.kind != .project {
                                Button("Move to Project Scope") {
                                    do {
                                        try onConvertChain(selectedChain, .project)
                                    } catch {
                                        NSSound.beep()
                                    }
                                }
                            }
                        }
                    } label: {
                        Label("New", systemImage: "plus")
                    }
                }

                if let selectedChain = viewModel.selectedChain {
                    ToolbarSpacer(.fixed, placement: .primaryAction)

                    ToolbarItemGroup(placement: .primaryAction) {
                        Button {
                            openFile(selectedChain.filePath)
                        } label: {
                            Label("Open", systemImage: "folder")
                        }
                        .help("Open the selected chain file")

                        Button {
                            revealInFinder(selectedChain.filePath)
                        } label: {
                            Label("Reveal", systemImage: "arrow.up.forward.app")
                        }
                        .help("Reveal the selected chain file in Finder")

                        Menu {
                            Button("Duplicate as Global Chain") {
                                onDuplicateChain(selectedChain, .global)
                            }
                            if viewModel.selectedProjectPath != nil {
                                Button("Duplicate as Project Chain") {
                                    onDuplicateChain(selectedChain, .project)
                                }
                            }
                            Divider()
                            if selectedChain.source.kind != .global {
                                Button("Move to Global Scope") {
                                    do {
                                        try onConvertChain(selectedChain, .global)
                                    } catch {
                                        NSSound.beep()
                                    }
                                }
                            }
                            if viewModel.selectedProjectPath != nil, selectedChain.source.kind != .project {
                                Button("Move to Project Scope") {
                                    do {
                                        try onConvertChain(selectedChain, .project)
                                    } catch {
                                        NSSound.beep()
                                    }
                                }
                            }
                        } label: {
                            Label("More", systemImage: "ellipsis.circle")
                        }
                        .help("More chain actions")

                        Button {
                            onEditChain(selectedChain)
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .help("Edit selected chain")
                    }
                }
            }
            .frame(minWidth: 320, idealWidth: 380, maxWidth: 460)

            if let chain = viewModel.selectedChain {
                AppPage(chain.name, subtitle: chain.description.nonEmpty) {
                    AppCard(title: "How Chains Work") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("• Each step runs in order and later steps can use earlier output.")
                            Text("• Step `output`, `reads`, `skills`, `model`, and `progress` override the agent’s defaults for that step.")
                            Text("• `reads: false`, `skills: false`, or `output: false` explicitly turn that behavior off for the step.")
                            Text("• Relative read/write paths are resolved from the chain working directory.")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    AppCard(title: "Library & Source") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Reusable chains live in ~/.pi/agent/agent-library/chains. Pi only sees them when Pi Manager links them globally or into a project.")
                                .foregroundStyle(AppTheme.mutedText)
                                .fixedSize(horizontal: false, vertical: true)

                            AppKeyValueList(rows: [
                                ("Scope", chain.source.kind.rawValue),
                                ("In Library", chain.source.kind == .library ? "Yes" : "No"),
                                ("Active Globally", viewModel.chainIsEnabledGlobally(chain) ? "Yes" : "No"),
                                ("Assigned Projects", assignedProjectSummary(chain)),
                                ("Path", chain.filePath),
                                ("Steps", "\(chain.steps.count)")
                            ])

                            if chain.source.kind != .library {
                                Button("Move to Library") { do { try viewModel.moveChainToLibrary(chain) } catch { NSSound.beep() } }
                            }
                        }
                    }

                    AppCard(title: "Global Visibility") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(viewModel.chainIsEnabledGlobally(chain) ? "This chain is available in every project." : "Make this chain available globally instead of only selected projects.")
                                .foregroundStyle(AppTheme.mutedText)
                            if viewModel.chainIsEnabledGlobally(chain) {
                                Button("Disable Globally") { do { try viewModel.disableChainGlobally(chain) } catch { NSSound.beep() } }
                            } else {
                                Button("Enable Globally") { do { try viewModel.enableChainGlobally(chain) } catch { NSSound.beep() } }
                                    .buttonStyle(.borderedProminent)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    AppCard(title: "Project Assignment") {
                        chainProjectAssignmentList(for: chain)
                    }

                    AppCard(title: "Raw Chain") {
                        Text(ChainPersistence().serialize(chain))
                            .font(.footnote.monospaced())
                            .foregroundStyle(AppTheme.mutedText)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    ForEach(chain.steps) { step in
                        AppCard(title: step.agent) {
                            VStack(alignment: .leading, spacing: 14) {
                                if step.outputDisabled || step.readsDisabled || step.model != nil || step.skillsDisabled || step.progress != nil || !(step.reads ?? []).isEmpty || !(step.skills ?? []).isEmpty {
                                    AppKeyValueList(rows: [
                                        ("Output", step.outputDisabled ? "false" : (step.output ?? "—")),
                                        ("Reads", step.readsDisabled ? "false" : (step.reads?.joined(separator: ", ") ?? "—")),
                                        ("Model", step.model ?? "—"),
                                        ("Skills", step.skillsDisabled ? "false" : (step.skills?.joined(separator: ", ") ?? "—")),
                                        ("Progress", step.progress.map { $0 ? "true" : "false" } ?? "—")
                                    ])
                                }
                                MarkdownDocumentView(source: step.body.isEmpty ? "No step body parsed yet." : step.body)
                            }
                        }
                    }
                }
            } else {
                ContentUnavailableView("No Chain Selected", systemImage: "point.3.connected.trianglepath.dotted")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }

        if isRecapPresented, let project = viewModel.selectedDiscoveredProject {
            Divider()
            SubagentsProjectRecapPanel(
                project: project,
                snapshot: viewModel.startupSnapshot(forProjectPath: project.path),
                libraryAgents: viewModel.snapshot.libraryAgents,
                libraryChains: viewModel.snapshot.libraryChains,
                onClose: { isRecapPresented = false }
            )
            .frame(width: 400)
        }
        }
    }

    private func chainProjectAssignmentList(for chain: ChainRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Check each project that should load this chain. Project links are created in PROJECT/.pi/chains.")
                .foregroundStyle(AppTheme.mutedText)
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(viewModel.enabledProjects) { project in
                    Toggle(isOn: Binding(
                        get: { viewModel.chain(chain, isEnabledFor: project) },
                        set: { enabled in do { try viewModel.setChain(chain, enabled: enabled, for: project) } catch { NSSound.beep() } }
                    )) {
                        HStack(spacing: 10) {
                            ProjectIconView(imageURL: project.iconFileURL, symbolName: project.fallbackSymbolName, size: 30)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(project.name).font(.body.weight(.semibold))
                                Text(project.repositoryName ?? project.path).font(.caption).foregroundStyle(AppTheme.mutedText).lineLimit(1).truncationMode(.middle)
                            }
                        }
                        .frame(height: 46, alignment: .center)
                    }
                    .toggleStyle(.checkbox)
                    .controlSize(.large)
                    .padding(.vertical, 8)
                    if project.id != viewModel.enabledProjects.last?.id { Divider() }
                }
            }
        }
    }

    private func assignedProjectSummary(_ chain: ChainRecord) -> String {
        let projects = viewModel.assignedProjects(for: chain).map(\.name)
        return projects.isEmpty ? "—" : projects.joined(separator: ", ")
    }

    private func openFile(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

private struct SubagentsInfoPopover: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Subagent library")
                .font(.headline)
                .fontWidth(.expanded)
            VStack(alignment: .leading, spacing: 10) {
                infoRow("Agent Library", "Central storage in ~/.pi/agent/agent-library/agents. Pi does not load these until linked.")
                infoRow("Chain Library", "Central storage in ~/.pi/agent/agent-library/chains. Pi does not load these until linked.")
                infoRow("Global", "Agent links are created where pi-subagents would create user agents (~/.agents when present, otherwise ~/.pi/agent/agents). Chain links use ~/.pi/agent/chains.")
                infoRow("Project", "Links are created in PROJECT/.pi/agents and PROJECT/.pi/chains.")
                infoRow("Builtins", "Package-provided builtins stay read-only. Customize them with pi-subagents settings overrides.")
            }
        }
        .padding(16)
        .frame(width: 390, alignment: .leading)
    }

    private func infoRow(_ title: String, _ description: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.subheadline.weight(.semibold)).fontWidth(.expanded)
            Text(description).font(.caption).foregroundStyle(AppTheme.mutedText).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SubagentsProjectRecapPanel: View {
    let project: DiscoveredProject
    let snapshot: ScanSnapshot
    let libraryAgents: [AgentRecord]
    let libraryChains: [ChainRecord]
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ProjectIconView(imageURL: project.iconFileURL, symbolName: project.fallbackSymbolName, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pi Subagents Recap").font(.headline).fontWidth(.expanded)
                    Text(project.name).font(.caption).foregroundStyle(AppTheme.mutedText)
                }
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark") }.buttonStyle(.plain)
            }
            .padding(16)
            Divider()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("These are the agents and chains Pi Manager expects pi-subagents to discover for this project, after global/project precedence and builtin overrides.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                    agentRecapSection("Effective Agents", agents: snapshot.effectiveAgents, color: .purple)
                    chainRecapSection("Effective Chains", chains: snapshot.chains, color: .blue)
                    if !libraryAgents.isEmpty { libraryAgentSection }
                    if !libraryChains.isEmpty { libraryChainSection }
                }
                .padding(16)
            }
        }
        .background(AppTheme.subtleFill)
    }

    private func agentRecapSection(_ title: String, agents: [EffectiveAgentRecord], color: Color) -> some View {
        recapShell(title, count: agents.count, color: color) {
            ForEach(agents) { agent in
                recapRow(icon: agent.resolved.disabled == true ? "nosign" : "sparkles.rectangle.stack", color: agent.resolved.disabled == true ? .red : color, title: agent.name, subtitle: agent.resolutionKind.rawValue)
            }
        }
    }

    private func chainRecapSection(_ title: String, chains: [ChainRecord], color: Color) -> some View {
        recapShell(title, count: chains.count, color: color) {
            ForEach(chains) { chain in
                recapRow(icon: "point.3.connected.trianglepath.dotted", color: color, title: chain.name, subtitle: "\(chain.source.kind.rawValue) · \(chain.steps.count) steps")
            }
        }
    }

    private var libraryAgentSection: some View {
        recapShell("Library Agents", count: libraryAgents.count, color: .secondary) {
            ForEach(libraryAgents) { agent in recapRow(icon: "books.vertical", color: .secondary, title: agent.name, subtitle: "Stored, not loaded until assigned") }
        }
    }

    private var libraryChainSection: some View {
        recapShell("Library Chains", count: libraryChains.count, color: .secondary) {
            ForEach(libraryChains) { chain in recapRow(icon: "books.vertical", color: .secondary, title: chain.name, subtitle: "Stored, not loaded until assigned") }
        }
    }

    private func recapShell<Content: View>(_ title: String, count: Int, color: Color, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text(title).font(.headline).fontWidth(.expanded); Spacer(); AppLabelTag(text: "\(count)", color: color) }
            if count == 0 { Text("None").font(.caption).foregroundStyle(AppTheme.mutedText) } else { VStack(alignment: .leading, spacing: 8) { content() } }
        }
    }

    private func recapRow(icon: String, color: Color, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(AppTheme.mutedText).lineLimit(2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct SkillsInfoPopover: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Skill visibility")
                .font(.headline)
                .fontWidth(.expanded)

            VStack(alignment: .leading, spacing: 10) {
                infoRow("Library", "Central storage in ~/.pi/agent/skill-library. Pi does not load these until linked.")
                infoRow("Global", "Linked in ~/.pi/agent/skills. Pi loads these in every project.")
                infoRow("Project", "Linked or stored in PROJECT/.pi/skills. Pi loads these only for that project.")
                infoRow("Package", "Provided by installed packages. Treat as read-only unless imported later.")
            }

            Text("Use Global Visibility and Project Assignment in the right column to manage where library skills are loaded.")
                .font(.caption)
                .foregroundStyle(AppTheme.mutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 360, alignment: .leading)
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
}

private struct SkillsProjectRecapPanel: View {
    let project: DiscoveredProject
    let globalSkills: [SkillRecord]
    let projectSkills: [SkillRecord]
    let packageSkills: [SkillRecord]
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                ProjectIconView(imageURL: project.iconFileURL, symbolName: project.fallbackSymbolName, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pi Skill Recap")
                        .font(.headline)
                        .fontWidth(.expanded)
                    Text(project.name)
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedText)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("Close recap")
            }
            .padding(16)

            Divider()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("These are the skills Pi will effectively see when launched in this project: global skills, project-assigned library skills, and package-provided skills.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)

                    recapSection("Global", skills: globalSkills, color: .blue, emptyText: "No global skills")
                    recapSection("Project", skills: projectSkills, color: .green, emptyText: "No project-assigned skills")
                    recapSection("Package", skills: packageSkills, color: .orange, emptyText: "No package skills")
                }
                .padding(16)
            }
        }
        .background(AppTheme.subtleFill)
    }

    private func recapSection(_ title: String, skills: [SkillRecord], color: Color, emptyText: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.headline)
                    .fontWidth(.expanded)
                Spacer()
                AppLabelTag(text: "\(skills.count)", color: color)
            }

            if skills.isEmpty {
                Text(emptyText)
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(skills, id: \.name) { skill in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: title == "Package" ? "shippingbox" : "wand.and.stars")
                                .foregroundStyle(color)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(skill.name)
                                    .font(.subheadline.weight(.semibold))
                                if let description = skill.description, !description.isEmpty {
                                    Text(description)
                                        .font(.caption)
                                        .foregroundStyle(AppTheme.mutedText)
                                        .lineLimit(2)
                                }
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(AppTheme.cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }
        }
    }
}

private struct SkillsScreen: View {
    @ObservedObject var viewModel: AppViewModel
    @Binding var isRecapPresented: Bool
    @State private var selectedSkillName: String?

    var body: some View {
        HStack(spacing: 0) {
            AppPage("Skills", subtitle: pageSubtitle) {
                HStack(alignment: .top, spacing: AppTheme.sectionSpacing) {
                VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
                    if let selectedProject {
                        AppCard(title: "Active in \(selectedProject.name)") {
                            skillGrid(activeSkills, emptyText: "No skills are active for this project.")
                        }

                        if !inactiveLibrarySkills.isEmpty {
                            AppCard(title: "Library Skills") {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("Library skills are centrally stored and only become active when assigned to this project or enabled globally.")
                                        .foregroundStyle(AppTheme.mutedText)
                                    skillGrid(inactiveLibrarySkills, emptyText: "No unassigned library skills.")
                                }
                            }
                        }
                    } else {
                        AppCard(title: "Global Skills") {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Select a project to see exactly which skills are active there and to manage project assignment.")
                                    .foregroundStyle(AppTheme.mutedText)
                                skillGrid(globalSkills, emptyText: "No global skills.")
                            }
                        }

                        if !librarySkills.isEmpty {
                            AppCard(title: "Library Skills") {
                                skillGrid(librarySkills, emptyText: "No library skills.")
                            }
                        }
                    }

                    if !packageSkills.isEmpty {
                        AppCard(title: "Package Skills") {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Package skills are active by default when their package is discovered. They are package-managed, so Pi Manager does not assign or unlink them per project.")
                                    .foregroundStyle(AppTheme.mutedText)
                                skillGrid(packageSkills, emptyText: "No package skills.")
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)

                VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
                    if let skill = selectedSkill {
                        AppCard(title: "Manage \(skill.name)") {
                            AppKeyValueList(rows: [
                                ("Source", skillScopeLabel(skill, selectedProjectRoot: viewModel.snapshot.projectRoot)),
                                ("Active Globally", viewModel.skillIsEnabledGlobally(skill) ? "Yes" : "No"),
                                ("Assigned Projects", assignedProjectSummary(skill)),
                                ("Path", skill.filePath)
                            ])
                        }

                        if skill.source.kind == .package {
                            AppCard(title: "Package Skill") {
                                Text("This skill is provided by an installed package and is active through Pi/package discovery. Project assignment is disabled to avoid copying or modifying package-managed content.")
                                    .foregroundStyle(AppTheme.mutedText)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        } else {
                            AppCard(title: "Global Visibility") {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text(viewModel.skillIsEnabledGlobally(skill) ? "This skill is active in every project." : "Make this skill active everywhere instead of only selected projects.")
                                        .foregroundStyle(AppTheme.mutedText)
                                        .frame(maxWidth: .infinity, alignment: .leading)

                                    if viewModel.skillIsEnabledGlobally(skill) {
                                        Button("Disable Globally") {
                                            do { try viewModel.disableSkillGlobally(skill) }
                                            catch { NSSound.beep() }
                                        }
                                    } else {
                                        Button("Enable Globally") {
                                            do { try viewModel.enableSkillGlobally(skill) }
                                            catch { NSSound.beep() }
                                        }
                                        .buttonStyle(.borderedProminent)
                                    }
                                }
                            }

                            AppCard(title: "Project Assignment") {
                                projectAssignmentList(for: skill)
                            }
                        }

                        AppCard(title: "Definition") {
                            MarkdownDocumentView(source: skill.body, minimumHeight: 220)
                        }
                    } else {
                        AppCard {
                            ContentUnavailableView("No Skill Selected", systemImage: "wand.and.stars")
                                .frame(maxWidth: .infinity, minHeight: 240)
                        }
                    }
                }
                .frame(minWidth: 360, idealWidth: 460, maxWidth: 560, alignment: .topLeading)
                }
            }

            if isRecapPresented, let selectedProject {
                Divider()
                SkillsProjectRecapPanel(
                    project: selectedProject,
                    globalSkills: globalSkills,
                    projectSkills: projectAssignedSkills,
                    packageSkills: packageSkills,
                    onClose: { isRecapPresented = false }
                )
                .frame(width: 380)
            }
        }
        .onAppear { ensureSelection() }
        .onChange(of: viewModel.allVisibleSkillRecords) { _, _ in ensureSelection() }
    }

    private var selectedProject: DiscoveredProject? {
        viewModel.selectedDiscoveredProject
    }

    private var pageSubtitle: String {
        if let selectedProject {
            return "Active skills for \(selectedProject.name), plus central library assignment"
        }
        return "Select a project to manage project-specific skill assignment"
    }

    private var managedSkills: [SkillRecord] {
        let grouped = Dictionary(grouping: viewModel.allVisibleSkillRecords, by: \.name)
        return grouped.values.compactMap(preferredSkillRecord)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var selectedSkill: SkillRecord? {
        guard let selectedSkillName else { return managedSkills.first }
        return managedSkills.first { $0.name == selectedSkillName } ?? managedSkills.first
    }

    private var activeSkills: [SkillRecord] {
        if selectedProject != nil {
            return managedSkills.filter { skillIsActiveForCurrentProject($0) }
        }
        return globalSkills + packageSkills
    }

    private var globalSkills: [SkillRecord] {
        managedSkills.filter { viewModel.skillIsEnabledGlobally($0) && $0.source.kind != .package }
    }

    private var librarySkills: [SkillRecord] {
        managedSkills.filter { $0.source.kind == .library }
    }

    private var inactiveLibrarySkills: [SkillRecord] {
        librarySkills.filter { !skillIsActiveForCurrentProject($0) }
    }

    private var packageSkills: [SkillRecord] {
        managedSkills.filter { $0.source.kind == .package }
    }

    private var projectAssignedSkills: [SkillRecord] {
        guard let selectedProject else { return [] }
        return managedSkills.filter {
            viewModel.skill($0, isEnabledFor: selectedProject) &&
            !viewModel.skillIsEnabledGlobally($0) &&
            $0.source.kind != .package
        }
    }

    private func preferredSkillRecord(_ records: [SkillRecord]) -> SkillRecord? {
        records.first { $0.source.kind == .library }
        ?? records.first { $0.source.kind == .global }
        ?? records.first { $0.source.kind == .project }
        ?? records.first { $0.source.kind == .legacyProject }
        ?? records.first { $0.source.kind == .package }
        ?? records.first
    }

    private func skillIsActiveForCurrentProject(_ skill: SkillRecord) -> Bool {
        if viewModel.skillIsEnabledGlobally(skill) { return true }
        if let selectedProject, viewModel.skill(skill, isEnabledFor: selectedProject) { return true }
        return skill.source.kind == .package && selectedProject != nil
    }

    private func ensureSelection() {
        guard selectedSkillName == nil || !managedSkills.contains(where: { $0.name == selectedSkillName }) else { return }
        selectedSkillName = managedSkills.first?.name
    }

    private func skillGrid(_ skills: [SkillRecord], emptyText: String, inactive: Bool = false) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
            if skills.isEmpty {
                Text(emptyText)
                    .foregroundStyle(AppTheme.mutedText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(skills, id: \.name) { skill in
                    skillTile(skill, inactive: inactive)
                }
            }
        }
    }

    private func skillTile(_ skill: SkillRecord, inactive: Bool) -> some View {
        Button {
            selectedSkillName = skill.name
            viewModel.selectedSkillID = skill.id
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: skill.source.kind == .package ? "shippingbox" : "wand.and.stars")
                        .foregroundStyle(skillColor(skill))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(skill.name)
                            .font(.headline)
                            .fontWidth(.expanded)
                            .foregroundStyle(.primary)
                        Text(skill.description ?? "No description")
                            .font(.caption)
                            .foregroundStyle(AppTheme.mutedText)
                            .lineLimit(2)
                    }
                    Spacer()
                    AppLabelTag(text: statusLabel(skill), color: skillColor(skill))
                }

                if selectedProject != nil, !skillIsActiveForCurrentProject(skill) {
                    Text("Not active in selected project")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.mutedText)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(selectedSkillName == skill.name ? Color.accentColor.opacity(0.10) : AppTheme.subtleFill)
                    .stroke(selectedSkillName == skill.name ? Color.accentColor.opacity(0.45) : AppTheme.cardStroke, lineWidth: 1)
            )
            .opacity((inactive || skillIsUnusedLibrarySkill(skill)) ? 0.62 : 1)
            .saturation((inactive || skillIsUnusedLibrarySkill(skill)) ? 0.25 : 1)
        }
        .buttonStyle(.plain)
    }

    private func projectAssignmentList(for skill: SkillRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Check each project that should load this skill. The project icon helps confirm the target quickly.")
                .foregroundStyle(AppTheme.mutedText)

            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(viewModel.enabledProjects) { project in
                    Toggle(isOn: Binding(
                        get: { viewModel.skill(skill, isEnabledFor: project) },
                        set: { enabled in
                            do { try viewModel.setSkill(skill, enabled: enabled, for: project) }
                            catch { NSSound.beep() }
                        }
                    )) {
                        HStack(alignment: .center, spacing: 10) {
                            ProjectIconView(imageURL: project.iconFileURL, symbolName: project.fallbackSymbolName, size: 30)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(project.name)
                                    .font(.body.weight(.semibold))
                                Text(project.repositoryName ?? project.path)
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.mutedText)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .frame(height: 46, alignment: .center)
                    }
                    .toggleStyle(.checkbox)
                    .controlSize(.large)
                    .padding(.vertical, 8)

                    if project.id != viewModel.enabledProjects.last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    private func statusLabel(_ skill: SkillRecord) -> String {
        if skillIsUnusedLibrarySkill(skill) { return "Unused" }
        if skill.source.kind == .package { return "Package" }
        if selectedProject != nil, skillIsActiveForCurrentProject(skill) { return "Active" }
        if viewModel.skillIsEnabledGlobally(skill) { return "Global" }
        if skill.source.kind == .library { return "Library" }
        return skillScopeLabel(skill, selectedProjectRoot: viewModel.snapshot.projectRoot)
    }

    private func skillColor(_ skill: SkillRecord) -> Color {
        if selectedProject != nil, skillIsActiveForCurrentProject(skill) { return .green }
        if viewModel.skillIsEnabledGlobally(skill) { return .blue }
        switch skill.source.kind {
        case .library: return .purple
        case .package: return .orange
        case .project, .legacyProject: return .green
        default: return .blue
        }
    }

    private func skillIsUnusedLibrarySkill(_ skill: SkillRecord) -> Bool {
        skill.source.kind == .library &&
        !viewModel.skillIsEnabledGlobally(skill) &&
        viewModel.assignedProjects(for: skill).isEmpty
    }

    private func assignedProjectSummary(_ skill: SkillRecord) -> String {
        let projects = viewModel.assignedProjects(for: skill).map(\.name)
        return projects.isEmpty ? "—" : projects.joined(separator: ", ")
    }
}

private struct EnvironmentScreen: View {
    let snapshot: ScanSnapshot
    let onEditKey: (EnvKeyRecord) -> Void
    @State private var revealedKeys: Set<String> = []

    var body: some View {
        AppPage("Environment", subtitle: "Keys are shown without secret values unless you explicitly reveal them") {
            AppCard(title: "How Environment Resolution Works") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("• Project `.env` values win over global/user `.env` values for the same key.")
                    Text("• The effective list shows the winning value per key, not every duplicate at once.")
                    Text("• Reveal only changes the app display. It does not change the file.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            AppCard(title: "Effective Environment") {
                if effectiveEnvRows.isEmpty {
                    Text("No env files found.")
                        .foregroundStyle(AppTheme.mutedText)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        if snapshot.projectRoot != nil {
                            Text("Project keys override global keys when the same name appears in both files.")
                                .foregroundStyle(AppTheme.mutedText)
                        } else {
                            Text("Showing the effective global environment plus any discovered project-specific keys. Select a project to inspect one merged environment precisely.")
                                .foregroundStyle(AppTheme.mutedText)
                        }

                        ForEach(effectiveEnvRows, id: \.key) { row in
                            AppRowCard {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(alignment: .top, spacing: 10) {
                                        Image(systemName: "key")
                                            .foregroundStyle(.orange)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(row.key)
                                                .font(.body.monospaced())
                                            Text(row.summary)
                                                .font(.caption)
                                                .foregroundStyle(AppTheme.mutedText)
                                        }
                                        Spacer()
                                        AppLabelTag(text: row.winningSource.kind.rawValue, color: row.winningSource.kind == .project ? .green : .orange)
                                    }

                                    HStack(spacing: 10) {
                                        Text(revealedKeys.contains(row.key) ? (row.winningRecord.value ?? "") : maskedValue(row.winningRecord.value))
                                            .font(.footnote.monospaced())
                                            .foregroundStyle(AppTheme.mutedText)
                                            .textSelection(.enabled)
                                        Spacer()
                                        Button(revealedKeys.contains(row.key) ? "Hide" : "Reveal") {
                                            toggleReveal(for: row.key)
                                        }
                                        Menu("Actions") {
                                            Button("Copy Key") { copyToPasteboard(row.winningRecord.key) }
                                            Button("Copy Value") { copyToPasteboard(row.winningRecord.value ?? "") }
                                            Button("Copy Line") { copyToPasteboard("\(row.winningRecord.key)=\(row.winningRecord.value ?? "")") }
                                            Divider()
                                            Button("Edit Key") { onEditKey(row.winningRecord) }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            AppCard(title: "Source Files") {
                if snapshot.envKeys.isEmpty {
                    Text("No env source files found.")
                        .foregroundStyle(AppTheme.mutedText)
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(groupedEnvFiles, id: \.path) { file in
                            AppRowCard {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(alignment: .top, spacing: 10) {
                                        Image(systemName: "doc.text")
                                            .foregroundStyle(.secondary)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(file.path)
                                                .font(.footnote.monospaced())
                                            Text("\(file.keys.count) keys")
                                                .font(.caption)
                                                .foregroundStyle(AppTheme.mutedText)
                                        }
                                        Spacer()
                                        AppLabelTag(text: file.kind.rawValue, color: file.kind == .project ? .green : .orange)
                                    }

                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(spacing: 8) {
                                            ForEach(file.keys) { key in
                                                Button(key.key) { onEditKey(key) }
                                                    .buttonStyle(.bordered)
                                                    .font(.caption.monospaced())
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var effectiveEnvRows: [EffectiveEnvRow] {
        var grouped: [String: [EnvKeyRecord]] = [:]
        for record in snapshot.envKeys {
            grouped[record.key, default: []].append(record)
        }

        return grouped.keys.sorted().compactMap { key in
            guard let records = grouped[key], let winning = records.sorted(by: envPrecedence).first else { return nil }
            let overridden = records.filter { $0.id != winning.id }
            let summary: String
            if overridden.isEmpty {
                summary = winning.source.path
            } else {
                summary = "Using \(winning.source.path) over \(overridden.map { $0.source.path }.joined(separator: ", "))"
            }
            return EffectiveEnvRow(key: key, winningRecord: winning, winningSource: winning.source, summary: summary)
        }
    }

    private var groupedEnvFiles: [(path: String, kind: ResourceScopeKind, keys: [EnvKeyRecord])] {
        Dictionary(grouping: snapshot.envKeys, by: { $0.source.path })
            .map { path, keys in
                (path: path, kind: keys.first?.source.kind ?? .global, keys: keys.sorted { $0.key < $1.key })
            }
            .sorted { $0.path < $1.path }
    }

    private func envPrecedence(_ lhs: EnvKeyRecord, _ rhs: EnvKeyRecord) -> Bool {
        envRank(lhs.source.kind) > envRank(rhs.source.kind)
    }

    private func envRank(_ kind: ResourceScopeKind) -> Int {
        switch kind {
        case .project, .legacyProject:
            return 2
        default:
            return 1
        }
    }

    private func maskedValue(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "(empty)" }
        return String(repeating: "•", count: min(max(value.count, 8), 24))
    }

    private func toggleReveal(for key: String) {
        if revealedKeys.contains(key) {
            revealedKeys.remove(key)
        } else {
            revealedKeys.insert(key)
        }
    }
}

private struct EffectiveEnvRow {
    let key: String
    let winningRecord: EnvKeyRecord
    let winningSource: ScopeID
    let summary: String
}

private struct MCPScreen: View {
    let snapshot: ScanSnapshot

    var body: some View {
        AppPage("MCP", subtitle: "Configured MCP files, detected servers, and agent references") {
            AppCard(title: "MCP Access") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("MCP config files declare servers. Agents only use them when their configuration explicitly references matching direct `mcp:` tools or relevant extensions.")
                    AppKeyValueList(rows: [
                        ("Config Files", "\(snapshot.mcpConfigs.count)"),
                        ("Configured Servers", "\(allServers.count)"),
                        ("Agents Using Direct MCP Tools", "\(agentsUsingDirectMCP.count)"),
                        ("Direct MCP Tool Names", directToolSummary)
                    ])
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            AppCard(title: "Config Files") {
                if snapshot.mcpConfigs.isEmpty {
                    Text("No MCP config files found.")
                        .foregroundStyle(AppTheme.mutedText)
                } else {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(Array(snapshot.mcpConfigs.enumerated()), id: \.element.id) { index, config in
                            mcpConfigSection(config)
                            if index < snapshot.mcpConfigs.count - 1 {
                                Divider()
                            }
                        }
                    }
                }
            }

            AppCard(title: "Agents with Direct MCP Tools") {
                if agentsUsingDirectMCP.isEmpty {
                    Text("No visible agents currently declare direct `mcp:` tool entries.")
                        .foregroundStyle(AppTheme.mutedText)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(agentsUsingDirectMCP.enumerated()), id: \.element.id) { index, agent in
                            directMCPAgentRow(agent)
                            if index < agentsUsingDirectMCP.count - 1 {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
    }

    private func mcpConfigSection(_ config: MCPConfigRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(config.path)
                        .font(.headline)
                        .fontWidth(.expanded)
                        .textSelection(.enabled)
                    Text("\(config.source.kind.rawValue) · \(config.serverNames.count) servers")
                        .foregroundStyle(AppTheme.mutedText)
                }
                Spacer()
                Button("Open") { openFile(config.path) }
                Button("Reveal") { revealInFinder(config.path) }
            }

            AppKeyValueList(rows: [
                ("Project", projectName(from: config.path) ?? "—"),
                ("Likely Used By Direct MCP Tools", likelyUsedServersSummary(for: config))
            ])

            if config.serverNames.isEmpty {
                Text("No servers detected.")
                    .foregroundStyle(AppTheme.mutedText)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(config.serverNames.enumerated()), id: \.element) { index, server in
                        serverRow(server, config: config)
                        if index < config.serverNames.count - 1 {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private func serverRow(_ server: String, config: MCPConfigRecord) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "server.rack")
                .foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 2) {
                Text(server)
                    .font(.body.weight(.semibold))
                Text(serverUsageSummary(server, config: config))
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)
            }
        }
        .padding(.vertical, 8)
    }

    private func directMCPAgentRow(_ agent: EffectiveAgentRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(agent.name)
                .font(.headline)
                .fontWidth(.expanded)
            Text((agent.resolved.mcpDirectTools ?? []).map { "mcp:\($0)" }.joined(separator: ", "))
                .font(.footnote.monospaced())
                .foregroundStyle(AppTheme.mutedText)
                .textSelection(.enabled)
        }
        .padding(.vertical, 10)
    }

    private var agentsUsingDirectMCP: [EffectiveAgentRecord] {
        snapshot.effectiveAgents
            .filter { !(($0.resolved.mcpDirectTools ?? []).isEmpty) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var allServers: [String] {
        Array(Set(snapshot.mcpConfigs.flatMap(\.serverNames))).sorted()
    }

    private var allDirectTools: [String] {
        Array(Set(agentsUsingDirectMCP.flatMap { $0.resolved.mcpDirectTools ?? [] })).sorted()
    }

    private var directToolSummary: String {
        allDirectTools.isEmpty ? "None" : allDirectTools.map { "mcp:\($0)" }.joined(separator: ", ")
    }

    private func likelyUsedServersSummary(for config: MCPConfigRecord) -> String {
        let matches = config.serverNames.filter { allDirectTools.contains($0) }
        return matches.isEmpty ? "No obvious direct name match" : matches.joined(separator: ", ")
    }

    private func serverUsageSummary(_ server: String, config: MCPConfigRecord) -> String {
        let matchingAgents = agentsUsingDirectMCP.filter { ($0.resolved.mcpDirectTools ?? []).contains(server) }.map(\.name)
        if matchingAgents.isEmpty {
            return "No visible agent declares mcp:\(server)."
        }
        return "Referenced by \(matchingAgents.joined(separator: ", "))."
    }
}

private struct DiagnosticsScreen: View {
    let snapshot: ScanSnapshot

    var body: some View {
        AppPage("Diagnostics", subtitle: "Parsed settings, overrides, and actionable warnings") {
            AppCard(title: "Diagnostics") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("This screen shows what Pi Manager parsed from settings files. Builtin overrides are JSON patches; custom agents and chains still come from markdown files.")
                        .foregroundStyle(AppTheme.mutedText)
                    AppKeyValueList(rows: [
                        ("Settings Files", "\(snapshot.settings.count)"),
                        ("Overrides", "\(snapshot.settings.flatMap(\.agentOverrides).count)"),
                        ("Warnings", "\(snapshot.warnings.count)")
                    ])
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if snapshot.settings.isEmpty {
                AppCard(title: "Settings Files") {
                    Text("No settings files found.")
                        .foregroundStyle(AppTheme.mutedText)
                }
            } else {
                AppCard(title: "Settings Files") {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(Array(snapshot.settings.enumerated()), id: \.element.path) { index, settings in
                            settingsSection(settings)
                            if index < snapshot.settings.count - 1 {
                                Divider()
                            }
                        }
                    }
                }
            }

            AppCard(title: "Warnings") {
                if snapshot.warnings.isEmpty {
                    Text("No warnings")
                        .foregroundStyle(AppTheme.mutedText)
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        warningSection(title: "Duplicate / Resolution", warnings: snapshot.warnings.filter { $0.message.contains("Duplicate agent") || $0.message.contains("Duplicate prompt template") })
                        warningSection(title: "Malformed Files", warnings: snapshot.warnings.filter { $0.message.contains("Malformed") || $0.message.contains("step block") })
                        warningSection(title: "Prompt Discovery", warnings: snapshot.warnings.filter { $0.message.contains("Prompt path") || $0.message.contains("declares prompt templates") })
                        warningSection(title: "Missing Skills / Env", warnings: snapshot.warnings.filter { $0.message.contains("missing skill") || $0.message.contains("API key") })
                        warningSection(title: "Capability Mismatches", warnings: snapshot.warnings.filter { $0.message.contains("extensions") })
                        warningSection(title: "Chain References", warnings: snapshot.warnings.filter { $0.message.contains("Chain ") && $0.message.contains("missing agent") })
                    }
                }
            }
        }
    }

    private func settingsSection(_ settings: SettingsSummary) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(settings.path)
                .font(.headline)
                .fontWidth(.expanded)
                .textSelection(.enabled)

            AppKeyValueList(rows: [
                ("Disable Builtins", boolLabel(settings.disableBuiltins)),
                ("Override Count", "\(settings.agentOverrides.count)"),
                ("Configured Prompt Paths", "\(settings.prompts.count)")
            ])

            simpleListSection(title: "Packages", items: settings.packages, icon: "shippingbox")
            simpleListSection(title: "Prompt Paths", items: settings.prompts, icon: "text.badge.plus")
            overridesSection(settings.agentOverrides)
        }
    }

    private func simpleListSection(title: String, items: [String], icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .fontWidth(.expanded)
            if items.isEmpty {
                Text("None")
                    .foregroundStyle(AppTheme.mutedText)
            } else {
                ForEach(items, id: \.self) { item in
                    HStack(spacing: 10) {
                        Image(systemName: icon)
                            .foregroundStyle(AppTheme.mutedText)
                        Text(item)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func overridesSection(_ overrides: [BuiltinOverrideRecord]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Builtin Overrides")
                .font(.headline)
                .fontWidth(.expanded)
            if overrides.isEmpty {
                Text("None")
                    .foregroundStyle(AppTheme.mutedText)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(overrides.enumerated()), id: \.element.agentName) { index, override in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(override.agentName)
                                .font(.body.weight(.semibold))
                            Text(prettyJSONObject(override.values))
                                .font(.footnote.monospaced())
                                .foregroundStyle(AppTheme.mutedText)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 8)

                        if index < overrides.count - 1 {
                            Divider()
                        }
                    }
                }
            }
        }
    }
}

@ViewBuilder
private func warningSection(title: String, warnings: [DiagnosticWarning]) -> some View {
    if !warnings.isEmpty {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .fontWidth(.expanded)
            ForEach(warnings) { warning in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(warning.message)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

private func prettyJSONObject(_ object: [String: Any]) -> String {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
          let text = String(data: data, encoding: .utf8) else {
        return object.map { "\($0.key): \(String(describing: $0.value))" }.sorted().joined(separator: "\n")
    }
    return text
}

private func boolLabel(_ value: Bool?) -> String {
    guard let value else { return "—" }
    return value ? "true" : "false"
}

private func resolutionUsageLabel(_ agent: EffectiveAgentRecord) -> String {
    let scope: String
    if let projectRoot = agent.projectRoot,
       (agent.projectCustom != nil || agent.projectOverride != nil) {
        scope = "Project · \(URL(fileURLWithPath: projectRoot).lastPathComponent)"
    } else if agent.globalCustom != nil {
        scope = "Global"
    } else {
        scope = agent.resolutionKind.rawValue
    }
    return "\(scope) · \(agent.resolutionKind.rawValue)"
}

private func copyToPasteboard(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
}

private func openFile(_ path: String) {
    NSWorkspace.shared.open(URL(fileURLWithPath: path))
}

private func revealInFinder(_ path: String) {
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
}

private func projectName(from path: String) -> String? {
    let marker = "/Documents/GitHub/"
    guard let range = path.range(of: marker) else { return nil }
    let remainder = path[range.upperBound...]
    return remainder.split(separator: "/").first.map(String.init)
}

private func skillScopeLabel(_ skill: SkillRecord, selectedProjectRoot: String?) -> String {
    switch skill.source.kind {
    case .project, .legacyProject:
        return "Project"
    case .package:
        return "Package"
    case .library:
        return "Library"
    default:
        return "Global"
    }
}

private func skillProjectLabel(_ skill: SkillRecord, selectedProjectRoot: String?) -> String? {
    switch skill.source.kind {
    case .project, .legacyProject:
        return projectName(from: skill.filePath) ?? selectedProjectRoot.map { URL(fileURLWithPath: $0).lastPathComponent }
    default:
        return nil
    }
}

private func skillPackageLabel(_ skill: SkillRecord) -> String? {
    guard skill.source.kind == .package else { return nil }

    let path = skill.filePath
    if let range = path.range(of: "/node_modules/") {
        let remainder = path[range.upperBound...]
        let components = remainder.split(separator: "/")
        guard let first = components.first else { return nil }
        if first.hasPrefix("@"), components.count > 1 {
            return "\(first)/\(components[1])"
        }
        return String(first)
    }

    return URL(fileURLWithPath: path).deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
}

private func skillLocationLabel(_ skill: SkillRecord, selectedProjectRoot: String?) -> String {
    if let project = skillProjectLabel(skill, selectedProjectRoot: selectedProjectRoot) {
        return project
    }
    if let package = skillPackageLabel(skill) {
        return package
    }
    return "User"
}

private struct EnvEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: EnvEditorDraft
    let onCancel: () -> Void
    let onSave: (EnvEditorDraft) throws -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(draft.originalKey == nil ? "New Environment Key" : "Edit Environment Key")
                .font(.title2.bold())
                .fontWidth(.expanded)

            Form {
                Section("Key") {
                    TextField("Key", text: $draft.key)
                    TextField("Value", text: $draft.value)
                    TextField("Path", text: .constant(draft.path))
                        .disabled(true)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    onCancel()
                    dismiss()
                }
                Button("Save") {
                    do {
                        draft.key = draft.key.trimmingCharacters(in: .whitespacesAndNewlines)
                        try onSave(draft)
                        dismiss()
                    } catch {
                        NSSound.beep()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(draft.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 240)
    }
}

private struct SubagentConfigEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: SubagentConfigDraft
    let onCancel: () -> Void
    let onSave: (SubagentConfigDraft) throws -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Subagents Config")
                .font(.title2.bold())
                .fontWidth(.expanded)

            ScrollView(showsIndicators: false) {
                Form {
                    Section("Runtime Defaults") {
                        Toggle("Async By Default", isOn: optionalBoolBinding(\ .asyncByDefault))
                        Toggle("Force Top-Level Async", isOn: optionalBoolBinding(\ .forceTopLevelAsync))
                        TextField("Default Session Dir", text: optionalStringBinding(\ .defaultSessionDir))
                        Stepper("Max Subagent Depth: \(draft.config.maxSubagentDepth ?? 0)", value: optionalIntBinding(\ .maxSubagentDepth), in: 0...10)
                    }

                    Section("Control Notices") {
                        Toggle("Control Enabled", isOn: optionalControlBoolBinding(\ .enabled))
                        Stepper("Needs Attention After: \(draft.config.control.needsAttentionAfterMs ?? 60000) ms", value: optionalControlIntBinding(\ .needsAttentionAfterMs, defaultValue: 60000), in: 1000...600000, step: 1000)
                        TextField("Notify Channels", text: notifyChannelsBinding)
                    }

                    Section("Parallel Defaults") {
                        Stepper("Max Tasks: \(draft.config.parallel.maxTasks ?? 8)", value: optionalParallelIntBinding(\ .maxTasks, defaultValue: 8), in: 1...32)
                        Stepper("Concurrency: \(draft.config.parallel.concurrency ?? 4)", value: optionalParallelIntBinding(\ .concurrency, defaultValue: 4), in: 1...32)
                    }

                    Section("Intercom Bridge") {
                        TextField("Mode", text: optionalIntercomStringBinding(\ .mode))
                        TextField("Instruction File", text: optionalIntercomStringBinding(\ .instructionFile))
                    }

                    Section("Worktree Hook") {
                        TextField("Setup Hook", text: optionalStringBinding(\ .worktreeSetupHook))
                        Stepper("Hook Timeout: \(draft.config.worktreeSetupHookTimeoutMs ?? 30000) ms", value: optionalIntBinding(\ .worktreeSetupHookTimeoutMs, defaultValue: 30000), in: 1000...300000, step: 1000)
                    }

                    Section("Notes") {
                        Text("Use `always`, `fork-only`, or `off` for intercom bridge mode. Notify channels are comma-separated, for example `event, async, intercom`.")
                            .foregroundStyle(AppTheme.mutedText)
                    }
                }
                .formStyle(.grouped)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    onCancel()
                    dismiss()
                }
                Button("Save") {
                    do {
                        draft.config.control.notifyChannels = draft.config.control.notifyChannels.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                        try onSave(draft)
                        dismiss()
                    } catch {
                        NSSound.beep()
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(minWidth: 720, minHeight: 620)
    }

    private var notifyChannelsBinding: Binding<String> {
        Binding(
            get: { draft.config.control.notifyChannels.joined(separator: ", ") },
            set: { draft.config.control.notifyChannels = $0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
        )
    }

    private func optionalBoolBinding(_ keyPath: WritableKeyPath<SubagentExtensionConfig, Bool?>) -> Binding<Bool> {
        Binding(
            get: { draft.config[keyPath: keyPath] ?? false },
            set: { draft.config[keyPath: keyPath] = $0 }
        )
    }

    private func optionalIntBinding(_ keyPath: WritableKeyPath<SubagentExtensionConfig, Int?>, defaultValue: Int = 0) -> Binding<Int> {
        Binding(
            get: { draft.config[keyPath: keyPath] ?? defaultValue },
            set: { draft.config[keyPath: keyPath] = $0 }
        )
    }

    private func optionalStringBinding(_ keyPath: WritableKeyPath<SubagentExtensionConfig, String?>) -> Binding<String> {
        Binding(
            get: { draft.config[keyPath: keyPath] ?? "" },
            set: { draft.config[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }

    private func optionalControlBoolBinding(_ keyPath: WritableKeyPath<SubagentControlConfig, Bool?>) -> Binding<Bool> {
        Binding(
            get: { draft.config.control[keyPath: keyPath] ?? false },
            set: { draft.config.control[keyPath: keyPath] = $0 }
        )
    }

    private func optionalControlIntBinding(_ keyPath: WritableKeyPath<SubagentControlConfig, Int?>, defaultValue: Int) -> Binding<Int> {
        Binding(
            get: { draft.config.control[keyPath: keyPath] ?? defaultValue },
            set: { draft.config.control[keyPath: keyPath] = $0 }
        )
    }

    private func optionalParallelIntBinding(_ keyPath: WritableKeyPath<SubagentParallelConfig, Int?>, defaultValue: Int) -> Binding<Int> {
        Binding(
            get: { draft.config.parallel[keyPath: keyPath] ?? defaultValue },
            set: { draft.config.parallel[keyPath: keyPath] = $0 }
        )
    }

    private func optionalIntercomStringBinding(_ keyPath: WritableKeyPath<SubagentIntercomBridgeConfig, String?>) -> Binding<String> {
        Binding(
            get: { draft.config.intercomBridge[keyPath: keyPath] ?? "" },
            set: { draft.config.intercomBridge[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }
}

private struct AgentEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: AgentEditorDraft
    let availableTools: [String]
    let availableSkills: [String]
    let availableModels: [AvailableModel]
    let modelsLastUpdatedAt: Date?
    let onCancel: () -> Void
    let onSave: (AgentEditorDraft) throws -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(editorTitle)
                .font(.title2.bold())
                .fontWidth(.expanded)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    Form {
                        if case .custom = draft.target {
                            Section("Identity") {
                                TextField("Name", text: $draft.config.name)
                                TextField("Description", text: $draft.config.description)
                            }
                        } else {
                            Section("Builtin") {
                                TextField("Name", text: .constant(draft.originalName))
                                    .disabled(true)
                                Text("Builtin overrides only patch the supported fields from pi-subagents settings.")
                                    .foregroundStyle(AppTheme.mutedText)
                            }
                        }

                        Section("Behavior") {
                            Text(modelSelectionSummary)
                                .foregroundStyle(AppTheme.mutedText)
                            TextField("Model", text: binding(for: \ .model))
                                .help(Text(verbatim: "Set the primary model used by this subagent. Values come from `pi --list-models`, and the saved frontmatter should usually use `provider/model`."))
                            Menu("Choose Model") {
                                Button("Use Pi Default Model") {
                                    draft.config.model = nil
                                    clampThinkingForSelectedModel()
                                }
                                Divider()
                                modelPickerMenu { model in
                                    draft.config.model = model.identifier
                                    clampThinkingForSelectedModel()
                                }
                            }
                            TextField("Fallback Models", text: arrayBinding(for: \ .fallbackModels))
                                .help("Optional fallback models, saved as a list in frontmatter or override settings.")
                            Menu("Add Fallback Model") {
                                modelPickerMenu { model in
                                    addFallbackModel(model.identifier)
                                }
                            }
                            selectedListView(title: "Selected Fallback Models", values: draft.config.fallbackModels, remove: removeFallbackModel)
                            Picker("Thinking", selection: thinkingSelectionBinding) {
                                ForEach(availableThinkingLevelsForDraft, id: \.self) { level in
                                    Text(level).tag(level)
                                }
                            }
                            .pickerStyle(.menu)
                            .help("Thinking options are derived from Pi’s installed model metadata for the selected model. If no model is selected, Pi’s generic thinking levels are shown.")
                            TextField("Prompt Mode", text: binding(for: \ .systemPromptMode))
                                .help(Text(verbatim: "`replace` makes a focused specialist. `append` keeps more of Pi’s normal behavior and adds your instructions on top."))
                            Toggle("Inherit Project Context", isOn: defaultedOptionalBoolBinding(for: \ .inheritProjectContext) { draft.config.name == "delegate" })
                                .help("When enabled, the child keeps Pi’s project-context prompt section, including instructions loaded from files like AGENTS.md or CLAUDE.md. This is prompt context, not the full parent session history.")
                            Toggle("Inherit Skills", isOn: defaultedOptionalBoolBinding(for: \ .inheritSkills, default: false))
                                .help("When enabled, the child keeps Pi’s discovered skills section in its prompt. Global skills are visible everywhere; project skills are only visible inside their project.")
                            Toggle("Disabled", isOn: optionalBoolBinding(for: \ .disabled))
                                .help("Disabled agents are hidden by discovery logic, matching pi-subagents behavior.")
                        }

                        Section("Tools & Skills") {
                            Text(toolSelectionSummary)
                                .foregroundStyle(AppTheme.mutedText)
                            TextField("Tools", text: toolsBinding())
                            Menu("Add Tool") {
                                ForEach(availableTools, id: \.self) { tool in
                                    Button(tool) { addTool(tool) }
                                }
                            }
                            selectedListView(title: "Selected Tools", values: selectedToolValues, remove: removeTool)

                            TextField("Skills", text: arrayBinding(for: \ .skills))
                            Text(skillSelectionSummary)
                                .foregroundStyle(AppTheme.mutedText)
                            Menu("Add Skill") {
                                ForEach(availableSkills, id: \.self) { skill in
                                    Button(skill) { addSkill(skill) }
                                }
                            }
                            selectedListView(title: "Selected Skills", values: draft.config.skills, remove: removeSkill)
                        }

                        if case .custom = draft.target {
                            Section("Files") {
                                TextField("Extensions", text: listBinding(for: \ .extensions))
                                TextField("Output", text: binding(for: \ .output))
                                TextField("Default Reads", text: listBinding(for: \ .defaultReads))
                                Toggle("Default Progress", isOn: optionalBoolBinding(for: \ .defaultProgress))
                                Toggle("Interactive", isOn: optionalBoolBinding(for: \ .interactive))
                                Stepper("Max Subagent Depth: \(draft.config.maxSubagentDepth ?? 0)", value: intBinding(for: \ .maxSubagentDepth), in: 0...10)
                            }
                        }
                    }
                    .formStyle(.grouped)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Prompt")
                            .font(.headline)
                            .fontWidth(.expanded)
                        Text(promptSectionSummary)
                            .foregroundStyle(AppTheme.mutedText)
                        TextEditor(text: Binding(
                            get: { draft.config.systemPrompt },
                            set: { draft.config.systemPrompt = $0 }
                        ))
                        .frame(minHeight: 320)
                        .font(.system(.body, design: .monospaced))
                        .padding(8)
                        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    onCancel()
                    dismiss()
                }
                Button("Save") {
                    do {
                        try onSave(normalizedDraft())
                        dismiss()
                    } catch {
                        NSSound.beep()
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(minWidth: 720, minHeight: 720)
    }

    private var editorTitle: String {
        switch draft.target {
        case let .builtinOverride(scope):
            return "Edit Builtin Override · \(scope.displayName)"
        case let .custom(scope):
            return draft.sourcePath == nil ? "New Custom Agent · \(scope.displayName)" : "Edit Custom Agent · \(scope.displayName)"
        }
    }

    private var modelSelectionSummary: String {
        let freshness = modelsLastUpdatedAt.map { date in
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            return " Refreshed \(formatter.localizedString(for: date, relativeTo: Date()))."
        } ?? ""
        return "Available models come from `pi --list-models` and are cached in the app on refresh.\(freshness)"
    }

    private var toolSelectionSummary: String {
        switch draft.target {
        case .builtinOverride(scope: .global), .custom(scope: .global):
            return "Global agent: tools are based on the global environment only."
        case .builtinOverride(scope: .project), .custom(scope: .project):
            return "Project agent: tools are based on global + selected project scope."
        }
    }

    private var skillSelectionSummary: String {
        switch draft.target {
        case .builtinOverride(scope: .global), .custom(scope: .global):
            return "Global agent: skills come from the global catalog only."
        case .builtinOverride(scope: .project), .custom(scope: .project):
            return "Project agent: skills come from the global catalog plus project-local skills in the selected project."
        }
    }

    private var promptSectionSummary: String {
        switch draft.target {
        case .builtinOverride:
            return "This prompt is saved as the builtin override’s `systemPrompt` patch in settings, matching pi-subagents builtin override behavior."
        case .custom:
            return "This prompt is saved in the markdown body of the agent file."
        }
    }

    @ViewBuilder
    private func modelPickerMenu(select: @escaping (AvailableModel) -> Void) -> some View {
        ForEach(groupedAvailableModels, id: \.provider) { group in
            Menu(group.provider) {
                ForEach(group.models) { model in
                    Button(modelMenuLabel(for: model)) {
                        select(model)
                    }
                }
            }
        }
    }

    private var groupedAvailableModels: [(provider: String, models: [AvailableModel])] {
        Dictionary(grouping: availableModels, by: \.provider)
            .map { provider, models in
                (
                    provider: provider,
                    models: models.sorted { $0.model.localizedCaseInsensitiveCompare($1.model) == .orderedAscending }
                )
            }
            .sorted { $0.provider.localizedCaseInsensitiveCompare($1.provider) == .orderedAscending }
    }

    private func modelMenuLabel(for model: AvailableModel) -> String {
        let thinking = model.supportsThinking ? "thinking" : "no thinking"
        let images = model.supportsImages ? "images" : "text"
        return "\(model.model) · \(thinking) · \(images) · ctx \(model.contextWindow) · out \(model.maxOutput)"
    }

    private var selectedAvailableModel: AvailableModel? {
        guard let identifier = draft.config.model else { return nil }
        return availableModels.first(where: { $0.identifier == identifier })
    }

    private var availableThinkingLevelsForDraft: [String] {
        if let model = selectedAvailableModel {
            return model.supportedThinkingLevels
        }
        return ["off", "minimal", "low", "medium", "high", "xhigh"]
    }

    private var thinkingSelectionBinding: Binding<String> {
        Binding(
            get: {
                let current = draft.config.thinking ?? "off"
                return availableThinkingLevelsForDraft.contains(current) ? current : (availableThinkingLevelsForDraft.first ?? "off")
            },
            set: { draft.config.thinking = $0 == "off" ? nil : $0 }
        )
    }

    private func normalizedDraft() -> AgentEditorDraft {
        var copy = draft
        copy.config.fallbackModels = normalizedList(copy.config.fallbackModels) ?? []
        copy.config.tools = normalizedList(copy.config.tools)
        copy.config.mcpDirectTools = normalizedList(copy.config.mcpDirectTools)
        copy.config.skills = normalizedList(copy.config.skills) ?? []
        copy.config.extensions = copy.config.extensions == nil ? nil : (normalizedList(copy.config.extensions) ?? [])
        return copy
    }

    @ViewBuilder
    private func selectedListView(title: String, values: [String], remove: @escaping (String) -> Void) -> some View {
        if !values.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 8)], spacing: 8) {
                    ForEach(values, id: \.self) { value in
                        HStack(spacing: 8) {
                            Text(value)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Button {
                                remove(value)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    private var selectedToolValues: [String] {
        (draft.config.tools ?? []) + (draft.config.mcpDirectTools ?? []).map { "mcp:\($0)" }
    }

    private func addTool(_ tool: String) {
        var values = selectedToolValues
        guard !values.contains(tool) else { return }
        values.append(tool)
        applyToolValues(values)
    }

    private func removeTool(_ tool: String) {
        applyToolValues(selectedToolValues.filter { $0 != tool })
    }

    private func applyToolValues(_ values: [String]) {
        var tools: [String] = []
        var mcpTools: [String] = []
        for value in values {
            if value.hasPrefix("mcp:") {
                let name = String(value.dropFirst(4))
                if !name.isEmpty { mcpTools.append(name) }
            } else {
                tools.append(value)
            }
        }
        draft.config.tools = tools.isEmpty ? nil : tools
        draft.config.mcpDirectTools = mcpTools.isEmpty ? nil : mcpTools
    }

    private func clampThinkingForSelectedModel() {
        let available = availableThinkingLevelsForDraft
        let current = draft.config.thinking ?? "off"
        if available.contains(current) { return }
        draft.config.thinking = (available.first ?? "off") == "off" ? nil : (available.first ?? "off")
    }

    private func addFallbackModel(_ model: String) {
        guard !draft.config.fallbackModels.contains(model) else { return }
        draft.config.fallbackModels.append(model)
    }

    private func removeFallbackModel(_ model: String) {
        draft.config.fallbackModels.removeAll { $0 == model }
    }

    private func addSkill(_ skill: String) {
        guard !draft.config.skills.contains(skill) else { return }
        draft.config.skills.append(skill)
    }

    private func removeSkill(_ skill: String) {
        draft.config.skills.removeAll { $0 == skill }
    }

    private func normalizedList(_ value: [String]?) -> [String]? {
        guard let value else { return nil }
        let items = value.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return items.isEmpty ? nil : items
    }

    private func binding(for keyPath: WritableKeyPath<AgentConfig, String?>) -> Binding<String> {
        Binding(
            get: { draft.config[keyPath: keyPath] ?? "" },
            set: { draft.config[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }

    private func binding(for keyPath: WritableKeyPath<AgentConfig, String>) -> Binding<String> {
        Binding(
            get: { draft.config[keyPath: keyPath] },
            set: { draft.config[keyPath: keyPath] = $0 }
        )
    }

    private func binding(for keyPath: WritableKeyPath<AgentConfig, String?>, fallback: String) -> Binding<String> {
        Binding(
            get: { draft.config[keyPath: keyPath] ?? fallback },
            set: { draft.config[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }

    private func listBinding(for keyPath: WritableKeyPath<AgentConfig, [String]?>) -> Binding<String> {
        Binding(
            get: { (draft.config[keyPath: keyPath] ?? []).joined(separator: ", ") },
            set: { input in
                let values = input.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                draft.config[keyPath: keyPath] = values.isEmpty ? nil : values
            }
        )
    }

    private func toolsBinding() -> Binding<String> {
        Binding(
            get: {
                ((draft.config.tools ?? []) + (draft.config.mcpDirectTools ?? []).map { "mcp:\($0)" }).joined(separator: ", ")
            },
            set: { input in
                let items = input.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                var tools: [String] = []
                var mcp: [String] = []
                for item in items {
                    if item.hasPrefix("mcp:") {
                        let name = String(item.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !name.isEmpty { mcp.append(name) }
                    } else {
                        tools.append(item)
                    }
                }
                draft.config.tools = tools.isEmpty ? nil : tools
                draft.config.mcpDirectTools = mcp.isEmpty ? nil : mcp
            }
        )
    }

    private func arrayBinding(for keyPath: WritableKeyPath<AgentConfig, [String]>) -> Binding<String> {
        Binding(
            get: { draft.config[keyPath: keyPath].joined(separator: ", ") },
            set: { input in
                draft.config[keyPath: keyPath] = input.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            }
        )
    }

    private func binding(for keyPath: WritableKeyPath<AgentConfig, String?>, listSeparator: Bool) -> Binding<String> {
        binding(for: keyPath)
    }

    private func binding(for keyPath: WritableKeyPath<AgentConfig, String?>, default defaultValue: String) -> Binding<String> {
        binding(for: keyPath, fallback: defaultValue)
    }

    private func defaultedOptionalBoolBinding(for keyPath: WritableKeyPath<AgentConfig, Bool?>, default defaultValue: Bool) -> Binding<Bool> {
        Binding(
            get: { draft.config[keyPath: keyPath] ?? defaultValue },
            set: { draft.config[keyPath: keyPath] = $0 }
        )
    }

    private func defaultedOptionalBoolBinding(for keyPath: WritableKeyPath<AgentConfig, Bool?>, _ defaultValue: @escaping () -> Bool) -> Binding<Bool> {
        Binding(
            get: { draft.config[keyPath: keyPath] ?? defaultValue() },
            set: { draft.config[keyPath: keyPath] = $0 }
        )
    }

    private func optionalBoolBinding(for keyPath: WritableKeyPath<AgentConfig, Bool?>) -> Binding<Bool> {
        Binding(
            get: { draft.config[keyPath: keyPath] ?? false },
            set: { draft.config[keyPath: keyPath] = $0 }
        )
    }

    private func intBinding(for keyPath: WritableKeyPath<AgentConfig, Int?>) -> Binding<Int> {
        Binding(
            get: { draft.config[keyPath: keyPath] ?? 0 },
            set: { draft.config[keyPath: keyPath] = $0 }
        )
    }
}

private struct ChainEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: ChainEditorDraft
    let onCancel: () -> Void
    let onSave: (ChainEditorDraft) throws -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(draft.originalName == draft.chain.name && FileManager.default.fileExists(atPath: draft.chain.filePath) ? "Edit Chain" : "New Chain")
                .font(.title2.bold())
                .fontWidth(.expanded)

            Form {
                Section("Identity") {
                    TextField("Name", text: $draft.chain.name)
                    TextField("Description", text: $draft.chain.description)
                    TextField("Path", text: .constant(draft.chain.filePath))
                        .disabled(true)
                }

                Section("Steps") {
                    ForEach($draft.chain.steps) { $step in
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Agent", text: $step.agent)
                            Toggle("Disable Output", isOn: $step.outputDisabled)
                            TextField("Output", text: optionalStringBinding($step.output))
                                .disabled(step.outputDisabled)
                            Toggle("Disable Reads", isOn: $step.readsDisabled)
                            TextField("Reads", text: optionalArrayBinding($step.reads))
                                .disabled(step.readsDisabled)
                            TextField("Model", text: optionalStringBinding($step.model))
                            Toggle("Disable Skills", isOn: $step.skillsDisabled)
                            TextField("Skills", text: optionalArrayBinding($step.skills))
                                .disabled(step.skillsDisabled)
                            Toggle("Track Progress", isOn: optionalBoolBinding($step.progress))
                            TextEditor(text: $step.body)
                                .frame(minHeight: 120)
                                .font(.system(.body, design: .monospaced))
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    onCancel()
                    dismiss()
                }
                Button("Save") {
                    do {
                        try onSave(draft)
                        dismiss()
                    } catch {
                        NSSound.beep()
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 720)
    }

    private func optionalStringBinding(_ binding: Binding<String?>) -> Binding<String> {
        Binding(
            get: { binding.wrappedValue ?? "" },
            set: { binding.wrappedValue = $0.isEmpty ? nil : $0 }
        )
    }

    private func optionalArrayBinding(_ binding: Binding<[String]?>) -> Binding<String> {
        Binding(
            get: { (binding.wrappedValue ?? []).joined(separator: ", ") },
            set: {
                let values = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                binding.wrappedValue = values.isEmpty ? nil : values
            }
        )
    }

    private func optionalBoolBinding(_ binding: Binding<Bool?>) -> Binding<Bool> {
        Binding(
            get: { binding.wrappedValue ?? false },
            set: { binding.wrappedValue = $0 }
        )
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}

private extension Array where Element == String {
    var nonEmptyJoined: String {
        isEmpty ? "—" : joined(separator: ", ")
    }
}

#Preview {
    ContentView()
}
