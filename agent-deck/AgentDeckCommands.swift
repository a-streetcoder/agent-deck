import AppKit
import SwiftUI

enum AgentDeckShortcutAction: String, CaseIterable, Identifiable {
    case newSession
    case newAgent
    case refresh
    case stopSession
    case deleteSession
    case toggleInspector
    case resumeInTerminal
    case refreshGitHub
    case commitChanges
    case pushBranch
    case addProject
    case importSkills
    case newPrompt

    var id: String { rawValue }
}

struct AgentDeckShortcutItem: Identifiable {
    let action: AgentDeckShortcutAction
    let title: String
    let key: String
    let modifiers: EventModifiers
    let description: String

    var id: AgentDeckShortcutAction { action }
}

struct AgentDeckShortcutSection: Identifiable {
    let title: String
    let items: [AgentDeckShortcutItem]

    var id: String { title }
}

extension AgentDeckShortcutItem {
    init(_ action: AgentDeckShortcutAction, _ title: String, key: String, modifiers: EventModifiers, description: String) {
        self.action = action
        self.title = title
        self.key = key
        self.modifiers = modifiers
        self.description = description
    }
}

extension AgentDeckShortcutSection {
    static let all: [AgentDeckShortcutSection] = [
        AgentDeckShortcutSection(title: "Session", items: [
            .init(.newSession, "New Session", key: "n", modifiers: [.command], description: "Create a new Pi Agent session for the current project."),
            .init(.stopSession, "Stop Session", key: ".", modifiers: [.command], description: "Stop the currently running session."),
            .init(.deleteSession, "Delete Session", key: "delete", modifiers: [.command], description: "Delete the selected session."),
            .init(.toggleInspector, "Toggle Inspector", key: "i", modifiers: [.command, .option], description: "Show or hide the session inspector."),
            .init(.resumeInTerminal, "Resume in Terminal", key: "t", modifiers: [.command, .option], description: "Resume the selected session in your configured terminal.")
        ]),
        AgentDeckShortcutSection(title: "Agents", items: [
            .init(.newAgent, "New Agent", key: "n", modifiers: [.command, .shift], description: "Create a new custom agent.")
        ]),
        AgentDeckShortcutSection(title: "App", items: [
            .init(.refresh, "Refresh", key: "r", modifiers: [.command], description: "Refresh projects, agents, prompts, and GitHub data.")
        ]),
        AgentDeckShortcutSection(title: "GitHub", items: [
            .init(.refreshGitHub, "Refresh GitHub", key: "g", modifiers: [.command, .shift], description: "Refresh GitHub issue and repository data."),
            .init(.commitChanges, "Commit Changes", key: "c", modifiers: [.command, .option], description: "Commit the prepared GitHub changes."),
            .init(.pushBranch, "Push Branch", key: "p", modifiers: [.command, .option], description: "Push the current GitHub branch.")
        ]),
        AgentDeckShortcutSection(title: "Projects & Resources", items: [
            .init(.addProject, "Add Project…", key: "o", modifiers: [.command, .option], description: "Add a project folder."),
            .init(.importSkills, "Import Skills…", key: "i", modifiers: [.command, .shift], description: "Import agent skills."),
            .init(.newPrompt, "New Prompt", key: "n", modifiers: [.command, .option], description: "Create a new prompt template.")
        ])
    ]

    static func item(for action: AgentDeckShortcutAction) -> AgentDeckShortcutItem {
        all.flatMap(\.items).first { $0.action == action }!
    }
}

private extension View {
    @ViewBuilder
    func agentDeckShortcut(_ action: AgentDeckShortcutAction) -> some View {
        let item = AgentDeckShortcutSection.item(for: action)
        if item.key == "delete" {
            keyboardShortcut(.delete, modifiers: item.modifiers)
        } else if let character = item.key.first {
            keyboardShortcut(KeyEquivalent(character), modifiers: item.modifiers)
        } else {
            self
        }
    }
}

/// `@Observable` so property mutations are picked up by SwiftUI consumers
/// (`@FocusedValue(\.agentDeckCommands)` readers like the menu `Commands` body)
/// without needing to swap the focused-scene-value's reference on every update.
/// The old pattern in `updateCommandContext` was to allocate a brand-new
/// `AgentDeckCommandContext` instance per call and reassign it to the `@State`,
/// which made `focusedSceneValue` see a new identity every frame and SwiftUI
/// logged "FocusedValue update tried to update multiple times per frame" when
/// two updates landed in the same render cycle. With `@Observable` we keep the
/// same instance for the lifetime of the scene and just mutate its properties.
@Observable
final class AgentDeckCommandContext {
    var canCreatePiAgentSession = false
    var canCreateAgent = false
    var canDeletePiAgentSession = false
    var canStopPiAgentSession = false
    var canTogglePiAgentInspector = false
    var canOpenPiAgentInTerminal = false
    var canCommitGitHubChanges = false
    var canPushGitHubBranch = false
    var canEnableAllProjects = false
    var canDisableAllProjects = false
    var canAddProject = false
    var canImportSkills = false
    var canCreatePrompt = false
    var canCopyPromptInvocation = false
    var canOpenPromptFile = false
    var canRevealPromptFile = false
    var canOpenSelectedAgentFile = false
    var canRevealSelectedAgentFile = false
    var canToggleSelectedAgentDisabled = false
    var selectedAgentIsDisabled = false

    var openSettings: () -> Void = {}
    var refresh: () -> Void = {}
    var createPiAgentSession: () -> Void = {}
    var createAgent: () -> Void = {}
    var deletePiAgentSession: () -> Void = {}
    var stopPiAgentSession: () -> Void = {}
    var togglePiAgentInspector: () -> Void = {}
    var resumePiAgentInTerminal: () -> Void = {}
    var refreshGitHub: () -> Void = {}
    var commitGitHubChanges: () -> Void = {}
    var pushGitHubBranch: () -> Void = {}
    var enableAllProjects: () -> Void = {}
    var disableAllProjects: () -> Void = {}
    var addProject: () -> Void = {}
    var importSkills: () -> Void = {}
    var createPrompt: () -> Void = {}
    var copyPromptInvocation: () -> Void = {}
    var openPromptFile: () -> Void = {}
    var revealPromptFile: () -> Void = {}
    var openSelectedAgentFile: () -> Void = {}
    var revealSelectedAgentFile: () -> Void = {}
    var toggleSelectedAgentDisabled: () -> Void = {}
}

private struct AgentDeckCommandContextKey: FocusedValueKey {
    typealias Value = AgentDeckCommandContext
}

extension FocusedValues {
    var agentDeckCommands: AgentDeckCommandContext? {
        get { self[AgentDeckCommandContextKey.self] }
        set { self[AgentDeckCommandContextKey.self] = newValue }
    }
}

/// Tiny `Equatable` host that owns the `focusedSceneValue` publication.
/// Applying `.focusedSceneValue` directly on a view whose body reads many
/// observable properties (e.g. `ContentView.mainContent`) lets SwiftUI invoke
/// the modifier multiple times within a single render frame during bursty
/// updates (streaming, etc.), which logs
/// "FocusedValue update tried to update multiple times per frame".
/// `commandContext` is a stable reference for the lifetime of the scene, so
/// identity comparison short-circuits re-renders and the modifier runs once.
struct AgentDeckCommandsScope: View, Equatable {
    let context: AgentDeckCommandContext

    static func == (lhs: AgentDeckCommandsScope, rhs: AgentDeckCommandsScope) -> Bool {
        lhs.context === rhs.context
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .focusedSceneValue(\.agentDeckCommands, context)
    }
}

struct AgentDeckCommands: Commands {
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.agentDeckCommands) private var context

    var body: some Commands {
        SidebarCommands()
        InspectorCommands()

        CommandGroup(replacing: .appInfo) {
            Button("About \(AppBrand.displayName)") {
                openWindow(id: AboutWindow.id)
            }
            Button("Check for Updates…") {
                AgentDeckAppDelegate.shared?.updater.checkForUpdates()
            }
        }

        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                openSettings()
            }
            .keyboardShortcut(",", modifiers: [.command])
        }

        CommandGroup(replacing: .newItem) {
            Button("New Session") {
                context?.createPiAgentSession()
            }
            .agentDeckShortcut(.newSession)
            .disabled(context?.canCreatePiAgentSession != true)

            Button("New Agent") {
                context?.createAgent()
            }
            .agentDeckShortcut(.newAgent)
            .disabled(context?.canCreateAgent != true)
        }

        CommandGroup(after: .saveItem) {
            Button("Refresh") {
                context?.refresh()
            }
            .agentDeckShortcut(.refresh)
            .disabled(context == nil)
        }

        CommandMenu("Agent") {
            Button("Stop Session") {
                context?.stopPiAgentSession()
            }
            .agentDeckShortcut(.stopSession)
            .disabled(context?.canStopPiAgentSession != true)

            Button("Delete Session") {
                context?.deletePiAgentSession()
            }
            .agentDeckShortcut(.deleteSession)
            .disabled(context?.canDeletePiAgentSession != true)

            Divider()

            Button("Toggle Inspector") {
                context?.togglePiAgentInspector()
            }
            .agentDeckShortcut(.toggleInspector)
            .disabled(context?.canTogglePiAgentInspector != true)

            Button("Resume in Terminal") {
                context?.resumePiAgentInTerminal()
            }
            .agentDeckShortcut(.resumeInTerminal)
            .disabled(context?.canOpenPiAgentInTerminal != true)

            Divider()

            Button("Open Agent File") {
                context?.openSelectedAgentFile()
            }
            .disabled(context?.canOpenSelectedAgentFile != true)

            Button("Reveal Agent in Finder") {
                context?.revealSelectedAgentFile()
            }
            .disabled(context?.canRevealSelectedAgentFile != true)

            Button(context?.selectedAgentIsDisabled == true ? "Enable Agent" : "Disable Agent") {
                context?.toggleSelectedAgentDisabled()
            }
            .disabled(context?.canToggleSelectedAgentDisabled != true)
        }

        CommandMenu("GitHub") {
            Button("Refresh GitHub") {
                context?.refreshGitHub()
            }
            .agentDeckShortcut(.refreshGitHub)
            .disabled(context == nil)

            Button("Commit Changes") {
                context?.commitGitHubChanges()
            }
            .agentDeckShortcut(.commitChanges)
            .disabled(context?.canCommitGitHubChanges != true)

            Button("Push Branch") {
                context?.pushGitHubBranch()
            }
            .agentDeckShortcut(.pushBranch)
            .disabled(context?.canPushGitHubBranch != true)
        }

        CommandMenu("Projects") {
            Button("Add Project…") {
                context?.addProject()
            }
            .agentDeckShortcut(.addProject)
            .disabled(context?.canAddProject != true)

            Divider()

            Button("Enable All Projects") {
                context?.enableAllProjects()
            }
            .disabled(context?.canEnableAllProjects != true)

            Button("Disable All Projects") {
                context?.disableAllProjects()
            }
            .disabled(context?.canDisableAllProjects != true)
        }

        CommandMenu("Resources") {
            Button("Import Skills…") {
                context?.importSkills()
            }
            .agentDeckShortcut(.importSkills)
            .disabled(context?.canImportSkills != true)

            Divider()

            Button("New Prompt") {
                context?.createPrompt()
            }
            .agentDeckShortcut(.newPrompt)
            .disabled(context?.canCreatePrompt != true)

            Button("Copy Prompt Invocation") {
                context?.copyPromptInvocation()
            }
            .disabled(context?.canCopyPromptInvocation != true)

            Button("Open Prompt File") {
                context?.openPromptFile()
            }
            .disabled(context?.canOpenPromptFile != true)

            Button("Reveal Prompt in Finder") {
                context?.revealPromptFile()
            }
            .disabled(context?.canRevealPromptFile != true)
        }
    }
}
