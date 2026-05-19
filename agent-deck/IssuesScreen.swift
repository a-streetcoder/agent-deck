import AppKit
import SwiftUI

struct IssuesScreen: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        AppPage("Issues", subtitle: subtitle) {
            GitHubIssuesWorkspace(
                viewModel: viewModel,
                board: viewModel.githubProjectBoard,
                isLoading: viewModel.githubIsLoadingProjectBoard,
                showStateFilter: true,
                refreshAction: { viewModel.refreshProjectBoard(force: true) }
            )
        }
        .task {
            await Task.yield()
            await viewModel.prepareGitHubScreen()
        }
        .task(id: refreshKey) {
            await Task.yield()
            guard viewModel.githubConnectionState.isConnected,
                  viewModel.selectedGitHubProject?.gitHubRemote != nil else { return }
            viewModel.refreshProjectBoard(force: false)
        }
    }

    private var subtitle: String {
        if let project = viewModel.selectedGitHubProject {
            return "Browse issues for \(project.repositoryDisplayName)"
        }
        if viewModel.selectedProjectPath != nil {
            return "The selected project is not mapped to a GitHub remote yet."
        }
        return "Select a project to browse its issues."
    }

    private var refreshKey: String {
        [
            viewModel.githubIssueStateFilter.rawValue,
            viewModel.selectedGitHubProject?.path ?? "none",
            viewModel.githubConnectionState.isConnected ? "connected" : "disconnected"
        ].joined(separator: "|")
    }
}
