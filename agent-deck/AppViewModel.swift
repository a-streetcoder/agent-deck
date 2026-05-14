import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

@MainActor
private final class NativeSubagentCompletionGate {
    private(set) var isCompleted = false

    func complete(_ body: () -> Void) {
        guard !isCompleted else { return }
        isCompleted = true
        body()
    }
}

@MainActor
private final class NativeParallelGraphScheduler {
    let id = UUID()
    let parentSession: PiAgentSessionRecord
    let graphRunID: UUID
    let tasks: [(agentName: String, task: String)]
    let concurrency: Int
    let useWorktreeIsolation: Bool
    let completion: ((PiSubagentRunRecord) -> Void)?
    var nextIndex = 0
    var active = 0
    var completed = 0
    var failed = false

    init(parentSession: PiAgentSessionRecord, graphRunID: UUID, tasks: [(agentName: String, task: String)], concurrency: Int, useWorktreeIsolation: Bool, completion: ((PiSubagentRunRecord) -> Void)?) {
        self.parentSession = parentSession
        self.graphRunID = graphRunID
        self.tasks = tasks
        self.concurrency = concurrency
        self.useWorktreeIsolation = useWorktreeIsolation
        self.completion = completion
    }
}

private struct GitDiffCacheKey: Hashable {
    let projectPath: String
    let filePath: String
    let kind: GitDiffKind
}

private struct RepositoryChangesCacheEntry {
    var snapshot: RepositoryChangesSnapshot? = nil
    var fetchedAt: Date? = nil
    var isLoading: Bool = false
    var error: String?
    var requestID: Int = 0
}

@MainActor
final class AppViewModel: NSObject, ObservableObject {
    let windowID = UUID()
    @Published var snapshot: ScanSnapshot = .empty
    @Published var selectedSidebarItem: SidebarItem = .agent
    @Published var selectedAgentID: EffectiveAgentRecord.ID?
    @Published var selectedSkillID: SkillRecord.ID?
    @Published var selectedCommandItemID: String?
    @Published var selectedAgentFilter: AgentFilter = .all
    @Published var discoveredProjects: [DiscoveredProject] = []
    @Published var projectPreferencesByPath: [String: ProjectPreference] = ProjectPreferencesStore.shared.preferencesByPath
    @Published var selectedProjectPath: String?
    @Published var allProjectSnapshots: [String: ScanSnapshot] = [:]
    @Published var availableModels: [AvailableModel] = []
    @Published var modelsLastUpdatedAt: Date?
    @Published private var piRuntimeSettingsRevision = 0
    private var cachedPiRuntimeSettingsObject: [String: Any]?
    private var cachedPiRuntimeSettingsModificationDate: Date?
    private var lastPiRuntimeSettingsStatCheck: Date?
    @Published var githubConnectionState: GitHubConnectionState = .checking
    @Published var githubSelectedSection: GitHubSection = .projectBoard
    @Published var githubIssueStateFilter: GitHubIssueStateFilter = .open
    @Published var githubAggregateBoard: GitHubBoardSnapshot?
    @Published var githubProjectBoard: GitHubBoardSnapshot?
    @Published var githubRepositoryChanges: RepositoryChangesSnapshot?
    @Published var githubRepositoryChangesProjectPath: String?
    @Published private var repositoryChangesCache: [String: RepositoryChangesCacheEntry] = [:]
    @Published var githubSelectedChangePaths: Set<String> = []
    @Published var githubSelectedDiffFilePath: String?
    @Published var githubSelectedDiffKind: GitDiffKind?
    @Published var githubSelectedDiffText: String?
    @Published var githubCommitMessage = ""
    @Published var githubCommitDescription = ""
    @Published var githubSelectedWorkItem: GitHubWorkItem?
    @Published var githubIssueDetail: GitHubIssueDetail?
    @Published var githubCommentDraft = ""
    @Published var githubIsLoadingAggregateBoard = false
    @Published var githubIsLoadingProjectBoard = false
    @Published var githubIsLoadingRepositoryChanges = false
    @Published var githubIsLoadingIssueDetail = false
    @Published var githubIsSubmittingComment = false
    @Published var githubIsClosingIssue = false
    @Published var githubIsCommitting = false
    @Published var githubIsPushing = false
    @Published var piAgentGitAutomationAction: PiAgentGitAutomationAction?
    @Published var githubIsRefreshingEverything = false
    @Published var githubLastError: String?
    @Published var githubLastStatusCheckAt: Date?
    @Published var appSettings: AppSettings = AppSettings()
    @Published private(set) var hasCompletedInitialRefresh = false
    var enabledAvailableModels: [AvailableModel] {
        availableModels.filter { !appSettings.disabledModelIdentifiers.contains($0.identifier) }
    }
    @Published var isPiAgentInspectorPresented = false
    @Published var showPiAgentAttentionOnly = false
    @Published private(set) var piAgentTitleGeneratingSessionIDs: Set<UUID> = []
    private(set) var piAgentPendingComposerText: String?
    let piAgentSessionStore = PiAgentSessionStore()
    let agentMemoryStore = AgentMemoryStore()

    private let agentPersistence = AgentPersistence()
    private let envPersistence = EnvPersistence()
    private let projectPreferencesStore = ProjectPreferencesStore.shared
    private let appSettingsController = AppSettingsController()
    private let gitHubAuthService: GitHubAuthService = GitHubCLIAuthService()
    private let gitRepositoryService = GitRepositoryService()
    private let shipService = PiAgentShipService()
    private let subagentWorktreeService = PiSubagentWorktreeService()
    private lazy var piAgentRunner = PiAgentRunnerService(store: piAgentSessionStore)
    private lazy var nativeSubagentRunner = PiSubagentRunService(store: piAgentSessionStore)
    private let piSessionTitleGenerator = PiSessionTitleGenerationService()
    private var globalSnapshot: ScanSnapshot = .empty
    private var gitHubSession: GitHubSession?
    private(set) var projectRootURL: URL?
    private var autoRefreshCancellable: AnyCancellable?
    private var piAgentSessionStoreCancellable: AnyCancellable?
    private var watchFingerprintTask: Task<Void, Never>?
    private var watchEventDebounceTask: Task<Void, Never>?
    private var fileWatchEventMonitor: FileWatchEventMonitor?
    private var lastWatchFingerprint: String = ""
    private var watchedURLsForAutoRefresh: [URL] = []
    private var refreshTask: Task<Void, Never>?
    private var refreshRequestID = 0
    private var isRefreshingModels = false
    private var githubProjectBoardRequestID = 0
    private var githubRepositoryChangesRequestID = 0
    private var githubDiffRequestID = 0
    private var githubIssueDetailRequestID = 0
    private var githubDiffCache: [GitDiffCacheKey: String] = [:]
    private var githubDiffCacheOrder: [GitDiffCacheKey] = []
    private let githubDiffCacheLimit = 64
    private let repositoryChangesCacheLifetime: TimeInterval = 5
    private let watchEventDebounceNanoseconds: UInt64 = 1_000_000_000
    private let fallbackAutoRefreshInterval: TimeInterval = 300
    private var nativeParallelSchedulersByID: [UUID: NativeParallelGraphScheduler] = [:]
    private let lastSelectedProjectDefaultsKey = "lastSelectedProjectPath"
    private let lastExternalSkillsDirectoryDefaultsKey = "lastExternalSkillsDirectoryPath"
    private var githubProjectBoardCacheKey: String?
    private var githubProjectBoardFetchedAt: Date?
    private var pendingPiAgentNotificationTasks: [UUID: Task<Void, Never>] = [:]
    private var didShutdown = false

    private var piAgentNotificationDelay: TimeInterval {
        TimeInterval(piAgentNotificationDelayMinutes * 60)
    }

    private var piAgentIdleParkingTimeout: TimeInterval? {
        guard isPiAgentIdleParkingEnabled else { return nil }
        return TimeInterval(piAgentIdleParkingTimeoutMinutes * 60)
    }

    override init() {
        super.init()

        appSettings = appSettingsController.settings
        selectedProjectPath = UserDefaults.standard.string(forKey: lastSelectedProjectDefaultsKey)
        if let selectedProjectPath {
            projectRootURL = URL(fileURLWithPath: selectedProjectPath, isDirectory: true).standardizedFileURL
        }
        piAgentSessionStore.newSessionSubagentsEnabled = appSettings.nativeSubagentsEnabledForNewSessions
        configureAgentMemory()
        piAgentSessionStoreCancellable = piAgentSessionStore.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        writeOpenAIFastModeConfig()
        configurePiAgentIdleParking()
        configurePiAgentTranscriptMemory()
        refresh(includeModels: true, scanAllProjects: true)
        piAgentRunner.onTurnFinished = { [weak self] sessionID in
            Task { @MainActor in self?.handlePiAgentTurnFinished(sessionID) }
        }
        piAgentRunner.onManagedSubagentRequest = { [weak self] sessionID, request, completion in
            Task { @MainActor in
                self?.runManagedNativeSubagent(parentSessionID: sessionID, request: request, completion: completion)
            }
        }
        piAgentRunner.onManagedParallelRequest = { [weak self] sessionID, request, completion in
            Task { @MainActor in
                self?.runManagedNativeParallel(parentSessionID: sessionID, request: request, completion: completion)
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
        piAgentRunner.parentSkillArgumentsProvider = { [weak self] projectURL in
            try self?.parentSkillArguments(for: projectURL) ?? []
        }
        piAgentRunner.parentPromptTemplateArgumentsProvider = { [weak self] projectURL in
            try self?.parentPromptTemplateArguments(for: projectURL) ?? []
        }
        piAgentRunner.parentMemoryArgumentsProvider = { [weak self] session, projectURL, initialPrompt in
            self?.parentMemoryArguments(for: session, projectURL: projectURL, initialPrompt: initialPrompt) ?? []
        }
        piAgentRunner.onMemoryProposal = { [weak self] sessionID, request in
            self?.handleParentMemoryProposal(sessionID: sessionID, request: request) ?? "\(AppBrand.displayName) memory is not available."
        }
        piAgentRunner.onMemoryMarkStale = { [weak self] sessionID, request in
            self?.handleParentMemoryMarkStale(sessionID: sessionID, request: request) ?? "\(AppBrand.displayName) memory is not available."
        }
        nativeSubagentRunner.childMemoryArgumentsProvider = { [weak self] parentSession, agent, task in
            self?.childMemoryArguments(for: parentSession, agent: agent, task: task) ?? []
        }
        nativeSubagentRunner.onMemoryProposal = { [weak self] parentSessionID, runID, agentName, request in
            self?.handleSubagentMemoryProposal(parentSessionID: parentSessionID, runID: runID, agentName: agentName, request: request) ?? "\(AppBrand.displayName) memory is not available."
        }
        nativeSubagentRunner.onMemoryMarkStale = { [weak self] parentSessionID, runID, agentName, request in
            self?.handleSubagentMemoryMarkStale(parentSessionID: parentSessionID, runID: runID, agentName: agentName, request: request) ?? "\(AppBrand.displayName) memory is not available."
        }
        registerAppNotificationObservers()
        startAutoRefresh()
        cleanupOrphanedNativeSubagentArtifacts()

        Task {
            await refreshGitHubStatus()
            if case .available = githubConnectionState {
                await connectGitHubUsingCLIIfNeeded()
            }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func shutdown(recordTranscript: Bool) {
        guard !didShutdown else { return }
        didShutdown = true
        stopAutoRefresh(cancelPendingScan: true)
        refreshTask?.cancel()
        refreshTask = nil
        for task in pendingPiAgentNotificationTasks.values {
            task.cancel()
        }
        pendingPiAgentNotificationTasks.removeAll()
        piSessionTitleGenerator.cancelAll()
        piAgentRunner.stopAll(recordTranscript: recordTranscript)
        nativeSubagentRunner.stopAll(recordTranscript: recordTranscript)
        nativeParallelSchedulersByID.removeAll()
    }

    private func cleanupOrphanedNativeSubagentArtifacts(retentionDays: Int = 30) {
        let referencedArtifactPaths = Set(piAgentSessionStore.subagentRunsBySessionID.values.flatMap { runs in
            runs.map(\.artifactDirectory).filter { !$0.isEmpty }
        })
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 24 * 60 * 60)
        Task.detached {
            let fileManager = FileManager.default
            let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            let runsDirectory = appSupport.appendingPathComponent("\(AppBrand.displayName)", isDirectory: true).appendingPathComponent("Subagent Runs", isDirectory: true)
            guard let entries = try? fileManager.contentsOfDirectory(at: runsDirectory, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]) else { return }
            for url in entries {
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
                guard values?.isDirectory == true,
                      !referencedArtifactPaths.contains(url.path),
                      (values?.contentModificationDate ?? .distantFuture) < cutoff else { continue }
                try? fileManager.removeItem(at: url)
            }
        }
    }

    func refresh(includeModels: Bool = false, scanAllProjects: Bool = false, extraProjectPathsToScan: Set<String> = []) {
        let selectedProjectPath = selectedProjectPath
        let shouldScanAllProjects = scanAllProjects
        let preferencesByPath = projectPreferencesStore.preferencesByPath
        let rootURL = configuredProjectsRootURL
        let externalSkillPaths = appSettings.externalSkillPaths
        refreshRequestID += 1
        let requestID = refreshRequestID

        refreshTask?.cancel()
        let viewModel = self
        refreshTask = Task.detached {
            let result = AppRefreshService().loadSnapshot(
                rootURL: rootURL,
                selectedProjectPath: selectedProjectPath,
                preferencesByPath: preferencesByPath,
                externalSkillPaths: externalSkillPaths,
                scanAllProjects: shouldScanAllProjects,
                extraProjectPathsToScan: extraProjectPathsToScan
            )

            await MainActor.run {
                guard !Task.isCancelled, requestID == viewModel.refreshRequestID else { return }
                viewModel.applyRefreshSnapshot(
                    result,
                    includeModels: includeModels
                )
            }
        }
    }

    private func applyRefreshSnapshot(
        _ result: AppRefreshSnapshot,
        includeModels: Bool
    ) {
        projectPreferencesByPath = result.projectPreferencesByPath
        discoveredProjects = result.discoveredProjects

        if !appSettings.didMigrateAgentAssignmentsFromDiscoveredFiles {
            guard result.includesAllProjectSnapshots else {
                refresh(includeModels: includeModels, scanAllProjects: true)
                return
            }
            migrateAgentAssignmentsFromDiscoveredFiles(globalSnapshot: result.globalSnapshot, projectSnapshots: result.projectSnapshots)
        }

        let catalogProjectSnapshots = Array(result.projectSnapshots.values)
        globalSnapshot = scopedAgentSnapshot(result.globalSnapshot, projectPath: nil, globalCatalogSnapshot: result.globalSnapshot, catalogProjectSnapshots: catalogProjectSnapshots)
        let freshProjectSnapshots = result.projectSnapshots.mapValues { projectSnapshot in
            scopedAgentSnapshot(projectSnapshot, projectPath: projectSnapshot.projectRoot, globalCatalogSnapshot: result.globalSnapshot, catalogProjectSnapshots: catalogProjectSnapshots)
        }
        if result.includesAllProjectSnapshots {
            allProjectSnapshots = freshProjectSnapshots
        } else {
            allProjectSnapshots.merge(freshProjectSnapshots) { _, fresh in fresh }
            let discoveredProjectPaths = Set(result.discoveredProjects.map(\.path))
            allProjectSnapshots = allProjectSnapshots.filter { discoveredProjectPaths.contains($0.key) }
        }
        watchedURLsForAutoRefresh = result.watchedURLs
        if result.includesWatchFingerprint {
            lastWatchFingerprint = result.watchFingerprint
        }
        updateAutoRefreshWatchList()

        if let matchingProject = result.selectedProject {
            projectRootURL = matchingProject.url
            snapshot = allProjectSnapshots[matchingProject.path]
                ?? result.selectedProjectSnapshot.map { scopedAgentSnapshot($0, projectPath: matchingProject.path, globalCatalogSnapshot: result.globalSnapshot, catalogProjectSnapshots: catalogProjectSnapshots) }
                ?? globalSnapshot
        } else {
            projectRootURL = nil
            self.selectedProjectPath = nil
            persistSelectedProjectPath(nil)
            snapshot = makeAggregateSnapshot()
        }

        let currentAgentID = selectedAgentID
        let currentSkillID = selectedSkillID
        let currentCommandItemID = selectedCommandItemID

        selectedAgentID = filteredAgents.contains(where: { $0.id == currentAgentID }) ? currentAgentID : filteredAgents.first?.id
        selectedSkillID = allVisibleSkillRecords.contains(where: { $0.id == currentSkillID }) ? currentSkillID : allVisibleSkillRecords.first?.id
        let availablePromptIDs = Set(allVisiblePromptTemplateRecords.map(\.id))
        if availablePromptIDs.contains(currentCommandItemID ?? "") {
            selectedCommandItemID = currentCommandItemID
        } else {
            selectedCommandItemID = allVisiblePromptTemplateRecords.first?.id
        }
        piAgentSessionStore.newSessionSubagentsEnabled = appSettings.nativeSubagentsEnabledForNewSessions

        if includeModels {
            refreshAvailableModels()
        }

        hasCompletedInitialRefresh = true
    }

    func chooseProjectRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Project"
        panel.message = "Choose a repo or project root to add to \(AppBrand.displayName)."

        guard panel.runModal() == .OK, let url = panel.url else { return }
        addProject(url)
    }

    var suggestedExternalSkillsDirectoryURL: URL {
        let fileManager = FileManager.default

        func validDirectoryURL(for path: String?) -> URL? {
            guard let rawPath = path?.trimmingCharacters(in: .whitespacesAndNewlines), !rawPath.isEmpty else { return nil }
            let url = URL(fileURLWithPath: rawPath, isDirectory: true).standardizedFileURL
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
            return url
        }

        if let configuredURL = validDirectoryURL(for: appSettings.defaultSkillsImportRootPath) {
            return configuredURL
        }

        if let lastURL = validDirectoryURL(for: UserDefaults.standard.string(forKey: lastExternalSkillsDirectoryDefaultsKey)) {
            return lastURL
        }

        if let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            return documentsURL
        }

        return fileManager.homeDirectoryForCurrentUser
    }

    func chooseExternalSkillsDirectory(startingAt url: URL? = nil, completion: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Skills Folder"
        panel.message = "Choose a skill root or a folder to search recursively for SKILL.md files you want to add to the \(AppBrand.displayName) skill catalog."
        panel.directoryURL = url ?? suggestedExternalSkillsDirectoryURL

        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            DispatchQueue.main.async {
                guard response == .OK,
                      let selectedURL = panel.url?.standardizedFileURL else {
                    completion(nil)
                    return
                }
                self?.persistLastExternalSkillsDirectoryPath(selectedURL.path)
                completion(selectedURL)
            }
        }

        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            panel.begin(completionHandler: handler)
        }
    }

    func externalSkillCandidate(at skillRoot: URL) -> ExternalSkillCandidate? {
        let skillFile = skillRoot.appendingPathComponent("SKILL.md")
        guard let body = try? String(contentsOf: skillFile, encoding: .utf8) else { return nil }
        let frontmatter = parseSimpleFrontmatter(body)
        let parsedName = frontmatter["name"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedDescription = frontmatter["description"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (parsedName?.isEmpty == false ? parsedName! : skillRoot.lastPathComponent)
        let description = parsedDescription?.isEmpty == false ? parsedDescription : nil
        return ExternalSkillCandidate(
            name: name,
            description: description,
            sourceRootPath: skillRoot.standardizedFileURL.path,
            skillFilePath: skillFile.standardizedFileURL.path
        )
    }

    func discoverImportableSkills(in root: URL) -> [ExternalSkillCandidate] {
        let fileManager = FileManager.default
        var results: [ExternalSkillCandidate] = []
        var seenRootPaths = Set<String>()

        func walk(_ directory: URL) {
            let standardizedDirectory = directory.standardizedFileURL

            if let candidate = externalSkillCandidate(at: standardizedDirectory) {
                if seenRootPaths.insert(candidate.sourceRootPath).inserted {
                    results.append(candidate)
                }
                // A folder containing SKILL.md is a skill root; do not recurse into
                // examples or nested reference folders that may also contain skills.
                return
            }

            guard let entries = try? fileManager.contentsOfDirectory(
                at: standardizedDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                return
            }

            for entry in entries {
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: entry.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
                walk(entry)
            }
        }

        walk(root)

        return results.sorted { lhs, rhs in
            let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return lhs.sourceRootPath < rhs.sourceRootPath
        }
    }

    func importExternalSkills(_ candidates: [ExternalSkillCandidate]) throws -> SkillImportResult {
        var importedNames: [String] = []
        var skippedNames: [String] = []
        var importedPaths: [String] = []
        let existingPaths = appSettings.externalSkillPaths

        for candidate in candidates {
            let sourcePath = URL(fileURLWithPath: candidate.sourceRootPath).standardizedFileURL.path
            if existingPaths.contains(sourcePath) {
                skippedNames.append(candidate.name)
                continue
            }
            importedPaths.append(sourcePath)
            importedNames.append(candidate.name)
        }

        if appSettingsController.addExternalSkillPaths(importedPaths) {
            appSettings = appSettingsController.settings
        }
        refresh(includeModels: false)
        if let firstImported = importedNames.first {
            selectedSkillID = allVisibleSkillRecords.first { $0.name == firstImported }?.id ?? selectedSkillID
        }
        return SkillImportResult(importedNames: importedNames, skippedNames: skippedNames)
    }

    func addProject(_ url: URL, selectingAfterAdd: Bool = false) {
        let standardizedURL = url.standardizedFileURL
        projectPreferencesStore.addProjectPath(standardizedURL.path)
        projectPreferencesByPath = projectPreferencesStore.preferencesByPath

        if selectingAfterAdd {
            projectRootURL = standardizedURL
            selectedProjectPath = standardizedURL.path
            persistSelectedProjectPath(standardizedURL.path)
        }

        refresh(includeModels: false, scanAllProjects: false, extraProjectPathsToScan: [standardizedURL.path])
        if selectingAfterAdd {
            refreshGitHubProjectScopedState()
        }
    }

    func setSelectedProject(_ url: URL?) {
        guard let url else {
            clearProjectRoot()
            return
        }

        let standardizedURL = url.standardizedFileURL
        projectPreferencesStore.addProjectPath(standardizedURL.path)
        projectPreferencesByPath = projectPreferencesStore.preferencesByPath
        projectRootURL = standardizedURL
        selectedProjectPath = standardizedURL.path
        persistSelectedProjectPath(standardizedURL.path)
        refresh(includeModels: false, scanAllProjects: false, extraProjectPathsToScan: [standardizedURL.path])
        refreshGitHubProjectScopedState()
    }

    func clearProjectRoot() {
        projectRootURL = nil
        selectedProjectPath = nil
        persistSelectedProjectPath(nil)
        refresh(includeModels: false)
        refreshGitHubProjectScopedState()
    }

    func projectPreference(for path: String) -> ProjectPreference {
        projectPreferencesStore.preference(for: path)
    }

    func setProjectEnabled(_ isEnabled: Bool, for project: DiscoveredProject) {
        projectPreferencesStore.setEnabled(isEnabled, for: project.path)
        applyProjectPreferenceChanges()

        if !isEnabled, selectedProjectPath == project.path {
            projectRootURL = nil
            selectedProjectPath = nil
            persistSelectedProjectPath(nil)
        }

        if isEnabled {
            refresh(includeModels: false, scanAllProjects: false, extraProjectPathsToScan: [project.path])
        } else if selectedProjectPath == nil {
            snapshot = makeAggregateSnapshot()
        }
        refreshGitHubProjectScopedState()
    }

    func setAllProjectsEnabled(_ isEnabled: Bool) {
        let paths = discoveredProjects.map(\.path)
        projectPreferencesStore.setAllEnabled(isEnabled, for: paths)
        applyProjectPreferenceChanges()

        if !isEnabled, selectedProjectPath != nil {
            projectRootURL = nil
            selectedProjectPath = nil
            persistSelectedProjectPath(nil)
        }

        if isEnabled {
            refresh(includeModels: false)
        } else {
            snapshot = makeAggregateSnapshot()
        }
        refreshGitHubProjectScopedState()
    }

    func removeProjectFromLibrary(_ project: DiscoveredProject) {
        projectPreferencesStore.setHidden(true, for: project.path)
        applyProjectPreferenceChanges()
        allProjectSnapshots.removeValue(forKey: project.path)

        if selectedProjectPath == project.path {
            projectRootURL = nil
            selectedProjectPath = nil
            persistSelectedProjectPath(nil)
        }

        if selectedProjectPath == nil {
            snapshot = makeAggregateSnapshot()
        }
        refreshGitHubProjectScopedState()
    }

    func toggleProjectFavorite(_ project: DiscoveredProject) {
        projectPreferencesStore.toggleFavorite(for: project.path)
        applyProjectPreferenceChanges()
    }

    func chooseCustomIcon(for project: DiscoveredProject) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.prompt = "Choose Icon"
        panel.message = "Choose an image to use as this project's custom icon."

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try projectPreferencesStore.setCustomIcon(from: url, for: project.path)
            applyProjectPreferenceChanges()
        } catch {
            githubLastError = error.localizedDescription
        }
    }

    func clearCustomIcon(for project: DiscoveredProject) {
        projectPreferencesStore.clearCustomIcon(for: project.path)
        applyProjectPreferenceChanges()
    }

    private func applyProjectPreferenceChanges() {
        // Preference changes (especially hiding/removing a project) must invalidate any
        // in-flight refresh that was built with older preferences. Otherwise a stale
        // refresh can apply after this local mutation and reinsert the removed project.
        refreshRequestID += 1
        refreshTask?.cancel()

        projectPreferencesByPath = projectPreferencesStore.preferencesByPath
        discoveredProjects = discoveredProjects.compactMap { project in
            let preference = projectPreferencesStore.preference(for: project.path)
            guard !preference.isHidden else { return nil }
            return DiscoveredProject(
                url: project.url,
                gitHubRemote: project.gitHubRemote,
                isGitRepository: project.isGitRepository,
                iconFileURL: preference.customIconPath.flatMap { URL(fileURLWithPath: $0) },
                fallbackSymbolName: project.fallbackSymbolName,
                searchIndex: project.searchIndex
            )
        }
    }

    private func persistSelectedProjectPath(_ path: String?) {
        if let path {
            UserDefaults.standard.set(path, forKey: lastSelectedProjectDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: lastSelectedProjectDefaultsKey)
        }
    }

    private func persistLastExternalSkillsDirectoryPath(_ path: String?) {
        if let path {
            UserDefaults.standard.set(path, forKey: lastExternalSkillsDirectoryDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: lastExternalSkillsDirectoryDefaultsKey)
        }
    }

    func refreshGitHubStatus() async {
        githubConnectionState = .checking
        githubLastError = nil

        let state = await gitHubAuthService.loadStatus()
        switch state {
        case let .available(account):
            if gitHubSession?.account == account {
                githubConnectionState = .connected(account)
            } else {
                gitHubSession = nil
                githubConnectionState = .available(account)
            }
        case let .connected(account):
            githubConnectionState = .connected(account)
        default:
            gitHubSession = nil
            githubConnectionState = state
        }

        githubLastStatusCheckAt = Date()
    }

    func connectGitHubUsingCLI() {
        Task {
            await connectGitHubUsingCLIIfNeeded(forceReconnect: true)
        }
    }

    func connectGitHubUsingCLIIfNeeded(forceReconnect: Bool = false) async {
        if !forceReconnect, gitHubSession != nil, githubConnectionState.isConnected {
            return
        }

        githubConnectionState = .checking
        githubLastError = nil

        do {
            let session = try await gitHubAuthService.connectUsingCLI()
            gitHubSession = session
            githubConnectionState = .connected(session.account)
            githubLastStatusCheckAt = Date()
            refreshGitHubConnectionScopedState()
        } catch {
            gitHubSession = nil
            githubConnectionState = .failed(message: error.localizedDescription)
            githubLastError = error.localizedDescription
            githubLastStatusCheckAt = Date()
        }
    }

    func prepareGitHubScreen() async {
        if githubConnectionState.isConnected, gitHubSession != nil {
            return
        }

        await refreshGitHubStatus()
        if case .available = githubConnectionState {
            await connectGitHubUsingCLIIfNeeded()
        }
    }

    func refreshEverything() {
        guard !githubIsRefreshingEverything else { return }

        githubIsRefreshingEverything = true
        githubLastError = nil

        Task {
            defer {
                Task { @MainActor in
                    self.githubIsRefreshingEverything = false
                }
            }

            await MainActor.run {
                self.refresh(includeModels: true)
            }

            await self.refreshGitHubStatus()

            if case .available = self.githubConnectionState {
                await self.connectGitHubUsingCLIIfNeeded()
            }

            await MainActor.run {
                if self.gitHubSession != nil, self.githubConnectionState.isConnected {
                    self.refreshProjectBoard(force: true)
                }

                if self.selectedDiscoveredProject?.isGitRepository == true {
                    self.refreshRepositoryChanges(preservingDiffSelection: true)
                }

                if let selectedItem = self.githubSelectedWorkItem, self.gitHubSession != nil {
                    self.loadIssueDetail(for: selectedItem)
                }
            }
        }
    }

    func disconnectGitHub() {
        let availableAccount = githubConnectionState.account ?? gitHubSession?.account

        gitHubAuthService.disconnect()
        gitHubSession = nil
        githubProjectBoardRequestID += 1
        githubRepositoryChangesRequestID += 1
        githubIssueDetailRequestID += 1
        githubAggregateBoard = nil
        githubProjectBoard = nil
        githubProjectBoardCacheKey = nil
        githubProjectBoardFetchedAt = nil
        githubRepositoryChanges = nil
        githubRepositoryChangesProjectPath = nil
        repositoryChangesCache.removeAll()
        githubSelectedChangePaths = []
        githubDiffCache.removeAll()
        githubDiffCacheOrder.removeAll()
        githubSelectedDiffFilePath = nil
        githubSelectedDiffKind = nil
        githubSelectedDiffText = nil
        githubSelectedWorkItem = nil
        githubIssueDetail = nil
        githubCommentDraft = ""
        githubIsLoadingAggregateBoard = false
        githubIsLoadingProjectBoard = false
        githubIsLoadingRepositoryChanges = false
        githubIsLoadingIssueDetail = false
        githubIsSubmittingComment = false
        githubIsClosingIssue = false
        githubLastError = nil
        githubConnectionState = availableAccount.map(GitHubConnectionState.available) ?? .disconnected
        githubLastStatusCheckAt = Date()
    }

    func refreshAggregateBoard() {
        guard let session = gitHubSession else {
            githubLastError = "Connect GitHub first."
            githubAggregateBoard = nil
            return
        }

        let repos = gitHubProjects.compactMap(\.gitHubRemote)
        githubIsLoadingAggregateBoard = true
        githubLastError = nil

        Task {
            do {
                let service = GitHubSearchService(apiClient: GitHubAPIClient(session: session))
                let snapshot = try await service.fetchAggregateIssues(
                    repos: repos,
                    state: self.githubIssueStateFilter
                )

                await MainActor.run {
                    self.githubAggregateBoard = snapshot
                    self.githubIsLoadingAggregateBoard = false
                }
            } catch {
                await MainActor.run {
                    self.githubAggregateBoard = nil
                    self.githubIsLoadingAggregateBoard = false
                    self.githubLastError = error.localizedDescription
                }
            }
        }
    }

    func refreshProjectBoard(force: Bool = false) {
        guard let session = gitHubSession else {
            githubIsLoadingProjectBoard = false
            githubLastError = "Connect GitHub first."
            githubProjectBoard = nil
            githubProjectBoardCacheKey = nil
            githubProjectBoardFetchedAt = nil
            return
        }

        guard let remote = selectedGitHubProject?.gitHubRemote else {
            githubIsLoadingProjectBoard = false
            githubLastError = nil
            githubProjectBoard = nil
            githubProjectBoardCacheKey = nil
            githubProjectBoardFetchedAt = nil
            return
        }

        let state = githubIssueStateFilter
        let cacheKey = boardCacheKey(for: remote, state: state)
        if !force,
           githubProjectBoard != nil,
           githubProjectBoardCacheKey == cacheKey,
           !isGitHubBoardCacheStale(fetchedAt: githubProjectBoardFetchedAt) {
            return
        }

        githubProjectBoardRequestID += 1
        let requestID = githubProjectBoardRequestID
        githubIsLoadingProjectBoard = true
        githubLastError = nil

        Task {
            do {
                let service = GitHubSearchService(apiClient: GitHubAPIClient(session: session))
                let snapshot = try await service.fetchRepositoryIssues(
                    repo: remote,
                    state: state
                )

                await MainActor.run {
                    guard self.githubProjectBoardRequestID == requestID,
                          self.selectedGitHubProject?.gitHubRemote == remote,
                          self.githubIssueStateFilter == state else { return }

                    self.githubProjectBoard = snapshot
                    self.githubProjectBoardCacheKey = cacheKey
                    self.githubProjectBoardFetchedAt = Date()
                    self.githubIsLoadingProjectBoard = false

                    let visibleItemIDs = Set(snapshot.columns.flatMap(\.items).map(\.id))
                    if let selectedID = self.githubSelectedWorkItem?.id,
                       !visibleItemIDs.contains(selectedID) {
                        self.githubIssueDetailRequestID += 1
                        self.githubSelectedWorkItem = nil
                        self.githubIssueDetail = nil
                        self.githubCommentDraft = ""
                        self.githubIsLoadingIssueDetail = false
                        self.githubIsSubmittingComment = false
                    }
                }
            } catch {
                await MainActor.run {
                    guard self.githubProjectBoardRequestID == requestID,
                          self.selectedGitHubProject?.gitHubRemote == remote,
                          self.githubIssueStateFilter == state else { return }

                    self.githubProjectBoard = nil
                    self.githubProjectBoardCacheKey = nil
                    self.githubProjectBoardFetchedAt = nil
                    self.githubIsLoadingProjectBoard = false
                    self.githubLastError = error.localizedDescription
                }
            }
        }
    }

    func refreshRepositoryChanges(preservingDiffSelection: Bool = false, force: Bool = true) {
        guard let project = selectedDiscoveredProject, project.isGitRepository else {
            githubRepositoryChangesRequestID += 1
            githubRepositoryChanges = nil
            githubRepositoryChangesProjectPath = nil
            githubSelectedChangePaths = []
            githubSelectedDiffFilePath = nil
            githubSelectedDiffKind = nil
            githubSelectedDiffText = nil
            githubIsLoadingRepositoryChanges = false
            githubLastError = nil
            return
        }

        refreshRepositoryChanges(
            forProjectPath: project.path,
            preservingDiffSelection: preservingDiffSelection,
            force: force,
            activeContextIsCurrent: { [weak self] in
                guard let self else { return false }
                return self.selectedDiscoveredProject?.path == project.path
            }
        )
    }

    func loadDiff(for filePath: String, kind: GitDiffKind) {
        guard let project = selectedDiscoveredProject else { return }
        let cacheKey = GitDiffCacheKey(projectPath: project.path, filePath: filePath, kind: kind)
        if githubSelectedDiffFilePath == filePath,
           githubSelectedDiffKind == kind,
           githubSelectedDiffText != nil {
            return
        }

        githubDiffRequestID += 1
        let requestID = githubDiffRequestID
        githubSelectedDiffFilePath = filePath
        githubSelectedDiffKind = kind
        githubSelectedDiffText = cachedGithubDiff(for: cacheKey)
        githubLastError = nil

        Task {
            do {
                let diff = try await self.gitRepositoryService.loadDiff(for: filePath, kind: kind, in: project.url)
                await MainActor.run {
                    guard self.githubDiffRequestID == requestID,
                          self.selectedDiscoveredProject?.path == project.path,
                          self.githubSelectedDiffFilePath == filePath,
                          self.githubSelectedDiffKind == kind else { return }
                    let displayText = diff.isEmpty ? "No \(kind.rawValue.lowercased()) diff for this file." : diff
                    self.storeGithubDiff(displayText, for: cacheKey)
                    self.githubSelectedDiffText = displayText
                }
            } catch {
                await MainActor.run {
                    guard self.githubDiffRequestID == requestID,
                          self.selectedDiscoveredProject?.path == project.path,
                          self.githubSelectedDiffFilePath == filePath,
                          self.githubSelectedDiffKind == kind else { return }
                    self.githubSelectedDiffText = nil
                    self.githubLastError = error.localizedDescription
                }
            }
        }
    }

    func stage(_ filePath: String) {
        guard let project = selectedDiscoveredProject else { return }
        githubLastError = nil

        Task {
            do {
                try await self.gitRepositoryService.stage(filePath, in: project.url)
                await MainActor.run {
                    self.invalidateDiffCache(projectPath: project.path, filePath: filePath)
                    self.refreshRepositoryChanges(preservingDiffSelection: true)
                    self.loadDiff(for: filePath, kind: .staged)
                }
            } catch {
                await MainActor.run {
                    self.githubLastError = error.localizedDescription
                }
            }
        }
    }

    func unstage(_ filePath: String) {
        guard let project = selectedDiscoveredProject else { return }
        githubLastError = nil

        Task {
            do {
                try await self.gitRepositoryService.unstage(filePath, in: project.url)
                await MainActor.run {
                    self.invalidateDiffCache(projectPath: project.path, filePath: filePath)
                    self.refreshRepositoryChanges(preservingDiffSelection: true)
                    self.loadDiff(for: filePath, kind: .unstaged)
                }
            } catch {
                await MainActor.run {
                    self.githubLastError = error.localizedDescription
                }
            }
        }
    }

    func toggleChangeSelection(_ filePath: String) {
        if githubSelectedChangePaths.contains(filePath) {
            githubSelectedChangePaths.remove(filePath)
        } else {
            githubSelectedChangePaths.insert(filePath)
        }
    }

    func selectAllVisibleChanges() {
        guard let snapshot = githubRepositoryChanges else { return }
        githubSelectedChangePaths = Set(snapshot.staged.map(\.path) + snapshot.unstaged.map(\.path) + snapshot.untracked.map(\.path) + snapshot.conflicted.map(\.path))
    }

    func clearSelectedChanges() {
        githubSelectedChangePaths.removeAll()
    }

    func stageSelectedChanges() {
        guard let project = selectedDiscoveredProject else { return }
        let paths = Array(githubSelectedChangePaths)
        guard !paths.isEmpty else { return }
        githubLastError = nil

        Task {
            do {
                for path in paths {
                    try await self.gitRepositoryService.stage(path, in: project.url)
                }
                await MainActor.run { self.refreshRepositoryChanges() }
            } catch {
                await MainActor.run { self.githubLastError = error.localizedDescription }
            }
        }
    }

    func unstageSelectedChanges() {
        guard let project = selectedDiscoveredProject else { return }
        let paths = Array(githubSelectedChangePaths)
        guard !paths.isEmpty else { return }
        githubLastError = nil

        Task {
            do {
                for path in paths {
                    try await self.gitRepositoryService.unstage(path, in: project.url)
                }
                await MainActor.run { self.refreshRepositoryChanges() }
            } catch {
                await MainActor.run { self.githubLastError = error.localizedDescription }
            }
        }
    }

    func stageAllChanges() {
        guard let project = selectedDiscoveredProject else { return }
        githubLastError = nil

        Task {
            do {
                try await self.gitRepositoryService.stageAll(in: project.url)
                await MainActor.run {
                    self.invalidateDiffCache(projectPath: project.path)
                    self.refreshRepositoryChanges(preservingDiffSelection: true)
                }
            } catch {
                await MainActor.run { self.githubLastError = error.localizedDescription }
            }
        }
    }

    func unstageAllChanges() {
        guard let project = selectedDiscoveredProject else { return }
        githubLastError = nil

        Task {
            do {
                try await self.gitRepositoryService.unstageAll(in: project.url)
                await MainActor.run {
                    self.invalidateDiffCache(projectPath: project.path)
                    self.refreshRepositoryChanges(preservingDiffSelection: true)
                }
            } catch {
                await MainActor.run { self.githubLastError = error.localizedDescription }
            }
        }
    }

    private func invalidateDiffCache(projectPath: String, filePath: String? = nil) {
        githubDiffCache = githubDiffCache.filter { entry in
            guard entry.key.projectPath == projectPath else { return true }
            guard let filePath else { return false }
            return entry.key.filePath != filePath
        }
        githubDiffCacheOrder.removeAll { key in
            guard key.projectPath == projectPath else { return false }
            guard let filePath else { return true }
            return key.filePath == filePath
        }
    }

    private func cachedGithubDiff(for key: GitDiffCacheKey) -> String? {
        guard let value = githubDiffCache[key] else { return nil }
        markGithubDiffCacheKeyUsed(key)
        return value
    }

    private func storeGithubDiff(_ value: String, for key: GitDiffCacheKey) {
        githubDiffCache[key] = value
        markGithubDiffCacheKeyUsed(key)
        while githubDiffCacheOrder.count > githubDiffCacheLimit, let oldest = githubDiffCacheOrder.first {
            githubDiffCacheOrder.removeFirst()
            githubDiffCache[oldest] = nil
        }
    }

    private func markGithubDiffCacheKeyUsed(_ key: GitDiffCacheKey) {
        githubDiffCacheOrder.removeAll { $0 == key }
        githubDiffCacheOrder.append(key)
    }

    func commitChanges() {
        guard let project = selectedDiscoveredProject else { return }
        let message = githubCommitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = githubCommitDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            githubLastError = "Enter a commit title first."
            return
        }

        githubIsCommitting = true
        githubLastError = nil

        Task {
            do {
                try await self.gitRepositoryService.commit(message: message, description: description, in: project.url)
                await MainActor.run {
                    self.githubCommitMessage = ""
                    self.githubCommitDescription = ""
                    self.githubIsCommitting = false
                    self.refreshRepositoryChanges()
                }
            } catch {
                await MainActor.run {
                    self.githubIsCommitting = false
                    self.githubLastError = error.localizedDescription
                }
            }
        }
    }

    func pushCurrentBranch() {
        guard let project = selectedDiscoveredProject else { return }
        githubIsPushing = true
        githubLastError = nil

        Task {
            do {
                try await self.gitRepositoryService.pushCurrentBranch(in: project.url)
                await MainActor.run {
                    self.githubIsPushing = false
                    self.refreshRepositoryChanges()
                }
            } catch {
                await MainActor.run {
                    self.githubIsPushing = false
                    self.githubLastError = error.localizedDescription
                }
            }
        }
    }

    func selectWorkItem(_ item: GitHubWorkItem) {
        githubSelectedWorkItem = item
        githubIssueDetail = nil
        githubCommentDraft = ""
        loadIssueDetail(for: item)
    }

    func selectIssueReference(_ reference: GitHubIssueReference) {
        if let matchingProject = discoveredProjects.first(where: {
            $0.gitHubRemote?.nameWithOwner.caseInsensitiveCompare(reference.repository) == .orderedSame
        }), selectedProjectPath != matchingProject.path {
            setSelectedProject(matchingProject.url)
        }

        if let existing = githubProjectBoard?.allItems.first(where: { $0.repository == reference.repository && $0.number == reference.number }) {
            selectWorkItem(existing)
            return
        }

        let item = GitHubWorkItem(
            id: "\(reference.repository)-\(reference.number)",
            number: reference.number,
            title: reference.title,
            repository: reference.repository,
            url: reference.url,
            isPullRequest: false,
            state: reference.state,
            stateReason: nil,
            type: reference.type,
            labels: [],
            assignees: [],
            author: nil,
            body: "",
            commentCount: 0,
            createdAt: .distantPast,
            updatedAt: .distantPast,
            closedAt: nil,
            subIssuesSummary: nil,
            issueDependenciesSummary: nil
        )
        selectWorkItem(item)
    }

    func loadIssueDetail(for item: GitHubWorkItem) {
        guard let session = gitHubSession else {
            githubIsLoadingIssueDetail = false
            githubLastError = "Connect GitHub first."
            return
        }

        githubIssueDetailRequestID += 1
        let requestID = githubIssueDetailRequestID
        githubIsLoadingIssueDetail = true
        githubLastError = nil

        Task {
            do {
                let service = GitHubIssueService(apiClient: GitHubAPIClient(session: session))
                let detail = try await service.fetchDetail(for: item)
                await MainActor.run {
                    guard self.githubIssueDetailRequestID == requestID,
                          self.githubSelectedWorkItem == item else { return }

                    self.githubIssueDetail = detail
                    self.githubIsLoadingIssueDetail = false
                }
            } catch {
                await MainActor.run {
                    guard self.githubIssueDetailRequestID == requestID,
                          self.githubSelectedWorkItem == item else { return }

                    self.githubIssueDetail = nil
                    self.githubIsLoadingIssueDetail = false
                    self.githubLastError = error.localizedDescription
                }
            }
        }
    }

    func openPiAgentForSelectedProject() {
        selectedSidebarItem = .agent
        isPiAgentInspectorPresented = false
        let project = piAgentSessionProjectContext()
        if piAgentSessionStore.selectedSession?.projectPath != project.path {
            let existing = piAgentSessionStore.sessions.first { $0.projectPath == project.path && $0.kind == .project }
            if let existing {
                selectPiAgentSession(existing.id)
                ensurePiAgentModelCatalogLoaded()
            } else {
                _ = piAgentSessionStore.createSession(
                    kind: .project,
                    title: "Project agent · \(project.name)",
                    project: project,
                    repository: project.gitHubRemote?.nameWithOwner
                )
                ensurePiAgentModelCatalogLoaded()
            }
        } else {
            acknowledgeVisibleSelectedPiAgentSession()
        }
    }

    func createPiAgentDraftForSelectedProject() {
        createPiAgentDraft(for: piAgentSessionProjectContext())
    }

    func createPiAgentDraft(for project: DiscoveredProject) {
        selectedSidebarItem = .agent
        isPiAgentInspectorPresented = false
        _ = piAgentSessionStore.createSession(
            kind: .project,
            title: "Draft · \(project.name)",
            project: project,
            repository: project.gitHubRemote?.nameWithOwner
        )
        ensurePiAgentModelCatalogLoaded()
    }

    func startPiAgentForSelectedProject(initialInstruction: String) {
        guard let project = selectedDiscoveredProject else {
            githubLastError = "Select a project before starting Pi Agent."
            selectedSidebarItem = .agent
            return
        }
        selectedSidebarItem = .agent
        isPiAgentInspectorPresented = true
        piAgentRunner.startProjectSession(project: project, initialInstruction: initialInstruction)
    }

    func startPiAgentForIssue(_ detail: GitHubIssueDetail) {
        guard let project = selectedDiscoveredProject else {
            githubLastError = "Select the local project for this issue before starting Pi Agent."
            return
        }
        selectedSidebarItem = .agent
        isPiAgentInspectorPresented = false
        _ = piAgentSessionStore.createSession(
            kind: .issue,
            title: detail.item.title,
            project: project,
            repository: detail.item.repository,
            issueNumber: detail.item.number,
            issueURL: detail.item.url
        )
        ensurePiAgentModelCatalogLoaded()
        piAgentPendingComposerText = PiIssuePromptBuilder.issuePrompt(detail: detail, project: project)
    }

    func consumePendingPiAgentComposerText() -> String? {
        guard let pending = piAgentPendingComposerText else { return nil }
        piAgentPendingComposerText = nil
        return pending
    }

    func openPiAgentScreen() {
        selectedSidebarItem = .agent
        if piAgentSessionStore.selectedSession?.id != nil {
            ensurePiAgentModelCatalogLoaded()
        }
        prepareRepoChangesForSelectedPiAgentSession()
        acknowledgeVisibleSelectedPiAgentSession()
    }

    func selectPiAgentSession(_ id: UUID) {
        piAgentSessionStore.select(id)
        selectedSidebarItem = .agent
        ensurePiAgentModelCatalogLoaded()
        prepareRepoChangesForSelectedPiAgentSession()
        acknowledgePiAgentSession(id)
    }

    func acknowledgeVisibleSelectedPiAgentSession() {
        guard let sessionID = piAgentSessionStore.selectedSession?.id,
              isPiAgentSessionActuallyVisible(sessionID) else { return }
        acknowledgePiAgentSession(sessionID)
    }

    var piAgentNeedsAttentionCount: Int {
        piAgentSessionStore.sessions.filter(\.needsAttention).count
    }

    var piAgentRunningSessionCount: Int {
        piAgentSessionStore.sessions.filter { session in
            !session.needsAttention && piAgentSessionIsWorking(session)
        }.count
    }

    func piAgentSessionIsWorking(_ session: PiAgentSessionRecord) -> Bool {
        session.status.isActive || piAgentSessionHasActiveSubagent(session.id)
    }

    private func piAgentSessionHasActiveSubagent(_ sessionID: UUID) -> Bool {
        piAgentSessionStore.subagentRuns(for: sessionID).contains { $0.status.isActive }
    }

    func isModelEnabled(_ model: AvailableModel) -> Bool {
        !appSettings.disabledModelIdentifiers.contains(model.identifier)
    }

    func setModelEnabled(_ model: AvailableModel, isEnabled: Bool) {
        guard appSettingsController.setModelEnabled(identifier: model.identifier, isEnabled: isEnabled) else { return }
        appSettings = appSettingsController.settings
    }

    func isOpenAIFastModeEnabled(_ model: AvailableModel) -> Bool {
        appSettings.openAIFastModeModelIdentifiers.contains(model.identifier)
    }

    func setOpenAIFastMode(_ model: AvailableModel, isEnabled: Bool) {
        guard PiNativeSubagentBridgeExtensions.isOpenAIFastEligibleModel(provider: model.provider, modelID: model.model) else { return }
        guard appSettingsController.setOpenAIFastMode(identifier: model.identifier, isEnabled: isEnabled) else { return }
        syncAppSettings()
    }

    func enableAllModels() {
        guard appSettingsController.enableAllModels() else { return }
        appSettings = appSettingsController.settings
    }

    func setDefaultPiAgentModel(_ model: AvailableModel?) {
        guard writePiRuntimeDefaults(provider: model?.provider, model: model?.model, thinkingLevel: nil) else { return }
        piRuntimeSettingsRevision += 1
    }

    func setDefaultPiAgentThinkingLevel(_ level: String) {
        guard writePiRuntimeDefaults(provider: nil, model: nil, thinkingLevel: level) else { return }
        piRuntimeSettingsRevision += 1
    }

    func acknowledgePiAgentSession(_ id: UUID) {
        pendingPiAgentNotificationTasks[id]?.cancel()
        pendingPiAgentNotificationTasks[id] = nil
        piAgentSessionStore.updateSession(id) { $0.needsAttention = false }
        let identifier = piAgentNotificationIdentifier(for: id)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    private func handlePiAgentTurnFinished(_ sessionID: UUID) {
        guard let session = piAgentSessionStore.sessions.first(where: { $0.id == sessionID }) else { return }
        if isPiAgentSessionActuallyVisible(sessionID) {
            acknowledgePiAgentSession(sessionID)
            return
        }

        guard !session.needsAttention else { return }
        piAgentSessionStore.updateSession(sessionID) { record in
            record.status = .idle
            record.needsAttention = true
        }
        schedulePiAgentCompletionNotification(for: sessionID)
    }

    private func isPiAgentSessionActuallyVisible(_ sessionID: UUID) -> Bool {
        NSApp.isActive
            && selectedSidebarItem == .agent
            && piAgentSessionStore.selectedSession?.id == sessionID
            && (NSApp.keyWindow?.isVisible ?? NSApp.mainWindow?.isVisible ?? false)
    }

    private func schedulePiAgentCompletionNotification(for sessionID: UUID) {
        pendingPiAgentNotificationTasks[sessionID]?.cancel()
        let delay = UInt64(piAgentNotificationDelay * 1_000_000_000)
        pendingPiAgentNotificationTasks[sessionID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.sendPiAgentCompletionNotificationIfNeeded(for: sessionID)
            }
        }
    }

    private func sendPiAgentCompletionNotificationIfNeeded(for sessionID: UUID) {
        pendingPiAgentNotificationTasks[sessionID] = nil
        guard let session = piAgentSessionStore.sessions.first(where: { $0.id == sessionID }) else { return }
        guard session.needsAttention, !isPiAgentSessionActuallyVisible(sessionID), shouldSendPiAgentSystemNotification else { return }
        sendPiAgentCompletionNotification(for: session)
    }

    private var shouldSendPiAgentSystemNotification: Bool {
        !NSApp.isActive || !(NSApp.keyWindow?.isVisible ?? NSApp.mainWindow?.isVisible ?? false)
    }

    private func piAgentNotificationIdentifier(for sessionID: UUID) -> String {
        "pi-agent-\(sessionID.uuidString)"
    }

    private func sendPiAgentCompletionNotification(for session: PiAgentSessionRecord) {
        Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
                guard granted else { return }

                let content = UNMutableNotificationContent()
                content.title = "Pi Agent needs review"
                content.body = session.displayTitle
                content.userInfo = [
                    "sessionID": session.id.uuidString,
                    "windowID": windowID.uuidString
                ]

                let request = UNNotificationRequest(
                    identifier: "pi-agent-\(session.id.uuidString)",
                    content: content,
                    trigger: nil
                )

                try await UNUserNotificationCenter.current().add(request)
                self.piAgentSessionStore.updateSession(session.id) { record in
                    record.lastNotificationAt = Date()
                }
            } catch {
                return
            }
        }
    }

    func renamePiAgentSession(_ id: UUID, title: String) {
        piAgentSessionStore.renameSession(id, title: title)
        piAgentRunner.syncSessionName(for: id)
    }

    var canOpenSelectedPiAgentSessionInTerminal: Bool {
        guard let session = piAgentSessionStore.selectedSession else { return false }
        if let sessionFile = session.piSessionFile, FileManager.default.fileExists(atPath: sessionFile) { return true }
        return session.piSessionId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    func openPiSelfUpdateInTerminal() {
        let operationID = UUID()
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-deck-pi-update-\(operationID.uuidString)")
            .appendingPathExtension("command")
        let updateCommand = terminalPiSelfUpdateCommand()
        let script = """
        #!/bin/zsh
        \(updateCommand)
        """

        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
            openTerminalScript(scriptURL, command: updateCommand, for: operationID)
        } catch {
            NSLog("Failed to create Pi update terminal script: \(error.localizedDescription)")
        }
    }

    private func terminalPiSelfUpdateCommand() -> String {
        """
        export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
        if command -v pi >/dev/null 2>&1; then
          pi update pi
        elif [ -x /opt/homebrew/bin/pi ]; then
          /opt/homebrew/bin/pi update pi
        elif [ -x /usr/local/bin/pi ]; then
          /usr/local/bin/pi update pi
        else
          echo "Pi CLI not found. Install pi or add it to PATH."
        fi
        echo ""
        echo "Press any key to close."
        read -k 1
        """
    }

    func openSelectedPiAgentSessionInTerminal() {
        guard let session = piAgentSessionStore.selectedSession,
              let sessionRef = resumablePiSessionReference(for: session) else { return }
        acknowledgePiAgentSession(session.id)

        let workingDirectory = session.worktreePath ?? session.projectPath
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-deck-resume-\(session.id.uuidString)")
            .appendingPathExtension("command")
        let resumeCommand = terminalResumeCommand(workingDirectory: workingDirectory, sessionReference: sessionRef)
        let script = """
        #!/bin/zsh
        \(resumeCommand)
        """

        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
            openTerminalScript(scriptURL, command: resumeCommand, for: session.id)
        } catch {
            piAgentSessionStore.updateSession(session.id) { record in
                record.lastError = error.localizedDescription
            }
        }
    }

    private func resumablePiSessionReference(for session: PiAgentSessionRecord) -> String? {
        if let sessionFile = session.piSessionFile?.trimmingCharacters(in: .whitespacesAndNewlines),
           !sessionFile.isEmpty,
           FileManager.default.fileExists(atPath: sessionFile) {
            return sessionFile
        }
        if let sessionID = session.piSessionId?.trimmingCharacters(in: .whitespacesAndNewlines), !sessionID.isEmpty {
            return sessionID
        }
        if let sessionFile = session.piSessionFile?.trimmingCharacters(in: .whitespacesAndNewlines), !sessionFile.isEmpty {
            piAgentSessionStore.updateSession(session.id) { record in
                record.lastError = "Pi session file no longer exists; trying session id if available."
            }
        }
        return nil
    }

    private func terminalResumeCommand(workingDirectory: String, sessionReference: String) -> String {
        """
        cd \(shellQuoted(workingDirectory)) || exit 1
        export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
        if command -v pi >/dev/null 2>&1; then
          exec pi --session \(shellQuoted(sessionReference))
        elif [ -x /opt/homebrew/bin/pi ]; then
          exec /opt/homebrew/bin/pi --session \(shellQuoted(sessionReference))
        elif [ -x /usr/local/bin/pi ]; then
          exec /usr/local/bin/pi --session \(shellQuoted(sessionReference))
        else
          echo "Pi CLI not found. Install pi or add it to PATH."
          echo ""
          echo "Command: pi --session \(shellQuoted(sessionReference))"
          read -k 1 "?Press any key to close."
        fi
        """
    }

    private func openTerminalScript(_ scriptURL: URL, command: String, for sessionID: UUID) {
        let selectedTerminalPath = appSettings.piAgentTerminalApplicationPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedTerminalName = selectedTerminalPath.map { URL(fileURLWithPath: $0).lastPathComponent.lowercased() }

        if selectedTerminalPath == nil || selectedTerminalName == "terminal.app" {
            if openInAppleTerminal(command: command, sessionID: sessionID) { return }
            openCommandFile(scriptURL, withApplicationAt: defaultTerminalURL(), sessionID: sessionID)
            return
        }
        if selectedTerminalName == "iterm.app" {
            if openInITerm(command: command, sessionID: sessionID) { return }
            openCommandFile(scriptURL, withApplicationAt: selectedTerminalPath.map(URL.init(fileURLWithPath:)), sessionID: sessionID)
            return
        }

        guard let terminalPath = selectedTerminalPath, !terminalPath.isEmpty else { return }
        let terminalURL = URL(fileURLWithPath: terminalPath)
        guard FileManager.default.fileExists(atPath: terminalURL.path) else {
            piAgentSessionStore.updateSession(sessionID) { record in
                record.lastError = "Selected terminal app no longer exists. Choose another app in Settings."
            }
            return
        }

        openCommandFile(scriptURL, withApplicationAt: terminalURL, sessionID: sessionID)
    }

    private func openCommandFile(_ scriptURL: URL, withApplicationAt terminalURL: URL?, sessionID: UUID) {
        guard let terminalURL else {
            guard NSWorkspace.shared.open(scriptURL) else {
                piAgentSessionStore.updateSession(sessionID) { record in
                    record.lastError = "Could not open the default terminal app."
                }
                return
            }
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let sessionStore = piAgentSessionStore
        NSWorkspace.shared.open([scriptURL], withApplicationAt: terminalURL, configuration: configuration) { _, error in
            guard let error else { return }
            Task { @MainActor in
                sessionStore.updateSession(sessionID) { record in
                    record.lastError = error.localizedDescription
                }
            }
        }
    }

    private func defaultTerminalURL() -> URL? {
        [
            "/System/Applications/Utilities/Terminal.app",
            "/Applications/Utilities/Terminal.app"
        ]
        .map(URL.init(fileURLWithPath:))
        .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    @discardableResult
    private func openInAppleTerminal(command: String, sessionID: UUID) -> Bool {
        let script = """
        tell application "Terminal"
            activate
            do script "\(appleScriptEscaped(command))"
        end tell
        """
        return runAppleScript(script, sessionID: sessionID, fallbackMessage: "Could not open Terminal.")
    }

    @discardableResult
    private func openInITerm(command: String, sessionID: UUID) -> Bool {
        let script = """
        tell application "iTerm"
            activate
            create window with default profile command "\(appleScriptEscaped(command))"
        end tell
        """
        return runAppleScript(script, sessionID: sessionID, fallbackMessage: "Could not open iTerm.")
    }

    @discardableResult
    private func runAppleScript(_ source: String, sessionID: UUID, fallbackMessage: String) -> Bool {
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            piAgentSessionStore.updateSession(sessionID) { $0.lastError = fallbackMessage }
            return false
        }
        _ = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = (errorInfo[NSAppleScript.errorMessage] as? String) ?? fallbackMessage
            piAgentSessionStore.updateSession(sessionID) { record in
                record.lastError = message
            }
            return false
        }
        return true
    }

    private func appleScriptEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func togglePiAgentSessionPinned(_ id: UUID) {
        piAgentSessionStore.togglePinned(id)
    }

    func resumeSelectedPiAgentSession() {
        guard let session = piAgentSessionStore.selectedSession else { return }
        selectedSidebarItem = .agent
        isPiAgentInspectorPresented = true
        acknowledgePiAgentSession(session.id)
        piAgentRunner.resume(session: session)
    }

    func runNativeSubagent(agentName: String, task: String, useWorktreeIsolation: Bool = false, allowDirectProjectWrites: Bool = false, expectedOutcome: PiSubagentExpectedOutcome = .reportOnly, requestedOutputPath: String? = nil, allowOverwrite: Bool = false, readFirstPaths: [String] = []) {
        guard let session = piAgentSessionStore.selectedSession else { return }
        runNativeSubagent(parentSession: session, agentName: agentName, task: task, useWorktreeIsolation: useWorktreeIsolation, allowDirectProjectWrites: allowDirectProjectWrites, expectedOutcome: expectedOutcome, requestedOutputPath: requestedOutputPath, allowOverwrite: allowOverwrite, readFirstPaths: readFirstPaths, completion: nil)
    }

    func runNativeParallel(agentTasks: [(agentName: String, task: String)], concurrency: Int = 4, useWorktreeIsolation: Bool = false) {
        guard let session = piAgentSessionStore.selectedSession else { return }
        runNativeParallel(parentSession: session, agentTasks: agentTasks, concurrency: concurrency, useWorktreeIsolation: useWorktreeIsolation, completion: nil)
    }

    private func runManagedNativeSubagent(parentSessionID: UUID, request: PiManagedSubagentBridgeRequest, completion: @escaping (String) -> Void) {
        guard let session = piAgentSessionStore.sessions.first(where: { $0.id == parentSessionID }) else {
            completion("\(AppBrand.displayName) could not find the parent session.")
            return
        }
        guard session.subagentsEnabled else {
            completion("Native subagents are disabled for this \(AppBrand.displayName) session.")
            return
        }
        let continueRunID = request.continueSubagentID.flatMap { UUID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if request.continueSubagentID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false, continueRunID == nil {
            completion("Invalid continueSubagentID `\(request.continueSubagentID ?? "")`. Use the Subagent ID shown on the native subagent card.")
            return
        }
        let useWorktreeIsolation = false
        let expectedOutcome: PiSubagentExpectedOutcome = .reportOnly
        let gate = NativeSubagentCompletionGate()
        var timeoutTask: Task<Void, Never>?
        let launchedRun = runNativeSubagent(parentSession: session, agentName: request.agent, task: request.task, continueRunID: continueRunID, useWorktreeIsolation: useWorktreeIsolation, allowDirectProjectWrites: false, expectedOutcome: expectedOutcome, requestedOutputPath: nil, allowOverwrite: false, readFirstPaths: request.reads ?? []) { run in
            timeoutTask?.cancel()
            gate.complete {
                let status = run.status == .completed ? "completed" : run.status.rawValue
                let summary = run.summary ?? run.error ?? "No summary returned."
                let isPersistedRun = self.piAgentSessionStore.subagentRuns(for: parentSessionID).contains { $0.id == run.id }
                let idLine = isPersistedRun ? "\nSubagent ID: \(run.id.uuidString)" : ""
                completion("Native subagent \(run.agentName) \(status).\(idLine)\n\n\(summary)")
            }
        }
        if launchedRun.status.isActive, !gate.isCompleted {
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(30 * 60))
                await MainActor.run {
                    guard let self else { return }
                    gate.complete {
                        self.nativeSubagentRunner.stop(runID: launchedRun.id, parentSessionID: parentSessionID)
                        completion("Native subagent \(launchedRun.agentName) timed out after 30 minutes waiting for a result.")
                    }
                }
            }
        }
    }

    private func runManagedNativeParallel(parentSessionID: UUID, request: PiManagedParallelBridgeRequest, completion: @escaping (String) -> Void) {
        guard let session = piAgentSessionStore.sessions.first(where: { $0.id == parentSessionID }) else {
            completion("\(AppBrand.displayName) could not find the parent session.")
            return
        }
        guard session.subagentsEnabled else {
            completion("Native subagents are disabled for this \(AppBrand.displayName) session.")
            return
        }
        let tasks = request.tasks.map { (agentName: $0.agent, task: $0.task) }
        let useWorktreeIsolation = request.worktree == true
        runNativeParallel(parentSession: session, agentTasks: tasks, concurrency: request.concurrency ?? 4, useWorktreeIsolation: useWorktreeIsolation) { run in
            let status = run.status == .completed ? "completed" : run.status.rawValue
            completion("Native parallel run \(status).\n\n\(run.summary ?? run.error ?? "No summary returned.")")
        }
    }

    @discardableResult
    private func runNativeSubagent(parentSession: PiAgentSessionRecord, agentName: String, task: String, continueRunID: UUID? = nil, useWorktreeIsolation: Bool, allowDirectProjectWrites: Bool = false, expectedOutcome: PiSubagentExpectedOutcome = .reportOnly, requestedOutputPath: String? = nil, allowOverwrite: Bool = false, readFirstPaths: [String] = [], completion: ((PiSubagentRunRecord) -> Void)?) -> PiSubagentRunRecord {
        guard parentSession.subagentsEnabled else {
            let message = "Native subagents are disabled for this session."
            piAgentSessionStore.append(.init(sessionID: parentSession.id, role: .error, title: "Subagents Disabled", text: message))
            let placeholder = PiSubagentRunRecord.failedPlaceholder(parentSessionID: parentSession.id, agentName: agentName, task: task, error: message)
            completion?(placeholder)
            return placeholder
        }
        let snapshot = startupSnapshot(forProjectPath: parentSession.projectPath)
        guard let agent = snapshot.effectiveAgents.first(where: { $0.name == agentName && $0.resolved.disabled != true }) else {
            let message = "No enabled agent named \(agentName) was found for this session."
            piAgentSessionStore.append(.init(sessionID: parentSession.id, role: .error, title: "Subagent Not Found", text: message))
            let placeholder = PiSubagentRunRecord.failedPlaceholder(parentSessionID: parentSession.id, agentName: agentName, task: task, error: message)
            completion?(placeholder)
            return placeholder
        }
        if let validationError = validateNativeSubagentOutcome(parentSession: parentSession, expectedOutcome: expectedOutcome, requestedOutputPath: requestedOutputPath, allowOverwrite: allowOverwrite, allowDirectProjectWrites: allowDirectProjectWrites) {
            piAgentSessionStore.append(.init(sessionID: parentSession.id, role: .error, title: "Subagent Output Policy", text: validationError))
            let placeholder = PiSubagentRunRecord.failedPlaceholder(parentSessionID: parentSession.id, agentName: agentName, task: task, error: validationError)
            completion?(placeholder)
            return placeholder
        }
        return runNativeSubagent(parentSession: parentSession, agent: agent, snapshot: snapshotWithSkillCatalog(snapshot, projectPath: parentSession.projectPath), task: task, continueRunID: continueRunID, useWorktreeIsolation: useWorktreeIsolation, expectedOutcome: expectedOutcome, requestedOutputPath: requestedOutputPath, allowOverwrite: allowOverwrite, readFirstPaths: readFirstPaths, completion: completion)
    }

    private func snapshotWithSkillCatalog(_ base: ScanSnapshot, projectPath: String) -> ScanSnapshot {
        ScanSnapshot(
            projectRoot: base.projectRoot,
            builtinAgents: base.builtinAgents,
            globalAgents: base.globalAgents,
            projectAgents: base.projectAgents,
            legacyProjectAgents: base.legacyProjectAgents,
            effectiveAgents: base.effectiveAgents,
            libraryAgents: base.libraryAgents,
            skills: skillCatalog(forProjectPath: projectPath),
            librarySkills: [],
            promptTemplates: base.promptTemplates,
            libraryPromptTemplates: base.libraryPromptTemplates,
            settings: base.settings,
            envKeys: base.envKeys,
            warnings: base.warnings
        )
    }

    @discardableResult
    private func runNativeSubagent(parentSession: PiAgentSessionRecord, agent: EffectiveAgentRecord, snapshot: ScanSnapshot, task: String, continueRunID: UUID? = nil, useWorktreeIsolation: Bool, expectedOutcome: PiSubagentExpectedOutcome = .reportOnly, requestedOutputPath: String? = nil, allowOverwrite: Bool = false, readFirstPaths: [String] = [], completion: ((PiSubagentRunRecord) -> Void)?) -> PiSubagentRunRecord {
        do {
            return try nativeSubagentRunner.runSingle(parentSession: parentSession, agent: agent, snapshot: snapshot, task: task, continueRunID: continueRunID, useWorktreeIsolation: useWorktreeIsolation, expectedOutcome: expectedOutcome, requestedOutputPath: requestedOutputPath, allowOverwrite: allowOverwrite, readFirstPaths: readFirstPaths, onCompletion: completion)
        } catch {
            piAgentSessionStore.append(.init(sessionID: parentSession.id, role: .error, title: "Subagent Launch Failed", text: error.localizedDescription))
            let placeholder = PiSubagentRunRecord.failedPlaceholder(parentSessionID: parentSession.id, agentName: agent.name, task: task, error: error.localizedDescription)
            completion?(placeholder)
            return placeholder
        }
    }

    private func runNativeParallel(parentSession: PiAgentSessionRecord, agentTasks: [(agentName: String, task: String)], concurrency: Int, useWorktreeIsolation: Bool, completion: ((PiSubagentRunRecord) -> Void)?) {
        let tasks = agentTasks.map { ($0.agentName.trimmingCharacters(in: .whitespacesAndNewlines), $0.task.trimmingCharacters(in: .whitespacesAndNewlines)) }.filter { !$0.0.isEmpty && !$0.1.isEmpty }
        guard !tasks.isEmpty else { return }
        let now = Date()
        let runID = UUID()
        let artifactDirectory = nativeGraphArtifactDirectory(for: runID)
        let childRecords = tasks.enumerated().map { index, item in
            PiSubagentChildRecord(
                id: UUID(), runID: runID, index: index, agentName: item.0, task: item.1,
                status: .queued, model: nil,
                expectedOutcome: useWorktreeIsolation ? .editFilesInWorktree : .reportOnly, requestedOutputPath: nil, allowOverwrite: false,
                currentTool: nil, inputTokens: nil, outputTokens: nil, totalTokens: nil, toolCount: nil, durationMs: nil,
                artifactDirectory: nil, sessionFile: nil, outputPath: nil, worktreePath: nil, launchCommand: nil, executionRunID: nil,
                summary: nil, error: nil, dependencies: nil, completedAt: nil, createdAt: now, updatedAt: now
            )
        }
        let limit = max(1, min(concurrency, tasks.count))
        let run = nativeGraphRun(id: runID, parentSession: parentSession, mode: .parallel, title: "Parallel", task: "\(tasks.count) parallel native subagent task(s)", artifactDirectory: artifactDirectory, children: childRecords, edges: [], concurrency: limit, worktreeIsolation: useWorktreeIsolation)
        piAgentSessionStore.upsertSubagentRun(run)
        piAgentSessionStore.append(.init(
            sessionID: parentSession.id,
            role: .status,
            title: "Native Parallel Started",
            text: "Subagent ID: \(run.id.uuidString)\n\nStarted \(tasks.count) task(s), concurrency \(limit).",
            rawJSON: nativeSubagentCardPayload(for: run)
        ))
        let scheduler = NativeParallelGraphScheduler(parentSession: parentSession, graphRunID: runID, tasks: tasks.map { (agentName: $0.0, task: $0.1) }, concurrency: limit, useWorktreeIsolation: useWorktreeIsolation, completion: completion)
        nativeParallelSchedulersByID[scheduler.id] = scheduler
        pumpNativeParallelScheduler(scheduler)
    }

    private func pumpNativeParallelScheduler(_ scheduler: NativeParallelGraphScheduler) {
        if scheduler.completed == scheduler.tasks.count {
            let run = piAgentSessionStore.subagentRuns(for: scheduler.parentSession.id).first(where: { $0.id == scheduler.graphRunID })
            let summaries = (run?.children ?? []).sorted { $0.index < $1.index }.map { "- \($0.agentName): \($0.summary ?? $0.error ?? $0.status.rawValue)" }.joined(separator: "\n")
            finishNativeGraphRun(scheduler.graphRunID, parentSessionID: scheduler.parentSession.id, status: scheduler.failed ? .failed : .completed, summary: summaries, completion: scheduler.completion)
            nativeParallelSchedulersByID[scheduler.id] = nil
            return
        }
        while scheduler.active < scheduler.concurrency && scheduler.nextIndex < scheduler.tasks.count {
            let index = scheduler.nextIndex
            scheduler.nextIndex += 1
            scheduler.active += 1
            let item = scheduler.tasks[index]
            updateNativeGraphChild(scheduler.graphRunID, parentSessionID: scheduler.parentSession.id, index: index) { $0.status = .running }
            let childRun = runNativeSubagent(parentSession: scheduler.parentSession, agentName: item.agentName, task: item.task, useWorktreeIsolation: scheduler.useWorktreeIsolation, expectedOutcome: scheduler.useWorktreeIsolation ? .editFilesInWorktree : .reportOnly) { [weak self, weak scheduler] childResult in
                guard let self, let scheduler else { return }
                self.updateNativeGraphChildFromRun(scheduler.graphRunID, parentSessionID: scheduler.parentSession.id, index: index, childResult: childResult)
                scheduler.active = max(0, scheduler.active - 1)
                scheduler.completed += 1
                scheduler.failed = scheduler.failed || childResult.status != .completed
                self.pumpNativeParallelScheduler(scheduler)
            }
            updateNativeGraphChildFromRun(scheduler.graphRunID, parentSessionID: scheduler.parentSession.id, index: index, childResult: childRun)
        }
    }

    private func validateNativeSubagentOutcome(parentSession: PiAgentSessionRecord, expectedOutcome: PiSubagentExpectedOutcome, requestedOutputPath: String?, allowOverwrite: Bool, allowDirectProjectWrites: Bool) -> String? {
        switch expectedOutcome {
        case .reportOnly, .editFilesInWorktree:
            return nil
        case .directProjectWrites:
            return allowDirectProjectWrites ? nil : "Direct project writes require explicit approval."
        case .writeProjectFile:
            let trimmedPath = requestedOutputPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmedPath.isEmpty else { return "Write/update project file requires a project-relative output path." }
            guard !trimmedPath.hasPrefix("/") && !trimmedPath.contains("..") else { return "Output path must be project-relative and cannot contain `..`." }
            let rootURL = URL(fileURLWithPath: parentSession.worktreePath ?? parentSession.projectPath)
            let outputURL = rootURL.appendingPathComponent(trimmedPath).standardizedFileURL
            let rootPath = rootURL.standardizedFileURL.path.hasSuffix("/") ? rootURL.standardizedFileURL.path : rootURL.standardizedFileURL.path + "/"
            guard (outputURL.path + (outputURL.hasDirectoryPath ? "/" : "")).hasPrefix(rootPath) else { return "Output path must stay inside the project." }
            if FileManager.default.fileExists(atPath: outputURL.path), !allowOverwrite {
                return "`\(trimmedPath)` already exists. Enable overwrite or choose another output path."
            }
            return nil
        }
    }

    private func nativeGraphRun(id: UUID, parentSession: PiAgentSessionRecord, mode: PiSubagentRunMode, title: String, task: String, artifactDirectory: URL, children: [PiSubagentChildRecord], edges: [PiSubagentGraphEdgeRecord], concurrency: Int, worktreeIsolation: Bool) -> PiSubagentRunRecord {
        PiSubagentRunRecord(
            id: id, parentSessionID: parentSession.id, mode: mode, status: .running,
            agentName: title, task: task,
            model: nil, thinking: nil, expectedOutcome: worktreeIsolation ? .editFilesInWorktree : .reportOnly, requestedOutputPath: nil, allowOverwrite: false, tools: [], skills: [],
            concurrencyLimit: concurrency, worktreePolicy: worktreeIsolation ? "isolated-per-child" : "parent", aggregateSummary: nil,
            artifactDirectory: artifactDirectory.path, outputPath: artifactDirectory.appendingPathComponent("summary.md").path,
            worktreePath: nil, parentRepoPath: parentSession.worktreePath ?? parentSession.projectPath, baseCommit: nil,
            isWorktreeIsolated: false, worktreeStatus: PiSubagentWorktreeStatus.none, worktreePatchPath: nil,
            childSessionID: nil, childPiSessionFile: nil, launchCommand: nil, summary: nil, error: nil,
            child: nil, children: children, graphEdges: edges, createdAt: Date(), updatedAt: Date(), completedAt: nil, durationMs: nil
        )
    }

    private func finishNativeGraphRun(_ runID: UUID, parentSessionID: UUID, status: PiSubagentRunStatus, summary: String, completion: ((PiSubagentRunRecord) -> Void)?) {
        let completedAt = Date()
        piAgentSessionStore.updateSubagentRun(runID, parentSessionID: parentSessionID) { run in
            run.status = status
            run.summary = summary
            run.aggregateSummary = summary
            run.completedAt = completedAt
            run.durationMs = max(0, Int((completedAt.timeIntervalSince(run.createdAt) * 1000).rounded()))
            if status == .failed { run.error = summary }
        }
        if let outputPath = piAgentSessionStore.subagentRuns(for: parentSessionID).first(where: { $0.id == runID })?.outputPath {
            try? summary.write(toFile: outputPath, atomically: true, encoding: .utf8)
        }
        piAgentSessionStore.append(.init(sessionID: parentSessionID, role: status == .completed ? .status : .error, title: status == .completed ? "Native Graph Completed" : "Native Graph Failed", text: summary))
        if let run = piAgentSessionStore.subagentRuns(for: parentSessionID).first(where: { $0.id == runID }) { completion?(run) }
    }

    private func updateNativeGraphChild(_ runID: UUID, parentSessionID: UUID, index: Int, mutate: (inout PiSubagentChildRecord) -> Void) {
        piAgentSessionStore.updateSubagentRun(runID, parentSessionID: parentSessionID) { run in
            guard var children = run.children, children.indices.contains(index) else { return }
            mutate(&children[index])
            children[index].updatedAt = Date()
            run.children = children
        }
    }

    private func updateNativeGraphChildFromRun(_ graphRunID: UUID, parentSessionID: UUID, index: Int, childResult: PiSubagentRunRecord) {
        updateNativeGraphChild(graphRunID, parentSessionID: parentSessionID, index: index) { child in
            child.status = childResult.status
            child.executionRunID = childResult.id
            child.artifactDirectory = childResult.artifactDirectory
            child.outputPath = childResult.outputPath
            child.worktreePath = childResult.worktreePath
            child.launchCommand = childResult.launchCommand
            child.summary = childResult.summary
            child.error = childResult.error
            child.completedAt = childResult.completedAt
            child.durationMs = childResult.durationMs
        }
    }

    private func recomputeNativeGraphCompletion(_ graphRunID: UUID, parentSessionID: UUID) {
        guard let run = piAgentSessionStore.subagentRuns(for: parentSessionID).first(where: { $0.id == graphRunID }), let children = run.children else { return }
        guard !children.contains(where: { $0.status.isActive || $0.status == .queued }) else { return }
        let summary = children.sorted { $0.index < $1.index }.map { "- \($0.agentName): \($0.summary ?? $0.error ?? $0.status.rawValue)" }.joined(separator: "\n")
        finishNativeGraphRun(graphRunID, parentSessionID: parentSessionID, status: children.allSatisfy { $0.status == .completed } ? .completed : .failed, summary: summary, completion: nil)
    }

    private func nativeSubagentCardPayload(for run: PiSubagentRunRecord) -> String? {
        let artifactDirectory = run.artifactDirectory
        let payload: [String: Any] = [
            "type": "agent_deck_subagent_card",
            "runID": run.id.uuidString,
            "agent": run.agentName,
            "artifactDirectory": artifactDirectory,
            "turnIndex": run.child?.index ?? 0,
            "authoredSystemPromptPath": URL(fileURLWithPath: artifactDirectory).appendingPathComponent("system-prompt.md").path,
            "finalSystemPromptPath": URL(fileURLWithPath: artifactDirectory).appendingPathComponent("final-system-prompt.md").path
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    private func nativeGraphArtifactDirectory(for runID: UUID) -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let directory = appSupport.appendingPathComponent("\(AppBrand.displayName)", isDirectory: true).appendingPathComponent("Subagent Runs", isDirectory: true).appendingPathComponent(runID.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func pendingSupervisorRequestsJSON(parentSessionID: UUID) -> String {
        let rows = piAgentSessionStore.supervisorRequests(for: parentSessionID)
            .filter { $0.status == .pending }
            .map { request -> [String: String] in
                [
                    "requestID": request.id,
                    "kind": request.kind.rawValue,
                    "title": request.title,
                    "message": request.message,
                    "runID": request.runID.uuidString
                ]
            }
        guard let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    private func answerSupervisorRequestFromParentAgent(parentSessionID: UUID, requestID: String, response: String) -> String {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Supervisor response is empty." }
        guard piAgentSessionStore.supervisorRequests(for: parentSessionID).contains(where: { $0.id == requestID && $0.status == .pending }) else {
            return "No pending supervisor request found for id `\(requestID)`."
        }
        nativeSubagentRunner.respondToSupervisorRequest(requestID, parentSessionID: parentSessionID, response: trimmed)
        return "Supervisor response sent to child request `\(requestID)`."
    }

    private func setSessionPlanFromParentAgent(sessionID: UUID, request: PiSessionPlanSetBridgeRequest) -> String {
        let plan = piAgentSessionStore.setSessionPlan(sessionID: sessionID, items: request.items)
        schedulePiAgentTitleUpdateIfNeeded(sessionID: sessionID, plan: plan)
        let rows = plan.items.map { ["id": $0.id, "title": $0.title, "status": $0.status.rawValue] }
        guard let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "Session plan set with \(plan.items.count) item(s)."
        }
        return "Session plan set (`\(plan.id.uuidString)`). Use these item ids for updates:\n\(text)"
    }

    private func updateSessionPlanFromParentAgent(sessionID: UUID, request: PiSessionPlanUpdateBridgeRequest) -> String {
        guard let plan = piAgentSessionStore.updateSessionPlan(sessionID: sessionID, updates: request.updates) else {
            return "No current session plan exists. Call set_session_plan first."
        }
        let rows = plan.items.map { ["id": $0.id, "title": $0.title, "status": $0.status.rawValue] }
        guard let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "Session plan updated."
        }
        return "Session plan updated (`\(plan.id.uuidString)`):\n\(text)"
    }

    private func nativeSubagentCatalogPrompt(for session: PiAgentSessionRecord) -> String? {
        let agents = startupSnapshot(forProjectPath: session.projectPath).effectiveAgents
            .filter { $0.resolved.disabled != true }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard !agents.isEmpty else { return nil }
        let lines = agents.map { agent in
            let routing = (agent.resolved.whenToUse ?? agent.resolved.description).trimmingCharacters(in: .whitespacesAndNewlines)
            let tools = (agent.resolved.tools ?? []).isEmpty ? "default tools" : "tools: \((agent.resolved.tools ?? []).joined(separator: ", "))"
            return "- \(agent.name): \(routing.isEmpty ? "Use when this specialist fits the requested task." : routing) [\(tools)]"
        }
        let continuableRuns = piAgentSessionStore.subagentRuns(for: session.id)
            .filter { $0.mode == .single && !$0.status.isActive && $0.childPiSessionFile?.isEmpty == false }
            .prefix(6)
            .map { run in
                "- \(run.id.uuidString) \(run.agentName) — \(run.status.rawValue) — latest task: \(String(run.task.prefix(120)))"
            }
        let continuableSection = continuableRuns.isEmpty ? "" : "\nRecent continuable subagents:\n\(continuableRuns.joined(separator: "\n"))"
        return """
        Native \(AppBrand.displayName) tools: `ask_user`, `set_session_plan`, `update_session_plan`, `managed_subagent`, `managed_parallel`, `list_supervisor_requests`, `answer_supervisor_request`.
        - Act as the orchestrator: clarify, plan, delegate, supervise, update the visible plan, and synthesize results.
        - Handle work directly only when it is trivial, low-risk, and faster than delegation.
        - Use `ask_user` for one focused user decision when requirements are ambiguous or preference-dependent.
        - For multi-step work, keep a short parent-owned visible plan with `set_session_plan` and `update_session_plan`.
        - If you delegate planning to `planner`, convert its returned implementation plan into `set_session_plan` before implementation unless the user only asked for a report. Planner text alone does not update the visible \(AppBrand.displayName) plan.
        - Update the visible plan when steps start, complete, block, skip, or materially change.
        - Delegate bounded work with `managed_subagent`; include expected output and `reads` when known. Use worktrees for writer tasks.
        - Native subagent runs start fresh by default. Do not assume a later `managed_subagent` call remembers an earlier child run.
        - The tool result and native subagent card show a stable Subagent ID. For a direct follow-up to a previous child, pass that ID as `continueSubagentID` so Agent Deck resumes the same child session and updates the same card.
        - If starting fresh for follow-up work, pass a compact continuity packet: prior findings/status, what changed, relevant files/artifact paths, and exact expected output.
        - Prefer fresh runs for independent work; prefer continuation for direct refinement, re-review, debugging, or answering a child-specific follow-up.
        Available native subagents:
        \(lines.joined(separator: "\n"))\(continuableSection)
        """
    }

    func stopNativeSubagent(runID: UUID, parentSessionID: UUID) {
        if let run = piAgentSessionStore.subagentRuns(for: parentSessionID).first(where: { $0.id == runID }), run.children?.isEmpty == false {
            stopNativeSubagentGraph(runID: runID, parentSessionID: parentSessionID)
            return
        }
        nativeSubagentRunner.stop(runID: runID, parentSessionID: parentSessionID)
    }

    func stopNativeSubagentGraph(runID: UUID, parentSessionID: UUID) {
        guard let run = piAgentSessionStore.subagentRuns(for: parentSessionID).first(where: { $0.id == runID }) else { return }
        for child in run.children ?? [] where child.status.isActive {
            if let executionRunID = child.executionRunID {
                nativeSubagentRunner.stop(runID: executionRunID, parentSessionID: parentSessionID)
            }
        }
        let completedAt = Date()
        piAgentSessionStore.updateSubagentRun(runID, parentSessionID: parentSessionID) { run in
            run.status = .stopped
            run.completedAt = completedAt
            run.durationMs = max(0, Int((completedAt.timeIntervalSince(run.createdAt) * 1000).rounded()))
            if var children = run.children {
                for index in children.indices where children[index].status.isActive || children[index].status == .queued {
                    children[index].status = .stopped
                    children[index].updatedAt = completedAt
                    children[index].completedAt = completedAt
                    children[index].durationMs = max(0, Int((completedAt.timeIntervalSince(children[index].createdAt) * 1000).rounded()))
                }
                run.children = children
            }
        }
        piAgentSessionStore.append(.init(sessionID: parentSessionID, role: .status, title: "Native Graph Stopped", text: "Stopped graph run \(runID.uuidString)."))
    }

    func stopNativeSubagentGraphChild(graphRunID: UUID, childID: UUID, parentSessionID: UUID) {
        guard let run = piAgentSessionStore.subagentRuns(for: parentSessionID).first(where: { $0.id == graphRunID }),
              let child = (run.children ?? []).first(where: { $0.id == childID }) else { return }
        if let executionRunID = child.executionRunID, child.status.isActive {
            nativeSubagentRunner.stop(runID: executionRunID, parentSessionID: parentSessionID)
        }
        let completedAt = Date()
        piAgentSessionStore.updateSubagentRun(graphRunID, parentSessionID: parentSessionID) { run in
            guard var children = run.children, let index = children.firstIndex(where: { $0.id == childID }) else { return }
            children[index].status = .stopped
            children[index].updatedAt = completedAt
            children[index].completedAt = completedAt
            children[index].durationMs = max(0, Int((completedAt.timeIntervalSince(children[index].createdAt) * 1000).rounded()))
            run.children = children
        }
        piAgentSessionStore.append(.init(sessionID: parentSessionID, role: .status, title: "Native Graph Child Stopped", text: "Stopped \(child.agentName)."))
    }

    func retryNativeSubagentGraphChild(graphRunID: UUID, childID: UUID, parentSessionID: UUID) {
        guard let parentSession = piAgentSessionStore.sessions.first(where: { $0.id == parentSessionID }),
              let run = piAgentSessionStore.subagentRuns(for: parentSessionID).first(where: { $0.id == graphRunID }),
              let children = run.children,
              let childIndex = children.firstIndex(where: { $0.id == childID }) else { return }
        piAgentSessionStore.updateSubagentRun(graphRunID, parentSessionID: parentSessionID) { run in
            run.status = .running
            run.error = nil
            guard var children = run.children else { return }
            children[childIndex].status = .running
            children[childIndex].summary = nil
            children[childIndex].error = nil
            children[childIndex].completedAt = nil
            children[childIndex].durationMs = nil
            children[childIndex].executionRunID = nil
            run.children = children
        }
        let child = children[childIndex]
        let isolated = run.worktreePolicy == "isolated-per-child"
        let childRun = runNativeSubagent(parentSession: parentSession, agentName: child.agentName, task: child.task ?? run.task, useWorktreeIsolation: isolated, expectedOutcome: isolated ? .editFilesInWorktree : (child.expectedOutcome ?? .reportOnly), requestedOutputPath: child.requestedOutputPath, allowOverwrite: child.allowOverwrite == true) { [weak self] childResult in
            guard let self else { return }
            self.updateNativeGraphChildFromRun(graphRunID, parentSessionID: parentSessionID, index: childIndex, childResult: childResult)
            self.recomputeNativeGraphCompletion(graphRunID, parentSessionID: parentSessionID)
        }
        updateNativeGraphChildFromRun(graphRunID, parentSessionID: parentSessionID, index: childIndex, childResult: childRun)
    }

    func openNativeSubagentWorktreePatch(runID: UUID, parentSessionID: UUID) {
        guard let run = piAgentSessionStore.subagentRuns(for: parentSessionID).first(where: { $0.id == runID }) else { return }
        Task {
            do {
                let patch = try await subagentWorktreeService.preparePatch(for: run)
                await MainActor.run {
                    piAgentSessionStore.updateSubagentRun(runID, parentSessionID: parentSessionID) { run in
                        run.worktreeStatus = .patchReady
                        run.worktreePatchPath = patch.patchPath
                    }
                    piAgentSessionStore.append(.init(sessionID: parentSessionID, role: .status, title: "Subagent Worktree Patch Ready", text: "\(patch.changedFiles.count) changed file(s).\n\n\(patch.patchPath)"))
                    NSWorkspace.shared.open(URL(fileURLWithPath: patch.patchPath))
                }
            } catch {
                await MainActor.run { recordSubagentWorktreeError(error, runID: runID, parentSessionID: parentSessionID) }
            }
        }
    }

    func applyNativeSubagentWorktreePatch(runID: UUID, parentSessionID: UUID) {
        guard let run = piAgentSessionStore.subagentRuns(for: parentSessionID).first(where: { $0.id == runID }) else { return }
        Task {
            do {
                let patch = try await subagentWorktreeService.applyPatch(for: run)
                await MainActor.run {
                    piAgentSessionStore.updateSubagentRun(runID, parentSessionID: parentSessionID) { run in
                        run.worktreeStatus = .applied
                        run.worktreePatchPath = patch.patchPath
                    }
                    piAgentSessionStore.append(.init(sessionID: parentSessionID, role: .status, title: "Subagent Worktree Applied", text: "Applied \(patch.changedFiles.count) changed file(s) from the isolated worktree.\n\nPatch: \(patch.patchPath)"))
                }
            } catch {
                await MainActor.run { recordSubagentWorktreeError(error, runID: runID, parentSessionID: parentSessionID) }
            }
        }
    }

    func discardNativeSubagentWorktree(runID: UUID, parentSessionID: UUID) {
        if let run = piAgentSessionStore.subagentRuns(for: parentSessionID).first(where: { $0.id == runID }), run.status.isActive {
            nativeSubagentRunner.stop(runID: runID, parentSessionID: parentSessionID)
        }
        guard let run = piAgentSessionStore.subagentRuns(for: parentSessionID).first(where: { $0.id == runID }) else { return }
        Task {
            do {
                try await subagentWorktreeService.discardWorktree(for: run)
                await MainActor.run {
                    piAgentSessionStore.updateSubagentRun(runID, parentSessionID: parentSessionID) { run in
                        run.worktreeStatus = .discarded
                    }
                    piAgentSessionStore.append(.init(sessionID: parentSessionID, role: .status, title: "Subagent Worktree Discarded", text: "Removed isolated worktree for run \(runID.uuidString). Artifacts were kept."))
                }
            } catch {
                await MainActor.run { recordSubagentWorktreeError(error, runID: runID, parentSessionID: parentSessionID) }
            }
        }
    }

    private func recordSubagentWorktreeError(_ error: Error, runID: UUID, parentSessionID: UUID) {
        let message = error.localizedDescription
        piAgentSessionStore.updateSubagentRun(runID, parentSessionID: parentSessionID) { run in
            run.worktreeStatus = .failed
            run.error = [run.error, message].compactMap { $0 }.joined(separator: "\n")
        }
        piAgentSessionStore.append(.init(sessionID: parentSessionID, role: .error, title: "Subagent Worktree Failed", text: message))
    }

    func respondToSubagentSupervisorRequest(_ requestID: String, parentSessionID: UUID, response: String) {
        nativeSubagentRunner.respondToSupervisorRequest(requestID, parentSessionID: parentSessionID, response: response)
    }

    func cancelSubagentSupervisorRequest(_ requestID: String, parentSessionID: UUID) {
        nativeSubagentRunner.cancelSupervisorRequest(requestID, parentSessionID: parentSessionID)
    }

    var shouldShowPiAgentGitActions: Bool {
        piAgentCommitMessageModel() != nil
    }

    var shouldShowCommitSelectedPiAgentSession: Bool {
        guard shouldShowPiAgentGitActions,
              let session = piAgentSessionStore.selectedSession,
              let changes = repositoryChangesCache[session.projectPath]?.snapshot else { return false }
        return changes.conflicted.isEmpty
            && (!changes.staged.isEmpty || !changes.unstaged.isEmpty || !changes.untracked.isEmpty)
    }

    var shouldShowPushSelectedPiAgentSession: Bool {
        guard shouldShowPiAgentGitActions,
              let session = piAgentSessionStore.selectedSession,
              let changes = repositoryChangesCache[session.projectPath]?.snapshot else { return false }
        return changes.aheadCount > 0
    }

    var canCommitSelectedPiAgentSession: Bool {
        guard shouldShowCommitSelectedPiAgentSession,
              let session = piAgentSessionStore.selectedSession else { return false }
        return piAgentGitAutomationAction == nil && !session.status.isActive
    }

    var canPushSelectedPiAgentSession: Bool {
        guard shouldShowPushSelectedPiAgentSession,
              let session = piAgentSessionStore.selectedSession else { return false }
        return piAgentGitAutomationAction == nil && !session.status.isActive
    }

    var canCommitAndPushSelectedPiAgentSession: Bool { canCommitSelectedPiAgentSession }

    func commitSelectedPiAgentSession() {
        shipSelectedPiAgentSession(pushAfterCommit: false)
    }

    func commitAndPushSelectedPiAgentSession() {
        shipSelectedPiAgentSession(pushAfterCommit: true)
    }

    func pushSelectedPiAgentSession() {
        guard let session = piAgentSessionStore.selectedSession else { return }
        let sessionID = session.id
        let projectURL = URL(fileURLWithPath: session.projectPath, isDirectory: true)
        piAgentGitAutomationAction = .push
        piAgentSessionStore.append(.init(sessionID: sessionID, role: .status, title: "Push Started", text: "Pushing committed changes on the current branch."))
        Task { [weak self] in
            guard let self else { return }
            do {
                try await gitRepositoryService.pushCurrentBranch(in: projectURL)
                await MainActor.run {
                    self.piAgentGitAutomationAction = nil
                    self.piAgentSessionStore.append(.init(sessionID: sessionID, role: .status, title: "Push Completed", text: "Pushed committed changes."))
                    self.prepareRepoChangesForSelectedPiAgentSession(force: true)
                }
            } catch {
                await MainActor.run {
                    self.piAgentGitAutomationAction = nil
                    self.piAgentSessionStore.append(.init(sessionID: sessionID, role: .error, title: "Push Failed", text: error.localizedDescription))
                    self.prepareRepoChangesForSelectedPiAgentSession(force: true)
                }
            }
        }
    }

    private func shipSelectedPiAgentSession(pushAfterCommit: Bool) {
        guard let session = piAgentSessionStore.selectedSession else { return }
        guard let model = piAgentCommitMessageModel() else {
            piAgentSessionStore.append(.init(sessionID: session.id, role: .error, title: "Ship Failed", text: PiAgentShipService.ShipError.noModel.localizedDescription))
            return
        }

        let sessionID = session.id
        let projectURL = URL(fileURLWithPath: session.projectPath, isDirectory: true)
        let environment = EnvRuntimeEnvironment().environment(projectRoot: projectURL)
        piAgentGitAutomationAction = pushAfterCommit ? .commitAndPush : .commit
        piAgentSessionStore.append(.init(sessionID: sessionID, role: .status, title: pushAfterCommit ? "Commit & Push Started" : "Commit Started", text: pushAfterCommit ? "Staging all changes, generating a commit message, committing, and pushing the current branch." : "Staging all changes, generating a commit message, and committing on the current branch."))

        Task { [weak self] in
            guard let self else { return }
            do {
                let before = try await gitRepositoryService.loadChanges(in: projectURL)
                if !before.conflicted.isEmpty { throw PiAgentShipService.ShipError.conflicts }
                if before.staged.isEmpty && before.unstaged.isEmpty && before.untracked.isEmpty { throw PiAgentShipService.ShipError.noChanges }

                try await gitRepositoryService.stageAll(in: projectURL)
                let status = try await gitRepositoryService.statusText(in: projectURL)
                let diff = try await gitRepositoryService.stagedDiffForCommitMessage(in: projectURL)
                let message = try await withCheckedThrowingContinuation { continuation in
                    shipService.generateCommitMessage(status: status, diff: diff, model: model, projectURL: projectURL, environment: environment) { result in
                        continuation.resume(with: result)
                    }
                }
                try await gitRepositoryService.commit(message: message.title, description: message.body, in: projectURL)
                if pushAfterCommit {
                    try await gitRepositoryService.pushCurrentBranch(in: projectURL)
                }

                await MainActor.run {
                    self.piAgentGitAutomationAction = nil
                    self.piAgentSessionStore.append(.init(sessionID: sessionID, role: .status, title: pushAfterCommit ? "Commit & Push Completed" : "Commit Completed", text: pushAfterCommit ? "Committed and pushed `\(message.title)`." : "Committed `\(message.title)`."))
                    self.prepareRepoChangesForSelectedPiAgentSession(force: true)
                }
            } catch {
                await MainActor.run {
                    self.piAgentGitAutomationAction = nil
                    self.piAgentSessionStore.append(.init(sessionID: sessionID, role: .error, title: pushAfterCommit ? "Commit & Push Failed" : "Commit Failed", text: error.localizedDescription))
                    self.prepareRepoChangesForSelectedPiAgentSession(force: true)
                }
            }
        }
    }

    func sendPiAgentMessage(_ text: String, mode: PiAgentInputMode, transcriptText: String? = nil, images: [PiAgentImageAttachment] = [], pasteAttachments: [PiAgentPasteAttachment] = []) {
        guard let session = piAgentSessionStore.selectedSession else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if images.isEmpty, trimmed == "/compact" || trimmed.hasPrefix("/compact ") {
            let instructions = trimmed.hasPrefix("/compact ") ? String(trimmed.dropFirst("/compact ".count)) : nil
            piAgentRunner.compact(session: session, customInstructions: instructions)
            return
        }
        schedulePiAgentTitleGenerationIfNeeded(for: session, firstMessage: trimmed)
        if !piAgentRunner.isRunning(sessionID: session.id), mode == .prompt {
            piAgentRunner.resume(session: session, initialPrompt: text, transcriptText: transcriptText, images: images, pasteAttachments: pasteAttachments)
            isPiAgentInspectorPresented = selectedSidebarItem != .agent
            return
        }
        piAgentRunner.send(text, mode: mode, to: session.id, transcriptText: transcriptText, images: images, pasteAttachments: pasteAttachments)
    }

    private func schedulePiAgentTitleUpdateIfNeeded(sessionID: UUID, plan: PiSessionPlanRecord) {
        guard appSettings.autoGeneratePiAgentSessionTitles,
              appSettings.autoUpdatePiAgentSessionTitles,
              !plan.items.isEmpty,
              !piAgentTitleGeneratingSessionIDs.contains(sessionID),
              let session = piAgentSessionStore.sessions.first(where: { $0.id == sessionID }),
              !session.title.hasPrefix("Draft ·"),
              !session.isTitleUserEdited,
              let latestUserMessage = piAgentSessionStore.transcript(for: sessionID)
                .filter({ $0.role == .user })
                .max(by: { $0.timestamp < $1.timestamp })?
                .text
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !latestUserMessage.isEmpty,
              let model = piAgentTitleGenerationModel() else { return }

        piAgentTitleGeneratingSessionIDs.insert(sessionID)
        let projectURL = URL(fileURLWithPath: session.worktreePath ?? session.projectPath)
        let environment = EnvRuntimeEnvironment().environment(projectRoot: projectURL)
        piSessionTitleGenerator.updateTitle(
            currentTitle: session.title,
            latestUserMessage: latestUserMessage,
            planItems: plan.items,
            model: model,
            projectURL: projectURL,
            environment: environment
        ) { [weak self] result in
            guard let self else { return }
            self.piAgentTitleGeneratingSessionIDs.remove(sessionID)
            guard case let .success(title) = result,
                  title.caseInsensitiveCompare("KEEP") != .orderedSame else { return }
            guard let current = self.piAgentSessionStore.sessions.first(where: { $0.id == sessionID }),
                  !current.title.hasPrefix("Draft ·"),
                  !current.isTitleUserEdited,
                  current.title.caseInsensitiveCompare(title) != .orderedSame else { return }
            withAnimation(.snappy(duration: 0.26)) {
                self.piAgentSessionStore.applyGeneratedTitle(sessionID, title: title)
            }
            self.piAgentRunner.syncSessionName(for: sessionID, force: true)
        }
    }

    private func schedulePiAgentTitleGenerationIfNeeded(for session: PiAgentSessionRecord, firstMessage: String) {
        let trimmedMessage = firstMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard appSettings.autoGeneratePiAgentSessionTitles,
              !trimmedMessage.isEmpty,
              session.title.hasPrefix("Draft ·"),
              !session.isTitleUserEdited,
              !piAgentTitleGeneratingSessionIDs.contains(session.id),
              piAgentSessionStore.transcript(for: session.id).filter({ $0.role == .user }).isEmpty,
              let model = piAgentTitleGenerationModel() else { return }

        piAgentTitleGeneratingSessionIDs.insert(session.id)
        let projectURL = URL(fileURLWithPath: session.worktreePath ?? session.projectPath)
        let environment = EnvRuntimeEnvironment().environment(projectRoot: projectURL)
        piSessionTitleGenerator.generateTitle(
            for: trimmedMessage,
            model: model,
            projectURL: projectURL,
            environment: environment
        ) { [weak self] result in
            guard let self else { return }
            self.piAgentTitleGeneratingSessionIDs.remove(session.id)
            guard case let .success(title) = result else { return }
            guard let current = self.piAgentSessionStore.sessions.first(where: { $0.id == session.id }),
                  current.title.hasPrefix("Draft ·"),
                  !current.isTitleUserEdited else { return }
            withAnimation(.snappy(duration: 0.26)) {
                self.piAgentSessionStore.applyGeneratedTitle(session.id, title: title)
            }
            self.piAgentRunner.syncSessionName(for: session.id, force: true)
        }
    }

    func compactSelectedPiAgentSession(customInstructions: String? = nil) {
        guard let session = piAgentSessionStore.selectedSession else { return }
        piAgentRunner.compact(session: session, customInstructions: customInstructions)
    }

    func refreshPiAgentControlsForSelectedSession() {
        refreshAvailableModels()
        guard let sessionID = piAgentSessionStore.selectedSession?.id else { return }
        piAgentRunner.refreshPiControls(sessionID: sessionID)
    }

    func setPiAgentModelForSelectedSession(provider: String?, modelID: String?) {
        guard let session = piAgentSessionStore.selectedSession else { return }
        piAgentRunner.setModel(sessionID: session.id, provider: provider, modelID: modelID)
        if let currentLevel = session.thinkingLevel {
            let fallback = defaultPiAgentModel()
            let levels = supportedPiAgentThinkingLevels(session: session, provider: provider ?? session.modelProvider ?? fallback?.provider, modelID: modelID ?? session.model ?? fallback?.model)
            if !levels.contains(currentLevel == "none" ? "off" : currentLevel) {
                piAgentRunner.setThinkingLevel(sessionID: session.id, level: levels.first ?? "off")
            }
        }
    }

    func cyclePiAgentModelForSelectedSession() {
        guard let session = piAgentSessionStore.selectedSession else { return }
        let options = piAgentModelOptions()
        guard !options.isEmpty else { return }
        let fallback = defaultPiAgentModel()
        let currentProvider = session.modelOverrideProvider ?? session.modelProvider ?? fallback?.provider
        let currentModel = session.modelOverrideID ?? session.model ?? fallback?.model
        let currentIndex = options.firstIndex { $0.provider == currentProvider && $0.id == currentModel } ?? -1
        let next = options[(currentIndex + 1 + options.count) % options.count]
        setPiAgentModelForSelectedSession(provider: next.provider, modelID: next.id)
    }

    func setPiAgentThinkingLevelForSelectedSession(_ level: String) {
        guard let session = piAgentSessionStore.selectedSession else { return }
        let normalized = level == "none" ? "off" : level
        let fallback = defaultPiAgentModel()
        let levels = supportedPiAgentThinkingLevels(session: session, provider: session.modelOverrideProvider ?? session.modelProvider ?? fallback?.provider, modelID: session.modelOverrideID ?? session.model ?? fallback?.model)
        guard levels.contains(normalized) else {
            piAgentSessionStore.updateSession(session.id) { record in
                record.lastError = "Thinking level '\(level)' is not available for the selected model."
            }
            return
        }
        piAgentRunner.setThinkingLevel(sessionID: session.id, level: normalized)
    }

    func defaultPiAgentModel() -> AvailableModel? {
        _ = piRuntimeSettingsRevision
        let defaults = readPiRuntimeDefaults()
        let provider = defaults.provider
        let model = defaults.model
        let candidateModels = enabledAvailableModels
        if let provider, let model {
            return candidateModels.first { $0.provider == provider && $0.model == model }
                ?? candidateModels.first { $0.model == model }
                ?? candidateModels.first
        }
        if let model {
            return candidateModels.first { $0.identifier == model || $0.model == model } ?? candidateModels.first
        }
        return candidateModels.first
    }

    func defaultPiAgentThinkingLevel(for levels: [String]) -> String {
        _ = piRuntimeSettingsRevision
        let normalized = readPiRuntimeDefaults().thinkingLevel ?? "medium"
        if levels.contains(normalized) { return normalized }
        if levels.contains("medium") { return "medium" }
        return levels.first ?? "off"
    }

    func piRuntimeDefaultThinkingLevel() -> String {
        _ = piRuntimeSettingsRevision
        return readPiRuntimeDefaults().thinkingLevel ?? "medium"
    }

    private func readPiRuntimeDefaults() -> (provider: String?, model: String?, thinkingLevel: String?) {
        guard let object = piRuntimeSettingsObject() else { return (nil, nil, nil) }
        let provider = nonEmptyPiSetting(object["defaultProvider"])
        var model = nonEmptyPiSetting(object["defaultModel"])
        var parsedProvider = provider
        if let rawModel = model, rawModel.contains("/") {
            let parts = rawModel.split(separator: "/", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                parsedProvider = parsedProvider ?? parts[0]
                model = parts[1]
            }
        }
        let rawThinking = nonEmptyPiSetting(object["defaultThinkingLevel"])
        let thinking = (rawThinking ?? "medium") == "none"
            ? "off"
            : rawThinking
        return (parsedProvider, model, thinking)
    }

    private func writePiRuntimeDefaults(provider: String?, model: String?, thinkingLevel: String?) -> Bool {
        var object = piRuntimeSettingsObject() ?? [:]
        if let provider, let model {
            object["defaultProvider"] = provider
            object["defaultModel"] = model
        }
        if let thinkingLevel {
            let normalized = thinkingLevel == "none" ? "off" : thinkingLevel.trimmingCharacters(in: .whitespacesAndNewlines)
            object["defaultThinkingLevel"] = normalized.isEmpty ? "medium" : normalized
        }
        do {
            let url = piRuntimeSettingsURL
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: url, options: .atomic)
            cachedPiRuntimeSettingsObject = object
            cachedPiRuntimeSettingsModificationDate = piRuntimeSettingsModificationDate(force: true)
            lastPiRuntimeSettingsStatCheck = Date()
            return true
        } catch {
            githubLastError = "Could not update Pi settings: \(error.localizedDescription)"
            return false
        }
    }

    private func piRuntimeSettingsObject() -> [String: Any]? {
        let modificationDate = piRuntimeSettingsModificationDate()
        guard let modificationDate else {
            cachedPiRuntimeSettingsObject = nil
            cachedPiRuntimeSettingsModificationDate = nil
            return nil
        }
        if cachedPiRuntimeSettingsModificationDate == modificationDate {
            return cachedPiRuntimeSettingsObject
        }
        guard let data = try? Data(contentsOf: piRuntimeSettingsURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            cachedPiRuntimeSettingsObject = nil
            cachedPiRuntimeSettingsModificationDate = modificationDate
            return nil
        }
        cachedPiRuntimeSettingsObject = object
        cachedPiRuntimeSettingsModificationDate = modificationDate
        return object
    }

    private func piRuntimeSettingsModificationDate(force: Bool = false) -> Date? {
        let now = Date()
        if !force,
           let lastPiRuntimeSettingsStatCheck,
           now.timeIntervalSince(lastPiRuntimeSettingsStatCheck) < 1,
           let cachedPiRuntimeSettingsModificationDate {
            return cachedPiRuntimeSettingsModificationDate
        }
        lastPiRuntimeSettingsStatCheck = now
        return (try? FileManager.default.attributesOfItem(atPath: piRuntimeSettingsURL.path)[.modificationDate]) as? Date
    }

    private var piRuntimeSettingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/settings.json")
    }

    private func nonEmptyPiSetting(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func piAgentModelOptions() -> [PiAgentModelOption] {
        return enabledAvailableModels
            .filter { !appSettings.disabledModelIdentifiers.contains($0.identifier) }
            .map { model in
                PiAgentModelOption(
                    provider: model.provider,
                    id: model.model,
                    name: nil,
                    contextWindow: Int(model.contextWindow),
                    maxOutput: Int(model.maxOutput),
                    supportsThinking: model.supportsThinking,
                    supportedThinkingLevels: model.supportedThinkingLevels,
                    supportsImages: model.supportsImages
                )
            }
    }

    private func supportedPiAgentThinkingLevels(session: PiAgentSessionRecord, provider: String?, modelID: String?) -> [String] {
        if let provider, let modelID {
            if let cached = enabledAvailableModels.first(where: { $0.provider == provider && $0.model == modelID }) {
                if !cached.supportedThinkingLevels.isEmpty { return cached.supportedThinkingLevels }
                return cached.supportsThinking ? [] : ["off"]
            }
        }
        return []
    }

    func cyclePiAgentThinkingLevelForSelectedSession() {
        guard let session = piAgentSessionStore.selectedSession else { return }
        let fallback = defaultPiAgentModel()
        let levels = supportedPiAgentThinkingLevels(session: session, provider: session.modelOverrideProvider ?? session.modelProvider ?? fallback?.provider, modelID: session.modelOverrideID ?? session.model ?? fallback?.model)
        guard !levels.isEmpty else { return }
        let current = (session.thinkingLevel ?? defaultPiAgentThinkingLevel(for: levels)) == "none" ? "off" : (session.thinkingLevel ?? defaultPiAgentThinkingLevel(for: levels))
        let currentIndex = levels.firstIndex(of: current) ?? -1
        let next = levels[(currentIndex + 1 + levels.count) % levels.count]
        piAgentRunner.setThinkingLevel(sessionID: session.id, level: next)
    }

    func stopSelectedPiAgentSession() {
        guard let sessionID = piAgentSessionStore.selectedSession?.id else { return }
        piAgentRunner.stop(sessionID: sessionID)
        refreshRepositoryChangesForPiAgentSession()
    }

    func respondToPiAgentUIRequest(_ request: PiAgentUIRequest, value: String) {
        piAgentRunner.respondToExtensionUI(sessionID: request.sessionID, requestID: request.id, value: value)
    }

    func respondToPiAgentFreeformUIRequest(_ request: PiAgentUIRequest, sentinel: String, value: String) {
        piAgentRunner.respondToFreeformExtensionUI(sessionID: request.sessionID, requestID: request.id, sentinel: sentinel, value: value)
    }

    func confirmPiAgentUIRequest(_ request: PiAgentUIRequest, confirmed: Bool) {
        piAgentRunner.confirmExtensionUI(sessionID: request.sessionID, requestID: request.id, confirmed: confirmed)
    }

    func cancelPiAgentUIRequest(_ request: PiAgentUIRequest) {
        piAgentRunner.cancelExtensionUI(sessionID: request.sessionID, requestID: request.id)
    }

    func deletePiAgentSession(_ sessionID: UUID) {
        deletePiAgentSessions([sessionID])
    }

    func deletePiAgentSessions(_ sessionIDs: Set<UUID>) {
        for sessionID in sessionIDs where piAgentRunner.isRunning(sessionID: sessionID) {
            piAgentRunner.stop(sessionID: sessionID, recordTranscript: false)
        }
        piAgentSessionStore.deleteSessions(sessionIDs)
    }

    func prepareRepoChangesForSelectedPiAgentSession(force: Bool = false) {
        guard let session = piAgentSessionStore.selectedSession else { return }
        refreshRepositoryChanges(
            forProjectPath: session.projectPath,
            preservingDiffSelection: true,
            force: force,
            activeContextIsCurrent: { [weak self] in
                guard let self else { return false }
                return self.piAgentSessionStore.selectedSession?.projectPath == session.projectPath || self.selectedDiscoveredProject?.path == session.projectPath
            }
        )
    }

    func refreshRepositoryChanges(forProjectPath projectPath: String, preservingDiffSelection: Bool = false, force: Bool = true) {
        refreshRepositoryChanges(
            forProjectPath: projectPath,
            preservingDiffSelection: preservingDiffSelection,
            force: force,
            activeContextIsCurrent: { [weak self] in
                guard let self else { return false }
                return self.piAgentSessionStore.selectedSession?.projectPath == projectPath || self.selectedDiscoveredProject?.path == projectPath
            }
        )
    }

    private func refreshRepositoryChanges(
        forProjectPath projectPath: String,
        preservingDiffSelection: Bool,
        force: Bool,
        activeContextIsCurrent: @escaping @MainActor () -> Bool
    ) {
        if !force, let entry = repositoryChangesCache[projectPath] {
            syncActiveRepositoryChanges(projectPath: projectPath, preservingDiffSelection: preservingDiffSelection)
            if entry.isLoading || !isRepositoryChangesCacheStale(entry) { return }
        }

        let projectURL = URL(fileURLWithPath: projectPath, isDirectory: true)
        githubRepositoryChangesRequestID += 1
        let requestID = githubRepositoryChangesRequestID
        var entry = repositoryChangesCache[projectPath] ?? RepositoryChangesCacheEntry()
        entry.isLoading = true
        entry.error = nil
        entry.requestID = requestID
        repositoryChangesCache[projectPath] = entry

        if activeContextIsCurrent() {
            syncActiveRepositoryChanges(projectPath: projectPath, preservingDiffSelection: preservingDiffSelection)
        }

        Task {
            do {
                let snapshot = try await self.gitRepositoryService.loadChanges(in: projectURL)
                await MainActor.run {
                    guard self.repositoryChangesCache[projectPath]?.requestID == requestID else { return }
                    self.repositoryChangesCache[projectPath] = RepositoryChangesCacheEntry(
                        snapshot: snapshot,
                        fetchedAt: Date(),
                        isLoading: false,
                        error: nil,
                        requestID: requestID
                    )
                    guard activeContextIsCurrent() else { return }
                    self.syncActiveRepositoryChanges(projectPath: projectPath, preservingDiffSelection: preservingDiffSelection)
                }
            } catch {
                await MainActor.run {
                    guard var entry = self.repositoryChangesCache[projectPath], entry.requestID == requestID else { return }
                    entry.isLoading = false
                    entry.error = error.localizedDescription
                    self.repositoryChangesCache[projectPath] = entry
                    guard activeContextIsCurrent() else { return }
                    self.syncActiveRepositoryChanges(projectPath: projectPath, preservingDiffSelection: preservingDiffSelection)
                }
            }
        }
    }

    private func syncActiveRepositoryChanges(projectPath: String, preservingDiffSelection: Bool) {
        let entry = repositoryChangesCache[projectPath]
        githubRepositoryChanges = entry?.snapshot
        githubRepositoryChangesProjectPath = entry?.snapshot == nil ? nil : projectPath
        githubIsLoadingRepositoryChanges = entry?.isLoading == true
        githubLastError = entry?.error

        if !preservingDiffSelection {
            githubSelectedChangePaths = []
            githubSelectedDiffFilePath = nil
            githubSelectedDiffKind = nil
            githubSelectedDiffText = nil
        }

        guard let snapshot = entry?.snapshot else { return }
        let validPaths = Set(snapshot.staged.map(\.path) + snapshot.unstaged.map(\.path) + snapshot.untracked.map(\.path) + snapshot.conflicted.map(\.path))
        if preservingDiffSelection {
            githubSelectedChangePaths = githubSelectedChangePaths.intersection(validPaths)
        }
    }

    private func isRepositoryChangesCacheStale(_ entry: RepositoryChangesCacheEntry) -> Bool {
        guard let fetchedAt = entry.fetchedAt else { return true }
        return Date().timeIntervalSince(fetchedAt) > repositoryChangesCacheLifetime
    }

    func openRepoChangesForSelectedPiAgentSession() {
        prepareRepoChangesForSelectedPiAgentSession()
        selectedSidebarItem = .agent
    }

    func isPiAgentSessionRunning(_ sessionID: UUID) -> Bool {
        piAgentRunner.isRunning(sessionID: sessionID)
    }

    private func refreshRepositoryChangesForPiAgentSession() {
        guard let session = piAgentSessionStore.selectedSession,
              selectedProjectPath == session.projectPath else { return }
        refreshRepositoryChanges(preservingDiffSelection: true)
    }

    func submitComment() {
        guard let item = githubSelectedWorkItem, let session = gitHubSession else {
            githubLastError = "Select an issue or pull request first."
            return
        }

        let body = githubCommentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            githubLastError = "Enter a comment first."
            return
        }

        githubIsSubmittingComment = true
        githubLastError = nil

        Task {
            do {
                let service = GitHubIssueService(apiClient: GitHubAPIClient(session: session))
                try await service.postComment(body: body, for: item)
                await MainActor.run {
                    guard self.githubSelectedWorkItem == item,
                          self.gitHubSession == session else {
                        self.githubIsSubmittingComment = false
                        return
                    }

                    self.githubCommentDraft = ""
                    self.githubIsSubmittingComment = false
                    self.githubProjectBoardFetchedAt = nil
                    self.loadIssueDetail(for: item)
                }
            } catch {
                await MainActor.run {
                    guard self.githubSelectedWorkItem == item else {
                        self.githubIsSubmittingComment = false
                        return
                    }

                    self.githubIsSubmittingComment = false
                    self.githubLastError = error.localizedDescription
                }
            }
        }
    }

    func closeSelectedIssue() {
        guard let item = githubSelectedWorkItem, let session = gitHubSession else {
            githubLastError = "Select an issue first."
            return
        }
        githubIsClosingIssue = true
        githubLastError = nil

        Task {
            do {
                let service = GitHubIssueService(apiClient: GitHubAPIClient(session: session))
                try await service.closeIssue(item)
                await MainActor.run {
                    self.githubIsClosingIssue = false
                    self.githubProjectBoardFetchedAt = nil
                    self.refreshProjectBoard(force: true)
                    self.loadIssueDetail(for: item)
                }
            } catch {
                await MainActor.run {
                    self.githubIsClosingIssue = false
                    self.githubLastError = error.localizedDescription
                }
            }
        }
    }

    private func refreshGitHubConnectionScopedState() {
        githubProjectBoardRequestID += 1
        githubIssueDetailRequestID += 1
        githubAggregateBoard = nil
        githubProjectBoard = nil
        githubProjectBoardCacheKey = nil
        githubProjectBoardFetchedAt = nil
        githubSelectedWorkItem = nil
        githubIssueDetail = nil
        githubCommentDraft = ""
        githubIsLoadingAggregateBoard = false
        githubIsLoadingProjectBoard = false
        githubIsLoadingIssueDetail = false
        githubIsSubmittingComment = false
        githubIsClosingIssue = false
    }

    private func refreshGitHubProjectScopedState() {
        githubProjectBoardRequestID += 1
        githubRepositoryChangesRequestID += 1
        githubIssueDetailRequestID += 1
        githubProjectBoard = nil
        githubProjectBoardCacheKey = nil
        githubProjectBoardFetchedAt = nil
        githubRepositoryChanges = nil
        githubRepositoryChangesProjectPath = nil
        repositoryChangesCache.removeAll()
        githubSelectedChangePaths = []
        githubSelectedDiffFilePath = nil
        githubSelectedDiffKind = nil
        githubSelectedDiffText = nil
        githubCommitMessage = ""
        githubCommitDescription = ""
        githubSelectedWorkItem = nil
        githubIssueDetail = nil
        githubCommentDraft = ""
        githubIsLoadingProjectBoard = false
        githubIsLoadingRepositoryChanges = false
        githubIsLoadingIssueDetail = false
        githubIsSubmittingComment = false
        githubIsClosingIssue = false
    }

    private func boardCacheKey(for remote: GitHubRemote, state: GitHubIssueStateFilter) -> String {
        "\(remote.host.lowercased())|\(remote.nameWithOwner.lowercased())|\(state.rawValue.lowercased())"
    }

    private func isGitHubBoardCacheStale(fetchedAt: Date?) -> Bool {
        guard let fetchedAt else { return true }
        return Date().timeIntervalSince(fetchedAt) >= gitHubBoardCacheLifetime
    }

    private var gitHubBoardCacheLifetime: TimeInterval {
        appSettingsController.gitHubBoardCacheLifetime
    }

    var gitHubBoardCacheLifetimeMinutes: Int {
        appSettingsController.gitHubBoardCacheLifetimeMinutes
    }

    var piAgentNotificationDelayMinutes: Int {
        appSettingsController.piAgentNotificationDelayMinutes
    }

    var piAgentIdleParkingTimeoutMinutes: Int {
        appSettingsController.piAgentIdleParkingTimeoutMinutes
    }

    var isPiAgentIdleParkingEnabled: Bool {
        appSettingsController.isPiAgentIdleParkingEnabled
    }

    var isPiAgentLazyTranscriptLoadingEnabled: Bool {
        appSettingsController.isPiAgentLazyTranscriptLoadingEnabled
    }

    var piAgentLoadedTranscriptCacheLimit: Int {
        appSettingsController.piAgentLoadedTranscriptCacheLimit
    }

    func setAppearanceMode(_ mode: AppAppearanceMode) {
        guard appSettingsController.setAppearanceMode(mode) else { return }
        syncAppSettings()
    }

    func setPiAgentNotificationDelayMinutes(_ minutes: Int) {
        guard appSettingsController.setPiAgentNotificationDelayMinutes(minutes) else { return }
        syncAppSettings()
    }

    func setPiAgentIdleParkingEnabled(_ isEnabled: Bool) {
        guard appSettingsController.setPiAgentIdleParkingEnabled(isEnabled) else { return }
        syncAppSettings()
    }

    func setPiAgentIdleParkingTimeoutMinutes(_ minutes: Int) {
        guard appSettingsController.setPiAgentIdleParkingTimeoutMinutes(minutes) else { return }
        syncAppSettings()
    }

    func setPiAgentLazyTranscriptLoadingEnabled(_ isEnabled: Bool) {
        guard appSettingsController.setPiAgentLazyTranscriptLoadingEnabled(isEnabled) else { return }
        syncAppSettings()
    }

    func setPiAgentLoadedTranscriptCacheLimit(_ count: Int) {
        guard appSettingsController.setPiAgentLoadedTranscriptCacheLimit(count) else { return }
        syncAppSettings()
    }

    func setGitHubBoardCacheLifetimeMinutes(_ minutes: Int) {
        guard appSettingsController.setGitHubBoardCacheLifetimeMinutes(minutes) else { return }
        syncAppSettings()
    }

    func chooseProjectsRootDirectory() {
        guard appSettingsController.chooseProjectsRootDirectory() else { return }
        handleProjectsRootSettingsChange()
    }

    func setProjectsRootPath(_ path: String) {
        guard appSettingsController.setProjectsRootPath(path) else { return }
        handleProjectsRootSettingsChange()
    }

    func resetProjectsRootPathToDefault() {
        guard appSettingsController.resetProjectsRootPathToDefault() else { return }
        handleProjectsRootSettingsChange()
    }

    func chooseDefaultSkillsImportDirectory() {
        guard appSettingsController.chooseDefaultSkillsImportDirectory(startingAt: suggestedExternalSkillsDirectoryURL) else { return }
        syncAppSettings()
    }

    func setDefaultSkillsImportRootPath(_ path: String) {
        guard appSettingsController.setDefaultSkillsImportRootPath(path) else { return }
        syncAppSettings()
    }

    func resetDefaultSkillsImportRootPath() {
        guard appSettingsController.resetDefaultSkillsImportRootPath() else { return }
        syncAppSettings()
    }

    var piAgentTerminalApplicationDisplayName: String {
        appSettingsController.piAgentTerminalApplicationDisplayName
    }

    var piAgentTerminalApplicationSelectionID: String {
        appSettingsController.piAgentTerminalApplicationSelectionID
    }

    var piAgentTerminalApplicationOptions: [TerminalApplicationOption] {
        appSettingsController.piAgentTerminalApplicationOptions
    }

    func setPiAgentTerminalApplicationSelection(_ selectionID: String) {
        appSettingsController.setPiAgentTerminalApplicationSelection(selectionID)
        syncAppSettings()
    }

    func choosePiAgentTerminalApplication() {
        guard appSettingsController.choosePiAgentTerminalApplication() else { return }
        syncAppSettings()
    }

    func setPiAgentTerminalApplicationPath(_ path: String?) {
        guard appSettingsController.setPiAgentTerminalApplicationPath(path) else { return }
        syncAppSettings()
    }

    func resetPiAgentTerminalApplicationToDefault() {
        guard appSettingsController.resetPiAgentTerminalApplicationToDefault() else { return }
        syncAppSettings()
    }

    func togglePiAgentThinkingBlocksVisibility() {
        guard appSettingsController.togglePiAgentThinkingBlocksVisibility() else { return }
        syncAppSettings()
    }

    func setPiAgentTranscriptVisibility(_ keyPath: WritableKeyPath<PiAgentTranscriptVisibilitySettings, Bool>, to value: Bool) {
        guard appSettingsController.setPiAgentTranscriptVisibility(keyPath, to: value) else { return }
        syncAppSettings()
    }

    func setAgentMemoryEnabled(_ isEnabled: Bool) {
        guard appSettingsController.setAgentMemoryEnabled(isEnabled) else { return }
        syncAppSettings()
    }

    func setAgentMemorySubagentsEnabled(_ isEnabled: Bool) {
        guard appSettingsController.setAgentMemorySubagentsEnabled(isEnabled) else { return }
        syncAppSettings()
    }

    func setAgentMemoryShowTranscriptCards(_ isEnabled: Bool) {
        guard appSettingsController.setAgentMemoryShowTranscriptCards(isEnabled) else { return }
        syncAppSettings()
    }

    func setAgentMemoryInjectionCharacterBudget(_ budget: Int) {
        guard appSettingsController.setAgentMemoryInjectionCharacterBudget(budget) else { return }
        syncAppSettings()
    }

    func createAgentMemory(title: String, summary: String, body: String, kind: AgentMemoryKind, tags: [String]) {
        do {
            let record = try agentMemoryStore.createMemory(
                kind: kind,
                scope: selectedProjectPath == nil ? .global : .project,
                status: .active,
                title: title,
                summary: summary,
                body: body,
                projectPath: selectedProjectPath,
                tags: tags
            )
            appendMemoryEvent(.stored, records: [record], summary: "Stored \(record.kind.displayName.lowercased()) memory: \(record.title).")
        } catch {
            appendMemoryBlockedEvent(error.localizedDescription)
        }
    }

    func updateAgentMemory(id: String, title: String, summary: String, body: String, tags: [String]) {
        do {
            try agentMemoryStore.updateMemory(id: id, title: title, summary: summary, body: body, tags: tags)
            if let record = agentMemoryStore.records.first(where: { $0.id == id }) {
                appendMemoryEvent(.edited, records: [record], summary: "Edited memory: \(record.title).")
            }
        } catch {
            appendMemoryBlockedEvent(error.localizedDescription)
        }
    }

    func setAgentMemoryStatus(_ id: String, status: AgentMemoryStatus) {
        agentMemoryStore.setStatus(id: id, status: status)
        if let record = agentMemoryStore.records.first(where: { $0.id == id }) {
            appendMemoryEvent(status == .archived ? .archived : .edited, records: [record], summary: "Set memory status to \(status.displayName): \(record.title).")
        }
    }

    func deleteAgentMemory(_ id: String) {
        agentMemoryStore.deleteMemory(id: id)
    }

    func setShowContextSmartZoneHint(_ isEnabled: Bool) {
        guard appSettingsController.setShowContextSmartZoneHint(isEnabled) else { return }
        syncAppSettings()
    }

    func setAutoGeneratePiAgentSessionTitles(_ isEnabled: Bool) {
        guard appSettingsController.setAutoGeneratePiAgentSessionTitles(isEnabled) else { return }
        syncAppSettings()
    }

    func setAutoUpdatePiAgentSessionTitles(_ isEnabled: Bool) {
        guard appSettingsController.setAutoUpdatePiAgentSessionTitles(isEnabled) else { return }
        syncAppSettings()
    }

    func setPiAgentTitleGenerationModelIdentifier(_ identifier: String?) {
        guard appSettingsController.setPiAgentTitleGenerationModelIdentifier(identifier) else { return }
        syncAppSettings()
    }

    func setPiAgentGitAutomationEnabled(_ isEnabled: Bool) {
        guard appSettingsController.setPiAgentGitAutomationEnabled(isEnabled) else { return }
        syncAppSettings()
    }

    func setPiAgentGitAutomationRequiresConfirmation(_ isEnabled: Bool) {
        guard appSettingsController.setPiAgentGitAutomationRequiresConfirmation(isEnabled) else { return }
        syncAppSettings()
    }

    func setPiAgentCommitMessageModelIdentifier(_ identifier: String?) {
        guard appSettingsController.setPiAgentCommitMessageModelIdentifier(identifier) else { return }
        syncAppSettings()
    }

    func isInjectedCommandEnabled(_ command: PiInjectedCommand) -> Bool {
        PiInjectedCommandCatalog.isEnabled(command, settings: appSettings)
    }

    func setInjectedCommandEnabled(_ command: PiInjectedCommand, isEnabled: Bool) {
        guard appSettingsController.setInjectedCommandEnabled(command, isEnabled: isEnabled) else { return }
        syncAppSettings()
    }

    func importCommandFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.sourceCode, .javaScript]
        panel.message = "Choose a Pi extension file containing pi.registerCommand(...)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? PiInjectedCommandCatalog.importCommandFile(url)
        syncAppSettings()
    }

    func piAgentTitleGenerationModel() -> AvailableModel? {
        if let identifier = appSettings.piAgentTitleGenerationModelIdentifier,
           let selected = enabledAvailableModels.first(where: { $0.identifier == identifier }) {
            return selected
        }
        return defaultPiAgentModel() ?? enabledAvailableModels.first
    }

    func piAgentCommitMessageModel() -> AvailableModel? {
        guard appSettings.piAgentGitAutomationEnabled,
              let identifier = appSettings.piAgentCommitMessageModelIdentifier,
              let selected = enabledAvailableModels.first(where: { $0.identifier == identifier }) else { return nil }
        return selected
    }

    private func syncAppSettings() {
        appSettings = appSettingsController.settings
        writeOpenAIFastModeConfig()
        configurePiAgentIdleParking()
        configurePiAgentTranscriptMemory()
        configureAgentMemory()
    }

    private func writeOpenAIFastModeConfig() {
        PiNativeSubagentBridgeExtensions.writeOpenAIFastConfig(
            enabledModelIdentifiers: appSettings.openAIFastModeModelIdentifiers
        )
    }

    private func configurePiAgentIdleParking() {
        piAgentRunner.configureIdleParking(timeout: piAgentIdleParkingTimeout)
    }

    private func configurePiAgentTranscriptMemory() {
        piAgentSessionStore.configureTranscriptMemory(
            lazyLoadingEnabled: isPiAgentLazyTranscriptLoadingEnabled,
            cacheLimit: piAgentLoadedTranscriptCacheLimit
        )
    }

    private func configureAgentMemory() {
        objectWillChange.send()
    }

    private func parentMemoryArguments(for session: PiAgentSessionRecord, projectURL: URL, initialPrompt: String?) -> [String] {
        guard appSettings.agentMemoryEnabled else { return [] }
        let query = [initialPrompt, session.title, session.repository].compactMap { $0 }.joined(separator: "\n")
        let guidance = agentMemoryGuidancePrompt(projectPath: session.projectPath)
        guard let retrieval = agentMemoryStore.retrieve(
            projectPath: session.projectPath,
            query: query,
            maxItems: 5,
            maxCharacters: appSettings.agentMemoryInjectionCharacterBudget
        ) else {
            return PiParentAppendPromptResolver.appendSystemPromptArguments(projectURL: projectURL, agentDeckAppendPrompts: [guidance])
        }
        agentMemoryStore.markUsed(retrieval.records.map(\.id))
        appendMemoryEvent(.recalled, records: retrieval.records, summary: "Loaded \(retrieval.records.count) relevant memor\(retrieval.records.count == 1 ? "y" : "ies") for this session.", sessionID: session.id)
        return PiParentAppendPromptResolver.appendSystemPromptArguments(projectURL: projectURL, agentDeckAppendPrompts: [guidance, retrieval.prompt])
    }

    private func childMemoryArguments(for parentSession: PiAgentSessionRecord, agent: EffectiveAgentRecord, task: String) -> [String] {
        guard appSettings.agentMemoryEnabled, appSettings.agentMemorySubagentsEnabled else { return [] }
        let query = [agent.name, agent.resolved.description, task].joined(separator: "\n")
        var prompts = [agentMemoryGuidancePrompt(projectPath: parentSession.projectPath, isSubagent: true)]
        guard let retrieval = agentMemoryStore.retrieve(
            projectPath: parentSession.projectPath,
            query: query,
            maxItems: 4,
            maxCharacters: min(appSettings.agentMemoryInjectionCharacterBudget, 3_500)
        ) else { return prompts.flatMap { ["--append-system-prompt", $0] } }
        agentMemoryStore.markUsed(retrieval.records.map(\.id))
        appendMemoryEvent(.recalled, records: retrieval.records, summary: "Loaded \(retrieval.records.count) scoped memor\(retrieval.records.count == 1 ? "y" : "ies") for subagent \(agent.name).", sessionID: parentSession.id)
        prompts.append(retrieval.prompt)
        return prompts.flatMap { ["--append-system-prompt", $0] }
    }

    private func agentMemoryGuidancePrompt(projectPath: String?, isSubagent: Bool = false) -> String {
        """
        <agent-deck-memory-policy>
        Agent Deck Memory is enabled. Use `agent_deck_memory_propose` when you discover durable knowledge worth remembering.
        Store project knowledge as project memory: repo architecture, commands, tests, CI, deployment, conventions, decisions, recurring failures, and runbooks.
        Store global memory only for user preferences or cross-project workflow rules.
        Do not propose temporary task state, speculative facts, raw logs, customer data, API keys, tokens, passwords, or private keys.
        Use `agent_deck_memory_mark_stale` when recalled memory is outdated, wrong, or contradicted by the current repository or user correction.
        \(isSubagent ? "As a subagent, store durable findings as project memory by default; do not create subagent-specific memory." : "")
        Agent Deck classifies, scans, and stores memory automatically. Stale memory is removed from future automatic injection.
        Current project memory scope: \(projectPath ?? "none").
        </agent-deck-memory-policy>
        """
    }

    private func handleParentMemoryProposal(sessionID: UUID, request: AgentMemoryProposalBridgeRequest) -> String {
        guard appSettings.agentMemoryEnabled else { return "\(AppBrand.displayName) memory is disabled." }
        let session = piAgentSessionStore.sessions.first(where: { $0.id == sessionID })
        return createAutomaticMemory(request, sourceSessionID: sessionID, sourceRunID: nil, sourceAgentName: nil, fallbackProjectPath: session?.projectPath)
    }

    private func handleSubagentMemoryProposal(parentSessionID: UUID, runID: UUID, agentName: String?, request: AgentMemoryProposalBridgeRequest) -> String {
        guard appSettings.agentMemoryEnabled else { return "\(AppBrand.displayName) memory is disabled." }
        let session = piAgentSessionStore.sessions.first(where: { $0.id == parentSessionID })
        return createAutomaticMemory(request, sourceSessionID: parentSessionID, sourceRunID: runID, sourceAgentName: agentName, fallbackProjectPath: session?.projectPath)
    }

    private func createAutomaticMemory(_ request: AgentMemoryProposalBridgeRequest, sourceSessionID: UUID, sourceRunID: UUID?, sourceAgentName: String?, fallbackProjectPath: String?) -> String {
        let classification = classifyMemoryProposal(request, fallbackProjectPath: fallbackProjectPath, sourceAgentName: sourceAgentName)
        do {
            let record = try agentMemoryStore.createMemory(
                kind: request.kind ?? classification.kind,
                scope: classification.scope,
                status: .active,
                title: request.title,
                summary: request.summary,
                body: request.body,
                projectPath: classification.scope == .project ? classification.projectPath : nil,
                sourceSessionID: sourceSessionID,
                sourceRunID: sourceRunID,
                sourceAgentName: sourceAgentName,
                proposalReason: request.reason,
                tags: request.tags ?? []
            )
            appendMemoryEvent(.stored, records: [record], summary: "Stored \(record.scope.displayName.lowercased()) \(record.kind.displayName.lowercased()) memory: \(record.title).", sessionID: sourceSessionID)
            return "Memory stored as \(record.scope.displayName) / \(record.kind.displayName): \(record.title)."
        } catch {
            appendMemoryBlockedEvent(error.localizedDescription, sessionID: sourceSessionID)
            return error.localizedDescription
        }
    }

    private func handleParentMemoryMarkStale(sessionID: UUID, request: AgentMemoryStaleBridgeRequest) -> String {
        guard appSettings.agentMemoryEnabled else { return "\(AppBrand.displayName) memory is disabled." }
        let session = piAgentSessionStore.sessions.first(where: { $0.id == sessionID })
        return markStaleMemories(request, sourceSessionID: sessionID, fallbackProjectPath: session?.projectPath)
    }

    private func handleSubagentMemoryMarkStale(parentSessionID: UUID, runID: UUID, agentName: String?, request: AgentMemoryStaleBridgeRequest) -> String {
        guard appSettings.agentMemoryEnabled else { return "\(AppBrand.displayName) memory is disabled." }
        let session = piAgentSessionStore.sessions.first(where: { $0.id == parentSessionID })
        return markStaleMemories(request, sourceSessionID: parentSessionID, fallbackProjectPath: session?.projectPath)
    }

    private func markStaleMemories(_ request: AgentMemoryStaleBridgeRequest, sourceSessionID: UUID, fallbackProjectPath: String?) -> String {
        var matchedRecords: [AgentMemoryRecord] = []
        let requestedIDs = Set((request.memoryIDs ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        if !requestedIDs.isEmpty {
            matchedRecords.append(contentsOf: agentMemoryStore.records.filter { requestedIDs.contains($0.id) && $0.isInjectable })
        }
        if matchedRecords.isEmpty, let query = request.query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty {
            matchedRecords = agentMemoryStore.retrieve(projectPath: fallbackProjectPath, query: query, maxItems: 5)?.records ?? []
        }
        let uniqueRecords = Dictionary(grouping: matchedRecords, by: \.id).compactMap { $0.value.first }
        guard !uniqueRecords.isEmpty else {
            let summary = "No active Agent Deck memory matched the stale request."
            appendMemoryEvent(.blocked, records: [], summary: summary, sessionID: sourceSessionID)
            return summary
        }
        for record in uniqueRecords {
            agentMemoryStore.setStatus(id: record.id, status: .stale)
        }
        appendMemoryEvent(.stale, records: uniqueRecords, summary: "Marked \(uniqueRecords.count) memor\(uniqueRecords.count == 1 ? "y" : "ies") stale; stale memory is no longer injected automatically.", sessionID: sourceSessionID)
        return "Marked \(uniqueRecords.count) Agent Deck memor\(uniqueRecords.count == 1 ? "y" : "ies") stale."
    }

    private func classifyMemoryProposal(_ request: AgentMemoryProposalBridgeRequest, fallbackProjectPath: String?, sourceAgentName: String?) -> (scope: AgentMemoryScope, kind: AgentMemoryKind, projectPath: String?) {
        let text = [request.title, request.summary, request.body, request.reason ?? "", sourceAgentName ?? ""].joined(separator: "\n").lowercased()
        let requestedScope = request.scope
        let kind = request.kind ?? inferredMemoryKind(from: text)
        let globalHints = ["prefer", "always ask", "my preference", "i prefer", "communication style", "before pushing", "across projects"]
        let projectHints = ["repo", "project", "file", "directory", "package", "xcode", "swift", "react", "pnpm", "npm", "test", "ci", "deploy", "build", "architecture", "command"]
        let looksProjectSpecific = projectHints.contains(where: { text.contains($0) })
        let looksGlobal = globalHints.contains(where: { text.contains($0) })
        guard fallbackProjectPath != nil else { return (.global, kind, nil) }
        if requestedScope == .project || (requestedScope == .global && looksProjectSpecific) {
            return (.project, kind, fallbackProjectPath)
        }
        if requestedScope == .global || (looksGlobal && !looksProjectSpecific) {
            return (.global, kind, nil)
        }
        return (.project, kind, fallbackProjectPath)
    }

    private func inferredMemoryKind(from text: String) -> AgentMemoryKind {
        if text.contains("runbook") || text.contains("steps") || text.contains("command") || text.contains("how to") { return .runbook }
        if text.contains("decision") || text.contains("decided") || text.contains("rationale") { return .decision }
        if text.contains("failed") || text.contains("failure") || text.contains("do not") || text.contains("does not work") { return .failure }
        if text.contains("prefer") || text.contains("always ask") || text.contains("style") { return .preference }
        if text.contains("architecture") || text.contains("structure") || text.contains("uses") { return .context }
        return .observation
    }

    private func appendMemoryEvent(_ kind: AgentMemoryEventKind, records: [AgentMemoryRecord], summary: String, sessionID explicitSessionID: UUID? = nil) {
        guard appSettings.agentMemoryShowTranscriptCards,
              let sessionID = explicitSessionID ?? piAgentSessionStore.selectedSessionID else { return }
        let event = agentMemoryStore.transcriptEvent(kind: kind, records: records, summary: summary)
        let rawJSON = (try? JSONEncoder().encode(event)).flatMap { String(data: $0, encoding: .utf8) }
        piAgentSessionStore.append(.init(sessionID: sessionID, role: .status, title: event.title, text: event.summary, rawJSON: rawJSON))
    }

    private func appendMemoryBlockedEvent(_ summary: String, sessionID explicitSessionID: UUID? = nil) {
        guard appSettings.agentMemoryShowTranscriptCards,
              let sessionID = explicitSessionID ?? piAgentSessionStore.selectedSessionID else { return }
        let event = AgentMemoryTranscriptEvent(type: AgentMemoryTranscriptEvent.rawType, event: .blocked, memoryIDs: [], scope: nil, title: AgentMemoryEventKind.blocked.displayTitle, summary: summary)
        let rawJSON = (try? JSONEncoder().encode(event)).flatMap { String(data: $0, encoding: .utf8) }
        piAgentSessionStore.append(.init(sessionID: sessionID, role: .status, title: event.title, text: event.summary, rawJSON: rawJSON))
    }

    private func handleProjectsRootSettingsChange() {
        syncAppSettings()
        refresh(includeModels: false)
        refreshGitHubProjectScopedState()
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
    }

    var areSubagentsEnabledForNewSessions: Bool {
        appSettingsController.areSubagentsEnabledForNewSessions
    }

    func setSubagentsEnabledForNewSessions(_ isEnabled: Bool) {
        guard appSettingsController.setSubagentsEnabledForNewSessions(isEnabled) else { return }
        syncAppSettings()
        piAgentSessionStore.newSessionSubagentsEnabled = isEnabled
    }

    func toggleSubagentsForNewSessions() {
        guard appSettingsController.toggleSubagentsForNewSessions() else { return }
        syncAppSettings()
        piAgentSessionStore.newSessionSubagentsEnabled = appSettings.nativeSubagentsEnabledForNewSessions
    }

    func setSubagentsEnabledForSelectedSession(_ isEnabled: Bool) {
        guard let session = piAgentSessionStore.selectedSession else { return }
        piAgentSessionStore.updateSession(session.id, bumpUpdatedAt: false) { session in
            session.subagentsEnabled = isEnabled
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

    var currentGitHubAccount: GitHubHostAccount? {
        githubConnectionState.account ?? gitHubSession?.account
    }

    var shouldShowGitHubConnectionCard: Bool {
        currentGitHubAccount != nil || githubLastStatusCheckAt != nil || githubIsRefreshingEverything
    }

    var allDisplayAgents: [EffectiveAgentRecord] {
        var byID: [EffectiveAgentRecord.ID: EffectiveAgentRecord] = [:]
        for agent in snapshot.effectiveAgents { byID[agent.id] = agent }
        for agent in catalogOnlyEffectiveAgents { byID[agent.id] = agent }
        for agent in libraryOnlyEffectiveAgents { byID[agent.id] = agent }
        for agent in projectAssignedLibraryAgentsForAggregateView { byID[agent.id] = agent }
        return Array(byID.values)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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
        filteredAgents.first(where: { $0.id == selectedAgentID }) ?? (snapshot.effectiveAgents + catalogOnlyEffectiveAgents + libraryOnlyEffectiveAgents).first(where: { $0.id == selectedAgentID })
    }

    private var catalogOnlyEffectiveAgents: [EffectiveAgentRecord] {
        let effectivePaths = Set(snapshot.effectiveAgents.compactMap(\.sourcePath).map(standardizedPath))
        return agentCatalog(forProjectPath: selectedProjectPath)
            .filter { $0.source.kind != .builtin }
            .filter { !effectivePaths.contains(standardizedPath($0.filePath)) }
            .filter { $0.source.kind != .library }
            .map { catalogDisplayAgent(from: $0, projectRoot: snapshot.projectRoot) }
    }

    private var libraryOnlyEffectiveAgents: [EffectiveAgentRecord] {
        // In the global view, project-local agents should not hide reusable library
        // agents with the same name. Global/custom winners still hide library duplicates.
        let agentsThatHideLibrary = snapshot.projectRoot == nil
            ? snapshot.effectiveAgents.filter { $0.projectCustom == nil && $0.projectOverride == nil }
            : snapshot.effectiveAgents
        let effectiveNames = Set(agentsThatHideLibrary.map(\.name))
        return snapshot.libraryAgents
            .filter { !effectiveNames.contains($0.name) }
            .map { libraryDisplayAgent(from: $0, projectRoot: snapshot.projectRoot) }
    }

    private var projectAssignedLibraryAgentsForAggregateView: [EffectiveAgentRecord] {
        guard snapshot.projectRoot == nil else { return [] }
        let effectiveNames = Set(snapshot.effectiveAgents.map(\.name))
        let libraryByName = Dictionary(uniqueKeysWithValues: snapshot.libraryAgents.map { ($0.name, $0) })
        let assignedNames = Set(projectPreferencesByPath.values.flatMap(\.assignedAgentNames))
        let libraryNames = Set(snapshot.libraryAgents.map(\.name))
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
        var records = globalSnapshot.globalAgents + globalSnapshot.libraryAgents
        for projectSnapshot in allProjectSnapshots.values {
            records += projectSnapshot.projectAgents + projectSnapshot.legacyProjectAgents + projectSnapshot.libraryAgents
        }
        if selectedProjectPath == projectPath {
            records += snapshot.projectAgents + snapshot.legacyProjectAgents + snapshot.libraryAgents
        }
        return deduplicateByID(records)
    }

    private func agentCatalog(globalSnapshot: ScanSnapshot, catalogProjectSnapshots: [ScanSnapshot]) -> [AgentRecord] {
        deduplicateByID(
            globalSnapshot.globalAgents +
            globalSnapshot.libraryAgents +
            catalogProjectSnapshots.flatMap { $0.projectAgents + $0.legacyProjectAgents + $0.libraryAgents }
        )
    }

    private func scopedAgentSnapshot(_ base: ScanSnapshot, projectPath: String?, globalCatalogSnapshot: ScanSnapshot, catalogProjectSnapshots: [ScanSnapshot]) -> ScanSnapshot {
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

    private func migrateAgentAssignmentsFromDiscoveredFiles(globalSnapshot: ScanSnapshot, projectSnapshots: [String: ScanSnapshot]) {
        for name in Set(globalSnapshot.globalAgents.map(\.name)) {
            _ = appSettingsController.setDefaultAgent(name, enabled: true)
        }
        for (projectPath, projectSnapshot) in projectSnapshots {
            for name in Set((projectSnapshot.projectAgents + projectSnapshot.legacyProjectAgents).map(\.name)) {
                projectPreferencesStore.setAssignedAgent(name, assigned: true, for: projectPath)
            }
        }
        _ = appSettingsController.markAgentAssignmentsMigratedFromDiscoveredFiles()
        appSettings = appSettingsController.settings
        projectPreferencesByPath = projectPreferencesStore.preferencesByPath
    }

    var selectedSkill: SkillRecord? {
        allVisibleSkillRecords.first(where: { $0.id == selectedSkillID })
    }

    var allVisibleSkillRecords: [SkillRecord] {
        deduplicateByID(snapshot.skills + snapshot.librarySkills)
            .sorted { lhs, rhs in
                let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                return lhs.source.kind.rawValue < rhs.source.kind.rawValue
            }
    }

    func startupSnapshot(forProjectPath path: String) -> ScanSnapshot {
        guard let projectSnapshot = allProjectSnapshots[path] else { return snapshot }
        return scopedStartupSnapshot(projectSnapshot: projectSnapshot)
    }

    private func scopedStartupSnapshot(projectSnapshot: ScanSnapshot) -> ScanSnapshot {
        projectSnapshot
    }

    var selectedPromptTemplate: PromptTemplateRecord? {
        allVisiblePromptTemplateRecords.first(where: { $0.id == selectedCommandItemID })
    }

    var allVisiblePromptTemplateRecords: [PromptTemplateRecord] {
        deduplicateByID(snapshot.promptTemplates + snapshot.libraryPromptTemplates)
            .sorted { lhs, rhs in
                let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                return lhs.source.kind.rawValue < rhs.source.kind.rawValue
            }
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
        let projectRoot = scopeSnapshot(for: target).projectRoot.map { URL(fileURLWithPath: $0) }
        let environment = EnvRuntimeEnvironment().environment(projectRoot: projectRoot)
        return PiNativeSubagentBridgeExtensions.isExaConfigured(environment: environment)
    }

    func availableModelIdentifiers() -> [String] {
        enabledAvailableModels.map(\.identifier)
    }

    var selectedProjectName: String {
        projectRootURL?.lastPathComponent ?? "No Project Selected"
    }

    var configuredProjectsRootURL: URL {
        appSettingsController.configuredProjectsRootURL
    }

    var configuredProjectsRootPath: String {
        appSettingsController.configuredProjectsRootPath
    }

    var enabledProjects: [DiscoveredProject] {
        discoveredProjects.filter { projectPreference(for: $0.path).isEnabled }
    }

    var favoriteProjects: [DiscoveredProject] {
        enabledProjects.filter { projectPreference(for: $0.path).isFavorite }
    }

    var gitHubProjects: [DiscoveredProject] {
        enabledProjects.filter(\.isGitHubRepository)
    }

    var selectedDiscoveredProject: DiscoveredProject? {
        guard let selectedProjectPath else { return nil }
        return discoveredProjects.first(where: { $0.path == selectedProjectPath })
    }

    var selectedGitHubProject: DiscoveredProject? {
        guard let selectedDiscoveredProject, selectedDiscoveredProject.isGitHubRepository else { return nil }
        return selectedDiscoveredProject
    }

    var shouldWarnProjectSelection: Bool {
        enabledProjects.isEmpty
    }

    var hasAgentWarnings: Bool {
        filteredAgents.contains { agent in
            !warnings(for: agent).isEmpty || !explicitSkillVisibilityIssues(for: agent).isEmpty
        }
    }

    var hasSkillWarnings: Bool {
        !skillReferenceWarnings.isEmpty || !skillWarnings.isEmpty
    }

    var hasPromptWarnings: Bool {
        !promptWarnings.isEmpty
    }

    var skillWarnings: [DiagnosticWarning] {
        let baseWarnings = snapshot.warnings.filter { warning in
            warning.id.hasPrefix("malformed-skill:") || warning.message.localizedCaseInsensitiveContains("skill")
        }
        let collisionWarnings = PiSkillLaunchResolver.collisions(in: allVisibleSkillRecords).map { collision in
            let paths = collision.skills.map(\.filePath).joined(separator: ", ")
            return DiagnosticWarning(id: "duplicate-skill:\(collision.name)", message: "Duplicate skill name `\(collision.name)` found at: \(paths)")
        }
        return baseWarnings + collisionWarnings
    }

    var promptWarnings: [DiagnosticWarning] {
        let baseWarnings = snapshot.warnings.filter { warning in
            warning.id.hasPrefix("duplicate-prompt:")
        }
        let collisionWarnings = PiPromptTemplateLaunchResolver.collisions(in: allVisiblePromptTemplateRecords).map { collision in
            let paths = collision.prompts.map(\.filePath).joined(separator: ", ")
            return DiagnosticWarning(id: "duplicate-prompt-template:\(collision.name)", message: "Duplicate prompt template name `/\(collision.name)` found at: \(paths)")
        }
        return baseWarnings + collisionWarnings
    }

    var skillReferenceWarnings: [SkillReferenceWarning] {
        filteredAgents.flatMap { agent in
            explicitSkillVisibilityIssues(for: agent).flatMap { issue in
                issue.missingSkills.map { missingSkill in
                    SkillReferenceWarning(agentName: agent.name, project: issue.project, missingSkill: missingSkill)
                }
            }
        }
        .sorted {
            if $0.missingSkill != $1.missingSkill { return $0.missingSkill < $1.missingSkill }
            if $0.agentName != $1.agentName { return $0.agentName < $1.agentName }
            return $0.project.name < $1.project.name
        }
    }

    func piAgentSessionProjectContext() -> DiscoveredProject {
        if let selectedDiscoveredProject {
            return selectedDiscoveredProject
        }

        let rootURL = configuredProjectsRootURL
        let rootName = rootURL.lastPathComponent.isEmpty ? rootURL.path : rootURL.lastPathComponent
        return DiscoveredProject(
            url: rootURL,
            gitHubRemote: nil,
            isGitRepository: false,
            iconFileURL: nil,
            fallbackSymbolName: "folder",
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

    func saveAgentDraft(_ draft: AgentEditorDraft, for agent: EffectiveAgentRecord) throws {
        try agentPersistence.save(draft, original: agent, projectRoot: selectedProjectPath)
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
            extensions: nil,
            skills: [],
            output: nil,
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

        refresh(includeModels: false, scanAllProjects: true)
        selectedAgentID = filteredAgents.first { $0.name == newName }?.id ?? selectedAgentID
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

        refresh(includeModels: false, scanAllProjects: true)
        selectedSkillID = allVisibleSkillRecords.first { $0.name == newName }?.id ?? selectedSkillID
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
        refreshTask?.cancel()
        let result = AppRefreshService().loadSnapshot(
            rootURL: configuredProjectsRootURL,
            selectedProjectPath: selectedProjectPath,
            preferencesByPath: projectPreferencesStore.preferencesByPath,
            externalSkillPaths: appSettings.externalSkillPaths,
            scanAllProjects: true
        )
        applyRefreshSnapshot(result, includeModels: false)
    }

    private func validateAgentRename(_ record: AgentRecord, to newName: String) throws {
        guard !agentNameExists(newName, excludingPaths: [standardizedPath(record.filePath)]) else {
            throw ResourceRenameError.duplicateName(newName)
        }
        let sourceURL = URL(fileURLWithPath: record.filePath).standardizedFileURL
        if (try? sourceURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw ResourceRenameError.unsupportedResource("Symlinked agents cannot be renamed safely in app. Rename the real agent file instead.")
        }
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
        try validateCustomAgentSkillReferenceWriteTargets(for: skill.name)
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
            guard let writeURL = customAgentWriteURL(for: record) else {
                throw ResourceRenameError.unsupportedResource("Agent `\(record.name)` is symlinked. Rename or edit that agent manually before renaming this skill.")
            }
            guard seenWriteTargets.insert(writeURL.path).inserted else { continue }
            var config = record.parsed
            config.skills = config.skills.map { $0 == oldName ? newName : $0 }
            let text = agentPersistence.serializedText(for: config)
            try text.write(to: writeURL, atomically: true, encoding: .utf8)
        }
    }

    private func validateCustomAgentSkillReferenceWriteTargets(for skillName: String) throws {
        for record in allAgentRecordsForReferenceUpdates() where record.parsed.skills.contains(skillName) && record.source.kind != .builtin && record.source.kind != .package {
            guard customAgentWriteURL(for: record) != nil else {
                throw ResourceRenameError.unsupportedResource("Agent `\(record.name)` is symlinked. Rename or edit that agent manually before renaming this skill.")
            }
        }
    }

    private func customAgentWriteURL(for record: AgentRecord) -> URL? {
        let sourceURL = URL(fileURLWithPath: record.filePath).standardizedFileURL
        guard (try? sourceURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return nil }
        return sourceURL
    }

    private func replaceSkillReferencesInBuiltinOverrides(from oldName: String, to newName: String) throws {
        for settingsPath in allSettingsPaths() {
            var root = try loadJSONDictionary(at: settingsPath)
            guard var subagents = root["subagents"] as? [String: Any], var overrides = subagents["agentOverrides"] as? [String: Any] else { continue }
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
            guard changed else { continue }
            subagents["agentOverrides"] = overrides
            root["subagents"] = subagents
            try writeJSONDictionary(root, to: settingsPath)
        }
    }

    private func settingsContainPromptFile(_ filePath: String) -> Bool {
        let target = standardizedPath(filePath)
        return allSettingsPaths().contains { settingsPath in
            guard let root = try? loadJSONDictionary(at: settingsPath), let prompts = root["prompts"] else { return false }
            let baseURL = URL(fileURLWithPath: settingsPath).deletingLastPathComponent()
            return promptEntries(from: prompts).contains { standardizedPath(resolveSettingsPath($0, baseURL: baseURL).path) == target }
        }
    }

    private func replacePromptSettingsPaths(oldURLs: [URL], newURL: URL) throws {
        let oldPaths = Set(oldURLs.map { $0.standardizedFileURL.path })
        for settingsPath in allSettingsPaths() {
            var root = try loadJSONDictionary(at: settingsPath)
            guard let prompts = root["prompts"] else { continue }
            let baseURL = URL(fileURLWithPath: settingsPath).deletingLastPathComponent()
            var changed = false
            func replacement(for entry: String) -> String {
                let resolved = resolveSettingsPath(entry, baseURL: baseURL).standardizedFileURL.path
                guard oldPaths.contains(resolved) else { return entry }
                changed = true
                return rewrittenSettingsPath(for: newURL, originalEntry: entry, baseURL: baseURL)
            }
            if let value = prompts as? String {
                root["prompts"] = replacement(for: value)
            } else if let values = prompts as? [Any] {
                root["prompts"] = values.map { value -> Any in
                    guard let entry = value as? String else { return value }
                    return replacement(for: entry)
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

    func createLibraryPromptTemplate() throws {
        let libraryRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/prompt-library", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        var candidate = "new-prompt"
        var index = 2
        while FileManager.default.fileExists(atPath: libraryRoot.appendingPathComponent("\(candidate).md").path) {
            candidate = "new-prompt-\(index)"
            index += 1
        }
        let url = libraryRoot.appendingPathComponent("\(candidate).md")
        let text = """
        ---
        description: Describe this reusable prompt template.
        argument-hint: <task>
        ---

        Write the reusable prompt template here. Use $ARGUMENTS where all slash-command arguments should be inserted.
        """
        try text.write(to: url, atomically: true, encoding: .utf8)
        refresh(includeModels: false)
        selectedCommandItemID = allVisiblePromptTemplateRecords.first { $0.name == candidate }?.id ?? selectedCommandItemID
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
        refresh(includeModels: false, scanAllProjects: false, extraProjectPathsToScan: [project.path])
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

    func movePromptToLibrary(_ prompt: PromptTemplateRecord) throws {
        _ = try ensureLibraryPrompt(for: prompt)
        refresh(includeModels: false)
    }

    func agent(_ agent: AgentRecord, isEnabledFor project: DiscoveredProject) -> Bool {
        projectPreference(for: project.path).assignedAgentNames.contains(agent.name)
    }

    func assignedProjects(for agent: AgentRecord) -> [DiscoveredProject] {
        enabledProjects.filter { self.agent(agent, isEnabledFor: $0) }
    }

    func explicitSkillVisibilityIssues(for agent: EffectiveAgentRecord) -> [AgentSkillVisibilityIssue] {
        guard !agent.resolved.skills.isEmpty else { return [] }
        let explicitSkills = agent.resolved.skills
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !explicitSkills.isEmpty else { return [] }

        let managedRecord = snapshot.libraryAgents.first { $0.name == agent.name }
            ?? agent.globalCustom
            ?? agent.projectCustom
        guard let managedRecord else { return [] }

        return assignedProjects(for: managedRecord).compactMap { project in
            let missingSkills = explicitSkills.filter { !skillNamed($0, isRuntimeVisibleIn: project) }
            guard !missingSkills.isEmpty else { return nil }
            return AgentSkillVisibilityIssue(project: project, missingSkills: missingSkills)
        }
    }

    private func skillNamed(_ skillName: String, isRuntimeVisibleIn project: DiscoveredProject) -> Bool {
        let projectSnapshot = allProjectSnapshots[project.path] ?? PiScanner(externalSkillPaths: appSettings.externalSkillPaths).scan(projectRoot: project.url)
        let matches = PiSkillLaunchResolver.catalog(from: projectSnapshot).filter { $0.name == skillName }
        return matches.count == 1
    }

    func agentIsEnabledGlobally(_ agent: AgentRecord) -> Bool {
        appSettings.defaultAgentNames.contains(agent.name)
    }

    func setAgent(_ agent: AgentRecord, enabled: Bool, for project: DiscoveredProject) throws {
        projectPreferencesStore.setAssignedAgent(agent.name, assigned: enabled, for: project.path)
        applyProjectPreferenceChanges()
        refresh(includeModels: false, scanAllProjects: false, extraProjectPathsToScan: [project.path])
    }

    func enableAgentGlobally(_ agent: AgentRecord) throws {
        guard appSettingsController.setDefaultAgent(agent.name, enabled: true) else { return }
        appSettings = appSettingsController.settings
        refresh(includeModels: false)
    }

    func disableAgentGlobally(_ agent: AgentRecord) throws {
        guard appSettingsController.setDefaultAgent(agent.name, enabled: false) else { return }
        appSettings = appSettingsController.settings
        refresh(includeModels: false)
    }

    func moveAgentToLibrary(_ agent: AgentRecord) throws {
        _ = try ensureLibraryAgent(for: agent)
        refresh(includeModels: false)
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
        guard var draft = makeAgentDraft(for: agent) else { throw CocoaError(.fileNoSuchFile) }
        var skills = draft.config.skills
        if enabled {
            if !skills.contains(skill.name) { skills.append(skill.name) }
        } else {
            skills.removeAll { $0 == skill.name }
        }
        draft.config.skills = PiSkillLaunchResolver.normalizedNames(skills)
        try saveAgentDraft(draft, for: agent)
    }

    func assignedAgents(for skillRecord: SkillRecord) -> [EffectiveAgentRecord] {
        snapshot.effectiveAgents.filter { skill(skillRecord, isAssignedTo: $0) }
    }

    private func setSkill(_ skill: SkillRecord, enabled: Bool, forProjectPath projectPath: String) throws {
        projectPreferencesStore.setAssignedSkill(skill.name, assigned: enabled, for: projectPath)
        applyProjectPreferenceChanges()
        refresh(includeModels: false, scanAllProjects: false, extraProjectPathsToScan: [projectPath])
        selectedSkillID = allVisibleSkillRecords.first { $0.name == skill.name }?.id ?? selectedSkillID
    }

    func enableSkillGlobally(_ skill: SkillRecord) throws {
        if skill.source.kind == .project || skill.source.kind == .legacyProject {
            try moveSkillToGlobalDirectory(skill)
        }
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

    func deleteSkill(_ skill: SkillRecord) throws {
        guard canDeleteSkill(skill) else { throw CocoaError(.fileWriteNoPermission) }

        let targetURL = skillDeletionTargetURL(for: skill)
        try removeSkillReferences(named: skill.name)
        try FileManager.default.trashItem(at: targetURL, resultingItemURL: nil)
        removeExternalSkillCatalogReferences(for: skill, deletedTarget: targetURL)
        refresh(includeModels: false)
        selectedSkillID = allVisibleSkillRecords.first?.id
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

    private func parentSkillArguments(for projectURL: URL) throws -> [String] {
        let projectPath = projectURL.standardizedFileURL.path
        let names = Array(appSettings.defaultSkillNames.union(projectPreference(for: projectPath).assignedSkillNames))
        return try PiSkillLaunchResolver.skillArguments(for: names, catalog: skillCatalog(forProjectPath: projectPath))
    }

    private func parentPromptTemplateArguments(for projectURL: URL) throws -> [String] {
        let projectPath = projectURL.standardizedFileURL.path
        let names = Array(appSettings.defaultPromptTemplateNames.union(projectPreference(for: projectPath).assignedPromptTemplateNames))
        return try PiPromptTemplateLaunchResolver.promptTemplateArguments(for: names, catalog: promptTemplateCatalog(forProjectPath: projectPath))
    }

    private func promptTemplateCatalog(forProjectPath projectPath: String) -> [PromptTemplateRecord] {
        var records = globalSnapshot.promptTemplates + globalSnapshot.libraryPromptTemplates
        if let projectSnapshot = allProjectSnapshots[projectPath] {
            records += projectSnapshot.promptTemplates + projectSnapshot.libraryPromptTemplates
        }
        if selectedProjectPath == projectPath {
            records += snapshot.promptTemplates + snapshot.libraryPromptTemplates
        }
        var seen = Set<String>()
        return records.filter { seen.insert($0.id).inserted }
    }

    private func skillCatalog(forProjectPath projectPath: String) -> [SkillRecord] {
        var records = globalSnapshot.skills + globalSnapshot.librarySkills
        if let projectSnapshot = allProjectSnapshots[projectPath] {
            records += projectSnapshot.skills + projectSnapshot.librarySkills
        }
        if selectedProjectPath == projectPath {
            records += snapshot.skills + snapshot.librarySkills
        }
        var seen = Set<String>()
        return records.filter { seen.insert($0.id).inserted }
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
            try saveAgentDraft(draft, for: agent)
        }
    }

    private func removeExternalSkillCatalogReferences(for skill: SkillRecord, deletedTarget: URL) {
        let fileURL = URL(fileURLWithPath: skill.filePath).standardizedFileURL
        let deletedTargetPath = deletedTarget.standardizedFileURL.path
        let pathsToRemove = appSettings.externalSkillPaths.filter { rawPath in
            let url = URL(fileURLWithPath: rawPath).standardizedFileURL
            return url.path == fileURL.path || url.path == deletedTargetPath
        }
        guard appSettingsController.removeExternalSkillPaths(pathsToRemove) else { return }
        appSettings = appSettingsController.settings
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

    private func parseSimpleFrontmatter(_ text: String) -> [String: String] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---\n") else { return [:] }
        let remainder = String(normalized.dropFirst(4))
        guard let closingRange = remainder.range(of: "\n---\n") else { return [:] }
        let frontmatterText = remainder[..<closingRange.lowerBound]
        var values: [String: String] = [:]
        for rawLine in frontmatterText.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#"), let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                values[String(key)] = String(value)
            }
        }
        return values
    }

    func makeEnvDraft(for record: EnvKeyRecord) -> EnvEditorDraft {
        envPersistence.makeDraft(for: record)
    }

    func makeNewEnvDraft(scope: AgentEditingTarget.CustomAgentScope, prefilledKey: String? = nil) -> EnvEditorDraft {
        envPersistence.makeNewDraft(scope: scope, projectRoot: selectedProjectPath, prefilledKey: prefilledKey)
    }

    func saveEnvDraft(_ draft: EnvEditorDraft) throws {
        try envPersistence.save(draft)
        refreshAfterFileScopedChange(sourceKind: draft.scope, filePath: draft.path)
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
            githubLastError = error.localizedDescription
        }
    }

    func setBuiltinDisabled(_ isDisabled: Bool, for agent: EffectiveAgentRecord, scope: AgentEditingTarget.OverrideScope) {
        do {
            try agentPersistence.setBuiltinDisabled(isDisabled, for: agent, scope: scope, projectRoot: selectedProjectPath)
            refreshAfterOverrideChange(scope: scope)
        } catch {
            githubLastError = error.localizedDescription
        }
    }

    func toggleBuiltinDisabledGlobally(_ agent: EffectiveAgentRecord) {
        setBuiltinDisabled(!(agent.resolved.disabled ?? false), for: agent, scope: .global)
    }

    func builtinStateBadge(for agent: EffectiveAgentRecord) -> (text: String, color: Color)? {
        guard agent.builtin != nil, agent.globalCustom == nil, agent.projectCustom == nil else { return nil }

        let projectOverrideDisabled = agent.projectOverride?.values["disabled"] as? Bool
        let userOverrideDisabled = agent.userOverride?.values["disabled"] as? Bool

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
        snapshot.warnings.filter { warning in
            warning.message.contains("Agent \(agent.name) ") || warning.message.contains("Agent \(agent.name)")
        }
    }

    func agentsExplicitlyUsingSkill(_ skill: SkillRecord) -> [EffectiveAgentRecord] {
        snapshot.effectiveAgents
            .filter { $0.resolved.skills.contains(skill.name) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func agentsAmbientlySeeingSkill(_ skill: SkillRecord) -> [EffectiveAgentRecord] {
        []
    }

    private func makeAggregateSnapshot() -> ScanSnapshot {
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
                refresh(includeModels: false)
                return
            }
            refreshAfterProjectScopedChange(projectPath: draft.sourcePath.flatMap(projectPath(containing:)) ?? selectedProjectPath)
        case let .builtinOverride(scope):
            refreshAfterOverrideChange(scope: scope)
        }
    }

    private func refreshAfterOverrideChange(scope: AgentEditingTarget.OverrideScope) {
        switch scope {
        case .global:
            refresh(includeModels: false)
        case .project:
            refreshAfterProjectScopedChange(projectPath: selectedProjectPath)
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
        guard let projectPath else {
            refresh(includeModels: false)
            return
        }
        refresh(includeModels: false, scanAllProjects: false, extraProjectPathsToScan: [projectPath])
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

    private func refreshAvailableModels() {
        guard !isRefreshingModels else { return }
        isRefreshingModels = true

        Task.detached(priority: .utility) { [weak self] in
            let models = await PiModelDiscoveryService().loadAvailableModels()
            await self?.applyAvailableModelsRefresh(models, markRefreshComplete: true)
        }
    }

    private func ensurePiAgentModelCatalogLoaded() {
        guard availableModels.isEmpty else { return }

        Task.detached(priority: .utility) { [weak self] in
            let models = await PiModelDiscoveryService().loadAvailableModels()
            guard !models.isEmpty else { return }
            await self?.applyAvailableModelsRefresh(models, markRefreshComplete: false)
        }
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
        if agent.projectCustom != nil || agent.projectOverride != nil || (agent.projectRoot != nil && selectedProjectPath != nil) {
            return .project
        }
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

        guard autoRefreshCancellable == nil else { return }
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
        autoRefreshCancellable?.cancel()
        autoRefreshCancellable = nil
        if cancelPendingScan {
            watchFingerprintTask?.cancel()
            watchFingerprintTask = nil
        }
    }

    private func updateAutoRefreshWatchList() {
        guard let fileWatchEventMonitor else { return }
        fileWatchEventMonitor.updateWatchedURLs(currentWatchedURLsForAutoRefresh())
    }

    private func currentWatchedURLsForAutoRefresh() -> [URL] {
        watchedURLsForAutoRefresh.isEmpty
            ? AppRefreshService.watchedURLs(projects: selectedDiscoveredProject.map { [$0] } ?? [], snapshot: snapshot, externalSkillPaths: appSettings.externalSkillPaths)
            : watchedURLsForAutoRefresh
    }

    private func scheduleRefreshForWatchedFileEvent() {
        guard !didShutdown else { return }
        watchEventDebounceTask?.cancel()
        let delay = watchEventDebounceNanoseconds
        watchEventDebounceTask = Task { @MainActor [weak self, delay] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self, !Task.isCancelled, !self.didShutdown else { return }
            self.watchEventDebounceTask = nil
            self.refreshIfWatchedFilesChanged()
        }
    }

    private func refreshIfWatchedFilesChanged() {
        guard watchFingerprintTask == nil else { return }
        let previousFingerprint = lastWatchFingerprint
        let urls = currentWatchedURLsForAutoRefresh()
        watchFingerprintTask = Task.detached(priority: .utility) { [weak self, previousFingerprint, urls] in
            let fingerprint = FileWatchFingerprint.make(urls: urls)
            guard !Task.isCancelled else { return }
            await self?.applyWatchFingerprint(fingerprint, previousFingerprint: previousFingerprint)
        }
    }

    private func applyWatchFingerprint(_ fingerprint: String, previousFingerprint: String) {
        guard !Task.isCancelled else { return }
        watchFingerprintTask = nil
        guard fingerprint != previousFingerprint else { return }
        lastWatchFingerprint = fingerprint
        refresh(includeModels: false)
    }

}
