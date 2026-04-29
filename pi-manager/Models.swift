import Foundation

enum ResourceScopeKind: String, CaseIterable, Codable {
    case builtin = "Builtin"
    case global = "Global"
    case project = "Project"
    case legacyProject = "Legacy Project"
    case override = "Override"
    case package = "Package"
}

struct ScopeID: Hashable, Identifiable {
    let kind: ResourceScopeKind
    let path: String

    var id: String { "\(kind.rawValue):\(path)" }
    var displayName: String { kind.rawValue }
}

struct AgentConfig: Hashable {
    var name: String
    var description: String
    var model: String?
    var fallbackModels: [String]
    var thinking: String?
    var systemPromptMode: String?
    var inheritProjectContext: Bool?
    var inheritSkills: Bool?
    var disabled: Bool?
    var tools: [String]?
    var mcpDirectTools: [String]?
    var extensions: [String]?
    var skills: [String]
    var output: String?
    var defaultReads: [String]?
    var defaultProgress: Bool?
    var interactive: Bool?
    var maxSubagentDepth: Int?
    var systemPrompt: String
    var unknownFields: [String: String]

    static let empty = AgentConfig(
        name: "",
        description: "",
        model: nil,
        fallbackModels: [],
        thinking: nil,
        systemPromptMode: nil,
        inheritProjectContext: nil,
        inheritSkills: nil,
        disabled: nil,
        tools: nil,
        mcpDirectTools: nil,
        extensions: nil,
        skills: [],
        output: nil,
        defaultReads: nil,
        defaultProgress: nil,
        interactive: nil,
        maxSubagentDepth: nil,
        systemPrompt: "",
        unknownFields: [:]
    )
}

struct AgentRecord: Identifiable, Hashable {
    let id: String
    let name: String
    let description: String
    let source: ScopeID
    let filePath: String
    let rawFrontmatter: [String: String]
    let promptBody: String
    let parsed: AgentConfig
}

struct BuiltinOverrideRecord: Hashable {
    let agentName: String
    let scope: ScopeID
    let settingsPath: String
    let values: [String: Any]

    static func == (lhs: BuiltinOverrideRecord, rhs: BuiltinOverrideRecord) -> Bool {
        lhs.agentName == rhs.agentName &&
        lhs.scope == rhs.scope &&
        lhs.settingsPath == rhs.settingsPath &&
        NSDictionary(dictionary: lhs.values).isEqual(to: rhs.values)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(agentName)
        hasher.combine(scope)
        hasher.combine(settingsPath)
        for key in values.keys.sorted() {
            hasher.combine(key)
            hasher.combine(String(describing: values[key]!))
        }
    }
}

enum ResolutionKind: String {
    case builtin
    case builtinWithOverride = "Builtin + Override"
    case globalReplacement = "Global Replacement"
    case projectReplacement = "Project Replacement"
}

struct EffectiveAgentRecord: Identifiable, Hashable {
    let id: String
    let name: String
    let projectRoot: String?
    let builtin: AgentRecord?
    let globalCustom: AgentRecord?
    let projectCustom: AgentRecord?
    let userOverride: BuiltinOverrideRecord?
    let projectOverride: BuiltinOverrideRecord?
    let resolved: AgentConfig
    let resolutionKind: ResolutionKind

    var winningRecord: AgentRecord? {
        projectCustom ?? globalCustom ?? builtin
    }

    var sourcePath: String? {
        winningRecord?.filePath
    }
}

struct ChainStepRecord: Identifiable, Hashable {
    let id: String
    var agent: String
    var title: String
    var output: String?
    var outputDisabled: Bool
    var reads: [String]?
    var readsDisabled: Bool
    var model: String?
    var skills: [String]?
    var skillsDisabled: Bool
    var progress: Bool?
    var body: String
}

struct ChainRecord: Identifiable, Hashable {
    let id: String
    var name: String
    let source: ScopeID
    let filePath: String
    var description: String
    var steps: [ChainStepRecord]
    var extraFields: [String: String]
}

struct SkillRecord: Identifiable, Hashable {
    let id: String
    let name: String
    let description: String?
    let source: ScopeID
    let filePath: String
    let body: String
}

struct DiagnosticWarning: Identifiable, Hashable {
    let id: String
    let message: String
}

struct SettingsSummary: Hashable {
    let path: String
    let packages: [String]
    let disableBuiltins: Bool?
    let agentOverrides: [BuiltinOverrideRecord]
}

struct EnvKeyRecord: Identifiable, Hashable {
    let id: String
    let key: String
    let value: String?
    let source: ScopeID
}

struct MCPConfigRecord: Identifiable, Hashable {
    let id: String
    let path: String
    let source: ScopeID
    let serverNames: [String]
}

struct AvailableModel: Identifiable, Hashable {
    let provider: String
    let model: String
    let contextWindow: String
    let maxOutput: String
    let supportsThinking: Bool
    let supportsImages: Bool

    var id: String { identifier }
    var identifier: String { "\(provider)/\(model)" }
    var summary: String {
        "\(identifier) · ctx \(contextWindow) · out \(maxOutput)"
    }
}

struct ScanSnapshot: Hashable {
    let projectRoot: String?
    let builtinAgents: [AgentRecord]
    let globalAgents: [AgentRecord]
    let projectAgents: [AgentRecord]
    let legacyProjectAgents: [AgentRecord]
    let effectiveAgents: [EffectiveAgentRecord]
    let chains: [ChainRecord]
    let skills: [SkillRecord]
    let settings: [SettingsSummary]
    let envKeys: [EnvKeyRecord]
    let mcpConfigs: [MCPConfigRecord]
    let warnings: [DiagnosticWarning]

    static let empty = ScanSnapshot(
        projectRoot: nil,
        builtinAgents: [],
        globalAgents: [],
        projectAgents: [],
        legacyProjectAgents: [],
        effectiveAgents: [],
        chains: [],
        skills: [],
        settings: [],
        envKeys: [],
        mcpConfigs: [],
        warnings: []
    )
}
