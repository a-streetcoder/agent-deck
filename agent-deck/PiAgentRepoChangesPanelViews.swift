import AppKit
import SwiftUI

struct PiAgentRepoChangesPanel: View {
    @ObservedObject var viewModel: AppViewModel
    @Binding var isPresented: Bool
    @State private var filterText = ""

    private var snapshot: RepositoryChangesSnapshot? { viewModel.githubRepositoryChanges }

    private var items: [PiAgentGitChangeListItem] {
        guard let snapshot else { return [] }
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        return PiAgentGitChangeListItem.items(from: snapshot).filter { item in
            query.isEmpty || item.path.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        AppSidebarPane(title: "Repo Changes", subtitle: snapshot.map { "\($0.totalChangeCount) changes" }) {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)

                Divider()

                panelContent
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .task { viewModel.prepareRepoChangesForSelectedPiAgentSession() }
    }

    @ViewBuilder
    private var panelContent: some View {
        if let error = viewModel.githubLastError {
            VStack(alignment: .leading, spacing: 12) {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                repositoryState
            }
        } else {
            repositoryState
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
                    viewModel.prepareRepoChangesForSelectedPiAgentSession()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .help("Refresh changes")
                .accessibilityLabel("Refresh changes")

                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .help("Close repo changes")
                .accessibilityLabel("Close repo changes")
            }
        }
    }

    private var repositoryDisplayName: String {
        viewModel.piAgentSessionStore.selectedSession?.projectName ?? viewModel.selectedDiscoveredProject?.name ?? "Pi Agent repository"
    }

    private func cleanRepositoryState(_ snapshot: RepositoryChangesSnapshot) -> some View {
        VStack(spacing: 16) {
            Image(systemName: snapshot.canPush ? "arrow.up.circle" : "checkmark.circle")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(snapshot.canPush ? Color.accentColor : AppTheme.mutedText)
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
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Button("Include All") { viewModel.stageAllChanges() }
                        .disabled(!snapshot.canStageAll)
                    Button("Exclude All") { viewModel.unstageAllChanges() }
                        .disabled(!snapshot.canUnstageAll)
                    Spacer()
                    Text("\(snapshot.staged.count)/\(snapshot.totalChangeCount) included")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.mutedText)
                }

                TextField("Filter files", text: $filterText)
                    .textFieldStyle(.roundedBorder)

                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(items) { item in
                        PiAgentGitChangeRow(
                            item: item,
                            onToggleIncluded: { toggleIncluded(item) }
                        )
                    }
                }

                Divider()
                    .padding(.top, 8)

                commitBox(snapshot)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
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

    private func commitBox(_ snapshot: RepositoryChangesSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Commit")
                .font(.headline)
            Text("Write a title, optionally add a description, then commit the included files.")
                .font(.footnote)
                .foregroundStyle(AppTheme.mutedText)

            TextField("Commit title", text: $viewModel.githubCommitMessage)
                .textFieldStyle(.roundedBorder)

            Text("Description")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.mutedText)
            TextEditor(text: $viewModel.githubCommitDescription)
                .font(.body)
                .frame(minHeight: 72, maxHeight: 100)
                .padding(6)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(AppTheme.contentStroke, lineWidth: 1))
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(AppTheme.contentFill))

            HStack {
                Button(viewModel.githubIsCommitting ? "Committing…" : "Commit \(snapshot.staged.count) file\(snapshot.staged.count == 1 ? "" : "s")") { viewModel.commitChanges() }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.githubIsCommitting || !snapshot.canCommit || viewModel.githubCommitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if snapshot.canPush {
                    Button(viewModel.githubIsPushing ? "Pushing…" : "Push \(snapshot.aheadCount)") { viewModel.pushCurrentBranch() }
                        .disabled(viewModel.githubIsPushing)
                }
                Spacer()
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(AppTheme.contentSubtleFill.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(AppTheme.contentStroke, lineWidth: 1))
    }

    private func toggleIncluded(_ item: PiAgentGitChangeListItem) {
        if item.isIncluded {
            viewModel.unstage(item.path)
        } else {
            viewModel.stage(item.path)
        }
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
        return paths.sorted().map { path in
            PiAgentGitChangeListItem(
                path: path,
                staged: snapshot.staged.first(where: { $0.path == path }),
                unstaged: snapshot.unstaged.first(where: { $0.path == path }),
                untracked: snapshot.untracked.first(where: { $0.path == path }),
                conflicted: snapshot.conflicted.first(where: { $0.path == path })
            )
        }
    }
}

private struct PiAgentGitChangeRow: View {
    let item: PiAgentGitChangeListItem
    let onToggleIncluded: () -> Void

    var body: some View {
        Button(action: onToggleIncluded) {
            HStack(spacing: 9) {
                Image(systemName: item.isIncluded ? "checkmark.square.fill" : "square")
                    .foregroundStyle(item.isIncluded ? Color.accentColor : AppTheme.mutedText)
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
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(item.isIncluded ? Color.accentColor.opacity(0.10) : Color.clear))
        }
        .buttonStyle(.plain)
        .help(item.isIncluded ? "Exclude from commit" : "Include in commit")
    }
}
