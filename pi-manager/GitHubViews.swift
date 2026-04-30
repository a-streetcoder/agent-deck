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

struct GitHubConnectionCard: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        HStack(spacing: 12) {
            GitHubAvatarView(url: avatarURL, size: 36)
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 10, height: 10)
                        .overlay(Circle().stroke(AppTheme.cardFill, lineWidth: 2))
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(accountName)
                    .font(.headline)
                    .fontWidth(.expanded)
                Text(statusText)
                    .font(.footnote)
                    .foregroundStyle(AppTheme.mutedText)
            }

            Spacer()

            VStack(alignment: .center, spacing: 4) {
                Button {
                    viewModel.refreshEverything()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppTheme.mutedText)
                        .symbolEffect(.rotate.byLayer, isActive: viewModel.githubIsRefreshingEverything)
                }
                .buttonStyle(.plain)
                .help("Refresh GitHub status, project scans, and repo data")
                .disabled(viewModel.githubIsRefreshingEverything)

                if let lastCheckedAt = viewModel.githubLastStatusCheckAt {
                    Text(timeFormatter.string(from: lastCheckedAt))
                        .font(.caption2)
                        .foregroundStyle(AppTheme.mutedText)
                        .monospacedDigit()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AppTheme.cardFill)
                .stroke(AppTheme.cardStroke, lineWidth: 1)
        )
    }

    private var accountName: String {
        viewModel.currentGitHubAccount?.login ?? "GitHub"
    }

    private var statusText: String {
        if viewModel.githubIsRefreshingEverything {
            return "Refreshing…"
        }

        switch viewModel.githubConnectionState {
        case .connected:
            return "Connected"
        case .checking:
            return "Connecting…"
        case .failed:
            return "Error"
        case .available:
            return "Ready"
        case .unavailable:
            return "Unavailable"
        case .disconnected:
            return "Inactive"
        }
    }

    private var timeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }

    private var statusColor: Color {
        switch viewModel.githubConnectionState {
        case .connected:
            return .green
        case .failed:
            return .red
        default:
            return .secondary
        }
    }

    private var avatarURL: URL? {
        guard let account = viewModel.currentGitHubAccount else { return nil }
        return GitHubAvatarResolver.url(login: account.login, host: account.host)
    }
}

private struct GitHubAvatarView: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        AsyncImage(url: url) { image in
            image
                .resizable()
                .scaledToFill()
        } placeholder: {
            Circle()
                .fill(AppTheme.subtleFill)
                .overlay {
                    Image(systemName: "person.crop.circle.fill")
                        .foregroundStyle(AppTheme.mutedText)
                }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

private enum GitHubAvatarResolver {
    static func url(login: String, host: String?) -> URL? {
        let normalizedHost = host?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedHost, !normalizedHost.isEmpty, normalizedHost.caseInsensitiveCompare("github.com") != .orderedSame {
            return URL(string: "https://\(normalizedHost)/\(login).png")
        }
        return URL(string: "https://github.com/\(login).png")
    }
}

private struct GitHubIssueListRow: View {
    let item: GitHubWorkItem
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 8) {
                    AppLabelTag(
                        text: item.state.capitalized,
                        color: item.state.lowercased() == "open" ? .green : .secondary
                    )
                    if let issueType = item.type, !issueType.isEmpty {
                        AppLabelTag(text: issueType, color: issueTypeColor(issueType))
                    }
                    Text("#\(item.number)")
                        .font(.footnote.monospaced())
                        .foregroundStyle(AppTheme.mutedText)
                    Spacer(minLength: 12)
                }

                Text(item.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)

                if !item.labels.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(item.labels.prefix(4), id: \.self) { label in
                                AppLabelTag(text: label, color: .secondary)
                            }
                        }
                    }
                }

                HStack(spacing: 8) {
                    if let author = item.author {
                        GitHubAvatarView(url: GitHubAvatarResolver.url(login: author, host: item.url.host()), size: 18)
                        Text(author)
                    }
                    Spacer()
                    Text(RelativeDateTimeFormatter().localizedString(for: item.updatedAt, relativeTo: Date()))
                }
                .font(.footnote)
                .foregroundStyle(AppTheme.mutedText)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isSelected ? Color.accentColor.opacity(0.35) : AppTheme.cardStroke, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Link("Open in Browser", destination: item.url)
        }
    }
}

private struct GitHubIssueDetailCard: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        AppCard(title: detailTitle) {
            if viewModel.githubIsLoadingIssueDetail {
                ProgressView("Loading details…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else if let detail = viewModel.githubIssueDetail {
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .center, spacing: 10) {
                            AppLabelTag(text: detail.state.capitalized, color: detail.state.lowercased() == "open" ? .green : .secondary)
                            if let issueType = detail.type, !issueType.isEmpty {
                                AppLabelTag(text: issueType, color: issueTypeColor(issueType))
                            }
                            Text("\(detail.item.repository) #\(detail.item.number)")
                                .font(.footnote.monospaced())
                                .foregroundStyle(AppTheme.mutedText)
                            Spacer()
                            Link("Open in Browser", destination: detail.item.url)
                        }

                        if !detail.labels.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(detail.labels, id: \.self) { label in
                                        AppLabelTag(text: label, color: .secondary)
                                    }
                                }
                            }
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 10) {
                                if let author = detail.author {
                                    GitHubAvatarView(url: GitHubAvatarResolver.url(login: author, host: detail.item.url.host()), size: 28)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(author)
                                            .fontWeight(.semibold)
                                        Text("Author")
                                            .font(.caption)
                                            .foregroundStyle(AppTheme.mutedText)
                                    }
                                } else {
                                    Text("Author unavailable")
                                        .foregroundStyle(AppTheme.mutedText)
                                }
                                Spacer()
                            }

                            AppKeyValueList(rows: [
                                ("Type", detail.type ?? "—"),
                                ("Assignees", detail.assignees.isEmpty ? "—" : detail.assignees.joined(separator: ", ")),
                                ("Created", relativeDate(detail.createdAt)),
                                ("Updated", relativeDate(detail.updatedAt)),
                                ("Closed", detail.closedAt.map(relativeDate) ?? "—")
                            ])
                        }

                        if detail.parent != nil || !detail.subIssues.isEmpty || !detail.blockedBy.isEmpty || !detail.blocking.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Relationships")
                                    .font(.headline)
                                    .fontWidth(.expanded)

                                if let parent = detail.parent {
                                    GitHubRelationshipGroup(title: "Parent", items: [parent], accent: .purple) { reference in
                                        viewModel.selectIssueReference(reference)
                                    }
                                }
                                if !detail.subIssues.isEmpty {
                                    GitHubRelationshipGroup(title: "Sub-issues", items: detail.subIssues, accent: .purple) { reference in
                                        viewModel.selectIssueReference(reference)
                                    }
                                }
                                if !detail.blockedBy.isEmpty {
                                    GitHubRelationshipGroup(title: "Blocked by", items: detail.blockedBy, accent: .orange) { reference in
                                        viewModel.selectIssueReference(reference)
                                    }
                                }
                                if !detail.blocking.isEmpty {
                                    GitHubRelationshipGroup(title: "Blocking", items: detail.blocking, accent: .blue) { reference in
                                        viewModel.selectIssueReference(reference)
                                    }
                                }
                            }
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Description")
                                .font(.headline)
                                .fontWidth(.expanded)
                            if detail.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text("No description provided.")
                                    .foregroundStyle(AppTheme.mutedText)
                            } else {
                                MarkdownDocumentView(source: detail.body, minimumHeight: 80)
                            }
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            Text("Comments")
                                .font(.headline)
                                .fontWidth(.expanded)

                            if detail.comments.isEmpty {
                                Text("No comments yet.")
                                    .foregroundStyle(AppTheme.mutedText)
                            } else {
                                ForEach(detail.comments) { comment in
                                    AppRowCard {
                                        VStack(alignment: .leading, spacing: 10) {
                                            HStack(alignment: .center, spacing: 10) {
                                                GitHubAvatarView(url: GitHubAvatarResolver.url(login: comment.author, host: detail.item.url.host()), size: 24)
                                                VStack(alignment: .leading, spacing: 2) {
                                                    Text(comment.author)
                                                        .fontWeight(.semibold)
                                                    Text(relativeDate(comment.updatedAt))
                                                        .font(.footnote)
                                                        .foregroundStyle(AppTheme.mutedText)
                                                }
                                                Spacer()
                                                Link(destination: comment.url) {
                                                    Image(systemName: "arrow.up.forward.square")
                                                }
                                                .buttonStyle(.plain)
                                            }

                                            MarkdownTextView(source: comment.cleanedBody)
                                        }
                                    }
                                }
                            }
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            Text("Add Comment")
                                .font(.headline)
                                .fontWidth(.expanded)
                            TextEditor(text: $viewModel.githubCommentDraft)
                                .frame(minHeight: 110)
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(AppTheme.cardStroke, lineWidth: 1))

                            HStack {
                                Spacer()
                                Button(viewModel.githubIsSubmittingComment ? "Posting…" : "Post Comment") {
                                    viewModel.submitComment()
                                }
                                .disabled(viewModel.githubIsSubmittingComment)
                            }
                        }
                    }
                }
            } else {
                Text("Select an issue from the list to read it, browse comments, and reply.")
                    .foregroundStyle(AppTheme.mutedText)
            }
        }
    }

    private var detailTitle: String {
        viewModel.githubIssueDetail?.item.title ?? viewModel.githubSelectedWorkItem?.title ?? "Issue Details"
    }

    private func relativeDate(_ date: Date) -> String {
        RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
    }
}

struct GitHubIssuesWorkspace: View {
    @ObservedObject var viewModel: AppViewModel
    let board: GitHubBoardSnapshot?
    let isLoading: Bool
    let showStateFilter: Bool
    let refreshAction: () -> Void

    var body: some View {
        if let project = viewModel.selectedGitHubProject, let remote = project.gitHubRemote {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(project.repositoryDisplayName)
                            .font(.headline)
                            .fontWidth(.expanded)
                        Text(remote.nameWithOwner)
                            .font(.footnote.monospaced())
                            .foregroundStyle(AppTheme.mutedText)
                    }

                    Spacer()

                    if showStateFilter {
                        Picker("State", selection: $viewModel.githubIssueStateFilter) {
                            ForEach(GitHubIssueStateFilter.allCases) { state in
                                Text(state.rawValue).tag(state)
                            }
                        }
                        .frame(maxWidth: 180)
                    }

                    Button("Open Repository") {
                        open(remote)
                    }

                    Button("Refresh") {
                        refreshAction()
                    }
                    .disabled(!viewModel.githubConnectionState.isConnected || isLoading)
                }

                if let error = viewModel.githubLastError {
                    Text(error)
                        .foregroundStyle(.red)
                }

                if isLoading {
                    ProgressView("Loading issues…")
                } else if !viewModel.githubConnectionState.isConnected {
                    Text("Connecting to your GitHub CLI session…")
                        .foregroundStyle(AppTheme.mutedText)
                } else if let board {
                    if board.shownCount < board.totalCount {
                        Text("Showing the first \(board.shownCount) of \(board.totalCount) matching issues.")
                            .foregroundStyle(.orange)
                    }

                    if board.incompleteResults {
                        Text("GitHub reported incomplete search results. Narrow the scope if items look missing.")
                            .foregroundStyle(.orange)
                    }

                    if board.allItems.isEmpty {
                        Text(showStateFilter ? "No matching issues for this repository." : "No open issues for this repository.")
                            .foregroundStyle(AppTheme.mutedText)
                    } else {
                        HSplitView {
                            AppSidebarPane(
                                title: showStateFilter ? "Issues" : "Open Issues",
                                subtitle: "\(board.allItems.count) shown"
                            ) {
                                ScrollView(showsIndicators: false) {
                                    LazyVStack(alignment: .leading, spacing: 12) {
                                        ForEach(board.allItems) { item in
                                            GitHubIssueListRow(
                                                item: item,
                                                isSelected: viewModel.githubSelectedWorkItem == item,
                                                onSelect: { viewModel.selectWorkItem(item) }
                                            )
                                        }
                                    }
                                    .padding(16)
                                }
                            }
                            .frame(minWidth: 320, idealWidth: 360, maxWidth: 420)

                            GitHubIssueDetailCard(viewModel: viewModel)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                .padding(.leading, 8)
                        }
                        .frame(minHeight: 720)
                    }
                } else {
                    Text("Loading issues for this repository…")
                        .foregroundStyle(AppTheme.mutedText)
                }
            }
        } else if viewModel.selectedProjectPath != nil {
            Text("Select a project with a GitHub remote to see its issues here.")
                .foregroundStyle(AppTheme.mutedText)
        } else {
            Text("Choose a project from the toolbar to browse its issues.")
                .foregroundStyle(AppTheme.mutedText)
        }
    }

    private func open(_ remote: GitHubRemote) {
        guard let url = URL(string: "https://\(remote.host)/\(remote.nameWithOwner)") else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct GitHubProjectPlaceholder: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        AppCard(title: "Issues", trailing: {
            if let board = viewModel.githubProjectBoard {
                Text("\(board.totalCount)")
                    .foregroundStyle(AppTheme.mutedText)
            }
        }) {
            GitHubIssuesWorkspace(
                viewModel: viewModel,
                board: viewModel.githubProjectBoard,
                isLoading: viewModel.githubIsLoadingProjectBoard,
                showStateFilter: true,
                refreshAction: { viewModel.refreshProjectBoard(force: true) }
            )
        }
    }
}

private struct GitHubRelationshipGroup: View {
    let title: String
    let items: [GitHubIssueReference]
    let accent: Color
    let onSelect: (GitHubIssueReference) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppTheme.mutedText)

            ForEach(items) { item in
                AppRowCard {
                    HStack(alignment: .top, spacing: 10) {
                        Circle()
                            .fill(accent)
                            .frame(width: 8, height: 8)
                            .padding(.top, 6)

                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                AppLabelTag(
                                    text: item.state.capitalized,
                                    color: item.state.lowercased() == "open" ? .green : .secondary
                                )
                                if let type = item.type, !type.isEmpty {
                                    AppLabelTag(text: type, color: issueTypeColor(type))
                                }
                                Text("\(item.repository) #\(item.number)")
                                    .font(.footnote.monospaced())
                                    .foregroundStyle(AppTheme.mutedText)
                            }

                            Button {
                                onSelect(item)
                            } label: {
                                Text(item.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .multilineTextAlignment(.leading)
                            }
                            .buttonStyle(.plain)

                            HStack(spacing: 12) {
                                Button {
                                    onSelect(item)
                                } label: {
                                    Label("Open in App", systemImage: "sidebar.right")
                                        .font(.footnote)
                                }
                                .buttonStyle(.plain)

                                Link(destination: item.url) {
                                    Label("Open in GitHub", systemImage: "arrow.up.forward.square")
                                        .font(.footnote)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        Spacer()
                    }
                }
            }
        }
    }
}

private func issueTypeColor(_ issueType: String) -> Color {
    switch issueType.lowercased() {
    case "bug":
        return .red
    case "feature", "enhancement":
        return .blue
    case "task", "chore":
        return .purple
    case "epic", "initiative":
        return .orange
    default:
        return .secondary
    }
}

private extension GitHubIssueComment {
    var cleanedBody: String {
        var result = body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let trailingPatterns = [
            #"\n{2,}On .+ wrote:\n[\s\S]*$"#,
            #"\n{2,}> .*$"#,
            #"\n{2,}Reply to this email directly[\s\S]*$"#,
            #"\n{2,}You are receiving this because[\s\S]*$"#
        ]

        for pattern in trailingPatterns {
            if let range = result.range(of: pattern, options: .regularExpression) {
                result = String(result[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return result.isEmpty ? body : result
    }
}

private struct GitHubRepoChangesPlaceholder: View {
    @ObservedObject var viewModel: AppViewModel

    private func hasSelectedStageableChanges(in snapshot: RepositoryChangesSnapshot) -> Bool {
        let stageable = Set(snapshot.unstaged.map(\.path) + snapshot.untracked.map(\.path) + snapshot.conflicted.map(\.path))
        return !viewModel.githubSelectedChangePaths.intersection(stageable).isEmpty
    }

    private func hasSelectedStagedChanges(in snapshot: RepositoryChangesSnapshot) -> Bool {
        let staged = Set(snapshot.staged.map(\.path) + snapshot.conflicted.map(\.path))
        return !viewModel.githubSelectedChangePaths.intersection(staged).isEmpty
    }

    var body: some View {
        AppCard(title: "Repo Changes", trailing: {
            if let snapshot = viewModel.githubRepositoryChanges {
                Text("\(snapshot.totalChangeCount)")
                    .foregroundStyle(AppTheme.mutedText)
            }
        }) {
            if let project = viewModel.selectedDiscoveredProject {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(project.repositoryDisplayName)
                                .font(.headline)
                            Text(project.path)
                                .font(.footnote.monospaced())
                                .foregroundStyle(AppTheme.mutedText)
                        }

                        Spacer()

                        if project.isGitRepository {
                            Button("Select All") {
                                viewModel.selectAllVisibleChanges()
                            }
                            .disabled(viewModel.githubRepositoryChanges == nil)

                            Button("Clear Selection") {
                                viewModel.clearSelectedChanges()
                            }
                            .disabled(viewModel.githubSelectedChangePaths.isEmpty)

                            Button("Refresh") {
                                viewModel.refreshRepositoryChanges()
                            }
                        }
                    }

                    if let error = viewModel.githubLastError {
                        Text(error)
                            .foregroundStyle(.red)
                    }

                    if !project.isGitRepository {
                        Text("The selected project is not a git repository, so local git changes are unavailable here.")
                            .foregroundStyle(AppTheme.mutedText)
                    } else if viewModel.githubIsLoadingRepositoryChanges {
                        ProgressView("Loading repository changes…")
                    } else if let snapshot = viewModel.githubRepositoryChanges {
                        AppKeyValueList(rows: [
                            ("Branch", snapshot.branchName),
                            ("Upstream", snapshot.upstreamBranch ?? "—"),
                            ("Ahead", "\(snapshot.aheadCount)"),
                            ("Behind", "\(snapshot.behindCount)")
                        ])

                        AppCard(title: "Commit & Push") {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Selected files: \(viewModel.githubSelectedChangePaths.count)")
                                    .foregroundStyle(AppTheme.mutedText)

                                HStack {
                                    Button("Stage Selected") {
                                        viewModel.stageSelectedChanges()
                                    }
                                    .disabled(!hasSelectedStageableChanges(in: snapshot))

                                    Button("Unstage Selected") {
                                        viewModel.unstageSelectedChanges()
                                    }
                                    .disabled(!hasSelectedStagedChanges(in: snapshot))

                                    Button("Stage All") {
                                        viewModel.stageAllChanges()
                                    }
                                    .disabled(!(snapshot.canStageAll))

                                    Button("Unstage All") {
                                        viewModel.unstageAllChanges()
                                    }
                                    .disabled(!(snapshot.canUnstageAll))
                                }

                                TextEditor(text: $viewModel.githubCommitMessage)
                                    .frame(minHeight: 70)
                                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(AppTheme.cardStroke, lineWidth: 1))

                                HStack {
                                    Button("Commit") {
                                        viewModel.commitChanges()
                                    }
                                    .disabled(viewModel.githubIsCommitting || !(snapshot.canCommit) || viewModel.githubCommitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                                    Button("Push") {
                                        viewModel.pushCurrentBranch()
                                    }
                                    .disabled(viewModel.githubIsPushing || !snapshot.canPush)
                                }
                            }
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            GitChangeSection(title: "Conflicted", changes: snapshot.conflicted, viewModel: viewModel)
                            GitChangeSection(title: "Staged", changes: snapshot.staged, viewModel: viewModel)
                            GitChangeSection(title: "Unstaged", changes: snapshot.unstaged, viewModel: viewModel)
                            GitChangeSection(title: "Untracked", changes: snapshot.untracked, viewModel: viewModel)
                        }
                    } else {
                        Text("Press Refresh to load local git status for this repository.")
                            .foregroundStyle(AppTheme.mutedText)
                    }
                }
            } else {
                Text("Choose a project to inspect local repository changes.")
                    .foregroundStyle(AppTheme.mutedText)
            }
        }
    }
}

private struct GitChangeSection: View {
    let title: String
    let changes: [RepositoryFileChange]
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        if !changes.isEmpty {
            AppCard(title: title, trailing: {
                Text("\(changes.count)")
                    .foregroundStyle(AppTheme.mutedText)
            }) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(changes) { change in
                        Button {
                            viewModel.toggleChangeSelection(change.path)
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: viewModel.githubSelectedChangePaths.contains(change.path) ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(viewModel.githubSelectedChangePaths.contains(change.path) ? Color.accentColor : AppTheme.mutedText)
                                Text(change.statusSummary)
                                    .font(.footnote.monospaced())
                                    .foregroundStyle(AppTheme.mutedText)
                                Text(change.path)
                                    .foregroundStyle(.primary)
                                    .multilineTextAlignment(.leading)
                                Spacer()
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

private struct GitHubConnectionDetails: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        AppCard(title: "GitHub CLI Session") {
            VStack(alignment: .leading, spacing: 12) {
                Text("pi-manager currently reuses the existing `gh` authentication session.")

                switch viewModel.githubConnectionState {
                case let .available(account), let .connected(account):
                    AppKeyValueList(rows: [
                        ("Login", account.login),
                        ("Host", account.host),
                        ("Git Protocol", account.gitProtocol ?? "—"),
                        ("Token Source", account.tokenSource ?? "—"),
                        ("Scopes", account.scopes.isEmpty ? "—" : account.scopes.joined(separator: ", "))
                    ])
                case .unavailable:
                    Text("Install GitHub CLI and run `gh auth login`, then reconnect here.")
                        .foregroundStyle(AppTheme.mutedText)
                default:
                    Text("After connecting, this screen will show the active GitHub CLI account and scopes.")
                        .foregroundStyle(AppTheme.mutedText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
