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
                    HStack(spacing: 6) {
                        ForEach(item.labels.prefix(4), id: \.self) { label in
                            AppLabelTag(text: label, color: .secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .clipped()
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

struct GitHubIssueDetailView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        if viewModel.githubIsLoadingIssueDetail && viewModel.githubIssueDetail == nil {
            loadingState
        } else if let detail = viewModel.githubIssueDetail {
            detailContent(detail)
        } else {
            ContentUnavailableView(
                "Issue Details Unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text("Could not load this issue. Try refreshing.")
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
                        Text("Loading issue")
                            .font(.headline)
                        Text("Fetching the description and comments.")
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

    private func detailContent(_ detail: GitHubIssueDetail) -> some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 20) {
                titleRow(detail)
                metadataRow(detail)

                if !detail.labels.isEmpty {
                    labelsRow(detail.labels)
                }

                if detail.parent != nil || !detail.subIssues.isEmpty || !detail.blockedBy.isEmpty || !detail.blocking.isEmpty {
                    relationshipsSection(detail)
                }

                descriptionSection(detail)
                commentsSection(detail)
                addCommentSection(detail)
            }
            .padding(AppTheme.pagePadding)
        }
    }

    // MARK: - Sections

    private func titleRow(_ detail: GitHubIssueDetail) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(detail.item.title)
                    .font(.title2.weight(.bold))
                    .fontWidth(.expanded)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    AppLabelTag(text: detail.state.capitalized, color: detail.state.lowercased() == "open" ? .green : .secondary)
                    if let issueType = detail.type, !issueType.isEmpty {
                        AppLabelTag(text: issueType, color: issueTypeColor(issueType))
                    }
                    Text("\(detail.item.repository) #\(detail.item.number)")
                        .font(.footnote.monospaced())
                        .foregroundStyle(AppTheme.mutedText)
                }
            }

            Spacer(minLength: 12)

            actionButtons(detail)
        }
    }

    private func actionButtons(_ detail: GitHubIssueDetail) -> some View {
        HStack(spacing: 8) {
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
            .help(viewModel.selectedDiscoveredProject == nil ? "Select a project first." : "Open a Pi Agent session for this issue.")

            if detail.state.lowercased() == "open" {
                Button {
                    viewModel.closeSelectedIssue()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 16, weight: .semibold))
                        Text(viewModel.githubIsClosingIssue ? "Closing…" : "Close")
                            .fontWeight(.semibold)
                    }
                    .foregroundStyle(AppTheme.mutedText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .appGlassCapsule()
                }
                .buttonStyle(.plain)
                .disabled(viewModel.githubIsClosingIssue)
                .opacity(viewModel.githubIsClosingIssue ? 0.6 : 1)
                .help("Close this issue on GitHub.")
            }
        }
    }

    private func metadataRow(_ detail: GitHubIssueDetail) -> some View {
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
    }

    private func labelsRow(_ labels: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(labels, id: \.self) { label in
                    AppLabelTag(text: label, color: .secondary)
                }
            }
        }
    }

    private func relationshipsSection(_ detail: GitHubIssueDetail) -> some View {
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

    private func descriptionSection(_ detail: GitHubIssueDetail) -> some View {
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
    }

    private func commentsSection(_ detail: GitHubIssueDetail) -> some View {
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
    }

    private func addCommentSection(_ detail: GitHubIssueDetail) -> some View {
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

    private func relativeDate(_ date: Date) -> String {
        RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
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
