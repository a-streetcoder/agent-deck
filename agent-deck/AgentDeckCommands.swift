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
    /// `Localizable.strings` key for the menu / shortcuts title.
    let titleKey: String
    let key: String
    let modifiers: EventModifiers
    /// `Localizable.strings` key for the longer help description.
    let descriptionKey: String

    var id: AgentDeckShortcutAction { action }

    @MainActor
    var title: String { LanguageStore.shared.t(titleKey) }

    @MainActor
    var description: String { LanguageStore.shared.t(descriptionKey) }
}

struct AgentDeckShortcutSection: Identifiable {
    let titleKey: String
    let items: [AgentDeckShortcutItem]

    var id: String { titleKey }

    @MainActor
    var title: String { LanguageStore.shared.t(titleKey) }
}

extension AgentDeckShortcutItem {
    init(_ action: AgentDeckShortcutAction, _ titleKey: String, key: String, modifiers: EventModifiers, descriptionKey: String) {
        self.action = action
        self.titleKey = titleKey
        self.key = key
        self.modifiers = modifiers
        self.descriptionKey = descriptionKey
    }
}

extension AgentDeckShortcutSection {
    static let all: [AgentDeckShortcutSection] = [
        AgentDeckShortcutSection(titleKey: "shortcut.section.navigation", items: [
            .init(.openPiAgent, "menu.openPiAgent", key: "1", modifiers: [.command], descriptionKey: "shortcut.openPiAgent.desc"),
            .init(.toggleSessionsPanel, "menu.toggleSessions", key: "s", modifiers: [.command], descriptionKey: "shortcut.toggleSessions.desc"),
            .init(.openProjects, "menu.openProjects", key: "2", modifiers: [.command], descriptionKey: "shortcut.openProjects.desc"),
            .init(.openAgents, "menu.openAgents", key: "4", modifiers: [.command], descriptionKey: "shortcut.openAgents.desc"),
            .init(.openSkills, "menu.openSkills", key: "5", modifiers: [.command], descriptionKey: "shortcut.openSkills.desc"),
            .init(.openPrompts, "menu.openPrompts", key: "6", modifiers: [.command], descriptionKey: "shortcut.openPrompts.desc")
        ]),
        AgentDeckShortcutSection(titleKey: "shortcut.section.session", items: [
            .init(.newSession, "menu.newSession", key: "n", modifiers: [.command], descriptionKey: "shortcut.newSession.desc"),
            .init(.nextSession, "menu.nextSession", key: "]", modifiers: [.command], descriptionKey: "shortcut.nextSession.desc"),
            .init(.previousSession, "menu.previousSession", key: "[", modifiers: [.command], descriptionKey: "shortcut.previousSession.desc"),
            .init(.previousQuestion, "shortcut.previousQuestion", key: "upArrow", modifiers: [.shift], descriptionKey: "shortcut.previousQuestion.desc"),
            .init(.nextQuestion, "shortcut.nextQuestion", key: "downArrow", modifiers: [.shift], descriptionKey: "shortcut.nextQuestion.desc"),
            .init(.stopSession, "menu.stopSession", key: ".", modifiers: [.command], descriptionKey: "shortcut.stopSession.desc"),
            .init(.deleteSession, "menu.deleteSession", key: "delete", modifiers: [.command], descriptionKey: "shortcut.deleteSession.desc"),
            .init(.resumeInTerminal, "menu.resumeTerminal", key: "t", modifiers: [.command, .option], descriptionKey: "shortcut.resumeTerminal.desc"),
            .init(.startComposerDictation, "shortcut.dictation", key: "d", modifiers: [.option], descriptionKey: "shortcut.dictation.desc")
        ]),
        AgentDeckShortcutSection(titleKey: "shortcut.section.agents", items: [
            .init(.newAgent, "menu.newAgent", key: "n", modifiers: [.command, .shift], descriptionKey: "shortcut.newAgent.desc")
        ]),
        AgentDeckShortcutSection(titleKey: "shortcut.section.app", items: [
            .init(.refresh, "menu.refresh", key: "r", modifiers: [.command], descriptionKey: "shortcut.refresh.desc")
        ]),
        AgentDeckShortcutSection(titleKey: "shortcut.section.git", items: [
            .init(.refreshGitHub, "menu.refreshGit", key: "g", modifiers: [.command, .shift], descriptionKey: "shortcut.refreshGit.desc"),
            .init(.commitChanges, "menu.commit", key: "c", modifiers: [.command, .option], descriptionKey: "shortcut.commit.desc"),
            .init(.pushBranch, "menu.push", key: "p", modifiers: [.command, .option], descriptionKey: "shortcut.push.desc")
        ]),
        AgentDeckShortcutSection(titleKey: "shortcut.section.projectsResources", items: [
            .init(.addProject, "menu.addProject", key: "o", modifiers: [.command, .option], descriptionKey: "shortcut.addProject.desc"),
            .init(.importSkills, "menu.importSkillsEllipsis", key: "i", modifiers: [.command, .shift], descriptionKey: "shortcut.importSkills.desc"),
            .init(.newPrompt, "menu.newPrompt", key: "n", modifiers: [.command, .option], descriptionKey: "shortcut.newPrompt.desc")
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
    @ObservedObject private var languageStore = LanguageStore.shared

    var body: some Commands {
        SidebarCommands()

        CommandGroup(replacing: .appInfo) {
            Button(languageStore.t("menu.about", AppBrand.displayName)) {
                openWindow(id: AboutWindow.id)
            }
            // Pi Deck: Sparkle is off unless a first-party SUFeedURL is set.
            // Keep the item but no-op when updater is disabled (avoids Agent Deck appcast).
            Button(languageStore.t("menu.checkUpdates")) {
                AgentDeckAppDelegate.shared?.updater.checkForUpdates()
            }
        }

        CommandGroup(replacing: .appSettings) {
            Button(languageStore.t("menu.settings")) {
                openSettings()
            }
            .keyboardShortcut(",", modifiers: [.command])

            Menu(languageStore.t("menu.language")) {
                ForEach(AppLanguage.allCases) { lang in
                    Button {
                        languageStore.setLanguage(lang)
                    } label: {
                        if languageStore.language == lang {
                            Label(lang.menuLabel, systemImage: "checkmark")
                        } else {
                            Text(lang.menuLabel)
                        }
                    }
                }
            }
        }

        CommandGroup(replacing: .newItem) {
            Button(languageStore.t("menu.newSession")) {
                context?.createPiAgentSession()
            }
            .agentDeckShortcut(.newSession)
            .disabled(context?.canCreatePiAgentSession != true)

            Button(languageStore.t("menu.newAgent")) {
                context?.createAgent()
            }
            .agentDeckShortcut(.newAgent)
            .disabled(context?.canCreateAgent != true)
        }

        CommandGroup(replacing: .printItem) {
            Button(languageStore.t("menu.openPiAgent")) {
                context?.openPiAgent()
            }
            .keyboardShortcut("p", modifiers: [.command])
            .disabled(context == nil)
        }

        CommandGroup(after: .saveItem) {
            Button(languageStore.t("menu.refresh")) {
                context?.refresh()
            }
            .agentDeckShortcut(.refresh)
            .disabled(context == nil)
        }

        CommandMenu(languageStore.t("menu.agent")) {
            Button(languageStore.t("menu.openPiAgent")) {
                context?.openPiAgent()
            }
            .agentDeckShortcut(.openPiAgent)
            .disabled(context == nil)

            Button(languageStore.t("menu.toggleSessions")) {
                context?.toggleSessionsPanel()
            }
            .agentDeckShortcut(.toggleSessionsPanel)
            .disabled(context == nil)

            Divider()

            Button(languageStore.t("menu.openProjects")) {
                context?.openProjects()
            }
            .agentDeckShortcut(.openProjects)
            .disabled(context == nil)

            Button(languageStore.t("menu.openAgents")) {
                context?.openAgents()
            }
            .agentDeckShortcut(.openAgents)
            .disabled(context == nil)

            Button(languageStore.t("menu.openSkills")) {
                context?.openSkills()
            }
            .agentDeckShortcut(.openSkills)
            .disabled(context == nil)

            Button(languageStore.t("menu.openPrompts")) {
                context?.openPrompts()
            }
            .agentDeckShortcut(.openPrompts)
            .disabled(context == nil)

            Divider()

            Button(languageStore.t("menu.nextSession")) {
                context?.selectNextPiAgentSession()
            }
            .agentDeckShortcut(.nextSession)
            .disabled(context?.canNavigatePiAgentSessions != true)

            Button(languageStore.t("menu.previousSession")) {
                context?.selectPreviousPiAgentSession()
            }
            .agentDeckShortcut(.previousSession)
            .disabled(context?.canNavigatePiAgentSessions != true)

            Divider()

            Button(languageStore.t("menu.stopSession")) {
                context?.stopPiAgentSession()
            }
            .agentDeckShortcut(.stopSession)
            .disabled(context?.canStopPiAgentSession != true)

            Button(languageStore.t("menu.deleteSession")) {
                context?.deletePiAgentSession()
            }
            .agentDeckShortcut(.deleteSession)
            .disabled(context?.canDeletePiAgentSession != true)

            Divider()

            Button(languageStore.t("menu.resumeTerminal")) {
                context?.resumePiAgentInTerminal()
            }
            .agentDeckShortcut(.resumeInTerminal)
            .disabled(context?.canOpenPiAgentInTerminal != true)

            Divider()

            Button(languageStore.t("menu.openAgentFile")) {
                context?.openSelectedAgentFile()
            }
            .disabled(context?.canOpenSelectedAgentFile != true)

            Button(languageStore.t("menu.revealAgent")) {
                context?.revealSelectedAgentFile()
            }
            .disabled(context?.canRevealSelectedAgentFile != true)

            Button(context?.selectedAgentIsDisabled == true
                   ? languageStore.t("menu.enableAgent")
                   : languageStore.t("menu.disableAgent")) {
                context?.toggleSelectedAgentDisabled()
            }
            .disabled(context?.canToggleSelectedAgentDisabled != true)
        }

        CommandMenu(languageStore.t("menu.git")) {
            Button(languageStore.t("menu.refreshGit")) {
                context?.refreshGitHub()
            }
            .agentDeckShortcut(.refreshGitHub)
            .disabled(context == nil)

            Button(languageStore.t("menu.commit")) {
                context?.commitGitHubChanges()
            }
            .agentDeckShortcut(.commitChanges)
            .disabled(context?.canCommitGitHubChanges != true)

            Button(languageStore.t("menu.push")) {
                context?.pushGitHubBranch()
            }
            .agentDeckShortcut(.pushBranch)
            .disabled(context?.canPushGitHubBranch != true)
        }

        CommandMenu(languageStore.t("menu.projects")) {
            Button(languageStore.t("menu.addProject")) {
                context?.addProject()
            }
            .agentDeckShortcut(.addProject)
            .disabled(context?.canAddProject != true)

            Divider()

            Button(languageStore.t("menu.enableAllProjects")) {
                context?.enableAllProjects()
            }
            .disabled(context?.canEnableAllProjects != true)

            Button(languageStore.t("menu.disableAllProjects")) {
                context?.disableAllProjects()
            }
            .disabled(context?.canDisableAllProjects != true)
        }

        CommandMenu(languageStore.t("menu.resources")) {
            Button(languageStore.t("menu.importSkills")) {
                context?.importSkills()
            }
            .agentDeckShortcut(.importSkills)
            .disabled(context?.canImportSkills != true)

            Divider()

            Button(languageStore.t("menu.newPrompt")) {
                context?.createPrompt()
            }
            .agentDeckShortcut(.newPrompt)
            .disabled(context?.canCreatePrompt != true)

            Button(languageStore.t("menu.copyPrompt")) {
                context?.copyPromptInvocation()
            }
            .disabled(context?.canCopyPromptInvocation != true)

            Button(languageStore.t("menu.openPromptFile")) {
                context?.openPromptFile()
            }
            .disabled(context?.canOpenPromptFile != true)

            Button(languageStore.t("menu.revealPrompt")) {
                context?.revealPromptFile()
            }
            .disabled(context?.canRevealPromptFile != true)
        }
    }
}
