import Foundation

nonisolated enum ResourceScopeKind: String, CaseIterable, Codable, Sendable {
    case builtin = "Builtin"
    case global = "Global"
    case project = "Project"
    case legacyProject = "Legacy Project"
    case override = "Override"
    case package = "Package"
    case library = "Library"
}

nonisolated struct ScopeID: Hashable, Identifiable, Sendable {
    let kind: ResourceScopeKind
    let path: String

    var id: String { "\(kind.rawValue):\(path)" }
    var displayName: String { kind.rawValue }
}

nonisolated struct AgentConfig: Hashable, Sendable {
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

nonisolated struct AgentRecord: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let description: String
    let source: ScopeID
    let filePath: String
    let rawFrontmatter: [String: String]
    let promptBody: String
    let parsed: AgentConfig
}

nonisolated struct BuiltinOverrideRecord: Hashable, @unchecked Sendable {
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
            if let value = values[key] {
                hasher.combine(String(describing: value))
            }
        }
    }
}

nonisolated enum ResolutionKind: String, Sendable {
    case builtin = "Builtin"
    case builtinWithOverride = "Builtin + Override"
    case globalCustom = "Global"
    case projectCustom = "Project"
    case globalReplacement = "Global Replacement"
    case projectReplacement = "Project Replacement"
    case library = "Library"
}

nonisolated struct EffectiveAgentRecord: Identifiable, Hashable, Sendable {
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

nonisolated struct ChainStepRecord: Identifiable, Hashable, Sendable {
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

nonisolated struct ChainRecord: Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    let source: ScopeID
    let filePath: String
    var description: String
    var steps: [ChainStepRecord]
    var extraFields: [String: String]
}

nonisolated struct SkillRecord: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let description: String?
    let source: ScopeID
    let filePath: String
    let body: String
}

nonisolated enum SkillLibraryImportMode: String, CaseIterable, Hashable, Identifiable, Sendable {
    case symlink
    case copy

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .symlink: return "Symlink"
        case .copy: return "Copy"
        }
    }

    var description: String {
        switch self {
        case .symlink: return "Keep the source repo as the single source of truth and link it into the library."
        case .copy: return "Make an editable snapshot in the library that no longer tracks source updates."
        }
    }
}

nonisolated struct ExternalSkillCandidate: Identifiable, Hashable, Sendable {
    let name: String
    let description: String?
    let sourceRootPath: String
    let skillFilePath: String

    var id: String { sourceRootPath }
}

nonisolated struct SkillImportResult: Hashable, Sendable {
    let importedNames: [String]
    let skippedNames: [String]
}

nonisolated enum PromptTemplateDiscoveryKind: String, Hashable, Sendable {
    case standardDirectory = "Standard Directory"
    case settings = "Settings"
    case package = "Package"
}

nonisolated struct PromptTemplateRecord: Identifiable, Hashable, Sendable {
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

nonisolated enum CommandRecordKind: String, Hashable, Sendable {
    case builtIn = "Built-in Command"
    case `extension` = "Extension Command"
}

nonisolated struct CommandRecord: Identifiable, Hashable, Sendable {
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

nonisolated struct DiagnosticWarning: Identifiable, Hashable, Sendable {
    let id: String
    let message: String
}

nonisolated struct AgentSkillVisibilityIssue: Identifiable, Hashable, Sendable {
    let project: DiscoveredProject
    let missingSkills: [String]

    var id: String { "\(project.id):\(missingSkills.joined(separator: ","))" }
}

nonisolated struct SettingsSummary: Hashable, Sendable {
    let path: String
    let packages: [String]
    let prompts: [String]
    let disableBuiltins: Bool?
    let agentOverrides: [BuiltinOverrideRecord]
}

nonisolated struct EnvKeyRecord: Identifiable, Hashable, Sendable {
    let id: String
    let key: String
    let value: String?
    let source: ScopeID
}

nonisolated struct AvailableModel: Identifiable, Hashable, Sendable {
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

nonisolated struct ScanSnapshot: Hashable, Sendable {
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
        warnings: []
    )
}
