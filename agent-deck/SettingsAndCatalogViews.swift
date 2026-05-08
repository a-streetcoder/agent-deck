import AppKit
import SwiftUI

struct ExtensionsScreen: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        AppPage("Extensions", subtitle: "Choose which discovered extensions Agent Deck injects into managed sessions") {
            AppCard(title: "Safety") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Agent Deck stores these choices in app preferences. It does not modify Pi settings, extension files, package folders, or CLI/TUI behavior.")
                    Text("Changes affect new Pi sessions launched from Agent Deck. Existing app sessions need a new session.")
                        .foregroundStyle(AppTheme.mutedText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            let extensions = viewModel.visibleExtensions
            if extensions.isEmpty {
                ContentUnavailableView("No Extensions Found", systemImage: "puzzlepiece.extension", description: Text("Agent Deck did not find auto-discovered, settings, or package extensions for the current scope."))
            } else {
                VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
                    let packageExtensions = extensions.filter { $0.origin == .package }
                    let localExtensions = extensions.filter { $0.origin != .package }

                    if !localExtensions.isEmpty {
                        extensionGroup(title: "Custom Local Extensions", subtitle: "Files loaded from global or project extension folders/settings.", records: localExtensions)
                    }

                    if !packageExtensions.isEmpty {
                        extensionGroup(title: "Package Extensions", subtitle: "Extensions provided by installed Pi packages.", records: packageExtensions)
                    }
                }
            }
        }
    }

    private func extensionGroup(title: String, subtitle: String, records: [PiExtensionRecord]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.title3.weight(.bold))
                        .fontWidth(.expanded)
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(AppTheme.mutedText)
                }
                Spacer()
            }
            .padding(.horizontal, 2)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                    extensionRow(record)
                    if index < records.count - 1 { Divider() }
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

    private func extensionRow(_ record: PiExtensionRecord) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "puzzlepiece.extension")
                        .foregroundStyle(record.enabled ? .orange : AppTheme.mutedText)
                        .frame(width: 22)

                    Text(record.displayName)
                        .font(.headline)
                        .fontWidth(.expanded)
                }

                VStack(alignment: .leading, spacing: 4) {
                    if let description = record.packageDescription, !description.isEmpty {
                        Text(description)
                            .font(.footnote)
                            .foregroundStyle(.primary.opacity(0.82))
                    }

                    Text(record.path)
                        .font(.footnote.monospaced())
                        .foregroundStyle(AppTheme.mutedText)
                        .textSelection(.enabled)

                    if let repositoryURL = record.repositoryURL,
                       let linkURL = normalizedRepositoryURL(repositoryURL) {
                        Button {
                            NSWorkspace.shared.open(linkURL)
                        } label: {
                            HStack(spacing: 6) {
                                Image("github")
                                    .resizable()
                                    .renderingMode(.template)
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 12, height: 12)
                                Text(repositoryDisplayText(for: linkURL))
                                Image(systemName: "arrow.up.right.square")
                                    .font(.caption2)
                            }
                            .font(.caption)
                            .foregroundStyle(AppTheme.mutedText)
                        }
                        .buttonStyle(.plain)
                        .help(linkURL.absoluteString)
                    }

                    Text(extensionDetails(for: record))
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedText)
                        .textSelection(.enabled)
                }
                .padding(.leading, 32)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { record.enabled },
                set: { viewModel.setExtension(record, enabled: $0) }
            ))
            .labelsHidden()
                        .help(record.enabled ? "Do not inject this extension into Agent Deck sessions" : "Inject this extension into Agent Deck sessions")
        }
        .padding(.vertical, 10)
    }

    private func extensionDetails(for record: PiExtensionRecord) -> String {
        var parts = [record.scope.rawValue, record.origin.rawValue]
        if let packageName = record.packageName, !packageName.isEmpty, record.origin == .package {
            parts.append(packageName)
        }
        parts.append(record.enabled ? "injected by Agent Deck" : "not injected")
        return parts.joined(separator: " · ")
    }

    private func normalizedRepositoryURL(_ value: String) -> URL? {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("git+") { text.removeFirst(4) }
        if text.hasSuffix(".git") { text.removeLast(4) }
        if text.hasPrefix("git@github.com:") {
            text = "https://github.com/" + text.dropFirst("git@github.com:".count)
        }
        return URL(string: text)
    }

    private func repositoryDisplayText(for url: URL) -> String {
        if url.host?.localizedCaseInsensitiveContains("github.com") == true {
            let parts = url.path.split(separator: "/").map(String.init)
            if parts.count >= 2 { return parts.prefix(2).joined(separator: "/") }
        }
        return url.absoluteString
    }
}

struct ModelsScreen: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        AppPage("Models", subtitle: "Available models from `pi --list-models`") {
            if viewModel.availableModels.isEmpty {
                AppCard(title: "Catalog", trailing: catalogUpdatedLabel) {
                    Text("No models loaded yet. Use Refresh to query Pi.")
                        .foregroundStyle(AppTheme.mutedText)
                }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text("Pi’s model catalog, grouped by provider. Disable models to hide them from Agent Deck model pickers.")
                        .foregroundStyle(AppTheme.mutedText)
                    Spacer()
                    Text("\(viewModel.enabledAvailableModels.count) of \(viewModel.availableModels.count) enabled")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(AppTheme.mutedText)
                    Button("Enable All") {
                        viewModel.enableAllModels()
                    }
                    .disabled(viewModel.appSettings.disabledModelIdentifiers.isEmpty)
                    catalogUpdatedLabel()
                }

                VStack(alignment: .leading, spacing: 20) {
                    defaultSelectionSection
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
                Text("\(group.models.filter { viewModel.isModelEnabled($0) }.count)/\(group.models.count) enabled")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(AppTheme.mutedText)
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
        ["off", "minimal", "low", "medium", "high", "xhigh"]
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
                Text(model.model)
                    .font(.headline)
                    .fontWidth(.expanded)
                    .foregroundStyle(isEnabled ? .primary : AppTheme.mutedText)
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
        .opacity(isEnabled ? 1 : 0.55)
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
                Text("• Agent Deck launches child Pi sessions itself and keeps parent, child, transcript, artifact, and supervisor state in the app.")
                Text("• Parent sessions receive app-provided managed tools for single, chain, and parallel delegation.")
                Text("• Child sessions can contact the supervisor through Agent Deck's native request cards.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var sessionDefaultsCard: some View {
        AppCard(title: "Session Defaults") {
            AppKeyValueList(rows: [
                ("New Sessions", viewModel.areSubagentsEnabledForNewSessions ? "Native subagents enabled" : "Native subagents disabled"),
                ("Selected Session", selectedSessionStatus),
                ("Available Agents", "\(viewModel.snapshot.effectiveAgents.filter { $0.resolved.disabled != true }.count)"),
                ("Available Chains", "\(viewModel.snapshot.chains.count)")
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
                Text("• Parent and child transcript state is persisted by Agent Deck.")
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

        let seeded = Dictionary(uniqueKeysWithValues: context.sections
            .flatMap(\.agents)
            .compactMap { agent in makeDraft(agent).map { (agent.id, $0) } })
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
                VStack(alignment: .trailing, spacing: 4) {
                    Text("Model + thinking only")
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedText)
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(context.sections) { section in
                        if !section.agents.isEmpty {
                            AppCard(title: section.title) {
                                VStack(alignment: .leading, spacing: 12) {
                                    ForEach(section.agents) { agent in
                                        if let draftBinding = binding(for: agent.id) {
                                            AgentModelQuickEditRow(
                                                agent: agent,
                                                draft: draftBinding,
                                                availableModels: availableModels,
                                                isDirty: isDirty(agent.id)
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            HStack {
                if let saveMessage {
                    Text(saveMessage)
                        .font(.caption)
                        .foregroundStyle(.green)
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
        .padding(20)
        .frame(minWidth: 860, minHeight: 640)
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

struct AgentModelQuickEditRow: View {
    let agent: EffectiveAgentRecord
    @Binding var draft: AgentEditorDraft
    let availableModels: [AvailableModel]
    let isDirty: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(agent.name)
                    .font(.headline)
                    .fontWidth(.expanded)
                if isDirty {
                    AppLabelTag(text: "Unsaved", color: .orange)
                }
            }

            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Model")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.mutedText)
                    Picker("Model", selection: modelSelectionBinding) {
                        Text("Use Pi Default Model").tag("")
                        ForEach(availableModels, id: \.identifier) { model in
                            Text(model.identifier).tag(model.identifier)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if let summary = selectedModelMetadataSummary {
                        Text(summary)
                            .font(.caption.monospaced())
                            .foregroundStyle(AppTheme.mutedText)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(AppTheme.contentSubtleFill.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 8) {
                    Text("Thinking")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.mutedText)
                    Picker("Thinking", selection: thinkingSelectionBinding) {
                        ForEach(availableThinkingLevels, id: \.self) { level in
                            Text(level.capitalized).tag(level)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 180, alignment: .leading)
                }
                .frame(width: 220, alignment: .leading)
                .padding(12)
                .background(AppTheme.contentSubtleFill.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.contentSubtleFill.opacity(0.28), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var selectedModel: AvailableModel? {
        guard let identifier = draft.config.model else { return nil }
        return availableModels.first { $0.identifier == identifier }
    }

    private var selectedModelMetadataSummary: String? {
        guard let model = selectedModel else { return nil }
        return "context: \(model.contextWindow)"
    }

    private var availableThinkingLevels: [String] {
        selectedModel?.supportedThinkingLevels ?? ["off", "minimal", "low", "medium", "high", "xhigh"]
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
                let current = draft.config.thinking ?? "off"
                return availableThinkingLevels.contains(current) ? current : (availableThinkingLevels.first ?? "off")
            },
            set: { newValue in
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
