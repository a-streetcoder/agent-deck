import AppKit
import SwiftUI

struct GitHubIssueListRow: View {
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
                    Spacer(minLength: 12)
                    Text("#\(item.number)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(AppTheme.mutedText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule(style: .continuous).fill(AppTheme.contentSubtleFill))
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
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? AppTheme.selectionFill : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isSelected ? AppTheme.selectionStroke : AppTheme.contentStroke, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .contextMenu {
            Link("Open in Browser", destination: item.url)
        }
    }
}

private struct GitHubIssueDetailCard: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var confirmsCloseIssue = false

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
                            Button {
                                viewModel.startPiAgentForIssue(detail)
                            } label: {
                                HStack(spacing: 8) {
                                    Image("pi")
                                        .resizable()
                                        .renderingMode(.template)
                                        .scaledToFit()
                                        .frame(width: 16, height: 16)
                                    Text("Open")
                                        .fontWeight(.semibold)
                                }
                                .foregroundStyle(AppTheme.accentForeground.gradient)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(AppTheme.brandAccent.gradient)
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(viewModel.selectedDiscoveredProject == nil)
                            .opacity(viewModel.selectedDiscoveredProject == nil ? 0.45 : 1)
                            if detail.state.lowercased() == "open" {
                                Button {
                                    confirmsCloseIssue = true
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "checkmark.circle")
                                            .font(.system(size: 16, weight: .semibold))
                                        Text(viewModel.githubIsClosingIssue ? "Closing…" : "Close Issue")
                                            .fontWeight(.semibold)
                                    }
                                    .foregroundStyle(AppTheme.mutedText)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(Capsule(style: .continuous).fill(AppTheme.contentSubtleFill).stroke(AppTheme.contentStroke, lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                                .disabled(viewModel.githubIsClosingIssue)
                                .opacity(viewModel.githubIsClosingIssue ? 0.6 : 1)
                            }
                        }
                        .confirmationDialog(
                            "Close issue #\(detail.item.number)?",
                            isPresented: $confirmsCloseIssue,
                            titleVisibility: .visible
                        ) {
                            Button("Close Issue", role: .destructive) {
                                viewModel.closeSelectedIssue()
                            }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("Only close this after reviewing and finishing the agent's changes.")
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
                                    GitHubRelationshipGroup(title: "Parent", items: [parent], accent: AppTheme.assistantAccent) { reference in
                                        viewModel.selectIssueReference(reference)
                                    }
                                }
                                if !detail.subIssues.isEmpty {
                                    GitHubRelationshipGroup(title: "Sub-issues", items: detail.subIssues, accent: AppTheme.assistantAccent) { reference in
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
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(AppTheme.contentStroke, lineWidth: 1))

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

struct GitHubProjectPlaceholder: View {
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

