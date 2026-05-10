import AppKit
import SwiftUI

struct SidebarNavigationRow: View {
    let item: SidebarItem
    var showsWarning = false

    var body: some View {
        Label {
            HStack(spacing: 6) {
                Text(item.rawValue)
                    .font(.callout.weight(.medium))
                if showsWarning {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.yellow)
                        .help("This section has warnings that need attention.")
                        .accessibilityLabel("Section warning")
                }
            }
            .fontWidth(.expanded)
        } icon: {
            icon
        }
    }

    private var icon: some View {
        Image(systemName: item.systemImage)
            .frame(width: 16, height: 16)
    }
}


struct PiAgentSidebarButton: View {
    let isSelected: Bool
    let runningSessionCount: Int
    let needsAttentionCount: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image("pi")
                    .resizable()
                    .renderingMode(.template)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 18, height: 18)
                    .foregroundStyle(isSelected ? .primary : .secondary)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Pi Agent")
                        .font(.callout.weight(.semibold))
                        .fontWidth(.expanded)
                        .foregroundStyle(.primary)
                    Text(statusText)
                        .font(.callout)
                        .fontWeight(.regular)
                        .foregroundStyle(AppTheme.mutedText)
                        .fontWidth(.compressed)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .mask {
                    HStack(spacing: 0) {
                        Rectangle()
                        if needsAttentionCount > 0 {
                            LinearGradient(
                                stops: [
                                    .init(color: .black, location: 0),
                                    .init(color: .black.opacity(0), location: 1)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: 36)
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .appControlSurface(cornerRadius: 16)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isSelected ? AppTheme.selectionStroke : Color.clear, lineWidth: 1)
            )
            .overlay(alignment: .topTrailing) {
                if needsAttentionCount > 0 {
                    Text(badgeText)
                        .font(.caption2.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, needsAttentionCount > 9 ? 6 : 5)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Capsule(style: .continuous).fill(Color.red))
                        .overlay(Capsule(style: .continuous).stroke(.white.opacity(0.9), lineWidth: 1.5))
                        .offset(x: 6, y: -6)
                        .accessibilityLabel("\(needsAttentionCount) Pi Agent notification\(needsAttentionCount == 1 ? "" : "s")")
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Pi Agent")
        .accessibilityHint(accessibilityHint)
    }

    private var statusText: String {
        if needsAttentionCount > 0 {
            let remainingRunningCount = max(0, runningSessionCount - needsAttentionCount)
            let waitingText = needsAttentionCount == 1 ? "1 waiting" : "\(needsAttentionCount) waiting"
            if remainingRunningCount > 0 {
                let runningText = remainingRunningCount == 1 ? "1 running" : "\(remainingRunningCount) running"
                return "\(waitingText) · \(runningText)"
            }
            return needsAttentionCount == 1 ? "1 session waiting" : "\(needsAttentionCount) sessions waiting"
        }

        if runningSessionCount > 0 {
            return runningSessionCount == 1 ? "1 session running" : "\(runningSessionCount) sessions running"
        }

        return isSelected ? "Ready to code" : "Click to start coding"
    }

    private var accessibilityHint: String {
        if needsAttentionCount > 0 {
            return needsAttentionCount == 1 ? "1 Pi Agent session is waiting" : "\(needsAttentionCount) Pi Agent sessions are waiting"
        }
        if runningSessionCount > 0 {
            return runningSessionCount == 1 ? "1 Pi Agent session is running" : "\(runningSessionCount) Pi Agent sessions are running"
        }
        return "Open Pi Agent sessions"
    }

    private var badgeText: String {
        needsAttentionCount > 99 ? "99+" : "\(needsAttentionCount)"
    }
}

struct SidebarProjectGitHubCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var viewModel: AppViewModel
    let projects: [DiscoveredProject]
    let selectedProject: DiscoveredProject?
    let selectedProjectPath: String?
    let favoriteProjectPaths: Set<String>
    @Binding var filterText: String
    let isSearchDebouncing: Bool
    let onSelectProject: (DiscoveredProject) -> Void
    let onSelectAllProjects: () -> Void
    let onToggleFavorite: (DiscoveredProject) -> Void
    let onChooseProject: () -> Void

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                ProjectIconView(
                    imageURL: selectedProject?.iconFileURL,
                    symbolName: selectedProject?.fallbackSymbolName ?? "folder",
                    size: 34
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(selectedProjectTitle)
                        .font(.body)
                        .fontWeight(.medium)
//                        .fontWidth(selectedProject != nil ? .expanded : .standard )
                        .lineLimit(1)
                    if selectedProject != nil {
                        Text(selectedProjectSubtitle)
                            .font(.callout)
                            .fontWeight(.regular)
                            .foregroundStyle(AppTheme.mutedText)
                            .lineLimit(1)
                            .fontWidth(.compressed)
                    }
                }

                Spacer(minLength: 8)

                Button {
                    isExpanded.toggle()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .appControlSurface(cornerRadius: 14)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Choose project")
                .accessibilityHint("Opens the project picker")
                .popover(isPresented: $isExpanded, arrowEdge: .bottom) {
                    ProjectPickerPopover(
                        projects: orderedProjects,
                        selectedProjectPath: selectedProjectPath,
                        favoriteProjectPaths: favoriteProjectPaths,
                        filterText: $filterText,
                        isSearchDebouncing: isSearchDebouncing,
                        onSelectProject: { project in
                            onSelectProject(project)
                            isExpanded = false
                        },
                        onSelectAllProjects: {
                            onSelectAllProjects()
                            isExpanded = false
                        },
                        onToggleFavorite: onToggleFavorite
                    )
                }
            }

            Divider()
                .opacity(0.7)

            HStack(spacing: 12) {
                SidebarGitHubAvatarView(url: avatarURL, size: 32)
                    .overlay(alignment: Alignment.bottomTrailing) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 10, height: 10)
                            .overlay(Circle().stroke(AppTheme.contentFill, lineWidth: 2))
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(accountName)
                        .fontWeight(.medium)
//                        .fontWidth(.expanded)
                        .lineLimit(1)
                    Text(statusText)
                        .font(.callout)
                        .fontWeight(.regular)
                        .foregroundStyle(AppTheme.mutedText)
                        .fontWidth(.compressed)
                }

                Spacer()

                Button {
                    viewModel.refreshEverything()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppTheme.mutedText)
                        .frame(width: 28, height: 28)
                        .appControlSurface(cornerRadius: 14)
                        .symbolEffect(.rotate.byLayer, isActive: viewModel.githubIsRefreshingEverything)
                }
                .buttonStyle(.plain)
                .help("Refresh GitHub status, project scans, and repo data")
                .accessibilityLabel("Refresh GitHub and projects")
                .disabled(viewModel.githubIsRefreshingEverything)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: isExpanded)
        .appContentSurface(cornerRadius: 16)
    }

    private var favoriteProjects: [DiscoveredProject] {
        projects.filter { favoriteProjectPaths.contains($0.path) }
    }

    private var otherProjects: [DiscoveredProject] {
        projects.filter { !favoriteProjectPaths.contains($0.path) }
    }

    private var orderedProjects: [DiscoveredProject] {
        favoriteProjects + otherProjects
    }

    private var selectedProjectTitle: String {
        if let remote = selectedProject?.gitHubRemote {
            return remote.repo
        }
        if let selectedProject {
            return selectedProject.name
        }
        if let selectedProjectPath {
            return URL(fileURLWithPath: selectedProjectPath).lastPathComponent
        }
        return "All Projects"
    }

    private var selectedProjectSubtitle: String {
        if let remote = selectedProject?.gitHubRemote {
            return remote.owner
        }
        return selectedProject?.path ?? selectedProjectPath ?? ""
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
        guard let account = viewModel.currentGitHubAccount,
              account.host.caseInsensitiveCompare("github.com") == .orderedSame else { return nil }
        return URL(string: "https://avatars.githubusercontent.com/\(account.login)")
    }

}


struct ProjectPickerPopover: View {
    let projects: [DiscoveredProject]
    let selectedProjectPath: String?
    let favoriteProjectPaths: Set<String>
    @Binding var filterText: String
    let isSearchDebouncing: Bool
    let onSelectProject: (DiscoveredProject) -> Void
    let onSelectAllProjects: () -> Void
    let onToggleFavorite: (DiscoveredProject) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SearchFieldWithProgress(
                placeholder: "Search enabled projects",
                text: $filterText,
                isLoading: isSearchDebouncing
            )

            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ProjectSidebarRow(
                        title: "All Projects",
                        subtitle: "Show global resources and sessions across every project",
                        symbolName: "rectangle.stack",
                        imageURL: nil,
                        isSelected: selectedProjectPath == nil,
                        isFavorite: false,
                        showsFavoriteButton: false,
                        onToggleFavorite: nil,
                        action: onSelectAllProjects
                    )

                    Divider().opacity(0.7)

                    ForEach(projects) { project in
                        ProjectSidebarRow(
                            title: project.repositoryDisplayName,
                            subtitle: project.path,
                            symbolName: project.fallbackSymbolName,
                            imageURL: project.iconFileURL,
                            isSelected: selectedProjectPath == project.path,
                            isFavorite: favoriteProjectPaths.contains(project.path),
                            showsFavoriteButton: true,
                            onToggleFavorite: { onToggleFavorite(project) },
                            action: { onSelectProject(project) }
                        )
                    }
                }
            }
            .frame(width: 360, height: 220)
        }
        .padding(14)
    }
}

struct ProjectSidebarRow: View {
    let title: String
    let subtitle: String
    let symbolName: String
    let imageURL: URL?
    let isSelected: Bool
    let isFavorite: Bool
    let showsFavoriteButton: Bool
    let onToggleFavorite: (() -> Void)?
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: action) {
                HStack(spacing: 10) {
                    ProjectIconView(imageURL: imageURL, symbolName: symbolName, size: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(AppTheme.mutedText)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(AppTheme.brandAccent)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isSelected ? AppTheme.selectionFill : AppTheme.contentSubtleFill.opacity(0.22))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(isSelected ? AppTheme.selectionStroke : AppTheme.contentStroke, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)

            if showsFavoriteButton, let onToggleFavorite {
                Button(action: onToggleFavorite) {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .font(.caption)
                        .foregroundStyle(isFavorite ? Color.yellow : AppTheme.mutedText)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(AppTheme.contentSubtleFill.opacity(0.8)))
                }
                .buttonStyle(.plain)
                .help(isFavorite ? "Remove favorite" : "Add favorite")
            }
        }
    }
}

struct SidebarGitHubAvatarView: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case let .success(image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        Image("github")
                            .resizable()
                            .renderingMode(.template)
                            .scaledToFit()
                            .padding(7)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Image("github")
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .padding(7)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .background(
            Circle()
                .fill(AppTheme.contentSubtleFill)
        )
        .clipShape(Circle())
    }
}
