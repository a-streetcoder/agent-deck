import AppKit
import Foundation
import UniformTypeIdentifiers

// MARK: - Project library preferences

extension AppViewModel {
    func addProject(_ url: URL, selectingAfterAdd: Bool = false) {
        let standardizedURL = url.standardizedFileURL
        projectPreferencesStore.addProjectPath(standardizedURL.path)
        projectPreferencesStore.setEnabled(true, for: standardizedURL.path)
        projectPreferencesByPath = projectPreferencesStore.preferencesByPath

        if selectingAfterAdd {
            projectRootURL = standardizedURL
            selectedProjectPath = standardizedURL.path
            persistSelectedProjectPath(standardizedURL.path)
        }

        refresh(includeModels: false, scanAllProjects: false, extraProjectPathsToScan: [standardizedURL.path])
        if selectingAfterAdd {
            refreshRepositoryProjectScopedState()
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
        refreshRepositoryProjectScopedState()
    }

    func clearProjectRoot() {
        projectRootURL = nil
        selectedProjectPath = nil
        persistSelectedProjectPath(nil)
        refresh(includeModels: false)
        refreshRepositoryProjectScopedState()
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
        refreshRepositoryProjectScopedState()
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
        refreshRepositoryProjectScopedState()
    }

    func removeProjectFromLibrary(_ project: DiscoveredProject) {
        forgetProject(project)
        refreshRepositoryProjectScopedState()
    }

    func moveProjectToTrash(_ project: DiscoveredProject) throws {
        try FileManager.default.trashItem(at: project.url, resultingItemURL: nil)
        forgetProject(project)
        refresh(includeModels: false, scanAllProjects: true)
        refreshRepositoryProjectScopedState()
    }

    func forgetProject(_ project: DiscoveredProject) {
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
    }

    func chooseCustomIcon(for project: DiscoveredProject) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.prompt = LanguageStore.shared.t("vm.chooseIcon")
        panel.message = LanguageStore.shared.t("vm.chooseIconMessage")

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try projectPreferencesStore.setCustomIcon(from: url, for: project.path)
            applyProjectPreferenceChanges()
        } catch {
            repositoryLastError = error.localizedDescription
        }
    }

    func clearCustomIcon(for project: DiscoveredProject) {
        projectPreferencesStore.clearCustomIcon(for: project.path)
        applyProjectPreferenceChanges()
    }

    func applyProjectPreferenceChanges() {
        // Preference changes (especially hiding/removing a project) must invalidate any
        // in-flight refresh that was built with older preferences. Otherwise a stale
        // refresh can apply after this local mutation and reinsert the removed project.
        refreshRequestID += 1
        refreshTask?.cancel()

        projectPreferencesByPath = projectPreferencesStore.preferencesByPath
        projectPreferencesRevision &+= 1
        discoveredProjects = discoveredProjects.compactMap { project in
            let preference = projectPreferencesStore.preference(for: project.path)
            guard !preference.isHidden else { return nil }
            return DiscoveredProject(
                url: project.url,
                gitHubRemote: project.gitHubRemote,
                isGitRepository: project.isGitRepository,
                iconFileURL: preference.customIconPath.flatMap { URL(fileURLWithPath: $0) },
                projectType: project.projectType,
                fallbackSymbolName: project.fallbackSymbolName,
                searchIndex: project.searchIndex
            )
        }
    }

    func persistSelectedProjectPath(_ path: String?) {
        if let path {
            UserDefaults.standard.set(path, forKey: lastSelectedProjectDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: lastSelectedProjectDefaultsKey)
        }
    }

}
