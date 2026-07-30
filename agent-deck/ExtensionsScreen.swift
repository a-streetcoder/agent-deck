import SwiftUI

/// Runtime → Extensions. Controls whether the user's own Pi extensions load into
/// Agent Deck sessions, with a deselectable checklist and tool-name conflict
/// warnings. Discovery runs OFF the main thread and is cached in `@State`; the
/// SwiftUI body never performs filesystem I/O.
struct ExtensionsScreen: View {
    var viewModel: AppViewModel
    @ObservedObject private var languageStore = LanguageStore.shared

    /// Discovered Pi extension candidates, loaded off-main and cached. Never read
    /// via a body-time `discover()` call.
    @State private var candidates: [PiExtensionCandidate] = []
    /// Bridge tool-name overlaps per candidate id, computed off-main.
    @State private var conflictsByID: [String: [String]] = [:]
    @State private var isDiscovering = false
    /// Whether the local web-fetch fallback dependency is installed (filesystem
    /// check, refreshed off the render path). Drives the "Web fetch" bridge state.
    @State private var webFetchInstalled = false

    private var mode: PiAgentExtensionLoadingMode {
        viewModel.appSettings.piAgentExtensionLoadingMode
    }

    var body: some View {
        AppPage(LanguageStore.shared.t("ext.pageTitle"), subtitle: LanguageStore.shared.t("ext.pageSubtitle")) {
            VStack(alignment: .leading, spacing: 20) {
                modeCard
                if mode.usesCustomPiExtensionSelection {
                    selectionCard
                }
                bridgesCard
            }
        }
        // Re-discover on appear, on project switch, and on toolbar Refresh. Off-main.
        .task(id: "\(viewModel.projectRootURL?.path ?? "")#\(viewModel.piExtensionsRefreshToken)") {
            await discoverCandidates()
        }
        // Re-scan conflicts whenever the candidate set changes. Off-main.
        .task(id: candidates.map(\.id).joined()) {
            await loadRowMetadata()
        }
    }

    // MARK: - Mode

    private var modeCard: some View {
        AppCard(title: languageStore.t("ext.loadingMode")) {
            VStack(alignment: .leading, spacing: 12) {
                Picker(languageStore.t("ext.loadingModePicker"), selection: modeBinding) {
                    ForEach(PiAgentExtensionLoadingMode.allCases) { mode in
                        Text(languageStore.t(mode.l10nTitleKey)).tag(mode)
                    }
                }
                .appSegmentedPicker()
                .labelsHidden()

                Text(languageStore.t(mode.l10nDescriptionKey))
                    .font(AppTheme.Font.supporting)
                    .foregroundStyle(AppTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var modeBinding: Binding<PiAgentExtensionLoadingMode> {
        Binding(
            get: { viewModel.appSettings.piAgentExtensionLoadingMode },
            set: { viewModel.setPiAgentExtensionLoadingMode($0) }
        )
    }

    // MARK: - Agent Deck bridges (read-only, live state)

    /// The bridges that would actually load right now, evaluated against current
    /// settings + environment (mirrors `PiNativeSubagentBridgeExtensions` /
    /// `PiAgentRunnerService` inject conditions). Reactive to settings/env changes.
    private var activeBridgeIDs: Set<String> {
        let envMap = Dictionary(uniqueKeysWithValues: viewModel.snapshot.envKeys.compactMap { item -> (String, String)? in
            guard let value = item.value else { return nil }
            return (item.key, value)
        })
        let exaConfigured = PiNativeSubagentBridgeExtensions.isWebSearchConfigured(environment: envMap)
        return Set(PiNativeSubagentBridgeExtensions.injectedParentBridges(
            memoryEnabled: viewModel.appSettings.agentMemoryEnabled,
            exaConfigured: exaConfigured,
            fallbackWebFetchAvailable: webFetchInstalled,
            subagentsActive: viewModel.appSettings.nativeSubagentsEnabledForNewSessions,
            mcpActive: viewModel.appSettings.mcpEnabled
        ).map(\.id))
    }

    /// Whether discovery found a pi-web-access (or *web-access*) package/extension candidate.
    private var candidatesContainPiWebAccess: Bool {
        candidates.contains { candidate in
            let package = (candidate.packageName ?? "").lowercased()
            let name = candidate.name.lowercased()
            let launch = candidate.launchSource.lowercased()
            let id = candidate.id.lowercased()
            return package.contains("web-access")
                || name.contains("web-access")
                || launch.contains("web-access")
                || id.contains("web-access")
                || package.contains("pi-web-access")
        }
    }


    private var bridgesCard: some View {
        AppCard(title: LanguageStore.shared.t("ext.bridgesTitle")) {
            VStack(alignment: .leading, spacing: 10) {
                Text(LanguageStore.shared.t("ext.bridgesBody", AppBrand.displayName))
                    .font(AppTheme.Font.supporting)
                    .foregroundStyle(AppTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)

                // pi-web-access config dependency: keys only; package is not required.
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "link.circle.fill")
                        .foregroundStyle(Color.accentColor.opacity(0.85))
                        .font(.caption)
                    Text(languageStore.t("ext.bridge.webSearch.piWebAccessHint"))
                        .font(AppTheme.Font.micro)
                        .foregroundStyle(AppTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)

                if candidatesContainPiWebAccess {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                        Text(languageStore.t("ext.piWebAccessSkippedBanner"))
                            .font(AppTheme.Font.micro)
                            .foregroundStyle(AppTheme.mutedText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                let active = activeBridgeIDs
                VStack(alignment: .leading, spacing: 0) {
                    let bridges = PiNativeSubagentBridgeExtensions.bridgeDescriptors
                    ForEach(Array(bridges.enumerated()), id: \.element.id) { index, bridge in
                        bridgeRow(bridge, isActive: active.contains(bridge.id))
                        if index < bridges.count - 1 {
                            Divider().opacity(0.5)
                        }
                    }
                }
            }
        }
    }

    private func bridgeRow(_ bridge: PiNativeSubagentBridgeExtensions.BridgeDescriptor, isActive: Bool) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(languageStore.t(bridge.nameKey))
                    .font(AppTheme.Font.primary.weight(.semibold))
                    .fontWidth(.expanded)
                Text(languageStore.t(bridge.summaryKey))
                    .font(AppTheme.Font.supporting)
                    .foregroundStyle(AppTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
                Text(bridge.toolNames.joined(separator: ", "))
                    .font(AppTheme.Font.micro.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let conditionKey = bridge.conditionKey {
                    Text(languageStore.t(conditionKey))
                        .font(AppTheme.Font.micro)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)
            AppLabelTag(text: isActive ? languageStore.t("ext.active") : languageStore.t("ext.off"), color: isActive ? .green : .secondary)
        }
        .padding(.vertical, 12)
        .opacity(isActive ? 1 : 0.55)
    }

    // MARK: - User extension checklist

    private var selectionCard: some View {
        AppCard(title: LanguageStore.shared.t("ext.yourExtensions"), trailing: { selectionToolbar }) {
            if candidates.isEmpty {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                        PiExtensionSelectionRow(
                            candidate: candidate,
                            isEnabled: Binding(
                                get: { !viewModel.appSettings.disabledPiExtensionIDs.contains(candidate.id) },
                                set: { viewModel.setPiExtension(candidate, enabled: $0) }
                            ),
                            conflictingToolNames: conflictsByID[candidate.id] ?? []
                        )
                        if index < candidates.count - 1 {
                            Divider().opacity(0.5)
                        }
                    }
                }
            }
        }
    }

    private var selectionToolbar: some View {
        HStack(spacing: 8) {
            Button(languageStore.t("ext.all")) { viewModel.setAllPiExtensions(candidates, enabled: true) }
                .controlSize(.small)
                .disabled(candidates.isEmpty || enabledCount == candidates.count)
            Button(languageStore.t("ext.none")) { viewModel.setAllPiExtensions(candidates, enabled: false) }
                .controlSize(.small)
                .disabled(candidates.isEmpty || enabledCount == 0)
        }
    }

    private var enabledCount: Int {
        candidates.filter { !viewModel.appSettings.disabledPiExtensionIDs.contains($0.id) }.count
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(isDiscovering ? languageStore.t("ext.looking") : languageStore.t("ext.noneFound"))
                .font(.subheadline.weight(.semibold))
            Text(languageStore.t("ext.discoveryHelp"))
                .font(.footnote)
                .foregroundStyle(AppTheme.mutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Off-main loading

    private func discoverCandidates() async {
        let root = viewModel.projectRootURL
        // Cheap 2-file check; refreshed here rather than in the render path.
        webFetchInstalled = WebFetchDependencyService().status().isInstalled
        isDiscovering = true
        let found = await Task.detached(priority: .utility) {
            PiExtensionDiscoveryService().discover(projectRoot: root)
        }.value
        candidates = found
        // Drop deselection state for extensions that no longer exist.
        viewModel.prunePiExtensionSelection(to: found)
        isDiscovering = false
    }

    private func loadRowMetadata() async {
        let snapshot = candidates
        let conflicts = await Task.detached(priority: .utility) { () -> [String: [String]] in
            var result: [String: [String]] = [:]
            for candidate in snapshot {
                let found = PiExtensionConflictDetector.conflictingBridgeToolNames(for: candidate)
                if !found.isEmpty { result[candidate.id] = found }
            }
            return result
        }.value
        conflictsByID = conflicts
    }
}

// MARK: - Rows

private struct PiExtensionSelectionRow: View {
    let candidate: PiExtensionCandidate
    @Binding var isEnabled: Bool
    /// Bridge tool names detected in this extension's source that overlap with
    /// Agent Deck's built-in bridges. Empty means no detected conflict.
    var conflictingToolNames: [String] = []
    @ObservedObject private var languageStore = LanguageStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $isEnabled) {
                Text(candidate.name)
                    .font(.body.weight(.semibold))
                    .fontWidth(.expanded)
                    .lineLimit(1)
            }
            .appCheckbox()
            .opacity(!conflictingToolNames.isEmpty ? 0.6 : 1.0)

            Text(candidate.launchSource)
                .font(.caption)
                .foregroundStyle(AppTheme.mutedText)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, 22)

            if isEnabled && !conflictingToolNames.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text(conflictWarningText)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fontWidth(.condensed)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 22)
            }
        }
        .padding(.vertical, 10)
        .help(candidate.launchSource)
    }

    private var conflictWarningText: String {
        let names = conflictingToolNames.joined(separator: ", ")
        if conflictingToolNames.count == 1 {
            return languageStore.t("ext.conflict.one", names)
        }
        return languageStore.t("ext.conflict.many", names)
    }
}
