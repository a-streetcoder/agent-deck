import SwiftUI

struct PiManagerCommandContext {
    var canCreateAgent = false
    var canDeletePiAgentSession = false
    var canStopPiAgentSession = false
    var canOpenPiAgentActivity = false
    var canOpenPiAgentRepoChanges = false
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
    var canCopyCommandInvocation = false
    var canOpenSelectedAgentFile = false
    var canRevealSelectedAgentFile = false
    var canEditSelectedAgent = false
    var canToggleSelectedAgentDisabled = false
    var selectedAgentIsDisabled = false

    var openSettings: () -> Void = {}
    var refresh: () -> Void = {}
    var createAgent: () -> Void = {}
    var deletePiAgentSession: () -> Void = {}
    var stopPiAgentSession: () -> Void = {}
    var showPiAgentActivity: () -> Void = {}
    var showPiAgentRepoChanges: () -> Void = {}
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
    var copyCommandInvocation: () -> Void = {}
    var openSelectedAgentFile: () -> Void = {}
    var revealSelectedAgentFile: () -> Void = {}
    var editSelectedAgent: () -> Void = {}
    var toggleSelectedAgentDisabled: () -> Void = {}
}

private struct PiManagerCommandContextKey: FocusedValueKey {
    typealias Value = PiManagerCommandContext
}

extension FocusedValues {
    var piManagerCommands: PiManagerCommandContext? {
        get { self[PiManagerCommandContextKey.self] }
        set { self[PiManagerCommandContextKey.self] = newValue }
    }
}

struct PiManagerCommands: Commands {
    @FocusedValue(\.piManagerCommands) private var context

    var body: some Commands {
        SidebarCommands()
        InspectorCommands()

        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                context?.openSettings()
            }
            .keyboardShortcut(",", modifiers: [.command])
            .disabled(context == nil)
        }

        CommandGroup(replacing: .newItem) {
            Button("New Agent") {
                context?.createAgent()
            }
            .keyboardShortcut("n", modifiers: [.command])
            .disabled(context?.canCreateAgent != true)
        }

        CommandGroup(after: .saveItem) {
            Button("Refresh") {
                context?.refresh()
            }
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(context == nil)
        }

        CommandMenu("Agent") {
            Button("Stop Session") {
                context?.stopPiAgentSession()
            }
            .keyboardShortcut(".", modifiers: [.command])
            .disabled(context?.canStopPiAgentSession != true)

            Button("Delete Session") {
                context?.deletePiAgentSession()
            }
            .keyboardShortcut(.delete, modifiers: [.command])
            .disabled(context?.canDeletePiAgentSession != true)

            Divider()

            Button("Show Activity") {
                context?.showPiAgentActivity()
            }
            .keyboardShortcut("1", modifiers: [.command, .option])
            .disabled(context?.canOpenPiAgentActivity != true)

            Button("Show Repo Changes") {
                context?.showPiAgentRepoChanges()
            }
            .keyboardShortcut("2", modifiers: [.command, .option])
            .disabled(context?.canOpenPiAgentRepoChanges != true)

            Button("Toggle Inspector") {
                context?.togglePiAgentInspector()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(context?.canTogglePiAgentInspector != true)

            Button("Resume in Terminal") {
                context?.resumePiAgentInTerminal()
            }
            .keyboardShortcut("t", modifiers: [.command, .option])
            .disabled(context?.canOpenPiAgentInTerminal != true)

            Divider()

            Button("Edit Agent") {
                context?.editSelectedAgent()
            }
            .keyboardShortcut("e", modifiers: [.command, .option])
            .disabled(context?.canEditSelectedAgent != true)

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
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(context == nil)

            Button("Commit Changes") {
                context?.commitGitHubChanges()
            }
            .keyboardShortcut("c", modifiers: [.command, .option])
            .disabled(context?.canCommitGitHubChanges != true)

            Button("Push Branch") {
                context?.pushGitHubBranch()
            }
            .keyboardShortcut("p", modifiers: [.command, .option])
            .disabled(context?.canPushGitHubBranch != true)
        }

        CommandMenu("Projects") {
            Button("Add Project…") {
                context?.addProject()
            }
            .keyboardShortcut("o", modifiers: [.command, .option])
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
            .keyboardShortcut("i", modifiers: [.command, .shift])
            .disabled(context?.canImportSkills != true)

            Divider()

            Button("New Prompt") {
                context?.createPrompt()
            }
            .keyboardShortcut("n", modifiers: [.command, .option])
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

            Button("Copy Command Invocation") {
                context?.copyCommandInvocation()
            }
            .disabled(context?.canCopyCommandInvocation != true)
        }
    }
}
