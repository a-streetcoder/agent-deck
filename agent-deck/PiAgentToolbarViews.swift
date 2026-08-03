import AppKit
import SwiftUI

struct PiAgentCommitToolbarButton: View {
    var viewModel: AppViewModel
    @ObservedObject private var languageStore = LanguageStore.shared
    @State private var isConfirmationPresented = false

    var body: some View {
        Button { commitTapped() } label: {
            Label {
                Text(languageStore.t("agent.commit"))
            } icon: {
                if viewModel.piAgentGitAutomationAction == .commit {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .symbolEffect(.rotate, options: .repeating)
                        .transition(.identity)
                } else {
                    // Framed to the toolbar icon size so the custom asset matches the
                    // SF-symbol spinner's width — no size jump when the icon swaps.
                    Image("git-commit")
                        .resizable()
                        .renderingMode(.template)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: AppTheme.toolbarAssetIconSize.width,
                               height: AppTheme.toolbarAssetIconSize.height)
                        .transition(.identity)
                }
            }
        }
        .accessibilityLabel(languageStore.t("agent.commit"))
        .disabled(!viewModel.canCommitSelectedPiAgentSession)
        .help(languageStore.t("agent.commitHelp"))
        .alert(languageStore.t("agent.commitAlertTitle"), isPresented: $isConfirmationPresented) {
            Button(languageStore.t("agent.commitAlertConfirm")) { viewModel.commitSelectedPiAgentSession() }
            Button(languageStore.t("common.cancel"), role: .cancel) {}
        } message: {
            Text(piAgentGitAlertMessage(for: .commit, viewModel: viewModel))
        }
    }

    private func commitTapped() {
        if viewModel.appSettings.piAgentGitAutomationRequiresConfirmation {
            isConfirmationPresented = true
        } else {
            viewModel.commitSelectedPiAgentSession()
        }
    }
}

struct PiAgentPushToolbarButton: View {
    var viewModel: AppViewModel
    @ObservedObject private var languageStore = LanguageStore.shared

    var body: some View {
        Button { viewModel.pushSelectedPiAgentSession() } label: {
            Label {
                Text(languageStore.t("agent.push"))
            } icon: {
                if viewModel.piAgentGitAutomationAction == .push {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .symbolEffect(.rotate, options: .repeating)
                        .transition(.identity)
                } else {
                    Image(systemName: "arrow.up")
                        .transition(.identity)
                }
            }
        }
        .accessibilityLabel(languageStore.t("agent.push"))
        .disabled(!viewModel.canPushSelectedPiAgentSession)
        .help(languageStore.t("agent.pushHelp"))
    }
}

struct PiAgentCommitAndPushToolbarButton: View {
    var viewModel: AppViewModel
    @ObservedObject private var languageStore = LanguageStore.shared
    @State private var isConfirmationPresented = false

    var body: some View {
        Button { commitAndPushTapped() } label: {
            Label {
                Text(languageStore.t("agent.commitAndPush"))
            } icon: {
                if viewModel.piAgentGitAutomationAction == .commitAndPush {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .symbolEffect(.rotate, options: .repeating)
                } else {
                    Image("git-commit")
                }
            }
        }
        .accessibilityLabel(languageStore.t("agent.commitAndPush"))
        .disabled(!viewModel.canCommitAndPushSelectedPiAgentSession)
        .help(languageStore.t("agent.commitAndPushHelp"))
        .alert(languageStore.t("agent.commitAndPushAlertTitle"), isPresented: $isConfirmationPresented) {
            Button(languageStore.t("agent.commitAndPushAlertConfirm")) { viewModel.commitAndPushSelectedPiAgentSession() }
            Button(languageStore.t("common.cancel"), role: .cancel) {}
        } message: {
            Text(piAgentGitAlertMessage(for: .commitAndPush, viewModel: viewModel))
        }
    }

    private func commitAndPushTapped() {
        if viewModel.appSettings.piAgentGitAutomationRequiresConfirmation {
            isConfirmationPresented = true
        } else {
            viewModel.commitAndPushSelectedPiAgentSession()
        }
    }
}

struct PiAgentMergeToolbarButton: View {
    var viewModel: AppViewModel
    @ObservedObject private var languageStore = LanguageStore.shared
    @State private var isConfirmationPresented = false

    var body: some View {
        Button { isConfirmationPresented = true } label: {
            Label {
                Text(languageStore.t("agent.merge"))
            } icon: {
                if viewModel.piAgentGitAutomationAction == .merge {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .symbolEffect(.rotate, options: .repeating)
                        .transition(.identity)
                } else {
                    Image(systemName: "arrow.triangle.merge")
                        .transition(.identity)
                }
            }
        }
        .accessibilityLabel(languageStore.t("agent.merge"))
        .disabled(!viewModel.canMergeSelectedPiAgentSession)
        .help(languageStore.t("agent.mergeHelp"))
        .alert(languageStore.t("agent.mergeAlertTitle"), isPresented: $isConfirmationPresented) {
            Button(languageStore.t("agent.merge")) { viewModel.mergeSelectedPiAgentSession() }
            Button(languageStore.t("common.cancel"), role: .cancel) {}
        } message: {
            Text(piAgentMergeAlertMessage(viewModel: viewModel))
        }
    }
}

private func piAgentGitAlertMessage(for action: PiAgentGitAction, viewModel: AppViewModel) -> String {
    guard let session = viewModel.piAgentSessionStore.selectedSession else { return action.alertMessage }
    let repoName = URL(fileURLWithPath: session.repositoryRoot, isDirectory: true).lastPathComponent
    return "Repository: \(repoName)\n\n\(action.alertMessage)"
}

private func piAgentMergeAlertMessage(viewModel: AppViewModel) -> String {
    guard let session = viewModel.piAgentSessionStore.selectedSession,
          let branch = session.branchName,
          let source = session.sourceBranch else {
        return "Merge the session branch into its source branch."
    }
    let repoName = session.projectPathForProjectFeatures.map { URL(fileURLWithPath: $0, isDirectory: true).lastPathComponent } ?? PiAgentSessionRecord.noProjectDisplayName
    return """
    Repository: \(repoName)
    Source branch: \(source)
    Session branch: \(branch)

    Merge will:
    • Commit pending worktree changes (AI message)
    • Merge into the source branch with --no-ff
    • Remove the worktree and delete the branch

    Requires the project repo to be clean.
    """
}

private enum PiAgentGitAction: Identifiable {
    case commit
    case commitAndPush

    var id: String { String(describing: self) }

    var alertTitle: String {
        switch self {
        case .commit: return "Commit all changes?"
        case .commitAndPush: return "Commit and push all changes?"
        }
    }

    var confirmTitle: String {
        switch self {
        case .commit: return "Commit All Changes"
        case .commitAndPush: return "Commit & Push All Changes"
        }
    }

    var alertMessage: String {
        switch self {
        case .commit:
            return "This will stage all changes in the selected session's working tree, generate a commit title and description with a no-thinking helper model, and commit on the current branch. It will not push."
        case .commitAndPush:
            return "This will stage all changes in the selected session's working tree, generate a commit title and description with a no-thinking helper model, commit on the current branch, and push to the configured upstream. It will not ask follow-up questions."
        }
    }
}

struct PiAgentOpenTerminalToolbarButton: View {
    var viewModel: AppViewModel
    var store: PiAgentSessionStore
    @ObservedObject private var languageStore = LanguageStore.shared
    /// Cached result of `canOpen`. Refreshed via `.onChange` rather than
    /// computed per body — avoids `FileManager.fileExists` on every toolbar
    /// re-render (streaming hot path).
    @State private var canOpen: Bool = false

    var body: some View {
        Button {
            viewModel.openSelectedPiAgentSessionInTerminal()
        } label: {
            Label(languageStore.t("agent.resumeTerminal"), systemImage: "terminal")
        }
        .accessibilityLabel(languageStore.t("agent.resumeTerminal"))
        .symbolRenderingMode(.monochrome)
        .foregroundStyle(.primary)
        .tint(.primary)
        .help(languageStore.t("agent.resumeTerminalHelp"))
        .disabled(!canOpen)
        .task(id: store.selectedSession?.id) { refreshCanOpen() }
        .onChange(of: store.selectedSession?.projectPath) { refreshCanOpen() }
        .onChange(of: store.selectedSession?.worktreePath) { refreshCanOpen() }
    }

    /// Enables the button when the selected session has an on-disk project directory.
    private func refreshCanOpen() {
        canOpen = viewModel.canOpenSelectedPiAgentSessionInTerminal
    }
}


struct PiAgentTranscriptDisplayOptionsPopover: View {
    var viewModel: AppViewModel
    @ObservedObject private var languageStore = LanguageStore.shared

    private var visibility: PiAgentTranscriptVisibilitySettings {
        viewModel.appSettings.piAgentTranscriptVisibility
    }

    private struct Option: Identifiable {
        let title: String
        let subtitle: String
        let systemImage: String
        var assetImage: String? = nil
        let keyPath: WritableKeyPath<PiAgentTranscriptVisibilitySettings, Bool>
        var id: String { title }
    }

    private var options: [Option] {
        let ls = languageStore
        return [
        .init(title: ls.t("display.shortcuts"), subtitle: ls.t("display.shortcutsSub"), systemImage: "keyboard", keyPath: \.showShortcutsStrip),
        .init(title: ls.t("display.thinking"), subtitle: ls.t("display.thinkingSub"), systemImage: "brain.head.profile", keyPath: \.showThinking),
        .init(title: ls.t("display.web"), subtitle: ls.t("display.webSub"), systemImage: "globe", keyPath: \.showWebActivity),
        .init(title: ls.t("display.errors"), subtitle: ls.t("display.errorsSub"), systemImage: "exclamationmark.triangle", keyPath: \.showErrors),
        .init(title: ls.t("display.finalPrompt"), subtitle: ls.t("display.finalPromptSub"), systemImage: "doc.text", keyPath: \.showFinalSystemPrompt),
        .init(title: ls.t("display.diffs"), subtitle: ls.t("display.diffsSub"), systemImage: "plusminus", keyPath: \.showDiffs),
        .init(title: ls.t("display.images"), subtitle: ls.t("display.imagesSub"), systemImage: "photo", keyPath: \.showImages),
        .init(title: ls.t("display.memory"), subtitle: ls.t("display.memorySub"), systemImage: "brain", keyPath: \.showMemoryCards),
        .init(title: ls.t("display.mcp"), subtitle: ls.t("display.mcpSub"), systemImage: AppSymbols.mcp, assetImage: AppSymbols.mcp, keyPath: \.showMCPCards),
        ]
    }

    var body: some View {
        AppPopoverContainer(title: languageStore.t("display.title")) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                    AppPopoverToggleRow(
                        systemImage: option.systemImage,
                        assetImage: option.assetImage,
                        title: option.title,
                        subtitle: option.subtitle,
                        isOn: Binding(
                            get: { visibility[keyPath: option.keyPath] },
                            set: { viewModel.setPiAgentTranscriptVisibility(option.keyPath, to: $0) }
                        )
                    )
                    if index < options.count - 1 {
                        Divider()
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }
}

