import AppKit
import Foundation
import UniformTypeIdentifiers
import SwiftUI

// MARK: - Prompt templates

extension AppViewModel {
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

    /// boundaries (alongside the other warning caches), so this must NEVER
    /// recompute or touch disk — it is called from view bodies for every agent
    /// on every layout pass. Agents without issues are intentionally absent from
    /// the cache, so a miss means "no issues", not "needs recompute". The old
    /// recompute-on-miss path fell through to a synchronous `PiScanner().scan()`
    /// per healthy agent, producing multi-hundred-ms main-thread hangs on tab

    func removePromptReferences(named promptName: String) throws {
        _ = appSettingsController.setDefaultPromptTemplate(promptName, enabled: false)
        appSettings = appSettingsController.settings

        for projectPath in projectPreferencesStore.preferencesByPath.keys {
            projectPreferencesStore.setAssignedPromptTemplate(promptName, assigned: false, for: projectPath)
        }
        applyProjectPreferenceChanges()
    }

    func parentPromptTemplateArguments(for projectURL: URL) throws -> [String] {
        let projectPath = projectURL.standardizedFileURL.path
        let names = Array(appSettings.defaultPromptTemplateNames.union(projectPreference(for: projectPath).assignedPromptTemplateNames))
        return try PiPromptTemplateLaunchResolver.promptTemplateArguments(for: names, catalog: promptTemplateCatalog(forProjectPath: projectPath), missingPromptPolicy: .skip)
    }

    func promptTemplateCatalog(forProjectPath projectPath: String) -> [PromptTemplateRecord] {
        let records = globalSnapshot.promptTemplates + globalSnapshot.libraryPromptTemplates
        let disabledBundled = appSettings.disabledBundledPromptNames
        var seen = Set<String>()
        return records
            .filter { !($0.source.kind == .builtin && disabledBundled.contains($0.name)) }
            .filter { seen.insert($0.id).inserted }
    }

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

    func ensureLibraryPrompt(for prompt: PromptTemplateRecord) throws -> URL {
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

}
