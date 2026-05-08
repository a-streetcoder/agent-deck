import AppKit
import SwiftUI

struct PromptsScreen: View {
    @ObservedObject var viewModel: AppViewModel

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
        AppPage("Prompts", subtitle: pageSubtitle) {
            VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
                if let selectedProject = viewModel.selectedDiscoveredProject {
                    if !projectPrompts.isEmpty {
                        AppCard(title: "Project Prompts") {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Loaded from \(selectedProject.name)'s .pi/prompts directory or project settings.")
                                    .foregroundStyle(AppTheme.mutedText)
                                promptGrid(projectPrompts, emptyText: "No project prompt templates.")
                            }
                        }
                    }

                    if !globalPrompts.isEmpty {
                        AppCard(title: "Global Prompts") {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Loaded from global prompt locations and available in every project.")
                                    .foregroundStyle(AppTheme.mutedText)
                                promptGrid(globalPrompts, emptyText: "No global prompt templates.")
                            }
                        }
                    }

                    if !libraryPrompts.isEmpty {
                        AppCard(title: "Prompt Library") {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Loaded from ~/.pi/agent/prompt-library as reusable prompt templates.")
                                    .foregroundStyle(AppTheme.mutedText)
                                promptGrid(libraryPrompts, emptyText: "No library prompts.")
                            }
                        }
                    }
                } else {
                    promptSourceSection("Global Prompts", prompts: globalPrompts, emptyText: "No global prompt templates.")
                    promptSourceSection("Project Prompts", prompts: projectPrompts, emptyText: "No project prompt templates.")
                    promptSourceSection("Prompt Library", prompts: libraryPrompts, emptyText: "No library prompts.")
                }

                if !settingsPrompts.isEmpty {
                    AppCard(title: "Settings Prompts") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Loaded from explicit settings.json prompt paths.")
                                .foregroundStyle(AppTheme.mutedText)
                            promptGrid(settingsPrompts, emptyText: "No settings prompts.")
                        }
                    }
                }

                if !packagePrompts.isEmpty {
                    AppCard(title: "Package Prompts") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Package prompt templates are provided by installed packages and are read-only.")
                                .foregroundStyle(AppTheme.mutedText)
                            promptGrid(packagePrompts, emptyText: "No package prompts.")
                        }
                    }
                }

            }
        }
    }

    private var pageSubtitle: String {
        if let selectedProject = viewModel.selectedDiscoveredProject {
            return "Prompt template locations active for \(selectedProject.name)"
        }
        return "Reusable prompt templates loaded from Pi prompt locations"
    }

    private var visiblePrompts: [PromptTemplateRecord] {
        viewModel.allVisiblePromptTemplateRecords
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
    private func promptSourceSection(_ title: String, prompts: [PromptTemplateRecord], emptyText: String) -> some View {
        if !prompts.isEmpty {
            AppCard(title: title) {
                promptGrid(prompts, emptyText: emptyText)
            }
        }
    }

    private func promptGrid(_ prompts: [PromptTemplateRecord], emptyText: String) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
            if prompts.isEmpty {
                Text(emptyText)
                    .foregroundStyle(AppTheme.mutedText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(prompts) { prompt in
                    promptTile(prompt)
                }
            }
        }
    }

    private func promptTile(_ prompt: PromptTemplateRecord) -> some View {
        return Button { viewModel.selectedCommandItemID = prompt.id } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: promptIcon(prompt))
                        .foregroundStyle(promptColor(prompt))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(prompt.invocation)
                            .font(.headline)
                            .fontWidth(.expanded)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        Text(prompt.description)
                            .font(.caption)
                            .foregroundStyle(AppTheme.mutedText)
                            .lineLimit(2)
                        if let argumentHint = prompt.argumentHint {
                            Label(argumentHint, systemImage: "text.cursor")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(promptColor(prompt))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 4)
                                .background(promptColor(prompt).opacity(0.10), in: Capsule(style: .continuous))
                        }
                    }
                    Spacer(minLength: 8)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(viewModel.selectedCommandItemID == prompt.id ? AppTheme.selectionFill : AppTheme.contentSubtleFill)
                    .stroke(viewModel.selectedCommandItemID == prompt.id ? AppTheme.selectionStroke : AppTheme.contentStroke, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
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
                        Text("Pi loads prompt templates from global, project, library, package, and settings-declared prompt locations.")
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
