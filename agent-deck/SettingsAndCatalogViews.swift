import AppKit
import SwiftUI

struct ModelsScreen: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        AppPage("Models", subtitle: "Available Pi models and local automation models") {
            if displayModels.isEmpty {
                AppCard(title: "Catalog") {
                    HStack {
                        Text("No models loaded yet. Use Refresh to query Pi.")
                            .foregroundStyle(AppTheme.mutedText)
                        Spacer()
                        Button("Refresh") {
                            viewModel.refreshModels()
                        }
                    }
                }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text("Pi’s model catalog, grouped by provider. Apple Foundation Model is local and can be used for Automations in Settings.")
                        .foregroundStyle(AppTheme.mutedText)
                    Spacer()
                    Button("Refresh") {
                        viewModel.refreshModels()
                    }
                }

                VStack(alignment: .leading, spacing: 20) {
                    if !viewModel.availableModels.isEmpty {
                        defaultSelectionSection
                    }
                    ForEach(groupedModels, id: \.provider) { group in
                        providerSection(group)
                    }
                }
            }
        }
        .onAppear {
            viewModel.ensureAvailableModelsLoaded()
        }
    }

    private func providerSection(_ group: (provider: String, models: [AvailableModel])) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                ProviderLabel(provider: group.provider, logoSize: 22, spacing: 8)
                    .font(.title3.weight(.bold))
                    .fontWidth(.expanded)
                    .foregroundStyle(.primary)
                Spacer()
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
                    .fill(AppTheme.contentFill)
                    .stroke(AppTheme.contentStroke, lineWidth: 1)
            )
        }
    }

    private var defaultSelectionSection: some View {
        AppCard(title: "Pi Agent Defaults") {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 12) {
                GridRow {
                    Text("Default model")
                        .foregroundStyle(AppTheme.mutedText)
                    Picker("Default model", selection: defaultModelBinding) {
                        ForEach(viewModel.enabledAvailableModels, id: \.identifier) { model in
                            Text(model.identifier).tag(model.identifier)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 360)
                }

                GridRow {
                    Text("Default thinking")
                        .foregroundStyle(AppTheme.mutedText)
                    Picker("Default thinking", selection: defaultThinkingBinding) {
                        ForEach(defaultThinkingLevels, id: \.self) { level in
                            Text(level.capitalized).tag(level)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                }
            }
        }
    }

    private var defaultModelBinding: Binding<String> {
        Binding(
            get: {
                viewModel.defaultPiAgentModel()?.identifier ?? viewModel.enabledAvailableModels.first?.identifier ?? ""
            },
            set: { identifier in
                let model = viewModel.enabledAvailableModels.first { $0.identifier == identifier }
                viewModel.setDefaultPiAgentModel(model)
            }
        )
    }

    private var defaultThinkingBinding: Binding<String> {
        Binding(
            get: {
                let current = viewModel.piRuntimeDefaultThinkingLevel()
                return defaultThinkingLevels.contains(current) ? current : "medium"
            },
            set: { viewModel.setDefaultPiAgentThinkingLevel($0) }
        )
    }

    private var defaultThinkingLevels: [String] {
        viewModel.enabledAvailableModels.flatMap(\.supportedThinkingLevels).reduce(into: []) { levels, level in
            if !levels.contains(level) { levels.append(level) }
        }
    }

    private func modelRow(_ model: AvailableModel) -> some View {
        let isEnabled = viewModel.isModelEnabled(model)
        return HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: Binding(
                get: { viewModel.isModelEnabled(model) },
                set: { viewModel.setModelEnabled(model, isEnabled: $0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 8) {
                    Text(model.modelDisplayName)
                        .font(.headline)
                        .fontWidth(.expanded)
                        .foregroundStyle(isEnabled ? .primary : AppTheme.mutedText)
                }
                Text(model.identifier)
                    .font(.footnote.monospaced())
                    .foregroundStyle(AppTheme.mutedText)
                    .textSelection(.enabled)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 8) {
                    if FoundationModelAutomationService.isFoundationModel(model) {
                        AppLabelTag(text: "Local", color: .green)
                        AppLabelTag(text: "Automation Only", color: AppTheme.brandAccent)
                    }
                    AppLabelTag(text: model.supportsThinking ? "Thinking" : "No Thinking", color: model.supportsThinking ? .green : .secondary)
                    AppLabelTag(text: model.supportsImages ? "Images" : "Text Only", color: model.supportsImages ? .purple : .secondary)
                    if PiNativeSubagentBridgeExtensions.isOpenAIFastEligibleModel(provider: model.provider, modelID: model.model) {
                        fastModeTagButton(for: model, isModelEnabled: isEnabled)
                    }
                }
                Text("ctx \(model.contextWindow) · out \(model.maxOutput)")
                    .font(.footnote.monospaced())
                    .foregroundStyle(AppTheme.mutedText)
            }
        }
        .opacity(isEnabled ? 1 : 0.55)
        .padding(.vertical, 10)
    }

    private func fastModeTagButton(for model: AvailableModel, isModelEnabled: Bool) -> some View {
        let isFastEnabled = viewModel.isOpenAIFastModeEnabled(model)
        return Button {
            viewModel.setOpenAIFastMode(model, isEnabled: !isFastEnabled)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isFastEnabled ? "checkmark.square.fill" : "square")
                    .font(.caption.weight(.semibold))
                    .contentTransition(.symbolEffect(.replace))
                Text("Fast")
                    .font(.caption.weight(.semibold))
                    .fontWidth(.expanded)
            }
            .foregroundStyle(isFastEnabled ? AppTheme.brandAccent : AppTheme.mutedText)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background((isFastEnabled ? AppTheme.brandAccent : Color.secondary).opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isModelEnabled)
        .help("Use OpenAI priority service tier for this ChatGPT-auth Codex model in parent sessions and native subagents.")
        .animation(.snappy(duration: 0.18), value: isFastEnabled)
    }

    private var displayModels: [AvailableModel] {
        var models = viewModel.availableModels
        if let foundationModel = viewModel.foundationAutomationModel,
           !models.contains(where: { $0.identifier == foundationModel.identifier }) {
            models.insert(foundationModel, at: 0)
        }
        return models
    }

    private var groupedModels: [(provider: String, models: [AvailableModel])] {
        Dictionary(grouping: displayModels, by: \.provider)
            .map { provider, models in
                (provider, models.sorted { $0.model.localizedCaseInsensitiveCompare($1.model) == .orderedAscending })
            }
            .sorted { lhs, rhs in
                if lhs.provider == FoundationModelAutomationService.provider { return true }
                if rhs.provider == FoundationModelAutomationService.provider { return false }
                return lhs.provider.localizedCaseInsensitiveCompare(rhs.provider) == .orderedAscending
            }
    }
}

struct SubagentsScreen: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        AppPage("Subagents", subtitle: "Native app-managed delegation and supervision") {
            nativeRuntimeCard
            sessionDefaultsCard
            availableAgentsCard
            safetyCard
        }
    }

    private var nativeRuntimeCard: some View {
        AppCard(title: "Native Runtime") {
            VStack(alignment: .leading, spacing: 10) {
                Text("• \(AppBrand.displayName) launches child Pi sessions itself and keeps parent, child, transcript, artifact, and supervisor state in the app.")
                Text("• Parent sessions receive app-provided managed tools for single and parallel delegation.")
                Text("• Child sessions can contact the supervisor through \(AppBrand.displayName)'s native request cards.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var sessionDefaultsCard: some View {
        AppCard(title: "Session Defaults") {
            AppKeyValueList(rows: [
                ("New Sessions", viewModel.areSubagentsEnabledForNewSessions ? "Native subagents enabled" : "Native subagents disabled"),
                ("Selected Session", selectedSessionStatus),
                ("Available Agents", "\(viewModel.snapshot.effectiveAgents.filter { $0.resolved.disabled != true }.count)")
            ])
        }
    }

    private var availableAgentsCard: some View {
        AppCard(title: "Available Native Agents") {
            VStack(alignment: .leading, spacing: 10) {
                let agents = viewModel.snapshot.effectiveAgents
                    .filter { $0.resolved.disabled != true }
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                if agents.isEmpty {
                    Text("No enabled agents are available in the current scope.")
                        .foregroundStyle(AppTheme.mutedText)
                } else {
                    ForEach(agents.prefix(12)) { agent in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: "rectangle.connected.to.line.below")
                                .foregroundStyle(AppTheme.mutedText)
                                .frame(width: 18)
                            Text(agent.name)
                                .font(.body.weight(.semibold))
                            Text(agent.resolved.description.isEmpty ? "No description" : agent.resolved.description)
                                .foregroundStyle(AppTheme.mutedText)
                                .lineLimit(1)
                        }
                    }

                    if agents.count > 12 {
                        Text("\(agents.count - 12) more agents are available from the run picker.")
                            .font(.caption)
                            .foregroundStyle(AppTheme.mutedText)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var safetyCard: some View {
        AppCard(title: "Safety") {
            VStack(alignment: .leading, spacing: 10) {
                Text("• Writer-like native runs use isolated worktrees unless direct project writes are explicitly allowed.")
                Text("• Parent and child transcript state is persisted by \(AppBrand.displayName).")
                Text("• Supervisor questions stay scoped to the owning parent session and window.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var selectedSessionStatus: String {
        guard let session = viewModel.piAgentSessionStore.selectedSession else { return "No session selected" }
        return session.subagentsEnabled ? "Native subagents enabled" : "Native subagents disabled"
    }
}

struct AgentModelQuickEditorContext: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let sections: [AgentModelQuickEditorSection]
    let preferredOverrideScope: AgentEditingTarget.OverrideScope
}

struct AgentModelQuickEditorSection: Identifiable {
    let title: String
    let agents: [EffectiveAgentRecord]
    var isDimmed = false

    var id: String { title }
}

struct AgentModelQuickEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let context: AgentModelQuickEditorContext
    let availableModels: [AvailableModel]
    let modelsLastUpdatedAt: Date?
    let makeDraft: (EffectiveAgentRecord) -> AgentEditorDraft?
    let onSave: (AgentEditorDraft, EffectiveAgentRecord) throws -> Void

    @State private var drafts: [EffectiveAgentRecord.ID: AgentEditorDraft]
    @State private var baselines: [EffectiveAgentRecord.ID: AgentEditorDraft]
    @State private var saveMessage: String?

    init(
        context: AgentModelQuickEditorContext,
        availableModels: [AvailableModel],
        modelsLastUpdatedAt: Date?,
        makeDraft: @escaping (EffectiveAgentRecord) -> AgentEditorDraft?,
        onSave: @escaping (AgentEditorDraft, EffectiveAgentRecord) throws -> Void
    ) {
        self.context = context
        self.availableModels = availableModels
        self.modelsLastUpdatedAt = modelsLastUpdatedAt
        self.makeDraft = makeDraft
        self.onSave = onSave

        var seeded: [EffectiveAgentRecord.ID: AgentEditorDraft] = [:]
        for agent in context.sections.flatMap(\.agents) where seeded[agent.id] == nil {
            seeded[agent.id] = makeDraft(agent)
        }
        _drafts = State(initialValue: seeded)
        _baselines = State(initialValue: seeded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(context.title)
                        .font(.title2.bold())
                        .fontWidth(.expanded)
                    Text(context.subtitle)
                        .foregroundStyle(AppTheme.mutedText)
                    Text(modelSelectionSummary)
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedText)
                }
                Spacer()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
                    ForEach(context.sections) { section in
                        if !section.agents.isEmpty {
                            AgentModelQuickEditSectionView(
                                section: section,
                                availableModels: availableModels,
                                binding: binding(for:),
                                isDirty: isDirty
                            )
                        }
                    }
                }
            }

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Default model and thinking can be changed in Sidebar > Models.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedText)
                    if let saveMessage {
                        Text(saveMessage)
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button("Save All") {
                    saveAll()
                }
                .buttonStyle(.borderedProminent)
                .disabled(dirtyAgentIDs.isEmpty)
            }
        }
        .padding(AppTheme.pagePadding)
        .frame(minWidth: 900, minHeight: 560)
    }

    private var dirtyAgentIDs: [EffectiveAgentRecord.ID] {
        drafts.keys.filter(isDirty)
    }

    private func isDirty(_ id: EffectiveAgentRecord.ID) -> Bool {
        drafts[id] != baselines[id]
    }

    private func binding(for id: EffectiveAgentRecord.ID) -> Binding<AgentEditorDraft>? {
        guard let initial = drafts[id] else { return nil }
        return Binding(
            get: { drafts[id] ?? initial },
            set: { drafts[id] = $0 }
        )
    }

    private var modelSelectionSummary: String {
        let freshness = modelsLastUpdatedAt.map { date in
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            return " Refreshed \(formatter.localizedString(for: date, relativeTo: Date()))."
        } ?? ""
        return "Uses the same model list and thinking rules as the full editor. Thinking choices update automatically for the selected model.\(freshness)"
    }

    private func saveAll() {
        var savedCount = 0
        for section in context.sections {
            for agent in section.agents where isDirty(agent.id) {
                guard let draft = drafts[agent.id] else { continue }
                do {
                    try onSave(draft, agent)
                    baselines[agent.id] = draft
                    savedCount += 1
                } catch {
                    NSSound.beep()
                    saveMessage = nil
                    return
                }
            }
        }

        saveMessage = savedCount == 1 ? "Saved 1 agent." : "Saved \(savedCount) agents."
    }
}

struct AgentModelQuickEditSectionView: View {
    let section: AgentModelQuickEditorSection
    let availableModels: [AvailableModel]
    let binding: (EffectiveAgentRecord.ID) -> Binding<AgentEditorDraft>?
    let isDirty: (EffectiveAgentRecord.ID) -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(section.title)
                    .font(.headline)
                    .fontWidth(.expanded)
                Spacer()
            }
            .padding(.horizontal, sectionContentInset)
            .padding(.top, sectionContentInset)
            .padding(.bottom, AppTheme.contentSpacing)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: AppTheme.contentSpacing) {
                    AgentModelColumnHeader("Agent")
                        .frame(minWidth: 220, maxWidth: .infinity, alignment: .leading)
                    AgentModelColumnHeader("Model")
                        .frame(minWidth: 320, maxWidth: .infinity, alignment: .leading)
                    AgentModelColumnHeader("Thinking")
                        .frame(width: 130, alignment: .leading)
                    AgentModelColumnHeader("")
                        .frame(width: 120, alignment: .trailing)
                }
                .padding(.bottom, AppTheme.contentSpacing / 2)

                Divider()

                ForEach(editableAgents) { agent in
                    if let draftBinding = binding(agent.id) {
                        AgentModelQuickEditRow(
                            agent: agent,
                            draft: draftBinding,
                            availableModels: availableModels,
                            isDirty: isDirty(agent.id)
                        )
                    }
                }
            }
            .padding(.horizontal, sectionContentInset)

            Spacer(minLength: sectionContentInset)
        }
        .opacity(section.isDimmed ? 0.58 : 1)
        .background(AppTheme.contentSubtleFill.opacity(section.isDimmed ? 0.10 : 0.18), in: RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius, style: .continuous)
                .stroke(AppTheme.contentStroke, lineWidth: 1)
        )
    }

    private var sectionContentInset: CGFloat { AppTheme.pagePadding }

    private var editableAgents: [EffectiveAgentRecord] {
        section.agents.filter { binding($0.id) != nil }
    }
}

private struct AgentModelColumnHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(AppTheme.mutedText)
    }
}

struct AgentModelQuickEditRow: View {
    let agent: EffectiveAgentRecord
    @Binding var draft: AgentEditorDraft
    let availableModels: [AvailableModel]
    let isDirty: Bool

    var body: some View {
        HStack(spacing: AppTheme.contentSpacing) {
            HStack(spacing: 8) {
                Text(agent.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                if isDirty {
                    AppLabelTag(text: "Unsaved", color: .orange)
                }
            }
            .frame(minWidth: 220, maxWidth: .infinity, alignment: .leading)

            Picker("Model", selection: modelSelectionBinding) {
                Text("Default").tag("")
                ForEach(availableModels, id: \.identifier) { model in
                    Text(model.identifier).tag(model.identifier)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(minWidth: 320, maxWidth: .infinity, alignment: .leading)
            .help(selectedModelMetadataSummary ?? "Use the default model from Sidebar > Models")

            Picker("Thinking", selection: thinkingSelectionBinding) {
                if usesDefaultModel {
                    Text("Default").tag(defaultThinkingSelection)
                } else {
                    ForEach(availableThinkingLevels, id: \.self) { level in
                        Text(level.capitalized).tag(level)
                    }
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 130, alignment: .leading)
            .disabled(usesDefaultModel || availableThinkingLevels.isEmpty)
            .help(usesDefaultModel ? "Select a specific model to override thinking for this agent" : "Override thinking for the selected model")

            Text(selectedModelMetadataSummary ?? "Default")
                .font(.caption.monospaced())
                .foregroundStyle(AppTheme.mutedText)
                .lineLimit(1)
                .frame(width: 120, alignment: .trailing)
        }
        .frame(minHeight: rowHeight)
        .background(rowHighlight)
    }

    private var rowHeight: CGFloat { 42 }

    @ViewBuilder
    private var rowHighlight: some View {
        if isDirty {
            Color.orange.opacity(0.08)
        } else {
            Color.clear
        }
    }

    private var usesDefaultModel: Bool {
        draft.config.model == nil
    }

    private var selectedModel: AvailableModel? {
        guard let identifier = draft.config.model else { return nil }
        return availableModels.first { $0.identifier == identifier }
    }

    private var selectedModelMetadataSummary: String? {
        guard let model = selectedModel else { return nil }
        return "context: \(model.contextWindow)"
    }

    private var defaultThinkingSelection: String { "__default__" }

    private var availableThinkingLevels: [String] {
        selectedModel?.supportedThinkingLevels ?? []
    }

    private var modelSelectionBinding: Binding<String> {
        Binding(
            get: { draft.config.model ?? "" },
            set: { newValue in
                draft.config.model = newValue.isEmpty ? nil : newValue
                clampThinkingSelection()
            }
        )
    }

    private var thinkingSelectionBinding: Binding<String> {
        Binding(
            get: {
                guard !usesDefaultModel else { return defaultThinkingSelection }
                let current = draft.config.thinking ?? "off"
                return availableThinkingLevels.contains(current) ? current : (availableThinkingLevels.first ?? "off")
            },
            set: { newValue in
                guard newValue != defaultThinkingSelection else { return }
                draft.config.thinking = newValue == "off" ? nil : newValue
            }
        )
    }

    private func clampThinkingSelection() {
        let current = draft.config.thinking ?? "off"
        guard !availableThinkingLevels.contains(current) else { return }
        let fallback = availableThinkingLevels.first ?? "off"
        draft.config.thinking = fallback == "off" ? nil : fallback
    }
}
