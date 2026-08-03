import AppKit
import Foundation
import UniformTypeIdentifiers

// MARK: - Profile, themes, settings mutators

extension AppViewModel {
    var piAgentNotificationDelayMinutes: Int {
        appSettingsController.piAgentNotificationDelayMinutes
    }

    var piAgentIdleParkingTimeoutMinutes: Int {
        appSettingsController.piAgentIdleParkingTimeoutMinutes
    }

    var isPiAgentIdleParkingEnabled: Bool {
        appSettingsController.isPiAgentIdleParkingEnabled
    }

    // MARK: - User profile (transcript "You" bubble)

    /// Effective label for user message headers.
    var resolvedUserDisplayName: String {
        let trimmed = appSettings.userDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return LanguageStore.shared.t("profile.defaultYou")
    }

    /// File URL of the custom user avatar, if configured.
    var userAvatarImageURL: URL? {
        UserAvatarStore.imageURL(fileName: appSettings.userAvatarFileName)
    }

    /// Preferred `pi` CLI absolute path from settings (`nil` = auto-detect).
    var piExecutablePathSetting: String? {
        appSettings.piExecutablePath
    }

    /// Saves the preferred `pi` path (Settings / Doctor). Session launches then skip scan.
    ///
    /// - Parameter path: Absolute path to an executable `pi`, or empty/`nil` to clear.
    func setPiExecutablePath(_ path: String?) {
        _ = appSettingsController.setPiExecutablePath(path)
        syncAppSettings()
    }

    /// Runs Doctor-style resolution once, persists the path when found, and returns it.
    ///
    /// - Parameter forceScan: When `true`, temporarily clears preferred path to re-scan PATH/candidates.
    /// - Returns: Resolved absolute path, or `nil` if `pi` is not found.
    @discardableResult
    func detectAndSavePiExecutablePath(forceScan: Bool = false) -> String? {
        if forceScan {
            PiExecutableResolver.setPreferredPath(nil)
        }
        let resolved = PiExecutableResolver().resolve()?.path
        if let resolved, !resolved.isEmpty {
            setPiExecutablePath(resolved)
            return resolved
        }
        return appSettings.piExecutablePath.flatMap { raw in
            let expanded = (raw as NSString).expandingTildeInPath
            return FileManager.default.isExecutableFile(atPath: expanded) ? expanded : nil
        }
    }

    /// Update the display name shown on user transcript bubbles.
    ///
    /// - Parameter name: Free-form display name; empty restores default "You".
    func setUserDisplayName(_ name: String) {
        appSettingsController.userDisplayName = name
        syncAppSettings()
    }

    /// Import a user-picked image as the transcript avatar.
    ///
    /// - Parameter url: Local image file. Required.
    func setUserAvatar(from url: URL) {
        do {
            try appSettingsController.setUserAvatar(from: url)
            syncAppSettings()
        } catch {
            NSLog("[profile] setUserAvatar failed: \(error.localizedDescription)")
        }
    }

    /// Save a cropped square avatar from the crop sheet.
    ///
    /// - Parameter image: Cropped image from `UserAvatarCropSheet`. Required.
    func setUserAvatar(image: NSImage) {
        do {
            try appSettingsController.setUserAvatar(image: image)
            syncAppSettings()
        } catch {
            NSLog("[profile] setUserAvatar(image:) failed: \(error.localizedDescription)")
        }
    }

    /// Remove the custom user avatar.
    func clearUserAvatar() {
        appSettingsController.clearUserAvatar()
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

    func markLoopsOpenedFromSidebar() {
        guard appSettingsController.markLoopsOpenedFromSidebar() else { return }
        syncAppSettings()
    }

    // MARK: - Color themes
    //
    // Theme state is read by the UI straight off `appSettings` (the observable
    // store) — `appSettings.selectedThemeID` / `appSettings.customThemes` — so a
    // change reliably re-renders the Settings tab. These mutators apply the
    // change to `ThemeManager` whenever the *active* theme is affected.

    func selectTheme(id: UUID) {
        guard appSettingsController.selectTheme(id: id) else { return }
        syncAppSettings()
        ThemeManager.shared.apply(appSettingsController.resolvedActiveTheme)
    }

    func setPiAgentMarkdownHighlightingEnabled(_ isEnabled: Bool) {
        guard appSettingsController.setPiAgentMarkdownHighlightingEnabled(isEnabled) else { return }
        syncAppSettings()
        ThemeManager.shared.setMarkdownHighlightingEnabled(isEnabled)
    }

    func addCustomTheme(_ theme: Theme) {
        guard appSettingsController.addCustomTheme(theme) else { return }
        syncAppSettings()
    }

    func updateCustomTheme(_ theme: Theme) {
        guard appSettingsController.updateCustomTheme(theme) else { return }
        syncAppSettings()
        if appSettingsController.resolvedActiveTheme.id == theme.id {
            ThemeManager.shared.apply(appSettingsController.resolvedActiveTheme)
        }
    }

    func deleteCustomTheme(id: UUID) {
        guard appSettingsController.deleteCustomTheme(id: id) else { return }
        syncAppSettings()
        ThemeManager.shared.apply(appSettingsController.resolvedActiveTheme)
    }

    /// Duplicates any theme into a new editable custom theme and returns it.
    @discardableResult
    func duplicateTheme(id: UUID) -> Theme? {
        guard let copy = appSettingsController.duplicateTheme(id: id) else { return nil }
        syncAppSettings()
        return copy
    }

    // MARK: - App icon

    var selectedAppIcon: AppIconChoice {
        appSettingsController.selectedAppIcon
    }

    func selectAppIcon(_ choice: AppIconChoice) {
        guard appSettingsController.selectAppIcon(choice) else { return }
        syncAppSettings()
        AppIconChoice.apply(choice)
    }

    func chooseProjectsRootDirectory(replacingExisting: Bool = false) {
        guard appSettingsController.chooseProjectsRootDirectory(replacingExisting: replacingExisting) else { return }
        handleProjectsRootSettingsChange()
    }

    func useSuggestedProjectsRootDirectory(replacingExisting: Bool = false) {
        guard appSettingsController.useSuggestedProjectsRootDirectory(replacingExisting: replacingExisting) else { return }
        handleProjectsRootSettingsChange()
    }

    func addProjectsRootPaths(_ paths: [String]) {
        guard appSettingsController.addProjectsRootPaths(paths) else { return }
        handleProjectsRootSettingsChange()
    }

    func removeProjectsRootPath(_ path: String) {
        guard appSettingsController.removeProjectsRootPath(path) else { return }
        handleProjectsRootSettingsChange()
    }

    func replaceProjectsRootPath(at index: Int, with path: String) {
        guard appSettingsController.replaceProjectsRootPath(at: index, with: path) else { return }
        handleProjectsRootSettingsChange()
    }

    func resetProjectsRootPathsToDefault() {
        guard appSettingsController.resetProjectsRootPathsToDefault() else { return }
        handleProjectsRootSettingsChange()
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

    var piAgentLaunchPreview: String {
        appSettingsController.piAgentLaunchPreview
    }

    func refreshDiscoveredPiExtensions() {
        piExtensionsRefreshToken &+= 1
    }

    func requestAddMCPServer() { mcpAddRequestToken &+= 1 }
    func requestRefreshMCPServers() { mcpRefreshRequestToken &+= 1 }

    func isPiExtensionEnabled(_ candidate: PiExtensionCandidate) -> Bool {
        appSettingsController.isPiExtensionEnabled(candidate)
    }

    func setPiAgentExtensionLoadingMode(_ mode: PiAgentExtensionLoadingMode) {
        guard appSettingsController.setPiAgentExtensionLoadingMode(mode) else { return }
        syncAppSettings()
        reconcileRunningSessionLaunchResourceFingerprints()
    }

    func setPiExtension(_ candidate: PiExtensionCandidate, enabled: Bool) {
        guard appSettingsController.setPiExtension(candidate, enabled: enabled) else { return }
        syncAppSettings()
        reconcileRunningSessionLaunchResourceFingerprints()
    }

    /// Caller passes the already-discovered candidate list (the Extensions screen
    /// discovers off-main and caches) so this never triggers filesystem I/O.
    func setAllPiExtensions(_ candidates: [PiExtensionCandidate], enabled: Bool) {
        guard appSettingsController.setAllPiExtensions(candidates, enabled: enabled) else { return }
        syncAppSettings()
        reconcileRunningSessionLaunchResourceFingerprints()
    }

    func prunePiExtensionSelection(to candidates: [PiExtensionCandidate]) {
        guard appSettingsController.prunePiExtensionSelection(to: candidates) else { return }
        syncAppSettings()
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
        if isEnabled { warmMemoryEmbedder() }
        reconcileRunningSessionLaunchResourceFingerprints()
    }

    /// Kicks off the on-device embedding model download/load in the background so
    /// the first memory recall isn't empty while the OS fetches the asset. Runs at
    /// launch and when memory is switched on; idempotent and a no-op when memory is
    /// off or the model is already loaded. Once the asset is on disk, later launches
    /// just reload it locally (no network).
    func warmMemoryEmbedder() {
        guard appSettings.agentMemoryEnabled else { return }
        agentMemoryStore.warmEmbedder()
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
        reconcileRunningSessionLaunchResourceFingerprints()
    }

    func createAgentMemory(title: String, summary: String, body: String, kind: AgentMemoryKind, tags: [String]) {
        do {
            let record = try agentMemoryStore.createMemory(
                kind: kind,
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
            let eventKind: AgentMemoryEventKind
            switch status {
            case .archived:
                eventKind = .archived
            case .stale:
                eventKind = .stale
            default:
                eventKind = .edited
            }
            appendMemoryEvent(eventKind, records: [record], summary: "Set memory status to \(status.displayName): \(record.title).")
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
        // No model auto-pick on enable: a nil identifier means Default model
        // (the user's Pi default), same as every other automation.
        syncAppSettings()
    }

    func setPiAgentGitAutomationRequiresConfirmation(_ isEnabled: Bool) {
        guard appSettingsController.setPiAgentGitAutomationRequiresConfirmation(isEnabled) else { return }
        syncAppSettings()
    }

    func setPiAgentAutoUpdateEnabled(_ isEnabled: Bool) {
        guard appSettingsController.setPiAgentAutoUpdateEnabled(isEnabled) else { return }
        syncAppSettings()
    }

    func setPiAgentCommitMessageModelIdentifier(_ identifier: String?) {
        guard appSettingsController.setPiAgentCommitMessageModelIdentifier(identifier) else { return }
        syncAppSettings()
    }

    func setPiAgentSessionsUseWorktree(_ isEnabled: Bool) {
        guard appSettingsController.setPiAgentSessionsUseWorktree(isEnabled) else { return }
        syncAppSettings()
    }

    func setPiAgentSessionsKeepWorktreeAfterMerge(_ isEnabled: Bool) {
        guard appSettingsController.setPiAgentSessionsKeepWorktreeAfterMerge(isEnabled) else { return }
        syncAppSettings()
    }

    func setAutoGenerateAgentAvatarPrompts(_ isEnabled: Bool) {
        guard appSettingsController.setAutoGenerateAgentAvatarPrompts(isEnabled) else { return }
        // No model auto-pick on enable: nil identifier = Default model.
        syncAppSettings()
    }

    func setAgentAvatarPromptModelIdentifier(_ identifier: String?) {
        guard appSettingsController.setAgentAvatarPromptModelIdentifier(identifier) else { return }
        syncAppSettings()
    }

    func setSkillDescriptionModelIdentifier(_ identifier: String?) {
        guard appSettingsController.setSkillDescriptionModelIdentifier(identifier) else { return }
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
        panel.message = LanguageStore.shared.t("vm.choosePiExtension")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? PiInjectedCommandCatalog.importCommandFile(url)
        syncAppSettings()
    }

    func piAgentTitleGenerationModel() -> AvailableModel? {
        if let identifier = appSettings.piAgentTitleGenerationModelIdentifier,
           let selected = automationAvailableModels.first(where: { $0.identifier == identifier }) {
            return selected
        }
        return defaultPiAgentModel() ?? foundationAutomationModel ?? enabledAvailableModels.first
    }

    func piAgentCommitMessageModel() -> AvailableModel? {
        guard appSettings.piAgentGitAutomationEnabled else { return nil }
        if let identifier = appSettings.piAgentCommitMessageModelIdentifier,
           let selected = automationAvailableModels.first(where: { $0.identifier == identifier }) {
            return selected
        }
        // No explicit pick = follow the user's Pi default model, like every
        // other automation (the picker's Default model option).
        return defaultPiAgentModel() ?? foundationAutomationModel ?? enabledAvailableModels.first
    }

    func agentAvatarPromptGenerationModel() -> AvailableModel? {
        if let identifier = appSettings.agentAvatarPromptModelIdentifier,
           let selected = automationAvailableModels.first(where: { $0.identifier == identifier }) {
            return selected
        }
        // The picker labels the nil choice Default model — resolve it as the
        // user's Pi default first (it used to silently prefer Apple Foundation
        // Models, contradicting the label).
        return defaultPiAgentModel() ?? foundationAutomationModel ?? enabledAvailableModels.first
    }

    func generateAgentAvatarPrompt(for agent: EffectiveAgentRecord) async throws -> String {
        guard let model = agentAvatarPromptGenerationModel() else {
            throw PiAgentShipService.ShipError.noModel
        }
        let projectPath = agent.projectRoot ?? selectedProjectPath ?? primaryProjectsRootPath
        let projectURL = URL(fileURLWithPath: projectPath, isDirectory: true)
        let environment = EnvRuntimeEnvironment().environment()
        return try await agentAvatarPromptService.generatePrompt(for: agent, model: model, projectURL: projectURL, environment: environment)
    }

    /// Resolves the model used for AI skill summaries. An explicit pick in
    /// Automations wins; otherwise follows the user's Pi default model, with
    /// Apple Foundation Models and then another enabled model as fallbacks.
    func skillDescriptionGenerationModel() -> AvailableModel? {
        if let identifier = appSettings.skillDescriptionModelIdentifier,
           let selected = automationAvailableModels.first(where: { $0.identifier == identifier }) {
            return selected
        }
        return defaultPiAgentModel() ?? foundationAutomationModel ?? enabledAvailableModels.first
    }

    /// Read full SKILL.md bytes from a discovery clone (git mode).
    func readRemoteSkillFile(directory: String, inCloneAt clonePath: URL) async throws -> String {
        try await skillRepositorySyncService.readSkillFile(directory: directory, inCloneAt: clonePath)
    }

    /// Cache-aware summary generation: returns a previously stored entry when
    /// the SKILL.md byte hash matches, otherwise dispatches to the service and
    /// writes the result back into the on-disk cache.
    func generateSkillDescription(skillContent: String) async throws -> String {
        guard let model = skillDescriptionGenerationModel() else {
            throw SkillDescriptionGenerationService.GenerationError.rpc(LanguageStore.shared.t("vm.noModelForSkillSummaries"))
        }
        let hash = SkillDescriptionCache.sha256(of: Data(skillContent.utf8))
        if let cached = SkillDescriptionCache.get(hash: hash) {
            return cached.summary
        }
        let projectPath = selectedProjectPath ?? primaryProjectsRootPath
        let projectURL = URL(fileURLWithPath: projectPath, isDirectory: true)
        let environment = EnvRuntimeEnvironment().environment()
        let summary = try await skillDescriptionService.generate(
            skillContent: skillContent,
            model: model,
            projectURL: projectURL,
            environment: environment
        )
        SkillDescriptionCache.put(hash: hash, summary: summary, modelIdentifier: model.identifier)
        return summary
    }

}
