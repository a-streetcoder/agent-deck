import AppKit
import SwiftUI


extension View {
    func bottomEdgeFade(height: CGFloat = 36) -> some View {
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

    /// Hides the native macOS scroller for the nearest enclosing `NSScrollView`.
    /// `.scrollIndicators(.hidden)` is unreliable for `List` — especially when the
    /// system "Show scroll bars" preference is set to "Always" — so we reach down
    /// to AppKit to guarantee no scrollers anywhere in the app.
    func hideNativeScrollers() -> some View {
        background(ScrollerHidingConfigurator())
    }
}

private struct ScrollerHidingConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> ScrollerHidingProbe {
        ScrollerHidingProbe()
    }

    func updateNSView(_ nsView: ScrollerHidingProbe, context: Context) {
        nsView.suppressScrollers()
    }
}

/// A scroller that occupies zero width and never draws. Installed onto a
/// `List`'s `NSScrollView`, it makes the scroll indicator permanently invisible
/// without fighting SwiftUI: `List` re-toggles `hasVerticalScroller` on every
/// layout pass, but the scroller it toggles is this one — nothing to show.
private final class HiddenScroller: NSScroller {
    override class func scrollerWidth(
        for controlSize: NSControl.ControlSize,
        scrollerStyle: NSScroller.Style
    ) -> CGFloat {
        0
    }

    override func draw(_ dirtyRect: NSRect) {
        // Intentionally empty — the scroller renders nothing.
    }
}

/// A zero-cost probe inserted via `.background(...)`. It locates the sibling
/// `NSScrollView` it is layered behind — by matching frames window-wide, since
/// SwiftUI does not make the scroll view a reachable ancestor — and swaps in
/// `HiddenScroller`s. Once swapped, the scrollers stay hidden permanently
/// regardless of how `List` re-renders, so there is no visible "fighting".
final class ScrollerHidingProbe: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        suppressScrollers()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        suppressScrollers()
    }

    func suppressScrollers() {
        // The target scroll view may not be laid out yet on the first pass, so
        // retry across the next few runloop turns until it turns up.
        for delay in [0.0, 0.1, 0.3, 0.6, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.applySuppression()
            }
        }
    }

    private func applySuppression() {
        guard let scrollView = targetScrollView() else { return }
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        if !(scrollView.verticalScroller is HiddenScroller) {
            scrollView.verticalScroller = HiddenScroller()
        }
        if !(scrollView.horizontalScroller is HiddenScroller) {
            scrollView.horizontalScroller = HiddenScroller()
        }
    }

    /// Among every scroll view in the window, pick the smallest one that covers
    /// most of this probe — that is the list/scroll view we are layered behind.
    private func targetScrollView() -> NSScrollView? {
        guard let contentView = window?.contentView else { return nil }
        let probe = convert(bounds, to: nil)
        let probeArea = probe.width * probe.height
        guard probeArea > 1 else { return nil }

        var best: NSScrollView?
        var bestArea = CGFloat.greatestFiniteMagnitude
        var stack: [NSView] = [contentView]
        while let view = stack.popLast() {
            stack.append(contentsOf: view.subviews)
            guard let scrollView = view as? NSScrollView else { continue }
            let frame = scrollView.convert(scrollView.bounds, to: nil)
            let overlap = frame.intersection(probe)
            guard overlap.width * overlap.height >= probeArea * 0.6 else { continue }
            let area = frame.width * frame.height
            if area < bestArea {
                bestArea = area
                best = scrollView
            }
        }
        return best
    }
}

extension View {
    func toolbarNeutralChrome() -> some View {
        symbolRenderingMode(.monochrome)
            .foregroundStyle(.primary)
            .tint(.primary)
    }

    /// Primary create/`+` actions. `.tint` drives the brand-coloured glyph and
    /// the tinted hover/press highlight. `.menuStyle(.button)` makes a `Menu`
    /// render as a push button so its hover highlight matches a plain `Button`
    /// — a toolbar `Menu` is a pulldown and otherwise draws a different
    /// highlight. It is a harmless no-op on `Button`s.
    func toolbarPrimaryActionChrome() -> some View {
        symbolRenderingMode(.monochrome)
            .foregroundStyle(AppTheme.brandAccent)
            .tint(AppTheme.brandAccent)
            .menuStyle(.button)
    }
}

struct ContentView: View {
    @Environment(\.openSettings) private var openSettings
    @Environment(AppViewModel.self) private var viewModel
    @State private var agentDraft: AgentEditorDraft?
    @State private var editingAgent: EffectiveAgentRecord?
    @State private var envDraft: EnvEditorDraft?
    @State private var projectFilterText = ""
    @State private var debouncedProjectFilterText = ""
    @State private var agentSearchText = ""
    @State private var issueSearchText = ""
    @State private var memorySearchText = ""
    @State private var projectSearchText = ""
    @State private var skillSearchText = ""
    @State private var promptSearchText = ""
    @State private var piAgentSessionSearchText = ""
    @State private var isSkillsInfoPresented = false
    @State private var isSubagentsInfoPresented = false
    @State private var isEnvironmentInfoPresented = false
    @State private var isModelsInfoPresented = false
    @State private var showingEnableAllProjectsAlert = false
    @State private var showingDisableAllProjectsAlert = false
    @State private var showingPiAgentDeleteAlert = false
    @State private var isPiAgentTranscriptOptionsPresented = false
    @State private var isPiAgentStartupResourcesPresented = false
    @State private var isPiAgentSubagentsPopoverPresented = false
    @State private var navigationColumnVisibility: NavigationSplitViewVisibility = .all
    @State private var agentModelQuickEditor: AgentModelQuickEditorContext?
    @State private var commandContext = AgentDeckCommandContext()
    @State private var isIssuesFilterPopoverPresented = false
    @State private var isAgentsFilterPopoverPresented = false
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
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 18)

                sidebarSectionsList(warnings: warnings)

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
        .toolbar { mainToolbarContent }
        // Detect the selected project's dev-server commands off the render path
        // so the toolbar control can hide for projects that have none.
        .task(id: viewModel.piAgentSessionStore.selectedSession?.projectPath) {
            if let path = viewModel.piAgentSessionStore.selectedSession?.projectPath {
                viewModel.projectServerService.refreshDetectedCommands(forProjectPath: path)
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
                projectRoot: viewModel.selectedProjectPath,
                onCancel: { envDraft = nil },
                onSave: { drafts in
                    try viewModel.saveEnvDrafts(drafts)
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
            get: { viewModel.isPiAgentInspectorPresented },
            set: { viewModel.isPiAgentInspectorPresented = $0 }
        )
    }

    private var detailInspectorContent: some View {
        PiAgentInspectorPanel(viewModel: viewModel, store: viewModel.piAgentSessionStore)
            .inspectorColumnWidth(min: 300, ideal: 380, max: 560)
    }

    private var toolbarSearchIsVisible: Bool {
        switch viewModel.selectedSidebarItem {
        case .projects, .agents, .issues, .memory, .skills, .prompts, .agent:
            return true
        default:
            return false
        }
    }

    private var toolbarSearchPrompt: String {
        switch viewModel.selectedSidebarItem {
        case .projects: return "Search projects"
        case .agents: return "Search agents"
        case .issues: return "Search issues"
        case .memory: return "Search memories"
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
                case .projects: return projectSearchText
                case .agents: return agentSearchText
                case .issues: return issueSearchText
                case .memory: return memorySearchText
                case .skills: return skillSearchText
                case .prompts: return promptSearchText
                case .agent: return piAgentSessionSearchText
                default: return ""
                }
            },
            set: { value in
                switch viewModel.selectedSidebarItem {
                case .projects: projectSearchText = value
                case .agents: agentSearchText = value
                case .issues: issueSearchText = value
                case .memory: memorySearchText = value
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
            // Route through the Prompts screen so the new prompt opens in the
            // editor sheet and is only written to disk if the user saves.
            if viewModel.selectedSidebarItem != .prompts {
                viewModel.selectedSidebarItem = .prompts
            }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .agentDeckNewPromptRequested, object: nil)
            }
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

    private var issuesFiltersAreActive: Bool {
        viewModel.githubAuthorFilter != nil
            || viewModel.githubAssigneeFilter != nil
            || viewModel.githubTypeFilter != nil
            || !viewModel.githubLabelFilters.isEmpty
    }

    /// Extracted from `mainContent` so the type-checker doesn't choke on the
    /// nested-ForEach inside a List inside a NavigationSplitView column. The
    /// inlined version was tipping the compiler over "type-check in reasonable
    /// time" after recent additions to the surrounding toolbar/body.
    @ViewBuilder
    private func sidebarSectionsList(warnings: [SidebarItem: Bool]) -> some View {
        @Bindable var viewModel = viewModel
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
        .bottomEdgeFade(height: 34)
    }

    @ToolbarContentBuilder
    private var mainToolbarContent: some ToolbarContent {
        ToolbarSpacer(.flexible)
        primaryActionToolbarItems
    }

    private var agentsFilterButton: some View {
        Button {
            isAgentsFilterPopoverPresented.toggle()
        } label: {
            Label("Filter", systemImage: viewModel.selectedAgentFilter == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .toolbarNeutralChrome()
        .help("Filter agents")
        .popover(isPresented: $isAgentsFilterPopoverPresented, arrowEdge: .bottom) {
            AgentsFilterPopover(viewModel: viewModel)
        }
    }

    @ToolbarContentBuilder
    private var primaryActionToolbarItems: some ToolbarContent {
        if viewModel.selectedSidebarItem == .projects {
            projectsPrimaryToolbarContent
        }
        if viewModel.selectedSidebarItem == .issues {
            issuesPrimaryToolbarContent
        }
        if viewModel.selectedSidebarItem == .agents {
            agentsPrimaryToolbarContent
        }
        if viewModel.selectedSidebarItem == .environment {
            environmentPrimaryToolbarContent
        }
        if viewModel.selectedSidebarItem == .prompts {
            promptsPrimaryToolbarContent
        }
        if viewModel.selectedSidebarItem == .skills {
            skillsPrimaryToolbarContent
        }
        if viewModel.selectedSidebarItem == .agent {
            piAgentPrimaryToolbarContent
        }
        if viewModel.selectedSidebarItem == .models {
            modelsPrimaryToolbarContent
        }
    }

    @ToolbarContentBuilder
    private var projectsPrimaryToolbarContent: some ToolbarContent {
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

    @ToolbarContentBuilder
    private var agentsPrimaryToolbarContent: some ToolbarContent {
        // Utility island: filter the list, bulk-edit models, and (contextually)
        // create a replacement for a selected builtin agent.
        ToolbarItem(placement: .primaryAction) {
            ControlGroup {
                agentsFilterButton

                Button {
                    agentModelQuickEditor = currentAgentModelQuickEditorContext
                } label: {
                    Label("Quick Edit Models", systemImage: "cpu")
                }
                .toolbarNeutralChrome()
                .help("Quick edit agent models and thinking")
                .disabled(currentAgentModelQuickEditorContext.sections.allSatisfy { $0.agents.isEmpty })

                if let agent = viewModel.selectedAgent {
                    replacementAgentButton(for: agent)
                }
            }
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        // Info + create island. `newAgentMenu` is the tinted trailing member, so
        // the ControlGroup renders it as a filled prominent segment — matching
        // the primary action in the instruction-editor toolbars.
        ToolbarItem(placement: .primaryAction) {
            ControlGroup {
                subagentsInfoButton
                newAgentMenu
            }
        }
    }

    private var newAgentMenu: some View {
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

    private func replacementAgentButton(for agent: EffectiveAgentRecord) -> some View {
        Button {
            editingAgent = nil
            agentDraft = viewModel.makeReplacementAgentDraft(from: agent, scope: .global)
        } label: {
            Label("Replacement", systemImage: "arrow.triangle.2.circlepath")
        }
        .toolbarNeutralChrome()
        .help("Create a global replacement for this builtin agent")
        .disabled(!(agent.builtin != nil && agent.globalCustom == nil))
    }

    private var subagentsInfoButton: some View {
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

    @ToolbarContentBuilder
    private var environmentPrimaryToolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            ControlGroup {
                Button {
                    isEnvironmentInfoPresented.toggle()
                } label: {
                    Label("Info", systemImage: "info.circle")
                }
                .help("Explain environment resolution order")
                .popover(isPresented: $isEnvironmentInfoPresented, arrowEdge: .bottom) {
                    EnvironmentInfoPopover()
                }
                .toolbarNeutralChrome()

                Button {
                    // The sheet itself carries the scope picker now — open it
                    // defaulting to Project when one is selected, else Global.
                    let scope: AgentEditingTarget.CustomAgentScope =
                        viewModel.selectedProjectPath == nil ? .global : .project
                    envDraft = viewModel.makeNewEnvDraft(scope: scope)
                } label: {
                    Label("New Key", systemImage: "plus")
                }
                .toolbarPrimaryActionChrome()
                .help("Add one or more environment keys")
            }
        }
    }

    @ToolbarContentBuilder
    private var modelsPrimaryToolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            ControlGroup {
                Button {
                    isModelsInfoPresented.toggle()
                } label: {
                    Label("Info", systemImage: "info.circle")
                }
                .help("Explain the models catalog and Pi Agent defaults")
                .popover(isPresented: $isModelsInfoPresented, arrowEdge: .bottom) {
                    ModelsInfoPopover()
                }
                .toolbarNeutralChrome()

                Button {
                    viewModel.refreshModels()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .toolbarNeutralChrome()
                .help("Refresh models")
            }
        }
    }

    @ToolbarContentBuilder
    private var promptsPrimaryToolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("New Prompt") {
                    NotificationCenter.default.post(name: .agentDeckNewPromptRequested, object: nil)
                }
                Button("Import Prompt") {
                    NotificationCenter.default.post(name: .agentDeckImportPromptRequested, object: nil)
                }
            } label: {
                Label("New", systemImage: "plus")
            }
            .menuIndicator(.hidden)
            .toolbarPrimaryActionChrome()
            .help("Create a new prompt template or import an existing markdown file")
        }
    }

    private var skillsUpdateAllTitle: String {
        if viewModel.isUpdatingAllSkillRepositories { return "Updating" }
        let count = viewModel.skillRepositoriesWithKnownUpdates.count
        return count > 0 ? "Update All (\(count))" : "Update All"
    }

    @ToolbarContentBuilder
    private var skillsPrimaryToolbarContent: some ToolbarContent {
        // Sync island — manage updates for skills imported from Git repos.
        // Only shown once at least one skill repository has been synced.
        if !viewModel.appSettings.importedSkillRepositories.isEmpty {
            ToolbarItem(placement: .primaryAction) {
                ControlGroup {
                    Button {
                        Task { await viewModel.checkAllSkillRepositoriesForUpdates() }
                    } label: {
                        Label(
                            viewModel.isCheckingAllSkillUpdates ? "Checking" : "Check for Updates",
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                    }
                    .symbolEffect(.rotate.byLayer, isActive: viewModel.isCheckingAllSkillUpdates)
                    .toolbarNeutralChrome()
                    .help("Check every synced skill repository for updates")
                    .disabled(viewModel.isCheckingAllSkillUpdates || viewModel.isUpdatingAllSkillRepositories)

                    Button {
                        Task { await viewModel.updateAllSkillRepositoriesWithKnownUpdates() }
                    } label: {
                        Label(skillsUpdateAllTitle, systemImage: "arrow.down.circle")
                    }
                    .toolbarNeutralChrome()
                    .help("Update every synced skill that has a new version available")
                    .disabled(
                        viewModel.skillRepositoriesWithKnownUpdates.isEmpty
                            || viewModel.isCheckingAllSkillUpdates
                            || viewModel.isUpdatingAllSkillRepositories
                    )
                }
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }

        // Rescan + info + create island — `New` is the tinted trailing member
        // so the ControlGroup renders it as a filled prominent segment.
        ToolbarItem(placement: .primaryAction) {
            ControlGroup {
                Button {
                    viewModel.refresh(includeModels: false, scanAllProjects: true)
                } label: {
                    Label(viewModel.isRefreshingProjects ? "Refreshing" : "Refresh", systemImage: "arrow.clockwise")
                }
                .symbolEffect(.rotate.byLayer, isActive: viewModel.isRefreshingProjects)
                .toolbarNeutralChrome()
                .help("Rescan skills")
                .disabled(viewModel.isRefreshingProjects)

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

                Menu {
                    Button("New Skill") {
                        NotificationCenter.default.post(name: .agentDeckNewSkillRequested, object: nil)
                    }
                    Button("Import Skills") {
                        NotificationCenter.default.post(name: .agentDeckImportSkillsRequested, object: nil)
                    }
                } label: {
                    Label("New", systemImage: "plus")
                }
                .menuIndicator(.hidden)
                .help("Create a new skill or import skill folders from an external source")
                .toolbarPrimaryActionChrome()
            }
        }
    }

    @ToolbarContentBuilder
    private var piAgentPrimaryToolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            ControlGroup {
                PiAgentPlanToolbarButton(store: viewModel.piAgentSessionStore)

                Button {
                    isPiAgentStartupResourcesPresented.toggle()
                } label: {
                    Label("Session Resources", systemImage: "info.circle")
                }
                .toolbarNeutralChrome()
                .help("Agents, skills, prompts, and environment available to this session")
                .disabled(viewModel.piAgentSessionStore.selectedSession == nil)
                .popover(isPresented: $isPiAgentStartupResourcesPresented, arrowEdge: .bottom) {
                    if let session = viewModel.piAgentSessionStore.selectedSession {
                        PiAgentStartupResourcesPopover(viewModel: viewModel, session: session)
                    }
                }

                Button {
                    isPiAgentTranscriptOptionsPresented.toggle()
                } label: {
                    Label("Transcript Display", systemImage: "eye")
                }
                .toolbarNeutralChrome()
                .help("Choose what appears in the agent transcript")
                .popover(isPresented: $isPiAgentTranscriptOptionsPresented, arrowEdge: .bottom) {
                    PiAgentTranscriptDisplayOptionsPopover(viewModel: viewModel)
                }
            }
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        if viewModel.shouldShowPiAgentGitActions {
            ToolbarItem(placement: .primaryAction) {
                ControlGroup {
                    PiAgentCommitToolbarButton(viewModel: viewModel)
                    PiAgentPushToolbarButton(viewModel: viewModel)
                    if viewModel.shouldShowMergeSelectedPiAgentSession {
                        PiAgentMergeToolbarButton(viewModel: viewModel)
                    }
                } label: {
                    Label("Git Actions", systemImage: "checkmark")
                }
                .toolbarNeutralChrome()
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }

        if viewModel.shouldShowProjectServerControls {
            ToolbarItem(placement: .primaryAction) {
                ProjectServerToolbarButton(
                    viewModel: viewModel,
                    store: viewModel.piAgentSessionStore
                )
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }

        ToolbarItem(placement: .primaryAction) {
            PiAgentOpenTerminalToolbarButton(
                viewModel: viewModel,
                store: viewModel.piAgentSessionStore
            )
        }
    }

    @ToolbarContentBuilder
    private var issuesPrimaryToolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) { issuesFilterButton }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) { issuesRefreshButton }
    }

    private var issuesFilterButton: some View {
        Button {
            isIssuesFilterPopoverPresented.toggle()
        } label: {
            Label("Filter", systemImage: issuesFiltersAreActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .toolbarNeutralChrome()
        .help("Filter issues")
        .disabled(viewModel.selectedGitHubProject?.gitHubRemote == nil)
        .popover(isPresented: $isIssuesFilterPopoverPresented, arrowEdge: .bottom) {
            IssuesFiltersPopover(viewModel: viewModel)
        }
    }

    private var issuesRefreshButton: some View {
        Button {
            viewModel.refreshProjectBoard(force: true)
        } label: {
            Label(viewModel.githubIsLoadingProjectBoard ? "Refreshing" : "Refresh", systemImage: "arrow.clockwise")
        }
        .symbolEffect(.rotate.byLayer, isActive: viewModel.githubIsLoadingProjectBoard)
        .toolbarNeutralChrome()
        .help("Refresh issues")
        .disabled(!viewModel.githubConnectionState.isConnected || viewModel.githubIsLoadingProjectBoard)
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
            ProjectsScreen(viewModel: viewModel, searchText: $projectSearchText)
        case .instructions:
            SystemInstructionsScreen(viewModel: viewModel)
        case .memory:
            MemoryScreen(viewModel: viewModel, memoryStore: viewModel.agentMemoryStore, searchText: $memorySearchText)
        case .issues:
            IssuesScreen(viewModel: viewModel, searchText: $issueSearchText)
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
        }
    }

    private func handleSidebarSelectionChange(_ newValue: SidebarItem) {
        if newValue == .agent {
            viewModel.acknowledgeVisibleSelectedPiAgentSession()
        }
    }

    private var toolbarTitle: String {
        switch viewModel.selectedSidebarItem {
        case .agents:
            return viewModel.selectedAgent?.name ?? "Agents"
        case .agent:
            return viewModel.piAgentSessionStore.selectedSession?.displayTitle ?? "Pi Agent"
        case .skills:
            return viewModel.selectedSkill?.name ?? "Skills"
        case .issues:
            return viewModel.selectedGitHubProject?.gitHubRemote?.nameWithOwner ?? "Issues"
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
