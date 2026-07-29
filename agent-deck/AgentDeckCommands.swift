import AppKit
import SwiftUI

enum AgentDeckShortcutAction: String, CaseIterable, Identifiable {
    case openPiAgent
    case toggleSessionsPanel
    case openProjects
    case openAgents
    case openSkills
    case openPrompts
    case newSession
    case nextSession
    case previousSession
    case previousQuestion
    case nextQuestion
    case newAgent
    case refresh
    case stopSession
    case deleteSession
    case resumeInTerminal
    case startComposerDictation
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
        AgentDeckShortcutSection(title: "Navigation", items: [
            .init(.openPiAgent, "Open Pi Agent", key: "1", modifiers: [.command], description: "Jump to the Pi Agent screen."),
            .init(.toggleSessionsPanel, "Toggle Sessions Panel", key: "s", modifiers: [.command], description: "Expand or collapse the sessions panel in the sidebar."),
            .init(.openProjects, "Open Projects", key: "2", modifiers: [.command], description: "Jump to the Projects screen."),
            .init(.openAgents, "Open Agents", key: "4", modifiers: [.command], description: "Jump to the Agents screen."),
            .init(.openSkills, "Open Skills", key: "5", modifiers: [.command], description: "Jump to the Skills screen."),
            .init(.openPrompts, "Open Prompts", key: "6", modifiers: [.command], description: "Jump to the Prompts screen.")
        ]),
        AgentDeckShortcutSection(title: "Session", items: [
            .init(.newSession, "New Session", key: "n", modifiers: [.command], description: "Create a new Pi Agent session for the current project."),
            .init(.nextSession, "Next Session", key: "]", modifiers: [.command], description: "Select the next session in the current project."),
            .init(.previousSession, "Previous Session", key: "[", modifiers: [.command], description: "Select the previous session in the current project."),
            .init(.previousQuestion, "Previous Question", key: "upArrow", modifiers: [.shift], description: "Jump to the previous user question when the Pi Agent transcript is focused."),
            .init(.nextQuestion, "Next Question", key: "downArrow", modifiers: [.shift], description: "Jump to the next user question when the Pi Agent transcript is focused."),
            .init(.stopSession, "Stop Session", key: ".", modifiers: [.command], description: "Stop the currently running session."),
            .init(.deleteSession, "Delete Session", key: "delete", modifiers: [.command], description: "Delete the selected session."),
            .init(.resumeInTerminal, "Resume in Terminal", key: "t", modifiers: [.command, .option], description: "Resume the selected session in your configured terminal."),
            .init(.startComposerDictation, "Start Composer Dictation", key: "d", modifiers: [.option], description: "Start macOS Dictation in the focused Pi Agent composer.")
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
@MainActor
final class AgentDeckCommandContext {
    var canCreatePiAgentSession = false
    var canCreateAgent = false
    var canDeletePiAgentSession = false
    var canStopPiAgentSession = false
    var canNavigatePiAgentSessions = false
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
    var openPiAgent: () -> Void = {}
    var toggleSessionsPanel: () -> Void = {}
    var openProjects: () -> Void = {}
    var openAgents: () -> Void = {}
    var openSkills: () -> Void = {}
    var openPrompts: () -> Void = {}
    var createPiAgentSession: () -> Void = {}
    var selectNextPiAgentSession: () -> Void = {}
    var selectPreviousPiAgentSession: () -> Void = {}
    var createAgent: () -> Void = {}
    var deletePiAgentSession: () -> Void = {}
    var stopPiAgentSession: () -> Void = {}
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

        CommandGroup(replacing: .printItem) {
            Button("Open Pi Agent") {
                context?.openPiAgent()
            }
            .keyboardShortcut("p", modifiers: [.command])
            .disabled(context == nil)
        }

        CommandGroup(after: .saveItem) {
            Button("Refresh") {
                context?.refresh()
            }
            .agentDeckShortcut(.refresh)
            .disabled(context == nil)
        }

        CommandMenu("Agent") {
            Button("Open Pi Agent") {
                context?.openPiAgent()
            }
            .agentDeckShortcut(.openPiAgent)
            .disabled(context == nil)

            Button("Toggle Sessions Panel") {
                context?.toggleSessionsPanel()
            }
            .agentDeckShortcut(.toggleSessionsPanel)
            .disabled(context == nil)

            Divider()

            Button("Open Projects") {
                context?.openProjects()
            }
            .agentDeckShortcut(.openProjects)
            .disabled(context == nil)

            Button("Open Agents") {
                context?.openAgents()
            }
            .agentDeckShortcut(.openAgents)
            .disabled(context == nil)

            Button("Open Skills") {
                context?.openSkills()
            }
            .agentDeckShortcut(.openSkills)
            .disabled(context == nil)

            Button("Open Prompts") {
                context?.openPrompts()
            }
            .agentDeckShortcut(.openPrompts)
            .disabled(context == nil)

            Divider()

            Button("Next Session") {
                context?.selectNextPiAgentSession()
            }
            .agentDeckShortcut(.nextSession)
            .disabled(context?.canNavigatePiAgentSessions != true)

            Button("Previous Session") {
                context?.selectPreviousPiAgentSession()
            }
            .agentDeckShortcut(.previousSession)
            .disabled(context?.canNavigatePiAgentSessions != true)

            Divider()

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
            Button("Import Skills") {
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
