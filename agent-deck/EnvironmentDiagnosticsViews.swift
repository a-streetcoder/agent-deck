import AppKit
import SwiftUI

struct EnvironmentScreen: View {
    let snapshot: ScanSnapshot
    let onEditKey: (EnvKeyRecord) -> Void
    @State private var revealedKeys: Set<String> = []

    var body: some View {
        AppPage("Environment", subtitle: "Keys are shown without secret values unless you explicitly reveal them") {
            AppCard(title: "How Environment Resolution Works") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("• New Pi sessions launched from Agent Deck receive inherited app environment, then global `.env`, then project `.env`, then Agent Deck runtime variables.")
                    Text("• Project `.env` values win over global/user `.env` values for the same key. Agent Deck runtime variables win over both.")
                    Text("• This does not change standalone Pi CLI/TUI behavior. If Pi or a Pi extension loads `.env` there, that is separate.")
                    Text("• Existing sessions keep the environment they started with. Start or resume a session to pick up saved changes.")
                    Text("• Reveal only changes the app display. It does not change the file.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            AppCard(title: "Effective Environment") {
                if effectiveEnvRows.isEmpty {
                    Text("No env files found.")
                        .foregroundStyle(AppTheme.mutedText)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        if snapshot.projectRoot != nil {
                            Text("Showing the values Agent Deck will inject for new sessions in this project. Duplicate keys are marked with their winning source and overridden files.")
                                .foregroundStyle(AppTheme.mutedText)
                        } else {
                            Text("Showing discovered global environment keys. Select a project to inspect the exact merged environment for that project.")
                                .foregroundStyle(AppTheme.mutedText)
                        }

                        ForEach(effectiveEnvRows, id: \.key) { row in
                            AppRowCard {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(alignment: .top, spacing: 10) {
                                        Image(systemName: "key")
                                            .foregroundStyle(.orange)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(row.key)
                                                .font(.body.monospaced())
                                            Text(row.summary)
                                                .font(.caption)
                                                .foregroundStyle(AppTheme.mutedText)
                                        }
                                        Spacer()
                                        if !row.overriddenRecords.isEmpty {
                                            AppLabelTag(text: "Overrides \(row.overriddenRecords.count)", color: .red)
                                        }
                                        AppLabelTag(text: row.winningSource.kind.rawValue, color: row.winningSource.kind == .project ? .green : .orange)
                                    }

                                    if !row.overriddenRecords.isEmpty {
                                        VStack(alignment: .leading, spacing: 4) {
                                            ForEach(row.overriddenRecords, id: \.id) { record in
                                                Text("Overrides \(record.source.path)")
                                                    .font(.caption)
                                                    .foregroundStyle(AppTheme.mutedText)
                                            }
                                        }
                                        .padding(.leading, 32)
                                    }

                                    HStack(spacing: 10) {
                                        Text(revealedKeys.contains(row.key) ? (row.winningRecord.value ?? "") : maskedValue(row.winningRecord.value))
                                            .font(.footnote.monospaced())
                                            .foregroundStyle(AppTheme.mutedText)
                                            .textSelection(.enabled)
                                        Spacer()
                                        Button(revealedKeys.contains(row.key) ? "Hide" : "Reveal") {
                                            toggleReveal(for: row.key)
                                        }
                                        Menu("Actions") {
                                            AppCopyTextButton(title: "Copy Key", text: row.winningRecord.key)
                                            AppCopyTextButton(title: "Copy Value", text: row.winningRecord.value ?? "")
                                            AppCopyTextButton(title: "Copy Line", text: "\(row.winningRecord.key)=\(row.winningRecord.value ?? "")")
                                            Divider()
                                            Button("Edit Key") { onEditKey(row.winningRecord) }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            AppCard(title: "Source Files") {
                if snapshot.envKeys.isEmpty {
                    Text("No env source files found.")
                        .foregroundStyle(AppTheme.mutedText)
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(groupedEnvFiles, id: \.path) { file in
                            AppRowCard {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(alignment: .top, spacing: 10) {
                                        Image(systemName: "doc.text")
                                            .foregroundStyle(.secondary)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(file.path)
                                                .font(.footnote.monospaced())
                                            Text("\(file.keys.count) keys")
                                                .font(.caption)
                                                .foregroundStyle(AppTheme.mutedText)
                                        }
                                        Spacer()
                                        AppLabelTag(text: file.kind.rawValue, color: file.kind == .project ? .green : .orange)
                                    }

                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(spacing: 8) {
                                            ForEach(file.keys) { key in
                                                Button(key.key) { onEditKey(key) }
                                                    .buttonStyle(.bordered)
                                                    .font(.caption.monospaced())
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
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

    private var groupedEnvFiles: [(path: String, kind: ResourceScopeKind, keys: [EnvKeyRecord])] {
        Dictionary(grouping: snapshot.envKeys, by: { $0.source.path })
            .map { path, keys in
                (path: path, kind: keys.first?.source.kind ?? .global, keys: keys.sorted { $0.key < $1.key })
            }
            .sorted { $0.path < $1.path }
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
        case agents = "Agents & Chains"
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

            AppCard(title: "Context Modes") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("• **Fresh** (default): child starts blank, gets only its own system prompt, skills, and task.")
                    Text("• **Fork**: child inherits the full parent conversation as read-only reference. Used for oracle, worker, planner.")
                    Text("• Auto-detection: if any requested agent has `defaultContext: fork`, the entire invocation upgrades to fork mode.")
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

    // MARK: - Prompts & Commands

    private var promptsTab: some View {
        VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
            AppCard(title: "Slash Entries") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("In Pi, many things start with `/` but they are not all the same:")
                    Text("• **Built-in commands** — app actions like `/settings`, `/model`, `/reload`, `/quit`")
                    Text("• **Commands** — registered by packages, e.g. `/agents`, `/subagents-status`")
                    Text("• **Prompt templates** — file-backed `.md` templates that expand into the composer")
                    Text("• **Skill commands** — invoke a skill by name")
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

    // MARK: - Agents & Chains

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
                        ("defaultContext", "fresh or fork — default context mode"),
                        ("inheritProjectContext", "Whether child reads project context files"),
                        ("inheritSkills", "Whether child keeps Pi's discovered skills catalog"),
                        ("tools", "Builtin tool allowlist; mcp: entries for direct MCP tools"),
                        ("extensions", "Extension loading mode: omitted, empty, or allowlist"),
                        ("skills", "Explicit skills to attach"),
                        ("disabled", "Disable this agent"),
                        ("output", "File path for chain step output"),
                        ("defaultReads", "Files Pi should read before execution"),
                        ("defaultProgress", "Enable progress.md tracking"),
                        ("maxSubagentDepth", "Max nested subagent launches (0-10)")
                    ])
                }
            }

            AppCard(title: "Chains") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Chains are `.chain.md` files defining sequential pipelines where each step's output becomes `{previous}` for the next.")
                    Text("Locations: `~/.pi/agent/agents/*.chain.md` (user) or `.pi/agents/*.chain.md` (project).")
                    Text("Steps are defined with `## agent-name` headers. Each step supports: `output`, `reads`, `model`, `skill`/`skills`, `progress`.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            AppCard(title: "Settings Overrides") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("You can patch any agent's fields without creating a file, using `settings.json`:")
                    Text("```json\n{ \"subagents\": { \"agentOverrides\": { \"worker\": { \"model\": \"anthropic/claude-sonnet-4\", \"thinking\": \"high\" } } } }\n```"   )
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
                    Text("Four entry points can trigger a subagent:")
                    Text("• **Managed tools** — parent sessions call \(AppBrand.displayName) bridge tools for single, chain, and parallel delegation")
                    Text("• **Manual run picker** — users start native child sessions from the composer or inspector")
                    Text("• **Chains** — app-managed sequential workflows where each step receives previous output")
                    Text("• **Parallel runs** — app-managed concurrent child sessions with optional worktree isolation")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            AppCard(title: "Execution Modes") {
                VStack(alignment: .leading, spacing: 12) {
                    docKeyValueRows([
                        ("SINGLE", "`params.agent?` → one agent, one task"),
                        ("PARALLEL", "`params.tasks?` → concurrent agents"),
                        ("CHAIN", "`params.chain?` → sequential pipeline with {previous} templating")
                    ])
                }
            }

            AppCard(title: "Foreground vs Background") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("• **Single**: one app-owned child Pi RPC session for a bounded task.")
                    Text("• **Chain**: sequential native child runs where each step receives the previous result.")
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

struct DiagnosticsScreen: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var setupItems: [SetupCheckItem] = []
    @State private var isRefreshingSetup = true

    private var snapshot: ScanSnapshot {
        viewModel.snapshot
    }

    private struct PackageInfo {
        let name: String
        let displayName: String
        let description: String
        let repoURL: String?
        let homepageURL: String?
        let author: String
        let installCommand: String
        let category: Category
        let isInstalled: Bool
        let installedVersion: String?

        enum Category {
            case essential, recommended, niceToHave
        }
    }

    private var packages: [PackageInfo] {
        return [
            PackageInfo(
                name: "pi-web-access",
                displayName: "pi-web-access",
                description: "Web search, URL fetching, GitHub repo cloning, PDF extraction, and YouTube/local video analysis.",
                repoURL: "https://github.com/nicobailon/pi-web-access",
                homepageURL: "https://github.com/nicobailon/pi-web-access#readme",
                author: "Nico Bailon",
                installCommand: "pi install npm:pi-web-access",
                category: .essential,
                isInstalled: isPackageInstalled("pi-web-access"),
                installedVersion: installedPackageVersion("pi-web-access")
            )
        ]
    }

    var body: some View {
        AppPage("Doctor", subtitle: "Check what \(AppBrand.displayName) is missing and fix the essentials faster") {
            setupChecksSection
            packageSection
            settingsSection
            warningsSection
        }
        .task {
            if setupItems.isEmpty {
                await refreshSetupChecks()
            }
        }
    }

    // MARK: - Setup Checks

    private var setupChecksSection: some View {
        AppCard(title: "Setup Checks") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Same checks shown during onboarding.")
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedText)
                    Spacer()
                    Button {
                        Task { await refreshSetupChecks() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isRefreshingSetup)
                    .help("Refresh setup checks")
                }

                if isRefreshingSetup && setupItems.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Checking \(AppBrand.displayName) setup...")
                            .foregroundStyle(AppTheme.mutedText)
                    }
                    .padding(.vertical, 8)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(setupItems.enumerated()), id: \.element.id) { index, item in
                            setupCheckRow(item)
                            if index < setupItems.count - 1 {
                                Divider()
                            }
                        }
                    }
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
            }

            Spacer(minLength: 8)

            AppLabelTag(text: item.status.label, color: item.status.color)
        }
        .padding(.vertical, 12)
    }

    @MainActor
    private func refreshSetupChecks() async {
        isRefreshingSetup = true
        defer { isRefreshingSetup = false }
        setupItems = await SetupDependencyService().loadItems(
            projectRootPath: viewModel.appSettings.projectsRootPath,
            githubAccount: viewModel.currentGitHubAccount,
            selectedProjectPath: viewModel.selectedProjectPath
        )
    }

    // MARK: - Packages

    private var packageSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.sectionSpacing) {
            AppCard(title: "Essential") {
                packageRows(packages.filter { $0.category == .essential })
            }

            let recommended = packages.filter { $0.category == .recommended }
            if !recommended.isEmpty {
                AppCard(title: "Recommended") {
                    packageRows(recommended)
                }
            }

            let optional = packages.filter { $0.category == .niceToHave }
            if !optional.isEmpty {
                AppCard(title: "Nice to Have") {
                    packageRows(optional)
                }
            }
        }
    }

    private func packageRows(_ items: [PackageInfo]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.name) { index, pkg in
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: pkg.isInstalled ? "checkmark.circle.fill" : "xmark.circle")
                        .font(.title3)
                        .foregroundStyle(pkg.isInstalled ? .green : .red)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(pkg.displayName)
                                .font(.body.weight(.semibold))
                                .fontWidth(.expanded)

                            if let version = pkg.installedVersion {
                                Text(version)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(AppTheme.mutedText)
                            }
                        }

                        Text(pkg.description)
                            .font(.caption)
                            .foregroundStyle(AppTheme.mutedText)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 8) {
                            if !pkg.author.isEmpty {
                                doctorMetaChip("Author", value: pkg.author)
                            }
                            if let repoURL = pkg.repoURL {
                                doctorLinkChip("GitHub", url: repoURL)
                            }
                            if let homepageURL = pkg.homepageURL {
                                doctorLinkChip("Docs", url: homepageURL)
                            }
                        }

                        HStack(spacing: 8) {
                            Text(pkg.installCommand)
                                .font(.caption.monospaced())
                                .foregroundStyle(AppTheme.mutedText)
                                .textSelection(.enabled)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Capsule(style: .continuous).fill(AppTheme.contentSubtleFill))

                            AppCopyTextButton(text: pkg.installCommand)
                            .controlSize(.small)
                        }
                    }

                    Spacer(minLength: 8)

                    AppLabelTag(
                        text: pkg.isInstalled ? "Installed" : "Missing",
                        color: pkg.isInstalled ? .green : .red
                    )
                }
                .padding(.vertical, 12)

                if index < items.count - 1 {
                    Divider()
                }
            }
        }
    }

    // MARK: - Helpers

    private func doctorMetaChip(_ title: String, value: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .foregroundStyle(AppTheme.mutedText)
            Text(value)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule(style: .continuous).fill(AppTheme.contentSubtleFill))
    }

    private func doctorLinkChip(_ title: String, url: String) -> some View {
        Button {
            guard let resolvedURL = URL(string: url) else { return }
            NSWorkspace.shared.open(resolvedURL)
        } label: {
            HStack(spacing: 6) {
                Text(title)
                Image(systemName: "arrow.up.right.square")
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule(style: .continuous).fill(AppTheme.contentSubtleFill))
        }
        .buttonStyle(.plain)
        .help(url)
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

    // MARK: - Helpers

    private func installedPackageVersion(_ name: String) -> String? {
        let candidates = [
            URL(fileURLWithPath: "/opt/homebrew/lib/node_modules/\(name)/package.json"),
            URL(fileURLWithPath: "/usr/local/lib/node_modules/\(name)/package.json"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".npm-global/lib/node_modules/\(name)/package.json"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("node_modules/\(name)/package.json")
        ]

        for candidate in candidates {
            guard let data = try? Data(contentsOf: candidate),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let version = json["version"] as? String,
                  !version.isEmpty else { continue }
            return version
        }

        return nil
    }

    private func isPackageInstalled(_ name: String) -> Bool {
        let candidates = [
            URL(fileURLWithPath: "/opt/homebrew/lib/node_modules/\(name)"),
            URL(fileURLWithPath: "/usr/local/lib/node_modules/\(name)"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".npm-global/lib/node_modules/\(name)"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("node_modules/\(name)")
        ]
        return candidates.contains { FileManager.default.fileExists(atPath: $0.path) }
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
    case .project, .legacyProject:
        return "Project"
    case .package:
        return "Package"
    case .library:
        return "Library"
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
    return "User"
}
