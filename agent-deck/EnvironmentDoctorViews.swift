import AppKit
import SwiftUI

struct EnvironmentInfoPopover: View {
    @ObservedObject private var languageStore = LanguageStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(languageStore.t("env.resolutionOrder"))
                .font(.headline)
                .fontWidth(.expanded)

            VStack(alignment: .leading, spacing: 10) {
                infoRow(languageStore.t("env.res1Title"), languageStore.t("env.res1Body"))
                infoRow(languageStore.t("env.res2Title"), languageStore.t("env.res2Body"))
                infoRow(languageStore.t("env.res3Title"), languageStore.t("env.res3Body"))
            }

            Text(languageStore.t("env.existingSessionsNote"))
                .font(.caption)
                .foregroundStyle(AppTheme.mutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 360, alignment: .leading)
    }

    private func infoRow(_ title: String, _ description: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .fontWidth(.expanded)
            Text(description)
                .font(.caption)
                .foregroundStyle(AppTheme.mutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct EnvironmentScreen: View {
    let snapshot: ScanSnapshot
    let onEditKey: (EnvKeyRecord) -> Void
    let onDeleteKey: (EnvKeyRecord) -> Void
    @ObservedObject private var languageStore = LanguageStore.shared
    @State private var revealedKeys: Set<String> = []
    @State private var pendingDelete: EnvKeyRecord?

    var body: some View {
        AppPage(languageStore.t("env.pageTitle"), subtitle: languageStore.t("env.pageSubtitle")) {
            AppCard(title: languageStore.t("env.cardTitle")) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(languageStore.t("env.cardBody"))
                        .font(AppTheme.Font.supporting)
                        .foregroundStyle(AppTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)

                    if snapshot.envKeys.isEmpty {
                        emptyEnvironmentState
                    } else {
                        VStack(spacing: 10) {
                            ForEach(snapshot.envKeys.sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }) { record in
                                environmentKeyRow(record)
                            }
                        }
                    }
                }
            }
        }
        .confirmationDialog(
            languageStore.t("env.deleteTitle"),
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { record in
            Button(languageStore.t("env.deleteConfirm", record.key), role: .destructive) {
                onDeleteKey(record)
                pendingDelete = nil
            }
            Button(languageStore.t("common.cancel"), role: .cancel) {
                pendingDelete = nil
            }
        } message: { record in
            Text(languageStore.t("env.deleteMessage", record.key, record.source.path))
        }
    }

    private var emptyEnvironmentState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(languageStore.t("env.emptyTitle"), systemImage: "key")
                .font(AppTheme.Font.primary.weight(.semibold))
            Text(languageStore.t("env.emptyBody"))
                .font(AppTheme.Font.supporting)
                .foregroundStyle(AppTheme.mutedText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(AppTheme.contentSubtleFill))
    }

    private func environmentKeyRow(_ record: EnvKeyRecord) -> some View {
        AppRowCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "key.fill")
                        .foregroundStyle(.orange)
                        .frame(width: 22)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.key)
                            .font(AppTheme.Font.primary.monospaced().weight(.semibold))
                            .textSelection(.enabled)
                        Text(record.source.path)
                            .font(AppTheme.Font.metadata.monospaced())
                            .foregroundStyle(AppTheme.mutedText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }

                    Spacer(minLength: 12)
                }

                HStack(spacing: 8) {
                    Text(revealedKeys.contains(record.key) ? (record.value ?? "") : maskedValue(record.value))
                        .font(.footnote.monospaced())
                        .foregroundStyle(revealedKeys.contains(record.key) ? .primary : AppTheme.mutedText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .appGlassCapsule()

                    Button {
                        toggleReveal(for: record.key)
                    } label: {
                        Label(revealedKeys.contains(record.key) ? "Hide" : "Reveal", systemImage: revealedKeys.contains(record.key) ? "eye.slash" : "eye")
                    }
                    .labelStyle(.iconOnly)
                    .help(revealedKeys.contains(record.key) ? "Hide value" : "Reveal value")

                    Button(languageStore.t("common.edit")) { onEditKey(record) }
                    Button(languageStore.t("common.delete"), role: .destructive) {
                        pendingDelete = record
                    }
                }
            }
        }
    }

    private func maskedValue(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "(empty)" }
        return String(repeating: "•", count: min(max(value.count, 8), 24))
    }

    private func toggleReveal(for key: String) {
        if revealedKeys.contains(key) {
            revealedKeys.remove(key)
        } else {
            revealedKeys.insert(key)
        }
    }
}

struct DoctorScreen: View {
    var viewModel: AppViewModel
    @ObservedObject private var languageStore = LanguageStore.shared
    @State private var setupItems: [SetupCheckItem] = []
    /// Shared with the launch auto-updater so manual and automatic updates use
    /// one installer, one `isRunning` guard, and one `phase`.
    private var piInstaller = PiAgentAutoUpdater.shared.installer
    @State private var piRuntimeStatus: PiAgentRuntimeStatus?
    @State private var isRefreshingSetup = true
    @State private var webFetchStatus = WebFetchDependencyService().status()
    @State private var isInstallingWebFetchDependencies = false
    @State private var webFetchInstallMessage: String?
    @State private var isRefreshingPiRuntime = false
    @State private var envDraft: EnvEditorDraft?
    @State private var loginService = PiProviderLoginService()
    @State private var isConnectProviderPresented = false

    /// Demo only: forced install states. When set, the Doctor runs the real
    /// `SetupDependencyService` against these (1:1 with reality) and shows the
    /// runtime/Web sections as not-installed.
    private let demoSimulation: SetupSimulation?
    private var isDemo: Bool { demoSimulation != nil }

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
        self.demoSimulation = nil
    }

    #if DEBUG
    /// Preview seam: render the Doctor for a forced simulation (e.g. nothing
    /// installed) using the same checks the real screen runs.
    init(viewModel: AppViewModel, simulation: SetupSimulation) {
        self.viewModel = viewModel
        self.demoSimulation = simulation
    }
    #endif

    private var skipLiveChecksForPreview: Bool { isDemo }

    private var snapshot: ScanSnapshot {
        viewModel.snapshot
    }

    var body: some View {
        AppPage(languageStore.t("doctor.pageTitle"), subtitle: languageStore.t("doctor.pageSubtitle")) {
            piAgentSection
            dependenciesSection
            webAccessSection
            if !snapshot.warnings.isEmpty {
                warningsSection
            }
            foundationModelSection
        }
        .task {
            if let demoSimulation {
                setupItems = await SetupDependencyService().loadItems(
                    projectRootPaths: viewModel.configuredProjectsRootPaths,
                    selectedProjectPath: viewModel.selectedProjectPath,
                    hasConfirmedProjectsRootPaths: viewModel.hasConfirmedProjectsRootPaths,
                    suggestedProjectsRootPath: viewModel.suggestedProjectsRootPath,
                    simulation: demoSimulation
                )
                piRuntimeStatus = demoSimulation.piInstalled == true ? nil : .missing
                webFetchStatus = WebFetchDependencyService.Status(
                    installDirectory: webFetchStatus.installDirectory,
                    installedPackages: [],
                    missingPackages: WebFetchDependencyService.packages
                )
                isRefreshingSetup = false
                return
            }
            if setupItems.isEmpty {
                await refreshSetupChecks()
            }
            refreshWebFetchStatus()
        }
        // Re-check Pi after returning from Terminal so installs/updates appear
        // without a manual refresh. `scenePhase` does not fire on macOS focus
        // changes, so listen to AppKit's activation notification directly.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if skipLiveChecksForPreview { return }
            guard !piInstaller.isRunning else { return }
            refreshWebFetchStatus()
            Task {
                await refreshPiRuntimeStatus()
                await refreshSetupChecks()
            }
        }
        // The launch auto-updater and this screen share the same installer.
        // Refresh an already-open Doctor as soon as that background work ends.
        .onChange(of: piInstaller.phase) { _, phase in
            guard !skipLiveChecksForPreview else { return }
            if case .succeeded = phase {
                Task { await refreshPiRuntimeStatus() }
            }
        }
        .sheet(item: $envDraft) { draft in
            EnvEditorSheet(
                draft: draft,
                onCancel: { envDraft = nil },
                onSave: { drafts in
                    try viewModel.saveEnvDrafts(drafts)
                    envDraft = nil
                    Task { await refreshSetupChecks() }
                }
            )
        }
        .sheet(isPresented: $isConnectProviderPresented) {
            AddProviderFlowSheet(viewModel: viewModel, loginService: loginService)
        }
        .onChange(of: isConnectProviderPresented) { _, presented in
            if !presented, !skipLiveChecksForPreview { Task { await refreshSetupChecks() } }
        }
    }

    @MainActor
    private func refreshPiRuntimeStatus() async {
        guard !isRefreshingPiRuntime else { return }
        isRefreshingPiRuntime = true
        defer { isRefreshingPiRuntime = false }
        piRuntimeStatus = await PiAgentUpdateService().loadStatus()
    }

    // MARK: - Pi Agent

    private var piAgentSection: some View {
        AppCard(title: "Pi Runtime") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 16) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(AppTheme.contentSubtleFill)
                            .stroke(AppTheme.contentStroke, lineWidth: 1)
                        Image("pi")
                            .resizable()
                            .renderingMode(.template)
                            .scaledToFit()
                            .foregroundStyle(AppTheme.piLogo.gradient)
                            .padding(13)
                    }
                    .frame(width: 54, height: 54)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .center, spacing: 8) {
                            Text("Pi")
                                .font(.title3.weight(.semibold))
                                .fontWidth(.expanded)
                            if let version = piRuntimeStatus?.currentVersion, !version.isEmpty {
                                Text(version)
                                    .font(.callout)
                                    .monospacedDigit()
                                    .foregroundStyle(AppTheme.mutedText)
                            }
                        }
                        if let status = piRuntimeStatus {
                            Text(status.detail)
                                .font(.caption)
                                .foregroundStyle(AppTheme.mutedText)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            HStack(spacing: 8) {
                                AppSpinner().controlSize(.small)
                                Text(languageStore.t("doctor.checkingPi")).font(.caption).foregroundStyle(AppTheme.mutedText)
                            }
                        }
                    }

                    Spacer(minLength: 8)
                    AppLabelTag(text: piAgentStatusLabel, color: piAgentStatusColor)
                }

                if let status = piRuntimeStatus {
                    if let path = status.resolvedPath {
                        Text(path)
                            .font(.caption.monospaced())
                            .foregroundStyle(AppTheme.mutedText)
                            .textSelection(.enabled)
                    }
                    if !status.isInstalled {
                        piAutoInstallControls(isUpdate: false)
                    } else {
                        piRuntimeVersionDetails(status)

                        switch status.updateState {
                        case let .some(.updateAvailable(latestVersion)):
                            piAutoInstallControls(isUpdate: true, targetVersion: latestVersion)
                        case let .some(.unableToCheck(reason)):
                            Text(reason)
                                .font(.caption.monospaced())
                                .foregroundStyle(AppTheme.mutedText)
                                .textSelection(.enabled)
                        case .some(.upToDate), .none:
                            EmptyView()
                        }

                        Divider()
                            .padding(.top, 2)
                        piAutoUpdateToggleRow
                    }
                }
            }
            .padding(.vertical, 10)
        }
    }

    private func piRuntimeVersionDetails(_ status: PiAgentRuntimeStatus) -> some View {
        let sourceName = status.installationSource?.displayName ?? "Pi"
        return Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
            GridRow {
                Text(languageStore.t("doctor.installedVia"))
                    .foregroundStyle(AppTheme.mutedText)
                Text(sourceName)
            }
            GridRow {
                Text(languageStore.t("doctor.current"))
                    .foregroundStyle(AppTheme.mutedText)
                Text(status.currentVersion ?? languageStore.t("common.unavailable"))
                    .monospacedDigit()
            }
            GridRow {
                Text(languageStore.t("doctor.latestOfficial"))
                    .foregroundStyle(AppTheme.mutedText)
                Text(status.latestOfficialVersion ?? languageStore.t("common.unavailable"))
                    .monospacedDigit()
            }
            GridRow {
                Text(languageStore.t("doctor.latestVia", sourceName))
                    .foregroundStyle(AppTheme.mutedText)
                Text(status.latestSourceVersion ?? languageStore.t("common.unavailable"))
                    .monospacedDigit()
            }
        }
        .font(.caption)
        .textSelection(.enabled)
    }

    /// Opt-in: when on, the app silently updates Pi to the latest release on
    /// launch (same shared installer and method-aware path as the "Update Pi"
    /// button above, so an in-flight launch update shows through those controls).
    private var piAutoUpdateToggleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(languageStore.t("doctor.autoUpdate"))
                    .font(.callout.weight(.medium))
                Text(languageStore.t("doctor.autoUpdateHelp"))
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Toggle("", isOn: Binding(
                get: { viewModel.appSettings.piAgentAutoUpdateEnabled },
                set: { viewModel.setPiAgentAutoUpdateEnabled($0) }
            ))
            .labelsHidden()
            .appSwitch()
        }
    }

    private func piCommandChip(_ command: String, buttonLabel: String = "Run in Terminal", action: (() -> Void)? = nil) -> some View {
        HStack(spacing: 8) {
            DoctorCopyCommandButton(command: command)

            if let action {
                Button(buttonLabel, action: action)
                    .appPrimaryButton()
            }
        }
    }

    /// One-click in-app Pi install/update with live progress; the copyable
    /// command and the Terminal flow stay available as explicit fallbacks.
    @ViewBuilder
    private func piAutoInstallControls(isUpdate: Bool, targetVersion: String? = nil) -> some View {
        switch piInstaller.phase {
        case .running(let method, let runningIsUpdate):
            HStack(spacing: 8) {
                AppSpinner()
                    .controlSize(.small)
                Text(runningIsUpdate
                    ? "Updating Pi via \(method.displayName)…"
                    : "Installing Pi via \(method.displayName)… this can take a few minutes.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .font(.caption.monospaced())
                    .foregroundStyle(AppTheme.mutedText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(languageStore.t("common.tryAgain")) { runPiAutoTask(isUpdate: isUpdate, targetVersion: targetVersion) }
                        .appPrimaryButton()
                    Button(isUpdate ? "Update in Terminal" : "Install in Terminal") {
                        if isUpdate {
                            viewModel.openPiSelfUpdateInTerminal()
                        } else {
                            viewModel.openPiInstallInTerminal()
                        }
                    }
                    .appSecondaryButton()
                }
            }
        case .idle, .succeeded:
            HStack(spacing: 8) {
                DoctorCopyCommandButton(command: isUpdate ? piUpdateCommandHint : piInstallCommandHint)
                Button(isUpdate ? "Update Pi" : "Install Pi") { runPiAutoTask(isUpdate: isUpdate, targetVersion: targetVersion) }
                    .appPrimaryButton()
            }
        }
    }

    /// The official curl installer is the copyable all-machine fallback; the
    /// in-app action still prefers npm, then pnpm, then Bun when available.
    private var piInstallCommandHint: String {
        "curl -fsSL https://pi.dev/install.sh | sh"
    }

    /// Method-aware hint: a brew-owned pi updates via brew, anything else via
    /// Pi's own updater. Matches what the in-app update actually runs.
    private var piUpdateCommandHint: String {
        guard let path = piRuntimeStatus?.resolvedPath else { return "pi update pi" }
        return PiAutoInstaller.isHomebrewOwned(piPath: path) ? "brew upgrade pi-coding-agent" : "pi update pi"
    }

    private func runPiAutoTask(isUpdate: Bool, targetVersion: String? = nil) {
        if skipLiveChecksForPreview { return }
        Task {
            if isUpdate {
                let previousVersion = piRuntimeStatus?.currentVersion
                if await piInstaller.update(expectedVersion: targetVersion) {
                    await waitForPiRuntimeChange(afterVersion: previousVersion)
                    await refreshSetupChecks()
                    piInstaller.reset()
                }
            } else {
                switch await piInstaller.install() {
                case true?:
                    await waitForPiRuntimeChange(afterVersion: nil)
                    await refreshSetupChecks()
                    piInstaller.reset()
                case false?:
                    break // the card shows the failure detail with retry + Terminal
                case nil:
                    // No npm, pnpm, or Bun: Terminal runs Pi's official curl
                    // installer, which can also set up Node interactively.
                    viewModel.openPiInstallInTerminal()
                }
            }
        }
    }

    /// Some update methods replace a symlink or package directory just after
    /// their command exits. The first immediate `pi --version` can therefore
    /// still see the previous executable. Poll briefly so the Doctor card
    /// settles in place instead of requiring navigation to trigger another
    /// status check.
    @MainActor
    private func waitForPiRuntimeChange(afterVersion previousVersion: String?) async {
        let retryDelays: [Duration] = [.milliseconds(750), .seconds(1), .seconds(2)]
        let updateService = PiAgentUpdateService()
        for delay in retryDelays {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            if await updateService.loadCurrentVersion() != previousVersion {
                return
            }
        }
    }

    private var piAgentIconName: String {
        guard let status = piRuntimeStatus else { return "clock" }
        guard status.isInstalled else { return "xmark.circle.fill" }
        if case .some(.updateAvailable) = status.updateState { return "arrow.up.circle.fill" }
        if case .some(.unableToCheck) = status.updateState { return "exclamationmark.triangle.fill" }
        if status.isOfficialReleaseAheadOfSource { return "clock.fill" }
        return "checkmark.circle.fill"
    }

    private var piAgentStatusColor: Color {
        guard let status = piRuntimeStatus else { return .secondary }
        guard status.isInstalled else { return .red }
        if case .some(.updateAvailable) = status.updateState { return .orange }
        if case .some(.unableToCheck) = status.updateState { return .orange }
        if status.isOfficialReleaseAheadOfSource { return .orange }
        return .green
    }

    private var piAgentStatusLabel: String {
        guard let status = piRuntimeStatus else { return languageStore.t("common.checking") }
        guard status.isInstalled else { return languageStore.t("common.missing") }
        if case .some(.updateAvailable) = status.updateState { return languageStore.t("common.update") }
        if case .some(.unableToCheck) = status.updateState { return languageStore.t("common.checkFailed") }
        if status.isOfficialReleaseAheadOfSource { return languageStore.t("common.waiting") }
        return languageStore.t("common.ready")
    }

    // MARK: - Foundation Model

    private var foundationModelSection: some View {
        let isAvailable = FoundationModelAutomationService.isAvailable()
        return AppCard(title: languageStore.t("doctor.foundationTitle")) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: isAvailable ? "checkmark.circle.fill" : "circle.dashed")
                    .font(.title3)
                    .foregroundStyle(isAvailable ? .green : .secondary)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "apple.logo")
                            .imageScale(.medium)
                        Text(languageStore.t("doctor.foundationModel"))
                            .font(.body.weight(.semibold))
                            .fontWidth(.expanded)
                    }

                    Text(isAvailable ? foundationModelReadyDetail : foundationModelUnavailableDetail)
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)

                    AppKeyValueList(rows: foundationModelRows(isAvailable: isAvailable))
                }

                Spacer(minLength: 8)
                AppLabelTag(text: isAvailable ? languageStore.t("common.ready") : languageStore.t("common.unavailable"), color: isAvailable ? .green : .secondary)
            }
            .padding(.vertical, 12)
        }
    }

    private var foundationModelReadyDetail: String {
        languageStore.t("doctor.foundationReady")
    }

    private var foundationModelUnavailableDetail: String {
        languageStore.t("doctor.foundationUnavailable")
    }

    private func foundationModelRows(isAvailable: Bool) -> [(String, String)] {
        [
            (languageStore.t("common.model"), "apple/foundation"),
            (languageStore.t("common.runtime"), isAvailable ? languageStore.t("doctor.runtimeLocal") : languageStore.t("common.unavailable"))
        ]
    }

    // MARK: - Dependencies

    private var dependenciesSection: some View {
        AppCard(title: languageStore.t("doctor.dependencies"), trailing: {
            Button {
                Task { await refreshSetupChecks() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(isRefreshingSetup)
            .help(languageStore.t("doctor.refreshDeps"))
        }) {
            VStack(alignment: .leading, spacing: 14) {
                Text(languageStore.t("doctor.coreRequirements"))
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)

                if isRefreshingSetup && setupItems.isEmpty {
                    HStack(spacing: 10) {
                        AppSpinner()
                            .controlSize(.small)
                        Text(languageStore.t("doctor.checkingDeps"))
                            .foregroundStyle(AppTheme.mutedText)
                    }
                    .padding(.vertical, 8)
                } else {
                    dependencyGroup(nil, items: coreDependencyItems)
                }
            }
        }
    }

    private var coreDependencyItems: [SetupCheckItem] {
        setupItems.filter { ["pi-cli", "pi-models", "project-root"].contains($0.id) }
    }

    private func dependencyGroup(_ title: String?, items: [SetupCheckItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.mutedText)
                    .padding(.bottom, 4)
            }
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                setupCheckRow(item)
                if index < items.count - 1 {
                    Divider()
                }
            }
        }
    }

    private func setupCheckRow(_ item: SetupCheckItem) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: item.status.systemImage)
                .font(.title3)
                .foregroundStyle(item.status.color)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 7) {
                Text(item.title)
                    .font(.body.weight(.semibold))
                    .fontWidth(.expanded)

                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)

                if let recovery = item.recovery, item.status != .passed {
                    Text(recovery)
                        .font(.caption.monospaced())
                        .foregroundStyle(AppTheme.mutedText)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if item.id == "pi-cli", item.status != .passed {
                    // Same one-click installer as the Pi Runtime card, so the
                    // row shows live progress instead of a dead button.
                    piAutoInstallControls(isUpdate: false)
                } else if item.status != .passed, item.action != nil || item.secondaryAction != nil {
                    HStack(spacing: 8) {
                        if let action = item.action {
                            Button(action.buttonTitle) { performSetupAction(action) }
                                .appPrimaryButton()
                        }
                        if let secondaryAction = item.secondaryAction {
                            Button(secondaryAction.buttonTitle) { performSetupAction(secondaryAction) }
                                .appSecondaryButton()
                        }
                    }
                }
            }

            Spacer(minLength: 8)

            AppLabelTag(text: item.status.label, color: item.status.color)
        }
        .padding(.vertical, 12)
    }

    private func performSetupAction(_ action: SetupCheckAction) {
        let replacing = !viewModel.hasConfirmedProjectsRootPaths
        switch action {
        case .chooseProjectRoot:
            viewModel.chooseProjectsRootDirectory(replacingExisting: replacing)
            Task { await refreshSetupChecks() }
        case .useSuggestedProjectRoot:
            viewModel.useSuggestedProjectsRootDirectory(replacingExisting: replacing)
            Task { await refreshSetupChecks() }
        case .installPi:
            runPiAutoTask(isUpdate: false)
        case .connectProvider:
            isConnectProviderPresented = true // re-checks on sheet dismiss
        }
    }

    @MainActor
    private func refreshSetupChecks() async {
        isRefreshingSetup = true
        defer { isRefreshingSetup = false }
        async let setup = SetupDependencyService().loadItems(
            projectRootPaths: viewModel.configuredProjectsRootPaths,
            selectedProjectPath: viewModel.selectedProjectPath,
            hasConfirmedProjectsRootPaths: viewModel.hasConfirmedProjectsRootPaths,
            suggestedProjectsRootPath: viewModel.suggestedProjectsRootPath
        )
        async let piRuntime = PiAgentUpdateService().loadStatus()
        setupItems = await setup
        piRuntimeStatus = await piRuntime
    }

    // MARK: - Web Access

    private var webAccessSection: some View {
        AppCard(title: languageStore.t("doctor.webAccess")) {
            VStack(alignment: .leading, spacing: 0) {
                webAccessOptionRow(
                    icon: hasWebSearchCredential ? "checkmark.circle.fill" : "circle.dashed",
                    iconColor: hasWebSearchCredential ? .green : .secondary,
                    title: languageStore.t("doctor.webSearchTitle"),
                    detail: hasWebSearchCredential
                        ? languageStore.t("doctor.webSearchReady")
                        : languageStore.t("doctor.webSearchOptional"),
                    tag: hasWebSearchCredential ? languageStore.t("common.ready") : languageStore.t("common.optional"),
                    tagColor: hasWebSearchCredential ? .green : .secondary
                )

                Divider()

                webFetchFallbackRow
            }
        }
    }

    private func webAccessOptionRow(icon: String, iconColor: Color, title: String, detail: String, tag: String, tagColor: Color) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(iconColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .fontWidth(.expanded)
                    if title == languageStore.t("doctor.webSearchTitle"), let infoURL = URL(string: "https://dashboard.exa.ai/api-keys") {
                        Button {
                            NSWorkspace.shared.open(infoURL)
                        } label: {
                            Image(systemName: "info.circle")
                                .font(.system(size: 13))
                        }
                        .buttonStyle(.borderless)
                        .help(languageStore.t("doctor.webSearchHelp"))
                    }
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)

                if title == languageStore.t("doctor.webSearchTitle"), !hasWebSearchCredential {
                    Button(languageStore.t("doctor.addExaKey")) {
                        envDraft = viewModel.makeNewEnvDraft(prefilledKey: "EXA_API_KEY")
                    }
                    .appPrimaryButton()
                }
            }

            Spacer(minLength: 8)
            AppLabelTag(text: tag, color: tagColor)
        }
        .padding(.vertical, 12)
    }

    private var webFetchFallbackRow: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: webFetchStatus.isInstalled ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                .font(.title3)
                .foregroundStyle(webFetchStatus.isInstalled ? .green : .orange)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 8) {
                Text(languageStore.t("doctor.urlFetchFallback"))
                    .font(.body.weight(.semibold))
                    .fontWidth(.expanded)

                Text(webFetchStatus.isInstalled
                     ? languageStore.t("doctor.urlFetchInstalled")
                     : languageStore.t("doctor.urlFetchOptional"))
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)

                AppKeyValueList(rows: webFetchFallbackRows)

                HStack(spacing: 8) {
                    Button {
                        Task { await installWebFetchDependencies() }
                    } label: {
                        if isInstallingWebFetchDependencies {
                            AppSpinner()
                                .controlSize(.small)
                        } else {
                            Text(webFetchStatus.isInstalled ? languageStore.t("doctor.reinstallDeps") : languageStore.t("doctor.installDeps"))
                        }
                    }
                    .appPrimaryButton()
                    .disabled(isInstallingWebFetchDependencies)
                }

                if let webFetchInstallMessage {
                    Text(webFetchInstallMessage)
                        .font(.caption.monospaced())
                        .foregroundStyle(AppTheme.mutedText)
                        .textSelection(.enabled)
                }
            }

            Spacer(minLength: 8)
            AppLabelTag(text: webFetchStatus.isInstalled ? languageStore.t("common.ready") : languageStore.t("common.optional"), color: webFetchStatus.isInstalled ? .green : .orange)
        }
        .padding(.vertical, 12)
    }

    private var webFetchFallbackRows: [(String, String)] {
        var rows = [
            (languageStore.t("common.status"), webFetchStatus.isInstalled ? languageStore.t("common.installed") : languageStore.t("doctor.depsMissing")),
            (languageStore.t("common.packages"), WebFetchDependencyService.packages.joined(separator: ", ")),
            (languageStore.t("doctor.installPath"), webFetchStatus.installDirectory.path)
        ]
        if !webFetchStatus.missingPackages.isEmpty {
            rows.insert((languageStore.t("common.missing"), webFetchStatus.missingPackages.joined(separator: ", ")), at: 1)
        }
        return rows
    }

    private func refreshWebFetchStatus() {
        webFetchStatus = WebFetchDependencyService().status()
    }

    private func installWebFetchDependencies() async {
        isInstallingWebFetchDependencies = true
        webFetchInstallMessage = languageStore.t("doctor.installingWebFetch")
        defer {
            isInstallingWebFetchDependencies = false
            refreshWebFetchStatus()
        }
        do {
            let result = try await WebFetchDependencyService().install()
            if result.exitCode == 0 {
                webFetchInstallMessage = "Installed web_fetch dependencies."
            } else {
                webFetchInstallMessage = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "npm install exited with code \(result.exitCode)." : result.stderr
            }
        } catch {
            webFetchInstallMessage = error.localizedDescription
        }
    }

    private var hasWebSearchCredential: Bool {
        if skipLiveChecksForPreview { return false }
        let envMap = Dictionary(uniqueKeysWithValues: snapshot.envKeys.compactMap { item -> (String, String)? in
            guard let value = item.value else { return nil }
            return (item.key, value)
        })
        return PiNativeSubagentBridgeExtensions.isWebSearchConfigured(environment: envMap)
    }

    // MARK: - Settings

    private var settingsSection: some View {
        AppCard(title: "Settings Files") {
            if snapshot.settings.isEmpty {
                Text(languageStore.t("doctor.noSettings"))
                    .foregroundStyle(AppTheme.mutedText)
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(snapshot.settings.enumerated()), id: \.element.path) { index, settings in
                        settingsDetail(settings)
                        if index < snapshot.settings.count - 1 {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private func settingsDetail(_ settings: SettingsSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(settings.path)
                    .font(.body.weight(.semibold))
                    .fontWidth(.expanded)
                    .textSelection(.enabled)
                Spacer()
                Button(languageStore.t("common.open")) { openFile(settings.path) }
                    .appSmallSecondaryButton()
                Button(languageStore.t("common.reveal")) { revealInFinder(settings.path) }
                    .appSmallSecondaryButton()
            }

            AppKeyValueList(rows: [
                ("Disable Builtins", boolLabel(settings.disableBuiltins)),
                ("Builtin Agent Overrides", "\(settings.agentOverrides.count)"),
                ("Extra Prompt Template Paths", "\(settings.prompts.count)"),
                ("Packages", "\(settings.packages.count)")
            ])

            if !settings.packages.isEmpty {
                packageListDetail(settings.packages)
            }

            if !settings.agentOverrides.isEmpty {
                overridesDetail(settings.agentOverrides)
            }
        }
    }

    private func packageListDetail(_ packages: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(languageStore.t("doctor.packages"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.mutedText)
            ForEach(packages, id: \.self) { pkg in
                HStack(spacing: 8) {
                    Image(systemName: "shippingbox")
                        .foregroundStyle(.orange)
                        .frame(width: 16)
                    Text(pkg)
                        .font(.footnote)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private struct RenderedOverride: Identifiable {
        let agentName: String
        let formatted: String
        var id: String { agentName }
    }

    private func overridesDetail(_ overrides: [BuiltinOverrideRecord]) -> some View {
        // Precompute the pretty-printed value once per override so we don't
        // JSON-serialize per body eval inside the ForEach row builder.
        let rendered = overrides.map { RenderedOverride(agentName: $0.agentName, formatted: prettyJSON($0.values)) }
        return VStack(alignment: .leading, spacing: 6) {
            Text(languageStore.t("doctor.builtinOverrides"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.mutedText)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rendered.enumerated()), id: \.element.id) { index, entry in
                    HStack(alignment: .top, spacing: 10) {
                        Text(entry.agentName)
                            .font(.footnote.weight(.semibold))
                            .frame(minWidth: 100, alignment: .trailing)
                        Text(entry.formatted)
                            .font(.footnote.monospaced())
                            .foregroundStyle(AppTheme.mutedText)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 6)
                    if index < rendered.count - 1 { Divider() }
                }
            }
        }
    }

    // MARK: - Warnings

    private var warningsSection: some View {
        AppCard(title: "Warnings") {
            if snapshot.warnings.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(languageStore.t("doctor.allPassed"))
                        .font(AppTheme.Font.primary)
                        .foregroundStyle(AppTheme.mutedText)
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(snapshot.warnings.prefix(20).enumerated()), id: \.element.id) { index, warning in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .frame(width: 20)
                            Text(warning.message)
                                .font(AppTheme.Font.primary)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 8)
                        if index < min(snapshot.warnings.count, 20) - 1 { Divider() }
                    }
                }
            }
        }
    }

}

@ViewBuilder
private func warningSection(title: String, warnings: [DiagnosticWarning]) -> some View {
    if !warnings.isEmpty {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(AppTheme.Font.sectionTitle)
                .fontWidth(.expanded)
            ForEach(warnings) { warning in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(warning.message)
                        .font(AppTheme.Font.primary)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

private struct DoctorCopyCommandButton: View {
    let command: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            showCopiedFeedback()
        } label: {
            HStack(spacing: 0) {
                Text(command)
                    .font(.footnote.monospaced())
                    .padding(.leading, 12)
                    .padding(.trailing, 10)

                Divider()
                    .frame(height: 18)

                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption.weight(.semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 38)
                    .accessibilityLabel(copied ? "Copied" : "Copy command")
            }
            .frame(height: 32)
            .foregroundStyle(.primary)
            .glassEffect(.regular, in: Capsule(style: .continuous))
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .help(copied ? "Copied" : "Copy command")
    }

    private func showCopiedFeedback() {
        copied = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1100))
            copied = false
        }
    }
}

func prettyJSONObject(_ object: [String: Any]) -> String {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
          let text = String(data: data, encoding: .utf8) else {
        return object.map { "\($0.key): \(String(describing: $0.value))" }.sorted().joined(separator: "\n")
    }
    return text
}

/// Pretty-prints typed JSONValue overrides for the doctor view. Bridges the
/// `[String: JSONValue]` shape (introduced when BuiltinOverrideRecord moved
/// off `[String: Any]`) into a JSONSerialization-friendly form once.
func prettyJSON(_ values: [String: JSONValue]) -> String {
    let foundation = values.mapValues { $0.foundationValue }
    return prettyJSONObject(foundation)
}

private extension JSONValue {
    /// Converts to the Foundation tree (`String`/`NSNumber`/`Bool`/`NSNull`/
    /// `[Any]`/`[String: Any]`) that `JSONSerialization` accepts.
    var foundationValue: Any {
        switch self {
        case .null: return NSNull()
        case let .bool(value): return value
        case let .number(value): return value
        case let .string(value): return value
        case let .array(values): return values.map(\.foundationValue)
        case let .object(values): return values.mapValues(\.foundationValue)
        }
    }
}

private func boolLabel(_ value: Bool?) -> String {
    guard let value else { return "—" }
    return value ? "true" : "false"
}

private func resolutionUsageLabel(_ agent: EffectiveAgentRecord) -> String {
    let scope: String
    if let projectRoot = agent.projectRoot,
       (agent.projectCustom != nil || agent.projectOverride != nil) {
        scope = "Project · \(URL(fileURLWithPath: projectRoot).lastPathComponent)"
    } else if agent.globalCustom != nil {
        scope = "Global"
    } else {
        scope = agent.resolutionKind.rawValue
    }
    return "\(scope) · \(agent.resolutionKind.rawValue)"
}

private func openFile(_ path: String) {
    NSWorkspace.shared.open(URL(fileURLWithPath: path))
}

private func revealInFinder(_ path: String) {
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
}

private func projectName(from path: String) -> String? {
    let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
    if let piIndex = components.lastIndex(of: ".pi"), piIndex > 0 {
        return components[piIndex - 1]
    }
    if let agentsIndex = components.lastIndex(of: ".agents"), agentsIndex > 0 {
        return components[agentsIndex - 1]
    }
    return nil
}

func skillScopeLabel(_ skill: SkillRecord, selectedProjectRoot: String?) -> String {
    switch skill.source.kind {
    case .builtin:
        return "Bundled"
    case .project, .legacyProject:
        return "Project"
    case .package:
        return "Package"
    case .library:
        return "External"
    default:
        return "Global"
    }
}

private func skillProjectLabel(_ skill: SkillRecord, selectedProjectRoot: String?) -> String? {
    switch skill.source.kind {
    case .project, .legacyProject:
        return projectName(from: skill.filePath) ?? selectedProjectRoot.map { URL(fileURLWithPath: $0).lastPathComponent }
    default:
        return nil
    }
}

private func skillPackageLabel(_ skill: SkillRecord) -> String? {
    guard skill.source.kind == .package else { return nil }

    let path = skill.filePath
    if let range = path.range(of: "/node_modules/") {
        let remainder = path[range.upperBound...]
        let components = remainder.split(separator: "/")
        guard let first = components.first else { return nil }
        if first.hasPrefix("@"), components.count > 1 {
            return "\(first)/\(components[1])"
        }
        return String(first)
    }

    return URL(fileURLWithPath: path).deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
}

func skillLocationLabel(_ skill: SkillRecord, selectedProjectRoot: String?) -> String {
    if let project = skillProjectLabel(skill, selectedProjectRoot: selectedProjectRoot) {
        return project
    }
    if let package = skillPackageLabel(skill) {
        return package
    }
    if skill.source.kind == .builtin {
        return "Bundled"
    }
    if skill.source.kind == .library {
        return "External"
    }
    return "User"
}
