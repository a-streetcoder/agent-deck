import AppKit
import SwiftUI

struct PiAgentCommitToolbarButton: View {
    var viewModel: AppViewModel
    @State private var isConfirmationPresented = false

    var body: some View {
        Button { commitTapped() } label: {
            Label {
                Text("Commit")
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
        .accessibilityLabel("Commit")
        .disabled(!viewModel.canCommitSelectedPiAgentSession)
        .help("Stage all changes and create a commit with an AI-generated title and description")
        .alert("Commit all changes?", isPresented: $isConfirmationPresented) {
            Button("Commit All Changes") { viewModel.commitSelectedPiAgentSession() }
            Button("Cancel", role: .cancel) {}
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

    var body: some View {
        Button { viewModel.pushSelectedPiAgentSession() } label: {
            Label {
                Text("Push")
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
        .accessibilityLabel("Push")
        .disabled(!viewModel.canPushSelectedPiAgentSession)
        .help("Push committed changes on the selected session's current branch")
    }
}

struct PiAgentCommitAndPushToolbarButton: View {
    var viewModel: AppViewModel
    @State private var isConfirmationPresented = false

    var body: some View {
        Button { commitAndPushTapped() } label: {
            Label {
                Text("Commit & Push")
            } icon: {
                if viewModel.piAgentGitAutomationAction == .commitAndPush {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .symbolEffect(.rotate, options: .repeating)
                } else {
                    Image("git-commit")
                }
            }
        }
        .accessibilityLabel("Commit & Push")
        .disabled(!viewModel.canCommitAndPushSelectedPiAgentSession)
        .help("Stage all changes, commit, and push the selected session's current branch")
        .alert("Commit and push all changes?", isPresented: $isConfirmationPresented) {
            Button("Commit & Push All Changes") { viewModel.commitAndPushSelectedPiAgentSession() }
            Button("Cancel", role: .cancel) {}
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
    @State private var isConfirmationPresented = false

    var body: some View {
        Button { isConfirmationPresented = true } label: {
            Label {
                Text("Merge")
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
        .accessibilityLabel("Merge")
        .disabled(!viewModel.canMergeSelectedPiAgentSession)
        .help("Switch the project to the source branch and merge the session branch back in")
        .alert("Merge session branch?", isPresented: $isConfirmationPresented) {
            Button("Merge") { viewModel.mergeSelectedPiAgentSession() }
            Button("Cancel", role: .cancel) {}
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
    let repoName = URL(fileURLWithPath: session.projectPath, isDirectory: true).lastPathComponent
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
            Label("Resume in Terminal", systemImage: "terminal")
        }
        .accessibilityLabel("Resume in Terminal")
        .symbolRenderingMode(.monochrome)
        .foregroundStyle(.primary)
        .tint(.primary)
        .help("Opens a terminal continuation from this session file. Terminal messages do not sync back into \(AppBrand.displayName) yet.")
        .disabled(!canOpen)
        .alert("Resume in Terminal?", isPresented: $isParallelContinuationWarningPresented) {
            Button("Resume in Terminal") { viewModel.openSelectedPiAgentSessionInTerminal() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This opens a parallel terminal continuation from the session file. Messages sent in Terminal do not sync back into \(AppBrand.displayName) yet.")
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
        let keyPath: WritableKeyPath<PiAgentTranscriptVisibilitySettings, Bool>
        var id: String { title }
    }

    private let options: [Option] = [
        .init(title: "Keyboard shortcuts", subtitle: "Show the shortcut strip at the top of the transcript", systemImage: "keyboard", keyPath: \.showShortcutsStrip),
        .init(title: "Thinking", subtitle: "Show Pi reasoning blocks", systemImage: "brain.head.profile", keyPath: \.showThinking),
        .init(title: "Web activity", subtitle: "Show searches and fetched/read links", systemImage: "globe", keyPath: \.showWebActivity),
        .init(title: "Tool calls", subtitle: "Show non-web tool call summaries", systemImage: "wrench.and.screwdriver", keyPath: \.showToolCalls),
        .init(title: "Errors", subtitle: "Show error rows in the transcript", systemImage: "exclamationmark.triangle", keyPath: \.showErrors),
        .init(title: "Final system prompt", subtitle: "Show Pi's captured final system prompt card", systemImage: "doc.text", keyPath: \.showFinalSystemPrompt),
        .init(title: "Diffs", subtitle: "Show compact file changes in chat", systemImage: "doc.text.magnifyingglass", keyPath: \.showDiffs),
        .init(title: "Memory", subtitle: "Show memory recall cards in the transcript", systemImage: "brain", keyPath: \.showMemoryCards),
    ]

    var body: some View {
        // Plain dividered rows, matching the native Session resources popover —
        // no per-row themed card surface.
        VStack(alignment: .leading, spacing: 0) {
            Label("Transcript display", systemImage: "eye")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.mutedText)
                .padding(.bottom, 10)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                    optionRow(option)
                    if index < options.count - 1 {
                        Divider()
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 280)
    }

    private func optionRow(_ option: Option) -> some View {
        let isOn = visibility[keyPath: option.keyPath]
        return Button {
            viewModel.setPiAgentTranscriptVisibility(option.keyPath, to: !isOn)
        } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOn ? AppTheme.brandAccent : AppTheme.mutedText)
                    .frame(width: 17)
                Image(systemName: option.systemImage)
                    .foregroundStyle(AppTheme.mutedText)
                    .frame(width: 17)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(option.subtitle)
                        .font(.caption2)
                        .foregroundStyle(AppTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

