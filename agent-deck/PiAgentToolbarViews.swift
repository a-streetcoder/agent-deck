import AppKit
import SwiftUI

struct PiAgentCommitToolbarButton: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var isConfirmationPresented = false

    var body: some View {
        Button { commitTapped() } label: {
            Label {
                Text("Commit")
            } icon: {
                if viewModel.piAgentGitAutomationAction == .commit {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .symbolEffect(.rotate, options: .repeating)
                } else {
                    Image("git-commit")
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
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        Button { viewModel.pushSelectedPiAgentSession() } label: {
            Label("Push", systemImage: iconName)
                .symbolEffect(.rotate, options: .repeating, isActive: viewModel.piAgentGitAutomationAction == .push)
        }
        .accessibilityLabel("Push")
        .disabled(!viewModel.canPushSelectedPiAgentSession)
        .help("Push committed changes on the selected session's current branch")
    }

    private var iconName: String {
        viewModel.piAgentGitAutomationAction == .push ? "arrow.triangle.2.circlepath" : "arrow.up"
    }
}

struct PiAgentCommitAndPushToolbarButton: View {
    @ObservedObject var viewModel: AppViewModel
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

private func piAgentGitAlertMessage(for action: PiAgentGitAction, viewModel: AppViewModel) -> String {
    guard let session = viewModel.piAgentSessionStore.selectedSession else { return action.alertMessage }
    let repoName = URL(fileURLWithPath: session.projectPath, isDirectory: true).lastPathComponent
    return "Repository: \(repoName)\n\n\(action.alertMessage)"
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
            return "This will stage all changes in the selected session's project, generate a commit title and description with a no-thinking helper model, and commit on the current branch. It will not push."
        case .commitAndPush:
            return "This will stage all changes in the selected session's project, generate a commit title and description with a no-thinking helper model, commit on the current branch, and push to the configured upstream. It will not ask follow-up questions."
        }
    }
}

struct PiAgentOpenTerminalToolbarButton: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var store: PiAgentSessionStore
    @State private var isParallelContinuationWarningPresented = false

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
    }

    private var canOpen: Bool {
        guard let session = store.selectedSession else { return false }
        if let sessionFile = session.piSessionFile, FileManager.default.fileExists(atPath: sessionFile) { return true }
        return session.piSessionId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private var selectedSessionIsActive: Bool {
        store.selectedSession?.status.isActive == true
    }
}


struct PiAgentTranscriptDisplayOptionsPopover: View {
    @ObservedObject var viewModel: AppViewModel

    private var visibility: PiAgentTranscriptVisibilitySettings {
        viewModel.appSettings.piAgentTranscriptVisibility
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Transcript display", systemImage: "eye")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.mutedText)

            optionRow(
                title: "Thinking",
                subtitle: "Show Pi reasoning blocks",
                systemImage: "brain.head.profile",
                isOn: visibility.showThinking,
                keyPath: \.showThinking
            )
            optionRow(
                title: "Web activity",
                subtitle: "Show searches and fetched/read links",
                systemImage: "globe",
                isOn: visibility.showWebActivity,
                keyPath: \.showWebActivity
            )
            optionRow(
                title: "Tool calls",
                subtitle: "Show non-web tool call summaries",
                systemImage: "wrench.and.screwdriver",
                isOn: visibility.showToolCalls,
                keyPath: \.showToolCalls
            )
            optionRow(
                title: "Errors",
                subtitle: "Show error rows in the transcript",
                systemImage: "exclamationmark.triangle",
                isOn: visibility.showErrors,
                keyPath: \.showErrors
            )
            optionRow(
                title: "Plans",
                subtitle: "Show the current session plan above the chat",
                systemImage: "checklist",
                isOn: visibility.showPlans,
                keyPath: \.showPlans
            )
            optionRow(
                title: "Diffs",
                subtitle: "Show compact file changes in chat",
                systemImage: "doc.text.magnifyingglass",
                isOn: visibility.showDiffs,
                keyPath: \.showDiffs
            )
        }
        .padding(12)
        .frame(width: 260)
    }

    private func optionRow(
        title: String,
        subtitle: String,
        systemImage: String,
        isOn: Bool,
        keyPath: WritableKeyPath<PiAgentTranscriptVisibilitySettings, Bool>
    ) -> some View {
        Button {
            viewModel.setPiAgentTranscriptVisibility(keyPath, to: !isOn)
        } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOn ? AppTheme.brandAccent : AppTheme.mutedText)
                    .frame(width: 17)
                Image(systemName: systemImage)
                    .foregroundStyle(AppTheme.mutedText)
                    .frame(width: 17)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(AppTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .appContentSurface(cornerRadius: 9, isSelected: isOn)
        }
        .buttonStyle(.plain)
    }
}

