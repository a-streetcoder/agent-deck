import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppViewModel: ObservableObject {
    @Published var snapshot: ScanSnapshot = .empty
    @Published var selectedSidebarItem: SidebarItem = .overview
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
    @Published var githubOverviewBoard: GitHubBoardSnapshot?
    @Published var githubProjectBoard: GitHubBoardSnapshot?
    @Published var githubRepositoryChanges: RepositoryChangesSnapshot?
    @Published var githubSelectedChangePaths: Set<String> = []
    @Published var githubSelectedDiffFilePath: String?
    @Published var githubSelectedDiffKind: GitDiffKind?
    @Published var githubSelectedDiffText: String?
    @Published var githubCommitMessage = ""
    @Published var githubSelectedWorkItem: GitHubWorkItem?
    @Published var githubIssueDetail: GitHubIssueDetail?
    @Published var githubCommentDraft = ""
    @Published var githubIsLoadingAggregateBoard = false
    @Published var githubIsLoadingOverviewBoard = false
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
    private var githubOverviewBoardRequestID = 0
    private var githubProjectBoardRequestID = 0
    private var githubRepositoryChangesRequestID = 0
    private var githubIssueDetailRequestID = 0
    private let lastSelectedProjectDefaultsKey = "lastSelectedProjectPath"
    private var githubOverviewBoardCacheKey: String?
    private var githubOverviewBoardFetchedAt: Date?
    private var githubProjectBoardCacheKey: String?
    private var githubProjectBoardFetchedAt: Date?

    init() {
        let piAgentSessionStore = PiAgentSessionStore()
        self.piAgentSessionStore = piAgentSessionStore
        self.piAgentRunner = PiAgentRunnerService(store: piAgentSessionStore)
        appSettings = appSettingsStore.settings
        selectedProjectPath = UserDefaults.standard.string(forKey: lastSelectedProjectDefaultsKey)
        refresh(includeModels: true)
        lastWatchFingerprint = watchFingerprint()
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
        selectedChainID = snapshot.chains.contains(where: { $0.id == previousChainID }) ? previousChainID : snapshot.chains.first?.id
        selectedSkillID = snapshot.skills.contains(where: { $0.id == previousSkillID }) ? previousSkillID : snapshot.skills.first?.id
        let availableCommandItemIDs = Set(snapshot.commands.map(\.id) + snapshot.promptTemplates.map(\.id))
        selectedCommandItemID = availableCommandItemIDs.contains(previousCommandItemID ?? "") ? previousCommandItemID : (snapshot.commands.first?.id ?? snapshot.promptTemplates.first?.id)
        lastWatchFingerprint = watchFingerprint()

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
                    self.refreshOverviewBoard(force: true)
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
        githubOverviewBoardRequestID += 1
        githubProjectBoardRequestID += 1
        githubRepositoryChangesRequestID += 1
        githubIssueDetailRequestID += 1
        githubAggregateBoard = nil
        githubOverviewBoard = nil
        githubOverviewBoardCacheKey = nil
        githubOverviewBoardFetchedAt = nil
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
        githubIsLoadingOverviewBoard = false
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

    func refreshOverviewBoard(force: Bool = false) {
        guard let session = gitHubSession else {
            githubIsLoadingOverviewBoard = false
            githubLastError = "Connect GitHub first."
            githubOverviewBoard = nil
            githubOverviewBoardCacheKey = nil
            githubOverviewBoardFetchedAt = nil
            return
        }

        guard let remote = selectedGitHubProject?.gitHubRemote else {
            githubIsLoadingOverviewBoard = false
            githubLastError = nil
            githubOverviewBoard = nil
            githubOverviewBoardCacheKey = nil
            githubOverviewBoardFetchedAt = nil
            return
        }

        let cacheKey = boardCacheKey(for: remote, state: .open)
        if !force,
           githubOverviewBoard != nil,
           githubOverviewBoardCacheKey == cacheKey,
           !isGitHubBoardCacheStale(fetchedAt: githubOverviewBoardFetchedAt) {
            return
        }

        githubOverviewBoardRequestID += 1
        let requestID = githubOverviewBoardRequestID
        githubIsLoadingOverviewBoard = true
        githubLastError = nil

        Task {
            do {
                let service = GitHubSearchService(apiClient: GitHubAPIClient(session: session))
                let snapshot = try await service.fetchRepositoryIssues(
                    repo: remote,
                    state: .open
                )

                await MainActor.run {
                    guard self.githubOverviewBoardRequestID == requestID,
                          self.selectedGitHubProject?.gitHubRemote == remote else { return }

                    self.githubOverviewBoard = snapshot
                    self.githubOverviewBoardCacheKey = cacheKey
                    self.githubOverviewBoardFetchedAt = Date()
                    self.githubIsLoadingOverviewBoard = false

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
                    guard self.githubOverviewBoardRequestID == requestID,
                          self.selectedGitHubProject?.gitHubRemote == remote else { return }

                    self.githubOverviewBoard = nil
                    self.githubOverviewBoardCacheKey = nil
                    self.githubOverviewBoardFetchedAt = nil
                    self.githubIsLoadingOverviewBoard = false
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
        guard !message.isEmpty else {
            githubLastError = "Enter a commit message first."
            return
        }

        githubIsCommitting = true
        githubLastError = nil

        Task {
            do {
                try await self.gitRepositoryService.commit(message: message, in: project.url)
                await MainActor.run {
                    self.githubCommitMessage = ""
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
        guard let project = selectedDiscoveredProject else { return }
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
        guard let project = selectedDiscoveredProject else {
            githubLastError = "Select a project before starting Pi Agent."
            selectedSidebarItem = .agent
            return
        }
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
        isPiAgentInspectorPresented = true
        piAgentRunner.startIssueSession(detail: detail, project: project)
    }

    func selectPiAgentSession(_ id: UUID) {
        piAgentSessionStore.select(id)
        selectedSidebarItem = .agent
    }

    func renamePiAgentSession(_ id: UUID, title: String) {
        piAgentSessionStore.renameSession(id, title: title)
    }

    func resumeSelectedPiAgentSession() {
        guard let session = piAgentSessionStore.selectedSession else { return }
        selectedSidebarItem = .agent
        isPiAgentInspectorPresented = true
        piAgentRunner.resume(session: session)
    }

    func sendPiAgentMessage(_ text: String, mode: PiAgentInputMode, images: [PiAgentImageAttachment] = []) {
        guard let session = piAgentSessionStore.selectedSession else { return }
        if !piAgentRunner.isRunning(sessionID: session.id), mode == .prompt {
            piAgentRunner.resume(session: session, initialPrompt: text, images: images)
            isPiAgentInspectorPresented = selectedSidebarItem != .agent
            return
        }
        piAgentRunner.send(text, mode: mode, to: session.id, images: images)
    }

    func refreshPiAgentControlsForSelectedSession() {
        guard let sessionID = piAgentSessionStore.selectedSession?.id else { return }
        piAgentRunner.refreshPiControls(sessionID: sessionID)
    }

    func setPiAgentModelForSelectedSession(provider: String?, modelID: String?) {
        guard let sessionID = piAgentSessionStore.selectedSession?.id else { return }
        piAgentRunner.setModel(sessionID: sessionID, provider: provider, modelID: modelID)
    }

    func cyclePiAgentModelForSelectedSession() {
        guard let sessionID = piAgentSessionStore.selectedSession?.id else { return }
        piAgentRunner.cycleModel(sessionID: sessionID)
    }

    func setPiAgentThinkingLevelForSelectedSession(_ level: String) {
        guard let sessionID = piAgentSessionStore.selectedSession?.id else { return }
        piAgentRunner.setThinkingLevel(sessionID: sessionID, level: level)
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

    func deletePiAgentSession(_ sessionID: UUID) {
        if piAgentRunner.isRunning(sessionID: sessionID) {
            piAgentRunner.stop(sessionID: sessionID)
        }
        piAgentSessionStore.deleteSession(sessionID)
    }

    func openRepoChangesForSelectedPiAgentSession() {
        guard let session = piAgentSessionStore.selectedSession else { return }
        if selectedProjectPath != session.projectPath {
            setSelectedProject(URL(fileURLWithPath: session.projectPath))
        }
        githubSelectedSection = .repoChanges
        selectedSidebarItem = .github
        refreshRepositoryChanges(preservingDiffSelection: true)
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
                    self.githubOverviewBoardFetchedAt = nil
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
                    self.githubOverviewBoardFetchedAt = nil
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
        githubOverviewBoardRequestID += 1
        githubProjectBoardRequestID += 1
        githubIssueDetailRequestID += 1
        githubAggregateBoard = nil
        githubOverviewBoard = nil
        githubOverviewBoardCacheKey = nil
        githubOverviewBoardFetchedAt = nil
        githubProjectBoard = nil
        githubProjectBoardCacheKey = nil
        githubProjectBoardFetchedAt = nil
        githubSelectedWorkItem = nil
        githubIssueDetail = nil
        githubCommentDraft = ""
        githubIsLoadingAggregateBoard = false
        githubIsLoadingOverviewBoard = false
        githubIsLoadingProjectBoard = false
        githubIsLoadingIssueDetail = false
        githubIsSubmittingComment = false
        githubIsClosingIssue = false
    }

    private func refreshGitHubProjectScopedState() {
        githubOverviewBoardRequestID += 1
        githubProjectBoardRequestID += 1
        githubRepositoryChangesRequestID += 1
        githubIssueDetailRequestID += 1
        githubOverviewBoard = nil
        githubOverviewBoardCacheKey = nil
        githubOverviewBoardFetchedAt = nil
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
        githubIsLoadingOverviewBoard = false
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

    var filteredAgents: [EffectiveAgentRecord] {
        snapshot.effectiveAgents.filter { agent in
            switch selectedAgentFilter {
            case .all:
                return true
            case .builtin:
                return agent.builtin != nil && agent.globalCustom == nil && agent.projectCustom == nil
            case .global:
                return agent.globalCustom != nil
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
        filteredAgents.first(where: { $0.id == selectedAgentID }) ?? snapshot.effectiveAgents.first(where: { $0.id == selectedAgentID })
    }

    var selectedChain: ChainRecord? {
        snapshot.chains.first(where: { $0.id == selectedChainID })
    }

    var selectedSkill: SkillRecord? {
        snapshot.skills.first(where: { $0.id == selectedSkillID })
    }

    var selectedCommand: CommandRecord? {
        snapshot.commands.first(where: { $0.id == selectedCommandItemID })
    }

    var selectedPromptTemplate: PromptTemplateRecord? {
        snapshot.promptTemplates.first(where: { $0.id == selectedCommandItemID })
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
        let directMCPTools = scopeSnapshot.mcpConfigs.flatMap(\.serverNames).map { "mcp:\($0)" }
        let existingMCPTools = scopeSnapshot.effectiveAgents.flatMap { ($0.resolved.mcpDirectTools ?? []).map { "mcp:\($0)" } }
        return Array(Set(tools + explicitTools + directMCPTools + existingMCPTools))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func availableModelIdentifiers() -> [String] {
        availableModels.map(\.identifier)
    }

    var selectedProjectName: String {
        projectRootURL?.lastPathComponent ?? "All Projects"
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
        let skills = deduplicateByID(globalSnapshot.skills + projectSnapshots.flatMap(\.skills))
        let commands = deduplicateByID(globalSnapshot.commands + projectSnapshots.flatMap(\.commands))
        let promptTemplates = deduplicateByID(globalSnapshot.promptTemplates + projectSnapshots.flatMap(\.promptTemplates))
        let envKeys = deduplicateByID(globalSnapshot.envKeys + projectSnapshots.flatMap(\.envKeys))
        let mcpConfigs = deduplicateByID(globalSnapshot.mcpConfigs + projectSnapshots.flatMap(\.mcpConfigs))
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
            skills: skills,
            commands: commands,
            promptTemplates: promptTemplates,
            settings: settings,
            envKeys: envKeys,
            mcpConfigs: mcpConfigs,
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
        return ScanSnapshot(
            projectRoot: projectSnapshot.projectRoot,
            builtinAgents: globalSnapshot.builtinAgents,
            globalAgents: globalSnapshot.globalAgents,
            projectAgents: projectSnapshot.projectAgents,
            legacyProjectAgents: projectSnapshot.legacyProjectAgents,
            effectiveAgents: globalSnapshot.effectiveAgents + projectSnapshot.effectiveAgents.filter { $0.projectCustom != nil || $0.projectOverride != nil },
            chains: globalSnapshot.chains + projectSnapshot.chains,
            skills: globalSnapshot.skills + projectSnapshot.skills,
            commands: deduplicateByID(globalSnapshot.commands + projectSnapshot.commands),
            promptTemplates: deduplicateByID(globalSnapshot.promptTemplates + projectSnapshot.promptTemplates),
            settings: globalSnapshot.settings + projectSnapshot.settings,
            envKeys: globalSnapshot.envKeys + projectSnapshot.envKeys,
            mcpConfigs: globalSnapshot.mcpConfigs + projectSnapshot.mcpConfigs,
            subagentConfig: globalSnapshot.subagentConfig,
            warnings: globalSnapshot.warnings + projectSnapshot.warnings
        )
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
        let marker = "/Documents/GitHub/"
        guard let range = path.range(of: marker) else { return nil }
        let remainder = path[range.upperBound...]
        return remainder.split(separator: "/").first.map(String.init)
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
            urls.append(project.url.appendingPathComponent(".mcp.json"))
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
}

struct AppSettings: Codable, Hashable {
    var gitHubBoardCacheLifetimeMinutes: Int = 15
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
    case overview = "Overview"
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
    case mcp = "MCP"
    case diagnostics = "Diagnostics"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .overview: return "square.grid.2x2"
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
        case .mcp: return "cable.connector"
        case .diagnostics: return "stethoscope"
        }
    }
}

enum SidebarSection: String, CaseIterable, Identifiable {
    case workspace = "Workspace"
    case piResources = "Pi Resources"
    case runtime = "Runtime"

    var id: String { rawValue }

    var items: [SidebarItem] {
        switch self {
        case .workspace:
            return [.overview, .projects, .github, .agent]
        case .piResources:
            return [.agents, .chains, .skills, .commandsAndPrompts]
        case .runtime:
            return [.models, .settings, .environment, .mcp, .diagnostics]
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
