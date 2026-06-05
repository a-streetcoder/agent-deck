import AppKit
import SwiftUI

struct SettingsSceneContent: View {
    @Environment(AppViewModel.self) private var viewModel
    @State private var themeManager = ThemeManager.shared
    @State private var selectedTab: SettingsTab = .general

    private var visibleTabs: [SettingsTab] {
        SettingsTab.allCases.filter { SettingsFeatureFlags.isEnabled($0) }
    }

    var body: some View {
        // Custom tab strip (instead of native `TabView` + `Tab`): SwiftUI's
        // Settings-scene TabView renders the strip via `NSToolbar`, which
        // ignores `.tint(_:)`. To theme the selected tab we render the strip
        // ourselves with glass material backing (matching the native look)
        // and an `AppTheme.brandAccent` chip behind the selected tab.
        VStack(spacing: 0) {
            SettingsTabStrip(
                tabs: visibleTabs,
                selection: $selectedTab,
                label: { $0.rawValue },
                systemImage: { $0.systemImage }
            )
            Divider()
            selectedTabContent(for: selectedTab)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 700, idealWidth: 780, minHeight: 560, idealHeight: 640)
        .background(AppTheme.windowBackground)
        // Theme the Settings window itself (bg + transparent titlebar) so its
        // titlebar matches, like the main window.
        .background(WindowBackgroundApplier(color: AppTheme.windowBackground))
        // `AppTheme`'s themed tokens are computed `static var`s, invisible to
        // SwiftUI's dependency graph, so re-key on the theme revision to force a
        // uniform repaint. Crucially this `.id` is INSIDE the body — below the
        // `selectedTab` @State owner — so the tab selection survives the rebuild.
        .id(themeManager.revision)
    }

    @ViewBuilder
    private func selectedTabContent(for tab: SettingsTab) -> some View {
        switch tab {
        case .general:
            GeneralSettingsTab(viewModel: viewModel)
        case .appearance:
            AppearanceSettingsTab(viewModel: viewModel)
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

private enum SettingsFeatureFlags {
    static let appearanceTabEnabled = true

    static func isEnabled(_ tab: SettingsTab) -> Bool {
        switch tab {
        case .appearance:
            return appearanceTabEnabled
        default:
            return true
        }
    }
}

private enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General"
    case appearance = "Appearance"
    case agent = "Agent"
    case automations = "Automations"
    case github = "GitHub"
    case performance = "Performance"
    case subagents = "Deck agents"
    case commands = "Commands"
    case shortcuts = "Shortcuts"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintpalette"
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

// MARK: - Custom themed tab strip
//
// Mirrors the native macOS Settings tab toolbar (icon-above-label tabs in a
// horizontal strip with glass material background) but renders the selected-
// tab chip in `AppTheme.brandAccent` instead of `NSColor.controlAccentColor`.
// Use here instead of `TabView` + `Tab` so theme switches reach the strip.

private struct SettingsTabStrip<TabValue: Hashable & Identifiable>: View {
    let tabs: [TabValue]
    @Binding var selection: TabValue
    let label: (TabValue) -> String
    let systemImage: (TabValue) -> String

    var body: some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            ForEach(tabs) { tab in
                SettingsTabButton(
                    label: label(tab),
                    systemImage: systemImage(tab),
                    isSelected: selection == tab,
                    action: { selection = tab }
                )
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(AppTheme.windowBackground) // Themed (was the system .bar material)
    }
}

private struct SettingsTabButton: View {
    let label: String
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(iconStyle)
                    .frame(height: 22)
                // Constant weight across selected/unselected so the label's
                // intrinsic width stays the same — switching tabs otherwise
                // shifts adjacent tabs sideways as the bold metrics differ
                // from the regular metrics. The selection signal is carried
                // by the chip + icon color, not weight.
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .frame(minWidth: 60)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .modifier(SettingsTabSelectionGlass(isSelected: isSelected, isHovering: isHovering))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(label)
    }

    private var iconStyle: AnyShapeStyle {
        isSelected
            ? AnyShapeStyle(AppTheme.brandAccent)
            : AnyShapeStyle(Color.secondary)
    }
}

/// Selection chrome for `SettingsTabButton`. Mirrors the native macOS Settings
/// selected-tab treatment: a tinted Liquid Glass capsule via `.glassEffect`
/// (with `.interactive()` for native press feedback) rather than a flat fill.
/// The tint comes from `AppTheme.brandAccent` so the chip tracks the active
/// theme. Non-selected tabs render no glass — the strip's `.bar` material
/// already provides the toolbar surface.
private struct SettingsTabSelectionGlass: ViewModifier {
    let isSelected: Bool
    let isHovering: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        if isSelected {
            content.glassEffect(
                .regular.tint(AppTheme.brandAccent.opacity(0.30)).interactive(),
                in: shape
            )
        } else if isHovering {
            content.background(shape.fill(Color.primary.opacity(0.06)))
        } else {
            content
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
        ScrollView(showsIndicators: false) {
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
    var alignment: VerticalAlignment = .firstTextBaseline
    var note: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: alignment, spacing: 16) {
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

/// Small uppercased caption used as the header of a subgroup *inside* a
/// `SettingsSection`. Keep this the single source of truth so every tab
/// (Appearance, Shortcuts, …) renders subgroup titles identically.
private struct SettingsGroupHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
    }
}

private struct SettingsTextFieldRow: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    var note: String?

    var body: some View {
        SettingsRow(title: title, note: note) {
            AppTextField(text: $text, placeholder: placeholder, font: .body.monospaced())
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
            .appMenuPicker()
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
            .appBrandTint()
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
                .appCheckbox()
        }
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    var viewModel: AppViewModel

    var body: some View {
        SettingsForm {
            SettingsSection {
                ProjectsRootListRow(viewModel: viewModel)

                SettingsButtonRow {
                    Button("Add Folder...") { viewModel.chooseProjectsRootDirectory() }
                        .appSecondaryButton()
                    Button("Use Suggested") { viewModel.useSuggestedProjectsRootDirectory() }
                        .appSecondaryButton()
                        .disabled(viewModel.suggestedProjectsRootPath == nil)
                    Button("Reset to Default") { viewModel.resetProjectsRootPathsToDefault() }
                        .appSecondaryButton()
                }
            }

            SettingsSection {
                SettingsPickerRow(
                    title: "Pi extensions:",
                    selection: Binding(
                        get: { viewModel.appSettings.piAgentExtensionLoadingMode },
                        set: { viewModel.setPiAgentExtensionLoadingMode($0) }
                    ),
                    note: "Applies to Pi Agent sessions, native Deck agents, and automation helpers. Restart running sessions for changes to apply."
                ) {
                    ForEach(PiAgentExtensionLoadingMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                SettingsRow(title: "Current mode:", alignment: .top) {
                    PiExtensionLoadingSummary(mode: viewModel.appSettings.piAgentExtensionLoadingMode)
                }

                if viewModel.appSettings.piAgentExtensionLoadingMode.usesCustomPiExtensionSelection {
                    SettingsRow(title: "Loaded extensions:", alignment: .top, note: "Unchecked extensions are skipped only by Agent Deck launches. Pi's own settings.json is not changed.") {
                        PiExtensionSelectionList(viewModel: viewModel)
                    }
                }
            }

            SettingsSection {
                SettingsValueButtonRow(
                    title: "Skill repositories:",
                    value: SkillRepositorySyncService.repositoriesDirectoryURL().path
                ) {
                    Button("Reveal in Finder") {
                        let url = SkillRepositorySyncService.repositoriesDirectoryURL()
                        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                        revealInFinder(url.path)
                    }
                    .appSecondaryButton()
                }
            }
        }
    }
}

private struct PiExtensionSelectionList: View {
    var viewModel: AppViewModel
    /// Keyed by `PiExtensionCandidate.id`. Populated asynchronously once per
    /// candidate-set change so we don't re-read source files on every layout pass.
    @State private var conflictsByID: [String: [String]] = [:]

    private var candidates: [PiExtensionCandidate] {
        viewModel.discoveredPiExtensions
    }

    private var disabledExtensionIDs: Set<String> {
        viewModel.appSettings.disabledPiExtensionIDs
    }

    private var enabledCount: Int {
        candidates.filter { !disabledExtensionIDs.contains($0.id) }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("\(enabledCount) of \(candidates.count) selected")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("All") { viewModel.setAllDiscoveredPiExtensions(enabled: true) }
                    .appSecondaryButton()
                    .disabled(candidates.isEmpty || enabledCount == candidates.count)
                Button("None") { viewModel.setAllDiscoveredPiExtensions(enabled: false) }
                    .appSecondaryButton()
                    .disabled(candidates.isEmpty || enabledCount == 0)
            }

            if candidates.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No Pi default extensions were discovered.")
                        .font(.subheadline.weight(.semibold))
                    Text("Agent Deck looked in ~/.pi/agent/extensions, the selected project's .pi/extensions folder, settings.json extension paths, and installed package extension directories.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppTheme.contentSubtleFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(candidates) { candidate in
                        PiExtensionSelectionRow(
                            candidate: candidate,
                            isEnabled: Binding(
                                get: { !viewModel.appSettings.disabledPiExtensionIDs.contains(candidate.id) },
                                set: { viewModel.setPiExtension(candidate, enabled: $0) }
                            ),
                            conflictingToolNames: conflictsByID[candidate.id] ?? []
                        )
                    }
                }
            }
        }
        .padding(12)
        .frame(width: SettingsLayout.controlWidth, alignment: .leading)
        .background(AppTheme.contentSubtleFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(AppTheme.contentStroke, lineWidth: 1)
        }
        .task(id: candidates.map(\.id).joined()) {
            // Run conflict detection off the main thread — each candidate requires
            // a source-file read. Results are small and stable; the task re-fires
            // only when the candidate set changes (add/remove/prune).
            let snapshot = candidates
            let detected = await Task.detached(priority: .utility) {
                var result: [String: [String]] = [:]
                for candidate in snapshot {
                    let conflicts = PiExtensionConflictDetector.conflictingBridgeToolNames(for: candidate)
                    if !conflicts.isEmpty {
                        result[candidate.id] = conflicts
                    }
                }
                return result
            }.value
            conflictsByID = detected
        }
    }
}

private struct PiExtensionSelectionRow: View {
    let candidate: PiExtensionCandidate
    @Binding var isEnabled: Bool
    /// Bridge tool names detected in this extension's source that overlap with
    /// Agent Deck's built-in bridges. Empty means no detected conflict.
    var conflictingToolNames: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $isEnabled) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(candidate.name)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        PiExtensionScopeBadge(candidate: candidate)
                    }
                    HStack(spacing: 5) {
                        Text(candidate.detailLabel)
                        Text("•")
                        Text(candidate.launchSource)
                            .truncationMode(.middle)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }
            .appCheckbox()

            if isEnabled && !conflictingToolNames.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text(conflictWarningText)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 22)
            }
        }
    }

    private var conflictWarningText: String {
        let names = conflictingToolNames.joined(separator: ", ")
        let plural = conflictingToolNames.count == 1 ? "Tool" : "Tools"
        let verb = conflictingToolNames.count == 1 ? "is" : "are"
        return "\(plural) \(names) \(verb) also registered by an Agent Deck bridge. If both are enabled for a launch, Agent Deck's bridge is loaded after this extension and may shadow this implementation."
    }
}

private struct PiExtensionScopeBadge: View {
    let candidate: PiExtensionCandidate

    var body: some View {
        Label(candidate.scopeLabel, systemImage: iconName)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.10), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(0.25), lineWidth: 1))
    }

    private var iconName: String {
        switch candidate.source.kind {
        case .project, .legacyProject:
            return "folder"
        case .package:
            return "shippingbox"
        default:
            return "globe"
        }
    }

    private var color: Color {
        switch candidate.source.kind {
        case .project, .legacyProject:
            return .cyan
        case .package:
            return .purple
        default:
            return .blue
        }
    }
}

private struct PiExtensionLoadingSummary: View {
    let mode: PiAgentExtensionLoadingMode

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: mode.disablesAmbientPiExtensions ? "lock.shield" : "puzzlepiece.extension")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(AppTheme.brandAccent)
                    .frame(width: 26, height: 26)

                VStack(alignment: .leading, spacing: 4) {
                    Text(mode.disablesAmbientPiExtensions ? "Managed extension loading" : "Pi extension discovery enabled")
                        .font(.headline)
                    Text(mode.extensionDiscoverySummary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()
                .opacity(0.6)

            VStack(alignment: .leading, spacing: 6) {
                summaryLine(label: "Launch", value: mode.launchSummary, monospaced: true)
                summaryLine(label: "Scope", value: "Parent sessions, Deck agents, and helpers")
                summaryLine(label: "Agent Deck bridges", value: "Always loaded when required")
            }
        }
        .padding(12)
        .frame(width: SettingsLayout.controlWidth, alignment: .leading)
        .background(AppTheme.contentSubtleFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(AppTheme.contentStroke, lineWidth: 1)
        }
    }

    private func summaryLine(label: String, value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 88, alignment: .leading)
            Text(value)
                .font(monospaced ? .caption.monospaced() : .caption)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Settings row that lists every configured projects-root folder. Each row
/// exposes Reveal / Remove; the parent section provides Add / Use Suggested
/// / Reset.
private struct ProjectsRootListRow: View {
    var viewModel: AppViewModel

    var body: some View {
        // Read raw `appSettings.projectsRootPaths` directly (not the
        // controller-derived helper) so SwiftUI's @Observable dependency
        // tracking re-renders the row immediately when the list mutates.
        // Going via `viewModel.configuredProjectsRootPaths` reads through
        // the non-observable AppSettingsController and the row would only
        // refresh on next view re-creation (e.g. tab switch).
        let paths = viewModel.appSettings.projectsRootPaths
        SettingsRow(
            title: "Projects folders:",
            alignment: .top,
            note: noteText
        ) {
            VStack(alignment: .leading, spacing: 6) {
                if paths.isEmpty {
                    Text("No projects folders configured yet. Click Add Folder… below.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    ForEach(Array(paths.enumerated()), id: \.element) { _, path in
                        projectRootRow(path: path)
                    }
                }
            }
            .frame(width: SettingsLayout.controlWidth, alignment: .leading)
        }
    }

    private var noteText: String {
        let suggested = ProjectDiscovery.defaultRootDirectoryURL().path
        return "Each folder is the parent of your project repositories, not a single repo. Suggested: \(suggested)"
    }

    private func projectRootRow(path: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(path)
                .font(.body.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                revealInFinder(path)
            } label: {
                Image(systemName: "arrow.up.right.square")
            }
            .buttonStyle(.borderless)
            .help("Reveal in Finder")
            Button {
                viewModel.removeProjectsRootPath(path)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove this folder")
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(AppTheme.contentSubtleFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

// MARK: - Appearance

private struct AppearanceSettingsTab: View {
    var viewModel: AppViewModel

    @State private var draft: Theme = .defaultTheme
    @State private var commitTask: Task<Void, Never>?
    @State private var isConfirmingDelete = false

    var body: some View {
        SettingsForm {
            themePickerSection
            if isEditingCustomTheme {
                editorSection
            } else {
                presetNoteSection
            }
            previewSection
            appIconSection
        }
        .onAppear { draft = selectedTheme }
        .onChange(of: viewModel.appSettings.selectedThemeID) { _, _ in
            commitTask?.cancel()
            // Flush any un-committed edits to the theme we are leaving.
            if !draft.isBuiltIn {
                viewModel.updateCustomTheme(draft)
            }
            draft = selectedTheme
        }
        .onChange(of: draft) { _, newValue in
            scheduleThemeCommit(newValue)
        }
    }

    // MARK: Derived state

    private var allThemes: [Theme] {
        Theme.builtInThemes + viewModel.appSettings.customThemes
    }

    private var selectedTheme: Theme {
        allThemes.first { $0.id == viewModel.appSettings.selectedThemeID } ?? .defaultTheme
    }

    private var isEditingCustomTheme: Bool {
        !selectedTheme.isBuiltIn
    }

    /// The live draft while editing a custom theme, otherwise the selected preset.
    private var previewTheme: Theme {
        isEditingCustomTheme ? draft : selectedTheme
    }

    // MARK: Theme picker

    private var themePickerSection: some View {
        SettingsSection {
            groupHeader("Presets")
            ForEach(allThemes.filter(\.isBuiltIn)) { themeRow($0) }

            let customThemes = viewModel.appSettings.customThemes
            if !customThemes.isEmpty {
                groupHeader("My Themes")
                ForEach(customThemes) { themeRow($0) }
            }

            Divider()
                .padding(.vertical, 4)

            HStack(spacing: 8) {
                Button("New Theme", action: createTheme)
                    .appSecondaryButton()
                Button("Duplicate", action: duplicateSelectedTheme)
                    .appSecondaryButton()
                if isEditingCustomTheme {
                    Button("Delete", role: .destructive) { isConfirmingDelete = true }
                        .appSecondaryButton()
                }
                Spacer(minLength: 0)
            }
        }
        .alert("Delete “\(selectedTheme.name)”?", isPresented: $isConfirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                viewModel.deleteCustomTheme(id: selectedTheme.id)
            }
        } message: {
            Text("This custom theme will be removed. Built-in presets are not affected.")
        }
    }

    private func groupHeader(_ title: String) -> some View {
        SettingsGroupHeader(title: title)
    }

    private func themeRow(_ theme: Theme) -> some View {
        let isSelected = theme.id == viewModel.appSettings.selectedThemeID
        return Button {
            viewModel.selectTheme(id: theme.id)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? AppTheme.brandAccent : Color.secondary)
                Text(theme.name)
                    .fontWeight(isSelected ? .semibold : .regular)
                Spacer(minLength: 12)
                swatchStrip(theme)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? AppTheme.accentSelectionFill : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? AppTheme.accentSelectionStroke : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func swatchStrip(_ theme: Theme) -> some View {
        HStack(spacing: 3) {
            ForEach(Array(theme.previewSwatches.enumerated()), id: \.offset) { item in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(item.element.color)
                    .frame(width: 14, height: 14)
            }
        }
    }

    // MARK: Custom theme editor

    private var editorSection: some View {
        SettingsSection {
            SettingsRow(title: "Theme name:") {
                AppTextField(text: nameBinding, placeholder: "Theme name")
                    .frame(width: 220)
            }
            colorRow("Background", \.background, note: "The window and app canvas.")
            colorRow("Surface", \.surface, note: "Panels, cards, sidebar, and list rows.")
            colorRow("Border", \.stroke, note: "Separators and card outlines.")
            colorRow("Accent", \.accent, note: "Buttons, links, and selection highlights.")
            colorRow("You", \.assistant, note: "User-side transcript bubbles and secondary accents.")
            colorRow("Thinking", \.thinking)
            colorRow("Tool calls", \.tool)
            colorRow("Errors", \.error)
            colorRow("Stderr", \.stderr)
            colorRow("Diff added", \.diffAdded)
            colorRow("Built-in source", \.sourceBuiltin, note: "Avatar tint for bundled agents, prompts, and skills.")
            colorRow("Library source", \.sourceLibrary, note: "Avatar tint for items in your library.")
            colorRow("Project source", \.sourceProject, note: "Avatar tint for project-assigned items.")

            SettingsRow(
                title: "Accent shades:",
                alignment: .top,
                note: "Auto-derived from the accent for gradients and depth."
            ) {
                HStack(spacing: 8) {
                    derivedSwatch(draft.accentBright, label: "Bright")
                    derivedSwatch(draft.accent, label: "Accent")
                    derivedSwatch(draft.accentDeep, label: "Deep")
                    derivedSwatch(draft.accentShadow, label: "Shadow")
                }
            }
        }
    }

    private func colorRow(
        _ title: String,
        _ keyPath: WritableKeyPath<Theme, ThemeColor>,
        note: String? = nil
    ) -> some View {
        SettingsRow(title: "\(title):", alignment: .top, note: note) {
            ColorPicker("", selection: colorBinding(keyPath), supportsOpacity: false)
                .labelsHidden()
                .frame(width: SettingsLayout.controlWidth, alignment: .leading)
        }
    }

    private func derivedSwatch(_ color: ThemeColor, label: String) -> some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(color.color)
                .frame(width: 44, height: 24)
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(AppTheme.hairlineStroke, lineWidth: 1)
                )
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var presetNoteSection: some View {
        SettingsSection {
            SettingsNote(text: "“\(selectedTheme.name)” is a built-in preset and can't be edited. Use Duplicate to make an editable copy.")
        }
    }

    // MARK: Live preview

    private var previewSection: some View {
        SettingsSection {
            groupHeader("Preview")
            VStack(alignment: .leading, spacing: 8) {
                previewBubble(previewTheme.assistant, systemIcon: "person.fill", role: "You", text: "Add a theme picker to the settings screen.")
                previewBubble(previewTheme.accent, assetIcon: "pi", role: "Assistant", text: "I fixed the custom theme alignment and corrected the color mapping.")
                previewBubble(previewTheme.thinking, systemIcon: "brain", role: "Thinking", text: "Weighing a few layout options…")
                previewBubble(previewTheme.tool, systemIcon: "wrench.and.screwdriver.fill", role: "Tool", text: "Edit DesignSystem.swift")
                previewBubble(previewTheme.error, systemIcon: "exclamationmark.triangle.fill", role: "Error", text: "Could not read the file.")

                HStack(spacing: 12) {
                    Text("Primary Action")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule(style: .continuous).fill(
                                LinearGradient(
                                    colors: [previewTheme.accentBright.color, previewTheme.accent.color],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        )

                    HStack(spacing: 10) {
                        Text("+ added line")
                            .foregroundStyle(previewTheme.diffAdded.color)
                        Text("- removed line")
                            .foregroundStyle(previewTheme.error.color)
                    }
                    .font(.caption.monospaced())

                    Spacer(minLength: 0)
                }
                .padding(.top, 2)
            }
        }
    }

    private func previewBubble(
        _ color: ThemeColor,
        systemIcon: String? = nil,
        assetIcon: String? = nil,
        role: String,
        text: String
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
                if let systemIcon {
                    Image(systemName: systemIcon)
                        .font(.caption)
                        .foregroundStyle(color.color)
                } else if let assetIcon {
                    Image(assetIcon)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(color.color)
                        .frame(width: 12, height: 12)
                }
            }
            .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(role)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color.color)
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.primary)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(color.color.opacity(AppTheme.roleFillOpacity))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(color.color.opacity(AppTheme.roleStrokeOpacity), lineWidth: 1)
        )
    }

    // MARK: Bindings & actions

    private var nameBinding: Binding<String> {
        Binding(
            get: { draft.name },
            set: { draft.name = $0 }
        )
    }

    private func colorBinding(_ keyPath: WritableKeyPath<Theme, ThemeColor>) -> Binding<Color> {
        Binding(
            get: { draft[keyPath: keyPath].color },
            set: { draft[keyPath: keyPath] = ThemeColor(color: $0) }
        )
    }

    private func createTheme() {
        let base = Theme.defaultTheme
        let newTheme = Theme(
            name: "Custom Theme",
            isBuiltIn: false,
            accent: base.accent,
            assistant: base.assistant,
            thinking: base.thinking,
            tool: base.tool,
            error: base.error,
            stderr: base.stderr,
            diffAdded: base.diffAdded,
            sourceBuiltin: base.sourceBuiltin,
            sourceLibrary: base.sourceLibrary,
            sourceProject: base.sourceProject
        )
        viewModel.addCustomTheme(newTheme)
        viewModel.selectTheme(id: newTheme.id)
    }

    private func duplicateSelectedTheme() {
        guard let copy = viewModel.duplicateTheme(id: selectedTheme.id) else { return }
        viewModel.selectTheme(id: copy.id)
    }

    /// Debounced so a `ColorPicker` drag does not re-key the main window on
    /// every frame — the in-tab preview already updates live from `draft`.
    private func scheduleThemeCommit(_ theme: Theme) {
        guard !theme.isBuiltIn else { return }
        commitTask?.cancel()
        commitTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            viewModel.updateCustomTheme(theme)
        }
    }

    // MARK: App icon

    private var appIconSection: some View {
        SettingsSection {
            groupHeader("App Icon")
            HStack(spacing: 12) {
                ForEach(AppIconChoice.allCases) { choice in
                    appIconTile(choice)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 2)
        }
    }

    private func appIconTile(_ choice: AppIconChoice) -> some View {
        let isSelected = choice == viewModel.selectedAppIcon
        return Button {
            viewModel.selectAppIcon(choice)
        } label: {
            VStack(spacing: 6) {
                Image(nsImage: NSImage(named: choice.assetName) ?? NSImage())
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 64, height: 64)
                    .padding(4)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(isSelected ? AppTheme.accentSelectionFill : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(isSelected ? AppTheme.brandAccent : AppTheme.hairlineStroke,
                                    lineWidth: isSelected ? 2 : 1)
                    )
                Text(choice.displayName)
                    .font(.caption2)
                    .foregroundStyle(isSelected ? AppTheme.brandAccent : .secondary)
                    .fontWeight(isSelected ? .semibold : .regular)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(choice.displayName)
    }
}

// MARK: - Agent

private struct AgentSettingsTab: View {
    var viewModel: AppViewModel

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
                    title: "Deck agents:",
                    label: "Enable Deck agents by default",
                    note: "Applies to newly created Pi Agent drafts and sessions. Already-running sessions keep the instructions they launched with.",
                    isOn: newSessionsSubagentsBinding
                )

                SettingsRow(
                    title: "Delegation policy:",
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Delegation policy", selection: subagentDelegationPolicyBinding) {
                            ForEach(NativeSubagentDelegationPolicy.allCases) { policy in
                                Text(policy.displayName).tag(policy)
                            }
                        }
                        .appSegmentedPicker()
                        .labelsHidden()
                        .frame(width: SettingsLayout.controlWidth, alignment: .leading)

                        Text(viewModel.appSettings.nativeSubagentDelegationPolicy.settingsDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .disabled(!viewModel.areSubagentsEnabledForNewSessions)
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
                            .appBrandTint()
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
                        .appSecondaryButton()
                    Button("Use macOS Default") { viewModel.resetPiAgentTerminalApplicationToDefault() }
                        .appSecondaryButton()
                }

                SettingsRow(title: "") {
                    Text("Supported terminals: \(SupportedTerminal.displayList). Others (such as Warp) can't be driven to open a new window and run a command.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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

    private var newSessionsSubagentsBinding: Binding<Bool> {
        Binding(
            get: { viewModel.areSubagentsEnabledForNewSessions },
            set: { viewModel.setSubagentsEnabledForNewSessions($0) }
        )
    }

    private var subagentDelegationPolicyBinding: Binding<NativeSubagentDelegationPolicy> {
        Binding(
            get: { viewModel.appSettings.nativeSubagentDelegationPolicy },
            set: { viewModel.setNativeSubagentDelegationPolicy($0) }
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
    var viewModel: AppViewModel

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
                        .appSecondaryButton()
                    }
                    .font(.footnote)
                    .padding(.leading, SettingsLayout.labelWidth + 16)
                }
            }

            SettingsSection {
                SettingsToggleRow(
                    title: "Worktree isolation:",
                    label: "Run each new session in its own git branch + worktree",
                    note: "Off by default. When enabled, every new session creates a branch named agent-deck/session-<id> and an isolated working copy under ~/Library/Application Support/agent-deck/Session Worktrees/. Use the Merge toolbar button to bring the work back into the source branch. Only affects new sessions; existing sessions stay in the project root.",
                    isOn: sessionsUseWorktreeBinding
                )

                SettingsToggleRow(
                    title: "Keep after merge:",
                    label: "Keep worktree and branch after a successful merge",
                    note: "On by default. A successful Merge lands the work on the source branch and preserves the session worktree and branch so you can keep iterating and merge again later. Turn off if you'd rather have the worktree removed and the branch deleted as soon as it's merged. Deleting a session from the list always removes its worktree regardless of this setting. Only matters when Worktree isolation is on.",
                    isOn: keepWorktreeAfterMergeBinding
                )
                .disabled(!viewModel.appSettings.piAgentSessionsUseWorktree)
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

            SettingsSection {
                SettingsPickerRow(
                    title: "Skill summaries:",
                    selection: skillDescriptionModelBinding,
                    note: skillDescriptionModelNote
                ) {
                    Text("Default (Foundation Models if available)").tag("")
                    ForEach(viewModel.automationAvailableModels, id: \.identifier) { model in
                        Text(model.displayName).tag(model.identifier)
                    }
                }
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

    private var sessionsUseWorktreeBinding: Binding<Bool> {
        Binding(
            get: { viewModel.appSettings.piAgentSessionsUseWorktree },
            set: { viewModel.setPiAgentSessionsUseWorktree($0) }
        )
    }

    private var keepWorktreeAfterMergeBinding: Binding<Bool> {
        Binding(
            get: { viewModel.appSettings.piAgentSessionsKeepWorktreeAfterMerge },
            set: { viewModel.setPiAgentSessionsKeepWorktreeAfterMerge($0) }
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

    private var skillDescriptionModelBinding: Binding<String> {
        Binding(
            get: { viewModel.appSettings.skillDescriptionModelIdentifier ?? "" },
            set: { viewModel.setSkillDescriptionModelIdentifier($0) }
        )
    }

    private var skillDescriptionModelNote: String {
        let resolved = viewModel.skillDescriptionGenerationModel()
        guard let resolved else {
            return "Powers the ✨ summary button in the Import Skills sheet. Pick a model — Apple Foundation Models is unavailable on this Mac, so the button stays hidden until one is selected."
        }
        if resolved.identifier == FoundationModelAutomationService.identifier {
            return "Powers the ✨ summary button in the Import Skills sheet. Apple Foundation Models runs locally on-device."
        }
        return "Powers the ✨ summary button in the Import Skills sheet, in a hidden no-thinking Pi helper session."
    }
}

// MARK: - Performance

private struct PerformanceSettingsTab: View {
    var viewModel: AppViewModel

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
}

// MARK: - Commands

private struct CommandsSettingsTab: View {
    var viewModel: AppViewModel

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
                .appSecondaryButton()
            }

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

            SettingsNote(text: "Changes apply to newly started or resumed RPC sessions. Restart an active Pi session to change which injected commands it has loaded.")
                .padding(.horizontal, 14)
        }
    }

    private func revealCommandLibraryInFinder() {
        let appSupport = URL.applicationSupportDirectory
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
    var viewModel: AppViewModel

    var body: some View {
        SettingsSection {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption.italic())
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 0) {
                ForEach(commands) { command in
                    CommandSettingsRow(command: command, viewModel: viewModel)

                    if command.id != commands.last?.id {
                        Divider()
                            .padding(.leading, 2)
                    }
                }
            }
        }
    }
}

private struct CommandSettingsRow: View {
    let command: PiInjectedCommand
    var viewModel: AppViewModel

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
            .appSwitch()
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
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
            ForEach(sections) { section in
                SettingsSection {
                    SettingsGroupHeader(title: section.title)

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
    var viewModel: AppViewModel

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
    var viewModel: AppViewModel

    var body: some View {
        SettingsForm {
            SettingsSection {
                SettingsToggleRow(
                    title: "New sessions:",
                    label: "Enable Deck agents by default",
                    note: "Applies to newly created Pi Agent drafts and sessions. After the first message starts Pi, the session footer becomes read-only.",
                    isOn: newSessionsSubagentsBinding
                )

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

    private var newSessionsSubagentsBinding: Binding<Bool> {
        Binding(
            get: { viewModel.areSubagentsEnabledForNewSessions },
            set: { viewModel.setSubagentsEnabledForNewSessions($0) }
        )
    }
}

private func revealInFinder(_ path: String?) {
    guard let path, !path.isEmpty else { return }
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
}

#Preview {
    SettingsSceneContent()
        .environment(AppViewModel())
}
