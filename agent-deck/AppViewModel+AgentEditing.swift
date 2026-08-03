import Foundation
import SwiftUI

// MARK: - Agent drafts, assignment, builtins, post-edit refresh

extension AppViewModel {
    func patchEffectiveAgentSkills(agentName: String, skills: [String]) {
        func patch(_ snap: ScanSnapshot) -> ScanSnapshot {
            guard snap.effectiveAgents.contains(where: { $0.name == agentName }) else { return snap }
            let patchedAgents = snap.effectiveAgents.map { record -> EffectiveAgentRecord in
                guard record.name == agentName else { return record }
                var resolved = record.resolved
                resolved.skills = skills
                return EffectiveAgentRecord(
                    id: record.id,
                    name: record.name,
                    projectRoot: record.projectRoot,
                    builtin: record.builtin,
                    globalCustom: record.globalCustom,
                    projectCustom: record.projectCustom,
                    userOverride: record.userOverride,
                    projectOverride: record.projectOverride,
                    resolved: resolved,
                    resolutionKind: record.resolutionKind
                )
            }
            return ScanSnapshot(
                projectRoot: snap.projectRoot,
                builtinAgents: snap.builtinAgents,
                globalAgents: snap.globalAgents,
                projectAgents: snap.projectAgents,
                legacyProjectAgents: snap.legacyProjectAgents,
                effectiveAgents: patchedAgents,
                libraryAgents: snap.libraryAgents,
                skills: snap.skills,
                librarySkills: snap.librarySkills,
                promptTemplates: snap.promptTemplates,
                libraryPromptTemplates: snap.libraryPromptTemplates,
                settings: snap.settings,
                envKeys: snap.envKeys,
                warnings: snap.warnings
            )
        }
        globalSnapshot = patch(globalSnapshot)
        allProjectSnapshots = allProjectSnapshots.mapValues(patch)
        snapshot = patch(snapshot)
    }

    /// Mirror a `.custom` agent-draft save into the in-memory snapshots so
    /// `cachedDisplayAgentByID` (read by the detail pane via `selectedAgent`)
    /// and `displayAgentsRevision` (drives the list `cachedLayout` rebuild)
    /// reflect the new config before the post-save rescan lands.
    ///
    /// Skips renames — `EffectiveAgentRecord.id` and `AgentRecord.id` both
    /// encode the name, so a rename needs the existing refresh path that also
    /// runs the `pendingSelectAgentName` flow. Skips builtin-override edits;
    /// those mutate a different on-disk structure and use `refreshSynchronouslyBlocksMainUntilDone`.
    func patchEffectiveAgentConfig(originalName: String, newConfig: AgentConfig, filePath: String?) {
        guard originalName == newConfig.name else { return }

        func matches(_ record: AgentRecord) -> Bool {
            guard record.name == originalName else { return false }
            if let filePath, !filePath.isEmpty { return record.filePath == filePath }
            return true
        }

        func updated(_ record: AgentRecord) -> AgentRecord {
            AgentRecord(
                id: record.id,
                name: newConfig.name,
                description: newConfig.description,
                source: record.source,
                filePath: record.filePath,
                rawFrontmatter: record.rawFrontmatter,
                promptBody: newConfig.systemPrompt,
                parsed: newConfig
            )
        }

        func patchAgents(_ records: [AgentRecord]) -> [AgentRecord] {
            records.map { matches($0) ? updated($0) : $0 }
        }

        func patchEffective(_ records: [EffectiveAgentRecord]) -> [EffectiveAgentRecord] {
            records.map { record -> EffectiveAgentRecord in
                guard record.name == originalName else { return record }
                let newGlobalCustom = record.globalCustom.map { matches($0) ? updated($0) : $0 }
                let newProjectCustom = record.projectCustom.map { matches($0) ? updated($0) : $0 }
                // Custom-agent resolution: project > global > builtin, with no
                // overrides applied (overrides only graft onto a builtin winner).
                // Match `PiAgentLaunchResolver.effectiveCustomAgent`'s winner pick.
                let winner = newProjectCustom ?? newGlobalCustom ?? record.builtin
                let resolved = winner?.parsed ?? record.resolved
                return EffectiveAgentRecord(
                    id: record.id,
                    name: record.name,
                    projectRoot: record.projectRoot,
                    builtin: record.builtin,
                    globalCustom: newGlobalCustom,
                    projectCustom: newProjectCustom,
                    userOverride: record.userOverride,
                    projectOverride: record.projectOverride,
                    resolved: resolved,
                    resolutionKind: record.resolutionKind
                )
            }
        }

        func patch(_ snap: ScanSnapshot) -> ScanSnapshot {
            ScanSnapshot(
                projectRoot: snap.projectRoot,
                builtinAgents: snap.builtinAgents,
                globalAgents: patchAgents(snap.globalAgents),
                projectAgents: patchAgents(snap.projectAgents),
                legacyProjectAgents: patchAgents(snap.legacyProjectAgents),
                effectiveAgents: patchEffective(snap.effectiveAgents),
                libraryAgents: patchAgents(snap.libraryAgents),
                skills: snap.skills,
                librarySkills: snap.librarySkills,
                promptTemplates: snap.promptTemplates,
                libraryPromptTemplates: snap.libraryPromptTemplates,
                settings: snap.settings,
                envKeys: snap.envKeys,
                warnings: snap.warnings
            )
        }

        globalSnapshot = patch(globalSnapshot)
        allProjectSnapshots = allProjectSnapshots.mapValues(patch)
        snapshot = patch(snapshot)
    }

    /// In-memory patch of `settings[].agentOverrides[name]["disabled"]` followed
    /// by a re-resolve. Matches the skill-assignment fast path: no disk re-scan,
    /// so toggles render immediately instead of waiting for `refresh()`. The
    /// file watcher will still fire later for the actual JSON write, but the
    /// resulting snapshot is identical so there is no visible flash.
    func patchBuiltinDisabledOverride(agentName: String, scope: AgentEditingTarget.OverrideScope, isDisabled: Bool, explicitProjectRoot: String? = nil) {
        let targetPath: String
        switch scope {
        case .global:
            targetPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/settings.json").path
        case .project:
            guard let projectRoot = explicitProjectRoot ?? selectedProjectPath else { return }
            targetPath = URL(fileURLWithPath: projectRoot).appendingPathComponent(".pi/settings.json").path
        }

        func patch(_ snap: ScanSnapshot) -> ScanSnapshot {
            let updatedSettings: [SettingsSummary] = snap.settings.map { summary in
                guard summary.path == targetPath else { return summary }
                var overrides = summary.agentOverrides
                if let idx = overrides.firstIndex(where: { $0.agentName == agentName }) {
                    var values = overrides[idx].values
                    values["disabled"] = .bool(isDisabled)
                    overrides[idx] = BuiltinOverrideRecord(
                        agentName: agentName,
                        scope: ScopeID(kind: .override, path: targetPath),
                        settingsPath: targetPath,
                        values: values
                    )
                } else {
                    overrides.append(BuiltinOverrideRecord(
                        agentName: agentName,
                        scope: ScopeID(kind: .override, path: targetPath),
                        settingsPath: targetPath,
                        values: ["disabled": .bool(isDisabled)]
                    ))
                    overrides.sort { $0.agentName.localizedCaseInsensitiveCompare($1.agentName) == .orderedAscending }
                }
                return SettingsSummary(
                    path: summary.path,
                    packages: summary.packages,
                    prompts: summary.prompts,
                    disableBuiltins: summary.disableBuiltins,
                    agentOverrides: overrides
                )
            }
            return ScanSnapshot(
                projectRoot: snap.projectRoot,
                builtinAgents: snap.builtinAgents,
                globalAgents: snap.globalAgents,
                projectAgents: snap.projectAgents,
                legacyProjectAgents: snap.legacyProjectAgents,
                effectiveAgents: snap.effectiveAgents,
                libraryAgents: snap.libraryAgents,
                skills: snap.skills,
                librarySkills: snap.librarySkills,
                promptTemplates: snap.promptTemplates,
                libraryPromptTemplates: snap.libraryPromptTemplates,
                settings: updatedSettings,
                envKeys: snap.envKeys,
                warnings: snap.warnings
            )
        }

        globalSnapshot = patch(globalSnapshot)
        allProjectSnapshots = allProjectSnapshots.mapValues(patch)
        snapshot = patch(snapshot)

        reconcileSnapshotsFromPreferences()
    }


    func setAgentSelection(_ selection: Set<String>?, for sessionID: UUID) {
        piAgentSessionStore.updateSession(sessionID, bumpUpdatedAt: false) { session in
            session.agentSelection = session.isNoProject ? nil : selection
        }
        reconcileRunningSessionLaunchResourceFingerprints()
    }

    func setAgentLaunchOverride(
        _ value: PiAgentSessionLaunchOverrideValue?,
        for agentName: String,
        field: WritableKeyPath<PiAgentSessionAgentLaunchOverride, PiAgentSessionLaunchOverrideValue?>,
        sessionID: UUID
    ) {
        piAgentSessionStore.updateSession(sessionID, bumpUpdatedAt: false) { session in
            guard !session.isNoProject else { return }
            var overrides = session.agentLaunchOverrides ?? [:]
            var override = overrides[agentName] ?? .init(model: nil, thinking: nil)
            override[keyPath: field] = value
            if override.isEmpty {
                overrides.removeValue(forKey: agentName)
            } else {
                overrides[agentName] = override
            }
            session.agentLaunchOverrides = overrides.isEmpty ? nil : overrides
        }
    }

    func settingsSummary(for scope: AgentEditingTarget.OverrideScope) -> SettingsSummary? {
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


    func makeAgentDraft(for agent: EffectiveAgentRecord, preferredOverrideScope: AgentEditingTarget.OverrideScope? = nil) -> AgentEditorDraft? {
        agentPersistence.makeDraft(for: agent, preferredOverrideScope: preferredOverrideScope)
    }

    func saveAgentDrafts(_ pairs: [(draft: AgentEditorDraft, agent: EffectiveAgentRecord)]) throws {
        guard !pairs.isEmpty else { return }
        for pair in pairs {
            try agentPersistence.save(pair.draft, original: pair.agent, projectRoot: selectedProjectPath)
        }
        var needsGlobalRefresh = false
        var projectPaths: Set<String> = []
        var didPatchInMemory = false
        for pair in pairs {
            switch pair.draft.target {
            case .custom(.global), .custom(.library), .builtinOverride(.global):
                needsGlobalRefresh = true
            case .custom(.project):
                if let path = pair.draft.sourcePath.flatMap(projectPath(containing:)) ?? selectedProjectPath {
                    projectPaths.insert(path)
                }
            case .builtinOverride(.project):
                if let path = selectedProjectPath {
                    projectPaths.insert(path)
                }
            }
            // Sync in-memory patch for custom edits so the panes update before
            // the rescan lands. Matches the single-save fast path in `saveAgentDraft`.
            if case .custom = pair.draft.target, pair.draft.originalName == pair.draft.config.name {
                patchEffectiveAgentConfig(
                    originalName: pair.draft.originalName,
                    newConfig: pair.draft.config,
                    filePath: pair.draft.sourcePath
                )
                didPatchInMemory = true
            }
        }
        if didPatchInMemory {
            rebuildWarningCaches()
        }
        if needsGlobalRefresh {
            refresh(includeModels: false, silentlyReconcile: didPatchInMemory)
        }
        for path in projectPaths {
            refreshAfterProjectScopedChange(projectPath: path)
        }
    }

    func saveAgentDraft(_ draft: AgentEditorDraft, for agent: EffectiveAgentRecord) throws {
        try agentPersistence.save(draft, original: agent, projectRoot: selectedProjectPath)
        // Fast-path: mirror the disk write into the in-memory snapshots so the
        // detail pane (reading `cachedDisplayAgentByID`) and the list layout
        // (driven by `displayAgentsRevision`) reflect the new config now,
        // instead of waiting for `refreshAfterAgentDraftChange`'s async rescan.
        // Skips rename + builtin-override edits; those keep the existing flow.
        if case .custom = draft.target, draft.originalName == draft.config.name {
            patchEffectiveAgentConfig(originalName: draft.originalName, newConfig: draft.config, filePath: draft.sourcePath)
            rebuildWarningCaches()
        }
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
            mcpServers: nil,
            extensions: nil,
            skills: [],
            output: nil,
            defaultExpectedOutcome: .reportOnly,
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

        // Drop the redundant synchronous rescan; the async refresh reconciles.
        // `pendingSelectAgentName` keeps the selection on the renamed agent
        // once that fresh snapshot lands.
        pendingSelectAgentName = newName
        refresh(includeModels: false, scanAllProjects: true)
    }

    func agent(_ agent: AgentRecord, isEnabledFor project: DiscoveredProject) -> Bool {
        projectPreference(for: project.path).assignedAgentNames.contains(agent.name)
    }

    func assignedProjects(for agent: AgentRecord) -> [DiscoveredProject] {
        enabledProjects.filter { self.agent(agent, isEnabledFor: $0) }
    }

    /// Read-only accessor for the per-agent skill-visibility cache. The full map
    /// is computed by `buildSkillVisibilityIssuesByAgentID()` at refresh

    func agentIsEnabledGlobally(_ agent: AgentRecord) -> Bool {
        appSettings.defaultAgentNames.contains(agent.name)
    }

    func setAgent(_ agent: AgentRecord, enabled: Bool, for project: DiscoveredProject) throws {
        projectPreferencesStore.setAssignedAgent(agent.name, assigned: enabled, for: project.path)
        applyProjectPreferenceChanges()
        // Project assignment only mutates UserDefaults — reconcile the
        // affected `effectiveAgents` in memory instead of rescanning disk.
        reconcileSnapshotsFromPreferences()
    }

    func assignAgentNames(_ names: [String], toProjectPath projectPath: String) {
        let cleaned = names
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !projectPath.isEmpty, !cleaned.isEmpty else { return }
        for name in Set(cleaned) {
            projectPreferencesStore.setAssignedAgent(name, assigned: true, for: projectPath)
        }
        applyProjectPreferenceChanges()
        reconcileSnapshotsFromPreferences()
    }

    func enableAgentGlobally(_ agent: AgentRecord) throws {
        guard appSettingsController.setDefaultAgent(agent.name, enabled: true) else { return }
        appSettings = appSettingsController.settings
        // Global assignment only mutates app settings. Reconcile the already-
        // loaded snapshots in memory so the row can move sections without a
        // refresh window that drops selection onto another agent.
        reconcileSnapshotsFromPreferences()
    }

    func disableAgentGlobally(_ agent: AgentRecord) throws {
        guard appSettingsController.setDefaultAgent(agent.name, enabled: false) else { return }
        appSettings = appSettingsController.settings
        // Global assignment only mutates app settings. Reconcile the already-
        // loaded snapshots in memory so the row can move sections without a
        // refresh window that drops selection onto another agent.
        reconcileSnapshotsFromPreferences()
    }

    func moveAgentToLibrary(_ agent: AgentRecord) throws {
        _ = try ensureLibraryAgent(for: agent)
        refresh(includeModels: false)
    }

    /// Custom and library agents own a real file that can be removed. Builtin and
    /// package agents are read-only — they are disabled or overridden, not deleted.
    func canDeleteAgent(_ agent: AgentRecord) -> Bool {
        switch agent.source.kind {
        case .builtin, .package:
            return false
        case .global, .project, .legacyProject, .override, .library:
            return true
        }
    }

    func deleteAgent(_ agent: AgentRecord) throws {
        guard canDeleteAgent(agent) else { throw CocoaError(.fileWriteNoPermission) }

        try removeAgentReferences(named: agent.name)
        let fileURL = URL(fileURLWithPath: agent.filePath).standardizedFileURL
        try FileManager.default.trashItem(at: fileURL, resultingItemURL: nil)
        // Reconcile in the background — no blocking rescan. The row updates
        // when the fresh snapshot lands; a builtin of the same name correctly
        // reappears instead of the row being wrongly hidden, so agent deletion
        // is not optimistically hidden the way skill/prompt deletion is.
        refresh(includeModels: false, scanAllProjects: true)
    }

    func removeAgentReferences(named agentName: String) throws {
        _ = appSettingsController.setDefaultAgent(agentName, enabled: false)
        appSettings = appSettingsController.settings

        for projectPath in projectPreferencesStore.preferencesByPath.keys {
            projectPreferencesStore.setAssignedAgent(agentName, assigned: false, for: projectPath)
        }
        applyProjectPreferenceChanges()
    }

    func setDisableBuiltins(_ isDisabled: Bool, scope: AgentEditingTarget.OverrideScope) {
        do {
            try agentPersistence.setDisableBuiltins(isDisabled, scope: scope, projectRoot: selectedProjectPath)
            refreshAfterOverrideChange(scope: scope)
        } catch {
            repositoryLastError = error.localizedDescription
        }
    }

    func setBuiltinDisabled(_ isDisabled: Bool, for agent: EffectiveAgentRecord, scope: AgentEditingTarget.OverrideScope, explicitProjectRoot: String? = nil) {
        let targetRoot = explicitProjectRoot ?? selectedProjectPath
        do {
            try agentPersistence.setBuiltinDisabled(isDisabled, for: agent, scope: scope, projectRoot: targetRoot)
            patchBuiltinDisabledOverride(agentName: agent.name, scope: scope, isDisabled: isDisabled, explicitProjectRoot: explicitProjectRoot)
        } catch {
            repositoryLastError = error.localizedDescription
        }
    }

    /// Builtin enablement is global-only; Agent Deck never rewrites project
    /// `.pi/settings.json` subagent configuration.
    func setBuiltinGloballyEnabled(_ isEnabled: Bool, for agent: EffectiveAgentRecord) {
        setBuiltinDisabled(!isEnabled, for: agent, scope: .global)
    }

    func patchBuiltinDisabledOverrideCleared(agentName: String, projectRoot: String) {
        let targetPath = URL(fileURLWithPath: projectRoot).appendingPathComponent(".pi/settings.json").path

        func patch(_ snap: ScanSnapshot) -> ScanSnapshot {
            let updatedSettings: [SettingsSummary] = snap.settings.map { summary in
                guard summary.path == targetPath else { return summary }
                var overrides = summary.agentOverrides
                if let idx = overrides.firstIndex(where: { $0.agentName == agentName }) {
                    var values = overrides[idx].values
                    values.removeValue(forKey: "disabled")
                    if values.isEmpty {
                        overrides.remove(at: idx)
                    } else {
                        overrides[idx] = BuiltinOverrideRecord(
                            agentName: agentName,
                            scope: ScopeID(kind: .override, path: targetPath),
                            settingsPath: targetPath,
                            values: values
                        )
                    }
                }
                return SettingsSummary(
                    path: summary.path,
                    packages: summary.packages,
                    prompts: summary.prompts,
                    disableBuiltins: summary.disableBuiltins,
                    agentOverrides: overrides
                )
            }
            return ScanSnapshot(
                projectRoot: snap.projectRoot,
                builtinAgents: snap.builtinAgents,
                globalAgents: snap.globalAgents,
                projectAgents: snap.projectAgents,
                legacyProjectAgents: snap.legacyProjectAgents,
                effectiveAgents: snap.effectiveAgents,
                libraryAgents: snap.libraryAgents,
                skills: snap.skills,
                librarySkills: snap.librarySkills,
                promptTemplates: snap.promptTemplates,
                libraryPromptTemplates: snap.libraryPromptTemplates,
                settings: updatedSettings,
                envKeys: snap.envKeys,
                warnings: snap.warnings
            )
        }

        globalSnapshot = patch(globalSnapshot)
        allProjectSnapshots = allProjectSnapshots.mapValues(patch)
        snapshot = patch(snapshot)

        reconcileSnapshotsFromPreferences()
    }

    /// Effective disabled state for a builtin in a specific project. Mirrors
    /// `PiAgentLaunchResolver`'s precedence so the per-project checkboxes
    /// show what Pi actually loads: explicit per-agent project override →
    /// project `disableBuiltins` → per-agent user override → user
    /// `disableBuiltins`. Falling through to global state matters when the
    /// project has no settings file yet (e.g. just-added project), otherwise
    /// brand-new projects render as "enabled" even when global says disabled.
    func builtinIsDisabled(agentName: String, inProject projectPath: String) -> Bool {
        let projectSettingsPath = URL(fileURLWithPath: projectPath).appendingPathComponent(".pi/settings.json").standardizedFileURL.path
        let projectSettings = allProjectSnapshots[projectPath]?.settings.first { summary in
            URL(fileURLWithPath: summary.path).standardizedFileURL.path == projectSettingsPath
        }
        if let projectOverrideDisabled = projectSettings?.agentOverrides.first(where: { $0.agentName == agentName })?.disabledOverride {
            return projectOverrideDisabled
        }
        if projectSettings?.disableBuiltins == true {
            return true
        }

        let globalSettingsPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pi/agent/settings.json").standardizedFileURL.path
        let globalSettings = globalSnapshot.settings.first { summary in
            URL(fileURLWithPath: summary.path).standardizedFileURL.path == globalSettingsPath
        }
        if let userOverrideDisabled = globalSettings?.agentOverrides.first(where: { $0.agentName == agentName })?.disabledOverride {
            return userOverrideDisabled
        }
        return globalSettings?.disableBuiltins == true
    }

    func toggleBuiltinDisabledGlobally(_ agent: EffectiveAgentRecord) {
        setBuiltinDisabled(!(agent.resolved.disabled ?? false), for: agent, scope: .global)
    }

    func builtinStateBadge(for agent: EffectiveAgentRecord) -> (text: String, color: Color)? {
        guard agent.builtin != nil, agent.globalCustom == nil, agent.projectCustom == nil else { return nil }

        let projectOverrideDisabled = agent.projectOverride?.disabledOverride
        let userOverrideDisabled = agent.userOverride?.disabledOverride

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
        // Cache hit (incl. an empty array) is authoritative — see
        // `rebuildWarningCaches()`. Miss → live compute (e.g. before first scan).
        if let cached = cachedAgentWarningsByID[agent.id] { return cached }
        return computeWarnings(for: agent)
    }

    func computeWarnings(for agent: EffectiveAgentRecord) -> [DiagnosticWarning] {
        let collectionNames = Set(appSettings.skillCollections.map(\.name))
        return globalSnapshot.warnings.filter { warning in
            if warning.id.hasPrefix("skill:\(agent.name):") {
                let missingName = String(warning.id.dropFirst("skill:\(agent.name):".count))
                if collectionNames.contains(missingName) { return false }
            }
            return warning.message.contains("Agent \(agent.name) ") || warning.message.contains("Agent \(agent.name)")
        }
    }

    func agentsExplicitlyUsingSkill(_ skill: SkillRecord) -> [EffectiveAgentRecord] {
        globalSnapshot.effectiveAgents
            .filter { $0.resolved.skills.contains(skill.name) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func agentsAmbientlySeeingSkill(_ skill: SkillRecord) -> [EffectiveAgentRecord] {
        []
    }

    func refreshAfterAgentDraftChange(_ draft: AgentEditorDraft) {
        switch draft.target {
        case let .custom(scope):
            guard scope == .project else {
                // Global agent edit (incl. setSkill→saveAgentDraft toggle) —
                // `patchEffectiveAgentSkills` already updated the in-memory
                // snapshot, so this scan is reconciliation only.
                refresh(includeModels: false, silentlyReconcile: true)
                return
            }
            refreshAfterProjectScopedChange(projectPath: draft.sourcePath.flatMap(projectPath(containing:)) ?? selectedProjectPath)
        case let .builtinOverride(scope):
            refreshAfterOverrideChange(scope: scope)
        }
    }

    func refreshAfterOverrideChange(scope: AgentEditingTarget.OverrideScope) {
        // Builtin-override changes feed bound, snapshot-derived toggles — the
        // Settings "Disable builtins" switch and the per-agent builtin-disable
        // control. Keep this synchronous so those toggles show the new state
        // immediately instead of snapping back while an async refresh is in
        // flight. Override edits are infrequent admin actions, so the brief
        // rescan is an acceptable cost here.
        switch scope {
        case .global:
            refreshSynchronouslyBlocksMainUntilDone(includeModels: false)
            refresh(includeModels: false)
        case .project:
            if let projectPath = selectedProjectPath {
                refreshSynchronouslyBlocksMainUntilDone(includeModels: false, scanAllProjects: false, extraProjectPathsToScan: [projectPath])
                refresh(includeModels: false, scanAllProjects: false, extraProjectPathsToScan: [projectPath])
            } else {
                refreshSynchronouslyBlocksMainUntilDone(includeModels: false)
                refresh(includeModels: false)
            }
        }
    }

    func refreshAfterFileScopedChange(sourceKind: ResourceScopeKind, filePath: String) {
        switch sourceKind {
        case .project, .legacyProject:
            refreshAfterProjectScopedChange(projectPath: projectPath(containing: filePath) ?? selectedProjectPath)
        default:
            refresh(includeModels: false)
        }
    }

    func refreshAfterProjectScopedChange(projectPath: String?) {
        // Async-only: agent-draft saves, override edits and env-key changes all
        // route through here; a synchronous rescan would freeze the UI on each.
        // `silentlyReconcile`: the visible state has already been patched in
        // memory (e.g. by `patchEffectiveAgentSkills`), so the list stays
        // interactive while the background scan reconciles.
        guard let projectPath else {
            refresh(includeModels: false, silentlyReconcile: true)
            return
        }
        refresh(includeModels: false, scanAllProjects: false, extraProjectPathsToScan: [projectPath], silentlyReconcile: true)
    }

    func projectPath(containing filePath: String) -> String? {
        enabledProjects.first { project in
            filePath == project.path || filePath.hasPrefix(project.path + "/")
        }?.path
    }

    func scopeSnapshot(for target: AgentEditingTarget) -> ScanSnapshot {
        switch target {
        case let .builtinOverride(scope):
            return scopedSnapshot(for: scope == .project)
        case let .custom(scope):
            return scopedSnapshot(for: scope == .project)
        }
    }

    func scopedSnapshot(for includeProject: Bool) -> ScanSnapshot {
        guard includeProject, let selectedProjectPath, let projectSnapshot = allProjectSnapshots[selectedProjectPath] else {
            return globalSnapshot
        }
        return projectSnapshot
    }


}
