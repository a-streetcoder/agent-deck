import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsSceneContent: View {
    @Environment(AppViewModel.self) private var viewModel
    @ObservedObject private var languageStore = LanguageStore.shared
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
                label: { languageStore.t($0.l10nKey) },
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
        case .performance:
            PerformanceSettingsTab(viewModel: viewModel)
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
    case performance = "Performance"
    case commands = "Commands"
    case shortcuts = "Shortcuts"

    var id: String { rawValue }

    /// Stable `Localizable.strings` key for the tab label.
    var l10nKey: String {
        switch self {
        case .general: return "settings.tab.general"
        case .appearance: return "settings.tab.appearance"
        case .agent: return "settings.tab.agent"
        case .automations: return "settings.tab.automations"
        case .performance: return "settings.tab.performance"
        case .commands: return "settings.tab.commands"
        case .shortcuts: return "settings.tab.shortcuts"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintpalette"
        case .agent: return "sparkles.rectangle.stack"
        case .automations: return "wand.and.stars"
        case .performance: return "speedometer"
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
                    .font(.system(size: 20, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(iconStyle)
                    .frame(height: 24)
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
            .font(AppTheme.Font.micro.weight(.semibold))
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
    @ObservedObject private var languageStore = LanguageStore.shared

    @State private var isAvatarImporterPresented = false

    var body: some View {
        SettingsForm {
            SettingsSection {
                SettingsRow(
                    title: languageStore.t("settings.profile.name"),
                    note: languageStore.t("settings.profile.nameHelp")
                ) {
                    TextField(
                        languageStore.t("settings.profile.namePlaceholder"),
                        text: Binding(
                            get: { viewModel.appSettings.userDisplayName },
                            set: { viewModel.setUserDisplayName($0) }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(width: SettingsLayout.controlWidth, alignment: .leading)
                }

                SettingsRow(
                    title: languageStore.t("settings.profile.avatar"),
                    note: languageStore.t("settings.profile.avatarHelp")
                ) {
                    HStack(spacing: 12) {
                        userAvatarPreview
                        Button(languageStore.t("settings.profile.chooseAvatar")) {
                            isAvatarImporterPresented = true
                        }
                        .appSecondaryButton()
                        if viewModel.appSettings.userAvatarFileName != nil {
                            Button(languageStore.t("settings.profile.clearAvatar")) {
                                viewModel.clearUserAvatar()
                            }
                            .appSecondaryButton()
                        }
                    }
                    .frame(width: SettingsLayout.controlWidth, alignment: .leading)
                }
            }

            SettingsSection {
                SettingsRow(
                    title: languageStore.t("settings.language"),
                    note: languageStore.t("settings.languageHelp")
                ) {
                    Picker("", selection: Binding(
                        get: { languageStore.language },
                        set: { languageStore.setLanguage($0) }
                    )) {
                        ForEach(AppLanguage.allCases) { lang in
                            Text(lang.menuLabel).tag(lang)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: SettingsLayout.controlWidth, alignment: .leading)
                }
            }

            SettingsSection {
                ProjectsRootListRow(viewModel: viewModel)

                SettingsButtonRow {
                    Button(languageStore.t("settings.addFolder")) { viewModel.chooseProjectsRootDirectory() }
                        .appSecondaryButton()
                    Button(languageStore.t("settings.useSuggested")) { viewModel.useSuggestedProjectsRootDirectory() }
                        .appSecondaryButton()
                        .disabled(viewModel.suggestedProjectsRootPath == nil)
                    Button(languageStore.t("settings.resetToDefault")) { viewModel.resetProjectsRootPathsToDefault() }
                        .appSecondaryButton()
                }
            }

            SettingsSection {
                SettingsValueButtonRow(
                    title: languageStore.t("settings.skillRepositories"),
                    value: SkillRepositorySyncService.repositoriesDirectoryURL().path
                ) {
                    Button(languageStore.t("settings.revealInFinder")) {
                        let url = SkillRepositorySyncService.repositoriesDirectoryURL()
                        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                        revealInFinder(url.path)
                    }
                    .appSecondaryButton()
                }
            }
        }
        .fileImporter(
            isPresented: $isAvatarImporterPresented,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            viewModel.setUserAvatar(from: url)
        }
    }

    @ViewBuilder
    private var userAvatarPreview: some View {
        let size: CGFloat = 40
        Group {
            if let url = viewModel.userAvatarImageURL,
               let ns = NSImage(contentsOf: url) {
                Image(nsImage: ns)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
                    .padding(6)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(AppTheme.contentStroke, lineWidth: 1))
    }
}

/// Settings row that lists every configured projects-root folder. Each row
/// exposes Reveal / Remove; the parent section provides Add / Use Suggested
/// / Reset.
private struct ProjectsRootListRow: View {
    var viewModel: AppViewModel
    @ObservedObject private var languageStore = LanguageStore.shared

    var body: some View {
        // Read raw `appSettings.projectsRootPaths` directly (not the
        // controller-derived helper) so SwiftUI's @Observable dependency
        // tracking re-renders the row immediately when the list mutates.
        // Going via `viewModel.configuredProjectsRootPaths` reads through
        // the non-observable AppSettingsController and the row would only
        // refresh on next view re-creation (e.g. tab switch).
        let paths = viewModel.appSettings.projectsRootPaths
        SettingsRow(
            title: languageStore.t("settings.projectsFolders"),
            alignment: .top,
            note: noteText
        ) {
            VStack(alignment: .leading, spacing: 6) {
                if paths.isEmpty {
                    Text(languageStore.t("settings.projectsFoldersEmpty"))
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
        return languageStore.t("settings.projectsFoldersNote", suggested)
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
                    .appActionTarget()
            }
            .buttonStyle(.borderless)
            .help(languageStore.t("settings.revealInFinder"))
            .accessibilityLabel(languageStore.t("settings.revealPathA11y", path))
            Button {
                viewModel.removeProjectsRootPath(path)
            } label: {
                Image(systemName: "minus.circle")
                    .appActionTarget()
            }
            .buttonStyle(.borderless)
            .help(languageStore.t("settings.removeFolder"))
            .accessibilityLabel(languageStore.t("settings.removeFolderA11y", path))
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
            markdownSection
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

    // MARK: Chat text

    private var markdownSection: some View {
        SettingsSection {
            groupHeader("Chat")
            SettingsToggleRow(
                title: LanguageStore.shared.t("settings.markdown"),
                label: LanguageStore.shared.t("settings.useThemeColors"),
                note: LanguageStore.shared.t("settings.markdownNote"),
                isOn: Binding(
                    get: { viewModel.appSettings.piAgentMarkdownHighlightingEnabled },
                    set: { viewModel.setPiAgentMarkdownHighlightingEnabled($0) }
                )
            )
        }
    }

    // MARK: Theme picker

    private var themePickerSection: some View {
        SettingsSection {
            groupHeader("Presets")
            ForEach(allThemes.filter(\.isBuiltIn)) { themeRow($0) }

            let customThemes = viewModel.appSettings.customThemes
            if !customThemes.isEmpty {
                groupHeader(LanguageStore.shared.t("settings.myThemes"))
                ForEach(customThemes) { themeRow($0) }
            }

            Divider()
                .padding(.vertical, 4)

            HStack(spacing: 8) {
                Button(LanguageStore.shared.t("settings.newTheme"), action: createTheme)
                    .appSecondaryButton()
                Button(LanguageStore.shared.t("settings.duplicate"), action: duplicateSelectedTheme)
                    .appSecondaryButton()
                if isEditingCustomTheme {
                    Button(LanguageStore.shared.t("common.delete"), role: .destructive) { isConfirmingDelete = true }
                        .appSecondaryButton()
                }
                Spacer(minLength: 0)
            }
        }
        .alert(LanguageStore.shared.t("settings.deleteThemeTitle", selectedTheme.name), isPresented: $isConfirmingDelete) {
            Button(LanguageStore.shared.t("common.cancel"), role: .cancel) {}
            Button(LanguageStore.shared.t("common.delete"), role: .destructive) {
                viewModel.deleteCustomTheme(id: selectedTheme.id)
            }
        } message: {
            Text(LanguageStore.shared.t("settings.themeRemoveBody"))
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
            SettingsRow(title: LanguageStore.shared.t("settings.themeName")) {
                AppTextField(text: nameBinding, placeholder: LanguageStore.shared.t("settings.themeNameA11y"))
                    .frame(width: 220)
            }
            colorRow("Background", \.background, note: "The window and app canvas.")
            colorRow("Surface", \.surface, note: "Panels, cards, sidebar, and list rows.")
            colorRow("Border", \.stroke, note: "Separators and card outlines.")
            colorRow(LanguageStore.shared.t("settings.colorAccent"), \.accent, note: LanguageStore.shared.t("settings.colorAccentNote"))
            colorRow(LanguageStore.shared.t("settings.colorYou"), \.assistant, note: LanguageStore.shared.t("settings.colorYouNote"))
            colorRow("Thinking", \.thinking)
            colorRow("Tool calls", \.tool)
            colorRow("Errors", \.error)
            colorRow("Stderr", \.stderr)
            colorRow("Diff added", \.diffAdded)
            colorRow("Built-in source", \.sourceBuiltin, note: "Avatar tint for bundled agents, prompts, and skills.")
            colorRow("Library source", \.sourceLibrary, note: "Avatar tint for items in your library.")
            colorRow("Project source", \.sourceProject, note: "Avatar tint for project-assigned items.")

            SettingsRow(
                title: LanguageStore.shared.t("settings.accentShades"),
                alignment: .top,
                note: LanguageStore.shared.t("settings.accentShadesNote")
            ) {
                HStack(spacing: 8) {
                    derivedSwatch(draft.accentBright, label: LanguageStore.shared.t("settings.colorBright"))
                    derivedSwatch(draft.accent, label: LanguageStore.shared.t("settings.colorAccent"))
                    derivedSwatch(draft.accentDeep, label: LanguageStore.shared.t("settings.colorDeep"))
                    derivedSwatch(draft.accentShadow, label: LanguageStore.shared.t("settings.colorShadow"))
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
                .font(AppTheme.Font.micro)
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
                previewBubble(previewTheme.assistant, systemIcon: "person.fill", role: LanguageStore.shared.t("settings.roleYou"), text: "Add a theme picker to the settings screen.")
                previewBubble(previewTheme.accent, assetIcon: "pi", role: LanguageStore.shared.t("settings.roleAssistant"), text: "I fixed the custom theme alignment and corrected the color mapping.")
                previewBubble(previewTheme.thinking, systemIcon: "brain.head.profile", role: LanguageStore.shared.t("settings.roleThinking"), text: "Weighing a few layout options…")
                previewBubble(previewTheme.tool, systemIcon: "wrench.and.screwdriver.fill", role: LanguageStore.shared.t("settings.roleTool"), text: "Edit DesignSystem.swift")
                previewBubble(previewTheme.error, systemIcon: "exclamationmark.triangle.fill", role: LanguageStore.shared.t("settings.roleError"), text: "Could not read the file.")

                HStack(spacing: 12) {
                    Text(LanguageStore.shared.t("settings.primaryAction"))
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
                    .font(AppTheme.Font.micro)
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
    @ObservedObject private var languageStore = LanguageStore.shared

    var body: some View {
        SettingsForm {
            SettingsSection {
                SettingsStepperRow(
                    title: languageStore.t("settings.agent.notificationDelay"),
                    value: piAgentNotificationDelayBinding,
                    range: 1...60,
                    valueText: languageStore.t("common.minutes", viewModel.piAgentNotificationDelayMinutes),
                    note: languageStore.t("settings.agent.notificationDelayNote")
                )
            }

            SettingsSection {
                SettingsToggleRow(
                    title: languageStore.t("settings.agent.deckAgents"),
                    label: languageStore.t("settings.agent.deckAgentsLabel"),
                    note: languageStore.t("settings.agent.deckAgentsNote"),
                    isOn: newSessionsSubagentsBinding
                )

                SettingsRow(
                    title: languageStore.t("settings.agent.delegation"),
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker(languageStore.t("settings.agent.delegationA11y"), selection: subagentDelegationPolicyBinding) {
                            ForEach(NativeSubagentDelegationPolicy.allCases) { policy in
                                Text(languageStore.t(policy.l10nTitleKey)).tag(policy)
                            }
                        }
                        .appSegmentedPicker()
                        .labelsHidden()
                        .frame(width: SettingsLayout.controlWidth, alignment: .leading)

                        Text(languageStore.t(viewModel.appSettings.nativeSubagentDelegationPolicy.l10nDescriptionKey))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .disabled(!viewModel.areSubagentsEnabledForNewSessions)
            }

            SettingsSection {
                SettingsToggleRow(
                    title: languageStore.t("settings.agent.contextZones"),
                    label: languageStore.t("settings.agent.contextZonesLabel"),
                    note: languageStore.t("settings.agent.contextZonesNote"),
                    isOn: showContextSmartZoneHintBinding
                )

                SettingsRow(title: "") {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(languageStore.t("settings.agent.contextQuote"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Link(languageStore.t("settings.agent.readArticle"), destination: URL(string: "https://www.aihero.dev/why-the-anthropic-ralph-plugin-sucks")!)
                            .font(.caption.weight(.semibold))
                            .appBrandTint()
                    }
                }
            }

            SettingsSection {
                SettingsPickerRow(title: languageStore.t("settings.agent.terminalApp"), selection: piAgentTerminalApplicationSelectionBinding) {
                    ForEach(viewModel.piAgentTerminalApplicationOptions) { option in
                        Text(option.name).tag(option.id)
                    }
                }

                SettingsValueButtonRow(title: languageStore.t("settings.agent.application"), value: selectedTerminalPathText) {
                    Button(languageStore.t("settings.agent.chooseOther")) { viewModel.choosePiAgentTerminalApplication() }
                        .appSecondaryButton()
                    Button(languageStore.t("settings.agent.useMacOSDefault")) { viewModel.resetPiAgentTerminalApplicationToDefault() }
                        .appSecondaryButton()
                }

                SettingsRow(title: "") {
                    Text(languageStore.t("settings.agent.terminalSupport", SupportedTerminal.displayList))
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
        viewModel.appSettings.piAgentTerminalApplicationPath ?? languageStore.t("settings.agent.macOSDefault")
    }
}


// MARK: - Automations

private struct AutomationsSettingsTab: View {
    var viewModel: AppViewModel
    @ObservedObject private var languageStore = LanguageStore.shared

    var body: some View {
        SettingsForm {
            SettingsSection {
                SettingsToggleRow(
                    title: languageStore.t("settings.auto.sessionTitles"),
                    label: languageStore.t("settings.auto.sessionTitlesLabel"),
                    note: languageStore.t("settings.auto.sessionTitlesNote"),
                    isOn: autoGenerateSessionTitlesBinding
                )

                SettingsToggleRow(
                    title: languageStore.t("settings.auto.updateTitles"),
                    label: languageStore.t("settings.auto.updateTitlesLabel"),
                    note: languageStore.t("settings.auto.updateTitlesNote"),
                    isOn: autoUpdateSessionTitlesBinding
                )
                .disabled(!viewModel.appSettings.autoGeneratePiAgentSessionTitles)

                SettingsPickerRow(
                    title: languageStore.t("settings.auto.titleModel"),
                    selection: titleGenerationModelBinding,
                    note: languageStore.t("settings.auto.titleModelNote")
                ) {
                    Text(languageStore.t("common.defaultModel")).tag("")
                    ForEach(viewModel.automationAvailableModels, id: \.identifier) { model in
                        Text(model.displayName).tag(model.identifier)
                    }
                }
            }

            SettingsSection {
                SettingsToggleRow(
                    title: languageStore.t("settings.auto.gitActions"),
                    label: languageStore.t("settings.auto.gitActionsLabel"),
                    note: languageStore.t("settings.auto.gitActionsNote"),
                    isOn: gitAutomationEnabledBinding
                )

                SettingsToggleRow(
                    title: languageStore.t("settings.auto.confirmActions"),
                    label: languageStore.t("settings.auto.confirmActionsLabel"),
                    note: languageStore.t("settings.auto.confirmActionsNote"),
                    isOn: gitAutomationConfirmationBinding
                )
                .disabled(!viewModel.appSettings.piAgentGitAutomationEnabled)

                SettingsPickerRow(
                    title: languageStore.t("settings.auto.commitModel"),
                    selection: commitMessageModelBinding,
                    note: languageStore.t("settings.auto.commitModelNote")
                ) {
                    Text(languageStore.t("common.defaultModel")).tag("")
                    ForEach(viewModel.automationAvailableModels, id: \.identifier) { model in
                        Text(model.displayName).tag(model.identifier)
                    }
                }
                .disabled(!viewModel.appSettings.piAgentGitAutomationEnabled)

                if viewModel.automationAvailableModels.isEmpty {
                    HStack(spacing: 8) {
                        Label(languageStore.t("settings.auto.noModels"), systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button(languageStore.t("common.refreshModels")) {
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
                    title: languageStore.t("settings.auto.worktree"),
                    label: languageStore.t("settings.auto.worktreeLabel"),
                    note: languageStore.t("settings.auto.worktreeNote"),
                    isOn: sessionsUseWorktreeBinding
                )

                SettingsToggleRow(
                    title: languageStore.t("settings.auto.keepAfterMerge"),
                    label: languageStore.t("settings.auto.keepAfterMergeLabel"),
                    note: languageStore.t("settings.auto.keepAfterMergeNote"),
                    isOn: keepWorktreeAfterMergeBinding
                )
                .disabled(!viewModel.appSettings.piAgentSessionsUseWorktree)
            }

            SettingsSection {
                SettingsToggleRow(
                    title: languageStore.t("settings.auto.agentAvatars"),
                    label: languageStore.t("settings.auto.agentAvatarsLabel"),
                    note: languageStore.t("settings.auto.agentAvatarsNote"),
                    isOn: agentAvatarPromptAutomationBinding
                )

                SettingsPickerRow(
                    title: languageStore.t("settings.auto.promptModel"),
                    selection: agentAvatarPromptModelBinding,
                    note: agentAvatarPromptModelNote
                ) {
                    Text(languageStore.t("common.defaultModel")).tag("")
                    ForEach(viewModel.automationAvailableModels, id: \.identifier) { model in
                        Text(model.displayName).tag(model.identifier)
                    }
                }
                .disabled(!viewModel.appSettings.autoGenerateAgentAvatarPrompts)
            }

            SettingsSection {
                SettingsPickerRow(
                    title: languageStore.t("settings.auto.skillSummaries"),
                    selection: skillDescriptionModelBinding,
                    note: skillDescriptionModelNote
                ) {
                    Text(languageStore.t("common.defaultModel")).tag("")
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
            return languageStore.t("settings.auto.avatarNote.foundation")
        }
        return languageStore.t("settings.auto.avatarNote.helper")
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
            return languageStore.t("settings.auto.skillNote.empty")
        }
        if resolved.identifier == FoundationModelAutomationService.identifier {
            return languageStore.t("settings.auto.skillNote.foundation")
        }
        return languageStore.t("settings.auto.skillNote.helper")
    }
}

// MARK: - Performance

private struct PerformanceSettingsTab: View {
    var viewModel: AppViewModel
    @ObservedObject private var languageStore = LanguageStore.shared

    var body: some View {
        SettingsForm {
            SettingsSection {
                SettingsToggleRow(
                    title: languageStore.t("settings.perf.idleParking"),
                    label: languageStore.t("settings.perf.idleParkingLabel"),
                    note: languageStore.t("settings.perf.idleParkingNote"),
                    isOn: piAgentIdleParkingEnabledBinding
                )

                SettingsStepperRow(
                    title: languageStore.t("settings.perf.parkingDelay"),
                    value: piAgentIdleParkingTimeoutBinding,
                    range: 1...120,
                    valueText: languageStore.t("common.minutes", viewModel.piAgentIdleParkingTimeoutMinutes),
                    note: languageStore.t("settings.perf.parkingDelayNote")
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
    @ObservedObject private var languageStore = LanguageStore.shared

    var body: some View {
        SettingsForm {
            SettingsSection {
                VStack(alignment: .leading, spacing: 6) {
                    Text(languageStore.t("settings.cmd.injectedTitle"))
                        .font(.headline)
                    SettingsNote(text: languageStore.t("settings.cmd.injectedNote", PiInjectedCommandCatalog.commandLibraryPath))
                }

                HStack {
                    Button {
                        viewModel.importCommandFile()
                    } label: {
                        Label(languageStore.t("settings.cmd.import"), systemImage: "square.and.arrow.down")
                    }
                    Button {
                        revealCommandLibraryInFinder()
                    } label: {
                        Label(languageStore.t("settings.cmd.revealLibrary"), systemImage: "folder")
                    }
                }
                .appSecondaryButton()
            }

            CommandGroupSection(
                title: languageStore.t("settings.cmd.bundledTitle"),
                subtitle: languageStore.t("settings.cmd.bundledSubtitle"),
                commands: PiInjectedCommandCatalog.all.filter { $0.source == .builtIn },
                viewModel: viewModel
            )

            let importedCommands = PiInjectedCommandCatalog.all.filter { $0.source == .library }
            if !importedCommands.isEmpty {
                CommandGroupSection(
                    title: languageStore.t("settings.cmd.importedTitle"),
                    subtitle: languageStore.t("settings.cmd.importedSubtitle"),
                    commands: importedCommands,
                    viewModel: viewModel
                )
            }

            SettingsNote(text: languageStore.t("settings.cmd.changesNote"))
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
    @ObservedObject private var languageStore = LanguageStore.shared

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
                        .font(AppTheme.Font.micro.monospaced())
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
        Label(command.source == .builtIn ? languageStore.t("settings.cmd.bundledTag") : languageStore.t("settings.cmd.importedTitle"), systemImage: command.source == .builtIn ? "shippingbox" : "square.and.arrow.down")
            .font(AppTheme.Font.micro.weight(.semibold))
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
    @ObservedObject private var languageStore = LanguageStore.shared
    private let sections = AgentDeckShortcutSection.all

    var body: some View {
        let _ = languageStore.language
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
        case "upArrow": return "↑"
        case "downArrow": return "↓"
        case "leftArrow": return "←"
        case "rightArrow": return "→"
        case " ": return "Space"
        default: return key.uppercased()
        }
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
