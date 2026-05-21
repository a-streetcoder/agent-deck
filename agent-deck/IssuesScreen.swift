import AppKit
import SwiftUI

struct IssuesScreen: View {
    @ObservedObject var viewModel: AppViewModel
    @Binding var searchText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if viewModel.selectedGitHubProject?.gitHubRemote != nil {
                header
                Divider()
            }
            body(for: viewModel.selectedGitHubProject)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        .onChange(of: viewModel.githubIssueStateFilter) { _, _ in
            viewModel.refreshProjectBoard(force: true)
        }
        .onChange(of: viewModel.githubAuthorFilter) { _, _ in reconcileSelectionWithFilters() }
        .onChange(of: viewModel.githubLabelFilters) { _, _ in reconcileSelectionWithFilters() }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        if let remote = viewModel.selectedGitHubProject?.gitHubRemote {
            HStack(spacing: 10) {
                Image("github")
                    .resizable()
                    .renderingMode(.template)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 18, height: 18)
                    .foregroundStyle(.primary)
                Text(remote.nameWithOwner)
                    .font(.headline)
                    .fontWidth(.expanded)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, AppTheme.pagePadding)
            .padding(.vertical, 12)
        }
    }

    // MARK: - Body

    @ViewBuilder
    private func body(for project: DiscoveredProject?) -> some View {
        if let error = viewModel.githubLastError {
            errorBanner(error)
        }

        if project?.gitHubRemote == nil {
            noProjectPlaceholder
        } else if !viewModel.githubConnectionState.isConnected {
            ContentUnavailableView(
                "Not Connected to GitHub",
                systemImage: "person.crop.circle.badge.questionmark",
                description: Text("Connect your GitHub CLI session to browse issues.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.githubIsLoadingProjectBoard && viewModel.githubProjectBoard == nil {
            loadingState
        } else if let board = viewModel.githubProjectBoard {
            boardContent(board: board)
        } else {
            ContentUnavailableView(
                "No Issues Loaded",
                systemImage: "circle.dashed",
                description: Text("Refresh to load issues for this repository.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var noProjectPlaceholder: some View {
        if viewModel.selectedProjectPath != nil {
            ContentUnavailableView(
                "No GitHub Remote",
                systemImage: "link.badge.plus",
                description: Text("The selected project is not mapped to a GitHub remote.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView(
                "No Project Selected",
                systemImage: "folder",
                description: Text("Choose a project to browse its issues.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var loadingState: some View {
        VStack {
            AppRowCard {
                HStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.small)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Loading issues")
                            .font(.headline)
                        Text("Fetching open issues for this repository.")
                            .foregroundStyle(AppTheme.mutedText)
                    }
                    Spacer()
                }
            }
            .frame(maxWidth: 460)
            Spacer()
        }
        .padding(AppTheme.pagePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func boardContent(board: GitHubBoardSnapshot) -> some View {
        let visibleItems = searchFiltered(viewModel.filteredBoardItems(from: board))
        let query = trimmedSearchQuery
        let filtersActive = viewModel.githubAuthorFilter != nil || !viewModel.githubLabelFilters.isEmpty
        let narrowed = filtersActive || !query.isEmpty

        if visibleItems.isEmpty {
            ContentUnavailableView(
                "No Matching Issues",
                systemImage: narrowed ? "line.3.horizontal.decrease.circle" : "checkmark.circle",
                description: Text(emptyStateMessage(query: query, filtersActive: filtersActive))
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HSplitView {
                issueList(items: visibleItems, totalShown: board.shownCount, totalCount: board.totalCount, incomplete: board.incompleteResults)
                    .frame(minWidth: 430, idealWidth: 520, maxWidth: 640)
                detailColumn
                    .frame(minWidth: 440, idealWidth: 640, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private func issueList(items: [GitHubWorkItem], totalShown: Int, totalCount: Int, incomplete: Bool) -> some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 10) {
                if totalShown < totalCount {
                    listNote("Showing first \(totalShown) of \(totalCount) matching issues.", tint: .orange)
                }
                if incomplete {
                    listNote("GitHub reported incomplete search results — narrow the scope if items look missing.", tint: .orange)
                }

                ForEach(items) { item in
                    GitHubIssueListRow(
                        item: item,
                        isSelected: viewModel.githubSelectedWorkItem == item,
                        onSelect: { viewModel.selectWorkItem(item) },
                        onOpenInPi: { viewModel.startPiAgentForWorkItem(item) },
                        onToggleState: {
                            if item.state.lowercased() == "open" {
                                viewModel.closeIssue(item)
                            } else {
                                viewModel.reopenIssue(item)
                            }
                        }
                    )
                }
            }
            .padding(.horizontal, AppTheme.pagePadding)
            .padding(.vertical, 16)
        }
    }

    private func listNote(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(tint)
            .padding(.bottom, 4)
    }

    private var detailColumn: some View {
        GeometryReader { proxy in
            Group {
                if viewModel.githubSelectedWorkItem != nil {
                    GitHubIssueDetailView(viewModel: viewModel)
                } else {
                    ContentUnavailableView(
                        "Select an Issue",
                        systemImage: "doc.text",
                        description: Text("Pick an issue from the list to read it, browse comments, and reply.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, AppTheme.pagePadding)
        .padding(.vertical, 10)
        .background(Color.red.opacity(0.07))
    }

    // MARK: - Search

    private var trimmedSearchQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func searchFiltered(_ items: [GitHubWorkItem]) -> [GitHubWorkItem] {
        let query = trimmedSearchQuery
        guard !query.isEmpty else { return items }
        return items.filter { item in
            if item.title.lowercased().contains(query) { return true }
            if String(item.number).contains(query) { return true }
            if let author = item.author, author.lowercased().contains(query) { return true }
            if item.labels.contains(where: { $0.lowercased().contains(query) }) { return true }
            if item.body.lowercased().contains(query) { return true }
            return false
        }
    }

    private func emptyStateMessage(query: String, filtersActive: Bool) -> String {
        if !query.isEmpty {
            return "No issues match “\(searchText.trimmingCharacters(in: .whitespacesAndNewlines))”."
        }
        if filtersActive {
            return "Try clearing the filters or changing the state."
        }
        return "There are no \(viewModel.githubIssueStateFilter.rawValue.lowercased()) issues for this repository."
    }

    // MARK: - Helpers

    private func reconcileSelectionWithFilters() {
        let visible = viewModel.githubVisibleBoardItems
        guard let current = viewModel.githubSelectedWorkItem else {
            if let first = visible.first { viewModel.selectWorkItem(first) }
            return
        }
        if !visible.contains(current), let first = visible.first {
            viewModel.selectWorkItem(first)
        }
    }

    private var refreshKey: String {
        [
            viewModel.githubIssueStateFilter.rawValue,
            viewModel.selectedGitHubProject?.path ?? "none",
            viewModel.githubConnectionState.isConnected ? "connected" : "disconnected"
        ].joined(separator: "|")
    }
}

// MARK: - Filters popover

struct IssuesFiltersPopover: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            stateSection
            Divider()
            creatorSection
            if !viewModel.githubAvailableLabels.isEmpty {
                Divider()
                labelsSection
            }
            if filtersActive {
                Divider()
                HStack {
                    Spacer()
                    Button("Clear all filters") {
                        viewModel.resetIssueFilters()
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(14)
        .frame(width: 280)
    }

    private var filtersActive: Bool {
        viewModel.githubAuthorFilter != nil || !viewModel.githubLabelFilters.isEmpty
    }

    private var stateSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("State")
            Picker("State", selection: $viewModel.githubIssueStateFilter) {
                ForEach(GitHubIssueStateFilter.allCases) { state in
                    Text(state.rawValue).tag(state)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var creatorSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Creator")
            Picker("Creator", selection: authorBinding) {
                Text("Any creator").tag(String?.none)
                if !viewModel.githubAvailableAuthors.isEmpty {
                    Divider()
                    ForEach(viewModel.githubAvailableAuthors, id: \.self) { author in
                        Text(author).tag(String?.some(author))
                    }
                }
            }
            .labelsHidden()
            .disabled(viewModel.githubAvailableAuthors.isEmpty)
        }
    }

    private var authorBinding: Binding<String?> {
        Binding(
            get: { viewModel.githubAuthorFilter },
            set: { viewModel.githubAuthorFilter = $0 }
        )
    }

    private var labelsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionHeader("Labels")
                Spacer()
                if !viewModel.githubLabelFilters.isEmpty {
                    Button("Clear") { viewModel.githubLabelFilters = [] }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(viewModel.githubAvailableLabels, id: \.self) { label in
                        labelToggleRow(label)
                    }
                }
            }
            .frame(maxHeight: 220)
        }
    }

    private func labelToggleRow(_ label: String) -> some View {
        let isOn = viewModel.githubLabelFilters.contains(label)
        return Button {
            if isOn {
                viewModel.githubLabelFilters.remove(label)
            } else {
                viewModel.githubLabelFilters.insert(label)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isOn ? AppTheme.brandAccent : AppTheme.mutedText)
                Text(label)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(AppTheme.mutedText)
    }
}
