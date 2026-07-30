import AppKit
import ImageIO
import SwiftUI

private func loadingRow(_ text: String) -> some View {
    HStack(spacing: 10) {
        AppSpinner()
            .controlSize(.small)
        Text(text)
            .foregroundStyle(AppTheme.mutedText)
    }
}

struct ProjectAssignmentToggleRow: View {
    let project: DiscoveredProject
    @Binding var isOn: Bool

    var body: some View {
        AppCheckboxRow(
            isOn: $isOn,
            accessibilityLabel: LanguageStore.shared.t("projects.toggleProject", project.name)
        ) {
            HStack(alignment: .center, spacing: 12) {
                ProjectIconView(imageURL: project.iconFileURL, symbolName: project.fallbackSymbolName, size: 30, assetName: project.projectType.assetName)

                VStack(alignment: .leading, spacing: 3) {
                    Text(project.name)
                        .font(AppTheme.Font.primary.weight(.semibold))
                    Text(project.repositoryName ?? project.path)
                        .font(AppTheme.Font.metadata)
                        .foregroundStyle(AppTheme.mutedText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 0)
            }
        }
        .controlSize(.regular)
        .frame(minHeight: 46, alignment: .center)
        .padding(.vertical, 8)
    }
}

/// Row that mirrors `ProjectAssignmentToggleRow` but represents the
/// "enable for every project" shortcut — same icon and copy as the sidebar's
/// All Projects entry.
struct AllProjectsAssignmentRow: View {
    @Binding var isOn: Bool
    var subtitle: String = LanguageStore.shared.t("agents.enableEveryProject")

    var body: some View {
        AppCheckboxRow(
            isOn: $isOn,
            accessibilityLabel: LanguageStore.shared.t("projects.toggleAll")
        ) {
            HStack(alignment: .center, spacing: 12) {
                ProjectIconView(imageURL: nil, symbolName: "square.grid.2x2", size: 30)

                VStack(alignment: .leading, spacing: 3) {
                    Text(LanguageStore.shared.t("common.allProjects"))
                        .font(AppTheme.Font.primary.weight(.semibold))
                    Text(subtitle)
                        .font(AppTheme.Font.metadata)
                        .foregroundStyle(AppTheme.mutedText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 0)
            }
        }
        .controlSize(.regular)
        .frame(minHeight: 46, alignment: .center)
        .padding(.vertical, 8)
    }
}

struct SearchFieldWithProgress: View {
    let placeholder: String
    @Binding var text: String
    let isLoading: Bool
    var font: Font = .body

    var body: some View {
        AppTextField(text: $text, placeholder: placeholder, font: font)
            .overlay(alignment: .trailing) {
                if isLoading {
                    AppSpinner()
                        .controlSize(.small)
                        .padding(.trailing, 6)
                }
            }
    }
}


private struct ProjectIconEditorButton: View {
    let imageURL: URL?
    let symbolName: String
    let size: CGFloat
    var assetName: String? = nil
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                ProjectIconView(imageURL: imageURL, symbolName: symbolName, size: size, assetName: assetName)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isHovering ? Color.black.opacity(0.18) : .clear)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(isHovering ? AppTheme.brandAccent.opacity(0.9) : AppTheme.contentStroke, lineWidth: isHovering ? 2 : 1)
                    }
                    .overlay {
                        if isHovering {
                            Image(systemName: imageURL == nil ? "photo.badge.plus" : "pencil")
                                .font(.system(size: max(11, size * 0.32), weight: .bold))
                                .foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 1)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }

            }
            .scaleEffect(isHovering ? 1.03 : 1)
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.16), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
        .help(imageURL == nil ? LanguageStore.shared.t("projects.setCustomIcon") : LanguageStore.shared.t("projects.changeCustomIcon"))
    }
}

struct ProjectIconView: View {
    let imageURL: URL?
    let symbolName: String
    let size: CGFloat
    /// Optional `Assets.xcassets` entry for the project type. Rendered when the
    /// asset exists in the catalog; otherwise falls back to the SF Symbol.
    var assetName: String? = nil

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .interpolation(.high)
                    .antialiased(true)
                    .resizable()
                    .scaledToFill()
            } else if imageURL != nil {
                AppSpinner()
                    .controlSize(.small)
            } else if let assetName, !assetName.isEmpty, NSImage(named: assetName) != nil {
                Image(assetName)
                    .resizable()
                    .scaledToFit()
                    .padding(6)
            } else {
                Image(systemName: symbolName)
                    .resizable()
                    .scaledToFit()
                    .padding(6)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(AppTheme.contentSubtleFill)
        )
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: imageURL?.path) {
            await loadImage()
        }
    }

    private var cornerRadius: CGFloat {
        min(8, size * 0.267)
    }

    private func loadImage() async {
        guard let imageURL else {
            image = nil
            return
        }

        if let cachedImage = await ProjectIconCache.shared.cachedImage(for: imageURL) {
            image = cachedImage
            return
        }

        let loadedImage = await ProjectIconCache.shared.loadImage(for: imageURL)
        guard imageURL == self.imageURL else { return }
        image = loadedImage
    }
}

actor ProjectIconCache {
    static let shared = ProjectIconCache()

    private let cache = NSCache<NSString, NSImage>()

    /// Project icons render at most ~34pt; at 3x that's ~102px. Decoding a 128px
    /// thumbnail keeps every use crisp while avoiding the full-resolution decode
    /// (app icons / favicons are often 512px+ and were being downscaled by SwiftUI,
    /// which both wasted memory and rendered fuzzily). One entry per path, shared.
    private static let maxPixelSize = 128

    func cachedImage(for url: URL) -> NSImage? {
        cache.object(forKey: url.path as NSString)
    }

    func loadImage(for url: URL) async -> NSImage? {
        if let cachedImage = cache.object(forKey: url.path as NSString) {
            return cachedImage
        }

        let image = await Task.detached(priority: .utility) {
            Self.downsampledImage(at: url, maxPixelSize: Self.maxPixelSize)
        }.value

        if let image {
            cache.setObject(image, forKey: url.path as NSString)
        }

        return image
    }

    /// Decode `url` straight to a crisp thumbnail no larger than `maxPixelSize` on
    /// its long edge, honoring EXIF orientation. Falls back to a plain decode for
    /// formats ImageIO can't thumbnail.
    private static func downsampledImage(at url: URL, maxPixelSize: Int) -> NSImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            return NSImage(contentsOf: url)
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            return NSImage(contentsOf: url)
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

struct ProjectsScreen: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all
        case enabled
        case disabled

        var id: String { rawValue }

        var l10nKey: String {
            switch self {
            case .all: return "projects.filter.all"
            case .enabled: return "projects.filter.enabled"
            case .disabled: return "projects.filter.disabled"
            }
        }

        @MainActor
        var localizedTitle: String {
            LanguageStore.shared.t(l10nKey)
        }
    }

    var viewModel: AppViewModel
    @Binding var searchText: String
    @State private var filter: Filter = .enabled
    @State private var debouncedSearchText = ""
    @State private var agentsRecapProject: DiscoveredProject?
    @State private var skillsRecapProject: DiscoveredProject?
    @State private var mcpRecapProject: DiscoveredProject?
    @State private var projectPendingRemoval: DiscoveredProject?
    @State private var shouldMovePendingProjectToTrash = false
    @State private var projectDeleteError: String?
    /// Cached visible-project layout. Without this, the body would walk
    /// `discoveredProjects` twice per render (once for `.isEmpty`, once for
    /// `ForEach`) plus a third pass for `hasEnabledProjects`, with each
    /// `projectPreference(for:)` lookup hitting the dictionary. For users
    /// with 30-80 projects this is O(N) ×3 per body. Recomputed via
    /// `.task(id: cacheKey)` over the 4 inputs.
    @State private var cachedVisibleProjects: [DiscoveredProject] = []
    @State private var cachedHasEnabledProjects: Bool = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            AppCard(title: LanguageStore.shared.t("common.library")) {
                projectList
            }
            .padding(AppTheme.pagePadding)
        }
        .task(id: searchText) {
            let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            debouncedSearchText = trimmed.lowercased()
        }
        .task(id: projectsCacheKey) { recomputeProjectsLayout() }
        .sheet(item: $agentsRecapProject) { project in
            ProjectAgentsRecapSheet(
                project: project,
                viewModel: viewModel,
                imageStore: viewModel.agentImageStore
            )
        }
        .sheet(item: $skillsRecapProject) { project in
            ProjectSkillsRecapSheet(
                project: project,
                viewModel: viewModel
            )
        }
        .sheet(item: $mcpRecapProject) { project in
            ProjectMcpServersRecapSheet(
                project: project,
                viewModel: viewModel
            )
        }
        .sheet(item: $projectPendingRemoval, onDismiss: { shouldMovePendingProjectToTrash = false }) { project in
            ProjectRemovalConfirmationSheet(
                project: project,
                moveToTrash: $shouldMovePendingProjectToTrash,
                onCancel: {
                    projectPendingRemoval = nil
                },
                onConfirm: {
                    confirmProjectRemoval(project)
                }
            )
        }
        .alert(LanguageStore.shared.t("projects.alert.moveTrashTitle"), isPresented: Binding(
            get: { projectDeleteError != nil },
            set: { if !$0 { projectDeleteError = nil } }
        )) {
            Button(LanguageStore.shared.t("common.ok"), role: .cancel) { projectDeleteError = nil }
        } message: {
            Text(projectDeleteError ?? LanguageStore.shared.t("projects.alert.unknownError"))
        }
    }

    private func showProjectRemovalConfirmation(for project: DiscoveredProject) {
        shouldMovePendingProjectToTrash = false
        projectPendingRemoval = project
    }

    private func confirmProjectRemoval(_ project: DiscoveredProject) {
        if shouldMovePendingProjectToTrash {
            do {
                try viewModel.moveProjectToTrash(project)
            } catch {
                projectDeleteError = error.localizedDescription
            }
        } else {
            viewModel.removeProjectFromLibrary(project)
        }
        shouldMovePendingProjectToTrash = false
        projectPendingRemoval = nil
    }

    private func showProjectInFinder(_ project: DiscoveredProject) {
        NSWorkspace.shared.activateFileViewerSelecting([project.url])
    }

    private var projectList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(LanguageStore.shared.t("projects.filter"), selection: $filter) {
                ForEach(Filter.allCases) { option in
                    Text(option.localizedTitle).tag(option)
                }
            }
            .labelsHidden()
            .appSegmentedPicker()
            .frame(maxWidth: 320)

            Text(LanguageStore.shared.t("projects.manageIntro"))
                .font(.caption)
                .foregroundStyle(AppTheme.mutedText)
                .fixedSize(horizontal: false, vertical: true)

            if viewModel.discoveredProjects.isEmpty {
                ContentUnavailableView(
                    LanguageStore.shared.t("projects.emptyTitle"),
                    systemImage: "folder",
                    description: Text(emptyProjectsRootDescription)
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } else if visibleProjects.isEmpty {
                ContentUnavailableView(
                    LanguageStore.shared.t("projects.noMatchingTitle"),
                    systemImage: "magnifyingglass",
                    description: Text(LanguageStore.shared.t("common.tryAnotherSearch"))
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } else {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(visibleProjects) { project in
                        projectRow(project)
                    }
                }
            }
        }
    }

    private var emptyProjectsRootDescription: String {
        let paths = viewModel.configuredProjectsRootPaths
        switch paths.count {
        case 0:
            return LanguageStore.shared.t("projects.emptyRootNone")
        case 1:
            return LanguageStore.shared.t("projects.emptyRootOne", paths[0])
        default:
            return LanguageStore.shared.t("projects.emptyRootMany", paths.count)
        }
    }

    private var visibleProjects: [DiscoveredProject] { cachedVisibleProjects }
    private var hasEnabledProjects: Bool { cachedHasEnabledProjects }

    private var projectsCacheKey: String {
        // Both revision counters bump once per mutation (no per-render hashing).
        "\(viewModel.discoveredProjectsRevision)|\(viewModel.projectPreferencesRevision)|\(debouncedSearchText)|\(filter.rawValue)"
    }

    private func recomputeProjectsLayout() {
        // Two-pass to match the original semantics: `effectiveFilter` depends
        // on whether ANY project is enabled across the full collection. A
        // streaming pass would race a not-yet-discovered enabled project
        // against the filter applied to earlier items.
        let allProjects = viewModel.discoveredProjects
        var anyEnabled = false
        var prefByPath: [String: ProjectPreference] = [:]
        prefByPath.reserveCapacity(allProjects.count)
        for project in allProjects {
            let preference = viewModel.projectPreference(for: project.path)
            prefByPath[project.path] = preference
            if preference.isEnabled { anyEnabled = true }
        }
        cachedHasEnabledProjects = anyEnabled

        let effectiveFilter: Filter = (!anyEnabled && filter == .enabled) ? .all : filter
        let query = debouncedSearchText
        var matched: [DiscoveredProject] = []
        matched.reserveCapacity(allProjects.count)
        for project in allProjects {
            guard let preference = prefByPath[project.path] else { continue }
            let matchesFilter: Bool = switch effectiveFilter {
            case .all: true
            case .enabled: preference.isEnabled
            case .disabled: !preference.isEnabled
            }
            guard matchesFilter else { continue }
            if !query.isEmpty, !project.searchIndex.contains(query) { continue }
            matched.append(project)
        }
        cachedVisibleProjects = matched
    }

    private func shouldShowGitHubBadge(for project: DiscoveredProject) -> Bool {
        guard let remote = project.gitHubRemote else { return false }
        return remote.isGitHubDotCom && !remote.owner.isEmpty && !remote.repo.isEmpty
    }

    @ViewBuilder
    private func projectRow(_ project: DiscoveredProject) -> some View {
        let preference = viewModel.projectPreference(for: project.path)
        let isActiveSessionProject = viewModel.selectedProjectPath == project.path
        let hasAgentAssignments = !viewModel.appSettings.defaultAgentNames.isEmpty || !preference.assignedAgentNames.isEmpty
        let hasSkillAssignments = !viewModel.appSettings.defaultSkillNames.isEmpty || !preference.assignedSkillNames.isEmpty
        let hasMcpAssignments = !viewModel.appSettings.defaultMcpServerNames.isEmpty || !preference.assignedMcpServerNames.isEmpty

        HStack(spacing: 10) {
            ProjectIconEditorButton(
                imageURL: project.iconFileURL,
                symbolName: project.fallbackSymbolName,
                size: 28,
                assetName: project.projectType.assetName,
                action: { viewModel.chooseCustomIcon(for: project) }
            )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(project.repositoryDisplayName)
                        .font(.subheadline.weight(.semibold))
                        .fontWidth(.expanded)
                        .lineLimit(1)

                    if shouldShowGitHubBadge(for: project) {
                        Image("github")
                            .resizable()
                            .renderingMode(.template)
                            .foregroundStyle(.secondary)
                            .frame(width: 12, height: 12)
                    }

                    if isActiveSessionProject {
                        AppLabelTag(text: LanguageStore.shared.t("projects.tag.active"), color: AppTheme.brandAccent)
                            .help(LanguageStore.shared.t("projects.activeSessionProject"))
                    }
                }

                Text(project.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(AppTheme.mutedText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Toggle(LanguageStore.shared.t("projects.filter.enabled"), isOn: Binding(
                get: { preference.isEnabled },
                set: { viewModel.setProjectEnabled($0, for: project) }
            ))
            .appSwitch()
            .labelsHidden()
            .help(preference.isEnabled ? LanguageStore.shared.t("projects.help.disable") : LanguageStore.shared.t("projects.help.enable"))

            Button {
                agentsRecapProject = project
            } label: {
                Image(systemName: "paperplane")
                    .foregroundStyle(hasAgentAssignments ? AppTheme.mutedText : AppTheme.mutedText.opacity(0.35))
                    .appActionTarget()
            }
            .buttonStyle(.plain)
            .disabled(!hasAgentAssignments)
            .help(hasAgentAssignments ? LanguageStore.shared.t("projects.help.showAgents") : LanguageStore.shared.t("projects.help.noAgents"))
            .accessibilityLabel(LanguageStore.shared.t("projects.showAgents", project.repositoryDisplayName))

            Button {
                skillsRecapProject = project
            } label: {
                Image(systemName: "wand.and.stars")
                    .foregroundStyle(hasSkillAssignments ? AppTheme.mutedText : AppTheme.mutedText.opacity(0.35))
                    .appActionTarget()
            }
            .buttonStyle(.plain)
            .disabled(!hasSkillAssignments)
            .help(hasSkillAssignments ? LanguageStore.shared.t("projects.help.showSkills") : LanguageStore.shared.t("projects.help.noSkills"))
            .accessibilityLabel(LanguageStore.shared.t("projects.showSkills", project.repositoryDisplayName))

            Button {
                mcpRecapProject = project
            } label: {
                Image(AppSymbols.mcp)
                    .resizable()
                    .renderingMode(.template)
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(hasMcpAssignments ? AppTheme.mutedText : AppTheme.mutedText.opacity(0.35))
                    .frame(width: 16, height: 16)
                    .appActionTarget()
            }
            .buttonStyle(.plain)
            .disabled(!hasMcpAssignments)
            .help(hasMcpAssignments ? LanguageStore.shared.t("projects.help.showMcp") : LanguageStore.shared.t("projects.help.noMcp"))
            .accessibilityLabel(LanguageStore.shared.t("projects.showMcp", project.repositoryDisplayName))

            Button {
                showProjectInFinder(project)
            } label: {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                    .appActionTarget()
            }
            .buttonStyle(.plain)
            .help(LanguageStore.shared.t("projects.showInFinder"))
            .accessibilityLabel(LanguageStore.shared.t("projects.showInFinderNamed", project.repositoryDisplayName))

            Button(role: .destructive) {
                showProjectRemovalConfirmation(for: project)
            } label: {
                Image(systemName: "eye.slash")
                    .foregroundStyle(.secondary)
                    .appActionTarget()
            }
            .buttonStyle(.plain)
            .help(LanguageStore.shared.t("projects.hideFromApp", AppBrand.displayName))
            .accessibilityLabel(LanguageStore.shared.t("projects.hideNamedFromApp", project.repositoryDisplayName, AppBrand.displayName))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AppTheme.contentFill)
                .stroke(AppTheme.contentStroke, lineWidth: 1)
        )
        .opacity(preference.isEnabled ? 1 : 0.58)
        .contextMenu {
            Button {
                showProjectInFinder(project)
            } label: {
                Label(LanguageStore.shared.t("projects.showInFinder"), systemImage: "folder")
            }

            Button(role: .destructive) {
                showProjectRemovalConfirmation(for: project)
            } label: {
                Label(LanguageStore.shared.t("projects.deleteProject"), systemImage: "trash")
            }
        }
    }
}

private struct ProjectRemovalConfirmationSheet: View {
    let project: DiscoveredProject
    @Binding var moveToTrash: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 6) {
                    Text(LanguageStore.shared.t("projects.removeProject"))
                        .font(.headline)
                        .fontWidth(.expanded)
                    Text(project.repositoryDisplayName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(project.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(AppTheme.mutedText)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }

            Text(LanguageStore.shared.t("projects.hideOnlyBody", AppBrand.displayName))
                .font(.callout)
                .foregroundStyle(AppTheme.mutedText)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(isOn: $moveToTrash) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(LanguageStore.shared.t("projects.moveToTrash"))
                        .font(.subheadline.weight(.semibold))
                    Text(LanguageStore.shared.t("projects.trashBody"))
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedText)
                }
            }
            .toggleStyle(.checkbox)

            HStack {
                Spacer()
                Button(LanguageStore.shared.t("common.cancel"), role: .cancel, action: onCancel)
                Button(moveToTrash ? LanguageStore.shared.t("projects.moveToTrashAction") : LanguageStore.shared.t("projects.hideFromList"), role: moveToTrash ? .destructive : nil, action: onConfirm)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

private struct ProjectAgentsRecapSheet: View {
    let project: DiscoveredProject
    let viewModel: AppViewModel
    @ObservedObject var imageStore: AgentImageStore

    @Environment(\.dismiss) private var dismiss

    private var recap: ProjectAgentRecap {
        viewModel.agentRecap(for: project)
    }

    private var hasLoadedProjectAssignments: Bool {
        viewModel.allProjectSnapshots[project.path] != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                ProjectIconView(imageURL: project.iconFileURL, symbolName: project.fallbackSymbolName, size: 34, assetName: project.projectType.assetName)

                VStack(alignment: .leading, spacing: 2) {
                    Text(LanguageStore.shared.t("projects.projectAgents"))
                        .font(.headline)
                        .fontWidth(.expanded)
                    Text(project.repositoryDisplayName)
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedText)
                        .lineLimit(1)
                }

                Spacer()

                Button(LanguageStore.shared.t("common.done")) {
                    dismiss()
                }
            }
            .padding(18)

            Divider()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    if hasResolvedAgents {
                        if !recap.defaultAgents.isEmpty {
                            agentRecapSection(title: LanguageStore.shared.t("projects.scope.global"), agents: recap.defaultAgents, color: .blue)
                        }
                        if !recap.projectAgents.isEmpty {
                            agentRecapSection(title: LanguageStore.shared.t("projects.scope.project"), agents: recap.projectAgents, color: .green)
                        }
                        if !recap.otherEffectiveAgents.isEmpty {
                            agentRecapSection(title: LanguageStore.shared.t("projects.scope.default"), agents: recap.otherEffectiveAgents, color: AppTheme.assistantAccent)
                        }
                    } else if hasLoadedProjectAssignments {
                        ContentUnavailableView(
                            LanguageStore.shared.t("projects.noAgentsTitle"),
                            systemImage: "paperplane",
                            description: Text(LanguageStore.shared.t("projects.noAgents"))
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                    } else {
                        loadingRow(LanguageStore.shared.t("projects.loadingAgents"))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 32)
                    }

                    if hasLoadedProjectAssignments, !recap.unresolvedNames.isEmpty {
                        unresolvedAgentSection
                    }
                }
                .padding(18)
            }
        }
        .frame(width: 560, height: 620)
        .task(id: project.path) {
            guard !hasLoadedProjectAssignments else { return }
            viewModel.refresh(
                includeModels: false,
                scanAllProjects: false,
                extraProjectPathsToScan: [project.path],
                silentlyReconcile: true
            )
        }
    }

    private var hasResolvedAgents: Bool {
        !recap.defaultAgents.isEmpty || !recap.projectAgents.isEmpty || !recap.otherEffectiveAgents.isEmpty
    }

    private func agentRecapSection(title: String, agents: [EffectiveAgentRecord], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .fontWidth(.expanded)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(agents) { agent in
                    HStack(alignment: .center, spacing: 10) {
                        AgentAvatarView(
                            imageURL: imageStore.imageURL(for: agent.name),
                            fallbackSystemImage: "paperplane",
                            color: agent.resolved.disabled == true ? .red : color,
                            size: 28
                        )

                        VStack(alignment: .leading, spacing: 3) {
                            Text(agent.name)
                                .font(.subheadline.weight(.semibold))
                                .strikethrough(agent.resolved.disabled == true, color: AppTheme.mutedText)
                            if !agent.resolved.description.isEmpty {
                                Text(agent.resolved.description)
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.mutedText)
                                    .lineLimit(2)
                            }
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppTheme.contentFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
    }

    private var unresolvedAgentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(LanguageStore.shared.t("projects.needsAttention"))
                .font(.headline)
                .fontWidth(.expanded)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(recap.unresolvedNames, id: \.self) { name in
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(name)
                            .font(.caption.weight(.semibold))
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.contentFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

private struct ProjectSkillsRecapSheet: View {
    let project: DiscoveredProject
    let viewModel: AppViewModel

    @Environment(\.dismiss) private var dismiss

    private var recap: ProjectSkillRecap {
        viewModel.skillRecap(for: project)
    }

    private var hasLoadedProjectAssignments: Bool {
        viewModel.allProjectSnapshots[project.path] != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                ProjectIconView(imageURL: project.iconFileURL, symbolName: project.fallbackSymbolName, size: 34, assetName: project.projectType.assetName)

                VStack(alignment: .leading, spacing: 2) {
                    Text(LanguageStore.shared.t("projects.projectSkills"))
                        .font(.headline)
                        .fontWidth(.expanded)
                    Text(project.repositoryDisplayName)
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedText)
                        .lineLimit(1)
                }

                Spacer()

                Button(LanguageStore.shared.t("common.done")) {
                    dismiss()
                }
            }
            .padding(18)

            Divider()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(LanguageStore.shared.t("projects.skillsPassHint"))
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)

                    if hasResolvedSkills {
                        if !recap.defaultSkills.isEmpty {
                            skillRecapSection(title: LanguageStore.shared.t("projects.scope.default"), skills: recap.defaultSkills, color: .blue)
                        }

                        if !recap.projectSkills.isEmpty {
                            skillRecapSection(title: LanguageStore.shared.t("projects.scope.project"), skills: recap.projectSkills, color: .green)
                        }
                    } else if hasLoadedProjectAssignments {
                        ContentUnavailableView(
                            LanguageStore.shared.t("projects.noSkillsTitle"),
                            systemImage: "wand.and.stars",
                            description: Text(LanguageStore.shared.t("projects.noSkills"))
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                    } else {
                        loadingRow(LanguageStore.shared.t("projects.loadingSkills"))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 32)
                    }

                    if hasLoadedProjectAssignments, !recap.unresolvedNames.isEmpty {
                        unresolvedSection
                    }
                }
                .padding(18)
            }
        }
        .frame(width: 520, height: 560)
        .task(id: project.path) {
            guard !hasLoadedProjectAssignments else { return }
            viewModel.refresh(
                includeModels: false,
                scanAllProjects: false,
                extraProjectPathsToScan: [project.path],
                silentlyReconcile: true
            )
        }
    }

    private var hasResolvedSkills: Bool {
        !recap.defaultSkills.isEmpty || !recap.projectSkills.isEmpty
    }

    private func skillRecapSection(title: String, skills: [SkillRecord], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .fontWidth(.expanded)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(skills, id: \.id) { skill in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "wand.and.stars")
                            .foregroundStyle(color)
                            .frame(width: 18)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(skill.name)
                                .font(.subheadline.weight(.semibold))
                            if let description = skill.description, !description.isEmpty {
                                Text(description)
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.mutedText)
                                    .lineLimit(2)
                            }
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppTheme.contentFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
    }

    private var unresolvedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(LanguageStore.shared.t("projects.needsAttention"))
                .font(.headline)
                .fontWidth(.expanded)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(recap.unresolvedNames, id: \.self) { name in
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(name)
                            .font(.caption.weight(.semibold))
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.contentFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

private struct ProjectMcpServersRecapSheet: View {
    let project: DiscoveredProject
    let viewModel: AppViewModel

    @Environment(\.dismiss) private var dismiss

    private var recap: ProjectMcpServerRecap {
        viewModel.mcpRecap(for: project)
    }

    private var hasLoadedProjectAssignments: Bool {
        viewModel.allProjectSnapshots[project.path] != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                ProjectIconView(imageURL: project.iconFileURL, symbolName: project.fallbackSymbolName, size: 34, assetName: project.projectType.assetName)

                VStack(alignment: .leading, spacing: 2) {
                    Text(LanguageStore.shared.t("projects.projectMcp"))
                        .font(.headline)
                        .fontWidth(.expanded)
                    Text(project.repositoryDisplayName)
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedText)
                        .lineLimit(1)
                }

                Spacer()

                Button(LanguageStore.shared.t("common.done")) {
                    dismiss()
                }
            }
            .padding(18)

            Divider()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(LanguageStore.shared.t("projects.mcpPassHint"))
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)

                    if recap.hasResolvedServers {
                        if !recap.defaultServers.isEmpty {
                            serverRecapSection(title: LanguageStore.shared.t("projects.scope.allProjects"), servers: recap.defaultServers, color: .blue)
                        }

                        if !recap.projectServers.isEmpty {
                            serverRecapSection(title: LanguageStore.shared.t("projects.scope.project"), servers: recap.projectServers, color: .green)
                        }
                    } else if hasLoadedProjectAssignments {
                        ContentUnavailableView {
                            Label {
                                Text(LanguageStore.shared.t("projects.noMcpTitle"))
                            } icon: {
                                Image(AppSymbols.mcp)
                            }
                        } description: {
                            Text(LanguageStore.shared.t("projects.noMcpBody"))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                    } else {
                        loadingRow(LanguageStore.shared.t("projects.loadingMcp"))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 32)
                    }

                    if hasLoadedProjectAssignments, !recap.unresolvedNames.isEmpty {
                        unresolvedSection
                    }
                }
                .padding(18)
            }
        }
        .frame(width: 520, height: 560)
        .task(id: project.path) {
            guard !hasLoadedProjectAssignments else { return }
            viewModel.refresh(
                includeModels: false,
                scanAllProjects: false,
                extraProjectPathsToScan: [project.path],
                silentlyReconcile: true
            )
        }
    }

    private func serverRecapSection(title: String, servers: [MCPServerRecapItem], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .fontWidth(.expanded)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(servers) { server in
                    HStack(alignment: .top, spacing: 10) {
                        Image(AppSymbols.mcp)
                            .resizable()
                            .renderingMode(.template)
                            .aspectRatio(contentMode: .fit)
                            .foregroundStyle(color)
                            .frame(width: 16, height: 16)
                            .frame(width: 18)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(server.name)
                                .font(.subheadline.weight(.semibold))
                            if let detail = server.detail, !detail.isEmpty {
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.mutedText)
                                    .lineLimit(1)
                            }
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppTheme.contentFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
    }

    private var unresolvedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(LanguageStore.shared.t("projects.needsAttention"))
                .font(.headline)
                .fontWidth(.expanded)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(recap.unresolvedNames, id: \.self) { name in
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(name)
                            .font(.caption.weight(.semibold))
                        Spacer(minLength: 0)
                        Text(LanguageStore.shared.t("projects.notInMcpJson"))
                            .font(AppTheme.Font.micro)
                            .foregroundStyle(AppTheme.mutedText)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.contentFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}
