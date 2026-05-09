import AppKit
import SwiftUI

struct AgentsScreen: View {
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
                    availableModels: viewModel.enabledAvailableModels,
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
        List(selection: $viewModel.selectedAgentID) {
            if viewModel.selectedDiscoveredProject != nil {
                appListSection("Active") {
                    if activeCustomAgents.isEmpty {
                        nativeEmptyRow("No custom agents are active for this project.")
                    }
                    ForEach(activeCustomAgents) { agent in
                        agentListRow(agent, inactive: false)
                            .tag(agent.id)
                    }
                }

                if !libraryAgents.isEmpty {
                    appListSection("Library Agents", info: "Library agents are centrally stored and only become active when assigned to this project or enabled globally.") {
                        ForEach(libraryAgents) { agent in
                            agentListRow(agent, inactive: true)
                                .tag(agent.id)
                        }
                    }
                }
            } else {
                appListSection("Global Agents", info: "Select a project to see exactly which custom agents are active there and to manage project assignment.") {
                    if globalCustomAgents.isEmpty {
                        nativeEmptyRow("No global custom agents.")
                    }
                    ForEach(globalCustomAgents) { agent in
                        agentListRow(agent, inactive: false)
                            .tag(agent.id)
                    }
                }

                if !libraryAgents.isEmpty {
                    appListSection("Library Agents") {
                        ForEach(libraryAgents) { agent in
                            agentListRow(agent, inactive: false)
                                .tag(agent.id)
                        }
                    }
                }
            }

            appListSection("Builtin Agents", info: "Builtins are bundled with \(AppBrand.displayName) and customized through settings overrides or replacement files.") {
                if builtinAgents.isEmpty {
                    nativeEmptyRow("No builtin agents discovered.")
                }
                ForEach(builtinAgents) { agent in
                    agentListRow(agent, inactive: false)
                        .tag(agent.id)
                }
            }
        }
        .appResourceListStyle()
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
            agent.resolutionKind == .library
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

    private func agentListRow(_ agent: EffectiveAgentRecord, inactive: Bool) -> some View {
        let warnings = viewModel.warnings(for: agent)
        let skillIssues = viewModel.explicitSkillVisibilityIssues(for: agent)
        let hasWarningDetails = !warnings.isEmpty || !skillIssues.isEmpty
        let isMuted = inactive || agent.resolved.disabled == true || agentIsUnusedLibraryAgent(agent)

        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon(for: agent))
                .foregroundStyle(color(for: agent))
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(agent.name)
                        .font(.headline)
                        .fontWidth(.expanded)
                        .foregroundStyle(.primary)
                        .strikethrough(agent.resolved.disabled == true, color: AppTheme.mutedText)
                        .lineLimit(1)

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
        .padding(.vertical, 6)
        .opacity(isMuted ? 0.62 : 1)
        .saturation(isMuted ? 0.25 : 1)
        .badge(statusLabel(agent))
    }

    private func nativeEmptyRow(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(AppTheme.mutedText)
            .padding(.vertical, 4)
            .selectionDisabled()
            .listRowSeparator(.hidden)
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

    private func agentIsUnusedLibraryAgent(_ agent: EffectiveAgentRecord) -> Bool {
        guard agent.resolutionKind == .library,
              let record = viewModel.snapshot.libraryAgents.first(where: { $0.name == agent.name }) else {
            return false
        }
        return !viewModel.agentIsEnabledGlobally(record) && viewModel.assignedProjects(for: record).isEmpty
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
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(selectedTab == tab ? AppTheme.selectionFill : AppTheme.contentSubtleFill)
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
            Task { @MainActor in
                await Task.yield()
                toggleEditMode()
            }
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
                            AppLabelTag(text: agent.resolutionKind.rawValue, color: AppTheme.assistantAccent)
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
                        let visibilityIssues = skillVisibilityIssues(agent)
                        let visibilityIssuesByProjectID = Dictionary(uniqueKeysWithValues: visibilityIssues.map { ($0.project.id, $0) })
                        let assignedProjectIDs = Set(assignedAgentProjects(managedAgent).map(\.id))

                        Text("Check each project that should load this agent. Assigning to a project removes managed global visibility, like Skills.")
                            .foregroundStyle(AppTheme.mutedText)
                        if !visibilityIssues.isEmpty {
                            skillVisibilityWarningBlock(visibilityIssues)
                        }
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(projects) { project in
                                let projectIssue = visibilityIssuesByProjectID[project.id]
                                ProjectAssignmentToggleRow(
                                    project: project,
                                    isOn: Binding(
                                        get: { assignedProjectIDs.contains(project.id) },
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
        selectedInlineModel?.supportedThinkingLevels ?? []
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
            return "Choose from installed Pi package references already visible to \(AppBrand.displayName)."
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

struct SaveConfirmation: Identifiable {
    let id = UUID()
    let summary: String
    let exitEditMode: Bool
}
