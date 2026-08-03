import AppKit
import Foundation
import SwiftUI

struct GitDiffCacheKey: Hashable {
    let projectPath: String
    let filePath: String
    let kind: GitDiffKind
}

struct RepositoryChangesCacheEntry {
    var snapshot: RepositoryChangesSnapshot? = nil
    var fetchedAt: Date? = nil
    var isLoading: Bool = false
    var error: String?
    var requestID: Int = 0
    var mergeSourceBranch: String?
    var mergeSessionBranch: String?
    var hasMergeableBranchChanges: Bool?
}


// MARK: - Repository / Review (git status, diff, stage, commit, push)

extension AppViewModel {
    func refreshEverything() {
        guard !isRefreshingEverything else { return }

        isRefreshingEverything = true
        repositoryLastError = nil

        Task { [weak self] in
            guard let self else { return }
            defer {
                self.isRefreshingEverything = false
            }
            self.refresh(includeModels: true)
            if self.selectedDiscoveredProject?.isGitRepository == true {
                self.refreshRepositoryChanges(preservingDiffSelection: true)
            }
        }
    }
    func refreshRepositoryChanges(preservingDiffSelection: Bool = false, force: Bool = true) {
        guard let project = selectedDiscoveredProject, project.isGitRepository else {
            repositoryChangesRequestID += 1
            repositoryChanges = nil
            repositoryChangesProjectPath = nil
            repositorySelectedChangePaths = []
            repositorySelectedDiffFilePath = nil
            repositorySelectedDiffKind = nil
            repositorySelectedDiffText = nil
            isLoadingRepositoryChanges = false
            repositoryLastError = nil
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

    /// Active git root for Review / stage / diff — session worktree first so
    /// isolated sessions never stage/diff against the parent project root.
    var activeRepositoryRootPath: String? {
        if let session = piAgentSessionStore.selectedSession {
            return session.repositoryRoot
        }
        if let path = repositoryChangesProjectPath, !path.isEmpty { return path }
        return selectedDiscoveredProject?.path
    }

    var activeRepositoryURL: URL? {
        guard let path = activeRepositoryRootPath else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    func loadDiff(for filePath: String, kind: GitDiffKind) {
        guard let rootPath = activeRepositoryRootPath,
              let repoURL = activeRepositoryURL else { return }
        let cacheKey = GitDiffCacheKey(projectPath: rootPath, filePath: filePath, kind: kind)
        if repositorySelectedDiffFilePath == filePath,
           repositorySelectedDiffKind == kind,
           repositorySelectedDiffText != nil {
            return
        }

        repositoryDiffRequestID += 1
        let requestID = repositoryDiffRequestID
        repositorySelectedDiffFilePath = filePath
        repositorySelectedDiffKind = kind
        repositorySelectedDiffText = cachedRepositoryDiff(for: cacheKey)
        repositoryLastError = nil
        // Always also load the full working-tree file for the Review inspector.
        loadRepositoryFileContent(for: filePath)

        Task { [weak self] in
            guard let self else { return }
            do {
                // Full-file context so Review can render Codex-style complete file + collapse.
                let diff = try await self.gitRepositoryService.loadDiff(
                    for: filePath,
                    kind: kind,
                    in: repoURL,
                    contextLines: 1_000_000
                )
                await MainActor.run {
                    guard self.repositoryDiffRequestID == requestID,
                          self.activeRepositoryRootPath == rootPath,
                          self.repositorySelectedDiffFilePath == filePath,
                          self.repositorySelectedDiffKind == kind else { return }
                    let displayText = diff.isEmpty ? LanguageStore.shared.t("vm.noDiffForFile", kind.rawValue.lowercased()) : diff
                    self.storeRepositoryDiff(displayText, for: cacheKey)
                    self.repositorySelectedDiffText = displayText
                }
            } catch {
                await MainActor.run {
                    guard self.repositoryDiffRequestID == requestID,
                          self.activeRepositoryRootPath == rootPath,
                          self.repositorySelectedDiffFilePath == filePath,
                          self.repositorySelectedDiffKind == kind else { return }
                    self.repositorySelectedDiffText = nil
                    self.repositoryLastError = error.localizedDescription
                }
            }
        }
    }

    func stage(_ filePath: String) {
        guard let rootPath = activeRepositoryRootPath,
              let repoURL = activeRepositoryURL else { return }
        repositoryLastError = nil

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.gitRepositoryService.stage(filePath, in: repoURL)
                await MainActor.run {
                    self.invalidateDiffCache(projectPath: rootPath, filePath: filePath)
                    self.refreshRepositoryChanges(forProjectPath: rootPath, preservingDiffSelection: true, force: true)
                    self.loadDiff(for: filePath, kind: .staged)
                }
            } catch {
                await MainActor.run {
                    self.repositoryLastError = error.localizedDescription
                }
            }
        }
    }

    func unstage(_ filePath: String) {
        guard let rootPath = activeRepositoryRootPath,
              let repoURL = activeRepositoryURL else { return }
        repositoryLastError = nil

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.gitRepositoryService.unstage(filePath, in: repoURL)
                await MainActor.run {
                    self.invalidateDiffCache(projectPath: rootPath, filePath: filePath)
                    self.refreshRepositoryChanges(forProjectPath: rootPath, preservingDiffSelection: true, force: true)
                    self.loadDiff(for: filePath, kind: .unstaged)
                }
            } catch {
                await MainActor.run {
                    self.repositoryLastError = error.localizedDescription
                }
            }
        }
    }

    func toggleChangeSelection(_ filePath: String) {
        if repositorySelectedChangePaths.contains(filePath) {
            repositorySelectedChangePaths.remove(filePath)
        } else {
            repositorySelectedChangePaths.insert(filePath)
        }
    }

    func selectAllVisibleChanges() {
        guard let snapshot = repositoryChanges else { return }
        repositorySelectedChangePaths = Set(snapshot.staged.map(\.path) + snapshot.unstaged.map(\.path) + snapshot.untracked.map(\.path) + snapshot.conflicted.map(\.path))
    }

    func clearSelectedChanges() {
        repositorySelectedChangePaths.removeAll()
    }

    func stageSelectedChanges() {
        guard let rootPath = activeRepositoryRootPath,
              let repoURL = activeRepositoryURL else { return }
        let paths = Array(repositorySelectedChangePaths)
        guard !paths.isEmpty else { return }
        repositoryLastError = nil

        Task { [weak self] in
            guard let self else { return }
            do {
                for path in paths {
                    try await self.gitRepositoryService.stage(path, in: repoURL)
                }
                await MainActor.run {
                    self.refreshRepositoryChanges(forProjectPath: rootPath, preservingDiffSelection: true, force: true)
                }
            } catch {
                await MainActor.run { self.repositoryLastError = error.localizedDescription }
            }
        }
    }

    func unstageSelectedChanges() {
        guard let rootPath = activeRepositoryRootPath,
              let repoURL = activeRepositoryURL else { return }
        let paths = Array(repositorySelectedChangePaths)
        guard !paths.isEmpty else { return }
        repositoryLastError = nil

        Task { [weak self] in
            guard let self else { return }
            do {
                for path in paths {
                    try await self.gitRepositoryService.unstage(path, in: repoURL)
                }
                await MainActor.run {
                    self.refreshRepositoryChanges(forProjectPath: rootPath, preservingDiffSelection: true, force: true)
                }
            } catch {
                await MainActor.run { self.repositoryLastError = error.localizedDescription }
            }
        }
    }

    func stageAllChanges() {
        guard let rootPath = activeRepositoryRootPath,
              let repoURL = activeRepositoryURL else { return }
        repositoryLastError = nil

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.gitRepositoryService.stageAll(in: repoURL)
                await MainActor.run {
                    self.invalidateDiffCache(projectPath: rootPath)
                    self.refreshRepositoryChanges(forProjectPath: rootPath, preservingDiffSelection: true, force: true)
                }
            } catch {
                await MainActor.run { self.repositoryLastError = error.localizedDescription }
            }
        }
    }

    func unstageAllChanges() {
        guard let rootPath = activeRepositoryRootPath,
              let repoURL = activeRepositoryURL else { return }
        repositoryLastError = nil

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.gitRepositoryService.unstageAll(in: repoURL)
                await MainActor.run {
                    self.invalidateDiffCache(projectPath: rootPath)
                    self.refreshRepositoryChanges(forProjectPath: rootPath, preservingDiffSelection: true, force: true)
                }
            } catch {
                await MainActor.run { self.repositoryLastError = error.localizedDescription }
            }
        }
    }

    private func invalidateDiffCache(projectPath: String, filePath: String? = nil) {
        repositoryDiffCache = repositoryDiffCache.filter { entry in
            guard entry.key.projectPath == projectPath else { return true }
            guard let filePath else { return false }
            return entry.key.filePath != filePath
        }
        repositoryDiffCacheOrder.removeAll { key in
            guard key.projectPath == projectPath else { return false }
            guard let filePath else { return true }
            return key.filePath == filePath
        }
    }

    private func cachedRepositoryDiff(for key: GitDiffCacheKey) -> String? {
        guard let value = repositoryDiffCache[key] else { return nil }
        markRepositoryDiffCacheKeyUsed(key)
        return value
    }

    private func storeRepositoryDiff(_ value: String, for key: GitDiffCacheKey) {
        repositoryDiffCache[key] = value
        markRepositoryDiffCacheKeyUsed(key)
        while repositoryDiffCacheOrder.count > repositoryDiffCacheLimit, let oldest = repositoryDiffCacheOrder.first {
            repositoryDiffCacheOrder.removeFirst()
            repositoryDiffCache[oldest] = nil
        }
    }

    private func markRepositoryDiffCacheKeyUsed(_ key: GitDiffCacheKey) {
        repositoryDiffCacheOrder.removeAll { $0 == key }
        repositoryDiffCacheOrder.append(key)
    }

    func commitChanges() {
        guard let project = selectedDiscoveredProject else { return }
        let message = repositoryCommitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = repositoryCommitDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            repositoryLastError = LanguageStore.shared.t("vm.enterCommitTitle")
            return
        }

        isCommittingRepository = true
        repositoryLastError = nil

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.gitRepositoryService.commit(message: message, description: description, in: project.url)
                await MainActor.run {
                    self.repositoryCommitMessage = ""
                    self.repositoryCommitDescription = ""
                    self.isCommittingRepository = false
                    self.refreshRepositoryChanges()
                }
            } catch {
                await MainActor.run {
                    self.isCommittingRepository = false
                    self.repositoryLastError = error.localizedDescription
                }
            }
        }
    }

    func pushCurrentBranch() {
        guard let project = selectedDiscoveredProject else { return }
        isPushingRepository = true
        repositoryLastError = nil

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.gitRepositoryService.pushCurrentBranch(in: project.url)
                await MainActor.run {
                    self.isPushingRepository = false
                    self.refreshRepositoryChanges()
                }
            } catch {
                await MainActor.run {
                    self.isPushingRepository = false
                    self.repositoryLastError = error.localizedDescription
                }
            }
        }
    }

    func prepareRepoChangesForSelectedPiAgentSession(force: Bool = false) {
        guard let session = piAgentSessionStore.selectedSession else { return }
        let repoRoot = session.repositoryRoot
        refreshRepositoryChanges(
            forProjectPath: repoRoot,
            preservingDiffSelection: true,
            force: force,
            activeContextIsCurrent: { [weak self] in
                guard let self else { return false }
                return self.piAgentSessionStore.selectedSession?.repositoryRoot == repoRoot || self.selectedDiscoveredProject?.path == repoRoot
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
        repositoryChangesRequestID += 1
        let requestID = repositoryChangesRequestID
        var entry = repositoryChangesCache[projectPath] ?? RepositoryChangesCacheEntry()
        entry.isLoading = true
        entry.error = nil
        entry.requestID = requestID
        repositoryChangesCache[projectPath] = entry

        if activeContextIsCurrent() {
            syncActiveRepositoryChanges(projectPath: projectPath, preservingDiffSelection: preservingDiffSelection)
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await self.gitRepositoryService.loadChanges(in: projectURL)
                let mergeability = await self.mergeabilityState(forRepositoryPath: projectPath, repositoryURL: projectURL)
                await MainActor.run {
                    guard self.repositoryChangesCache[projectPath]?.requestID == requestID else { return }
                    self.repositoryChangesCache[projectPath] = RepositoryChangesCacheEntry(
                        snapshot: snapshot,
                        fetchedAt: Date(),
                        isLoading: false,
                        error: nil,
                        requestID: requestID,
                        mergeSourceBranch: mergeability?.sourceBranch,
                        mergeSessionBranch: mergeability?.sessionBranch,
                        hasMergeableBranchChanges: mergeability?.hasMergeableChanges
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

    private func mergeabilityState(forRepositoryPath projectPath: String, repositoryURL: URL) async -> (sourceBranch: String, sessionBranch: String, hasMergeableChanges: Bool)? {
        guard let session = await MainActor.run(body: { self.piAgentSessionStore.selectedSession }),
              session.repositoryRoot == projectPath,
              let sourceBranch = session.sourceBranch,
              let sessionBranch = session.branchName else { return nil }

        let hasMergeableChanges = (try? await gitRepositoryService.isBranchAhead(sessionBranch, of: sourceBranch, in: repositoryURL)) ?? false
        return (sourceBranch, sessionBranch, hasMergeableChanges)
    }

    private func syncActiveRepositoryChanges(projectPath: String, preservingDiffSelection: Bool) {
        let entry = repositoryChangesCache[projectPath]
        repositoryChanges = entry?.snapshot
        repositoryChangesProjectPath = entry?.snapshot == nil ? nil : projectPath
        isLoadingRepositoryChanges = entry?.isLoading == true
        repositoryLastError = entry?.error

        if !preservingDiffSelection {
            repositorySelectedChangePaths = []
            repositorySelectedDiffFilePath = nil
            repositorySelectedDiffKind = nil
            repositorySelectedDiffText = nil
        }

        guard let snapshot = entry?.snapshot else { return }
        let validPaths = Set(snapshot.staged.map(\.path) + snapshot.unstaged.map(\.path) + snapshot.untracked.map(\.path) + snapshot.conflicted.map(\.path))
        if preservingDiffSelection {
            repositorySelectedChangePaths = repositorySelectedChangePaths.intersection(validPaths)
        }
    }

    private func isRepositoryChangesCacheStale(_ entry: RepositoryChangesCacheEntry) -> Bool {
        guard let fetchedAt = entry.fetchedAt else { return true }
        return Date().timeIntervalSince(fetchedAt) > repositoryChangesCacheLifetime
    }

    func openRepoChangesForSelectedPiAgentSession() {
        prepareRepoChangesForSelectedPiAgentSession(force: true)
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
            isTrailingInspectorExpanded = true
        }
    }

    func toggleTrailingInspector() {
        if isTrailingInspectorExpanded {
            collapseTrailingInspector()
        } else {
            openRepoChangesForSelectedPiAgentSession()
        }
    }

    func collapseTrailingInspector() {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
            isTrailingInspectorExpanded = false
        }
    }

    /// Absolute file URL under the active review repository root.
    func absoluteURLForRepositoryRelativePath(_ relativePath: String) -> URL? {
        guard let root = activeRepositoryRootPath else { return nil }
        if relativePath.hasPrefix("/") {
            return URL(fileURLWithPath: relativePath)
        }
        return URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(relativePath)
    }

    func openRepositoryFileInDefaultEditor(_ relativePath: String) {
        // Prefer remembered / VS Code default when available; fall back to system default app.
        if let preferred = ExternalCodeEditor.preferredBundleID() {
            openRepositoryFile(relativePath, withEditorBundleID: preferred)
            return
        }
        guard let url = absoluteURLForRepositoryRelativePath(relativePath) else { return }
        NSWorkspace.shared.open(url)
    }

    func openRepositoryFile(_ relativePath: String, withEditorBundleID bundleID: String) {
        guard let fileURL = absoluteURLForRepositoryRelativePath(relativePath) else { return }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            NSWorkspace.shared.open(fileURL)
            return
        }
        ExternalCodeEditor.rememberPreferred(bundleID: bundleID)
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([fileURL], withApplicationAt: appURL, configuration: configuration, completionHandler: nil)
    }

    func revealRepositoryFileInFinder(_ relativePath: String) {
        guard let url = absoluteURLForRepositoryRelativePath(relativePath) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Loads the full working-tree file (not a truncated diff preview).
    func loadRepositoryFileContent(for relativePath: String) {
        guard let url = absoluteURLForRepositoryRelativePath(relativePath) else {
            repositorySelectedFileText = nil
            repositorySelectedFileLoadError = LanguageStore.shared.t("review.fileMissing")
            return
        }
        repositoryFileContentRequestID += 1
        let requestID = repositoryFileContentRequestID
        repositorySelectedFileLoadError = nil
        // Keep previous text until the new read finishes to avoid flicker.
        Task.detached(priority: .userInitiated) {
            let result: Result<String, Error>
            do {
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
                if values.isDirectory == true {
                    result = .failure(NSError(domain: "PiDeck", code: 1, userInfo: [NSLocalizedDescriptionKey: "Path is a directory"]))
                } else if let size = values.fileSize, size > 2_000_000 {
                    // Still load, but cap display length for UI safety.
                    let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                    let prefix = data.prefix(2_000_000)
                    var text = String(data: prefix, encoding: .utf8)
                        ?? String(decoding: prefix, as: UTF8.self)
                    text += "\n\n… [file truncated for display; opened size > 2MB]"
                    result = .success(text)
                } else {
                    let data = try Data(contentsOf: url)
                    if let text = String(data: data, encoding: .utf8) {
                        result = .success(text)
                    } else if data.isEmpty {
                        result = .success("")
                    } else {
                        result = .failure(NSError(domain: "PiDeck", code: 2, userInfo: [NSLocalizedDescriptionKey: "Binary or non-UTF8 file"]))
                    }
                }
            } catch {
                result = .failure(error)
            }
            await MainActor.run {
                guard self.repositoryFileContentRequestID == requestID,
                      self.repositorySelectedDiffFilePath == relativePath else { return }
                switch result {
                case let .success(text):
                    self.repositorySelectedFileText = text
                    self.repositorySelectedFileLoadError = nil
                case let .failure(error):
                    self.repositorySelectedFileText = nil
                    self.repositorySelectedFileLoadError = error.localizedDescription
                }
            }
        }
    }

    func refreshRepositoryChangesForPiAgentSession() {
        guard let session = piAgentSessionStore.selectedSession,
              selectedProjectPath == session.projectPath else { return }
        // The Git tab is showing the project — refresh by project path. The session's
        // own worktree status is refreshed separately by prepareRepoChangesForSelectedPiAgentSession.
        refreshRepositoryChanges(preservingDiffSelection: true)
        if session.repositoryRoot != session.projectPath {
            prepareRepoChangesForSelectedPiAgentSession(force: true)
        }
    }
    func refreshRepositoryProjectScopedState() {
        repositoryChangesRequestID += 1
        repositoryChanges = nil
        repositoryChangesProjectPath = nil
        repositoryChangesCache.removeAll()
        repositorySelectedChangePaths = []
        repositorySelectedDiffFilePath = nil
        repositorySelectedDiffKind = nil
        repositorySelectedDiffText = nil
        repositoryCommitMessage = ""
        repositoryCommitDescription = ""
        isLoadingRepositoryChanges = false
    }

}
