import AppKit
import SwiftUI

struct GitHubScreen: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        AppPage("GitHub", subtitle: subtitle) {
            Picker("Section", selection: $viewModel.githubSelectedSection) {
                ForEach(GitHubSection.allCases) { section in
                    Text(section.rawValue).tag(section)
                }
            }
            .pickerStyle(.segmented)

            switch viewModel.githubSelectedSection {
            case .projectBoard:
                GitHubProjectPlaceholder(viewModel: viewModel)
            case .repoChanges:
                GitHubRepoChangesPlaceholder(viewModel: viewModel)
            case .connection:
                GitHubConnectionDetails(viewModel: viewModel)
            }
        }
        .task {
            await Task.yield()
            await viewModel.prepareGitHubScreen()
        }
        .task(id: boardRefreshKey) {
            await Task.yield()
            guard viewModel.githubSelectedSection == .projectBoard,
                  viewModel.githubConnectionState.isConnected,
                  viewModel.selectedGitHubProject?.gitHubRemote != nil else { return }
            viewModel.refreshProjectBoard(force: false)
        }
        .task(id: repoRefreshKey) {
            await Task.yield()
            guard viewModel.githubSelectedSection == .repoChanges,
                  viewModel.selectedDiscoveredProject?.isGitRepository == true else { return }
            viewModel.refreshRepositoryChanges()
        }
    }

    private var subtitle: String {
        if let project = viewModel.selectedGitHubProject {
            return "Rich issue list and repo workflow for \(project.repositoryDisplayName)"
        }
        if viewModel.selectedProjectPath != nil {
            return "The selected project is not mapped to a GitHub remote yet."
        }
        return "No project selected. Choose one from the sidebar to work repo-by-repo."
    }

    private var boardRefreshKey: String {
        [
            viewModel.githubSelectedSection.rawValue,
            viewModel.githubIssueStateFilter.rawValue,
            viewModel.selectedGitHubProject?.path ?? "none",
            viewModel.githubConnectionState.isConnected ? "connected" : "disconnected"
        ].joined(separator: "|")
    }

    private var repoRefreshKey: String {
        [
            viewModel.githubSelectedSection.rawValue,
            viewModel.selectedDiscoveredProject?.path ?? "none"
        ].joined(separator: "|")
    }
}
