import AppKit
import SwiftUI

/// One editable key/value pair in `EnvEditorSheet`. The `id` keeps SwiftUI's
/// `ForEach` stable while rows are added and removed; `isGlobal` routes a new
/// key to the global `.env` file instead of the project one.
private struct EnvKeyEntry: Identifiable, Equatable {
    let id = UUID()
    var key: String = ""
    var value: String = ""
    var isGlobal: Bool = false
}

/// Editor for environment keys. Creates one or more keys — each routed to the
/// project or global `.env` file with its own toggle — or edits a single
/// existing key. Follows the shared modal-sheet chrome (compact `.headline`
/// header, dividers, Cancel/Save footer) and surfaces problems as an inline
/// footer error instead of only beeping.
struct EnvEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let draft: EnvEditorDraft
    /// Root of the active project, or `nil` when none is selected. With no
    /// project open every new key is global and the per-row toggle is hidden.
    let projectRoot: String?
    let onCancel: () -> Void
    /// Persists every draft the sheet produces — several when creating keys, a
    /// single one when editing. Throwing surfaces as an inline footer error.
    let onSave: ([EnvEditorDraft]) throws -> Void

    @State private var entries: [EnvKeyEntry]
    @State private var errorMessage: String?

    init(
        draft: EnvEditorDraft,
        projectRoot: String?,
        onCancel: @escaping () -> Void,
        onSave: @escaping ([EnvEditorDraft]) throws -> Void
    ) {
        self.draft = draft
        self.projectRoot = projectRoot
        self.onCancel = onCancel
        self.onSave = onSave
        _entries = State(initialValue: [
            EnvKeyEntry(key: draft.key, value: draft.value, isGlobal: draft.scope == .global)
        ])
    }

    private var isNew: Bool { draft.originalKey == nil }
    private let keyColumnWidth: CGFloat = 200
    private let scopeColumnWidth: CGFloat = 56
    private let removeColumnWidth: CGFloat = 22

    /// The per-row Global toggle is only meaningful when creating keys with a
    /// project open — otherwise every key is global and the column is hidden.
    private var showsScopeColumn: Bool { isNew && projectRoot != nil }

    private var globalEnvPath: String {
        EnvPersistence.envFilePath(scope: .global, projectRoot: projectRoot)
    }

    private var projectEnvPath: String {
        EnvPersistence.envFilePath(scope: .project, projectRoot: projectRoot)
    }

    private var canSave: Bool {
        entries.contains { !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func abbreviate(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 600)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(isNew ? "New Environment Key" : "Edit Environment Key")
                .font(.headline)
                .fontWidth(.expanded)
            if !isNew {
                Text(abbreviate(draft.path))
                    .font(.caption.monospaced())
                    .foregroundStyle(AppTheme.mutedText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                columnHeaders
                ForEach($entries) { $entry in
                    keyRow($entry)
                }
            }

            if isNew {
                Button {
                    entries.append(EnvKeyEntry())
                } label: {
                    Label("Add another key", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)

                scopeLegend
            }
        }
        .padding(18)
        .onChange(of: entries) { _, _ in errorMessage = nil }
    }

    private var columnHeaders: some View {
        HStack(spacing: 10) {
            Text("Key")
                .frame(width: keyColumnWidth, alignment: .leading)
            Text("Value")
                .frame(maxWidth: .infinity, alignment: .leading)
            if showsScopeColumn {
                Text("Global")
                    .frame(width: scopeColumnWidth)
            }
            if isNew {
                Color.clear.frame(width: removeColumnWidth, height: 1)
            }
        }
        .font(.caption)
        .foregroundStyle(AppTheme.mutedText)
    }

    @ViewBuilder
    private func keyRow(_ entry: Binding<EnvKeyEntry>) -> some View {
        HStack(spacing: 10) {
            AppTextField(text: entry.key, placeholder: "")
                .frame(width: keyColumnWidth)
            AppTextField(text: entry.value, placeholder: "")
                .frame(maxWidth: .infinity)
            if showsScopeColumn {
                Toggle("", isOn: entry.isGlobal)
                    .appCheckbox()
                    .labelsHidden()
                    .frame(width: scopeColumnWidth)
                    .help("Store this key in the global ~/.pi/agent/.env file instead of the project's .pi/.env")
            }
            if isNew {
                Button {
                    entries.removeAll { $0.id == entry.wrappedValue.id }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .frame(width: removeColumnWidth)
                .disabled(entries.count == 1)
                .opacity(entries.count == 1 ? 0.3 : 1)
                .help("Remove this key")
            }
        }
    }

    /// Maps the per-row Global toggle to concrete files so it's clear where
    /// checked and unchecked keys are written.
    private var scopeLegend: some View {
        VStack(alignment: .leading, spacing: 3) {
            if showsScopeColumn {
                legendRow("Project", projectEnvPath)
                legendRow("Global", globalEnvPath)
            } else {
                legendRow("Global", globalEnvPath)
            }
        }
    }

    private func legendRow(_ label: String, _ path: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AppTheme.mutedText)
                .frame(width: 50, alignment: .leading)
            Text(abbreviate(path))
                .font(.caption2.monospaced())
                .foregroundStyle(AppTheme.mutedText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("Cancel") {
                onCancel()
                dismiss()
            }
            .appSecondaryButton()
            Button("Save") { save() }
                .appPrimaryButton()
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
        }
        .padding(16)
    }

    private func save() {
        errorMessage = nil
        let drafts: [EnvEditorDraft]
        do {
            drafts = try buildDrafts()
        } catch let error as ValidationError {
            errorMessage = error.message
            NSSound.beep()
            return
        } catch {
            errorMessage = error.localizedDescription
            NSSound.beep()
            return
        }
        do {
            try onSave(drafts)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            NSSound.beep()
        }
    }

    /// Validates the rows and turns them into drafts ready to persist. Throws a
    /// `ValidationError` carrying a user-facing message on the first problem.
    private func buildDrafts() throws -> [EnvEditorDraft] {
        let cleaned = entries.map {
            (
                key: $0.key.trimmingCharacters(in: .whitespacesAndNewlines),
                value: $0.value,
                isGlobal: $0.isGlobal
            )
        }
        // When creating, an untouched blank row is simply ignored; an edit keeps
        // its single row so a cleared-out key still fails validation loudly.
        let rows = isNew ? cleaned.filter { !($0.key.isEmpty && $0.value.isEmpty) } : cleaned

        guard !rows.isEmpty else {
            throw ValidationError("Enter a key name before saving.")
        }

        // A duplicate key is only a conflict within the same file — the same
        // name in the project and global files is allowed.
        var seenPerFile: [String: Set<String>] = [:]
        return try rows.map { row in
            guard !row.key.isEmpty else {
                throw ValidationError("Every key needs a name.")
            }
            guard isValidEnvKey(row.key) else {
                throw ValidationError("“\(row.key)” isn’t a valid key name — use letters, numbers, and underscores, and don’t start with a number.")
            }

            // An edit stays in the file its key already lives in; a new key
            // follows its own Global toggle (always global with no project).
            let scope: ResourceScopeKind
            let path: String
            if isNew {
                scope = (row.isGlobal || projectRoot == nil) ? .global : .project
                path = EnvPersistence.envFilePath(scope: scope, projectRoot: projectRoot)
            } else {
                scope = draft.scope
                path = draft.path
            }

            guard seenPerFile[path, default: []].insert(row.key).inserted else {
                throw ValidationError("“\(row.key)” is listed more than once.")
            }
            return EnvEditorDraft(
                originalKey: draft.originalKey,
                key: row.key,
                value: row.value,
                path: path,
                scope: scope
            )
        }
    }

    private func isValidEnvKey(_ key: String) -> Bool {
        key.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
    }

    private struct ValidationError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }
}

/// A markdown file the user can open in `MarkdownFileEditorSheet`. Identified by
/// its path so it can drive a `.sheet(item:)` presentation.
struct MarkdownFileEditTarget: Identifiable {
    let title: String
    let path: String
    let note: String?
    /// When non-nil, this target is a file that does not exist on disk yet.
    /// The editor seeds itself with this text instead of reading the file, and
    /// `save()` creates the file (and any missing parent folders) only when the
    /// user saves — so cancelling a brand-new skill or prompt persists nothing,
    /// matching the agent editor where nothing is stored until Save.
    var seedContent: String? = nil

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var displayPath: String { (path as NSString).abbreviatingWithTildeInPath }
    var isNew: Bool { seedContent != nil }
}

/// Standardized sheet for editing a markdown file's raw contents. Mirrors the
/// system-prompt instruction editor: header + path + monospaced `TextEditor` +
/// Cancel/Save. Loads an existing file on appear and writes it back on save; a
/// `seedContent` target instead starts empty-of-disk and is created only on save.
struct MarkdownFileEditorSheet: View {
    let target: MarkdownFileEditTarget
    /// Called after the file is successfully written, so the caller can refresh.
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""
    @State private var hasLoaded = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(target.title)
                        .font(.headline)
                        .fontWidth(.expanded)
                    Text(target.displayPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(AppTheme.mutedText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let note = target.note {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(AppTheme.mutedText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                if !target.isNew {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([target.url])
                    } label: {
                        Label("Reveal", systemImage: "folder")
                    }
                }
            }
            .padding(18)

            Divider()

            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(12)
                .frame(minHeight: 360)
                .disabled(!hasLoaded || errorMessage != nil)

            Divider()

            HStack {
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .appSecondaryButton()
                Button("Save") { save() }
                    .appPrimaryButton()
                    .keyboardShortcut(.defaultAction)
                    .disabled(!hasLoaded || errorMessage != nil)
            }
            .padding(16)
        }
        .frame(width: 760, height: 560)
        .task {
            guard !hasLoaded else { return }
            // A brand-new target has no file yet — seed the editor instead of
            // reading from disk. The file is created in `save()`.
            if let seedContent = target.seedContent {
                text = seedContent
                hasLoaded = true
                return
            }
            do {
                text = try String(contentsOf: target.url, encoding: .utf8)
                hasLoaded = true
            } catch {
                errorMessage = "Could not open this file: \(error.localizedDescription)"
            }
        }
    }

    private func save() {
        do {
            // New targets don't exist on disk yet — create their parent folder
            // (e.g. the skill's own directory) before writing the file.
            if target.isNew {
                try FileManager.default.createDirectory(
                    at: target.url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
            }
            try text.write(to: target.url, atomically: true, encoding: .utf8)
            onSaved()
            dismiss()
        } catch {
            errorMessage = "Could not save: \(error.localizedDescription)"
            NSSound.beep()
        }
    }
}

/// Read-only sheet showing the final system prompt sent to the agent. Mirrors the
/// `MarkdownFileEditorSheet` chrome (compact `.headline` header + Divider, 16pt
/// footer) so it reads as a proper modal rather than a cramped popover.
struct PiAgentFinalSystemPromptSheet: View {
    let text: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Final System Prompt")
                        .font(.headline)
                        .fontWidth(.expanded)
                    Text("The full system prompt sent to the agent")
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedText)
                }
                Spacer()
            }
            .padding(18)

            Divider()

            ScrollView {
                Text(text)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .frame(minHeight: 360)

            Divider()

            HStack {
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .appSecondaryButton()
                Button("Done") { dismiss() }
                    .appPrimaryButton()
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 720, height: 600)
    }
}

struct NewSkillDraft: Identifiable {
    var name: String
    var description: String
    var body: String

    var id: String { name }
}

struct NewSkillEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var draft: NewSkillDraft
    @State private var errorMessage: String?

    private let identityLabelWidth: CGFloat = 120

    let destinationPath: String
    let onSave: (NewSkillDraft) throws -> Void

    init(draft: NewSkillDraft, destinationPath: String, onSave: @escaping (NewSkillDraft) throws -> Void) {
        _draft = State(initialValue: draft)
        self.destinationPath = destinationPath
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New Skill")
                    .font(.headline)
                    .fontWidth(.expanded)
                Text(destinationDisplayPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(AppTheme.mutedText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Create the skill folder, frontmatter, and `SKILL.md` from these fields when you save.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)
            }
            .padding(18)

            Divider()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Identity")
                            .font(.headline)
                            .fontWidth(.expanded)

                        VStack(alignment: .leading, spacing: 12) {
                            LabeledContent {
                                AppTextField(text: nameBinding, placeholder: "macos-development")
                                    .labelsHidden()
                            } label: {
                                fieldLabel(
                                    "Skill name",
                                    help: "Use a lowercase slug with letters, numbers, and hyphens. This becomes the folder name and frontmatter `name`."
                                )
                                .frame(width: identityLabelWidth, alignment: .leading)
                            }

                            LabeledContent {
                                AppTextField(text: $draft.description, placeholder: "What the skill does and when Pi should use it", axis: .vertical)
                                    .lineLimit(2...4)
                                    .labelsHidden()
                            } label: {
                                fieldLabel(
                                    "Description",
                                    help: "This becomes the frontmatter `description`. Keep it specific enough that Pi knows when to use the skill."
                                )
                                .frame(width: identityLabelWidth, alignment: .leading)
                            }
                        }
                    }
                    .padding(18)
                    .appContentSurface()

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Instructions")
                            .font(.headline)
                            .fontWidth(.expanded)
                        Text("Write the body of `SKILL.md` here. Agent Deck adds the `# \(previewName)` heading above this content automatically.")
                            .font(.caption)
                            .foregroundStyle(AppTheme.mutedText)

                        TextEditor(text: $draft.body)
                            .font(.system(.body, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 260)
                            .padding(10)
                            .background(AppTheme.contentFill)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(AppTheme.contentStroke, lineWidth: 1)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .padding(18)
                    .appContentSurface()

                    VStack(alignment: .leading, spacing: 10) {
                        Text("What Gets Created")
                            .font(.headline)
                            .fontWidth(.expanded)

                        VStack(alignment: .leading, spacing: 12) {
                            outputRow("Folder", value: outputFolderDisplayPath)
                            outputRow("File", value: outputFileDisplayPath)
                            outputRow("Heading", value: "# \(previewName)")

                            Divider()

                            Text("Generated `SKILL.md` preview")
                                .font(.subheadline.weight(.semibold))
                            previewBlock
                        }
                    }
                    .padding(18)
                    .appContentSurface()
                }
                .padding(18)
            }

            Divider()

            HStack {
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .appSecondaryButton()
                Button("Save") { save() }
                    .appPrimaryButton()
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding(16)
        }
        .frame(width: 760, height: 640)
    }

    private var destinationDisplayPath: String {
        (destinationPath as NSString).abbreviatingWithTildeInPath
    }

    private var outputFolderDisplayPath: String {
        let folder = URL(fileURLWithPath: destinationPath).deletingLastPathComponent().path
        return (folder as NSString).abbreviatingWithTildeInPath
    }

    private var outputFileDisplayPath: String {
        destinationDisplayPath
    }

    private var previewName: String {
        draft.name.isEmpty ? "skill-name" : draft.name
    }

    private var canSave: Bool {
        !draft.name.isEmpty && !draft.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var nameBinding: Binding<String> {
        Binding(
            get: { draft.name },
            set: { draft.name = Self.sanitizedSkillName($0) }
        )
    }

    @ViewBuilder
    private var previewBlock: some View {
        let preview = """
        ---
        name: \(previewName)
        description: \(draft.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Describe what this skill does and when Pi should use it." : draft.description.trimmingCharacters(in: .whitespacesAndNewlines))
        ---

        # \(previewName)

        \(draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Document the skill instructions here." : draft.body.trimmingCharacters(in: .whitespacesAndNewlines))
        """

        Text(preview)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.contentFill)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(AppTheme.contentStroke, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func fieldLabel(_ title: String, help: String? = nil) -> some View {
        HStack(spacing: 6) {
            Text(title)
            if let help {
                AppHelpButton(text: help)
            }
        }
    }

    private func outputRow(_ title: String, value: String) -> some View {
        LabeledContent {
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .foregroundStyle(.primary)
        } label: {
            Text(title)
                .foregroundStyle(AppTheme.mutedText)
                .frame(width: identityLabelWidth, alignment: .leading)
        }
    }

    private func save() {
        do {
            draft.description = draft.description.trimmingCharacters(in: .whitespacesAndNewlines)
            draft.body = draft.body.trimmingCharacters(in: .whitespacesAndNewlines)
            try onSave(draft)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            NSSound.beep()
        }
    }

    private static func sanitizedSkillName(_ rawValue: String) -> String {
        let lowercased = rawValue.lowercased()
        var result = ""
        var lastWasHyphen = false

        for scalar in lowercased.unicodeScalars {
            switch scalar {
            case "a"..."z", "0"..."9":
                result.unicodeScalars.append(scalar)
                lastWasHyphen = false
            case "-", "_", " ":
                if !result.isEmpty, !lastWasHyphen {
                    result.append("-")
                    lastWasHyphen = true
                }
            default:
                continue
            }
        }

        while result.hasPrefix("-") { result.removeFirst() }
        while result.hasSuffix("-") { result.removeLast() }
        return result
    }
}

struct AgentEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: AgentEditorDraft
    let availableTools: [String]
    let availableSkills: [String]
    let availableModels: [AvailableModel]
    let modelsLastUpdatedAt: Date?
    let onCancel: () -> Void
    let onSave: (AgentEditorDraft) throws -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(editorTitle)
                    .font(.headline)
                    .fontWidth(.expanded)
                if let editorSubtitle {
                    Text(editorSubtitle)
                        .font(.caption.monospaced())
                        .foregroundStyle(AppTheme.mutedText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(18)

            Divider()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    Form {
                        if case .custom = draft.target {
                            Section("Identity") {
                                TextField("Name", text: $draft.config.name)
                                TextField("Description", text: $draft.config.description)
                                TextField("When to Use", text: binding(for: \.whenToUse))
                                    .help("Concise routing guidance injected into parent sessions when Deck agents are enabled. Prefer one short sentence.")
                            }
                        } else {
                            Section("Builtin") {
                                TextField("Name", text: .constant(draft.originalName))
                                    .disabled(true)
                                Text("Builtin overrides only patch the supported Deck agent settings fields.")
                                    .foregroundStyle(AppTheme.mutedText)
                            }
                        }

                        Section("Behavior") {
                            Text(modelSelectionSummary)
                                .foregroundStyle(AppTheme.mutedText)

                            LabeledContent {
                                TextField("", text: binding(for: \ .model))
                                    .labelsHidden()
                            } label: {
                                editorFieldLabel("Model", help: "Default model for this agent. \(AppBrand.displayName) reads these from `pi --list-models`, and saved configs usually use `provider/model`.")
                            }

                            LabeledContent {
                                Menu("Choose Model") {
                                    Button("Use Pi Default Model") {
                                        draft.config.model = nil
                                        clampThinkingForSelectedModel()
                                    }
                                    Divider()
                                    modelPickerMenu { model in
                                        draft.config.model = model.identifier
                                        clampThinkingForSelectedModel()
                                    }
                                }
                            } label: {
                                editorFieldLabel("Choose Model", help: "Pick from models Pi currently knows about. Choosing one also constrains the thinking levels shown below.")
                            }

                            LabeledContent {
                                TextField("", text: arrayBinding(for: \ .fallbackModels))
                                    .labelsHidden()
                            } label: {
                                editorFieldLabel("Fallback Models", help: "Ordered backup models Pi can try if the primary model is unavailable or a pattern resolves differently.")
                            }

                            LabeledContent {
                                Menu("Add Fallback Model") {
                                    modelPickerMenu { model in
                                        addFallbackModel(model.identifier)
                                    }
                                }
                            } label: {
                                editorFieldLabel("Add Fallback Model", help: "Adds one model to the fallback list without editing the comma-separated field manually.")
                            }

                            selectedListView(title: "Selected Fallback Models", values: draft.config.fallbackModels, remove: removeFallbackModel)

                            LabeledContent {
                                Picker("", selection: thinkingSelectionBinding) {
                                    ForEach(availableThinkingLevelsForDraft, id: \.self) { level in
                                        Text(level).tag(level)
                                    }
                                }
                                .labelsHidden()
                                .appMenuPicker()
                            } label: {
                                editorFieldLabel("Thinking", help: "Reasoning effort for the selected model. Pi only shows levels that the current model supports.")
                            }

                            LabeledContent {
                                TextField("", text: binding(for: \ .systemPromptMode))
                                    .labelsHidden()
                            } label: {
                                editorFieldLabel("Prompt Mode", help: "`replace` makes this agent’s prompt the main system prompt. `append` keeps more of Pi’s base behavior and adds this agent’s instructions on top.")
                            }

                            Toggle(isOn: optionalBoolBinding(for: \ .disabled)) {
                                editorFieldLabel("Disabled", help: "Disabled agents are hidden from normal Deck agent discovery and launch flows while keeping the agent installed.")
                            }
                        }

                        Section("Tools & Skills") {
                            Text(toolSelectionSummary)
                                .foregroundStyle(AppTheme.mutedText)

                            LabeledContent {
                                HStack(spacing: 10) {
                                    Menu("Choose Tool") {
                                        ForEach(availableTools, id: \.self) { tool in
                                            Button(tool) { addTool(tool) }
                                        }
                                    }

                                    Menu("Apply Preset") {
                                        Button("Core") { applyToolPreset(["read", "grep", "find", "ls", "bash"]) }
                                        Button("Coding") { applyToolPreset(["read", "grep", "find", "ls", "bash", "edit", "write"]) }
                                        if availableTools.contains("web_search") {
                                            Button("Research") { applyToolPreset(["read", "web_search", "fetch_content", "get_search_content"]) }
                                        } else if availableTools.contains("web_fetch") {
                                            Button("URL Fetch") { applyToolPreset(["read", "web_fetch"]) }
                                        }
                                        Button("Clear Tools") { draft.config.tools = [] }
                                    }
                                }
                            } label: {
                                editorFieldLabel("Tools", help: "Explicit tools become the agent’s allowlist. New custom agents start with a core preset: read, grep, find, ls, bash.")
                            }

                            LabeledContent {
                                TextField("Comma-separated tools", text: toolsBinding())
                                    .labelsHidden()
                            } label: {
                                editorFieldLabel("Tool List", help: "You can edit tool names directly here. \(AppBrand.displayName) stores them as a comma-separated list in frontmatter.")
                            }

                            selectedListView(title: "Selected Tools", values: selectedToolValues, remove: removeTool)

                            Text(skillSelectionSummary)
                                .foregroundStyle(AppTheme.mutedText)

                            LabeledContent {
                                Menu("Choose Skill") {
                                    ForEach(availableSkills, id: \.self) { skill in
                                        Button(skill) { addSkill(skill) }
                                    }
                                }
                            } label: {
                                editorFieldLabel("Skills", help: "Choose from Agent Deck's skill catalog. Assigned skills are passed to Pi with native --skill arguments when this agent runs.")
                            }

                            LabeledContent {
                                TextField("Comma-separated skills", text: arrayBinding(for: \ .skills))
                                    .labelsHidden()
                            } label: {
                                editorFieldLabel("Skill List", help: "Explicit skills are attached by name to this agent. You can add them from the picker above or edit the list directly here.")
                            }

                            selectedListView(title: "Selected Skills", values: draft.config.skills, remove: removeSkill)
                        }

                        if case .custom = draft.target {
                            Section("Files") {
                                TextField("Extensions", text: listBinding(for: \ .extensions))
                                TextField("Output", text: binding(for: \ .output))
                                Picker("Default Outcome", selection: defaultExpectedOutcomeBinding()) {
                                    Text("Unspecified").tag(PiSubagentExpectedOutcome?.none)
                                    ForEach(PiSubagentExpectedOutcome.allCases) { outcome in
                                        Text(outcome.displayName).tag(Optional(outcome))
                                    }
                                }
                                TextField("Default Reads", text: listBinding(for: \ .defaultReads))
                                Toggle("Default Progress", isOn: optionalBoolBinding(for: \ .defaultProgress))
                                Toggle("Interactive", isOn: optionalBoolBinding(for: \ .interactive))
                                Stepper("Max Subagent Depth: \(draft.config.maxSubagentDepth ?? 0)", value: intBinding(for: \ .maxSubagentDepth), in: 0...10)
                                    .appBrandTint()
                            }
                        }
                    }
                    .formStyle(.grouped)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Prompt")
                            .font(.headline)
                            .fontWidth(.expanded)
                        Text(promptSectionSummary)
                            .foregroundStyle(AppTheme.mutedText)
                        TextEditor(text: Binding(
                            get: { draft.config.systemPrompt },
                            set: { draft.config.systemPrompt = $0 }
                        ))
                        .frame(minHeight: 320)
                        .font(.system(.body, design: .monospaced))
                        .scrollContentBackground(.hidden)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 18)
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel") {
                    onCancel()
                    dismiss()
                }
                .appSecondaryButton()
                Button("Save") {
                    do {
                        try onSave(normalizedDraft())
                        dismiss()
                    } catch {
                        NSSound.beep()
                    }
                }
                .appPrimaryButton()
            }
            .padding(16)
        }
        .frame(width: 720, height: 720)
    }

    private var editorTitle: String {
        switch draft.target {
        case let .builtinOverride(scope):
            return "Edit Builtin Override · \(scope.displayName)"
        case let .custom(scope):
            return draft.sourcePath == nil ? "New Custom Agent · \(scope.displayName)" : "Edit Custom Agent · \(scope.displayName)"
        }
    }

    private var editorSubtitle: String? {
        guard let path = draft.sourcePath else { return nil }
        return (path as NSString).abbreviatingWithTildeInPath
    }

    private func editorFieldLabel(_ title: String, help: String? = nil) -> some View {
        HStack(spacing: 6) {
            Text(title)
            if let help {
                AppHelpButton(text: help)
            }
        }
    }

    private func applyToolPreset(_ tools: [String]) {
        let allowed = Set(availableTools)
        draft.config.tools = tools.filter { allowed.contains($0) }
    }

    private var modelSelectionSummary: String {
        let freshness = modelsLastUpdatedAt.map { date in
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            return " Refreshed \(formatter.localizedString(for: date, relativeTo: Date()))."
        } ?? ""
        return "Available models come from `pi --list-models` and are cached in the app on refresh.\(freshness)"
    }

    private var toolSelectionSummary: String {
        switch draft.target {
        case .builtinOverride(scope: .global), .custom(scope: .global), .custom(scope: .library):
            return "Library/global agent: tools are based on the global environment only."
        case .builtinOverride(scope: .project), .custom(scope: .project):
            return "Project agent: tools are based on global + selected project scope."
        }
    }

    private var skillSelectionSummary: String {
        switch draft.target {
        case .builtinOverride(scope: .global), .custom(scope: .global), .custom(scope: .library):
            return "Choose catalog skills to assign explicitly to this agent. Agents do not inherit Default or Project skills."
        case .builtinOverride(scope: .project), .custom(scope: .project):
            return "Choose catalog skills to assign explicitly to this agent. Agents do not inherit Default or Project skills."
        }
    }

    private var promptSectionSummary: String {
        switch draft.target {
        case .builtinOverride:
            return "This prompt is saved as the builtin override’s `systemPrompt` patch in settings."
        case .custom:
            return "This prompt is saved in the markdown body of the agent file."
        }
    }

    @ViewBuilder
    private func modelPickerMenu(select: @escaping (AvailableModel) -> Void) -> some View {
        ForEach(groupedAvailableModels, id: \.provider) { group in
            Menu {
                ForEach(group.models) { model in
                    Button(modelMenuLabel(for: model)) {
                        select(model)
                    }
                }
            } label: {
                ProviderLabel(provider: group.provider)
            }
        }
    }

    private var groupedAvailableModels: [(provider: String, models: [AvailableModel])] {
        Dictionary(grouping: availableModels, by: \.provider)
            .map { provider, models in
                (
                    provider: provider,
                    models: models.sorted { $0.model.localizedCaseInsensitiveCompare($1.model) == .orderedAscending }
                )
            }
            .sorted { $0.provider.localizedCaseInsensitiveCompare($1.provider) == .orderedAscending }
    }

    private func modelMenuLabel(for model: AvailableModel) -> String {
        let thinking = model.supportsThinking ? "thinking" : "no thinking"
        let images = model.supportsImages ? "images" : "text"
        return "\(model.model) · \(thinking) · \(images) · ctx \(model.contextWindow) · out \(model.maxOutput)"
    }

    private var selectedAvailableModel: AvailableModel? {
        guard let identifier = draft.config.model else { return nil }
        return availableModels.first(where: { $0.identifier == identifier })
    }

    private var availableThinkingLevelsForDraft: [String] {
        if let model = selectedAvailableModel {
            return model.supportedThinkingLevels
        }
        return []
    }

    private var thinkingSelectionBinding: Binding<String> {
        Binding(
            get: {
                let current = draft.config.thinking ?? "off"
                return availableThinkingLevelsForDraft.contains(current) ? current : (availableThinkingLevelsForDraft.first ?? "off")
            },
            set: { draft.config.thinking = $0 == "off" ? nil : $0 }
        )
    }

    private func normalizedDraft() -> AgentEditorDraft {
        var copy = draft
        copy.config.whenToUse = copy.config.whenToUse?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        copy.config.fallbackModels = normalizedList(copy.config.fallbackModels) ?? []
        copy.config.tools = normalizedList(copy.config.tools)
        copy.config.mcpDirectTools = normalizedList(copy.config.mcpDirectTools)
        copy.config.skills = normalizedList(copy.config.skills) ?? []
        copy.config.extensions = copy.config.extensions == nil ? nil : (normalizedList(copy.config.extensions) ?? [])
        return copy
    }

    @ViewBuilder
    private func selectedListView(title: String, values: [String], remove: @escaping (String) -> Void) -> some View {
        if !values.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 8)], spacing: 8) {
                    ForEach(values, id: \.self) { value in
                        HStack(spacing: 8) {
                            Text(value)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Button {
                                remove(value)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    private var selectedToolValues: [String] {
        (draft.config.tools ?? []) + (draft.config.mcpDirectTools ?? []).map { "mcp:\($0)" }
    }

    private func addTool(_ tool: String) {
        var values = selectedToolValues
        guard !values.contains(tool) else { return }
        values.append(tool)
        applyToolValues(values)
    }

    private func removeTool(_ tool: String) {
        applyToolValues(selectedToolValues.filter { $0 != tool })
    }

    private func applyToolValues(_ values: [String]) {
        var tools: [String] = []
        var mcpTools: [String] = []
        for value in values {
            if value.hasPrefix("mcp:") {
                let name = String(value.dropFirst(4))
                if !name.isEmpty { mcpTools.append(name) }
            } else {
                tools.append(value)
            }
        }
        draft.config.tools = tools.isEmpty ? nil : tools
        draft.config.mcpDirectTools = mcpTools.isEmpty ? nil : mcpTools
    }

    private func clampThinkingForSelectedModel() {
        let available = availableThinkingLevelsForDraft
        let current = draft.config.thinking ?? "off"
        if available.contains(current) { return }
        draft.config.thinking = (available.first ?? "off") == "off" ? nil : (available.first ?? "off")
    }

    private func addFallbackModel(_ model: String) {
        guard !draft.config.fallbackModels.contains(model) else { return }
        draft.config.fallbackModels.append(model)
    }

    private func removeFallbackModel(_ model: String) {
        draft.config.fallbackModels.removeAll { $0 == model }
    }

    private func addSkill(_ skill: String) {
        guard !draft.config.skills.contains(skill) else { return }
        draft.config.skills.append(skill)
    }

    private func removeSkill(_ skill: String) {
        draft.config.skills.removeAll { $0 == skill }
    }

    private func normalizedList(_ value: [String]?) -> [String]? {
        guard let value else { return nil }
        let items = value.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return items.isEmpty ? nil : items
    }

    private func binding(for keyPath: WritableKeyPath<AgentConfig, String?>) -> Binding<String> {
        Binding(
            get: { draft.config[keyPath: keyPath] ?? "" },
            set: { draft.config[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }

    private func binding(for keyPath: WritableKeyPath<AgentConfig, String>) -> Binding<String> {
        Binding(
            get: { draft.config[keyPath: keyPath] },
            set: { draft.config[keyPath: keyPath] = $0 }
        )
    }

    private func binding(for keyPath: WritableKeyPath<AgentConfig, String?>, fallback: String) -> Binding<String> {
        Binding(
            get: { draft.config[keyPath: keyPath] ?? fallback },
            set: { draft.config[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }

    private func defaultExpectedOutcomeBinding() -> Binding<PiSubagentExpectedOutcome?> {
        Binding(
            get: { draft.config.defaultExpectedOutcome },
            set: { draft.config.defaultExpectedOutcome = $0 }
        )
    }

    private func listBinding(for keyPath: WritableKeyPath<AgentConfig, [String]?>) -> Binding<String> {
        Binding(
            get: { (draft.config[keyPath: keyPath] ?? []).joined(separator: ", ") },
            set: { input in
                let values = input.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                draft.config[keyPath: keyPath] = values.isEmpty ? nil : values
            }
        )
    }

    private func toolsBinding() -> Binding<String> {
        Binding(
            get: {
                ((draft.config.tools ?? []) + (draft.config.mcpDirectTools ?? []).map { "mcp:\($0)" }).joined(separator: ", ")
            },
            set: { input in
                let items = input.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                var tools: [String] = []
                var mcp: [String] = []
                for item in items {
                    if item.hasPrefix("mcp:") {
                        let name = String(item.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !name.isEmpty { mcp.append(name) }
                    } else {
                        tools.append(item)
                    }
                }
                draft.config.tools = tools.isEmpty ? nil : tools
                draft.config.mcpDirectTools = mcp.isEmpty ? nil : mcp
            }
        )
    }

    private func arrayBinding(for keyPath: WritableKeyPath<AgentConfig, [String]>) -> Binding<String> {
        Binding(
            get: { draft.config[keyPath: keyPath].joined(separator: ", ") },
            set: { input in
                draft.config[keyPath: keyPath] = input.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            }
        )
    }

    private func binding(for keyPath: WritableKeyPath<AgentConfig, String?>, listSeparator: Bool) -> Binding<String> {
        binding(for: keyPath)
    }

    private func binding(for keyPath: WritableKeyPath<AgentConfig, String?>, default defaultValue: String) -> Binding<String> {
        binding(for: keyPath, fallback: defaultValue)
    }

    private func defaultedOptionalBoolBinding(for keyPath: WritableKeyPath<AgentConfig, Bool?>, default defaultValue: Bool) -> Binding<Bool> {
        Binding(
            get: { draft.config[keyPath: keyPath] ?? defaultValue },
            set: { draft.config[keyPath: keyPath] = $0 }
        )
    }

    private func defaultedOptionalBoolBinding(for keyPath: WritableKeyPath<AgentConfig, Bool?>, _ defaultValue: @escaping () -> Bool) -> Binding<Bool> {
        Binding(
            get: { draft.config[keyPath: keyPath] ?? defaultValue() },
            set: { draft.config[keyPath: keyPath] = $0 }
        )
    }

    private func optionalBoolBinding(for keyPath: WritableKeyPath<AgentConfig, Bool?>) -> Binding<Bool> {
        Binding(
            get: { draft.config[keyPath: keyPath] ?? false },
            set: { draft.config[keyPath: keyPath] = $0 }
        )
    }

    private func intBinding(for keyPath: WritableKeyPath<AgentConfig, Int?>) -> Binding<Int> {
        Binding(
            get: { draft.config[keyPath: keyPath] ?? 0 },
            set: { draft.config[keyPath: keyPath] = $0 }
        )
    }
}
