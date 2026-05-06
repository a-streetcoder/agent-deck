import AppKit
import SwiftUI

private struct PiAgentOpenTerminalToolbarButton: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var store: PiAgentSessionStore
    @State private var isParallelContinuationWarningPresented = false

    var body: some View {
        Button {
            if selectedSessionIsActive {
                isParallelContinuationWarningPresented = true
            } else {
                viewModel.openSelectedPiAgentSessionInTerminal()
            }
        } label: {
            Label("Resume in Terminal", systemImage: "terminal")
        }
        .help("Opens a terminal continuation from this session file. Terminal messages do not sync back into Pi Manager yet.")
        .disabled(!canOpen)
        .alert("Resume in Terminal?", isPresented: $isParallelContinuationWarningPresented) {
            Button("Resume in Terminal") { viewModel.openSelectedPiAgentSessionInTerminal() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This opens a parallel terminal continuation from the session file. Messages sent in Terminal do not sync back into Pi Manager yet.")
        }
    }

    private var canOpen: Bool {
        guard let session = store.selectedSession else { return false }
        if let sessionFile = session.piSessionFile, FileManager.default.fileExists(atPath: sessionFile) { return true }
        return session.piSessionId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private var selectedSessionIsActive: Bool {
        store.selectedSession?.status.isActive == true
    }
}

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
    @State private var agentModelQuickEditor: AgentModelQuickEditorContext?
    @State private var isOnboardingPresented = !UserDefaults.standard.bool(forKey: "piManagerWelcomeTourCompleted.v1")

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
                                    if item == .github {
                                        Image("github")
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
                                }
                                .fontWidth(.expanded)
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
        .frame(minWidth: 900, minHeight: 600)
        .toolbar(removing: .title)
        .focusedSceneValue(\.piManagerCommands, commandContext)
        .onChange(of: viewModel.selectedSidebarItem) { _, newValue in
            if newValue == .agent {
                viewModel.acknowledgeVisibleSelectedPiAgentSession()
            }
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
            if viewModel.selectedSidebarItem == .projects {
                ToolbarItemGroup(placement: .primaryAction) {
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
                ToolbarItemGroup(placement: .navigation) {
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

                ToolbarItemGroup(placement: .primaryAction) {
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
                    ToolbarSpacer(.fixed, placement: .primaryAction)

                    ToolbarItemGroup(placement: .primaryAction) {
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

                ToolbarSpacer(.fixed, placement: .primaryAction)

                ToolbarItemGroup(placement: .primaryAction) {
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
                ToolbarItem(placement: .confirmationAction) {
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

            if viewModel.selectedSidebarItem == .commandsAndPrompts {
                ToolbarItemGroup(placement: .primaryAction) {
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
                    } else if let command = viewModel.selectedCommand {
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
                }

                ToolbarSpacer(.fixed, placement: .primaryAction)

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        NotificationCenter.default.post(name: .piManagerImportSkillsRequested, object: nil)
                    } label: {
                        Label("Import Skills", systemImage: "plus")
                    }
                    .help("Import skill folders from an external source into the Pi Manager library")
                }

                ToolbarItemGroup(placement: .primaryAction) {
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
                ToolbarItemGroup(placement: .primaryAction) {
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
                    .help("Open Pi Agent activity sidebar")
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
                    .help("Open repo changes sidebar")
                    .accessibilityLabel("Open repo changes")
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
        .sheet(isPresented: $isOnboardingPresented, onDismiss: {
            UserDefaults.standard.set(true, forKey: "piManagerWelcomeTourCompleted.v1")
        }) {
            WelcomeOnboardingSheet(viewModel: viewModel) {
                isOnboardingPresented = false
            }
        }
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
            canCopyPromptInvocation: selectedPrompt != nil,
            canOpenPromptFile: selectedPrompt != nil,
            canRevealPromptFile: selectedPrompt != nil,
            canCopyCommandInvocation: selectedCommand != nil,
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
            SkillsScreen(
                viewModel: viewModel,
                isRecapPresented: $isSkillsRecapPresented
            )
        case .commandsAndPrompts:
            CommandsAndPromptsScreen(viewModel: viewModel)
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
        case .settings:
            SettingsScreen(viewModel: viewModel)
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
            DiagnosticsScreen(snapshot: viewModel.snapshot)
        case .piDocs:
            PiDocsScreen()
        case .credits:
            CreditsScreen()
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

private struct PiAgentTranscriptDisplayOptionsPopover: View {
    @ObservedObject var viewModel: AppViewModel

    private var visibility: PiAgentTranscriptVisibilitySettings {
        viewModel.appSettings.piAgentTranscriptVisibility
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Transcript display", systemImage: "eye")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.mutedText)

            optionRow(
                title: "Thinking",
                subtitle: "Show Pi reasoning blocks",
                systemImage: "brain.head.profile",
                isOn: visibility.showThinking,
                keyPath: \.showThinking
            )
            optionRow(
                title: "Web activity",
                subtitle: "Show searches and fetched/read links",
                systemImage: "globe",
                isOn: visibility.showWebActivity,
                keyPath: \.showWebActivity
            )
            optionRow(
                title: "Tool calls",
                subtitle: "Show non-web tool call summaries",
                systemImage: "wrench.and.screwdriver",
                isOn: visibility.showToolCalls,
                keyPath: \.showToolCalls
            )
            optionRow(
                title: "Errors",
                subtitle: "Show error rows in the transcript",
                systemImage: "exclamationmark.triangle",
                isOn: visibility.showErrors,
                keyPath: \.showErrors
            )
        }
        .padding(12)
        .frame(width: 260)
    }

    private func optionRow(
        title: String,
        subtitle: String,
        systemImage: String,
        isOn: Bool,
        keyPath: WritableKeyPath<PiAgentTranscriptVisibilitySettings, Bool>
    ) -> some View {
        Button {
            viewModel.setPiAgentTranscriptVisibility(keyPath, to: !isOn)
        } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOn ? Color.accentColor : AppTheme.mutedText)
                    .frame(width: 17)
                Image(systemName: systemImage)
                    .foregroundStyle(AppTheme.mutedText)
                    .frame(width: 17)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(AppTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .appContentSurface(cornerRadius: 9, isSelected: isOn)
        }
        .buttonStyle(.plain)
    }
}

private struct PiAgentSidebarButton: View {
    let isSelected: Bool
    let needsAttentionCount: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image("pi")
                    .resizable()
                    .renderingMode(.template)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 18, height: 18)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Pi Agent")
                        .font(.body.weight(.semibold))
                        .fontWidth(.expanded)
                        .foregroundStyle(.primary)
                    Text(isSelected ? "Ready" : "Open")
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedText)
                }

                Spacer(minLength: 8)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .appGlassControl(cornerRadius: 16)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isSelected ? AppTheme.selectionStroke : Color.clear, lineWidth: 1)
            )
            .overlay(alignment: .topTrailing) {
                if needsAttentionCount > 0 {
                    Text(badgeText)
                        .font(.caption2.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, needsAttentionCount > 9 ? 6 : 5)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Capsule(style: .continuous).fill(Color.red))
                        .overlay(Capsule(style: .continuous).stroke(.white.opacity(0.9), lineWidth: 1.5))
                        .offset(x: 6, y: -6)
                        .accessibilityLabel("\(needsAttentionCount) Pi Agent notification\(needsAttentionCount == 1 ? "" : "s")")
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Pi Agent")
        .accessibilityHint(needsAttentionCount > 0 ? "\(needsAttentionCount) session\(needsAttentionCount == 1 ? "" : "s") need review" : "Open Pi Agent sessions")
    }

    private var badgeText: String {
        needsAttentionCount > 99 ? "99+" : "\(needsAttentionCount)"
    }
}

private struct SidebarProjectGitHubCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                        .appGlassControl(cornerRadius: 14)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Choose project")
                .accessibilityHint("Opens the project picker")
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
                            .overlay(Circle().stroke(AppTheme.contentFill, lineWidth: 2))
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
                        .appGlassControl(cornerRadius: 14)
                        .symbolEffect(.rotate.byLayer, isActive: viewModel.githubIsRefreshingEverything)
                }
                .buttonStyle(.plain)
                .help("Refresh GitHub status, project scans, and repo data")
                .accessibilityLabel("Refresh GitHub and projects")
                .disabled(viewModel.githubIsRefreshingEverything)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: isExpanded)
        .appGlassPanel(cornerRadius: 16)
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

private struct ProjectAssignmentToggleRow: View {
    let project: DiscoveredProject
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Toggle("", isOn: $isOn)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .controlSize(.regular)
                .frame(width: 18)

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

            Spacer(minLength: 0)
        }
        .frame(minHeight: 46, alignment: .center)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            isOn.toggle()
        }
    }
}

private struct SearchFieldWithProgress: View {
    let placeholder: String
    @Binding var text: String
    let isLoading: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
            .overlay(alignment: .trailing) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.trailing, 6)
                }
            }
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
            SearchFieldWithProgress(
                placeholder: "Search enabled projects",
                text: $filterText,
                isLoading: isSearchDebouncing
            )

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
                        .fill(isSelected ? Color.accentColor.opacity(0.12) : AppTheme.contentSubtleFill.opacity(0.22))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(isSelected ? Color.accentColor.opacity(0.35) : AppTheme.contentStroke, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)

            if showsFavoriteButton, let onToggleFavorite {
                Button(action: onToggleFavorite) {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .font(.caption)
                        .foregroundStyle(isFavorite ? Color.yellow : AppTheme.mutedText)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(AppTheme.contentSubtleFill.opacity(0.8)))
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
                .fill(AppTheme.contentSubtleFill)
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
            ZStack(alignment: .topTrailing) {
                ProjectIconView(imageURL: imageURL, symbolName: symbolName, size: size)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isHovering ? Color.black.opacity(0.18) : .clear)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(isHovering ? Color.accentColor.opacity(0.9) : AppTheme.contentStroke, lineWidth: isHovering ? 2 : 1)
                    }
                    .overlay {
                        if isHovering {
                            Image(systemName: imageURL == nil ? "photo.badge.plus" : "pencil")
                                .font(.system(size: max(11, size * 0.32), weight: .bold))
                                .foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 1)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }

            }
            .scaleEffect(isHovering ? 1.03 : 1)
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.16), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
        .help(imageURL == nil ? "Set custom icon" : "Change custom icon")
    }
}

struct ProjectIconView: View {
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
                .fill(AppTheme.contentSubtleFill)
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
        AppPage("Projects", subtitle: "Showing projects from \(viewModel.configuredProjectsRootPath)") {
            AppCard(title: "Library") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        SearchFieldWithProgress(
                            placeholder: "Search projects",
                            text: $searchText,
                            isLoading: isSearchDebouncing
                        )

                        Picker("Filter", selection: $filter) {
                            ForEach(Filter.allCases) { option in
                                Text(option.rawValue).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 320)
                    }

                    if viewModel.discoveredProjects.isEmpty {
                        ContentUnavailableView(
                            "No Projects Yet",
                            systemImage: "folder",
                            description: Text("Projects from \(viewModel.configuredProjectsRootPath) will appear here automatically.")
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    } else if visibleProjects.isEmpty {
                        ContentUnavailableView(
                            "No Matching Projects",
                            systemImage: "magnifyingglass",
                            description: Text("Try another search or filter.")
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(visibleProjects) { project in
                                projectRow(project)
                            }
                        }
                    }
                }
            }
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
    private func projectRow(_ project: DiscoveredProject) -> some View {
        let preference = viewModel.projectPreference(for: project.path)
        let isSelected = viewModel.selectedProjectPath == project.path

        HStack(spacing: 10) {
                ProjectIconEditorButton(
                    imageURL: project.iconFileURL,
                    symbolName: project.fallbackSymbolName,
                    size: 28,
                    action: { viewModel.chooseCustomIcon(for: project) }
                )

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(project.repositoryDisplayName)
                            .font(.subheadline.weight(.semibold))
                            .fontWidth(.expanded)
                            .lineLimit(1)

                        if project.isGitHubRepository {
                            Image("github")
                                .resizable()
                                .renderingMode(.template)
                                .foregroundStyle(.secondary)
                                .frame(width: 12, height: 12)
                        }

                        if isSelected {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 8, height: 8)
                                .help("Active project")
                        }
                    }

                    Text(project.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(AppTheme.mutedText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                Toggle("Enabled", isOn: Binding(
                    get: { preference.isEnabled },
                    set: { viewModel.setProjectEnabled($0, for: project) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .help(preference.isEnabled ? "Disable project" : "Enable project")

                Button {
                    viewModel.toggleProjectFavorite(project)
                } label: {
                    Image(systemName: preference.isFavorite ? "star.fill" : "star")
                        .foregroundStyle(preference.isFavorite ? .yellow : AppTheme.mutedText)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help(preference.isFavorite ? "Remove favorite" : "Add favorite")

                Button(role: .destructive) {
                    viewModel.removeProjectFromLibrary(project)
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help("Remove from Pi Manager")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.08) : AppTheme.contentFill)
                    .stroke(isSelected ? Color.accentColor.opacity(0.28) : AppTheme.contentStroke, lineWidth: 1)
            )
            .opacity(preference.isEnabled ? 1 : 0.58)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture {
            guard preference.isEnabled else { return }
            if isSelected {
                viewModel.clearProjectRoot()
            } else {
                viewModel.setSelectedProject(project.url)
            }
        }
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
                    managedAgent: libraryManagedAgentRecord(for: agent, libraryAgents: viewModel.snapshot.libraryAgents),
                    isAgentGlobal: { record in viewModel.agentIsEnabledGlobally(record) },
                    assignedAgentProjects: { record in viewModel.assignedProjects(for: record) },
                    skillVisibilityIssues: { viewModel.explicitSkillVisibilityIssues(for: $0) },
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

private struct AgentWarningPopover: View {
    let agent: EffectiveAgentRecord
    let warnings: [DiagnosticWarning]
    let skillIssues: [AgentSkillVisibilityIssue]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Agent warnings", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)

            if !skillIssues.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Explicit skills not visible in assigned projects")
                        .font(.subheadline.weight(.semibold))
                    Text("The agent stores skill names only. Assign the missing skills to these projects or enable them globally.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(skillIssues) { issue in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(issue.project.name)
                                .font(.caption.weight(.semibold))
                            Text(issue.missingSkills.joined(separator: ", "))
                                .font(.caption.monospaced())
                                .foregroundStyle(.orange)
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            if !warnings.isEmpty {
                if !skillIssues.isEmpty { Divider() }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Other scanner warnings")
                        .font(.subheadline.weight(.semibold))
                    ForEach(warnings) { warning in
                        Text("• \(warning.message)")
                            .font(.caption)
                            .foregroundStyle(AppTheme.mutedText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 360, alignment: .leading)
    }
}

private struct AgentLibraryPane: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var warningPopoverAgentID: String?

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
                        Text("Builtins are bundled with Pi Manager and customized through settings overrides or replacement files.")
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
        let candidates = viewModel.filteredAgents.filter { agent in
            agent.resolutionKind == .library || libraryBackedActiveAgentNames.contains(agent.name)
        }
        return preferredAgentsByName(candidates) { records in
            records.first { $0.resolutionKind == .library }
            ?? records.first { $0.projectCustom == nil }
            ?? records.first
        }
    }

    private func preferredAgentsByName(_ agents: [EffectiveAgentRecord], prefer: ([EffectiveAgentRecord]) -> EffectiveAgentRecord?) -> [EffectiveAgentRecord] {
        Dictionary(grouping: agents, by: \.name).values.compactMap(prefer)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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
        let warnings = viewModel.warnings(for: agent)
        let skillIssues = viewModel.explicitSkillVisibilityIssues(for: agent)
        let hasWarningDetails = !warnings.isEmpty || !skillIssues.isEmpty

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon(for: agent))
                    .foregroundStyle(color(for: agent))
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(agent.name)
                            .font(.headline)
                            .fontWidth(.expanded)
                            .foregroundStyle(.primary)
                            .strikethrough(agent.resolved.disabled == true, color: AppTheme.mutedText)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if hasWarningDetails {
                            Button {
                                warningPopoverAgentID = agent.id
                            } label: {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .imageScale(.small)
                                    .accessibilityLabel("Agent warnings")
                            }
                            .buttonStyle(.plain)
                            .popover(isPresented: Binding(
                                get: { warningPopoverAgentID == agent.id },
                                set: { if !$0 { warningPopoverAgentID = nil } }
                            )) {
                                AgentWarningPopover(agent: agent, warnings: warnings, skillIssues: skillIssues)
                            }
                        }
                    }
                    Text(agent.resolved.description.isEmpty ? "No description" : agent.resolved.description)
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedText)
                        .lineLimit(2)

                    capabilityStrip(for: agent)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(viewModel.selectedAgentID == agent.id ? Color.accentColor.opacity(0.10) : AppTheme.contentSubtleFill)
                .stroke(viewModel.selectedAgentID == agent.id ? Color.accentColor.opacity(0.45) : AppTheme.contentStroke, lineWidth: 1)
        )
        .opacity(agent.resolved.disabled == true ? 0.62 : 1)
        .saturation(agent.resolved.disabled == true ? 0.25 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture {
            viewModel.selectedAgentID = agent.id
        }
    }

    private func capabilityStrip(for agent: EffectiveAgentRecord) -> some View {
        HStack(spacing: 6) {
            if agent.resolutionKind == .globalReplacement || agent.resolutionKind == .projectReplacement {
                capabilityPill("Replacement", symbol: "arrow.triangle.2.circlepath", color: .blue)
            }
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
            if !viewModel.warnings(for: agent).isEmpty || !viewModel.explicitSkillVisibilityIssues(for: agent).isEmpty {
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

private func libraryManagedAgentRecord(for agent: EffectiveAgentRecord, libraryAgents: [AgentRecord]) -> AgentRecord? {
    guard let winningRecord = agent.winningRecord else { return nil }
    guard winningRecord.source.kind != .builtin else { return nil }
    // Same-name custom agents that replace builtins are intentional overrides.
    // Keep them in their chosen scope instead of offering reusable library assignment.
    if agent.builtin != nil && (agent.globalCustom != nil || agent.projectCustom != nil) { return nil }
    return libraryAgents.first { $0.name == agent.name } ?? winningRecord
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
    let skillVisibilityIssues: (EffectiveAgentRecord) -> [AgentSkillVisibilityIssue]
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
                                        .fill(selectedTab == tab ? Color.accentColor : AppTheme.contentSubtleFill)
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

            agentVisibilityManagementCards
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
                                .lineLimit(1)
                                .fontWidth(.condensed)
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
                                        .lineLimit(1)

                                        Text((draft.config.extensions == nil) ? "Inherits Pi’s default extension behavior." : "Using an explicit extension list.")
                                            .font(.caption)
                                            .fontWidth(.condensed)
                                            .lineLimit(1)
                                            .fixedSize(horizontal: true, vertical: false)
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
                                    .lineLimit(1)
                                    .fontWidth(.condensed)
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
                            readOnlyFieldRow("Inherit Skills", value: display(agent.resolved.inheritSkills), isLast: true)
                        }

                        if !skillVisibilityIssues(agent).isEmpty {
                            skillVisibilityWarningBlock(skillVisibilityIssues(agent))
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

    private func skillVisibilityWarningBlock(_ issues: [AgentSkillVisibilityIssue]) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text("Some assigned projects cannot resolve this agent's explicit skills.")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("Agents carry skill names only. Assign the missing skills to these projects or enable them globally.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(issues) { issue in
                    Text("\(issue.project.name): \(issue.missingSkills.joined(separator: ", "))")
                        .font(.caption.monospaced())
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
                        if !skillVisibilityIssues(agent).isEmpty {
                            skillVisibilityWarningBlock(skillVisibilityIssues(agent))
                        }
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(projects) { project in
                                let projectIssue = skillVisibilityIssues(agent).first { $0.project.id == project.id }
                                ProjectAssignmentToggleRow(
                                    project: project,
                                    isOn: Binding(
                                        get: { assignedAgentProjects(managedAgent).contains(where: { $0.id == project.id }) },
                                        set: { enabled in
                                            do { try setAgentForProject(managedAgent, project, enabled) } catch { NSSound.beep() }
                                        }
                                    )
                                )
                                if let projectIssue {
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .foregroundStyle(.orange)
                                        Text("Missing skills here: \(projectIssue.missingSkills.joined(separator: ", "))")
                                            .font(.caption)
                                            .foregroundStyle(AppTheme.mutedText)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .padding(.leading, 60)
                                    .padding(.bottom, 8)
                                }
                                if project.id != projects.last?.id { Divider() }
                            }
                        }
                    }
                }
            }
        }
    }


    private var advancedTab: some View {
        VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
            AppCard(title: "Source Files") {
                AppKeyValueList(rows: [
                    ("Builtin File", agent.builtin?.filePath ?? "—"),
                    ("Global File", agent.globalCustom?.filePath ?? "—"),
                    ("Project File", agent.projectCustom?.filePath ?? "—"),
                    ("Global Override", agent.userOverride?.settingsPath ?? "—"),
                    ("Project Override", agent.projectOverride?.settingsPath ?? "—"),
                    ("Write Target", writeTargetSummary)
                ])
            }

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
            .background(AppTheme.contentSubtleFill.opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
                    .background(AppTheme.contentSubtleFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
            return "Compatibility frontmatter field for interactive behavior. Parsed and preserved."
        case "Max Subagent Depth", "Max Depth":
            return "Limits how many more nested subagent launches this agent can create below itself."
        case "Extensions":
            return "Extension loading mode. Omitted means normal extension loading, empty means none, and explicit values act as an allowlist."
        case "Tool Access":
            return "If tools are omitted, the agent keeps Pi’s normal tool behavior. If tools are explicitly set, they become an allowlist."
        case "Extension Mode":
            return "If extensions are omitted, Pi uses normal extension loading. An explicit list acts as an allowlist. An empty list means no discovered extensions."
        case "Add Tool":
            return "Choose from built-in Pi tools visible in this agent’s scope."
        case "Selected":
            return "Current explicit values for this field. Remove any item with the x button."
        case "Add Extension":
            return "Choose from installed Pi package references already visible to Pi Manager."
        case "Add Skill":
            return "Choose from skills visible in this agent’s current scope."
        case "Skill Catalog":
            return "Only skills discoverable in this scope are offered here."
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
    @State private var isRunChainSheetPresented = false
    @State private var chainRunTask = ""
    @State private var chainRunUsesWorktreeIsolation = false

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
                            chainRunTask = ""
                            isRunChainSheetPresented = true
                        } label: {
                            Label("Run", systemImage: "play.circle")
                        }
                        .help("Run this chain as a Pi Manager native chain")

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
    }

    private func chainProjectAssignmentList(for chain: ChainRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Check each project that should load this chain. Project links are created in PROJECT/.pi/chains.")
                .foregroundStyle(AppTheme.mutedText)
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(viewModel.enabledProjects) { project in
                    ProjectAssignmentToggleRow(
                        project: project,
                        isOn: Binding(
                            get: { viewModel.chain(chain, isEnabledFor: project) },
                            set: { enabled in
                                do { try viewModel.setChain(chain, enabled: enabled, for: project) }
                                catch { NSSound.beep() }
                            }
                        )
                    )
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
                infoRow("Global", "Agent links are created in the standard global agent locations (~/.agents when present, otherwise ~/.pi/agent/agents). Chain links use ~/.pi/agent/chains.")
                infoRow("Project", "Links are created in PROJECT/.pi/agents and PROJECT/.pi/chains.")
                infoRow("Builtins", "Pi Manager bundled builtins stay read-only. Customize them with settings overrides or replacement files.")
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
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close recap")
            }
            .padding(16)
            Divider()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("These are the native agents and chains Pi Manager discovers for this project, after global/project precedence and builtin overrides.")
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
        .background(AppTheme.contentSubtleFill)
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
            HStack { Text(title).font(.headline).fontWidth(.expanded); Spacer() }
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
        .background(AppTheme.contentFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                .accessibilityLabel("Close recap")
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
        .background(AppTheme.contentSubtleFill)
    }

    private func recapSection(_ title: String, skills: [SkillRecord], color: Color, emptyText: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.headline)
                    .fontWidth(.expanded)
                Spacer()
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
                        .background(AppTheme.contentFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
    @State private var isImportSheetPresented = false
    @State private var shouldPromptForImportSource = false
    @State private var importSourceURL: URL?
    @State private var importCandidates: [ExternalSkillCandidate] = []
    @State private var selectedImportCandidateIDs: Set<String> = []
    @State private var importMode: SkillLibraryImportMode = .symlink
    @State private var replaceExistingImports = false
    @State private var importErrorMessage: String?
    @State private var importSummaryMessage: String?

    var body: some View {
        HStack(spacing: 0) {
            HSplitView {
                AppPage("Skills", subtitle: pageSubtitle) {
                    skillLibraryContent
                }
                .frame(minWidth: 430, idealWidth: 520, maxWidth: 640)

                AppPage(selectedSkill?.name ?? "Skill Details", subtitle: selectedSkill.map { skillLocationLabel($0, selectedProjectRoot: viewModel.snapshot.projectRoot) }) {
                    skillDetailContent
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
        .onReceive(NotificationCenter.default.publisher(for: .piManagerImportSkillsRequested)) { _ in
            beginSkillImport()
        }
        .sheet(isPresented: $isImportSheetPresented) {
            importSkillsSheet
        }
        .alert("Skill Import", isPresented: Binding(
            get: { importErrorMessage != nil || importSummaryMessage != nil },
            set: { if !$0 { importErrorMessage = nil; importSummaryMessage = nil } }
        )) {
            Button("OK") {
                importErrorMessage = nil
                importSummaryMessage = nil
            }
        } message: {
            Text(importErrorMessage ?? importSummaryMessage ?? "")
        }
    }

    @ViewBuilder
    private var skillLibraryContent: some View {
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
    }

    @ViewBuilder
    private var skillDetailContent: some View {
        if let skill = selectedSkill {
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

            AppCard(title: "Manage \(skill.name)") {
                AppKeyValueList(rows: [
                    ("Source", skillScopeLabel(skill, selectedProjectRoot: viewModel.snapshot.projectRoot)),
                    ("Active Globally", viewModel.skillIsEnabledGlobally(skill) ? "Yes" : "No"),
                    ("Assigned Projects", assignedProjectSummary(skill)),
                    ("Path", skill.filePath)
                ])
            }
        } else {
            AppCard {
                ContentUnavailableView("No Skill Selected", systemImage: "wand.and.stars")
                    .frame(maxWidth: .infinity, minHeight: 240)
            }
        }
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
        managedSkills.filter {
            $0.source.kind == .library &&
            !viewModel.skillIsEnabledGlobally($0)
        }
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
                    Image(systemName: skillIcon(skill))
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
                    Spacer(minLength: 8)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(selectedSkillName == skill.name ? Color.accentColor.opacity(0.10) : AppTheme.contentSubtleFill)
                    .stroke(selectedSkillName == skill.name ? Color.accentColor.opacity(0.45) : AppTheme.contentStroke, lineWidth: 1)
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
                    ProjectAssignmentToggleRow(
                        project: project,
                        isOn: Binding(
                            get: { viewModel.skill(skill, isEnabledFor: project) },
                            set: { enabled in
                                do { try viewModel.setSkill(skill, enabled: enabled, for: project) }
                                catch { NSSound.beep() }
                            }
                        )
                    )

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
        if skill.source.kind == .library && !viewModel.assignedProjects(for: skill).isEmpty { return "Assigned" }
        if skill.source.kind == .library { return "Library" }
        return skillScopeLabel(skill, selectedProjectRoot: viewModel.snapshot.projectRoot)
    }

    private func skillIcon(_ skill: SkillRecord) -> String {
        if skill.source.kind == .package { return "shippingbox" }
        if viewModel.skillIsEnabledGlobally(skill) { return "globe" }
        if skill.source.kind == .library { return "building.columns" }
        if selectedProject != nil, skillIsActiveForCurrentProject(skill) { return "checkmark.circle" }
        return "wand.and.stars"
    }

    private func skillColor(_ skill: SkillRecord) -> Color {
        if skill.source.kind == .package { return .orange }
        if viewModel.skillIsEnabledGlobally(skill) { return .blue }
        if skill.source.kind == .library { return .purple }
        if selectedProject != nil, skillIsActiveForCurrentProject(skill) { return .green }
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

    private var existingLibrarySkillNames: Set<String> {
        Set(viewModel.snapshot.librarySkills.map(\.name))
    }

    private func candidateAlreadyImported(_ candidate: ExternalSkillCandidate) -> Bool {
        existingLibrarySkillNames.contains(candidate.name)
    }

    private var importableCandidateIDs: Set<String> {
        Set(importCandidates.filter { !candidateAlreadyImported($0) || replaceExistingImports }.map(\.id))
    }

    private var allImportableCandidatesSelected: Bool {
        !importableCandidateIDs.isEmpty && importableCandidateIDs.isSubset(of: selectedImportCandidateIDs)
    }

    @ViewBuilder
    private var importSkillsSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                AppCard(title: "Source") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(importSourceURL?.path ?? "No source selected")
                            .textSelection(.enabled)
                            .font(.caption.monospaced())
                            .foregroundStyle(AppTheme.mutedText)
                        Button("Choose Different Folder") {
                            DispatchQueue.main.async {
                                chooseDifferentImportFolder()
                            }
                        }
                    }
                }

                AppCard(title: "Import Mode") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Import Mode", selection: $importMode) {
                            ForEach(SkillLibraryImportMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)

                        Text(importMode.description)
                            .font(.caption)
                            .foregroundStyle(AppTheme.mutedText)
                            .fixedSize(horizontal: false, vertical: true)

                        Toggle("Replace existing library skills with the same name", isOn: $replaceExistingImports)
                    }
                }

                AppCard(title: "Skills") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .center, spacing: 12) {
                            Text("Select one or more skill roots to import into the Pi Manager library.")
                                .font(.caption)
                                .foregroundStyle(AppTheme.mutedText)
                            Spacer()
                            Button(allImportableCandidatesSelected ? "Deselect All" : "Select All") {
                                if allImportableCandidatesSelected {
                                    selectedImportCandidateIDs.removeAll()
                                } else {
                                    selectedImportCandidateIDs = importableCandidateIDs
                                }
                            }
                            .buttonStyle(.bordered)

                            Button("Clear") {
                                selectedImportCandidateIDs.removeAll()
                            }
                            .buttonStyle(.bordered)
                            .disabled(selectedImportCandidateIDs.isEmpty)
                        }

                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(importCandidates) { candidate in
                                    let alreadyImported = candidateAlreadyImported(candidate)
                                    Toggle(isOn: Binding(
                                        get: { selectedImportCandidateIDs.contains(candidate.id) },
                                        set: { isSelected in
                                            guard !alreadyImported || replaceExistingImports else { return }
                                            if isSelected { selectedImportCandidateIDs.insert(candidate.id) }
                                            else { selectedImportCandidateIDs.remove(candidate.id) }
                                        }
                                    )) {
                                        VStack(alignment: .leading, spacing: 8) {
                                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                                Text(candidate.name)
                                                    .font(.body.weight(.semibold))
                                                if alreadyImported {
                                                    AppLabelTag(text: replaceExistingImports ? "Will Replace" : "Already Imported", color: .gray)
                                                }
                                            }

                                            if let description = candidate.description {
                                                VStack(alignment: .leading, spacing: 2) {
                                                    Text("Description")
                                                        .font(.caption2.weight(.semibold))
                                                        .foregroundStyle(AppTheme.mutedText)
                                                    Text(description)
                                                        .font(.caption)
                                                        .foregroundStyle(.primary)
                                                        .lineLimit(2)
                                                }
                                            }

                                            VStack(alignment: .leading, spacing: 2) {
                                                Text("Path")
                                                    .font(.caption2.weight(.semibold))
                                                    .foregroundStyle(AppTheme.mutedText)
                                                Text(candidate.sourceRootPath)
                                                    .font(.caption.monospaced())
                                                    .foregroundStyle(AppTheme.mutedText)
                                                    .lineLimit(1)
                                                    .truncationMode(.middle)
                                            }
                                        }
                                        .padding(.vertical, 10)
                                    }
                                    .toggleStyle(.checkbox)
                                    .disabled(alreadyImported && !replaceExistingImports)
                                    if candidate.id != importCandidates.last?.id {
                                        Divider()
                                    }
                                }
                            }
                        }
                        .frame(minHeight: 280)
                    }
                }

                Spacer()
            }
            .padding(AppTheme.pagePadding)
            .frame(minWidth: 760, minHeight: 680, alignment: .topLeading)
            .navigationTitle("Import External Skills")
            .task(id: shouldPromptForImportSource) {
                guard shouldPromptForImportSource else { return }
                shouldPromptForImportSource = false
                DispatchQueue.main.async {
                    chooseDifferentImportFolder()
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isImportSheetPresented = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        importSelectedSkills()
                    }
                    .disabled(selectedImportCandidateIDs.isEmpty)
                }
            }
        }
    }

    private func beginSkillImport() {
        importErrorMessage = nil
        importSummaryMessage = nil
        importCandidates = []
        selectedImportCandidateIDs.removeAll()
        importSourceURL = nil
        shouldPromptForImportSource = true
        isImportSheetPresented = true
    }

    private func chooseDifferentImportFolder() {
        print("[SkillImport] chooseDifferentImportFolder currentSource=\(importSourceURL?.path ?? "nil")")
        viewModel.chooseExternalSkillsDirectory(startingAt: importSourceURL) { url in
            guard let url else { return }
            DispatchQueue.main.async {
                loadImportCandidates(from: url)
            }
        }
    }

    private func loadImportCandidates(from url: URL) {
        importErrorMessage = nil
        importSummaryMessage = nil
        importSourceURL = url

        var candidates = viewModel.discoverImportableSkills(in: url)
        if candidates.isEmpty, let directCandidate = viewModel.externalSkillCandidate(at: url) {
            candidates = [directCandidate]
        }

        guard !candidates.isEmpty else {
            importCandidates = []
            selectedImportCandidateIDs.removeAll()
            importErrorMessage = "No importable skill folders were found. Choose either a skill root containing SKILL.md or a folder whose direct child folders contain SKILL.md files."
            return
        }

        importCandidates = candidates
        selectedImportCandidateIDs = Set(candidates.filter { !existingLibrarySkillNames.contains($0.name) }.map(\.id))
        importMode = .symlink
        replaceExistingImports = false

        if !isImportSheetPresented {
            DispatchQueue.main.async {
                isImportSheetPresented = true
            }
        }
    }

    private func importSelectedSkills() {
        let selectedCandidates = importCandidates.filter { selectedImportCandidateIDs.contains($0.id) }
        guard !selectedCandidates.isEmpty else { return }
        do {
            let result = try viewModel.importExternalSkills(selectedCandidates, mode: importMode, replaceExisting: replaceExistingImports)
            isImportSheetPresented = false
            var summaryParts: [String] = []
            if !result.importedNames.isEmpty {
                summaryParts.append("Imported \(result.importedNames.count) skill\(result.importedNames.count == 1 ? "" : "s"): \(result.importedNames.joined(separator: ", ")).")
            }
            if !result.skippedNames.isEmpty {
                summaryParts.append("Skipped \(result.skippedNames.count) existing skill\(result.skippedNames.count == 1 ? "" : "s"): \(result.skippedNames.joined(separator: ", ")).")
            }
            importSummaryMessage = summaryParts.joined(separator: "\n\n")
        } catch {
            importErrorMessage = error.localizedDescription
        }
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

private struct PiDocsScreen: View {
    enum DocsTab: String, CaseIterable, Identifiable {
        case core = "Core System"
        case skills = "Skills"
        case prompts = "Prompts & Commands"
        case agents = "Agents & Chains"
        case architecture = "Architecture"

        var id: String { rawValue }
    }

    @State private var selectedTab: DocsTab = .core

    var body: some View {
        AppPage("Docs", subtitle: "Concise reference from pi-documentation/") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(DocsTab.allCases) { tab in
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
                                        .fill(selectedTab == tab ? Color.accentColor : AppTheme.contentSubtleFill)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }

            switch selectedTab {
            case .core: coreTab
            case .skills: skillsTab
            case .prompts: promptsTab
            case .agents: agentsTab
            case .architecture: architectureTab
            }
        }
    }

    // MARK: - Core System

    private var coreTab: some View {
        VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
            AppCard(title: "How Pi Works") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Pi is the parent session. A subagent is a child Pi process with a narrower job. Children inherit tools, skills, and extensions from the parent unless explicitly restricted.")
                    Text("Settings are layered: project `.pi/settings.json` overrides user `~/.pi/agent/settings.json`. Agent files follow the same precedence: project `.pi/agents/` > global `~/.pi/agent/agents/` > builtins.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            AppCard(title: "Key File Locations") {
                VStack(alignment: .leading, spacing: 12) {
                    docKeyValueRows([
                        ("User settings", "~/.pi/agent/settings.json"),
                        ("Project settings", ".pi/settings.json"),
                        ("User agents", "~/.pi/agent/agents/*.md"),
                        ("Project agents", ".pi/agents/*.md"),
                        ("Bundled agents", "App bundle bundled-agents/*.md"),
                        ("User skills", "~/.pi/agent/skills/"),
                        ("Project skills", ".pi/skills/"),
                        ("User prompts", "~/.pi/agent/prompts/*.md"),
                        ("Project prompts", ".pi/prompts/*.md"),
                        ("User env", "~/.pi/agent/.env"),
                        ("Project env", ".pi/.env")
                    ])
                }
            }

            AppCard(title: "Agent Resolution") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("1. Bundled agents are discovered from Pi Manager's app resources.")
                    Text("2. Global custom agents in `~/.pi/agent/agents/` or `~/.agents/` override builtins by name.")
                    Text("3. Project agents in `.pi/agents/` override both global and builtin.")
                    Text("4. Settings overrides (`subagents.agentOverrides`) patch any agent's fields without creating a file.")
                    Text("5. `disableBuiltins: true` removes all builtins; individual agents can be disabled via overrides.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            AppCard(title: "Context Modes") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("• **Fresh** (default): child starts blank, gets only its own system prompt, skills, and task.")
                    Text("• **Fork**: child inherits the full parent conversation as read-only reference. Used for oracle, worker, planner.")
                    Text("• Auto-detection: if any requested agent has `defaultContext: fork`, the entire invocation upgrades to fork mode.")
                    Text("• Recursion guard: max nesting depth (default 2) enforced via `PI_SUBAGENT_DEPTH` environment variable.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Skills

    private var skillsTab: some View {
        VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
            AppCard(title: "Skill Discovery") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Pi loads skills from five source categories: global locations, project locations, installed packages, settings-defined paths, and CLI-provided paths.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            AppCard(title: "Discovery Locations") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Global").font(.headline).fontWidth(.expanded)
                    docKeyValueRows([
                        ("Primary", "~/.pi/agent/skills/ — root *.md or */SKILL.md"),
                        ("Legacy", "~/.agents/skills/ — recursive */SKILL.md only")
                    ])
                    Text("Project").font(.headline).fontWidth(.expanded).padding(.top, 6)
                    docKeyValueRows([
                        ("Primary", ".pi/skills/ — root *.md or */SKILL.md"),
                        ("Legacy", ".agents/skills/ — recursive, walks up to git root")
                    ])
                    Text("Package").font(.headline).fontWidth(.expanded).padding(.top, 6)
                    docKeyValueRows([
                        ("Conventional", "<package>/skills/*/SKILL.md"),
                        ("Manifest", "package.json → pi.skills")
                    ])
                }
            }

            AppCard(title: "Rules") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("• Skills are identified by directory name (the `name` frontmatter field, or directory name if omitted).")
                    Text("• Same-name skills at higher precedence replace lower: project > global > package.")
                    Text("• `~/.pi/agent/skills/` supports root `*.md` files as individual skills; `~/.agents/skills/` does not.")
                    Text("• Package skills are active by default when the package is discovered and are read-only.")
                    Text("• Skills are non-recursive within their directory (only direct children, not nested subdirs).")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Prompts & Commands

    private var promptsTab: some View {
        VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
            AppCard(title: "Slash Entries") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("In Pi, many things start with `/` but they are not all the same:")
                    Text("• **Built-in commands** — app actions like `/settings`, `/model`, `/reload`, `/quit`")
                    Text("• **Extension commands** — registered by packages, e.g. `/agents`, `/subagents-status`")
                    Text("• **Prompt templates** — file-backed `.md` templates that expand into the composer")
                    Text("• **Skill commands** — invoke a skill by name")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            AppCard(title: "Prompt Template Locations") {
                VStack(alignment: .leading, spacing: 12) {
                    docKeyValueRows([
                        ("Global", "~/.pi/agent/prompts/*.md"),
                        ("Project", ".pi/prompts/*.md"),
                        ("Settings", "settings.json → prompts array (files/dirs)"),
                        ("Package", "package.json → pi.prompts or conventional prompts/ dir"),
                        ("CLI", "--prompt-template <path>")
                    ])
                }
            }

            AppCard(title: "Template Frontmatter") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Prompt templates are `.md` files with optional YAML frontmatter:")
                    Text("• `name` — display name (defaults to filename)")
                    Text("• `description` — shown in the slash menu")
                    Text("• `argument-hint` — placeholder text for the argument input")
                    Text("• Body content is injected into the composer when invoked.")
                    Text("• Discovery is non-recursive within each directory.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            AppCard(title: "Legacy Commands") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Pi migrates deprecated `commands/` directories to `prompts/` automatically. If you have a `commands/` directory, Pi will read it but you should rename it to `prompts/`.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Agents & Chains

    private var agentsTab: some View {
        VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
            AppCard(title: "Custom Agents") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Custom agents are `.md` files with YAML frontmatter. They live in global or project discovery paths and override builtins by name.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            AppCard(title: "Agent Frontmatter Fields") {
                VStack(alignment: .leading, spacing: 12) {
                    docKeyValueRows([
                        ("name", "Agent name (defaults to filename without extension)"),
                        ("description", "Short description"),
                        ("model", "Model identifier, e.g. anthropic/claude-sonnet-4"),
                        ("fallbackModels", "Ordered backup models"),
                        ("thinking", "Thinking level: off, low, medium, high"),
                        ("systemPromptMode", "replace (default) or append"),
                        ("systemPrompt", "Main instruction body (below frontmatter)"),
                        ("defaultContext", "fresh or fork — default context mode"),
                        ("inheritProjectContext", "Whether child reads project context files"),
                        ("inheritSkills", "Whether child keeps Pi's discovered skills catalog"),
                        ("tools", "Builtin tool allowlist; mcp: entries for direct MCP tools"),
                        ("extensions", "Extension loading mode: omitted, empty, or allowlist"),
                        ("skills", "Explicit skills to attach"),
                        ("disabled", "Disable this agent"),
                        ("output", "File path for chain step output"),
                        ("defaultReads", "Files Pi should read before execution"),
                        ("defaultProgress", "Enable progress.md tracking"),
                        ("maxSubagentDepth", "Max nested subagent launches (0-10)")
                    ])
                }
            }

            AppCard(title: "Chains") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Chains are `.chain.md` files defining sequential pipelines where each step's output becomes `{previous}` for the next.")
                    Text("Locations: `~/.pi/agent/agents/*.chain.md` (user) or `.pi/agents/*.chain.md` (project).")
                    Text("Steps are defined with `## agent-name` headers. Each step supports: `output`, `reads`, `model`, `skill`/`skills`, `progress`.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            AppCard(title: "Settings Overrides") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("You can patch any agent's fields without creating a file, using `settings.json`:")
                    Text("```json\n{ \"subagents\": { \"agentOverrides\": { \"worker\": { \"model\": \"anthropic/claude-sonnet-4\", \"thinking\": \"high\" } } } }\n```"   )
                    Text("Project settings beat user settings. `disableBuiltins: true` removes all builtins.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Architecture

    private var architectureTab: some View {
        VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
            AppCard(title: "Entry Points") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Four entry points can trigger a subagent:")
                    Text("• **Managed tools** — parent sessions call Pi Manager bridge tools for single, chain, and parallel delegation")
                    Text("• **Manual run picker** — users start native child sessions from the composer or inspector")
                    Text("• **Chains** — app-managed sequential workflows where each step receives previous output")
                    Text("• **Parallel runs** — app-managed concurrent child sessions with optional worktree isolation")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            AppCard(title: "Execution Modes") {
                VStack(alignment: .leading, spacing: 12) {
                    docKeyValueRows([
                        ("SINGLE", "`params.agent?` → one agent, one task"),
                        ("PARALLEL", "`params.tasks?` → concurrent agents"),
                        ("CHAIN", "`params.chain?` → sequential pipeline with {previous} templating")
                    ])
                }
            }

            AppCard(title: "Foreground vs Background") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("• **Single**: one app-owned child Pi RPC session for a bounded task.")
                    Text("• **Chain**: sequential native child runs where each step receives the previous result.")
                    Text("• **Parallel**: independent native child runs with app-owned status, stop, retry, and worktree controls.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            AppCard(title: "Control & Visibility") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("• `needs_attention` — fired when a child has had no activity for a configured window")
                    Text("• `active_long_running` — fired when a child has been running beyond a threshold")
                    Text("• `failed_tool_attempts` — consecutive mutating-tool failures trigger escalation")
                    Text("• These events appear as native transcript and activity cards scoped to the owning parent session.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Helpers

    private func docKeyValueRows(_ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(row.0)
                        .font(.body.weight(.semibold))
                        .frame(minWidth: 160, alignment: .trailing)
                    Text(row.1)
                        .foregroundStyle(AppTheme.mutedText)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DiagnosticsScreen: View {
    let snapshot: ScanSnapshot

    private struct PackageInfo {
        let name: String
        let displayName: String
        let description: String
        let repoURL: String?
        let homepageURL: String?
        let author: String
        let installCommand: String
        let category: Category
        let isInstalled: Bool
        let installedVersion: String?

        enum Category {
            case essential, recommended, niceToHave
        }
    }

    private var packages: [PackageInfo] {
        let installed = Set(detectInstalledPackageNames())
        return [
            PackageInfo(
                name: "pi-web-access",
                displayName: "pi-web-access",
                description: "Web search, URL fetching, GitHub repo cloning, PDF extraction, and YouTube/local video analysis.",
                repoURL: "https://github.com/nicobailon/pi-web-access",
                homepageURL: "https://github.com/nicobailon/pi-web-access#readme",
                author: "Nico Bailon",
                installCommand: "pi install npm:pi-web-access",
                category: .essential,
                isInstalled: installed.contains("pi-web-access"),
                installedVersion: installedPackageVersion("pi-web-access")
            ),
            PackageInfo(
                name: "pi-ask-user",
                displayName: "pi-ask-user",
                description: "Interactive multi-choice and freeform question UI for Pi agents. Provides the ask_user tool.",
                repoURL: "https://github.com/edlsh/pi-ask-user",
                homepageURL: "https://github.com/edlsh/pi-ask-user#readme",
                author: "Enzo Lucchesi",
                installCommand: "pi install npm:pi-ask-user",
                category: .niceToHave,
                isInstalled: installed.contains("pi-ask-user") || FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.pi/agent/extensions/ask-user/index.ts"),
                installedVersion: installedPackageVersion("pi-ask-user")
            )
        ]
    }

    var body: some View {
        AppPage("Doctor", subtitle: "Check what Pi Manager is missing and fix the essentials faster") {
            packageSection
            settingsSection
            warningsSection
        }
    }

    // MARK: - Packages

    private var packageSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
            AppCard(title: "Essential") {
                packageRows(packages.filter { $0.category == .essential })
            }

            let recommended = packages.filter { $0.category == .recommended }
            if !recommended.isEmpty {
                AppCard(title: "Recommended") {
                    packageRows(recommended)
                }
            }

            let optional = packages.filter { $0.category == .niceToHave }
            if !optional.isEmpty {
                AppCard(title: "Nice to Have") {
                    packageRows(optional)
                }
            }
        }
    }

    private func packageRows(_ items: [PackageInfo]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.name) { index, pkg in
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: pkg.isInstalled ? "checkmark.circle.fill" : "xmark.circle")
                        .font(.title3)
                        .foregroundStyle(pkg.isInstalled ? .green : .red)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(pkg.displayName)
                                .font(.body.weight(.semibold))
                                .fontWidth(.expanded)

                            if let version = pkg.installedVersion {
                                Text(version)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(AppTheme.mutedText)
                            }
                        }

                        Text(pkg.description)
                            .font(.caption)
                            .foregroundStyle(AppTheme.mutedText)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 8) {
                            if !pkg.author.isEmpty {
                                doctorMetaChip("Author", value: pkg.author)
                            }
                            if let repoURL = pkg.repoURL {
                                doctorLinkChip("GitHub", url: repoURL)
                            }
                            if let homepageURL = pkg.homepageURL {
                                doctorLinkChip("Docs", url: homepageURL)
                            }
                        }

                        HStack(spacing: 8) {
                            Text(pkg.installCommand)
                                .font(.caption.monospaced())
                                .foregroundStyle(AppTheme.mutedText)
                                .textSelection(.enabled)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Capsule(style: .continuous).fill(AppTheme.contentSubtleFill))

                            Button("Copy") {
                                copyToPasteboard(pkg.installCommand)
                            }
                            .controlSize(.small)
                        }
                    }

                    Spacer(minLength: 8)

                    AppLabelTag(
                        text: pkg.isInstalled ? "Installed" : "Missing",
                        color: pkg.isInstalled ? .green : .red
                    )
                }
                .padding(.vertical, 12)

                if index < items.count - 1 {
                    Divider()
                }
            }
        }
    }

    // MARK: - Helpers

    private func doctorMetaChip(_ title: String, value: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .foregroundStyle(AppTheme.mutedText)
            Text(value)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule(style: .continuous).fill(AppTheme.contentSubtleFill))
    }

    private func doctorLinkChip(_ title: String, url: String) -> some View {
        Button {
            guard let resolvedURL = URL(string: url) else { return }
            NSWorkspace.shared.open(resolvedURL)
        } label: {
            HStack(spacing: 6) {
                Text(title)
                Image(systemName: "arrow.up.right.square")
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule(style: .continuous).fill(AppTheme.contentSubtleFill))
        }
        .buttonStyle(.plain)
        .help(url)
    }

    // MARK: - Settings

    private var settingsSection: some View {
        AppCard(title: "Settings Files") {
            if snapshot.settings.isEmpty {
                Text("No settings files found.")
                    .foregroundStyle(AppTheme.mutedText)
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(snapshot.settings.enumerated()), id: \.element.path) { index, settings in
                        settingsDetail(settings)
                        if index < snapshot.settings.count - 1 {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private func settingsDetail(_ settings: SettingsSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(settings.path)
                    .font(.body.weight(.semibold))
                    .fontWidth(.expanded)
                    .textSelection(.enabled)
                Spacer()
                Button("Open") { openFile(settings.path) }
                Button("Reveal") { revealInFinder(settings.path) }
            }

            AppKeyValueList(rows: [
                ("Disable Builtins", boolLabel(settings.disableBuiltins)),
                ("Builtin Agent Overrides", "\(settings.agentOverrides.count)"),
                ("Extra Prompt Template Paths", "\(settings.prompts.count)"),
                ("Packages", "\(settings.packages.count)")
            ])

            if !settings.packages.isEmpty {
                packageListDetail(settings.packages)
            }

            if !settings.agentOverrides.isEmpty {
                overridesDetail(settings.agentOverrides)
            }
        }
    }

    private func packageListDetail(_ packages: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Packages")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.mutedText)
            ForEach(packages, id: \.self) { pkg in
                HStack(spacing: 8) {
                    Image(systemName: "shippingbox")
                        .foregroundStyle(.orange)
                        .frame(width: 16)
                    Text(pkg)
                        .font(.footnote)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func overridesDetail(_ overrides: [BuiltinOverrideRecord]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Builtin Overrides")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.mutedText)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(overrides.enumerated()), id: \.element.agentName) { index, override in
                    HStack(alignment: .top, spacing: 10) {
                        Text(override.agentName)
                            .font(.footnote.weight(.semibold))
                            .frame(minWidth: 100, alignment: .trailing)
                        Text(prettyJSONObject(override.values))
                            .font(.footnote.monospaced())
                            .foregroundStyle(AppTheme.mutedText)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 6)
                    if index < overrides.count - 1 { Divider() }
                }
            }
        }
    }

    // MARK: - Warnings

    private var warningsSection: some View {
        AppCard(title: "Warnings") {
            if snapshot.warnings.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("All checks passed.")
                        .foregroundStyle(AppTheme.mutedText)
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(snapshot.warnings.prefix(20).enumerated()), id: \.element.id) { index, warning in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .frame(width: 20)
                            Text(warning.message)
                                .font(.body)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 8)
                        if index < min(snapshot.warnings.count, 20) - 1 { Divider() }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func installedPackageVersion(_ name: String) -> String? {
        let candidates = [
            URL(fileURLWithPath: "/opt/homebrew/lib/node_modules/\(name)/package.json"),
            URL(fileURLWithPath: "/usr/local/lib/node_modules/\(name)/package.json"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".npm-global/lib/node_modules/\(name)/package.json"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("node_modules/\(name)/package.json")
        ]

        for candidate in candidates {
            guard let data = try? Data(contentsOf: candidate),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let version = json["version"] as? String,
                  !version.isEmpty else { continue }
            return version
        }

        return nil
    }

    private func detectInstalledPackageNames() -> [String] {
        let candidates = [
            URL(fileURLWithPath: "/opt/homebrew/lib/node_modules"),
            URL(fileURLWithPath: "/usr/local/lib/node_modules")
        ]
        var names: [String] = []
        for dir in candidates {
            guard let contents = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for url in contents {
                let name = url.lastPathComponent
                if name.hasPrefix("pi-") || name.contains("pi-") {
                    names.append(name)
                }
            }
        }
        return names
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

private extension Notification.Name {
    static let piManagerImportSkillsRequested = Notification.Name("piManagerImportSkillsRequested")
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
    let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
    if let piIndex = components.lastIndex(of: ".pi"), piIndex > 0 {
        return components[piIndex - 1]
    }
    if let agentsIndex = components.lastIndex(of: ".agents"), agentsIndex > 0 {
        return components[agentsIndex - 1]
    }
    return nil
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
                                Text("Builtin overrides only patch the supported subagent settings fields.")
                                    .foregroundStyle(AppTheme.mutedText)
                            }
                        }

                        Section("Behavior") {
                            Text(modelSelectionSummary)
                                .foregroundStyle(AppTheme.mutedText)

                            LabeledContent {
                                TextField("", text: binding(for: \ .model))
                                    .labelsHidden()
                            } label: {
                                editorFieldLabel("Model", help: "Default model for this agent. Pi Manager reads these from `pi --list-models`, and saved configs usually use `provider/model`.")
                            }

                            LabeledContent {
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
                            } label: {
                                editorFieldLabel("Choose Model", help: "Pick from models Pi currently knows about. Choosing one also constrains the thinking levels shown below.")
                            }

                            LabeledContent {
                                TextField("", text: arrayBinding(for: \ .fallbackModels))
                                    .labelsHidden()
                            } label: {
                                editorFieldLabel("Fallback Models", help: "Ordered backup models Pi can try if the primary model is unavailable or a pattern resolves differently.")
                            }

                            LabeledContent {
                                Menu("Add Fallback Model") {
                                    modelPickerMenu { model in
                                        addFallbackModel(model.identifier)
                                    }
                                }
                            } label: {
                                editorFieldLabel("Add Fallback Model", help: "Adds one model to the fallback list without editing the comma-separated field manually.")
                            }

                            selectedListView(title: "Selected Fallback Models", values: draft.config.fallbackModels, remove: removeFallbackModel)

                            LabeledContent {
                                Picker("", selection: thinkingSelectionBinding) {
                                    ForEach(availableThinkingLevelsForDraft, id: \.self) { level in
                                        Text(level).tag(level)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                            } label: {
                                editorFieldLabel("Thinking", help: "Reasoning effort for the selected model. Pi only shows levels that the current model supports.")
                            }

                            LabeledContent {
                                TextField("", text: binding(for: \ .systemPromptMode))
                                    .labelsHidden()
                            } label: {
                                editorFieldLabel("Prompt Mode", help: "`replace` makes this agent’s prompt the main system prompt. `append` keeps more of Pi’s base behavior and adds this agent’s instructions on top.")
                            }

                            Toggle(isOn: defaultedOptionalBoolBinding(for: \ .inheritProjectContext) { draft.config.name == "delegate" }) {
                                editorFieldLabel("Inherit Project Context", help: "When enabled, the agent keeps project instruction files such as `AGENTS.md` or `CLAUDE.md`. This is prompt context, not the full parent session history.")
                            }

                            Toggle(isOn: defaultedOptionalBoolBinding(for: \ .inheritSkills, default: false)) {
                                editorFieldLabel("Inherit Skills", help: "When enabled, the agent keeps Pi’s discovered skills catalog in its prompt. This is separate from explicit skills listed on the agent itself.")
                            }

                            Toggle(isOn: optionalBoolBinding(for: \ .disabled)) {
                                editorFieldLabel("Disabled", help: "Disabled agents are hidden from normal native subagent discovery and launch flows while keeping the agent installed.")
                            }
                        }

                        Section("Tools & Skills") {
                            Text(toolSelectionSummary)
                                .foregroundStyle(AppTheme.mutedText)

                            LabeledContent {
                                HStack(spacing: 10) {
                                    Menu("Choose Tool") {
                                        ForEach(availableTools, id: \.self) { tool in
                                            Button(tool) { addTool(tool) }
                                        }
                                    }

                                    Menu("Apply Preset") {
                                        Button("Core") { applyToolPreset(["read", "grep", "find", "ls", "bash"]) }
                                        Button("Coding") { applyToolPreset(["read", "grep", "find", "ls", "bash", "edit", "write"]) }
                                        Button("Research") { applyToolPreset(["read", "web_search", "fetch_content", "get_search_content", "code_search"]) }
                                        Button("Clear Tools") { draft.config.tools = [] }
                                    }
                                }
                            } label: {
                                editorFieldLabel("Tools", help: "Explicit tools become the agent’s allowlist. New custom agents start with a core preset: read, grep, find, ls, bash.")
                            }

                            LabeledContent {
                                TextField("Comma-separated tools", text: toolsBinding())
                                    .labelsHidden()
                            } label: {
                                editorFieldLabel("Tool List", help: "You can edit tool names directly here. Pi Manager stores them as a comma-separated list in frontmatter.")
                            }

                            selectedListView(title: "Selected Tools", values: selectedToolValues, remove: removeTool)

                            Text(skillSelectionSummary)
                                .foregroundStyle(AppTheme.mutedText)

                            LabeledContent {
                                Menu("Choose Skill") {
                                    ForEach(availableSkills, id: \.self) { skill in
                                        Button(skill) { addSkill(skill) }
                                    }
                                }
                            } label: {
                                editorFieldLabel("Skills", help: "Choose from skills visible in this agent’s current scope. This includes reusable library skills as well as globally visible and project-visible skills.")
                            }

                            LabeledContent {
                                TextField("Comma-separated skills", text: arrayBinding(for: \ .skills))
                                    .labelsHidden()
                            } label: {
                                editorFieldLabel("Skill List", help: "Explicit skills are attached by name to this agent. You can add them from the picker above or edit the list directly here.")
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

    private func editorFieldLabel(_ title: String, help: String? = nil) -> some View {
        HStack(spacing: 6) {
            Text(title)
            if let help {
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(AppTheme.mutedText)
                    .help(help)
            }
        }
    }

    private func applyToolPreset(_ tools: [String]) {
        let allowed = Set(availableTools)
        draft.config.tools = tools.filter { allowed.contains($0) }
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
        case .builtinOverride(scope: .global), .custom(scope: .global), .custom(scope: .library):
            return "Library/global agent: tools are based on the global environment only."
        case .builtinOverride(scope: .project), .custom(scope: .project):
            return "Project agent: tools are based on global + selected project scope."
        }
    }

    private var skillSelectionSummary: String {
        switch draft.target {
        case .builtinOverride(scope: .global), .custom(scope: .global), .custom(scope: .library):
            return "Library/global agent: skills come from globally visible skills plus reusable library skills."
        case .builtinOverride(scope: .project), .custom(scope: .project):
            return "Project agent: skills come from globally visible skills, reusable library skills, and project-local skills in the selected project."
        }
    }

    private var promptSectionSummary: String {
        switch draft.target {
        case .builtinOverride:
            return "This prompt is saved as the builtin override’s `systemPrompt` patch in settings."
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
