import Foundation

enum SidebarItem: String, CaseIterable, Identifiable {
    case projects = "Projects"
    case agent = "Pi Agent"
    case agents = "Agents"
    case chains = "Chains"
    case skills = "Skills"
    case prompts = "Prompts"
    case subagents = "Subagents"
    case models = "Models"
    case environment = "Environment"
    case diagnostics = "Diagnostics"
    case piDocs = "Docs"
    case credits = "Credits"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .projects: return "folder"
        case .agent: return "sparkles.rectangle.stack"
        case .agents: return "rectangle.connected.to.line.below"
        case .chains: return "point.3.connected.trianglepath.dotted"
        case .skills: return "wand.and.stars"
        case .prompts: return "rectangle.and.pencil.and.ellipsis"
        case .subagents: return "slider.horizontal.3"
        case .models: return "cpu"
        case .environment: return "key"
        case .diagnostics: return "stethoscope"
        case .piDocs: return "book"
        case .credits: return "info.circle"
        }
    }
}

enum SidebarSection: String, CaseIterable, Identifiable {
    case workspace = "Workspace"
    case piResources = "Pi Resources"
    case runtime = "Runtime"
    case reference = "Reference"

    var id: String { rawValue }

    var items: [SidebarItem] {
        switch self {
        case .workspace:
            return [.projects]
        case .piResources:
            return [.agents, .chains, .skills, .prompts]
        case .runtime:
            return [.models, .environment, .diagnostics]
        case .reference:
            return [.piDocs, .credits]
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
