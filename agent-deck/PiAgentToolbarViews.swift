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
    @State private var isParallelContinuationWarningPresented = false
    /// Cached result of `canOpen`. Refreshed via `.onChange` rather than
    /// computed per body — the previous computed property did a
    /// `FileManager.default.fileExists` on every toolbar re-render (which
    /// includes per-streaming-token invalidation pulses on a jank-sensitive
    /// hot path).
    @State private var canOpen: Bool = false

    var body: some View {
        Button {
            if selectedSessionIsActive {
                isParallelContinuationWarningPresented = true
            } else {
                viewModel.openSelectedPiAgentSessionInTerminal()
            }
        } label: {
            Label(languageStore.t("agent.resumeTerminal"), systemImage: "terminal")
        }
        .accessibilityLabel(languageStore.t("agent.resumeTerminal"))
        .symbolRenderingMode(.monochrome)
        .foregroundStyle(.primary)
        .tint(.primary)
        .help(languageStore.t("agent.resumeTerminalHelp", AppBrand.displayName))
        .disabled(!canOpen)
        .alert(languageStore.t("agent.resumeTerminalAlertTitle"), isPresented: $isParallelContinuationWarningPresented) {
            Button(languageStore.t("agent.resumeTerminal")) { viewModel.openSelectedPiAgentSessionInTerminal() }
            Button(languageStore.t("common.cancel"), role: .cancel) {}
        } message: {
            Text(languageStore.t("agent.resumeTerminalMessage", AppBrand.displayName))
        }
        .task(id: store.selectedSession?.id) { refreshCanOpen() }
        .onChange(of: store.selectedSession?.piSessionFile) { refreshCanOpen() }
        .onChange(of: store.selectedSession?.piSessionId) { refreshCanOpen() }
    }

    private func refreshCanOpen() {
        guard let session = store.selectedSession else {
            canOpen = false
            return
        }
        if let sessionFile = session.piSessionFile, FileManager.default.fileExists(atPath: sessionFile) {
            canOpen = true
            return
        }
        canOpen = session.piSessionId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private var selectedSessionIsActive: Bool {
        store.selectedSession?.status.isActive == true
    }
}


struct PiAgentTranscriptDisplayOptionsPopover: View {
    var viewModel: AppViewModel

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

    private let options: [Option] = [
        .init(title: "Keyboard shortcuts", subtitle: "Show the shortcut strip at the top of the transcript", systemImage: "keyboard", keyPath: \.showShortcutsStrip),
        .init(title: "Thinking", subtitle: "Show Pi reasoning blocks", systemImage: "brain.head.profile", keyPath: \.showThinking),
        .init(title: "Web activity", subtitle: "Show searches and fetched/read links", systemImage: "globe", keyPath: \.showWebActivity),
        .init(title: "Errors", subtitle: "Show error rows in the transcript", systemImage: "exclamationmark.triangle", keyPath: \.showErrors),
        .init(title: "Final system prompt", subtitle: "Show Pi's captured final system prompt card", systemImage: "doc.text", keyPath: \.showFinalSystemPrompt),
        .init(title: "Diffs", subtitle: "Show compact file changes in chat", systemImage: "plusminus", keyPath: \.showDiffs),
        .init(title: "Images", subtitle: "Show inline image previews in transcripts", systemImage: "photo", keyPath: \.showImages),
        .init(title: "Memory", subtitle: "Show memory recall cards in the transcript", systemImage: "brain", keyPath: \.showMemoryCards),
        .init(title: "MCP", subtitle: "Show MCP tool call cards in the transcript", systemImage: AppSymbols.mcp, assetImage: AppSymbols.mcp, keyPath: \.showMCPCards),
    ]

    var body: some View {
        AppPopoverContainer(title: "Transcript display") {
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

