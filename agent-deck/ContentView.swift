import AppKit
import SwiftUI


private extension View {
    func sidebarBottomFade(height: CGFloat = 36) -> some View {
        mask {
            VStack(spacing: 0) {
                Rectangle()
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black.opacity(0), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: height)
            }
        }
    }

    func toolbarNeutralChrome() -> some View {
        symbolRenderingMode(.monochrome)
            .foregroundStyle(.primary)
            .tint(.primary)
    }
}

struct ContentView: View {
    @Environment(\.openSettings) private var openSettings
    @EnvironmentObject private var viewModel: AppViewModel
    @State private var agentDraft: AgentEditorDraft?
    @State private var editingAgent: EffectiveAgentRecord?
    @State private var envDraft: EnvEditorDraft?
    @State private var projectFilterText = ""
    @State private var debouncedProjectFilterText = ""
    @State private var agentSearchText = ""
    @State private var skillSearchText = ""
    @State private var promptSearchText = ""
    @State private var piAgentSessionSearchText = ""
    @State private var agentDetailEditCommand = 0
    @State private var agentDetailIsEditing = false
    @State private var isSkillsInfoPresented = false
    @State private var isSubagentsInfoPresented = false
    @State private var isSubagentsRecapPresented = false
    @State private var showingEnableAllProjectsAlert = false
    @State private var showingDisableAllProjectsAlert = false
    @State private var showingPiAgentDeleteAlert = false
    @State private var isPiAgentTranscriptOptionsPresented = false
    @State private var isPiAgentSubagentsPopoverPresented = false
    @State private var isPiAgentRepoChangesPresented = false
    @State private var navigationColumnVisibility: NavigationSplitViewVisibility = .all
    @State private var piAgentRightPanelCollapsedSidebar = false
    @State private var agentModelQuickEditor: AgentModelQuickEditorContext?
    @State private var commandContext = AgentDeckCommandContext()
    @State private var isOnboardingPresented = !UserDefaults.standard.bool(forKey: "agentDeckWelcomeTourCompleted.v1")

    var body: some View {
        mainContent
            .sheet(isPresented: $isOnboardingPresented, onDismiss: completeOnboarding) {
                WelcomeOnboardingSheet(viewModel: viewModel) { openDoctor in
                    if openDoctor {
                        viewModel.selectedSidebarItem = .diagnostics
                    }
                    completeOnboarding()
                }
            }
    }

    private func sidebarWarning(for item: SidebarItem) -> Bool {
        guard viewModel.hasCompletedInitialRefresh else { return false }

        switch item {
        case .projects:
            return viewModel.shouldWarnProjectSelection
        case .agents:
            return viewModel.hasAgentWarnings
        case .skills:
            return viewModel.hasSkillWarnings
        case .prompts:
            return viewModel.hasPromptWarnings
        default:
            return false
        }
    }

    private var mainContent: some View {
        NavigationSplitView(columnVisibility: $navigationColumnVisibility) {
            VStack(spacing: 0) {
                HStack {
//                    Image("agent-deck")
//                        .resizable()
//                    a    .scaledToFit()
//                        .frame(width: 20, height: 20)

                    Text("\(AppBrand.displayName)")
                        .font(AppFonts.kemcoPixelBold(size: 18))
                        .foregroundStyle(.primary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 18)

                List(selection: $viewModel.selectedSidebarItem) {
                    ForEach(SidebarSection.allCases) { section in
                        Section(section.rawValue) {
                            ForEach(section.items) { item in
                                SidebarNavigationRow(
                                    item: item,
                                    showsWarning: sidebarWarning(for: item)
                                )
                                .tag(item)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.hidden)
                .tint(AppTheme.brandAccent)
                .sidebarBottomFade(height: 34)

                PiAgentSidebarButton(
                    isSelected: viewModel.selectedSidebarItem == .agent,
                    runningSessionCount: viewModel.piAgentRunningSessionCount,
                    needsAttentionCount: viewModel.piAgentNeedsAttentionCount,
                    action: { viewModel.openPiAgentScreen() }
                )
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Spacer(minLength: 0)

                SidebarProjectGitHubCard(
                    viewModel: viewModel,
                    projects: filteredProjects,
                    selectedProject: selectedProject,
                    selectedProjectPath: viewModel.selectedProjectPath,
                    filterText: $projectFilterText,
                    isSearchDebouncing: projectFilterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != debouncedProjectFilterText,
                    onSelectProject: { viewModel.setSelectedProject($0?.url) },
                    onChooseProject: { viewModel.chooseProjectRoot() }
                )
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 16)
            }
            .frame(minWidth: 240)
            .background(Color.clear, ignoresSafeAreaEdges: .all)
            .navigationSplitViewColumnWidth(min: 240, ideal: 260, max: 320)
        } detail: {
            detailSplitView
            .inspector(isPresented: Binding(
                get: { viewModel.isPiAgentInspectorPresented && viewModel.selectedSidebarItem != .agent },
                set: { viewModel.isPiAgentInspectorPresented = $0 }
            )) {
                PiAgentInspectorPanel(viewModel: viewModel, store: viewModel.piAgentSessionStore)
                    .inspectorColumnWidth(min: 300, ideal: 380, max: 560)
            }
        }
        .frame(minWidth: 1180, minHeight: 700)
        .navigationTitle(toolbarTitle)
        .focusedSceneValue(\.agentDeckCommands, commandContext)
        .onAppear(perform: updateCommandContext)
        .onChange(of: commandContextUpdateToken) { _, _ in updateCommandContext() }
        .onChange(of: viewModel.selectedSidebarItem) { _, newValue in
            handleSidebarSelectionChange(newValue)
        }
        .onChange(of: isPiAgentRightPanelPresented) { _, isPresented in
            updateSidebarVisibilityForPiAgentRightPanel(isPresented: isPresented)
        }
        .alert("Enable all projects?", isPresented: $showingEnableAllProjectsAlert) {
            Button("Enable All") { viewModel.setAllProjectsEnabled(true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will enable every project currently in \(AppBrand.displayName).")
        }
        .alert("Disable all projects?", isPresented: $showingDisableAllProjectsAlert) {
            Button("Disable All", role: .destructive) { viewModel.setAllProjectsEnabled(false) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will disable every project currently in \(AppBrand.displayName) and clear the active project selection.")
        }
        .alert("Delete Pi Agent session?", isPresented: $showingPiAgentDeleteAlert) {
            Button("Delete", role: .destructive) {
                if let session = viewModel.piAgentSessionStore.selectedSession {
                    viewModel.deletePiAgentSession(session.id)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the selected Pi Agent session and its local transcript from \(AppBrand.displayName).")
        }
        .toolbar {
            if viewModel.selectedSidebarItem == .agent {
                ToolbarItem(placement: .navigation) {
                    Button(role: .destructive) {
                        showingPiAgentDeleteAlert = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .toolbarNeutralChrome()
                    .help("Delete the current Pi Agent session")
                    .disabled(viewModel.piAgentSessionStore.selectedSession == nil)
                }
            }

            if viewModel.selectedSidebarItem == .agents {
                ToolbarItem(placement: .navigation) {
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
                    .toolbarNeutralChrome()
                    .help("Filter agents")
                }
            }

            ToolbarSpacer(.flexible)

            if viewModel.selectedSidebarItem == .projects {
                ToolbarItemGroup {
                    Group {
                        Button("Enable All") {
                            showingEnableAllProjectsAlert = true
                        }
                        .help("Enable all discovered projects")

                        Button("Disable All") {
                            showingDisableAllProjectsAlert = true
                        }
                        .help("Disable all discovered projects")

                        Button {
                            viewModel.chooseProjectRoot()
                        } label: {
                            Image(systemName: "plus")
                        }
                        .help("Add project manually")
                    }
                    .toolbarNeutralChrome()
                }
            }

            if viewModel.selectedSidebarItem == .agents {
                ToolbarItem(placement: .primaryAction) {
                    ControlGroup {
                        Button {
                            agentModelQuickEditor = currentAgentModelQuickEditorContext
                        } label: {
                            Image(systemName: "cpu")
                        }
                        .help("Quick edit agent models and thinking")
                        .disabled(currentAgentModelQuickEditorContext.sections.allSatisfy { $0.agents.isEmpty })

                        Menu {
                            Button("New Library Agent") {
                                editingAgent = nil
                                agentDraft = viewModel.makeNewAgentDraft(scope: .library)
                            }
                            if viewModel.selectedProjectPath != nil {
                                Button("New Project Agent") {
                                    editingAgent = nil
                                    agentDraft = viewModel.makeNewAgentDraft(scope: .project)
                                }
                            }
                        } label: {
                            Label("New", systemImage: "plus")
                        }
                        .help("Create a library agent, then choose global or project visibility")
                    }
                    .toolbarNeutralChrome()
                }

                if let agent = viewModel.selectedAgent {
                    ToolbarSpacer(.fixed, placement: .primaryAction)
                    ToolbarItem(placement: .primaryAction) {
                        ControlGroup {
                            Button {
                                editingAgent = nil
                                agentDraft = viewModel.makeReplacementAgentDraft(from: agent, scope: .global)
                            } label: {
                                Label("Replacement", systemImage: "arrow.triangle.2.circlepath")
                            }
                            .help("Create a global replacement for this builtin agent")
                            .disabled(!(agent.builtin != nil && agent.globalCustom == nil))

                            Button {
                                agentDetailEditCommand += 1
                            } label: {
                                Label(agentDetailIsEditing ? "Done" : "Edit", systemImage: agentDetailIsEditing ? "checkmark" : "pencil")
                            }
                            .help(agentDetailIsEditing ? "Finish editing selected agent" : "Edit selected agent")

                            Menu {
                                Button("Open Raw File") { openSelectedAgentFile() }
                                    .disabled(selectedAgentFilePath == nil)
                                Button("Reveal in Finder") { revealSelectedAgentFile() }
                                    .disabled(selectedAgentFilePath == nil)
                                Divider()
                                if agent.resolved.disabled == true {
                                    Button("Enable Agent") { setSelectedAgentDisabled(false) }
                                } else {
                                    Button("Disable Agent", role: .destructive) { setSelectedAgentDisabled(true) }
                                }
                            } label: {
                                Label("More", systemImage: "ellipsis.circle")
                            }
                            .help("More actions for the selected agent")
                        }
                        .toolbarNeutralChrome()
                    }
                }

                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarItem(placement: .primaryAction) {
                    ControlGroup {
                        Button {
                            isSubagentsRecapPresented.toggle()
                        } label: {
                            Label("Project Recap", systemImage: "sidebar.right")
                        }
                        .help("Show subagents available for the selected project")
                        .disabled(viewModel.selectedProjectPath == nil)

                        Button {
                            isSubagentsInfoPresented.toggle()
                        } label: {
                            Label("Info", systemImage: "info.circle")
                        }
                        .help("Explain subagent library visibility")
                        .popover(isPresented: $isSubagentsInfoPresented, arrowEdge: .bottom) {
                            SubagentsInfoPopover()
                        }
                    }
                    .toolbarNeutralChrome()
                }
            }

            if viewModel.selectedSidebarItem == .environment {
                ToolbarItem {
                    Button {
                        envDraft = viewModel.makeNewEnvDraft(scope: viewModel.selectedProjectPath == nil ? .global : .project)
                    } label: {
                        Label("New Key", systemImage: "plus")
                    }
                    .toolbarNeutralChrome()
                    .help("Create a new environment key")
                }
            }

            if viewModel.selectedSidebarItem == .prompts {
                ToolbarItemGroup {
                    Button {
                        do { try viewModel.createLibraryPromptTemplate() }
                        catch { NSSound.beep() }
                    } label: {
                        Label("New", systemImage: "plus")
                    }
                    .toolbarNeutralChrome()
                    .help("Create a new library prompt template")

                    if let prompt = viewModel.selectedPromptTemplate {
                        Menu {
                            Button("Open Raw File") { openPromptFile(prompt.filePath) }
                            Button("Reveal in Finder") { revealPromptFile(prompt.filePath) }
                            AppCopyTextButton(title: "Copy Invocation", text: prompt.invocation)
                            AppCopyTextButton(title: "Copy Prompt Path", text: prompt.filePath)
                        } label: {
                            Label("More", systemImage: "ellipsis.circle")
                        }
                        .toolbarNeutralChrome()
                        .help("More actions for the selected prompt")
                    }
                }
            }

            if viewModel.selectedSidebarItem == .skills {
                ToolbarItem(placement: .primaryAction) {
                    ControlGroup {
                        Button {
                            isSkillsInfoPresented.toggle()
                        } label: {
                            Label("Info", systemImage: "info.circle")
                        }
                        .help("Explain Pi skill visibility")
                        .popover(isPresented: $isSkillsInfoPresented, arrowEdge: .bottom) {
                            SkillsInfoPopover()
                        }

                    }
                    .toolbarNeutralChrome()
                }

                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarItem(placement: .primaryAction) {
                    ControlGroup {
                        Button {
                            NotificationCenter.default.post(name: .agentDeckImportSkillsRequested, object: nil)
                        } label: {
                            Label("Import Skills", systemImage: "plus")
                        }
                        .help("Import skill folders from an external source into the \(AppBrand.displayName) library")
                    }
                    .toolbarNeutralChrome()
                }
            }

            if viewModel.selectedSidebarItem == .agent {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isPiAgentTranscriptOptionsPresented.toggle()
                    } label: {
                        Label("Transcript Display", systemImage: "eye")
                    }
                    .help("Choose what appears in the agent transcript")
                    .popover(isPresented: $isPiAgentTranscriptOptionsPresented, arrowEdge: .bottom) {
                        PiAgentTranscriptDisplayOptionsPopover(viewModel: viewModel)
                    }
                    .toolbarNeutralChrome()
                }

                if viewModel.shouldShowPiAgentGitActions {
                    ToolbarSpacer(.fixed, placement: .primaryAction)
                    ToolbarItem(placement: .primaryAction) {
                        PiAgentGitActionsToolbarGroup(viewModel: viewModel)
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(.primary)
                        .tint(.primary)
                    }
                    ToolbarSpacer(.fixed, placement: .primaryAction)
                }

                ToolbarItem(placement: .primaryAction) {
                    ControlGroup {
                        PiAgentGitHubToolbarButton(
                            viewModel: viewModel,
                            isRepoChangesPresented: $isPiAgentRepoChangesPresented
                        )

                        PiAgentOpenTerminalToolbarButton(
                            viewModel: viewModel,
                            store: viewModel.piAgentSessionStore
                        )
                    }
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(.primary)
                    .tint(.primary)
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
                availableModels: viewModel.enabledAvailableModels,
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
        .sheet(item: $agentModelQuickEditor) { context in
            AgentModelQuickEditorSheet(
                context: context,
                availableModels: viewModel.enabledAvailableModels,
                modelsLastUpdatedAt: viewModel.modelsLastUpdatedAt,
                makeDraft: { agent in
                    viewModel.makeAgentDraft(for: agent, preferredOverrideScope: context.preferredOverrideScope)
                },
                onSave: { draft, agent in
                    try viewModel.saveAgentDraft(draft, for: agent)
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
    }

    private func completeOnboarding() {
        guard isOnboardingPresented || !UserDefaults.standard.bool(forKey: "agentDeckWelcomeTourCompleted.v1") else {
            return
        }
        UserDefaults.standard.set(true, forKey: "agentDeckWelcomeTourCompleted.v1")
        isOnboardingPresented = false
    }

    @ViewBuilder
    private var detailSplitView: some View {
        if viewModel.selectedSidebarItem == .agent && isPiAgentRepoChangesPresented {
            HStack(spacing: 0) {
                searchableDetailView
                    .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)

                Divider()
                PiAgentRepoChangesPanel(viewModel: viewModel, isPresented: $isPiAgentRepoChangesPresented)
                    .frame(width: 400)
            }
        } else {
            searchableDetailView
                .frame(minWidth: viewModel.selectedSidebarItem == .agent ? 560 : 500, maxWidth: .infinity, maxHeight: .infinity)
        }
    }


    @ViewBuilder
    private var searchableDetailView: some View {
        if toolbarSearchIsVisible {
            detailView.searchable(text: toolbarSearchBinding, placement: .toolbar, prompt: toolbarSearchPrompt)
        } else {
            detailView
        }
    }

    private var toolbarSearchIsVisible: Bool {
        switch viewModel.selectedSidebarItem {
        case .agents, .skills, .prompts, .agent:
            return true
        default:
            return false
        }
    }

    private var toolbarSearchPrompt: String {
        switch viewModel.selectedSidebarItem {
        case .agents: return "Search agents"
        case .skills: return "Search skills"
        case .prompts: return "Search prompts"
        case .agent: return "Search sessions"
        default: return "Search"
        }
    }

    private var toolbarSearchBinding: Binding<String> {
        Binding(
            get: {
                switch viewModel.selectedSidebarItem {
                case .agents: return agentSearchText
                case .skills: return skillSearchText
                case .prompts: return promptSearchText
                case .agent: return piAgentSessionSearchText
                default: return ""
                }
            },
            set: { value in
                switch viewModel.selectedSidebarItem {
                case .agents: agentSearchText = value
                case .skills: skillSearchText = value
                case .prompts: promptSearchText = value
                case .agent: piAgentSessionSearchText = value
                default: break
                }
            }
        )
    }

    private var commandContextUpdateToken: String {
        let selectedSession = viewModel.piAgentSessionStore.selectedSession
        let selectedSessionID = selectedSession?.id
        let selectedSessionIsRunning = selectedSessionID.map { viewModel.isPiAgentSessionRunning($0) } ?? false
        let commitMessage = viewModel.githubCommitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasGitProject = viewModel.selectedDiscoveredProject?.isGitRepository == true
        let selectedPrompt = viewModel.selectedPromptTemplate
        let selectedAgent = viewModel.selectedAgent
        return [
            viewModel.selectedSidebarItem.id,
            selectedSessionID?.uuidString ?? "nil",
            String(selectedSessionIsRunning),
            String(viewModel.canOpenSelectedPiAgentSessionInTerminal),
            commitMessage,
            String(viewModel.githubIsCommitting),
            String(viewModel.githubIsPushing),
            String(hasGitProject),
            String(viewModel.discoveredProjects.count),
            selectedPrompt?.id ?? "nil",
            selectedAgent?.id ?? "nil",
            String(selectedAgent?.resolved.disabled ?? false),
            selectedAgentFilePath ?? "nil"
        ].joined(separator: "|")
    }

    private func updateCommandContext() {
        let selectedSession = viewModel.piAgentSessionStore.selectedSession
        let selectedSessionID = selectedSession?.id
        let selectedSessionIsRunning = selectedSessionID.map { viewModel.isPiAgentSessionRunning($0) } ?? false
        let commitMessage = viewModel.githubCommitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasGitProject = viewModel.selectedDiscoveredProject?.isGitRepository == true
        let selectedPrompt = viewModel.selectedPromptTemplate
        let selectedAgent = viewModel.selectedAgent
        let selectedAgentPath = selectedAgentFilePath
        let promptsAreVisible = viewModel.selectedSidebarItem == .prompts

        commandContext.canCreatePiAgentSession = true
        commandContext.canCreateAgent = true
        commandContext.canDeletePiAgentSession = selectedSession != nil
        commandContext.canStopPiAgentSession = selectedSessionIsRunning
        commandContext.canOpenPiAgentRepoChanges = selectedSession != nil
        commandContext.canTogglePiAgentInspector = viewModel.selectedSidebarItem != .agent
        commandContext.canOpenPiAgentInTerminal = viewModel.canOpenSelectedPiAgentSessionInTerminal
        commandContext.canCommitGitHubChanges = hasGitProject && !commitMessage.isEmpty && !viewModel.githubIsCommitting
        commandContext.canPushGitHubBranch = hasGitProject && !viewModel.githubIsPushing
        commandContext.canEnableAllProjects = !viewModel.discoveredProjects.isEmpty
        commandContext.canDisableAllProjects = !viewModel.discoveredProjects.isEmpty
        commandContext.canAddProject = true
        commandContext.canImportSkills = true
        commandContext.canCreatePrompt = true
        commandContext.canCopyPromptInvocation = promptsAreVisible && selectedPrompt != nil
        commandContext.canOpenPromptFile = promptsAreVisible && selectedPrompt != nil
        commandContext.canRevealPromptFile = promptsAreVisible && selectedPrompt != nil
        commandContext.canOpenSelectedAgentFile = selectedAgentPath != nil
        commandContext.canRevealSelectedAgentFile = selectedAgentPath != nil
        commandContext.canEditSelectedAgent = selectedAgent != nil
        commandContext.canToggleSelectedAgentDisabled = selectedAgent != nil
        commandContext.selectedAgentIsDisabled = selectedAgent?.resolved.disabled == true

        commandContext.openSettings = { openSettings() }
        commandContext.refresh = { viewModel.refreshEverything() }
        commandContext.createPiAgentSession = { viewModel.createPiAgentDraftForSelectedProject() }
        commandContext.createAgent = {
            editingAgent = nil
            agentDraft = viewModel.makeNewAgentDraft(scope: viewModel.selectedProjectPath == nil ? .library : .project)
        }
        commandContext.deletePiAgentSession = { showingPiAgentDeleteAlert = true }
        commandContext.stopPiAgentSession = { viewModel.stopSelectedPiAgentSession() }
        commandContext.showPiAgentRepoChanges = {
            viewModel.openPiAgentScreen()
            isPiAgentRepoChangesPresented.toggle()
            if isPiAgentRepoChangesPresented {
                viewModel.prepareRepoChangesForSelectedPiAgentSession()
            }
        }
        commandContext.togglePiAgentInspector = {
            if viewModel.selectedSidebarItem != .agent {
                viewModel.isPiAgentInspectorPresented.toggle()
            }
        }
        commandContext.resumePiAgentInTerminal = { viewModel.openSelectedPiAgentSessionInTerminal() }
        commandContext.refreshGitHub = { viewModel.refreshEverything() }
        commandContext.commitGitHubChanges = { viewModel.commitChanges() }
        commandContext.pushGitHubBranch = { viewModel.pushCurrentBranch() }
        commandContext.enableAllProjects = { showingEnableAllProjectsAlert = true }
        commandContext.disableAllProjects = { showingDisableAllProjectsAlert = true }
        commandContext.addProject = { viewModel.chooseProjectRoot() }
        commandContext.importSkills = {
            NotificationCenter.default.post(name: .agentDeckImportSkillsRequested, object: nil)
        }
        commandContext.createPrompt = {
            do { try viewModel.createLibraryPromptTemplate() }
            catch { NSSound.beep() }
        }
        commandContext.copyPromptInvocation = {
            guard let selectedPrompt else { return }
            copyCommandValue(selectedPrompt.invocation)
        }
        commandContext.openPromptFile = {
            guard let selectedPrompt else { return }
            openPromptFile(selectedPrompt.filePath)
        }
        commandContext.revealPromptFile = {
            guard let selectedPrompt else { return }
            revealPromptFile(selectedPrompt.filePath)
        }
        commandContext.openSelectedAgentFile = { openSelectedAgentFile() }
        commandContext.revealSelectedAgentFile = { revealSelectedAgentFile() }
        commandContext.editSelectedAgent = {
            guard selectedAgent != nil else { return }
            agentDetailEditCommand += 1
        }
        commandContext.toggleSelectedAgentDisabled = {
            setSelectedAgentDisabled(!(selectedAgent?.resolved.disabled == true))
        }
    }

    private var currentAgentModelQuickEditorContext: AgentModelQuickEditorContext {
        AgentModelQuickEditorContext(
            title: "Agent Models",
            subtitle: viewModel.selectedDiscoveredProject.map { "Quick edits for agents visible in \($0.name)." } ?? "Quick edits for agents visible in the current global view.",
            sections: currentAgentModelQuickEditorSections,
            preferredOverrideScope: viewModel.selectedProjectPath == nil ? .global : .project
        )
    }

    private var currentAgentModelQuickEditorSections: [AgentModelQuickEditorSection] {
        let filteredAgents = viewModel.filteredAgents
        let plainBuiltins = filteredAgents.filter { $0.builtin != nil && $0.globalCustom == nil && $0.projectCustom == nil }
        let libraryBackedActiveAgentNames = Set(viewModel.snapshot.libraryAgents.map(\.name))

        func preferredAgentsByName(_ agents: [EffectiveAgentRecord], prefer: ([EffectiveAgentRecord]) -> EffectiveAgentRecord?) -> [EffectiveAgentRecord] {
            Dictionary(grouping: agents, by: \.name).values.compactMap(prefer)
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }

        let libraryAgents = preferredAgentsByName(
            filteredAgents.filter { $0.resolutionKind == .library || libraryBackedActiveAgentNames.contains($0.name) }
        ) { records in
            records.first { $0.resolutionKind == .library }
            ?? records.first { $0.projectCustom == nil }
            ?? records.first
        }

        if let selectedProject = viewModel.selectedDiscoveredProject {
            let activeCustomAgents = filteredAgents.filter { agent in
                agent.resolutionKind != .library && !(agent.builtin != nil && agent.globalCustom == nil && agent.projectCustom == nil)
            }
            return [
                AgentModelQuickEditorSection(title: "Active in \(selectedProject.name)", agents: activeCustomAgents),
                AgentModelQuickEditorSection(title: "Library Agents", agents: libraryAgents),
                AgentModelQuickEditorSection(title: "Builtin Agents", agents: plainBuiltins)
            ]
        }

        let globalCustomAgents = filteredAgents.filter { $0.globalCustom != nil && $0.globalCustom?.source.kind != .library }
        return [
            AgentModelQuickEditorSection(title: "Global Agents", agents: globalCustomAgents),
            AgentModelQuickEditorSection(title: "Library Agents", agents: libraryAgents),
            AgentModelQuickEditorSection(title: "Builtin Agents", agents: plainBuiltins)
        ]
    }

    @ViewBuilder
    private var detailView: some View {
        switch viewModel.selectedSidebarItem {
        case .projects:
            ProjectsScreen(viewModel: viewModel)
        case .agents:
            AgentsScreen(
                viewModel: viewModel,
                editCommand: agentDetailEditCommand,
                isEditing: $agentDetailIsEditing,
                isRecapPresented: $isSubagentsRecapPresented,
                searchText: $agentSearchText
            )
        case .skills:
            SkillsScreen(
                viewModel: viewModel,
                searchText: $skillSearchText
            )
        case .prompts:
            PromptsScreen(viewModel: viewModel, searchText: $promptSearchText)
        case .agent:
            PiAgentScreen(
                viewModel: viewModel,
                store: viewModel.piAgentSessionStore,
                sessionSearchText: $piAgentSessionSearchText
            )
        case .models:
            ModelsScreen(viewModel: viewModel)
        case .subagents:
            SubagentsScreen(viewModel: viewModel)
        case .environment:
            EnvironmentScreen(
                snapshot: viewModel.snapshot,
                onEditKey: { record in
                    envDraft = viewModel.makeEnvDraft(for: record)
                }
            )
        case .diagnostics:
            DiagnosticsScreen(viewModel: viewModel)
        case .piDocs:
            PiDocsScreen()
        case .credits:
            CreditsScreen()
        }
    }

    private func handleSidebarSelectionChange(_ newValue: SidebarItem) {
        if newValue == .agent {
            viewModel.acknowledgeVisibleSelectedPiAgentSession()
        } else {
            restoreSidebarIfPiAgentRightPanelCollapsedIt()
        }
    }

    private var isPiAgentRightPanelPresented: Bool {
        viewModel.selectedSidebarItem == .agent && isPiAgentRepoChangesPresented
    }

    private func updateSidebarVisibilityForPiAgentRightPanel(isPresented: Bool) {
        if isPresented {
            guard navigationColumnVisibility == .all else { return }
            navigationColumnVisibility = .detailOnly
            piAgentRightPanelCollapsedSidebar = true
        } else {
            restoreSidebarIfPiAgentRightPanelCollapsedIt()
        }
    }

    private func restoreSidebarIfPiAgentRightPanelCollapsedIt() {
        guard piAgentRightPanelCollapsedSidebar else { return }
        navigationColumnVisibility = .all
        piAgentRightPanelCollapsedSidebar = false
    }

    private var toolbarTitle: String {
        switch viewModel.selectedSidebarItem {
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

#Preview {
    ContentView()
}
