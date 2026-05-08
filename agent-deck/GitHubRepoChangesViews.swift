import AppKit
import SwiftUI

struct GitHubRepoChangesPlaceholder: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var filterText = ""

    var body: some View {
        AppCard(title: "Repo Changes", trailing: {
            if let snapshot = viewModel.githubRepositoryChanges {
                Text("\(snapshot.totalChangeCount)")
                    .foregroundStyle(AppTheme.mutedText)
            }
        }) {
            if let project = viewModel.selectedDiscoveredProject {
                VStack(alignment: .leading, spacing: 14) {
                    repositoryHeader(project: project)

                    if let error = viewModel.githubLastError {
                        Text(error)
                            .foregroundStyle(.red)
                    }

                    if !project.isGitRepository {
                        Text("The selected project is not a git repository, so local git changes are unavailable here.")
                            .foregroundStyle(AppTheme.mutedText)
                    } else if let snapshot = viewModel.githubRepositoryChanges {
                        GitHubDesktopChangesView(snapshot: snapshot, filterText: $filterText, viewModel: viewModel)
                    } else if viewModel.githubIsLoadingRepositoryChanges {
                        ProgressView("Loading repository changes…")
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

    private func repositoryHeader(project: DiscoveredProject) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(project.repositoryDisplayName)
                    .font(.headline)
                Text(project.path)
                    .font(.footnote.monospaced())
                    .foregroundStyle(AppTheme.mutedText)
            }

            Spacer()

            if project.isGitRepository {
                HStack(spacing: 8) {
                    if viewModel.githubIsLoadingRepositoryChanges, viewModel.githubRepositoryChanges != nil {
                        ProgressView()
                            .controlSize(.small)
                            .help("Refreshing changes")
                    }
                    Button("Refresh") {
                        viewModel.refreshRepositoryChanges()
                    }
                }
            }
        }
    }
}

private struct GitHubDesktopChangesView: View {
    let snapshot: RepositoryChangesSnapshot
    @Binding var filterText: String
    @ObservedObject var viewModel: AppViewModel

    private var items: [GitChangeListItem] {
        GitChangeListItem.items(from: snapshot).filter { item in
            filterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            item.path.localizedCaseInsensitiveContains(filterText)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            repositorySummary

            HStack(alignment: .top, spacing: 0) {
                changesSidebar
                    .frame(width: 360)

                Divider()
                    .padding(.horizontal, 12)

                GitDiffPreviewPane(
                    filePath: viewModel.githubSelectedDiffFilePath,
                    kind: viewModel.githubSelectedDiffKind,
                    diffText: viewModel.githubSelectedDiffText
                )
                .frame(maxWidth: .infinity, minHeight: 520, alignment: .topLeading)
            }
            .frame(minHeight: 560)
        }
        .onAppear(perform: selectInitialDiffIfNeeded)
        .onChange(of: snapshot.totalChangeCount) { _, _ in
            Task { @MainActor in
                await Task.yield()
                selectInitialDiffIfNeeded()
            }
        }
    }

    private var repositorySummary: some View {
        HStack(spacing: 10) {
            AppLabelTag(text: snapshot.branchName, color: AppTheme.brandAccentDeep)
            if let upstream = snapshot.upstreamBranch {
                AppLabelTag(text: upstream, color: .gray)
            }
            if snapshot.aheadCount > 0 {
                AppLabelTag(text: "↑ \(snapshot.aheadCount)", color: .green)
            }
            if snapshot.behindCount > 0 {
                AppLabelTag(text: "↓ \(snapshot.behindCount)", color: .orange)
            }
            Spacer()
            Button("Include All") { viewModel.stageAllChanges() }
                .disabled(!snapshot.canStageAll)
            Button("Exclude All") { viewModel.unstageAllChanges() }
                .disabled(!snapshot.canUnstageAll)
        }
    }

    private var changesSidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Changes")
                        .font(.headline)
                    Text("\(snapshot.totalChangeCount)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.mutedText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule(style: .continuous).fill(AppTheme.contentSubtleFill))
                    Spacer()
                }

                TextField("Filter files", text: $filterText)
                    .textFieldStyle(.roundedBorder)

                Button {
                    snapshot.canUnstageAll ? viewModel.unstageAllChanges() : viewModel.stageAllChanges()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: snapshot.canUnstageAll ? "checkmark.square.fill" : "square")
                            .foregroundStyle(snapshot.canUnstageAll ? AppTheme.brandAccent : AppTheme.mutedText)
                        Text("\(includedCount) of \(snapshot.totalChangeCount) files included")
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(items) { item in
                        GitChangeFileRow(
                            item: item,
                            isSelected: viewModel.githubSelectedDiffFilePath == item.path,
                            onToggleIncluded: { toggleIncluded(item) },
                            onSelect: { viewModel.loadDiff(for: item.path, kind: item.preferredDiffKind) }
                        )
                    }
                }
            }
            .frame(minHeight: 220, maxHeight: 360)

            Divider()

            commitBox
        }
    }

    private var commitBox: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Commit")
                .font(.headline)
            Text("\(includedCount) file\(includedCount == 1 ? "" : "s") included")
                .font(.footnote)
                .foregroundStyle(AppTheme.mutedText)

            TextEditor(text: $viewModel.githubCommitMessage)
                .font(.body)
                .frame(minHeight: 86)
                .padding(6)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(AppTheme.contentStroke, lineWidth: 1))
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(AppTheme.contentFill))

            HStack {
                Button("Commit \(includedCount) file\(includedCount == 1 ? "" : "s")") {
                    viewModel.commitChanges()
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.githubIsCommitting || !snapshot.canCommit || viewModel.githubCommitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("Push") {
                    viewModel.pushCurrentBranch()
                }
                .disabled(viewModel.githubIsPushing || !snapshot.canPush)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(AppTheme.contentSubtleFill.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(AppTheme.contentStroke, lineWidth: 1))
    }

    private var includedCount: Int { snapshot.staged.count }

    private func toggleIncluded(_ item: GitChangeListItem) {
        if item.isIncluded {
            viewModel.unstage(item.path)
        } else {
            viewModel.stage(item.path)
        }
    }

    private func selectInitialDiffIfNeeded() {
        guard viewModel.githubSelectedDiffFilePath == nil, let first = items.first else { return }
        viewModel.loadDiff(for: first.path, kind: first.preferredDiffKind)
    }
}

private struct GitChangeListItem: Identifiable, Hashable {
    let path: String
    let staged: RepositoryFileChange?
    let unstaged: RepositoryFileChange?
    let untracked: RepositoryFileChange?
    let conflicted: RepositoryFileChange?

    var id: String { path }
    var isIncluded: Bool { staged != nil }
    var preferredDiffKind: GitDiffKind {
        if untracked != nil { return .untracked }
        if unstaged != nil { return .unstaged }
        if conflicted != nil { return .conflicted }
        return .staged
    }
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

    static func items(from snapshot: RepositoryChangesSnapshot) -> [GitChangeListItem] {
        let paths = Set(snapshot.staged.map(\.path) + snapshot.unstaged.map(\.path) + snapshot.untracked.map(\.path) + snapshot.conflicted.map(\.path))
        return paths.sorted().map { path in
            GitChangeListItem(
                path: path,
                staged: snapshot.staged.first(where: { $0.path == path }),
                unstaged: snapshot.unstaged.first(where: { $0.path == path }),
                untracked: snapshot.untracked.first(where: { $0.path == path }),
                conflicted: snapshot.conflicted.first(where: { $0.path == path })
            )
        }
    }
}

private struct GitChangeFileRow: View {
    let item: GitChangeListItem
    let isSelected: Bool
    let onToggleIncluded: () -> Void
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 9) {
                Button(action: onToggleIncluded) {
                    Image(systemName: item.isIncluded ? "checkmark.square.fill" : "square")
                        .foregroundStyle(item.isIncluded ? AppTheme.brandAccent : AppTheme.mutedText)
                }
                .buttonStyle(.plain)
                .help(item.isIncluded ? "Exclude from commit" : "Include in commit")

                Image(systemName: "doc.text")
                    .foregroundStyle(AppTheme.mutedText)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.primary)
                    HStack(spacing: 6) {
                        Text(item.badgeText)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(item.badgeColor)
                        if item.staged != nil && item.unstaged != nil {
                            Text("staged + unstaged")
                                .font(.caption2)
                                .foregroundStyle(AppTheme.mutedText)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(isSelected ? AppTheme.brandAccent.opacity(0.16) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(isSelected ? AppTheme.brandAccent.opacity(0.35) : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

private struct GitDiffPreviewPane: View {
    let filePath: String?
    let kind: GitDiffKind?
    let diffText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(filePath ?? "Select a file")
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let kind {
                        Text(kind.rawValue)
                            .font(.caption)
                            .foregroundStyle(AppTheme.mutedText)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 2)

            if filePath == nil {
                ContentUnavailableView("No file selected", systemImage: "doc.text.magnifyingglass", description: Text("Select a changed file to preview its diff."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let diffText {
                GitUnifiedDiffView(diffText: diffText)
            } else {
                ProgressView("Loading diff…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct GitUnifiedDiffView: View {
    let diffText: String
    @State private var cachedLines: [String] = []

    init(diffText: String) {
        self.diffText = diffText
        _cachedLines = State(initialValue: Self.lines(for: diffText))
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(cachedLines.indices, id: \.self) { index in
                        GitDiffLineView(lineNumber: index + 1, text: cachedLines[index], minWidth: geometry.size.width)
                    }
                }
                .padding(.vertical, 8)
                .frame(minWidth: geometry.size.width, alignment: .leading)
            }
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(AppTheme.contentSubtleFill.opacity(0.45)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(AppTheme.contentStroke, lineWidth: 1))
        .onAppear(perform: rebuildLines)
        .onChange(of: diffText) { _, _ in rebuildLines() }
    }

    private func rebuildLines() {
        cachedLines = Self.lines(for: diffText)
    }

    private static func lines(for diffText: String) -> [String] {
        let split = diffText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return split.isEmpty ? ["No diff for this file."] : split
    }
}

private struct GitDiffLineView: View {
    let lineNumber: Int
    let text: String
    let minWidth: CGFloat

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(lineNumber)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(AppTheme.mutedText)
                .frame(width: 42, alignment: .trailing)
            Text(text.isEmpty ? " " : text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(foregroundColor)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
        .frame(minWidth: minWidth, alignment: .leading)
        .background(backgroundColor)
    }

    private var foregroundColor: Color {
        if text.hasPrefix("+") && !text.hasPrefix("+++") { return .green }
        if text.hasPrefix("-") && !text.hasPrefix("---") { return .red }
        if text.hasPrefix("@@") { return .blue }
        return .primary
    }

    private var backgroundColor: Color {
        if text.hasPrefix("+") && !text.hasPrefix("+++") { return Color.green.opacity(0.14) }
        if text.hasPrefix("-") && !text.hasPrefix("---") { return Color.red.opacity(0.14) }
        if text.hasPrefix("@@") { return Color.blue.opacity(0.10) }
        return Color.clear
    }
}
