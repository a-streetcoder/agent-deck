import Foundation

enum AppSymbols {
    static let promptTemplate = "rectangle.and.pencil.and.ellipsis"
}

enum SidebarItem: String, CaseIterable, Identifiable {
    case projects = "Projects"
    case instructions = "System Prompt"
    case memory = "Memory"
    case issues = "Issues"
    case agent = "Pi Agent"
    case agents = "Agents"
    case skills = "Skills"
    case prompts = "Prompts"
    case subagents = "Deck agents"
    case models = "Models"
    case environment = "Environment"
    case doctor = "Doctor"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .projects: return "folder"
        case .instructions: return "doc.text.magnifyingglass"
        case .memory: return "brain"
        case .issues: return "circle.dotted"
        case .agent: return "sparkles.rectangle.stack"
        case .agents: return "paperplane"
        case .skills: return "wand.and.stars"
        case .prompts: return AppSymbols.promptTemplate
        case .subagents: return "slider.horizontal.3"
        case .models: return "cpu"
        case .environment: return "key"
        case .doctor: return "stethoscope"
        }
    }

    /// Asset-catalog image to use instead of `systemImage`, when set.
    var assetImageName: String? {
        switch self {
        case .issues: return "github"
        default: return nil
        }
    }
}

enum SidebarSection: String, CaseIterable, Identifiable {
    case workspace = "Workspace"
    case piResources = "Resources"
    case runtime = "Runtime"

    var id: String { rawValue }

    var items: [SidebarItem] {
        unsortedItems.sorted { $0.rawValue.localizedStandardCompare($1.rawValue) == .orderedAscending }
    }

    private var unsortedItems: [SidebarItem] {
        switch self {
        case .workspace:
            return [.projects, .instructions, .memory, .issues]
        case .piResources:
            return [.agents, .skills, .prompts]
        case .runtime:
            return [.models, .environment, .doctor]
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
