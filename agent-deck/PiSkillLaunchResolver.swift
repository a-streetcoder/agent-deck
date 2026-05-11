import Foundation

struct PiSkillLaunchResolver {
    struct Collision: Hashable {
        let name: String
        let skills: [SkillRecord]
    }

    enum ResolutionError: LocalizedError {
        case ambiguousSkill(name: String, matches: [SkillRecord])
        case missingSkill(name: String)
        case skillRequiresReadTool(agentName: String, skills: [String])

        var errorDescription: String? {
            switch self {
            case let .ambiguousSkill(name, matches):
                let list = matches.map { "- \($0.source.kind.rawValue): \($0.filePath)" }.joined(separator: "\n")
                return "Cannot launch because skill `\(name)` is ambiguous.\n\nMatching skills:\n\(list)\n\nRename one skill or remove one assignment, then try again."
            case let .missingSkill(name):
                return "Cannot launch because assigned skill `\(name)` could not be found in the Agent Deck skill catalog."
            case let .skillRequiresReadTool(agentName, skills):
                return "Agent `\(agentName)` has assigned skills but cannot load them because its tool allowlist does not include `read`. Add `read` to the agent tools or remove the assigned skills.\n\nSkills: \(skills.joined(separator: ", "))"
            }
        }
    }

    static func catalog(from snapshot: ScanSnapshot) -> [SkillRecord] {
        snapshot.skills + snapshot.librarySkills
    }

    static func collisions(in skills: [SkillRecord]) -> [Collision] {
        Dictionary(grouping: skills, by: { $0.name })
            .filter { $0.value.count > 1 }
            .map { Collision(name: $0.key, skills: $0.value.sorted(by: skillSort)) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func skillArguments(for names: [String], catalog: [SkillRecord]) throws -> [String] {
        let resolved = try resolve(names: names, catalog: catalog)
        return resolved.flatMap { ["--skill", $0.filePath] }
    }

    static func parentSkillArguments(defaultSkillNames: Set<String>, projectSkillNames: Set<String>, snapshot: ScanSnapshot) throws -> [String] {
        let names = Array(defaultSkillNames.union(projectSkillNames)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        guard !names.isEmpty else { return [] }
        return try skillArguments(for: names, catalog: catalog(from: snapshot))
    }

    static func childSkillArguments(agent: EffectiveAgentRecord, snapshot: ScanSnapshot) throws -> [String] {
        let names = normalizedNames(agent.resolved.skills)
        guard !names.isEmpty else { return [] }
        try validateReadToolAccess(agent: agent, skillNames: names)
        return try skillArguments(for: names, catalog: catalog(from: snapshot))
    }

    static func resolve(names: [String], catalog: [SkillRecord]) throws -> [SkillRecord] {
        var resolved: [SkillRecord] = []
        for name in normalizedNames(names) {
            let matches = catalog.filter { $0.name == name }.sorted(by: skillSort)
            if matches.isEmpty { throw ResolutionError.missingSkill(name: name) }
            if matches.count > 1 { throw ResolutionError.ambiguousSkill(name: name, matches: matches) }
            resolved.append(matches[0])
        }
        return resolved
    }

    static func normalizedNames(_ names: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in names {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(name).inserted else { continue }
            result.append(name)
        }
        return result
    }

    private static func validateReadToolAccess(agent: EffectiveAgentRecord, skillNames: [String]) throws {
        guard let tools = agent.resolved.tools else { return }
        guard tools.contains("read") else {
            throw ResolutionError.skillRequiresReadTool(agentName: agent.name, skills: skillNames)
        }
    }

    private static func skillSort(_ lhs: SkillRecord, _ rhs: SkillRecord) -> Bool {
        let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        let sourceOrder = lhs.source.kind.rawValue.localizedCaseInsensitiveCompare(rhs.source.kind.rawValue)
        if sourceOrder != .orderedSame { return sourceOrder == .orderedAscending }
        return lhs.filePath < rhs.filePath
    }
}
