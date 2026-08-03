import Combine
import Foundation

// MARK: - File watch auto-refresh

extension AppViewModel {
    func startAutoRefresh() {
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

    func stopAutoRefresh(cancelPendingScan: Bool) {
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

    func currentWatchedURLsForAutoRefresh() -> [URL] {
        watchedURLsForAutoRefresh.isEmpty
            ? AppRefreshService.watchedURLs(projects: selectedDiscoveredProject.map { [$0] } ?? [], snapshot: snapshot, externalSkillPaths: appSettings.externalSkillPaths, externalPromptPaths: appSettings.externalPromptPaths, codexPluginSkillReferences: appSettings.codexPluginSkillReferences, resolvedCodexPluginSkillPaths: cachedResolvedCodexPluginSkillPaths)
            : watchedURLsForAutoRefresh
    }

    func scheduleRefreshForWatchedFileEvent() {
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

    var shouldDeferWatchedFileRefresh: Bool {
        TranscriptInteractionGate.isInteractingRecently || TranscriptInteractionGate.isStreamingRecently
    }

    func scheduleDeferredWatchedFileRefresh() {
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

    func refreshIfWatchedFilesChanged() {
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

    func applyWatchFingerprint(_ fingerprint: String, previousFingerprint: String) {
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
