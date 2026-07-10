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
    var whenToUse: String?
    var model: String?
    var fallbackModels: [String]
    var thinking: String?
    var systemPromptMode: String?
    var inheritSkills: Bool?
    var disabled: Bool?
    var tools: [String]?
    var mcpDirectTools: [String]?
    /// MCP server names assigned to this agent (native MCP bridge). Distinct from
    /// `mcpDirectTools`, which is the external pi-mcp-adapter `mcp:tool` convention.
    var mcpServers: [String]?
    var extensions: [String]?
    var skills: [String]
    var output: String?
    var defaultExpectedOutcome: PiSubagentExpectedOutcome?
    var defaultReads: [String]?
    var defaultProgress: Bool?
    var interactive: Bool?
    var maxSubagentDepth: Int?
    var systemPrompt: String
    var unknownFields: [String: String]

    static let empty = AgentConfig(
        name: "",
        description: "",
        whenToUse: nil,
        model: nil,
        fallbackModels: [],
        thinking: nil,
        systemPromptMode: nil,
        inheritSkills: nil,
        disabled: nil,
        tools: nil,
        mcpDirectTools: nil,
        mcpServers: nil,
        extensions: nil,
        skills: [],
        output: nil,
        defaultExpectedOutcome: nil,
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

nonisolated struct BuiltinOverrideRecord: Hashable, Sendable {
    let agentName: String
    let scope: ScopeID
    let settingsPath: String
    let values: [String: JSONValue]

    /// The override's explicit `disabled` flag, or nil when it doesn't set one.
    /// `values` holds `JSONValue` (an enum), so `values["disabled"] as? Bool`
    /// always yields nil — every read must go through `boolValue`. Centralized
    /// here so the assignment UI and resolver-mirroring helpers can't diverge.
    var disabledOverride: Bool? {
        values["disabled"]?.boolValue
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

nonisolated struct SkillRecord: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let description: String?
    let source: ScopeID
    let filePath: String
    let body: String
}

nonisolated struct SkillCollectionRecord: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var description: String?
    /// Stable root paths for the skills that belong to this collection. Paths are
    /// standardized when written, and resolved against the current skill catalog
    /// so launch still emits individual `--skill <path>` arguments.
    var skillRootPaths: Set<String>
    /// Name fallback used when a member path no longer resolves (for example, a
    /// user moved a local imported skill but kept the same catalog entry).
    var skillNames: Set<String>
    /// Members that remain in the collection/catalog grouping but are excluded
    /// from runtime expansion. Missing keys default to empty for older settings.
    var excludedSkillRootPaths: Set<String>
    var excludedSkillNames: Set<String>
    /// The imported git repository this collection mirrors, when applicable.
    var importedRepositoryID: UUID?
    var sourceLabel: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case skillRootPaths
        case skillNames
        case excludedSkillRootPaths
        case excludedSkillNames
        case importedRepositoryID
        case sourceLabel
    }

    init(
        id: UUID = UUID(),
        name: String,
        description: String? = nil,
        skillRootPaths: Set<String>,
        skillNames: Set<String>,
        excludedSkillRootPaths: Set<String> = [],
        excludedSkillNames: Set<String> = [],
        importedRepositoryID: UUID? = nil,
        sourceLabel: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.skillRootPaths = Set(skillRootPaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        self.skillNames = skillNames
        self.excludedSkillRootPaths = Set(excludedSkillRootPaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        self.excludedSkillNames = excludedSkillNames
        self.importedRepositoryID = importedRepositoryID
        self.sourceLabel = sourceLabel
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            name: try container.decode(String.self, forKey: .name),
            description: try container.decodeIfPresent(String.self, forKey: .description),
            skillRootPaths: try container.decodeIfPresent(Set<String>.self, forKey: .skillRootPaths) ?? [],
            skillNames: try container.decodeIfPresent(Set<String>.self, forKey: .skillNames) ?? [],
            excludedSkillRootPaths: try container.decodeIfPresent(Set<String>.self, forKey: .excludedSkillRootPaths) ?? [],
            excludedSkillNames: try container.decodeIfPresent(Set<String>.self, forKey: .excludedSkillNames) ?? [],
            importedRepositoryID: try container.decodeIfPresent(UUID.self, forKey: .importedRepositoryID),
            sourceLabel: try container.decodeIfPresent(String.self, forKey: .sourceLabel)
        )
    }
}

nonisolated struct ProjectSkillRecap: Hashable, Sendable {
    let defaultSkills: [SkillRecord]
    let projectSkills: [SkillRecord]
    let unresolvedNames: [String]
}

nonisolated struct ProjectAgentRecap: Hashable, Sendable {
    let defaultAgents: [EffectiveAgentRecord]
    let projectAgents: [EffectiveAgentRecord]
    let otherEffectiveAgents: [EffectiveAgentRecord]
    let unresolvedNames: [String]
}

/// One MCP server in a project's assignment recap: its name plus a short
/// transport/endpoint detail (e.g. "Local · npx" or "Remote · api.pidgeon.news").
nonisolated struct MCPServerRecapItem: Hashable, Sendable, Identifiable {
    let name: String
    let detail: String?
    var id: String { name }
}

nonisolated struct ProjectMcpServerRecap: Hashable, Sendable {
    let defaultServers: [MCPServerRecapItem]
    let projectServers: [MCPServerRecapItem]
    let unresolvedNames: [String]

    var hasResolvedServers: Bool { !defaultServers.isEmpty || !projectServers.isEmpty }
    var totalAssigned: Int { defaultServers.count + projectServers.count + unresolvedNames.count }
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
    case externalReference = "Imported Reference"
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

nonisolated struct DiagnosticWarning: Identifiable, Hashable, Sendable {
    let id: String
    let message: String
}

nonisolated struct AgentSkillVisibilityIssue: Identifiable, Hashable, Sendable {
    let project: DiscoveredProject
    let missingSkills: [String]

    var id: String { "\(project.id):\(missingSkills.joined(separator: ","))" }
}

nonisolated struct SkillReferenceWarning: Identifiable, Hashable, Sendable {
    let agentName: String
    let project: DiscoveredProject
    let missingSkill: String

    var id: String { "\(agentName):\(project.id):\(missingSkill)" }
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

nonisolated enum PiThinkingLevelCatalog {
    /// Pi's canonical order as of 0.80.6. Individual models expose a subset;
    /// notably GPT-5.6 adds `max` while earlier reasoning models stop at `xhigh`.
    static let ordered = ["off", "minimal", "low", "medium", "high", "xhigh", "max"]
    /// Levels Pi guarantees for a reasoning model unless its model metadata says
    /// otherwise. Used only when the exact runtime capability probe cannot run.
    static let baseline = ["off", "minimal", "low", "medium", "high"]

    static func sortIndex(_ level: String) -> Int {
        ordered.firstIndex(of: level) ?? Int.max
    }
}

nonisolated struct AvailableModel: Identifiable, Hashable, Sendable {
    let provider: String
    let model: String
    let contextWindow: String
    /// nil when the source reports no max-output limit. Rendered as a dash, never a fabricated
    /// default. See [[feedback-show-dash-for-unknown-max-output]].
    let maxOutput: String?
    let supportsThinking: Bool
    let supportsImages: Bool
    let supportedThinkingLevels: [String]

    var id: String { identifier }
    var identifier: String { "\(provider)/\(model)" }
    var summary: String {
        "\(identifier) · ctx \(contextWindow) · out \(maxOutput ?? "—")"
    }

    var displayName: String {
        identifier == "apple/foundation" ? "Apple Foundation Model" : identifier
    }

    var modelDisplayName: String {
        identifier == "apple/foundation" ? "Foundation" : model
    }
}

nonisolated struct ScanSnapshot: Hashable, Sendable {
    let projectRoot: String?
    let builtinAgents: [AgentRecord]
    let globalAgents: [AgentRecord]
    let projectAgents: [AgentRecord]
    let legacyProjectAgents: [AgentRecord]
    let effectiveAgents: [EffectiveAgentRecord]
    let libraryAgents: [AgentRecord]
    let skills: [SkillRecord]
    let librarySkills: [SkillRecord]
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
        libraryAgents: [],
        skills: [],
        librarySkills: [],
        promptTemplates: [],
        libraryPromptTemplates: [],
        settings: [],
        envKeys: [],
        warnings: []
    )
}
