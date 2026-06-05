import AppKit
import SwiftUI

struct IssuesScreen: View {
    @Bindable var viewModel: AppViewModel
    @Binding var searchText: String
    /// Cached visible items. Recomputed via `.task(id: visibleItemsCacheKey)`
    /// over the 6 input drivers (board, 4 filters, search). Without this, every
    /// observable read of GitHub state would re-run the filter + search passes
    /// (each allocating a Set per item per call), producing a re-render storm
    /// on a board with even moderate item counts.
    @State private var visibleItems: [GitHubWorkItem] = []

    var body: some View {
        body(for: viewModel.selectedGitHubProject)
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
        .task(id: visibleItemsCacheKey) { recomputeVisibleItems() }
        .onChange(of: viewModel.githubIssueStateFilter) { _, _ in
            viewModel.refreshProjectBoard(force: true)
        }
        .onChange(of: viewModel.githubCloseReasonFilter) { _, _ in
            viewModel.refreshProjectBoard(force: true)
        }
        .onChange(of: viewModel.githubAuthorFilter) { _, _ in reconcileSelectionWithFilters() }
        .onChange(of: viewModel.githubAssigneeFilter) { _, _ in reconcileSelectionWithFilters() }
        .onChange(of: viewModel.githubTypeFilter) { _, _ in reconcileSelectionWithFilters() }
        .onChange(of: viewModel.githubLabelFilters) { _, _ in reconcileSelectionWithFilters() }
    }

    private var visibleItemsCacheKey: String {
        // Use the AppViewModel's board revision Int instead of hashing the
        // full board per render. `allItems` was O(N log N) (flatMap+sort);
        // the revision bumps once per board assignment.
        "\(viewModel.githubProjectBoardRevision)|\(viewModel.githubAuthorFilter ?? "")|\(viewModel.githubAssigneeFilter ?? "")|\(viewModel.githubTypeFilter ?? "")|\(viewModel.githubLabelFilters.sorted().joined(separator: ","))|\(trimmedSearchQuery)"
    }

    private func recomputeVisibleItems() {
        guard let board = viewModel.githubProjectBoard else {
            visibleItems = []
            return
        }
        visibleItems = searchFiltered(viewModel.filteredBoardItems(from: board))
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
                    AppSpinner()
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
        // `visibleItems` comes from the cached @State recomputed via
        // `.task(id: visibleItemsCacheKey)`. Body just reads it.
        let query = trimmedSearchQuery
        let filtersActive = viewModel.githubAuthorFilter != nil
            || viewModel.githubAssigneeFilter != nil
            || viewModel.githubTypeFilter != nil
            || !viewModel.githubLabelFilters.isEmpty
        let narrowed = filtersActive || !query.isEmpty

        if visibleItems.isEmpty {
            ContentUnavailableView(
                "No Matching Issues",
                systemImage: narrowed ? "line.3.horizontal.decrease.circle" : "checkmark.circle",
                description: Text(emptyStateMessage(query: query, filtersActive: filtersActive))
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            SplitView {
                issueList(items: visibleItems, totalShown: board.shownCount, totalCount: board.totalCount, incomplete: board.incompleteResults)
            } detail: {
                detailColumn
            }
        }
    }

    private func issueList(items: [GitHubWorkItem], totalShown: Int, totalCount: Int, incomplete: Bool) -> some View {
        // Same shared list primitive as Agents/Prompts/Skills (`AppList`): flat
        // themed selection rows, not the bespoke bordered cards this screen used
        // before. Truncation/incomplete notes are pinned above the list (mirroring
        // the Skills warning strip) since `AppList` rows are typed to `Item`.
        VStack(alignment: .leading, spacing: 0) {
            if totalShown < totalCount || incomplete {
                VStack(alignment: .leading, spacing: 4) {
                    if totalShown < totalCount {
                        listNote("Showing first \(totalShown) of \(totalCount) matching issues.", tint: .orange)
                    }
                    if incomplete {
                        listNote("GitHub reported incomplete search results — narrow the scope if items look missing.", tint: .orange)
                    }
                }
                .padding(.horizontal, AppTheme.pagePadding)
                .padding(.top, 12)
            }

            AppList(
                sections: [AppListSection(id: "issues", items: items)],
                selection: .single(selectedIssueIDBinding)
            ) { item in
                GitHubIssueRowContent(
                    item: item,
                    onOpenInPi: { viewModel.startPiAgentForWorkItem(item) },
                    onClose: { reason in viewModel.closeIssue(item, reason: reason) },
                    onReopen: { viewModel.reopenIssue(item) }
                )
                // Matches the Agents/Skills row density (this stacks on AppList's
                // own row padding, same as `agentListRow`).
                .padding(.vertical, 6)
            }
        }
    }

    /// Bridges `AppList`'s id-based single selection to the view model's
    /// item-based selection (which also kicks off the detail fetch).
    private var selectedIssueIDBinding: Binding<GitHubWorkItem.ID?> {
        Binding(
            get: { viewModel.githubSelectedWorkItem?.id },
            set: { id in
                guard let id, let item = visibleItems.first(where: { $0.id == id }) else { return }
                viewModel.selectWorkItem(item)
            }
        )
    }

    private func listNote(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(tint)
            .padding(.bottom, 4)
    }

    private var detailColumn: some View {
        // No GeometryReader here: the enclosing HSplitView already provides this
        // pane's width/height, so reading it again would just force an extra layout
        // pass — the same "no GeometryReader" discipline the transcript pipeline
        // adopted.
        Group {
            if viewModel.githubSelectedWorkItem != nil {
                GitHubIssueDetailView(viewModel: viewModel)
            } else {
                ContentUnavailableView(
                    "Select an Issue",
                    systemImage: "doc.text",
                    description: Text("Pick an issue from the list to read it, browse comments, and reply.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        // `searchableHaystack` is precomputed at snapshot time (lowercased
        // join of title/body/author/repository/number/assignees/labels), so
        // per-keystroke search is now one O(1) substring check per item
        // instead of five fresh `.lowercased()` allocations.
        return items.filter { $0.searchableHaystack.contains(query) }
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
    @Bindable var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            stateSection
            if viewModel.githubIssueStateFilter == .closed {
                closeReasonSection
            }
            if !viewModel.githubAvailableTypes.isEmpty {
                Divider()
                typeSection
            }
            Divider()
            creatorSection
            Divider()
            assigneeSection
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
        viewModel.githubAuthorFilter != nil
            || viewModel.githubAssigneeFilter != nil
            || viewModel.githubTypeFilter != nil
            || !viewModel.githubLabelFilters.isEmpty
            || (viewModel.githubIssueStateFilter == .closed && viewModel.githubCloseReasonFilter != nil)
    }

    private var stateSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("State")
            Picker("State", selection: $viewModel.githubIssueStateFilter) {
                ForEach(GitHubIssueStateFilter.allCases) { state in
                    Text(state.rawValue).tag(state)
                }
            }
            .appSegmentedPicker()
            .labelsHidden()
        }
    }

    private var closeReasonSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Close Reason")
            Picker("Close Reason", selection: closeReasonBinding) {
                Text("Any reason").tag(GitHubIssueCloseReason?.none)
                Divider()
                ForEach(GitHubIssueCloseReason.allCases) { reason in
                    Text(reason.title).tag(GitHubIssueCloseReason?.some(reason))
                }
            }
            .labelsHidden()
        }
    }

    private var closeReasonBinding: Binding<GitHubIssueCloseReason?> {
        Binding(
            get: { viewModel.githubCloseReasonFilter },
            set: { viewModel.githubCloseReasonFilter = $0 }
        )
    }

    private var typeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Type")
            Picker("Type", selection: typeBinding) {
                Text("Any type").tag(String?.none)
                Divider()
                ForEach(viewModel.githubAvailableTypes, id: \.self) { type in
                    Text(type).tag(String?.some(type))
                }
            }
            .labelsHidden()
        }
    }

    private var typeBinding: Binding<String?> {
        Binding(
            get: { viewModel.githubTypeFilter },
            set: { viewModel.githubTypeFilter = $0 }
        )
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

    private var assigneeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("Assignee")
            Picker("Assignee", selection: assigneeBinding) {
                Text("Anyone").tag(String?.none)
                if !viewModel.githubAvailableAssignees.isEmpty {
                    Divider()
                    ForEach(viewModel.githubAvailableAssignees, id: \.self) { assignee in
                        Text(assignee).tag(String?.some(assignee))
                    }
                }
            }
            .labelsHidden()
            .disabled(viewModel.githubAvailableAssignees.isEmpty)
        }
    }

    private var assigneeBinding: Binding<String?> {
        Binding(
            get: { viewModel.githubAssigneeFilter },
            set: { viewModel.githubAssigneeFilter = $0 }
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
                    ForEach(viewModel.githubAvailableLabels) { label in
                        labelToggleRow(label)
                    }
                }
            }
            .frame(maxHeight: 220)
        }
    }

    private func labelToggleRow(_ label: GitHubLabel) -> some View {
        let isOn = viewModel.githubLabelFilters.contains(label.name)
        return Button {
            if isOn {
                viewModel.githubLabelFilters.remove(label.name)
            } else {
                viewModel.githubLabelFilters.insert(label.name)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isOn ? AppTheme.brandAccent : AppTheme.mutedText)
                GitHubLabelTag(label: label)
                Spacer(minLength: 0)
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
