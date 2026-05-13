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

    private var hasRunningSessions: Bool { runningSessionCount > 0 }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image("pi")
                    .resizable()
                    .renderingMode(.template)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 18, height: 18)
                    .foregroundStyle(AppTheme.brandAccent.gradient)

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
                        if needsAttentionCount > 0 || hasRunningSessions {
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

                if hasRunningSessions {
                    PiAgentTypingIndicator()
                        .scaleEffect(0.72)
                        .frame(width: 34, alignment: .trailing)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(sidebarBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isSelected ? AppTheme.selectionStroke : AppTheme.contentStroke, lineWidth: 1)
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

    private var sidebarBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(
                isSelected
                    ? AnyShapeStyle(
                        LinearGradient(
                            colors: [
                                AppTheme.brandAccentBright.opacity(0.14),
                                AppTheme.brandAccent.opacity(0.08),
                                AppTheme.contentSubtleFill
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    : AnyShapeStyle(AppTheme.contentSubtleFill)
            )
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
    @Binding var filterText: String
    let isSearchDebouncing: Bool
    let onSelectProject: (DiscoveredProject?) -> Void
    let onChooseProject: () -> Void

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                ProjectIconView(
                    imageURL: selectedProject?.iconFileURL,
                    symbolName: selectedProject?.fallbackSymbolName ?? "square.grid.2x2",
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
                        projects: projects,
                        selectedProjectPath: selectedProjectPath,
                        filterText: $filterText,
                        isSearchDebouncing: isSearchDebouncing,
                        onSelectProject: { project in
                            onSelectProject(project)
                            isExpanded = false
                        }
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

    private var selectedProjectTitle: String {
        if selectedProject == nil && selectedProjectPath == nil {
            return "All Projects"
        }
        if let remote = selectedProject?.gitHubRemote {
            return remote.repo
        }
        if let selectedProject {
            return selectedProject.name
        }
        if let selectedProjectPath {
            return URL(fileURLWithPath: selectedProjectPath).lastPathComponent
        }
        return "Choose Project"
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
    @Binding var filterText: String
    let isSearchDebouncing: Bool
    let onSelectProject: (DiscoveredProject?) -> Void

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
                        subtitle: "Show sessions across every project",
                        symbolName: "square.grid.2x2",
                        imageURL: nil,
                        isSelected: selectedProjectPath == nil,
                        action: { onSelectProject(nil) }
                    )

                    ForEach(projects) { project in
                        ProjectSidebarRow(
                            title: project.repositoryDisplayName,
                            subtitle: project.path,
                            symbolName: project.fallbackSymbolName,
                            imageURL: project.iconFileURL,
                            isSelected: selectedProjectPath == project.path,
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
