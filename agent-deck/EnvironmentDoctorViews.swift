import AppKit
import SwiftUI

struct EnvironmentInfoPopover: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Resolution order")
                .font(.headline)
                .fontWidth(.expanded)

            VStack(alignment: .leading, spacing: 10) {
                infoRow("1. App launch environment", "Variables already present when Agent Deck launches are available first.")
                infoRow("2. Global", "Agent Deck reads global keys from `~/.pi/agent/.env`.")
                infoRow("3. Project", "When a project is selected, `.pi/.env` overrides matching global keys.")
                infoRow("4. Runtime", "Agent Deck appends its own runtime variables last when starting new Pi sessions.")
            }

            Text("Existing sessions keep the environment they started with. Start a new session to use saved changes.")
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
    @State private var revealedKeys: Set<String> = []
    @State private var pendingDelete: EnvKeyRecord?

    var body: some View {
        AppPage("Environment", subtitle: "Manage the keys Agent Deck injects into new Pi sessions") {
            AppCard(title: "Environment Keys") {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(snapshot.projectRoot == nil
                             ? "Showing discovered global keys. Select a project to see project overrides."
                             : "Showing the effective environment for the selected project. Project keys override global keys.")
                            .font(.caption)
                            .foregroundStyle(AppTheme.mutedText)
                            .fixedSize(horizontal: false, vertical: true)

                        Text("Values stay hidden until revealed. Editing a key writes back to its source `.env` file; new Pi sessions pick up changes automatically.")
                            .font(.caption)
                            .foregroundStyle(AppTheme.mutedText)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if effectiveEnvRows.isEmpty {
                        emptyEnvironmentState
                    } else {
                        VStack(spacing: 10) {
                            ForEach(effectiveEnvRows, id: \.key) { row in
                                environmentKeyRow(row)
                            }
                        }
                    }
                }
            }
        }
        .confirmationDialog(
            "Delete environment key?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { record in
            Button("Delete \(record.key)", role: .destructive) {
                onDeleteKey(record)
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDelete = nil
            }
        } message: { record in
            Text("This removes \(record.key) from \(record.source.path).")
        }
    }

    private var emptyEnvironmentState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("No environment keys yet", systemImage: "key")
                .font(.body.weight(.semibold))
            Text("Use the toolbar’s New Key button to add credentials like EXA_API_KEY. Agent Deck stores them in the same `.env` files it reads at runtime.")
                .font(.caption)
                .foregroundStyle(AppTheme.mutedText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(AppTheme.contentSubtleFill))
    }

    private func environmentKeyRow(_ row: EffectiveEnvRow) -> some View {
        AppRowCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "key.fill")
                        .foregroundStyle(.orange)
                        .frame(width: 22)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(row.key)
                                .font(.body.monospaced().weight(.semibold))
                                .textSelection(.enabled)
                            if !row.overriddenRecords.isEmpty {
                                AppLabelTag(text: "Overrides \(row.overriddenRecords.count)", color: .red)
                            }
                        }
                        Text(row.winningSource.path)
                            .font(.caption)
                            .foregroundStyle(AppTheme.mutedText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }

                    Spacer(minLength: 12)
                    AppLabelTag(text: row.winningSource.kind.rawValue, color: row.winningSource.kind == .project ? .green : .orange)
                }

                HStack(spacing: 8) {
                    Text(revealedKeys.contains(row.key) ? (row.winningRecord.value ?? "") : maskedValue(row.winningRecord.value))
                        .font(.footnote.monospaced())
                        .foregroundStyle(revealedKeys.contains(row.key) ? .primary : AppTheme.mutedText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .appGlassCapsule()

                    Button {
                        toggleReveal(for: row.key)
                    } label: {
                        Label(revealedKeys.contains(row.key) ? "Hide" : "Reveal", systemImage: revealedKeys.contains(row.key) ? "eye.slash" : "eye")
                    }
                    .labelStyle(.iconOnly)
                    .help(revealedKeys.contains(row.key) ? "Hide value" : "Reveal value")

                    Button("Edit") { onEditKey(row.winningRecord) }
                    Button("Delete", role: .destructive) {
                        pendingDelete = row.winningRecord
                    }
                }

                if !row.overriddenRecords.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(row.overriddenRecords, id: \.id) { record in
                            Text("Overrides \(record.source.path)")
                                .font(.caption)
                                .foregroundStyle(AppTheme.mutedText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .padding(.leading, 34)
                }
            }
        }
    }


    private var effectiveEnvRows: [EffectiveEnvRow] {
        var grouped: [String: [EnvKeyRecord]] = [:]
        for record in snapshot.envKeys {
            grouped[record.key, default: []].append(record)
        }

        return grouped.keys.sorted().compactMap { key in
            guard let records = grouped[key], let winning = records.sorted(by: envPrecedence).first else { return nil }
            let overridden = records.filter { $0.id != winning.id }
            let summary: String
            if overridden.isEmpty {
                summary = winning.source.path
            } else {
                summary = "Using \(winning.source.path) over \(overridden.map { $0.source.path }.joined(separator: ", "))"
            }
            return EffectiveEnvRow(key: key, winningRecord: winning, winningSource: winning.source, overriddenRecords: overridden, summary: summary)
        }
    }


    private func envPrecedence(_ lhs: EnvKeyRecord, _ rhs: EnvKeyRecord) -> Bool {
        envRank(lhs.source.kind) > envRank(rhs.source.kind)
    }

    private func envRank(_ kind: ResourceScopeKind) -> Int {
        switch kind {
        case .project, .legacyProject:
            return 2
        default:
            return 1
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

struct EffectiveEnvRow {
    let key: String
    let winningRecord: EnvKeyRecord
    let winningSource: ScopeID
    let overriddenRecords: [EnvKeyRecord]
    let summary: String
}

struct DoctorScreen: View {
    var viewModel: AppViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var setupItems: [SetupCheckItem] = []
    @State private var piRuntimeStatus: PiAgentRuntimeStatus?
    @State private var isRefreshingSetup = true
    @State private var webFetchStatus = WebFetchDependencyService().status()
    @State private var isInstallingWebFetchDependencies = false
    @State private var webFetchInstallMessage: String?
    @State private var isRefreshingPiRuntime = false
    @State private var envDraft: EnvEditorDraft?

    private var snapshot: ScanSnapshot {
        viewModel.snapshot
    }

    var body: some View {
        AppPage("Doctor", subtitle: "Runtime health, dependencies, and actionable warnings") {
            piAgentSection
            dependenciesSection
            githubAccessSection
            webAccessSection
            if !snapshot.warnings.isEmpty {
                warningsSection
            }
            foundationModelSection
        }
        .task {
            if setupItems.isEmpty {
                await refreshSetupChecks()
            }
            refreshWebFetchStatus()
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Re-check the Pi version when the app regains focus so that an
            // in-terminal `pi update pi` is reflected without a manual refresh click.
            // We only re-run the cheap Pi status fetch here; the broader Setup Checks
            // still belong to the explicit refresh button to avoid spawning subprocesses
            // on every focus change.
            guard newPhase == .active else { return }
            refreshWebFetchStatus()
            Task { await refreshPiRuntimeStatus() }
        }
        .sheet(item: $envDraft) { draft in
            EnvEditorSheet(
                draft: draft,
                projectRoot: viewModel.selectedProjectPath,
                onCancel: { envDraft = nil },
                onSave: { drafts in
                    try viewModel.saveEnvDrafts(drafts)
                    envDraft = nil
                    Task { await refreshSetupChecks() }
                }
            )
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
                            AppLabelTag(text: piAgentStatusLabel, color: piAgentStatusColor)
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
                                Text("Checking Pi…").font(.caption).foregroundStyle(AppTheme.mutedText)
                            }
                        }
                    }

                    Spacer(minLength: 8)
                }

                if let status = piRuntimeStatus {
                    if !status.isInstalled {
                        piCommandChip("npm install -g @earendil-works/pi-coding-agent", buttonLabel: "Install in Terminal") { viewModel.openPiInstallInTerminal() }
                    } else {
                        switch status.updateState {
                        case .some(.updateAvailable):
                            piCommandChip("pi update pi", buttonLabel: "Update in Terminal") { viewModel.openPiSelfUpdateInTerminal() }
                        case let .some(.unableToCheck(reason)):
                            Text(reason)
                                .font(.caption.monospaced())
                                .foregroundStyle(AppTheme.mutedText)
                                .textSelection(.enabled)
                        case .some(.upToDate), .none:
                            EmptyView()
                        }
                    }
                }
            }
            .padding(.vertical, 10)
        }
    }

    private func piCommandChip(_ command: String, buttonLabel: String = "Run in Terminal", action: (() -> Void)? = nil) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Text(command)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Copy command")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .appGlassCapsule()

            if let action {
                Button(buttonLabel, action: action)
                    .appPrimaryButton()
            }
        }
    }

    private var piAgentIconName: String {
        guard let status = piRuntimeStatus else { return "clock" }
        guard status.isInstalled else { return "xmark.circle.fill" }
        if case .some(.updateAvailable) = status.updateState { return "arrow.up.circle.fill" }
        if case .some(.unableToCheck) = status.updateState { return "exclamationmark.triangle.fill" }
        return "checkmark.circle.fill"
    }

    private var piAgentStatusColor: Color {
        guard let status = piRuntimeStatus else { return .secondary }
        guard status.isInstalled else { return .red }
        if case .some(.updateAvailable) = status.updateState { return .orange }
        if case .some(.unableToCheck) = status.updateState { return .orange }
        return .green
    }

    private var piAgentStatusLabel: String {
        guard let status = piRuntimeStatus else { return "Checking" }
        guard status.isInstalled else { return "Missing" }
        if case .some(.updateAvailable) = status.updateState { return "Update" }
        if case .some(.unableToCheck) = status.updateState { return "Check Failed" }
        return "Ready"
    }

    // MARK: - Foundation Model

    private var foundationModelSection: some View {
        let isAvailable = FoundationModelAutomationService.isAvailable()
        return AppCard(title: "Apple Foundation Model") {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: isAvailable ? "checkmark.circle.fill" : "circle.dashed")
                    .font(.title3)
                    .foregroundStyle(isAvailable ? .green : .secondary)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "apple.logo")
                            .imageScale(.medium)
                        Text("Foundation Model")
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
                AppLabelTag(text: isAvailable ? "Ready" : "Unavailable", color: isAvailable ? .green : .secondary)
            }
            .padding(.vertical, 12)
        }
    }

    private var foundationModelReadyDetail: String {
        "Available for local automation tasks. Session titles and commit messages can use Apple Foundation Model in Settings → Automations without starting a hidden Pi helper or using paid API tokens."
    }

    private var foundationModelUnavailableDetail: String {
        "Not currently available to Agent Deck. Apple Foundation Model require Apple Intelligence to be available and enabled on this Mac. Pi chat models are unaffected."
    }

    private func foundationModelRows(isAvailable: Bool) -> [(String, String)] {
        [
            ("Model", "apple/foundation"),
            ("Runtime", isAvailable ? "Local on-device" : "Unavailable")
        ]
    }

    // MARK: - Dependencies

    private var dependenciesSection: some View {
        AppCard(title: "Dependencies", trailing: {
            Button {
                Task { await refreshSetupChecks() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(isRefreshingSetup)
            .help("Refresh dependencies")
        }) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Core requirements for running local Pi workflows.")
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)

                if isRefreshingSetup && setupItems.isEmpty {
                    HStack(spacing: 10) {
                        AppSpinner()
                            .controlSize(.small)
                        Text("Checking dependencies...")
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
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .appGlassCapsule()
                }

                if item.status != .passed, item.action != nil || item.secondaryAction != nil {
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
                    .controlSize(.small)
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
        case .useSuggestedProjectRoot:
            viewModel.useSuggestedProjectsRootDirectory(replacingExisting: replacing)
        }
        Task { await refreshSetupChecks() }
    }

    @MainActor
    private func refreshSetupChecks() async {
        isRefreshingSetup = true
        defer { isRefreshingSetup = false }
        async let setup = SetupDependencyService().loadItems(
            projectRootPaths: viewModel.configuredProjectsRootPaths,
            githubAccount: viewModel.currentGitHubAccount,
            selectedProjectPath: viewModel.selectedProjectPath,
            hasConfirmedProjectsRootPaths: viewModel.hasConfirmedProjectsRootPaths,
            suggestedProjectsRootPath: viewModel.suggestedProjectsRootPath
        )
        async let piRuntime = PiAgentUpdateService().loadStatus()
        setupItems = await setup
        piRuntimeStatus = await piRuntime
    }

    // MARK: - GitHub Access

    private var githubAccessSection: some View {
        AppCard(title: "GitHub") {
            HStack(alignment: .top, spacing: 14) {
                Image("github")
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .foregroundStyle(viewModel.currentGitHubAccount == nil ? AppTheme.mutedText : .green)
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 8) {
                    Text("GitHub CLI")
                        .font(.body.weight(.semibold))
                        .fontWidth(.expanded)

                    Text(githubAccessDetail)
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)

                    if viewModel.currentGitHubAccount == nil {
                        Button("Connect GitHub") {
                            viewModel.connectGitHubUsingCLI()
                        }
                        .appPrimaryButton()
                        .controlSize(.small)
                    }
                }

                Spacer(minLength: 8)
                AppLabelTag(
                    text: viewModel.currentGitHubAccount == nil ? "Optional" : "Ready",
                    color: viewModel.currentGitHubAccount == nil ? .secondary : .green
                )
            }
            .padding(.vertical, 12)
        }
    }

    private var githubAccessDetail: String {
        if let account = viewModel.currentGitHubAccount {
            return "Connected as \(account.login) on \(account.host). Enables issue, comment, commit, and push workflows."
        }
        return "Optional. Connect GitHub CLI to enable issue, comment, commit, and push workflows."
    }

    // MARK: - Web Access

    private var webAccessSection: some View {
        AppCard(title: "Web Access") {
            VStack(alignment: .leading, spacing: 0) {
                webAccessOptionRow(
                    icon: hasExaAPIKey ? "checkmark.circle.fill" : "circle.dashed",
                    iconColor: hasExaAPIKey ? .green : .secondary,
                    title: "Exa Search",
                    detail: hasExaAPIKey
                        ? "EXA_API_KEY is configured. Exa web_search, fetch_content, and get_search_content are available to new Pi sessions."
                        : "Optional. Add EXA_API_KEY to enable Exa web_search, fetch_content, and get_search_content.",
                    tag: hasExaAPIKey ? "Ready" : "Optional",
                    tagColor: hasExaAPIKey ? .green : .secondary
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
                    if title == "Exa Search", let infoURL = URL(string: "https://dashboard.exa.ai/api-keys") {
                        Button {
                            NSWorkspace.shared.open(infoURL)
                        } label: {
                            Image(systemName: "info.circle")
                                .font(.system(size: 13))
                        }
                        .buttonStyle(.borderless)
                        .help("Get an Exa API key")
                    }
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)

                if title == "Exa Search", !hasExaAPIKey {
                    Button("Add EXA_API_KEY…") {
                        envDraft = viewModel.makeNewEnvDraft(scope: .global, prefilledKey: "EXA_API_KEY")
                    }
                    .appPrimaryButton()
                    .controlSize(.small)
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
                Text("URL Fetch Fallback")
                    .font(.body.weight(.semibold))
                    .fontWidth(.expanded)

                Text(webFetchStatus.isInstalled
                     ? "Installed. Used as a fallback for known URLs when Exa is not configured or direct URL fetching is enough."
                     : "Optional fallback for fetching known URLs without Exa search. Installs htmlparser2 and turndown locally for Agent Deck.")
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
                            Text(webFetchStatus.isInstalled ? "Reinstall Dependencies" : "Install Dependencies")
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
            AppLabelTag(text: webFetchStatus.isInstalled ? "Ready" : "Optional", color: webFetchStatus.isInstalled ? .green : .orange)
        }
        .padding(.vertical, 12)
    }

    private var webFetchFallbackRows: [(String, String)] {
        var rows = [
            ("Status", webFetchStatus.isInstalled ? "Installed" : "Dependencies missing"),
            ("Packages", WebFetchDependencyService.packages.joined(separator: ", ")),
            ("Install Path", webFetchStatus.installDirectory.path)
        ]
        if !webFetchStatus.missingPackages.isEmpty {
            rows.insert(("Missing", webFetchStatus.missingPackages.joined(separator: ", ")), at: 1)
        }
        return rows
    }

    private func refreshWebFetchStatus() {
        webFetchStatus = WebFetchDependencyService().status()
    }

    private func installWebFetchDependencies() async {
        isInstallingWebFetchDependencies = true
        webFetchInstallMessage = "Installing latest htmlparser2 and turndown with npm..."
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

    private var hasExaAPIKey: Bool {
        snapshot.envKeys.contains {
            $0.key == "EXA_API_KEY" && ($0.value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        }
    }

    // MARK: - Settings

    private var settingsSection: some View {
        AppCard(title: "Settings Files") {
            if snapshot.settings.isEmpty {
                Text("No settings files found.")
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
                Button("Open") { openFile(settings.path) }
                    .appSmallSecondaryButton()
                Button("Reveal") { revealInFinder(settings.path) }
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
            Text("Packages")
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
            Text("Builtin Overrides")
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
                    Text("All checks passed.")
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
                                .font(.body)
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
                .font(.headline)
                .fontWidth(.expanded)
            ForEach(warnings) { warning in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(warning.message)
                        .textSelection(.enabled)
                }
            }
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
