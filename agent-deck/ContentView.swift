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
}

extension View {
    func transcriptEdgeFade(height: CGFloat = 28) -> some View {
        mask {
            VStack(spacing: 0) {
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0), location: 0),
                        .init(color: .black, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: height)
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
}

extension View {
    func toolbarNeutralChrome() -> some View {
        symbolRenderingMode(.monochrome)
            .foregroundStyle(.primary)
            .tint(.primary)
    }

    func toolbarPrimaryActionChrome() -> some View {
        symbolRenderingMode(.monochrome)
            .foregroundStyle(AppTheme.brandAccent)
            .tint(AppTheme.brandAccent)
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
    @State private var isSkillsInfoPresented = false
    @State private var isSubagentsInfoPresented = false
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
    #if DEBUG
    /// Flip to `true` when testing onboarding.
    private static let forceOnboardingOnLaunch = false
    #endif

    @State private var isOnboardingPresented: Bool = {
        #if DEBUG
        if ContentView.forceOnboardingOnLaunch { return true }
        #endif
        return !UserDefaults.standard.bool(forKey: "agentDeckWelcomeTourCompleted.v1")
    }()

    var body: some View {
        mainContent
            .sheet(isPresented: $isOnboardingPresented, onDismiss: completeOnboarding) {
                WelcomeOnboardingSheet(viewModel: viewModel) { target in
                    if let target {
                        viewModel.selectedSidebarItem = target
                    }
                    completeOnboarding()
                }
            }
    }

    private var sidebarWarningSnapshot: [SidebarItem: Bool] {
        guard viewModel.hasCompletedInitialRefresh else { return [:] }
        return [
            .projects: viewModel.shouldWarnProjectSelection,
            .agents: viewModel.hasAgentWarnings,
            .skills: viewModel.hasSkillWarnings,
            .prompts: viewModel.hasPromptWarnings,
            .doctor: viewModel.shouldWarnDoctor
        ]
    }

    @ViewBuilder
    private var mainContent: some View {
        let warnings = sidebarWarningSnapshot
        NavigationSplitView(columnVisibility: $navigationColumnVisibility) {
            VStack(spacing: 0) {
                HStack(alignment: .center, spacing: 12) {
                    ForEach(AppBrand.titleWords, id: \.self) { word in
                        Text(word)
                            .font(AppFonts.kemcoPixelBold(size: 18))
                            .foregroundStyle(.primary)
                    }

                    Text(AppBrand.betaBadgeText)
                        .font(AppFonts.kemcoPixelBold(size: 18))
                        .foregroundStyle(AppTheme.brandAccent.gradient)
                        .accessibilityLabel(AppBrand.betaBadgeText)
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
                                    showsWarning: warnings[item] ?? false
                                )
                                .tag(item)
                                .disabled(item == .instructions && viewModel.selectedProjectPath == nil)
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
                .inspector(isPresented: detailInspectorIsPresented) {
                    detailInspectorContent
                }
        }
        .frame(minWidth: 1180, minHeight: 700)
        .navigationTitle(toolbarTitle)
        .background(AgentDeckCommandsScope(context: commandContext).equatable())
        .onAppear(perform: updateCommandContext)
        // .task(id:) cancels and restarts asynchronously after body settles, so at most
        // one `updateCommandContext()` call lands per render frame.
        .task(id: commandContextUpdateToken) { updateCommandContext() }
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
                ToolbarItem(placement: .primaryAction) {
                    ControlGroup {
                        Button {
                            viewModel.refresh(includeModels: false, scanAllProjects: true)
                        } label: {
                            Label(viewModel.isRefreshingProjects ? "Refreshing" : "Refresh", systemImage: "arrow.clockwise")
                        }
                        .symbolEffect(.rotate.byLayer, isActive: viewModel.isRefreshingProjects)
                        .toolbarNeutralChrome()
                        .help("Refresh project discovery")
                        .disabled(viewModel.isRefreshingProjects)

                        Button {
                            viewModel.chooseProjectRoot()
                        } label: {
                            Label("Add Project", systemImage: "plus")
                        }
                        .toolbarPrimaryActionChrome()
                        .help("Add project manually")
                    }
                }
            }

            if viewModel.selectedSidebarItem == .agents {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        agentModelQuickEditor = currentAgentModelQuickEditorContext
                    } label: {
                        Image(systemName: "cpu")
                    }
                    .toolbarNeutralChrome()
                    .help("Quick edit agent models and thinking")
                    .disabled(currentAgentModelQuickEditorContext.sections.allSatisfy { $0.agents.isEmpty })
                }

                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarItem(placement: .primaryAction) {
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
                    .menuIndicator(.hidden)
                    .toolbarPrimaryActionChrome()
                    .help("Create a library agent, then choose global or project visibility")
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
                        }
                        .toolbarNeutralChrome()
                    }
                }

                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isSubagentsInfoPresented.toggle()
                    } label: {
                        Label("Info", systemImage: "info.circle")
                    }
                    .help("Explain subagent library visibility")
                    .popover(isPresented: $isSubagentsInfoPresented, arrowEdge: .bottom) {
                        SubagentsInfoPopover()
                    }
                    .toolbarNeutralChrome()
                }
            }

            if viewModel.selectedSidebarItem == .environment {
                ToolbarItem(placement: .primaryAction) {
                    ControlGroup {
                        if viewModel.selectedProjectPath == nil {
                            Button {
                                envDraft = viewModel.makeNewEnvDraft(scope: .global)
                            } label: {
                                Label("New Key", systemImage: "plus")
                            }
                            .toolbarPrimaryActionChrome()
                            .help("Create a global environment key")
                        } else {
                            Menu {
                                Button("Project .pi/.env") {
                                    envDraft = viewModel.makeNewEnvDraft(scope: .project)
                                }
                                Button("Global ~/.pi/agent/.env") {
                                    envDraft = viewModel.makeNewEnvDraft(scope: .global)
                                }
                            } label: {
                                Label("New Key", systemImage: "plus")
                            }
                            .menuIndicator(.hidden)
                            .toolbarPrimaryActionChrome()
                            .help("Choose where to store the new environment key")
                        }
                    }
                }
            }

            if viewModel.selectedSidebarItem == .prompts {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        do { try viewModel.createLibraryPromptTemplate() }
                        catch { NSSound.beep() }
                    } label: {
                        Label("New", systemImage: "plus")
                    }
                    .toolbarPrimaryActionChrome()
                    .help("Create a new library prompt template")
                }

                if let prompt = viewModel.selectedPromptTemplate {
                    ToolbarSpacer(.fixed, placement: .primaryAction)
                    ToolbarItem(placement: .primaryAction) {
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
                    Button {
                        isSkillsInfoPresented.toggle()
                    } label: {
                        Label("Info", systemImage: "info.circle")
                    }
                    .help("Explain Pi skill visibility")
                    .popover(isPresented: $isSkillsInfoPresented, arrowEdge: .bottom) {
                        SkillsInfoPopover()
                    }
                    .toolbarNeutralChrome()
                }

                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        NotificationCenter.default.post(name: .agentDeckImportSkillsRequested, object: nil)
                    } label: {
                        Label("Import Skills", systemImage: "plus")
                    }
                    .help("Import skill folders from an external source into the \(AppBrand.displayName) library")
                    .toolbarPrimaryActionChrome()
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

                ToolbarSpacer(.fixed, placement: .primaryAction)

                if viewModel.shouldShowPiAgentGitActions {
                    ToolbarItem(placement: .primaryAction) {
                        ControlGroup {
                            PiAgentGitHubToolbarButton(
                                viewModel: viewModel,
                                isRepoChangesPresented: $isPiAgentRepoChangesPresented
                            )
                            PiAgentCommitToolbarButton(viewModel: viewModel)
                            PiAgentPushToolbarButton(viewModel: viewModel)
                        } label: {
                            Label("Git Actions", systemImage: "checkmark")
                        }
                        .toolbarNeutralChrome()
                    }
                    ToolbarSpacer(.fixed, placement: .primaryAction)
                }

                ToolbarItem(placement: .primaryAction) {
                    ControlGroup {
                        PiAgentOpenTerminalToolbarButton(
                            viewModel: viewModel,
                            store: viewModel.piAgentSessionStore
                        )
                    } label: {
                        Label("Terminal", systemImage: "terminal")
                    }
                    .toolbarNeutralChrome()
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
        #if DEBUG
        if ContentView.forceOnboardingOnLaunch {
            isOnboardingPresented = false
            return
        }
        #endif
        guard isOnboardingPresented || !UserDefaults.standard.bool(forKey: "agentDeckWelcomeTourCompleted.v1") else {
            return
        }
        UserDefaults.standard.set(true, forKey: "agentDeckWelcomeTourCompleted.v1")
        isOnboardingPresented = false
    }

    @ViewBuilder
    private var detailSplitView: some View {
        if toolbarSearchIsVisible {
            detailSplitContent
                .searchable(text: toolbarSearchBinding, placement: .toolbar, prompt: toolbarSearchPrompt)
        } else {
            detailSplitContent
        }
    }

    private var detailSplitContent: some View {
        detailView
            .frame(minWidth: viewModel.selectedSidebarItem == .agent ? 560 : 500, maxWidth: .infinity, maxHeight: .infinity)
    }

    private var detailInspectorIsPresented: Binding<Bool> {
        Binding(
            get: {
                if viewModel.selectedSidebarItem == .agent {
                    return isPiAgentRepoChangesPresented
                }
                return viewModel.isPiAgentInspectorPresented
            },
            set: { isPresented in
                if viewModel.selectedSidebarItem == .agent {
                    isPiAgentRepoChangesPresented = isPresented
                } else {
                    viewModel.isPiAgentInspectorPresented = isPresented
                }
            }
        )
    }

    @ViewBuilder
    private var detailInspectorContent: some View {
        if viewModel.selectedSidebarItem == .agent {
            PiAgentRepoChangesPanel(viewModel: viewModel, isPresented: $isPiAgentRepoChangesPresented)
                .inspectorColumnWidth(min: 360, ideal: 400, max: 560)
        } else {
            PiAgentInspectorPanel(viewModel: viewModel, store: viewModel.piAgentSessionStore)
                .inspectorColumnWidth(min: 300, ideal: 380, max: 560)
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

        // Mutate the existing `@State` context in place — `AgentDeckCommandContext`
        // is `@Observable`, so the menu `Commands` body's `@FocusedValue` reader
        // re-renders via observation when individual properties change. The stable
        // reference is also what lets `AgentDeckCommandsScope` short-circuit re-renders
        // via `Equatable` identity comparison.
        let ctx = commandContext

        ctx.canCreatePiAgentSession = true
        ctx.canCreateAgent = true
        ctx.canDeletePiAgentSession = selectedSession != nil
        ctx.canStopPiAgentSession = selectedSessionIsRunning
        ctx.canOpenPiAgentRepoChanges = selectedSession != nil
        ctx.canTogglePiAgentInspector = viewModel.selectedSidebarItem != .agent
        ctx.canOpenPiAgentInTerminal = viewModel.canOpenSelectedPiAgentSessionInTerminal
        ctx.canCommitGitHubChanges = hasGitProject && !commitMessage.isEmpty && !viewModel.githubIsCommitting
        ctx.canPushGitHubBranch = hasGitProject && !viewModel.githubIsPushing
        ctx.canEnableAllProjects = !viewModel.discoveredProjects.isEmpty
        ctx.canDisableAllProjects = !viewModel.discoveredProjects.isEmpty
        ctx.canAddProject = true
        ctx.canImportSkills = true
        ctx.canCreatePrompt = true
        ctx.canCopyPromptInvocation = promptsAreVisible && selectedPrompt != nil
        ctx.canOpenPromptFile = promptsAreVisible && selectedPrompt != nil
        ctx.canRevealPromptFile = promptsAreVisible && selectedPrompt != nil
        ctx.canOpenSelectedAgentFile = selectedAgentPath != nil
        ctx.canRevealSelectedAgentFile = selectedAgentPath != nil
        ctx.canToggleSelectedAgentDisabled = selectedAgent != nil
        ctx.selectedAgentIsDisabled = selectedAgent?.resolved.disabled == true

        ctx.openSettings = { openSettings() }
        ctx.refresh = { viewModel.refreshEverything() }
        ctx.createPiAgentSession = { viewModel.createPiAgentDraftForSelectedProject() }
        ctx.createAgent = {
            editingAgent = nil
            agentDraft = viewModel.makeNewAgentDraft(scope: viewModel.selectedProjectPath == nil ? .library : .project)
        }
        ctx.deletePiAgentSession = { showingPiAgentDeleteAlert = true }
        ctx.stopPiAgentSession = { viewModel.stopSelectedPiAgentSession() }
        ctx.showPiAgentRepoChanges = {
            viewModel.openPiAgentScreen()
            isPiAgentRepoChangesPresented.toggle()
        }
        ctx.togglePiAgentInspector = {
            if viewModel.selectedSidebarItem != .agent {
                viewModel.isPiAgentInspectorPresented.toggle()
            }
        }
        ctx.resumePiAgentInTerminal = { viewModel.openSelectedPiAgentSessionInTerminal() }
        ctx.refreshGitHub = { viewModel.refreshEverything() }
        ctx.commitGitHubChanges = { viewModel.commitChanges() }
        ctx.pushGitHubBranch = { viewModel.pushCurrentBranch() }
        ctx.enableAllProjects = { showingEnableAllProjectsAlert = true }
        ctx.disableAllProjects = { showingDisableAllProjectsAlert = true }
        ctx.addProject = { viewModel.chooseProjectRoot() }
        ctx.importSkills = {
            NotificationCenter.default.post(name: .agentDeckImportSkillsRequested, object: nil)
        }
        ctx.createPrompt = {
            do { try viewModel.createLibraryPromptTemplate() }
            catch { NSSound.beep() }
        }
        ctx.copyPromptInvocation = {
            guard let selectedPrompt else { return }
            copyCommandValue(selectedPrompt.invocation)
        }
        ctx.openPromptFile = {
            guard let selectedPrompt else { return }
            openPromptFile(selectedPrompt.filePath)
        }
        ctx.revealPromptFile = {
            guard let selectedPrompt else { return }
            revealPromptFile(selectedPrompt.filePath)
        }
        ctx.openSelectedAgentFile = { openSelectedAgentFile() }
        ctx.revealSelectedAgentFile = { revealSelectedAgentFile() }
        ctx.toggleSelectedAgentDisabled = {
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
        let filteredAgents = viewModel.selectedProjectPath == nil ? viewModel.allDisplayAgents : viewModel.filteredAgents

        func sortedUnique(_ agents: [EffectiveAgentRecord]) -> [EffectiveAgentRecord] {
            preferredAgentsByName(agents) { records in records.first }
        }

        func preferredAgentsByName(_ agents: [EffectiveAgentRecord], prefer: ([EffectiveAgentRecord]) -> EffectiveAgentRecord?) -> [EffectiveAgentRecord] {
            Dictionary(grouping: agents, by: { $0.name.lowercased() }).values.compactMap(prefer)
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }

        let builtinCandidates = filteredAgents.filter { agent in
            agent.builtin != nil && agent.globalCustom == nil && agent.projectCustom == nil
        }
        let builtinAgents = sortedUnique(builtinCandidates)

        let editableNonBuiltinAgents = filteredAgents.filter { agent in
            let isPlainBuiltin = agent.builtin != nil && agent.globalCustom == nil && agent.projectCustom == nil
            return !isPlainBuiltin
        }
        if viewModel.selectedProjectPath == nil {
            return [
                AgentModelQuickEditorSection(title: "Custom Agents", agents: sortedUnique(editableNonBuiltinAgents)),
                AgentModelQuickEditorSection(title: "Builtin Agents", agents: builtinAgents)
            ]
        }

        let activeCandidates = editableNonBuiltinAgents.filter { agent in
            agent.resolved.disabled != true
        }
        let inactiveCandidates = editableNonBuiltinAgents.filter { agent in
            agent.resolved.disabled == true
        }
        let activeAgents = sortedUnique(activeCandidates)
        let inactiveAgents = sortedUnique(inactiveCandidates)

        return [
            AgentModelQuickEditorSection(title: "Active Agents", agents: activeAgents),
            AgentModelQuickEditorSection(title: "Inactive Agents", agents: inactiveAgents, isDimmed: true),
            AgentModelQuickEditorSection(title: "Builtin Agents", agents: builtinAgents)
        ]
    }

    @ViewBuilder
    private var detailView: some View {
        switch viewModel.selectedSidebarItem {
        case .projects:
            ProjectsScreen(viewModel: viewModel)
        case .instructions:
            SystemInstructionsScreen(viewModel: viewModel)
        case .memory:
            MemoryScreen(viewModel: viewModel, memoryStore: viewModel.agentMemoryStore)
        case .agents:
            AgentsScreen(
                viewModel: viewModel,
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
                },
                onDeleteKey: { record in
                    do { try viewModel.deleteEnvKey(record) }
                    catch { NSSound.beep() }
                }
            )
        case .doctor:
            DoctorScreen(viewModel: viewModel)
        case .piDocs:
            PiDocsScreen()
        case .credits:
            CreditsScreen()
        case .listShowcase:
            NativeListShowcaseScreen()
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
