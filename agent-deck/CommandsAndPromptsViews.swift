import AppKit
import SwiftUI

struct PromptsScreen: View {
    @ObservedObject var viewModel: AppViewModel
    @Binding var searchText: String

    var body: some View {
        HSplitView {
            promptLibraryPane
                .frame(minWidth: 430, idealWidth: 520, maxWidth: 640)

            if let prompt = viewModel.selectedPromptTemplate {
                promptDetail(prompt)
            } else {
                ContentUnavailableView("No Prompt Selected", systemImage: "doc.text")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if viewModel.selectedPromptTemplate == nil {
                viewModel.selectedCommandItemID = viewModel.allVisiblePromptTemplateRecords.first?.id
            }
        }
    }

    private var promptLibraryPane: some View {
        List(selection: $viewModel.selectedCommandItemID) {
            if !viewModel.promptWarnings.isEmpty {
                appListSection("Warnings", info: "Prompt issues that need attention.") {
                    ForEach(viewModel.promptWarnings) { warning in
                        promptWarningRow(warning)
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
        .appResourceListStyle()
    }

    private func promptWarningRow(_ warning: DiagnosticWarning) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .frame(width: 18)
            Text(warning.message)
                .font(.caption)
                .foregroundStyle(AppTheme.mutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
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
        HStack(alignment: .top, spacing: 10) {
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
        }
        .padding(.vertical, 6)
        .badge(prompt.source.kind.rawValue)
    }

    private func nativePill(_ text: String, symbol: String, color: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(color.opacity(0.10), in: Capsule(style: .continuous))
    }

    private func nativeEmptyRow(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(AppTheme.mutedText)
            .padding(.vertical, 4)
            .selectionDisabled()
            .listRowSeparator(.hidden)
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
        AppPage(prompt.invocation, subtitle: prompt.description) {
            if prompt.source.kind == .package {
                AppCard(title: "Package Prompt") {
                    Text("This prompt template is package-managed and read-only.")
                        .foregroundStyle(AppTheme.mutedText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                AppCard(title: "Location") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Agent Deck scans prompt templates into a catalog. Parent Pi sessions launch with --no-prompt-templates and receive only Default and Project prompt assignments via --prompt-template.")
                            .foregroundStyle(AppTheme.mutedText)
                            .fixedSize(horizontal: false, vertical: true)
                        AppKeyValueList(rows: [
                            ("Source", prompt.source.kind.rawValue),
                            ("Discovery", prompt.discoveryKind.rawValue),
                            ("Path", prompt.filePath)
                        ])
                        HStack(spacing: 10) {
                            if prompt.source.kind != .library {
                                Button("Move to Library") { do { try viewModel.movePromptToLibrary(prompt) } catch { NSSound.beep() } }
                            }
                        }
                    }
                }
            }

            AppCard(title: "Assignments") {
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle("Default prompt", isOn: Binding(
                            get: { viewModel.promptIsEnabledGlobally(prompt) },
                            set: { enabled in
                                do {
                                    if enabled { try viewModel.enablePromptGlobally(prompt) }
                                    else { try viewModel.disablePromptGlobally(prompt) }
                                } catch {
                                    NSSound.beep()
                                }
                            }
                        ))
                        Text("Default prompts are passed to every parent Pi Agent session with explicit --prompt-template flags.")
                            .font(.caption)
                            .foregroundStyle(AppTheme.mutedText)

                        if !viewModel.enabledProjects.isEmpty {
                            Divider()
                            Text("Project assignments")
                                .font(.headline)
                            ForEach(viewModel.enabledProjects) { project in
                                Toggle(project.name, isOn: Binding(
                                    get: { viewModel.prompt(prompt, isEnabledFor: project) },
                                    set: { enabled in do { try viewModel.setPrompt(prompt, enabled: enabled, for: project) } catch { NSSound.beep() } }
                                ))
                            }
                        }
                    }
                }

            AppCard(title: "Template") {
                MarkdownDocumentView(source: prompt.body, minimumHeight: 120)
            }
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
