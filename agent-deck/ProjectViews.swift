import AppKit
import SwiftUI

struct ProjectAssignmentToggleRow: View {
    let project: DiscoveredProject
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Toggle("", isOn: $isOn)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .controlSize(.regular)
                .frame(width: 18)

            ProjectIconView(imageURL: project.iconFileURL, symbolName: project.fallbackSymbolName, size: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text(project.name)
                    .font(.body.weight(.semibold))
                Text(project.repositoryName ?? project.path)
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)
        }
        .frame(minHeight: 46, alignment: .center)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            isOn.toggle()
        }
    }
}

struct SearchFieldWithProgress: View {
    let placeholder: String
    @Binding var text: String
    let isLoading: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
            .overlay(alignment: .trailing) {
                if isLoading {
                    ProgressView()
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
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                ProjectIconView(imageURL: imageURL, symbolName: symbolName, size: size)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isHovering ? Color.black.opacity(0.18) : .clear)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(isHovering ? Color.accentColor.opacity(0.9) : AppTheme.contentStroke, lineWidth: isHovering ? 2 : 1)
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
        .help(imageURL == nil ? "Set custom icon" : "Change custom icon")
    }
}

struct ProjectIconView: View {
    let imageURL: URL?
    let symbolName: String
    let size: CGFloat

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
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
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppTheme.contentSubtleFill)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task(id: imageURL?.path) {
            await loadImage()
        }
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

private actor ProjectIconCache {
    static let shared = ProjectIconCache()

    private let cache = NSCache<NSString, NSImage>()

    func cachedImage(for url: URL) -> NSImage? {
        cache.object(forKey: url.path as NSString)
    }

    func loadImage(for url: URL) async -> NSImage? {
        if let cachedImage = cache.object(forKey: url.path as NSString) {
            return cachedImage
        }

        let image = await Task.detached(priority: .utility) {
            NSImage(contentsOf: url)
        }.value

        if let image {
            cache.setObject(image, forKey: url.path as NSString)
        }

        return image
    }
}

struct ProjectsScreen: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case enabled = "Enabled"
        case disabled = "Disabled"
        case favorites = "Favorites"

        var id: String { rawValue }
    }

    @ObservedObject var viewModel: AppViewModel
    @State private var filter: Filter = .all
    @State private var searchText = ""
    @State private var debouncedSearchText = ""

    var body: some View {
        AppPage("Projects", subtitle: "Showing projects from \(viewModel.configuredProjectsRootPath)") {
            AppCard(title: "Library") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        SearchFieldWithProgress(
                            placeholder: "Search projects",
                            text: $searchText,
                            isLoading: isSearchDebouncing
                        )

                        Picker("Filter", selection: $filter) {
                            ForEach(Filter.allCases) { option in
                                Text(option.rawValue).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 320)
                    }

                    if viewModel.discoveredProjects.isEmpty {
                        ContentUnavailableView(
                            "No Projects Yet",
                            systemImage: "folder",
                            description: Text("Projects from \(viewModel.configuredProjectsRootPath) will appear here automatically.")
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    } else if visibleProjects.isEmpty {
                        ContentUnavailableView(
                            "No Matching Projects",
                            systemImage: "magnifyingglass",
                            description: Text("Try another search or filter.")
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
        }
        .task(id: searchText) {
            let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            debouncedSearchText = trimmed.lowercased()
        }
    }

    private var isSearchDebouncing: Bool {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != debouncedSearchText
    }

    private var visibleProjects: [DiscoveredProject] {
        let query = debouncedSearchText

        return viewModel.discoveredProjects.filter { project in
            let preference = viewModel.projectPreference(for: project.path)

            let matchesFilter: Bool = switch filter {
            case .all: true
            case .enabled: preference.isEnabled
            case .disabled: !preference.isEnabled
            case .favorites: preference.isFavorite
            }

            guard matchesFilter else { return false }
            guard !query.isEmpty else { return true }
            return project.searchIndex.contains(query)
        }
    }

    @ViewBuilder
    private func projectRow(_ project: DiscoveredProject) -> some View {
        let preference = viewModel.projectPreference(for: project.path)
        let isSelected = viewModel.selectedProjectPath == project.path

        HStack(spacing: 10) {
                ProjectIconEditorButton(
                    imageURL: project.iconFileURL,
                    symbolName: project.fallbackSymbolName,
                    size: 28,
                    action: { viewModel.chooseCustomIcon(for: project) }
                )

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(project.repositoryDisplayName)
                            .font(.subheadline.weight(.semibold))
                            .fontWidth(.expanded)
                            .lineLimit(1)

                        if project.isGitHubRepository {
                            Image("github")
                                .resizable()
                                .renderingMode(.template)
                                .foregroundStyle(.secondary)
                                .frame(width: 12, height: 12)
                        }

                        if isSelected {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 8, height: 8)
                                .help("Active project")
                        }
                    }

                    Text(project.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(AppTheme.mutedText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                Toggle("Enabled", isOn: Binding(
                    get: { preference.isEnabled },
                    set: { viewModel.setProjectEnabled($0, for: project) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .help(preference.isEnabled ? "Disable project" : "Enable project")

                Button {
                    viewModel.toggleProjectFavorite(project)
                } label: {
                    Image(systemName: preference.isFavorite ? "star.fill" : "star")
                        .foregroundStyle(preference.isFavorite ? .yellow : AppTheme.mutedText)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help(preference.isFavorite ? "Remove favorite" : "Add favorite")

                Button(role: .destructive) {
                    viewModel.removeProjectFromLibrary(project)
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help("Remove from \(AppBrand.displayName)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.08) : AppTheme.contentFill)
                    .stroke(isSelected ? Color.accentColor.opacity(0.28) : AppTheme.contentStroke, lineWidth: 1)
            )
            .opacity(preference.isEnabled ? 1 : 0.58)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture {
            guard preference.isEnabled else { return }
            if isSelected {
                viewModel.clearProjectRoot()
            } else {
                viewModel.setSelectedProject(project.url)
            }
        }
    }
}

