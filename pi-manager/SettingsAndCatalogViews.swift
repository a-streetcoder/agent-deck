import AppKit
import SwiftUI

private func boolLabel(_ value: Bool?) -> String {
    guard let value else { return "—" }
    return value ? "true" : "false"
}

private func revealInFinder(_ path: String?) {
    guard let path, !path.isEmpty else { return }
    revealInFinder(path)
}

private func revealInFinder(_ path: String) {
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
}

struct SettingsScreen: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        AppPage("Settings", subtitle: "App-level preferences for Pi Manager") {
            AppCard(title: "Projects") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Choose the root folder Pi Manager scans for projects. When no project is selected, Pi Agent starts here too.")
                        .foregroundStyle(AppTheme.mutedText)

                    TextField("Projects root folder", text: projectsRootPathBinding)
                        .textFieldStyle(.roundedBorder)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)

                    HStack(spacing: 10) {
                        Button("Choose Folder") {
                            viewModel.chooseProjectsRootDirectory()
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Use Default") {
                            viewModel.resetProjectsRootPathToDefault()
                        }
                        .buttonStyle(.bordered)

                        Spacer()

                        Button("Reveal in Finder") {
                            revealInFinder(viewModel.configuredProjectsRootPath)
                        }
                        .buttonStyle(.bordered)
                    }

                    Text("Default: \(ProjectDiscovery.defaultRootDirectoryURL().path)")
                        .font(.footnote)
                        .foregroundStyle(AppTheme.mutedText)
                }
            }

            AppCard(title: "Skill Imports") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Optionally choose a default folder Pi Manager should open first when importing skills. If unset, Pi Manager falls back to the last used folder, then Documents.")
                        .foregroundStyle(AppTheme.mutedText)

                    TextField("Default skills import folder", text: defaultSkillsImportRootPathBinding)
                        .textFieldStyle(.roundedBorder)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)

                    HStack(spacing: 10) {
                        Button("Choose Folder") {
                            viewModel.chooseDefaultSkillsImportDirectory()
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Clear") {
                            viewModel.resetDefaultSkillsImportRootPath()
                        }
                        .buttonStyle(.bordered)

                        Spacer()

                        Button("Reveal in Finder") {
                            if let path = viewModel.appSettings.defaultSkillsImportRootPath, !path.isEmpty {
                                revealInFinder(path)
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled((viewModel.appSettings.defaultSkillsImportRootPath ?? "").isEmpty)
                    }
                }
            }

            AppCard(title: "GitHub") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Tune how long GitHub issue data stays fresh before Pi Manager reloads it.")
                        .foregroundStyle(AppTheme.mutedText)

                    AppStepper("Issue cache lifetime",
                               value: cacheLifetimeBinding,
                               in: 1...240,
                               unit: "minutes")

                    Text("Applies to the issue lists on the GitHub page. Use Refresh to bypass the cache at any time.")
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

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        AppStepper("Notification delay",
                                   value: piAgentNotificationDelayBinding,
                                   in: 1...60,
                                   unit: "minutes")

                        Text("Pi Manager marks sessions as needing attention immediately, then waits this long before sending a macOS notification if the session is still unread and the app is not active.")
                            .font(.footnote)
                            .foregroundStyle(AppTheme.mutedText)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Terminal app", selection: piAgentTerminalApplicationSelectionBinding) {
                            ForEach(viewModel.piAgentTerminalApplicationOptions) { option in
                                Text(option.name).tag(option.id)
                            }
                        }
                        .pickerStyle(.menu)

                        Text(viewModel.appSettings.piAgentTerminalApplicationPath ?? "Use macOS' default app for .command files")
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .foregroundStyle(AppTheme.mutedText)

                        HStack(spacing: 10) {
                            Button("Choose Other…") {
                                viewModel.choosePiAgentTerminalApplication()
                            }
                            .buttonStyle(.borderedProminent)

                            Button("Use macOS Default") {
                                viewModel.resetPiAgentTerminalApplicationToDefault()
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    Text("Used by the Pi Agent toolbar terminal button when opening a CLI resume session.")
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

    private var projectsRootPathBinding: Binding<String> {
        Binding(
            get: { viewModel.appSettings.projectsRootPath },
            set: { viewModel.setProjectsRootPath($0) }
        )
    }

    private var defaultSkillsImportRootPathBinding: Binding<String> {
        Binding(
            get: { viewModel.appSettings.defaultSkillsImportRootPath ?? "" },
            set: { viewModel.setDefaultSkillsImportRootPath($0) }
        )
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

    private var piAgentNotificationDelayBinding: Binding<Int> {
        Binding(
            get: { viewModel.piAgentNotificationDelayMinutes },
            set: { viewModel.setPiAgentNotificationDelayMinutes($0) }
        )
    }

    private var piAgentTerminalApplicationSelectionBinding: Binding<String> {
        Binding(
            get: { viewModel.piAgentTerminalApplicationSelectionID },
            set: { viewModel.setPiAgentTerminalApplicationSelection($0) }
        )
    }

    private var userDisableBuiltinsBinding: Binding<Bool> {
        Binding(
            get: { viewModel.userDisableBuiltins },
            set: { viewModel.setDisableBuiltins($0, scope: .global) }
        )
    }

}

struct ExtensionsScreen: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        AppPage("Extensions", subtitle: "Enable or disable Pi extensions without deleting extension files") {
            AppCard(title: "Safety") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Pi Manager only writes explicit + / - entries to Pi settings. It does not delete extension files, package folders, or unrelated settings keys.")
                    Text("Changes affect new Pi sessions in Pi Manager and the CLI/TUI. Existing TUI sessions can pick them up with `/reload`; existing app sessions need a new session.")
                        .foregroundStyle(AppTheme.mutedText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            let extensions = viewModel.visibleExtensions
            if extensions.isEmpty {
                ContentUnavailableView("No Extensions Found", systemImage: "puzzlepiece.extension", description: Text("Pi Manager did not find auto-discovered, settings, or package extensions for the current scope."))
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
            .help(record.enabled ? "Disable this extension in settings" : "Enable this extension in settings")
        }
        .padding(.vertical, 10)
    }

    private func extensionDetails(for record: PiExtensionRecord) -> String {
        var parts = [record.scope.rawValue, record.origin.rawValue]
        if let packageName = record.packageName, !packageName.isEmpty, record.origin == .package {
            parts.append(packageName)
        }
        parts.append("writes to \(record.settingsPath)")
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

struct SubagentsScreen: View {
    @ObservedObject var viewModel: AppViewModel
    let onEditConfig: () -> Void
    let onRestoreDefaults: () -> Void
    @State private var showingRestoreDefaultsConfirmation = false

    var body: some View {
        AppPage("Subagents", subtitle: "Global pi-subagents runtime defaults and package behavior") {
            editableScopeCard
            configFileCard
            packageDefaultsCard
            runtimeEffectsCard
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

    private var editableScopeCard: some View {
        AppCard(title: "What You Can Edit Here") {
            VStack(alignment: .leading, spacing: 10) {
                Text("• These settings control default runtime behavior for pi-subagents on this machine.")
                Text("• This is the package config file, not an agent markdown file.")
                Text("• Things like async defaults, intercom bridge behavior, control notices, parallel limits, and worktree hooks live here.")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var configFileCard: some View {
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
    }

    private var packageDefaultsCard: some View {
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
    }

    private var runtimeEffectsCard: some View {
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
