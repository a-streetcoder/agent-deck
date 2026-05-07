import AppKit
import SwiftUI


struct ContentView: View {
    @Environment(\.openSettings) private var openSettings
    @EnvironmentObject private var viewModel: AppViewModel
    @State private var agentDraft: AgentEditorDraft?
    @State private var editingAgent: EffectiveAgentRecord?
    @State private var chainDraft: ChainEditorDraft?
    @State private var envDraft: EnvEditorDraft?
    @State private var projectFilterText = ""
    @State private var debouncedProjectFilterText = ""
    @State private var agentDetailEditCommand = 0
    @State private var agentDetailIsEditing = false
    @State private var isSkillsInfoPresented = false
    @State private var isSkillsRecapPresented = false
    @State private var isSubagentsInfoPresented = false
    @State private var isSubagentsRecapPresented = false
    @State private var showingEnableAllProjectsAlert = false
    @State private var showingDisableAllProjectsAlert = false
    @State private var showingPiAgentDeleteAlert = false
    @State private var isPiAgentTranscriptOptionsPresented = false
    @State private var isPiAgentRepoChangesPresented = false
    @State private var isPiAgentActivityPresented = false
    @State private var navigationColumnVisibility: NavigationSplitViewVisibility = .all
    @State private var piAgentRightPanelCollapsedSidebar = false
    @State private var agentModelQuickEditor: AgentModelQuickEditorContext?
    @State private var isRunChainSheetPresented = false
    @State private var chainRunTask = ""
    @State private var chainRunUsesWorktreeIsolation = false
    @State private var isOnboardingPresented = !UserDefaults.standard.bool(forKey: "piManagerWelcomeTourCompleted.v1")

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

    private var mainContent: some View {
        NavigationSplitView(columnVisibility: $navigationColumnVisibility) {
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
                                SidebarNavigationRow(item: item)
                                .tag(item)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)

                PiAgentSidebarButton(
                    isSelected: viewModel.selectedSidebarItem == .agent,
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
        .focusedSceneValue(\.piManagerCommands, commandContext)
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
            Text("This will enable every project currently in Pi Manager.")
        }
        .alert("Disable all projects?", isPresented: $showingDisableAllProjectsAlert) {
            Button("Disable All", role: .destructive) { viewModel.setAllProjectsEnabled(false) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will disable every project currently in Pi Manager and clear the active project selection.")
        }
        .alert("Delete Pi Agent session?", isPresented: $showingPiAgentDeleteAlert) {
            Button("Delete", role: .destructive) {
                if let session = viewModel.piAgentSessionStore.selectedSession {
                    viewModel.deletePiAgentSession(session.id)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the selected Pi Agent session and its local transcript from Pi Manager.")
        }
        .toolbar {
            ToolbarSpacer(.flexible)

            if viewModel.selectedSidebarItem == .projects {
                ToolbarItemGroup {
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
            }

            if viewModel.selectedSidebarItem == .agents {
                ToolbarItemGroup {
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

                ToolbarItemGroup {
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

                if let agent = viewModel.selectedAgent {
                    ToolbarItemGroup {
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
                }

                ToolbarItemGroup {
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
            }

            if viewModel.selectedSidebarItem == .environment {
                ToolbarItem {
                    Button {
                        envDraft = viewModel.makeNewEnvDraft(scope: viewModel.selectedProjectPath == nil ? .global : .project)
                    } label: {
                        Label("New Key", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .help("Create a new environment key")
                }
            }

            if viewModel.selectedSidebarItem == .chains {
                ToolbarItemGroup {
                    Menu {
                        Button("New Global Chain") {
                            chainDraft = viewModel.makeNewChainDraft(scope: .global)
                        }
                        if viewModel.selectedProjectPath != nil {
                            Button("New Project Chain") {
                                chainDraft = viewModel.makeNewChainDraft(scope: .project)
                            }
                        }
                        if let selectedChain = viewModel.selectedChain {
                            Divider()
                            Button("Duplicate as Global Chain") {
                                chainDraft = viewModel.makeDuplicateChainDraft(from: selectedChain, scope: .global)
                            }
                            if viewModel.selectedProjectPath != nil {
                                Button("Duplicate as Project Chain") {
                                    chainDraft = viewModel.makeDuplicateChainDraft(from: selectedChain, scope: .project)
                                }
                            }
                            Divider()
                            if selectedChain.source.kind != .global {
                                Button("Move to Global Scope") {
                                    do {
                                        try viewModel.convertChain(selectedChain, to: .global)
                                    } catch {
                                        NSSound.beep()
                                    }
                                }
                            }
                            if viewModel.selectedProjectPath != nil, selectedChain.source.kind != .project {
                                Button("Move to Project Scope") {
                                    do {
                                        try viewModel.convertChain(selectedChain, to: .project)
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
                    ToolbarItemGroup {
                        Button {
                            chainRunTask = ""
                            isRunChainSheetPresented = true
                        } label: {
                            Label("Run", systemImage: "play.circle")
                        }
                        .help("Run this chain as a Pi Manager native chain")

                        Button {
                            openChainFile(selectedChain.filePath)
                        } label: {
                            Label("Open", systemImage: "folder")
                        }
                        .help("Open the selected chain file")

                        Button {
                            revealChainInFinder(selectedChain.filePath)
                        } label: {
                            Label("Reveal", systemImage: "arrow.up.forward.app")
                        }
                        .help("Reveal the selected chain file in Finder")

                        Menu {
                            Button("Duplicate as Global Chain") {
                                chainDraft = viewModel.makeDuplicateChainDraft(from: selectedChain, scope: .global)
                            }
                            if viewModel.selectedProjectPath != nil {
                                Button("Duplicate as Project Chain") {
                                    chainDraft = viewModel.makeDuplicateChainDraft(from: selectedChain, scope: .project)
                                }
                            }
                            Divider()
                            if selectedChain.source.kind != .global {
                                Button("Move to Global Scope") {
                                    do {
                                        try viewModel.convertChain(selectedChain, to: .global)
                                    } catch {
                                        NSSound.beep()
                                    }
                                }
                            }
                            if viewModel.selectedProjectPath != nil, selectedChain.source.kind != .project {
                                Button("Move to Project Scope") {
                                    do {
                                        try viewModel.convertChain(selectedChain, to: .project)
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
                            chainDraft = viewModel.makeChainDraft(for: selectedChain)
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .help("Edit selected chain")
                    }
                }

                ToolbarItemGroup {
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

            if viewModel.selectedSidebarItem == .prompts {
                ToolbarItemGroup {
                    Button {
                        do { try viewModel.createLibraryPromptTemplate() }
                        catch { NSSound.beep() }
                    } label: {
                        Label("New", systemImage: "plus")
                    }
                    .help("Create a new library prompt template")

                    if let prompt = viewModel.selectedPromptTemplate {
                        Menu {
                            Button("Open Raw File") { openPromptFile(prompt.filePath) }
                            Button("Reveal in Finder") { revealPromptFile(prompt.filePath) }
                            Button("Copy Invocation") { copyCommandValue(prompt.invocation) }
                            Button("Copy Prompt Path") { copyCommandValue(prompt.filePath) }
                        } label: {
                            Label("More", systemImage: "ellipsis.circle")
                        }
                        .help("More actions for the selected prompt")
                    }
                }
            }

            if viewModel.selectedSidebarItem == .commands {
                ToolbarItemGroup {
                    if let command = viewModel.selectedCommand {
                        Button {
                            copyCommandValue(command.invocation)
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        .help("Copy command invocation")
                    }
                }
            }

            if viewModel.selectedSidebarItem == .skills {
                ToolbarItem {
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

                ToolbarItem {
                    Button {
                        NotificationCenter.default.post(name: .piManagerImportSkillsRequested, object: nil)
                    } label: {
                        Label("Import Skills", systemImage: "plus")
                    }
                    .help("Import skill folders from an external source into the Pi Manager library")
                }

                ToolbarItemGroup {
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
                ToolbarItemGroup {
                    Button(role: .destructive) {
                        showingPiAgentDeleteAlert = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .help("Delete session")
                    .disabled(viewModel.piAgentSessionStore.selectedSession == nil)


                    Button {
                        isPiAgentTranscriptOptionsPresented.toggle()
                    } label: {
                        Label("Transcript Display", systemImage: "eye")
                    }
                    .help("Choose what appears in the agent transcript")
                    .popover(isPresented: $isPiAgentTranscriptOptionsPresented, arrowEdge: .bottom) {
                        PiAgentTranscriptDisplayOptionsPopover(viewModel: viewModel)
                    }

                    Button {
                        isPiAgentActivityPresented.toggle()
                        if isPiAgentActivityPresented { isPiAgentRepoChangesPresented = false }
                    } label: {
                        Label("Activity", systemImage: "sidebar.trailing")
                    }
                    .help("Show Pi Agent activity panel")
                    .disabled(viewModel.piAgentSessionStore.selectedSession == nil)

                    Button {
                        isPiAgentRepoChangesPresented.toggle()
                        if isPiAgentRepoChangesPresented {
                            isPiAgentActivityPresented = false
                            viewModel.prepareRepoChangesForSelectedPiAgentSession()
                        }
                    } label: {
                        Image("github")
                            .resizable()
                            .renderingMode(.template)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 16, height: 16)
                    }
                    .help("Show repo changes panel")
                    .accessibilityLabel("Show repo changes panel")
                    .disabled(viewModel.piAgentSessionStore.selectedSession == nil)

                    PiAgentOpenTerminalToolbarButton(
                        viewModel: viewModel,
                        store: viewModel.piAgentSessionStore
                    )
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
        .sheet(isPresented: $isRunChainSheetPresented) {
            if let chain = viewModel.selectedChain {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Run Native Chain")
                        .font(.title3.bold())
                    Text(chain.name)
                        .font(.headline)
                    TextEditor(text: $chainRunTask)
                        .frame(minHeight: 140)
                        .padding(8)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                    Toggle("Use isolated worktree per step", isOn: $chainRunUsesWorktreeIsolation)
                    HStack {
                        Spacer()
                        Button("Cancel") { isRunChainSheetPresented = false }
                        Button("Run") {
                            viewModel.runNativeChain(chainName: chain.name, task: chainRunTask, useWorktreeIsolation: chainRunUsesWorktreeIsolation)
                            isRunChainSheetPresented = false
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(chainRunTask.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(22)
                .frame(width: 560)
            }
        }
        .sheet(item: $agentModelQuickEditor) { context in
            AgentModelQuickEditorSheet(
                context: context,
                availableModels: viewModel.availableModels,
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
        guard isOnboardingPresented || !UserDefaults.standard.bool(forKey: "piManagerWelcomeTourCompleted.v1") else {
            return
        }
        UserDefaults.standard.set(true, forKey: "piManagerWelcomeTourCompleted.v1")
        isOnboardingPresented = false
    }

    @ViewBuilder
    private var detailSplitView: some View {
        if viewModel.selectedSidebarItem == .agent && isPiAgentActivityPresented {
            HStack(spacing: 0) {
                detailView
                    .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)

                Divider()
                PiAgentActivityPanel(store: viewModel.piAgentSessionStore, isPresented: $isPiAgentActivityPresented)
                    .frame(width: 380)
            }
        } else if viewModel.selectedSidebarItem == .agent && isPiAgentRepoChangesPresented {
            HStack(spacing: 0) {
                detailView
                    .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)

                Divider()
                PiAgentRepoChangesPanel(viewModel: viewModel, isPresented: $isPiAgentRepoChangesPresented)
                    .frame(width: 400)
            }
        } else {
            detailView
                .frame(minWidth: viewModel.selectedSidebarItem == .agent ? 560 : 500, maxWidth: .infinity, maxHeight: .infinity)
        }
    }


    private var commandContext: PiManagerCommandContext {
        let selectedSession = viewModel.piAgentSessionStore.selectedSession
        let selectedSessionID = selectedSession?.id
        let selectedSessionIsRunning = selectedSessionID.map { viewModel.isPiAgentSessionRunning($0) } ?? false
        let commitMessage = viewModel.githubCommitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasGitProject = viewModel.selectedDiscoveredProject?.isGitRepository == true
        let selectedPrompt = viewModel.selectedPromptTemplate
        let selectedCommand = viewModel.selectedCommand
        let selectedAgent = viewModel.selectedAgent
        let selectedAgentPath = selectedAgentFilePath
        let promptsAreVisible = viewModel.selectedSidebarItem == .prompts
        let extensionCommandsAreVisible = viewModel.selectedSidebarItem == .commands

        return PiManagerCommandContext(
            canCreateAgent: true,
            canDeletePiAgentSession: selectedSession != nil,
            canStopPiAgentSession: selectedSessionIsRunning,
            canOpenPiAgentActivity: selectedSession != nil,
            canOpenPiAgentRepoChanges: selectedSession != nil,
            canTogglePiAgentInspector: viewModel.selectedSidebarItem != .agent,
            canOpenPiAgentInTerminal: viewModel.canOpenSelectedPiAgentSessionInTerminal,
            canCommitGitHubChanges: hasGitProject && !commitMessage.isEmpty && !viewModel.githubIsCommitting,
            canPushGitHubBranch: hasGitProject && !viewModel.githubIsPushing,
            canEnableAllProjects: !viewModel.discoveredProjects.isEmpty,
            canDisableAllProjects: !viewModel.discoveredProjects.isEmpty,
            canAddProject: true,
            canImportSkills: true,
            canCreatePrompt: true,
            canCopyPromptInvocation: promptsAreVisible && selectedPrompt != nil,
            canOpenPromptFile: promptsAreVisible && selectedPrompt != nil,
            canRevealPromptFile: promptsAreVisible && selectedPrompt != nil,
            canCopyCommandInvocation: extensionCommandsAreVisible && selectedCommand != nil,
            canOpenSelectedAgentFile: selectedAgentPath != nil,
            canRevealSelectedAgentFile: selectedAgentPath != nil,
            canEditSelectedAgent: selectedAgent != nil,
            canToggleSelectedAgentDisabled: selectedAgent != nil,
            selectedAgentIsDisabled: selectedAgent?.resolved.disabled == true,
            openSettings: {
                openSettings()
            },
            refresh: { viewModel.refreshEverything() },
            createAgent: {
                editingAgent = nil
                agentDraft = viewModel.makeNewAgentDraft(scope: viewModel.selectedProjectPath == nil ? .library : .project)
            },
            deletePiAgentSession: { showingPiAgentDeleteAlert = true },
            stopPiAgentSession: { viewModel.stopSelectedPiAgentSession() },
            showPiAgentActivity: {
                viewModel.openPiAgentScreen()
                isPiAgentActivityPresented.toggle()
                if isPiAgentActivityPresented { isPiAgentRepoChangesPresented = false }
            },
            showPiAgentRepoChanges: {
                viewModel.openPiAgentScreen()
                isPiAgentRepoChangesPresented.toggle()
                if isPiAgentRepoChangesPresented {
                    isPiAgentActivityPresented = false
                    viewModel.prepareRepoChangesForSelectedPiAgentSession()
                }
            },
            togglePiAgentInspector: {
                if viewModel.selectedSidebarItem != .agent {
                    viewModel.isPiAgentInspectorPresented.toggle()
                }
            },
            resumePiAgentInTerminal: { viewModel.openSelectedPiAgentSessionInTerminal() },
            refreshGitHub: { viewModel.refreshEverything() },
            commitGitHubChanges: { viewModel.commitChanges() },
            pushGitHubBranch: { viewModel.pushCurrentBranch() },
            enableAllProjects: { showingEnableAllProjectsAlert = true },
            disableAllProjects: { showingDisableAllProjectsAlert = true },
            addProject: { viewModel.chooseProjectRoot() },
            importSkills: {
                NotificationCenter.default.post(name: .piManagerImportSkillsRequested, object: nil)
            },
            createPrompt: {
                do { try viewModel.createLibraryPromptTemplate() }
                catch { NSSound.beep() }
            },
            copyPromptInvocation: {
                guard let selectedPrompt else { return }
                copyCommandValue(selectedPrompt.invocation)
            },
            openPromptFile: {
                guard let selectedPrompt else { return }
                openPromptFile(selectedPrompt.filePath)
            },
            revealPromptFile: {
                guard let selectedPrompt else { return }
                revealPromptFile(selectedPrompt.filePath)
            },
            copyCommandInvocation: {
                guard let selectedCommand else { return }
                copyCommandValue(selectedCommand.invocation)
            },
            openSelectedAgentFile: { openSelectedAgentFile() },
            revealSelectedAgentFile: { revealSelectedAgentFile() },
            editSelectedAgent: {
                guard selectedAgent != nil else { return }
                agentDetailEditCommand += 1
            },
            toggleSelectedAgentDisabled: {
                setSelectedAgentDisabled(!(selectedAgent?.resolved.disabled == true))
            }
        )
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
                isRecapPresented: $isSubagentsRecapPresented
            )
        case .chains:
            ChainsScreen(
                viewModel: viewModel,
                isRecapPresented: $isSubagentsRecapPresented
            )
        case .skills:
            SkillsScreen(
                viewModel: viewModel,
                isRecapPresented: $isSkillsRecapPresented
            )
        case .prompts:
            PromptsScreen(viewModel: viewModel)
        case .commands:
            ExtensionCommandsScreen(viewModel: viewModel)
        case .github:
            GitHubScreen(viewModel: viewModel)
        case .agent:
            PiAgentScreen(
                viewModel: viewModel,
                store: viewModel.piAgentSessionStore
            )
        case .extensions:
            ExtensionsScreen(viewModel: viewModel)
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
        viewModel.selectedSidebarItem == .agent && (isPiAgentActivityPresented || isPiAgentRepoChangesPresented)
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
        case .extensions:
            return viewModel.selectedExtension?.displayName ?? "Extensions"
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

    private func openChainFile(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private func revealChainInFinder(_ path: String) {
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
