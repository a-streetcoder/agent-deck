import Foundation

enum AppSymbols {
    static let mcp = "mcp"
    static let promptTemplate = "rectangle.and.pencil.and.ellipsis"
}

enum SidebarItem: String, CaseIterable, Identifiable {
    case projects = "Projects"
    case instructions = "System Prompt"
    case memory = "Memory"
    case agent = "Pi Agent"
    case agents = "Agents"
    case skills = "Skills"
    case prompts = "Prompts"
    case loops = "Loops"
    case subagents = "Deck agents"
    case models = "Models"
    case extensions = "Extensions"
    case mcp = "MCP"
    case doctor = "Doctor"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .projects: return "folder"
        case .instructions: return "doc.text.magnifyingglass"
        case .memory: return "brain"
        case .agent: return "sparkles.rectangle.stack"
        case .agents: return "paperplane"
        case .skills: return "wand.and.stars"
        case .prompts: return AppSymbols.promptTemplate
        case .loops: return "infinity"
        case .subagents: return "slider.horizontal.3"
        case .models: return "cpu"
        case .extensions: return "puzzlepiece.extension"
        case .mcp: return AppSymbols.mcp
        case .doctor: return "stethoscope"
        }
    }

    /// Asset-catalog image to use instead of `systemImage`, when set.
    var assetImageName: String? {
        switch self {
        case .mcp: return AppSymbols.mcp
        default: return nil
        }
    }

    /// Stable `Localizable.strings` key for this item.
    var l10nKey: String {
        switch self {
        case .projects: return "sidebar.projects"
        case .instructions: return "sidebar.instructions"
        case .memory: return "sidebar.memory"
        case .agent: return "sidebar.agent"
        case .agents: return "sidebar.agents"
        case .skills: return "sidebar.skills"
        case .prompts: return "sidebar.prompts"
        case .loops: return "sidebar.loops"
        case .subagents: return "sidebar.subagents"
        case .models: return "sidebar.models"
        case .extensions: return "sidebar.extensions"
        case .mcp: return "sidebar.mcp"
        case .doctor: return "sidebar.doctor"
        }
    }

    /// Localized sidebar title (uses current `LanguageStore`).
    @MainActor
    var localizedTitle: String {
        LanguageStore.shared.t(l10nKey)
    }
}

enum SidebarSection: String, CaseIterable, Identifiable {
    case workspace = "Workspace"
    case piResources = "Resources"
    case runtime = "Runtime"

    var id: String { rawValue }

    /// Stable `Localizable.strings` key for this section header.
    var l10nKey: String {
        switch self {
        case .workspace: return "sidebar.section.workspace"
        case .piResources: return "sidebar.section.resources"
        case .runtime: return "sidebar.section.runtime"
        }
    }

    /// Localized section title (uses current `LanguageStore`).
    @MainActor
    var localizedTitle: String {
        LanguageStore.shared.t(l10nKey)
    }

    var items: [SidebarItem] {
        unsortedItems.sorted { $0.rawValue.localizedStandardCompare($1.rawValue) == .orderedAscending }
    }

    private var unsortedItems: [SidebarItem] {
        switch self {
        case .workspace:
            return [.projects, .instructions, .memory]
        case .piResources:
            return [.agents, .skills, .prompts, .loops]
        case .runtime:
            return [.models, .extensions, .mcp, .doctor]
        }
    }
}

enum AgentFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case builtin = "Builtin"
    case global = "Global"
    case project = "Project"
    case overriddenBuiltins = "Overridden Builtins"
    case replacedBuiltins = "Replaced Builtins"
    case customOnly = "Custom Only"
    case disabled = "Disabled"
    case needsAttention = "Needs Attention"

    var id: String { rawValue }
}
