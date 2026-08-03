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
    var configuredProjectsRootsExist: Bool {
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

}
