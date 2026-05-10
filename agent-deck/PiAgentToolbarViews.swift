import AppKit
import SwiftUI

struct PiAgentGitActionsToolbarGroup: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var isCommitConfirmationPresented = false
    @State private var isCommitAndPushConfirmationPresented = false

    var body: some View {
        ControlGroup {
            Button { commitTapped() } label: {
                Label("Commit", systemImage: "checkmark.seal")
                    .opacity(viewModel.piAgentGitAutomationAction == .commit ? 0 : 1)
                    .overlay {
                        if viewModel.piAgentGitAutomationAction == .commit {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .symbolEffect(.rotate, options: .repeating)
                        }
                    }
            }
            .disabled(!viewModel.canCommitSelectedPiAgentSession)
            .help("Stage all changes and create a commit with an AI-generated title and description")
            .alert("Commit all changes?", isPresented: $isCommitConfirmationPresented) {
                Button("Commit All Changes") { viewModel.commitSelectedPiAgentSession() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(alertMessage(for: .commit))
            }

            Button { viewModel.pushSelectedPiAgentSession() } label: {
                Label("Push", systemImage: "arrow.up.circle")
                    .opacity(viewModel.piAgentGitAutomationAction == .push ? 0 : 1)
                    .overlay {
                        if viewModel.piAgentGitAutomationAction == .push {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .symbolEffect(.rotate, options: .repeating)
                        }
                    }
            }
            .disabled(!viewModel.canPushSelectedPiAgentSession)
            .help("Push committed changes on the selected session's current branch")

            Button { commitAndPushTapped() } label: {
                Label("Commit & Push", systemImage: "shippingbox.and.arrow.backward")
                    .opacity(viewModel.piAgentGitAutomationAction == .commitAndPush ? 0 : 1)
                    .overlay {
                        if viewModel.piAgentGitAutomationAction == .commitAndPush {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .symbolEffect(.rotate, options: .repeating)
                        }
                    }
            }
            .disabled(!viewModel.canCommitAndPushSelectedPiAgentSession)
            .help("Stage all changes, commit, and push the selected session's current branch")
            .alert("Commit and push all changes?", isPresented: $isCommitAndPushConfirmationPresented) {
                Button("Commit & Push All Changes") { viewModel.commitAndPushSelectedPiAgentSession() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(alertMessage(for: .commitAndPush))
            }

        }
    }

    private func alertMessage(for action: PiAgentGitAction) -> String {
        guard let session = viewModel.piAgentSessionStore.selectedSession else { return action.alertMessage }
        let repoName = URL(fileURLWithPath: session.projectPath, isDirectory: true).lastPathComponent
        return "Repository: \(repoName)\n\n\(action.alertMessage)"
    }

    private func commitTapped() {
        if viewModel.appSettings.piAgentGitAutomationRequiresConfirmation {
            isCommitConfirmationPresented = true
        } else {
            viewModel.commitSelectedPiAgentSession()
        }
    }

    private func commitAndPushTapped() {
        if viewModel.appSettings.piAgentGitAutomationRequiresConfirmation {
            isCommitAndPushConfirmationPresented = true
        } else {
            viewModel.commitAndPushSelectedPiAgentSession()
        }
    }
}

struct PiAgentGitHubToolbarButton: View {
    @ObservedObject var viewModel: AppViewModel
    @Binding var isRepoChangesPresented: Bool

    var body: some View {
        Button {
            isRepoChangesPresented.toggle()
            if isRepoChangesPresented {
                viewModel.prepareRepoChangesForSelectedPiAgentSession()
            }
        } label: {
            Image("github")
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
        }
        .help("Show GitHub panel")
        .accessibilityLabel("Show GitHub panel")
        .disabled(viewModel.piAgentSessionStore.selectedSession == nil)
    }
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

