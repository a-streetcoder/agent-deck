import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

@MainActor
final class AppViewModel: ObservableObject {
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
    @Published var githubIsRefreshingEverything = false
    @Published var githubLastError: String?
    @Published var githubLastStatusCheckAt: Date?
    @Published var appSettings: AppSettings = AppSettingsStore.shared.settings
    @Published var isPiAgentInspectorPresented = false
    @Published var showPiAgentAttentionOnly = false
    @Published private(set) var piAgentPendingComposerText: String?
    let piAgentSessionStore: PiAgentSessionStore

    private let scanner = PiScanner()
    private let projectDiscovery = ProjectDiscovery()
    private let agentPersistence = AgentPersistence()
    private let chainPersistence = ChainPersistence()
    private let envPersistence = EnvPersistence()
    private let subagentConfigPersistence = SubagentConfigPersistence()
    private let projectPreferencesStore = ProjectPreferencesStore.shared
    private let appSettingsStore = AppSettingsStore.shared
    private let gitHubAuthService: GitHubAuthService = GitHubCLIAuthService()
    private let gitRepositoryService = GitRepositoryService()
    private let piAgentRunner: PiAgentRunnerService
    private var globalSnapshot: ScanSnapshot = .empty
    private var gitHubSession: GitHubSession?
    private(set) var projectRootURL: URL?
    private var autoRefreshCancellable: AnyCancellable?
    private var lastWatchFingerprint: String = ""
    private var isRefreshingModels = false
    private var githubProjectBoardRequestID = 0
    private var githubRepositoryChangesRequestID = 0
    private var githubIssueDetailRequestID = 0
    private let lastSelectedProjectDefaultsKey = "lastSelectedProjectPath"
    private let lastExternalSkillsDirectoryDefaultsKey = "lastExternalSkillsDirectoryPath"
    private var githubProjectBoardCacheKey: String?
    private var githubProjectBoardFetchedAt: Date?
    private var pendingPiAgentNotificationTasks: [UUID: Task<Void, Never>] = [:]
    private let piAgentNotificationDelay: TimeInterval = 60

    init() {
        let piAgentSessionStore = PiAgentSessionStore()
        self.piAgentSessionStore = piAgentSessionStore
        self.piAgentRunner = PiAgentRunnerService(store: piAgentSessionStore)
        appSettings = appSettingsStore.settings
        selectedProjectPath = UserDefaults.standard.string(forKey: lastSelectedProjectDefaultsKey)
        piAgentSessionStore.newSessionSubagentsEnabled = areSubagentsEnabledForNewSessions
        refresh(includeModels: true)
        lastWatchFingerprint = watchFingerprint()
        piAgentRunner.onTurnFinished = { [weak self] sessionID in
            Task { @MainActor in self?.handlePiAgentTurnFinished(sessionID) }
        }
        startAutoRefresh()

        Task {
            await refreshGitHubStatus()
            if case .available = githubConnectionState {
                await connectGitHubUsingCLIIfNeeded()
            }
        }
    }

    func refresh(includeModels: Bool = false) {
        let previousAgentID = selectedAgentID
        let previousChainID = selectedChainID
        let previousSkillID = selectedSkillID
        let previousCommandItemID = selectedCommandItemID

        projectPreferencesByPath = projectPreferencesStore.preferencesByPath
        discoveredProjects = projectDiscovery.discoverProjects(
            rootDirectoryURL: configuredProjectsRootURL,
            additionalProjectPaths: Array(projectPreferencesByPath.keys),
            preferencesByPath: projectPreferencesByPath
        )
        let enabledProjects = discoveredProjects.filter { projectPreference(for: $0.path).isEnabled }
        globalSnapshot = scanner.scan(projectRoot: nil)
        allProjectSnapshots = Dictionary(uniqueKeysWithValues: enabledProjects.map { project in
            (project.path, scanner.scan(projectRoot: project.url))
        })

        if let selectedProjectPath,
           let matchingProject = discoveredProjects.first(where: { $0.path == selectedProjectPath && projectPreference(for: $0.path).isEnabled }) {
            projectRootURL = matchingProject.url
            snapshot = allProjectSnapshots[selectedProjectPath] ?? scanner.scan(projectRoot: matchingProject.url)
        } else {
            projectRootURL = nil
            selectedProjectPath = nil
            persistSelectedProjectPath(nil)
            snapshot = makeAggregateSnapshot()
        }

        selectedAgentID = filteredAgents.contains(where: { $0.id == previousAgentID }) ? previousAgentID : filteredAgents.first?.id
        selectedChainID = allVisibleChainRecords.contains(where: { $0.id == previousChainID }) ? previousChainID : allVisibleChainRecords.first?.id
        selectedSkillID = allVisibleSkillRecords.contains(where: { $0.id == previousSkillID }) ? previousSkillID : allVisibleSkillRecords.first?.id
        let availableCommandItemIDs = Set(snapshot.commands.map(\.id) + allVisiblePromptTemplateRecords.map(\.id))
        selectedCommandItemID = availableCommandItemIDs.contains(previousCommandItemID ?? "") ? previousCommandItemID : (snapshot.commands.first?.id ?? allVisiblePromptTemplateRecords.first?.id)
        lastWatchFingerprint = watchFingerprint()

        piAgentSessionStore.newSessionSubagentsEnabled = areSubagentsEnabledForNewSessions

        if includeModels {
            refreshAvailableModels()
        }
    }

    func chooseProjectRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Project"
        panel.message = "Choose a repo or project root to add to Pi Manager."

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
        panel.message = "Choose a folder whose direct child folders contain SKILL.md files you want to import into the Pi Manager library."
        panel.directoryURL = url ?? suggestedExternalSkillsDirectoryURL

        let handler: (NSApplication.ModalResponse) -> Void = { [weak panel, weak self] response in
            guard response == .OK,
                  let selectedURL = panel?.url?.standardizedFileURL else {
                completion(nil)
                return
            }
            self?.persistLastExternalSkillsDirectoryPath(selectedURL.path)
            completion(selectedURL)
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

        return entries.compactMap { entry in
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: entry.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
            return externalSkillCandidate(at: entry)
        }
        .sorted { lhs, rhs in
            let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return lhs.sourceRootPath < rhs.sourceRootPath
        }
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

        refresh(includeModels: false)
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
        refresh(includeModels: false)
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
        projectPreferencesByPath = projectPreferencesStore.preferencesByPath

        if !isEnabled, selectedProjectPath == project.path {
            projectRootURL = nil
            selectedProjectPath = nil
            persistSelectedProjectPath(nil)
        }

        refresh(includeModels: false)
        refreshGitHubProjectScopedState()
    }

    func setAllProjectsEnabled(_ isEnabled: Bool) {
        let paths = discoveredProjects.map(\.path)
        projectPreferencesStore.setAllEnabled(isEnabled, for: paths)
        projectPreferencesByPath = projectPreferencesStore.preferencesByPath

        if !isEnabled, selectedProjectPath != nil {
            projectRootURL = nil
            selectedProjectPath = nil
            persistSelectedProjectPath(nil)
        }

        refresh(includeModels: false)
        refreshGitHubProjectScopedState()
    }

    func removeProjectFromLibrary(_ project: DiscoveredProject) {
        projectPreferencesStore.setHidden(true, for: project.path)
        projectPreferencesByPath = projectPreferencesStore.preferencesByPath

        if selectedProjectPath == project.path {
            projectRootURL = nil
            selectedProjectPath = nil
            persistSelectedProjectPath(nil)
        }

        refresh(includeModels: false)
        refreshGitHubProjectScopedState()
    }

    func toggleProjectFavorite(_ project: DiscoveredProject) {
        projectPreferencesStore.toggleFavorite(for: project.path)
        projectPreferencesByPath = projectPreferencesStore.preferencesByPath
        refresh(includeModels: false)
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
            projectPreferencesByPath = projectPreferencesStore.preferencesByPath
            refresh(includeModels: false)
        } catch {
            githubLastError = error.localizedDescription
        }
    }

    func clearCustomIcon(for project: DiscoveredProject) {
        projectPreferencesStore.clearCustomIcon(for: project.path)
        projectPreferencesByPath = projectPreferencesStore.preferencesByPath
        refresh(includeModels: false)
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
        githubSelectedDiffFilePath = filePath
        githubSelectedDiffKind = kind
        githubSelectedDiffText = nil
        githubLastError = nil

        Task {
            do {
                let diff = try await self.gitRepositoryService.loadDiff(for: filePath, kind: kind, in: project.url)
                await MainActor.run {
                    self.githubSelectedDiffText = diff.isEmpty ? "No \(kind.rawValue.lowercased()) diff for this file." : diff
                }
            } catch {
                await MainActor.run {
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
                await MainActor.run { self.refreshRepositoryChanges() }
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
                await MainActor.run { self.refreshRepositoryChanges() }
            } catch {
                await MainActor.run { self.githubLastError = error.localizedDescription }
            }
        }
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
                piAgentSessionStore.select(existing.id)
            } else {
                _ = piAgentSessionStore.createSession(
                    kind: .project,
                    title: "Project agent · \(project.name)",
                    project: project,
                    repository: project.gitHubRemote?.nameWithOwner
                )
            }
        }
    }

    func createPiAgentDraftForSelectedProject() {
        let project = piAgentSessionProjectContext()
        selectedSidebarItem = .agent
        isPiAgentInspectorPresented = false
        _ = piAgentSessionStore.createSession(
            kind: .project,
            title: "Draft · \(project.name)",
            project: project,
            repository: project.gitHubRemote?.nameWithOwner
        )
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
        piAgentPendingComposerText = PiIssuePromptBuilder.issuePrompt(detail: detail, project: project)
    }

    func consumePendingPiAgentComposerText() -> String? {
        let pending = piAgentPendingComposerText
        piAgentPendingComposerText = nil
        return pending
    }

    func selectPiAgentSession(_ id: UUID) {
        piAgentSessionStore.select(id)
        acknowledgePiAgentSession(id)
        selectedSidebarItem = .agent
    }

    var piAgentNeedsAttentionCount: Int {
        piAgentSessionStore.sessions.filter(\.needsAttention).count
    }

    func acknowledgePiAgentSession(_ id: UUID) {
        pendingPiAgentNotificationTasks[id]?.cancel()
        pendingPiAgentNotificationTasks[id] = nil
        piAgentSessionStore.updateSession(id) { $0.needsAttention = false }
    }

    private func handlePiAgentTurnFinished(_ sessionID: UUID) {
        guard piAgentSessionStore.sessions.contains(where: { $0.id == sessionID }) else { return }
        guard !isPiAgentSessionActuallyVisible(sessionID) else { return }

        piAgentSessionStore.updateSession(sessionID) { record in
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
        guard session.needsAttention, !isPiAgentSessionActuallyVisible(sessionID) else { return }
        piAgentSessionStore.updateSession(sessionID) { record in
            record.lastNotificationAt = Date()
        }
        sendPiAgentCompletionNotification(for: session)
    }

    private func sendPiAgentCompletionNotification(for session: PiAgentSessionRecord) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Pi Agent needs review"
            content.body = session.displayTitle
            content.userInfo = ["sessionID": session.id.uuidString]
            let request = UNNotificationRequest(identifier: "pi-agent-\(session.id.uuidString)-\(Date().timeIntervalSince1970)", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
    }

    func renamePiAgentSession(_ id: UUID, title: String) {
        piAgentSessionStore.renameSession(id, title: title)
        piAgentRunner.syncSessionName(for: id)
    }

    var canOpenSelectedPiAgentSessionInTerminal: Bool {
        guard let sessionFile = piAgentSessionStore.selectedSession?.piSessionFile else { return false }
        return FileManager.default.fileExists(atPath: sessionFile)
    }

    func openSelectedPiAgentSessionInTerminal() {
        guard let session = piAgentSessionStore.selectedSession,
              let sessionFile = session.piSessionFile else { return }
        guard FileManager.default.fileExists(atPath: sessionFile) else {
            piAgentSessionStore.updateSession(session.id) { record in
                record.lastError = "Pi session file no longer exists."
            }
            return
        }

        let workingDirectory = session.worktreePath ?? session.projectPath
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pi-manager-resume-\(session.id.uuidString)")
            .appendingPathExtension("command")
        let script = """
        #!/bin/zsh
        cd \(shellQuoted(workingDirectory)) || exit 1
        export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
        if command -v pi >/dev/null 2>&1; then
          exec pi --session \(shellQuoted(sessionFile))
        elif [ -x /opt/homebrew/bin/pi ]; then
          exec /opt/homebrew/bin/pi --session \(shellQuoted(sessionFile))
        elif [ -x /usr/local/bin/pi ]; then
          exec /usr/local/bin/pi --session \(shellQuoted(sessionFile))
        else
          echo "Pi CLI not found. Install pi or add it to PATH."
          echo ""
          echo "Command: pi --session \(shellQuoted(sessionFile))"
          read -k 1 "?Press any key to close."
        fi
        """

        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
            openTerminalScript(scriptURL, for: session.id)
        } catch {
            piAgentSessionStore.updateSession(session.id) { record in
                record.lastError = error.localizedDescription
            }
        }
    }

    private func openTerminalScript(_ scriptURL: URL, for sessionID: UUID) {
        guard let terminalPath = appSettings.piAgentTerminalApplicationPath, !terminalPath.isEmpty else {
            guard NSWorkspace.shared.open(scriptURL) else {
                piAgentSessionStore.updateSession(sessionID) { record in
                    record.lastError = "Could not open the default terminal app."
                }
                return
            }
            return
        }

        let terminalURL = URL(fileURLWithPath: terminalPath)
        guard FileManager.default.fileExists(atPath: terminalURL.path) else {
            piAgentSessionStore.updateSession(sessionID) { record in
                record.lastError = "Selected terminal app no longer exists. Choose another app in Settings."
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
        piAgentRunner.resume(session: session)
    }

    func sendPiAgentMessage(_ text: String, mode: PiAgentInputMode, images: [PiAgentImageAttachment] = []) {
        guard let session = piAgentSessionStore.selectedSession else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if images.isEmpty, trimmed == "/compact" || trimmed.hasPrefix("/compact ") {
            let instructions = trimmed.hasPrefix("/compact ") ? String(trimmed.dropFirst("/compact ".count)) : nil
            piAgentRunner.compact(session: session, customInstructions: instructions)
            return
        }
        if !piAgentRunner.isRunning(sessionID: session.id), mode == .prompt {
            piAgentRunner.resume(session: session, initialPrompt: text, images: images)
            isPiAgentInspectorPresented = selectedSidebarItem != .agent
            return
        }
        piAgentRunner.send(text, mode: mode, to: session.id, images: images)
    }

    func compactSelectedPiAgentSession(customInstructions: String? = nil) {
        guard let session = piAgentSessionStore.selectedSession else { return }
        piAgentRunner.compact(session: session, customInstructions: customInstructions)
    }

    func refreshPiAgentControlsForSelectedSession() {
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

    private func supportedPiAgentThinkingLevels(session: PiAgentSessionRecord, provider: String?, modelID: String?) -> [String] {
        if let provider, let modelID {
            if let runtimeModel = session.availableModels?.first(where: { $0.provider == provider && $0.id == modelID }) {
                if let levels = runtimeModel.supportedThinkingLevels, !levels.isEmpty { return levels }
                if runtimeModel.supportsThinking == false { return ["off"] }
                return defaultPiAgentThinkingLevels(provider: provider, modelID: modelID)
            }
            if let cached = availableModels.first(where: { $0.provider == provider && $0.model == modelID }) {
                if !cached.supportedThinkingLevels.isEmpty { return cached.supportedThinkingLevels }
                return cached.supportsThinking ? defaultPiAgentThinkingLevels(provider: provider, modelID: modelID) : ["off"]
            }
        }
        return ["off", "minimal", "low", "medium", "high"]
    }

    private func defaultPiAgentThinkingLevels(provider: String, modelID: String) -> [String] {
        PiModelCapability.supportsXhigh(modelID: modelID)
            ? ["off", "minimal", "low", "medium", "high", "xhigh"]
            : ["off", "minimal", "low", "medium", "high"]
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

    func confirmPiAgentUIRequest(_ request: PiAgentUIRequest, confirmed: Bool) {
        piAgentRunner.confirmExtensionUI(sessionID: request.sessionID, requestID: request.id, confirmed: confirmed)
    }

    func cancelPiAgentUIRequest(_ request: PiAgentUIRequest) {
        piAgentRunner.cancelExtensionUI(sessionID: request.sessionID, requestID: request.id)
    }

    func deletePiAgentSession(_ sessionID: UUID) {
        if piAgentRunner.isRunning(sessionID: sessionID) {
            piAgentRunner.stop(sessionID: sessionID)
        }
        piAgentSessionStore.deleteSession(sessionID)
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
        githubSelectedSection = .repoChanges
        selectedSidebarItem = .github
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
        TimeInterval(max(appSettings.gitHubBoardCacheLifetimeMinutes, 1) * 60)
    }

    var gitHubBoardCacheLifetimeMinutes: Int {
        max(appSettings.gitHubBoardCacheLifetimeMinutes, 1)
    }

    func setGitHubBoardCacheLifetimeMinutes(_ minutes: Int) {
        let normalizedMinutes = max(minutes, 1)
        guard appSettings.gitHubBoardCacheLifetimeMinutes != normalizedMinutes else { return }
        appSettings.gitHubBoardCacheLifetimeMinutes = normalizedMinutes
        appSettingsStore.settings = appSettings
    }

    func chooseProjectsRootDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Folder"
        panel.message = "Choose the folder Pi Manager should scan for projects and use for projectless Pi Agent sessions."
        panel.directoryURL = configuredProjectsRootURL

        guard panel.runModal() == .OK, let url = panel.url else { return }
        setProjectsRootPath(url.path)
    }

    func setProjectsRootPath(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPath = trimmed.isEmpty
            ? ProjectDiscovery.defaultRootDirectoryURL().path
            : URL(fileURLWithPath: trimmed).standardizedFileURL.path
        guard appSettings.projectsRootPath != normalizedPath else { return }
        appSettings.projectsRootPath = normalizedPath
        appSettingsStore.settings = appSettings
        refresh(includeModels: false)
        refreshGitHubProjectScopedState()
    }

    func resetProjectsRootPathToDefault() {
        setProjectsRootPath(ProjectDiscovery.defaultRootDirectoryURL().path)
    }

    func chooseDefaultSkillsImportDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Folder"
        panel.message = "Choose the default folder Pi Manager should open when importing skills."
        panel.directoryURL = suggestedExternalSkillsDirectoryURL

        guard panel.runModal() == .OK, let url = panel.url else { return }
        setDefaultSkillsImportRootPath(url.path)
    }

    func setDefaultSkillsImportRootPath(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPath = trimmed.isEmpty ? nil : URL(fileURLWithPath: trimmed).standardizedFileURL.path
        guard appSettings.defaultSkillsImportRootPath != normalizedPath else { return }
        appSettings.defaultSkillsImportRootPath = normalizedPath
        appSettingsStore.settings = appSettings
    }

    func resetDefaultSkillsImportRootPath() {
        guard appSettings.defaultSkillsImportRootPath != nil else { return }
        appSettings.defaultSkillsImportRootPath = nil
        appSettingsStore.settings = appSettings
    }

    var piAgentTerminalApplicationDisplayName: String {
        guard let path = appSettings.piAgentTerminalApplicationPath, !path.isEmpty else {
            return "macOS default"
        }
        return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }

    var piAgentTerminalApplicationSelectionID: String {
        appSettings.piAgentTerminalApplicationPath ?? TerminalApplicationOption.defaultID
    }

    var piAgentTerminalApplicationOptions: [TerminalApplicationOption] {
        var options = [TerminalApplicationOption(name: "macOS Default", path: nil)]
        let candidates = [
            "/System/Applications/Utilities/Terminal.app",
            "/Applications/Utilities/Terminal.app",
            "/Applications/iTerm.app",
            "/Applications/Warp.app",
            "/Applications/Ghostty.app",
            "/Applications/WezTerm.app",
            "/Applications/Alacritty.app",
            "/Applications/kitty.app",
            "/Applications/Hyper.app"
        ]

        var seen = Set(options.map(\.id))
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            let option = TerminalApplicationOption(name: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent, path: path)
            guard seen.insert(option.id).inserted else { continue }
            options.append(option)
        }

        if let selectedPath = appSettings.piAgentTerminalApplicationPath,
           !seen.contains(selectedPath) {
            options.append(TerminalApplicationOption(name: URL(fileURLWithPath: selectedPath).deletingPathExtension().lastPathComponent, path: selectedPath))
        }

        return options
    }

    func setPiAgentTerminalApplicationSelection(_ selectionID: String) {
        setPiAgentTerminalApplicationPath(selectionID == TerminalApplicationOption.defaultID ? nil : selectionID)
    }

    func choosePiAgentTerminalApplication() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.prompt = "Choose App"
        panel.message = "Choose the terminal app Pi Manager should use when resuming a Pi session in the CLI."
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)

        guard panel.runModal() == .OK, let url = panel.url else { return }
        setPiAgentTerminalApplicationPath(url.path)
    }

    func setPiAgentTerminalApplicationPath(_ path: String?) {
        let normalizedPath = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        appSettings.piAgentTerminalApplicationPath = normalizedPath?.isEmpty == false ? normalizedPath : nil
        appSettingsStore.settings = appSettings
    }

    func resetPiAgentTerminalApplicationToDefault() {
        setPiAgentTerminalApplicationPath(nil)
    }

    func setPiAgentThinkingDisplayMode(_ mode: PiAgentThinkingDisplayMode) {
        guard appSettings.piAgentThinkingDisplayMode != mode else { return }
        appSettings.piAgentThinkingDisplayMode = mode
        appSettingsStore.settings = appSettings
    }

    func togglePiAgentThinkingBlocksVisibility() {
        setPiAgentThinkingDisplayMode(appSettings.piAgentThinkingDisplayMode == .hidden ? .full : .hidden)
    }

    var isSubagentsToggleExtensionInstalled: Bool {
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/extensions")
        let candidates = [
            base.appendingPathComponent("subagents-toggle.ts"),
            base.appendingPathComponent("subagents-toggle/index.ts")
        ]
        return candidates.contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    var canShowPiAgentSubagentsToggle: Bool {
        isSubagentsToggleExtensionInstalled && isPackageInstalled("pi-subagents")
    }

    var areSubagentsEnabledForNewSessions: Bool {
        subagentsPackageEntries().contains(where: isSubagentsPackageEntry)
    }

    func toggleSubagentsForNewSessions() {
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/settings.json")

        var settings = loadJSONSettings(at: settingsURL) ?? [:]
        let packages = subagentsPackageEntries(from: settings)

        if areSubagentsEnabledForNewSessions {
            settings["packages"] = packages.filter { !isSubagentsPackageEntry($0) }
        } else {
            settings["packages"] = packages + ["npm:pi-subagents"]
        }

        saveJSONSettings(settings, to: settingsURL)
        piAgentSessionStore.newSessionSubagentsEnabled = areSubagentsEnabledForNewSessions
        refresh(includeModels: false)
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
        selectedSidebarItem == .github || currentGitHubAccount != nil || githubLastStatusCheckAt != nil || githubIsRefreshingEverything
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
            .filter { !effectiveNames.contains($0) && !libraryNames.contains($0) }
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

    var selectedCommand: CommandRecord? {
        snapshot.commands.first(where: { $0.id == selectedCommandItemID })
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
        return Array(Set(snapshot.skills.map(\.name)))
            .filter { $0 != "pi-subagents" }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func availableToolNames(for target: AgentEditingTarget) -> [String] {
        let scopeSnapshot = scopeSnapshot(for: target)
        var tools = [
            "read", "grep", "find", "ls", "bash",
            "edit", "write", "ask_user"
        ]

        if isPackageInstalled("pi-web-access") {
            tools += ["web_search", "fetch_content", "get_search_content", "code_search"]
        }
        if isPackageInstalled("pi-subagents") {
            tools.append("subagent")
        }
        if isPackageInstalled("pi-intercom") {
            tools.append("intercom")
        }

        let explicitTools = scopeSnapshot.effectiveAgents.flatMap { $0.resolved.tools ?? [] }
        return Array(Set(tools + explicitTools))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func availableModelIdentifiers() -> [String] {
        availableModels.map(\.identifier)
    }

    var selectedProjectName: String {
        projectRootURL?.lastPathComponent ?? "All Projects"
    }

    var configuredProjectsRootURL: URL {
        let trimmed = appSettings.projectsRootPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = ProjectDiscovery.defaultRootDirectoryURL()
        guard !trimmed.isEmpty else { return fallback }
        return URL(fileURLWithPath: trimmed).standardizedFileURL
    }

    var configuredProjectsRootPath: String {
        configuredProjectsRootURL.path
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
        Array(Set(availableModels.map(\.provider)))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var totalProjectWarnings: Int {
        allProjectSnapshots.values.reduce(0) { $0 + $1.warnings.count }
    }

    func makeAgentDraft(for agent: EffectiveAgentRecord, preferredOverrideScope: AgentEditingTarget.OverrideScope? = nil) -> AgentEditorDraft? {
        agentPersistence.makeDraft(for: agent, preferredOverrideScope: preferredOverrideScope)
    }

    func saveAgentDraft(_ draft: AgentEditorDraft, for agent: EffectiveAgentRecord) throws {
        try agentPersistence.save(draft, original: agent, projectRoot: selectedProjectPath)
        refresh(includeModels: false)
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
            tools: nil,
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
        refresh(includeModels: false)
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
        refresh(includeModels: false)
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
        refresh(includeModels: false)
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

    func agentIsEnabledGlobally(_ agent: AgentRecord) -> Bool {
        globalSnapshot.globalAgents.contains { $0.name == agent.name }
    }

    func setAgent(_ agent: AgentRecord, enabled: Bool, for project: DiscoveredProject) throws {
        if enabled { try addAgent(agent, toProjectPath: project.path) }
        else { try removeManagedFileLink(projectAgentLinkURL(name: agent.name, projectPath: project.path)) }
        refresh(includeModels: false)
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
        refresh(includeModels: false)
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
        refresh(includeModels: false)
        selectedSkillID = allVisibleSkillRecords.first { $0.name == skill.name }?.id ?? selectedSkillID
    }

    private func removeSkill(_ skill: SkillRecord, fromProjectPath projectPath: String) throws {
        try removeManagedSkillLink(URL(fileURLWithPath: projectPath).appendingPathComponent(".pi/skills/", isDirectory: true).appendingPathComponent(skill.name, isDirectory: true))
        refresh(includeModels: false)
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
        refresh(includeModels: false)
    }

    func makeSubagentConfigDraft() -> SubagentConfigDraft {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/extensions/subagent/config.json").path
        return subagentConfigPersistence.makeDraft(path: path, config: snapshot.subagentConfig?.config ?? .packageDefaults)
    }

    func saveSubagentConfigDraft(_ draft: SubagentConfigDraft) throws {
        try subagentConfigPersistence.save(draft)
        refresh(includeModels: false)
    }

    func restoreDefaultSubagentConfig() {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/extensions/subagent/config.json").path
        try? FileManager.default.removeItem(atPath: path)
        refresh(includeModels: false)
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
            refresh(includeModels: false)
        } catch {
            githubLastError = error.localizedDescription
        }
    }

    func setBuiltinDisabled(_ isDisabled: Bool, for agent: EffectiveAgentRecord, scope: AgentEditingTarget.OverrideScope) {
        do {
            try agentPersistence.setBuiltinDisabled(isDisabled, for: agent, scope: scope, projectRoot: selectedProjectPath)
            refresh(includeModels: false)
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
        let projectSnapshots = Array(allProjectSnapshots.values)
        let projectSpecificEffectiveAgents = projectSnapshots
            .flatMap(\.effectiveAgents)
            .filter { $0.projectCustom != nil || $0.projectOverride != nil }

        let chains = deduplicateByID(globalSnapshot.chains + projectSnapshots.flatMap(\.chains))
        let libraryAgents = deduplicateByID(globalSnapshot.libraryAgents + projectSnapshots.flatMap(\.libraryAgents))
        let libraryChains = deduplicateByID(globalSnapshot.libraryChains + projectSnapshots.flatMap(\.libraryChains))
        let skills = deduplicateByID(globalSnapshot.skills + projectSnapshots.flatMap(\.skills))
        let librarySkills = deduplicateByID(globalSnapshot.librarySkills + projectSnapshots.flatMap(\.librarySkills))
        let commands = deduplicateByID(globalSnapshot.commands + projectSnapshots.flatMap(\.commands))
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
            commands: commands,
            promptTemplates: promptTemplates,
            libraryPromptTemplates: libraryPromptTemplates,
            settings: settings,
            envKeys: envKeys,
            subagentConfig: globalSnapshot.subagentConfig,
            warnings: warnings
        )
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

    private func refreshAvailableModels() {
        guard !isRefreshingModels else { return }
        isRefreshingModels = true

        Task.detached(priority: .utility) {
            let models = Self.loadAvailableModels()
            await MainActor.run {
                self.availableModels = models
                self.modelsLastUpdatedAt = Date()
                self.isRefreshingModels = false
            }
        }
    }

    nonisolated private static func loadAvailableModels() -> [AvailableModel] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            "-lc",
            "if command -v pi >/dev/null 2>&1; then pi --list-models; elif [ -x /opt/homebrew/bin/pi ]; then /opt/homebrew/bin/pi --list-models; elif [ -x /usr/local/bin/pi ]; then /usr/local/bin/pi --list-models; else exit 127; fi"
        ]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return [] }
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            guard let text = String(data: data, encoding: .utf8) else { return [] }
            let exactThinkingLevels = loadModelThinkingLevels()
            return parseAvailableModels(from: text, exactThinkingLevels: exactThinkingLevels)
        } catch {
            return []
        }
    }

    nonisolated private static func loadModelThinkingLevels() -> [String: [String]] {
        let script = #"""
import { getModel, supportsXhigh } from '/opt/homebrew/lib/node_modules/@mariozechner/pi-coding-agent/node_modules/@mariozechner/pi-ai/dist/models.js';
const input = JSON.parse(process.env.PI_MANAGER_MODEL_INPUT ?? '[]');
const result = {};
for (const item of input) {
  const model = getModel(item.provider, item.model);
  if (!model || !model.reasoning) {
    result[`${item.provider}/${item.model}`] = ['off'];
    continue;
  }
  result[`${item.provider}/${item.model}`] = supportsXhigh(model)
    ? ['off', 'minimal', 'low', 'medium', 'high', 'xhigh']
    : ['off', 'minimal', 'low', 'medium', 'high'];
}
process.stdout.write(JSON.stringify(result));
"""#
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", "--input-type=module", "--eval", script]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        let knownModels = availableModelIdentifiersFromPiList().map { ["provider": $0.provider, "model": $0.model] }

        do {
            let inputData = try JSONSerialization.data(withJSONObject: knownModels)
            guard let inputText = String(data: inputData, encoding: .utf8) else { return [:] }
            var environment = ProcessInfo.processInfo.environment
            environment["PI_MANAGER_MODEL_INPUT"] = inputText
            process.environment = environment

            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return [:] }
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: [String]] else { return [:] }
            return object
        } catch {
            return [:]
        }
    }

    nonisolated private static func availableModelIdentifiersFromPiList() -> [(provider: String, model: String)] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            "-lc",
            "if command -v pi >/dev/null 2>&1; then pi --list-models; elif [ -x /opt/homebrew/bin/pi ]; then /opt/homebrew/bin/pi --list-models; elif [ -x /usr/local/bin/pi ]; then /usr/local/bin/pi --list-models; else exit 127; fi"
        ]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return [] }
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            guard let text = String(data: data, encoding: .utf8) else { return [] }
            return text.split(whereSeparator: \.isNewline).dropFirst().compactMap { line in
                let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
                guard parts.count >= 2 else { return nil }
                return (provider: parts[0], model: parts[1])
            }
        } catch {
            return []
        }
    }

    nonisolated private static func parseAvailableModels(from text: String, exactThinkingLevels: [String: [String]]) -> [AvailableModel] {
        text
            .split(whereSeparator: \.isNewline)
            .dropFirst()
            .compactMap { line in
                let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
                guard parts.count >= 6 else { return nil }
                let identifier = "\(parts[0])/\(parts[1])"
                let supportsThinking = parts[4].lowercased() == "yes"
                return AvailableModel(
                    provider: parts[0],
                    model: parts[1],
                    contextWindow: parts[2],
                    maxOutput: parts[3],
                    supportsThinking: supportsThinking,
                    supportsImages: parts[5].lowercased() == "yes",
                    supportedThinkingLevels: exactThinkingLevels[identifier] ?? (supportsThinking ? ["off", "minimal", "low", "medium", "high"] : ["off"])
                )
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
        autoRefreshCancellable = Timer.publish(every: 2, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refreshIfWatchedFilesChanged()
            }
    }

    private func refreshIfWatchedFilesChanged() {
        let fingerprint = watchFingerprint()
        guard fingerprint != lastWatchFingerprint else { return }
        refresh(includeModels: false)
    }

    private func watchFingerprint() -> String {
        let fileManager = FileManager.default
        let urls = watchedURLs()
        let entries: [String] = urls.flatMap { url in
            if let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey]),
               values.isDirectory == true {
                let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey])
                var children: [String] = []
                while let child = enumerator?.nextObject() as? URL {
                    guard watchedFileName(child.lastPathComponent) else { continue }
                    let date = (try? child.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
                    children.append("\(child.path)::\(date)")
                }
                return children
            }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
            return ["\(url.path)::\(date)"]
        }
        return entries.sorted().joined(separator: "|")
    }

    private func watchedURLs() -> [URL] {
        var urls: [URL] = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".agents", isDirectory: true)
        ]

        for project in enabledProjects {
            urls.append(project.url.appendingPathComponent(".pi", isDirectory: true))
            urls.append(project.url.appendingPathComponent(".agents", isDirectory: true))
        }

        urls += snapshot.promptTemplates.map { URL(fileURLWithPath: $0.filePath) }
        urls += snapshot.settings.flatMap(\.prompts).map { URL(fileURLWithPath: $0) }

        var seen: Set<String> = []
        return urls.filter { seen.insert($0.path).inserted }
    }

    private func watchedFileName(_ name: String) -> Bool {
        name.hasSuffix(".md") || name.hasSuffix(".json") || name == ".env" || name == "SKILL.md"
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

    private func loadJSONSettings(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func saveJSONSettings(_ settings: [String: Any], to url: URL) {
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard JSONSerialization.isValidJSONObject(settings),
              let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func subagentsPackageEntries() -> [Any] {
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/settings.json")
        return subagentsPackageEntries(from: loadJSONSettings(at: settingsURL) ?? [:])
    }

    private func subagentsPackageEntries(from settings: [String: Any]) -> [Any] {
        settings["packages"] as? [Any] ?? []
    }

    private func isSubagentsPackageEntry(_ entry: Any) -> Bool {
        if let value = entry as? String {
            return value == "npm:pi-subagents"
        }
        if let value = entry as? [String: Any], let source = value["source"] as? String {
            return source == "npm:pi-subagents"
        }
        return false
    }
}

enum PiAgentThinkingDisplayMode: String, Codable, CaseIterable, Identifiable {
    case full = "Full"
    case compact = "Compact"
    case hidden = "Hidden"

    var id: String { rawValue }
}

struct AppSettings: Codable, Hashable {
    var gitHubBoardCacheLifetimeMinutes: Int = 15
    var piAgentThinkingDisplayMode: PiAgentThinkingDisplayMode = .full
    var piAgentTerminalApplicationPath: String?
    var projectsRootPath: String = ProjectDiscovery.defaultRootDirectoryURL().path
    var defaultSkillsImportRootPath: String?
}

struct TerminalApplicationOption: Identifiable, Hashable {
    static let defaultID = "__macos_default__"

    var name: String
    var path: String?

    var id: String { path ?? Self.defaultID }
}

@MainActor
final class AppSettingsStore {
    static let shared = AppSettingsStore()

    private let defaults = UserDefaults.standard
    private let defaultsKey = "piManagerAppSettings"

    var settings: AppSettings {
        didSet { persist() }
    }

    private init() {
        if let data = defaults.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = decoded
        } else {
            settings = AppSettings()
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}

enum SidebarItem: String, CaseIterable, Identifiable {
    case projects = "Projects"
    case github = "GitHub"
    case agent = "Pi Agent"
    case agents = "Agents"
    case chains = "Chains"
    case skills = "Skills"
    case commandsAndPrompts = "Prompts"
    case subagents = "Subagents"
    case models = "Models"
    case settings = "Settings"
    case environment = "Environment"
    case diagnostics = "Diagnostics"
    case piDocs = "Docs"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .projects: return "folder"
        case .github: return "chevron.left.forwardslash.chevron.right"
        case .agent: return "sparkles.rectangle.stack"
        case .agents: return "rectangle.connected.to.line.below"
        case .chains: return "point.3.connected.trianglepath.dotted"
        case .skills: return "wand.and.stars"
        case .commandsAndPrompts: return "rectangle.and.pencil.and.ellipsis"
        case .subagents: return "slider.horizontal.3"
        case .models: return "cpu"
        case .settings: return "gearshape"
        case .environment: return "key"
        case .diagnostics: return "stethoscope"
        case .piDocs: return "book"
        }
    }
}

enum SidebarSection: String, CaseIterable, Identifiable {
    case workspace = "Workspace"
    case piResources = "Pi Resources"
    case runtime = "Runtime"
    case reference = "Reference"

    var id: String { rawValue }

    var items: [SidebarItem] {
        switch self {
        case .workspace:
            return [.projects, .github]
        case .piResources:
            return [.agents, .chains, .skills, .commandsAndPrompts]
        case .runtime:
            return [.models, .settings, .environment, .diagnostics]
        case .reference:
            return [.piDocs]
        }
    }
}

enum AgentFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case builtin = "Builtin"
    case global = "Global"
    case project = "Project"
    case overriddenBuiltins = "Overridden Builtins"
    case replacedBuiltins = "Replaced Builtins"
    case customOnly = "Custom Only"
    case disabled = "Disabled"
    case needsAttention = "Needs Attention"

    var id: String { rawValue }
}
