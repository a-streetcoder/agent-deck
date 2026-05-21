import AppKit
import SwiftUI

struct PromptsScreen: View {
    @ObservedObject var viewModel: AppViewModel
    @Binding var searchText: String
    @State private var promptPendingRename: PromptTemplateRecord?
    @State private var promptPendingDeletion: PromptTemplateRecord?
    @State private var hoveredPromptID: PromptTemplateRecord.ID?
    @State private var promptEditTarget: MarkdownFileEditTarget?

    var body: some View {
        HSplitView {
            if viewModel.hasCompletedInitialRefresh {
                promptLibraryPane
                    .frame(minWidth: 430, idealWidth: 520, maxWidth: 640)
            } else {
                AppLoadingView("Loading prompts…")
                    .frame(minWidth: 430, idealWidth: 520, maxWidth: 640)
            }

            if !viewModel.hasCompletedInitialRefresh {
                AppLoadingView("Loading prompt details…")
            } else if let prompt = viewModel.selectedPromptTemplate {
                promptDetail(prompt)
            } else {
                ContentUnavailableView("No Prompt Selected", systemImage: "doc.text")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(item: $promptPendingRename) { prompt in
            RenameResourceSheet(
                title: "Rename Prompt",
                currentName: prompt.name,
                resourceLabel: "prompt",
                makePreview: { viewModel.renamePreview(for: prompt, to: $0) },
                onRename: { try viewModel.renamePrompt(prompt, to: $0) }
            )
        }
        .sheet(item: $promptEditTarget) { target in
            MarkdownFileEditorSheet(target: target) {
                viewModel.refresh(includeModels: false, scanAllProjects: true)
                if target.isNew {
                    viewModel.selectedCommandItemID = viewModel.allVisiblePromptTemplateRecords.first { $0.filePath == target.path }?.id ?? viewModel.selectedCommandItemID
                }
            }
        }
        .alert("Delete Prompt?", isPresented: Binding(
            get: { promptPendingDeletion != nil },
            set: { if !$0 { promptPendingDeletion = nil } }
        ), presenting: promptPendingDeletion) { prompt in
            if prompt.discoveryKind == .externalReference {
                Button("Remove Reference", role: .destructive) {
                    deletePrompt(prompt)
                }
            } else {
                Button("Move to Trash", role: .destructive) {
                    deletePrompt(prompt)
                }
            }
            Button("Cancel", role: .cancel) {
                promptPendingDeletion = nil
            }
        } message: { prompt in
            if prompt.discoveryKind == .externalReference {
                Text("Stop referencing \"\(prompt.invocation)\" and remove its Default and project assignments? The original file is not deleted.")
            } else {
                Text("Move \"\(prompt.invocation)\" to the Trash and remove its Default and project assignments?")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .agentDeckNewPromptRequested)) { _ in
            createNewPrompt()
        }
        .onReceive(NotificationCenter.default.publisher(for: .agentDeckImportPromptRequested)) { _ in
            importPrompt()
        }
        .onAppear {
            Task { @MainActor in
                await Task.yield()
                if viewModel.selectedPromptTemplate == nil {
                    viewModel.selectedCommandItemID = viewModel.allVisiblePromptTemplateRecords.first?.id
                }
            }
        }
    }

    private var promptLibraryPane: some View {
        List(selection: $viewModel.selectedCommandItemID) {
            if !viewModel.promptWarnings.isEmpty {
                appListSection("Warnings", tint: .orange) {
                    ForEach(viewModel.promptWarnings) { warning in
                        promptWarningCard(warning)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                            .selectionDisabled()
                    }
                }
            }

            if let selectedProject = viewModel.selectedDiscoveredProject {
                if !projectPrompts.isEmpty {
                    promptSection(
                        "Project Prompts",
                        prompts: projectPrompts,
                        note: "Loaded from \(selectedProject.name)'s .pi/prompts directory or project settings."
                    )
                }

                if !globalPrompts.isEmpty {
                    promptSection(
                        "Global Prompts",
                        prompts: globalPrompts,
                        note: "Loaded from global prompt locations and available in every project."
                    )
                }

                if !libraryPrompts.isEmpty {
                    promptSection(
                        "Prompt Library",
                        prompts: libraryPrompts,
                        note: "Loaded from ~/.pi/agent/prompt-library as reusable prompt templates."
                    )
                }
            } else {
                promptSection("Global Prompts", prompts: globalPrompts, emptyText: "No global prompt templates.")
                if !projectPrompts.isEmpty {
                    promptSection("Project Prompts", prompts: projectPrompts)
                }
                if !libraryPrompts.isEmpty {
                    promptSection("Prompt Library", prompts: libraryPrompts)
                }
            }

            if !settingsPrompts.isEmpty {
                promptSection(
                    "Settings Prompts",
                    prompts: settingsPrompts,
                    note: "Loaded from explicit settings.json prompt paths."
                )
            }

            if !packagePrompts.isEmpty {
                promptSection(
                    "Package Prompts",
                    prompts: packagePrompts,
                    note: "Package prompt templates are provided by installed packages and are read-only."
                )
            }

            if visiblePrompts.isEmpty {
                appListSection("Prompts") {
                    nativeEmptyRow("No prompt templates discovered.")
                }
            }
        }
        .appListStyle()
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

    private var visiblePrompts: [PromptTemplateRecord] {
        let prompts = viewModel.allVisiblePromptTemplateRecords
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return prompts }
        return prompts.filter { prompt in
            [prompt.name, prompt.invocation, prompt.description, prompt.source.kind.rawValue, prompt.filePath, prompt.body]
                .contains { $0.lowercased().contains(query) }
        }
    }

    private var projectPrompts: [PromptTemplateRecord] {
        visiblePrompts.filter { $0.source.kind == .project && $0.discoveryKind == .standardDirectory }
    }

    private var globalPrompts: [PromptTemplateRecord] {
        visiblePrompts.filter { $0.source.kind == .global && $0.discoveryKind == .standardDirectory }
    }

    private var libraryPrompts: [PromptTemplateRecord] {
        visiblePrompts.filter { $0.source.kind == .library }
    }

    private var settingsPrompts: [PromptTemplateRecord] {
        visiblePrompts.filter { $0.discoveryKind == .settings }
    }

    private var packagePrompts: [PromptTemplateRecord] {
        visiblePrompts.filter { $0.source.kind == .package }
    }

    @ViewBuilder
    private func promptSection(_ title: String, prompts: [PromptTemplateRecord], emptyText: String? = nil, note: String? = nil) -> some View {
        appListSection(title, info: note) {
            if prompts.isEmpty, let emptyText {
                nativeEmptyRow(emptyText)
            }
            ForEach(prompts) { prompt in
                promptListRow(prompt)
                    .tag(prompt.id)
            }
        }
    }

    private func promptListRow(_ prompt: PromptTemplateRecord) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: promptIcon(prompt))
                .foregroundStyle(promptColor(prompt))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 5) {
                Text(prompt.invocation)
                    .font(.headline)
                    .fontWidth(.expanded)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(prompt.description)
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)
                    .lineLimit(2)
                if let argumentHint = prompt.argumentHint {
                    nativePill(argumentHint, symbol: "text.cursor", color: promptColor(prompt))
                }
            }

            Spacer(minLength: 0)

            if viewModel.canRenamePrompt(prompt) {
                Button {
                    promptEditTarget = makePromptEditTarget(prompt)
                } label: {
                    Text("Edit")
                        .font(.caption.weight(.semibold))
                }
                .appSmallSecondaryButton()
                .opacity(hoveredPromptID == prompt.id ? 1 : 0)
                .help("Edit prompt template")
                .animation(.easeInOut(duration: 0.15), value: hoveredPromptID == prompt.id)
            }
        }
        .onHover { hovering in
            hoveredPromptID = hovering ? prompt.id : nil
        }
        .padding(.vertical, 6)
        .listRowSeparator(.hidden, edges: .top)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                promptPendingDeletion = prompt
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(!viewModel.canDeletePrompt(prompt))
        }
        .contextMenu {
            Button {
                copyCommandValue(prompt.invocation)
            } label: {
                Label("Copy Invocation", systemImage: "doc.on.doc")
            }

            if viewModel.canRenamePrompt(prompt) {
                Button {
                    promptEditTarget = makePromptEditTarget(prompt)
                } label: {
                    Label("Edit Prompt", systemImage: "square.and.pencil")
                }
            }

            Divider()

            Button {
                openPromptFile(prompt.filePath)
            } label: {
                Label("Open Raw File", systemImage: "doc.text")
            }
            .disabled(prompt.filePath.isEmpty)

            Button {
                revealPromptFile(prompt.filePath)
            } label: {
                Label("Reveal in Finder", systemImage: "finder")
            }
            .disabled(prompt.filePath.isEmpty)

            Divider()

            Button(role: .destructive) {
                promptPendingDeletion = prompt
            } label: {
                Label("Delete Prompt", systemImage: "trash")
            }
            .disabled(!viewModel.canDeletePrompt(prompt))
        }
    }

    private func nativePill(_ text: String, symbol: String, color: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption2.weight(.semibold))
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
        return "doc.text"
    }

    private func promptColor(_ prompt: PromptTemplateRecord) -> Color {
        if prompt.source.kind == .package { return .orange }
        if prompt.source.kind == .library { return .purple }
        if prompt.source.kind == .project { return .green }
        if prompt.discoveryKind == .settings { return .indigo }
        if prompt.source.kind == .global { return .blue }
        return .blue
    }

    private func promptDetail(_ prompt: PromptTemplateRecord) -> some View {
        AppPage(prompt.invocation, subtitle: prompt.filePath) {
            AppCard(title: prompt.name) {
                MarkdownDocumentView(source: prompt.body, minimumHeight: 120)
            }

            if prompt.source.kind == .package {
                AppCard(title: "Package Prompt") {
                    Text("This prompt template is package-managed and read-only.")
                        .foregroundStyle(AppTheme.mutedText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if prompt.discoveryKind == .externalReference {
                AppCard(title: "Imported Prompt") {
                    Text("This prompt is referenced in place. Edits in \(AppBrand.displayName) save to the original file, and removing it only un-registers the reference — the file is not deleted.")
                        .foregroundStyle(AppTheme.mutedText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            AppCard(title: "Default Prompt") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Default prompts are passed to every parent Pi Agent session with explicit `--prompt-template` flags.")
                        .foregroundStyle(AppTheme.mutedText)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if viewModel.promptIsEnabledGlobally(prompt) {
                        Button("Remove Default") {
                            do { try viewModel.disablePromptGlobally(prompt) }
                            catch { NSSound.beep() }
                        }
                        .appSecondaryButton()
                    } else {
                        Button("Make Default") {
                            do { try viewModel.enablePromptGlobally(prompt) }
                            catch { NSSound.beep() }
                        }
                        .appPrimaryButton()
                    }
                }
            }

            if !viewModel.promptIsEnabledGlobally(prompt) && !viewModel.enabledProjects.isEmpty {
                AppCard(title: "Project Assignment") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Check each project that should load this prompt. Project assignment is stored in Agent Deck and does not create or remove prompt files.")
                            .foregroundStyle(AppTheme.mutedText)

                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(viewModel.enabledProjects) { project in
                                ProjectAssignmentToggleRow(
                                    project: project,
                                    isOn: Binding(
                                        get: { viewModel.prompt(prompt, isEnabledFor: project) },
                                        set: { enabled in
                                            do { try viewModel.setPrompt(prompt, enabled: enabled, for: project) }
                                            catch { NSSound.beep() }
                                        }
                                    )
                                )

                                if project.id != viewModel.enabledProjects.last?.id {
                                    Divider()
                                }
                            }
                        }
                    }
                }
            }

        }
    }

    private func makePromptEditTarget(_ prompt: PromptTemplateRecord) -> MarkdownFileEditTarget {
        MarkdownFileEditTarget(
            title: "Edit \(prompt.invocation)",
            path: prompt.filePath,
            note: "Editing the raw prompt markdown. Changes apply after you save."
        )
    }

    private func createNewPrompt() {
        let draft = viewModel.newLibraryPromptTemplateDraft()
        promptEditTarget = MarkdownFileEditTarget(
            title: "New Prompt",
            path: draft.path,
            note: "Edit this prompt template, then save to add it to your library. Cancelling discards it.",
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
