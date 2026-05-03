import Foundation

struct SubagentControlConfig: Hashable {
    var enabled: Bool?
    var needsAttentionAfterMs: Int?
    var notifyChannels: [String]
}

struct SubagentParallelConfig: Hashable {
    var maxTasks: Int?
    var concurrency: Int?
}

struct SubagentIntercomBridgeConfig: Hashable {
    var mode: String?
    var instructionFile: String?
}

struct SubagentExtensionConfig: Hashable {
    var asyncByDefault: Bool?
    var forceTopLevelAsync: Bool?
    var defaultSessionDir: String?
    var maxSubagentDepth: Int?
    var control: SubagentControlConfig
    var parallel: SubagentParallelConfig
    var worktreeSetupHook: String?
    var worktreeSetupHookTimeoutMs: Int?
    var intercomBridge: SubagentIntercomBridgeConfig

    static let empty = SubagentExtensionConfig(
        asyncByDefault: nil,
        forceTopLevelAsync: nil,
        defaultSessionDir: nil,
        maxSubagentDepth: nil,
        control: SubagentControlConfig(enabled: nil, needsAttentionAfterMs: nil, notifyChannels: []),
        parallel: SubagentParallelConfig(maxTasks: nil, concurrency: nil),
        worktreeSetupHook: nil,
        worktreeSetupHookTimeoutMs: nil,
        intercomBridge: SubagentIntercomBridgeConfig(mode: nil, instructionFile: nil)
    )

    static let packageDefaults = SubagentExtensionConfig(
        asyncByDefault: false,
        forceTopLevelAsync: false,
        defaultSessionDir: nil,
        maxSubagentDepth: nil,
        control: SubagentControlConfig(enabled: true, needsAttentionAfterMs: 60000, notifyChannels: ["event", "async", "intercom"]),
        parallel: SubagentParallelConfig(maxTasks: 8, concurrency: 4),
        worktreeSetupHook: nil,
        worktreeSetupHookTimeoutMs: 30000,
        intercomBridge: SubagentIntercomBridgeConfig(mode: "always", instructionFile: nil)
    )
}

enum ResourceScopeKind: String, CaseIterable, Codable {
    case builtin = "Builtin"
    case global = "Global"
    case project = "Project"
    case legacyProject = "Legacy Project"
    case override = "Override"
    case package = "Package"
    case library = "Library"
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
    var defaultContext: String?
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
        defaultContext: nil,
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
    case builtin = "Builtin"
    case builtinWithOverride = "Builtin + Override"
    case globalCustom = "Global"
    case projectCustom = "Project"
    case globalReplacement = "Global Replacement"
    case projectReplacement = "Project Replacement"
    case library = "Library"
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

enum PromptTemplateDiscoveryKind: String, Hashable {
    case standardDirectory = "Standard Directory"
    case settings = "Settings"
    case package = "Package"
}

struct PromptTemplateRecord: Identifiable, Hashable {
    let id: String
    let name: String
    let description: String
    let argumentHint: String?
    let source: ScopeID
    let filePath: String
    let body: String
    let discoveryKind: PromptTemplateDiscoveryKind
    let packageName: String?

    var invocation: String { "/\(name)" }
}

enum CommandRecordKind: String, Hashable {
    case builtIn = "Built-in Command"
    case `extension` = "Extension Command"
}

struct CommandRecord: Identifiable, Hashable {
    let id: String
    let name: String
    let description: String
    let kind: CommandRecordKind
    let packageName: String?
    let notes: String?
    let sourcePath: String?
    let sourceScope: String?
    let sourceOrigin: String?

    var invocation: String { "/\(name)" }
}

struct DiagnosticWarning: Identifiable, Hashable {
    let id: String
    let message: String
}

struct SettingsSummary: Hashable {
    let path: String
    let packages: [String]
    let prompts: [String]
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

struct SubagentConfigRecord: Identifiable, Hashable {
    let id: String
    let path: String
    let config: SubagentExtensionConfig
}

struct AvailableModel: Identifiable, Hashable {
    let provider: String
    let model: String
    let contextWindow: String
    let maxOutput: String
    let supportsThinking: Bool
    let supportsImages: Bool
    let supportedThinkingLevels: [String]

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
    let libraryAgents: [AgentRecord]
    let libraryChains: [ChainRecord]
    let skills: [SkillRecord]
    let librarySkills: [SkillRecord]
    let commands: [CommandRecord]
    let promptTemplates: [PromptTemplateRecord]
    let libraryPromptTemplates: [PromptTemplateRecord]
    let settings: [SettingsSummary]
    let envKeys: [EnvKeyRecord]
    let mcpConfigs: [MCPConfigRecord]
    let subagentConfig: SubagentConfigRecord?
    let warnings: [DiagnosticWarning]

    static let empty = ScanSnapshot(
        projectRoot: nil,
        builtinAgents: [],
        globalAgents: [],
        projectAgents: [],
        legacyProjectAgents: [],
        effectiveAgents: [],
        chains: [],
        libraryAgents: [],
        libraryChains: [],
        skills: [],
        librarySkills: [],
        commands: [],
        promptTemplates: [],
        libraryPromptTemplates: [],
        settings: [],
        envKeys: [],
        mcpConfigs: [],
        subagentConfig: nil,
        warnings: []
    )
}
