import SwiftUI

struct SettingsSceneContent: View {
    @StateObject private var viewModel = AppViewModel()

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                GeneralSettingsTab(viewModel: viewModel)
                NativeSettingsDivider()
                AgentSettingsTab(viewModel: viewModel)
                NativeSettingsDivider()
                GitHubSettingsTab(viewModel: viewModel)
                NativeSettingsDivider()
                SubagentsSettingsTab(viewModel: viewModel)
            }
            .padding(.horizontal, 40)
            .padding(.top, 30)
            .padding(.bottom, 24)
            .frame(maxWidth: 920, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(minWidth: 760, idealWidth: 860, minHeight: 540)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct NativeSettingsDivider: View {
    var body: some View {
        Divider()
            .padding(.vertical, 22)
    }
}

private struct NativeSettingsRow<Control: View>: View {
    let title: String
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .frame(width: 240, alignment: .trailing)

            control
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 7)
    }
}

private struct NativePathField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity)
    }
}

private struct NativeSettingsNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct NativeCheckboxRow: View {
    let title: String
    let note: String?
    @Binding var isOn: Bool

    init(_ title: String, note: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.note = note
        self._isOn = isOn
    }

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            Spacer()
                .frame(width: 240)

            Toggle(isOn: $isOn) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                    if let note {
                        NativeSettingsNote(text: note)
                    }
                }
            }
            .toggleStyle(.checkbox)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
    }
}

private struct NativeButtonRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 8) {
            content
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            NativeSettingsRow(title: "Project root:") {
                VStack(alignment: .leading, spacing: 7) {
                    NativePathField(placeholder: "Root folder", text: projectsRootPathBinding)
                    NativeSettingsNote(text: "Default: \(ProjectDiscovery.defaultRootDirectoryURL().path)")
                }
            }

            NativeSettingsRow(title: "") {
                NativeButtonRow {
                    Button("Choose Folder...") { viewModel.chooseProjectsRootDirectory() }
                    Button("Use Default") { viewModel.resetProjectsRootPathToDefault() }
                    Button("Reveal in Finder") { revealInFinder(viewModel.configuredProjectsRootPath) }
                }
            }

            NativeSettingsRow(title: "Skill import folder:") {
                VStack(alignment: .leading, spacing: 7) {
                    NativePathField(placeholder: "Default import folder", text: defaultSkillsImportRootPathBinding)
                    NativeSettingsNote(text: "Pi Manager falls back to the last used folder, then Documents.")
                }
            }

            NativeSettingsRow(title: "") {
                NativeButtonRow {
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
        VStack(alignment: .leading, spacing: 4) {
            NativeSettingsRow(title: "Thinking display:") {
                Picker("Thinking display", selection: piAgentThinkingDisplayBinding) {
                    ForEach(PiAgentThinkingDisplayMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 520)
            }

            NativeSettingsRow(title: "") {
                NativeSettingsNote(text: "Show full reasoning, compact previews, or hide thinking blocks from the transcript.")
            }

            NativeSettingsRow(title: "Notification delay:") {
                HStack(spacing: 12) {
                    Stepper(value: piAgentNotificationDelayBinding, in: 1...60) {
                        Text("\(viewModel.piAgentNotificationDelayMinutes) minutes")
                            .font(.system(size: 15, weight: .semibold).monospacedDigit())
                            .frame(minWidth: 92, alignment: .leading)
                    }
                    .labelsHidden()

                    NativeSettingsNote(text: "Before notifying about unread sessions.")
                }
            }

            NativeSettingsRow(title: "Terminal app:") {
                Picker("Terminal app", selection: piAgentTerminalApplicationSelectionBinding) {
                    ForEach(viewModel.piAgentTerminalApplicationOptions) { option in
                        Text(option.name).tag(option.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 520)
            }

            NativeSettingsRow(title: "Application:") {
                VStack(alignment: .leading, spacing: 7) {
                    NativeSettingsNote(text: selectedTerminalPathText)
                    NativeButtonRow {
                        Button("Choose Other...") { viewModel.choosePiAgentTerminalApplication() }
                        Button("Use macOS Default") { viewModel.resetPiAgentTerminalApplicationToDefault() }
                    }
                }
            }
        }
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
        VStack(alignment: .leading, spacing: 4) {
            NativeSettingsRow(title: "Issue cache lifetime:") {
                HStack(spacing: 12) {
                    Stepper(value: cacheLifetimeBinding, in: 1...240) {
                        Text("\(viewModel.gitHubBoardCacheLifetimeMinutes) minutes")
                            .font(.system(size: 15, weight: .semibold).monospacedDigit())
                            .frame(minWidth: 92, alignment: .leading)
                    }
                    .labelsHidden()

                    NativeSettingsNote(text: "Refresh bypasses the cache.")
                }
            }
        }
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
        VStack(alignment: .leading, spacing: 4) {
            NativeCheckboxRow(
                "Disable all builtins globally",
                note: "Per-agent quick controls in the Agents screen also apply globally for now.",
                isOn: userDisableBuiltinsBinding
            )
        }
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
