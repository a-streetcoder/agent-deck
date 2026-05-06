import SwiftUI

struct SettingsSceneContent: View {
    @StateObject private var viewModel = AppViewModel()

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettingsTab(viewModel: viewModel)
            }

            Tab("Agent", systemImage: "sparkles.rectangle.stack") {
                AgentSettingsTab(viewModel: viewModel)
            }

            Tab("GitHub", systemImage: "chevron.left.forwardslash.chevron.right") {
                GitHubSettingsTab(viewModel: viewModel)
            }

            Tab("Subagents", systemImage: "slider.horizontal.3") {
                SubagentsSettingsTab(viewModel: viewModel)
            }
        }
        .frame(minWidth: 660, idealWidth: 760, minHeight: 440, idealHeight: 520)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Project root:") {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Root folder", text: projectsRootPathBinding)
                            .font(.body.monospaced())
                            .textSelection(.enabled)

                        Text("Default: \(ProjectDiscovery.defaultRootDirectoryURL().path)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent("") {
                    HStack {
                        Button("Choose Folder...") { viewModel.chooseProjectsRootDirectory() }
                        Button("Use Default") { viewModel.resetProjectsRootPathToDefault() }
                        Button("Reveal in Finder") { revealInFinder(viewModel.configuredProjectsRootPath) }
                    }
                }
            }

            Section {
                LabeledContent("Skill import folder:") {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Default import folder", text: defaultSkillsImportRootPathBinding)
                            .font(.body.monospaced())
                            .textSelection(.enabled)

                        Text("Pi Manager falls back to the last used folder, then Documents.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent("") {
                    HStack {
                        Button("Choose Folder...") { viewModel.chooseDefaultSkillsImportDirectory() }
                        Button("Clear") { viewModel.resetDefaultSkillsImportRootPath() }
                        Button("Reveal in Finder") {
                            if let path = viewModel.appSettings.defaultSkillsImportRootPath, !path.isEmpty {
                                revealInFinder(path)
                            }
                        }
                        .disabled((viewModel.appSettings.defaultSkillsImportRootPath ?? "").isEmpty)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 640)
        .padding(24)
    }

    private var projectsRootPathBinding: Binding<String> {
        Binding(
            get: { viewModel.appSettings.projectsRootPath },
            set: { viewModel.setProjectsRootPath($0) }
        )
    }

    private var defaultSkillsImportRootPathBinding: Binding<String> {
        Binding(
            get: { viewModel.appSettings.defaultSkillsImportRootPath ?? "" },
            set: { viewModel.setDefaultSkillsImportRootPath($0) }
        )
    }
}

// MARK: - Agent

private struct AgentSettingsTab: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        Form {
            Section {
                Picker("Thinking display:", selection: piAgentThinkingDisplayBinding) {
                    ForEach(PiAgentThinkingDisplayMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }

                LabeledContent("") {
                    Text("Show full reasoning, compact previews, or hide thinking blocks from the transcript.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Stepper(value: piAgentNotificationDelayBinding, in: 1...60) {
                    Text("Notification delay: \(viewModel.piAgentNotificationDelayMinutes) minutes")
                }
            } footer: {
                Text("Before notifying about unread sessions.")
            }

            Section {
                Picker("Terminal app:", selection: piAgentTerminalApplicationSelectionBinding) {
                    ForEach(viewModel.piAgentTerminalApplicationOptions) { option in
                        Text(option.name).tag(option.id)
                    }
                }

                LabeledContent("Application:") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(selectedTerminalPathText)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)

                        HStack {
                            Button("Choose Other...") { viewModel.choosePiAgentTerminalApplication() }
                            Button("Use macOS Default") { viewModel.resetPiAgentTerminalApplicationToDefault() }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 640)
        .padding(24)
    }

    private var piAgentThinkingDisplayBinding: Binding<PiAgentThinkingDisplayMode> {
        Binding(
            get: { viewModel.appSettings.piAgentThinkingDisplayMode },
            set: { viewModel.setPiAgentThinkingDisplayMode($0) }
        )
    }

    private var piAgentNotificationDelayBinding: Binding<Int> {
        Binding(
            get: { viewModel.piAgentNotificationDelayMinutes },
            set: { viewModel.setPiAgentNotificationDelayMinutes($0) }
        )
    }

    private var piAgentTerminalApplicationSelectionBinding: Binding<String> {
        Binding(
            get: { viewModel.piAgentTerminalApplicationSelectionID },
            set: { viewModel.setPiAgentTerminalApplicationSelection($0) }
        )
    }

    private var selectedTerminalPathText: String {
        viewModel.appSettings.piAgentTerminalApplicationPath ?? "macOS default"
    }
}

// MARK: - GitHub

private struct GitHubSettingsTab: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        Form {
            Section {
                Stepper(value: cacheLifetimeBinding, in: 1...240) {
                    Text("Issue cache lifetime: \(viewModel.gitHubBoardCacheLifetimeMinutes) minutes")
                }
            } footer: {
                Text("Refresh bypasses the cache.")
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 640)
        .padding(24)
    }

    private var cacheLifetimeBinding: Binding<Int> {
        Binding(
            get: { viewModel.gitHubBoardCacheLifetimeMinutes },
            set: { viewModel.setGitHubBoardCacheLifetimeMinutes($0) }
        )
    }
}

// MARK: - Subagents

private struct SubagentsSettingsTab: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        Form {
            Section {
                Toggle(isOn: userDisableBuiltinsBinding) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Disable all builtins globally")
                        Text("Per-agent quick controls in the Agents screen also apply globally for now.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 640)
        .padding(24)
    }

    private var userDisableBuiltinsBinding: Binding<Bool> {
        Binding(
            get: { viewModel.userDisableBuiltins },
            set: { viewModel.setDisableBuiltins($0, scope: .global) }
        )
    }
}

private func revealInFinder(_ path: String?) {
    guard let path, !path.isEmpty else { return }
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
}

#Preview {
    SettingsSceneContent()
}
