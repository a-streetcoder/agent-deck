import AppKit
import ImageIO
import SwiftUI

struct ProjectAssignmentToggleRow: View {
    let project: DiscoveredProject
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Toggle("", isOn: $isOn)
                .appCheckbox()
                .labelsHidden()
                .controlSize(.regular)
                .frame(width: 18)
                // The whole row is the tap target (`.onTapGesture` below). The
                // checkbox is a visual indicator only — if it also handled
                // clicks, clicking the box itself would fire both handlers and
                // toggle twice (the "selected then unselected" flicker).
                .allowsHitTesting(false)

            ProjectIconView(imageURL: project.iconFileURL, symbolName: project.fallbackSymbolName, size: 30, assetName: project.projectType.assetName)

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

/// Row that mirrors `ProjectAssignmentToggleRow` but represents the
/// "enable for every project" shortcut — same icon and copy as the sidebar's
/// All Projects entry.
struct AllProjectsAssignmentRow: View {
    @Binding var isOn: Bool
    var subtitle: String = "Enable this agent for every project"

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Toggle("", isOn: $isOn)
                .appCheckbox()
                .labelsHidden()
                .controlSize(.regular)
                .frame(width: 18)
                .allowsHitTesting(false)

            ProjectIconView(imageURL: nil, symbolName: "square.grid.2x2", size: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text("All Projects")
                    .font(.body.weight(.semibold))
                Text(subtitle)
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
        .help(imageURL == nil ? "Set custom icon" : "Change custom icon")
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

struct SystemInstructionsScreen: View {
    var viewModel: AppViewModel

    var body: some View {
        if let project = viewModel.selectedDiscoveredProject {
            PiSystemInstructionsProjectDetail(
                project: project,
                includesNativeSubagentCatalog: viewModel.areSubagentsEnabledForNewSessions
            )
        } else {
            AppPage("System Prompt", subtitle: "Select a project to manage its effective prompt") {
                AppCard() {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Choose a project from the sidebar", systemImage: "folder.badge.gearshape")
                            .font(.headline)
                            .fontWidth(.expanded)
                        Text("The System Prompt view is project-scoped. Once a project is active, you can manage the project files and the global fallback files that contribute to that project’s effective prompt.")
                            .foregroundStyle(AppTheme.mutedText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

private final class PiInstructionDraftCache {
    static var draftsByScope: [String: [String: String]] = [:]
    static var originalsByScope: [String: [String: String]] = [:]
    static var existingPathsByScope: [String: Set<String>] = [:]

    static func store(scope: String, drafts: [String: String], originals: [String: String], existingPaths: Set<String>) {
        draftsByScope[scope] = drafts
        originalsByScope[scope] = originals
        existingPathsByScope[scope] = existingPaths
    }

    static func cached(scope: String) -> (drafts: [String: String], originals: [String: String], existingPaths: Set<String>)? {
        guard let drafts = draftsByScope[scope], let originals = originalsByScope[scope], let existingPaths = existingPathsByScope[scope] else { return nil }
        return (drafts, originals, existingPaths)
    }
}

private struct PiGlobalSystemInstructionsDetail: View {
    @State private var drafts: [String: String] = [:]
    @State private var originals: [String: String] = [:]
    @State private var existingPaths: Set<String> = []
    @State private var statusMessage: String?
    @State private var isInfoPresented = false
    @State private var isPreviewPresented = false

    private var isDirty: Bool {
        drafts.contains { path, text in text != originals[path, default: ""] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, AppTheme.pagePadding)
                .padding(.top, AppTheme.pagePadding)
                .padding(.bottom, 12)

            Divider()

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



                    scopeCard

                    instructionSection(
                        title: "Base system prompt",
                        description: "Global `~/.pi/agent/SYSTEM.md` replaces Pi’s built-in base prompt when a project does not provide `.pi/SYSTEM.md`.",
                        files: files(for: .base)
                    )

                    instructionSection(
                        title: "Append system prompt",
                        description: "Global `~/.pi/agent/APPEND_SYSTEM.md` is appended when a project does not provide `.pi/APPEND_SYSTEM.md`.",
                        files: files(for: .append)
                    )

                    instructionSection(
                        title: "Global context files",
                        description: "Pi loads one global context file. `AGENTS.md` wins over `CLAUDE.md` when both exist.",
                        files: files(for: .context)
                    )
                }
                .padding(AppTheme.pagePadding)
            }
            .sheet(isPresented: $isPreviewPresented) {
                PiPromptPreviewSheet(
                    title: "System Prompt Preview",
                    subtitle: "Global fallback · ~/.pi/agent",
                    preview: PiInstructionPreviewBuilder.globalPreview(existingPaths: existingPaths, drafts: drafts)
                )
            }
            .task {
                loadFiles()
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ControlGroup {
                    Button {
                        isInfoPresented.toggle()
                    } label: {
                        Label("Info", systemImage: "info.circle")
                    }
                    .popover(isPresented: $isInfoPresented, arrowEdge: .bottom) {
                        PiSystemInstructionsInfoPopover()
                    }
                    .toolbarNeutralChrome()
                    .help("Explain Pi instruction assembly")

                    Button {
                        isPreviewPresented = true
                    } label: {
                        Label("Preview", systemImage: "doc.text.magnifyingglass")
                    }
                    .toolbarPrimaryActionChrome()
                    .help("Preview the global instruction pieces from the current editor contents")
                }
            }
        }
        .onDisappear {
            PiInstructionDraftCache.store(scope: "global", drafts: drafts, originals: originals, existingPaths: existingPaths)
        }
    }

    private var scopeCard: some View {
        AppCard(title: "Scope") {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "globe")
                    .foregroundStyle(AppTheme.brandAccent)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Applies to all projects unless a project provides its own `.pi/SYSTEM.md`, `.pi/APPEND_SYSTEM.md`, or context file.")
                    if isDirty {
                        Text("Unsaved edits are preserved while you move around this view. Use Save on each changed file to write them to disk.")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(AppTheme.mutedText)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "globe")
                .font(.title3.weight(.semibold))
                .foregroundStyle(AppTheme.brandAccent)
                .frame(width: 32, height: 32)
                .background(AppTheme.brandAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text("Global System Prompt")
                    .font(.headline)
                    .fontWidth(.expanded)
                Text("~/.pi/agent")
                    .font(.caption.monospaced())
                    .foregroundStyle(AppTheme.mutedText)
            }

            Spacer()

        }
    }

    private var instructionFiles: [PiInstructionFile] {
        PiInstructionFile.globalCatalog(existingPaths: existingPaths)
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

    private func loadFiles() {
        if let cached = PiInstructionDraftCache.cached(scope: "global") {
            drafts = cached.drafts
            originals = cached.originals
            existingPaths = cached.existingPaths
            statusMessage = nil
            return
        }

        let discoveredExistingPaths = PiInstructionFile.discoverGlobalExistingPaths()
        let files = PiInstructionFile.globalCatalog(existingPaths: discoveredExistingPaths)
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
        if FileManager.default.fileExists(atPath: file.url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([file.url])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([file.url.deletingLastPathComponent()])
        }
    }
}

/// The System Prompt "Preview" sheet. Renders the assembled effective prompt as
/// labelled sections — each base/append/context file in its own card, and Agent
/// Deck's runtime placeholders as visually distinct callouts — so literal prompt
/// text is never confused with text Pi substitutes at runtime.
private struct PiPromptPreviewSheet: View {
    let title: String
    let subtitle: String
    let preview: PiPromptPreview
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AppSheetHeader(
                systemImage: "doc.text.magnifyingglass",
                title: title,
                subtitle: subtitle,
                metadata: metadataLine
            ) {
                AppCopyTextButton(text: preview.fullText, help: "Copy the full assembled system prompt")
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
                    ForEach(preview.sections) { section in
                        PiPromptPreviewSectionView(section: section)
                    }
                }
                .padding(18)
            }
        }
        .frame(width: 760, height: 620)
    }

    private var metadataLine: String {
        let text = preview.fullText
        let lineCount = text.split(separator: "\n", omittingEmptySubsequences: false).count
        let lines = lineCount == 1 ? "1 line" : "\(lineCount.formatted()) lines"
        let size = ByteCountFormatter.string(fromByteCount: Int64(text.utf8.count), countStyle: .file)
        return "\(lines) · \(size) · \(tokenEstimate(for: text))"
    }

    // A rough chars-per-token heuristic — enough to gauge context budget, not
    // an exact tokenizer count, hence the "≈".
    private func tokenEstimate(for text: String) -> String {
        let tokens = max(1, text.count / 4)
        guard tokens >= 1000 else { return "≈\(tokens) tokens" }
        let thousands = (Double(tokens) / 1000).formatted(.number.precision(.fractionLength(0...1)))
        return "≈\(thousands)k tokens"
    }
}

/// One section of `PiPromptPreviewSheet`: a file-backed card (base/append/context)
/// or a tinted "inserted at runtime" callout for Agent Deck's placeholders.
private struct PiPromptPreviewSectionView: View {
    let section: PiPromptPreview.Section

    var body: some View {
        if section.kind.isFileBacked {
            fileCard
        } else {
            runtimeCallout
        }
    }

    private var fileCard: some View {
        VStack(alignment: .leading, spacing: AppTheme.contentSpacing) {
            HStack(spacing: 8) {
                roleChip
                Text(section.sourcePath ?? section.sourceLabel ?? section.title)
                    .font(.caption.monospaced())
                    .foregroundStyle(AppTheme.mutedText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                AppCopyTextButton(text: section.content, help: "Copy this section")
            }

            if section.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("(empty file)")
                    .font(.system(.caption, design: .monospaced))
                    .italic()
                    .foregroundStyle(AppTheme.mutedText)
            } else {
                Text(section.content)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(AppTheme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appContentSurface()
    }

    private var roleChip: some View {
        Text(roleLabel)
            .font(.caption2.weight(.semibold))
            .fontWidth(.expanded)
            .foregroundStyle(AppTheme.brandAccent)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(AppTheme.brandAccent.opacity(0.14), in: Capsule(style: .continuous))
    }

    private var roleLabel: String {
        switch section.kind {
        case .base: return "BASE"
        case .append: return "APPEND"
        case .context: return "CONTEXT"
        case .builtinDefault, .subagentCatalog, .runtime: return ""
        }
    }

    private var runtimeCallout: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: calloutIcon)
                    .foregroundStyle(AppTheme.brandAccent)
                Text(section.title)
                    .font(.subheadline.weight(.semibold))
                    .fontWidth(.expanded)
                Spacer(minLength: 8)
                Text("Inserted at runtime")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.mutedText)
            }
            Text(section.content)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(AppTheme.mutedText)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(AppTheme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appControlSurface()
    }

    private var calloutIcon: String {
        switch section.kind {
        case .subagentCatalog: return "person.2"
        case .runtime: return "clock"
        case .builtinDefault, .base, .append, .context: return "info.circle"
        }
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

    var viewModel: AppViewModel
    @Binding var searchText: String
    @State private var filter: Filter = .enabled
    @State private var debouncedSearchText = ""
    @State private var agentsRecapProject: DiscoveredProject?
    @State private var skillsRecapProject: DiscoveredProject?
    @State private var projectPendingRemoval: DiscoveredProject?
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
            AppCard(title: "Library") {
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
                recap: viewModel.agentRecap(for: project),
                imageStore: viewModel.agentImageStore
            )
        }
        .sheet(item: $skillsRecapProject) { project in
            ProjectSkillsRecapSheet(
                project: project,
                recap: viewModel.skillRecap(for: project)
            )
        }
        .alert("Remove project?", isPresented: removeProjectAlertBinding, presenting: projectPendingRemoval) { project in
            Button("Cancel", role: .cancel) {
                projectPendingRemoval = nil
            }
            Button("Hide from List") {
                viewModel.removeProjectFromLibrary(project)
                projectPendingRemoval = nil
            }
            Button("Move to Trash", role: .destructive) {
                do {
                    try viewModel.moveProjectToTrash(project)
                } catch {
                    projectDeleteError = error.localizedDescription
                }
                projectPendingRemoval = nil
            }
        } message: { project in
            Text("Hide \(project.repositoryDisplayName) from Agent Deck, or move the project folder to the macOS Trash. Moving to Trash deletes the folder from its current location.")
        }
        .alert("Couldn’t move project to Trash", isPresented: Binding(
            get: { projectDeleteError != nil },
            set: { if !$0 { projectDeleteError = nil } }
        )) {
            Button("OK", role: .cancel) { projectDeleteError = nil }
        } message: {
            Text(projectDeleteError ?? "Unknown error")
        }
    }

    private var removeProjectAlertBinding: Binding<Bool> {
        Binding(
            get: { projectPendingRemoval != nil },
            set: { isPresented in
                if !isPresented {
                    projectPendingRemoval = nil
                }
            }
        )
    }

    private var projectList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Filter", selection: $filter) {
                ForEach(Filter.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .labelsHidden()
            .appSegmentedPicker()
            .frame(maxWidth: 320)

            Text("Manage project visibility, favorites, icons, and assigned resource summaries. Use the System Prompt view to inspect and edit Pi instruction files.")
                .font(.caption)
                .foregroundStyle(AppTheme.mutedText)
                .fixedSize(horizontal: false, vertical: true)

            if viewModel.discoveredProjects.isEmpty {
                ContentUnavailableView(
                    "No Projects Yet",
                    systemImage: "folder",
                    description: Text(emptyProjectsRootDescription)
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

    private var emptyProjectsRootDescription: String {
        let paths = viewModel.configuredProjectsRootPaths
        switch paths.count {
        case 0:
            return "Add a projects folder in Settings or Doctor to start discovering projects."
        case 1:
            return "Projects from \(paths[0]) will appear here automatically."
        default:
            return "Projects from \(paths.count) configured folders will appear here automatically."
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
            case .favorites: preference.isFavorite
            }
            guard matchesFilter else { continue }
            if !query.isEmpty, !project.searchIndex.contains(query) { continue }
            matched.append(project)
        }
        cachedVisibleProjects = matched
    }

    @ViewBuilder
    private func projectRow(_ project: DiscoveredProject) -> some View {
        let preference = viewModel.projectPreference(for: project.path)
        let isActiveSessionProject = viewModel.selectedProjectPath == project.path

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
            .appSwitch()
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
                agentsRecapProject = project
            } label: {
                Image(systemName: "paperplane")
                    .foregroundStyle(AppTheme.mutedText)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help("Show agents for this project")

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
                projectPendingRemoval = project
            } label: {
                Image(systemName: "eye.slash")
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help("Hide from \(AppBrand.displayName)")
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

    private var isDirty: Bool {
        drafts.contains { path, text in text != originals[path, default: ""] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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

                        instructionSection(title: "Base system prompt", files: files(for: .base))
                        instructionSection(title: "Append system prompt", files: files(for: .append))
                        instructionSection(title: "Context files", files: files(for: .context))
                    }
                    .padding(AppTheme.pagePadding)
                }
                .sheet(isPresented: $isPreviewPresented) {
                    PiPromptPreviewSheet(
                        title: "System Prompt Preview",
                        subtitle: project.path,
                        preview: previewText(for: project)
                    )
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
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ControlGroup {
                    Button {
                        isInfoPresented.toggle()
                    } label: {
                        Label("Info", systemImage: "info.circle")
                    }
                    .popover(isPresented: $isInfoPresented, arrowEdge: .bottom) {
                        PiSystemInstructionsInfoPopover()
                    }
                    .toolbarNeutralChrome()
                    .help("Explain Pi prompt assembly")

                    Button {
                        isPreviewPresented = true
                    } label: {
                        Label("Preview", systemImage: "doc.text.magnifyingglass")
                    }
                    .toolbarPrimaryActionChrome()
                    .help("Preview the effective prompt from the current editor contents")
                }
            }
        }
        .onDisappear {
            if let project {
                PiInstructionDraftCache.store(scope: "project:\(project.path)", drafts: drafts, originals: originals, existingPaths: existingPaths)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            if let project {
                ProjectIconView(imageURL: project.iconFileURL, symbolName: project.fallbackSymbolName, size: 32, assetName: project.projectType.assetName)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Project System Prompt")
                        .font(.headline)
                        .fontWidth(.expanded)
                    Text(project.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(AppTheme.mutedText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else {
                Text("Project System Prompt")
                    .font(.headline)
                    .fontWidth(.expanded)
            }

            Spacer()
        }
    }

    private var instructionFiles: [PiInstructionFile] {
        guard let project else { return [] }
        return PiInstructionFile.catalog(for: project.url, existingPaths: existingPaths)
    }

    private func files(for role: PiInstructionFile.Role) -> [PiInstructionFile] {
        instructionFiles.filter { $0.role == role }
    }

    private func instructionSection(title: String, files: [PiInstructionFile]) -> some View {
        PiInstructionRoleSection(
            title: title,
            statusText: sectionStatus(for: files),
            groups: PiInstructionFile.competitionGroups(for: files),
            draft: { file in
                Binding(
                    get: { drafts[file.id, default: ""] },
                    set: { drafts[file.id] = $0 }
                )
            },
            isDirty: { file in drafts[file.id, default: ""] != originals[file.id, default: ""] },
            save: { file in save(file) },
            revealInFinder: { file in revealInFinder(file) }
        )
    }

    private func sectionStatus(for files: [PiInstructionFile]) -> String {
        let active = files.first(where: { $0.status == .active })
        let isProject = active?.title.hasPrefix("Project") == true
        switch files.first?.role {
        case .base:
            guard active != nil else { return "No custom base prompt — Pi uses its built-in system prompt." }
            return isProject ? "Using project file — overrides global and built-in." : "No project file — using global SYSTEM.md."
        case .append:
            guard active != nil else { return "No append prompt active." }
            return isProject ? "Using project file — global file is ignored." : "No project file — using global APPEND_SYSTEM.md."
        case .context:
            return "Pi appends one context file per directory — every directory below contributes its own file. Within a directory AGENTS.md wins over CLAUDE.md; the highlighted card is the file Pi loads."
        case nil:
            return ""
        }
    }

    private func loadFiles(for project: DiscoveredProject) {
        let scope = "project:\(project.path)"
        if let cached = PiInstructionDraftCache.cached(scope: scope) {
            drafts = cached.drafts
            originals = cached.originals
            existingPaths = cached.existingPaths
            statusMessage = nil
            return
        }

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

    private func previewText(for project: DiscoveredProject) -> PiPromptPreview {
        PiInstructionPreviewBuilder.preview(
            projectURL: project.url,
            existingPaths: existingPaths,
            drafts: drafts,
            includesNativeSubagentCatalog: includesNativeSubagentCatalog
        )
    }
}

private struct PiInstructionFileEditor: View {
    /// Describes the file's place in a competing row so the editor can dim
    /// losing fallbacks and point at the file Pi actually loads.
    struct Competition {
        let hasWinner: Bool
        let winnerTitle: String?
    }

    let file: PiInstructionFile
    @Binding var text: String
    let isDirty: Bool
    /// Non-nil when this file shares a row with other competing files.
    var competition: Competition? = nil
    let save: () -> Void
    let revealInFinder: () -> Void

    @State private var isEditorPresented = false
    @State private var sheetDraft = ""

    private var isActive: Bool { file.status == .active }

    // Desaturate competing files that lost to a winner so the loaded file
    // stands out. Rows with no winner yet keep every card at full strength.
    private var isDimmed: Bool {
        guard let competition else { return false }
        return competition.hasWinner && !isActive
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow

            if showsPreview {
                // A static, truncated snippet — deliberately not a nested
                // ScrollView. One ScrollView per card traps the page's scroll
                // wheel and forces SwiftUI to composite a scrollable, selectable
                // text layer for every card, which makes the page scroll
                // sluggishly. The full content stays available via the Edit sheet.
                Text(previewText)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(10)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(10)
                    .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
                    .appControlSurface(cornerRadius: 10)
            } else {
                Text(file.note)
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appContentSurface(cornerRadius: 12, isSelected: isActive)
        .saturation(isDimmed ? 0.1 : 1.0)
        .opacity(isDimmed ? 0.55 : 1.0)
        .sheet(isPresented: $isEditorPresented) {
            PiInstructionFileEditorSheet(
                file: file,
                text: $sheetDraft,
                saveTitle: file.exists ? "Save" : "Create",
                onCancel: { isEditorPresented = false },
                onSave: {
                    text = sheetDraft
                    save()
                    isEditorPresented = false
                },
                revealInFinder: revealInFinder
            )
        }
    }

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: iconName)
                .font(.body.weight(.semibold))
                .foregroundStyle(iconColor)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(file.title)
                        .font(.subheadline.weight(.semibold))
                        .fontWidth(.expanded)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    statusBadge
                    if isDirty {
                        Text("Unsaved")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                }

                Text(file.displayPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(AppTheme.mutedText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Button(file.exists ? "Edit" : "Create") {
                sheetDraft = text
                isEditorPresented = true
            }
            .controlSize(.small)
            .help(file.exists ? "Edit this prompt file" : "Create this prompt file")

            if isDirty {
                Button("Save") {
                    save()
                }
                .controlSize(.small)
                .help("Save pending edits")
            }

            Button { revealInFinder() } label: {
                Image(systemName: "folder")
                    .font(.body)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .controlSize(.small)
            .help(file.exists ? "Reveal in Finder" : "Reveal parent folder in Finder")
        }
    }

    private var showsPreview: Bool {
        file.exists || isDirty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var previewText: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Created, but empty." : trimmed
    }

    private var iconName: String {
        switch file.status {
        case .active: return "checkmark.circle.fill"
        case .shadowed: return "moon.fill"
        case .available: return "doc.badge.plus"
        }
    }

    private var iconColor: Color {
        switch file.status {
        case .active: return .green
        case .shadowed: return .secondary
        case .available: return AppTheme.mutedText
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch file.status {
        case .active:
            Text("Active")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.green)
        case .shadowed:
            Text(shadowedLabel)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        case .available:
            EmptyView()
        }
    }

    // A shadowed fallback names the file that beat it, so precedence is
    // explicit ("Overridden by Project AGENTS.md"). Outside a competition,
    // or when the winner can't be named, it simply reads "Overridden".
    private var shadowedLabel: String {
        if let winner = competition?.winnerTitle, winner != file.title {
            return "Overridden by \(winner)"
        }
        return "Overridden"
    }
}

/// One titled section ("Base system prompt", "Context files", …) of the
/// System Prompt view. Each role is split into competition groups, and every
/// group is laid out as an equal-width row so competing files are easy to
/// compare and the file Pi actually loads is obvious.
private struct PiInstructionRoleSection: View {
    let title: String
    let statusText: String
    let groups: [PiInstructionFile.CompetitionGroup]
    let draft: (PiInstructionFile) -> Binding<String>
    let isDirty: (PiInstructionFile) -> Bool
    let save: (PiInstructionFile) -> Void
    let revealInFinder: (PiInstructionFile) -> Void

    var body: some View {
        AppCard(title: title) {
            VStack(alignment: .leading, spacing: 14) {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(groups) { group in
                    competitionRow(group)
                }
            }
        }
    }

    @ViewBuilder
    private func competitionRow(_ group: PiInstructionFile.CompetitionGroup) -> some View {
        let isContested = group.files.count > 1
        VStack(alignment: .leading, spacing: 7) {
            if let label = group.label {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.caption2)
                    Text(label)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundStyle(AppTheme.mutedText)
            }

            EqualColumns(items: group.files, spacing: 10) { file in
                PiInstructionFileEditor(
                    file: file,
                    text: draft(file),
                    isDirty: isDirty(file),
                    competition: isContested
                        ? PiInstructionFileEditor.Competition(
                            hasWinner: group.winner != nil,
                            winnerTitle: group.winner?.title
                        )
                        : nil,
                    save: { save(file) },
                    revealInFinder: { revealInFinder(file) }
                )
            }
        }
    }
}

/// Lays children out in equal-width columns by measuring the row and dividing
/// the available width evenly, so N competing cards always get 1/N each
/// regardless of their individual content. A single child keeps its own width.
private struct EqualColumns<Item: Identifiable, Cell: View>: View {
    let items: [Item]
    let spacing: CGFloat
    @ViewBuilder let cell: (Item) -> Cell

    @State private var rowWidth: CGFloat = 0

    var body: some View {
        HStack(alignment: .top, spacing: spacing) {
            ForEach(items) { item in
                cell(item)
                    .frame(width: columnWidth)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            rowWidth = width
        }
    }

    private var columnWidth: CGFloat? {
        let count = items.count
        guard count > 1, rowWidth > 0 else { return nil }
        let usableWidth = rowWidth - spacing * CGFloat(count - 1)
        return max(1, usableWidth / CGFloat(count))
    }
}

private struct PiInstructionFileEditorSheet: View {
    let file: PiInstructionFile
    @Binding var text: String
    let saveTitle: String
    let onCancel: () -> Void
    let onSave: () -> Void
    let revealInFinder: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(file.title)
                        .font(.headline)
                        .fontWidth(.expanded)
                    Text(file.displayPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(AppTheme.mutedText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(file.note)
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button { revealInFinder() } label: {
                    Label("Reveal", systemImage: "folder")
                }
            }
            .padding(18)

            Divider()

            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(12)
                .frame(minHeight: 360)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .appSecondaryButton()
                Button(saveTitle) { onSave() }
                    .appPrimaryButton()
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 760, height: 560)
    }
}

private struct PiSystemInstructionsInfoPopover: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("How the system prompt is built")
                .font(.headline)
                .fontWidth(.expanded)

            Text("Pi assembles every session's system prompt from a handful of Markdown files on disk. Each section below shows the files that can contribute — when more than one is available, the card tagged **Active** is the file Pi actually loads. Project files always beat global files, and you can Create or Edit any file to shape Pi's behavior.")
                .font(.caption)
                .foregroundStyle(AppTheme.mutedText)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                infoRow("Base prompt", "Replaces Pi's built-in personality. Project `.pi/SYSTEM.md` wins; otherwise global `~/.pi/agent/SYSTEM.md`; otherwise the built-in Pi prompt.")
                infoRow("Append prompt", "Tacked onto the end of the base prompt — handy for house rules. Project `.pi/APPEND_SYSTEM.md` wins over the global file. Agent Deck may also stack its own append content on top.")
                infoRow("Context files", "Project knowledge Pi reads on every turn. Pi loads one global `AGENTS.md`/`CLAUDE.md`, then walks from the filesystem root down to the project directory, picking up one file per directory. Within a directory, `AGENTS.md` wins over `CLAUDE.md`.")
                infoRow("Runtime pieces", "Tools, skill catalogs, date, and working directory are injected by Pi at run time. The Preview button shows these as placeholders since Agent Deck can't know their exact text up front.")
            }
        }
        .padding(16)
        .frame(width: 440, alignment: .leading)
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

private struct ProjectAgentsRecapSheet: View {
    let project: DiscoveredProject
    let recap: ProjectAgentRecap
    @ObservedObject var imageStore: AgentImageStore

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                ProjectIconView(imageURL: project.iconFileURL, symbolName: project.fallbackSymbolName, size: 34, assetName: project.projectType.assetName)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Project Agents")
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
                    if hasResolvedAgents {
                        if !recap.defaultAgents.isEmpty {
                            agentRecapSection(title: "Default", agents: recap.defaultAgents, color: .blue)
                        }
                        if !recap.projectAgents.isEmpty {
                            agentRecapSection(title: "Project", agents: recap.projectAgents, color: .green)
                        }
                        if !recap.otherEffectiveAgents.isEmpty {
                            agentRecapSection(title: "Effective", agents: recap.otherEffectiveAgents, color: AppTheme.assistantAccent)
                        }
                    } else {
                        ContentUnavailableView(
                            "No Agents",
                            systemImage: "paperplane",
                            description: Text("No project agent catalog has been loaded for this project yet.")
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                    }

                    if !recap.unresolvedNames.isEmpty {
                        unresolvedAgentSection
                    }
                }
                .padding(18)
            }
        }
        .frame(width: 560, height: 620)
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
                            HStack(spacing: 6) {
                                Text(agent.name)
                                    .font(.subheadline.weight(.semibold))
                                    .strikethrough(agent.resolved.disabled == true, color: AppTheme.mutedText)
                                Text(agent.resolutionKind.rawValue)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(color)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(color.opacity(0.12), in: Capsule(style: .continuous))
                            }
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

private struct ProjectSkillsRecapSheet: View {
    let project: DiscoveredProject
    let recap: ProjectSkillRecap

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                ProjectIconView(imageURL: project.iconFileURL, symbolName: project.fallbackSymbolName, size: 34, assetName: project.projectType.assetName)

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

    /// A set of instruction files that compete for the same prompt slot, where
    /// at most one (`winner`) is actually loaded by Pi. The remaining files are
    /// shadowed fallbacks or not-yet-created candidates.
    struct CompetitionGroup: Identifiable {
        let id: String
        /// Directory caption shown above a context-file row. `nil` for base and
        /// append rows, where the competing files live in different directories.
        let label: String?
        let files: [PiInstructionFile]

        var winner: PiInstructionFile? { files.first { $0.status == .active } }
    }

    /// Splits a role's files into the groups that actually compete in Pi.
    ///
    /// - Base/append: a session uses exactly one base prompt and one append
    ///   prompt, so every file of that role competes in a single group.
    /// - Context: Pi loads one context file *per directory* (`AGENTS.md` beats
    ///   `CLAUDE.md` within a directory, but every directory contributes one
    ///   file), so each directory is its own competition.
    static func competitionGroups(for files: [PiInstructionFile]) -> [CompetitionGroup] {
        guard let role = files.first?.role else { return [] }
        switch role {
        case .base, .append:
            return [CompetitionGroup(id: role.rawValue, label: nil, files: files)]
        case .context:
            var groups: [CompetitionGroup] = []
            for file in files {
                let directory = file.url.deletingLastPathComponent().path
                if let last = groups.indices.last,
                   groups[last].files.first?.url.deletingLastPathComponent().path == directory {
                    groups[last] = CompetitionGroup(
                        id: groups[last].id,
                        label: groups[last].label,
                        files: groups[last].files + [file]
                    )
                } else {
                    let label = directory.replacingOccurrences(of: NSHomeDirectory(), with: "~")
                    groups.append(CompetitionGroup(id: directory, label: label, files: [file]))
                }
            }
            // Order each directory's cards by Pi's candidate precedence so the
            // left-most column is always the highest-priority filename.
            return groups.map { group in
                CompetitionGroup(
                    id: group.id,
                    label: group.label,
                    files: group.files.sorted { contextPrecedence(of: $0) < contextPrecedence(of: $1) }
                )
            }
        }
    }

    private static func contextPrecedence(of file: PiInstructionFile) -> Int {
        contextCandidateNames.firstIndex(of: file.url.lastPathComponent) ?? contextCandidateNames.count
    }

    static func globalCatalog(existingPaths: Set<String>) -> [PiInstructionFile] {
        let globalDir = globalAgentDirectory
        let globalSystem = globalDir.appendingPathComponent("SYSTEM.md")
        let globalAppend = globalDir.appendingPathComponent("APPEND_SYSTEM.md")
        let globalActiveContext = activeContextFile(in: globalDir, existingPaths: existingPaths)?.path

        return [
            PiInstructionFile(
                url: globalSystem,
                role: .base,
                title: "Global SYSTEM.md",
                note: "Global replacement for Pi’s built-in base prompt.",
                status: status(for: globalSystem.path, activePath: existingPaths.contains(globalSystem.path) ? globalSystem.path : nil, existingPaths: existingPaths),
                exists: existingPaths.contains(globalSystem.path)
            ),
            PiInstructionFile(
                url: globalAppend,
                role: .append,
                title: "Global APPEND_SYSTEM.md",
                note: "Global append prompt used when no project append prompt overrides it.",
                status: status(for: globalAppend.path, activePath: existingPaths.contains(globalAppend.path) ? globalAppend.path : nil, existingPaths: existingPaths),
                exists: existingPaths.contains(globalAppend.path)
            ),
            PiInstructionFile(
                url: globalDir.appendingPathComponent("AGENTS.md"),
                role: .context,
                title: "Global AGENTS.md",
                note: "Global context loaded for every Pi session unless context files are disabled.",
                status: status(for: globalDir.appendingPathComponent("AGENTS.md").path, activePath: globalActiveContext, existingPaths: existingPaths),
                exists: existingPaths.contains(globalDir.appendingPathComponent("AGENTS.md").path)
            ),
            PiInstructionFile(
                url: globalDir.appendingPathComponent("CLAUDE.md"),
                role: .context,
                title: "Global CLAUDE.md",
                note: "Fallback global context. It is shadowed when global AGENTS.md exists.",
                status: status(for: globalDir.appendingPathComponent("CLAUDE.md").path, activePath: globalActiveContext, existingPaths: existingPaths),
                exists: existingPaths.contains(globalDir.appendingPathComponent("CLAUDE.md").path)
            )
        ]
    }

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

    static func discoverGlobalExistingPaths() -> Set<String> {
        let globalDir = globalAgentDirectory
        let fileManager = FileManager.default
        var paths = Set<String>()
        [
            globalDir.appendingPathComponent("SYSTEM.md"),
            globalDir.appendingPathComponent("APPEND_SYSTEM.md")
        ].forEach { url in
            if fileManager.fileExists(atPath: url.path) { paths.insert(url.path) }
        }
        insertCaseSensitiveContextMatches(in: globalDir, into: &paths)
        return paths
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
            insertCaseSensitiveContextMatches(in: directory, into: &paths)
        }

        return paths
    }

    // `FileManager.fileExists` is case-insensitive on APFS, so probing each
    // candidate casing reports the same on-disk file under every spelling.
    // Listing the directory once and matching exact names keeps only the real
    // on-disk casing.
    private static func insertCaseSensitiveContextMatches(in directory: URL, into paths: inout Set<String>) {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        let onDisk = Set(contents)
        for filename in contextCandidateNames where onDisk.contains(filename) {
            paths.insert(directory.appendingPathComponent(filename).path)
        }
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

/// The assembled effective prompt, split into the pieces that compose it. The
/// preview sheet labels each piece and sets Agent Deck's runtime placeholders
/// apart from literal prompt text. `fullText` is the verbatim flat string Pi
/// would assemble — used for the top-level Copy and the size readout.
struct PiPromptPreview {
    enum SectionKind {
        case base, append, context
        case builtinDefault, subagentCatalog, runtime

        /// File-backed sections render as cards; the rest render as runtime callouts.
        var isFileBacked: Bool {
            switch self {
            case .base, .append, .context: return true
            case .builtinDefault, .subagentCatalog, .runtime: return false
            }
        }
    }

    struct Section: Identifiable {
        let id: String
        let kind: SectionKind
        let title: String
        let sourceLabel: String?
        let sourcePath: String?
        let content: String
    }

    let sections: [Section]
    let assembledText: String

    var fullText: String { assembledText }
}

private enum PiInstructionPreviewBuilder {
    static func globalPreview(existingPaths: Set<String>, drafts: [String: String]) -> PiPromptPreview {
        let catalog = PiInstructionFile.globalCatalog(existingPaths: existingPaths.union(drafts.compactMap { path, content in
            existingPaths.contains(path) || content.isEmpty ? nil : path
        }))
        var prompt: String
        var sections: [PiPromptPreview.Section] = []

        if let baseFile = catalog.first(where: { $0.role == .base && $0.status == .active }) {
            prompt = content(for: baseFile.url, drafts: drafts)
            sections.append(fileSection(baseFile, kind: .base, title: "Base prompt", drafts: drafts))
        } else {
            prompt = builtinDefaultText
            sections.append(builtinDefaultSection)
        }

        if let appendFile = catalog.first(where: { $0.role == .append && $0.status == .active }) {
            prompt += "\n\n\(content(for: appendFile.url, drafts: drafts))"
            sections.append(fileSection(appendFile, kind: .append, title: "Append prompt", drafts: drafts))
        }

        if let contextFile = catalog.first(where: { $0.role == .context && $0.status == .active }) {
            prompt += "\n\n# Global Context\n\n## \(contextFile.url.path)\n\n\(content(for: contextFile.url, drafts: drafts))"
            sections.append(fileSection(contextFile, kind: .context, title: "Global context", drafts: drafts))
        }

        // Mirrors the original trailing block: a leading newline plus these lines.
        let runtime = """
        [PROJECT CONTEXT FILES, when a project session is launched]
        [PI SKILL CATALOG, if skills are enabled and the read tool is available]
        Current date: \(currentDateString())
        Current working directory: [selected project]
        """
        prompt += "\n" + runtime
        sections.append(runtimeSection(runtime))

        return PiPromptPreview(sections: sections, assembledText: prompt)
    }

    static func preview(projectURL: URL, existingPaths: Set<String>, drafts: [String: String], includesNativeSubagentCatalog: Bool = false) -> PiPromptPreview {
        let projectURL = projectURL.standardizedFileURL
        let draftedNewPaths = drafts.compactMap { path, content in
            existingPaths.contains(path) || content.isEmpty ? nil : path
        }
        let previewExistingPaths = existingPaths.union(draftedNewPaths)
        let catalog = PiInstructionFile.catalog(for: projectURL, existingPaths: previewExistingPaths)
        var prompt: String
        var sections: [PiPromptPreview.Section] = []

        if let baseFile = catalog.first(where: { $0.role == .base && $0.status == .active }) {
            prompt = content(for: baseFile.url, drafts: drafts)
            sections.append(fileSection(baseFile, kind: .base, title: "Base prompt", drafts: drafts))
        } else {
            prompt = builtinDefaultText
            sections.append(builtinDefaultSection)
        }

        if let appendFile = catalog.first(where: { $0.role == .append && $0.status == .active }) {
            prompt += "\n\n\(content(for: appendFile.url, drafts: drafts))"
            sections.append(fileSection(appendFile, kind: .append, title: "Append prompt", drafts: drafts))
        }

        if includesNativeSubagentCatalog {
            prompt += "\n\n[AGENT DECK — DECK AGENT CATALOG]"
            sections.append(PiPromptPreview.Section(
                id: "subagent-catalog",
                kind: .subagentCatalog,
                title: "Deck agent catalog",
                sourceLabel: nil,
                sourcePath: nil,
                content: "Agent Deck inserts its Deck agent catalog here when Deck agents are enabled."
            ))
        }

        let contextFiles = PiInstructionFile.activeContextFiles(for: projectURL, existingPaths: previewExistingPaths)
        if !contextFiles.isEmpty {
            prompt += "\n\n# Project Context\n\nProject-specific instructions and guidelines:\n\n"
            for url in contextFiles {
                prompt += "## \(url.path)\n\n\(content(for: url, drafts: drafts))\n\n"
                sections.append(PiPromptPreview.Section(
                    id: url.path,
                    kind: .context,
                    title: "Context file",
                    sourceLabel: catalog.first { $0.id == url.path }?.title ?? url.lastPathComponent,
                    sourcePath: url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"),
                    content: content(for: url, drafts: drafts)
                ))
            }
        }

        let runtime = """
        [PI SKILL CATALOG, if skills are enabled and the read tool is available]
        Current date: \(currentDateString())
        Current working directory: \(projectURL.path)
        """
        prompt += "\n" + runtime
        sections.append(runtimeSection(runtime))

        return PiPromptPreview(sections: sections, assembledText: prompt)
    }

    private static let builtinDefaultText = """
    [PI BUILT-IN DEFAULT SYSTEM PROMPT]
    [Pi tool-aware guidance is generated at runtime when the built-in prompt is used.]
    """

    private static var builtinDefaultSection: PiPromptPreview.Section {
        PiPromptPreview.Section(
            id: "builtin-default",
            kind: .builtinDefault,
            title: "Built-in default prompt",
            sourceLabel: nil,
            sourcePath: nil,
            content: builtinDefaultText
        )
    }

    private static func fileSection(_ file: PiInstructionFile, kind: PiPromptPreview.SectionKind, title: String, drafts: [String: String]) -> PiPromptPreview.Section {
        PiPromptPreview.Section(
            id: file.id,
            kind: kind,
            title: title,
            sourceLabel: file.title,
            sourcePath: file.displayPath,
            content: content(for: file.url, drafts: drafts)
        )
    }

    private static func runtimeSection(_ text: String) -> PiPromptPreview.Section {
        PiPromptPreview.Section(
            id: "runtime",
            kind: .runtime,
            title: "Runtime additions",
            sourceLabel: nil,
            sourcePath: nil,
            content: text
        )
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
