import AppKit
import Combine
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

@MainActor
final class NativeSubagentCompletionGate {
    private(set) var isCompleted = false

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
    private(set) var discoveredProjectsRevision: Int = 0
    /// O(1) lookup mirror of `discoveredProjects`. Use this from view bodies
    /// (e.g. `PiAgentSessionRow`'s project lookup) instead of `.first(where:)`,
    /// which would walk the array per row per render.
    private(set) var projectByPath: [String: DiscoveredProject] = [:]
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
    @ObservationIgnored private var loopDefinitionStore = LoopDefinitionStore()

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
    private(set) var cachedHasAgentWarnings = false
    private(set) var cachedHasSkillWarnings = false
    private(set) var cachedHasPromptWarnings = false
    private(set) var cachedSkillWarnings: [DiagnosticWarning] = []
    private(set) var cachedPromptWarnings: [DiagnosticWarning] = []
    private(set) var cachedSkillReferenceWarnings: [SkillReferenceWarning] = []
    private(set) var cachedSkillVisibilityIssuesByAgentID: [String: [AgentSkillVisibilityIssue]] = [:]
    // Automation-model lookup is cached. `FoundationModelAutomationService`
    // queries Apple's Foundation Models availability API, and the Pi Agent
    // toolbar reads `automationAvailableModels` on every `ContentView.body`
    // eval (i.e. once per streaming token). The result only changes at real
    // boundaries — see `rebuildModelCaches()`.
    private(set) var cachedFoundationAutomationModel: AvailableModel?
    private(set) var cachedEnabledAvailableModels: [AvailableModel] = []
    private(set) var cachedAvailableModelByIdentifier: [String: AvailableModel] = [:]
    private(set) var cachedEnabledAvailableModelByIdentifier: [String: AvailableModel] = [:]
    private(set) var cachedEnabledAvailableModelByModel: [String: AvailableModel] = [:]
    private(set) var cachedDisplayModels: [AvailableModel] = []
    private(set) var cachedGroupedDisplayModels: [(provider: String, models: [AvailableModel])] = []
    private(set) var cachedAutomationAvailableModels: [AvailableModel] = []
    private(set) var cachedAutomationAvailableModelByIdentifier: [String: AvailableModel] = [:]
    @ObservationIgnored var modelCacheRevision: Int = 0
    @ObservationIgnored var cachedDefaultPiAgentModelLookup: (provider: String?, model: String?, modelRevision: Int, result: AvailableModel?)?
    // Agent-list caches — the `allDisplayAgents` chain (a 4-source merge + sort)
    // and per-agent warnings were recomputed on every `AgentsScreen` /
    // `ContentView` body evaluation. Rebuilt inside `rebuildWarningCaches()`,
    // alongside `cachedSkillVisibilityIssuesByAgentID` — so they refresh on
    // exactly the same events (every data rescan) and can't go stale.
    private(set) var cachedAllDisplayAgents: [EffectiveAgentRecord] = []
    // O(1) selection lookup. Sourced from `cachedAllDisplayAgents` in
    // `rebuildWarningCaches()`; lets `selectedAgent` resolve without touching
    // `filteredAgents` / `catalogOnlyEffectiveAgents` / `libraryOnlyEffectiveAgents`
    // on every body read.
    private(set) var cachedDisplayAgentByID: [EffectiveAgentRecord.ID: EffectiveAgentRecord] = [:]
    // Bumped whenever the display-agent caches rebuild. Cheap `Int` signal for
    // `.onChange` so views don't pay an `Equatable` pass over the full agent
    // array every body eval just to detect changes.
    private(set) var displayAgentsRevision: Int = 0
    private(set) var cachedAgentWarningsByID: [EffectiveAgentRecord.ID: [DiagnosticWarning]] = [:]
    /// Lowercased search haystacks for `AgentLibraryPane`. Built from the exact
    /// fields the pane searches (name, description, resolution kind, source
    /// path, system prompt) when display-agent caches rebuild, so typing in the
    /// search field doesn't lowercase large prompts on every filter pass.
    private(set) var cachedAgentSearchHaystackByID: [EffectiveAgentRecord.ID: String] = [:]
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
    private(set) var cachedSkillMetadataByID: [SkillRecord.ID: SkillListMetadata] = [:]
    // Per-skill matching diagnostic warnings — precomputed alongside the
    // `hasWarnings` flag so the skill detail pane doesn't re-scan
    // `skillWarnings` with four string-contains checks per render. Empty
    // entry for any skill without warnings (cache-hit is authoritative).
    private(set) var cachedWarningsBySkillID: [SkillRecord.ID: [DiagnosticWarning]] = [:]
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
    private let envPersistence = EnvPersistence()
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
    private var autoRefreshCancellable: AnyCancellable?
    private var watchFingerprintTask: Task<Void, Never>?
    private var watchEventDebounceTask: Task<Void, Never>?
    private var deferredWatchRefreshTask: Task<Void, Never>?
    private var fileWatchEventMonitor: FileWatchEventMonitor?
    var lastWatchFingerprint: String = ""
    var watchedURLsForAutoRefresh: [URL] = []
    var refreshTask: Task<Void, Never>?
    var refreshRequestID = 0
    var launchResourceFingerprintTask: Task<Void, Never>?
    var launchResourceFingerprintsBySessionID: [UUID: String] = [:]
    private var isRefreshingModels = false
    var repositoryChangesRequestID = 0
    var repositoryDiffRequestID = 0
    var repositoryDiffCache: [GitDiffCacheKey: String] = [:]
    var repositoryDiffCacheOrder: [GitDiffCacheKey] = []
    let repositoryDiffCacheLimit = 64
    let repositoryChangesCacheLifetime: TimeInterval = 5
    private let watchEventDebounceNanoseconds: UInt64 = 1_000_000_000
    private let watchRefreshQuietNanoseconds: UInt64 = 1_200_000_000
    private let fallbackAutoRefreshInterval: TimeInterval = 300
    var nativeParallelSchedulersByID: [UUID: NativeParallelGraphScheduler] = [:]
    let lastSelectedProjectDefaultsKey = "lastSelectedProjectPath"
    var pendingPiAgentNotificationTasks: [UUID: Task<Void, Never>] = [:]
    /// In-flight first-send worktree provisioning, shared per session so a
    /// rapid second send awaits the same task instead of provisioning twice.
    @ObservationIgnored var worktreeProvisionTasksBySessionID: [UUID: Task<Void, Never>] = [:]
    private var artifactCleanupTask: Task<Void, Never>?
    private var didShutdown = false

    var piAgentNotificationDelay: TimeInterval {
        TimeInterval(piAgentNotificationDelayMinutes * 60)
    }

    private var piAgentIdleParkingTimeout: TimeInterval? {
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

    private func shutdown(recordTranscript: Bool) {
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
    func chooseProjectRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = LanguageStore.shared.t("vm.addProject")
        panel.message = LanguageStore.shared.t("vm.addProjectMessage", AppBrand.displayName)

        guard panel.runModal() == .OK, let url = panel.url else { return }
        addProject(url, selectingAfterAdd: true)
    }

    /// The folder the skill-import picker opens to. Skill catalogs are global
    /// or explicit imports only, so default to Pi's global skills folder rather
    /// than project-local `.pi/skills` folders.

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


    func syncAppSettings() {
        appSettings = appSettingsController.settings
        // Keep process-wide pi resolution pinned to Settings without rescanning PATH.
        PiExecutableResolver.setPreferredPath(appSettings.piExecutablePath)
        writeOpenAIFastModeConfig()
        configurePiAgentIdleParking()
    }

    private func writeOpenAIFastModeConfig() {
        // This view model is main-actor isolated. Writing this tiny config here,
        // rather than from detached tasks, preserves the order of rapid toggles.
        PiNativeSubagentBridgeExtensions.writeOpenAIFastConfig(
            isEnabled: appSettings.openAIFastEnabled
        )
    }

    private func configurePiAgentIdleParking() {
        piAgentRunner.configureIdleParking(timeout: piAgentIdleParkingTimeout)
    }


    func handleProjectsRootSettingsChange() {
        syncAppSettings()
        refresh(includeModels: false)
        refreshRepositoryProjectScopedState()
    }

    private func registerAppNotificationObservers() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(handlePiAgentNotificationResponse(_:)), name: .piAgentNotificationResponse, object: nil)
        center.addObserver(self, selector: #selector(handleAppDidBecomeActiveNotification(_:)), name: NSApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(handleAppWillResignActiveNotification(_:)), name: NSApplication.willResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(handleAppWillTerminateNotification(_:)), name: NSApplication.willTerminateNotification, object: nil)
    }

    @objc private func handlePiAgentNotificationResponse(_ notification: Notification) {
        guard let rawSessionID = notification.userInfo?["sessionID"] as? String,
              let sessionID = UUID(uuidString: rawSessionID) else { return }
        if let rawWindowID = notification.userInfo?["windowID"] as? String,
           let notificationWindowID = UUID(uuidString: rawWindowID),
           notificationWindowID != windowID {
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.selectPiAgentSession(sessionID)
            NSApp.activate(ignoringOtherApps: true)
            NSApp.mainWindow?.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func handleAppDidBecomeActiveNotification(_ notification: Notification) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Re-sample Foundation Model availability — it may have changed
            // (model finished downloading) while the app was inactive.
            self.rebuildModelCaches()
            self.startAutoRefresh()
            self.refreshIfWatchedFilesChanged()
            self.acknowledgeVisibleSelectedPiAgentSession()
            if self.selectedSidebarItem == .agent && self.shouldShowPiAgentGitActions {
                self.prepareRepoChangesForSelectedPiAgentSession()
            }
        }
    }

    @objc private func handleAppWillResignActiveNotification(_ notification: Notification) {
        stopAutoRefresh(cancelPendingScan: true)
    }

    @objc private func handleAppWillTerminateNotification(_ notification: Notification) {
        shutdown(recordTranscript: false)
        piAgentSessionStore.flushPendingSave()
        // Best-effort teardown of MCP server subprocesses on quit.
        Task { await shutdownMCP() }
    }

    var areSubagentsEnabledForNewSessions: Bool {
        appSettingsController.areSubagentsEnabledForNewSessions
    }

    func setSubagentsEnabledForNewSessions(_ isEnabled: Bool) {
        guard appSettingsController.setSubagentsEnabledForNewSessions(isEnabled) else { return }
        syncAppSettings()
        piAgentSessionStore.newSessionSubagentsEnabled = isEnabled
    }

    func setNativeSubagentDelegationPolicy(_ policy: NativeSubagentDelegationPolicy) {
        guard appSettingsController.setNativeSubagentDelegationPolicy(policy) else { return }
        syncAppSettings()
    }

    func toggleSubagentsForNewSessions() {
        guard appSettingsController.toggleSubagentsForNewSessions() else { return }
        syncAppSettings()
        piAgentSessionStore.newSessionSubagentsEnabled = appSettings.nativeSubagentsEnabledForNewSessions
    }

    func setSubagentsEnabledForSelectedSession(_ isEnabled: Bool) {
        guard let session = piAgentSessionStore.selectedSession else { return }
        setSubagentsEnabled(isEnabled, forSessionID: session.id)
    }

    func setSubagentsEnabled(_ isEnabled: Bool, forSessionID sessionID: UUID) {
        piAgentSessionStore.updateSession(sessionID, bumpUpdatedAt: false) { session in
            session.subagentsEnabled = session.isNoProject ? false : isEnabled
            if session.isNoProject {
                session.agentSelection = nil
            }
        }
        reconcileRunningSessionLaunchResourceFingerprints()
    }

    /// Draft-only footer control: before the first launch, subagents act like a
    /// session default. Update both the selected draft and the default for new
    /// sessions. Once Pi has started, the footer becomes read-only.
    func setSubagentsEnabledForSelectedDraftAndNewSessions(_ isEnabled: Bool) {
        guard let session = piAgentSessionStore.selectedSession, session.status == .draft else {
            setSubagentsEnabledForNewSessions(isEnabled)
            return
        }
        guard !session.isNoProject else {
            piAgentSessionStore.updateSession(session.id, bumpUpdatedAt: false) { session in
                session.subagentsEnabled = false
                session.agentSelection = nil
            }
            return
        }
        setSubagentsEnabledForNewSessions(isEnabled)
        piAgentSessionStore.updateSession(session.id, bumpUpdatedAt: false) { session in
            session.subagentsEnabled = isEnabled
        }
    }

    /// Persists a session's per-session subagent selection. `nil` restores the
    /// default (all effective agents); a non-nil set pins an explicit choice.
    /// Cached — see `cachedAllDisplayAgents`. Rebuilt by `rebuildWarningCaches()`.

    var selectedProjectName: String {
        projectRootURL?.lastPathComponent ?? LanguageStore.shared.t("vm.noProjectSelected")
    }

    var configuredProjectsRootURLs: [URL] {
        appSettingsController.configuredProjectsRootURLs
    }

    var configuredProjectsRootPaths: [String] {
        appSettingsController.configuredProjectsRootPaths
    }

    var primaryProjectsRootURL: URL {
        appSettingsController.primaryProjectsRootURL
    }

    var primaryProjectsRootPath: String {
        appSettingsController.primaryProjectsRootPath
    }

    var suggestedProjectsRootPath: String? {
        appSettingsController.suggestedProjectsRootURL?.path
    }

    var hasConfirmedProjectsRootPaths: Bool {
        appSettingsController.hasConfirmedProjectsRootPaths
    }

    var enabledProjects: [DiscoveredProject] {
        discoveredProjects.filter { projectPreference(for: $0.path).isEnabled }
    }

    var gitHubProjects: [DiscoveredProject] {
        enabledProjects.filter(\.isGitHubRepository)
    }

    var selectedDiscoveredProject: DiscoveredProject? {
        guard let selectedProjectPath else { return nil }
        return projectByPath[selectedProjectPath]
    }

    var selectedGitHubProject: DiscoveredProject? {
        guard let selectedDiscoveredProject, selectedDiscoveredProject.isGitHubRepository else { return nil }
        return selectedDiscoveredProject
    }

    var shouldWarnProjectSelection: Bool {
        enabledProjects.isEmpty
    }

    var shouldWarnDoctor: Bool {
        !hasConfirmedProjectsRootPaths
            || !configuredProjectsRootsExist
            || !snapshot.warnings.isEmpty
    }

    /// True only when every configured projects-root entry resolves to an
    /// existing directory. Empty list ⇒ warn.
    private var configuredProjectsRootsExist: Bool {
        let urls = configuredProjectsRootURLs
        guard !urls.isEmpty else { return false }
        return urls.allSatisfy { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }

    var hasAgentWarnings: Bool {
        cachedHasAgentWarnings
    }

    var hasSkillWarnings: Bool {
        cachedHasSkillWarnings
    }

    var hasPromptWarnings: Bool {
        cachedHasPromptWarnings
    }

    var skillWarnings: [DiagnosticWarning] {
        cachedSkillWarnings
    }

    var promptWarnings: [DiagnosticWarning] {
        cachedPromptWarnings
    }

    var skillReferenceWarnings: [SkillReferenceWarning] {
        guard !pendingDeletedSkillIDs.isEmpty else { return cachedSkillReferenceWarnings }
        // The cached warnings are rebuilt only on refresh, so for the ~1s until
        // the background scan lands they can still cite a skill the user just
        // deleted. Drop those so the warnings card matches the visible list.
        let names = Set((snapshot.skills + snapshot.librarySkills)
            .filter { pendingDeletedSkillIDs.contains($0.id) }
            .map(\.name))
        return cachedSkillReferenceWarnings.filter { !names.contains($0.missingSkill) }
    }

    func piAgentSessionProjectContext() -> DiscoveredProject {
        if let selectedDiscoveredProject {
            return selectedDiscoveredProject
        }

        let rootURL = primaryProjectsRootURL
        let rootName = rootURL.lastPathComponent.isEmpty ? rootURL.path : rootURL.lastPathComponent
        return DiscoveredProject(
            url: rootURL,
            gitHubRemote: nil,
            isGitRepository: false,
            iconFileURL: nil,
            projectType: .unknown,
            fallbackSymbolName: ProjectType.unknown.sfSymbolFallback,
            searchIndex: [rootName, rootURL.path].joined(separator: "\n").lowercased()
        )
    }

    var availableModelProviders: [String] {
        Array(Set(enabledAvailableModels.map(\.provider)))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var totalProjectWarnings: Int {
        let enabledProjectPaths = Set(enabledProjects.map(\.path))
        return allProjectSnapshots
            .filter { enabledProjectPaths.contains($0.key) }
            .values
            .reduce(0) { $0 + $1.warnings.count }
    }


    /// the user saves the editor sheet, so cancelling creates nothing.

    func makeNewLibrarySkillDraft() -> NewSkillDraft {
        .init(
            name: nextAvailableSkillName(),
            description: "",
            body: "Document the skill instructions here."
        )
    }

    func newLibrarySkillPath(for name: String) -> String {
        let skillsRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/skills", isDirectory: true)
        return skillsRoot
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent("SKILL.md")
            .path
    }

    func saveNewLibrarySkill(_ draft: NewSkillDraft) throws {
        let name = try validateNewSkillName(draft.name)
        let description = draft.description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else {
            throw ResourceRenameError.invalidName("Description cannot be empty.")
        }

        let body = draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Document the skill instructions here."
            : draft.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = """
        ---
        name: \(name)
        description: \(description)
        ---

        # \(name)

        \(body)
        """

        let fileURL = URL(fileURLWithPath: newLibrarySkillPath(for: name))
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// Computes the path and seed content for a brand-new library skill
    /// (`~/.pi/agent/skills/<name>/SKILL.md`) without touching the disk. The
    /// folder and `SKILL.md` are written only when the user saves the editor
    /// sheet, so cancelling creates nothing — matching the agent editor, where
    /// nothing is stored until Save.
    func newLibrarySkillDraft() -> (path: String, seedContent: String) {
        let fileManager = FileManager.default
        let skillsRoot = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/skills", isDirectory: true)
        let candidate = nextAvailableSkillName()
        let url = skillsRoot
            .appendingPathComponent(candidate, isDirectory: true)
            .appendingPathComponent("SKILL.md")
        let text = """
        ---
        name: \(candidate)
        description: Describe what this skill does and when Pi should use it.
        ---

        # \(candidate)

        Document the skill instructions here.
        """
        return (url.path, text)
    }

    private func nextAvailableSkillName() -> String {
        let fileManager = FileManager.default
        let skillsRoot = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/skills", isDirectory: true)
        var candidate = "new-skill"
        var index = 2
        while fileManager.fileExists(atPath: skillsRoot.appendingPathComponent(candidate, isDirectory: true).path) {
            candidate = "new-skill-\(index)"
            index += 1
        }
        return candidate
    }

    private func validateNewSkillName(_ requestedName: String) throws -> String {
        let name = try ResourceRenameSupport.normalizedName(requestedName)
        let pattern = /^[a-z0-9]+(?:-[a-z0-9]+)*$/
        guard name.wholeMatch(of: pattern) != nil else {
            throw ResourceRenameError.invalidName("Skill name must use lowercase letters, numbers, and single hyphens only.")
        }

        let fileURL = URL(fileURLWithPath: newLibrarySkillPath(for: name))
        guard !FileManager.default.fileExists(atPath: fileURL.deletingLastPathComponent().path) else {
            throw ResourceRenameError.destinationExists(fileURL.deletingLastPathComponent().path)
        }
        return name
    }

    /// switches.
    /// never per view body evaluation.
    func rebuildModelCaches() {
        let foundation = FoundationModelAutomationService.availableModel()
        let disabledProviders = appSettings.disabledProviders
        let disabledIdentifiers = appSettings.disabledModelIdentifiers

        var allByIdentifier: [String: AvailableModel] = [:]
        for model in availableModels where allByIdentifier[model.identifier] == nil {
            allByIdentifier[model.identifier] = model
        }
        if let foundation, allByIdentifier[foundation.identifier] == nil {
            allByIdentifier[foundation.identifier] = foundation
        }

        let enabled = availableModels.filter { model in
            !disabledProviders.contains(model.provider) && !disabledIdentifiers.contains(model.identifier)
        }
        var enabledByIdentifier: [String: AvailableModel] = [:]
        var enabledByModel: [String: AvailableModel] = [:]
        for model in enabled {
            if enabledByIdentifier[model.identifier] == nil { enabledByIdentifier[model.identifier] = model }
            if enabledByModel[model.model] == nil { enabledByModel[model.model] = model }
        }

        var displayModels = availableModels
        if let foundation,
           !displayModels.contains(where: { $0.identifier == foundation.identifier }) {
            displayModels.insert(foundation, at: 0)
        }

        var automationModels = enabled
        if let foundation,
           !automationModels.contains(where: { $0.identifier == foundation.identifier }) {
            automationModels.insert(foundation, at: 0)
        }

        cachedFoundationAutomationModel = foundation
        cachedEnabledAvailableModels = enabled
        cachedAvailableModelByIdentifier = allByIdentifier
        cachedEnabledAvailableModelByIdentifier = enabledByIdentifier
        cachedEnabledAvailableModelByModel = enabledByModel
        cachedDisplayModels = displayModels
        cachedGroupedDisplayModels = Dictionary(grouping: displayModels, by: \.provider)
            .map { provider, models in
                (provider, models.sorted { $0.model.localizedCaseInsensitiveCompare($1.model) == .orderedAscending })
            }
            .sorted { lhs, rhs in
                if lhs.provider == FoundationModelAutomationService.provider { return true }
                if rhs.provider == FoundationModelAutomationService.provider { return false }
                return lhs.provider.localizedCaseInsensitiveCompare(rhs.provider) == .orderedAscending
            }
        cachedAutomationAvailableModels = automationModels
        cachedAutomationAvailableModelByIdentifier = Dictionary(uniqueKeysWithValues: automationModels.map { ($0.identifier, $0) })
        modelCacheRevision &+= 1
        cachedDefaultPiAgentModelLookup = nil
    }

    func rebuildExternalSkillPathCache() {
        cachedStandardizedExternalSkillPaths = Set(
            appSettings.externalSkillPaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        )
    }

    func rebuildWarningCaches() {
        // Rebuild the agent-display cache first — the warning computations below
        // read `filteredAgents`, which derives from `allDisplayAgents`.
        cachedAllDisplayAgents = computeAllDisplayAgents()
        cachedDisplayAgentByID = Dictionary(uniqueKeysWithValues: cachedAllDisplayAgents.map { ($0.id, $0) })
        cachedAgentSearchHaystackByID = Dictionary(uniqueKeysWithValues: cachedAllDisplayAgents.map { ($0.id, agentSearchHaystack(for: $0)) })
        displayAgentsRevision &+= 1
        rebuildVisibleSkillRecordCachesIfNeeded()

        let skillWarnings = buildSkillWarnings()
        let promptWarnings = buildPromptWarnings()
        let visibilityIssuesByAgentID = buildSkillVisibilityIssuesByAgentID()
        let agentNamesByID = Dictionary(uniqueKeysWithValues: filteredAgents.map { ($0.id, $0.name) })
        let skillReferenceWarnings: [SkillReferenceWarning] = visibilityIssuesByAgentID
            .flatMap { pair -> [SkillReferenceWarning] in
                guard let agentName = agentNamesByID[pair.key] else { return [] }
                return pair.value.flatMap { issue in
                    issue.missingSkills.map { missingSkill in
                        SkillReferenceWarning(agentName: agentName, project: issue.project, missingSkill: missingSkill)
                    }
                }
            }
            .sorted(by: {
                if $0.missingSkill != $1.missingSkill { return $0.missingSkill < $1.missingSkill }
                if $0.agentName != $1.agentName { return $0.agentName < $1.agentName }
                return $0.project.name < $1.project.name
            })

        // Per-agent warnings — computed once here instead of O(agents × warnings)
        // on every AgentsScreen body eval. Every filtered agent gets an entry
        // (possibly empty), so a cache hit in `warnings(for:)` is authoritative.
        var agentWarningsByID: [EffectiveAgentRecord.ID: [DiagnosticWarning]] = [:]
        for agent in filteredAgents {
            agentWarningsByID[agent.id] = computeWarnings(for: agent)
        }

        // Per-skill list metadata — computed once here instead of
        // O(skills × warnings/projects/agents) on every SkillsScreen body eval.
        // Also collects the matching warnings per skill so the detail pane
        // doesn't re-run the four string-contains checks across `skillWarnings`
        // on every render.
        var skillMetadataByID: [SkillRecord.ID: SkillListMetadata] = [:]
        var warningsBySkillID: [SkillRecord.ID: [DiagnosticWarning]] = [:]
        // Resource catalog is always global; "active" = globally enabled (the
        // global-view definition), independent of `selectedProjectPath`.
        let activeProject: DiscoveredProject? = nil
        for record in allVisibleSkillRecords {
            let matchingWarnings = skillWarnings.filter { warning in
                warning.id == "duplicate-skill:\(record.name)" ||
                warning.id.contains(record.filePath) ||
                warning.message.contains("`\(record.name)`") ||
                warning.message.contains(record.filePath)
            }
            let hasWarnings = !matchingWarnings.isEmpty
            warningsBySkillID[record.id] = matchingWarnings
            let globallyEnabled = skillIsEnabledGlobally(record)
            let isAssigned = globallyEnabled ||
                !assignedProjects(for: record).isEmpty ||
                !assignedAgents(for: record).isEmpty
            let isActive = globallyEnabled ||
                (activeProject.map { skill(record, isEnabledFor: $0) } ?? false)
            skillMetadataByID[record.id] = SkillListMetadata(
                isAssigned: isAssigned,
                hasWarnings: hasWarnings,
                isActiveForCurrentProject: isActive,
                isImported: isImportedSkill(record)
            )
        }

        cachedSkillWarnings = skillWarnings
        cachedPromptWarnings = promptWarnings
        cachedSkillVisibilityIssuesByAgentID = visibilityIssuesByAgentID
        cachedSkillReferenceWarnings = skillReferenceWarnings
        cachedAgentWarningsByID = agentWarningsByID
        cachedSkillMetadataByID = skillMetadataByID
        cachedWarningsBySkillID = warningsBySkillID
        cachedHasSkillWarnings = !skillReferenceWarnings.isEmpty || !skillWarnings.isEmpty
        cachedHasPromptWarnings = !promptWarnings.isEmpty
        cachedHasAgentWarnings = agentWarningsByID.values.contains { !$0.isEmpty }
            || visibilityIssuesByAgentID.values.contains { !$0.isEmpty }
    }

    private func buildSkillWarnings() -> [DiagnosticWarning] {
        let baseWarnings = globalSnapshot.warnings.filter { warning in
            warning.id.hasPrefix("malformed-skill:") || warning.message.localizedCaseInsensitiveContains("skill")
        }
        let collisionWarnings = PiSkillLaunchResolver.collisions(in: allVisibleSkillRecords).map { collision in
            let paths = collision.skills.map(\.filePath).joined(separator: ", ")
            return DiagnosticWarning(id: "duplicate-skill:\(collision.name)", message: "Duplicate skill name `\(collision.name)` found at: \(paths)")
        }
        return baseWarnings + collisionWarnings
    }

    private func buildPromptWarnings() -> [DiagnosticWarning] {
        let baseWarnings = globalSnapshot.warnings.filter { warning in
            warning.id.hasPrefix("duplicate-prompt:")
        }
        let collisionWarnings = PiPromptTemplateLaunchResolver.collisions(in: allVisiblePromptTemplateRecords).map { collision in
            let paths = collision.prompts.map(\.filePath).joined(separator: ", ")
            return DiagnosticWarning(id: "duplicate-prompt-template:\(collision.name)", message: "Duplicate prompt template name `/\(collision.name)` found at: \(paths)")
        }
        return baseWarnings + collisionWarnings
    }

    private func buildSkillVisibilityIssuesByAgentID() -> [String: [AgentSkillVisibilityIssue]] {
        var issuesByAgentID: [String: [AgentSkillVisibilityIssue]] = [:]
        for agent in filteredAgents {
            guard !agent.resolved.skills.isEmpty else { continue }
            let explicitSkills = agent.resolved.skills
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !explicitSkills.isEmpty else { continue }

            let managedRecord = globalSnapshot.libraryAgents.first { $0.name == agent.name }
                ?? agent.globalCustom
                ?? agent.projectCustom
            guard let managedRecord else { continue }

            let issues: [AgentSkillVisibilityIssue] = assignedProjects(for: managedRecord).compactMap { project in
                // Match child launch resolution, which uses the centralized runtime
                // catalog rather than a potentially stale per-project scan snapshot.
                let missingSkills = PiSkillLaunchResolver.unresolvedNames(
                    explicitSkills,
                    catalog: skillCatalog(forProjectPath: project.path),
                    additionalResolvableNames: Set(appSettings.skillCollections.map(\.name))
                )
                guard !missingSkills.isEmpty else { return nil }
                return AgentSkillVisibilityIssue(project: project, missingSkills: missingSkills)
            }
            if !issues.isEmpty {
                issuesByAgentID[agent.id] = issues
            }
        }
        return issuesByAgentID
    }



    /// skills. Synchronous config read — call on a tap, not a hot path.
    func mcpRecap(for project: DiscoveredProject) -> ProjectMcpServerRecap {
        let defaultNames = appSettings.defaultMcpServerNames
        let projectNames = projectPreference(for: project.path).assignedMcpServerNames.subtracting(defaultNames)
        let entries = MCPConfigLoader().load(projectRoot: URL(fileURLWithPath: project.path)).servers
        let byName = Dictionary(entries.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

        func resolve(_ names: Set<String>) -> ([MCPServerRecapItem], [String]) {
            var items: [MCPServerRecapItem] = []
            var unresolved: [String] = []
            for name in names.sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }) {
                if let entry = byName[name] {
                    items.append(MCPServerRecapItem(name: name, detail: Self.mcpServerDetail(entry.config)))
                } else {
                    unresolved.append(name)
                }
            }
            return (items, unresolved)
        }

        let defaultResult = resolve(defaultNames)
        let projectResult = resolve(projectNames)
        return ProjectMcpServerRecap(
            defaultServers: defaultResult.0,
            projectServers: projectResult.0,
            unresolvedNames: (defaultResult.1 + projectResult.1).sorted()
        )
    }

    /// A short transport/endpoint summary for an MCP server config.
    private static func mcpServerDetail(_ config: MCPServerConfig) -> String? {
        switch config.resolvedTransport {
        case .stdio:
            guard let command = config.command, !command.isEmpty else { return "Local" }
            return "Local · \(command)"
        case .http, .sse:
            guard let url = config.url, !url.isEmpty else { return "Remote" }
            let host = URL(string: url)?.host(percentEncoded: false) ?? url
            return "Remote · \(host)"
        }
    }

    func agentRecap(for project: DiscoveredProject) -> ProjectAgentRecap {
        let defaultNames = appSettings.defaultAgentNames
        let projectNames = projectPreference(for: project.path).assignedAgentNames.subtracting(defaultNames)
        let effectiveAgents = (allProjectSnapshots[project.path]?.effectiveAgents ?? [])
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let effectiveByName = Dictionary(uniqueKeysWithValues: effectiveAgents.map { ($0.name, $0) })

        func resolvedAgents(for names: Set<String>) -> ([EffectiveAgentRecord], [String]) {
            var agents: [EffectiveAgentRecord] = []
            var unresolved: [String] = []
            for name in names.sorted() {
                if let agent = effectiveByName[name] {
                    agents.append(agent)
                } else {
                    unresolved.append(name)
                }
            }
            return (agents, unresolved)
        }

        let defaultResult = resolvedAgents(for: defaultNames)
        let projectResult = resolvedAgents(for: projectNames)
        let highlightedNames = Set(defaultResult.0.map(\.name)).union(projectResult.0.map(\.name))
        let otherEffectiveAgents = effectiveAgents.filter { !highlightedNames.contains($0.name) }
        return ProjectAgentRecap(
            defaultAgents: defaultResult.0,
            projectAgents: projectResult.0,
            otherEffectiveAgents: otherEffectiveAgents,
            unresolvedNames: (defaultResult.1 + projectResult.1).sorted()
        )
    }



    /// parent session is launched with (`parentPromptTemplateArguments`).

    func reloadLoopDefinitions() {
        loopDefinitions = loopDefinitionStore.loadDefinitions()
        if let selectedLoopDefinitionID,
           !loopDefinitions.contains(where: { $0.id == selectedLoopDefinitionID }) {
            self.selectedLoopDefinitionID = loopDefinitions.first?.id
        }
    }

    func loopDefinitionForLaunch(_ definition: LoopDefinition) -> LoopDefinition {
        guard definition.source == .user,
              let filePath = definition.filePath?.nonEmpty ?? definition.id.nonEmpty else {
            return definition
        }
        let url = URL(fileURLWithPath: filePath)
        guard FileManager.default.fileExists(atPath: url.path),
              let current = try? LoopDefinitionStore.decodeDefinition(at: url, source: .user) else {
            return definition
        }
        if let index = loopDefinitions.firstIndex(where: { $0.id == definition.id || $0.filePath == definition.filePath }) {
            loopDefinitions[index] = current
        }
        return current
    }

    var selectedLoopDefinition: LoopDefinition? {
        guard let selectedLoopDefinitionID else { return nil }
        return loopDefinitions.first { $0.id == selectedLoopDefinitionID }
    }

    func requestNewLoopDefinition() {
        newLoopRequestID = UUID()
    }

    @discardableResult
    func saveLoopDefinition(_ definition: LoopDefinition) throws -> LoopDefinition {
        let saved = try loopDefinitionStore.saveUserDefinition(definition)
        reloadLoopDefinitions()
        selectedLoopDefinitionID = saved.filePath ?? saved.id
        return saved
    }

    @discardableResult
    func duplicateLoopDefinition(_ definition: LoopDefinition) throws -> LoopDefinition {
        let saved = try loopDefinitionStore.duplicateUserDefinition(definition)
        reloadLoopDefinitions()
        selectedLoopDefinitionID = saved.filePath ?? saved.id
        return saved
    }

    func deleteLoopDefinition(_ definition: LoopDefinition) throws {
        try loopDefinitionStore.deleteUserDefinition(definition)
        reloadLoopDefinitions()
    }

    @discardableResult
    func saveLoopDefinitionFromRun(_ run: LoopRun) throws -> LoopDefinition {
        try saveLoopDefinitionFromDraft(
            loopDraft(from: run),
            request: LoopSaveRequest(
                name: defaultLoopSaveName(for: run),
                description: "Saved from completed loop run.",
                availability: run.projectPath?.isEmpty == false ? .projectPaths : .allProjects,
                projectPaths: run.projectPath.map { [$0] } ?? []
            )
        )
    }

    func retryLoopRun(_ run: LoopRun) {
        guard !run.isActive, run.status == .failed || run.presentsGoalNotMetOutcome || run.stopReason == .humanInputRequired || run.stopReason == .humanApproved else { return }
        guard let session = piAgentSessionStore.sessions.first(where: { $0.id == run.sessionID }) else { return }
        let draft = loopDraft(from: run)
        Task { @MainActor in
            _ = await launchLoop(session: session, draft: draft, stopExistingActive: false)
        }
    }

    private func loopDraft(from run: LoopRun) -> LoopDraft {
        LoopDraft(
            goal: run.goal,
            launchContext: run.launchContext,
            launchContextScope: run.launchContextScope,
            structure: run.structure,
            writeTarget: run.writeTarget,
            maxIterations: run.maxIterations,
            validationCommand: run.validationCommand,
            goalEvaluation: run.goalEvaluation,
            makerChecker: run.makerChecker,
            pipeline: run.pipeline,
            parallel: run.parallel,
            discoveryTriage: run.discoveryTriage,
            humanApproval: run.humanApproval
        )
    }

    private func defaultLoopSaveName(for run: LoopRun) -> String {
        let firstLine = run.goal.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Saved Loop" : String(trimmed.prefix(64))
    }

    @discardableResult
    func saveLoopDefinitionFromDraft(_ draft: LoopDraft, request: LoopSaveRequest) throws -> LoopDefinition {
        let projectPaths = request.availability == .projectPaths ? request.projectPaths : []
        let definition = LoopDefinition(
            name: request.name,
            description: request.description,
            goalTemplate: draft.goal,
            launchContext: draft.launchContext,
            launchContextScope: draft.launchContextScope,
            structure: draft.structure,
            writeTarget: draft.writeTarget,
            maxIterations: draft.maxIterations,
            validationCommand: draft.validationCommand,
            goalEvaluation: draft.goalEvaluation,
            makerChecker: draft.makerChecker,
            pipeline: draft.pipeline,
            parallel: draft.parallel,
            discoveryTriage: draft.discoveryTriage,
            humanApproval: draft.humanApproval,
            source: .user,
            availability: request.availability,
            projectPaths: projectPaths
        )
        let saved = try loopDefinitionStore.saveUserDefinition(definition)
        reloadLoopDefinitions()
        return saved
    }

    func configureLoopDefinitionStoreForTesting(directoryURL: URL) {
        loopDefinitionStore = LoopDefinitionStore(directoryURL: directoryURL)
        reloadLoopDefinitions()
    }

    func refreshedSlashItemForUse(_ item: SlashItem, projectPath: String?) -> SlashItem {
        switch item.payload {
        case .skill(let name, let body, let filePath, let recordID):
            let currentBody = latestSkillBody(name: name, filePath: filePath, recordID: recordID, projectPath: projectPath) ?? body
            return SlashItem(id: item.id, kind: item.kind, displayName: item.displayName, description: item.description, scopeLabel: item.scopeLabel, isActive: item.isActive, payload: .skill(name: name, body: currentBody, filePath: filePath, recordID: recordID))
        case .skillCollection(let id, let name, let body):
            guard let collection = appSettings.skillCollections.first(where: { $0.id == id }) else { return item }
            let currentBody = slashSkillCollectionBody(collection, forProjectPath: projectPath)
            return SlashItem(id: item.id, kind: item.kind, displayName: item.displayName, description: item.description, scopeLabel: item.scopeLabel, isActive: item.isActive, payload: .skillCollection(id: id, name: name, body: currentBody.isEmpty ? body : currentBody))
        case .prompt(let name, let body, let filePath, let recordID):
            let currentBody = latestPromptBody(name: name, filePath: filePath, recordID: recordID, projectPath: projectPath) ?? body
            return SlashItem(id: item.id, kind: item.kind, displayName: item.displayName, description: item.description, scopeLabel: item.scopeLabel, isActive: item.isActive, payload: .prompt(name: name, body: currentBody, filePath: filePath, recordID: recordID))
        case .loopDefinition(let definition):
            let currentDefinition = loopDefinitionForLaunch(definition)
            return SlashItem(id: item.id, kind: item.kind, displayName: item.displayName, description: item.description, scopeLabel: item.scopeLabel, isActive: item.isActive, payload: .loopDefinition(currentDefinition))
        case .command, .loopCreateNew:
            return item
        }
    }

    private func latestSkillBody(name: String, filePath: String?, recordID: String?, projectPath: String?) -> String? {
        if let filePath, let body = try? String(contentsOfFile: filePath, encoding: .utf8) { return body }
        let catalog = projectPath.flatMap { skillCatalog(forProjectPath: $0) } ?? globalSnapshot.skills
        return catalog.first { $0.id == recordID || $0.filePath == filePath || $0.name == name }?.body
    }

    private func latestPromptBody(name: String, filePath: String?, recordID: String?, projectPath: String?) -> String? {
        if let filePath, let body = try? String(contentsOfFile: filePath, encoding: .utf8) { return body }
        let catalog = projectPath.flatMap { promptTemplateCatalog(forProjectPath: $0) } ?? globalSnapshot.promptTemplates
        return catalog.first { $0.id == recordID || $0.filePath == filePath || $0.name == name }?.body
    }

    private func slashSkillCollectionBody(_ collection: SkillCollectionRecord, forProjectPath projectPath: String?, catalog providedCatalog: [SkillRecord]? = nil) -> String {
        let catalog = providedCatalog ?? projectPath.flatMap { skillCatalog(forProjectPath: $0) } ?? globalSnapshot.skills
        let members = skillRecords(in: collection, forProjectPath: projectPath)
            .filter { !skillIsExcludedFromRuntime($0, in: collection, catalog: catalog) }
        let memberList = members.map { "- `\($0.name)`" }.joined(separator: "\n")
        let description = collection.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        # \(collection.name)

        \(description?.isEmpty == false ? description! : "Skill collection")

        Included skills:
        \(memberList.isEmpty ? "- None" : memberList)
        """
    }

    /// Materializes the full universe of Skills, Prompts, Commands, and Loops the
    /// composer's `/` browser can show. Build once when the panel opens and hold
    /// the result in `@State` — never call inside a SwiftUI `body`.
    ///
    /// - Parameter runtimeSlashCommands: Pi `get_commands` for the active session
    ///   (extension registerCommand list + runtime skills/prompts). Merged so
    ///   user extensions appear in `/` even when not in Deck's Command Library.
    func slashUniverse(
        forProjectPath projectPath: String?,
        useSelectedProjectFallback: Bool = true,
        runtimeSlashCommands: [PiRuntimeSlashCommand]? = nil
    ) -> SlashUniverse {
        let fallback = useSelectedProjectFallback ? selectedProjectPath : nil
        let scopedPath = (projectPath ?? fallback)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        guard scopedPath != nil || useSelectedProjectFallback else { return .empty }
        let projectFeatureSlashEnabled = scopedPath != nil

        let runtime = runtimeSlashCommands ?? []
        let runtimeSkillNames: Set<String> = Set(runtime.compactMap { cmd in
            guard cmd.isSkill else { return nil }
            var bare = cmd.bareName
            if bare.hasPrefix("skill:") { bare = String(bare.dropFirst("skill:".count)) }
            return bare
        })
        let runtimePromptNames: Set<String> = Set(runtime.compactMap { cmd in
            guard cmd.source == "prompt", !cmd.isSkill else { return nil }
            return cmd.bareName
        })
        let runtimeExtensionCommands = runtime.filter(\.isExtensionCommand)

        // Skills
        let catalogSkillRecords: [SkillRecord]
        if let path = scopedPath {
            catalogSkillRecords = skillCatalog(forProjectPath: path)
        } else {
            catalogSkillRecords = globalSnapshot.skills
        }
        let activeSkillNames = activeParentSkillNames(forProjectPath: scopedPath, useSelectedProjectFallback: false)
            .union(runtimeSkillNames)
        let activeCollectionIDs = appSettings.defaultSkillCollectionIDs.union(scopedPath.map { projectPreference(for: $0).assignedSkillCollectionIDs } ?? [])
        let disabledBundledSkillNames = appSettings.disabledBundledSkillNames
        var seenSkillName = Set<String>()
        let individualSkillItems = catalogSkillRecords
            .filter { !($0.source.kind == .builtin && disabledBundledSkillNames.contains($0.name)) }
            .filter { seenSkillName.insert($0.name).inserted }
            .map { record in
                SlashItem(
                    id: "skill:\(record.id)",
                    kind: .skill,
                    displayName: record.name,
                    description: record.description?.isEmpty == false ? record.description : nil,
                    scopeLabel: record.source.displayName,
                    isActive: activeSkillNames.contains(record.name),
                    payload: .skill(name: record.name, body: record.body, filePath: record.filePath, recordID: record.id)
                )
            }
        let collectionItems = appSettings.skillCollections.map { collection in
            let body = slashSkillCollectionBody(collection, forProjectPath: scopedPath, catalog: catalogSkillRecords)
            let description = collection.description?.trimmingCharacters(in: .whitespacesAndNewlines)
            return SlashItem(
                id: "skill-collection:\(collection.id.uuidString)",
                kind: .skill,
                displayName: collection.name,
                description: description?.isEmpty == false ? description : "Skill collection",
                scopeLabel: "Collection",
                isActive: activeCollectionIDs.contains(collection.id),
                payload: .skillCollection(id: collection.id, name: collection.name, body: body)
            )
        }
        let skills = (collectionItems + individualSkillItems)
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

        // Prompts
        let promptRecords: [PromptTemplateRecord]
        if let path = scopedPath {
            promptRecords = promptTemplateCatalog(forProjectPath: path)
        } else {
            promptRecords = globalSnapshot.promptTemplates
        }
        let activePromptNames = activeParentPromptTemplateNames(forProjectPath: scopedPath, useSelectedProjectFallback: false)
            .union(runtimePromptNames)
        let disabledBundledPromptNames = appSettings.disabledBundledPromptNames
        var seenPromptName = Set<String>()
        let prompts = promptRecords
            .filter { !($0.source.kind == .builtin && disabledBundledPromptNames.contains($0.name)) }
            .filter { seenPromptName.insert($0.name).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { record in
                SlashItem(
                    id: "prompt:\(record.id)",
                    kind: .prompt,
                    displayName: record.name,
                    description: record.description.isEmpty ? nil : record.description,
                    scopeLabel: record.source.displayName,
                    isActive: activePromptNames.contains(record.name),
                    payload: .prompt(name: record.name, body: record.body, filePath: record.filePath, recordID: record.id)
                )
            }

        // Commands — Deck Command Library (when project-scoped) + Pi runtime
        // extension `registerCommand` entries from `get_commands`.
        var knownCommandSlash = Set<String>()
        var commands: [SlashItem] = []
        if projectFeatureSlashEnabled {
            for command in PiInjectedCommandCatalog.all
                .filter({ PiInjectedCommandCatalog.isEnabled($0, settings: appSettings) })
                .sorted(by: { $0.slashName.localizedStandardCompare($1.slashName) == .orderedAscending }) {
                knownCommandSlash.insert(command.slashName.lowercased())
                let bare = command.slashName.hasPrefix("/")
                    ? String(command.slashName.dropFirst()).lowercased()
                    : command.slashName.lowercased()
                knownCommandSlash.insert(bare)
                commands.append(
                    SlashItem(
                        id: "command:\(command.id)",
                        kind: .command,
                        displayName: command.title,
                        description: command.description.isEmpty ? nil : command.description,
                        scopeLabel: command.source == .builtIn ? "Built-in" : "Library",
                        isActive: true,
                        payload: .command(slashName: command.slashName, commandID: command.id)
                    )
                )
            }
        }
        for cmd in runtimeExtensionCommands.sorted(by: {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }) {
            let slashName = cmd.invocation
            let bare = cmd.bareName.lowercased()
            if knownCommandSlash.contains(slashName.lowercased()) || knownCommandSlash.contains(bare) {
                continue
            }
            knownCommandSlash.insert(slashName.lowercased())
            knownCommandSlash.insert(bare)
            commands.append(
                SlashItem(
                    id: "runtime-command:\(cmd.bareName)",
                    kind: .command,
                    displayName: cmd.bareName,
                    description: cmd.description,
                    scopeLabel: "Extension",
                    isActive: true,
                    payload: .command(slashName: slashName, commandID: "runtime:\(cmd.bareName)")
                )
            )
        }

        let createLoop = SlashItem(
            id: "loop:create-new",
            kind: .loop,
            displayName: "Create New Loop…",
            description: "Configure and launch an unsaved loop for this transcript.",
            scopeLabel: "Unsaved",
            isActive: true,
            payload: .loopCreateNew
        )
        let savedLoops = loopDefinitions
            .filter { $0.isAvailable(in: scopedPath) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { definition in
                SlashItem(
                    id: "loop:\(definition.id)",
                    kind: .loop,
                    displayName: definition.name,
                    description: definition.description.isEmpty ? nil : definition.description,
                    scopeLabel: definition.source.displayName,
                    isActive: true,
                    payload: .loopDefinition(definition)
                )
            }
        let loops = projectFeatureSlashEnabled ? [createLoop] + savedLoops : []

        return SlashUniverse(skills: skills, prompts: prompts, commands: commands, loops: loops)
    }


    func ensureLibraryAgent(for agent: AgentRecord) throws -> URL {
        let libraryRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/agent-library/agents", isDirectory: true)
        let libraryURL = libraryRoot.appendingPathComponent("\(agent.name).md")
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: libraryURL.path) { return libraryURL }

        let sourceURL = URL(fileURLWithPath: agent.filePath)
        if agent.source.kind == .global {
            try fileManager.moveItem(at: sourceURL, to: libraryURL)
        } else if agent.source.kind == .library {
            return sourceURL
        } else {
            try fileManager.copyItem(at: sourceURL, to: libraryURL)
        }
        return libraryURL
    }


    func makeEnvDraft(for record: EnvKeyRecord) -> EnvEditorDraft {
        envPersistence.makeDraft(for: record)
    }

    func makeNewEnvDraft(prefilledKey: String? = nil) -> EnvEditorDraft {
        envPersistence.makeNewDraft(prefilledKey: prefilledKey)
    }

    func saveEnvDrafts(_ drafts: [EnvEditorDraft]) throws {
        guard !drafts.isEmpty else { return }
        // A batch targets the global file. Recording inside the loop and
        // refreshing in `defer` keeps refreshes running for files already
        // written even if a later save throws.
        var written: [(scope: ResourceScopeKind, path: String)] = []
        defer {
            for file in written {
                refreshAfterFileScopedChange(sourceKind: file.scope, filePath: file.path)
            }
        }
        for draft in drafts {
            try envPersistence.save(draft)
            if !written.contains(where: { $0.path == draft.path }) {
                written.append((draft.scope, draft.path))
            }
        }
    }

    func deleteEnvKey(_ record: EnvKeyRecord) throws {
        try envPersistence.delete(record)
        refreshAfterFileScopedChange(sourceKind: record.source.kind, filePath: record.source.path)
    }

    var userDisableBuiltins: Bool {
        settingsSummary(for: .global)?.disableBuiltins ?? false
    }

    var projectDisableBuiltins: Bool {
        settingsSummary(for: .project)?.disableBuiltins ?? false
    }



    func refreshModels() {
        refreshAvailableModels()
    }

    func ensureAvailableModelsLoaded() {
        ensurePiAgentModelCatalogLoaded()
    }

    func refreshAvailableModels() {
        guard !isRefreshingModels else { return }
        isRefreshingModels = true

        Task.detached(priority: .utility) { [weak self] in
            // Keep NeuralWatt's ~/.pi/agent/models.json block in sync with the user's sign-in
            // state and NeuralWatt's live /v1/models, before querying pi. The neuralwatt block
            // exists ONLY when a real key is in ~/.pi/agent/auth.json — sign-out removes it, so
            // pi never lists NeuralWatt models without a credential. Best-effort: a failed fetch
            // leaves the existing block untouched and never blocks the model list. See
            // NeuralWattCatalogSync.
            let hasNeuralWattKey = PiAuthCredentialStore().signedInProviders().contains(NeuralWattProviderSpec.providerID)
            await NeuralWattCatalogSync().reconcile(hasRealKey: hasNeuralWattKey)
            let models = await PiModelDiscoveryService().loadAvailableModels()
            await self?.applyAvailableModelsRefresh(models, markRefreshComplete: true)
        }
    }

    func ensurePiAgentModelCatalogLoaded() {
        guard availableModels.isEmpty else { return }
        refreshAvailableModels()
    }

    private func applyAvailableModelsRefresh(_ models: [AvailableModel], markRefreshComplete: Bool) {
        availableModels = models
        modelsLastUpdatedAt = Date()
        if markRefreshComplete {
            isRefreshingModels = false
        }
    }

    func skillVisible(to agent: EffectiveAgentRecord, skill: SkillRecord) -> Bool {
        switch skill.source.kind {
        case .project, .legacyProject:
            guard let skillProject = projectName(from: skill.filePath) else { return false }
            if let agentProject = agent.projectRoot.map({ URL(fileURLWithPath: $0).lastPathComponent }) {
                return skillProject == agentProject
            }
            return false
        default:
            return true
        }
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

    func defaultCustomScope(for agent: EffectiveAgentRecord) -> AgentEditingTarget.CustomAgentScope {
        return .global
    }

    func duplicatedName(for name: String) -> String {
        let existingNames = Set(snapshot.effectiveAgents.map(\.name))
        var candidate = "\(name)-copy"
        var index = 2
        while existingNames.contains(candidate) {
            candidate = "\(name)-copy-\(index)"
            index += 1
        }
        return candidate
    }

    func deduplicateByID<T: Identifiable>(_ values: [T]) -> [T] where T.ID: Hashable {
        var seen: Set<T.ID> = []
        return values.filter { seen.insert($0.id).inserted }
    }

    private func startAutoRefresh() {
        guard !didShutdown else { return }
        if fileWatchEventMonitor == nil {
            fileWatchEventMonitor = FileWatchEventMonitor { [weak self] in
                Task { @MainActor in
                    self?.scheduleRefreshForWatchedFileEvent()
                }
            }
        }
        updateAutoRefreshWatchList()

        // Always cancel-and-reassign instead of `guard == nil else return`.
        // The latter silently leaks the prior subscription if anyone ever
        // calls `startAutoRefresh()` twice without an intervening
        // `stopAutoRefresh()`.
        autoRefreshCancellable?.cancel()
        autoRefreshCancellable = Timer.publish(every: fallbackAutoRefreshInterval, tolerance: 30, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refreshIfWatchedFilesChanged()
            }
    }

    private func stopAutoRefresh(cancelPendingScan: Bool) {
        fileWatchEventMonitor?.stop()
        fileWatchEventMonitor = nil
        watchEventDebounceTask?.cancel()
        watchEventDebounceTask = nil
        deferredWatchRefreshTask?.cancel()
        deferredWatchRefreshTask = nil
        autoRefreshCancellable?.cancel()
        autoRefreshCancellable = nil
        if cancelPendingScan {
            watchFingerprintTask?.cancel()
            watchFingerprintTask = nil
        }
    }

    func updateAutoRefreshWatchList() {
        guard let fileWatchEventMonitor else { return }
        fileWatchEventMonitor.updateWatchedURLs(currentWatchedURLsForAutoRefresh())
    }

    private func currentWatchedURLsForAutoRefresh() -> [URL] {
        watchedURLsForAutoRefresh.isEmpty
            ? AppRefreshService.watchedURLs(projects: selectedDiscoveredProject.map { [$0] } ?? [], snapshot: snapshot, externalSkillPaths: appSettings.externalSkillPaths, externalPromptPaths: appSettings.externalPromptPaths, codexPluginSkillReferences: appSettings.codexPluginSkillReferences, resolvedCodexPluginSkillPaths: cachedResolvedCodexPluginSkillPaths)
            : watchedURLsForAutoRefresh
    }

    private func scheduleRefreshForWatchedFileEvent() {
        guard !didShutdown else { return }
        if shouldDeferWatchedFileRefresh {
            watchEventDebounceTask?.cancel()
            watchEventDebounceTask = nil
            scheduleDeferredWatchedFileRefresh()
            return
        }
        watchEventDebounceTask?.cancel()
        let delay = watchEventDebounceNanoseconds
        watchEventDebounceTask = Task { @MainActor [weak self, delay] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self, !Task.isCancelled, !self.didShutdown else { return }
            self.watchEventDebounceTask = nil
            self.refreshIfWatchedFilesChanged()
        }
    }

    private var shouldDeferWatchedFileRefresh: Bool {
        TranscriptInteractionGate.isInteractingRecently || TranscriptInteractionGate.isStreamingRecently
    }

    private func scheduleDeferredWatchedFileRefresh() {
        guard !didShutdown, deferredWatchRefreshTask == nil else { return }
        let quietDelay = watchRefreshQuietNanoseconds
        deferredWatchRefreshTask = Task { @MainActor [weak self, quietDelay] in
            while true {
                try? await Task.sleep(nanoseconds: quietDelay)
                guard let self, !Task.isCancelled, !self.didShutdown else { return }
                guard self.shouldDeferWatchedFileRefresh else { break }
            }
            guard let self, !Task.isCancelled, !self.didShutdown else { return }
            self.deferredWatchRefreshTask = nil
            self.refreshIfWatchedFilesChanged()
        }
    }

    private func refreshIfWatchedFilesChanged() {
        guard watchFingerprintTask == nil else { return }
        guard !shouldDeferWatchedFileRefresh else {
            scheduleDeferredWatchedFileRefresh()
            return
        }
        let previousFingerprint = lastWatchFingerprint
        let urls = currentWatchedURLsForAutoRefresh()
        let pluginBasePaths = Set(appSettings.codexPluginSkillReferences.compactMap { CodexPluginSkillDiscovery.pluginBaseDirectory(for: $0)?.standardizedFileURL.path })
        watchFingerprintTask = Task.detached(priority: .utility) { [weak self, previousFingerprint, urls, pluginBasePaths] in
            let fingerprint = FileWatchFingerprint.make(urls: urls, shallowDirectoryPaths: pluginBasePaths)
            guard !Task.isCancelled else { return }
            await self?.applyWatchFingerprint(fingerprint, previousFingerprint: previousFingerprint)
        }
    }

    private func applyWatchFingerprint(_ fingerprint: String, previousFingerprint: String) {
        guard !Task.isCancelled else { return }
        watchFingerprintTask = nil
        guard fingerprint != previousFingerprint else { return }
        // A real on-disk change, but reassigning project state mid-scroll or
        // mid-stream re-evals the screen body (transcript itemsBuild +
        // updateNSView) and drops frames. Keep one deferred refresh armed
        // WITHOUT committing the new fingerprint, so once interaction/streaming
        // settles the next check still sees the change and refreshes.
        if shouldDeferWatchedFileRefresh {
            scheduleDeferredWatchedFileRefresh()
            return
        }
        lastWatchFingerprint = fingerprint
        refresh(includeModels: false)
    }

}
