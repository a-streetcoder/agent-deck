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
    @State private var filter: Filter = .enabled
    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var selectedInstructionProjectPath: String?
    @State private var skillsRecapProject: DiscoveredProject?

    var body: some View {
        HSplitView {
            ScrollView(showsIndicators: false) {
                AppCard(title: "Library") {
                    projectList
                }
                .padding(AppTheme.pagePadding)
            }
            .frame(minWidth: 460, idealWidth: 540, maxWidth: 700)

            PiSystemInstructionsProjectDetail(
                project: selectedInstructionProject,
                includesNativeSubagentCatalog: viewModel.areSubagentsEnabledForNewSessions
            )
                .frame(minWidth: 420)
        }
        .task(id: searchText) {
            let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            debouncedSearchText = trimmed.lowercased()
        }
        .onAppear(perform: ensureInstructionSelection)
        .onChange(of: visibleProjects.map(\.path)) { _, _ in
            ensureInstructionSelection()
        }
        .sheet(item: $skillsRecapProject) { project in
            ProjectSkillsRecapSheet(
                project: project,
                recap: viewModel.skillRecap(for: project)
            )
        }
    }

    private var projectList: some View {
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
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)
            }

            Text("Select a project here to inspect and edit its Pi instruction files. This no longer changes the active project used by sessions.")
                .font(.caption)
                .foregroundStyle(AppTheme.mutedText)
                .fixedSize(horizontal: false, vertical: true)

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
                        projectRow(project, isInstructionSelected: selectedInstructionPath == project.path)
                    }
                }
            }
        }
    }

    private var selectedInstructionPath: String? {
        if let selectedInstructionProjectPath,
           viewModel.discoveredProjects.contains(where: { $0.path == selectedInstructionProjectPath }) {
            return selectedInstructionProjectPath
        }
        return visibleProjects.first?.path
    }

    private var selectedInstructionProject: DiscoveredProject? {
        guard let selectedInstructionPath else { return nil }
        return viewModel.discoveredProjects.first { $0.path == selectedInstructionPath }
    }

    private var isSearchDebouncing: Bool {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != debouncedSearchText
    }

    private var visibleProjects: [DiscoveredProject] {
        let query = debouncedSearchText
        let effectiveFilter: Filter = (!hasEnabledProjects && filter == .enabled) ? .all : filter

        return viewModel.discoveredProjects.filter { project in
            let preference = viewModel.projectPreference(for: project.path)

            let matchesFilter: Bool = switch effectiveFilter {
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

    private var hasEnabledProjects: Bool {
        viewModel.discoveredProjects.contains { project in
            viewModel.projectPreference(for: project.path).isEnabled
        }
    }

    private func ensureInstructionSelection() {
        let visiblePaths = visibleProjects.map(\.path)
        guard !visiblePaths.isEmpty else {
            selectedInstructionProjectPath = nil
            return
        }

        if let selectedInstructionProjectPath, visiblePaths.contains(selectedInstructionProjectPath) {
            return
        }

        selectedInstructionProjectPath = visiblePaths.first
    }

    @ViewBuilder
    private func projectRow(_ project: DiscoveredProject, isInstructionSelected: Bool) -> some View {
        let preference = viewModel.projectPreference(for: project.path)
        let isActiveSessionProject = viewModel.selectedProjectPath == project.path

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

                    if isActiveSessionProject {
                        AppLabelTag(text: "Active", color: AppTheme.brandAccent)
                            .help("Active session project")
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

            Button {
                skillsRecapProject = project
            } label: {
                Image(systemName: "wand.and.stars")
                    .foregroundStyle(AppTheme.mutedText)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help("Show skills for this project")

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
                .fill(isInstructionSelected ? AppTheme.selectionFill : AppTheme.contentFill)
                .stroke(isInstructionSelected ? AppTheme.selectionStroke : AppTheme.contentStroke, lineWidth: 1)
        )
        .opacity(preference.isEnabled ? 1 : 0.58)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture {
            selectedInstructionProjectPath = project.path
        }
    }
}

private struct PiSystemInstructionsProjectDetail: View {
    let project: DiscoveredProject?
    let includesNativeSubagentCatalog: Bool

    @State private var drafts: [String: String] = [:]
    @State private var originals: [String: String] = [:]
    @State private var existingPaths: Set<String> = []
    @State private var statusMessage: String?
    @State private var isInfoPresented = false
    @State private var isPreviewPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, AppTheme.pagePadding)
                .padding(.top, AppTheme.pagePadding)
                .padding(.bottom, 12)

            Divider()

            if let project {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
                        if let statusMessage {
                            Text(statusMessage)
                                .font(.caption)
                                .foregroundStyle(AppTheme.mutedText)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .appControlSurface(cornerRadius: 10)
                        }

                        instructionSection(
                            title: "Base system prompt",
                            description: "Pi uses the first existing source in this group: project `.pi/SYSTEM.md`, then global `~/.pi/agent/SYSTEM.md`, then the built-in Pi prompt.",
                            files: files(for: .base)
                        )

                        instructionSection(
                            title: "Append system prompt",
                            description: "Pi appends one file from this group: project `.pi/APPEND_SYSTEM.md` if it exists, otherwise global `~/.pi/agent/APPEND_SYSTEM.md`. When Agent Deck adds parent append content, this active file is preserved first.",
                            files: files(for: .append)
                        )

                        instructionSection(
                            title: "Context files",
                            description: "Pi appends the global context file, then one `AGENTS.md`/`CLAUDE.md` file per ancestor/current directory. Within a directory, `AGENTS.md` wins over `CLAUDE.md`.",
                            files: files(for: .context)
                        )
                    }
                    .padding(AppTheme.pagePadding)
                }
                .sheet(isPresented: $isPreviewPresented) {
                    PiSystemPromptPreviewSheet(project: project, preview: previewText(for: project))
                }
                .task(id: project.path) {
                    loadFiles(for: project)
                }
            } else {
                ContentUnavailableView(
                    "Select a Project",
                    systemImage: "folder.badge.gearshape",
                    description: Text("Choose a project on the left to inspect its customizable Pi instruction components.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            if let project {
                ProjectIconView(imageURL: project.iconFileURL, symbolName: project.fallbackSymbolName, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("System Instructions")
                        .font(.headline)
                        .fontWidth(.expanded)
                    Text(project.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(AppTheme.mutedText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else {
                Text("System Instructions")
                    .font(.headline)
                    .fontWidth(.expanded)
            }

            Spacer()

            Button {
                isInfoPresented.toggle()
            } label: {
                Label("Info", systemImage: "info.circle")
                    .labelStyle(.iconOnly)
            }
            .popover(isPresented: $isInfoPresented, arrowEdge: .bottom) {
                PiSystemInstructionsInfoPopover()
            }
            .help("Explain Pi instruction assembly")

            Button {
                isPreviewPresented = true
            } label: {
                Label("Preview", systemImage: "doc.text.magnifyingglass")
            }
            .disabled(project == nil)
            .help("Preview the effective prompt from the current editor contents")
        }
    }

    private var instructionFiles: [PiInstructionFile] {
        guard let project else { return [] }
        return PiInstructionFile.catalog(for: project.url, existingPaths: existingPaths)
    }

    private func files(for role: PiInstructionFile.Role) -> [PiInstructionFile] {
        instructionFiles.filter { $0.role == role }
    }

    private func instructionSection(title: String, description: String, files: [PiInstructionFile]) -> some View {
        AppCard(title: title) {
            VStack(alignment: .leading, spacing: 12) {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(files) { file in
                    PiInstructionFileEditor(
                        file: file,
                        text: Binding(
                            get: { drafts[file.id, default: ""] },
                            set: { drafts[file.id] = $0 }
                        ),
                        isDirty: drafts[file.id, default: ""] != originals[file.id, default: ""],
                        save: { save(file) },
                        revealInFinder: { revealInFinder(file) }
                    )
                }
            }
        }
    }

    private func loadFiles(for project: DiscoveredProject) {
        let discoveredExistingPaths = PiInstructionFile.discoverExistingPaths(for: project.url)
        let files = PiInstructionFile.catalog(for: project.url, existingPaths: discoveredExistingPaths)
        var loadedDrafts: [String: String] = [:]
        var loadedOriginals: [String: String] = [:]

        for file in files {
            let content = (try? String(contentsOf: file.url, encoding: .utf8)) ?? ""
            loadedDrafts[file.id] = content
            loadedOriginals[file.id] = content
        }

        existingPaths = discoveredExistingPaths
        drafts = loadedDrafts
        originals = loadedOriginals
        statusMessage = nil
    }

    private func save(_ file: PiInstructionFile) {
        do {
            try FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let text = drafts[file.id, default: ""]
            try text.write(to: file.url, atomically: true, encoding: .utf8)
            originals[file.id] = text
            existingPaths.insert(file.id)
            statusMessage = "Saved \(file.displayPath)."
        } catch {
            statusMessage = "Could not save \(file.displayPath): \(error.localizedDescription)"
        }
    }

    private func revealInFinder(_ file: PiInstructionFile) {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: file.url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([file.url])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([file.url.deletingLastPathComponent()])
        }
    }

    private func previewText(for project: DiscoveredProject) -> String {
        PiInstructionPreviewBuilder.preview(
            projectURL: project.url,
            existingPaths: existingPaths,
            drafts: drafts,
            includesNativeSubagentCatalog: includesNativeSubagentCatalog
        )
    }
}

private struct PiInstructionFileEditor: View {
    let file: PiInstructionFile
    @Binding var text: String
    let isDirty: Bool
    let save: () -> Void
    let revealInFinder: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(file.title)
                            .font(.subheadline.weight(.semibold))
                            .fontWidth(.expanded)
                        statusBadge
                    }
                    Text(file.displayPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(AppTheme.mutedText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                Button("Save") { save() }
                    .controlSize(.small)
                    .opacity(isDirty ? 1 : 0)
                    .disabled(!isDirty)
                    .accessibilityHidden(!isDirty)

                Button { revealInFinder() } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.plain)
                .controlSize(.small)
                .help(file.exists ? "Reveal in Finder" : "Reveal parent folder in Finder")
            }

            Text(file.note)
                .font(.caption)
                .foregroundStyle(AppTheme.mutedText)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $text)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: file.role == .context ? 120 : 96)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(AppTheme.contentSubtleFill)
                        .stroke(AppTheme.contentStroke, lineWidth: 1)
                )
        }
        .padding(12)
        .appPanelSurface(cornerRadius: 12)
    }

    private var statusBadge: some View {
        Text(file.status.label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(file.status.color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(file.status.color.opacity(0.12)))
    }
}

private struct PiSystemInstructionsInfoPopover: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pi instruction assembly")
                .font(.headline)
                .fontWidth(.expanded)

            VStack(alignment: .leading, spacing: 10) {
                infoRow("Base prompt", "Project `.pi/SYSTEM.md` replaces the base prompt. If it does not exist, Pi uses global `~/.pi/agent/SYSTEM.md`; otherwise it uses the built-in Pi prompt.")
                infoRow("Append prompt", "Without explicit append values, Pi uses one file: project `.pi/APPEND_SYSTEM.md`, then global `~/.pi/agent/APPEND_SYSTEM.md`. When Agent Deck adds parent append content, it explicitly preserves that active file first and then stacks its own append prompt.")
                infoRow("Context files", "Pi loads one global `AGENTS.md`/`CLAUDE.md`, then walks from filesystem root to the project directory. In each directory, `AGENTS.md` wins over `CLAUDE.md`.")
                infoRow("Runtime pieces", "Tools, extension prompt changes, skill catalogs, date, and working directory are runtime-specific. The preview includes placeholders where Agent Deck cannot know the exact Pi runtime text.")
            }
        }
        .padding(16)
        .frame(width: 420, alignment: .leading)
    }

    private func infoRow(_ title: String, _ description: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .fontWidth(.expanded)
            Text(description)
                .font(.caption)
                .foregroundStyle(AppTheme.mutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct PiSystemPromptPreviewSheet: View {
    let project: DiscoveredProject
    let preview: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("System Prompt Preview")
                        .font(.headline)
                        .fontWidth(.expanded)
                    Text(project.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(AppTheme.mutedText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(16)

            Divider()

            ScrollView {
                Text(preview)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
        .frame(minWidth: 760, minHeight: 620)
    }
}

private struct ProjectSkillsRecapSheet: View {
    let project: DiscoveredProject
    let recap: ProjectSkillRecap

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                ProjectIconView(imageURL: project.iconFileURL, symbolName: project.fallbackSymbolName, size: 34)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Project Skills")
                        .font(.headline)
                        .fontWidth(.expanded)
                    Text(project.repositoryDisplayName)
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedText)
                        .lineLimit(1)
                }

                Spacer()

                Button("Done") {
                    dismiss()
                }
            }
            .padding(18)

            Divider()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("These are the skills Agent Deck will pass to parent Pi sessions for this project with explicit --skill arguments.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)

                    if hasResolvedSkills {
                        if !recap.defaultSkills.isEmpty {
                            skillRecapSection(title: "Default", skills: recap.defaultSkills, color: .blue)
                        }

                        if !recap.projectSkills.isEmpty {
                            skillRecapSection(title: "Project", skills: recap.projectSkills, color: .green)
                        }
                    } else {
                        ContentUnavailableView(
                            "No Skills",
                            systemImage: "wand.and.stars",
                            description: Text("No default or project-assigned skills are configured for this project.")
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                    }

                    if !recap.unresolvedNames.isEmpty {
                        unresolvedSection
                    }
                }
                .padding(18)
            }
        }
        .frame(width: 520, height: 560)
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
            Text("Needs Attention")
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

private struct PiInstructionFile: Identifiable, Hashable {
    enum Role: String {
        case base
        case append
        case context
    }

    enum Status: Hashable {
        case active
        case shadowed
        case available

        var label: String {
            switch self {
            case .active: "Active"
            case .shadowed: "Shadowed"
            case .available: "Available"
            }
        }

        var color: Color {
            switch self {
            case .active: .green
            case .shadowed: .orange
            case .available: AppTheme.mutedText
            }
        }
    }

    let url: URL
    let role: Role
    let title: String
    let note: String
    let status: Status
    let exists: Bool

    var id: String { url.path }
    var displayPath: String { url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }

    static func catalog(for projectURL: URL, existingPaths: Set<String>) -> [PiInstructionFile] {
        let projectURL = projectURL.standardizedFileURL
        let globalDir = globalAgentDirectory
        let projectPiDir = projectURL.appendingPathComponent(".pi", isDirectory: true)
        let projectSystem = projectPiDir.appendingPathComponent("SYSTEM.md")
        let globalSystem = globalDir.appendingPathComponent("SYSTEM.md")
        let activeSystem = existingPaths.contains(projectSystem.path) ? projectSystem.path : (existingPaths.contains(globalSystem.path) ? globalSystem.path : nil)

        let projectAppend = projectPiDir.appendingPathComponent("APPEND_SYSTEM.md")
        let globalAppend = globalDir.appendingPathComponent("APPEND_SYSTEM.md")
        let activeAppend = existingPaths.contains(projectAppend.path) ? projectAppend.path : (existingPaths.contains(globalAppend.path) ? globalAppend.path : nil)

        var files: [PiInstructionFile] = [
            PiInstructionFile(
                url: projectSystem,
                role: .base,
                title: "Project SYSTEM.md",
                note: "Project-local replacement for the Pi base prompt. If this file exists, it wins over the global SYSTEM.md and the built-in Pi prompt.",
                status: status(for: projectSystem.path, activePath: activeSystem, existingPaths: existingPaths),
                exists: existingPaths.contains(projectSystem.path)
            ),
            PiInstructionFile(
                url: globalSystem,
                role: .base,
                title: "Global SYSTEM.md",
                note: "Global replacement for the Pi base prompt. Used only when this project does not have `.pi/SYSTEM.md`.",
                status: status(for: globalSystem.path, activePath: activeSystem, existingPaths: existingPaths),
                exists: existingPaths.contains(globalSystem.path)
            ),
            PiInstructionFile(
                url: projectAppend,
                role: .append,
                title: "Project APPEND_SYSTEM.md",
                note: "Project-local append prompt. If this file exists, Pi uses it instead of the global append file.",
                status: status(for: projectAppend.path, activePath: activeAppend, existingPaths: existingPaths),
                exists: existingPaths.contains(projectAppend.path)
            ),
            PiInstructionFile(
                url: globalAppend,
                role: .append,
                title: "Global APPEND_SYSTEM.md",
                note: "Global append prompt. Used only when this project does not have `.pi/APPEND_SYSTEM.md`.",
                status: status(for: globalAppend.path, activePath: activeAppend, existingPaths: existingPaths),
                exists: existingPaths.contains(globalAppend.path)
            )
        ]

        files.append(contentsOf: contextFiles(for: projectURL, existingPaths: existingPaths))
        return files
    }

    static func discoverExistingPaths(for projectURL: URL) -> Set<String> {
        let projectURL = projectURL.standardizedFileURL
        let globalDir = globalAgentDirectory
        let projectPiDir = projectURL.appendingPathComponent(".pi", isDirectory: true)
        let fileManager = FileManager.default
        var paths = Set<String>()

        [
            projectPiDir.appendingPathComponent("SYSTEM.md"),
            globalDir.appendingPathComponent("SYSTEM.md"),
            projectPiDir.appendingPathComponent("APPEND_SYSTEM.md"),
            globalDir.appendingPathComponent("APPEND_SYSTEM.md")
        ].forEach { url in
            if fileManager.fileExists(atPath: url.path) { paths.insert(url.path) }
        }

        for directory in [globalDir] + contextDirectories(for: projectURL) {
            for filename in contextCandidateNames {
                let url = directory.appendingPathComponent(filename)
                if fileManager.fileExists(atPath: url.path) {
                    paths.insert(url.path)
                }
            }
        }

        return paths
    }

    static func activeContextFiles(for projectURL: URL, existingPaths: Set<String>) -> [URL] {
        let directories = [globalAgentDirectory] + contextDirectories(for: projectURL.standardizedFileURL)
        var seenPaths = Set<String>()
        return directories.compactMap { directory in
            guard let url = activeContextFile(in: directory, existingPaths: existingPaths), seenPaths.insert(url.path).inserted else {
                return nil
            }
            return url
        }
    }

    private static func contextFiles(for projectURL: URL, existingPaths: Set<String>) -> [PiInstructionFile] {
        let globalDir = globalAgentDirectory
        var files: [PiInstructionFile] = []
        var addedPaths = Set<String>()

        func appendContextCandidate(url: URL, title: String, note: String, activePath: String?) {
            guard addedPaths.insert(url.path).inserted else { return }
            files.append(PiInstructionFile(
                url: url,
                role: .context,
                title: title,
                note: note,
                status: status(for: url.path, activePath: activePath, existingPaths: existingPaths),
                exists: existingPaths.contains(url.path)
            ))
        }

        let globalActive = activeContextFile(in: globalDir, existingPaths: existingPaths)?.path
        appendContextCandidate(
            url: globalDir.appendingPathComponent("AGENTS.md"),
            title: "Global AGENTS.md",
            note: "Global context loaded for every Pi session unless context files are disabled.",
            activePath: globalActive
        )
        appendContextCandidate(
            url: globalDir.appendingPathComponent("CLAUDE.md"),
            title: "Global CLAUDE.md",
            note: "Fallback global context. It is shadowed when global AGENTS.md exists.",
            activePath: globalActive
        )
        for filename in ["AGENTS.MD", "CLAUDE.MD"] {
            let url = globalDir.appendingPathComponent(filename)
            if existingPaths.contains(url.path) {
                appendContextCandidate(
                    url: url,
                    title: "Global \(filename)",
                    note: "Existing global context file using uppercase extension. Pi recognizes it during context discovery.",
                    activePath: globalActive
                )
            }
        }

        for directory in contextDirectories(for: projectURL) {
            let activePath = activeContextFile(in: directory, existingPaths: existingPaths)?.path
            let isProjectDirectory = directory.standardizedFileURL.path == projectURL.standardizedFileURL.path
            let relativeTitle = contextDirectoryTitle(directory, projectURL: projectURL)

            if isProjectDirectory || existingPaths.contains(directory.appendingPathComponent("AGENTS.md").path) {
                appendContextCandidate(
                    url: directory.appendingPathComponent("AGENTS.md"),
                    title: "\(relativeTitle) AGENTS.md",
                    note: isProjectDirectory ? "Project context for this repository. Preferred over CLAUDE.md in the same directory." : "Ancestor context loaded before the project directory context.",
                    activePath: activePath
                )
            }

            if isProjectDirectory || existingPaths.contains(directory.appendingPathComponent("CLAUDE.md").path) {
                appendContextCandidate(
                    url: directory.appendingPathComponent("CLAUDE.md"),
                    title: "\(relativeTitle) CLAUDE.md",
                    note: isProjectDirectory ? "Project fallback context. Shadowed when project AGENTS.md exists." : "Ancestor fallback context. Shadowed when AGENTS.md exists in the same directory.",
                    activePath: activePath
                )
            }

            for filename in ["AGENTS.MD", "CLAUDE.MD"] {
                let url = directory.appendingPathComponent(filename)
                if existingPaths.contains(url.path) {
                    appendContextCandidate(
                        url: url,
                        title: "\(relativeTitle) \(filename)",
                        note: "Existing context file using uppercase extension. Pi recognizes it during context discovery.",
                        activePath: activePath
                    )
                }
            }
        }

        return files
    }

    private static var globalAgentDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
            .standardizedFileURL
    }

    private static let contextCandidateNames = ["AGENTS.md", "AGENTS.MD", "CLAUDE.md", "CLAUDE.MD"]

    private static func activeContextFile(in directory: URL, existingPaths: Set<String>) -> URL? {
        for filename in contextCandidateNames {
            let url = directory.appendingPathComponent(filename)
            if existingPaths.contains(url.path) { return url }
        }
        return nil
    }

    private static func status(for path: String, activePath: String?, existingPaths: Set<String>) -> Status {
        if activePath == path { return .active }
        if existingPaths.contains(path) { return .shadowed }
        return .available
    }

    private static func contextDirectories(for projectURL: URL) -> [URL] {
        var directories: [URL] = []
        var current = projectURL.standardizedFileURL
        let root = URL(fileURLWithPath: "/", isDirectory: true).standardizedFileURL.path

        while true {
            directories.insert(current, at: 0)
            if current.path == root { break }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent.path == current.path { break }
            current = parent
        }

        return directories
    }

    private static func contextDirectoryTitle(_ directory: URL, projectURL: URL) -> String {
        let directoryPath = directory.standardizedFileURL.path
        let projectPath = projectURL.standardizedFileURL.path
        if directoryPath == projectPath { return "Project" }
        return "Ancestor \(directory.lastPathComponent.nonEmpty ?? directoryPath)"
    }
}

private enum PiInstructionPreviewBuilder {
    static func preview(projectURL: URL, existingPaths: Set<String>, drafts: [String: String], includesNativeSubagentCatalog: Bool = false) -> String {
        let projectURL = projectURL.standardizedFileURL
        let draftedNewPaths = drafts.compactMap { path, content in
            existingPaths.contains(path) || content.isEmpty ? nil : path
        }
        let previewExistingPaths = existingPaths.union(draftedNewPaths)
        let catalog = PiInstructionFile.catalog(for: projectURL, existingPaths: previewExistingPaths)
        var prompt: String

        if let baseFile = catalog.first(where: { $0.role == .base && $0.status == .active }) {
            prompt = content(for: baseFile.url, drafts: drafts)
        } else {
            prompt = """
            [PI BUILT-IN DEFAULT SYSTEM PROMPT]
            [Pi tool-aware guidance is generated at runtime when the built-in prompt is used.]
            """
        }

        if let appendFile = catalog.first(where: { $0.role == .append && $0.status == .active }) {
            prompt += "\n\n\(content(for: appendFile.url, drafts: drafts))"
        }

        if includesNativeSubagentCatalog {
            prompt += "\n\n[AGENT DECK NATIVE SUBAGENT CATALOG]"
        }

        let contextFiles = PiInstructionFile.activeContextFiles(for: projectURL, existingPaths: previewExistingPaths)
        if !contextFiles.isEmpty {
            prompt += "\n\n# Project Context\n\nProject-specific instructions and guidelines:\n\n"
            for url in contextFiles {
                prompt += "## \(url.path)\n\n\(content(for: url, drafts: drafts))\n\n"
            }
        }

        prompt += """

        [PI SKILL CATALOG, if skills are enabled and the read tool is available]
        Current date: \(currentDateString())
        Current working directory: \(projectURL.path)
        """

        return prompt
    }

    private static func content(for url: URL, drafts: [String: String]) -> String {
        drafts[url.path] ?? (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private static let currentDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static func currentDateString() -> String {
        currentDateFormatter.string(from: Date())
    }
}
