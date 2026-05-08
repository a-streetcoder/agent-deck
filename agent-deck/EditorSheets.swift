import AppKit
import SwiftUI

struct EnvEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: EnvEditorDraft
    let onCancel: () -> Void
    let onSave: (EnvEditorDraft) throws -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(draft.originalKey == nil ? "New Environment Key" : "Edit Environment Key")
                .font(.title2.bold())
                .fontWidth(.expanded)

            Form {
                Section("Key") {
                    TextField("Key", text: $draft.key)
                    TextField("Value", text: $draft.value)
                    TextField("Path", text: .constant(draft.path))
                        .disabled(true)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    onCancel()
                    dismiss()
                }
                Button("Save") {
                    do {
                        draft.key = draft.key.trimmingCharacters(in: .whitespacesAndNewlines)
                        try onSave(draft)
                        dismiss()
                    } catch {
                        NSSound.beep()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(draft.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 240)
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
        VStack(alignment: .leading, spacing: 16) {
            Text(editorTitle)
                .font(.title2.bold())
                .fontWidth(.expanded)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    Form {
                        if case .custom = draft.target {
                            Section("Identity") {
                                TextField("Name", text: $draft.config.name)
                                TextField("Description", text: $draft.config.description)
                            }
                        } else {
                            Section("Builtin") {
                                TextField("Name", text: .constant(draft.originalName))
                                    .disabled(true)
                                Text("Builtin overrides only patch the supported subagent settings fields.")
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
                                editorFieldLabel("Model", help: "Default model for this agent. Agent Deck reads these from `pi --list-models`, and saved configs usually use `provider/model`.")
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
                                .pickerStyle(.menu)
                            } label: {
                                editorFieldLabel("Thinking", help: "Reasoning effort for the selected model. Pi only shows levels that the current model supports.")
                            }

                            LabeledContent {
                                TextField("", text: binding(for: \ .systemPromptMode))
                                    .labelsHidden()
                            } label: {
                                editorFieldLabel("Prompt Mode", help: "`replace` makes this agent’s prompt the main system prompt. `append` keeps more of Pi’s base behavior and adds this agent’s instructions on top.")
                            }

                            Toggle(isOn: defaultedOptionalBoolBinding(for: \ .inheritProjectContext) { draft.config.name == "delegate" }) {
                                editorFieldLabel("Inherit Project Context", help: "When enabled, the agent keeps project instruction files such as `AGENTS.md` or `CLAUDE.md`. This is prompt context, not the full parent session history.")
                            }

                            Toggle(isOn: defaultedOptionalBoolBinding(for: \ .inheritSkills, default: false)) {
                                editorFieldLabel("Inherit Skills", help: "When enabled, the agent keeps Pi’s discovered skills catalog in its prompt. This is separate from explicit skills listed on the agent itself.")
                            }

                            Toggle(isOn: optionalBoolBinding(for: \ .disabled)) {
                                editorFieldLabel("Disabled", help: "Disabled agents are hidden from normal native subagent discovery and launch flows while keeping the agent installed.")
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
                                        Button("Research") { applyToolPreset(["read", "web_search", "fetch_content", "get_search_content", "code_search"]) }
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
                                editorFieldLabel("Tool List", help: "You can edit tool names directly here. Agent Deck stores them as a comma-separated list in frontmatter.")
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
                                editorFieldLabel("Skills", help: "Choose from skills visible in this agent’s current scope. This includes reusable library skills as well as globally visible and project-visible skills.")
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
                                TextField("Default Reads", text: listBinding(for: \ .defaultReads))
                                Toggle("Default Progress", isOn: optionalBoolBinding(for: \ .defaultProgress))
                                Toggle("Interactive", isOn: optionalBoolBinding(for: \ .interactive))
                                Stepper("Max Subagent Depth: \(draft.config.maxSubagentDepth ?? 0)", value: intBinding(for: \ .maxSubagentDepth), in: 0...10)
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
                        .padding(8)
                        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    onCancel()
                    dismiss()
                }
                Button("Save") {
                    do {
                        try onSave(normalizedDraft())
                        dismiss()
                    } catch {
                        NSSound.beep()
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(minWidth: 720, minHeight: 720)
    }

    private var editorTitle: String {
        switch draft.target {
        case let .builtinOverride(scope):
            return "Edit Builtin Override · \(scope.displayName)"
        case let .custom(scope):
            return draft.sourcePath == nil ? "New Custom Agent · \(scope.displayName)" : "Edit Custom Agent · \(scope.displayName)"
        }
    }

    private func editorFieldLabel(_ title: String, help: String? = nil) -> some View {
        HStack(spacing: 6) {
            Text(title)
            if let help {
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(AppTheme.mutedText)
                    .help(help)
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
            return "Library/global agent: skills come from globally visible skills plus reusable library skills."
        case .builtinOverride(scope: .project), .custom(scope: .project):
            return "Project agent: skills come from globally visible skills, reusable library skills, and project-local skills in the selected project."
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
            Menu(group.provider) {
                ForEach(group.models) { model in
                    Button(modelMenuLabel(for: model)) {
                        select(model)
                    }
                }
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
        return ["off", "minimal", "low", "medium", "high", "xhigh"]
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

struct ChainEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: ChainEditorDraft
    let onCancel: () -> Void
    let onSave: (ChainEditorDraft) throws -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(draft.originalName == draft.chain.name && FileManager.default.fileExists(atPath: draft.chain.filePath) ? "Edit Chain" : "New Chain")
                .font(.title2.bold())
                .fontWidth(.expanded)

            Form {
                Section("Identity") {
                    TextField("Name", text: $draft.chain.name)
                    TextField("Description", text: $draft.chain.description)
                    TextField("Path", text: .constant(draft.chain.filePath))
                        .disabled(true)
                }

                Section("Steps") {
                    ForEach($draft.chain.steps) { $step in
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Agent", text: $step.agent)
                            Toggle("Disable Output", isOn: $step.outputDisabled)
                            TextField("Output", text: optionalStringBinding($step.output))
                                .disabled(step.outputDisabled)
                            Toggle("Disable Reads", isOn: $step.readsDisabled)
                            TextField("Reads", text: optionalArrayBinding($step.reads))
                                .disabled(step.readsDisabled)
                            TextField("Model", text: optionalStringBinding($step.model))
                            Toggle("Disable Skills", isOn: $step.skillsDisabled)
                            TextField("Skills", text: optionalArrayBinding($step.skills))
                                .disabled(step.skillsDisabled)
                            Toggle("Track Progress", isOn: optionalBoolBinding($step.progress))
                            TextEditor(text: $step.body)
                                .frame(minHeight: 120)
                                .font(.system(.body, design: .monospaced))
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    onCancel()
                    dismiss()
                }
                Button("Save") {
                    do {
                        try onSave(draft)
                        dismiss()
                    } catch {
                        NSSound.beep()
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 720)
    }

    private func optionalStringBinding(_ binding: Binding<String?>) -> Binding<String> {
        Binding(
            get: { binding.wrappedValue ?? "" },
            set: { binding.wrappedValue = $0.isEmpty ? nil : $0 }
        )
    }

    private func optionalArrayBinding(_ binding: Binding<[String]?>) -> Binding<String> {
        Binding(
            get: { (binding.wrappedValue ?? []).joined(separator: ", ") },
            set: {
                let values = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                binding.wrappedValue = values.isEmpty ? nil : values
            }
        )
    }

    private func optionalBoolBinding(_ binding: Binding<Bool?>) -> Binding<Bool> {
        Binding(
            get: { binding.wrappedValue ?? false },
            set: { binding.wrappedValue = $0 }
        )
    }
}
