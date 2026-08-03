import AppKit
import Combine
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

@MainActor
final class NativeSubagentCompletionGate {
    var isCompleted = false

    func complete(_ body: () -> Void) {
        guard !isCompleted else { return }
        isCompleted = true
        body()
    }
}

@MainActor
final class NativeParallelGraphScheduler {
    let id = UUID()
    let parentSession: PiAgentSessionRecord
    let graphRunID: UUID
    let tasks: [(agentName: String, task: String)]
    let concurrency: Int
    let useWorktreeIsolation: Bool
    let forcedExpectedOutcome: PiSubagentExpectedOutcome?
    let completion: ((PiSubagentRunRecord) -> Void)?
    var nextIndex = 0
    var active = 0
    var completed = 0
    var failed = false
    var isCancelled = false

    init(parentSession: PiAgentSessionRecord, graphRunID: UUID, tasks: [(agentName: String, task: String)], concurrency: Int, useWorktreeIsolation: Bool, forcedExpectedOutcome: PiSubagentExpectedOutcome? = nil, completion: ((PiSubagentRunRecord) -> Void)?) {
        self.parentSession = parentSession
        self.graphRunID = graphRunID
        self.tasks = tasks
        self.concurrency = concurrency
        self.useWorktreeIsolation = useWorktreeIsolation
        self.forcedExpectedOutcome = forcedExpectedOutcome
        self.completion = completion
    }
}

enum PiAgentSessionOwnedArtifactCleanup {
    static func childPiSessionFiles(in runs: [PiSubagentRunRecord]) -> Set<String> {
        Set(runs.flatMap { run in
            [run.childPiSessionFile, run.child?.sessionFile].compactMap { $0 }
                + (run.children ?? []).compactMap(\.sessionFile)
        })
    }

    nonisolated static func delete(
        piSessionFiles: Set<String>,
        subagentRunIDs: Set<UUID>,
        piSessionsRoot: URL? = nil,
        subagentRunsRoot: URL? = nil
    ) {
        let fileManager = FileManager.default
        let piRoot = (piSessionsRoot ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/sessions", isDirectory: true)).resolvingSymlinksInPath().standardizedFileURL
        let runRoot = (subagentRunsRoot ?? URL.applicationSupportDirectory
            .appendingPathComponent(AppBrand.displayName, isDirectory: true)
            .appendingPathComponent("Subagent Runs", isDirectory: true)).resolvingSymlinksInPath().standardizedFileURL

        for path in piSessionFiles {
            let candidate = URL(fileURLWithPath: path).standardizedFileURL
            let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.path.hasPrefix(piRoot.path + "/"), resolved.pathExtension == "jsonl",
                  let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            try? fileManager.removeItem(at: candidate)
            let parent = candidate.deletingLastPathComponent()
            if parent.path != piRoot.path,
               (try? fileManager.contentsOfDirectory(atPath: parent.path).isEmpty) == true {
                try? fileManager.removeItem(at: parent)
            }
        }

        for runID in subagentRunIDs {
            let candidate = runRoot.appendingPathComponent(runID.uuidString, isDirectory: true).standardizedFileURL
            guard candidate.path.hasPrefix(runRoot.path + "/"),
                  let values = try? candidate.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true else { continue }
            try? fileManager.removeItem(at: candidate)
        }
    }
}


@MainActor
@Observable
final class AppViewModel: NSObject {
    let windowID = UUID()
    var snapshot: ScanSnapshot = .empty {
        didSet { clearAgentUniverseCache() }
    }
    var selectedSidebarItem: SidebarItem = .agent
    /// Whether the Coding Agent pull-up panel covers the upper sidebar (full
    /// session list) or sits collapsed below RUNTIME (recent sessions only).
    /// Defaults **true** (session list expanded on launch / after store load).
    /// Collapsed only when the user collapses it or selects another sidebar item
    /// (see `ContentView.handleSidebarSelectionChange`).
    var isCodingAgentPanelExpanded = true

    /// Visible session rows of the ACTIVE sidebar panel (expanded or collapsed),
    /// refreshed by that panel whenever it rebuilds its cached sections. Keyboard
    /// navigation (`selectAdjacentPiAgentSession`, ⌘]/⌘[, in-list ↑/↓) operates
    /// within this list only — no navigation into hidden preview/collapsed rows
    /// and no auto-reveal. Empty until the first panel reports in; navigation
    /// falls back to `scopedPiAgentSessionsInOrder` in that brief window.
    var piAgentVisibleSessionsForNavigation: [PiAgentSessionRecord] = []

    // MARK: - Provider sign-in

    /// Providers with a credential in `~/.pi/agent/auth.json` (== signed in).
    var signedInProviders: Set<String> = []
    /// Provider id → credential type (`"api_key"`/`"oauth"`) for UI labelling.
    var providerAuthTypes: [String: String] = [:]
    /// Every provider Pi can connect to, including the authentication methods
    /// advertised by the installed runtime. This powers the Add Provider picker.
    var connectableProviders: [PiConnectableProvider] = []
    var isLoadingConnectableProviders = false
    var connectableProvidersError: String?
    var connectableProviderLoadState = PiProviderCatalogLoadState()
    let providerLogoutService = PiProviderLoginService()
    /// Drives the Add Provider picker sheet (opened from the Models toolbar `+`).
    var isAddProviderPresented = false

    var selectedAgentID: EffectiveAgentRecord.ID?
    var selectedSkillID: SkillRecord.ID?
    /// Skills whose deletion file I/O has finished but for which a fresh
    /// snapshot has not yet landed. Filtered out of `allVisibleSkillRecords`
    /// so the row disappears instantly. Pruned in `applyRefreshSnapshot`.
    var pendingDeletedSkillIDs: Set<String> = [] {
        didSet { rebuildVisibleSkillRecordCachesIfNeeded() }
    }
    /// Prompt templates whose deletion file I/O has finished but for which a
    /// fresh snapshot has not yet landed. Filtered out of
    /// `allVisiblePromptTemplateRecords`. Pruned in `applyRefreshSnapshot`.
    var pendingDeletedPromptIDs: Set<String> = []
    /// After a rename the fresh snapshot is applied asynchronously, so the
    /// renamed record's new id is not known synchronously. These hold the new
    /// name so `applyRefreshSnapshot` can restore the selection once it lands.
    @ObservationIgnored var pendingSelectAgentName: String?
    @ObservationIgnored var pendingSelectSkillName: String?
    /// After a new skill/prompt is saved its record only appears in the
    /// snapshot once the next refresh lands. These hold the filepath so
    /// `applyRefreshSnapshot` can select the freshly-created record once it
    /// becomes visible — replaces the older "synchronous refresh + lookup"
    /// pattern that froze the UI on the filesystem scan.
    @ObservationIgnored var pendingSelectSkillFilePath: String?
    @ObservationIgnored var pendingSelectPromptFilePath: String?
    var selectedCommandItemID: String?
    /// Set by `openMemory(byID:)` when the user taps an injected memory title in a
    /// transcript recall card. `MemoryScreen` consumes it to select that record,
    /// then nils it. Observable so the screen's `.onChange` fires.
    var selectedMemoryID: String?
    var selectedAgentFilter: AgentFilter = .all
    var discoveredProjects: [DiscoveredProject] = [] {
        didSet {
            rebuildProjectByPath()
            discoveredProjectsRevision &+= 1
        }
    }
    /// Bumped on every assignment to `discoveredProjects`. Cheap change signal
    /// for cached layouts that depend on the project list ordering or contents
    /// — avoids hashing/joining paths per `.task(id:)` evaluation.
    var discoveredProjectsRevision: Int = 0
    /// O(1) lookup mirror of `discoveredProjects`. Use this from view bodies
    /// (e.g. `PiAgentSessionRow`'s project lookup) instead of `.first(where:)`,
    /// which would walk the array per row per render.
    var projectByPath: [String: DiscoveredProject] = [:]
    /// Becomes true after the first discovery result is applied. Persisted sessions
    /// can load before then; grouping must not classify their project paths as
    /// orphaned during that cold-start window.
    var hasCompletedInitialProjectDiscovery = false
    func rebuildProjectByPath() {
        projectByPath = Dictionary(uniqueKeysWithValues: discoveredProjects.map { ($0.path, $0) })
    }
    var isRefreshingProjects = false
    var projectPreferencesByPath: [String: ProjectPreference] = ProjectPreferencesStore.shared.preferencesByPath
    /// Bumped every time `projectPreferencesByPath` is reassigned (via
    /// `applyProjectPreferenceChanges` or the refresh snapshot apply path).
    /// Cheap `.task(id:)` change signal for cached layouts that depend on
    /// preferences — avoids hashing the full dict per render.
    var projectPreferencesRevision: Int = 0
    var selectedProjectPath: String? {
        didSet { clearAgentUniverseCache() }
    }
    var allProjectSnapshots: [String: ScanSnapshot] = [:] {
        didSet { clearAgentUniverseCache() }
    }
    var availableModels: [AvailableModel] = [] {
        didSet { rebuildModelCaches() }
    }
    var modelsLastUpdatedAt: Date?
    // Manual invalidation token for Pi runtime defaults — bumped by
    // setDefaultPiAgentModel/setDefaultPiAgentThinkingLevel writers, read via
    // `_ = piRuntimeSettingsRevision` inside defaultPiAgentModel() and
    // piRuntimeDefaultThinkingLevel(). Must be observable so the "Set as
    // default" button (and any other consumer in a view body) re-renders
    // after a write — otherwise body reads stay stuck on the prior value.
    // No cycle risk: only mutated by explicit writers, never during a read.
    var piRuntimeSettingsRevision = 0
    // Internal caches for the on-disk Pi runtime settings file. Not tracked:
    // they're written during the same call that reads them (the stat-check
    // throttle), and they're consumed by methods like defaultPiAgentModel() /
    // piRuntimeDefaultThinkingLevel() that get called inside view bodies — so
    // tracking would create a read→write AttributeGraph cycle.
    @ObservationIgnored var cachedPiRuntimeSettingsObject: [String: Any]?
    @ObservationIgnored var cachedPiRuntimeSettingsModificationDate: Date?
    @ObservationIgnored var lastPiRuntimeSettingsStatCheck: Date?
    @ObservationIgnored var cachedPiRuntimeDefaults: (settingsModificationDate: Date?, provider: String?, model: String?, thinkingLevel: String?)?
    var repositoryChanges: RepositoryChangesSnapshot?
    var repositoryChangesProjectPath: String?
    var repositoryChangesCache: [String: RepositoryChangesCacheEntry] = [:]
    var repositorySelectedChangePaths: Set<String> = []
    var repositorySelectedDiffFilePath: String?
    var repositorySelectedDiffKind: GitDiffKind?
    var repositorySelectedDiffText: String?
    /// Trailing inspector open state (Repo Review workbench; expandable later).
    var isTrailingInspectorExpanded = false
    /// Full working-tree file text for the selected change (not truncated diff).
    var repositorySelectedFileText: String?
    var repositorySelectedFileLoadError: String?
    var repositoryFileContentRequestID = 0
    var repositoryCommitMessage = ""
    var repositoryCommitDescription = ""
    var isLoadingRepositoryChanges = false
    var isCommittingRepository = false
    var isPushingRepository = false
    var piAgentGitAutomationAction: PiAgentGitAutomationAction?
    var isRefreshingEverything = false
    var repositoryLastError: String?
    var loopDefinitions: [LoopDefinition] = []
    var selectedLoopDefinitionID: LoopDefinition.ID?
    var newLoopRequestID = UUID()
    var pendingNewLoopEditorDraft: LoopDefinitionEditorDraft?
    @ObservationIgnored var loopDefinitionStore = LoopDefinitionStore()

    var appSettings: AppSettings = AppSettings() {
        didSet {
            rebuildModelCaches()
            rebuildExternalSkillPathCache()
        }
    }
    /// Standardized `externalSkillPaths` as a set. `isImportedSkill` is called
    /// per skill row during layout and otherwise re-allocates + standardizes
    /// every external path for every skill (O(skills × paths) `URL` churn — a
    /// measured Skills-tab hang hotspot). Derived from `appSettings`, so it is
    /// observation-ignored and rebuilt in the `didSet` above.
    @ObservationIgnored var cachedStandardizedExternalSkillPaths: Set<String> = []
    /// Updated only by the refresh pipeline; prevents per-row Codex cache walks.
    @ObservationIgnored var cachedResolvedCodexPluginSkillPaths: [CodexPluginSkillReference: String] = [:]
    /// Transient merged MCP entries from the last refresh (config only).
    @ObservationIgnored var mergedMCPEntries: [MCPServerEntry] = []
    var hasCompletedInitialRefresh = false
    var cachedHasAgentWarnings = false
    var cachedHasSkillWarnings = false
    var cachedHasPromptWarnings = false
    var cachedSkillWarnings: [DiagnosticWarning] = []
    var cachedPromptWarnings: [DiagnosticWarning] = []
    var cachedSkillReferenceWarnings: [SkillReferenceWarning] = []
    var cachedSkillVisibilityIssuesByAgentID: [String: [AgentSkillVisibilityIssue]] = [:]
    // Automation-model lookup is cached. `FoundationModelAutomationService`
    // queries Apple's Foundation Models availability API, and the Pi Agent
    // toolbar reads `automationAvailableModels` on every `ContentView.body`
    // eval (i.e. once per streaming token). The result only changes at real
    // boundaries — see `rebuildModelCaches()`.
    var cachedFoundationAutomationModel: AvailableModel?
    var cachedEnabledAvailableModels: [AvailableModel] = []
    var cachedAvailableModelByIdentifier: [String: AvailableModel] = [:]
    var cachedEnabledAvailableModelByIdentifier: [String: AvailableModel] = [:]
    var cachedEnabledAvailableModelByModel: [String: AvailableModel] = [:]
    var cachedDisplayModels: [AvailableModel] = []
    var cachedGroupedDisplayModels: [(provider: String, models: [AvailableModel])] = []
    var cachedAutomationAvailableModels: [AvailableModel] = []
    var cachedAutomationAvailableModelByIdentifier: [String: AvailableModel] = [:]
    @ObservationIgnored var modelCacheRevision: Int = 0
    @ObservationIgnored var cachedDefaultPiAgentModelLookup: (provider: String?, model: String?, modelRevision: Int, result: AvailableModel?)?
    // Agent-list caches — the `allDisplayAgents` chain (a 4-source merge + sort)
    // and per-agent warnings were recomputed on every `AgentsScreen` /
    // `ContentView` body evaluation. Rebuilt inside `rebuildWarningCaches()`,
    // alongside `cachedSkillVisibilityIssuesByAgentID` — so they refresh on
    // exactly the same events (every data rescan) and can't go stale.
    var cachedAllDisplayAgents: [EffectiveAgentRecord] = []
    // O(1) selection lookup. Sourced from `cachedAllDisplayAgents` in
    // `rebuildWarningCaches()`; lets `selectedAgent` resolve without touching
    // `filteredAgents` / `catalogOnlyEffectiveAgents` / `libraryOnlyEffectiveAgents`
    // on every body read.
    var cachedDisplayAgentByID: [EffectiveAgentRecord.ID: EffectiveAgentRecord] = [:]
    // Bumped whenever the display-agent caches rebuild. Cheap `Int` signal for
    // `.onChange` so views don't pay an `Equatable` pass over the full agent
    // array every body eval just to detect changes.
    var displayAgentsRevision: Int = 0
    var cachedAgentWarningsByID: [EffectiveAgentRecord.ID: [DiagnosticWarning]] = [:]
    /// Lowercased search haystacks for `AgentLibraryPane`. Built from the exact
    /// fields the pane searches (name, description, resolution kind, source
    /// path, system prompt) when display-agent caches rebuild, so typing in the
    /// search field doesn't lowercase large prompts on every filter pass.
    var cachedAgentSearchHaystackByID: [EffectiveAgentRecord.ID: String] = [:]
    /// Cached global skill catalog for the Skills view. Rebuilt from
    /// `globalSnapshot` + pending-delete state and exposed through
    /// `visibleSkillRecordsRevision` so views can observe an Int instead of
    /// comparing full skill records (including bodies) on every refresh.
    var cachedAllVisibleSkillRecords: [SkillRecord] = []
    var visibleSkillRecordsRevision: Int = 0
    /// Lowercased base skill search haystacks (name, description, scope, path,
    /// body). Repository labels are still appended by `SkillsScreen` because
    /// they are derived while resolving repository membership there.
    var cachedSkillSearchHaystackByID: [SkillRecord.ID: String] = [:]
    // Per-skill list metadata (assigned / has-warnings). Same rebuild +
    // invalidation as the agent caches above — never per `SkillsScreen` body.
    var cachedSkillMetadataByID: [SkillRecord.ID: SkillListMetadata] = [:]
    // Per-skill matching diagnostic warnings — precomputed alongside the
    // `hasWarnings` flag so the skill detail pane doesn't re-scan
    // `skillWarnings` with four string-contains checks per render. Empty
    // entry for any skill without warnings (cache-hit is authoritative).
    var cachedWarningsBySkillID: [SkillRecord.ID: [DiagnosticWarning]] = [:]
    var enabledAvailableModels: [AvailableModel] { cachedEnabledAvailableModels }

    var foundationAutomationModel: AvailableModel? { cachedFoundationAutomationModel }

    var automationAvailableModels: [AvailableModel] { cachedAutomationAvailableModels }
    var showPiAgentAttentionOnly = false
    /// Acknowledged old attention session retained in the focused list only
    /// while it remains selected in Coding Agent. This is view state, never
    /// persisted, and filtering happens before grouping so it cannot bypass a
    /// search or attention-only filter.
    var transientFocusedPiAgentSessionID: UUID?
    /// Per-project "Show more/less" state for the All-Projects grouped session
    /// list, keyed by section id (project path, or the catch-all "Other").
    /// Shared on the view model so all mounted session lists (sidebar panel,
    /// Pi Agent screen column) stay consistent and so ⌘]/⌘[ and ↑/↓ can
    /// auto-reveal a hidden target.
    var expandedProjects: Set<String> = []
    /// Per-project disclosure-collapse state for the grouped list (a collapsed
    /// group renders only its header).
    var collapsedProjects: Set<String> = []
    var piAgentTitleGeneratingSessionIDs: Set<UUID> = []
    var piAgentPendingComposerText: String?
    let piAgentSessionStore = PiAgentSessionStore()
    let agentMemoryStore = AgentMemoryStore()
    let agentImageStore = AgentImageStore()
    let skillRepositorySyncService = SkillRepositorySyncService()
    var isCheckingAllSkillUpdates = false
    var isUpdatingAllSkillRepositories = false
    var skillBatchActionMessage: String?

    let agentPersistence = AgentPersistence()
    let envPersistence = EnvPersistence()
    let projectPreferencesStore = ProjectPreferencesStore.shared
    let appSettingsController = AppSettingsController()
    let gitRepositoryService = GitRepositoryService()
    let shipService = PiAgentShipService()
    /// Tag-and-push release flow, scoped to the agent-deck repo itself.
    var agentDeckReleaseService: ReleaseService { ReleaseService(gitRepositoryService: gitRepositoryService) }
    let agentAvatarPromptService = AgentAvatarPromptGenerationService()
    let skillDescriptionService = SkillDescriptionGenerationService()
    let releaseNotesGenerator = ReleaseNotesGenerationService()
    let subagentWorktreeService = PiSubagentWorktreeService()
    let sessionWorktreeService = PiAgentSessionWorktreeService()
    @ObservationIgnored lazy var piAgentRunner = PiAgentRunnerService(store: piAgentSessionStore)
    @ObservationIgnored lazy var nativeSubagentRunner = PiSubagentRunService(store: piAgentSessionStore)
    @ObservationIgnored var activePipelineChildRunByLoopID: [UUID: UUID] = [:]
    /// Memoizes `selectableAgentUniverse(forProjectPath:)` so the subagent
    /// picker (and `catalogAgents(for:)` / `sessionHasSelectableAgents`) read
    /// a precomputed list instead of rebuilding it on every body evaluation.
    /// Cleared in `clearAgentUniverseCache()` whenever a snapshot publishes.
    @ObservationIgnored var agentUniverseCacheByProjectPath: [String: [EffectiveAgentRecord]] = [:]
    let piSessionTitleGenerator = PiSessionTitleGenerationService()
    let projectServerService = ProjectServerService()
    /// App-shared MCP server connections. Survives across sessions; torn down at quit.
    let mcpConnectionManager = MCPConnectionManager()
    /// Cached catalog of all configured MCP tools, refreshed off-main. Read synchronously
    /// by the launch-time catalog provider, so it must never be recomputed in a view body.
    @ObservationIgnored var mcpCatalogSnapshot: [MCPCatalogEntry] = []
    var mcpCatalogRevision = 0
    @ObservationIgnored var mcpConfiguredServerNames: Set<String> = []
    @ObservationIgnored let mcpRefreshCoordinator = MCPConfigurationRefreshCoordinator()
    @ObservationIgnored var mcpRefreshTask: Task<Void, Never>?
    @ObservationIgnored var mcpLastRefreshKey: String?
    var globalSnapshot: ScanSnapshot = .empty {
        didSet {
            clearAgentUniverseCache()
            rebuildVisibleSkillRecordCachesIfNeeded()
        }
    }
    /// Always-global resource catalog snapshot, independent of `selectedProjectPath`.
    /// The Agents/Skills/Prompts management views read this so their listing is
    /// global — project selection only drives Memory and new-session context,
    /// never the resource catalog presentation.
    var globalCatalogSnapshot: ScanSnapshot { globalSnapshot }
    var projectRootURL: URL?
    var autoRefreshCancellable: AnyCancellable?
    var watchFingerprintTask: Task<Void, Never>?
    var watchEventDebounceTask: Task<Void, Never>?
    var deferredWatchRefreshTask: Task<Void, Never>?
    var fileWatchEventMonitor: FileWatchEventMonitor?
    var lastWatchFingerprint: String = ""
    var watchedURLsForAutoRefresh: [URL] = []
    var refreshTask: Task<Void, Never>?
    var refreshRequestID = 0
    var launchResourceFingerprintTask: Task<Void, Never>?
    var launchResourceFingerprintsBySessionID: [UUID: String] = [:]
    var isRefreshingModels = false
    var repositoryChangesRequestID = 0
    var repositoryDiffRequestID = 0
    var repositoryDiffCache: [GitDiffCacheKey: String] = [:]
    var repositoryDiffCacheOrder: [GitDiffCacheKey] = []
    let repositoryDiffCacheLimit = 64
    let repositoryChangesCacheLifetime: TimeInterval = 5
    let watchEventDebounceNanoseconds: UInt64 = 1_000_000_000
    let watchRefreshQuietNanoseconds: UInt64 = 1_200_000_000
    let fallbackAutoRefreshInterval: TimeInterval = 300
    var nativeParallelSchedulersByID: [UUID: NativeParallelGraphScheduler] = [:]
    let lastSelectedProjectDefaultsKey = "lastSelectedProjectPath"
    var pendingPiAgentNotificationTasks: [UUID: Task<Void, Never>] = [:]
    /// In-flight first-send worktree provisioning, shared per session so a
    /// rapid second send awaits the same task instead of provisioning twice.
    @ObservationIgnored var worktreeProvisionTasksBySessionID: [UUID: Task<Void, Never>] = [:]
    private var artifactCleanupTask: Task<Void, Never>?
    var didShutdown = false

    var piAgentNotificationDelay: TimeInterval {
        TimeInterval(piAgentNotificationDelayMinutes * 60)
    }

    var piAgentIdleParkingTimeout: TimeInterval? {
        guard isPiAgentIdleParkingEnabled else { return nil }
        return TimeInterval(piAgentIdleParkingTimeoutMinutes * 60)
    }

    override init() {
        super.init()

        appSettings = appSettingsController.settings
        PiExecutableResolver.setPreferredPath(appSettings.piExecutablePath)
        reloadLoopDefinitions()
        ThemeManager.shared.apply(appSettingsController.resolvedActiveTheme)
        ThemeManager.shared.setMarkdownHighlightingEnabled(appSettingsController.settings.piAgentMarkdownHighlightingEnabled)
        #if DEBUG
        // Xcode Previews: stop here so preview view models stay empty (no models,
        // no projects, no GitHub) and never spawn pi/gh subprocesses — giving a
        // deterministic "nothing installed" state for the onboarding/Doctor previews.
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" { return }
        #endif
        selectedProjectPath = UserDefaults.standard.string(forKey: lastSelectedProjectDefaultsKey)
        if let selectedProjectPath {
            projectRootURL = URL(fileURLWithPath: selectedProjectPath, isDirectory: true).standardizedFileURL
        }
        piAgentSessionStore.newSessionSubagentsEnabled = appSettings.nativeSubagentsEnabledForNewSessions
        piAgentSessionStore.onStopLoopRun = { [weak self] runID, sessionID in
            guard let self, let childRunID = self.activePipelineChildRunByLoopID.removeValue(forKey: runID) else { return }
            self.stopNativeSubagent(runID: childRunID, parentSessionID: sessionID)
        }
        piAgentSessionStore.onLoadApplied = { [weak self] in
            guard let self else { return }
            self.pruneNeverStartedDraftSessions()
            // Sessions panel stays expanded by default after the store finishes
            // loading (including empty first-run). Users can still collapse via
            // the header chevron / ⌘S; other sidebar items still hide the panel.
            self.isCodingAgentPanelExpanded = true
        }
        writeOpenAIFastModeConfig()
        configurePiAgentIdleParking()
        // First-frame refresh: only scan global + the last-selected project
        // (cheap). Defer memory embedder warm-up, model catalog, and full-project
        // scan until after the initial snapshot lands so launch CPU/disk do not
        // compete with first paint.
        let initialExtras: Set<String> = selectedProjectPath.map { [$0] } ?? []
        refresh(includeModels: false, scanAllProjects: false, extraProjectPathsToScan: initialExtras)
        Task { @MainActor [weak self] in
            // Wait until the first refresh applied (or a short timeout) before
            // heavier follow-up work.
            for _ in 0..<40 {
                guard let self, !self.didShutdown else { return }
                if self.hasCompletedInitialRefresh { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard let self, !self.didShutdown else { return }
            self.warmMemoryEmbedder()
            self.refresh(includeModels: true, scanAllProjects: true, silentlyReconcile: true)
        }
        piAgentRunner.onTurnFinished = { [weak self] sessionID in
            Task { @MainActor in self?.handlePiAgentTurnFinished(sessionID) }
        }
        piAgentRunner.onSessionLaunched = { [weak self] sessionID in
            Task { @MainActor in await self?.recordCurrentLaunchResourceFingerprint(sessionID: sessionID) }
        }
        piAgentRunner.onManagedSubagentRequest = { [weak self] sessionID, request, completion in
            Task { @MainActor in
                await self?.runManagedNativeSubagent(parentSessionID: sessionID, request: request, completion: completion)
            }
        }
        piAgentRunner.onManagedParallelRequest = { [weak self] sessionID, request, completion in
            Task { @MainActor in
                await self?.runManagedNativeParallel(parentSessionID: sessionID, request: request, completion: completion)
            }
        }
        piAgentRunner.onSupervisorRequestsList = { [weak self] sessionID in
            self?.pendingSupervisorRequestsJSON(parentSessionID: sessionID) ?? "[]"
        }
        piAgentRunner.onSupervisorRequestAnswer = { [weak self] sessionID, requestID, response in
            self?.answerSupervisorRequestFromParentAgent(parentSessionID: sessionID, requestID: requestID, response: response) ?? "\(AppBrand.displayName) could not route the supervisor response."
        }
        piAgentRunner.onSessionPlanSet = { [weak self] sessionID, request in
            self?.setSessionPlanFromParentAgent(sessionID: sessionID, request: request) ?? "\(AppBrand.displayName) could not update the session plan."
        }
        piAgentRunner.onSessionPlanUpdate = { [weak self] sessionID, request in
            self?.updateSessionPlanFromParentAgent(sessionID: sessionID, request: request) ?? "\(AppBrand.displayName) could not update the session plan."
        }
        piAgentRunner.nativeSubagentCatalogProvider = { [weak self] session in
            self?.nativeSubagentCatalogPrompt(for: session)
        }
        piAgentRunner.mcpCatalogProvider = { [weak self] session in
            await self?.mcpCatalogPrompt(for: session)
        }
        piAgentRunner.onMCPBridgeRequest = { [weak self] sessionID, request, completion in
            guard let self else { completion("\(AppBrand.displayName)'s MCP bridge is not available."); return }
            self.handleMCPBridge(sessionID: sessionID, request: request, completion: completion)
        }
        piAgentRunner.parentSkillArgumentsProvider = { [weak self] projectURL in
            try self?.parentSkillArguments(for: projectURL) ?? []
        }
        piAgentRunner.agentDeckBuilderSkillArgumentsProvider = { [weak self] in
            self?.agentDeckBuilderSkillArguments() ?? []
        }
        piAgentRunner.parentPromptTemplateArgumentsProvider = { [weak self] projectURL in
            try self?.parentPromptTemplateArguments(for: projectURL) ?? []
        }
        piAgentRunner.parentMemoryAppendPromptsProvider = { [weak self] session, initialPrompt in
            await self?.parentMemoryAppendPrompts(for: session, initialPrompt: initialPrompt) ?? []
        }
        piAgentRunner.boundAgentProvider = { [weak self] session in
            self?.boundAgent(for: session)
        }
        piAgentRunner.boundAgentSkillArgumentsProvider = { [weak self] agent in
            try self?.boundAgentSkillArguments(for: agent) ?? []
        }
        piAgentRunner.onMemoryWrite = { [weak self] sessionID, request in
            await self?.handleParentMemoryWrite(sessionID: sessionID, request: request) ?? "\(AppBrand.displayName) memory is not available."
        }
        piAgentRunner.onMemoryMarkStale = { [weak self] sessionID, request in
            await self?.handleParentMemoryMarkStale(sessionID: sessionID, request: request) ?? "\(AppBrand.displayName) memory is not available."
        }
        piAgentRunner.onMemorySearch = { [weak self] sessionID, request in
            await self?.handleParentMemorySearch(sessionID: sessionID, request: request) ?? "\(AppBrand.displayName) memory is not available."
        }
        nativeSubagentRunner.childMemoryArgumentsProvider = { [weak self] parentSession, agent, task in
            await self?.childMemoryLaunchContext(for: parentSession, agent: agent, task: task) ?? .empty
        }
        nativeSubagentRunner.childSkillArgumentsProvider = { [weak self] agent, snapshot in
            try self?.childSkillArguments(for: agent, snapshot: snapshot) ?? PiSkillLaunchResolver.childSkillArguments(agent: agent, snapshot: snapshot)
        }
        nativeSubagentRunner.childMCPArgumentsProvider = { [weak self] parentSession, agent in
            await self?.childMCPArguments(for: parentSession, agent: agent) ?? []
        }
        nativeSubagentRunner.onMCPBridgeRequest = { [weak self] parentSessionID, runID, agentName, request in
            await self?.handleSubagentMCPBridge(parentSessionID: parentSessionID, runID: runID, agentName: agentName, request: request) ?? "\(AppBrand.displayName)'s MCP bridge is not available."
        }
        nativeSubagentRunner.onMemoryWrite = { [weak self] parentSessionID, runID, agentName, request in
            await self?.handleSubagentMemoryWrite(parentSessionID: parentSessionID, runID: runID, agentName: agentName, request: request) ?? "\(AppBrand.displayName) memory is not available."
        }
        nativeSubagentRunner.onMemoryMarkStale = { [weak self] parentSessionID, runID, agentName, request in
            await self?.handleSubagentMemoryMarkStale(parentSessionID: parentSessionID, runID: runID, agentName: agentName, request: request) ?? "\(AppBrand.displayName) memory is not available."
        }
        nativeSubagentRunner.onMemorySearch = { [weak self] parentSessionID, runID, agentName, request in
            await self?.handleSubagentMemorySearch(parentSessionID: parentSessionID, runID: runID, agentName: agentName, request: request) ?? "\(AppBrand.displayName) memory is not available."
        }
        registerAppNotificationObservers()
        startAutoRefresh()
        cleanupOrphanedNativeSubagentArtifacts()

    }

    deinit {
        mcpRefreshTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    func shutdown(recordTranscript: Bool) {
        guard !didShutdown else { return }
        didShutdown = true
        stopAutoRefresh(cancelPendingScan: true)
        refreshTask?.cancel()
        refreshTask = nil
        mcpRefreshTask?.cancel()
        mcpRefreshTask = nil
        launchResourceFingerprintTask?.cancel()
        launchResourceFingerprintTask = nil
        launchResourceFingerprintsBySessionID.removeAll()
        artifactCleanupTask?.cancel()
        artifactCleanupTask = nil
        for task in pendingPiAgentNotificationTasks.values {
            task.cancel()
        }
        pendingPiAgentNotificationTasks.removeAll()
        piSessionTitleGenerator.cancelAll()
        piAgentRunner.stopAll(recordTranscript: recordTranscript)
        nativeSubagentRunner.stopAll(recordTranscript: recordTranscript)
        projectServerService.terminateAll()
        nativeParallelSchedulersByID.removeAll()
    }

    private func cleanupOrphanedNativeSubagentArtifacts(retentionDays: Int = 30) {
        let referencedArtifactPaths = Set(piAgentSessionStore.subagentRunsBySessionID.values.flatMap { runs in
            runs.map(\.artifactDirectory).filter { !$0.isEmpty }
        })
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 24 * 60 * 60)
        artifactCleanupTask?.cancel()
        // No `[weak self]`: the body never touches `self`, so there's no
        // implicit strong capture. The AppViewModel can be deallocated while
        // this cleanup walks the directory; the task observes cancellation
        // via `Task.isCancelled` between entries.
        artifactCleanupTask = Task.detached {
            let fileManager = FileManager.default
            let appSupport = URL.applicationSupportDirectory
            let runsDirectory = appSupport.appendingPathComponent("\(AppBrand.displayName)", isDirectory: true).appendingPathComponent("Subagent Runs", isDirectory: true)
            guard let entries = try? fileManager.contentsOfDirectory(at: runsDirectory, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]) else { return }
            for url in entries {
                if Task.isCancelled { return }
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
                guard values?.isDirectory == true,
                      !referencedArtifactPaths.contains(url.path),
                      (values?.contentModificationDate ?? .distantFuture) < cutoff else { continue }
                try? fileManager.removeItem(at: url)
            }
        }
    }

    /// `silentlyReconcile`: when true, skip toggling `isRefreshingProjects`.
    /// Use this from "patch then refresh" callers — `setSkill`, `deleteSkill`,
    /// `saveAgentDraft`, etc. — where the visible state has already been
    /// updated in-memory and the background scan is just confirming. Without
    /// this, the list dims + disables for the duration of the scan even
    /// though it shows the correct state already, which reads as a long wait
    /// after every toggle. Structural refreshes (project switch, initial
    /// load) leave the default so the spinner + disabled state still appear.

    /// Patch the in-memory effective-agent skill list so snapshot-derived
    /// toggles (`skill(_:isAssignedTo:)`) update immediately after a draft
    /// save, without waiting for a disk rescan.

    func isPiAgentSessionRunning(_ sessionID: UUID) -> Bool {
        piAgentRunner.isRunning(sessionID: sessionID)
    }



    /// Bumped by the Extensions toolbar Refresh action; the screen keys its
    /// off-main discovery `.task` on this so a Refresh re-scans without a project change.
    var piExtensionsRefreshToken = 0


    // MCP screen toolbar triggers (the toolbar lives in ContentView; the screen reacts
    // to these via .onChange).
    var mcpAddRequestToken = 0
    var mcpRefreshRequestToken = 0

}
