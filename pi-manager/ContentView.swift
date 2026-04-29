import AppKit
import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = AppViewModel()
    @State private var agentDraft: AgentEditorDraft?
    @State private var editingAgent: EffectiveAgentRecord?
    @State private var builtinOverrideTargetAgent: EffectiveAgentRecord?
    @State private var chainDraft: ChainEditorDraft?
    @State private var envDraft: EnvEditorDraft?

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

                List(SidebarItem.allCases, selection: $viewModel.selectedSidebarItem) { item in
                    Label(item.rawValue, systemImage: item.systemImage)
                        .fontWidth(.expanded)
                        .tag(item)
                }
            }
            .toolbar {
                ToolbarItemGroup {
                    Menu {
                        Button {
                            viewModel.clearProjectRoot()
                        } label: {
                            if viewModel.selectedProjectPath == nil {
                                Label("All Projects", systemImage: "checkmark")
                            } else {
                                Text("All Projects")
                            }
                        }

                        Divider()

                        ForEach(viewModel.discoveredProjects) { project in
                            Button {
                                viewModel.setSelectedProject(project.url)
                            } label: {
                                if viewModel.selectedProjectPath == project.path {
                                    Label(project.repositoryDisplayName, systemImage: "checkmark")
                                } else {
                                    Text(project.repositoryDisplayName)
                                }
                            }
                        }

                        Divider()

                        Button("Choose Project…", systemImage: "folder") {
                            viewModel.chooseProjectRoot()
                        }
                    } label: {
                        Label(viewModel.selectedProjectName, systemImage: "folder")
                    }

                    Button("Refresh", systemImage: "arrow.clockwise") {
                        viewModel.refresh(includeModels: true)
                    }
                }
            }
        } detail: {
            detailView
        }
        .frame(minWidth: 1180, minHeight: 760)
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
        .confirmationDialog("Choose override scope", isPresented: Binding(
            get: { builtinOverrideTargetAgent != nil },
            set: { if !$0 { builtinOverrideTargetAgent = nil } }
        )) {
            Button("Global Override") {
                if let agent = builtinOverrideTargetAgent {
                    editingAgent = agent
                    agentDraft = viewModel.makeAgentDraft(for: agent, preferredOverrideScope: .global)
                }
                builtinOverrideTargetAgent = nil
            }
            if viewModel.selectedProjectPath != nil {
                Button("Project Override") {
                    if let agent = builtinOverrideTargetAgent {
                        editingAgent = agent
                        agentDraft = viewModel.makeAgentDraft(for: agent, preferredOverrideScope: .project)
                    }
                    builtinOverrideTargetAgent = nil
                }
            }
        } message: {
            Text("Builtin agents are edited as settings overrides, matching /agents in pi-subagents.")
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch viewModel.selectedSidebarItem {
        case .overview:
            OverviewScreen(viewModel: viewModel)
        case .agents:
            AgentsScreen(
                viewModel: viewModel,
                onCreateAgent: { scope in
                    editingAgent = nil
                    agentDraft = viewModel.makeNewAgentDraft(scope: scope)
                },
                onDuplicateAgent: { agent, scope in
                    editingAgent = nil
                    agentDraft = viewModel.makeDuplicateAgentDraft(from: agent, scope: scope)
                },
                onEditAgent: { agent in
                    if agent.builtin != nil, agent.globalCustom == nil, agent.projectCustom == nil {
                        builtinOverrideTargetAgent = agent
                    } else {
                        editingAgent = agent
                        agentDraft = viewModel.makeAgentDraft(for: agent)
                    }
                }
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
                onEditChain: { chain in
                    chainDraft = viewModel.makeChainDraft(for: chain)
                }
            )
        case .skills:
            SkillsScreen(viewModel: viewModel)
        case .models:
            ModelsScreen(viewModel: viewModel)
        case .environment:
            EnvironmentScreen(
                snapshot: viewModel.snapshot,
                onNewGlobalKey: {
                    envDraft = viewModel.makeNewEnvDraft(scope: .global)
                },
                onNewProjectKey: viewModel.selectedProjectPath != nil ? {
                    envDraft = viewModel.makeNewEnvDraft(scope: .project)
                } : nil,
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
}

private struct OverviewScreen: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        AppPage("Overview", subtitle: viewModel.snapshot.projectRoot ?? "Showing global resources and all discovered projects") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 16)], spacing: 16) {
                AppMetricTile(title: "Builtin Agents", value: viewModel.snapshot.builtinAgents.count)
                AppMetricTile(title: "Global Agents", value: viewModel.snapshot.globalAgents.count)
                AppMetricTile(title: "Project Agents", value: viewModel.snapshot.projectAgents.count)
                AppMetricTile(title: "Overrides", value: viewModel.snapshot.settings.flatMap(\.agentOverrides).count)
                AppMetricTile(title: "Chains", value: viewModel.snapshot.chains.count)
                AppMetricTile(title: "Skills", value: viewModel.snapshot.skills.count)
                AppMetricTile(title: "Warnings", value: viewModel.snapshot.warnings.count)
                AppMetricTile(title: "All Project Warnings", value: viewModel.totalProjectWarnings)
            }

            AppCard(title: "Discovered Projects", trailing: {
                Text("\(viewModel.discoveredProjects.count)")
                    .foregroundStyle(AppTheme.mutedText)
            }) {
                if viewModel.discoveredProjects.isEmpty {
                    Text("No projects found in ~/Documents/GitHub.")
                        .foregroundStyle(AppTheme.mutedText)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(viewModel.discoveredProjects) { project in
                            AppRowCard {
                                HStack(alignment: .top, spacing: 14) {
                                    Image("github")
                                        .resizable()
                                        .renderingMode(.template)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 16, height: 16)
                                        .padding(.top, 2)

                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(project.repositoryDisplayName)
                                            .font(.headline)
                                            .fontWidth(.expanded)
                                        Text(project.path)
                                            .font(.footnote.monospaced())
                                            .foregroundStyle(AppTheme.mutedText)
                                    }

                                    Spacer()

                                    VStack(alignment: .trailing, spacing: 6) {
                                        let warningCount = viewModel.allProjectSnapshots[project.path]?.warnings.count ?? 0
                                        if warningCount > 0 {
                                            AppLabelTag(text: "\(warningCount) warnings", color: .orange)
                                        }
                                        if viewModel.selectedProjectPath == project.path {
                                            AppLabelTag(text: "Selected", color: .blue)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
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

            AppCard(title: "What These Columns Mean") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("• Thinking: whether Pi marks the model as supporting reasoning effort levels like low, medium, or high.")
                    Text("• Images: whether the model can accept image input.")
                    Text("• ctx: the model’s context window, meaning how much total prompt/history/input it can hold.")
                    Text("• out: the maximum output tokens Pi expects the model to produce in one response.")
                    Text("• This list comes from Pi’s own available-model catalog, so Refresh is the source of truth here.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            AppCard(title: "Catalog", trailing: {
                if let date = viewModel.modelsLastUpdatedAt {
                    Text(RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date()))
                        .foregroundStyle(AppTheme.mutedText)
                }
            }) {
                if viewModel.availableModels.isEmpty {
                    Text("No models loaded yet. Use Refresh to query Pi.")
                        .foregroundStyle(AppTheme.mutedText)
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(groupedModels, id: \.provider) { group in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text(group.provider)
                                        .font(.headline)
                                        .fontWidth(.expanded)
                                    Spacer()
                                    AppLabelTag(text: "\(group.models.count)", color: .blue)
                                }

                                ForEach(group.models) { model in
                                    AppRowCard {
                                        HStack(alignment: .top, spacing: 12) {
                                            VStack(alignment: .leading, spacing: 6) {
                                                Text(model.model)
                                                    .font(.headline)
                                                    .fontWidth(.expanded)
                                                Text(model.identifier)
                                                    .font(.footnote.monospaced())
                                                    .foregroundStyle(AppTheme.mutedText)
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
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var groupedModels: [(provider: String, models: [AvailableModel])] {
        Dictionary(grouping: viewModel.availableModels, by: \.provider)
            .map { provider, models in
                (provider, models.sorted { $0.model.localizedCaseInsensitiveCompare($1.model) == .orderedAscending })
            }
            .sorted { $0.provider.localizedCaseInsensitiveCompare($1.provider) == .orderedAscending }
    }
}

private struct AgentsScreen: View {
    @ObservedObject var viewModel: AppViewModel
    let onCreateAgent: (AgentEditingTarget.CustomAgentScope) -> Void
    let onDuplicateAgent: (EffectiveAgentRecord, AgentEditingTarget.CustomAgentScope) -> Void
    let onEditAgent: (EffectiveAgentRecord) -> Void

    var body: some View {
        HSplitView {
            AppSidebarPane(title: "Agents", subtitle: "\(viewModel.filteredAgents.count) visible") {
                List(selection: $viewModel.selectedAgentID) {
                    ForEach(viewModel.filteredAgents) { agent in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .top) {
                                Text(agent.name)
                                    .font(.headline)
                                    .fontWidth(.expanded)
                                    .lineLimit(2)
                                Spacer(minLength: 8)
                                AppLabelTag(text: agent.resolutionKind.rawValue, color: .purple)
                            }

                            Text(agent.resolved.description.isEmpty ? "No description" : agent.resolved.description)
                                .foregroundStyle(AppTheme.mutedText)
                                .lineLimit(2)

                            HStack(spacing: 8) {
                                if !agent.resolved.skills.isEmpty {
                                    rowIndicator("sparkles", color: .green)
                                }
                                if agent.resolved.inheritSkills == true {
                                    rowIndicator("square.stack.3d.up", color: .mint)
                                }
                                if !((agent.resolved.tools ?? []).isEmpty) || !((agent.resolved.mcpDirectTools ?? []).isEmpty) {
                                    rowIndicator("wrench.and.screwdriver", color: .blue)
                                }
                                if let extensions = agent.resolved.extensions, !extensions.isEmpty {
                                    rowIndicator("puzzlepiece.extension", color: .orange)
                                }
                                if agent.resolved.output != nil {
                                    rowIndicator("arrow.down.doc", color: .purple)
                                }
                                if agent.resolved.disabled == true {
                                    rowIndicator("nosign", color: .red)
                                }
                                if !viewModel.warnings(for: agent).isEmpty {
                                    rowIndicator("exclamationmark.triangle", color: .orange)
                                }
                            }

                            if let projectRoot = agent.projectRoot,
                               viewModel.selectedProjectPath == nil,
                               (agent.projectCustom != nil || agent.projectOverride != nil) {
                                Text(URL(fileURLWithPath: projectRoot).lastPathComponent)
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.mutedText)
                            }
                        }
                        .padding(.vertical, 6)
                        .tag(agent.id)
                    }
                }
                .listStyle(.inset)
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Menu {
                        Button("New Global Agent") {
                            onCreateAgent(.global)
                        }
                        if viewModel.selectedProjectPath != nil {
                            Button("New Project Agent") {
                                onCreateAgent(.project)
                            }
                        }
                        if let selectedAgent = viewModel.selectedAgent {
                            Divider()
                            Button("Duplicate as Global Agent") {
                                onDuplicateAgent(selectedAgent, .global)
                            }
                            if viewModel.selectedProjectPath != nil {
                                Button("Duplicate as Project Agent") {
                                    onDuplicateAgent(selectedAgent, .project)
                                }
                            }
                        }
                    } label: {
                        Label("New", systemImage: "plus")
                    }

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
                }
            }
            .frame(minWidth: 340, idealWidth: 400, maxWidth: 500)

            if let agent = viewModel.selectedAgent {
                AgentDetailView(
                    agent: agent,
                    canCreateProjectCopy: viewModel.selectedProjectPath != nil,
                    onDuplicateAsGlobal: { onDuplicateAgent(agent, .global) },
                    onDuplicateAsProject: { onDuplicateAgent(agent, .project) },
                    onEdit: { onEditAgent(agent) }
                )
            } else {
                ContentUnavailableView("No Agent Selected", systemImage: "sparkles.rectangle.stack")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
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
        case resolution = "Resolution"
        case sourceFiles = "Source Files"
        case advanced = "Advanced"

        var id: String { rawValue }
    }

    let agent: EffectiveAgentRecord
    let canCreateProjectCopy: Bool
    let onDuplicateAsGlobal: () -> Void
    let onDuplicateAsProject: () -> Void
    let onEdit: () -> Void
    @State private var selectedTab: DetailTab = .summary

    var body: some View {
        AppPage(agent.name, subtitle: agent.resolved.description.isEmpty ? nil : agent.resolved.description) {
            AppCard(trailing: {
                HStack(spacing: 10) {
                    Menu("Actions") {
                        Button("Open Raw File") { openFile(primarySourcePath) }
                        Button("Reveal in Finder") { revealInFinder(primarySourcePath) }
                        Divider()
                        Button(agent.builtin != nil ? "Create Global Copy from Builtin" : "Duplicate as Global Agent") {
                            onDuplicateAsGlobal()
                        }
                        if canCreateProjectCopy {
                            Button(agent.builtin != nil ? "Create Project Copy from Builtin" : "Duplicate as Project Agent") {
                                onDuplicateAsProject()
                            }
                        }
                    }
                    Button(agent.builtin != nil && agent.globalCustom == nil && agent.projectCustom == nil ? (hasOverride ? "Edit Override" : "Create Override") : "Edit Agent") {
                        onEdit()
                    }
                }
            }) {
                VStack(alignment: .leading, spacing: 8) {
                    if let projectRoot = agent.projectRoot {
                        Text(URL(fileURLWithPath: projectRoot).lastPathComponent)
                            .font(.headline)
                            .fontWidth(.expanded)
                    }
                    Text(agent.builtin != nil && agent.globalCustom == nil && agent.projectCustom == nil ? (hasOverride ? "This builtin is currently customized through a settings override, matching /agents in pi-subagents." : "Builtins are not edited directly. Creating an override writes to Pi settings, matching /agents in pi-subagents.") : "Custom agents are edited as markdown files in the Pi discovery paths.")
                        .foregroundStyle(AppTheme.mutedText)
                }
            }

            Picker("Agent Detail", selection: $selectedTab) {
                ForEach(DetailTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)

            switch selectedTab {
            case .summary:
                summaryTab
            case .prompt:
                promptTab
            case .tools:
                toolsTab
            case .skills:
                skillsTab
            case .resolution:
                resolutionTab
            case .sourceFiles:
                sourceFilesTab
            case .advanced:
                advancedTab
            }
        }
    }

    private var summaryTab: some View {
        VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
            AppCard(title: "Configuration", trailing: {
                AppLabelTag(text: agent.resolutionKind.rawValue, color: .purple)
            }) {
                AppKeyValueList(rows: [
                    ("Model", agent.resolved.model ?? "default"),
                    ("Fallback Models", agent.resolved.fallbackModels.isEmpty ? "—" : agent.resolved.fallbackModels.joined(separator: ", ")),
                    ("Thinking", agent.resolved.thinking ?? "off"),
                    ("Prompt Mode", agent.resolved.systemPromptMode ?? "—"),
                    ("Inherit Project Context", display(agent.resolved.inheritProjectContext)),
                    ("Inherit Skills", display(agent.resolved.inheritSkills)),
                    ("Disabled", display(agent.resolved.disabled)),
                    ("Output", agent.resolved.output ?? "—"),
                    ("Default Reads", agent.resolved.defaultReads?.joined(separator: ", ") ?? "—"),
                    ("Default Progress", display(agent.resolved.defaultProgress)),
                    ("Interactive", display(agent.resolved.interactive)),
                    ("Max Subagent Depth", agent.resolved.maxSubagentDepth.map(String.init) ?? "—")
                ])
            }

            AppCard(title: "What These Fields Mean") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("• Prompt mode: `replace` makes a focused specialist. `append` keeps more of Pi’s normal base behavior and adds this agent on top.")
                    Text("• Inherit Project Context: keeps Pi’s project-context prompt section, including AGENTS.md / CLAUDE.md style instructions. It does not copy the full parent session history.")
                    Text("• Inherit Skills: keeps Pi’s discovered skills section in the child prompt when those skills are in scope.")
                    Text("• Max Subagent Depth: limits how many more child delegations this agent can create below itself.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var promptTab: some View {
        VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
            AppCard(title: resolvedPromptDiffers ? "Resolved Prompt" : "Prompt") {
                MarkdownDocumentView(source: agent.resolved.systemPrompt)
            }

            if resolvedPromptDiffers {
                AppCard(title: "Raw Source Prompt") {
                    MarkdownDocumentView(source: agent.winningRecord?.promptBody ?? "")
                }
            }
        }
    }

    private var toolsTab: some View {
        VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
            AppCard(title: "Tools & Extensions") {
                VStack(alignment: .leading, spacing: 16) {
                    AppKeyValueList(rows: [
                        ("Extensions", extensionsSummary),
                        ("Output File", agent.resolved.output ?? "—"),
                        ("Default Reads", agent.resolved.defaultReads?.joined(separator: ", ") ?? "—")
                    ])

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
                        Text("Inherited or unspecified")
                            .foregroundStyle(AppTheme.mutedText)
                    }
                }
            }

            AppCard(title: "How Tool Access Works") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("• If `tools` is omitted, the child gets Pi’s normal default built-in tools.")
                    Text("• If `tools` is set, it acts like an allowlist for regular tool names.")
                    Text("• `mcp:name` entries are separate direct MCP tools and only make sense when that MCP server exists in config.")
                    Text("• `output` and `defaultReads` mostly matter when this agent is used inside managed runs such as chains or parallel workflows.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var skillsTab: some View {
        VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
            AppCard(title: "Skills") {
                VStack(alignment: .leading, spacing: 16) {
                    AppKeyValueList(rows: [
                        ("Inherit Skills", display(agent.resolved.inheritSkills)),
                        ("Explicit Skill Count", "\(agent.resolved.skills.count)")
                    ])

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

    private var resolutionTab: some View {
        VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
            AppCard(title: "Resolution") {
                AppKeyValueList(rows: [
                    ("Builtin Base", agent.builtin.map { sourceSummary(label: "Builtin", path: $0.filePath) } ?? "—"),
                    ("User Override", agent.userOverride.map { sourceSummary(label: "Override", path: $0.settingsPath) } ?? "—"),
                    ("Project Override", agent.projectOverride.map { sourceSummary(label: "Override", path: $0.settingsPath) } ?? "—"),
                    ("Global Custom", agent.globalCustom.map { sourceSummary(label: "Markdown", path: $0.filePath) } ?? "—"),
                    ("Project Custom", agent.projectCustom.map { sourceSummary(label: "Markdown", path: $0.filePath) } ?? "—"),
                    ("Override Status", overrideStatus),
                    ("Project", agent.projectRoot.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "—"),
                    ("Winning Source", sourceSummary(label: resolutionSourceKind, path: agent.sourcePath))
                ])
            }

            AppCard(title: "Precedence") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(precedenceExplanation)
                    Text("Builtins are lowest priority. User markdown agents replace builtins. Project markdown agents replace user and builtin agents. Builtin overrides only patch builtins; they do not patch custom markdown replacements.")
                        .foregroundStyle(AppTheme.mutedText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }

            if showsComparison {
                AppCard(title: "Compare Base vs Effective") {
                    HStack(alignment: .top, spacing: 16) {
                        compareColumn(title: comparisonLeftTitle, body: comparisonLeftBody)
                        compareColumn(title: comparisonRightTitle, body: comparisonRightBody)
                    }
                }
            }

            if let overrideValues = activeOverrideValues {
                AppCard(title: "Active Override Patch") {
                    Text(prettyJSONObject(overrideValues))
                        .font(.footnote.monospaced())
                        .foregroundStyle(AppTheme.mutedText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var sourceFilesTab: some View {
        AppCard(title: "Source Files") {
            VStack(alignment: .leading, spacing: 16) {
                AppKeyValueList(rows: [
                    ("Builtin File", agent.builtin?.filePath ?? "—"),
                    ("Global File", agent.globalCustom?.filePath ?? "—"),
                    ("Project File", agent.projectCustom?.filePath ?? "—"),
                    ("User Override", agent.userOverride?.settingsPath ?? "—"),
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

    private var showsComparison: Bool {
        comparisonLeftBody != comparisonRightBody
    }

    private var comparisonLeftTitle: String {
        agent.builtin != nil ? "Builtin Base" : "Winning Source"
    }

    private var comparisonRightTitle: String {
        "Effective Resolved"
    }

    private var comparisonLeftBody: String {
        if let builtin = agent.builtin {
            return comparisonText(for: builtin.parsed)
        }
        if let winning = agent.winningRecord {
            return comparisonText(for: winning.parsed)
        }
        return "—"
    }

    private var comparisonRightBody: String {
        comparisonText(for: agent.resolved)
    }

    private var hasOverride: Bool {
        agent.userOverride != nil || agent.projectOverride != nil
    }

    private var primarySourcePath: String? {
        agent.sourcePath ?? agent.projectOverride?.settingsPath ?? agent.userOverride?.settingsPath
    }

    private var writeTargetSummary: String {
        if agent.builtin != nil, agent.globalCustom == nil, agent.projectCustom == nil {
            return hasOverride ? (agent.projectOverride?.settingsPath ?? agent.userOverride?.settingsPath ?? "Pi settings override") : "Pi settings override (choose global or project on edit)"
        }
        return agent.sourcePath ?? "—"
    }

    private var extensionsSummary: String {
        guard let extensions = agent.resolved.extensions else { return "Inherited/default" }
        return extensions.isEmpty ? "None" : extensions.joined(separator: ", ")
    }

    private var overrideStatus: String {
        if let projectOverride = agent.projectOverride {
            return "Project · \(projectOverride.settingsPath)"
        }
        if let userOverride = agent.userOverride {
            return "Global · \(userOverride.settingsPath)"
        }
        return "Not enabled"
    }

    private var activeOverrideValues: [String: Any]? {
        agent.projectOverride?.values ?? agent.userOverride?.values
    }

    private var resolutionSourceKind: String {
        switch agent.resolutionKind {
        case .builtin, .builtinWithOverride:
            return "Builtin"
        case .globalReplacement, .projectReplacement:
            return "Markdown"
        }
    }

    private var precedenceExplanation: String {
        if agent.projectCustom != nil {
            return "This project markdown agent wins over any global custom agent, builtin base, or builtin override."
        }
        if agent.globalCustom != nil {
            return "This global markdown agent wins over the builtin base and any builtin overrides because a custom markdown file replaces the builtin definition."
        }
        if agent.projectOverride != nil {
            return "The builtin base is active, then the project override patch is applied. Project overrides take precedence over user overrides."
        }
        if agent.userOverride != nil {
            return "The builtin base is active, then the user override patch from settings is applied."
        }
        return "No custom replacement or override is active, so Pi uses the builtin definition directly."
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

    private func sourceSummary(label: String, path: String?) -> String {
        guard let path else { return "—" }
        return "\(label) · \(path)"
    }

    @ViewBuilder
    private func compareColumn(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .fontWidth(.expanded)
            Text(body)
                .font(.footnote.monospaced())
                .foregroundStyle(AppTheme.mutedText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func comparisonText(for config: AgentConfig) -> String {
        var lines: [String] = []
        lines.append("description: \(config.description)")
        lines.append("model: \(config.model ?? "default")")
        lines.append("fallbackModels: \(config.fallbackModels.isEmpty ? "—" : config.fallbackModels.joined(separator: ", "))")
        lines.append("thinking: \(config.thinking ?? "off")")
        lines.append("systemPromptMode: \(config.systemPromptMode ?? "—")")
        lines.append("inheritProjectContext: \(display(config.inheritProjectContext))")
        lines.append("inheritSkills: \(display(config.inheritSkills))")
        lines.append("disabled: \(display(config.disabled))")
        lines.append("tools: \(((config.tools ?? []) + (config.mcpDirectTools ?? []).map { "mcp:\($0)" }).nonEmptyJoined)")
        lines.append("extensions: \((config.extensions ?? []).nonEmptyJoined)")
        lines.append("skills: \(config.skills.nonEmptyJoined)")
        lines.append("output: \(config.output ?? "—")")
        lines.append("defaultReads: \((config.defaultReads ?? []).nonEmptyJoined)")
        lines.append("defaultProgress: \(display(config.defaultProgress))")
        lines.append("interactive: \(display(config.interactive))")
        lines.append("maxSubagentDepth: \(config.maxSubagentDepth.map(String.init) ?? "—")")
        return lines.joined(separator: "\n")
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

private struct ChainsScreen: View {
    @ObservedObject var viewModel: AppViewModel
    let onCreateChain: (AgentEditingTarget.CustomAgentScope) -> Void
    let onDuplicateChain: (ChainRecord, AgentEditingTarget.CustomAgentScope) -> Void
    let onEditChain: (ChainRecord) -> Void

    var body: some View {
        HSplitView {
            AppSidebarPane(title: "Chains", subtitle: "\(viewModel.snapshot.chains.count) total") {
                List(viewModel.snapshot.chains, selection: $viewModel.selectedChainID) { chain in
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
                        }
                    } label: {
                        Label("New", systemImage: "plus")
                    }
                }
            }
            .frame(minWidth: 320, idealWidth: 380, maxWidth: 460)

            if let chain = viewModel.selectedChain {
                AppPage(chain.name, subtitle: chain.description.nonEmpty) {
                    AppCard(trailing: {
                        HStack(spacing: 10) {
                            Menu("Actions") {
                                Button("Open Raw File") { openFile(chain.filePath) }
                                Button("Reveal in Finder") { revealInFinder(chain.filePath) }
                                Divider()
                                Button("Duplicate as Global Chain") {
                                    onDuplicateChain(chain, .global)
                                }
                                if viewModel.selectedProjectPath != nil {
                                    Button("Duplicate as Project Chain") {
                                        onDuplicateChain(chain, .project)
                                    }
                                }
                            }
                            Button("Edit Chain") {
                                onEditChain(chain)
                            }
                        }
                    }) {
                        Text("Chains are saved back as .chain.md files, matching pi-subagents chain serialization.")
                            .foregroundStyle(AppTheme.mutedText)
                    }

                    AppCard(title: "How Chains Work") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("• Each step runs in order and later steps can use earlier output.")
                            Text("• Step `output`, `reads`, `skills`, `model`, and `progress` override the agent’s defaults for that step.")
                            Text("• `reads: false`, `skills: false`, or `output: false` explicitly turn that behavior off for the step.")
                            Text("• Relative read/write paths are resolved from the chain working directory.")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    AppCard(title: "Source") {
                        AppKeyValueList(rows: [
                            ("Scope", chain.source.kind.rawValue),
                            ("Path", chain.filePath),
                            ("Steps", "\(chain.steps.count)")
                        ])
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
    }

    private func openFile(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

private struct SkillsScreen: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        HSplitView {
            AppSidebarPane(title: "Skills", subtitle: "\(viewModel.snapshot.skills.count) total") {
                List(viewModel.snapshot.skills, selection: $viewModel.selectedSkillID) { skill in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top) {
                            Text(skill.name)
                                .font(.headline)
                                .fontWidth(.expanded)
                                .lineLimit(2)
                            Spacer(minLength: 8)
                            AppLabelTag(
                                text: skillScopeLabel(skill, selectedProjectRoot: viewModel.snapshot.projectRoot),
                                color: skill.source.kind == .project ? .green : .blue
                            )
                        }
                        Text(skill.description ?? "No description")
                            .foregroundStyle(AppTheme.mutedText)
                            .lineLimit(2)
                        Text(skillLocationLabel(skill, selectedProjectRoot: viewModel.snapshot.projectRoot))
                            .font(.caption)
                            .foregroundStyle(AppTheme.mutedText)
                            .lineLimit(1)
                    }
                    .padding(.vertical, 6)
                    .tag(skill.id)
                }
                .listStyle(.inset)
            }
            .frame(minWidth: 320, idealWidth: 380, maxWidth: 460)

            if let skill = viewModel.selectedSkill {
                AppPage(skill.name, subtitle: skill.description) {
                    AppCard(trailing: {
                        Menu("Actions") {
                            Button("Open Raw File") { openFile(skill.filePath) }
                            Button("Reveal in Finder") { revealInFinder(skill.filePath) }
                            Button("Copy Skill Name") { copyToPasteboard(skill.name) }
                            Button("Copy Skill Path") { copyToPasteboard(skill.filePath) }
                        }
                    }) {
                        Text("Skills are markdown-backed resources. Project skills are only visible inside their project; global skills are visible everywhere.")
                            .foregroundStyle(AppTheme.mutedText)
                    }

                    AppCard(title: "Location") {
                        AppKeyValueList(rows: [
                            ("Scope", skillScopeLabel(skill, selectedProjectRoot: viewModel.snapshot.projectRoot)),
                            ("Project", skillProjectLabel(skill, selectedProjectRoot: viewModel.snapshot.projectRoot) ?? "—"),
                            ("Path", skill.filePath)
                        ])
                    }

                    AppCard(title: "Usage") {
                        let explicitAgents = viewModel.agentsExplicitlyUsingSkill(skill)
                        let ambientAgents = viewModel.agentsAmbientlySeeingSkill(skill)

                        VStack(alignment: .leading, spacing: 16) {
                            AppKeyValueList(rows: [
                                ("Explicit Assignments", "\(explicitAgents.count)"),
                                ("Ambiently Visible", "\(ambientAgents.count)"),
                                ("Used By Any Visible Agent", explicitAgents.isEmpty ? "No" : "Yes")
                            ])

                            VStack(alignment: .leading, spacing: 10) {
                                Text("Explicitly Assigned")
                                    .font(.headline)
                                    .fontWidth(.expanded)
                                if explicitAgents.isEmpty {
                                    Text("No visible agents explicitly assign this skill.")
                                        .foregroundStyle(AppTheme.mutedText)
                                } else {
                                    ForEach(explicitAgents) { agent in
                                        AppRowCard {
                                            VStack(alignment: .leading, spacing: 6) {
                                                Text(agent.name)
                                                    .font(.headline)
                                                    .fontWidth(.expanded)
                                                Text(agent.resolved.description.isEmpty ? resolutionUsageLabel(agent) : agent.resolved.description)
                                                    .foregroundStyle(AppTheme.mutedText)
                                                    .lineLimit(2)
                                            }
                                        }
                                    }
                                }
                            }

                            VStack(alignment: .leading, spacing: 10) {
                                Text("Ambiently Visible via inheritSkills")
                                    .font(.headline)
                                    .fontWidth(.expanded)
                                if ambientAgents.isEmpty {
                                    Text("No visible agents currently inherit this skill ambiently.")
                                        .foregroundStyle(AppTheme.mutedText)
                                } else {
                                    ForEach(ambientAgents) { agent in
                                        AppRowCard {
                                            VStack(alignment: .leading, spacing: 6) {
                                                Text(agent.name)
                                                    .font(.headline)
                                                    .fontWidth(.expanded)
                                                Text(resolutionUsageLabel(agent))
                                                    .foregroundStyle(AppTheme.mutedText)
                                                    .lineLimit(2)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    AppCard(title: "Definition") {
                        MarkdownDocumentView(source: skill.body, minimumHeight: 24)
                    }
                }
            } else {
                ContentUnavailableView("No Skill Selected", systemImage: "wand.and.stars")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct EnvironmentScreen: View {
    let snapshot: ScanSnapshot
    let onNewGlobalKey: () -> Void
    let onNewProjectKey: (() -> Void)?
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
            AppCard(trailing: {
                HStack(spacing: 10) {
                    Button("New Global Key", action: onNewGlobalKey)
                    if let onNewProjectKey {
                        Button("New Project Key", action: onNewProjectKey)
                    }
                }
            }) {
                Text("You can reveal, copy, and edit environment keys directly here. Project keys override global keys when both define the same name.")
                    .foregroundStyle(AppTheme.mutedText)
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

                                    ScrollView(.horizontal) {
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
        AppPage("MCP", subtitle: "Configured MCP files, detected servers, and likely agent impact") {
            AppCard(title: "How MCP Access Works") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("• MCP config files only declare available servers.")
                    Text("• That does not automatically give every agent MCP access.")
                    Text("• Direct `mcp:name` tools only make sense when a matching server exists in config.")
                    Text("• So the important question is: which servers exist, and which agents actually reference them?")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            AppCard(title: "Summary") {
                AppKeyValueList(rows: [
                    ("Config Files", "\(snapshot.mcpConfigs.count)"),
                    ("Configured Servers", "\(allServers.count)"),
                    ("Agents Using Direct MCP Tools", "\(agentsUsingDirectMCP.count)"),
                    ("Direct MCP Tool Names", directToolSummary)
                ])
            }

            AppCard(title: "How MCP Affects Agents") {
                Text("MCP access is not automatic. MCP config files declare available servers, but agents still need matching frontmatter configuration such as direct `mcp:` tool entries or other enabled tools/extensions before that access matters.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if snapshot.mcpConfigs.isEmpty {
                AppCard {
                    Text("No MCP config files found.")
                        .foregroundStyle(AppTheme.mutedText)
                }
            } else {
                ForEach(snapshot.mcpConfigs) { config in
                    AppCard(title: config.path, trailing: {
                        HStack(spacing: 10) {
                            Button("Open") { openFile(config.path) }
                            Button("Reveal") { revealInFinder(config.path) }
                            Text("\(config.serverNames.count) servers")
                                .foregroundStyle(AppTheme.mutedText)
                        }
                    }) {
                        VStack(alignment: .leading, spacing: 12) {
                            AppKeyValueList(rows: [
                                ("Scope", config.source.kind.rawValue),
                                ("Project", projectName(from: config.path) ?? "—"),
                                ("Likely Used By Direct MCP Tools", likelyUsedServersSummary(for: config))
                            ])

                            Divider()

                            if config.serverNames.isEmpty {
                                Text("No servers detected.")
                                    .foregroundStyle(AppTheme.mutedText)
                            } else {
                                VStack(alignment: .leading, spacing: 10) {
                                    ForEach(config.serverNames, id: \.self) { server in
                                        HStack(spacing: 10) {
                                            Image(systemName: "server.rack")
                                                .foregroundStyle(.purple)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(server)
                                                Text(serverUsageSummary(server, config: config))
                                                    .font(.caption)
                                                    .foregroundStyle(AppTheme.mutedText)
                                            }
                                        }
                                    }
                                }
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
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(agentsUsingDirectMCP) { agent in
                            AppRowCard {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(agent.name)
                                        .font(.headline)
                                        .fontWidth(.expanded)
                                    Text((agent.resolved.mcpDirectTools ?? []).map { "mcp:\($0)" }.joined(separator: ", "))
                                        .font(.footnote.monospaced())
                                        .foregroundStyle(AppTheme.mutedText)
                                }
                            }
                        }
                    }
                }
            }
        }
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
        AppPage("Diagnostics", subtitle: "Parsed settings, overrides, and warnings") {
            AppCard(title: "What You Are Looking At") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("• This screen explains what Pi parsed from settings files, not what you hoped it would parse.")
                    Text("• Builtin overrides come from settings JSON patches, not markdown files.")
                    Text("• Warnings here are useful mismatches or suspicious setup details worth checking.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            ForEach(snapshot.settings, id: \.path) { settings in
                AppCard(title: settings.path) {
                    VStack(alignment: .leading, spacing: 16) {
                        AppKeyValueList(rows: [
                            ("Disable Builtins", boolLabel(settings.disableBuiltins)),
                            ("Override Count", "\(settings.agentOverrides.count)")
                        ])

                        VStack(alignment: .leading, spacing: 10) {
                            Text("Packages")
                                .font(.headline)
                                .fontWidth(.expanded)
                            if settings.packages.isEmpty {
                                Text("None")
                                    .foregroundStyle(AppTheme.mutedText)
                            } else {
                                ForEach(settings.packages, id: \.self) { package in
                                    HStack(spacing: 10) {
                                        Image(systemName: "shippingbox")
                                            .foregroundStyle(AppTheme.mutedText)
                                        Text(package)
                                            .textSelection(.enabled)
                                    }
                                }
                            }
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 10) {
                            Text("Builtin Overrides")
                                .font(.headline)
                                .fontWidth(.expanded)
                            if settings.agentOverrides.isEmpty {
                                Text("None")
                                    .foregroundStyle(AppTheme.mutedText)
                            } else {
                                ForEach(settings.agentOverrides, id: \.agentName) { override in
                                    AppRowCard {
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(override.agentName)
                                                .font(.headline)
                                                .fontWidth(.expanded)
                                            Text(prettyJSONObject(override.values))
                                                .font(.footnote.monospaced())
                                                .foregroundStyle(AppTheme.mutedText)
                                                .textSelection(.enabled)
                                        }
                                    }
                                }
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
                        warningSection(title: "Duplicate / Resolution", warnings: snapshot.warnings.filter { $0.message.contains("Duplicate agent") })
                        warningSection(title: "Malformed Files", warnings: snapshot.warnings.filter { $0.message.contains("Malformed") || $0.message.contains("step block") })
                        warningSection(title: "Missing Skills / Env", warnings: snapshot.warnings.filter { $0.message.contains("missing skill") || $0.message.contains("API key") })
                        warningSection(title: "Capability Mismatches", warnings: snapshot.warnings.filter { $0.message.contains("extensions") })
                        warningSection(title: "Chain References", warnings: snapshot.warnings.filter { $0.message.contains("Chain ") && $0.message.contains("missing agent") })
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

private func skillLocationLabel(_ skill: SkillRecord, selectedProjectRoot: String?) -> String {
    if let project = skillProjectLabel(skill, selectedProjectRoot: selectedProjectRoot) {
        return project
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

            ScrollView {
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
                                .help("Set the primary model used by this subagent. Values come from `pi --list-models`, and the saved frontmatter should usually use `provider/model`.")
                            Menu("Choose Model") {
                                modelPickerMenu { model in
                                    draft.config.model = model.identifier
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
                            TextField("Thinking", text: binding(for: \ .thinking))
                                .help("Reasoning effort hint passed to Pi, typically off/minimal/low/medium/high/xhigh depending on provider support.")
                            TextField("Prompt Mode", text: binding(for: \ .systemPromptMode))
                                .help("`replace` makes a focused specialist. `append` keeps more of Pi’s normal behavior and adds your instructions on top.")
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
        return "\(model.model) · \(thinking) · ctx \(model.contextWindow)"
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
