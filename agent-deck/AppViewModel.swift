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

@MainActor
final class AppViewModel: NSObject, ObservableObject {
    let windowID = UUID()
    @Published var snapshot: ScanSnapshot = .empty
    @Published var selectedSidebarItem: SidebarItem = .agent
    @Published var selectedAgentID: EffectiveAgentRecord.ID?
    @Published var selectedChainID: ChainRecord.ID?
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
    @Published var githubConnectionState: GitHubConnectionState = .checking
    @Published var githubSelectedSection: GitHubSection = .projectBoard
    @Published var githubIssueStateFilter: GitHubIssueStateFilter = .open
    @Published var githubAggregateBoard: GitHubBoardSnapshot?
    @Published var githubProjectBoard: GitHubBoardSnapshot?
    @Published var githubRepositoryChanges: RepositoryChangesSnapshot?
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
    var enabledAvailableModels: [AvailableModel] {
        availableModels.filter { !appSettings.disabledModelIdentifiers.contains($0.identifier) }
    }
    @Published var isPiAgentInspectorPresented = false
    @Published var showPiAgentAttentionOnly = false
    @Published private(set) var piAgentTitleGeneratingSessionIDs: Set<UUID> = []
    @Published private(set) var piAgentPendingComposerText: String?
    let piAgentSessionStore = PiAgentSessionStore()

    private let agentPersistence = AgentPersistence()
    private let chainPersistence = ChainPersistence()
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
    private var watchFingerprintTask: Task<Void, Never>?
    private var lastWatchFingerprint: String = ""
    private var refreshTask: Task<Void, Never>?
    private var refreshRequestID = 0
    private var shouldWarmAllProjectSnapshotsAfterInitialLoad = false
    private var isRefreshingModels = false
    private var githubProjectBoardRequestID = 0
    private var githubRepositoryChangesRequestID = 0
    private var githubDiffRequestID = 0
    private var githubIssueDetailRequestID = 0
    private var githubDiffCache: [GitDiffCacheKey: String] = [:]
    private var githubDiffCacheOrder: [GitDiffCacheKey] = []
    private let githubDiffCacheLimit = 64
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
        configurePiAgentIdleParking()
        configurePiAgentTranscriptMemory()
        shouldWarmAllProjectSnapshotsAfterInitialLoad = false
        refresh(includeModels: true, scanAllProjects: false)
        piAgentRunner.onTurnFinished = { [weak self] sessionID in
            Task { @MainActor in self?.handlePiAgentTurnFinished(sessionID) }
        }
        piAgentRunner.onManagedSubagentRequest = { [weak self] sessionID, request, completion in
            Task { @MainActor in
                self?.runManagedNativeSubagent(parentSessionID: sessionID, request: request, completion: completion)
            }
        }
        piAgentRunner.onManagedChainRequest = { [weak self] sessionID, request, completion in
            Task { @MainActor in
                self?.runManagedNativeChain(parentSessionID: sessionID, request: request, completion: completion)
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
        let preferencesByPath = projectPreferencesStore.preferencesByPath
        let rootURL = configuredProjectsRootURL
        refreshRequestID += 1
        let requestID = refreshRequestID

        refreshTask?.cancel()
        let viewModel = self
        refreshTask = Task.detached {
            let result = AppRefreshService().loadSnapshot(
                rootURL: rootURL,
                selectedProjectPath: selectedProjectPath,
                preferencesByPath: preferencesByPath,
                scanAllProjects: scanAllProjects,
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
        globalSnapshot = result.globalSnapshot
        if result.includesAllProjectSnapshots {
            allProjectSnapshots = result.projectSnapshots
        } else {
            allProjectSnapshots.merge(result.projectSnapshots) { _, fresh in fresh }
            let discoveredProjectPaths = Set(result.discoveredProjects.map(\.path))
            allProjectSnapshots = allProjectSnapshots.filter { discoveredProjectPaths.contains($0.key) }
        }
        if result.includesWatchFingerprint {
            lastWatchFingerprint = result.watchFingerprint
        }

        if let matchingProject = result.selectedProject {
            projectRootURL = matchingProject.url
            snapshot = result.selectedProjectSnapshot ?? result.projectSnapshots[matchingProject.path] ?? result.globalSnapshot
        } else {
            projectRootURL = nil
            self.selectedProjectPath = nil
            persistSelectedProjectPath(nil)
            snapshot = makeAggregateSnapshot()
        }

        let currentAgentID = selectedAgentID
        let currentChainID = selectedChainID
        let currentSkillID = selectedSkillID
        let currentCommandItemID = selectedCommandItemID

        selectedAgentID = filteredAgents.contains(where: { $0.id == currentAgentID }) ? currentAgentID : filteredAgents.first?.id
        selectedChainID = allVisibleChainRecords.contains(where: { $0.id == currentChainID }) ? currentChainID : allVisibleChainRecords.first?.id
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

        if shouldWarmAllProjectSnapshotsAfterInitialLoad {
            shouldWarmAllProjectSnapshotsAfterInitialLoad = false
            if !result.includesAllProjectSnapshots {
                refresh(includeModels: false)
            }
        }
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
        panel.message = "Choose a folder whose direct child folders contain SKILL.md files you want to import into the \(AppBrand.displayName) library."
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

        if let directMatch = externalSkillCandidate(at: root) {
            return [directMatch]
        }

        guard let entries = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return []
        }

        let results: [ExternalSkillCandidate] = entries.compactMap { entry in
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: entry.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
            return externalSkillCandidate(at: entry)
        }
        .sorted { lhs, rhs in
            let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return lhs.sourceRootPath < rhs.sourceRootPath
        }
        return results
    }

    func importExternalSkills(_ candidates: [ExternalSkillCandidate], mode: SkillLibraryImportMode, replaceExisting: Bool) throws -> SkillImportResult {
        let fileManager = FileManager.default
        let libraryRoot = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/skill-library", isDirectory: true)
        try fileManager.createDirectory(at: libraryRoot, withIntermediateDirectories: true)

        var importedNames: [String] = []
        var skippedNames: [String] = []

        for candidate in candidates {
            let sourceURL = URL(fileURLWithPath: candidate.sourceRootPath).standardizedFileURL
            let destinationURL = libraryRoot.appendingPathComponent(candidate.name, isDirectory: true)

            if fileManager.fileExists(atPath: destinationURL.path) {
                if replaceExisting {
                    try fileManager.removeItem(at: destinationURL)
                } else {
                    skippedNames.append(candidate.name)
                    continue
                }
            }

            switch mode {
            case .symlink:
                try fileManager.createSymbolicLink(at: destinationURL, withDestinationURL: sourceURL)
            case .copy:
                try fileManager.copyItem(at: sourceURL, to: destinationURL)
            }
            importedNames.append(candidate.name)
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

    func refreshRepositoryChanges(preservingDiffSelection: Bool = false) {
        guard let project = selectedDiscoveredProject, project.isGitRepository else {
            githubRepositoryChangesRequestID += 1
            githubRepositoryChanges = nil
            githubSelectedChangePaths = []
            githubSelectedDiffFilePath = nil
            githubSelectedDiffKind = nil
            githubSelectedDiffText = nil
            githubIsLoadingRepositoryChanges = false
            githubLastError = nil
            return
        }

        let projectPath = project.path
        githubRepositoryChangesRequestID += 1
        let requestID = githubRepositoryChangesRequestID
        githubIsLoadingRepositoryChanges = true
        githubLastError = nil

        Task {
            do {
                let snapshot = try await self.gitRepositoryService.loadChanges(in: project.url)
                await MainActor.run {
                    guard self.githubRepositoryChangesRequestID == requestID,
                          self.selectedDiscoveredProject?.path == projectPath else { return }

                    self.githubRepositoryChanges = snapshot
                    let validPaths = Set(snapshot.staged.map(\.path) + snapshot.unstaged.map(\.path) + snapshot.untracked.map(\.path) + snapshot.conflicted.map(\.path))
                    self.githubSelectedChangePaths = self.githubSelectedChangePaths.intersection(validPaths)
                    if !preservingDiffSelection {
                        self.githubSelectedDiffFilePath = nil
                        self.githubSelectedDiffKind = nil
                        self.githubSelectedDiffText = nil
                    }
                    self.githubIsLoadingRepositoryChanges = false
                }
            } catch {
                await MainActor.run {
                    guard self.githubRepositoryChangesRequestID == requestID,
                          self.selectedDiscoveredProject?.path == projectPath else { return }

                    self.githubRepositoryChanges = nil
                    self.githubIsLoadingRepositoryChanges = false
                    self.githubLastError = error.localizedDescription
                }
            }
        }
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
                ensurePiAgentModels(for: existing.id)
            } else {
                let session = piAgentSessionStore.createSession(
                    kind: .project,
                    title: "Project agent · \(project.name)",
                    project: project,
                    repository: project.gitHubRemote?.nameWithOwner,
                    availableModels: piAgentModelOptionsForNewSession()
                )
                ensurePiAgentModels(for: session.id)
            }
        } else {
            acknowledgeVisibleSelectedPiAgentSession()
        }
    }

    func createPiAgentDraftForSelectedProject() {
        let project = piAgentSessionProjectContext()
        selectedSidebarItem = .agent
        isPiAgentInspectorPresented = false
        let session = piAgentSessionStore.createSession(
            kind: .project,
            title: "Draft · \(project.name)",
            project: project,
            repository: project.gitHubRemote?.nameWithOwner,
            availableModels: piAgentModelOptionsForNewSession()
        )
        ensurePiAgentModels(for: session.id)
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
        let session = piAgentSessionStore.createSession(
            kind: .issue,
            title: detail.item.title,
            project: project,
            repository: detail.item.repository,
            issueNumber: detail.item.number,
            issueURL: detail.item.url,
            availableModels: piAgentModelOptionsForNewSession()
        )
        ensurePiAgentModels(for: session.id)
        piAgentPendingComposerText = PiIssuePromptBuilder.issuePrompt(detail: detail, project: project)
    }

    func consumePendingPiAgentComposerText() -> String? {
        let pending = piAgentPendingComposerText
        piAgentPendingComposerText = nil
        return pending
    }

    func openPiAgentScreen() {
        selectedSidebarItem = .agent
        if let sessionID = piAgentSessionStore.selectedSession?.id {
            ensurePiAgentModels(for: sessionID)
        }
        acknowledgeVisibleSelectedPiAgentSession()
    }

    func selectPiAgentSession(_ id: UUID) {
        piAgentSessionStore.select(id)
        selectedSidebarItem = .agent
        ensurePiAgentModels(for: id)
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
        piAgentSessionStore.sessions.filter { $0.status.isActive && !$0.needsAttention }.count
    }

    func isModelEnabled(_ model: AvailableModel) -> Bool {
        !appSettings.disabledModelIdentifiers.contains(model.identifier)
    }

    func setModelEnabled(_ model: AvailableModel, isEnabled: Bool) {
        guard appSettingsController.setModelEnabled(identifier: model.identifier, isEnabled: isEnabled) else { return }
        appSettings = appSettingsController.settings
        seedPiAgentSessionsWithAvailableModels(availableModels, overwriteExisting: true)
    }

    func enableAllModels() {
        guard appSettingsController.enableAllModels() else { return }
        appSettings = appSettingsController.settings
        seedPiAgentSessionsWithAvailableModels(availableModels, overwriteExisting: true)
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

    func runNativeChain(chainName: String, task: String, useWorktreeIsolation: Bool = false) {
        guard let session = piAgentSessionStore.selectedSession,
              let chain = allVisibleChainRecords.first(where: { $0.name == chainName }) else { return }
        runNativeChain(parentSession: session, chain: chain, task: task, useWorktreeIsolation: useWorktreeIsolation, completion: nil)
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
        let contextOverride = PiSubagentContextMode(bridgeValue: request.context)
        let useWorktreeIsolation = false
        let expectedOutcome: PiSubagentExpectedOutcome = .reportOnly
        let gate = NativeSubagentCompletionGate()
        var timeoutTask: Task<Void, Never>?
        let launchedRun = runNativeSubagent(parentSession: session, agentName: request.agent, task: request.task, useWorktreeIsolation: useWorktreeIsolation, allowDirectProjectWrites: false, expectedOutcome: expectedOutcome, requestedOutputPath: nil, allowOverwrite: false, readFirstPaths: request.reads ?? [], contextOverride: contextOverride) { run in
            timeoutTask?.cancel()
            gate.complete {
                let status = run.status == .completed ? "completed" : run.status.rawValue
                let summary = run.summary ?? run.error ?? "No summary returned."
                completion("Native subagent \(run.agentName) \(status).\n\n\(summary)")
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

    private func runManagedNativeChain(parentSessionID: UUID, request: PiManagedChainBridgeRequest, completion: @escaping (String) -> Void) {
        guard let session = piAgentSessionStore.sessions.first(where: { $0.id == parentSessionID }) else {
            completion("\(AppBrand.displayName) could not find the parent session.")
            return
        }
        guard session.subagentsEnabled else {
            completion("Native subagents are disabled for this \(AppBrand.displayName) session.")
            return
        }
        guard let chain = allVisibleChainRecords.first(where: { $0.name == request.chain }) else {
            completion("\(AppBrand.displayName) could not find a native chain named `\(request.chain)`." )
            return
        }
        let useWorktreeIsolation = request.worktree == true
        runNativeChain(parentSession: session, chain: chain, task: request.task, useWorktreeIsolation: useWorktreeIsolation) { run in
            let status = run.status == .completed ? "completed" : run.status.rawValue
            completion("Native chain \(chain.name) \(status).\n\n\(run.summary ?? run.error ?? "No summary returned.")")
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
    private func runNativeSubagent(parentSession: PiAgentSessionRecord, agentName: String, task: String, useWorktreeIsolation: Bool, allowDirectProjectWrites: Bool = false, expectedOutcome: PiSubagentExpectedOutcome = .reportOnly, requestedOutputPath: String? = nil, allowOverwrite: Bool = false, readFirstPaths: [String] = [], contextOverride: PiSubagentContextMode? = nil, completion: ((PiSubagentRunRecord) -> Void)?) -> PiSubagentRunRecord {
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
        return runNativeSubagent(parentSession: parentSession, agent: agent, snapshot: snapshot, task: task, useWorktreeIsolation: useWorktreeIsolation, expectedOutcome: expectedOutcome, requestedOutputPath: requestedOutputPath, allowOverwrite: allowOverwrite, readFirstPaths: readFirstPaths, contextOverride: contextOverride, completion: completion)
    }

    @discardableResult
    private func runNativeSubagent(parentSession: PiAgentSessionRecord, agent: EffectiveAgentRecord, snapshot: ScanSnapshot, task: String, useWorktreeIsolation: Bool, expectedOutcome: PiSubagentExpectedOutcome = .reportOnly, requestedOutputPath: String? = nil, allowOverwrite: Bool = false, readFirstPaths: [String] = [], contextOverride: PiSubagentContextMode? = nil, completion: ((PiSubagentRunRecord) -> Void)?) -> PiSubagentRunRecord {
        do {
            return try nativeSubagentRunner.runSingle(parentSession: parentSession, agent: agent, snapshot: snapshot, task: task, requestedContext: contextOverride, useWorktreeIsolation: useWorktreeIsolation, expectedOutcome: expectedOutcome, requestedOutputPath: requestedOutputPath, allowOverwrite: allowOverwrite, readFirstPaths: readFirstPaths, onCompletion: completion)
        } catch {
            piAgentSessionStore.append(.init(sessionID: parentSession.id, role: .error, title: "Subagent Launch Failed", text: error.localizedDescription))
            let placeholder = PiSubagentRunRecord.failedPlaceholder(parentSessionID: parentSession.id, agentName: agent.name, task: task, error: error.localizedDescription)
            completion?(placeholder)
            return placeholder
        }
    }

    private func runNativeChain(parentSession: PiAgentSessionRecord, chain: ChainRecord, task: String, useWorktreeIsolation: Bool, completion: ((PiSubagentRunRecord) -> Void)?) {
        let trimmedTask = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTask.isEmpty, !chain.steps.isEmpty else { return }
        let now = Date()
        let runID = UUID()
        let artifactDirectory = nativeGraphArtifactDirectory(for: runID)
        let childRecords = chain.steps.enumerated().map { index, step in
            PiSubagentChildRecord(
                id: UUID(), runID: runID, index: index, agentName: step.agent, task: step.body.isEmpty ? nil : step.body,
                status: .queued, requestedContext: .agentDefault, resolvedContext: nil, model: step.model,
                expectedOutcome: useWorktreeIsolation ? .editFilesInWorktree : .reportOnly, requestedOutputPath: nil, allowOverwrite: false,
                currentTool: nil, inputTokens: nil, outputTokens: nil, totalTokens: nil, toolCount: nil, durationMs: nil,
                artifactDirectory: nil, sessionFile: nil, outputPath: nil, worktreePath: nil, launchCommand: nil, executionRunID: nil,
                summary: nil, error: nil, dependencies: index == 0 ? nil : [UUID](), completedAt: nil, createdAt: now, updatedAt: now
            )
        }
        let run = nativeGraphRun(id: runID, parentSession: parentSession, mode: .chain, title: chain.name, task: trimmedTask, artifactDirectory: artifactDirectory, children: childRecords, edges: chainEdges(for: childRecords), concurrency: 1, worktreeIsolation: useWorktreeIsolation)
        piAgentSessionStore.upsertSubagentRun(run)
        piAgentSessionStore.append(.init(sessionID: parentSession.id, role: .status, title: "Native Chain Started", text: "\(chain.name) started with \(chain.steps.count) step(s)."))
        runNativeChainStep(parentSession: parentSession, chain: chain, graphRunID: runID, originalTask: trimmedTask, previous: "", index: 0, useWorktreeIsolation: useWorktreeIsolation, completion: completion)
    }

    private func runNativeChainStep(parentSession: PiAgentSessionRecord, chain: ChainRecord, graphRunID: UUID, originalTask: String, previous: String, index: Int, useWorktreeIsolation: Bool, completion: ((PiSubagentRunRecord) -> Void)?) {
        guard index < chain.steps.count else {
            finishNativeGraphRun(graphRunID, parentSessionID: parentSession.id, status: .completed, summary: previous.isEmpty ? "Chain completed." : previous, completion: completion)
            return
        }
        let step = chain.steps[index]
        let template = step.body.isEmpty ? (index == 0 ? "{task}" : "{previous}") : step.body
        let stepTask = renderChainTemplate(template, originalTask: originalTask, previous: previous, chainDir: nativeGraphChainDirectory(graphRunID: graphRunID))
        updateNativeGraphChild(graphRunID, parentSessionID: parentSession.id, index: index) { child in
            child.status = .running
            child.task = stepTask
        }
        let snapshot = startupSnapshot(forProjectPath: parentSession.projectPath)
        guard let agent = snapshot.effectiveAgents.first(where: { $0.name == step.agent && $0.resolved.disabled != true }) else {
            updateNativeGraphChild(graphRunID, parentSessionID: parentSession.id, index: index) { child in
                child.status = .failed
                child.error = "Agent not found: \(step.agent)"
            }
            finishNativeGraphRun(graphRunID, parentSessionID: parentSession.id, status: .failed, summary: "Chain failed: agent not found `\(step.agent)`.", completion: completion)
            return
        }
        let stepAgent = agentApplying(chainStep: step, to: agent)
        let stepOutcome: PiSubagentExpectedOutcome = useWorktreeIsolation ? .editFilesInWorktree : .reportOnly
        let childRun = runNativeSubagent(parentSession: parentSession, agent: stepAgent, snapshot: snapshot, task: stepTask, useWorktreeIsolation: useWorktreeIsolation, expectedOutcome: stepOutcome) { [weak self] childResult in
            guard let self else { return }
            self.updateNativeGraphChildFromRun(graphRunID, parentSessionID: parentSession.id, index: index, childResult: childResult)
            guard childResult.status == .completed else {
                self.finishNativeGraphRun(graphRunID, parentSessionID: parentSession.id, status: .failed, summary: childResult.error ?? "Chain failed at step \(index + 1).", completion: completion)
                return
            }
            self.runNativeChainStep(parentSession: parentSession, chain: chain, graphRunID: graphRunID, originalTask: originalTask, previous: childResult.summary ?? "", index: index + 1, useWorktreeIsolation: useWorktreeIsolation, completion: completion)
        }
        updateNativeGraphChildFromRun(graphRunID, parentSessionID: parentSession.id, index: index, childResult: childRun)
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
                status: .queued, requestedContext: .agentDefault, resolvedContext: nil, model: nil,
                expectedOutcome: useWorktreeIsolation ? .editFilesInWorktree : .reportOnly, requestedOutputPath: nil, allowOverwrite: false,
                currentTool: nil, inputTokens: nil, outputTokens: nil, totalTokens: nil, toolCount: nil, durationMs: nil,
                artifactDirectory: nil, sessionFile: nil, outputPath: nil, worktreePath: nil, launchCommand: nil, executionRunID: nil,
                summary: nil, error: nil, dependencies: nil, completedAt: nil, createdAt: now, updatedAt: now
            )
        }
        let limit = max(1, min(concurrency, tasks.count))
        let run = nativeGraphRun(id: runID, parentSession: parentSession, mode: .parallel, title: "Parallel", task: "\(tasks.count) parallel native subagent task(s)", artifactDirectory: artifactDirectory, children: childRecords, edges: [], concurrency: limit, worktreeIsolation: useWorktreeIsolation)
        piAgentSessionStore.upsertSubagentRun(run)
        piAgentSessionStore.append(.init(sessionID: parentSession.id, role: .status, title: "Native Parallel Started", text: "Started \(tasks.count) task(s), concurrency \(limit)."))
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
            agentName: title, task: task, requestedContext: .agentDefault, resolvedContext: .fresh,
            model: nil, thinking: nil, expectedOutcome: worktreeIsolation ? .editFilesInWorktree : .reportOnly, requestedOutputPath: nil, allowOverwrite: false, tools: [], skills: [], chainName: mode == .chain ? title : nil,
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

    private func agentApplying(chainStep step: ChainStepRecord, to agent: EffectiveAgentRecord) -> EffectiveAgentRecord {
        var config = agent.resolved
        if let model = step.model, !model.isEmpty { config.model = model }
        if let skills = step.skills { config.skills = skills }
        if step.skillsDisabled { config.skills = [] }
        if step.readsDisabled { config.defaultReads = [] }
        else if let reads = step.reads { config.defaultReads = reads }
        if step.outputDisabled { config.output = nil }
        else if let output = step.output { config.output = output }
        if let progress = step.progress { config.defaultProgress = progress }
        return EffectiveAgentRecord(id: agent.id, name: agent.name, projectRoot: agent.projectRoot, builtin: agent.builtin, globalCustom: agent.globalCustom, projectCustom: agent.projectCustom, userOverride: agent.userOverride, projectOverride: agent.projectOverride, resolved: config, resolutionKind: agent.resolutionKind)
    }

    private func renderChainTemplate(_ template: String, originalTask: String, previous: String, chainDir: String) -> String {
        template
            .replacingOccurrences(of: "{task}", with: originalTask)
            .replacingOccurrences(of: "{previous}", with: previous)
            .replacingOccurrences(of: "{chain_dir}", with: chainDir)
    }

    private func nativeGraphArtifactDirectory(for runID: UUID) -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let directory = appSupport.appendingPathComponent("\(AppBrand.displayName)", isDirectory: true).appendingPathComponent("Subagent Runs", isDirectory: true).appendingPathComponent(runID.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: directory.appendingPathComponent("chain_dir", isDirectory: true), withIntermediateDirectories: true)
        return directory
    }

    private func nativeGraphChainDirectory(graphRunID: UUID) -> String {
        nativeGraphArtifactDirectory(for: graphRunID).appendingPathComponent("chain_dir", isDirectory: true).path
    }

    private func chainEdges(for children: [PiSubagentChildRecord]) -> [PiSubagentGraphEdgeRecord] {
        guard children.count > 1 else { return [] }
        return (1..<children.count).map { index in
            PiSubagentGraphEdgeRecord(id: "\(children[index - 1].id.uuidString)->\(children[index].id.uuidString)", fromChildID: children[index - 1].id, toChildID: children[index].id)
        }
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
            let description = agent.resolved.description.trimmingCharacters(in: .whitespacesAndNewlines)
            let context = agent.resolved.defaultContext ?? "fresh"
            let model = agent.resolved.model ?? "default"
            let tools = (agent.resolved.tools ?? []).isEmpty ? "default tools" : "tools: \((agent.resolved.tools ?? []).joined(separator: ", "))"
            let skills = agent.resolved.skills.isEmpty ? "no private skills" : "skills: \(agent.resolved.skills.joined(separator: ", "))"
            return "- \(agent.name): \(description.isEmpty ? "No description" : description) [context: \(context), model: \(model), \(tools), \(skills)]"
        }
        let chains = allVisibleChainRecords
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { "- \($0.name): \($0.description.isEmpty ? "\($0.steps.count) step(s)" : $0.description)" }
            .joined(separator: "\n")
        let chainSection = chains.isEmpty ? "" : "\n\nAvailable native chains via `managed_chain`:\n\(chains)"
        return """
        Native \(AppBrand.displayName) tools: `ask_user`, `set_session_plan`, `update_session_plan`, `managed_subagent`, `managed_chain`, `managed_parallel`, `list_supervisor_requests`, `answer_supervisor_request`. Use `ask_user` for one focused user decision when requirements are ambiguous or preference-dependent. For multi-step work, keep a short session plan updated on meaningful transitions. Use native subagents for bounded work; include expected output and `reads` when known. Use worktrees for writer tasks.
        \(lines.joined(separator: "\n"))\(chainSection)
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
            if run.mode == .chain { run.status = .stopped }
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
            if run.mode == .chain {
                for index in childIndex..<children.count {
                    children[index].status = index == childIndex ? .running : .queued
                    children[index].summary = nil
                    children[index].error = nil
                    children[index].completedAt = nil
                    children[index].durationMs = nil
                    children[index].executionRunID = nil
                }
            } else {
                children[childIndex].status = .running
                children[childIndex].summary = nil
                children[childIndex].error = nil
                children[childIndex].completedAt = nil
                children[childIndex].durationMs = nil
                children[childIndex].executionRunID = nil
            }
            run.children = children
        }
        if run.mode == .chain, let chainName = run.chainName, let chain = allVisibleChainRecords.first(where: { $0.name == chainName }) {
            let previous = childIndex > 0 ? (children[childIndex - 1].summary ?? "") : ""
            runNativeChainStep(parentSession: parentSession, chain: chain, graphRunID: graphRunID, originalTask: run.task, previous: previous, index: childIndex, useWorktreeIsolation: run.worktreePolicy == "isolated-per-child", completion: nil)
        } else {
            let child = children[childIndex]
            let isolated = run.worktreePolicy == "isolated-per-child"
            let childRun = runNativeSubagent(parentSession: parentSession, agentName: child.agentName, task: child.task ?? run.task, useWorktreeIsolation: isolated, expectedOutcome: isolated ? .editFilesInWorktree : (child.expectedOutcome ?? .reportOnly), requestedOutputPath: child.requestedOutputPath, allowOverwrite: child.allowOverwrite == true) { [weak self] childResult in
                guard let self else { return }
                self.updateNativeGraphChildFromRun(graphRunID, parentSessionID: parentSessionID, index: childIndex, childResult: childResult)
                self.recomputeNativeGraphCompletion(graphRunID, parentSessionID: parentSessionID)
            }
            updateNativeGraphChildFromRun(graphRunID, parentSessionID: parentSessionID, index: childIndex, childResult: childRun)
        }
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
              selectedDiscoveredProject?.path == session.projectPath,
              let changes = githubRepositoryChanges else { return false }
        return changes.conflicted.isEmpty
            && (!changes.staged.isEmpty || !changes.unstaged.isEmpty || !changes.untracked.isEmpty)
    }

    var shouldShowPushSelectedPiAgentSession: Bool {
        guard shouldShowPiAgentGitActions,
              let session = piAgentSessionStore.selectedSession,
              selectedDiscoveredProject?.path == session.projectPath,
              let changes = githubRepositoryChanges else { return false }
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
                    self.prepareRepoChangesForSelectedPiAgentSession()
                }
            } catch {
                await MainActor.run {
                    self.piAgentGitAutomationAction = nil
                    self.piAgentSessionStore.append(.init(sessionID: sessionID, role: .error, title: "Push Failed", text: error.localizedDescription))
                    self.prepareRepoChangesForSelectedPiAgentSession()
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
                    self.prepareRepoChangesForSelectedPiAgentSession()
                }
            } catch {
                await MainActor.run {
                    self.piAgentGitAutomationAction = nil
                    self.piAgentSessionStore.append(.init(sessionID: sessionID, role: .error, title: pushAfterCommit ? "Commit & Push Failed" : "Commit Failed", text: error.localizedDescription))
                    self.prepareRepoChangesForSelectedPiAgentSession()
                }
            }
        }
    }

    func sendPiAgentMessage(_ text: String, mode: PiAgentInputMode, images: [PiAgentImageAttachment] = []) {
        guard let session = piAgentSessionStore.selectedSession else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if images.isEmpty, trimmed == "/compact" || trimmed.hasPrefix("/compact ") {
            let instructions = trimmed.hasPrefix("/compact ") ? String(trimmed.dropFirst("/compact ".count)) : nil
            piAgentRunner.compact(session: session, customInstructions: instructions)
            return
        }
        schedulePiAgentTitleGenerationIfNeeded(for: session, firstMessage: trimmed)
        if !piAgentRunner.isRunning(sessionID: session.id), mode == .prompt {
            piAgentRunner.resume(session: session, initialPrompt: text, images: images)
            isPiAgentInspectorPresented = selectedSidebarItem != .agent
            return
        }
        piAgentRunner.send(text, mode: mode, to: session.id, images: images)
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
            let levels = supportedPiAgentThinkingLevels(session: session, provider: provider ?? session.modelProvider, modelID: modelID ?? session.model)
            if !levels.contains(currentLevel == "none" ? "off" : currentLevel) {
                piAgentRunner.setThinkingLevel(sessionID: session.id, level: levels.first ?? "off")
            }
        }
    }

    func cyclePiAgentModelForSelectedSession() {
        guard let sessionID = piAgentSessionStore.selectedSession?.id else { return }
        piAgentRunner.cycleModel(sessionID: sessionID)
    }

    func setPiAgentThinkingLevelForSelectedSession(_ level: String) {
        guard let session = piAgentSessionStore.selectedSession else { return }
        let normalized = level == "none" ? "off" : level
        let levels = supportedPiAgentThinkingLevels(session: session, provider: session.modelOverrideProvider ?? session.modelProvider, modelID: session.modelOverrideID ?? session.model)
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
        if let provider, let model {
            return enabledAvailableModels.first { $0.provider == provider && $0.model == model }
                ?? enabledAvailableModels.first { $0.model == model }
                ?? enabledAvailableModels.first
        }
        if let model {
            return enabledAvailableModels.first { $0.identifier == model || $0.model == model } ?? enabledAvailableModels.first
        }
        return enabledAvailableModels.first
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
            return true
        } catch {
            githubLastError = "Could not update Pi settings: \(error.localizedDescription)"
            return false
        }
    }

    private func piRuntimeSettingsObject() -> [String: Any]? {
        guard let data = try? Data(contentsOf: piRuntimeSettingsURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private var piRuntimeSettingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/settings.json")
    }

    private func nonEmptyPiSetting(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func supportedPiAgentThinkingLevels(session: PiAgentSessionRecord, provider: String?, modelID: String?) -> [String] {
        if let provider, let modelID {
            if let runtimeModel = session.availableModels?.first(where: { $0.provider == provider && $0.id == modelID }) {
                if let levels = runtimeModel.supportedThinkingLevels, !levels.isEmpty { return levels }
                if runtimeModel.supportsThinking == false { return ["off"] }
                return []
            }
            if let cached = enabledAvailableModels.first(where: { $0.provider == provider && $0.model == modelID }) {
                if !cached.supportedThinkingLevels.isEmpty { return cached.supportedThinkingLevels }
                return cached.supportsThinking ? [] : ["off"]
            }
        }
        return []
    }

    func cyclePiAgentThinkingLevelForSelectedSession() {
        guard let sessionID = piAgentSessionStore.selectedSession?.id else { return }
        piAgentRunner.cycleThinkingLevel(sessionID: sessionID)
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

    func prepareRepoChangesForSelectedPiAgentSession() {
        guard let session = piAgentSessionStore.selectedSession else { return }
        if selectedProjectPath != session.projectPath {
            setSelectedProject(URL(fileURLWithPath: session.projectPath))
        }
        refreshRepositoryChanges(preservingDiffSelection: true)
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

    func setPiAgentThinkingDisplayMode(_ mode: PiAgentThinkingDisplayMode) {
        guard appSettingsController.setPiAgentThinkingDisplayMode(mode) else { return }
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

    func setShowContextSmartZoneHint(_ isEnabled: Bool) {
        guard appSettingsController.setShowContextSmartZoneHint(isEnabled) else { return }
        syncAppSettings()
    }

    func setAutoGeneratePiAgentSessionTitles(_ isEnabled: Bool) {
        guard appSettingsController.setAutoGeneratePiAgentSessionTitles(isEnabled) else { return }
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
        configurePiAgentIdleParking()
        configurePiAgentTranscriptMemory()
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

    private var allDisplayAgents: [EffectiveAgentRecord] {
        var byID: [EffectiveAgentRecord.ID: EffectiveAgentRecord] = [:]
        for agent in snapshot.effectiveAgents { byID[agent.id] = agent }
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
        filteredAgents.first(where: { $0.id == selectedAgentID }) ?? (snapshot.effectiveAgents + libraryOnlyEffectiveAgents).first(where: { $0.id == selectedAgentID })
    }

    private var libraryOnlyEffectiveAgents: [EffectiveAgentRecord] {
        let effectiveNames = Set(snapshot.effectiveAgents.map(\.name))
        return snapshot.libraryAgents
            .filter { !effectiveNames.contains($0.name) }
            .map { libraryDisplayAgent(from: $0, projectRoot: snapshot.projectRoot) }
    }

    private var projectAssignedLibraryAgentsForAggregateView: [EffectiveAgentRecord] {
        guard snapshot.projectRoot == nil else { return [] }
        let effectiveNames = Set(snapshot.effectiveAgents.map(\.name))
        let libraryByName = Dictionary(uniqueKeysWithValues: snapshot.libraryAgents.map { ($0.name, $0) })
        let assignedNames = Set(allProjectSnapshots.values.flatMap(\.projectAgents).map(\.name))
        let libraryNames = Set(snapshot.libraryAgents.map(\.name))
        return assignedNames
            .filter { !effectiveNames.contains($0) && libraryNames.contains($0) }
            .compactMap { libraryByName[$0] }
            .map { libraryDisplayAgent(from: $0, projectRoot: nil) }
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

    var selectedChain: ChainRecord? {
        allVisibleChainRecords.first(where: { $0.id == selectedChainID })
    }

    var allVisibleAgentRecords: [AgentRecord] {
        let activeCustom = snapshot.effectiveAgents.compactMap { $0.projectCustom ?? $0.globalCustom }
        return deduplicateByID(activeCustom + snapshot.libraryAgents)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var allVisibleChainRecords: [ChainRecord] {
        var byName: [String: ChainRecord] = [:]
        for chain in snapshot.chains {
            if shouldReplaceChain(existing: byName[chain.name], candidate: chain) {
                byName[chain.name] = chain
            }
        }
        for chain in snapshot.libraryChains where byName[chain.name] == nil {
            byName[chain.name] = chain
        }
        return Array(byName.values)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func shouldReplaceChain(existing: ChainRecord?, candidate: ChainRecord) -> Bool {
        guard let existing else { return true }
        return chainPrecedence(candidate.source.kind) >= chainPrecedence(existing.source.kind)
    }

    private func chainPrecedence(_ kind: ResourceScopeKind) -> Int {
        switch kind {
        case .project: return 4
        case .legacyProject: return 3
        case .global: return 2
        case .library: return 1
        default: return 0
        }
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
        let tools = [
            "read", "grep", "find", "ls", "bash",
            "edit", "write", "ask_user",
            "web_search", "fetch_content", "get_search_content"
        ]

        let explicitTools = scopeSnapshot.effectiveAgents.flatMap { $0.resolved.tools ?? [] }
        return Array(Set(tools + explicitTools))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func availableModelIdentifiers() -> [String] {
        enabledAvailableModels.map(\.identifier)
    }

    var selectedProjectName: String {
        projectRootURL?.lastPathComponent ?? "All Projects"
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
        githubConnectionState.isConnected && selectedProjectPath == nil
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
            model: nil,
            fallbackModels: [],
            thinking: nil,
            systemPromptMode: "replace",
            inheritProjectContext: false,
            inheritSkills: false,
            defaultContext: nil,
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

    func makeChainDraft(for chain: ChainRecord) -> ChainEditorDraft {
        ChainEditorDraft(originalName: chain.name, chain: chain)
    }

    func makeNewChainDraft(scope: AgentEditingTarget.CustomAgentScope) -> ChainEditorDraft {
        chainPersistence.makeNewDraft(scope: scope, projectRoot: selectedProjectPath)
    }

    func makeDuplicateChainDraft(from chain: ChainRecord, scope: AgentEditingTarget.CustomAgentScope) -> ChainEditorDraft {
        chainPersistence.makeDuplicateDraft(from: chain, scope: scope, projectRoot: selectedProjectPath)
    }

    func saveChainDraft(_ draft: ChainEditorDraft) throws {
        try chainPersistence.save(draft)
        refreshAfterFileScopedChange(sourceKind: draft.chain.source.kind, filePath: draft.chain.filePath)
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

        Write the reusable prompt template here. Use {argument} where the slash-command argument should be inserted.
        """
        try text.write(to: url, atomically: true, encoding: .utf8)
        refresh(includeModels: false)
        selectedCommandItemID = allVisiblePromptTemplateRecords.first { $0.name == candidate }?.id ?? selectedCommandItemID
    }

    func prompt(_ prompt: PromptTemplateRecord, isEnabledFor project: DiscoveredProject) -> Bool {
        allProjectSnapshots[project.path]?.promptTemplates.contains { $0.name == prompt.name && $0.source.kind == .project } == true
    }

    func assignedProjects(for prompt: PromptTemplateRecord) -> [DiscoveredProject] {
        enabledProjects.filter { self.prompt(prompt, isEnabledFor: $0) }
    }

    func promptIsEnabledGlobally(_ prompt: PromptTemplateRecord) -> Bool {
        globalSnapshot.promptTemplates.contains { $0.name == prompt.name && $0.source.kind == .global }
    }

    func setPrompt(_ prompt: PromptTemplateRecord, enabled: Bool, for project: DiscoveredProject) throws {
        if enabled { try addPrompt(prompt, toProjectPath: project.path) }
        else { try removeManagedPromptLink(projectPromptLinkURL(name: prompt.name, projectPath: project.path)) }
        refresh(includeModels: false, scanAllProjects: false, extraProjectPathsToScan: [project.path])
    }

    func enablePromptGlobally(_ prompt: PromptTemplateRecord) throws {
        let libraryURL = try ensureLibraryPrompt(for: prompt)
        try createPromptSymlink(from: globalPromptLinkURL(name: prompt.name), to: libraryURL)
        try removeProjectVisibility(forPromptNamed: prompt.name)
        refresh(includeModels: false)
    }

    func disablePromptGlobally(_ prompt: PromptTemplateRecord) throws {
        if prompt.source.kind == .global {
            _ = try ensureLibraryPrompt(for: prompt)
        } else if let globalRecord = globalSnapshot.promptTemplates.first(where: { $0.name == prompt.name && $0.source.kind == .global }) {
            _ = try ensureLibraryPrompt(for: globalRecord)
        }
        try removeManagedPromptLinkIfExists(globalPromptLinkURL(name: prompt.name))
        refresh(includeModels: false)
    }

    func movePromptToLibrary(_ prompt: PromptTemplateRecord) throws {
        _ = try ensureLibraryPrompt(for: prompt)
        refresh(includeModels: false)
    }

    private func addPrompt(_ prompt: PromptTemplateRecord, toProjectPath projectPath: String) throws {
        let libraryURL = try ensureLibraryPrompt(for: prompt)
        try removeGlobalVisibility(forPromptNamed: prompt.name)
        try createPromptSymlink(from: projectPromptLinkURL(name: prompt.name, projectPath: projectPath), to: libraryURL)
    }

    func agent(_ agent: AgentRecord, isEnabledFor project: DiscoveredProject) -> Bool {
        allProjectSnapshots[project.path]?.projectAgents.contains { $0.name == agent.name } == true
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
            guard let projectSnapshot = allProjectSnapshots[project.path] else {
                return AgentSkillVisibilityIssue(project: project, missingSkills: explicitSkills)
            }
            let visibleSkillNames = Set((projectSnapshot.skills + projectSnapshot.librarySkills).map(\.name))
            let missingSkills = explicitSkills.filter { !visibleSkillNames.contains($0) }
            guard !missingSkills.isEmpty else { return nil }
            return AgentSkillVisibilityIssue(project: project, missingSkills: missingSkills)
        }
    }

    func agentIsEnabledGlobally(_ agent: AgentRecord) -> Bool {
        globalSnapshot.globalAgents.contains { $0.name == agent.name }
    }

    func setAgent(_ agent: AgentRecord, enabled: Bool, for project: DiscoveredProject) throws {
        if enabled { try addAgent(agent, toProjectPath: project.path) }
        else { try removeManagedFileLink(projectAgentLinkURL(name: agent.name, projectPath: project.path)) }
        refresh(includeModels: false, scanAllProjects: false, extraProjectPathsToScan: [project.path])
    }

    func enableAgentGlobally(_ agent: AgentRecord) throws {
        let libraryURL = try ensureLibraryAgent(for: agent)
        try createManagedSymlink(from: globalAgentLinkURL(name: agent.name), to: libraryURL)
        try removeProjectVisibility(forAgentNamed: agent.name)
        refresh(includeModels: false)
    }

    func disableAgentGlobally(_ agent: AgentRecord) throws {
        if agent.source.kind == .global {
            _ = try ensureLibraryAgent(for: agent)
        } else if let globalRecord = globalSnapshot.globalAgents.first(where: { $0.name == agent.name }) {
            _ = try ensureLibraryAgent(for: globalRecord)
        }
        try removeGlobalVisibility(forAgentNamed: agent.name)
        refresh(includeModels: false)
    }

    func moveAgentToLibrary(_ agent: AgentRecord) throws {
        _ = try ensureLibraryAgent(for: agent)
        refresh(includeModels: false)
    }

    private func addAgent(_ agent: AgentRecord, toProjectPath projectPath: String) throws {
        let libraryURL = try ensureLibraryAgent(for: agent)
        try removeGlobalVisibility(forAgentNamed: agent.name)
        try createManagedSymlink(from: projectAgentLinkURL(name: agent.name, projectPath: projectPath), to: libraryURL)
    }

    func chain(_ chain: ChainRecord, isEnabledFor project: DiscoveredProject) -> Bool {
        allProjectSnapshots[project.path]?.chains.contains { $0.name == chain.name && $0.source.kind == .project } == true
    }

    func assignedProjects(for chain: ChainRecord) -> [DiscoveredProject] {
        enabledProjects.filter { self.chain(chain, isEnabledFor: $0) }
    }

    func chainIsEnabledGlobally(_ chain: ChainRecord) -> Bool {
        globalSnapshot.chains.contains { $0.name == chain.name && $0.source.kind == .global }
    }

    func setChain(_ chain: ChainRecord, enabled: Bool, for project: DiscoveredProject) throws {
        if enabled { try addChain(chain, toProjectPath: project.path) }
        else { try removeManagedFileLink(projectChainLinkURL(name: chain.name, projectPath: project.path)) }
        refresh(includeModels: false, scanAllProjects: false, extraProjectPathsToScan: [project.path])
    }

    func enableChainGlobally(_ chain: ChainRecord) throws {
        let libraryURL = try ensureLibraryChain(for: chain)
        try createManagedSymlink(from: globalChainLinkURL(name: chain.name), to: libraryURL)
        try removeProjectVisibility(forChainNamed: chain.name)
        refresh(includeModels: false)
    }

    func disableChainGlobally(_ chain: ChainRecord) throws {
        if chain.source.kind == .global {
            _ = try ensureLibraryChain(for: chain)
        } else if let globalRecord = globalSnapshot.chains.first(where: { $0.name == chain.name && $0.source.kind == .global }) {
            _ = try ensureLibraryChain(for: globalRecord)
        }
        try removeManagedFileLinkIfExists(globalChainLinkURL(name: chain.name))
        refresh(includeModels: false)
    }

    func moveChainToLibrary(_ chain: ChainRecord) throws {
        _ = try ensureLibraryChain(for: chain)
        refresh(includeModels: false)
    }

    private func addChain(_ chain: ChainRecord, toProjectPath projectPath: String) throws {
        let libraryURL = try ensureLibraryChain(for: chain)
        try removeGlobalVisibility(forChainNamed: chain.name)
        try createManagedSymlink(from: projectChainLinkURL(name: chain.name, projectPath: projectPath), to: libraryURL)
    }

    func addSkillToSelectedProject(_ skill: SkillRecord) throws {
        guard let selectedProjectPath else { throw CocoaError(.fileNoSuchFile) }
        try addSkill(skill, toProjectPath: selectedProjectPath)
    }

    func removeSkillFromSelectedProject(_ skill: SkillRecord) throws {
        guard let selectedProjectPath else { throw CocoaError(.fileNoSuchFile) }
        try removeSkill(skill, fromProjectPath: selectedProjectPath)
    }

    func setSkill(_ skill: SkillRecord, enabled: Bool, for project: DiscoveredProject) throws {
        if enabled {
            try addSkill(skill, toProjectPath: project.path)
        } else {
            try removeSkill(skill, fromProjectPath: project.path)
        }
    }

    func skill(_ skill: SkillRecord, isEnabledFor project: DiscoveredProject) -> Bool {
        allProjectSnapshots[project.path]?.skills.contains { $0.name == skill.name && $0.source.kind == .project } == true
    }

    func assignedProjects(for skill: SkillRecord) -> [DiscoveredProject] {
        enabledProjects.filter { self.skill(skill, isEnabledFor: $0) }
    }

    private func addSkill(_ skill: SkillRecord, toProjectPath projectPath: String) throws {
        let libraryURL = try ensureLibrarySkill(for: skill)
        try removeGlobalVisibility(forSkillNamed: skill.name)
        let linkURL = URL(fileURLWithPath: projectPath)
            .appendingPathComponent(".pi/skills", isDirectory: true)
            .appendingPathComponent(skill.name, isDirectory: true)
        try createSkillSymlink(from: linkURL, to: libraryURL)
        refresh(includeModels: false, scanAllProjects: false, extraProjectPathsToScan: [projectPath])
        selectedSkillID = allVisibleSkillRecords.first { $0.name == skill.name }?.id ?? selectedSkillID
    }

    private func removeSkill(_ skill: SkillRecord, fromProjectPath projectPath: String) throws {
        try removeManagedSkillLink(URL(fileURLWithPath: projectPath).appendingPathComponent(".pi/skills/", isDirectory: true).appendingPathComponent(skill.name, isDirectory: true))
        refresh(includeModels: false, scanAllProjects: false, extraProjectPathsToScan: [projectPath])
        selectedSkillID = allVisibleSkillRecords.first { $0.name == skill.name }?.id ?? selectedSkillID
    }

    func enableSkillGlobally(_ skill: SkillRecord) throws {
        let libraryURL = try ensureLibrarySkill(for: skill)
        let linkURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/skills", isDirectory: true).appendingPathComponent(skill.name, isDirectory: true)
        if !FileManager.default.fileExists(atPath: linkURL.path) {
            try createSkillSymlink(from: linkURL, to: libraryURL)
        }
        try removeProjectVisibility(forSkillNamed: skill.name)
        refresh(includeModels: false)
    }

    func disableSkillGlobally(_ skill: SkillRecord) throws {
        let globalURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/skills", isDirectory: true).appendingPathComponent(skill.name, isDirectory: true)
        if (try? globalURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            try FileManager.default.removeItem(at: globalURL)
        } else if skill.source.kind == .global {
            _ = try ensureLibrarySkill(for: skill)
        } else {
            throw CocoaError(.fileWriteNoPermission)
        }
        refresh(includeModels: false)
    }

    func skillIsEnabledGlobally(_ skill: SkillRecord) -> Bool {
        snapshot.skills.contains { $0.name == skill.name && $0.source.kind == .global }
    }

    func skillIsEnabledForSelectedProject(_ skill: SkillRecord) -> Bool {
        snapshot.skills.contains { $0.name == skill.name && $0.source.kind == .project }
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

    private func ensureLibraryChain(for chain: ChainRecord) throws -> URL {
        let libraryRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/agent-library/chains", isDirectory: true)
        let libraryURL = libraryRoot.appendingPathComponent("\(chain.name).chain.md")
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: libraryURL.path) { return libraryURL }

        let sourceURL = URL(fileURLWithPath: chain.filePath)
        if chain.source.kind == .global {
            try fileManager.moveItem(at: sourceURL, to: libraryURL)
        } else if chain.source.kind == .library {
            return sourceURL
        } else {
            try fileManager.copyItem(at: sourceURL, to: libraryURL)
        }
        return libraryURL
    }

    private func createManagedSymlink(from linkURL: URL, to targetURL: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: linkURL.path) {
            guard isManagedAgentLibrarySymlink(linkURL) else { throw CocoaError(.fileWriteFileExists) }
            try fileManager.removeItem(at: linkURL)
        }
        try fileManager.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)
    }

    private func removeManagedFileLink(_ linkURL: URL) throws {
        guard FileManager.default.fileExists(atPath: linkURL.path) else { return }
        guard isManagedAgentLibrarySymlink(linkURL) else { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.removeItem(at: linkURL)
    }

    private func isManagedAgentLibrarySymlink(_ url: URL) -> Bool {
        let fileManager = FileManager.default
        guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true,
              let destination = try? fileManager.destinationOfSymbolicLink(atPath: url.path) else { return false }
        let destinationURL = URL(fileURLWithPath: destination, relativeTo: url.deletingLastPathComponent()).standardizedFileURL
        let libraryRoot = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/agent-library", isDirectory: true).standardizedFileURL.path
        return destinationURL.path.hasPrefix(libraryRoot + "/")
    }

    private func removeGlobalVisibility(forAgentNamed name: String) throws {
        for url in globalAgentLinkURLs(name: name) {
            try removeManagedFileLinkIfExists(url)
        }
    }
    private func removeProjectVisibility(forAgentNamed name: String) throws { for project in enabledProjects { try removeManagedFileLinkIfExists(projectAgentLinkURL(name: name, projectPath: project.path)) } }
    private func removeGlobalVisibility(forChainNamed name: String) throws { try removeManagedFileLinkIfExists(globalChainLinkURL(name: name)) }
    private func removeProjectVisibility(forChainNamed name: String) throws { for project in enabledProjects { try removeManagedFileLinkIfExists(projectChainLinkURL(name: name, projectPath: project.path)) } }

    private func removeManagedFileLinkIfExists(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try removeManagedFileLink(url)
    }

    private func globalAgentLinkURL(name: String) -> URL {
        let legacyGlobal = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".agents", isDirectory: true)
        if FileManager.default.fileExists(atPath: legacyGlobal.path) {
            return legacyGlobal.appendingPathComponent("\(name).md")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/agents/\(name).md")
    }

    private func globalAgentLinkURLs(name: String) -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(".agents/\(name).md"),
            home.appendingPathComponent(".pi/agent/agents/\(name).md")
        ]
    }

    private func projectAgentLinkURL(name: String, projectPath: String) -> URL { URL(fileURLWithPath: projectPath).appendingPathComponent(".pi/agents/\(name).md") }
    private func globalChainLinkURL(name: String) -> URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/chains/\(name).chain.md") }
    private func projectChainLinkURL(name: String, projectPath: String) -> URL { URL(fileURLWithPath: projectPath).appendingPathComponent(".pi/chains/\(name).chain.md") }

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

    private func createPromptSymlink(from linkURL: URL, to targetURL: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: linkURL.path) {
            guard isManagedPromptLibrarySymlink(linkURL) else { throw CocoaError(.fileWriteFileExists) }
            try fileManager.removeItem(at: linkURL)
        }
        try fileManager.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)
    }

    private func removeManagedPromptLink(_ linkURL: URL) throws {
        guard FileManager.default.fileExists(atPath: linkURL.path) else { return }
        guard isManagedPromptLibrarySymlink(linkURL) else { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.removeItem(at: linkURL)
    }

    private func removeManagedPromptLinkIfExists(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try removeManagedPromptLink(url)
    }

    private func isManagedPromptLibrarySymlink(_ url: URL) -> Bool {
        let fileManager = FileManager.default
        guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true,
              let destination = try? fileManager.destinationOfSymbolicLink(atPath: url.path) else { return false }
        let destinationURL = URL(fileURLWithPath: destination, relativeTo: url.deletingLastPathComponent()).standardizedFileURL
        let libraryRoot = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/prompt-library", isDirectory: true).standardizedFileURL.path
        return destinationURL.path.hasPrefix(libraryRoot + "/")
    }

    private func removeGlobalVisibility(forPromptNamed name: String) throws { try removeManagedPromptLinkIfExists(globalPromptLinkURL(name: name)) }
    private func removeProjectVisibility(forPromptNamed name: String) throws { for project in enabledProjects { try removeManagedPromptLinkIfExists(projectPromptLinkURL(name: name, projectPath: project.path)) } }
    private func globalPromptLinkURL(name: String) -> URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/prompts/\(name).md") }
    private func projectPromptLinkURL(name: String, projectPath: String) -> URL { URL(fileURLWithPath: projectPath).appendingPathComponent(".pi/prompts/\(name).md") }

    private func ensureLibrarySkill(for skill: SkillRecord) throws -> URL {
        let libraryRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/skill-library", isDirectory: true)
        let libraryURL = libraryRoot.appendingPathComponent(skill.name, isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: libraryURL.appendingPathComponent("SKILL.md").path) { return libraryURL }

        let sourceURL = skillRootURL(for: skill)
        var isDirectory: ObjCBool = false
        fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory)

        if isDirectory.boolValue {
            if skill.source.kind == .global {
                try fileManager.moveItem(at: sourceURL, to: libraryURL)
            } else if skill.source.kind == .library {
                return sourceURL
            } else {
                try fileManager.copyItem(at: sourceURL, to: libraryURL)
            }
        } else {
            try fileManager.createDirectory(at: libraryURL, withIntermediateDirectories: true)
            let destinationFile = libraryURL.appendingPathComponent("SKILL.md")
            if skill.source.kind == .global {
                try fileManager.moveItem(at: sourceURL, to: destinationFile)
            } else if skill.source.kind == .library {
                try fileManager.copyItem(at: sourceURL, to: destinationFile)
            } else {
                try fileManager.copyItem(at: sourceURL, to: destinationFile)
            }
        }
        return libraryURL
    }

    private func createSkillSymlink(from linkURL: URL, to targetURL: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard !fileManager.fileExists(atPath: linkURL.path) else { throw CocoaError(.fileWriteFileExists) }
        try fileManager.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)
    }

    private func removeManagedSkillLink(_ linkURL: URL) throws {
        let values = try linkURL.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink == true else { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.removeItem(at: linkURL)
    }

    private func removeGlobalVisibility(forSkillNamed skillName: String) throws {
        let fileManager = FileManager.default
        for globalSkill in snapshot.skills where globalSkill.name == skillName && globalSkill.source.kind == .global {
            let url = skillRootURL(for: globalSkill)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                try fileManager.removeItem(at: url)
            }
        }
    }

    private func removeProjectVisibility(forSkillNamed skillName: String) throws {
        let fileManager = FileManager.default
        for project in enabledProjects {
            let url = URL(fileURLWithPath: project.path).appendingPathComponent(".pi/skills", isDirectory: true).appendingPathComponent(skillName, isDirectory: true)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                try fileManager.removeItem(at: url)
            }
        }
    }

    private func skillRootURL(for skill: SkillRecord) -> URL {
        let fileURL = URL(fileURLWithPath: skill.filePath)
        if fileURL.lastPathComponent == "SKILL.md" { return fileURL.deletingLastPathComponent() }
        return fileURL
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

    func convertChain(_ chain: ChainRecord, to scope: AgentEditingTarget.CustomAgentScope) throws {
        try chainPersistence.convert(chain, to: scope, projectRoot: selectedProjectPath)
        refresh(includeModels: false)
    }

    func makeEnvDraft(for record: EnvKeyRecord) -> EnvEditorDraft {
        envPersistence.makeDraft(for: record)
    }

    func makeNewEnvDraft(scope: AgentEditingTarget.CustomAgentScope) -> EnvEditorDraft {
        envPersistence.makeNewDraft(scope: scope, projectRoot: selectedProjectPath)
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
        let explicitIDs = Set(agentsExplicitlyUsingSkill(skill).map(\.id))
        return snapshot.effectiveAgents
            .filter { agent in
                !explicitIDs.contains(agent.id) &&
                (agent.resolved.inheritSkills ?? false) &&
                skillVisible(to: agent, skill: skill)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func makeAggregateSnapshot() -> ScanSnapshot {
        let enabledProjectPaths = Set(enabledProjects.map(\.path))
        let projectSnapshots = allProjectSnapshots
            .filter { enabledProjectPaths.contains($0.key) }
            .map(\.value)
        let projectSpecificEffectiveAgents = projectSnapshots
            .flatMap(\.effectiveAgents)
            .filter { $0.projectCustom != nil || $0.projectOverride != nil }

        let chains = deduplicateByID(globalSnapshot.chains + projectSnapshots.flatMap(\.chains))
        let libraryAgents = deduplicateByID(globalSnapshot.libraryAgents + projectSnapshots.flatMap(\.libraryAgents))
        let libraryChains = deduplicateByID(globalSnapshot.libraryChains + projectSnapshots.flatMap(\.libraryChains))
        let skills = deduplicateByID(globalSnapshot.skills + projectSnapshots.flatMap(\.skills))
        let librarySkills = deduplicateByID(globalSnapshot.librarySkills + projectSnapshots.flatMap(\.librarySkills))
        let promptTemplates = deduplicateByID(globalSnapshot.promptTemplates + projectSnapshots.flatMap(\.promptTemplates))
        let libraryPromptTemplates = deduplicateByID(globalSnapshot.libraryPromptTemplates + projectSnapshots.flatMap(\.libraryPromptTemplates))
        let envKeys = deduplicateByID(globalSnapshot.envKeys + projectSnapshots.flatMap(\.envKeys))
        let warnings = deduplicateByID(globalSnapshot.warnings + projectSnapshots.flatMap(\.warnings))
        let settings = Array(Set(globalSnapshot.settings + projectSnapshots.flatMap(\.settings))).sorted { $0.path < $1.path }

        return ScanSnapshot(
            projectRoot: nil,
            builtinAgents: globalSnapshot.builtinAgents,
            globalAgents: globalSnapshot.globalAgents,
            projectAgents: deduplicateByID(projectSnapshots.flatMap(\.projectAgents)),
            legacyProjectAgents: deduplicateByID(projectSnapshots.flatMap(\.legacyProjectAgents)),
            effectiveAgents: globalSnapshot.effectiveAgents + projectSpecificEffectiveAgents,
            chains: chains,
            libraryAgents: libraryAgents,
            libraryChains: libraryChains,
            skills: skills,
            librarySkills: librarySkills,
            promptTemplates: promptTemplates,
            libraryPromptTemplates: libraryPromptTemplates,
            settings: settings,
            envKeys: envKeys,
            warnings: warnings
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

        Task.detached(priority: .utility) {
            let models = await PiModelDiscoveryService().loadAvailableModels()
            await MainActor.run {
                self.availableModels = models
                self.seedPiAgentSessionsWithAvailableModels(models)
                self.modelsLastUpdatedAt = Date()
                self.isRefreshingModels = false
            }
        }
    }

    private func ensurePiAgentModels(for sessionID: UUID) {
        guard let session = piAgentSessionStore.sessions.first(where: { $0.id == sessionID }),
              session.availableModels?.isEmpty ?? true else { return }
        let enabledModels = enabledAvailableModels
        if !enabledModels.isEmpty {
            piAgentSessionStore.updateAvailableModelsForSessions([sessionID], options: piAgentModelOptions(from: enabledModels))
            return
        }

        Task.detached(priority: .utility) { [weak self] in
            let models = await PiModelDiscoveryService().loadAvailableModels()
            await MainActor.run {
                guard let self, !models.isEmpty else { return }
                self.availableModels = models
                self.seedPiAgentSessionsWithAvailableModels(models)
                self.modelsLastUpdatedAt = Date()
            }
        }
    }

    private func piAgentModelOptionsForNewSession() -> [PiAgentModelOption]? {
        let models = enabledAvailableModels
        return models.isEmpty ? nil : piAgentModelOptions(from: models)
    }

    private func seedPiAgentSessionsWithAvailableModels(_ models: [AvailableModel], overwriteExisting: Bool = false) {
        let enabledModels = models.filter { !appSettings.disabledModelIdentifiers.contains($0.identifier) }
        guard !enabledModels.isEmpty || overwriteExisting else { return }
        let options = piAgentModelOptions(from: enabledModels)
        piAgentSessionStore.updateAvailableModelsForSessions(options: options, overwriteExisting: overwriteExisting)
    }

    private func piAgentModelOptions(from models: [AvailableModel]) -> [PiAgentModelOption] {
        models.map { model in
            PiAgentModelOption(
                provider: model.provider,
                id: model.model,
                name: nil,
                contextWindow: Self.compactModelNumber(model.contextWindow),
                maxOutput: Self.compactModelNumber(model.maxOutput),
                supportsThinking: model.supportsThinking,
                supportedThinkingLevels: model.supportedThinkingLevels,
                supportsImages: model.supportsImages
            )
        }
    }

    private static func compactModelNumber(_ value: String) -> Int? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let multiplier: Double
        let numericText: String
        if trimmed.lowercased().hasSuffix("k") {
            multiplier = 1_000
            numericText = String(trimmed.dropLast())
        } else if trimmed.lowercased().hasSuffix("m") {
            multiplier = 1_000_000
            numericText = String(trimmed.dropLast())
        } else {
            multiplier = 1
            numericText = trimmed
        }
        guard let number = Double(numericText) else { return nil }
        return Int(number * multiplier)
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
        guard autoRefreshCancellable == nil, !didShutdown else { return }
        autoRefreshCancellable = Timer.publish(every: 2, tolerance: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refreshIfWatchedFilesChanged()
            }
    }

    private func stopAutoRefresh(cancelPendingScan: Bool) {
        autoRefreshCancellable?.cancel()
        autoRefreshCancellable = nil
        if cancelPendingScan {
            watchFingerprintTask?.cancel()
            watchFingerprintTask = nil
        }
    }

    private func refreshIfWatchedFilesChanged() {
        guard watchFingerprintTask == nil else { return }
        let previousFingerprint = lastWatchFingerprint
        let shouldScanAllProjects = false
        let projectsToWatch = selectedDiscoveredProject.map { [$0] } ?? []
        let urls = AppRefreshService.watchedURLs(projects: projectsToWatch, snapshot: snapshot)
        watchFingerprintTask = Task.detached(priority: .utility) { [weak self, previousFingerprint, shouldScanAllProjects, urls] in
            let fingerprint = FileWatchFingerprint.make(urls: urls)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, !Task.isCancelled else { return }
                self.watchFingerprintTask = nil
                guard fingerprint != previousFingerprint else { return }
                self.lastWatchFingerprint = fingerprint
                self.refresh(includeModels: false, scanAllProjects: shouldScanAllProjects)
            }
        }
    }

}
