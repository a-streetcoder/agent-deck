import AppKit
import OSLog
import SwiftUI

/// Top-level "System Prompt" screen. Always available — no project required.
///
/// Two clearly separated sections keep the scope obvious:
/// - **Global instructions** are the `~/.pi/agent` files Pi loads for every
///   session. Editable whether or not a project is selected.
/// - **Project instructions** are the project's own `.pi/SYSTEM.md`,
///   `.pi/APPEND_SYSTEM.md`, and per-directory context files. They only make
///   sense with a project, so without one the section shows a "select a
///   project" placeholder.
///
/// The active project is picked from a menu in this screen's toolbar (not the
/// sidebar), so the user can stay here while switching scope.
struct SystemInstructionsScreen: View {
    private static let layoutLog = Logger(subsystem: "works.earendil.pi-deck", category: "ResourceLayout")

    let viewModel: AppViewModel

    @State private var drafts: [String: String] = [:]
    @State private var originals: [String: String] = [:]
    @State private var existingPaths: Set<String> = []
    @State private var statusMessage: String?
    @State private var isInfoPresented = false
    @State private var isPreviewPresented = false
    @State private var isProjectPickerPresented = false
    @State private var selectedFileID: String?

    private var project: DiscoveredProject? { viewModel.selectedDiscoveredProject }
    private var projectURL: URL? { project?.url }
    private var includesNativeSubagentCatalog: Bool { viewModel.areSubagentsEnabledForNewSessions }

    private var cacheKey: String { viewModel.selectedProjectPath ?? "global" }

    var body: some View {
        SplitView {
            listPane
                .appDebugLayout("SystemPrompt.libraryPane", logger: Self.layoutLog)
        } detail: {
            detailPane
                .appDebugLayout("SystemPrompt.detailPane", logger: Self.layoutLog)
        }
        .appDebugLayout("SystemPrompt.hsplit", logger: Self.layoutLog)
        .sheet(isPresented: $isPreviewPresented) {
            PiPromptPreviewSheet(
                title: "System Prompt Preview",
                subtitle: project?.path ?? "Global · ~/.pi/agent",
                preview: makePreview()
            )
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ProjectToolbarSelector(
                    viewModel: viewModel,
                    isPresented: $isProjectPickerPresented
                )
            }

            ToolbarSpacer(.fixed, placement: .primaryAction)

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
        .task(id: cacheKey) { loadFiles() }
        .onChange(of: drafts) { _, newDrafts in
            // Persist unsaved edits across project switches / reloads. Keyed by
            // file path so the same global file keeps its edits when the user
            // moves between "no project" and a specific project.
            for (path, text) in newDrafts {
                if text != originals[path, default: ""] {
                    PiInstructionDraftStore.unsavedDrafts[path] = text
                } else {
                    PiInstructionDraftStore.unsavedDrafts.removeValue(forKey: path)
                }
            }
        }
    }

    // MARK: File list (left pane)

    /// Catalog sections for the list. Global files always appear; project files
    /// appear only when a project is selected (otherwise the Project section
    /// shows a "select a project" empty message). The catalog is small (a
    /// handful of candidates), so recomputing per body eval is cheap.
    private var sections: [AppListSection<PiInstructionFile>] {
        var built: [AppListSection<PiInstructionFile>] = [
            AppListSection(
                id: "global",
                title: "Global",
                info: "`~/.pi/agent` files — the fallback for every session.",
                items: PiInstructionFile.globalCatalog(existingPaths: existingPaths)
            )
        ]
        if let projectURL {
            built.append(AppListSection(
                id: "project",
                title: "Project",
                info: projHeaderInfo,
                items: PiInstructionFile.projectCatalog(for: projectURL, existingPaths: existingPaths),
                emptyMessage: "This project has no instruction files yet."
            ))
        } else {
            built.append(AppListSection(
                id: "project",
                title: "Project",
                items: [],
                emptyMessage: "Select a project from the toolbar to edit its instruction files."
            ))
        }
        return built
    }

    private var projHeaderInfo: String? {
        guard let project else { return nil }
        return "Project `.pi/` files override their global counterparts for sessions in \(project.repositoryDisplayName)."
    }

    private var selectedFile: PiInstructionFile? {
        let files = allFiles
        if let id = selectedFileID, let file = files.first(where: { $0.id == id }) {
            return file
        }
        return files.first
    }

    private var allFiles: [PiInstructionFile] { sections.flatMap { $0.items } }

    @ViewBuilder
    private var listPane: some View {
        AppList(
            sections: sections,
            selection: .single($selectedFileID)
        ) { file in
            SystemPromptFileRowView(
                file: file,
                isDirty: isDirtyFile(file),
                statusHelp: statusDotHelp(file),
                onReveal: { revealInFinder(file) }
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .contextMenu {
                Button(file.exists ? "Reveal in Finder" : "Reveal Parent Folder") {
                    revealInFinder(file)
                }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(file.url.path, forType: .string)
                }
            }
        }
    }

    private func isDirtyFile(_ file: PiInstructionFile) -> Bool {
        drafts[file.id, default: ""] != originals[file.id, default: ""]
    }

    private func statusDotHelp(_ file: PiInstructionFile) -> String {
        switch file.status {
        case .active: return "Active — this is the file Pi loads."
        case .shadowed: return "Inactive — exists but Pi loads another file for this slot."
        case .available: return "Not created — select it, start typing, then Create to write it to disk."
        }
    }

    // MARK: Editor (right pane)

    @ViewBuilder
    private var detailPane: some View {
        if let file = selectedFile {
            SystemPromptFileDetail(
                file: file,
                text: Binding(
                    get: { drafts[file.id, default: ""] },
                    set: { drafts[file.id] = $0 }
                ),
                isDirty: isDirtyFile(file),
                statusMessage: statusMessage,
                onSave: { save(file) },
                onReveal: { revealInFinder(file) }
            )
        } else {
            AppEmptyState(
                "Select an Instruction File",
                systemImage: "doc.text",
                description: "Choose a file on the left to inspect or edit it.",
                layout: .fill
            )
        }
    }

    // MARK: Loading / saving

    private func loadFiles() {
        let discoveredExistingPaths: Set<String>
        let files: [PiInstructionFile]
        if let projectURL {
            discoveredExistingPaths = PiInstructionFile.discoverExistingPaths(for: projectURL)
            files = PiInstructionFile.catalog(for: projectURL, existingPaths: discoveredExistingPaths)
        } else {
            discoveredExistingPaths = PiInstructionFile.discoverGlobalExistingPaths()
            files = PiInstructionFile.globalCatalog(existingPaths: discoveredExistingPaths)
        }

        var loadedDrafts: [String: String] = [:]
        var loadedOriginals: [String: String] = [:]
        for file in files {
            let diskContent = (try? String(contentsOf: file.url, encoding: .utf8)) ?? ""
            loadedOriginals[file.id] = diskContent
            // Restore any unsaved edit for this path; otherwise use disk content.
            loadedDrafts[file.id] = PiInstructionDraftStore.unsavedDrafts[file.id] ?? diskContent
        }
        existingPaths = discoveredExistingPaths
        drafts = loadedDrafts
        originals = loadedOriginals
        statusMessage = nil
        ensureSelection()
    }

    /// Keep the list selection valid across project switches: if the previously
    /// selected file is no longer in the catalog (e.g. it was a project file and
    /// the user dropped the project), fall back to the first file.
    private func ensureSelection() {
        if allFiles.first(where: { $0.id == selectedFileID }) == nil {
            selectedFileID = allFiles.first?.id
        }
    }

    private func save(_ file: PiInstructionFile) {
        do {
            try FileManager.default.createDirectory(
                at: file.url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let text = drafts[file.id, default: ""]
            try text.write(to: file.url, atomically: true, encoding: .utf8)
            originals[file.id] = text
            existingPaths.insert(file.id)
            PiInstructionDraftStore.unsavedDrafts.removeValue(forKey: file.id)
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

    private func makePreview() -> PiPromptPreview {
        if let projectURL {
            return PiInstructionPreviewBuilder.preview(
                projectURL: projectURL,
                existingPaths: existingPaths,
                drafts: drafts,
                includesNativeSubagentCatalog: includesNativeSubagentCatalog
            )
        } else {
            return PiInstructionPreviewBuilder.globalPreview(
                existingPaths: existingPaths,
                drafts: drafts,
                includesNativeSubagentCatalog: includesNativeSubagentCatalog
            )
        }
    }
}

/// Holds unsaved editor drafts keyed by file path, so edits survive switching
/// projects or reloading the screen. Purely in-memory — cleared on app restart.
private final class PiInstructionDraftStore {
    static var unsavedDrafts: [String: String] = [:]
}

private struct SystemPromptFileRowView: View {
    let file: PiInstructionFile
    let isDirty: Bool
    let statusHelp: String
    let onReveal: () -> Void
    @State private var isHovered = false

    private var isInactive: Bool { file.status != .active }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: file.status.systemImage)
                .imageScale(.large)
                .foregroundStyle(file.status.color)
                .frame(width: 18)
                .help(statusHelp)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(file.title)
                        .font(AppTheme.Font.sectionTitle)
                        .fontWidth(.expanded)
                        .lineLimit(1)
                    if isDirty {
                        Circle()
                            .fill(.orange)
                            .frame(width: 6, height: 6)
                            .help("Unsaved edits")
                    }
                }

                Text(file.displayPath)
                    .font(AppTheme.Font.metadata.monospaced())
                    .foregroundStyle(AppTheme.mutedText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)

            Button { onReveal() } label: {
                Label("Reveal", systemImage: "folder")
                    .labelStyle(.titleAndIcon)
            }
            .appSmallSecondaryButton()
            .opacity(isHovered ? 1 : 0)
            .animation(.easeInOut(duration: 0.15), value: isHovered)
            .help(file.exists ? "Reveal in Finder" : "Reveal parent folder in Finder")
        }
        .padding(.vertical, 6)
        .opacity(isInactive ? 0.62 : 1)
        .saturation(isInactive ? 0.25 : 1)
        .onHover { isHovered = $0 }
    }
}

/// Right-hand editor pane for the selected instruction file. Replaces the old
/// per-card editor + modal sheet: one full-height monospaced `TextEditor` with
/// a compact header (role chip, status, path) and a single Save / Reveal
/// action row. Switching files is just clicking another list row — no sheet.
struct SystemPromptFileDetail: View {
    let file: PiInstructionFile
    @Binding var text: String
    let isDirty: Bool
    let statusMessage: String?
    let onSave: () -> Void
    let onReveal: () -> Void
    @FocusState private var isEditorFocused: Bool

    var body: some View {
        AppPage(file.title, subtitle: file.displayPath, constrainsContentToViewport: true) {
            AppCard(trailing: { headerActions }) {
                VStack(alignment: .leading, spacing: AppTheme.contentSpacing) {
                    HStack(spacing: 10) {
                        roleChip
                        statusLine
                    }
                    AppKeyValueList(rows: metadataRows)
                    if let statusMessage {
                        Text(statusMessage)
                            .font(AppTheme.Font.caption)
                            .foregroundStyle(AppTheme.mutedText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            AppCard(title: "Prompt Role", info: "Explains how this instruction file participates in Pi's prompt assembly.") {
                note
            }

            AppCard(title: file.exists ? "Markdown Instructions" : "Create Markdown Instructions") {
                editor
            }
        }
    }

    private var headerActions: some View {
        HStack(spacing: 8) {
            Button { onReveal() } label: {
                Label("Reveal", systemImage: "folder")
                    .labelStyle(.titleAndIcon)
            }
            .appSmallSecondaryButton()
            .help(file.exists ? "Reveal in Finder" : "Reveal parent folder in Finder")

            Button { onSave() } label: {
                Label(file.exists ? "Save" : "Create", systemImage: file.exists ? "square.and.arrow.down" : "plus")
                    .labelStyle(.titleAndIcon)
            }
            .appPrimaryButton()
            .disabled(!isDirty)
            .help(file.exists ? "Save changes to disk" : "Create this file on disk")
            .keyboardShortcut("s", modifiers: .command)
        }
    }

    private var metadataRows: [(String, String)] {
        [
            ("File", file.displayPath),
            ("Status", file.status.label),
            ("Scope", file.scopeLabel)
        ]
    }

    private var roleChip: some View {
        Text(roleLabel)
            .font(.caption.weight(.semibold))
            .fontWidth(.expanded)
            .foregroundStyle(AppTheme.brandAccent)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(AppTheme.brandAccent.opacity(0.14), in: Capsule(style: .continuous))
    }

    private var roleLabel: String {
        switch file.role {
        case .base: "BASE"
        case .append: "APPEND"
        case .context: "CONTEXT"
        }
    }

    private var note: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(file.note)
                .font(AppTheme.Font.caption)
                .foregroundStyle(AppTheme.mutedText)
            if !file.exists {
                Label(createImpactMessage, systemImage: "square.and.pencil")
                    .font(AppTheme.Font.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // Baseline-align explicitly; `Label` centers the symbol bounds and reads low here.
    private var statusLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: file.status.systemImage)
            Text(file.status.label)
        }
        .font(AppTheme.Font.caption.weight(.semibold))
        .foregroundStyle(file.status.color)
    }

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .focused($isEditorFocused)
                .padding(12)
                .frame(maxWidth: .infinity, minHeight: 420, alignment: .topLeading)
                .background(AppTheme.contentSubtleFill, in: RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius, style: .continuous)
                        .stroke(AppTheme.contentStroke, lineWidth: 1)
                }
            if text.isEmpty && !isEditorFocused {
                VStack(alignment: .leading, spacing: 8) {
                    Text(file.exists ? "Empty file" : "Start writing Markdown instructions")
                        .font(AppTheme.Font.callout.weight(.semibold))
                        .foregroundStyle(AppTheme.mutedText)
                    Text(file.exists ? "Add instructions, then Save." : "This file does not exist yet. Type here, then Create writes it to the path above.")
                        .font(AppTheme.Font.caption)
                        .foregroundStyle(AppTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 20)
                .allowsHitTesting(false)
            }
        }
    }

    private var createImpactMessage: String {
        switch file.role {
        case .base:
            return "Creating SYSTEM.md overrides Pi’s built-in base prompt here."
        case .append:
            return "Creating APPEND_SYSTEM.md adds extra instructions here."
        case .context:
            return "Creating this file adds fallback context for sessions here."
        }
    }
}

/// Popover explaining how Pi assembles its system prompt from the on-disk files.
private struct PiSystemInstructionsInfoPopover: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("How the system prompt is built")
                .font(.headline)
                .fontWidth(.expanded)

            Text("Pi assembles every session's system prompt from a handful of Markdown files on disk. Each section below shows the files that can contribute — the first existing file in each slot is the one Pi loads.")
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

/// The System Prompt "Preview" sheet. Renders the assembled effective prompt as
/// labelled sections — each base/append/context file in its own card, and Agent
/// Deck's runtime placeholders as visually distinct callouts — so literal prompt
/// text is never confused with text Pi substitutes at runtime.
struct PiPromptPreviewSheet: View {
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
            .font(AppTheme.Font.micro.weight(.semibold))
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
                    .font(AppTheme.Font.micro)
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

/// A discoverable Pi instruction file: its URL, role, display metadata, and
/// whether Pi loads it (`status`). The catalog methods enumerate the candidate
/// files Pi consults, in load precedence order.
struct PiInstructionFile: Identifiable, Hashable {
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
            case .available: "Not created"
            }
        }

        var color: Color {
            switch self {
            case .active: .green
            case .shadowed: .orange
            case .available: AppTheme.mutedText
            }
        }

        var systemImage: String {
            switch self {
            case .active: "checkmark.circle.fill"
            case .shadowed: "circle.fill"
            case .available: "circle.dashed"
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
    var scopeLabel: String { title.hasPrefix("Project") ? "Project" : "Global" }

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
                note: "Fallback global context. Shadowed when global AGENTS.md exists.",
                status: status(for: globalDir.appendingPathComponent("CLAUDE.md").path, activePath: globalActiveContext, existingPaths: existingPaths),
                exists: existingPaths.contains(globalDir.appendingPathComponent("CLAUDE.md").path)
            )
        ]
    }

    /// The project-owned instruction files only (no global fallback rows).
    /// Used for the "Project Instructions" section, which sits next to a
    /// separate "Global Instructions" section — showing globals here would
    /// duplicate them.
    static func projectCatalog(for projectURL: URL, existingPaths: Set<String>) -> [PiInstructionFile] {
        let projectURL = projectURL.standardizedFileURL
        let projectPiDir = projectURL.appendingPathComponent(".pi", isDirectory: true)
        let projectSystem = projectPiDir.appendingPathComponent("SYSTEM.md")
        let projectAppend = projectPiDir.appendingPathComponent("APPEND_SYSTEM.md")

        // Project base/append are active whenever they exist (they override the
        // global counterpart shown in the Global section).
        let files: [PiInstructionFile] = [
            PiInstructionFile(
                url: projectSystem,
                role: .base,
                title: "Project SYSTEM.md",
                note: "Project-local replacement for the Pi base prompt. Overrides global SYSTEM.md and the built-in Pi prompt.",
                status: status(for: projectSystem.path, activePath: existingPaths.contains(projectSystem.path) ? projectSystem.path : nil, existingPaths: existingPaths),
                exists: existingPaths.contains(projectSystem.path)
            ),
            PiInstructionFile(
                url: projectAppend,
                role: .append,
                title: "Project APPEND_SYSTEM.md",
                note: "Project-local append prompt. Overrides the global append file when present.",
                status: status(for: projectAppend.path, activePath: existingPaths.contains(projectAppend.path) ? projectAppend.path : nil, existingPaths: existingPaths),
                exists: existingPaths.contains(projectAppend.path)
            )
        ]

        return files + projectContextFiles(for: projectURL, existingPaths: existingPaths)
    }

    /// The merged catalog — project files first, then their global fallbacks —
    /// used to determine which single file Pi loads per slot. Kept for the
    /// Preview builder; the editor sections display global/project separately.
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

    /// Project-only context files: one candidate per directory from the
    /// filesystem root down to the project directory. Excludes the global
    /// `~/.pi/agent` directory (that belongs to the Global section).
    private static func projectContextFiles(for projectURL: URL, existingPaths: Set<String>) -> [PiInstructionFile] {
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

    /// Merged context files — global dir first, then ancestors down to project.
    /// Used by `catalog(for:)` (for the Preview builder).
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

        files.append(contentsOf: projectContextFiles(for: projectURL, existingPaths: existingPaths))
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
/// would receive.
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

private enum PiBuiltinPromptExtractor {
    struct Result {
        let text: String
        let sourcePath: String
    }

    private static let result: Result? = extract()

    static func extractBasePrompt() -> String? { result?.text }

    static var promptSourceLabel: String? {
        result == nil ? nil : "Extracted from installed Pi"
    }

    static var promptSourcePath: String? {
        result?.sourcePath.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private static func extract() -> Result? {
        guard let packageRoot = resolvePackageRoot() else { return nil }
        let sourceURL = packageRoot
            .appendingPathComponent("dist", isDirectory: true)
            .appendingPathComponent("core", isDirectory: true)
            .appendingPathComponent("system-prompt.js")
        guard let source = try? String(contentsOf: sourceURL, encoding: .utf8),
              var template = extractPromptTemplate(from: source)
        else { return nil }

        template = template
            .replacingOccurrences(of: "${toolsList}", with: "[PI AVAILABLE TOOLS — generated at runtime]")
            .replacingOccurrences(of: "${guidelines}", with: "[PI TOOL-AWARE GUIDELINES — generated at runtime]")
            .replacingOccurrences(of: "${readmePath}", with: packageRoot.appendingPathComponent("README.md").path)
            .replacingOccurrences(of: "${docsPath}", with: packageRoot.appendingPathComponent("docs", isDirectory: true).path)
            .replacingOccurrences(of: "${examplesPath}", with: packageRoot.appendingPathComponent("examples", isDirectory: true).path)
        return Result(text: template, sourcePath: sourceURL.path)
    }

    private static func resolvePackageRoot() -> URL? {
        guard let executable = PiExecutableResolver().resolve()?.resolvingSymlinksInPath() else { return nil }
        let fileManager = FileManager.default
        let components = executable.pathComponents
        if let nodeModules = components.lastIndex(of: "node_modules"),
           components.count > nodeModules + 2,
           components[nodeModules + 1] == "@earendil-works",
           components[nodeModules + 2] == "pi-coding-agent" {
            let rootPath = components[0...nodeModules + 2].joined(separator: "/").replacingOccurrences(of: "//", with: "/")
            let root = URL(fileURLWithPath: rootPath, isDirectory: true)
            if hasSystemPromptSource(in: root, fileManager: fileManager) { return root }
        }

        var directory = executable.deletingLastPathComponent()
        while directory.path != directory.deletingLastPathComponent().path {
            for relative in [
                "libexec/lib/node_modules/@earendil-works/pi-coding-agent",
                "lib/node_modules/@earendil-works/pi-coding-agent",
                "node_modules/@earendil-works/pi-coding-agent"
            ] {
                let candidate = directory.appendingPathComponent(relative, isDirectory: true)
                if hasSystemPromptSource(in: candidate, fileManager: fileManager) { return candidate }
            }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }

    private static func hasSystemPromptSource(in root: URL, fileManager: FileManager) -> Bool {
        fileManager.fileExists(atPath: root.appendingPathComponent("dist/core/system-prompt.js").path)
    }

    private static func extractPromptTemplate(from source: String) -> String? {
        let pattern = #"(?:let|const|var)\s+prompt\s*=\s*`"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
              let matchRange = Range(match.range, in: source)
        else { return nil }
        let start = source.index(before: matchRange.upperBound)
        var index = source.index(after: start)
        var output = ""
        var escaped = false
        while index < source.endIndex {
            let character = source[index]
            if escaped {
                switch character {
                case "n": output.append("\n")
                case "r": output.append("\r")
                case "t": output.append("\t")
                default: output.append(character)
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "`" {
                return output
            } else {
                output.append(character)
            }
            index = source.index(after: index)
        }
        return nil
    }
}

private enum PiInstructionPreviewBuilder {
    static func globalPreview(existingPaths: Set<String>, drafts: [String: String], includesNativeSubagentCatalog: Bool = false) -> PiPromptPreview {
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

        if includesNativeSubagentCatalog {
            prompt += "\n\n[AGENT DECK — DECK AGENT CATALOG]"
            sections.append(subagentCatalogSection)
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
            sections.append(subagentCatalogSection)
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

    private static var builtinDefaultText: String {
        PiBuiltinPromptExtractor.extractBasePrompt() ?? """
        [PI BUILT-IN DEFAULT SYSTEM PROMPT]
        [Agent Deck could not extract Pi’s installed base prompt from the local pi package. Pi will still generate its built-in prompt at runtime when no SYSTEM.md exists.]
        """
    }

    private static var builtinDefaultSection: PiPromptPreview.Section {
        PiPromptPreview.Section(
            id: "builtin-default",
            kind: .builtinDefault,
            title: "Built-in Pi base prompt",
            sourceLabel: PiBuiltinPromptExtractor.promptSourceLabel,
            sourcePath: PiBuiltinPromptExtractor.promptSourcePath,
            content: builtinDefaultText
        )
    }

    private static var subagentCatalogSection: PiPromptPreview.Section {
        PiPromptPreview.Section(
            id: "subagent-catalog",
            kind: .subagentCatalog,
            title: "Deck agent catalog",
            sourceLabel: nil,
            sourcePath: nil,
            content: "Agent Deck inserts its Deck agent catalog here when Deck agents are enabled."
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
