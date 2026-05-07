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

private enum SettingsLayout {
    static let formWidth: CGFloat = 660
    static let labelWidth: CGFloat = 170
    static let controlWidth: CGFloat = 360
    static let noteSpacing: CGFloat = 5
    static let rowSpacing: CGFloat = 10
    static let sectionSpacing: CGFloat = 18
    static let formPadding: CGFloat = 28
}

private struct SettingsForm<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsLayout.sectionSpacing) {
                content
            }
            .frame(width: SettingsLayout.formWidth, alignment: .topLeading)
            .padding(SettingsLayout.formPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .scrollBounceBehavior(.basedOnSize)
    }
}

private struct SettingsSection<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsLayout.rowSpacing) {
            content
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.separator.opacity(0.45), lineWidth: 1)
        }
    }
}

private struct SettingsRow<Content: View>: View {
    let title: String
    var note: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(title)
                .fontWeight(.semibold)
                .frame(width: SettingsLayout.labelWidth, alignment: .trailing)

            VStack(alignment: .leading, spacing: SettingsLayout.noteSpacing) {
                content
                if let note {
                    SettingsNote(text: note)
                }
            }
            .frame(width: SettingsLayout.controlWidth, alignment: .leading)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

private struct SettingsNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SettingsTextFieldRow: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    var note: String?

    var body: some View {
        SettingsRow(title: title, note: note) {
            TextField(placeholder, text: $text)
                .font(.body.monospaced())
                .textSelection(.enabled)
                .frame(width: SettingsLayout.controlWidth)
        }
    }
}

private struct SettingsButtonRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        SettingsRow(title: "") {
            HStack(spacing: 8) {
                content
            }
        }
    }
}

private struct SettingsPickerRow<SelectionValue: Hashable, Content: View>: View {
    let title: String
    @Binding var selection: SelectionValue
    var note: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        SettingsRow(title: title, note: note) {
            Picker(title, selection: $selection) {
                content
            }
            .labelsHidden()
            .frame(width: 220, alignment: .leading)
        }
    }
}

private struct SettingsStepperRow: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let valueText: String
    var note: String? = nil

    var body: some View {
        SettingsRow(title: title, note: note) {
            Stepper(value: $value, in: range) {
                Text(valueText)
                    .monospacedDigit()
                    .frame(minWidth: 96, alignment: .leading)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }
}

private struct SettingsValueButtonRow<Content: View>: View {
    let title: String
    let value: String
    @ViewBuilder let buttons: Content

    var body: some View {
        SettingsRow(title: title) {
            Text(value)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: SettingsLayout.controlWidth, alignment: .leading)

            HStack(spacing: 8) {
                buttons
            }
        }
    }
}

private struct SettingsToggleRow: View {
    let title: String
    var label: String = ""
    var note: String?
    @Binding var isOn: Bool

    var body: some View {
        SettingsRow(title: title, note: note) {
            Toggle(label, isOn: $isOn)
                .toggleStyle(.checkbox)
        }
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        SettingsForm {
            SettingsSection {
                SettingsTextFieldRow(
                    title: "Project root:",
                    placeholder: "Root folder",
                    text: projectsRootPathBinding,
                    note: "Default: \(ProjectDiscovery.defaultRootDirectoryURL().path)"
                )

                SettingsButtonRow {
                    Button("Choose Folder...") { viewModel.chooseProjectsRootDirectory() }
                    Button("Use Default") { viewModel.resetProjectsRootPathToDefault() }
                    Button("Reveal in Finder") { revealInFinder(viewModel.configuredProjectsRootPath) }
                }
            }

            SettingsSection {
                SettingsTextFieldRow(
                    title: "Skill import folder:",
                    placeholder: "Default import folder",
                    text: defaultSkillsImportRootPathBinding,
                    note: "Pi Manager falls back to the last used folder, then Documents."
                )

                SettingsButtonRow {
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
        SettingsForm {
            SettingsSection {
                SettingsPickerRow(
                    title: "Thinking display:",
                    selection: piAgentThinkingDisplayBinding,
                    note: "Show full reasoning, compact previews, or hide thinking blocks from the transcript."
                ) {
                    ForEach(PiAgentThinkingDisplayMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
            }

            SettingsSection {
                SettingsStepperRow(
                    title: "Notification delay:",
                    value: piAgentNotificationDelayBinding,
                    range: 1...60,
                    valueText: "\(viewModel.piAgentNotificationDelayMinutes) minutes",
                    note: "Before notifying about unread sessions."
                )
            }

            SettingsSection {
                SettingsPickerRow(title: "Terminal app:", selection: piAgentTerminalApplicationSelectionBinding) {
                    ForEach(viewModel.piAgentTerminalApplicationOptions) { option in
                        Text(option.name).tag(option.id)
                    }
                }

                SettingsValueButtonRow(title: "Application:", value: selectedTerminalPathText) {
                    Button("Choose Other...") { viewModel.choosePiAgentTerminalApplication() }
                    Button("Use macOS Default") { viewModel.resetPiAgentTerminalApplicationToDefault() }
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
        SettingsForm {
            SettingsSection {
                SettingsStepperRow(
                    title: "Issue cache lifetime:",
                    value: cacheLifetimeBinding,
                    range: 1...240,
                    valueText: "\(viewModel.gitHubBoardCacheLifetimeMinutes) minutes",
                    note: "Refresh bypasses the cache."
                )
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
        SettingsForm {
            SettingsSection {
                SettingsToggleRow(
                    title: "Builtins:",
                    label: "Disable all builtins globally",
                    note: "Per-agent quick controls in the Agents screen also apply globally for now.",
                    isOn: userDisableBuiltinsBinding
                )
            }
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
