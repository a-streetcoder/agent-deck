import Foundation

struct PiScanner {
    private let fileManager = FileManager.default
    private let builtinAgentsDirectory = URL(fileURLWithPath: "/opt/homebrew/lib/node_modules/pi-subagents/agents", isDirectory: true)

    func scan(projectRoot: URL?) -> ScanSnapshot {
        let legacyGlobalAgentDirectory = homeDirectory().appendingPathComponent(".pi/agent/agents", isDirectory: true)
        let globalAgentDirectory = homeDirectory().appendingPathComponent(".agents", isDirectory: true)
        let globalSettings = homeDirectory().appendingPathComponent(".pi/agent/settings.json")
        let globalEnv = homeDirectory().appendingPathComponent(".pi/agent/.env")
        let globalMCP = homeDirectory().appendingPathComponent(".pi/agent/mcp.json")
        let globalSkills = homeDirectory().appendingPathComponent(".pi/agent/skills", isDirectory: true)
        let extraGlobalSkills = homeDirectory().appendingPathComponent(".agents/skills", isDirectory: true)

        let projectAgentDirectory = projectRoot?.appendingPathComponent(".pi/agents", isDirectory: true)
        let legacyProjectAgentDirectory = projectRoot?.appendingPathComponent(".agents", isDirectory: true)
        let projectSettings = projectRoot?.appendingPathComponent(".pi/settings.json")
        let projectEnv = projectRoot?.appendingPathComponent(".pi/.env")
        let projectPiMCP = projectRoot?.appendingPathComponent(".pi/mcp.json")
        let projectRootMCP = projectRoot?.appendingPathComponent(".mcp.json")
        let projectSkills = projectRoot?.appendingPathComponent(".pi/skills", isDirectory: true)

        let builtinAgents = scanAgents(at: builtinAgentsDirectory, scope: .builtin)
        let legacyGlobalAgents = scanAgents(at: legacyGlobalAgentDirectory, scope: .global)
        let globalAgents = scanAgents(at: globalAgentDirectory, scope: .global)
        let projectAgents = scanAgents(at: projectAgentDirectory, scope: .project)
        let legacyProjectAgents = scanAgents(at: legacyProjectAgentDirectory, scope: .legacyProject)

        let settings = [
            scanSettings(at: globalSettings, scope: .global),
            scanSettings(at: projectSettings, scope: .project)
        ].compactMap { $0 }

        let chains =
            scanChains(at: legacyGlobalAgentDirectory, scope: .global) +
            scanChains(at: globalAgentDirectory, scope: .global) +
            scanChains(at: legacyProjectAgentDirectory, scope: .legacyProject) +
            scanChains(at: projectAgentDirectory, scope: .project)

        let skills =
            scanSkills(at: globalSkills, scope: .global) +
            scanSkills(at: extraGlobalSkills, scope: .package) +
            scanSkills(at: projectSkills, scope: .project)

        let envKeys =
            scanEnv(at: globalEnv, scope: .global) +
            scanEnv(at: projectEnv, scope: .project)

        let mcpConfigs = [
            scanMCP(at: globalMCP, scope: .global),
            scanMCP(at: projectRootMCP, scope: .project),
            scanMCP(at: projectPiMCP, scope: .project)
        ].compactMap { $0 }

        let globalSettingsSummary = settings.first(where: { $0.path == globalSettings.path })
        let projectSettingsSummary = settings.first(where: { $0.path == projectSettings?.path })

        let effectiveAgents = resolveAgents(
            projectRoot: projectRoot?.path,
            builtin: builtinAgents,
            legacyGlobal: legacyGlobalAgents,
            global: globalAgents,
            legacyProject: legacyProjectAgents,
            project: projectAgents,
            userOverrides: globalSettingsSummary?.agentOverrides ?? [],
            projectOverrides: projectSettingsSummary?.agentOverrides ?? [],
            userDisableBuiltins: globalSettingsSummary?.disableBuiltins,
            projectDisableBuiltins: projectSettingsSummary?.disableBuiltins
        )

        let warnings = buildWarnings(
            effectiveAgents: effectiveAgents,
            rawAgents: builtinAgents + legacyGlobalAgents + globalAgents + legacyProjectAgents + projectAgents,
            chains: chains,
            skills: skills,
            envKeys: envKeys,
            malformedWarnings: malformedResourceWarnings(
                agentDirectories: [builtinAgentsDirectory, legacyGlobalAgentDirectory, globalAgentDirectory, legacyProjectAgentDirectory, projectAgentDirectory].compactMap { $0 },
                skillDirectories: [globalSkills, extraGlobalSkills, projectSkills].compactMap { $0 }
            )
        )

        return ScanSnapshot(
            projectRoot: projectRoot?.path,
            builtinAgents: builtinAgents,
            globalAgents: legacyGlobalAgents + globalAgents,
            projectAgents: projectAgents,
            legacyProjectAgents: legacyProjectAgents,
            effectiveAgents: effectiveAgents,
            chains: chains,
            skills: skills,
            settings: settings,
            envKeys: envKeys,
            mcpConfigs: mcpConfigs,
            warnings: warnings
        )
    }

    private func homeDirectory() -> URL {
        fileManager.homeDirectoryForCurrentUser
    }

    private func scanAgents(at directory: URL?, scope: ResourceScopeKind) -> [AgentRecord] {
        guard let directory, let urls = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }

        return urls
            .filter { $0.pathExtension == "md" && !$0.lastPathComponent.hasSuffix(".chain.md") }
            .compactMap { url in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                let document = parseMarkdownDocument(text)
                let config = parseAgentConfig(frontmatter: document.frontmatter, body: document.body)
                guard !config.name.isEmpty, !config.description.isEmpty else { return nil }
                let name = config.name
                return AgentRecord(
                    id: "\(scope.rawValue):\(name):\(url.path)",
                    name: name,
                    description: config.description,
                    source: ScopeID(kind: scope, path: url.path),
                    filePath: url.path,
                    rawFrontmatter: document.frontmatter,
                    promptBody: document.body,
                    parsed: AgentConfig(name: name, description: config.description, model: config.model, fallbackModels: config.fallbackModels, thinking: config.thinking, systemPromptMode: config.systemPromptMode, inheritProjectContext: config.inheritProjectContext, inheritSkills: config.inheritSkills, disabled: config.disabled, tools: config.tools, mcpDirectTools: config.mcpDirectTools, extensions: config.extensions, skills: config.skills, output: config.output, defaultReads: config.defaultReads, defaultProgress: config.defaultProgress, interactive: config.interactive, maxSubagentDepth: config.maxSubagentDepth, systemPrompt: config.systemPrompt, unknownFields: config.unknownFields)
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func scanChains(at directory: URL?, scope: ResourceScopeKind) -> [ChainRecord] {
        guard let directory, let urls = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }

        return urls
            .filter { $0.lastPathComponent.hasSuffix(".chain.md") }
            .compactMap { url in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                let document = parseMarkdownDocument(text)
                let name = document.frontmatter["name"]?.nonEmpty ?? url.deletingPathExtension().deletingPathExtension().lastPathComponent
                let description = document.frontmatter["description"]?.nonEmpty ?? ""
                let steps = parseChainSteps(document.body)
                var extraFields = document.frontmatter
                extraFields.removeValue(forKey: "name")
                extraFields.removeValue(forKey: "description")
                return ChainRecord(
                    id: "\(scope.rawValue):\(name):\(url.path)",
                    name: name,
                    source: ScopeID(kind: scope, path: url.path),
                    filePath: url.path,
                    description: description,
                    steps: steps,
                    extraFields: extraFields
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func scanSkills(at directory: URL?, scope: ResourceScopeKind) -> [SkillRecord] {
        guard let directory, let urls = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }

        return urls.compactMap { folder in
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return nil
            }

            let skillFile = folder.appendingPathComponent("SKILL.md")
            guard let text = try? String(contentsOf: skillFile, encoding: .utf8) else { return nil }
            let document = parseMarkdownDocument(text)
            let name = document.frontmatter["name"]?.nonEmpty ?? folder.lastPathComponent
            let description = document.frontmatter["description"]?.nonEmpty
            return SkillRecord(
                id: "\(scope.rawValue):\(name):\(skillFile.path)",
                name: name,
                description: description,
                source: ScopeID(kind: scope, path: skillFile.path),
                filePath: skillFile.path,
                body: text
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func scanSettings(at file: URL?, scope: ResourceScopeKind) -> SettingsSummary? {
        guard let file, let data = try? Data(contentsOf: file) else { return nil }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return SettingsSummary(path: file.path, packages: [], disableBuiltins: nil, agentOverrides: [])
        }

        let packages = root["packages"] as? [String] ?? []
        let subagents = root["subagents"] as? [String: Any]
        let disableBuiltins = subagents?["disableBuiltins"] as? Bool
        let overridesRoot = (subagents?["agentOverrides"] as? [String: Any]) ?? [:]
        let overrides: [BuiltinOverrideRecord] = overridesRoot.compactMap { name, payload in
            guard let payload = payload as? [String: Any] else { return nil }
            let values = payload
            return BuiltinOverrideRecord(
                agentName: name,
                scope: ScopeID(kind: .override, path: file.path),
                settingsPath: file.path,
                values: values
            )
        }
        .sorted { $0.agentName.localizedCaseInsensitiveCompare($1.agentName) == .orderedAscending }

        return SettingsSummary(path: file.path, packages: packages, disableBuiltins: disableBuiltins, agentOverrides: overrides)
    }

    private func scanEnv(at file: URL?, scope: ResourceScopeKind) -> [EnvKeyRecord] {
        guard let file, let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return text
            .split(whereSeparator: \.isNewline)
            .compactMap { rawLine -> EnvKeyRecord? in
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty, !line.hasPrefix("#") else {
                    return nil
                }
                let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard let rawKey = parts.first else { return nil }
                let key = String(rawKey).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else { return nil }
                let value = parts.count > 1 ? String(parts[1]) : nil
                return EnvKeyRecord(id: "\(scope.rawValue):\(key):\(file.path)", key: key, value: value, source: ScopeID(kind: scope, path: file.path))
            }
    }

    private func scanMCP(at file: URL?, scope: ResourceScopeKind) -> MCPConfigRecord? {
        guard let file, let data = try? Data(contentsOf: file) else { return nil }
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let servers = ((json?["mcpServers"] as? [String: Any]) ?? [:]).keys.sorted()
        return MCPConfigRecord(id: "\(scope.rawValue):\(file.path)", path: file.path, source: ScopeID(kind: scope, path: file.path), serverNames: servers)
    }

    private func resolveAgents(
        projectRoot: String?,
        builtin: [AgentRecord],
        legacyGlobal: [AgentRecord],
        global: [AgentRecord],
        legacyProject: [AgentRecord],
        project: [AgentRecord],
        userOverrides: [BuiltinOverrideRecord],
        projectOverrides: [BuiltinOverrideRecord],
        userDisableBuiltins: Bool?,
        projectDisableBuiltins: Bool?
    ) -> [EffectiveAgentRecord] {
        let allNames = Set(
            builtin.map(\.name) +
            legacyGlobal.map(\.name) +
            global.map(\.name) +
            legacyProject.map(\.name) +
            project.map(\.name) +
            userOverrides.map(\.agentName) +
            projectOverrides.map(\.agentName)
        )

        return allNames.sorted().compactMap { name in
            let builtinRecord = builtin.first(where: { $0.name == name })
            let globalRecord = global.first(where: { $0.name == name }) ?? legacyGlobal.first(where: { $0.name == name })
            let projectRecord = project.first(where: { $0.name == name }) ?? legacyProject.first(where: { $0.name == name })
            let userOverride = userOverrides.first(where: { $0.agentName == name })
            let projectOverride = projectOverrides.first(where: { $0.agentName == name })

            let winner = projectRecord ?? globalRecord ?? builtinRecord
            guard var resolved = winner?.parsed else { return nil }
            if winner?.source.kind == .builtin {
                if let projectOverride {
                    resolved = applyOverride(projectOverride, to: resolved)
                } else if projectDisableBuiltins == true {
                    resolved.disabled = true
                } else if let userOverride {
                    resolved = applyOverride(userOverride, to: resolved)
                } else if projectDisableBuiltins == nil, userDisableBuiltins == true {
                    resolved.disabled = true
                }
            }
            if resolved.disabled == true { return nil }

            let resolutionKind: ResolutionKind
            if projectRecord != nil {
                resolutionKind = .projectReplacement
            } else if globalRecord != nil {
                resolutionKind = .globalReplacement
            } else if userOverride != nil || projectOverride != nil {
                resolutionKind = .builtinWithOverride
            } else {
                resolutionKind = .builtin
            }

            return EffectiveAgentRecord(
                id: "\(projectRoot ?? "global")::\(name)",
                name: name,
                projectRoot: projectRoot,
                builtin: builtinRecord,
                globalCustom: globalRecord,
                projectCustom: projectRecord,
                userOverride: userOverride,
                projectOverride: projectOverride,
                resolved: resolved,
                resolutionKind: resolutionKind
            )
        }
    }

    private func applyOverride(_ override: BuiltinOverrideRecord?, to config: AgentConfig) -> AgentConfig {
        guard let override else { return config }
        var result = config

        for (key, rawValue) in override.values {
            switch key {
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
                result.unknownFields[key] = stringify(rawValue)
            }
        }

        return result
    }

    private func buildWarnings(
        effectiveAgents: [EffectiveAgentRecord],
        rawAgents: [AgentRecord],
        chains: [ChainRecord],
        skills: [SkillRecord],
        envKeys: [EnvKeyRecord],
        malformedWarnings: [DiagnosticWarning]
    ) -> [DiagnosticWarning] {
        var warnings: [DiagnosticWarning] = malformedWarnings
        let skillNames = Set(skills.map(\.name))
        let agentNames = Set(effectiveAgents.map(\.name))
        let envNames = Set(envKeys.map(\.key))
        let duplicateAgentNames = Dictionary(grouping: rawAgents, by: \.name).filter { $0.value.count > 1 }

        for (name, records) in duplicateAgentNames {
            let scopes = records.map { "\($0.source.kind.rawValue) · \($0.filePath)" }.sorted().joined(separator: ", ")
            warnings.append(.init(id: "duplicate-agent:\(name)", message: "Duplicate agent name \(name) exists across scopes: \(scopes)."))
        }

        for agent in effectiveAgents {
            for skill in agent.resolved.skills where !skillNames.contains(skill) {
                warnings.append(.init(id: "skill:\(agent.name):\(skill)", message: "Agent \(agent.name) references missing skill \(skill)."))
            }
            if let tools = agent.resolved.tools, tools.contains("web_search") && !envNames.contains("EXA_API_KEY") && !envNames.contains("GEMINI_API_KEY") && !envNames.contains("PERPLEXITY_API_KEY") {
                warnings.append(.init(id: "env:\(agent.name)", message: "Agent \(agent.name) uses web search tools but no known web provider API key was found."))
            }
            if let extensions = agent.resolved.extensions, !extensions.isEmpty,
               ((agent.resolved.tools ?? []).isEmpty && (agent.resolved.mcpDirectTools ?? []).isEmpty) {
                warnings.append(.init(id: "extensions:\(agent.name)", message: "Agent \(agent.name) declares extensions but no explicit tools, so capabilities may not match expectations."))
            }
        }

        for chain in chains {
            for step in chain.steps where !agentNames.contains(step.agent) {
                warnings.append(.init(id: "chain:\(chain.name):\(step.agent)", message: "Chain \(chain.name) references missing agent \(step.agent)."))
            }
        }

        return warnings.sorted { $0.message.localizedCaseInsensitiveCompare($1.message) == .orderedAscending }
    }

    private func malformedResourceWarnings(agentDirectories: [URL], skillDirectories: [URL]) -> [DiagnosticWarning] {
        var warnings: [DiagnosticWarning] = []

        for directory in agentDirectories {
            guard let urls = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { continue }
            for url in urls where url.pathExtension == "md" {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let document = parseMarkdownDocument(text)
                if !text.hasPrefix("---") {
                    warnings.append(.init(id: "malformed-agent:\(url.path)", message: "Malformed frontmatter in \(url.path). Markdown agent files should start with frontmatter."))
                    continue
                }
                if !url.lastPathComponent.hasSuffix(".chain.md") {
                    if document.frontmatter["name"]?.isEmpty != false || document.frontmatter["description"]?.isEmpty != false {
                        warnings.append(.init(id: "incomplete-agent:\(url.path)", message: "Malformed frontmatter in \(url.path). Agent files need at least name and description."))
                    }
                } else if parseChainSteps(document.body).isEmpty {
                    warnings.append(.init(id: "empty-chain:\(url.path)", message: "Malformed step block in \(url.path). No chain steps were parsed."))
                }
            }
        }

        for directory in skillDirectories {
            guard let urls = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { continue }
            for folder in urls {
                let skillFile = folder.appendingPathComponent("SKILL.md")
                guard let text = try? String(contentsOf: skillFile, encoding: .utf8) else { continue }
                let document = parseMarkdownDocument(text)
                if !text.hasPrefix("---") || document.frontmatter["name"]?.isEmpty != false {
                    warnings.append(.init(id: "malformed-skill:\(skillFile.path)", message: "Malformed frontmatter in \(skillFile.path). Skills should define frontmatter with a name."))
                }
            }
        }

        return warnings
    }

    private func parseAgentConfig(frontmatter: [String: String], body: String) -> AgentConfig {
        var unknownFields = frontmatter

        func pop(_ key: String) -> String? {
            defer { unknownFields.removeValue(forKey: key) }
            return frontmatter[key]?.nonEmpty
        }

        let name = pop("name") ?? ""
        let rawTools = pop("tools")
        let skillValue = pop("skill") ?? pop("skills")
        let parsedMaxSubagentDepth = Int(pop("maxSubagentDepth") ?? "")
        return AgentConfig(
            name: name,
            description: pop("description") ?? "",
            model: pop("model"),
            fallbackModels: splitList(pop("fallbackModels")),
            thinking: pop("thinking"),
            systemPromptMode: parseSystemPromptMode(pop("systemPromptMode"), name: name),
            inheritProjectContext: parseBool(pop("inheritProjectContext")) ?? defaultInheritProjectContext(name: name),
            inheritSkills: parseBool(pop("inheritSkills")) ?? false,
            disabled: parseBool(pop("disabled")),
            tools: frontmatter.keys.contains("tools") ? splitToolList(rawTools).tools : nil,
            mcpDirectTools: frontmatter.keys.contains("tools") ? splitToolList(rawTools).mcpDirectTools : nil,
            extensions: frontmatter.keys.contains("extensions") ? splitList(pop("extensions")) : nil,
            skills: optionalList(skillValue) ?? [],
            output: pop("output"),
            defaultReads: optionalList(pop("defaultReads")),
            defaultProgress: parseBool(pop("defaultProgress")) ?? false,
            interactive: parseBool(pop("interactive")) ?? false,
            maxSubagentDepth: parsedMaxSubagentDepth.flatMap { $0 >= 0 ? $0 : nil },
            systemPrompt: body,
            unknownFields: unknownFields
        )
    }

    private func parseChainSteps(_ body: String) -> [ChainStepRecord] {
        let sections = body.components(separatedBy: "\n## ")
        return sections.enumerated().compactMap { index, section in
            let normalized = index == 0 ? section : "## " + section
            guard normalized.hasPrefix("## ") else { return nil }
            let lines = normalized.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            guard let first = lines.first else { return nil }
            let title = first.replacingOccurrences(of: "## ", with: "").trimmingCharacters(in: .whitespaces)
            let body = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let parsed = parseChainStep(title: title, body: body, index: index)
            return parsed
        }
    }

    private func parseMarkdownDocument(_ text: String) -> (frontmatter: [String: String], body: String) {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---") else {
            return ([:], normalized)
        }

        let startIndex = normalized.index(normalized.startIndex, offsetBy: 3)
        guard let range = normalized.range(of: "\n---", range: startIndex..<normalized.endIndex) else {
            return ([:], normalized)
        }

        let frontmatterBlock = String(normalized[normalized.index(after: startIndex)..<range.lowerBound])
        let bodyStart = normalized.index(range.lowerBound, offsetBy: 4)
        let body = String(normalized[bodyStart...]).trimmingCharacters(in: .whitespacesAndNewlines)

        var frontmatter: [String: String] = [:]
        for rawLine in frontmatterBlock.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let separator = rawLine.firstIndex(of: ":") else { continue }
            let key = String(rawLine[..<separator]).trimmingCharacters(in: .whitespaces)
            var value = String(rawLine[rawLine.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty { frontmatter[key] = value }
        }
        return (frontmatter, body)
    }

    private func parseBool(_ value: String?) -> Bool? {
        guard let value else { return nil }
        switch value.lowercased() {
        case "true", "yes", "1": return true
        case "false", "no", "0": return false
        default: return nil
        }
    }

    private func parseStrictBool(_ value: String?) -> Bool? {
        switch value?.lowercased() {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    private func parseSystemPromptMode(_ value: String?, name: String) -> String {
        switch value {
        case "append", "replace": return value ?? "replace"
        default: return defaultSystemPromptMode(name: name)
        }
    }

    private func defaultSystemPromptMode(name: String) -> String {
        name == "delegate" ? "append" : "replace"
    }

    private func defaultInheritProjectContext(name: String) -> Bool {
        name == "delegate"
    }

    private func parseChainStep(title: String, body: String, index: Int) -> ChainStepRecord {
        let lines = body.components(separatedBy: "\n")
        let blankIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        let configLines = blankIndex.map { Array(lines[..<$0]) } ?? lines
        let taskBody = blankIndex.map { lines.suffix(from: $0 + 1).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""

        var output: String?
        var outputDisabled = false
        var reads: [String]?
        var readsDisabled = false
        var model: String?
        var skills: [String]?
        var skillsDisabled = false
        var progress: Bool?

        for line in configLines {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            switch key {
            case "output":
                if value == "false" { output = nil; outputDisabled = true }
                else { output = value.nonEmpty }
            case "reads":
                if value == "false" { reads = nil; readsDisabled = true }
                else {
                    let parsed = splitList(value)
                    reads = parsed.isEmpty ? nil : parsed
                    readsDisabled = parsed.isEmpty
                }
            case "model": model = value.nonEmpty
            case "skills":
                if value == "false" { skills = nil; skillsDisabled = true }
                else {
                    let parsed = splitList(value)
                    skills = parsed.isEmpty ? nil : parsed
                    skillsDisabled = parsed.isEmpty
                }
            case "progress": progress = parseStrictBool(value)
            default: break
            }
        }

        return ChainStepRecord(id: "\(index):\(title)", agent: title, title: title, output: output, outputDisabled: outputDisabled, reads: reads, readsDisabled: readsDisabled, model: model, skills: skills, skillsDisabled: skillsDisabled, progress: progress, body: taskBody)
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

    private func optionalList(_ value: String?) -> [String]? {
        let values = splitList(value)
        return values.isEmpty ? nil : values
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

    private func stringify(_ value: Any) -> String {
        switch value {
        case let value as String:
            return value
        case let value as Bool:
            return value ? "true" : "false"
        case let value as [String]:
            return value.joined(separator: ", ")
        case let value as [Any]:
            return value.map(stringify).joined(separator: ", ")
        default:
            return String(describing: value)
        }
    }
}

private extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let self, !self.isEmpty else { return nil }
        return self
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
