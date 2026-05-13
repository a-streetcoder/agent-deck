import Foundation

nonisolated enum PiAgentLaunchResolver {
    static func effectiveAgents(
        defaultAgentNames: Set<String>,
        projectAgentNames: Set<String>,
        snapshot: ScanSnapshot,
        catalog: [AgentRecord]
    ) -> [EffectiveAgentRecord] {
        let userOverrides = snapshot.settings.flatMap(\.agentOverrides).filter { $0.scope.kind == .global }
        let projectOverrides = snapshot.settings.flatMap(\.agentOverrides).filter { $0.scope.kind == .project }
        let userDisableBuiltins = globalSettings(in: snapshot)?.disableBuiltins
        let projectDisableBuiltins = projectSettings(in: snapshot)?.disableBuiltins

        var byName: [String: EffectiveAgentRecord] = [:]
        for builtin in snapshot.builtinAgents {
            let userOverride = userOverrides.first { $0.agentName == builtin.name }
            let projectOverride = projectOverrides.first { $0.agentName == builtin.name }
            var resolved = builtin.parsed
            if let projectOverride {
                resolved = applyOverride(projectOverride, to: resolved)
            } else if projectDisableBuiltins == true {
                resolved.disabled = true
            } else if let userOverride {
                resolved = applyOverride(userOverride, to: resolved)
            } else if projectDisableBuiltins == nil, userDisableBuiltins == true {
                resolved.disabled = true
            }
            byName[builtin.name] = EffectiveAgentRecord(
                id: "\(snapshot.projectRoot ?? "global")::\(builtin.name)",
                name: builtin.name,
                projectRoot: snapshot.projectRoot,
                builtin: builtin,
                globalCustom: nil,
                projectCustom: nil,
                userOverride: userOverride,
                projectOverride: projectOverride,
                resolved: resolved,
                resolutionKind: userOverride != nil || projectOverride != nil ? .builtinWithOverride : .builtin
            )
        }

        for name in defaultAgentNames.sorted(by: localizedSort) {
            guard let record = record(named: name, in: catalog, preferredKinds: [.library, .global, .project, .legacyProject]), record.source.kind != .builtin else { continue }
            byName[name] = effectiveCustomAgent(
                name: name,
                snapshot: snapshot,
                builtin: snapshot.builtinAgents.first { $0.name == name },
                globalCustom: record,
                projectCustom: nil,
                userOverride: userOverrides.first { $0.agentName == name },
                projectOverride: projectOverrides.first { $0.agentName == name }
            )
        }
        for name in projectAgentNames.sorted(by: localizedSort) {
            guard let record = record(named: name, in: catalog, preferredKinds: [.project, .legacyProject, .library, .global]), record.source.kind != .builtin else { continue }
            let existing = byName[name]
            byName[name] = effectiveCustomAgent(
                name: name,
                snapshot: snapshot,
                builtin: existing?.builtin ?? snapshot.builtinAgents.first { $0.name == name },
                globalCustom: existing?.globalCustom,
                projectCustom: record,
                userOverride: existing?.userOverride ?? userOverrides.first { $0.agentName == name },
                projectOverride: existing?.projectOverride ?? projectOverrides.first { $0.agentName == name }
            )
        }

        return byName.values.sorted { localizedSort($0.name, $1.name) }
    }

    private static func effectiveCustomAgent(
        name: String,
        snapshot: ScanSnapshot,
        builtin: AgentRecord?,
        globalCustom: AgentRecord?,
        projectCustom: AgentRecord?,
        userOverride: BuiltinOverrideRecord?,
        projectOverride: BuiltinOverrideRecord?
    ) -> EffectiveAgentRecord {
        let winner = projectCustom ?? globalCustom ?? builtin
        let resolutionKind: ResolutionKind
        if projectCustom != nil {
            resolutionKind = builtin == nil ? .projectCustom : .projectReplacement
        } else if globalCustom != nil {
            resolutionKind = builtin == nil ? .globalCustom : .globalReplacement
        } else if userOverride != nil || projectOverride != nil {
            resolutionKind = .builtinWithOverride
        } else {
            resolutionKind = .builtin
        }
        return EffectiveAgentRecord(
            id: "\(snapshot.projectRoot ?? "global")::\(name)",
            name: name,
            projectRoot: snapshot.projectRoot,
            builtin: builtin,
            globalCustom: globalCustom,
            projectCustom: projectCustom,
            userOverride: userOverride,
            projectOverride: projectOverride,
            resolved: winner?.parsed ?? AgentConfig.empty,
            resolutionKind: resolutionKind
        )
    }

    private static func record(named name: String, in records: [AgentRecord], preferredKinds: [ResourceScopeKind]) -> AgentRecord? {
        let matches = records.filter { $0.name == name }.sorted(by: recordSort)
        for kind in preferredKinds {
            if let match = matches.first(where: { $0.source.kind == kind }) { return match }
        }
        return matches.first { $0.source.kind != .builtin }
    }

    private static func recordSort(_ lhs: AgentRecord, _ rhs: AgentRecord) -> Bool {
        let lhsRank = sourceRank(lhs.source.kind)
        let rhsRank = sourceRank(rhs.source.kind)
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        if lhs.name != rhs.name { return localizedSort(lhs.name, rhs.name) }
        return lhs.filePath < rhs.filePath
    }

    private static func sourceRank(_ kind: ResourceScopeKind) -> Int {
        switch kind {
        case .library: return 0
        case .global: return 1
        case .project: return 2
        case .legacyProject: return 3
        case .override: return 4
        case .package: return 5
        case .builtin: return 6
        }
    }

    private static func localizedSort(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
    }

    private static func globalSettings(in snapshot: ScanSnapshot) -> SettingsSummary? {
        guard let projectRoot = snapshot.projectRoot else { return snapshot.settings.first }
        let projectSettingsPath = URL(fileURLWithPath: projectRoot).appendingPathComponent(".pi/settings.json").standardizedFileURL.path
        return snapshot.settings.first { URL(fileURLWithPath: $0.path).standardizedFileURL.path != projectSettingsPath }
    }

    private static func projectSettings(in snapshot: ScanSnapshot) -> SettingsSummary? {
        guard let projectRoot = snapshot.projectRoot else { return nil }
        let projectSettingsPath = URL(fileURLWithPath: projectRoot).appendingPathComponent(".pi/settings.json").standardizedFileURL.path
        return snapshot.settings.first { URL(fileURLWithPath: $0.path).standardizedFileURL.path == projectSettingsPath }
    }

    private static func applyOverride(_ override: BuiltinOverrideRecord?, to config: AgentConfig) -> AgentConfig {
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
            case "inheritProjectContext", "defaultContext":
                continue
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

    private static func splitToolList(_ value: String?) -> (tools: [String]?, mcpDirectTools: [String]?) {
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

    private static func splitJSONArray(_ value: Any) -> [String]? {
        guard let array = value as? [Any] else { return nil }
        return array.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private static func splitList(_ value: String?) -> [String] {
        guard let value, !value.isEmpty else { return [] }
        return value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func stringify(_ value: Any) -> String {
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
