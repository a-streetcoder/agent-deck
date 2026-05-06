import AppKit
import SwiftUI

struct CommandsAndPromptsScreen: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        HSplitView {
            promptLibraryPane
                .frame(minWidth: 430, idealWidth: 520, maxWidth: 640)

            if let command = viewModel.selectedCommand {
                commandDetail(command)
            } else if let prompt = viewModel.selectedPromptTemplate {
                promptDetail(prompt)
            } else {
                ContentUnavailableView("No Prompt Selected", systemImage: "doc.text")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var promptLibraryPane: some View {
        AppPage("Prompts", subtitle: pageSubtitle) {
            VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
                if let selectedProject = viewModel.selectedDiscoveredProject {
                    AppCard(title: "Active in \(selectedProject.name)") {
                        promptGrid(activePrompts, emptyText: "No prompt templates are active for this project.")
                    }

                    if !libraryPrompts.isEmpty {
                        AppCard(title: "Library Prompts") {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Library prompts are centrally stored and only become active when assigned to this project or enabled globally.")
                                    .foregroundStyle(AppTheme.mutedText)
                                promptGrid(libraryPrompts, emptyText: "No library prompts.")
                            }
                        }
                    }
                } else {
                    if !globalPrompts.isEmpty {
                        AppCard(title: "Global Prompts") {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Select a project to see exactly which prompt templates are active there and to manage project assignment.")
                                    .foregroundStyle(AppTheme.mutedText)
                                promptGrid(globalPrompts, emptyText: "No global prompt templates.")
                            }
                        }
                    }

                    if !libraryPrompts.isEmpty {
                        AppCard(title: "Library Prompts") {
                            promptGrid(libraryPrompts, emptyText: "No library prompts.")
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

                if !viewModel.snapshot.commands.isEmpty {
                    AppCard(title: "Extension Commands") {
                        commandGrid(viewModel.snapshot.commands, emptyText: "No extension commands.")
                    }
                }
            }
        }
    }

    private var pageSubtitle: String {
        if let selectedProject = viewModel.selectedDiscoveredProject {
            return "Active prompts for \(selectedProject.name), plus central library assignment"
        }
        return "Reusable prompt templates and extension commands"
    }

    private var managedPrompts: [PromptTemplateRecord] {
        Dictionary(grouping: viewModel.allVisiblePromptTemplateRecords, by: \.name).values.compactMap(preferredPromptRecord)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var activePrompts: [PromptTemplateRecord] {
        managedPrompts.filter { promptIsActiveForCurrentProject($0) }
    }

    private var globalPrompts: [PromptTemplateRecord] {
        managedPrompts.filter { viewModel.promptIsEnabledGlobally($0) && $0.source.kind != .package }
    }

    private var libraryPrompts: [PromptTemplateRecord] {
        managedPrompts.filter { $0.source.kind == .library && !viewModel.promptIsEnabledGlobally($0) }
    }

    private var packagePrompts: [PromptTemplateRecord] {
        managedPrompts.filter { $0.source.kind == .package }
    }

    private func preferredPromptRecord(_ records: [PromptTemplateRecord]) -> PromptTemplateRecord? {
        records.first { $0.source.kind == .library }
        ?? records.first { $0.source.kind == .global }
        ?? records.first { $0.source.kind == .project }
        ?? records.first { $0.source.kind == .package }
        ?? records.first
    }

    private func promptIsActiveForCurrentProject(_ prompt: PromptTemplateRecord) -> Bool {
        if viewModel.promptIsEnabledGlobally(prompt) { return true }
        if let selectedProject = viewModel.selectedDiscoveredProject, viewModel.prompt(prompt, isEnabledFor: selectedProject) { return true }
        return prompt.source.kind == .package && viewModel.selectedDiscoveredProject != nil
    }

    private func promptGrid(_ prompts: [PromptTemplateRecord], emptyText: String) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
            if prompts.isEmpty {
                Text(emptyText)
                    .foregroundStyle(AppTheme.mutedText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(prompts, id: \.name) { prompt in
                    promptTile(prompt)
                }
            }
        }
    }

    private func commandGrid(_ commands: [CommandRecord], emptyText: String) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
            if commands.isEmpty {
                Text(emptyText).foregroundStyle(AppTheme.mutedText)
            } else {
                ForEach(commands) { command in commandTile(command) }
            }
        }
    }

    private func promptTile(_ prompt: PromptTemplateRecord) -> some View {
        Button { viewModel.selectedCommandItemID = prompt.id } label: {
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
                    .fill(viewModel.selectedCommandItemID == prompt.id ? Color.accentColor.opacity(0.10) : AppTheme.contentSubtleFill)
                    .stroke(viewModel.selectedCommandItemID == prompt.id ? Color.accentColor.opacity(0.45) : AppTheme.contentStroke, lineWidth: 1)
            )
            .opacity(promptIsUnusedLibraryPrompt(prompt) ? 0.62 : 1)
            .saturation(promptIsUnusedLibraryPrompt(prompt) ? 0.25 : 1)
        }
        .buttonStyle(.plain)
    }

    private func commandTile(_ command: CommandRecord) -> some View {
        Button { viewModel.selectedCommandItemID = command.id } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "terminal")
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 5) {
                    Text(command.invocation)
                        .font(.headline)
                        .fontWidth(.expanded)
                        .foregroundStyle(.primary)
                    Text(command.description)
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedText)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(viewModel.selectedCommandItemID == command.id ? Color.accentColor.opacity(0.10) : AppTheme.contentSubtleFill)
                    .stroke(viewModel.selectedCommandItemID == command.id ? Color.accentColor.opacity(0.45) : AppTheme.contentStroke, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func promptIcon(_ prompt: PromptTemplateRecord) -> String {
        if prompt.source.kind == .package { return "shippingbox" }
        if viewModel.promptIsEnabledGlobally(prompt) { return "globe" }
        if prompt.source.kind == .library { return "building.columns" }
        return "doc.text"
    }

    private func promptColor(_ prompt: PromptTemplateRecord) -> Color {
        if prompt.source.kind == .package { return .orange }
        if viewModel.promptIsEnabledGlobally(prompt) { return .blue }
        if prompt.source.kind == .library { return .purple }
        if viewModel.selectedProjectPath != nil, promptIsActiveForCurrentProject(prompt) { return .green }
        return .blue
    }

    private func promptIsUnusedLibraryPrompt(_ prompt: PromptTemplateRecord) -> Bool {
        prompt.source.kind == .library && !viewModel.promptIsEnabledGlobally(prompt) && viewModel.assignedProjects(for: prompt).isEmpty
    }

    private func commandDetail(_ command: CommandRecord) -> some View {
        AppPage(command.invocation, subtitle: command.description) {
            AppCard(title: "Details") {
                AppKeyValueList(rows: [
                    ("Invocation", command.invocation),
                    ("Type", command.kind.rawValue),
                    ("Provider", command.packageName ?? "Extension"),
                    ("Scope", command.sourceScope ?? "—"),
                    ("Origin", command.sourceOrigin ?? "—"),
                    ("Path", command.sourcePath ?? "—")
                ])
            }
        }
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
                AppCard(title: "Library & Visibility") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Reusable prompts live in ~/.pi/agent/prompt-library. Pi only sees them when Pi Manager links them globally or into a project.")
                            .foregroundStyle(AppTheme.mutedText)
                            .fixedSize(horizontal: false, vertical: true)
                        AppKeyValueList(rows: [
                            ("In Library", canonicalPrompt(prompt).source.kind == .library ? "Yes" : "No"),
                            ("Active Globally", viewModel.promptIsEnabledGlobally(prompt) ? "Yes" : "No"),
                            ("Assigned Projects", assignedProjectSummary(prompt)),
                            ("Path", canonicalPrompt(prompt).filePath)
                        ])
                        HStack(spacing: 10) {
                            if canonicalPrompt(prompt).source.kind != .library {
                                Button("Move to Library") { do { try viewModel.movePromptToLibrary(prompt) } catch { NSSound.beep() } }
                            }
                            if viewModel.promptIsEnabledGlobally(prompt) {
                                Button("Disable Globally") { do { try viewModel.disablePromptGlobally(prompt) } catch { NSSound.beep() } }
                            } else {
                                Button("Enable Globally") { do { try viewModel.enablePromptGlobally(prompt) } catch { NSSound.beep() } }
                                    .buttonStyle(.borderedProminent)
                            }
                        }
                    }
                }

                AppCard(title: "Project Assignment") {
                    projectAssignmentList(for: prompt)
                }
            }

            AppCard(title: "Template") {
                MarkdownDocumentView(source: prompt.body, minimumHeight: 120)
            }
        }
    }

    private func canonicalPrompt(_ prompt: PromptTemplateRecord) -> PromptTemplateRecord {
        viewModel.snapshot.libraryPromptTemplates.first { $0.name == prompt.name } ?? prompt
    }

    private func projectAssignmentList(for prompt: PromptTemplateRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Check each project that should expose this prompt template. Assigning to a project removes managed global visibility, like Skills.")
                .foregroundStyle(AppTheme.mutedText)
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(viewModel.enabledProjects) { project in
                    Toggle(isOn: Binding(
                        get: { viewModel.prompt(prompt, isEnabledFor: project) },
                        set: { enabled in do { try viewModel.setPrompt(prompt, enabled: enabled, for: project) } catch { NSSound.beep() } }
                    )) {
                        HStack(spacing: 10) {
                            ProjectIconView(imageURL: project.iconFileURL, symbolName: project.fallbackSymbolName, size: 30)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(project.name).font(.body.weight(.semibold))
                                Text(project.repositoryName ?? project.path).font(.caption).foregroundStyle(AppTheme.mutedText).lineLimit(1).truncationMode(.middle)
                            }
                        }
                        .frame(height: 46, alignment: .center)
                    }
                    .toggleStyle(.checkbox)
                    .controlSize(.large)
                    .padding(.vertical, 8)
                    if project.id != viewModel.enabledProjects.last?.id { Divider() }
                }
            }
        }
    }

    private func assignedProjectSummary(_ prompt: PromptTemplateRecord) -> String {
        let projects = viewModel.assignedProjects(for: prompt).map(\.name)
        return projects.isEmpty ? "—" : projects.joined(separator: ", ")
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
