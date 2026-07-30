import AppKit
import OSLog
import SwiftUI

struct PromptsScreen: View {
    private static let layoutLog = Logger(subsystem: "works.earendil.pi-deck", category: "ResourceLayout")
    var viewModel: AppViewModel
    @Binding var searchText: String
    @ObservedObject private var languageStore = LanguageStore.shared
    @State private var promptPendingRename: PromptTemplateRecord?
    @State private var promptPendingDeletion: PromptTemplateRecord?
    @State private var promptEditTarget: MarkdownFileEditTarget?
    // Local mirror for the `List` selection — the macOS `List` writes its
    // selection back during the SwiftUI update pass, so it binds to this
    // `@State` rather than straight onto the view model. `viewModel`'s
    // selection is synced from `.onChange`, which runs after the pass.
    // Mirrors the pattern in `SkillsScreen`.
    @State private var selectedCommandItemID: String?
    @State private var isRenamingPromptName = false
    @State private var draftPromptName = ""
    @State private var isPromptNameHovered = false
    @FocusState private var isPromptNameFocused: Bool
    @State private var renameErrorMessage: String?
    // Cached sectioning + filtered list. Pre-refactor `promptListSections`
    // rebuilt seven `.filter` passes over `visiblePrompts` (each of which
    // itself ran a multi-field substring search over every prompt body) on
    // every body eval — every selection click, hover, scroll. Recompute
    // only on input changes. Mirrors `AgentLibraryPane.cachedLayout`.
    @State private var cachedLayout: (
        sections: [AppListSection<PromptTemplateRecord>],
        visiblePrompts: [PromptTemplateRecord]
    ) = ([], [])

    var body: some View {
        SplitView {
            if viewModel.hasCompletedInitialRefresh {
                promptLibraryPane
                    .appDebugLayout("Prompts.libraryPane", logger: Self.layoutLog)
            } else {
                AppLoadingView(LanguageStore.shared.t("prompts.loading"))
                    .appDebugLayout("Prompts.libraryLoading", logger: Self.layoutLog)
            }
        } detail: {
            if !viewModel.hasCompletedInitialRefresh {
                AppLoadingView(LanguageStore.shared.t("prompts.loadingDetail"))
                    .appDebugLayout("Prompts.detailLoading", logger: Self.layoutLog)
            } else if let prompt = viewModel.selectedPromptTemplate {
                promptDetail(prompt)
                    .appDebugLayout("Prompts.detail selected=\(prompt.name) source=\(prompt.source.kind.rawValue)", logger: Self.layoutLog)
            } else {
                ContentUnavailableView(LanguageStore.shared.t("prompts.noneSelected"), systemImage: AppSymbols.promptTemplate)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .appDebugLayout("Prompts.detailEmpty", logger: Self.layoutLog)
            }
        }
        .appDebugLayout("Prompts.hsplit", logger: Self.layoutLog)
        .sheet(item: $promptPendingRename) { prompt in
            RenameResourceSheet(
                title: LanguageStore.shared.t("prompts.rename"),
                currentName: prompt.name,
                resourceLabel: "prompt",
                makePreview: { viewModel.renamePreview(for: prompt, to: $0) },
                onRename: { try viewModel.renamePrompt(prompt, to: $0) }
            )
        }
        .sheet(item: $promptEditTarget) { target in
            MarkdownFileEditorSheet(target: target) {
                // New prompt: queue selection by path and let async refresh
                // apply it. Edit-in-place: just kick a silent reconciliation.
                // Replaces the prior synchronous refresh that froze the UI.
                if target.isNew {
                    viewModel.scheduleSelectPrompt(byFilePath: target.path)
                } else {
                    viewModel.refresh(includeModels: false, scanAllProjects: true, silentlyReconcile: true)
                }
            }
        }
        .alert(LanguageStore.shared.t("prompts.deleteTitle"), isPresented: Binding(
            get: { promptPendingDeletion != nil },
            set: { if !$0 { promptPendingDeletion = nil } }
        ), presenting: promptPendingDeletion) { prompt in
            if prompt.discoveryKind == .externalReference {
                Button(LanguageStore.shared.t("prompts.removeReference"), role: .destructive) {
                    deletePrompt(prompt)
                }
            } else {
                Button(LanguageStore.shared.t("prompts.moveTrash"), role: .destructive) {
                    deletePrompt(prompt)
                }
            }
            Button(LanguageStore.shared.t("common.cancel"), role: .cancel) {
                promptPendingDeletion = nil
            }
        } message: { prompt in
            if prompt.discoveryKind == .externalReference {
                Text(LanguageStore.shared.t("prompts.stopReferencing", prompt.invocation))
            } else {
                Text(LanguageStore.shared.t("prompts.moveTrash", prompt.invocation))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .agentDeckNewPromptRequested)) { _ in
            createNewPrompt()
        }
        .onReceive(NotificationCenter.default.publisher(for: .agentDeckImportPromptRequested)) { _ in
            importPrompt()
        }
        .onAppear {
            logPromptLayoutState("appear")
            cachedLayout = recomputeLayout()
            scheduleSelectionSynchronization()
        }
        .onChange(of: viewModel.selectedCommandItemID) { _, _ in
            logPromptLayoutState("selectedCommandItemID")
            scheduleSelectionSynchronization()
        }
        .onChange(of: viewModel.allVisiblePromptTemplateRecords) { _, _ in
            cachedLayout = recomputeLayout()
            scheduleSelectionSynchronization()
        }
        // `cachedPromptWarnings` and friends rebuild alongside
        // `displayAgentsRevision` in `rebuildWarningCaches()`, so this catches
        // metadata-only changes without a separate prompt-revision counter.
        .onChange(of: viewModel.displayAgentsRevision) { _, _ in
            cachedLayout = recomputeLayout()
        }
        .onChange(of: searchText) { _, _ in
            cachedLayout = recomputeLayout()
            scheduleSelectionSynchronization()
        }
        .onChange(of: selectedCommandItemID) { _, id in
            guard viewModel.selectedCommandItemID != id else { return }
            viewModel.selectedCommandItemID = id
        }
    }

    private func logPromptLayoutState(_ event: String) {
        #if DEBUG
        let prompt = viewModel.selectedPromptTemplate
        Self.layoutLog.debug("Prompts.state event=\(event, privacy: .public) selectedID=\(selectedCommandItemID ?? "nil", privacy: .public) vmSelectedID=\(viewModel.selectedCommandItemID ?? "nil", privacy: .public) prompt=\(prompt?.name ?? "nil", privacy: .public) fileLength=\(prompt?.filePath.count ?? 0, privacy: .public) sections=\(cachedLayout.sections.count, privacy: .public) visible=\(cachedLayout.visiblePrompts.count, privacy: .public)")
        #endif
    }

    private var promptLibraryPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !viewModel.promptWarnings.isEmpty {
                promptWarningStrip
            }
            AppList(
                sections: promptListSections,
                selection: .single($selectedCommandItemID)
            ) { prompt in
                promptListRow(prompt)
            }
        }
    }

    @ViewBuilder
    private var promptWarningStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(LanguageStore.shared.t("prompts.warnings"))
                .font(AppTheme.Font.micro.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(.orange)
                .padding(.horizontal, 18)
                .padding(.top, 10)
                .padding(.bottom, 2)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(viewModel.promptWarnings) { warning in
                    promptWarningCard(warning)
                        .padding(.horizontal, 8)
                }
            }
            .padding(.bottom, 4)
        }
    }

    /// Reads from `cachedLayout`. The build logic lives in `recomputeLayout()`
    /// and runs only on input changes (snapshot, search, project).
    private var promptListSections: [AppListSection<PromptTemplateRecord>] {
        cachedLayout.sections
    }

    /// Mirrors the previous body-inlined `promptSection` blocks one-for-one —
    /// same source ordering, same empty-state messages. Called only from
    /// `.onAppear` / `.onChange` paths via `cachedLayout`.
    private func recomputeLayout() -> (
        sections: [AppListSection<PromptTemplateRecord>],
        visiblePrompts: [PromptTemplateRecord]
    ) {
        let prompts = viewModel.allVisiblePromptTemplateRecords
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let visible: [PromptTemplateRecord]
        if query.isEmpty {
            visible = prompts
        } else {
            visible = prompts.filter { prompt in
                [prompt.name, prompt.invocation, prompt.description, prompt.source.kind.rawValue, prompt.filePath, prompt.body]
                    .contains { $0.lowercased().contains(query) }
            }
        }

        let globalPrompts = visible.filter { $0.source.kind == .global && $0.discoveryKind == .standardDirectory }
        let libraryPrompts = visible.filter { $0.source.kind == .library }
        let settingsPrompts = visible.filter { $0.discoveryKind == .settings }
        let packagePrompts = visible.filter { $0.source.kind == .package }
        let builtinPrompts = visible.filter { $0.source.kind == .builtin }

        var sections: [AppListSection<PromptTemplateRecord>] = []

        // Resource catalog is always global — the Prompts view is decoupled
        // from `selectedProjectPath`. Project assignment is managed per-prompt
        // via the detail card's project toggles.
        sections.append(AppListSection(
            id: "global",
            title: LanguageStore.shared.t("prompts.section.global"),
            items: globalPrompts,
            emptyMessage: LanguageStore.shared.t("prompts.section.global.empty")
        ))
        if !libraryPrompts.isEmpty {
            sections.append(AppListSection(id: "library", title: LanguageStore.shared.t("prompts.section.library"), items: libraryPrompts))
        }

        if !settingsPrompts.isEmpty {
            sections.append(AppListSection(
                id: "settings",
                title: LanguageStore.shared.t("prompts.section.settings"),
                info: LanguageStore.shared.t("prompts.section.settings.info"),
                items: settingsPrompts
            ))
        }

        if !packagePrompts.isEmpty {
            sections.append(AppListSection(
                id: "package",
                title: LanguageStore.shared.t("prompts.section.package"),
                info: LanguageStore.shared.t("prompts.section.package.info"),
                items: packagePrompts
            ))
        }

        if !builtinPrompts.isEmpty {
            sections.append(AppListSection(
                id: "builtin",
                title: LanguageStore.shared.t("prompts.section.builtin"),
                info: LanguageStore.shared.t("prompts.section.builtin.info", AppBrand.displayName),
                items: builtinPrompts
            ))
        }

        if visible.isEmpty {
            sections.append(AppListSection(
                id: "empty",
                title: LanguageStore.shared.t("prompts.section.emptyTitle"),
                items: [],
                emptyMessage: LanguageStore.shared.t("prompts.section.empty")
            ))
        }

        return (sections, visible)
    }

    private func promptWarningCard(_ warning: DiagnosticWarning) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .imageScale(.medium)
            Text(warning.message)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.orange.opacity(0.25), lineWidth: 1))
    }

    /// Reads from `cachedLayout`. Hit from selection-sync (`contains(where:)`,
    /// `first(where:)`) and from derived filters. Pre-refactor this property ran the multi-field
    /// substring search inline on every access — including from
    /// `promptListSections` (which ran seven `.filter` passes per body eval).
    /// Now O(1).
    private var visiblePrompts: [PromptTemplateRecord] {
        cachedLayout.visiblePrompts
    }

    private var promptSelection: Binding<String?> {
        Binding(get: { selectedCommandItemID }, set: { selectedCommandItemID = $0 })
    }

    /// Pulls `viewModel.selectedCommandItemID` into the local mirror off the
    /// current update pass. Mirrors `SkillsScreen.scheduleSelectionSynchronization()`.
    private func scheduleSelectionSynchronization() {
        Task { @MainActor in
            await Task.yield()
            synchronizeSelectionFromViewModel()
        }
    }

    private func synchronizeSelectionFromViewModel() {
        guard let vmID = viewModel.selectedCommandItemID else {
            ensureSelection()
            return
        }
        if visiblePrompts.contains(where: { $0.id == vmID }) {
            selectedCommandItemID = vmID
            return
        }
        // Selected prompt hidden by search or rebuilt under a new id —
        // keep the user's selection by name when possible.
        if let name = viewModel.allVisiblePromptTemplateRecords.first(where: { $0.id == vmID })?.name,
           let preferred = visiblePrompts.first(where: { $0.name == name }) {
            selectedCommandItemID = preferred.id
            return
        }
        ensureSelection()
    }

    private func ensureSelection() {
        guard selectedCommandItemID == nil
            || !visiblePrompts.contains(where: { $0.id == selectedCommandItemID }) else { return }
        selectedCommandItemID = visiblePrompts.first?.id
    }

    private func promptListRow(_ prompt: PromptTemplateRecord) -> some View {
        let iconName = promptIcon(prompt)
        let iconColor = promptColor(prompt)
        let canRename = viewModel.canRenamePrompt(prompt)
        let isAssignedSomewhere = viewModel.promptIsEnabledGlobally(prompt) || !viewModel.assignedProjects(for: prompt).isEmpty
        return PromptListRowView(
            prompt: prompt,
            iconName: iconName,
            iconColor: iconColor,
            isInactive: !isAssignedSomewhere,
            isDisabled: viewModel.bundledPromptIsDisabled(prompt),
            canRename: canRename,
            onEdit: { promptEditTarget = makePromptEditTarget(prompt) }
        )
        // Fill the row and give it a hit-testable shape so a right-click anywhere on the
        // row (not just on the name text) opens the context menu.
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                copyCommandValue(prompt.invocation)
            } label: {
                Label(LanguageStore.shared.t("prompts.copyInvocation"), systemImage: "doc.on.doc")
            }

            if viewModel.canRenamePrompt(prompt) {
                Button {
                    promptEditTarget = makePromptEditTarget(prompt)
                } label: {
                    Label(LanguageStore.shared.t("prompts.editPrompt"), systemImage: "square.and.pencil")
                }
            }

            Divider()

            Button {
                openPromptFile(prompt.filePath)
            } label: {
                Label(LanguageStore.shared.t("prompts.openRaw"), systemImage: "doc.text")
            }
            .disabled(prompt.filePath.isEmpty)

            Button {
                revealPromptFile(prompt.filePath)
            } label: {
                Label(LanguageStore.shared.t("prompts.revealFinder"), systemImage: "finder")
            }
            .disabled(prompt.filePath.isEmpty)

            if prompt.source.kind == .builtin {
                Divider()
                if viewModel.bundledPromptIsDisabled(prompt) {
                    Button {
                        viewModel.setBundledPromptDisabled(false, for: prompt)
                    } label: {
                        Label(LanguageStore.shared.t("prompts.enable"), systemImage: "checkmark.circle")
                    }
                } else {
                    Button(role: .destructive) {
                        viewModel.setBundledPromptDisabled(true, for: prompt)
                    } label: {
                        Label(LanguageStore.shared.t("prompts.disable"), systemImage: "nosign")
                    }
                }
            }

            Divider()

            Button(role: .destructive) {
                promptPendingDeletion = prompt
            } label: {
                Label(LanguageStore.shared.t("prompts.delete"), systemImage: "trash")
            }
            .disabled(!viewModel.canDeletePrompt(prompt))
        }
    }

    private func nativePill(_ text: String, symbol: String, color: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(AppTheme.Font.micro.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(color.opacity(0.10), in: Capsule(style: .continuous))
    }

    private func promptIcon(_ prompt: PromptTemplateRecord) -> String {
        if prompt.source.kind == .package { return "shippingbox" }
        if prompt.source.kind == .library { return "building.columns" }
        if prompt.source.kind == .project { return "checkmark.circle" }
        if prompt.discoveryKind == .settings { return "gearshape" }
        if prompt.source.kind == .global { return "globe" }
        return AppSymbols.promptTemplate
    }

    private func promptColor(_ prompt: PromptTemplateRecord) -> Color {
        if prompt.source.kind == .package { return AppTheme.sourceBuiltin }
        if prompt.source.kind == .library { return AppTheme.sourceLibrary }
        if prompt.source.kind == .project { return AppTheme.sourceProject }
        if prompt.discoveryKind == .settings { return AppTheme.assistantAccent }
        return AppTheme.brandAccent
    }

    private func promptDetail(_ prompt: PromptTemplateRecord) -> some View {
        AppPage(
            prompt.invocation,
            subtitle: prompt.description.isEmpty ? nil : prompt.description,
            constrainsContentToViewport: true
        ) {
            AppCard {
                promptHeaderEditor(prompt)

                let rows = promptMetadataRows(prompt)
                if !rows.isEmpty {
                    AppKeyValueList(rows: rows)
                }
            }

            projectAssignmentCard(for: prompt)

            LazyMarkdownCard(
                title: LanguageStore.shared.t("prompts.templateTitle"),
                source: prompt.body,
                minimumHeight: 120,
                trailing: {
                    if viewModel.canRenamePrompt(prompt) {
                        Button {
                            promptEditTarget = makePromptEditTarget(prompt)
                        } label: {
                            Label(LanguageStore.shared.t("prompts.edit"), systemImage: "square.and.pencil")
                                .font(.caption.weight(.semibold))
                                .labelStyle(.titleAndIcon)
                        }
                        .appSmallSecondaryButton()
                        .help(LanguageStore.shared.t("prompts.editTemplate"))
                    }
                }
            )

            if prompt.source.kind == .package {
                AppCard(title: LanguageStore.shared.t("prompts.packageTitle")) {
                    Text(LanguageStore.shared.t("prompts.packageBody"))
                        .foregroundStyle(AppTheme.mutedText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if prompt.discoveryKind == .externalReference {
                AppCard(title: LanguageStore.shared.t("prompts.importedTitle")) {
                    Text(LanguageStore.shared.t("prompts.importedBody", AppBrand.displayName))
                        .foregroundStyle(AppTheme.mutedText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if prompt.source.kind == .builtin {
                AppCard(title: LanguageStore.shared.t("prompts.disable")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(viewModel.bundledPromptIsDisabled(prompt)
                             ? "Re-enable this built-in prompt so it appears in the composer's `/` menu and can be assigned as a Default."
                             : "Turn this built-in prompt off everywhere so it does not appear in the composer's `/` menu or get auto-assigned.")
                            .font(.callout)
                            .foregroundStyle(AppTheme.mutedText)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if viewModel.bundledPromptIsDisabled(prompt) {
                            Button(LanguageStore.shared.t("prompts.enable")) {
                                viewModel.setBundledPromptDisabled(false, for: prompt)
                            }
                            .appSecondaryButton()
                        } else {
                            Button(LanguageStore.shared.t("prompts.disable"), role: .destructive) {
                                viewModel.setBundledPromptDisabled(true, for: prompt)
                            }
                            .appDestructiveButton()
                        }
                    }
                }
            }

            if prompt.source.kind != .builtin && viewModel.canDeletePrompt(prompt) {
                AppCard(title: LanguageStore.shared.t("prompts.delete")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(prompt.discoveryKind == .externalReference
                             ? "Stop referencing this prompt and remove its Default and project assignments. The original file is not deleted."
                             : "Move this prompt's file to the Trash and remove its Default and project assignments.")
                            .font(.callout)
                            .foregroundStyle(AppTheme.mutedText)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Button(prompt.discoveryKind == .externalReference ? LanguageStore.shared.t("prompts.removeReference") : LanguageStore.shared.t("prompts.delete"), role: .destructive) {
                            promptPendingDeletion = prompt
                        }
                        .appDestructiveButton()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func projectAssignmentCard(for prompt: PromptTemplateRecord) -> some View {
        if !viewModel.enabledProjects.isEmpty {
            AppCard(title: LanguageStore.shared.t("prompts.projectAssignment")) {
                VStack(alignment: .leading, spacing: 10) {
                    let isGlobal = viewModel.promptIsEnabledGlobally(prompt)

                    Text(LanguageStore.shared.t("prompts.projectAssignmentHelp"))
                        .foregroundStyle(AppTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)

                    LazyVStack(alignment: .leading, spacing: 0) {
                        AllProjectsAssignmentRow(
                            isOn: Binding(
                                get: { isGlobal },
                                set: { enabled in
                                    do {
                                        if enabled {
                                            try viewModel.enablePromptGlobally(prompt)
                                        } else {
                                            try viewModel.disablePromptGlobally(prompt)
                                        }
                                    } catch { NSSound.beep() }
                                }
                            ),
                            subtitle: LanguageStore.shared.t("prompts.enableEveryProject")
                        )
                        Divider()
                        ForEach(viewModel.enabledProjects) { project in
                            ProjectAssignmentToggleRow(
                                project: project,
                                isOn: Binding(
                                    get: { isGlobal ? true : viewModel.prompt(prompt, isEnabledFor: project) },
                                    set: { enabled in
                                        do { try viewModel.setPrompt(prompt, enabled: enabled, for: project) }
                                        catch { NSSound.beep() }
                                    }
                                )
                            )
                            .opacity(isGlobal ? 0.4 : 1)
                            .allowsHitTesting(!isGlobal)
                            if project.id != viewModel.enabledProjects.last?.id {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func promptHeaderEditor(_ prompt: PromptTemplateRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            promptNameEditableView(prompt)
            if let renameErrorMessage {
                Text(renameErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 4)
        .onChange(of: prompt.id) { _, _ in
            cancelPromptRename(for: prompt)
        }
    }

    @ViewBuilder
    private func promptNameEditableView(_ prompt: PromptTemplateRecord) -> some View {
        if isRenamingPromptName {
            TextField("Prompt name", text: $draftPromptName)
                .textFieldStyle(.plain)
                .font(.body.weight(.semibold))
                .fontWidth(.expanded)
                .focused($isPromptNameFocused)
                .onSubmit { commitPromptRename(for: prompt) }
                .onExitCommand { cancelPromptRename(for: prompt) }
                .onAppear {
                    draftPromptName = prompt.name
                    isPromptNameFocused = true
                }
        } else {
            Button { beginPromptRename(for: prompt) } label: {
                HStack(alignment: .center, spacing: 6) {
                    Text(prompt.name)
                    .font(.body.weight(.semibold))
                    .fontWidth(.expanded)
                    .lineLimit(1)
                if viewModel.canRenamePrompt(prompt) {
                    Image(systemName: "pencil")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(AppTheme.mutedText)
                        .opacity(isPromptNameHovered ? 0.85 : 0)
                }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isPromptNameHovered = $0 }
            .help(viewModel.canRenamePrompt(prompt) ? "Rename prompt" : "")
            .accessibilityLabel(LanguageStore.shared.t("prompts.renameA11y", prompt.name))
            .disabled(!viewModel.canRenamePrompt(prompt))
        }
    }

    private func beginPromptRename(for prompt: PromptTemplateRecord) {
        guard viewModel.canRenamePrompt(prompt), !isRenamingPromptName else { return }
        renameErrorMessage = nil
        draftPromptName = prompt.name
        isRenamingPromptName = true
        isPromptNameFocused = true
    }

    private func cancelPromptRename(for prompt: PromptTemplateRecord) {
        isRenamingPromptName = false
        isPromptNameFocused = false
        draftPromptName = prompt.name
        renameErrorMessage = nil
    }

    private func commitPromptRename(for prompt: PromptTemplateRecord) {
        let trimmed = draftPromptName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            cancelPromptRename(for: prompt)
            return
        }
        guard trimmed != prompt.name else {
            cancelPromptRename(for: prompt)
            return
        }
        do {
            try viewModel.renamePrompt(prompt, to: trimmed)
            isRenamingPromptName = false
            isPromptNameFocused = false
            renameErrorMessage = nil
        } catch {
            renameErrorMessage = error.localizedDescription
            NSSound.beep()
        }
    }

    private func promptMetadataRows(_ prompt: PromptTemplateRecord) -> [(String, String)] {
        var rows: [(String, String)] = []
        if let argumentHint = prompt.argumentHint, !argumentHint.isEmpty {
            rows.append((LanguageStore.shared.t("prompts.argumentHint"), argumentHint))
        }
        if !prompt.filePath.isEmpty {
            rows.append((LanguageStore.shared.t("prompts.file"), prompt.filePath))
        }
        return rows
    }

    private func makePromptEditTarget(_ prompt: PromptTemplateRecord) -> MarkdownFileEditTarget {
        MarkdownFileEditTarget(
            title: LanguageStore.shared.t("prompts.editNamed", prompt.invocation),
            path: prompt.filePath,
            note: LanguageStore.shared.t("prompts.editNote")
        )
    }

    private func createNewPrompt() {
        let draft = viewModel.newLibraryPromptTemplateDraft()
        promptEditTarget = MarkdownFileEditTarget(
            title: LanguageStore.shared.t("prompts.newPrompt"),
            path: draft.path,
            note: LanguageStore.shared.t("prompts.newNote"),
            seedContent: draft.seedContent
        )
    }

    private func importPrompt() {
        viewModel.choosePromptFileToImport { url in
            guard let url else { return }
            do {
                _ = try viewModel.importPromptTemplate(from: url)
            } catch {
                NSSound.beep()
            }
        }
    }

    private func assignedProjectSummary(_ prompt: PromptTemplateRecord) -> String {
        let projects = viewModel.assignedProjects(for: prompt).map(\.name)
        return projects.isEmpty ? "—" : projects.joined(separator: ", ")
    }

    private func deletePrompt(_ prompt: PromptTemplateRecord) {
        do {
            try viewModel.deletePrompt(prompt)
            promptPendingDeletion = nil
        } catch {
            promptPendingDeletion = nil
            NSSound.beep()
        }
    }
}

func copyCommandValue(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
}

func openPromptFile(_ path: String) {
    NSWorkspace.shared.open(URL(fileURLWithPath: path))
}

func revealPromptFile(_ path: String) {
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
}

/// Prompt catalog row. Owns its own hover `@State` so a hover on row A only
/// invalidates row A — pre-extraction the parent owned a `hoveredPromptID`
/// and every visible row had to re-evaluate `hoveredPromptID == prompt.id`
/// when any row was hovered.
private struct PromptListRowView: View {
    let prompt: PromptTemplateRecord
    let iconName: String
    let iconColor: Color
    let isInactive: Bool
    let isDisabled: Bool
    let canRename: Bool
    let onEdit: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 5) {
                Text(prompt.name)
                    .font(AppTheme.Font.sectionTitle)
                    .fontWidth(.expanded)
                    .foregroundStyle(.primary)
                    .strikethrough(isDisabled, color: AppTheme.mutedText)
                    .lineLimit(1)
                Text(prompt.description)
                    .font(AppTheme.Font.metadata)
                    .foregroundStyle(AppTheme.mutedText)
                    .lineLimit(2)
            }

            Spacer(minLength: 0)

            if canRename {
                Button(action: onEdit) {
                    Text(LanguageStore.shared.t("prompts.edit"))
                        .font(.caption.weight(.semibold))
                }
                .appSmallSecondaryButton()
                .opacity(isHovered ? 1 : 0)
                .help(LanguageStore.shared.t("prompts.editTemplate"))
                .animation(.easeInOut(duration: 0.15), value: isHovered)
            }
        }
        .onHover { isHovered = $0 }
        .padding(.vertical, 6)
        .opacity(isInactive ? 0.62 : 1)
        .saturation(isInactive ? 0.25 : 1)
    }
}
