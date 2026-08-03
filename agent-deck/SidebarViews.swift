import SwiftUI

struct SidebarNavigationRow: View {
    let item: SidebarItem
    var isSelected: Bool = false
    var showsWarning = false
    var showsNewFeatureBadge = false
    @ObservedObject private var languageStore = LanguageStore.shared

    var body: some View {
        Label {
            HStack(spacing: 6) {
                Text(languageStore.t(item.l10nKey))
                    .font(AppTheme.Font.primary.weight(.medium))
                if showsNewFeatureBadge {
                    SidebarNewFeatureBadge(isSelected: isSelected)
                }
                if showsWarning {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.yellow)
                        .help(languageStore.t("sidebar.sectionWarning"))
                        .accessibilityLabel(languageStore.t("sidebar.sectionWarningA11y"))
                }
            }
        } icon: {
            icon
        }
    }

    @ViewBuilder
    private var icon: some View {
        if let asset = item.assetImageName {
            Image(asset)
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
                .foregroundStyle(iconStyle)
        } else {
            Image(systemName: item.systemImage)
                .frame(width: 16, height: 16)
                .foregroundStyle(iconStyle)
        }
    }

    private var iconStyle: AnyShapeStyle {
        isSelected
            ? AnyShapeStyle(AppTheme.brandAccent)
            : AnyShapeStyle(Color.secondary)
    }
}

private struct SidebarNewFeatureBadge: View {
    let isSelected: Bool

    var body: some View {
        Text(LanguageStore.shared.t("sidebar.badgeNew"))
            .font(AppTheme.Font.caption2.weight(.bold))
            .foregroundStyle(isSelected ? .primary : AppTheme.brandAccent)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background {
                Capsule(style: .continuous)
                    .fill(AppTheme.brandAccent.opacity(isSelected ? 0.24 : 0.14))
            }
            .overlay {
                Capsule(style: .continuous)
                    .stroke(AppTheme.brandAccent.opacity(isSelected ? 0.55 : 0.35), lineWidth: 0.75)
            }
            .help(LanguageStore.shared.t("sidebar.newLoopHelp"))
            .accessibilityLabel(LanguageStore.shared.t("sidebar.newFunctionality"))
    }
}


/// Brand row at the top of the sidebar: product title on the left; on the right
/// the Sparkle update shortcut (only when an update is available), the
/// refresh-everything button, and the Settings gear.
struct SidebarTitleBar: View {
    var viewModel: AppViewModel
    @Environment(\.openSettings) private var openSettings
    @EnvironmentObject private var updater: UpdaterService

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(AppBrand.displayName)
                .font(.system(size: 15, weight: .semibold, design: .default))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .fixedSize()
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 8)

            if updater.updateAvailable {
                Button {
                    updater.checkForUpdates()
                } label: {
                    // Point size chosen so the filled circle's optical diameter
                    // matches the gear glyph next to it (circle badges render
                    // smaller than outline glyphs at equal scale).
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(AppTheme.brandAccent)
                        .appActionTarget()
                }
                .buttonStyle(.plain)
                .help(updater.availableVersion.map { LanguageStore.shared.t("sidebar.updateToVersion", $0) } ?? LanguageStore.shared.t("sidebar.updateAvailable"))
                .accessibilityLabel(LanguageStore.shared.t("sidebar.installUpdate"))
            }

            Button {
                viewModel.refreshEverything()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .imageScale(.medium)
                    .foregroundStyle(AppTheme.mutedText)
                    .appActionTarget()
                    .symbolEffect(.rotate.byLayer, isActive: viewModel.isRefreshingEverything)
            }
            .buttonStyle(.plain)
            .help(LanguageStore.shared.t("sidebar.refreshEverythingHelp"))
            .accessibilityLabel(LanguageStore.shared.t("sidebar.refreshProjectsGit"))
            .disabled(viewModel.isRefreshingEverything)

            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .imageScale(.medium)
                    .foregroundStyle(AppTheme.mutedText)
                    .appActionTarget()
            }
            .buttonStyle(.plain)
            .help(LanguageStore.shared.t("sidebar.settingsEllipsis"))
            .accessibilityLabel(LanguageStore.shared.t("sidebar.settings"))
        }
    }
}

/// Shared project-scope picker used by project-scoped screen toolbars
/// (Issues, Memory, System Prompt). Shows the active project (or "Select
/// Project") and opens a popover listing every enabled project; selection
/// routes through `viewModel.setSelectedProject(_:)`.
struct ProjectToolbarSelector: View {
    @Bindable var viewModel: AppViewModel
    @Binding var isPresented: Bool

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 7) {
                if let project = viewModel.selectedDiscoveredProject {
                    ProjectIconView(
                        imageURL: project.iconFileURL,
                        symbolName: project.fallbackSymbolName,
                        size: 18,
                        assetName: project.projectType.assetName
                    )
                    Text(project.repositoryDisplayName)
                } else {
                    Image(systemName: "folder")
                    Text(LanguageStore.shared.t("sidebar.selectProject"))
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .toolbarNeutralChrome()
        .help(LanguageStore.shared.t("sidebar.chooseProject"))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(LanguageStore.shared.t("sidebar.projects"))
                    .font(.headline)
                Button {
                    viewModel.clearProjectRoot()
                    isPresented = false
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "square.grid.2x2")
                            .frame(width: 24, height: 24)
                            .foregroundStyle(AppTheme.mutedText)
                        Text(LanguageStore.shared.t("common.allProjects"))
                            .font(.body.weight(.medium))
                        Spacer(minLength: 12)
                        if viewModel.selectedProjectPath == nil {
                            Image(systemName: "checkmark")
                                .foregroundStyle(AppTheme.brandAccent)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                ForEach(viewModel.enabledProjects) { project in
                    Button {
                        viewModel.setSelectedProject(project.url)
                        isPresented = false
                    } label: {
                        HStack(spacing: 10) {
                            ProjectIconView(
                                imageURL: project.iconFileURL,
                                symbolName: project.fallbackSymbolName,
                                size: 24,
                                assetName: project.projectType.assetName
                            )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(project.repositoryDisplayName)
                                    .font(.body.weight(.medium))
                                if let remote = project.gitHubRemote {
                                    Text(remote.nameWithOwner)
                                        .font(.caption)
                                        .foregroundStyle(AppTheme.mutedText)
                                }
                            }
                            Spacer(minLength: 12)
                            if project.path == viewModel.selectedProjectPath {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(AppTheme.brandAccent)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(14)
            .frame(width: 300)
        }
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
                placeholder: LanguageStore.shared.t("sidebar.searchEnabledProjects"),
                text: $filterText,
                isLoading: isSearchDebouncing,
                font: .subheadline
            )

            ScrollView {
                LazyVStack(spacing: 2) {
                    ProjectSidebarRow(
                        title: LanguageStore.shared.t("common.allProjects"),
                        subtitle: LanguageStore.shared.t("sidebar.showSessionsAcrossProjects"),
                        symbolName: "square.grid.2x2",
                        imageURL: nil,
                        isSelected: selectedProjectPath == nil,
                        action: { select(nil) }
                    )

                    ForEach(projects) { project in
                        ProjectSidebarRow(
                            title: project.repositoryDisplayName,
                            subtitle: project.path,
                            symbolName: project.fallbackSymbolName,
                            imageURL: project.iconFileURL,
                            assetName: project.projectType.assetName,
                            isSelected: selectedProjectPath == project.path,
                            action: { select(project) }
                        )
                    }
                }
                .padding(.horizontal, 3)
            }
            .scrollIndicators(.never, axes: .vertical)
            .frame(width: 360, height: 220)
        }
        .padding(14)
    }

    private func select(_ project: DiscoveredProject?) {
        // Hop to the next runloop tick: the tap fires inside a SwiftUI update
        // pass, and onSelectProject triggers @Published mutations on
        // AppViewModel that would otherwise emit "Publishing changes from
        // within view updates is not allowed".
        Task { @MainActor in
            onSelectProject(project)
        }
    }
}

struct ProjectSidebarRow: View {
    let title: String
    let subtitle: String
    let symbolName: String
    let imageURL: URL?
    var assetName: String? = nil
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ProjectIconView(imageURL: imageURL, symbolName: symbolName, size: 28, assetName: assetName)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(AppTheme.Font.supporting.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(AppTheme.Font.micro)
                        .foregroundStyle(AppTheme.mutedText)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(rowFill)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    private var rowFill: Color {
        if isSelected {
            return AppTheme.brandAccent.opacity(0.22)
        }
        if isHovering {
            return Color.primary.opacity(0.06)
        }
        return .clear
    }
}
