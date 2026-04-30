import AppKit
import SwiftUI

struct CommandsAndPromptsScreen: View {
    @ObservedObject var viewModel: AppViewModel

    private var extensionCommands: [CommandRecord] {
        viewModel.snapshot.commands
    }

    var body: some View {
        HSplitView {
            AppSidebarPane(
                title: "Prompts",
                subtitle: "\(viewModel.snapshot.commands.count) commands · \(viewModel.snapshot.promptTemplates.count) prompts"
            ) {
                List(selection: $viewModel.selectedCommandItemID) {
                    if !extensionCommands.isEmpty {
                        Section("Extension Commands") {
                            ForEach(extensionCommands) { command in
                                commandRow(command)
                                    .tag(command.id)
                            }
                        }
                    }

                    if !viewModel.snapshot.promptTemplates.isEmpty {
                        Section {
                            ForEach(viewModel.snapshot.promptTemplates) { prompt in
                                promptRow(prompt)
                                    .tag(prompt.id)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
            .frame(minWidth: 320, idealWidth: 380, maxWidth: 460)

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

    private func commandRow(_ command: CommandRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(command.invocation)
                    .font(.headline)
                    .fontWidth(.expanded)
                    .lineLimit(2)
                Spacer(minLength: 8)
                AppLabelTag(text: command.kind.rawValue, color: .blue)
            }
            Text(command.description)
                .foregroundStyle(AppTheme.mutedText)
                .lineLimit(2)
            if let packageName = command.packageName {
                Text(packageName)
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 6)
    }

    private func promptRow(_ prompt: PromptTemplateRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(prompt.invocation)
                        .font(.headline)
                        .fontWidth(.expanded)
                        .lineLimit(2)
                    if let argumentHint = prompt.argumentHint {
                        Text(argumentHint)
                            .font(.caption.monospaced())
                            .foregroundStyle(AppTheme.mutedText)
                    }
                }
                Spacer(minLength: 8)
                AppLabelTag(text: prompt.discoveryKind.rawValue, color: prompt.source.kind == .project ? .green : (prompt.source.kind == .package ? .orange : .blue))
            }
            Text(prompt.description)
                .foregroundStyle(AppTheme.mutedText)
                .lineLimit(2)
            Text(promptLocationLabel(prompt, selectedProjectRoot: viewModel.snapshot.projectRoot))
                .font(.caption)
                .foregroundStyle(AppTheme.mutedText)
                .lineLimit(1)
        }
        .padding(.vertical, 6)
    }

    private func commandDetail(_ command: CommandRecord) -> some View {
        AppPage(command.invocation, subtitle: command.description) {
            AppCard(trailing: {
                Menu("Actions") {
                    Button("Copy Invocation") { copyCommandValue(command.invocation) }
                    if let packageName = command.packageName {
                        Button("Copy Package Name") { copyCommandValue(packageName) }
                    }
                }
            }) {
                Text("Prompt templates expand markdown into prompt text. This screen also shows slash commands so prompt-related invocation can be inspected in one place. Skill commands stay in the Skills section so capabilities are not duplicated here.")
                    .foregroundStyle(AppTheme.mutedText)
            }

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

            if let notes = command.notes, !notes.isEmpty {
                AppCard(title: "Notes") {
                    Text(notes)
                        .foregroundStyle(AppTheme.mutedText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func promptDetail(_ prompt: PromptTemplateRecord) -> some View {
        AppPage(prompt.invocation, subtitle: prompt.description) {
            AppCard(trailing: {
                Menu("Actions") {
                    Button("Open Raw File") { openPromptFile(prompt.filePath) }
                    Button("Reveal in Finder") { revealPromptFile(prompt.filePath) }
                    Button("Copy Invocation") { copyCommandValue(prompt.invocation) }
                    Button("Copy Prompt Path") { copyCommandValue(prompt.filePath) }
                }
            }) {
                Text("Prompt templates are markdown-backed slash entries. They expand into reusable prompt text rather than performing direct app actions.")
                    .foregroundStyle(AppTheme.mutedText)
            }

            AppCard(title: "Location") {
                AppKeyValueList(rows: [
                    ("Invocation", prompt.invocation),
                    ("Discovery", prompt.discoveryKind.rawValue),
                    ("Scope", promptScopeLabel(prompt, selectedProjectRoot: viewModel.snapshot.projectRoot)),
                    ("Package", prompt.packageName ?? "—"),
                    ("Argument Hint", prompt.argumentHint ?? "—"),
                    ("Path", prompt.filePath)
                ])
            }

            AppCard(title: "Template") {
                MarkdownDocumentView(source: prompt.body, minimumHeight: 24)
            }
        }
    }
}

private func promptScopeLabel(_ prompt: PromptTemplateRecord, selectedProjectRoot: String?) -> String {
    switch prompt.source.kind {
    case .project:
        return promptProjectLabel(prompt, selectedProjectRoot: selectedProjectRoot) ?? "Project"
    case .package:
        return "Package"
    default:
        return prompt.source.kind.rawValue
    }
}

private func promptProjectLabel(_ prompt: PromptTemplateRecord, selectedProjectRoot: String?) -> String? {
    guard prompt.source.kind == .project else { return nil }
    if let selectedProjectRoot {
        return URL(fileURLWithPath: selectedProjectRoot).lastPathComponent
    }
    return commandProjectName(from: prompt.filePath)
}

private func promptLocationLabel(_ prompt: PromptTemplateRecord, selectedProjectRoot: String?) -> String {
    switch prompt.source.kind {
    case .project:
        return promptProjectLabel(prompt, selectedProjectRoot: selectedProjectRoot) ?? "Project Prompt"
    case .package:
        return prompt.packageName ?? "Package Prompt"
    default:
        return prompt.discoveryKind.rawValue
    }
}

private func commandProjectName(from path: String) -> String? {
    let marker = "/Documents/GitHub/"
    guard let range = path.range(of: marker) else { return nil }
    return path[range.upperBound...].split(separator: "/").first.map(String.init)
}

private func copyCommandValue(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
}

private func openPromptFile(_ path: String) {
    NSWorkspace.shared.open(URL(fileURLWithPath: path))
}

private func revealPromptFile(_ path: String) {
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
}
