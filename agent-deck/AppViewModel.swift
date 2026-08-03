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
    @ObservationIgnored private var cachedStandardizedExternalSkillPaths: Set<String> = []
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
    private(set) var cachedAllVisibleSkillRecords: [SkillRecord] = []
    private(set) var visibleSkillRecordsRevision: Int = 0
    /// Lowercased base skill search haystacks (name, description, scope, path,
    /// body). Repository labels are still appended by `SkillsScreen` because
    /// they are derived while resolving repository membership there.
    private(set) var cachedSkillSearchHaystackByID: [SkillRecord.ID: String] = [:]
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
    @ObservationIgnored private var agentUniverseCacheByProjectPath: [String: [EffectiveAgentRecord]] = [:]
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
    private func patchEffectiveAgentSkills(agentName: String, skills: [String]) {
        func patch(_ snap: ScanSnapshot) -> ScanSnapshot {
            guard snap.effectiveAgents.contains(where: { $0.name == agentName }) else { return snap }
            let patchedAgents = snap.effectiveAgents.map { record -> EffectiveAgentRecord in
                guard record.name == agentName else { return record }
                var resolved = record.resolved
                resolved.skills = skills
                return EffectiveAgentRecord(
                    id: record.id,
                    name: record.name,
                    projectRoot: record.projectRoot,
                    builtin: record.builtin,
                    globalCustom: record.globalCustom,
                    projectCustom: record.projectCustom,
                    userOverride: record.userOverride,
                    projectOverride: record.projectOverride,
                    resolved: resolved,
                    resolutionKind: record.resolutionKind
                )
            }
            return ScanSnapshot(
                projectRoot: snap.projectRoot,
                builtinAgents: snap.builtinAgents,
                globalAgents: snap.globalAgents,
                projectAgents: snap.projectAgents,
                legacyProjectAgents: snap.legacyProjectAgents,
                effectiveAgents: patchedAgents,
                libraryAgents: snap.libraryAgents,
                skills: snap.skills,
                librarySkills: snap.librarySkills,
                promptTemplates: snap.promptTemplates,
                libraryPromptTemplates: snap.libraryPromptTemplates,
                settings: snap.settings,
                envKeys: snap.envKeys,
                warnings: snap.warnings
            )
        }
        globalSnapshot = patch(globalSnapshot)
        allProjectSnapshots = allProjectSnapshots.mapValues(patch)
        snapshot = patch(snapshot)
    }

    /// Mirror a `.custom` agent-draft save into the in-memory snapshots so
    /// `cachedDisplayAgentByID` (read by the detail pane via `selectedAgent`)
    /// and `displayAgentsRevision` (drives the list `cachedLayout` rebuild)
    /// reflect the new config before the post-save rescan lands.
    ///
    /// Skips renames — `EffectiveAgentRecord.id` and `AgentRecord.id` both
    /// encode the name, so a rename needs the existing refresh path that also
    /// runs the `pendingSelectAgentName` flow. Skips builtin-override edits;
    /// those mutate a different on-disk structure and use `refreshSynchronouslyBlocksMainUntilDone`.
    private func patchEffectiveAgentConfig(originalName: String, newConfig: AgentConfig, filePath: String?) {
        guard originalName == newConfig.name else { return }

        func matches(_ record: AgentRecord) -> Bool {
            guard record.name == originalName else { return false }
            if let filePath, !filePath.isEmpty { return record.filePath == filePath }
            return true
        }

        func updated(_ record: AgentRecord) -> AgentRecord {
            AgentRecord(
                id: record.id,
                name: newConfig.name,
                description: newConfig.description,
                source: record.source,
                filePath: record.filePath,
                rawFrontmatter: record.rawFrontmatter,
                promptBody: newConfig.systemPrompt,
                parsed: newConfig
            )
        }

        func patchAgents(_ records: [AgentRecord]) -> [AgentRecord] {
            records.map { matches($0) ? updated($0) : $0 }
        }

        func patchEffective(_ records: [EffectiveAgentRecord]) -> [EffectiveAgentRecord] {
            records.map { record -> EffectiveAgentRecord in
                guard record.name == originalName else { return record }
                let newGlobalCustom = record.globalCustom.map { matches($0) ? updated($0) : $0 }
                let newProjectCustom = record.projectCustom.map { matches($0) ? updated($0) : $0 }
                // Custom-agent resolution: project > global > builtin, with no
                // overrides applied (overrides only graft onto a builtin winner).
                // Match `PiAgentLaunchResolver.effectiveCustomAgent`'s winner pick.
                let winner = newProjectCustom ?? newGlobalCustom ?? record.builtin
                let resolved = winner?.parsed ?? record.resolved
                return EffectiveAgentRecord(
                    id: record.id,
                    name: record.name,
                    projectRoot: record.projectRoot,
                    builtin: record.builtin,
                    globalCustom: newGlobalCustom,
                    projectCustom: newProjectCustom,
                    userOverride: record.userOverride,
                    projectOverride: record.projectOverride,
                    resolved: resolved,
                    resolutionKind: record.resolutionKind
                )
            }
        }

        func patch(_ snap: ScanSnapshot) -> ScanSnapshot {
            ScanSnapshot(
                projectRoot: snap.projectRoot,
                builtinAgents: snap.builtinAgents,
                globalAgents: patchAgents(snap.globalAgents),
                projectAgents: patchAgents(snap.projectAgents),
                legacyProjectAgents: patchAgents(snap.legacyProjectAgents),
                effectiveAgents: patchEffective(snap.effectiveAgents),
                libraryAgents: patchAgents(snap.libraryAgents),
                skills: snap.skills,
                librarySkills: snap.librarySkills,
                promptTemplates: snap.promptTemplates,
                libraryPromptTemplates: snap.libraryPromptTemplates,
                settings: snap.settings,
                envKeys: snap.envKeys,
                warnings: snap.warnings
            )
        }

        globalSnapshot = patch(globalSnapshot)
        allProjectSnapshots = allProjectSnapshots.mapValues(patch)
        snapshot = patch(snapshot)
    }

    /// In-memory patch of `settings[].agentOverrides[name]["disabled"]` followed
    /// by a re-resolve. Matches the skill-assignment fast path: no disk re-scan,
    /// so toggles render immediately instead of waiting for `refresh()`. The
    /// file watcher will still fire later for the actual JSON write, but the
    /// resulting snapshot is identical so there is no visible flash.
    private func patchBuiltinDisabledOverride(agentName: String, scope: AgentEditingTarget.OverrideScope, isDisabled: Bool, explicitProjectRoot: String? = nil) {
        let targetPath: String
        switch scope {
        case .global:
            targetPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/settings.json").path
        case .project:
            guard let projectRoot = explicitProjectRoot ?? selectedProjectPath else { return }
            targetPath = URL(fileURLWithPath: projectRoot).appendingPathComponent(".pi/settings.json").path
        }

        func patch(_ snap: ScanSnapshot) -> ScanSnapshot {
            let updatedSettings: [SettingsSummary] = snap.settings.map { summary in
                guard summary.path == targetPath else { return summary }
                var overrides = summary.agentOverrides
                if let idx = overrides.firstIndex(where: { $0.agentName == agentName }) {
                    var values = overrides[idx].values
                    values["disabled"] = .bool(isDisabled)
                    overrides[idx] = BuiltinOverrideRecord(
                        agentName: agentName,
                        scope: ScopeID(kind: .override, path: targetPath),
                        settingsPath: targetPath,
                        values: values
                    )
                } else {
                    overrides.append(BuiltinOverrideRecord(
                        agentName: agentName,
                        scope: ScopeID(kind: .override, path: targetPath),
                        settingsPath: targetPath,
                        values: ["disabled": .bool(isDisabled)]
                    ))
                    overrides.sort { $0.agentName.localizedCaseInsensitiveCompare($1.agentName) == .orderedAscending }
                }
                return SettingsSummary(
                    path: summary.path,
                    packages: summary.packages,
                    prompts: summary.prompts,
                    disableBuiltins: summary.disableBuiltins,
                    agentOverrides: overrides
                )
            }
            return ScanSnapshot(
                projectRoot: snap.projectRoot,
                builtinAgents: snap.builtinAgents,
                globalAgents: snap.globalAgents,
                projectAgents: snap.projectAgents,
                legacyProjectAgents: snap.legacyProjectAgents,
                effectiveAgents: snap.effectiveAgents,
                libraryAgents: snap.libraryAgents,
                skills: snap.skills,
                librarySkills: snap.librarySkills,
                promptTemplates: snap.promptTemplates,
                libraryPromptTemplates: snap.libraryPromptTemplates,
                settings: updatedSettings,
                envKeys: snap.envKeys,
                warnings: snap.warnings
            )
        }

        globalSnapshot = patch(globalSnapshot)
        allProjectSnapshots = allProjectSnapshots.mapValues(patch)
        snapshot = patch(snapshot)

        reconcileSnapshotsFromPreferences()
    }

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
    var suggestedExternalSkillsDirectoryURL: URL {
        let fileManager = FileManager.default
        func isDirectory(_ url: URL) -> Bool {
            var isDir: ObjCBool = false
            return fileManager.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        }

        let globalSkills = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/skills", isDirectory: true)
        return isDirectory(globalSkills) ? globalSkills : fileManager.homeDirectoryForCurrentUser
    }

    func chooseExternalSkillsDirectory(startingAt url: URL? = nil, completion: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = LanguageStore.shared.t("vm.chooseSkillsFolder")
        panel.message = LanguageStore.shared.t("vm.chooseSkillsFolderMessage", AppBrand.displayName)
        panel.directoryURL = url ?? suggestedExternalSkillsDirectoryURL

        let handler: (NSApplication.ModalResponse) -> Void = { response in
            DispatchQueue.main.async {
                guard response == .OK,
                      let selectedURL = panel.url?.standardizedFileURL else {
                    completion(nil)
                    return
                }
                completion(selectedURL)
            }
        }

        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            panel.begin(completionHandler: handler)
        }
    }

    func importExternalSkills(
        _ candidates: [ExternalSkillCandidate],
        collectionName: String?
    ) throws -> SkillImportResult {
        var importedNames: [String] = []
        var skippedNames: [String] = []
        var importedPaths: [String] = []
        var importedCandidates: [ExternalSkillCandidate] = []
        let requestedCollectionName = collectionName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingPaths = appSettings.externalSkillPaths

        for candidate in candidates {
            let sourceURL = URL(fileURLWithPath: candidate.sourceRootPath)
            let sourcePath = sourceURL.standardizedFileURL.path
            if existingPaths.contains(sourcePath) {
                skippedNames.append(candidate.name)
                continue
            }
            importedPaths.append(sourcePath)
            importedNames.append(candidate.name)
            importedCandidates.append(candidate)
        }

        if appSettingsController.addExternalSkillPaths(importedPaths) {
            appSettings = appSettingsController.settings
        }
        if !importedPaths.isEmpty, let collectionName = requestedCollectionName, !collectionName.isEmpty {
            let sourceRoots = Set(importedCandidates.map { URL(fileURLWithPath: $0.sourceRootPath).standardizedFileURL.path })
            let commonRoot = commonAncestorPath(for: Array(sourceRoots))
            upsertSkillCollection(
                name: collectionName,
                description: LanguageStore.shared.t("vm.localSkillCollection"),
                skillRootPaths: importedPaths,
                skillNames: Set(importedNames),
                importedRepositoryID: nil,
                sourceLabel: commonRoot.map { "Local · \($0)" }
            )
            appSettings = appSettingsController.settings
        }
        refresh(includeModels: false, scanAllProjects: true)
        if let firstImported = importedNames.first {
            selectedSkillID = allVisibleSkillRecords.first { $0.name == firstImported }?.id ?? selectedSkillID
        }
        return SkillImportResult(importedNames: importedNames, skippedNames: skippedNames)
    }

    func importKnownSkills(
        _ candidates: [SkillImportSheet.KnownSkillCandidate],
        collectionName: String?
    ) throws -> SkillImportResult {
        let existingPaths = appSettings.externalSkillPaths
        let existingReferences = appSettings.codexPluginSkillReferences
        var paths: [String] = []
        var references = Set<CodexPluginSkillReference>()
        var importedNames: [String] = []
        var skippedNames: [String] = []
        for candidate in candidates {
            if let reference = candidate.pluginReference {
                if existingReferences.contains(reference) { skippedNames.append(candidate.external.name) }
                else { references.insert(reference); importedNames.append(candidate.external.name) }
            } else {
                let path = URL(fileURLWithPath: candidate.external.sourceRootPath).standardizedFileURL.path
                if existingPaths.contains(path) { skippedNames.append(candidate.external.name) }
                else { paths.append(path); importedNames.append(candidate.external.name) }
            }
        }
        let addedPaths = appSettingsController.addExternalSkillPaths(paths)
        let addedReferences = appSettingsController.addCodexPluginSkillReferences(references)
        if addedPaths || addedReferences { appSettings = appSettingsController.settings }
        if !importedNames.isEmpty, let name = collectionName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            let roots = Set(paths)
            upsertSkillCollection(
                name: name,
                description: references.isEmpty ? "Local skill collection" : "Claude / Codex skill collection",
                skillRootPaths: paths,
                skillNames: Set(importedNames),
                importedRepositoryID: nil,
                sourceLabel: references.isEmpty ? commonAncestorPath(for: Array(roots)).map { "Local · \($0)" } : "Codex Plugin"
            )
            appSettings = appSettingsController.settings
        }
        if addedPaths || addedReferences { refresh(includeModels: false, scanAllProjects: true) }
        return SkillImportResult(importedNames: importedNames, skippedNames: skippedNames)
    }

    private func commonAncestorPath(for paths: [String]) -> String? {
        guard var components = paths.first.map({ URL(fileURLWithPath: $0).standardizedFileURL.pathComponents }) else { return nil }
        for path in paths.dropFirst() {
            let next = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
            components = Array(zip(components, next).prefix { $0 == $1 }.map(\.0))
            if components.isEmpty { return nil }
        }
        return NSString.path(withComponents: components)
    }

    func upsertSkillCollection(
        name: String,
        description: String?,
        skillRootPaths: [String],
        skillNames: Set<String>,
        importedRepositoryID: UUID?,
        sourceLabel: String?
    ) {
        let standardizedPaths = Set(skillRootPaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        guard !standardizedPaths.isEmpty || !skillNames.isEmpty else { return }
        let existing = appSettingsController.settings.skillCollections.first { collection in
            if let importedRepositoryID, collection.importedRepositoryID == importedRepositoryID { return true }
            return collection.importedRepositoryID == nil && collection.name == name && collection.sourceLabel == sourceLabel
        }
        var collection = existing ?? SkillCollectionRecord(
            name: name,
            description: description,
            skillRootPaths: [],
            skillNames: [],
            importedRepositoryID: importedRepositoryID,
            sourceLabel: sourceLabel
        )
        collection.description = description ?? collection.description
        collection.skillRootPaths.formUnion(standardizedPaths)
        collection.skillNames.formUnion(skillNames)
        collection.importedRepositoryID = importedRepositoryID ?? collection.importedRepositoryID
        collection.sourceLabel = sourceLabel ?? collection.sourceLabel
        appSettingsController.upsertSkillCollection(collection)
    }
















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
    func setAgentSelection(_ selection: Set<String>?, for sessionID: UUID) {
        piAgentSessionStore.updateSession(sessionID, bumpUpdatedAt: false) { session in
            session.agentSelection = session.isNoProject ? nil : selection
        }
        reconcileRunningSessionLaunchResourceFingerprints()
    }

    func setAgentLaunchOverride(
        _ value: PiAgentSessionLaunchOverrideValue?,
        for agentName: String,
        field: WritableKeyPath<PiAgentSessionAgentLaunchOverride, PiAgentSessionLaunchOverrideValue?>,
        sessionID: UUID
    ) {
        piAgentSessionStore.updateSession(sessionID, bumpUpdatedAt: false) { session in
            guard !session.isNoProject else { return }
            var overrides = session.agentLaunchOverrides ?? [:]
            var override = overrides[agentName] ?? .init(model: nil, thinking: nil)
            override[keyPath: field] = value
            if override.isEmpty {
                overrides.removeValue(forKey: agentName)
            } else {
                overrides[agentName] = override
            }
            session.agentLaunchOverrides = overrides.isEmpty ? nil : overrides
        }
    }

    private func settingsSummary(for scope: AgentEditingTarget.OverrideScope) -> SettingsSummary? {
        switch scope {
        case .global:
            let path = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".pi/agent/settings.json").path
            return snapshot.settings.first(where: { $0.path == path })
        case .project:
            guard let selectedProjectPath else { return nil }
            let path = URL(fileURLWithPath: selectedProjectPath)
                .appendingPathComponent(".pi/settings.json").path
            return snapshot.settings.first(where: { $0.path == path })
        }
    }

    /// Cached — see `cachedAllDisplayAgents`. Rebuilt by `rebuildWarningCaches()`.
    var allDisplayAgents: [EffectiveAgentRecord] { cachedAllDisplayAgents }

    /// Plain builtin rows for editors that must expose the bundled base even
    /// when the regular display list shows a custom replacement of the same
    /// name. These rows write settings overrides, never the bundled files.
    var builtinAgentModelRecords: [EffectiveAgentRecord] {
        let globalSettingsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/settings.json")
            .standardizedFileURL.path
        let globalOverrides = globalSnapshot.settings
            .first { URL(fileURLWithPath: $0.path).standardizedFileURL.path == globalSettingsPath }?
            .agentOverrides ?? []
        return globalSnapshot.builtinAgents
            .map { builtin in
                let userOverride = globalOverrides.first { $0.agentName == builtin.name }
                return EffectiveAgentRecord(
                    id: "builtin-model::\(builtin.name)",
                    name: builtin.name,
                    projectRoot: nil,
                    builtin: builtin,
                    globalCustom: nil,
                    projectCustom: nil,
                    userOverride: userOverride,
                    projectOverride: nil,
                    resolved: builtin.parsed,
                    resolutionKind: userOverride == nil ? .builtin : .builtinWithOverride
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The actual merge+sort. Called only from `rebuildWarningCaches()`.
    private func computeAllDisplayAgents() -> [EffectiveAgentRecord] {
        // Sourced from `globalSnapshot` so the Agents view stays global even
        // when a project is selected for Issues/Memory. Mirrors the prior
        // no-project-selected presentation exactly.
        var byID: [EffectiveAgentRecord.ID: EffectiveAgentRecord] = [:]
        for agent in globalSnapshot.effectiveAgents { byID[agent.id] = agent }
        for agent in catalogOnlyEffectiveAgents { byID[agent.id] = agent }
        for agent in libraryOnlyEffectiveAgents { byID[agent.id] = agent }
        for agent in projectAssignedLibraryAgentsForAggregateView { byID[agent.id] = agent }
        return Array(byID.values)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func agentSearchHaystack(for agent: EffectiveAgentRecord) -> String {
        [agent.name, agent.resolved.description, agent.resolutionKind.rawValue, agent.sourcePath ?? "", agent.resolved.systemPrompt]
            .joined(separator: "\n")
            .lowercased()
    }

    private func skillSearchHaystack(for skill: SkillRecord) -> String {
        [skill.name, skill.description ?? "", skill.source.kind.rawValue, skill.filePath, skill.body]
            .joined(separator: "\n")
            .lowercased()
    }

    private func computeAllVisibleSkillRecords() -> [SkillRecord] {
        let records = deduplicateByID(globalSnapshot.skills + globalSnapshot.librarySkills)
            .sorted { lhs, rhs in
                let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                return lhs.source.kind.rawValue < rhs.source.kind.rawValue
            }
        guard !pendingDeletedSkillIDs.isEmpty else { return records }
        return records.filter { !pendingDeletedSkillIDs.contains($0.id) }
    }

    func rebuildVisibleSkillRecordCachesIfNeeded() {
        let records = computeAllVisibleSkillRecords()
        guard records != cachedAllVisibleSkillRecords else { return }
        cachedAllVisibleSkillRecords = records
        cachedSkillSearchHaystackByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, skillSearchHaystack(for: $0)) })
        visibleSkillRecordsRevision &+= 1
    }

    var filteredAgents: [EffectiveAgentRecord] {
        allDisplayAgents.filter { agent in
            switch selectedAgentFilter {
            case .all:
                return true
            case .builtin:
                return agent.builtin != nil && agent.globalCustom == nil && agent.projectCustom == nil
            case .global:
                return agent.globalCustom?.source.kind == .global
            case .project:
                return agent.projectCustom != nil
            case .overriddenBuiltins:
                return agent.builtin != nil && (agent.userOverride != nil || agent.projectOverride != nil)
            case .replacedBuiltins:
                return agent.builtin != nil && (agent.globalCustom != nil || agent.projectCustom != nil)
            case .customOnly:
                return agent.globalCustom != nil || agent.projectCustom != nil
            case .disabled:
                return agent.resolved.disabled == true
            case .needsAttention:
                return !warnings(for: agent).isEmpty
            }
        }
    }

    var selectedAgent: EffectiveAgentRecord? {
        // O(1) lookup over `cachedDisplayAgentByID`. The cache is sourced from
        // `cachedAllDisplayAgents` (a superset of `snapshot.effectiveAgents`,
        // `catalogOnlyEffectiveAgents`, and `libraryOnlyEffectiveAgents`), so
        // we drop the heavy fallback that recomputed the catalog walk on every
        // body read.
        guard let id = selectedAgentID else { return nil }
        return cachedDisplayAgentByID[id]
    }

    private var catalogOnlyEffectiveAgents: [EffectiveAgentRecord] {
        // Global catalog: custom agents come from global user storage or
        // explicit library imports, independent of `selectedProjectPath`.
        let effectivePaths = Set(globalSnapshot.effectiveAgents.compactMap(\.sourcePath).map(standardizedPath))
        return agentCatalog(forProjectPath: nil)
            .filter { $0.source.kind != .builtin }
            .filter { !effectivePaths.contains(standardizedPath($0.filePath)) }
            .filter { $0.source.kind != .library }
            .map { catalogDisplayAgent(from: $0, projectRoot: nil) }
    }

    private var libraryOnlyEffectiveAgents: [EffectiveAgentRecord] {
        // Global/custom winners hide library duplicates.
        let agentsThatHideLibrary = globalSnapshot.effectiveAgents
            .filter { $0.projectOverride == nil }
        let effectiveNames = Set(agentsThatHideLibrary.map(\.name))
        return globalSnapshot.libraryAgents
            .filter { !effectiveNames.contains($0.name) }
            .map { libraryDisplayAgent(from: $0, projectRoot: nil) }
    }

    /// Every agent a session could pick for its subagent catalog: the
    /// project-effective agents plus catalog-only and library agents not
    /// otherwise assigned. Parameterized by project path so it resolves for
    /// any session, not only the currently selected project.
    ///
    /// Results are memoized per project path; the cache is cleared via
    /// `clearAgentUniverseCache()` whenever any underlying snapshot
    /// publishes, so callers can read this on every `body` evaluation
    /// without rebuilding the catalog walk each time.
    /// Resolves the `EffectiveAgentRecord` an agent-bound session was created
    /// against. Looks up the session's `agentName` in the session's project
    /// snapshot first (so a project override wins), then falls back to the
    /// global snapshot and finally the cross-project union returned by
    /// `selectableAgentUniverse`. Returns `nil` when the agent is no longer
    /// present anywhere — the runner surfaces this as an "Agent Unavailable"
    /// transcript error.
    func boundAgent(for session: PiAgentSessionRecord) -> EffectiveAgentRecord? {
        guard session.isAgentBound, let name = session.agentName else { return nil }
        let projectPath = session.projectPathForProjectFeatures
        if let scoped = projectPath.flatMap({ allProjectSnapshots[$0]?.effectiveAgents.first(where: { $0.name == name }) }) {
            return scoped
        }
        if let global = globalSnapshot.effectiveAgents.first(where: { $0.name == name }) {
            return global
        }
        return projectPath.flatMap { selectableAgentUniverse(forProjectPath: $0).first { $0.name == name } }
    }

    /// Skill argument list (`--skill <name=path>` pairs) for a 1:1 agent chat.
    /// Reuses the subagent runner's resolver so the agent sees the same skill
    /// universe it would as a delegated child.
    func boundAgentSkillArguments(for agent: EffectiveAgentRecord) throws -> [String] {
        let projectPath = agent.projectRoot ?? snapshot.projectRoot
        let snap = projectPath.map { startupSnapshot(forProjectPath: $0) } ?? globalSnapshot
        return try childSkillArguments(for: agent, snapshot: snap)
    }

    private func childSkillArguments(for agent: EffectiveAgentRecord, snapshot: ScanSnapshot) throws -> [String] {
        let collectionNames = Set(appSettings.skillCollections.map(\.name))
        let directNames = Set(agent.resolved.skills.filter { !collectionNames.contains($0) })
        let collectionIDs = Set(appSettings.skillCollections.filter { agent.resolved.skills.contains($0.name) }.map(\.id))
        let expandedNames = effectiveSkillNames(directNames: directNames, collectionIDs: collectionIDs, catalog: PiSkillLaunchResolver.catalog(from: snapshot))
        return try PiSkillLaunchResolver.childSkillArguments(
            agent: agent,
            snapshot: snapshot,
            expandedSkillNames: expandedNames,
            ignoredMissingSkillNames: []
        )
    }

    /// Popover entry point: build the session and launch Pi. Switches the
    /// sidebar to the agent screen so the new session is visible.
    func startAgentSession(agent: EffectiveAgentRecord, project: DiscoveredProject, initialInstruction: String?) {
        guard agent.resolved.disabled != true else {
            piAgentRunnerSurfaceError(message: "Agent '\(agent.name)' is disabled.")
            return
        }
        selectedSidebarItem = .agent
        ensurePiAgentModelCatalogLoaded()
        piAgentRunner.startAgentSession(agent: agent, project: project, initialInstruction: initialInstruction)
    }

    /// Picker-card entry point: bind a not-yet-launched draft to a single
    /// agent, turning it into a 1:1 chat in place instead of spawning a
    /// separate session. Pi hasn't launched yet, so this is a pure record
    /// mutation — the first send picks up the agent's system prompt and
    /// tools via `boundAgent(for:)`.
    func bindPiAgentDraft(_ sessionID: UUID, to agent: EffectiveAgentRecord) {
        guard agent.resolved.disabled != true else {
            piAgentRunnerSurfaceError(message: "Agent '\(agent.name)' is disabled.")
            return
        }
        piAgentSessionStore.updateSession(sessionID) { record in
            guard record.status == .draft, record.piSessionFile == nil, !record.isNoProject else { return }
            record.kind = .agent
            record.agentName = agent.name
            if !record.isTitleUserEdited {
                record.title = "Chat · \(agent.name)"
            }
        }
    }

    /// "Switch back" in the picker card: revert a bound draft to a regular
    /// project session. Only meaningful before the first message — once Pi
    /// has a session file the binding is baked into the conversation.
    func unbindPiAgentDraft(_ sessionID: UUID) {
        piAgentSessionStore.updateSession(sessionID) { record in
            guard record.status == .draft, record.piSessionFile == nil, record.kind == .agent else { return }
            record.kind = .project
            record.agentName = nil
            if !record.isTitleUserEdited {
                record.title = "Draft · \(record.projectName)"
            }
        }
    }

    /// Mutates a session's `agentName` and reruns it. Used by the "Switch
    /// agent…" affordance shown in the transcript header when the original
    /// agent disappears.
    func rebindAgent(sessionID: UUID, to agent: EffectiveAgentRecord) {
        guard let existing = piAgentSessionStore.sessions.first(where: { $0.id == sessionID }) else { return }
        guard existing.kind == .agent else { return }
        piAgentSessionStore.updateSession(sessionID) { record in
            record.agentName = agent.name
            record.title = "Chat · \(agent.name)"
            record.lastError = nil
            record.status = .draft
        }
        guard let refreshed = piAgentSessionStore.sessions.first(where: { $0.id == sessionID }) else { return }
        piAgentRunner.resume(session: refreshed)
    }

    func piAgentRunnerSurfaceError(message: String) {
        // The agent-chat start path has no transcript yet; route the message
        // through the existing GitHub-style banner so the user sees it.
        repositoryLastError = message
    }

    func selectableAgentUniverse(forProjectPath path: String) -> [EffectiveAgentRecord] {
        let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return [] }
        if let cached = agentUniverseCacheByProjectPath[path] {
            return cached
        }
        let snap = startupSnapshot(forProjectPath: path)
        let effective = snap.effectiveAgents
        let effectivePaths = Set(effective.compactMap(\.sourcePath).map(standardizedPath))
        let catalogOnly = agentCatalog(forProjectPath: path)
            .filter { $0.source.kind != .builtin && $0.source.kind != .library }
            .filter { !effectivePaths.contains(standardizedPath($0.filePath)) }
            .map { catalogDisplayAgent(from: $0, projectRoot: snap.projectRoot) }
        let effectiveNames = Set(effective.map(\.name))
        let libraryOnly = snap.libraryAgents
            .filter { !effectiveNames.contains($0.name) }
            .map { libraryDisplayAgent(from: $0, projectRoot: snap.projectRoot) }
        let result = effective + catalogOnly + libraryOnly
        agentUniverseCacheByProjectPath[path] = result
        return result
    }

    func clearAgentUniverseCache() {
        agentUniverseCacheByProjectPath.removeAll(keepingCapacity: true)
    }

    /// The exact, deduplicated set of subagents advertised to — and delegable
    /// by — a session. Single source of truth shared by the catalog prompt,
    /// the delegation lookups, and the session resources popover. A `nil`
    /// `agentSelection` keeps the historical default of all effective agents;
    /// an explicit selection is resolved against the full universe so an agent
    /// not assigned to the project can still be included.
    func catalogAgents(for session: PiAgentSessionRecord) -> [EffectiveAgentRecord] {
        guard !session.isNoProject, let projectPath = session.projectPathForProjectFeatures else { return [] }
        let agents: [EffectiveAgentRecord]
        if let selection = session.agentSelection {
            agents = selectableAgentUniverse(forProjectPath: projectPath)
                .filter { selection.contains($0.name) }
        } else {
            agents = startupSnapshot(forProjectPath: projectPath).effectiveAgents
        }
        var seen = Set<String>()
        return agents
            .filter { $0.resolved.disabled != true && seen.insert($0.name).inserted }
            .map { applyingSessionLaunchOverrides(to: $0, session: session) }
    }

    private func applyingSessionLaunchOverrides(to agent: EffectiveAgentRecord, session: PiAgentSessionRecord) -> EffectiveAgentRecord {
        guard let override = session.agentLaunchOverrides?[agent.name] else { return agent }
        var resolved = agent.resolved
        switch override.model {
        case .piDefault:
            resolved.model = nil
        case let .value(value):
            resolved.model = value.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        case nil:
            break
        }
        switch override.thinking {
        case .piDefault:
            resolved.thinking = nil
        case let .value(value):
            resolved.thinking = value.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        case nil:
            break
        }
        return EffectiveAgentRecord(
            id: agent.id,
            name: agent.name,
            projectRoot: agent.projectRoot,
            builtin: agent.builtin,
            globalCustom: agent.globalCustom,
            projectCustom: agent.projectCustom,
            userOverride: agent.userOverride,
            projectOverride: agent.projectOverride,
            resolved: resolved,
            resolutionKind: agent.resolutionKind
        )
    }

    /// Whether a session has any non-disabled agent it could run as a subagent.
    /// Fast path: a usable effective agent (builtins normally qualify) returns
    /// immediately, so the broader global/imported catalog lookup only runs in
    /// the rare case where the project has no usable effective agents at all.
    func sessionHasSelectableAgents(_ session: PiAgentSessionRecord) -> Bool {
        guard !session.isNoProject, let projectPath = session.projectPathForProjectFeatures else { return false }
        if startupSnapshot(forProjectPath: projectPath)
            .effectiveAgents.contains(where: { $0.resolved.disabled != true }) {
            return true
        }
        return selectableAgentUniverse(forProjectPath: projectPath)
            .contains { $0.resolved.disabled != true }
    }

    private var projectAssignedLibraryAgentsForAggregateView: [EffectiveAgentRecord] {
        // Global view — `globalSnapshot.projectRoot` is always nil here.
        guard globalSnapshot.projectRoot == nil else { return [] }
        let effectiveNames = Set(globalSnapshot.effectiveAgents.map(\.name))
        let libraryByName = Dictionary(uniqueKeysWithValues: globalSnapshot.libraryAgents.map { ($0.name, $0) })
        let assignedNames = Set(projectPreferencesByPath.values.flatMap(\.assignedAgentNames))
        let libraryNames = Set(globalSnapshot.libraryAgents.map(\.name))
        return assignedNames
            .filter { !effectiveNames.contains($0) && libraryNames.contains($0) }
            .compactMap { libraryByName[$0] }
            .map { libraryDisplayAgent(from: $0, projectRoot: nil) }
    }

    private func catalogDisplayAgent(from record: AgentRecord, projectRoot: String?) -> EffectiveAgentRecord {
        EffectiveAgentRecord(
            id: "catalog::\(record.source.kind.rawValue)::\(record.filePath)",
            name: record.name,
            projectRoot: projectRoot,
            builtin: nil,
            globalCustom: record.source.kind == .global ? record : nil,
            projectCustom: record.source.kind == .project || record.source.kind == .legacyProject ? record : nil,
            userOverride: nil,
            projectOverride: nil,
            resolved: record.parsed,
            resolutionKind: record.source.kind == .global ? .globalCustom : .projectCustom
        )
    }

    private func libraryDisplayAgent(from record: AgentRecord, projectRoot: String?) -> EffectiveAgentRecord {
        EffectiveAgentRecord(
            id: "library::\(record.name)",
            name: record.name,
            projectRoot: projectRoot,
            builtin: nil,
            globalCustom: record,
            projectCustom: nil,
            userOverride: nil,
            projectOverride: nil,
            resolved: record.parsed,
            resolutionKind: .library
        )
    }

    var allVisibleAgentRecords: [AgentRecord] {
        agentCatalog(forProjectPath: selectedProjectPath)
            .filter { $0.source.kind != .builtin }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func agentCatalog(forProjectPath projectPath: String?) -> [AgentRecord] {
        let records = globalSnapshot.globalAgents + globalSnapshot.libraryAgents
        return deduplicateByID(records)
    }

    private func agentCatalog(globalSnapshot: ScanSnapshot, catalogProjectSnapshots: [ScanSnapshot]) -> [AgentRecord] {
        deduplicateByID(
            globalSnapshot.globalAgents +
            globalSnapshot.libraryAgents
        )
    }

    func scopedAgentSnapshot(_ base: ScanSnapshot, projectPath: String?, globalCatalogSnapshot: ScanSnapshot, catalogProjectSnapshots: [ScanSnapshot]) -> ScanSnapshot {
        let projectAgentNames = projectPath.map { projectPreference(for: $0).assignedAgentNames } ?? []
        return ScanSnapshot(
            projectRoot: base.projectRoot,
            builtinAgents: base.builtinAgents,
            globalAgents: base.globalAgents,
            projectAgents: base.projectAgents,
            legacyProjectAgents: base.legacyProjectAgents,
            effectiveAgents: PiAgentLaunchResolver.effectiveAgents(
                defaultAgentNames: appSettings.defaultAgentNames,
                projectAgentNames: projectAgentNames,
                snapshot: base,
                catalog: agentCatalog(globalSnapshot: globalCatalogSnapshot, catalogProjectSnapshots: catalogProjectSnapshots)
            ),
            libraryAgents: base.libraryAgents,
            skills: base.skills,
            librarySkills: base.librarySkills,
            promptTemplates: base.promptTemplates,
            libraryPromptTemplates: base.libraryPromptTemplates,
            settings: base.settings,
            envKeys: base.envKeys,
            warnings: base.warnings
        )
    }

    func migrateAgentAssignmentsFromDiscoveredFiles(globalSnapshot: ScanSnapshot, projectSnapshots: [String: ScanSnapshot]) {
        for name in Set(globalSnapshot.globalAgents.map(\.name)) {
            _ = appSettingsController.setDefaultAgent(name, enabled: true)
        }
        _ = appSettingsController.markAgentAssignmentsMigratedFromDiscoveredFiles()
        appSettings = appSettingsController.settings
        projectPreferencesByPath = projectPreferencesStore.preferencesByPath
    }

    var selectedSkill: SkillRecord? {
        allVisibleSkillRecords.first(where: { $0.id == selectedSkillID })
    }

    var allVisibleSkillRecords: [SkillRecord] {
        // Global resource catalog — independent of `selectedProjectPath` so the
        // Skills view stays global even when a project is selected for Issues.
        // Cached and revisioned to avoid sorting/comparing skill bodies in view
        // observation paths.
        cachedAllVisibleSkillRecords
    }

    /// Standardized `SKILL.md` paths of every skill currently in the catalog
    /// (builtin, global, project, package, and imported). The import sheet uses
    /// this to hide skills the user already has. Pure string work, no I/O — but
    /// O(catalog) to build, so callers should read it once and cache it rather
    /// than re-reading it per render.
    var catalogedSkillFilePaths: Set<String> {
        Set(allVisibleSkillRecords.map { URL(fileURLWithPath: $0.filePath).standardizedFileURL.path })
    }

    func startupSnapshot(forProjectPath path: String) -> ScanSnapshot {
        let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return globalSnapshot }
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        if let projectSnapshot = allProjectSnapshots[standardizedPath] {
            return scopedStartupSnapshot(projectSnapshot: projectSnapshot)
        }

        // A draft can target a project before its scan lands. Resolve that
        // project's assignments from the global catalog instead of leaking the
        // currently displayed (possibly unrelated) project's effective agents.
        let fallback = PiAgentLaunchResolver.projectFallbackSnapshot(
            from: globalSnapshot,
            projectRoot: standardizedPath
        )
        return scopedAgentSnapshot(
            fallback,
            projectPath: standardizedPath,
            globalCatalogSnapshot: globalSnapshot,
            catalogProjectSnapshots: Array(allProjectSnapshots.values)
        )
    }

    private func scopedStartupSnapshot(projectSnapshot: ScanSnapshot) -> ScanSnapshot {
        projectSnapshot
    }

    var selectedPromptTemplate: PromptTemplateRecord? {
        allVisiblePromptTemplateRecords.first(where: { $0.id == selectedCommandItemID })
    }

    var allVisiblePromptTemplateRecords: [PromptTemplateRecord] {
        // Global resource catalog — independent of `selectedProjectPath` so the
        // Prompts view stays global even when a project is selected for Issues.
        let records = deduplicateByID(globalSnapshot.promptTemplates + globalSnapshot.libraryPromptTemplates)
            .sorted { lhs, rhs in
                let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                return lhs.source.kind.rawValue < rhs.source.kind.rawValue
            }
        guard !pendingDeletedPromptIDs.isEmpty else { return records }
        return records.filter { !pendingDeletedPromptIDs.contains($0.id) }
    }

    var packageNames: [String] {
        Array(Set(snapshot.settings.flatMap(\.packages))).sorted()
    }

    func availableExtensionNames(for target: AgentEditingTarget) -> [String] {
        let snapshot = scopeSnapshot(for: target)
        return Array(Set(snapshot.settings.flatMap(\.packages)))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func availableSkillNames(for target: AgentEditingTarget) -> [String] {
        let snapshot = scopeSnapshot(for: target)
        return Array(Set((snapshot.skills + snapshot.librarySkills).map(\.name)))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func availableSkillCollectionNames(for target: AgentEditingTarget) -> [String] {
        appSettings.skillCollections.map(\.name)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func availableToolNames(for target: AgentEditingTarget) -> [String] {
        let scopeSnapshot = scopeSnapshot(for: target)
        var tools = [
            "read", "grep", "find", "ls", "bash",
            "edit", "write", "ask_user"
        ]
        let exaConfigured = isExaConfigured(for: target)
        if exaConfigured {
            tools.append(contentsOf: PiNativeSubagentBridgeExtensions.exaToolNames)
        } else if WebFetchDependencyService().status().isInstalled {
            tools.append(PiNativeSubagentBridgeExtensions.fallbackWebFetchToolName)
        }

        let explicitTools = scopeSnapshot.effectiveAgents.flatMap { $0.resolved.tools ?? [] }
            .filter { tool in
                let normalized = tool.lowercased()
                if PiNativeSubagentBridgeExtensions.exaToolNames.contains(normalized) { return exaConfigured }
                if normalized == PiNativeSubagentBridgeExtensions.fallbackWebFetchToolName {
                    return !exaConfigured && WebFetchDependencyService().status().isInstalled
                }
                return true
            }
        return Array(Set(tools + explicitTools))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func isExaConfigured(for target: AgentEditingTarget) -> Bool {
        let environment = EnvRuntimeEnvironment().environment()
        return PiNativeSubagentBridgeExtensions.isExaConfigured(environment: environment)
    }

    func availableModelIdentifiers() -> [String] {
        enabledAvailableModels.map(\.identifier)
    }

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

    func makeAgentDraft(for agent: EffectiveAgentRecord, preferredOverrideScope: AgentEditingTarget.OverrideScope? = nil) -> AgentEditorDraft? {
        agentPersistence.makeDraft(for: agent, preferredOverrideScope: preferredOverrideScope)
    }

    func saveAgentDrafts(_ pairs: [(draft: AgentEditorDraft, agent: EffectiveAgentRecord)]) throws {
        guard !pairs.isEmpty else { return }
        for pair in pairs {
            try agentPersistence.save(pair.draft, original: pair.agent, projectRoot: selectedProjectPath)
        }
        var needsGlobalRefresh = false
        var projectPaths: Set<String> = []
        var didPatchInMemory = false
        for pair in pairs {
            switch pair.draft.target {
            case .custom(.global), .custom(.library), .builtinOverride(.global):
                needsGlobalRefresh = true
            case .custom(.project):
                if let path = pair.draft.sourcePath.flatMap(projectPath(containing:)) ?? selectedProjectPath {
                    projectPaths.insert(path)
                }
            case .builtinOverride(.project):
                if let path = selectedProjectPath {
                    projectPaths.insert(path)
                }
            }
            // Sync in-memory patch for custom edits so the panes update before
            // the rescan lands. Matches the single-save fast path in `saveAgentDraft`.
            if case .custom = pair.draft.target, pair.draft.originalName == pair.draft.config.name {
                patchEffectiveAgentConfig(
                    originalName: pair.draft.originalName,
                    newConfig: pair.draft.config,
                    filePath: pair.draft.sourcePath
                )
                didPatchInMemory = true
            }
        }
        if didPatchInMemory {
            rebuildWarningCaches()
        }
        if needsGlobalRefresh {
            refresh(includeModels: false, silentlyReconcile: didPatchInMemory)
        }
        for path in projectPaths {
            refreshAfterProjectScopedChange(projectPath: path)
        }
    }

    func saveAgentDraft(_ draft: AgentEditorDraft, for agent: EffectiveAgentRecord) throws {
        try agentPersistence.save(draft, original: agent, projectRoot: selectedProjectPath)
        // Fast-path: mirror the disk write into the in-memory snapshots so the
        // detail pane (reading `cachedDisplayAgentByID`) and the list layout
        // (driven by `displayAgentsRevision`) reflect the new config now,
        // instead of waiting for `refreshAfterAgentDraftChange`'s async rescan.
        // Skips rename + builtin-override edits; those keep the existing flow.
        if case .custom = draft.target, draft.originalName == draft.config.name {
            patchEffectiveAgentConfig(originalName: draft.originalName, newConfig: draft.config, filePath: draft.sourcePath)
            rebuildWarningCaches()
        }
        refreshAfterAgentDraftChange(draft)
    }

    func setAgentDisabled(_ isDisabled: Bool, for agent: EffectiveAgentRecord) throws {
        let overrideScope: AgentEditingTarget.OverrideScope = selectedProjectPath == nil ? .global : .project
        guard var draft = makeAgentDraft(for: agent, preferredOverrideScope: overrideScope) else { return }
        draft.config.disabled = isDisabled
        try saveAgentDraft(draft, for: agent)
    }

    func makeNewAgentDraft(scope: AgentEditingTarget.CustomAgentScope) -> AgentEditorDraft {
        let base = AgentConfig(
            name: "new-agent",
            description: "",
            whenToUse: nil,
            model: nil,
            fallbackModels: [],
            thinking: nil,
            systemPromptMode: "replace",
            inheritSkills: nil,
            disabled: nil,
            tools: ["read", "grep", "find", "ls", "bash"],
            mcpDirectTools: nil,
            mcpServers: nil,
            extensions: nil,
            skills: [],
            output: nil,
            defaultExpectedOutcome: .reportOnly,
            defaultReads: nil,
            defaultProgress: nil,
            interactive: nil,
            maxSubagentDepth: nil,
            systemPrompt: "Describe the agent behavior here.",
            unknownFields: [:]
        )
        return agentPersistence.makeNewDraft(scope: scope, base: base)
    }

    func makeDuplicateAgentDraft(from agent: EffectiveAgentRecord, scope: AgentEditingTarget.CustomAgentScope? = nil) -> AgentEditorDraft {
        let targetScope = scope ?? defaultCustomScope(for: agent)
        var config = agent.winningRecord?.parsed ?? agent.resolved
        config.name = duplicatedName(for: config.name)
        return agentPersistence.makeNewDraft(scope: targetScope, base: config)
    }

    func makeReplacementAgentDraft(from agent: EffectiveAgentRecord, scope: AgentEditingTarget.CustomAgentScope) -> AgentEditorDraft {
        var config: AgentConfig
        if scope == .global, agent.builtin != nil, agent.globalCustom == nil {
            // Global replacement files should not accidentally bake in project-only overrides.
            config = makeAgentDraft(for: agent, preferredOverrideScope: .global)?.config ?? agent.resolved
        } else {
            config = agent.resolved
        }
        config.name = agent.name
        return agentPersistence.makeNewDraft(scope: scope, base: config)
    }

    func saveNewAgentDraft(_ draft: AgentEditorDraft) throws {
        try agentPersistence.saveNewCustomAgent(draft, projectRoot: selectedProjectPath)
        refreshAfterAgentDraftChange(draft)
    }

    func canRenameAgent(_ agent: EffectiveAgentRecord) -> Bool {
        renameableAgentRecord(for: agent) != nil
    }

    func renamePreview(for agent: EffectiveAgentRecord, to requestedName: String) -> ResourceRenamePreview {
        renamePreview(oldName: agent.name, requestedName: requestedName) { newName in
            guard let record = renameableAgentRecord(for: agent) else {
                throw ResourceRenameError.unsupportedResource("Bundled agents cannot be renamed. Create a custom replacement or duplicate instead.")
            }
            try validateAgentRename(record, to: newName)
            var changes = ["Update agent frontmatter `name` from `\(agent.name)` to `\(newName)`.", "Rename the agent markdown file to `\(newName).md`."]
            if appSettings.defaultAgentNames.contains(agent.name) { changes.append("Update Default agent assignment.") }
            if projectPreferencesByPath.values.contains(where: { $0.assignedAgentNames.contains(agent.name) }) { changes.append("Update project agent assignments.") }
            var warnings: [String] = []
            if snapshot.builtinAgents.contains(where: { $0.name == agent.name }) {
                warnings.append("This custom agent currently replaces a builtin. After renaming it, it will become a separate custom agent.")
            }
            return (changes, warnings)
        }
    }

    func renameAgent(_ agent: EffectiveAgentRecord, to requestedName: String) throws {
        refreshAllProjectSnapshotsForRename()
        let newName = try ResourceRenameSupport.normalizedName(requestedName)
        guard newName != agent.name else { return }
        guard let record = renameableAgentRecord(for: agent) else {
            throw ResourceRenameError.unsupportedResource("Bundled agents cannot be renamed. Create a custom replacement or duplicate instead.")
        }
        try validateAgentRename(record, to: newName)

        let oldName = record.name
        let sourceURL = URL(fileURLWithPath: record.filePath).standardizedFileURL
        let destinationURL = sourceURL.deletingLastPathComponent().appendingPathComponent("\(newName).md")
        try ensureRenameDestinationAvailable(destinationURL, sourceURL: sourceURL)

        var config = record.parsed
        config.name = newName
        let serialized = agentPersistence.serializedText(for: config)
        try moveItemIfNeeded(from: sourceURL, to: destinationURL)
        try serialized.write(to: destinationURL, atomically: true, encoding: .utf8)

        _ = appSettingsController.renameDefaultAgent(from: oldName, to: newName)
        projectPreferencesStore.renameAssignedAgent(from: oldName, to: newName)
        applyProjectPreferenceChanges()
        appSettings = appSettingsController.settings

        // Drop the redundant synchronous rescan; the async refresh reconciles.
        // `pendingSelectAgentName` keeps the selection on the renamed agent
        // once that fresh snapshot lands.
        pendingSelectAgentName = newName
        refresh(includeModels: false, scanAllProjects: true)
    }

    func canRenameSkill(_ skill: SkillRecord) -> Bool {
        switch skill.source.kind {
        case .builtin, .package:
            return false
        case .global, .project, .legacyProject, .override, .library:
            return true
        }
    }

    func renamePreview(for skill: SkillRecord, to requestedName: String) -> ResourceRenamePreview {
        renamePreview(oldName: skill.name, requestedName: requestedName) { newName in
            guard canRenameSkill(skill) else {
                throw ResourceRenameError.unsupportedResource("Bundled and package skills are read-only and cannot be renamed.")
            }
            try validateSkillRename(skill, to: newName)
            var changes = ["Update `SKILL.md` frontmatter `name` from `\(skill.name)` to `\(newName)`." ]
            if skill.filePath.hasSuffix("/SKILL.md") {
                changes.append("Rename the skill folder to `\(newName)`.")
            } else {
                changes.append("Rename the skill file to `\(newName).md`.")
            }
            if appSettings.defaultSkillNames.contains(skill.name) { changes.append("Update Default skill assignment.") }
            if projectPreferencesByPath.values.contains(where: { $0.assignedSkillNames.contains(skill.name) }) { changes.append("Update project skill assignments.") }
            if allAgentRecordsForReferenceUpdates().contains(where: { $0.parsed.skills.contains(skill.name) }) { changes.append("Update agent skill references.") }
            return (changes, [])
        }
    }

    func renameSkill(_ skill: SkillRecord, to requestedName: String) throws {
        refreshAllProjectSnapshotsForRename()
        let newName = try ResourceRenameSupport.normalizedName(requestedName)
        guard newName != skill.name else { return }
        guard canRenameSkill(skill) else {
            throw ResourceRenameError.unsupportedResource("Bundled and package skills are read-only and cannot be renamed.")
        }
        try validateSkillRename(skill, to: newName)

        let fileURL = URL(fileURLWithPath: skill.filePath).standardizedFileURL
        let isSkillFolder = fileURL.lastPathComponent == "SKILL.md"
        let oldTargetURL = isSkillFolder ? fileURL.deletingLastPathComponent() : fileURL
        let newTargetURL = isSkillFolder
            ? oldTargetURL.deletingLastPathComponent().appendingPathComponent(newName, isDirectory: true)
            : oldTargetURL.deletingLastPathComponent().appendingPathComponent("\(newName).md")
        try ensureRenameDestinationAvailable(newTargetURL, sourceURL: oldTargetURL)

        let text = try String(contentsOf: fileURL, encoding: .utf8)
        let updatedText = ResourceRenameSupport.replacingFrontmatterValue(in: text, key: "name", value: newName)
        try updatedText.write(to: fileURL, atomically: true, encoding: .utf8)
        try moveItemIfNeeded(from: oldTargetURL, to: newTargetURL)

        _ = appSettingsController.renameDefaultSkill(from: skill.name, to: newName)
        projectPreferencesStore.renameAssignedSkill(from: skill.name, to: newName)
        applyProjectPreferenceChanges()
        try replaceSkillReferencesInCustomAgents(from: skill.name, to: newName)
        try replaceSkillReferencesInBuiltinOverrides(from: skill.name, to: newName)
        _ = appSettingsController.replaceExternalSkillPath(from: oldTargetURL.path, to: newTargetURL.path)
        _ = appSettingsController.replaceExternalSkillPath(from: fileURL.path, to: (isSkillFolder ? newTargetURL.appendingPathComponent("SKILL.md") : newTargetURL).path)
        appSettings = appSettingsController.settings

        // Drop the redundant synchronous rescan; the async refresh reconciles.
        // `pendingSelectSkillName` keeps the selection on the renamed skill
        // once that fresh snapshot lands.
        pendingSelectSkillName = newName
        refresh(includeModels: false, scanAllProjects: true)
    }

    func canRenamePrompt(_ prompt: PromptTemplateRecord) -> Bool {
        prompt.source.kind != .package
    }

    func renamePreview(for prompt: PromptTemplateRecord, to requestedName: String) -> ResourceRenamePreview {
        renamePreview(oldName: prompt.name, requestedName: requestedName) { newName in
            guard canRenamePrompt(prompt) else {
                throw ResourceRenameError.unsupportedResource("Package prompts are read-only and cannot be renamed.")
            }
            try validatePromptRename(prompt, to: newName)
            var changes = ["Rename prompt file to `\(newName).md`."]
            if appSettings.defaultPromptTemplateNames.contains(prompt.name) { changes.append("Update Default prompt assignment.") }
            if projectPreferencesByPath.values.contains(where: { $0.assignedPromptTemplateNames.contains(prompt.name) }) { changes.append("Update project prompt assignments.") }
            if settingsContainPromptFile(prompt.filePath) { changes.append("Update direct prompt paths in settings.json.") }
            return (changes, [])
        }
    }

    func renamePrompt(_ prompt: PromptTemplateRecord, to requestedName: String) throws {
        refreshAllProjectSnapshotsForRename()
        let newName = try ResourceRenameSupport.normalizedName(requestedName)
        guard newName != prompt.name else { return }
        guard canRenamePrompt(prompt) else {
            throw ResourceRenameError.unsupportedResource("Package prompts are read-only and cannot be renamed.")
        }
        try validatePromptRename(prompt, to: newName)

        let fileURL = URL(fileURLWithPath: prompt.filePath).standardizedFileURL
        let destinationURL = fileURL.deletingLastPathComponent().appendingPathComponent("\(newName).md")
        try ensureRenameDestinationAvailable(destinationURL, sourceURL: fileURL)
        try moveItemIfNeeded(from: fileURL, to: destinationURL)

        _ = appSettingsController.renameDefaultPromptTemplate(from: prompt.name, to: newName)
        projectPreferencesStore.renameAssignedPromptTemplate(from: prompt.name, to: newName)
        applyProjectPreferenceChanges()
        try replacePromptSettingsPaths(oldURLs: [fileURL], newURL: destinationURL)
        appSettings = appSettingsController.settings

        refresh(includeModels: false, scanAllProjects: true)
        selectedCommandItemID = allVisiblePromptTemplateRecords.first { $0.name == newName }?.id ?? selectedCommandItemID
    }

    private func renamePreview(oldName: String, requestedName: String, build: (String) throws -> (changes: [String], warnings: [String])) -> ResourceRenamePreview {
        do {
            let newName = try ResourceRenameSupport.normalizedName(requestedName)
            guard newName != oldName else {
                return ResourceRenameSupport.preview(oldName: oldName, requestedName: requestedName, changes: [])
            }
            let result = try build(newName)
            return ResourceRenameSupport.preview(oldName: oldName, requestedName: requestedName, changes: result.changes, warnings: result.warnings)
        } catch {
            return ResourceRenameSupport.preview(oldName: oldName, requestedName: requestedName, changes: [], blockers: [error.localizedDescription])
        }
    }

    private func renameableAgentRecord(for agent: EffectiveAgentRecord) -> AgentRecord? {
        let record = agent.projectCustom ?? agent.globalCustom ?? snapshot.libraryAgents.first { $0.name == agent.name }
        guard let record, record.source.kind != .builtin, record.source.kind != .package else { return nil }
        return record
    }

    private func refreshAllProjectSnapshotsForRename() {
        // Snapshot the inputs on @MainActor, then scan off-main using the same
        // detached pattern as `refresh(...)`. Rename validation already runs
        // against the current in-memory snapshot synchronously before the
        // mutation; this detached follow-up is the post-mutation reconciliation.
        let rootURLs = configuredProjectsRootURLs
        let selectedProjectPath = selectedProjectPath
        let preferencesByPath = projectPreferencesStore.preferencesByPath
        let externalSkillPaths = appSettings.externalSkillPaths
        let externalPromptPaths = appSettings.externalPromptPaths
        let codexPluginSkillReferences = appSettings.codexPluginSkillReferences
        let skillCollectionNames = Set(appSettings.skillCollections.map(\.name))
        refreshRequestID += 1
        let requestID = refreshRequestID
        refreshTask?.cancel()
        let viewModel = self
        // `.utility` so the project scan never outranks the main thread (see refresh()).
        refreshTask = Task.detached(priority: .utility) {
            let result = AppRefreshService().loadSnapshot(
                rootURLs: rootURLs,
                selectedProjectPath: selectedProjectPath,
                preferencesByPath: preferencesByPath,
                externalSkillPaths: externalSkillPaths,
                externalPromptPaths: externalPromptPaths,
                codexPluginSkillReferences: codexPluginSkillReferences,
                skillCollectionNames: skillCollectionNames,
                scanAllProjects: true
            )
            await MainActor.run {
                guard !Task.isCancelled, requestID == viewModel.refreshRequestID else { return }
                viewModel.applyRefreshSnapshot(result, includeModels: false)
            }
        }
    }

    private func validateAgentRename(_ record: AgentRecord, to newName: String) throws {
        guard !agentNameExists(newName, excludingPaths: [standardizedPath(record.filePath)]) else {
            throw ResourceRenameError.duplicateName(newName)
        }
        let sourceURL = URL(fileURLWithPath: record.filePath).standardizedFileURL
        let destinationURL = sourceURL.deletingLastPathComponent().appendingPathComponent("\(newName).md")
        try ensureRenameDestinationAvailable(destinationURL, sourceURL: sourceURL)
    }

    private func validateSkillRename(_ skill: SkillRecord, to newName: String) throws {
        guard !allSkillRecordsForRenameValidation().contains(where: { $0.name == newName && standardizedPath($0.filePath) != standardizedPath(skill.filePath) }) else {
            throw ResourceRenameError.duplicateName(newName)
        }
        let fileURL = URL(fileURLWithPath: skill.filePath).standardizedFileURL
        if (try? fileURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw ResourceRenameError.unsupportedResource("Symlinked skills cannot be renamed safely in app. Rename the real skill file or folder instead.")
        }
        let oldTargetURL = fileURL.lastPathComponent == "SKILL.md" ? fileURL.deletingLastPathComponent() : fileURL
        if (try? oldTargetURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw ResourceRenameError.unsupportedResource("Symlinked skill folders cannot be renamed safely in app. Rename the real skill folder instead.")
        }
        let newTargetURL = fileURL.lastPathComponent == "SKILL.md"
            ? oldTargetURL.deletingLastPathComponent().appendingPathComponent(newName, isDirectory: true)
            : oldTargetURL.deletingLastPathComponent().appendingPathComponent("\(newName).md")
        try ensureRenameDestinationAvailable(newTargetURL, sourceURL: oldTargetURL)
    }

    private func validatePromptRename(_ prompt: PromptTemplateRecord, to newName: String) throws {
        guard !allPromptRecordsForRenameValidation().contains(where: { $0.name == newName && standardizedPath($0.filePath) != standardizedPath(prompt.filePath) }) else {
            throw ResourceRenameError.duplicateName(newName)
        }
        let fileURL = URL(fileURLWithPath: prompt.filePath).standardizedFileURL
        if (try? fileURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw ResourceRenameError.unsupportedResource("Symlinked prompts cannot be renamed safely in app. Rename the real prompt file instead.")
        }
        let destinationURL = fileURL.deletingLastPathComponent().appendingPathComponent("\(newName).md")
        try ensureRenameDestinationAvailable(destinationURL, sourceURL: fileURL)
    }

    private func ensureRenameDestinationAvailable(_ destinationURL: URL, sourceURL: URL) throws {
        let destinationPath = destinationURL.standardizedFileURL.path
        let sourcePath = sourceURL.standardizedFileURL.path
        guard destinationPath.hasPrefix(sourceURL.deletingLastPathComponent().standardizedFileURL.path + "/") else {
            throw ResourceRenameError.unsafePath(destinationPath)
        }
        if pathExistsOrIsSymlink(destinationURL), destinationPath != sourcePath {
            throw ResourceRenameError.destinationExists(destinationPath)
        }
    }

    private func pathExistsOrIsSymlink(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path) || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private func moveItemIfNeeded(from sourceURL: URL, to destinationURL: URL) throws {
        let source = sourceURL.standardizedFileURL
        let destination = destinationURL.standardizedFileURL
        guard source.path != destination.path else { return }
        try FileManager.default.moveItem(at: source, to: destination)
    }

    private func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private func agentNameExists(_ name: String, excludingPaths: Set<String>) -> Bool {
        allAgentRecordsForReferenceUpdates().contains { record in
            record.name == name && !excludingPaths.contains(standardizedPath(record.filePath))
        }
    }

    private func allAgentRecordsForReferenceUpdates() -> [AgentRecord] {
        var seen = Set<String>()
        let snapshots = [snapshot, globalSnapshot] + Array(allProjectSnapshots.values)
        var records: [AgentRecord] = []
        for snapshot in snapshots {
            records.append(contentsOf: snapshot.libraryAgents)
            records.append(contentsOf: snapshot.globalAgents)
            records.append(contentsOf: snapshot.projectAgents)
            records.append(contentsOf: snapshot.legacyProjectAgents)
            records.append(contentsOf: snapshot.effectiveAgents.compactMap(\.winningRecord))
        }
        return records.filter { record in
            seen.insert(standardizedPath(record.filePath)).inserted
        }
    }

    private func allSkillRecordsForRenameValidation() -> [SkillRecord] {
        var seen = Set<String>()
        return ([snapshot, globalSnapshot] + Array(allProjectSnapshots.values))
            .flatMap { $0.skills + $0.librarySkills }
            .filter { seen.insert(standardizedPath($0.filePath)).inserted }
    }

    private func allPromptRecordsForRenameValidation() -> [PromptTemplateRecord] {
        var seen = Set<String>()
        return ([snapshot, globalSnapshot] + Array(allProjectSnapshots.values))
            .flatMap { $0.promptTemplates + $0.libraryPromptTemplates }
            .filter { seen.insert(standardizedPath($0.filePath)).inserted }
    }

    private func replaceSkillReferencesInCustomAgents(from oldName: String, to newName: String) throws {
        var seenWriteTargets = Set<String>()
        for record in allAgentRecordsForReferenceUpdates() where record.parsed.skills.contains(oldName) && record.source.kind != .builtin && record.source.kind != .package {
            let writeURL = customAgentWriteURL(for: record)
            guard seenWriteTargets.insert(writeURL.path).inserted else { continue }
            var config = record.parsed
            config.skills = config.skills.map { $0 == oldName ? newName : $0 }
            let text = agentPersistence.serializedText(for: config)
            try text.write(to: writeURL, atomically: true, encoding: .utf8)
        }
    }

    private func customAgentWriteURL(for record: AgentRecord) -> URL {
        URL(fileURLWithPath: record.filePath).standardizedFileURL
    }

    private func replaceSkillReferencesInBuiltinOverrides(from oldName: String, to newName: String) throws {
        // Builtin overrides are global-only. Never enumerate or rewrite a
        // project's `.pi/settings.json` while renaming a skill.
        let settingsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/settings.json")
            .standardizedFileURL.path
        let root = try loadJSONDictionary(at: settingsPath)
        guard let updatedRoot = Self.replacingBuiltinOverrideSkillReferences(in: root, from: oldName, to: newName) else { return }
        try writeJSONDictionary(updatedRoot, to: settingsPath)
    }

    static func replacingBuiltinOverrideSkillReferences(in root: [String: Any], from oldName: String, to newName: String) -> [String: Any]? {
        var updatedRoot = root
        guard var subagents = updatedRoot["subagents"] as? [String: Any], var overrides = subagents["agentOverrides"] as? [String: Any] else { return nil }
        var changed = false
        for key in overrides.keys {
            guard var override = overrides[key] as? [String: Any] else { continue }
            if let skills = override["skills"] as? [Any] {
                let updated = skills.map { value -> Any in
                    guard let skill = value as? String, skill == oldName else { return value }
                    changed = true
                    return newName
                }
                override["skills"] = updated
                overrides[key] = override
            } else if let skill = override["skills"] as? String, skill == oldName {
                override["skills"] = newName
                overrides[key] = override
                changed = true
            }
        }
        guard changed else { return nil }
        subagents["agentOverrides"] = overrides
        updatedRoot["subagents"] = subagents
        return updatedRoot
    }

    private func settingsContainPromptFile(_ filePath: String) -> Bool {
        let target = standardizedPath(filePath)
        return allSettingsPaths().contains { settingsPath in
            guard let root = try? loadJSONDictionary(at: settingsPath), let prompts = root["prompts"] else { return false }
            let baseURL = URL(fileURLWithPath: settingsPath).deletingLastPathComponent()
            return promptEntries(from: prompts).contains { standardizedPath(resolveSettingsPath($0, baseURL: baseURL).path) == target }
        }
    }

    private func replacePromptSettingsPaths(oldURLs: [URL], newURL: URL?) throws {
        let oldPaths = Set(oldURLs.map { $0.standardizedFileURL.path })
        for settingsPath in allSettingsPaths() {
            var root = try loadJSONDictionary(at: settingsPath)
            guard let prompts = root["prompts"] else { continue }
            let baseURL = URL(fileURLWithPath: settingsPath).deletingLastPathComponent()
            var changed = false
            func replacement(for entry: String) -> String? {
                let resolved = resolveSettingsPath(entry, baseURL: baseURL).standardizedFileURL.path
                guard oldPaths.contains(resolved) else { return entry }
                changed = true
                guard let newURL else { return nil }
                return rewrittenSettingsPath(for: newURL, originalEntry: entry, baseURL: baseURL)
            }
            if let value = prompts as? String {
                if let updatedValue = replacement(for: value) {
                    root["prompts"] = updatedValue
                } else {
                    root.removeValue(forKey: "prompts")
                }
            } else if let values = prompts as? [Any] {
                let updatedValues = values.compactMap { value -> Any? in
                    guard let entry = value as? String else { return value }
                    return replacement(for: entry)
                }
                if updatedValues.isEmpty {
                    root.removeValue(forKey: "prompts")
                } else {
                    root["prompts"] = updatedValues
                }
            }
            guard changed else { continue }
            try writeJSONDictionary(root, to: settingsPath)
        }
    }

    private func promptEntries(from rawValue: Any) -> [String] {
        if let value = rawValue as? String { return [value] }
        if let values = rawValue as? [Any] { return values.compactMap { $0 as? String } }
        return []
    }

    private func resolveSettingsPath(_ entry: String, baseURL: URL) -> URL {
        let expanded = NSString(string: entry).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded) }
        return baseURL.appendingPathComponent(expanded)
    }

    private func rewrittenSettingsPath(for newURL: URL, originalEntry: String, baseURL: URL) -> String {
        let expanded = NSString(string: originalEntry).expandingTildeInPath
        if expanded.hasPrefix("/") || originalEntry.hasPrefix("~") { return newURL.standardizedFileURL.path }
        let basePath = baseURL.standardizedFileURL.path
        let newPath = newURL.standardizedFileURL.path
        if newPath.hasPrefix(basePath + "/") {
            return String(newPath.dropFirst(basePath.count + 1))
        }
        return newPath
    }

    private func allSettingsPaths() -> [String] {
        var seen = Set<String>()
        return ([snapshot, globalSnapshot] + Array(allProjectSnapshots.values))
            .flatMap(\.settings)
            .map(\.path)
            .filter { seen.insert(standardizedPath($0)).inserted }
    }

    private func loadJSONDictionary(at path: String) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: path) else { return [:] }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard !data.isEmpty else { return [:] }
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private func writeJSONDictionary(_ dictionary: [String: Any], to path: String) throws {
        let data = try JSONSerialization.data(withJSONObject: dictionary, options: [.prettyPrinted, .sortedKeys])
        var text = String(decoding: data, as: UTF8.self)
        if !text.hasSuffix("\n") { text.append("\n") }
        try text.write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
    }

    /// Computes the path and seed content for a brand-new library prompt
    /// template without touching the disk. The `.md` file is written only when
    /// the user saves the editor sheet, so cancelling creates nothing.
    func newLibraryPromptTemplateDraft() -> (path: String, seedContent: String) {
        let fileManager = FileManager.default
        let libraryRoot = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/prompt-library", isDirectory: true)
        var candidate = "new-prompt"
        var index = 2
        while fileManager.fileExists(atPath: libraryRoot.appendingPathComponent("\(candidate).md").path) {
            candidate = "new-prompt-\(index)"
            index += 1
        }
        let url = libraryRoot.appendingPathComponent("\(candidate).md")
        let text = """
        ---
        description: Describe this reusable prompt template.
        argument-hint: "<task>"
        ---

        Write the reusable prompt template here. Use $ARGUMENTS where all slash-command arguments should be inserted.
        """
        return (url.path, text)
    }

    /// Registers an external prompt template file as a referenced library prompt
    /// and returns the source URL. The file stays where the user keeps it — Agent
    /// Deck scans and edits it in place, mirroring how external skills are imported.
    @discardableResult
    func importPromptTemplate(from sourceURL: URL) throws -> URL {
        let standardizedURL = sourceURL.standardizedFileURL
        guard FileManager.default.fileExists(atPath: standardizedURL.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        if appSettingsController.addExternalPromptPaths([standardizedURL.path]) {
            appSettings = appSettingsController.settings
        }
        refresh(includeModels: false)
        let importedName = standardizedURL.deletingPathExtension().lastPathComponent
        selectedCommandItemID = allVisiblePromptTemplateRecords.first { $0.name == importedName }?.id ?? selectedCommandItemID
        return standardizedURL
    }

    /// Presents a file picker for choosing a single markdown prompt file to import.
    func choosePromptFileToImport(completion: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Import Prompt"
        panel.message = LanguageStore.shared.t("vm.chooseMarkdownPrompt", AppBrand.displayName)
        let markdownTypes = ["md", "markdown", "mdown", "txt"].compactMap { UTType(filenameExtension: $0) }
        panel.allowedContentTypes = markdownTypes.isEmpty ? [.plainText] : markdownTypes + [.plainText]

        let handler: (NSApplication.ModalResponse) -> Void = { response in
            DispatchQueue.main.async {
                guard response == .OK, let url = panel.url?.standardizedFileURL else {
                    completion(nil)
                    return
                }
                completion(url)
            }
        }

        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            panel.begin(completionHandler: handler)
        }
    }

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

    func prompt(_ prompt: PromptTemplateRecord, isEnabledFor project: DiscoveredProject) -> Bool {
        projectPreference(for: project.path).assignedPromptTemplateNames.contains(prompt.name)
    }

    func assignedProjects(for prompt: PromptTemplateRecord) -> [DiscoveredProject] {
        enabledProjects.filter { self.prompt(prompt, isEnabledFor: $0) }
    }

    func promptIsEnabledGlobally(_ prompt: PromptTemplateRecord) -> Bool {
        appSettings.defaultPromptTemplateNames.contains(prompt.name)
    }

    func setPrompt(_ prompt: PromptTemplateRecord, enabled: Bool, for project: DiscoveredProject) throws {
        projectPreferencesStore.setAssignedPromptTemplate(prompt.name, assigned: enabled, for: project.path)
        applyProjectPreferenceChanges()
        // Project assignment only mutates UserDefaults — nothing on disk
        // changed. Reconcile snapshot-derived state in memory instead of
        // re-walking the filesystem, so the toggle is instant.
        reconcileSnapshotsFromPreferences()
        selectedCommandItemID = allVisiblePromptTemplateRecords.first { $0.name == prompt.name }?.id ?? selectedCommandItemID
    }

    func enablePromptGlobally(_ prompt: PromptTemplateRecord) throws {
        guard appSettingsController.setDefaultPromptTemplate(prompt.name, enabled: true) else { return }
        appSettings = appSettingsController.settings
        refresh(includeModels: false)
    }

    func disablePromptGlobally(_ prompt: PromptTemplateRecord) throws {
        guard appSettingsController.setDefaultPromptTemplate(prompt.name, enabled: false) else { return }
        appSettings = appSettingsController.settings
        refresh(includeModels: false)
    }

    func bundledPromptIsDisabled(_ prompt: PromptTemplateRecord) -> Bool {
        prompt.source.kind == .builtin && appSettings.disabledBundledPromptNames.contains(prompt.name)
    }

    func setBundledPromptDisabled(_ isDisabled: Bool, for prompt: PromptTemplateRecord) {
        guard prompt.source.kind == .builtin else { return }
        guard appSettingsController.setBundledPromptDisabled(prompt.name, isDisabled: isDisabled) else { return }
        appSettings = appSettingsController.settings
        refresh(includeModels: false)
    }

    func bundledSkillIsDisabled(_ skill: SkillRecord) -> Bool {
        skill.source.kind == .builtin && appSettings.disabledBundledSkillNames.contains(skill.name)
    }

    func setBundledSkillDisabled(_ isDisabled: Bool, for skill: SkillRecord) {
        guard skill.source.kind == .builtin else { return }
        guard appSettingsController.setBundledSkillDisabled(skill.name, isDisabled: isDisabled) else { return }
        appSettings = appSettingsController.settings
        refresh(includeModels: false)
    }

    func movePromptToLibrary(_ prompt: PromptTemplateRecord) throws {
        _ = try ensureLibraryPrompt(for: prompt)
        refresh(includeModels: false)
    }

    func canDeletePrompt(_ prompt: PromptTemplateRecord) -> Bool {
        switch prompt.source.kind {
        case .package:
            return false
        case .builtin, .global, .project, .legacyProject, .override, .library:
            return true
        }
    }

    func deletePrompt(_ prompt: PromptTemplateRecord) throws {
        guard canDeletePrompt(prompt) else { throw CocoaError(.fileWriteNoPermission) }

        // Throwing filesystem work first — optimistic hiding must not happen
        // unless it succeeds (the view shows an alert on throw).
        if prompt.discoveryKind == .externalReference {
            // Imported prompts are referenced in place — removing one only
            // un-registers the path. The user's original file is never trashed.
            try removePromptReferences(named: prompt.name)
            _ = appSettingsController.removeExternalPromptPaths([prompt.filePath])
            appSettings = appSettingsController.settings
        } else {
            try removePromptReferences(named: prompt.name)
            let fileURL = URL(fileURLWithPath: prompt.filePath).standardizedFileURL
            try FileManager.default.trashItem(at: fileURL, resultingItemURL: nil)
            try replacePromptSettingsPaths(oldURLs: [fileURL], newURL: nil)
            appSettings = appSettingsController.settings
        }

        // Hide the row immediately — no blocking rescan. The background refresh
        // prunes the pending id once the fresh snapshot confirms it's gone.
        withAnimation(.snappy(duration: 0.18)) {
            _ = pendingDeletedPromptIDs.insert(prompt.id)
        }
        selectedCommandItemID = allVisiblePromptTemplateRecords.first?.id
        refresh(includeModels: false, scanAllProjects: true)
    }

    func agent(_ agent: AgentRecord, isEnabledFor project: DiscoveredProject) -> Bool {
        projectPreference(for: project.path).assignedAgentNames.contains(agent.name)
    }

    func assignedProjects(for agent: AgentRecord) -> [DiscoveredProject] {
        enabledProjects.filter { self.agent(agent, isEnabledFor: $0) }
    }

    /// Read-only accessor for the per-agent skill-visibility cache. The full map
    /// is computed by `buildSkillVisibilityIssuesByAgentID()` at refresh
    /// boundaries (alongside the other warning caches), so this must NEVER
    /// recompute or touch disk — it is called from view bodies for every agent
    /// on every layout pass. Agents without issues are intentionally absent from
    /// the cache, so a miss means "no issues", not "needs recompute". The old
    /// recompute-on-miss path fell through to a synchronous `PiScanner().scan()`
    /// per healthy agent, producing multi-hundred-ms main-thread hangs on tab
    /// switches.
    func explicitSkillVisibilityIssues(for agent: EffectiveAgentRecord) -> [AgentSkillVisibilityIssue] {
        cachedSkillVisibilityIssuesByAgentID[agent.id] ?? []
    }

    private func skillNamed(_ skillName: String, isRuntimeVisibleIn project: DiscoveredProject) -> Bool {
        skillCatalog(forProjectPath: project.path).filter { $0.name == skillName }.count == 1
    }

    func unavailableSkillResolutionCandidate(for warning: SkillReferenceWarning) -> SkillRecord? {
        let records = deduplicateByID(
            allVisibleSkillRecords + allProjectSnapshots.values.flatMap { $0.skills + $0.librarySkills }
        )
        return records
            .filter { $0.name == warning.missingSkill }
            .filter { !skillNamed($0.name, isRuntimeVisibleIn: warning.project) }
            .sorted { lhs, rhs in
                let lhsIsProject = lhs.source.kind == .project || lhs.source.kind == .legacyProject
                let rhsIsProject = rhs.source.kind == .project || rhs.source.kind == .legacyProject
                if lhsIsProject != rhsIsProject { return lhsIsProject && !rhsIsProject }
                return lhs.filePath < rhs.filePath
            }
            .first
    }

    func moveSkillToGlobalCatalog(_ skill: SkillRecord) throws {
        try moveSkillToGlobalDirectory(skill)
        refresh(includeModels: false, scanAllProjects: true)
    }

    /// Recomputes cached model lists/lookups. Called only at real boundaries —
    /// app launch / activation, a model-list reload, or a settings change —
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

    private func rebuildExternalSkillPathCache() {
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

    func agentIsEnabledGlobally(_ agent: AgentRecord) -> Bool {
        appSettings.defaultAgentNames.contains(agent.name)
    }

    func setAgent(_ agent: AgentRecord, enabled: Bool, for project: DiscoveredProject) throws {
        projectPreferencesStore.setAssignedAgent(agent.name, assigned: enabled, for: project.path)
        applyProjectPreferenceChanges()
        // Project assignment only mutates UserDefaults — reconcile the
        // affected `effectiveAgents` in memory instead of rescanning disk.
        reconcileSnapshotsFromPreferences()
    }

    func assignAgentNames(_ names: [String], toProjectPath projectPath: String) {
        let cleaned = names
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !projectPath.isEmpty, !cleaned.isEmpty else { return }
        for name in Set(cleaned) {
            projectPreferencesStore.setAssignedAgent(name, assigned: true, for: projectPath)
        }
        applyProjectPreferenceChanges()
        reconcileSnapshotsFromPreferences()
    }

    func enableAgentGlobally(_ agent: AgentRecord) throws {
        guard appSettingsController.setDefaultAgent(agent.name, enabled: true) else { return }
        appSettings = appSettingsController.settings
        // Global assignment only mutates app settings. Reconcile the already-
        // loaded snapshots in memory so the row can move sections without a
        // refresh window that drops selection onto another agent.
        reconcileSnapshotsFromPreferences()
    }

    func disableAgentGlobally(_ agent: AgentRecord) throws {
        guard appSettingsController.setDefaultAgent(agent.name, enabled: false) else { return }
        appSettings = appSettingsController.settings
        // Global assignment only mutates app settings. Reconcile the already-
        // loaded snapshots in memory so the row can move sections without a
        // refresh window that drops selection onto another agent.
        reconcileSnapshotsFromPreferences()
    }

    func moveAgentToLibrary(_ agent: AgentRecord) throws {
        _ = try ensureLibraryAgent(for: agent)
        refresh(includeModels: false)
    }

    /// Custom and library agents own a real file that can be removed. Builtin and
    /// package agents are read-only — they are disabled or overridden, not deleted.
    func canDeleteAgent(_ agent: AgentRecord) -> Bool {
        switch agent.source.kind {
        case .builtin, .package:
            return false
        case .global, .project, .legacyProject, .override, .library:
            return true
        }
    }

    func deleteAgent(_ agent: AgentRecord) throws {
        guard canDeleteAgent(agent) else { throw CocoaError(.fileWriteNoPermission) }

        try removeAgentReferences(named: agent.name)
        let fileURL = URL(fileURLWithPath: agent.filePath).standardizedFileURL
        try FileManager.default.trashItem(at: fileURL, resultingItemURL: nil)
        // Reconcile in the background — no blocking rescan. The row updates
        // when the fresh snapshot lands; a builtin of the same name correctly
        // reappears instead of the row being wrongly hidden, so agent deletion
        // is not optimistically hidden the way skill/prompt deletion is.
        refresh(includeModels: false, scanAllProjects: true)
    }

    private func removeAgentReferences(named agentName: String) throws {
        _ = appSettingsController.setDefaultAgent(agentName, enabled: false)
        appSettings = appSettingsController.settings

        for projectPath in projectPreferencesStore.preferencesByPath.keys {
            projectPreferencesStore.setAssignedAgent(agentName, assigned: false, for: projectPath)
        }
        applyProjectPreferenceChanges()
    }

    private func removePromptReferences(named promptName: String) throws {
        _ = appSettingsController.setDefaultPromptTemplate(promptName, enabled: false)
        appSettings = appSettingsController.settings

        for projectPath in projectPreferencesStore.preferencesByPath.keys {
            projectPreferencesStore.setAssignedPromptTemplate(promptName, assigned: false, for: projectPath)
        }
        applyProjectPreferenceChanges()
    }

    func addSkillToSelectedProject(_ skill: SkillRecord) throws {
        guard let selectedProjectPath else { throw CocoaError(.fileNoSuchFile) }
        try setSkill(skill, enabled: true, forProjectPath: selectedProjectPath)
    }

    func removeSkillFromSelectedProject(_ skill: SkillRecord) throws {
        guard let selectedProjectPath else { throw CocoaError(.fileNoSuchFile) }
        try setSkill(skill, enabled: false, forProjectPath: selectedProjectPath)
    }

    func setSkill(_ skill: SkillRecord, enabled: Bool, for project: DiscoveredProject) throws {
        try setSkill(skill, enabled: enabled, forProjectPath: project.path)
    }

    func skill(_ skill: SkillRecord, isEnabledFor project: DiscoveredProject) -> Bool {
        projectPreference(for: project.path).assignedSkillNames.contains(skill.name)
    }

    func assignedProjects(for skill: SkillRecord) -> [DiscoveredProject] {
        enabledProjects.filter { self.skill(skill, isEnabledFor: $0) }
    }

    func skill(_ skill: SkillRecord, isAssignedTo agent: EffectiveAgentRecord) -> Bool {
        agent.resolved.skills.contains(skill.name)
    }

    func setSkill(_ skill: SkillRecord, enabled: Bool, for agent: EffectiveAgentRecord) throws {
        try setAgentSkillName(skill.name, enabled: enabled, for: agent)
    }

    func assignedAgents(for skillRecord: SkillRecord) -> [EffectiveAgentRecord] {
        snapshot.effectiveAgents.filter { skill(skillRecord, isAssignedTo: $0) }
    }

    func skillCollection(_ collection: SkillCollectionRecord, isAssignedTo agent: EffectiveAgentRecord) -> Bool {
        agent.resolved.skills.contains(collection.name)
    }

    func setSkillCollection(_ collection: SkillCollectionRecord, enabled: Bool, for agent: EffectiveAgentRecord) throws {
        try setAgentSkillName(collection.name, enabled: enabled, for: agent)
    }

    func assignedAgents(for collection: SkillCollectionRecord) -> [EffectiveAgentRecord] {
        snapshot.effectiveAgents.filter { skillCollection(collection, isAssignedTo: $0) }
    }

    private func setAgentSkillName(_ name: String, enabled: Bool, for agent: EffectiveAgentRecord) throws {
        guard var draft = makeAgentDraft(for: agent) else { throw CocoaError(.fileNoSuchFile) }
        var skills = draft.config.skills
        if enabled {
            if !skills.contains(name) { skills.append(name) }
        } else {
            skills.removeAll { $0 == name }
        }
        draft.config.skills = PiSkillLaunchResolver.normalizedNames(skills)
        try saveAgentDraft(draft, for: agent)
        // `saveAgentDraft` rewrites the agent `.md` and schedules a background
        // rescan, but the toggle's checkbox is snapshot-derived. Patch the
        // in-memory effective agent so the checkbox flips immediately instead
        // of waiting for that rescan to land.
        patchEffectiveAgentSkills(agentName: agent.name, skills: draft.config.skills)
        rebuildWarningCaches()
        reconcileRunningSessionLaunchResourceFingerprints()
    }

    private func setSkill(_ skill: SkillRecord, enabled: Bool, forProjectPath projectPath: String) throws {
        projectPreferencesStore.setAssignedSkill(skill.name, assigned: enabled, for: projectPath)
        applyProjectPreferenceChanges()
        // Project assignment only mutates UserDefaults — nothing on disk
        // changed. Reconcile snapshot-derived state in memory instead of
        // re-walking the filesystem, so the toggle is instant.
        reconcileSnapshotsFromPreferences()
        selectedSkillID = allVisibleSkillRecords.first { $0.name == skill.name }?.id ?? selectedSkillID
    }

    func enableSkillGlobally(_ skill: SkillRecord) throws {
        guard appSettingsController.setDefaultSkill(skill.name, enabled: true) else {
            refresh(includeModels: false, scanAllProjects: true)
            selectedSkillID = allVisibleSkillRecords.first { $0.name == skill.name }?.id ?? selectedSkillID
            return
        }
        appSettings = appSettingsController.settings
        refresh(includeModels: false, scanAllProjects: true)
        selectedSkillID = allVisibleSkillRecords.first { $0.name == skill.name }?.id ?? selectedSkillID
    }

    func disableSkillGlobally(_ skill: SkillRecord) throws {
        guard appSettingsController.setDefaultSkill(skill.name, enabled: false) else { return }
        appSettings = appSettingsController.settings
        refresh(includeModels: false)
    }

    func canDeleteSkill(_ skill: SkillRecord) -> Bool {
        switch skill.source.kind {
        case .builtin, .package:
            return false
        case .global, .project, .legacyProject, .override, .library:
            return true
        }
    }

    /// Filesystem + state mutations for deleting one skill, WITHOUT triggering
    /// a refresh. The caller is responsible for calling `refresh()` once after
    /// all desired deletions — single call sites do it inline, batch call sites
    /// do it once after the loop.
    private func performSkillDeletion(_ skill: SkillRecord) throws {
        guard canDeleteSkill(skill) else { throw CocoaError(.fileWriteNoPermission) }
        // Codex plugin packages are owned by Codex. "Delete" means un-import,
        // never modifying or trashing a cache file.
        if cachedResolvedCodexPluginSkillPaths.values.contains(skillDeletionTargetURL(for: skill).standardizedFileURL.path) {
            try performSkillCatalogRemoval(skill)
            return
        }

        // Throwing filesystem work first — optimistic hiding must not happen
        // unless these succeed (SkillsScreen shows an alert on throw).
        let targetURL = skillDeletionTargetURL(for: skill)
        try removeSkillReferences(named: skill.name)
        try FileManager.default.trashItem(at: targetURL, resultingItemURL: nil)
        removeExternalSkillCatalogReferences(for: skill, deletedTarget: targetURL)
        unlistSkillFromSyncedRepository(skill)

        // Hide the row immediately — no blocking rescan. SwiftUI updates the
        // list the instant the published set changes, like session deletion.
        withAnimation(.snappy(duration: 0.18)) {
            _ = pendingDeletedSkillIDs.insert(skill.id)
        }
        // Recompute selection AFTER hiding so the deleted skill isn't re-picked.
        selectedSkillID = allVisibleSkillRecords.first?.id
    }

    func deleteSkill(_ skill: SkillRecord) throws {
        try performSkillDeletion(skill)
        // Reconcile in the background; applyRefreshSnapshot prunes the pending
        // ID once the fresh snapshot confirms the skill is gone. `silentlyReconcile`
        // because `pendingDeletedSkillIDs.insert` already hid the row.
        refresh(includeModels: false, scanAllProjects: true, silentlyReconcile: true)
    }

    /// Batch delete: filesystem work per skill, then a single refresh. Returns
    /// the names of skills whose deletion threw (e.g. protected source kinds).
    /// Avoids the N-refresh storm of looping `deleteSkill(_:)`.
    func deleteSkills(_ skills: [SkillRecord]) -> [String] {
        var failed: [String] = []
        for skill in skills {
            do { try performSkillDeletion(skill) }
            catch { failed.append(skill.name) }
        }
        if skills.count > failed.count {
            refresh(includeModels: false, scanAllProjects: true, silentlyReconcile: true)
        }
        return failed
    }

    /// True when `skill` was imported — its root path is tracked in
    /// `externalSkillPaths` (a local-folder import or a Git-synced repo skill).
    func isImportedSkill(_ skill: SkillRecord) -> Bool {
        let filePath = URL(fileURLWithPath: skill.filePath).standardizedFileURL.path
        let rootPath = skillDeletionTargetURL(for: skill).standardizedFileURL.path
        if cachedResolvedCodexPluginSkillPaths.values.contains(where: { $0 == rootPath || $0 == filePath }) { return true }
        let paths = cachedStandardizedExternalSkillPaths
        return paths.contains(filePath) || paths.contains(rootPath)
    }

    /// Filesystem + state mutations for un-importing one skill, WITHOUT
    /// triggering a refresh. See `performSkillDeletion(_:)` for rationale.
    private func performSkillCatalogRemoval(_ skill: SkillRecord) throws {
        guard isImportedSkill(skill) else { throw CocoaError(.fileWriteNoPermission) }

        let fileURL = URL(fileURLWithPath: skill.filePath).standardizedFileURL
        let rootURL = skillDeletionTargetURL(for: skill).standardizedFileURL
        let pluginReferences = Set(cachedResolvedCodexPluginSkillPaths.compactMap { reference, path in
            path == rootURL.path || path == fileURL.path ? reference : nil
        })

        // Clear name-based assignments so no dangling missing-skill warning is
        // left behind — same as deletion, minus the trashing.
        try removeSkillReferences(named: skill.name)

        let pathsToRemove = appSettings.externalSkillPaths.filter { rawPath in
            let path = URL(fileURLWithPath: rawPath).standardizedFileURL.path
            return path == rootURL.path || path == fileURL.path
        }
        let removedPath = appSettingsController.removeExternalSkillPaths(pathsToRemove)
        let removedPlugin = appSettingsController.removeCodexPluginSkillReferences(pluginReferences)
        if removedPath || removedPlugin { appSettings = appSettingsController.settings }
        unlistSkillFromSyncedRepository(skill)

        withAnimation(.snappy(duration: 0.18)) {
            _ = pendingDeletedSkillIDs.insert(skill.id)
        }
        selectedSkillID = allVisibleSkillRecords.first?.id
    }

    /// Un-import a skill: drop it from the catalog without trashing its files.
    /// For a Git-synced skill the repository clone is kept; the skill is just
    /// un-listed from that repository's synced set.
    func removeSkillFromCatalog(_ skill: SkillRecord) throws {
        try performSkillCatalogRemoval(skill)
        refresh(includeModels: false, scanAllProjects: true, silentlyReconcile: true)
    }

    /// Batch un-import: filesystem work per skill, then a single refresh.
    /// Returns the names of skills whose removal threw.
    func removeSkillsFromCatalog(_ skills: [SkillRecord]) -> [String] {
        var failed: [String] = []
        for skill in skills {
            do { try performSkillCatalogRemoval(skill) }
            catch { failed.append(skill.name) }
        }
        if skills.count > failed.count {
            refresh(includeModels: false, scanAllProjects: true, silentlyReconcile: true)
        }
        return failed
    }

    /// Resolves a duplicate skill name by keeping one canonical copy and
    /// removing all other copies. Project assignments, global defaults, and
    /// agent skill lists keyed by the skill name are intentionally preserved,
    /// because the name remains valid via the kept copy.
    func resolveSkillDuplicate(keeping keptSkill: SkillRecord, removing removedSkills: [SkillRecord]) throws {
        try SkillDuplicateResolution.removeDuplicateCopies(
            keeping: keptSkill,
            removing: removedSkills,
            canDelete: canDeleteSkill,
            delete: { [weak self] skill in
                guard let self else { return }
                let url = self.skillDeletionTargetURL(for: skill)
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                self.removeExternalSkillCatalogReferences(for: skill, deletedTarget: url)
                self.unlistSkillFromSyncedRepository(skill)
            },
            isImported: isImportedSkill,
            removeExternalPath: { [weak self] skill in
                guard let self else { return }
                let url = self.skillDeletionTargetURL(for: skill)
                self.removeExternalSkillCatalogReferences(for: skill, deletedTarget: url)
            },
            unlistFromSyncedRepository: { [weak self] skill in
                self?.unlistSkillFromSyncedRepository(skill)
            }
        )

        // Hide removed rows immediately. `removeDuplicateCopies` already
        // performed the file/catalog work; this only updates the UI.
        withAnimation(.snappy(duration: 0.18)) {
            for skill in removedSkills {
                _ = pendingDeletedSkillIDs.insert(skill.id)
            }
        }

        // Select the kept copy. Because its id is unchanged, this is stable.
        selectedSkillID = keptSkill.id
        refresh(includeModels: false, scanAllProjects: true, silentlyReconcile: true)
    }

    /// Drop `skill` from its synced repository's tracked set, if it belongs to
    /// one. When that leaves the repository with no synced skills, the whole
    /// repository is un-registered — its record is removed (so it is no longer
    /// polled for updates) and its app-managed clone is deleted.
    private func unlistSkillFromSyncedRepository(_ skill: SkillRecord) {
        guard let repository = importedRepository(for: skill) else { return }
        let rootPath = skillDeletionTargetURL(for: skill).standardizedFileURL.path
        let cloneURL = URL(fileURLWithPath: repository.clonePath, isDirectory: true).standardizedFileURL

        var remaining = repository.syncedSkillRelativePaths
        remaining.removeAll { relativePath in
            let candidate = relativePath.isEmpty
                ? cloneURL.path
                : cloneURL.appendingPathComponent(relativePath, isDirectory: true).standardizedFileURL.path
            return candidate == rootPath
        }
        guard remaining != repository.syncedSkillRelativePaths else { return }

        if remaining.isEmpty {
            // Nothing left synced from this repository — fully un-register it so
            // it is no longer checked for updates, and drop its app-managed clone.
            appSettingsController.removeImportedSkillRepository(id: repository.id)
            removeSkillCollection(forRepositoryID: repository.id)
            try? FileManager.default.removeItem(at: cloneURL)
        } else {
            var updated = repository
            updated.syncedSkillRelativePaths = remaining
            appSettingsController.upsertImportedSkillRepository(updated)
            updateSkillCollection(for: updated)
            reconcileSparseCheckout(for: updated)
        }
        appSettings = appSettingsController.settings
    }

    private func removeSkillCollection(forRepositoryID repositoryID: UUID) {
        guard let collection = appSettingsController.settings.skillCollections.first(where: { $0.importedRepositoryID == repositoryID }) else { return }
        appSettingsController.removeSkillCollection(id: collection.id)
        for projectPath in projectPreferencesStore.preferencesByPath.keys {
            projectPreferencesStore.setAssignedSkillCollection(collection.id, assigned: false, for: projectPath)
        }
    }

    private func updateSkillCollection(for repository: ImportedSkillRepository) {
        guard var collection = appSettingsController.settings.skillCollections.first(where: { $0.importedRepositoryID == repository.id }) else { return }
        collection.skillRootPaths = Set(repository.syncedSkillRootPaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        appSettingsController.upsertSkillCollection(collection)
    }

    /// Keep Git's sparse-checkout patterns aligned with Agent Deck's tracked
    /// imported-skill set. This is best-effort because the user-facing removal
    /// already succeeded once settings were updated.
    private func reconcileSparseCheckout(for repository: ImportedSkillRepository) {
        let cloneURL = URL(fileURLWithPath: repository.clonePath, isDirectory: true)
        let directories = repository.syncedSkillRelativePaths.filter { !$0.isEmpty }
        Task { [skillRepositorySyncService] in
            do {
                try await skillRepositorySyncService.setSparseCheckout(directories, inCloneAt: cloneURL)
            } catch {
#if DEBUG
                NSLog("Failed to reconcile sparse checkout for imported skill repository %@: %@", repository.displayName, String(describing: error))
#endif
            }
        }
    }

    func skillIsEnabledGlobally(_ skill: SkillRecord) -> Bool {
        appSettings.defaultSkillNames.contains(skill.name)
    }

    private func moveSkillToGlobalDirectory(_ skill: SkillRecord) throws {
        let fileURL = URL(fileURLWithPath: skill.filePath).standardizedFileURL
        let sourceURL = skillMoveSourceURL(fileURL: fileURL)
        let destinationRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/skills", isDirectory: true)
            .standardizedFileURL
        let destinationURL = destinationRoot.appendingPathComponent(skill.name, isDirectory: true)

        guard !isSymbolicLink(sourceURL), !isSymbolicLink(fileURL) else {
            throw ResourceRenameError.unsupportedResource("Symlinked skills cannot be made Default safely in app. Move the real skill folder to ~/.pi/agent/skills instead.")
        }
        guard sourceURL.standardizedFileURL.path != destinationURL.standardizedFileURL.path else { return }
        try ensureGlobalSkillDestinationAvailable(destinationURL, sourceURL: sourceURL)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true, attributes: nil)

        if fileURL.lastPathComponent == "SKILL.md" {
            try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
        } else {
            try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: false, attributes: nil)
            try FileManager.default.moveItem(at: sourceURL, to: destinationURL.appendingPathComponent("SKILL.md"))
        }
    }

    private func skillMoveSourceURL(fileURL: URL) -> URL {
        if fileURL.lastPathComponent == "SKILL.md" {
            return fileURL.deletingLastPathComponent().standardizedFileURL
        }
        return fileURL.standardizedFileURL
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true ||
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private func ensureGlobalSkillDestinationAvailable(_ destinationURL: URL, sourceURL: URL) throws {
        let destination = destinationURL.standardizedFileURL
        let source = sourceURL.standardizedFileURL
        guard destination.path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/skills", isDirectory: true).standardizedFileURL.path + "/") else {
            throw ResourceRenameError.unsafePath(destination.path)
        }
        if pathExistsOrIsSymlink(destination), destination.path != source.path {
            throw ResourceRenameError.destinationExists(destination.path)
        }
    }

    func skillIsEnabledForSelectedProject(_ skill: SkillRecord) -> Bool {
        guard let selectedProjectPath else { return false }
        return projectPreference(for: selectedProjectPath).assignedSkillNames.contains(skill.name)
    }

    func skillRecap(for project: DiscoveredProject) -> ProjectSkillRecap {
        let defaultNames = appSettings.defaultSkillNames
        let projectNames = projectPreference(for: project.path).assignedSkillNames.subtracting(defaultNames)
        let catalog = skillCatalog(forProjectPath: project.path)
        let grouped = Dictionary(grouping: catalog, by: \.name)

        func resolvedSkills(for names: Set<String>) -> ([SkillRecord], [String]) {
            var skills: [SkillRecord] = []
            var unresolved: [String] = []

            for name in names.sorted() {
                let matches = grouped[name] ?? []
                if matches.count == 1, let skill = matches.first {
                    skills.append(skill)
                } else {
                    unresolved.append(name)
                }
            }

            return (
                skills.sorted { lhs, rhs in
                    lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                },
                unresolved
            )
        }

        let defaultResult = resolvedSkills(for: defaultNames)
        let projectResult = resolvedSkills(for: projectNames)
        return ProjectSkillRecap(
            defaultSkills: defaultResult.0,
            projectSkills: projectResult.0,
            unresolvedNames: (defaultResult.1 + projectResult.1).sorted()
        )
    }

    /// MCP servers assigned to a project (global defaults + per-project), resolved
    /// against the merged `mcp.json` so the project-row summary can list them like
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

    func parentSkillArguments(for projectURL: URL) throws -> [String] {
        let projectPath = projectURL.standardizedFileURL.path
        let names = effectiveSkillNames(
            directNames: appSettings.defaultSkillNames.union(projectPreference(for: projectPath).assignedSkillNames),
            collectionIDs: appSettings.defaultSkillCollectionIDs.union(projectPreference(for: projectPath).assignedSkillCollectionIDs),
            catalog: skillCatalog(forProjectPath: projectPath)
        )
        return try PiSkillLaunchResolver.skillArguments(for: names, catalog: skillCatalog(forProjectPath: projectPath), missingSkillPolicy: .skip)
    }

    private func agentDeckBuilderSkillArguments() -> [String] {
        globalCatalogSnapshot.skills
            .filter { $0.source.kind == .builtin }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .flatMap { ["--skill", $0.filePath] }
    }

    func parentPromptTemplateArguments(for projectURL: URL) throws -> [String] {
        let projectPath = projectURL.standardizedFileURL.path
        let names = Array(appSettings.defaultPromptTemplateNames.union(projectPreference(for: projectPath).assignedPromptTemplateNames))
        return try PiPromptTemplateLaunchResolver.promptTemplateArguments(for: names, catalog: promptTemplateCatalog(forProjectPath: projectPath), missingPromptPolicy: .skip)
    }

    private func promptTemplateCatalog(forProjectPath projectPath: String) -> [PromptTemplateRecord] {
        let records = globalSnapshot.promptTemplates + globalSnapshot.libraryPromptTemplates
        let disabledBundled = appSettings.disabledBundledPromptNames
        var seen = Set<String>()
        return records
            .filter { !($0.source.kind == .builtin && disabledBundled.contains($0.name)) }
            .filter { seen.insert($0.id).inserted }
    }

    func skillCatalog(forProjectPath projectPath: String) -> [SkillRecord] {
        let records = globalSnapshot.skills + globalSnapshot.librarySkills
        let disabledBundled = appSettings.disabledBundledSkillNames
        var seen = Set<String>()
        return records
            .filter { !($0.source.kind == .builtin && disabledBundled.contains($0.name)) }
            .filter { seen.insert($0.id).inserted }
    }

    func skillRecords(in collection: SkillCollectionRecord, forProjectPath projectPath: String? = nil) -> [SkillRecord] {
        let catalog: [SkillRecord]
        if let projectPath {
            catalog = skillCatalog(forProjectPath: projectPath)
        } else {
            catalog = allVisibleSkillRecords
        }
        var records: [SkillRecord] = []
        var seenIDs = Set<String>()
        for skill in catalog where skillBelongsToCollection(skill, collection: collection, catalog: catalog) {
            if seenIDs.insert(skill.id).inserted { records.append(skill) }
        }
        return records.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func skillCollectionMemberIDsByCollectionID(for collections: [SkillCollectionRecord], forProjectPath projectPath: String? = nil) -> [UUID: Set<SkillRecord.ID>] {
        let catalog: [SkillRecord]
        if let projectPath {
            catalog = skillCatalog(forProjectPath: projectPath)
        } else {
            catalog = allVisibleSkillRecords
        }
        guard !collections.isEmpty, !catalog.isEmpty else {
            return Dictionary(uniqueKeysWithValues: collections.map { ($0.id, Set<SkillRecord.ID>()) })
        }

        let nameCounts = Dictionary(grouping: catalog, by: \.name).mapValues(\.count)
        let normalizedCollections = collections.map { collection in
            (
                id: collection.id,
                rootPaths: Set(collection.skillRootPaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }),
                skillNames: collection.skillNames
            )
        }
        let normalizedSkills = catalog.map { skill in
            (
                id: skill.id,
                name: skill.name,
                rootPath: skillDeletionTargetURL(for: skill).path,
                filePath: URL(fileURLWithPath: skill.filePath).standardizedFileURL.path
            )
        }

        var memberIDsByCollectionID = Dictionary(uniqueKeysWithValues: collections.map { ($0.id, Set<SkillRecord.ID>()) })
        for normalizedSkill in normalizedSkills {
            for collection in normalizedCollections {
                let isRootMatch = collection.rootPaths.contains(normalizedSkill.rootPath) || collection.rootPaths.contains(normalizedSkill.filePath)
                let isUniqueNameFallback = collection.skillNames.contains(normalizedSkill.name) && nameCounts[normalizedSkill.name] == 1
                if isRootMatch || isUniqueNameFallback {
                    memberIDsByCollectionID[collection.id, default: []].insert(normalizedSkill.id)
                }
            }
        }
        return memberIDsByCollectionID
    }

    func skillCollections(containing skill: SkillRecord) -> [SkillCollectionRecord] {
        let catalog = selectedProjectPath.map { skillCatalog(forProjectPath: $0) } ?? allVisibleSkillRecords
        return appSettings.skillCollections.filter { collection in
            skillBelongsToCollection(skill, collection: collection, catalog: catalog)
        }
    }

    func saveSkillCollection(_ collection: SkillCollectionRecord) {
        guard appSettingsController.upsertSkillCollection(collection) else { return }
        appSettings = appSettingsController.settings
        refresh(includeModels: false, scanAllProjects: true)
    }

    func removeSkillCollection(_ collection: SkillCollectionRecord) {
        guard appSettingsController.removeSkillCollection(id: collection.id) else { return }
        for projectPath in projectPreferencesStore.preferencesByPath.keys {
            projectPreferencesStore.setAssignedSkillCollection(collection.id, assigned: false, for: projectPath)
        }
        for agent in snapshot.effectiveAgents where agent.resolved.skills.contains(collection.name) {
            guard var draft = makeAgentDraft(for: agent) else { continue }
            draft.config.skills.removeAll { $0 == collection.name }
            try? agentPersistence.save(draft, original: agent, projectRoot: selectedProjectPath)
        }
        appSettings = appSettingsController.settings
        applyProjectPreferenceChanges()
        refresh(includeModels: false, scanAllProjects: true)
    }

    func skillRootPath(forCollectionMembership skill: SkillRecord) -> String {
        let fileURL = URL(fileURLWithPath: skill.filePath).standardizedFileURL
        return fileURL.lastPathComponent == "SKILL.md"
            ? fileURL.deletingLastPathComponent().path
            : fileURL.path
    }

    private func skillBelongsToCollection(_ skill: SkillRecord, collection: SkillCollectionRecord, catalog: [SkillRecord]) -> Bool {
        let rootPaths = Set(collection.skillRootPaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        let rootPath = skillDeletionTargetURL(for: skill).standardizedFileURL.path
        let filePath = URL(fileURLWithPath: skill.filePath).standardizedFileURL.path
        if rootPaths.contains(rootPath) || rootPaths.contains(filePath) { return true }
        guard collection.skillNames.contains(skill.name) else { return false }
        // Name fallback is only safe when the catalog has a single matching name;
        // otherwise a stale collection member would accidentally expand to every
        // duplicate and turn an unrelated duplicate into a launch blocker.
        return catalog.filter { $0.name == skill.name }.count == 1
    }

    func skillIsExcludedFromRuntime(_ skill: SkillRecord, in collection: SkillCollectionRecord, catalog: [SkillRecord]? = nil) -> Bool {
        let excludedRootPaths = Set(collection.excludedSkillRootPaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        let rootPath = skillDeletionTargetURL(for: skill).standardizedFileURL.path
        let filePath = URL(fileURLWithPath: skill.filePath).standardizedFileURL.path
        if excludedRootPaths.contains(rootPath) || excludedRootPaths.contains(filePath) { return true }
        guard collection.excludedSkillNames.contains(skill.name) else { return false }
        let lookupCatalog = catalog ?? (selectedProjectPath.map { skillCatalog(forProjectPath: $0) } ?? allVisibleSkillRecords)
        return lookupCatalog.filter { $0.name == skill.name }.count == 1
    }

    func skillCollectionIsEnabledGlobally(_ collection: SkillCollectionRecord) -> Bool {
        appSettings.defaultSkillCollectionIDs.contains(collection.id)
    }

    func skillCollection(_ collection: SkillCollectionRecord, isEnabledFor project: DiscoveredProject) -> Bool {
        projectPreference(for: project.path).assignedSkillCollectionIDs.contains(collection.id)
    }

    func setSkillCollection(_ collection: SkillCollectionRecord, enabled: Bool, for project: DiscoveredProject) {
        projectPreferencesStore.setAssignedSkillCollection(collection.id, assigned: enabled, for: project.path)
        applyProjectPreferenceChanges()
        reconcileSnapshotsFromPreferences()
    }

    func enableSkillCollectionGlobally(_ collection: SkillCollectionRecord) {
        guard appSettingsController.setDefaultSkillCollection(collection.id, enabled: true) else { return }
        appSettings = appSettingsController.settings
        refresh(includeModels: false, scanAllProjects: true)
    }

    func disableSkillCollectionGlobally(_ collection: SkillCollectionRecord) {
        guard appSettingsController.setDefaultSkillCollection(collection.id, enabled: false) else { return }
        appSettings = appSettingsController.settings
        refresh(includeModels: false)
    }

    private func effectiveSkillNames(directNames: Set<String>, collectionIDs: Set<UUID>, catalog: [SkillRecord]) -> [String] {
        var names = directNames
        let collectionsByID = Dictionary(uniqueKeysWithValues: appSettings.skillCollections.map { ($0.id, $0) })
        for id in collectionIDs {
            guard let collection = collectionsByID[id] else { continue }
            for skill in catalog where skillBelongsToCollection(skill, collection: collection, catalog: catalog) && !skillIsExcludedFromRuntime(skill, in: collection, catalog: catalog) {
                names.insert(skill.name)
            }
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Names of the skills actually loaded into the parent session for
    /// `projectPath`: global defaults ∪ project-assigned. This is the exact set
    /// `parentSkillArguments` launches the orchestrator with — the single source
    /// of truth shared by the composer `/` browser's `isActive` flag and the
    /// session-resources popover, so neither recomputes it independently.
    func activeParentSkillNames(forProjectPath projectPath: String?, useSelectedProjectFallback: Bool = true) -> Set<String> {
        let fallback = useSelectedProjectFallback ? selectedProjectPath : nil
        let path = (projectPath ?? fallback)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        var directNames = appSettings.defaultSkillNames
        var collectionIDs = appSettings.defaultSkillCollectionIDs
        if let path {
            let preference = projectPreference(for: path)
            directNames.formUnion(preference.assignedSkillNames)
            collectionIDs.formUnion(preference.assignedSkillCollectionIDs)
        }
        let catalog = path.map { skillCatalog(forProjectPath: $0) } ?? (globalSnapshot.skills + globalSnapshot.librarySkills)
        let availableSkillNames = Set(catalog.map(\.name))
        return Set(effectiveSkillNames(directNames: directNames, collectionIDs: collectionIDs, catalog: catalog))
            .filter { availableSkillNames.contains($0) }
    }

    /// The resolved `SkillRecord`s actually available to the parent session for
    /// `projectPath` — the active names above, resolved against the same
    /// disabled-bundled-filtered catalog the launch path uses, deduped by name.
    func activeParentSkills(forProjectPath projectPath: String?) -> [SkillRecord] {
        let scopedPath = (projectPath ?? selectedProjectPath)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        let activeNames = activeParentSkillNames(forProjectPath: scopedPath)
        let catalog: [SkillRecord]
        if let path = scopedPath {
            catalog = skillCatalog(forProjectPath: path)
        } else {
            var seen = Set<String>()
            catalog = (globalSnapshot.skills + globalSnapshot.librarySkills).filter { seen.insert($0.id).inserted }
        }
        var seenName = Set<String>()
        return catalog
            .filter { activeNames.contains($0.name) }
            .filter { seenName.insert($0.name).inserted }
    }

    /// Prompt-template analogue of `activeParentSkillNames`: the templates the
    /// parent session is launched with (`parentPromptTemplateArguments`).
    func activeParentPromptTemplateNames(forProjectPath projectPath: String?, useSelectedProjectFallback: Bool = true) -> Set<String> {
        var names = appSettings.defaultPromptTemplateNames
        let fallback = useSelectedProjectFallback ? selectedProjectPath : nil
        let scopedPath = (projectPath ?? fallback)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        if let scopedPath {
            names.formUnion(projectPreference(for: scopedPath).assignedPromptTemplateNames)
        }
        let catalog = scopedPath.map { promptTemplateCatalog(forProjectPath: $0) } ?? allVisiblePromptTemplateRecords
        let availablePromptNames = Set(catalog.map(\.name))
        return Set(names.filter { availablePromptNames.contains($0) })
    }

    /// The resolved `PromptTemplateRecord`s actually available to the parent
    /// session for `projectPath`, deduped by name. Shared by the `/` browser's
    /// `isActive` flag and the session-resources popover.
    func activeParentPromptTemplates(forProjectPath projectPath: String?) -> [PromptTemplateRecord] {
        let scopedPath = (projectPath ?? selectedProjectPath)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        let activeNames = activeParentPromptTemplateNames(forProjectPath: scopedPath)
        let catalog: [PromptTemplateRecord]
        if let path = scopedPath {
            catalog = promptTemplateCatalog(forProjectPath: path)
        } else {
            catalog = allVisiblePromptTemplateRecords
        }
        var seenName = Set<String>()
        return catalog
            .filter { activeNames.contains($0.name) }
            .filter { seenName.insert($0.name).inserted }
    }

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

    private func skillDeletionTargetURL(for skill: SkillRecord) -> URL {
        let fileURL = URL(fileURLWithPath: skill.filePath).standardizedFileURL
        if fileURL.lastPathComponent == "SKILL.md" {
            return fileURL.deletingLastPathComponent()
        }
        return fileURL
    }

    private func removeSkillReferences(named skillName: String) throws {
        _ = appSettingsController.setDefaultSkill(skillName, enabled: false)
        appSettings = appSettingsController.settings

        for projectPath in projectPreferencesStore.preferencesByPath.keys {
            projectPreferencesStore.setAssignedSkill(skillName, assigned: false, for: projectPath)
        }
        applyProjectPreferenceChanges()

        for agent in snapshot.effectiveAgents where agent.resolved.skills.contains(skillName) {
            guard var draft = makeAgentDraft(for: agent) else { continue }
            draft.config.skills.removeAll { $0 == skillName }
            // Persist without a per-agent refresh — `saveAgentDraft` would
            // trigger a synchronous rescan per agent. The single trailing
            // refresh(scanAllProjects:) in deleteSkill picks up every edit.
            try agentPersistence.save(draft, original: agent, projectRoot: selectedProjectPath)
        }
    }

    private func removeExternalSkillCatalogReferences(for skill: SkillRecord, deletedTarget: URL) {
        let fileURL = URL(fileURLWithPath: skill.filePath).standardizedFileURL
        let deletedTargetPath = deletedTarget.standardizedFileURL.path
        let pathsToRemove = appSettings.externalSkillPaths.filter { rawPath in
            let url = URL(fileURLWithPath: rawPath).standardizedFileURL
            return url.path == fileURL.path || url.path == deletedTargetPath
        }
        let removedPaths = Set(pathsToRemove.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        let pluginReferences = Set(cachedResolvedCodexPluginSkillPaths.compactMap { reference, path in
            path == deletedTargetPath || path == fileURL.path ? reference : nil
        })
        let removedPathsChanged = appSettingsController.removeExternalSkillPaths(pathsToRemove)
        let removedPluginsChanged = appSettingsController.removeCodexPluginSkillReferences(pluginReferences)
        guard removedPathsChanged || removedPluginsChanged else { return }
        pruneSkillCollections(removingSkillName: skill.name, rootPath: deletedTargetPath, filePath: fileURL.path, extraPaths: removedPaths)
        appSettings = appSettingsController.settings
    }

    private func pruneSkillCollections(removingSkillName skillName: String, rootPath: String, filePath: String, extraPaths: Set<String> = []) {
        var updatedCollections: [SkillCollectionRecord] = []
        var didChange = false
        let removalPaths = extraPaths.union([rootPath, filePath].map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        for var collection in appSettingsController.settings.skillCollections {
            let before = collection
            collection.skillNames.remove(skillName)
            collection.skillRootPaths.subtract(removalPaths)
            collection.excludedSkillNames.remove(skillName)
            collection.excludedSkillRootPaths.subtract(removalPaths)
            if collection.skillRootPaths.isEmpty && collection.skillNames.isEmpty {
                didChange = true
                continue
            }
            if collection != before { didChange = true }
            updatedCollections.append(collection)
        }
        guard didChange else { return }
        appSettingsController.replaceSkillCollections(updatedCollections)
        let known = Set(updatedCollections.map(\.id))
        for projectPath in projectPreferencesStore.preferencesByPath.keys {
            let preference = projectPreferencesStore.preference(for: projectPath)
            for id in preference.assignedSkillCollectionIDs where !known.contains(id) {
                projectPreferencesStore.setAssignedSkillCollection(id, assigned: false, for: projectPath)
            }
        }
    }

    private func ensureLibraryAgent(for agent: AgentRecord) throws -> URL {
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

    private func ensureLibraryPrompt(for prompt: PromptTemplateRecord) throws -> URL {
        let libraryRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/prompt-library", isDirectory: true)
        let libraryURL = libraryRoot.appendingPathComponent("\(prompt.name).md")
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: libraryURL.path) { return libraryURL }

        let sourceURL = URL(fileURLWithPath: prompt.filePath)
        if prompt.source.kind == .global {
            try fileManager.moveItem(at: sourceURL, to: libraryURL)
        } else if prompt.source.kind == .library {
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

    func setDisableBuiltins(_ isDisabled: Bool, scope: AgentEditingTarget.OverrideScope) {
        do {
            try agentPersistence.setDisableBuiltins(isDisabled, scope: scope, projectRoot: selectedProjectPath)
            refreshAfterOverrideChange(scope: scope)
        } catch {
            repositoryLastError = error.localizedDescription
        }
    }

    func setBuiltinDisabled(_ isDisabled: Bool, for agent: EffectiveAgentRecord, scope: AgentEditingTarget.OverrideScope, explicitProjectRoot: String? = nil) {
        let targetRoot = explicitProjectRoot ?? selectedProjectPath
        do {
            try agentPersistence.setBuiltinDisabled(isDisabled, for: agent, scope: scope, projectRoot: targetRoot)
            patchBuiltinDisabledOverride(agentName: agent.name, scope: scope, isDisabled: isDisabled, explicitProjectRoot: explicitProjectRoot)
        } catch {
            repositoryLastError = error.localizedDescription
        }
    }

    /// Builtin enablement is global-only; Agent Deck never rewrites project
    /// `.pi/settings.json` subagent configuration.
    func setBuiltinGloballyEnabled(_ isEnabled: Bool, for agent: EffectiveAgentRecord) {
        setBuiltinDisabled(!isEnabled, for: agent, scope: .global)
    }

    private func patchBuiltinDisabledOverrideCleared(agentName: String, projectRoot: String) {
        let targetPath = URL(fileURLWithPath: projectRoot).appendingPathComponent(".pi/settings.json").path

        func patch(_ snap: ScanSnapshot) -> ScanSnapshot {
            let updatedSettings: [SettingsSummary] = snap.settings.map { summary in
                guard summary.path == targetPath else { return summary }
                var overrides = summary.agentOverrides
                if let idx = overrides.firstIndex(where: { $0.agentName == agentName }) {
                    var values = overrides[idx].values
                    values.removeValue(forKey: "disabled")
                    if values.isEmpty {
                        overrides.remove(at: idx)
                    } else {
                        overrides[idx] = BuiltinOverrideRecord(
                            agentName: agentName,
                            scope: ScopeID(kind: .override, path: targetPath),
                            settingsPath: targetPath,
                            values: values
                        )
                    }
                }
                return SettingsSummary(
                    path: summary.path,
                    packages: summary.packages,
                    prompts: summary.prompts,
                    disableBuiltins: summary.disableBuiltins,
                    agentOverrides: overrides
                )
            }
            return ScanSnapshot(
                projectRoot: snap.projectRoot,
                builtinAgents: snap.builtinAgents,
                globalAgents: snap.globalAgents,
                projectAgents: snap.projectAgents,
                legacyProjectAgents: snap.legacyProjectAgents,
                effectiveAgents: snap.effectiveAgents,
                libraryAgents: snap.libraryAgents,
                skills: snap.skills,
                librarySkills: snap.librarySkills,
                promptTemplates: snap.promptTemplates,
                libraryPromptTemplates: snap.libraryPromptTemplates,
                settings: updatedSettings,
                envKeys: snap.envKeys,
                warnings: snap.warnings
            )
        }

        globalSnapshot = patch(globalSnapshot)
        allProjectSnapshots = allProjectSnapshots.mapValues(patch)
        snapshot = patch(snapshot)

        reconcileSnapshotsFromPreferences()
    }

    /// Effective disabled state for a builtin in a specific project. Mirrors
    /// `PiAgentLaunchResolver`'s precedence so the per-project checkboxes
    /// show what Pi actually loads: explicit per-agent project override →
    /// project `disableBuiltins` → per-agent user override → user
    /// `disableBuiltins`. Falling through to global state matters when the
    /// project has no settings file yet (e.g. just-added project), otherwise
    /// brand-new projects render as "enabled" even when global says disabled.
    func builtinIsDisabled(agentName: String, inProject projectPath: String) -> Bool {
        let projectSettingsPath = URL(fileURLWithPath: projectPath).appendingPathComponent(".pi/settings.json").standardizedFileURL.path
        let projectSettings = allProjectSnapshots[projectPath]?.settings.first { summary in
            URL(fileURLWithPath: summary.path).standardizedFileURL.path == projectSettingsPath
        }
        if let projectOverrideDisabled = projectSettings?.agentOverrides.first(where: { $0.agentName == agentName })?.disabledOverride {
            return projectOverrideDisabled
        }
        if projectSettings?.disableBuiltins == true {
            return true
        }

        let globalSettingsPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/settings.json").standardizedFileURL.path
        let globalSettings = globalSnapshot.settings.first { summary in
            URL(fileURLWithPath: summary.path).standardizedFileURL.path == globalSettingsPath
        }
        if let userOverrideDisabled = globalSettings?.agentOverrides.first(where: { $0.agentName == agentName })?.disabledOverride {
            return userOverrideDisabled
        }
        return globalSettings?.disableBuiltins == true
    }

    func toggleBuiltinDisabledGlobally(_ agent: EffectiveAgentRecord) {
        setBuiltinDisabled(!(agent.resolved.disabled ?? false), for: agent, scope: .global)
    }

    func builtinStateBadge(for agent: EffectiveAgentRecord) -> (text: String, color: Color)? {
        guard agent.builtin != nil, agent.globalCustom == nil, agent.projectCustom == nil else { return nil }

        let projectOverrideDisabled = agent.projectOverride?.disabledOverride
        let userOverrideDisabled = agent.userOverride?.disabledOverride

        if agent.resolved.disabled == true {
            if projectOverrideDisabled == true || projectDisableBuiltins {
                return ("Disabled by project", .orange)
            }
            if userOverrideDisabled == true || userDisableBuiltins {
                return ("Disabled globally", .red)
            }
        } else if projectOverrideDisabled == false || userOverrideDisabled == false {
            return ("Explicitly enabled override", .green)
        }

        return nil
    }

    func warnings(for agent: EffectiveAgentRecord) -> [DiagnosticWarning] {
        // Cache hit (incl. an empty array) is authoritative — see
        // `rebuildWarningCaches()`. Miss → live compute (e.g. before first scan).
        if let cached = cachedAgentWarningsByID[agent.id] { return cached }
        return computeWarnings(for: agent)
    }

    private func computeWarnings(for agent: EffectiveAgentRecord) -> [DiagnosticWarning] {
        let collectionNames = Set(appSettings.skillCollections.map(\.name))
        return globalSnapshot.warnings.filter { warning in
            if warning.id.hasPrefix("skill:\(agent.name):") {
                let missingName = String(warning.id.dropFirst("skill:\(agent.name):".count))
                if collectionNames.contains(missingName) { return false }
            }
            return warning.message.contains("Agent \(agent.name) ") || warning.message.contains("Agent \(agent.name)")
        }
    }

    func agentsExplicitlyUsingSkill(_ skill: SkillRecord) -> [EffectiveAgentRecord] {
        globalSnapshot.effectiveAgents
            .filter { $0.resolved.skills.contains(skill.name) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func agentsAmbientlySeeingSkill(_ skill: SkillRecord) -> [EffectiveAgentRecord] {
        []
    }

    func makeAggregateSnapshot() -> ScanSnapshot {
        // The no-project view is a global/library management view. Project-local
        // resources remain visible only when their project is selected; they are not
        // merged here so global/library resources do not depend on scanning every repo.
        ScanSnapshot(
            projectRoot: nil,
            builtinAgents: globalSnapshot.builtinAgents,
            globalAgents: globalSnapshot.globalAgents,
            projectAgents: [],
            legacyProjectAgents: [],
            effectiveAgents: globalSnapshot.effectiveAgents,
            libraryAgents: globalSnapshot.libraryAgents,
            skills: globalSnapshot.skills,
            librarySkills: globalSnapshot.librarySkills,
            promptTemplates: globalSnapshot.promptTemplates,
            libraryPromptTemplates: globalSnapshot.libraryPromptTemplates,
            settings: globalSnapshot.settings,
            envKeys: globalSnapshot.envKeys,
            warnings: globalSnapshot.warnings
        )
    }

    private func refreshAfterAgentDraftChange(_ draft: AgentEditorDraft) {
        switch draft.target {
        case let .custom(scope):
            guard scope == .project else {
                // Global agent edit (incl. setSkill→saveAgentDraft toggle) —
                // `patchEffectiveAgentSkills` already updated the in-memory
                // snapshot, so this scan is reconciliation only.
                refresh(includeModels: false, silentlyReconcile: true)
                return
            }
            refreshAfterProjectScopedChange(projectPath: draft.sourcePath.flatMap(projectPath(containing:)) ?? selectedProjectPath)
        case let .builtinOverride(scope):
            refreshAfterOverrideChange(scope: scope)
        }
    }

    private func refreshAfterOverrideChange(scope: AgentEditingTarget.OverrideScope) {
        // Builtin-override changes feed bound, snapshot-derived toggles — the
        // Settings "Disable builtins" switch and the per-agent builtin-disable
        // control. Keep this synchronous so those toggles show the new state
        // immediately instead of snapping back while an async refresh is in
        // flight. Override edits are infrequent admin actions, so the brief
        // rescan is an acceptable cost here.
        switch scope {
        case .global:
            refreshSynchronouslyBlocksMainUntilDone(includeModels: false)
            refresh(includeModels: false)
        case .project:
            if let projectPath = selectedProjectPath {
                refreshSynchronouslyBlocksMainUntilDone(includeModels: false, scanAllProjects: false, extraProjectPathsToScan: [projectPath])
                refresh(includeModels: false, scanAllProjects: false, extraProjectPathsToScan: [projectPath])
            } else {
                refreshSynchronouslyBlocksMainUntilDone(includeModels: false)
                refresh(includeModels: false)
            }
        }
    }

    private func refreshAfterFileScopedChange(sourceKind: ResourceScopeKind, filePath: String) {
        switch sourceKind {
        case .project, .legacyProject:
            refreshAfterProjectScopedChange(projectPath: projectPath(containing: filePath) ?? selectedProjectPath)
        default:
            refresh(includeModels: false)
        }
    }

    private func refreshAfterProjectScopedChange(projectPath: String?) {
        // Async-only: agent-draft saves, override edits and env-key changes all
        // route through here; a synchronous rescan would freeze the UI on each.
        // `silentlyReconcile`: the visible state has already been patched in
        // memory (e.g. by `patchEffectiveAgentSkills`), so the list stays
        // interactive while the background scan reconciles.
        guard let projectPath else {
            refresh(includeModels: false, silentlyReconcile: true)
            return
        }
        refresh(includeModels: false, scanAllProjects: false, extraProjectPathsToScan: [projectPath], silentlyReconcile: true)
    }

    private func projectPath(containing filePath: String) -> String? {
        enabledProjects.first { project in
            filePath == project.path || filePath.hasPrefix(project.path + "/")
        }?.path
    }

    private func scopeSnapshot(for target: AgentEditingTarget) -> ScanSnapshot {
        switch target {
        case let .builtinOverride(scope):
            return scopedSnapshot(for: scope == .project)
        case let .custom(scope):
            return scopedSnapshot(for: scope == .project)
        }
    }

    private func scopedSnapshot(for includeProject: Bool) -> ScanSnapshot {
        guard includeProject, let selectedProjectPath, let projectSnapshot = allProjectSnapshots[selectedProjectPath] else {
            return globalSnapshot
        }
        return projectSnapshot
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

    private func skillVisible(to agent: EffectiveAgentRecord, skill: SkillRecord) -> Bool {
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

    private func defaultCustomScope(for agent: EffectiveAgentRecord) -> AgentEditingTarget.CustomAgentScope {
        return .global
    }

    private func duplicatedName(for name: String) -> String {
        let existingNames = Set(snapshot.effectiveAgents.map(\.name))
        var candidate = "\(name)-copy"
        var index = 2
        while existingNames.contains(candidate) {
            candidate = "\(name)-copy-\(index)"
            index += 1
        }
        return candidate
    }

    private func deduplicateByID<T: Identifiable>(_ values: [T]) -> [T] where T.ID: Hashable {
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
