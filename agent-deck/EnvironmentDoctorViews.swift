import AppKit
import SwiftUI

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

            AppCard(title: "Resolution Order") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("1. App launch environment")
                    Text("2. Global `~/.pi/agent/.env`")
                    Text("3. Selected project `.pi/.env`")
                    Text("4. Agent Deck runtime variables")
                    Text("Existing sessions keep the environment they started with. Start a new session to use saved changes.")
                        .foregroundStyle(AppTheme.mutedText)
                        .padding(.top, 4)
                }
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
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
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(AppTheme.contentSubtleFill))

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

struct PiDocsScreen: View {
    enum DocsTab: String, CaseIterable, Identifiable {
        case core = "Core System"
        case skills = "Skills"
        case prompts = "Prompts & Commands"
        case agents = "Agents"
        case architecture = "Architecture"

        var id: String { rawValue }
    }

    @State private var selectedTab: DocsTab = .core

    var body: some View {
        AppPage("Docs", subtitle: "Concise reference from pi-documentation/") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(DocsTab.allCases) { tab in
                        Button {
                            selectedTab = tab
                        } label: {
                            Text(tab.rawValue)
                                .font(.subheadline.weight(.semibold))
                                .fontWidth(.expanded)
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(selectedTab == tab ? AppTheme.selectionFill : AppTheme.contentSubtleFill)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }

            switch selectedTab {
            case .core: coreTab
            case .skills: skillsTab
            case .prompts: promptsTab
            case .agents: agentsTab
            case .architecture: architectureTab
            }
        }
    }

    // MARK: - Core System

    private var coreTab: some View {
        VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
            AppCard(title: "How Pi Works") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Pi is the parent session. A subagent is a child Pi process with a narrower job. Children inherit tools, skills, and extensions from the parent unless explicitly restricted.")
                    Text("Settings are layered: project `.pi/settings.json` overrides user `~/.pi/agent/settings.json`. Agent files follow the same precedence: project `.pi/agents/` > global `~/.pi/agent/agents/` > builtins.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            AppCard(title: "Key File Locations") {
                VStack(alignment: .leading, spacing: 12) {
                    docKeyValueRows([
                        ("User settings", "~/.pi/agent/settings.json"),
                        ("Project settings", ".pi/settings.json"),
                        ("User agents", "~/.pi/agent/agents/*.md"),
                        ("Project agents", ".pi/agents/*.md"),
                        ("Bundled agents", "App bundle bundled-agents/*.md"),
                        ("User skills", "~/.pi/agent/skills/"),
                        ("Project skills", ".pi/skills/"),
                        ("User prompts", "~/.pi/agent/prompts/*.md"),
                        ("Project prompts", ".pi/prompts/*.md"),
                        ("User env", "~/.pi/agent/.env"),
                        ("Project env", ".pi/.env")
                    ])
                }
            }

            AppCard(title: "Agent Resolution") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("1. Bundled agents are discovered from \(AppBrand.displayName)'s app resources.")
                    Text("2. Global custom agents in `~/.pi/agent/agents/` or `~/.agents/` override builtins by name.")
                    Text("3. Project agents in `.pi/agents/` override both global and builtin.")
                    Text("4. Settings overrides (`subagents.agentOverrides`) patch any agent's fields without creating a file.")
                    Text("5. `disableBuiltins: true` removes all builtins; individual agents can be disabled via overrides.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            AppCard(title: "Subagent Context") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("• Fresh runs: child starts blank, gets only its own system prompt, skills, project context files, and task.")
                    Text("• Continuations: direct follow-ups can explicitly resume a prior child session by Subagent ID and update the same card.")
                    Text("• Parent conversation history is not forked into native subagents.")
                    Text("• Recursion guard: max nesting depth (default 2) enforced via `PI_SUBAGENT_DEPTH` environment variable.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Skills

    private var skillsTab: some View {
        VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
            AppCard(title: "Skill Discovery") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Pi loads skills from five source categories: global locations, project locations, installed packages, settings-defined paths, and CLI-provided paths.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            AppCard(title: "Discovery Locations") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Global").font(.headline).fontWidth(.expanded)
                    docKeyValueRows([
                        ("Primary", "~/.pi/agent/skills/ — root *.md or */SKILL.md"),
                        ("Legacy", "~/.agents/skills/ — recursive */SKILL.md only")
                    ])
                    Text("Project").font(.headline).fontWidth(.expanded).padding(.top, 6)
                    docKeyValueRows([
                        ("Primary", ".pi/skills/ — root *.md or */SKILL.md"),
                        ("Legacy", ".agents/skills/ — recursive, walks up to git root")
                    ])
                    Text("Package").font(.headline).fontWidth(.expanded).padding(.top, 6)
                    docKeyValueRows([
                        ("Conventional", "<package>/skills/*/SKILL.md"),
                        ("Manifest", "package.json → pi.skills")
                    ])
                }
            }

            AppCard(title: "Rules") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("• Skills are identified by directory name (the `name` frontmatter field, or directory name if omitted).")
                    Text("• Same-name skills at higher precedence replace lower: project > global > package.")
                    Text("• `~/.pi/agent/skills/` supports root `*.md` files as individual skills; `~/.agents/skills/` does not.")
                    Text("• Package skills are active by default when the package is discovered and are read-only.")
                    Text("• Skills are non-recursive within their directory (only direct children, not nested subdirs).")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Prompts

    private var promptsTab: some View {
        VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
            AppCard(title: "Slash Entries") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("In Pi, many things start with `/` but Agent Deck only treats file-backed prompt templates as prompt resources.")
                    Text("• **Built-in commands** — app actions like `/settings`, `/model`, `/reload`, `/quit`; Agent Deck uses RPC APIs instead.")
                    Text("• **Extension commands** — package/extension code actions; Agent Deck-managed sessions run with discovered extensions disabled.")
                    Text("• **Prompt templates** — file-backed `.md` templates that expand into the composer.")
                    Text("• **Skill commands** — invoke a skill by name.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            AppCard(title: "Prompt Template Locations") {
                VStack(alignment: .leading, spacing: 12) {
                    docKeyValueRows([
                        ("Global", "~/.pi/agent/prompts/*.md"),
                        ("Project", ".pi/prompts/*.md"),
                        ("Settings", "settings.json → prompts array (files/dirs)"),
                        ("Package", "package.json → pi.prompts or conventional prompts/ dir"),
                        ("CLI", "--prompt-template <path>")
                    ])
                }
            }

            AppCard(title: "Template Frontmatter") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Prompt templates are `.md` files with optional YAML frontmatter:")
                    Text("• `name` — display name (defaults to filename)")
                    Text("• `description` — shown in the slash menu")
                    Text("• `argument-hint` — placeholder text for the argument input")
                    Text("• Body content is injected into the composer when invoked.")
                    Text("• Discovery is non-recursive within each directory.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            AppCard(title: "Legacy Commands") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Pi migrates deprecated `commands/` directories to `prompts/` automatically. If you have a `commands/` directory, Pi will read it but you should rename it to `prompts/`.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Agents

    private var agentsTab: some View {
        VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
            AppCard(title: "Custom Agents") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Custom agents are `.md` files with YAML frontmatter. They live in global or project discovery paths and override builtins by name.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            AppCard(title: "Agent Frontmatter Fields") {
                VStack(alignment: .leading, spacing: 12) {
                    docKeyValueRows([
                        ("name", "Agent name (defaults to filename without extension)"),
                        ("description", "Short description"),
                        ("model", "Model identifier, e.g. anthropic/claude-sonnet-4"),
                        ("fallbackModels", "Ordered backup models"),
                        ("thinking", "Thinking level: off, low, medium, high"),
                        ("systemPromptMode", "replace (default) or append"),
                        ("systemPrompt", "Main instruction body (below frontmatter)"),
                        ("skills", "Explicit skill names passed to native subagents with --skill"),
                        ("tools", "Builtin tool allowlist; mcp: entries for direct MCP tools"),
                        ("extensions", "Extension loading mode: omitted, empty, or allowlist"),
                        ("skills", "Explicit skills to attach"),
                        ("disabled", "Disable this agent"),
                        ("output", "Default output file path"),
                        ("defaultReads", "Files Pi should read before execution"),
                        ("defaultProgress", "Enable progress.md tracking"),
                        ("maxSubagentDepth", "Max nested subagent launches (0-10)")
                    ])
                }
            }

            AppCard(title: "Settings Overrides") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("You can patch any agent's fields without creating a file, using `settings.json`:")
                    Text("```json\n{ \"subagents\": { \"agentOverrides\": { \"coder\": { \"model\": \"anthropic/claude-sonnet-4\", \"thinking\": \"high\" } } } }\n```"   )
                    Text("Project settings beat user settings. `disableBuiltins: true` removes all builtins.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Architecture

    private var architectureTab: some View {
        VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
            AppCard(title: "Entry Points") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Three entry points can trigger a subagent:")
                    Text("• **Managed tools** — parent sessions call \(AppBrand.displayName) bridge tools for single and parallel delegation")
                    Text("• **Manual run picker** — users start native child sessions from the composer or inspector")
                    Text("• **Parallel runs** — app-managed concurrent child sessions with optional worktree isolation")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            AppCard(title: "Execution Modes") {
                VStack(alignment: .leading, spacing: 12) {
                    docKeyValueRows([
                        ("SINGLE", "`params.agent?` → one agent, one task"),
                        ("PARALLEL", "`params.tasks?` → concurrent agents")
                    ])
                }
            }

            AppCard(title: "Foreground vs Background") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("• **Single**: one app-owned child Pi RPC session for a bounded task.")
                    Text("• **Parallel**: independent native child runs with app-owned status, stop, retry, and worktree controls.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            AppCard(title: "Control & Visibility") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("• `needs_attention` — fired when a child has had no activity for a configured window")
                    Text("• `active_long_running` — fired when a child has been running beyond a threshold")
                    Text("• `failed_tool_attempts` — consecutive mutating-tool failures trigger escalation")
                    Text("• These events appear as native transcript and activity cards scoped to the owning parent session.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Helpers

    private func docKeyValueRows(_ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(row.0)
                        .font(.body.weight(.semibold))
                        .frame(minWidth: 160, alignment: .trailing)
                    Text(row.1)
                        .foregroundStyle(AppTheme.mutedText)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DoctorScreen: View {
    @ObservedObject var viewModel: AppViewModel
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
            Task { await refreshPiRuntimeStatus() }
        }
        .sheet(item: $envDraft) { draft in
            EnvEditorSheet(
                draft: draft,
                onCancel: { envDraft = nil },
                onSave: { updated in
                    try viewModel.saveEnvDraft(updated)
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
            HStack(alignment: .top, spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(AppTheme.contentSubtleFill)
                        .stroke(AppTheme.contentStroke, lineWidth: 1)
                    Image("pi")
                        .resizable()
                        .renderingMode(.template)
                        .scaledToFit()
                        .foregroundStyle(piAgentStatusColor)
                        .padding(13)
                }
                .frame(width: 54, height: 54)

                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Pi")
                            .font(.title3.weight(.semibold))
                            .fontWidth(.expanded)
                        AppLabelTag(text: piAgentStatusLabel, color: piAgentStatusColor)
                    }

                    if let status = piRuntimeStatus {
                        Text(status.detail)
                            .font(.caption)
                            .foregroundStyle(AppTheme.mutedText)
                            .fixedSize(horizontal: false, vertical: true)

                        AppKeyValueList(rows: piAgentRows(for: status))

                        switch status.updateState {
                        case .some(.updateAvailable):
                            Button("Update in Terminal") { viewModel.openPiSelfUpdateInTerminal() }
                                .buttonStyle(.borderedProminent)
                        case let .some(.unableToCheck(reason)):
                            Text(reason)
                                .font(.caption.monospaced())
                                .foregroundStyle(AppTheme.mutedText)
                                .textSelection(.enabled)
                        case .some(.upToDate), .none:
                            EmptyView()
                        }
                    } else {
                        HStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Checking Pi...")
                                .foregroundStyle(AppTheme.mutedText)
                        }
                    }
                }

                Spacer(minLength: 8)
            }
            .padding(.vertical, 10)
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

    private func piAgentRows(for status: PiAgentRuntimeStatus) -> [(String, String)] {
        if !status.isInstalled {
            return [("Install", "npm install -g @earendil-works/pi-coding-agent")]
        }
        var rows = [("Current", status.currentVersion.flatMap { $0.isEmpty ? nil : $0 } ?? "Unknown")]
        if case let .some(.updateAvailable(latestVersion)) = status.updateState {
            rows.append(("Latest", latestVersion))
            rows.append(("Command", "pi update pi"))
        }
        return rows
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
            ("Scope", "Automations only"),
            ("Runtime", isAvailable ? "Local on-device" : "Unavailable"),
            ("Context", "Small window; Agent Deck bounds automation prompts")
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
                        ProgressView()
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
                        .background(Capsule(style: .continuous).fill(AppTheme.contentSubtleFill))
                }

                if item.status != .passed, item.action != nil || item.secondaryAction != nil {
                    HStack(spacing: 8) {
                        if let action = item.action {
                            Button(action.buttonTitle) { performSetupAction(action) }
                        }
                        if let secondaryAction = item.secondaryAction {
                            Button(secondaryAction.buttonTitle) { performSetupAction(secondaryAction) }
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
        switch action {
        case .chooseProjectRoot:
            viewModel.chooseProjectsRootDirectory()
        case .useSuggestedProjectRoot:
            viewModel.useSuggestedProjectsRootDirectory()
        }
        Task { await refreshSetupChecks() }
    }

    @MainActor
    private func refreshSetupChecks() async {
        isRefreshingSetup = true
        defer { isRefreshingSetup = false }
        async let setup = SetupDependencyService().loadItems(
            projectRootPath: viewModel.appSettings.projectsRootPath,
            githubAccount: viewModel.currentGitHubAccount,
            selectedProjectPath: viewModel.selectedProjectPath,
            hasConfirmedProjectsRootPath: viewModel.hasConfirmedProjectsRootPath,
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
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text(webFetchStatus.isInstalled ? "Reinstall Dependencies" : "Install Dependencies")
                        }
                    }
                    .disabled(isInstallingWebFetchDependencies)

                    Button {
                        refreshWebFetchStatus()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isInstallingWebFetchDependencies)
                    .help("Refresh fallback dependency status")
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
        [
            ("Status", webFetchStatus.isInstalled ? "Installed" : "Dependencies missing"),
            ("Packages", WebFetchDependencyService.packages.joined(separator: ", "))
        ]
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
                Button("Reveal") { revealInFinder(settings.path) }
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

    private func overridesDetail(_ overrides: [BuiltinOverrideRecord]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Builtin Overrides")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.mutedText)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(overrides.enumerated()), id: \.element.agentName) { index, override in
                    HStack(alignment: .top, spacing: 10) {
                        Text(override.agentName)
                            .font(.footnote.weight(.semibold))
                            .frame(minWidth: 100, alignment: .trailing)
                        Text(prettyJSONObject(override.values))
                            .font(.footnote.monospaced())
                            .foregroundStyle(AppTheme.mutedText)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 6)
                    if index < overrides.count - 1 { Divider() }
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
