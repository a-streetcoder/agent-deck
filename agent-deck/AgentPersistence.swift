import Foundation

struct AgentPersistence {
    private let fileManager = FileManager.default

    func makeDraft(for agent: EffectiveAgentRecord, preferredOverrideScope: AgentEditingTarget.OverrideScope? = nil) -> AgentEditorDraft? {
        if let projectCustom = agent.projectCustom {
            return AgentEditorDraft(
                target: .custom(scope: .project),
                originalName: agent.name,
                config: projectCustom.parsed,
                sourcePath: projectCustom.filePath
            )
        }

        if let globalCustom = agent.globalCustom {
            return AgentEditorDraft(
                target: .custom(scope: .global),
                originalName: agent.name,
                config: globalCustom.parsed,
                sourcePath: globalCustom.filePath
            )
        }

        guard let builtin = agent.builtin?.parsed else { return nil }
        let scope: AgentEditingTarget.OverrideScope = preferredOverrideScope ?? .global
        let seededConfig = seededBuiltinOverrideConfig(for: agent, base: builtin, scope: scope)
        return AgentEditorDraft(
            target: .builtinOverride(scope: scope),
            originalName: agent.name,
            config: seededConfig,
            sourcePath: agent.sourcePath
        )
    }

    func save(_ draft: AgentEditorDraft, original effectiveAgent: EffectiveAgentRecord, projectRoot: String?) throws {
        switch draft.target {
        case let .custom(scope):
            try saveCustomAgent(draft.config, scope: scope, originalName: draft.originalName, sourcePath: draft.sourcePath, projectRoot: projectRoot)
        case let .builtinOverride(scope):
            try saveBuiltinOverride(draft.config, original: effectiveAgent, scope: scope, projectRoot: projectRoot)
        }
    }

    func makeNewDraft(scope: AgentEditingTarget.CustomAgentScope, base: AgentConfig = .empty) -> AgentEditorDraft {
        AgentEditorDraft(
            target: .custom(scope: scope),
            originalName: base.name,
            config: base,
            sourcePath: nil
        )
    }

    func saveNewCustomAgent(_ draft: AgentEditorDraft, projectRoot: String?) throws {
        guard case let .custom(scope) = draft.target else {
            throw PersistenceError.invalidDraftTarget
        }
        try saveCustomAgent(draft.config, scope: scope, originalName: draft.originalName, sourcePath: draft.sourcePath, projectRoot: projectRoot)
    }

    private func saveCustomAgent(_ config: AgentConfig, scope: AgentEditingTarget.CustomAgentScope, originalName: String, sourcePath: String?, projectRoot: String?) throws {
        let path = sourcePath ?? customAgentPath(name: config.name, scope: scope, projectRoot: projectRoot)
        guard isWritableCustomAgentPath(path, scope: scope, projectRoot: projectRoot) else {
            throw PersistenceError.invalidWriteTarget(path)
        }

        if let sourcePath, sourcePath != path, fileManager.fileExists(atPath: sourcePath) {
            try fileManager.removeItem(atPath: sourcePath)
        } else if config.name != originalName {
            let oldPath = customAgentPath(name: originalName, scope: scope, projectRoot: projectRoot)
            if oldPath != path, fileManager.fileExists(atPath: oldPath) {
                try fileManager.removeItem(atPath: oldPath)
            }
        }

        try writeText(serializeAgent(config), to: path)
    }

    private func seededBuiltinOverrideConfig(for agent: EffectiveAgentRecord, base: AgentConfig, scope: AgentEditingTarget.OverrideScope) -> AgentConfig {
        switch scope {
        case .global:
            return applyBuiltinOverride(agent.userOverride, to: base)
        case .project:
            return applyBuiltinOverride(agent.projectOverride, to: applyBuiltinOverride(agent.userOverride, to: base))
        }
    }

    private func applyBuiltinOverride(_ override: BuiltinOverrideRecord?, to config: AgentConfig) -> AgentConfig {
        guard let override else { return config }
        var result = config

        for (key, rawValue) in override.values {
            switch key {
            case "whenToUse":
                if let value = rawValue as? String { result.whenToUse = value }
                else if rawValue as? Bool == false { result.whenToUse = nil }
            case "model":
                if let value = rawValue as? String { result.model = value }
                else if rawValue as? Bool == false { result.model = nil }
            case "thinking":
                if let value = rawValue as? String { result.thinking = value }
                else if rawValue as? Bool == false { result.thinking = nil }
            case "systemPromptMode":
                if let value = rawValue as? String { result.systemPromptMode = value }
            case "inheritProjectContext":
                if let value = rawValue as? Bool { result.inheritProjectContext = value }
            case "inheritSkills":
                if let value = rawValue as? Bool { result.inheritSkills = value }
            case "defaultContext":
                if let value = rawValue as? String { result.defaultContext = value }
                else if rawValue as? Bool == false { result.defaultContext = nil }
            case "disabled":
                if let value = rawValue as? Bool { result.disabled = value }
            case "skills":
                if rawValue as? Bool == false { result.skills = [] }
                else if let values = splitJSONArray(rawValue) { result.skills = values }
            case "tools":
                if rawValue as? Bool == false {
                    result.tools = nil
                    result.mcpDirectTools = nil
                } else if let values = splitJSONArray(rawValue) {
                    let parsedTools = splitToolList(values.joined(separator: ", "))
                    result.tools = parsedTools.tools
                    result.mcpDirectTools = parsedTools.mcpDirectTools
                }
            case "fallbackModels":
                if rawValue as? Bool == false { result.fallbackModels = [] }
                else if let values = splitJSONArray(rawValue) { result.fallbackModels = values }
            case "systemPrompt":
                if let value = rawValue as? String { result.systemPrompt = value }
            default:
                break
            }
        }

        return result
    }

    private func saveBuiltinOverride(_ edited: AgentConfig, original: EffectiveAgentRecord, scope: AgentEditingTarget.OverrideScope, projectRoot: String?) throws {
        guard let builtin = original.builtin?.parsed else {
            throw PersistenceError.missingBuiltinBase(original.name)
        }

        let overridePath = settingsPath(for: scope, projectRoot: projectRoot)
        let overrideValues = buildBuiltinOverride(base: builtin, edited: edited)
        var root = try loadJSONObject(at: overridePath)
        var subagents = root["subagents"] as? [String: Any] ?? [:]
        var agentOverrides = subagents["agentOverrides"] as? [String: Any] ?? [:]

        if let overrideValues {
            agentOverrides[original.name] = overrideValues
        } else {
            agentOverrides.removeValue(forKey: original.name)
        }

        if agentOverrides.isEmpty {
            subagents.removeValue(forKey: "agentOverrides")
        } else {
            subagents["agentOverrides"] = agentOverrides
        }

        if subagents.isEmpty {
            root.removeValue(forKey: "subagents")
        } else {
            root["subagents"] = subagents
        }

        try writeJSON(root, to: overridePath)
    }

    private func buildBuiltinOverride(base: AgentConfig, edited: AgentConfig) -> [String: Any]? {
        var values: [String: Any] = [:]

        if edited.whenToUse != base.whenToUse { values["whenToUse"] = edited.whenToUse ?? false }
        if edited.model != base.model { values["model"] = edited.model ?? false }
        if !arraysEqual(edited.fallbackModels, base.fallbackModels) { values["fallbackModels"] = edited.fallbackModels.isEmpty ? false : edited.fallbackModels }
        if edited.thinking != base.thinking { values["thinking"] = edited.thinking ?? false }
        let editedPromptMode = edited.systemPromptMode ?? defaultSystemPromptMode(name: edited.name)
        let basePromptMode = base.systemPromptMode ?? defaultSystemPromptMode(name: base.name)
        if editedPromptMode != basePromptMode { values["systemPromptMode"] = editedPromptMode }
        let editedProjectContext = edited.inheritProjectContext ?? defaultInheritProjectContext(name: edited.name)
        let baseProjectContext = base.inheritProjectContext ?? defaultInheritProjectContext(name: base.name)
        if editedProjectContext != baseProjectContext { values["inheritProjectContext"] = editedProjectContext }
        let editedInheritSkills = edited.inheritSkills ?? false
        let baseInheritSkills = base.inheritSkills ?? false
        if editedInheritSkills != baseInheritSkills { values["inheritSkills"] = editedInheritSkills }
        if edited.defaultContext != base.defaultContext { values["defaultContext"] = edited.defaultContext ?? false }
        if edited.disabled != base.disabled { values["disabled"] = edited.disabled ?? false }
        if !arraysEqual(edited.skills, base.skills) { values["skills"] = edited.skills.isEmpty ? false : edited.skills }
        let editedToolList = joinedTools(from: edited)
        let baseToolList = joinedTools(from: base)
        if !arraysEqual(editedToolList, baseToolList) { values["tools"] = editedToolList ?? false }
        if edited.systemPrompt != base.systemPrompt { values["systemPrompt"] = edited.systemPrompt }

        return values.isEmpty ? nil : values
    }

    func serializedText(for config: AgentConfig) -> String {
        serializeAgent(config)
    }

    func builtinOverrideValuesForTesting(base: AgentConfig, edited: AgentConfig) -> [String: Any]? {
        buildBuiltinOverride(base: base, edited: edited)
    }

    func setDisableBuiltins(_ isDisabled: Bool?, scope: AgentEditingTarget.OverrideScope, projectRoot: String?) throws {
        let path = settingsPath(for: scope, projectRoot: projectRoot)
        var root = try loadJSONObject(at: path)
        var subagents = root["subagents"] as? [String: Any] ?? [:]

        if let isDisabled {
            subagents["disableBuiltins"] = isDisabled
        } else {
            subagents.removeValue(forKey: "disableBuiltins")
        }

        if subagents.isEmpty {
            root.removeValue(forKey: "subagents")
        } else {
            root["subagents"] = subagents
        }

        try writeJSON(root, to: path)
    }

    func setBuiltinDisabled(_ isDisabled: Bool, for agent: EffectiveAgentRecord, scope: AgentEditingTarget.OverrideScope, projectRoot: String?) throws {
        let path = settingsPath(for: scope, projectRoot: projectRoot)
        var root = try loadJSONObject(at: path)
        var subagents = root["subagents"] as? [String: Any] ?? [:]
        var agentOverrides = subagents["agentOverrides"] as? [String: Any] ?? [:]
        var overrideValues = agentOverrides[agent.name] as? [String: Any] ?? [:]

        overrideValues["disabled"] = isDisabled

        if overrideValues.isEmpty {
            agentOverrides.removeValue(forKey: agent.name)
        } else {
            agentOverrides[agent.name] = overrideValues
        }

        if agentOverrides.isEmpty {
            subagents.removeValue(forKey: "agentOverrides")
        } else {
            subagents["agentOverrides"] = agentOverrides
        }

        if subagents.isEmpty {
            root.removeValue(forKey: "subagents")
        } else {
            root["subagents"] = subagents
        }

        try writeJSON(root, to: path)
    }

    private func splitToolList(_ value: String?) -> (tools: [String]?, mcpDirectTools: [String]?) {
        let items = splitList(value)
        var tools: [String] = []
        var mcpDirectTools: [String] = []
        for item in items {
            if item.hasPrefix("mcp:") {
                let name = String(item.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { mcpDirectTools.append(name) }
            } else {
                tools.append(item)
            }
        }
        return (tools.isEmpty ? nil : tools, mcpDirectTools.isEmpty ? nil : mcpDirectTools)
    }

    private func splitJSONArray(_ value: Any) -> [String]? {
        guard let array = value as? [Any] else { return nil }
        let values = array.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return values
    }

    private func splitList(_ value: String?) -> [String] {
        guard let value, !value.isEmpty else { return [] }
        return value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func serializeAgent(_ config: AgentConfig) -> String {
        var lines: [String] = ["---"]
        lines.append("name: \(config.name)")
        lines.append("description: \(config.description)")
        if let whenToUse = config.whenToUse?.trimmingCharacters(in: .whitespacesAndNewlines), !whenToUse.isEmpty { lines.append("whenToUse: \(whenToUse)") }
        if let tools = joinComma(joinedTools(from: config)) { lines.append("tools: \(tools)") }
        if let model = config.model { lines.append("model: \(model)") }
        if let fallbackModels = joinComma(config.fallbackModels) { lines.append("fallbackModels: \(fallbackModels)") }
        if let thinking = config.thinking, thinking != "off" { lines.append("thinking: \(thinking)") }
        lines.append("systemPromptMode: \(config.systemPromptMode ?? defaultSystemPromptMode(name: config.name))")
        lines.append("inheritProjectContext: \((config.inheritProjectContext ?? defaultInheritProjectContext(name: config.name)) ? "true" : "false")")
        lines.append("inheritSkills: \((config.inheritSkills ?? false) ? "true" : "false")")
        if let defaultContext = config.defaultContext { lines.append("defaultContext: \(defaultContext)") }
        if let skills = joinComma(config.skills) { lines.append("skills: \(skills)") }
        if let extensions = config.extensions { lines.append("extensions: \(joinComma(extensions) ?? "")") }
        if let output = config.output { lines.append("output: \(output)") }
        if let defaultReads = joinComma(config.defaultReads) { lines.append("defaultReads: \(defaultReads)") }
        if let defaultProgress = config.defaultProgress, defaultProgress { lines.append("defaultProgress: true") }
        if let interactive = config.interactive, interactive { lines.append("interactive: true") }
        if let maxSubagentDepth = config.maxSubagentDepth, maxSubagentDepth >= 0 { lines.append("maxSubagentDepth: \(maxSubagentDepth)") }
        for key in config.unknownFields.keys.sorted() {
            if let value = config.unknownFields[key] { lines.append("\(key): \(value)") }
        }
        lines.append("---")
        lines.append("")
        lines.append(config.systemPrompt)
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private func customAgentPath(name: String, scope: AgentEditingTarget.CustomAgentScope, projectRoot: String?) -> String {
        switch scope {
        case .library:
            return homeDirectory().appendingPathComponent(".pi/agent/agent-library/agents/\(name).md").path
        case .global:
            let newPath = homeDirectory().appendingPathComponent(".agents", isDirectory: true)
            if fileManager.fileExists(atPath: newPath.path) {
                return newPath.appendingPathComponent("\(name).md").path
            }
            return homeDirectory().appendingPathComponent(".pi/agent/agents/\(name).md").path
        case .project:
            return URL(fileURLWithPath: projectRoot ?? "").appendingPathComponent(".pi/agents/\(name).md").path
        }
    }

    private func settingsPath(for scope: AgentEditingTarget.OverrideScope, projectRoot: String?) -> String {
        switch scope {
        case .global:
            return homeDirectory().appendingPathComponent(".pi/agent/settings.json").path
        case .project:
            return URL(fileURLWithPath: projectRoot ?? "").appendingPathComponent(".pi/settings.json").path
        }
    }

    private func isWritableCustomAgentPath(_ path: String, scope: AgentEditingTarget.CustomAgentScope, projectRoot: String?) -> Bool {
        switch scope {
        case .library:
            return path.hasPrefix(homeDirectory().appendingPathComponent(".pi/agent/agent-library/agents").path)
        case .global:
            return path.hasPrefix(homeDirectory().appendingPathComponent(".pi/agent/agents").path) ||
                path.hasPrefix(homeDirectory().appendingPathComponent(".pi/agent/agent-library/agents").path) ||
                path.hasPrefix(homeDirectory().appendingPathComponent(".agents").path)
        case .project:
            guard let projectRoot else { return false }
            return path.hasPrefix(URL(fileURLWithPath: projectRoot).appendingPathComponent(".pi/agents").path)
        }
    }

    private func loadJSONObject(at path: String) throws -> [String: Any] {
        guard fileManager.fileExists(atPath: path) else { return [:] }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard !data.isEmpty else { return [:] }
        let object = try JSONSerialization.jsonObject(with: data)
        guard let json = object as? [String: Any] else {
            throw PersistenceError.invalidJSON(path)
        }
        return json
    }

    private func writeJSON(_ object: [String: Any], to path: String) throws {
        let url = URL(fileURLWithPath: path)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        var text = String(decoding: data, as: UTF8.self)
        if !text.hasSuffix("\n") { text.append("\n") }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func writeText(_ text: String, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func homeDirectory() -> URL {
        fileManager.homeDirectoryForCurrentUser
    }

    private func defaultSystemPromptMode(name: String) -> String {
        name == "delegate" ? "append" : "replace"
    }

    private func defaultInheritProjectContext(name: String) -> Bool {
        name == "delegate"
    }

    private func arraysEqual(_ lhs: [String]?, _ rhs: [String]?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return lhs == rhs
        default:
            return false
        }
    }

    private func joinedTools(from config: AgentConfig) -> [String]? {
        let tools = (config.tools ?? []) + (config.mcpDirectTools ?? []).map { "mcp:\($0)" }
        return tools.isEmpty ? nil : tools
    }

    private func joinComma(_ values: [String]?) -> String? {
        guard let values, !values.isEmpty else { return nil }
        return values.joined(separator: ", ")
    }
}

enum PersistenceError: LocalizedError {
    case missingBuiltinBase(String)
    case invalidWriteTarget(String)
    case invalidJSON(String)
    case invalidDraftTarget

    var errorDescription: String? {
        switch self {
        case let .missingBuiltinBase(name): return "Missing builtin base for \(name)."
        case let .invalidWriteTarget(path): return "Refusing to write outside allowed paths: \(path)"
        case let .invalidJSON(path): return "Invalid JSON in \(path)."
        case .invalidDraftTarget: return "This save path only supports custom markdown agent drafts."
        }
    }
}

private protocol OptionalProtocol {
    var isNil: Bool { get }
}

extension Optional: OptionalProtocol {
    var isNil: Bool { self == nil }
}
