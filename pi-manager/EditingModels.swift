import Foundation

enum AgentEditingTarget: Hashable {
    case builtinOverride(scope: OverrideScope)
    case custom(scope: CustomAgentScope)

    enum OverrideScope: String, CaseIterable, Identifiable, Hashable {
        case global
        case project

        var id: String { rawValue }
        var displayName: String { rawValue.capitalized }
    }

    enum CustomAgentScope: String, CaseIterable, Identifiable, Hashable {
        case global
        case project

        var id: String { rawValue }
        var displayName: String { rawValue.capitalized }
    }
}

struct AgentEditorDraft: Identifiable, Hashable {
    let target: AgentEditingTarget
    let originalName: String
    var config: AgentConfig
    var sourcePath: String?

    var id: String {
        "agent::\(originalName)::\(sourcePath ?? targetLabel)"
    }

    private var targetLabel: String {
        switch target {
        case let .builtinOverride(scope): return "builtin-\(scope.rawValue)"
        case let .custom(scope): return "custom-\(scope.rawValue)"
        }
    }
}

struct ChainEditorDraft: Identifiable, Hashable {
    let originalName: String
    var chain: ChainRecord

    var id: String {
        "chain::\(originalName)::\(chain.filePath)"
    }
}

struct EnvEditorDraft: Identifiable, Hashable {
    let originalKey: String?
    var key: String
    var value: String
    let path: String
    let scope: ResourceScopeKind

    var id: String {
        "env::\(originalKey ?? key)::\(path)"
    }
}
