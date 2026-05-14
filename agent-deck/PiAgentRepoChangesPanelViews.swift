import AppKit
import SwiftUI

private enum PiAgentGitHubPanelSection: String, CaseIterable, Identifiable {
    case issues
    case changes

    var id: String { rawValue }
    var title: String {
        switch self {
        case .changes: return "Changes"
        case .issues: return "Issues"
        }
    }
}

struct PiAgentRepoChangesPanel: View {
    @ObservedObject var viewModel: AppViewModel
    @Binding var isPresented: Bool
    @State private var selectedSection: PiAgentGitHubPanelSection = .issues
    @State private var presentedIssue: GitHubWorkItem?
    @State private var isCommitConfirmationPresented = false
    @State private var isCommitAndPushConfirmationPresented = false

    private var snapshot: RepositoryChangesSnapshot? { viewModel.githubRepositoryChanges }

    private var items: [PiAgentGitChangeListItem] {
        guard let snapshot else { return [] }
        return PiAgentGitChangeListItem.items(from: snapshot)
    }

    var body: some View {
        AppSidebarPane(title: "GitHub", subtitle: panelSubtitle) {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)

                Divider()

                sectionControls
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)

                panelContent
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .task { await preparePanel() }
        .onChange(of: selectedSection) { _, _ in
            Task { await preparePanel() }
        }
    }

    @ViewBuilder
    private var panelContent: some View {
        if let error = viewModel.githubLastError {
            VStack(alignment: .leading, spacing: 12) {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                selectedSection == .changes ? AnyView(repositoryState) : AnyView(issuesState)
            }
        } else if selectedSection == .changes {
            repositoryState
        } else {
            issuesState
        }
    }

    private var sectionControls: some View {
        HStack(alignment: .center, spacing: 10) {
            Picker("GitHub section", selection: $selectedSection) {
                ForEach(PiAgentGitHubPanelSection.allCases) { section in
                    Text(section.title).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 150)

            Spacer(minLength: 12)

            if selectedSection == .issues {
                issuesControls
            }
        }
    }

    @ViewBuilder
    private var issuesControls: some View {
        if let board = viewModel.githubProjectBoard, board.shownCount < board.totalCount {
            Text("\(board.shownCount)/\(board.totalCount)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
        }
        Picker("State", selection: $viewModel.githubIssueStateFilter) {
            ForEach(GitHubIssueStateFilter.allCases) { state in
                Text(state.rawValue).tag(state)
            }
        }
        .labelsHidden()
        .frame(width: 110)
        .onChange(of: viewModel.githubIssueStateFilter) { _, _ in
            viewModel.refreshProjectBoard(force: true)
        }
    }

    @ViewBuilder
    private var repositoryState: some View {
        if let snapshot {
            if snapshot.totalChangeCount == 0 {
                cleanRepositoryState(snapshot)
            } else {
                changesContent(snapshot)
            }
        } else if viewModel.githubIsLoadingRepositoryChanges {
            ProgressView("Loading repository changes…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("No repository data", systemImage: "arrow.triangle.branch", description: Text("Refresh to inspect changes for this Pi Agent session."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var issuesState: some View {
        if viewModel.githubIsLoadingProjectBoard {
            ProgressView("Loading issues…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !viewModel.githubConnectionState.isConnected {
            ContentUnavailableView("Connect GitHub", systemImage: "person.crop.circle.badge.questionmark", description: Text("Connect your GitHub CLI session to browse repository issues."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.selectedGitHubProject?.gitHubRemote == nil {
            ContentUnavailableView("No GitHub repository", systemImage: "tray", description: Text("The selected Pi Agent session is not linked to a GitHub remote."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let board = viewModel.githubProjectBoard {
            issuesContent(board)
        } else {
            ContentUnavailableView("No issues loaded", systemImage: "circle.dashed", description: Text("Refresh to load issues for this repository."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image("github")
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(AppTheme.mutedText)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(repositoryDisplayName)
                    .font(.title3.weight(.bold))
                    .fontWidth(.expanded)
                    .lineLimit(1)
                if let branchName = snapshot?.branchName {
                    Label(branchName, systemImage: "arrow.trianglehead.branch")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.mutedText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                if viewModel.githubIsLoadingRepositoryChanges, snapshot != nil {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 28, height: 28)
                        .help("Refreshing changes")
                }

                Button {
                    refreshSelectedSection(force: true)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .help(selectedSection == .changes ? "Refresh changes" : "Refresh issues")
                .accessibilityLabel(selectedSection == .changes ? "Refresh changes" : "Refresh issues")

                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .help("Close GitHub panel")
                .accessibilityLabel("Close GitHub panel")
            }
        }
    }

    private var repositoryDisplayName: String {
        viewModel.piAgentSessionStore.selectedSession?.projectName ?? viewModel.selectedDiscoveredProject?.name ?? "Pi Agent repository"
    }

    private var panelSubtitle: String? {
        switch selectedSection {
        case .changes:
            return snapshot.map { "\($0.totalChangeCount) changes" }
        case .issues:
            if let board = viewModel.githubProjectBoard {
                return "\(board.allItems.count) issues"
            }
            return "Issues"
        }
    }

    private func preparePanel() async {
        await Task.yield()
        viewModel.prepareRepoChangesForSelectedPiAgentSession()
        if selectedSection == .issues {
            await viewModel.prepareGitHubScreen()
            viewModel.refreshProjectBoard(force: false)
        }
    }

    private func refreshSelectedSection(force: Bool) {
        switch selectedSection {
        case .changes:
            viewModel.prepareRepoChangesForSelectedPiAgentSession(force: force)
        case .issues:
            Task {
                await viewModel.prepareGitHubScreen()
                await MainActor.run {
                    viewModel.refreshProjectBoard(force: force)
                }
            }
        }
    }

    private func cleanRepositoryState(_ snapshot: RepositoryChangesSnapshot) -> some View {
        VStack(spacing: 16) {
            Image(systemName: snapshot.canPush ? "arrow.up.circle" : "checkmark.circle")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(snapshot.canPush ? AppTheme.brandAccent : AppTheme.mutedText)
            Text(snapshot.canPush ? "Ready to push" : "No local changes")
                .font(.title2.weight(.bold))
            Text(snapshot.canPush ? "Your branch is ahead of \(snapshot.upstreamBranch ?? "the upstream branch")." : "The selected Pi Agent repository is clean.")
                .font(.callout)
                .foregroundStyle(AppTheme.mutedText)
                .multilineTextAlignment(.center)
            if snapshot.canPush {
                Button(viewModel.githubIsPushing ? "Pushing…" : "Push \(snapshot.aheadCount) commit\(snapshot.aheadCount == 1 ? "" : "s")") {
                    viewModel.pushCurrentBranch()
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.githubIsPushing)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func changesContent(_ snapshot: RepositoryChangesSnapshot) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                changesListControls(snapshot)

                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(items) { item in
                        PiAgentGitChangeRow(item: item)
                    }
                }

                Divider()
                    .padding(.top, 8)

                piAgentGitActionsBox
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func changesListControls(_ snapshot: RepositoryChangesSnapshot) -> some View {
        HStack(spacing: 8) {
            Text("\(snapshot.totalChangeCount) changed file\(snapshot.totalChangeCount == 1 ? "" : "s")")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.mutedText)
            Spacer(minLength: 8)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AppTheme.contentSubtleFill.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(AppTheme.contentStroke, lineWidth: 1))
    }

    private func issuesContent(_ board: GitHubBoardSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if board.allItems.isEmpty {
                ContentUnavailableView("No matching issues", systemImage: "checkmark.circle", description: Text("There are no issues matching the current filter."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(board.allItems) { item in
                            GitHubIssueListRow(
                                item: item,
                                isSelected: viewModel.githubSelectedWorkItem == item,
                                onSelect: {
                                    viewModel.selectWorkItem(item)
                                    presentedIssue = item
                                }
                            )
                        }
                    }
                    .padding(.bottom, 8)
                }

            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: $presentedIssue) { issue in
            PiAgentGitHubIssueSheet(
                viewModel: viewModel,
                issue: issue,
                onOpenInPi: { detail in
                    viewModel.startPiAgentForIssue(detail)
                    presentedIssue = nil
                    isPresented = false
                }
            )
        }
    }

    private func branchSummary(_ snapshot: RepositoryChangesSnapshot) -> some View {
        HStack(spacing: 7) {
            gitTag(snapshot.branchName, systemImage: "arrow.trianglehead.branch", color: .blue)
            if let upstream = snapshot.upstreamBranch {
                gitTag(upstream, systemImage: "arrow.up.right", color: .gray)
            }
            if snapshot.aheadCount > 0 {
                gitTag("\(snapshot.aheadCount)", systemImage: "arrow.up", color: .green)
            }
            if snapshot.behindCount > 0 {
                gitTag("\(snapshot.behindCount)", systemImage: "arrow.down", color: .orange)
            }
            Spacer()
        }
    }

    private func gitTag(_ text: String, systemImage: String, color: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .fontWidth(.expanded)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .foregroundStyle(color)
    }

    private var piAgentGitActionsBox: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pi Agent Git Actions")
                .font(.headline)
            Text("Uses the same commands as the Pi Agent toolbar. Commit actions stage all changes and generate the title and description automatically.")
                .font(.footnote)
                .foregroundStyle(AppTheme.mutedText)

            VStack(spacing: 8) {
                gitActionButton(
                    title: "Commit",
                    subtitle: "Stage all changes and create an AI-generated commit.",
                    systemImage: "checkmark.seal",
                    isRunning: viewModel.piAgentGitAutomationAction == .commit,
                    isDisabled: !viewModel.canCommitSelectedPiAgentSession,
                    action: commitTapped
                )
                gitActionButton(
                    title: "Push",
                    subtitle: "Push committed changes on the current branch.",
                    systemImage: "arrow.up.circle",
                    isRunning: viewModel.piAgentGitAutomationAction == .push,
                    isDisabled: !viewModel.canPushSelectedPiAgentSession,
                    action: { viewModel.pushSelectedPiAgentSession() }
                )
                gitActionButton(
                    title: "Commit & Push",
                    subtitle: "Stage all changes, commit, then push.",
                    systemImage: "shippingbox.and.arrow.backward",
                    isRunning: viewModel.piAgentGitAutomationAction == .commitAndPush,
                    isDisabled: !viewModel.canCommitAndPushSelectedPiAgentSession,
                    action: commitAndPushTapped
                )
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(AppTheme.contentSubtleFill.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(AppTheme.contentStroke, lineWidth: 1))
        .alert("Commit all changes?", isPresented: $isCommitConfirmationPresented) {
            Button("Commit All Changes") { viewModel.commitSelectedPiAgentSession() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(commitAlertMessage(pushAfterCommit: false))
        }
        .alert("Commit and push all changes?", isPresented: $isCommitAndPushConfirmationPresented) {
            Button("Commit & Push All Changes") { viewModel.commitAndPushSelectedPiAgentSession() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(commitAlertMessage(pushAfterCommit: true))
        }
    }

    private func gitActionButton(title: String, subtitle: String, systemImage: String, isRunning: Bool, isDisabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    Image(systemName: systemImage)
                        .opacity(isRunning ? 0 : 1)
                    if isRunning {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .symbolEffect(.rotate, options: .repeating)
                    }
                }
                .font(.title3.weight(.semibold))
                .frame(width: 28)
                .foregroundStyle(AppTheme.brandAccent)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(AppTheme.contentFill))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(AppTheme.contentStroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
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

    private func commitAlertMessage(pushAfterCommit: Bool) -> String {
        let action = pushAfterCommit
            ? "This stages all changes, generates a commit title and description, commits, and pushes the current branch."
            : "This stages all changes, generates a commit title and description, and commits on the current branch."
        guard let session = viewModel.piAgentSessionStore.selectedSession else { return action }
        let repoName = URL(fileURLWithPath: session.projectPath, isDirectory: true).lastPathComponent
        return "Repository: \(repoName)\n\n\(action)"
    }
}

private struct PiAgentGitHubIssueSheet: View {
    @ObservedObject var viewModel: AppViewModel
    let issue: GitHubWorkItem
    let onOpenInPi: (GitHubIssueDetail) -> Void
    @Environment(\.dismiss) private var dismiss

    private var detail: GitHubIssueDetail? {
        guard let detail = viewModel.githubIssueDetail,
              detail.item.repository == issue.repository,
              detail.item.number == issue.number else { return nil }
        return detail
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(20)

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            footer
                .padding(20)
        }
        .frame(minWidth: 680, idealWidth: 760, maxWidth: 900, minHeight: 620, idealHeight: 740, maxHeight: 860)
        .task(id: issue.id) {
            if viewModel.githubSelectedWorkItem != issue {
                viewModel.selectWorkItem(issue)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .center, spacing: 10) {
                        Text("#\(issue.number)")
                            .font(.title2.weight(.bold).monospacedDigit())
                            .fontWidth(.expanded)
                            .foregroundStyle(AppTheme.mutedText)
                        Text(issue.title)
                            .font(.title2.weight(.bold))
                            .fontWidth(.expanded)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 16)

                HStack(spacing: 8) {
                    Button {
                        NSWorkspace.shared.open(issue.url)
                    } label: {
                        Label("Open issue in browser", systemImage: "globe")
                            .labelStyle(.iconOnly)
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .buttonStyle(.glass)
                    .controlSize(.regular)
                    .clipShape(Circle())
                    .help("Open issue in browser")
                    .accessibilityLabel("Open issue in browser")

                    Button {
                        dismiss()
                    } label: {
                        Label("Close issue details", systemImage: "xmark")
                            .labelStyle(.iconOnly)
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .buttonStyle(.glass)
                    .controlSize(.regular)
                    .clipShape(Circle())
                    .help("Close issue details")
                    .accessibilityLabel("Close issue details")
                }
            }

            if !activeLabels.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(activeLabels, id: \.self) { label in
                            AppLabelTag(text: label, color: .secondary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.githubIsLoadingIssueDetail && detail == nil {
            ProgressView("Loading issue details…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let detail {
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 18) {
                    metadata(detail)
                    description(detail)
                    comments(detail)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.orange)
                Text("Unable to load issue details")
                    .font(.headline)
                if let error = viewModel.githubLastError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(AppTheme.mutedText)
                        .multilineTextAlignment(.center)
                }
                Button("Retry") {
                    viewModel.selectWorkItem(issue)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()

            Button("Close") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button {
                guard let detail else { return }
                onOpenInPi(detail)
                dismiss()
            } label: {
                HStack(spacing: 8) {
                    Image("pi")
                        .resizable()
                        .renderingMode(.template)
                        .scaledToFit()
                        .frame(width: 16, height: 16)
                    Text("Open in Pi")
                        .fontWeight(.semibold)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(detail == nil || viewModel.selectedDiscoveredProject == nil)
            .keyboardShortcut(.defaultAction)
            .help(viewModel.selectedDiscoveredProject == nil ? "Select the local project before starting Pi Agent." : "Create a Pi Agent issue session with the issue prompt.")
        }
    }

    private func metadata(_ detail: GitHubIssueDetail) -> some View {
        AppCard(title: "Details") {
            VStack(alignment: .leading, spacing: 12) {
                if let author = detail.author {
                    HStack(spacing: 10) {
                        GitHubAvatarView(url: GitHubAvatarResolver.url(login: author, host: detail.item.url.host()), size: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(author)
                                .fontWeight(.semibold)
                            Text("Author")
                                .font(.caption)
                                .foregroundStyle(AppTheme.mutedText)
                        }
                    }
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
    }

    private func description(_ detail: GitHubIssueDetail) -> some View {
        AppCard(title: "Description") {
            if detail.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("No description provided.")
                    .foregroundStyle(AppTheme.mutedText)
            } else {
                MarkdownDocumentView(source: detail.body, minimumHeight: 120)
            }
        }
    }

    private func comments(_ detail: GitHubIssueDetail) -> some View {
        AppCard(title: "Comments", trailing: {
            Text("\(detail.comments.count)")
                .foregroundStyle(AppTheme.mutedText)
        }) {
            if detail.comments.isEmpty {
                Text("No comments yet.")
                    .foregroundStyle(AppTheme.mutedText)
            } else {
                VStack(alignment: .leading, spacing: 12) {
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

                                MarkdownTextView(source: cleanedCommentBody(comment.body))
                            }
                        }
                    }
                }
            }
        }
    }

    private var activeState: String {
        detail?.state ?? issue.state
    }

    private var activeType: String? {
        detail?.type ?? issue.type
    }

    private var activeLabels: [String] {
        detail?.labels ?? issue.labels
    }

    private func relativeDate(_ date: Date) -> String {
        RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
    }

    private func cleanedCommentBody(_ body: String) -> String {
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

private func piAgentIssueTypeColor(_ issueType: String) -> Color {
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

private struct PiAgentGitChangeListItem: Identifiable, Hashable {
    let path: String
    let staged: RepositoryFileChange?
    let unstaged: RepositoryFileChange?
    let untracked: RepositoryFileChange?
    let conflicted: RepositoryFileChange?

    var id: String { path }
    var isIncluded: Bool { staged != nil }
    var badgeText: String {
        if conflicted != nil { return "Conflict" }
        if untracked != nil { return "Added" }
        if staged != nil && unstaged != nil { return "Mixed" }
        let change = staged ?? unstaged
        switch change?.indexStatus == " " ? change?.worktreeStatus : change?.indexStatus {
        case "A": return "Added"
        case "D": return "Deleted"
        case "R": return "Renamed"
        case "M": return "Modified"
        default: return change?.statusSummary.trimmingCharacters(in: .whitespaces) ?? "Changed"
        }
    }
    var badgeColor: Color {
        switch badgeText {
        case "Added": return .green
        case "Deleted": return .red
        case "Renamed": return .purple
        case "Conflict": return .orange
        default: return .blue
        }
    }

    static func items(from snapshot: RepositoryChangesSnapshot) -> [PiAgentGitChangeListItem] {
        let paths = Set(snapshot.staged.map(\.path) + snapshot.unstaged.map(\.path) + snapshot.untracked.map(\.path) + snapshot.conflicted.map(\.path))
        let stagedByPath = Dictionary(snapshot.staged.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let unstagedByPath = Dictionary(snapshot.unstaged.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let untrackedByPath = Dictionary(snapshot.untracked.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let conflictedByPath = Dictionary(snapshot.conflicted.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        return paths.sorted().map { path in
            PiAgentGitChangeListItem(
                path: path,
                staged: stagedByPath[path],
                unstaged: unstagedByPath[path],
                untracked: untrackedByPath[path],
                conflicted: conflictedByPath[path]
            )
        }
    }
}

private struct PiAgentGitChangeRow: View {
    let item: PiAgentGitChangeListItem

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "doc.text")
                .foregroundStyle(AppTheme.mutedText)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.primary)
                Text(item.badgeText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(item.badgeColor)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
    }
}
