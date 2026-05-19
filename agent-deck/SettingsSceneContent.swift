import AppKit
import SwiftUI

struct SettingsSceneContent: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        TabView(selection: $selectedTab) {
            ForEach(SettingsTab.allCases) { tab in
                Tab(tab.rawValue, systemImage: tab.systemImage, value: tab) {
                    selectedTabContent(for: tab)
                }
            }
        }
        .tabViewStyle(.automatic)
        .frame(minWidth: 700, idealWidth: 780, minHeight: 560, idealHeight: 640)
        .tint(AppTheme.brandAccent)
        .background(AppTheme.windowBackground)
    }

    @ViewBuilder
    private func selectedTabContent(for tab: SettingsTab) -> some View {
        switch tab {
        case .general:
            GeneralSettingsTab(viewModel: viewModel)
        case .agent:
            AgentSettingsTab(viewModel: viewModel)
        case .automations:
            AutomationsSettingsTab(viewModel: viewModel)
        case .github:
            GitHubSettingsTab(viewModel: viewModel)
        case .performance:
            PerformanceSettingsTab(viewModel: viewModel)
        case .subagents:
            SubagentsSettingsTab(viewModel: viewModel)
        case .commands:
            CommandsSettingsTab(viewModel: viewModel)
        case .shortcuts:
            ShortcutsSettingsTab()
        }
    }
}

private enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General"
    case agent = "Agent"
    case automations = "Automations"
    case github = "GitHub"
    case performance = "Performance"
    case subagents = "Subagents"
    case commands = "Commands"
    case shortcuts = "Shortcuts"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .agent: return "sparkles.rectangle.stack"
        case .automations: return "wand.and.stars"
        case .github: return "chevron.left.forwardslash.chevron.right"
        case .performance: return "speedometer"
        case .subagents: return "slider.horizontal.3"
        case .commands: return "terminal"
        case .shortcuts: return "keyboard"
        }
    }
}

private enum SettingsLayout {
    static let formWidth: CGFloat = 700
    static let labelWidth: CGFloat = 180
    static let controlWidth: CGFloat = 390
    static let noteSpacing: CGFloat = 5
    static let rowSpacing: CGFloat = 10
    static let sectionSpacing: CGFloat = 18
    static let formPadding: CGFloat = 28
}

private struct SettingsForm<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
                content
            }
            .frame(width: SettingsLayout.formWidth, alignment: .topLeading)
            .padding(SettingsLayout.formPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .scrollBounceBehavior(.basedOnSize)
        .background(AppTheme.windowBackground)
    }
}

private struct SettingsSection<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.rowSpacing) {
            content
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.contentFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AppTheme.contentStroke, lineWidth: 1)
        }
    }
}

private struct SettingsRow<Content: View>: View {
    let title: String
    var note: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(title)
                .fontWeight(.semibold)
                .frame(width: SettingsLayout.labelWidth, alignment: .trailing)

            VStack(alignment: .leading, spacing: SettingsLayout.noteSpacing) {
                content
                if let note {
                    SettingsNote(text: note)
                }
            }
            .frame(width: SettingsLayout.controlWidth, alignment: .leading)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

private struct SettingsNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SettingsTextFieldRow: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    var note: String?

    var body: some View {
        SettingsRow(title: title, note: note) {
            TextField(placeholder, text: $text)
                .font(.body.monospaced())
                .textSelection(.enabled)
                .frame(width: SettingsLayout.controlWidth)
        }
    }
}

private struct SettingsButtonRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        SettingsRow(title: "") {
            HStack(spacing: 8) {
                content
            }
        }
    }
}

private struct SettingsPickerRow<SelectionValue: Hashable, Content: View>: View {
    let title: String
    @Binding var selection: SelectionValue
    var note: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        SettingsRow(title: title, note: note) {
            Picker(title, selection: $selection) {
                content
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .tint(AppTheme.brandAccent)
            .frame(width: SettingsLayout.controlWidth, alignment: .leading)
        }
    }
}

private struct SettingsStepperRow: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let valueText: String
    var note: String? = nil

    var body: some View {
        SettingsRow(title: title, note: note) {
            Stepper(value: $value, in: range) {
                Text(valueText)
                    .monospacedDigit()
                    .frame(minWidth: 96, alignment: .leading)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }
}

private struct SettingsValueButtonRow<Content: View>: View {
    let title: String
    let value: String
    @ViewBuilder let buttons: Content

    var body: some View {
        SettingsRow(title: title) {
            Text(value)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: SettingsLayout.controlWidth, alignment: .leading)

            HStack(spacing: 8) {
                buttons
            }
        }
    }
}

private struct SettingsToggleRow: View {
    let title: String
    var label: String = ""
    var note: String?
    @Binding var isOn: Bool

    var body: some View {
        SettingsRow(title: title, note: note) {
            Toggle(label, isOn: $isOn)
                .toggleStyle(.checkbox)
        }
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        SettingsForm {
            SettingsSection {
                SettingsPickerRow(
                    title: "Appearance:",
                    selection: appearanceModeBinding,
                    note: "System follows your macOS appearance. Light and Dark force Agent Deck to that scheme."
                ) {
                    ForEach(AppAppearanceMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
            }

            SettingsSection {
                SettingsTextFieldRow(
                    title: "Projects folder:",
                    placeholder: "Parent folder containing your projects",
                    text: projectsRootPathBinding,
                    note: "Choose the parent folder that contains your projects, not a single project repository. Suggested: \(ProjectDiscovery.defaultRootDirectoryURL().path)"
                )

                SettingsButtonRow {
                    Button("Choose Folder...") { viewModel.chooseProjectsRootDirectory() }
                    Button("Use Suggested") { viewModel.resetProjectsRootPathToDefault() }
                    Button("Reveal in Finder") { revealInFinder(viewModel.configuredProjectsRootPath) }
                }
            }

            SettingsSection {
                SettingsTextFieldRow(
                    title: "Skill import folder:",
                    placeholder: "Default import folder",
                    text: defaultSkillsImportRootPathBinding,
                    note: "\(AppBrand.displayName) falls back to the last used folder, then Documents."
                )

                SettingsButtonRow {
                    Button("Choose Folder...") { viewModel.chooseDefaultSkillsImportDirectory() }
                    Button("Clear") { viewModel.resetDefaultSkillsImportRootPath() }
                    Button("Reveal in Finder") {
                        if let path = viewModel.appSettings.defaultSkillsImportRootPath, !path.isEmpty {
                            revealInFinder(path)
                        }
                    }
                    .disabled((viewModel.appSettings.defaultSkillsImportRootPath ?? "").isEmpty)
                }
            }
        }
    }

    private var appearanceModeBinding: Binding<AppAppearanceMode> {
        Binding(
            get: { viewModel.appSettings.appearanceMode },
            set: { viewModel.setAppearanceMode($0) }
        )
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
}

// MARK: - Agent

private struct AgentSettingsTab: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        SettingsForm {
            SettingsSection {
                SettingsStepperRow(
                    title: "Notification delay:",
                    value: piAgentNotificationDelayBinding,
                    range: 1...60,
                    valueText: "\(viewModel.piAgentNotificationDelayMinutes) minutes",
                    note: "Before notifying about unread sessions."
                )
            }

            SettingsSection {
                SettingsToggleRow(
                    title: "Context zones:",
                    label: "Show smart/dumb zone hint",
                    note: "Off by default. When enabled, the context meter shows a 40% smart-zone marker and explains Matt Pocock's warning that added context can degrade model decisions.",
                    isOn: showContextSmartZoneHintBinding
                )

                SettingsRow(title: "") {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("“As LLMs receive more tokens, the relationships between tokens scale quadratically… every LLM has a smart zone and a dumb zone.”")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Link("Read the AIHero article", destination: URL(string: "https://www.aihero.dev/why-the-anthropic-ralph-plugin-sucks")!)
                            .font(.caption.weight(.semibold))
                    }
                }
            }

            SettingsSection {
                SettingsPickerRow(title: "Terminal app:", selection: piAgentTerminalApplicationSelectionBinding) {
                    ForEach(viewModel.piAgentTerminalApplicationOptions) { option in
                        Text(option.name).tag(option.id)
                    }
                }

                SettingsValueButtonRow(title: "Application:", value: selectedTerminalPathText) {
                    Button("Choose Other...") { viewModel.choosePiAgentTerminalApplication() }
                    Button("Use macOS Default") { viewModel.resetPiAgentTerminalApplicationToDefault() }
                }
            }
        }
    }

    private var piAgentNotificationDelayBinding: Binding<Int> {
        Binding(
            get: { viewModel.piAgentNotificationDelayMinutes },
            set: { viewModel.setPiAgentNotificationDelayMinutes($0) }
        )
    }

    private var showContextSmartZoneHintBinding: Binding<Bool> {
        Binding(
            get: { viewModel.appSettings.showContextSmartZoneHint },
            set: { viewModel.setShowContextSmartZoneHint($0) }
        )
    }

    private var piAgentTerminalApplicationSelectionBinding: Binding<String> {
        Binding(
            get: { viewModel.piAgentTerminalApplicationSelectionID },
            set: { viewModel.setPiAgentTerminalApplicationSelection($0) }
        )
    }

    private var selectedTerminalPathText: String {
        viewModel.appSettings.piAgentTerminalApplicationPath ?? "macOS default"
    }
}


// MARK: - Automations

private struct AutomationsSettingsTab: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        SettingsForm {
            SettingsSection {
                SettingsToggleRow(
                    title: "Session titles:",
                    label: "Generate titles with AI",
                    note: "Off by default. When enabled, the first draft prompt starts a hidden one-turn Pi session with no session persistence, extensions, skills, or tools.",
                    isOn: autoGenerateSessionTitlesBinding
                )

                SettingsToggleRow(
                    title: "Update titles:",
                    label: "Refresh generated titles as plans change",
                    note: "When enabled, new session plans may start a hidden helper to keep AI-generated, non-user-edited titles aligned with the latest request.",
                    isOn: autoUpdateSessionTitlesBinding
                )
                .disabled(!viewModel.appSettings.autoGeneratePiAgentSessionTitles)

                SettingsPickerRow(
                    title: "Title model:",
                    selection: titleGenerationModelBinding,
                    note: "Choose a cheap, fast text model."
                ) {
                    Text("Default model").tag("")
                    ForEach(viewModel.automationAvailableModels, id: \.identifier) { model in
                        Text(model.displayName).tag(model.identifier)
                    }
                }
            }

            SettingsSection {
                SettingsToggleRow(
                    title: "Git actions:",
                    label: "Enable Commit / Push toolbar actions",
                    note: "Off by default. When enabled with a model selected, Pi Agent shows native Commit, Push, and Commit & Push toolbar actions.",
                    isOn: gitAutomationEnabledBinding
                )

                SettingsToggleRow(
                    title: "Confirm actions:",
                    label: "Ask before committing or pushing",
                    note: "On by default. Turn off to run Commit and Commit & Push immediately from the toolbar.",
                    isOn: gitAutomationConfirmationBinding
                )
                .disabled(!viewModel.appSettings.piAgentGitAutomationEnabled)

                SettingsPickerRow(
                    title: "Commit model:",
                    selection: commitMessageModelBinding,
                    note: "Required. Apple Foundation Model runs locally; other models use a hidden no-thinking Pi helper session."
                ) {
                    Text("Choose model…").tag("")
                    ForEach(viewModel.automationAvailableModels, id: \.identifier) { model in
                        Text(model.displayName).tag(model.identifier)
                    }
                }

                if viewModel.automationAvailableModels.isEmpty {
                    HStack(spacing: 8) {
                        Label("No enabled models available", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Refresh Models") {
                            viewModel.refreshModels()
                        }
                    }
                    .font(.footnote)
                    .padding(.leading, SettingsLayout.labelWidth + 16)
                }
            }

            SettingsSection {
                SettingsToggleRow(
                    title: "Agent avatars:",
                    label: "Generate Image Playground prompts with AI",
                    note: "Off by default. When enabled, Agent Deck uses the agent frontmatter to draft a short prompt before generating an avatar with Image Playground. When disabled, it uses a simple fallback prompt.",
                    isOn: agentAvatarPromptAutomationBinding
                )

                SettingsPickerRow(
                    title: "Prompt model:",
                    selection: agentAvatarPromptModelBinding,
                    note: agentAvatarPromptModelNote
                ) {
                    Text("Default model").tag("")
                    ForEach(viewModel.automationAvailableModels, id: \.identifier) { model in
                        Text(model.displayName).tag(model.identifier)
                    }
                }
                .disabled(!viewModel.appSettings.autoGenerateAgentAvatarPrompts)
            }
        }
        .onAppear {
            viewModel.ensureAvailableModelsLoaded()
        }
    }

    private var autoGenerateSessionTitlesBinding: Binding<Bool> {
        Binding(
            get: { viewModel.appSettings.autoGeneratePiAgentSessionTitles },
            set: { viewModel.setAutoGeneratePiAgentSessionTitles($0) }
        )
    }

    private var autoUpdateSessionTitlesBinding: Binding<Bool> {
        Binding(
            get: { viewModel.appSettings.autoUpdatePiAgentSessionTitles },
            set: { viewModel.setAutoUpdatePiAgentSessionTitles($0) }
        )
    }

    private var titleGenerationModelBinding: Binding<String> {
        Binding(
            get: { viewModel.appSettings.piAgentTitleGenerationModelIdentifier ?? "" },
            set: { viewModel.setPiAgentTitleGenerationModelIdentifier($0) }
        )
    }

    private var gitAutomationEnabledBinding: Binding<Bool> {
        Binding(
            get: { viewModel.appSettings.piAgentGitAutomationEnabled },
            set: { viewModel.setPiAgentGitAutomationEnabled($0) }
        )
    }

    private var gitAutomationConfirmationBinding: Binding<Bool> {
        Binding(
            get: { viewModel.appSettings.piAgentGitAutomationRequiresConfirmation },
            set: { viewModel.setPiAgentGitAutomationRequiresConfirmation($0) }
        )
    }

    private var commitMessageModelBinding: Binding<String> {
        Binding(
            get: { viewModel.appSettings.piAgentCommitMessageModelIdentifier ?? "" },
            set: { viewModel.setPiAgentCommitMessageModelIdentifier($0) }
        )
    }

    private var agentAvatarPromptAutomationBinding: Binding<Bool> {
        Binding(
            get: { viewModel.appSettings.autoGenerateAgentAvatarPrompts },
            set: { viewModel.setAutoGenerateAgentAvatarPrompts($0) }
        )
    }

    private var agentAvatarPromptModelBinding: Binding<String> {
        Binding(
            get: { viewModel.appSettings.agentAvatarPromptModelIdentifier ?? "" },
            set: { viewModel.setAgentAvatarPromptModelIdentifier($0) }
        )
    }

    private var agentAvatarPromptModelNote: String {
        let identifier = viewModel.appSettings.agentAvatarPromptModelIdentifier ?? viewModel.agentAvatarPromptGenerationModel()?.identifier
        if identifier == FoundationModelAutomationService.identifier {
            return "Apple Foundation Model runs locally. Other models use a hidden no-thinking Pi helper session."
        }
        return "Uses the selected model in a hidden no-thinking Pi helper session to draft the avatar prompt."
    }
}

// MARK: - Performance

private struct PerformanceSettingsTab: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        SettingsForm {
            SettingsSection {
                SettingsToggleRow(
                    title: "Idle parking:",
                    label: "Stop idle Pi RPC processes",
                    note: "When enabled, idle parent chat processes are stopped and resumed from the saved session on the next prompt.",
                    isOn: piAgentIdleParkingEnabledBinding
                )

                SettingsStepperRow(
                    title: "Parking delay:",
                    value: piAgentIdleParkingTimeoutBinding,
                    range: 1...120,
                    valueText: "\(viewModel.piAgentIdleParkingTimeoutMinutes) minutes",
                    note: "How long an idle parent chat process can stay warm."
                )
                .disabled(!viewModel.isPiAgentIdleParkingEnabled)
            }

            SettingsSection {
                SettingsToggleRow(
                    title: "Transcript memory:",
                    label: "Load transcripts on demand",
                    note: "Keeps older chat transcripts on disk and loads them when opened. Turn off to keep all transcripts in memory.",
                    isOn: piAgentLazyTranscriptLoadingEnabledBinding
                )

                SettingsStepperRow(
                    title: "Loaded chats:",
                    value: piAgentLoadedTranscriptCacheLimitBinding,
                    range: 1...50,
                    valueText: "\(viewModel.piAgentLoadedTranscriptCacheLimit)",
                    note: "How many inactive parent-chat transcripts stay warm in memory."
                )
                .disabled(!viewModel.isPiAgentLazyTranscriptLoadingEnabled)
            }
        }
    }

    private var piAgentIdleParkingEnabledBinding: Binding<Bool> {
        Binding(
            get: { viewModel.isPiAgentIdleParkingEnabled },
            set: { viewModel.setPiAgentIdleParkingEnabled($0) }
        )
    }

    private var piAgentIdleParkingTimeoutBinding: Binding<Int> {
        Binding(
            get: { viewModel.piAgentIdleParkingTimeoutMinutes },
            set: { viewModel.setPiAgentIdleParkingTimeoutMinutes($0) }
        )
    }

    private var piAgentLazyTranscriptLoadingEnabledBinding: Binding<Bool> {
        Binding(
            get: { viewModel.isPiAgentLazyTranscriptLoadingEnabled },
            set: { viewModel.setPiAgentLazyTranscriptLoadingEnabled($0) }
        )
    }

    private var piAgentLoadedTranscriptCacheLimitBinding: Binding<Int> {
        Binding(
            get: { viewModel.piAgentLoadedTranscriptCacheLimit },
            set: { viewModel.setPiAgentLoadedTranscriptCacheLimit($0) }
        )
    }
}

// MARK: - Commands

private struct CommandsSettingsTab: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        SettingsForm {
            SettingsSection {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Injected Slash Commands")
                        .font(.headline)
                    SettingsNote(text: "Only Agent Deck bundled commands are shown here. Enabled commands are loaded into parent Pi RPC sessions with explicit --extension arguments while ambient Pi extension discovery remains disabled. Future imported commands should live in \(PiInjectedCommandCatalog.commandLibraryPath).")
                }

                HStack {
                    Button {
                        viewModel.importCommandFile()
                    } label: {
                        Label("Import Command…", systemImage: "square.and.arrow.down")
                    }
                    Button {
                        revealCommandLibraryInFinder()
                    } label: {
                        Label("Reveal Library", systemImage: "folder")
                    }
                }
                .buttonStyle(.glass)

                VStack(spacing: 24) {
                    CommandGroupSection(
                        title: "Agent Deck Bundled",
                        subtitle: "Commands shipped with the app.",
                        commands: PiInjectedCommandCatalog.all.filter { $0.source == .builtIn },
                        viewModel: viewModel
                    )

                    let importedCommands = PiInjectedCommandCatalog.all.filter { $0.source == .library }
                    if !importedCommands.isEmpty {
                        CommandGroupSection(
                            title: "Imported",
                            subtitle: "Commands copied into the Agent Deck command library. Imported commands are disabled by default.",
                            commands: importedCommands,
                            viewModel: viewModel
                        )
                    }
                }
                .padding(.top, 14)
            }

            SettingsNote(text: "Changes apply to newly started or resumed RPC sessions. Restart an active Pi session to change which injected commands it has loaded.")
                .padding(.horizontal, 14)
        }
    }

    private func revealCommandLibraryInFinder() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let directory = appSupport
            .appendingPathComponent(AppBrand.displayName, isDirectory: true)
            .appendingPathComponent("Command Library", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }
}

private struct CommandGroupSection: View {
    let title: String
    let subtitle: String
    let commands: [PiInjectedCommand]
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption.italic())
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 10) {
                ForEach(commands) { command in
                    CommandSettingsRow(command: command, viewModel: viewModel)
                }
            }
        }
    }
}

private struct CommandSettingsRow: View {
    let command: PiInjectedCommand
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    SlashCommandKeyCap(command.slashName)
                    Text(command.title)
                        .font(.headline)
                    sourcePill
                }

                Text(command.description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let path = command.extensionPath {
                    Text(path)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 24)

            Toggle("", isOn: Binding(
                get: { viewModel.isInjectedCommandEnabled(command) },
                set: { viewModel.setInjectedCommandEnabled(command, isEnabled: $0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.contentSubtleFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AppTheme.contentStroke, lineWidth: 1)
        }
    }

    private var sourcePill: some View {
        Label(command.source == .builtIn ? "Bundled" : "Imported", systemImage: command.source == .builtIn ? "shippingbox" : "square.and.arrow.down")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(command.source == .builtIn ? AppTheme.brandAccent : .blue)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background((command.source == .builtIn ? AppTheme.brandAccent : Color.blue).opacity(0.10), in: Capsule(style: .continuous))
    }
}

private struct SlashCommandKeyCap: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .frame(minHeight: 24)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(AppTheme.contentSubtleFill)
                    .shadow(color: .black.opacity(0.08), radius: 0, x: 0, y: 1)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(AppTheme.contentStroke, lineWidth: 1)
            }
    }
}

// MARK: - Shortcuts

private struct ShortcutsSettingsTab: View {
    private let sections = AgentDeckShortcutSection.all

    var body: some View {
        SettingsForm {
            VStack(alignment: .leading, spacing: 6) {
                Text("Keyboard Shortcuts")
                    .font(.title2.weight(.semibold))
                Text("These shortcuts mirror the app menus and update from the same shortcut catalog used by Agent Deck.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 2)

            ForEach(sections) { section in
                SettingsSection {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(section.title)
                            .font(.headline)

                        VStack(spacing: 0) {
                            ForEach(section.items) { item in
                                ShortcutRow(item: item)

                                if item.id != section.items.last?.id {
                                    Divider()
                                        .padding(.leading, 2)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct ShortcutRow: View {
    let item: AgentDeckShortcutItem

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(item.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)

            ShortcutKeyChord(item: item)
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title), \(accessibilityShortcutText)")
    }

    private var accessibilityShortcutText: String {
        item.displayParts.joined(separator: " ")
    }
}

private struct ShortcutKeyChord: View {
    let item: AgentDeckShortcutItem

    var body: some View {
        HStack(spacing: 4) {
            ForEach(item.displayParts, id: \.self) { part in
                ShortcutKeyCap(part)
            }
        }
        .fixedSize()
    }
}

private struct ShortcutKeyCap: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(.primary)
            .frame(minWidth: 24, minHeight: 24)
            .padding(.horizontal, text.count > 1 ? 6 : 0)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(AppTheme.contentSubtleFill)
                    .shadow(color: .black.opacity(0.08), radius: 0, x: 0, y: 1)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(AppTheme.contentStroke, lineWidth: 1)
            }
    }
}

private extension AgentDeckShortcutItem {
    var displayParts: [String] {
        modifierDisplayParts + [keyDisplayText]
    }

    private var modifierDisplayParts: [String] {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        if modifiers.contains(.command) { parts.append("⌘") }
        return parts
    }

    private var keyDisplayText: String {
        switch key {
        case "delete": return "⌫"
        case "escape": return "Esc"
        case "return": return "↩"
        case " ": return "Space"
        default: return key.uppercased()
        }
    }
}

// MARK: - GitHub

private struct GitHubSettingsTab: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        SettingsForm {
            SettingsSection {
                SettingsStepperRow(
                    title: "Issue cache lifetime:",
                    value: cacheLifetimeBinding,
                    range: 1...240,
                    valueText: "\(viewModel.gitHubBoardCacheLifetimeMinutes) minutes",
                    note: "Refresh bypasses the cache."
                )
            }
        }
    }

    private var cacheLifetimeBinding: Binding<Int> {
        Binding(
            get: { viewModel.gitHubBoardCacheLifetimeMinutes },
            set: { viewModel.setGitHubBoardCacheLifetimeMinutes($0) }
        )
    }
}

// MARK: - Subagents

private struct SubagentsSettingsTab: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        SettingsForm {
            SettingsSection {
                SettingsToggleRow(
                    title: "Builtins:",
                    label: "Disable all builtins globally",
                    note: "Per-agent quick controls in the Agents screen also apply globally for now.",
                    isOn: userDisableBuiltinsBinding
                )
            }
        }
    }

    private var userDisableBuiltinsBinding: Binding<Bool> {
        Binding(
            get: { viewModel.userDisableBuiltins },
            set: { viewModel.setDisableBuiltins($0, scope: .global) }
        )
    }
}

private func revealInFinder(_ path: String?) {
    guard let path, !path.isEmpty else { return }
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
}

#Preview {
    SettingsSceneContent()
        .environmentObject(AppViewModel())
}
