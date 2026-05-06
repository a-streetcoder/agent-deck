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
    }
}
