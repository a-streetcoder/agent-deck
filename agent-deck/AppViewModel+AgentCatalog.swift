import Foundation

// MARK: - Agent display catalog, scoped snapshots, launch universe

extension AppViewModel {
    var allDisplayAgents: [EffectiveAgentRecord] { cachedAllDisplayAgents }

    /// Plain builtin rows for editors that must expose the bundled base even
    /// when the regular display list shows a custom replacement of the same
    /// name. These rows write settings overrides, never the bundled files.
    var builtinAgentModelRecords: [EffectiveAgentRecord] {
        let globalSettingsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/settings.json")
            .standardizedFileURL.path
        let globalOverrides = globalSnapshot.settings
            .first { URL(fileURLWithPath: $0.path).standardizedFileURL.path == globalSettingsPath }?
            .agentOverrides ?? []
        return globalSnapshot.builtinAgents
            .map { builtin in
                let userOverride = globalOverrides.first { $0.agentName == builtin.name }
                return EffectiveAgentRecord(
                    id: "builtin-model::\(builtin.name)",
                    name: builtin.name,
                    projectRoot: nil,
                    builtin: builtin,
                    globalCustom: nil,
                    projectCustom: nil,
                    userOverride: userOverride,
                    projectOverride: nil,
                    resolved: builtin.parsed,
                    resolutionKind: userOverride == nil ? .builtin : .builtinWithOverride
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The actual merge+sort. Called only from `rebuildWarningCaches()`.
    func computeAllDisplayAgents() -> [EffectiveAgentRecord] {
        // Sourced from `globalSnapshot` so the Agents view stays global even
        // when a project is selected for Issues/Memory. Mirrors the prior
        // no-project-selected presentation exactly.
        var byID: [EffectiveAgentRecord.ID: EffectiveAgentRecord] = [:]
        for agent in globalSnapshot.effectiveAgents { byID[agent.id] = agent }
        for agent in catalogOnlyEffectiveAgents { byID[agent.id] = agent }
        for agent in libraryOnlyEffectiveAgents { byID[agent.id] = agent }
        for agent in projectAssignedLibraryAgentsForAggregateView { byID[agent.id] = agent }
        return Array(byID.values)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func agentSearchHaystack(for agent: EffectiveAgentRecord) -> String {
        [agent.name, agent.resolved.description, agent.resolutionKind.rawValue, agent.sourcePath ?? "", agent.resolved.systemPrompt]
            .joined(separator: "\n")
            .lowercased()
    }

    func skillSearchHaystack(for skill: SkillRecord) -> String {
        [skill.name, skill.description ?? "", skill.source.kind.rawValue, skill.filePath, skill.body]
            .joined(separator: "\n")
            .lowercased()
    }

    func computeAllVisibleSkillRecords() -> [SkillRecord] {
        let records = deduplicateByID(globalSnapshot.skills + globalSnapshot.librarySkills)
            .sorted { lhs, rhs in
                let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                return lhs.source.kind.rawValue < rhs.source.kind.rawValue
            }
        guard !pendingDeletedSkillIDs.isEmpty else { return records }
        return records.filter { !pendingDeletedSkillIDs.contains($0.id) }
    }

    func rebuildVisibleSkillRecordCachesIfNeeded() {
        let records = computeAllVisibleSkillRecords()
        guard records != cachedAllVisibleSkillRecords else { return }
        cachedAllVisibleSkillRecords = records
        cachedSkillSearchHaystackByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, skillSearchHaystack(for: $0)) })
        visibleSkillRecordsRevision &+= 1
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
        // O(1) lookup over `cachedDisplayAgentByID`. The cache is sourced from
        // `cachedAllDisplayAgents` (a superset of `snapshot.effectiveAgents`,
        // `catalogOnlyEffectiveAgents`, and `libraryOnlyEffectiveAgents`), so
        // we drop the heavy fallback that recomputed the catalog walk on every
        // body read.
        guard let id = selectedAgentID else { return nil }
        return cachedDisplayAgentByID[id]
    }

    var catalogOnlyEffectiveAgents: [EffectiveAgentRecord] {
        // Global catalog: custom agents come from global user storage or
        // explicit library imports, independent of `selectedProjectPath`.
        let effectivePaths = Set(globalSnapshot.effectiveAgents.compactMap(\.sourcePath).map(standardizedPath))
        return agentCatalog(forProjectPath: nil)
            .filter { $0.source.kind != .builtin }
            .filter { !effectivePaths.contains(standardizedPath($0.filePath)) }
            .filter { $0.source.kind != .library }
            .map { catalogDisplayAgent(from: $0, projectRoot: nil) }
    }

    var libraryOnlyEffectiveAgents: [EffectiveAgentRecord] {
        // Global/custom winners hide library duplicates.
        let agentsThatHideLibrary = globalSnapshot.effectiveAgents
            .filter { $0.projectOverride == nil }
        let effectiveNames = Set(agentsThatHideLibrary.map(\.name))
        return globalSnapshot.libraryAgents
            .filter { !effectiveNames.contains($0.name) }
            .map { libraryDisplayAgent(from: $0, projectRoot: nil) }
    }

    /// Every agent a session could pick for its subagent catalog: the
    /// project-effective agents plus catalog-only and library agents not
    /// otherwise assigned. Parameterized by project path so it resolves for
    /// any session, not only the currently selected project.
    ///
    /// Results are memoized per project path; the cache is cleared via
    /// `clearAgentUniverseCache()` whenever any underlying snapshot
    /// publishes, so callers can read this on every `body` evaluation
    /// without rebuilding the catalog walk each time.
    /// Resolves the `EffectiveAgentRecord` an agent-bound session was created
    /// against. Looks up the session's `agentName` in the session's project
    /// snapshot first (so a project override wins), then falls back to the
    /// global snapshot and finally the cross-project union returned by
    /// `selectableAgentUniverse`. Returns `nil` when the agent is no longer
    /// present anywhere — the runner surfaces this as an "Agent Unavailable"
    /// transcript error.
    func boundAgent(for session: PiAgentSessionRecord) -> EffectiveAgentRecord? {
        guard session.isAgentBound, let name = session.agentName else { return nil }
        let projectPath = session.projectPathForProjectFeatures
        if let scoped = projectPath.flatMap({ allProjectSnapshots[$0]?.effectiveAgents.first(where: { $0.name == name }) }) {
            return scoped
        }
        if let global = globalSnapshot.effectiveAgents.first(where: { $0.name == name }) {
            return global
        }
        return projectPath.flatMap { selectableAgentUniverse(forProjectPath: $0).first { $0.name == name } }
    }

    /// Skill argument list (`--skill <name=path>` pairs) for a 1:1 agent chat.
    /// Reuses the subagent runner's resolver so the agent sees the same skill
    /// universe it would as a delegated child.
    func boundAgentSkillArguments(for agent: EffectiveAgentRecord) throws -> [String] {
        let projectPath = agent.projectRoot ?? snapshot.projectRoot
        let snap = projectPath.map { startupSnapshot(forProjectPath: $0) } ?? globalSnapshot
        return try childSkillArguments(for: agent, snapshot: snap)
    }

    func childSkillArguments(for agent: EffectiveAgentRecord, snapshot: ScanSnapshot) throws -> [String] {
        let collectionNames = Set(appSettings.skillCollections.map(\.name))
        let directNames = Set(agent.resolved.skills.filter { !collectionNames.contains($0) })
        let collectionIDs = Set(appSettings.skillCollections.filter { agent.resolved.skills.contains($0.name) }.map(\.id))
        let expandedNames = effectiveSkillNames(directNames: directNames, collectionIDs: collectionIDs, catalog: PiSkillLaunchResolver.catalog(from: snapshot))
        return try PiSkillLaunchResolver.childSkillArguments(
            agent: agent,
            snapshot: snapshot,
            expandedSkillNames: expandedNames,
            ignoredMissingSkillNames: []
        )
    }

    /// Popover entry point: build the session and launch Pi. Switches the
    /// sidebar to the agent screen so the new session is visible.
    func startAgentSession(agent: EffectiveAgentRecord, project: DiscoveredProject, initialInstruction: String?) {
        guard agent.resolved.disabled != true else {
            piAgentRunnerSurfaceError(message: "Agent '\(agent.name)' is disabled.")
            return
        }
        selectedSidebarItem = .agent
        ensurePiAgentModelCatalogLoaded()
        piAgentRunner.startAgentSession(agent: agent, project: project, initialInstruction: initialInstruction)
    }

    /// Picker-card entry point: bind a not-yet-launched draft to a single
    /// agent, turning it into a 1:1 chat in place instead of spawning a
    /// separate session. Pi hasn't launched yet, so this is a pure record
    /// mutation — the first send picks up the agent's system prompt and
    /// tools via `boundAgent(for:)`.
    func bindPiAgentDraft(_ sessionID: UUID, to agent: EffectiveAgentRecord) {
        guard agent.resolved.disabled != true else {
            piAgentRunnerSurfaceError(message: "Agent '\(agent.name)' is disabled.")
            return
        }
        piAgentSessionStore.updateSession(sessionID) { record in
            guard record.status == .draft, record.piSessionFile == nil, !record.isNoProject else { return }
            record.kind = .agent
            record.agentName = agent.name
            if !record.isTitleUserEdited {
                record.title = "Chat · \(agent.name)"
            }
        }
    }

    /// "Switch back" in the picker card: revert a bound draft to a regular
    /// project session. Only meaningful before the first message — once Pi
    /// has a session file the binding is baked into the conversation.
    func unbindPiAgentDraft(_ sessionID: UUID) {
        piAgentSessionStore.updateSession(sessionID) { record in
            guard record.status == .draft, record.piSessionFile == nil, record.kind == .agent else { return }
            record.kind = .project
            record.agentName = nil
            if !record.isTitleUserEdited {
                record.title = "Draft · \(record.projectName)"
            }
        }
    }

    /// Mutates a session's `agentName` and reruns it. Used by the "Switch
    /// agent…" affordance shown in the transcript header when the original
    /// agent disappears.
    func rebindAgent(sessionID: UUID, to agent: EffectiveAgentRecord) {
        guard let existing = piAgentSessionStore.sessions.first(where: { $0.id == sessionID }) else { return }
        guard existing.kind == .agent else { return }
        piAgentSessionStore.updateSession(sessionID) { record in
            record.agentName = agent.name
            record.title = "Chat · \(agent.name)"
            record.lastError = nil
            record.status = .draft
        }
        guard let refreshed = piAgentSessionStore.sessions.first(where: { $0.id == sessionID }) else { return }
        piAgentRunner.resume(session: refreshed)
    }

    func piAgentRunnerSurfaceError(message: String) {
        // The agent-chat start path has no transcript yet; route the message
        // through the existing GitHub-style banner so the user sees it.
        repositoryLastError = message
    }

    func selectableAgentUniverse(forProjectPath path: String) -> [EffectiveAgentRecord] {
        let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return [] }
        if let cached = agentUniverseCacheByProjectPath[path] {
            return cached
        }
        let snap = startupSnapshot(forProjectPath: path)
        let effective = snap.effectiveAgents
        let effectivePaths = Set(effective.compactMap(\.sourcePath).map(standardizedPath))
        let catalogOnly = agentCatalog(forProjectPath: path)
            .filter { $0.source.kind != .builtin && $0.source.kind != .library }
            .filter { !effectivePaths.contains(standardizedPath($0.filePath)) }
            .map { catalogDisplayAgent(from: $0, projectRoot: snap.projectRoot) }
        let effectiveNames = Set(effective.map(\.name))
        let libraryOnly = snap.libraryAgents
            .filter { !effectiveNames.contains($0.name) }
            .map { libraryDisplayAgent(from: $0, projectRoot: snap.projectRoot) }
        let result = effective + catalogOnly + libraryOnly
        agentUniverseCacheByProjectPath[path] = result
        return result
    }

    func clearAgentUniverseCache() {
        agentUniverseCacheByProjectPath.removeAll(keepingCapacity: true)
    }

    /// The exact, deduplicated set of subagents advertised to — and delegable
    /// by — a session. Single source of truth shared by the catalog prompt,
    /// the delegation lookups, and the session resources popover. A `nil`
    /// `agentSelection` keeps the historical default of all effective agents;
    /// an explicit selection is resolved against the full universe so an agent
    /// not assigned to the project can still be included.
    func catalogAgents(for session: PiAgentSessionRecord) -> [EffectiveAgentRecord] {
        guard !session.isNoProject, let projectPath = session.projectPathForProjectFeatures else { return [] }
        let agents: [EffectiveAgentRecord]
        if let selection = session.agentSelection {
            agents = selectableAgentUniverse(forProjectPath: projectPath)
                .filter { selection.contains($0.name) }
        } else {
            agents = startupSnapshot(forProjectPath: projectPath).effectiveAgents
        }
        var seen = Set<String>()
        return agents
            .filter { $0.resolved.disabled != true && seen.insert($0.name).inserted }
            .map { applyingSessionLaunchOverrides(to: $0, session: session) }
    }

    func applyingSessionLaunchOverrides(to agent: EffectiveAgentRecord, session: PiAgentSessionRecord) -> EffectiveAgentRecord {
        guard let override = session.agentLaunchOverrides?[agent.name] else { return agent }
        var resolved = agent.resolved
        switch override.model {
        case .piDefault:
            resolved.model = nil
        case let .value(value):
            resolved.model = value.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        case nil:
            break
        }
        switch override.thinking {
        case .piDefault:
            resolved.thinking = nil
        case let .value(value):
            resolved.thinking = value.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        case nil:
            break
        }
        return EffectiveAgentRecord(
            id: agent.id,
            name: agent.name,
            projectRoot: agent.projectRoot,
            builtin: agent.builtin,
            globalCustom: agent.globalCustom,
            projectCustom: agent.projectCustom,
            userOverride: agent.userOverride,
            projectOverride: agent.projectOverride,
            resolved: resolved,
            resolutionKind: agent.resolutionKind
        )
    }

    /// Whether a session has any non-disabled agent it could run as a subagent.
    /// Fast path: a usable effective agent (builtins normally qualify) returns
    /// immediately, so the broader global/imported catalog lookup only runs in
    /// the rare case where the project has no usable effective agents at all.
    func sessionHasSelectableAgents(_ session: PiAgentSessionRecord) -> Bool {
        guard !session.isNoProject, let projectPath = session.projectPathForProjectFeatures else { return false }
        if startupSnapshot(forProjectPath: projectPath)
            .effectiveAgents.contains(where: { $0.resolved.disabled != true }) {
            return true
        }
        return selectableAgentUniverse(forProjectPath: projectPath)
            .contains { $0.resolved.disabled != true }
    }

    var projectAssignedLibraryAgentsForAggregateView: [EffectiveAgentRecord] {
        // Global view — `globalSnapshot.projectRoot` is always nil here.
        guard globalSnapshot.projectRoot == nil else { return [] }
        let effectiveNames = Set(globalSnapshot.effectiveAgents.map(\.name))
        let libraryByName = Dictionary(uniqueKeysWithValues: globalSnapshot.libraryAgents.map { ($0.name, $0) })
        let assignedNames = Set(projectPreferencesByPath.values.flatMap(\.assignedAgentNames))
        let libraryNames = Set(globalSnapshot.libraryAgents.map(\.name))
        return assignedNames
            .filter { !effectiveNames.contains($0) && libraryNames.contains($0) }
            .compactMap { libraryByName[$0] }
            .map { libraryDisplayAgent(from: $0, projectRoot: nil) }
    }

    func catalogDisplayAgent(from record: AgentRecord, projectRoot: String?) -> EffectiveAgentRecord {
        EffectiveAgentRecord(
            id: "catalog::\(record.source.kind.rawValue)::\(record.filePath)",
            name: record.name,
            projectRoot: projectRoot,
            builtin: nil,
            globalCustom: record.source.kind == .global ? record : nil,
            projectCustom: record.source.kind == .project || record.source.kind == .legacyProject ? record : nil,
            userOverride: nil,
            projectOverride: nil,
            resolved: record.parsed,
            resolutionKind: record.source.kind == .global ? .globalCustom : .projectCustom
        )
    }

    func libraryDisplayAgent(from record: AgentRecord, projectRoot: String?) -> EffectiveAgentRecord {
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

    var allVisibleAgentRecords: [AgentRecord] {
        agentCatalog(forProjectPath: selectedProjectPath)
            .filter { $0.source.kind != .builtin }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func agentCatalog(forProjectPath projectPath: String?) -> [AgentRecord] {
        let records = globalSnapshot.globalAgents + globalSnapshot.libraryAgents
        return deduplicateByID(records)
    }

    func agentCatalog(globalSnapshot: ScanSnapshot, catalogProjectSnapshots: [ScanSnapshot]) -> [AgentRecord] {
        deduplicateByID(
            globalSnapshot.globalAgents +
            globalSnapshot.libraryAgents
        )
    }

    func scopedAgentSnapshot(_ base: ScanSnapshot, projectPath: String?, globalCatalogSnapshot: ScanSnapshot, catalogProjectSnapshots: [ScanSnapshot]) -> ScanSnapshot {
        let projectAgentNames = projectPath.map { projectPreference(for: $0).assignedAgentNames } ?? []
        return ScanSnapshot(
            projectRoot: base.projectRoot,
            builtinAgents: base.builtinAgents,
            globalAgents: base.globalAgents,
            projectAgents: base.projectAgents,
            legacyProjectAgents: base.legacyProjectAgents,
            effectiveAgents: PiAgentLaunchResolver.effectiveAgents(
                defaultAgentNames: appSettings.defaultAgentNames,
                projectAgentNames: projectAgentNames,
                snapshot: base,
                catalog: agentCatalog(globalSnapshot: globalCatalogSnapshot, catalogProjectSnapshots: catalogProjectSnapshots)
            ),
            libraryAgents: base.libraryAgents,
            skills: base.skills,
            librarySkills: base.librarySkills,
            promptTemplates: base.promptTemplates,
            libraryPromptTemplates: base.libraryPromptTemplates,
            settings: base.settings,
            envKeys: base.envKeys,
            warnings: base.warnings
        )
    }

    func migrateAgentAssignmentsFromDiscoveredFiles(globalSnapshot: ScanSnapshot, projectSnapshots: [String: ScanSnapshot]) {
        for name in Set(globalSnapshot.globalAgents.map(\.name)) {
            _ = appSettingsController.setDefaultAgent(name, enabled: true)
        }
        _ = appSettingsController.markAgentAssignmentsMigratedFromDiscoveredFiles()
        appSettings = appSettingsController.settings
        projectPreferencesByPath = projectPreferencesStore.preferencesByPath
    }

    var selectedSkill: SkillRecord? {
        allVisibleSkillRecords.first(where: { $0.id == selectedSkillID })
    }

    var allVisibleSkillRecords: [SkillRecord] {
        // Global resource catalog — independent of `selectedProjectPath` so the
        // Skills view stays global even when a project is selected for Issues.
        // Cached and revisioned to avoid sorting/comparing skill bodies in view
        // observation paths.
        cachedAllVisibleSkillRecords
    }

    /// Standardized `SKILL.md` paths of every skill currently in the catalog
    /// (builtin, global, project, package, and imported). The import sheet uses
    /// this to hide skills the user already has. Pure string work, no I/O — but
    /// O(catalog) to build, so callers should read it once and cache it rather
    /// than re-reading it per render.
    var catalogedSkillFilePaths: Set<String> {
        Set(allVisibleSkillRecords.map { URL(fileURLWithPath: $0.filePath).standardizedFileURL.path })
    }

    func startupSnapshot(forProjectPath path: String) -> ScanSnapshot {
        let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return globalSnapshot }
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        if let projectSnapshot = allProjectSnapshots[standardizedPath] {
            return scopedStartupSnapshot(projectSnapshot: projectSnapshot)
        }

        // A draft can target a project before its scan lands. Resolve that
        // project's assignments from the global catalog instead of leaking the
        // currently displayed (possibly unrelated) project's effective agents.
        let fallback = PiAgentLaunchResolver.projectFallbackSnapshot(
            from: globalSnapshot,
            projectRoot: standardizedPath
        )
        return scopedAgentSnapshot(
            fallback,
            projectPath: standardizedPath,
            globalCatalogSnapshot: globalSnapshot,
            catalogProjectSnapshots: Array(allProjectSnapshots.values)
        )
    }

    func scopedStartupSnapshot(projectSnapshot: ScanSnapshot) -> ScanSnapshot {
        projectSnapshot
    }

    var selectedPromptTemplate: PromptTemplateRecord? {
        allVisiblePromptTemplateRecords.first(where: { $0.id == selectedCommandItemID })
    }

    var allVisiblePromptTemplateRecords: [PromptTemplateRecord] {
        // Global resource catalog — independent of `selectedProjectPath` so the
        // Prompts view stays global even when a project is selected for Issues.
        let records = deduplicateByID(globalSnapshot.promptTemplates + globalSnapshot.libraryPromptTemplates)
            .sorted { lhs, rhs in
                let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                return lhs.source.kind.rawValue < rhs.source.kind.rawValue
            }
        guard !pendingDeletedPromptIDs.isEmpty else { return records }
        return records.filter { !pendingDeletedPromptIDs.contains($0.id) }
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

    func availableSkillCollectionNames(for target: AgentEditingTarget) -> [String] {
        appSettings.skillCollections.map(\.name)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func availableToolNames(for target: AgentEditingTarget) -> [String] {
        let scopeSnapshot = scopeSnapshot(for: target)
        var tools = [
            "read", "grep", "find", "ls", "bash",
            "edit", "write", "ask_user"
        ]
        let exaConfigured = isExaConfigured(for: target)
        if exaConfigured {
            tools.append(contentsOf: PiNativeSubagentBridgeExtensions.exaToolNames)
        } else if WebFetchDependencyService().status().isInstalled {
            tools.append(PiNativeSubagentBridgeExtensions.fallbackWebFetchToolName)
        }

        let explicitTools = scopeSnapshot.effectiveAgents.flatMap { $0.resolved.tools ?? [] }
            .filter { tool in
                let normalized = tool.lowercased()
                if PiNativeSubagentBridgeExtensions.exaToolNames.contains(normalized) { return exaConfigured }
                if normalized == PiNativeSubagentBridgeExtensions.fallbackWebFetchToolName {
                    return !exaConfigured && WebFetchDependencyService().status().isInstalled
                }
                return true
            }
        return Array(Set(tools + explicitTools))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func isExaConfigured(for target: AgentEditingTarget) -> Bool {
        let environment = EnvRuntimeEnvironment().environment()
        return PiNativeSubagentBridgeExtensions.isExaConfigured(environment: environment)
    }

    func availableModelIdentifiers() -> [String] {
        enabledAvailableModels.map(\.identifier)
    }

    func makeAggregateSnapshot() -> ScanSnapshot {
        // The no-project view is a global/library management view. Project-local
        // resources remain visible only when their project is selected; they are not
        // merged here so global/library resources do not depend on scanning every repo.
        ScanSnapshot(
            projectRoot: nil,
            builtinAgents: globalSnapshot.builtinAgents,
            globalAgents: globalSnapshot.globalAgents,
            projectAgents: [],
            legacyProjectAgents: [],
            effectiveAgents: globalSnapshot.effectiveAgents,
            libraryAgents: globalSnapshot.libraryAgents,
            skills: globalSnapshot.skills,
            librarySkills: globalSnapshot.librarySkills,
            promptTemplates: globalSnapshot.promptTemplates,
            libraryPromptTemplates: globalSnapshot.libraryPromptTemplates,
            settings: globalSnapshot.settings,
            envKeys: globalSnapshot.envKeys,
            warnings: globalSnapshot.warnings
        )
    }

}
